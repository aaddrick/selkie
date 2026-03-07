//! Framebuffer/pixel capture from the current viewport.
//!
//! Captures the current OpenGL framebuffer as a PNG image, supporting both
//! edit mode and render mode. The capture reads whatever is currently drawn
//! on screen (or in a render texture), converts it to an Image, and exports
//! to PNG format in memory or to a file.
//!
//! Two capture modes:
//! - **Viewport capture**: Reads the current screen framebuffer (includes UI chrome)
//! - **Content-only capture**: Renders content to an offscreen texture, excluding
//!   menu bar, tab bar, sidebar, and other chrome elements
//!
//! The content-only mode re-renders the active tab's content (editor or document)
//! into a dedicated render texture at the specified dimensions.

const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.screenshot_capture);

pub const CaptureError = error{
    NoWindow,
    RenderTextureFailed,
    PixelReadFailed,
    PngEncodeFailed,
    WriteFailed,
    OutOfMemory,
};

/// Result of a capture operation. Caller must call `deinit()` to free.
pub const CaptureResult = struct {
    png_data: [*]u8, // owned by raylib — freed via rl.memFree
    png_size: usize,
    width: u32,
    height: u32,

    pub fn slice(self: CaptureResult) []const u8 {
        return self.png_data[0..self.png_size];
    }

    /// Free the raylib-owned PNG buffer. The CaptureResult must not be used
    /// after calling deinit — the png_data pointer becomes invalid.
    pub fn deinit(self: *CaptureResult) void {
        rl.memFree(@ptrCast(self.png_data));
        self.* = undefined;
    }

    pub fn writeToFile(self: CaptureResult, output_path: []const u8) CaptureError!void {
        const file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
            log.err("Failed to create output file '{s}': {}", .{ output_path, err });
            return CaptureError.WriteFailed;
        };
        defer file.close();

        file.writeAll(self.slice()) catch |err| {
            log.err("Failed to write PNG data to '{s}': {}", .{ output_path, err });
            return CaptureError.WriteFailed;
        };

        log.info("Screenshot saved to '{s}' ({d}x{d}, {d} bytes)", .{
            output_path, self.width, self.height, self.png_size,
        });
    }
};

/// Capture the current screen framebuffer as a PNG.
///
/// This reads whatever is currently rendered on the screen, including all
/// UI chrome (menu bar, tab bar, sidebar, scrollbar, dialogs).
/// Must be called after `rl.endDrawing()` or between frames when the
/// framebuffer contains the desired content.
pub fn captureViewport() CaptureError!CaptureResult {
    if (!rl.isWindowReady()) return CaptureError.NoWindow;

    // Read pixels from the current screen framebuffer via C API
    const image = rl.cdef.LoadImageFromScreen();
    // image.data is *anyopaque (non-optional); check dimensions to detect failure
    if (image.width <= 0 or image.height <= 0) {
        log.err("Failed to read screen framebuffer", .{});
        return CaptureError.PixelReadFailed;
    }
    defer rl.cdef.UnloadImage(image);

    const width: u32 = @intCast(image.width);
    const height: u32 = @intCast(image.height);

    // Export to PNG in memory
    var file_size: c_int = 0;
    const png_ptr = rl.cdef.ExportImageToMemory(image, ".png", &file_size) orelse {
        log.err("Failed to encode PNG from screen capture", .{});
        return CaptureError.PngEncodeFailed;
    };

    if (file_size <= 0) {
        rl.memFree(@ptrCast(png_ptr));
        return CaptureError.PngEncodeFailed;
    }

    return CaptureResult{
        .png_data = png_ptr,
        .png_size = @intCast(file_size),
        .width = width,
        .height = height,
    };
}

/// Parameters for content-only capture (no UI chrome). 0 = use current viewport size.
pub const ContentCaptureParams = struct {
    width: u32 = 0,
    height: u32 = 0,
};

/// Capture content rendered to an offscreen render texture.
///
/// This creates a render texture, invokes the provided draw callback to render
/// content into it (without UI chrome), then extracts the pixels as PNG.
///
/// The `draw_fn` receives the render texture dimensions and should draw the
/// desired content (editor or document view) at those dimensions. It is called
/// between `beginTextureMode` and `endTextureMode`.
///
/// Example:
/// ```zig
/// const result = try captureContent(.{ .width = 1920, .height = 1080 }, struct {
///     pub fn draw(w: u32, h: u32, ctx: *anyopaque) void {
///         const app: *App = @ptrCast(@alignCast(ctx));
///         app.drawContentOnly(w, h);
///     }
/// }.draw, @ptrCast(app));
/// defer result.deinit();
/// ```
pub fn captureContent(
    params: ContentCaptureParams,
    draw_fn: *const fn (width: u32, height: u32, context: *anyopaque) void,
    context: *anyopaque,
) CaptureError!CaptureResult {
    if (!rl.isWindowReady()) return CaptureError.NoWindow;

    const w: u32 = if (params.width > 0) params.width else @intCast(rl.getScreenWidth());
    const h: u32 = if (params.height > 0) params.height else @intCast(rl.getScreenHeight());

    // Create offscreen render texture
    const target = rl.loadRenderTexture(@intCast(w), @intCast(h)) catch {
        log.err("Failed to create {d}x{d} render texture for content capture", .{ w, h });
        return CaptureError.RenderTextureFailed;
    };
    defer rl.unloadRenderTexture(target);

    // Render content into the texture
    rl.beginTextureMode(target);
    draw_fn(w, h, context);
    rl.endTextureMode();

    // Extract image from texture
    var image = rl.loadImageFromTexture(target.texture) catch {
        log.err("Failed to read pixels from render texture", .{});
        return CaptureError.PixelReadFailed;
    };
    defer rl.unloadImage(image);

    // OpenGL textures are flipped vertically
    rl.imageFlipVertical(&image);

    // Export to PNG in memory
    var file_size: c_int = 0;
    const png_ptr = rl.cdef.ExportImageToMemory(image, ".png", &file_size) orelse {
        log.err("Failed to encode PNG from content capture", .{});
        return CaptureError.PngEncodeFailed;
    };

    if (file_size <= 0) {
        rl.memFree(@ptrCast(png_ptr));
        return CaptureError.PngEncodeFailed;
    }

    return CaptureResult{
        .png_data = png_ptr,
        .png_size = @intCast(file_size),
        .width = w,
        .height = h,
    };
}

/// Build a default PNG filename from a source file path.
/// "document.md" -> "document.png", null -> "screenshot.png"
///
/// Delegates to `png_exporter.buildPngName` with "screenshot.png" as the
/// fallback name for null paths.
pub fn buildPngName(allocator: Allocator, file_path: ?[]const u8) Allocator.Error![]u8 {
    const png_exporter = @import("png_exporter.zig");
    return png_exporter.buildPngName(allocator, file_path, "screenshot.png");
}

const testing = std.testing;

test "CaptureResult.slice returns correct range" {
    // Use a stack buffer to test that slice() returns the correct sub-range
    var buf: [64]u8 = undefined;
    @memset(&buf, 0xAB);

    const result = CaptureResult{
        .png_data = @ptrCast(&buf),
        .png_size = 42,
        .width = 100,
        .height = 200,
    };
    const s = result.slice();
    try testing.expectEqual(@as(usize, 42), s.len);
    try testing.expectEqual(@as(u8, 0xAB), s[0]);
    try testing.expectEqual(@as(u8, 0xAB), s[41]);
    // Verify the pointer is correct (points to our stack buffer)
    try testing.expectEqual(@as([*]const u8, @ptrCast(&buf)), s.ptr);
}

test "buildPngName with .md extension" {
    const name = try buildPngName(testing.allocator, "document.md");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("document.png", name);
}

test "buildPngName with path" {
    const name = try buildPngName(testing.allocator, "/home/user/notes/readme.md");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("readme.png", name);
}

test "buildPngName with no extension" {
    const name = try buildPngName(testing.allocator, "README");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("README.png", name);
}

test "buildPngName with null path" {
    const name = try buildPngName(testing.allocator, null);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("screenshot.png", name);
}

test "buildPngName with .markdown extension" {
    const name = try buildPngName(testing.allocator, "notes.markdown");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("notes.png", name);
}

test "buildPngName with multiple dots" {
    const name = try buildPngName(testing.allocator, "my.notes.v2.md");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("my.notes.v2.png", name);
}

test "CaptureError is distinct from other error sets" {
    // Verify the error set compiles and contains expected variants
    const err: CaptureError = CaptureError.NoWindow;
    try testing.expect(err == CaptureError.NoWindow);
}

test "ContentCaptureParams defaults to zero" {
    const params = ContentCaptureParams{};
    try testing.expectEqual(@as(u32, 0), params.width);
    try testing.expectEqual(@as(u32, 0), params.height);
}

test "ContentCaptureParams accepts custom dimensions" {
    const params = ContentCaptureParams{ .width = 1920, .height = 1080 };
    try testing.expectEqual(@as(u32, 1920), params.width);
    try testing.expectEqual(@as(u32, 1080), params.height);
}

// NOTE: captureViewport and captureContent depend on raylib (OpenGL context)
// and cannot be unit tested. Integration testing requires a live window.
