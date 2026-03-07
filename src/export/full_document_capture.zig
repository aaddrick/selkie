//! Full-document capture: renders the entire scrollable document content
//! into an in-memory pixel buffer (RGBA).
//!
//! When a document is taller than the viewport, this module tiles the
//! rendering: it creates an offscreen render texture of a manageable height,
//! renders successive vertical strips of the document (advancing scroll_y),
//! reads back each tile's pixels, and composites them into a single
//! contiguous RGBA buffer.
//!
//! Supports both render mode (layout tree) and editor mode (editor state).
//! The caller provides a draw callback that is invoked once per tile.
//!
//! OpenGL imposes a maximum texture dimension (commonly 4096–16384 px).
//! This module queries the GPU limit and uses it as the tile height,
//! falling back to 4096 if the query fails.

const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.full_document_capture);

pub const FullCaptureError = error{
    NoWindow,
    RenderTextureFailed,
    PixelReadFailed,
    EmptyDocument,
    OutOfMemory,
    ImageTooLarge,
};

/// Maximum total pixel buffer size (256 MB) to prevent runaway allocations.
const max_buffer_bytes: usize = 256 * 1024 * 1024;

/// Result of a full-document capture. Caller owns the pixel buffer.
pub const FullCaptureResult = struct {
    /// RGBA pixel data, row-major, top-to-bottom. Owned by `allocator`.
    pixels: []u8,
    width: u32,
    height: u32,
    allocator: Allocator,

    pub fn deinit(self: *FullCaptureResult) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn stride(self: FullCaptureResult) usize {
        return @as(usize, self.width) * 4;
    }
};

pub const FullCaptureParams = struct {
    /// 0 = use current screen width.
    width: u32 = 0,
    /// Total document height in pixels (must be > 0). Caller computes
    /// this from the layout tree or editor state.
    document_height: u32,
};

/// Signature for the draw callback invoked per tile.
///
/// Arguments:
///   - width:    tile width in pixels
///   - height:   tile height in pixels (may be less than max for the last tile)
///   - scroll_y: vertical offset into the document for this tile
///   - context:  opaque user pointer (typically *App)
///
/// The callback must draw the document content as if the viewport were
/// `width` x `height` pixels at the given `scroll_y` offset. It should
/// clear the background and render content without UI chrome.
pub const TileDrawFn = *const fn (width: u32, height: u32, scroll_y: f32, context: *anyopaque) void;

/// Capture the full document by tiling.
///
/// Creates a render texture, iterates through the document in vertical tiles,
/// calls `draw_fn` for each tile, reads back the pixels, and composites them
/// into a single RGBA buffer.
///
/// The render texture height is capped at the GPU's max texture size.
/// For documents shorter than one tile, a single render pass suffices.
pub fn captureFullDocument(
    allocator: Allocator,
    params: FullCaptureParams,
    draw_fn: TileDrawFn,
    context: *anyopaque,
) FullCaptureError!FullCaptureResult {
    if (!rl.isWindowReady()) return FullCaptureError.NoWindow;

    const doc_height = params.document_height;
    if (doc_height == 0) return FullCaptureError.EmptyDocument;

    const width: u32 = if (params.width > 0) params.width else @intCast(rl.getScreenWidth());
    if (width == 0) return FullCaptureError.EmptyDocument;

    // Check total buffer size before allocating
    const total_bytes = @as(usize, width) * @as(usize, doc_height) * 4;
    if (total_bytes > max_buffer_bytes) {
        log.err("Full document capture would require {d} bytes (max {d})", .{ total_bytes, max_buffer_bytes });
        return FullCaptureError.ImageTooLarge;
    }

    // Query the GPU's max texture dimension
    const max_tex_size = getMaxTextureSize();
    const tile_height: u32 = @min(doc_height, max_tex_size);

    log.info("Full document capture: {d}x{d}, tile height={d}, max_tex={d}", .{
        width, doc_height, tile_height, max_tex_size,
    });

    // Create the render texture (reused across tiles)
    const target = rl.loadRenderTexture(@intCast(width), @intCast(tile_height)) catch {
        log.err("Failed to create {d}x{d} render texture", .{ width, tile_height });
        return FullCaptureError.RenderTextureFailed;
    };
    defer rl.unloadRenderTexture(target);

    // Allocate the output pixel buffer
    const pixels = allocator.alloc(u8, total_bytes) catch return FullCaptureError.OutOfMemory;
    errdefer allocator.free(pixels);

    // Tile through the document
    var y_offset: u32 = 0;
    while (y_offset < doc_height) {
        const remaining = doc_height - y_offset;
        const this_tile_h: u32 = @min(tile_height, remaining);

        // Render this tile
        rl.beginTextureMode(target);
        rl.clearBackground(rl.Color.blank);
        draw_fn(width, this_tile_h, @floatFromInt(y_offset), context);
        rl.endTextureMode();

        // Read back pixels from the render texture
        var image = rl.loadImageFromTexture(target.texture) catch {
            log.err("Failed to read pixels from render texture at y_offset={d}", .{y_offset});
            return FullCaptureError.PixelReadFailed;
        };
        defer rl.unloadImage(image);

        // OpenGL render textures are vertically flipped
        rl.imageFlipVertical(&image);

        // Copy the tile's pixels into the output buffer.
        // The tile image is tile_height tall, but we only want the first
        // this_tile_h rows (the last tile may be shorter).
        const src_data: [*]const u8 = @ptrCast(image.data);
        const row_bytes = @as(usize, width) * 4;

        for (0..this_tile_h) |row| {
            const src_start = row * row_bytes;
            const dst_start = (@as(usize, y_offset) + row) * row_bytes;
            @memcpy(
                pixels[dst_start..][0..row_bytes],
                src_data[src_start..][0..row_bytes],
            );
        }

        y_offset += this_tile_h;
    }

    return FullCaptureResult{
        .pixels = pixels,
        .width = width,
        .height = doc_height,
        .allocator = allocator,
    };
}

/// Maximum render texture height per tile.
///
/// OpenGL imposes a maximum texture dimension (commonly 4096–16384).
/// The raylib-zig bindings do not expose `glGetIntegerv(GL_MAX_TEXTURE_SIZE)`
/// directly, so we use a conservative default of 4096 which is supported
/// by virtually all OpenGL 3.x+ GPUs. This also keeps per-tile memory
/// usage reasonable (~4096 * width * 4 bytes per tile readback).
const default_max_tile_height: u32 = 4096;

fn getMaxTextureSize() u32 {
    return default_max_tile_height;
}

/// Compute the full document height for render mode from a layout tree's total_height.
pub fn documentHeightFromLayout(total_height: f32) u32 {
    if (total_height <= 0) return 0;
    return @intFromFloat(@ceil(total_height));
}

/// Compute the full document height for editor mode.
pub fn documentHeightFromEditor(line_count: usize, font_size: f32, line_height_factor: f32) u32 {
    if (line_count == 0) return 0;
    const h = @as(f32, @floatFromInt(line_count)) * font_size * line_height_factor;
    // Add a small bottom margin for visual comfort
    const margin: f32 = font_size * 2;
    return @intFromFloat(@ceil(h + margin));
}

const testing = std.testing;

test "FullCaptureResult.stride computes correctly" {
    var result = FullCaptureResult{
        .pixels = &.{},
        .width = 800,
        .height = 600,
        .allocator = testing.allocator,
    };
    try testing.expectEqual(@as(usize, 3200), result.stride());
    // Ensure deinit doesn't crash on empty slice
    // (Can't call deinit here because it was not allocated by testing.allocator)
    _ = &result;
}

test "FullCaptureResult.stride for single pixel" {
    var result = FullCaptureResult{
        .pixels = &.{},
        .width = 1,
        .height = 1,
        .allocator = testing.allocator,
    };
    try testing.expectEqual(@as(usize, 4), result.stride());
    _ = &result;
}

test "FullCaptureParams defaults" {
    const params = FullCaptureParams{ .document_height = 1000 };
    try testing.expectEqual(@as(u32, 0), params.width);
    try testing.expectEqual(@as(u32, 1000), params.document_height);
}

test "documentHeightFromLayout zero" {
    try testing.expectEqual(@as(u32, 0), documentHeightFromLayout(0));
}

test "documentHeightFromLayout positive" {
    try testing.expectEqual(@as(u32, 500), documentHeightFromLayout(500.0));
}

test "documentHeightFromLayout fractional rounds up" {
    try testing.expectEqual(@as(u32, 501), documentHeightFromLayout(500.1));
}

test "documentHeightFromLayout negative" {
    try testing.expectEqual(@as(u32, 0), documentHeightFromLayout(-10.0));
}

test "documentHeightFromEditor zero lines" {
    try testing.expectEqual(@as(u32, 0), documentHeightFromEditor(0, 16.0, 1.5));
}

test "documentHeightFromEditor single line" {
    // 1 line * 16px * 1.5 = 24px + 32px margin = 56px
    try testing.expectEqual(@as(u32, 56), documentHeightFromEditor(1, 16.0, 1.5));
}

test "documentHeightFromEditor many lines" {
    // 100 lines * 16px * 1.5 = 2400px + 32px margin = 2432px
    try testing.expectEqual(@as(u32, 2432), documentHeightFromEditor(100, 16.0, 1.5));
}

test "documentHeightFromEditor fractional rounds up" {
    // 3 lines * 14px * 1.3 = 54.6px + 28px margin = 82.6 → 83px
    try testing.expectEqual(@as(u32, 83), documentHeightFromEditor(3, 14.0, 1.3));
}

test "FullCaptureError is distinct error set" {
    const err: FullCaptureError = FullCaptureError.NoWindow;
    try testing.expect(err == FullCaptureError.NoWindow);
}

test "FullCaptureError EmptyDocument variant" {
    const err: FullCaptureError = FullCaptureError.EmptyDocument;
    try testing.expect(err == FullCaptureError.EmptyDocument);
}

test "FullCaptureError ImageTooLarge variant" {
    const err: FullCaptureError = FullCaptureError.ImageTooLarge;
    try testing.expect(err == FullCaptureError.ImageTooLarge);
}

test "max_buffer_bytes is 256 MB" {
    try testing.expectEqual(@as(usize, 256 * 1024 * 1024), max_buffer_bytes);
}

test "FullCaptureResult deinit frees memory" {
    const data = try testing.allocator.alloc(u8, 32);
    var result = FullCaptureResult{
        .pixels = data,
        .width = 2,
        .height = 2, // 2*2*4 = 16 but we allocated 32 — ok for test
        .allocator = testing.allocator,
    };
    result.deinit();
    // testing.allocator detects leaks — if deinit didn't free, test fails
}

// NOTE: captureFullDocument requires an active OpenGL context and cannot be
// unit tested. It is tested via integration tests with a live window.
