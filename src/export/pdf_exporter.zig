//! Orchestrates PDF export by rendering document pages to offscreen textures,
//! extracting them as PNG images, and assembling a PDF file.
//!
//! Each page is rendered at A4 dimensions (1190×1684 pixels at 2× scale) using
//! raylib's RenderTexture2D. The renderer draws with an adjusted scroll_y so
//! each page captures the correct vertical slice of the document.

const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const LayoutTree = @import("../layout/layout_types.zig").LayoutTree;
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const renderer = @import("../render/renderer.zig");
const pdf_writer = @import("pdf_writer.zig");

const log = std.log.scoped(.pdf_exporter);

pub const ExportError = error{
    NoDocument,
    RenderFailed,
    WriteFailed,
    OutOfMemory,
};

/// Export the current document layout to a PDF file.
///
/// Renders the full document page-by-page to offscreen textures, extracts each
/// as a PNG image, and writes a single PDF containing all pages.
///
/// Parameters:
///   - allocator: Used for temporary allocations (PNG data, page list)
///   - tree: The laid-out document to render
///   - theme: Current theme for rendering
///   - fonts: Loaded fonts for text rendering
///   - output_path: File system path to write the PDF to
pub fn exportPdf(
    allocator: Allocator,
    tree: *const LayoutTree,
    theme: *const Theme,
    fonts: *const Fonts,
    output_path: []const u8,
) !void {
    const page_w = pdf_writer.page_pixel_width;
    const page_h = pdf_writer.page_pixel_height;
    const page_h_f: f32 = @floatFromInt(page_h);

    // Calculate number of pages needed
    const total_height = tree.total_height;
    if (total_height <= 0) return ExportError.NoDocument;

    const num_pages: u32 = @intFromFloat(@ceil(total_height / page_h_f));

    // Collect PNG data for all pages
    var png_buffers = std.ArrayList(PngBuffer).init(allocator);
    defer {
        for (png_buffers.items) |buf| {
            rl.memFree(@ptrCast(buf.data));
        }
        png_buffers.deinit();
    }

    // Create the render texture once and reuse it for each page
    const target = rl.loadRenderTexture(@intCast(page_w), @intCast(page_h)) catch {
        log.err("Failed to create render texture ({d}x{d})", .{ page_w, page_h });
        return ExportError.RenderFailed;
    };
    defer rl.unloadRenderTexture(target);

    for (0..num_pages) |page_idx| {
        const scroll_y: f32 = @as(f32, @floatFromInt(page_idx)) * page_h_f;

        // Render to offscreen texture
        rl.beginTextureMode(target);
        rl.clearBackground(theme.background);

        // Render with menu_bar_height=0 (no menu bar in PDF) and adjusted scroll_y.
        // We call the renderer directly — it uses scissor mode based on screen
        // dimensions, but inside a RenderTexture that's the texture dimensions.
        renderer.render(tree, theme, fonts, scroll_y, 0);

        rl.endTextureMode();

        // Extract image from texture (RenderTextures are Y-flipped in OpenGL)
        var image = rl.loadImageFromTexture(target.texture) catch {
            log.err("Failed to load image from texture for page {d}", .{page_idx});
            return ExportError.RenderFailed;
        };
        defer rl.unloadImage(image);
        rl.imageFlipVertical(&image);

        // Export as PNG to memory — call C API directly to safely null-check
        // the returned pointer (the Zig wrapper calls std.mem.span which panics on null)
        var file_size: c_int = 0;
        const raw_ptr: ?[*]u8 = rl.cdef.ExportImageToMemory(image, ".png", &file_size);
        if (raw_ptr == null or file_size <= 0) {
            log.err("Failed to export page {d} as PNG", .{page_idx});
            return ExportError.RenderFailed;
        }
        const png_ptr = raw_ptr.?;
        errdefer rl.memFree(@ptrCast(png_ptr));

        try png_buffers.append(.{
            .data = png_ptr,
            .size = @intCast(file_size),
        });
    }

    // Build PDF
    var pw = pdf_writer.PdfWriter.init(allocator);
    defer pw.deinit();

    for (png_buffers.items) |buf| {
        const png_slice = buf.data[0..buf.size];
        try pw.addPage(png_slice);
    }

    // Write to file
    const file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
        log.err("Failed to create output file '{s}': {}", .{ output_path, err });
        return ExportError.WriteFailed;
    };
    defer file.close();

    pw.write(file.writer()) catch |err| {
        log.err("Failed to write PDF: {}", .{err});
        return ExportError.WriteFailed;
    };

    log.info("Exported {d} page(s) to '{s}'", .{ num_pages, output_path });
}

/// Holds a pointer to PNG data allocated by raylib (freed via rl.memFree).
const PngBuffer = struct {
    data: [*]u8,
    size: usize,
};

/// Build a default PDF filename by replacing the extension.
/// E.g., "document.md" -> "document.pdf", null -> "export.pdf".
/// Caller must free the returned slice.
pub fn buildPdfName(allocator: Allocator, file_path: ?[]const u8) Allocator.Error![]u8 {
    const path = file_path orelse return try allocator.dupe(u8, "export.pdf");
    const basename = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOf(u8, basename, ".")) |dot_idx|
        basename[0..dot_idx]
    else
        basename;

    const result = try allocator.alloc(u8, stem.len + 4);
    @memcpy(result[0..stem.len], stem);
    @memcpy(result[stem.len..][0..4], ".pdf");
    return result;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "buildPdfName with .md extension" {
    const name = try buildPdfName(testing.allocator, "document.md");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("document.pdf", name);
}

test "buildPdfName with path" {
    const name = try buildPdfName(testing.allocator, "/home/user/notes/readme.md");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("readme.pdf", name);
}

test "buildPdfName with no extension" {
    const name = try buildPdfName(testing.allocator, "README");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("README.pdf", name);
}

test "buildPdfName with null path" {
    const name = try buildPdfName(testing.allocator, null);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("export.pdf", name);
}

test "buildPdfName with .markdown extension" {
    const name = try buildPdfName(testing.allocator, "notes.markdown");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("notes.pdf", name);
}

test "buildPdfName with multiple dots" {
    const name = try buildPdfName(testing.allocator, "my.notes.v2.md");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("my.notes.v2.pdf", name);
}

test "buildPdfName with dot-only filename" {
    const name = try buildPdfName(testing.allocator, ".hidden");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings(".pdf", name);
}

test "buildPdfName with empty string" {
    const name = try buildPdfName(testing.allocator, "");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings(".pdf", name);
}

// NOTE: exportPdf depends on raylib (OpenGL context, RenderTexture) and cannot
// be unit tested. Integration testing requires a live window.
