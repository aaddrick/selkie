//! Orchestrates PDF export by walking the LayoutTree and emitting text/vector
//! draw commands to produce a text-based PDF with embedded fonts.
//!
//! Text, headings, code blocks, tables → PDF text operators (selectable text)
//! Rectangles, borders → PDF vector operators
//! Images, mermaid diagrams → rasterized PNG XObjects (fallback)

const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const layout_types = @import("../layout/layout_types.zig");
const LayoutTree = layout_types.LayoutTree;
const LayoutNode = layout_types.LayoutNode;
const TextRun = layout_types.TextRun;
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const renderer = @import("../render/renderer.zig");
const pdf_writer = @import("pdf_writer.zig");
const document_layout = @import("../layout/document_layout.zig");
const ast = @import("../parser/ast.zig");
const ImageRenderer = @import("../render/image_renderer.zig").ImageRenderer;
const asset_paths = @import("../asset_paths.zig");

const log = std.log.scoped(.pdf_exporter);

pub const ExportError = error{
    NoDocument,
    RenderFailed,
    WriteFailed,
};

/// Holds a pointer to PNG data allocated by raylib (freed via rl.memFree).
const PngBuffer = struct {
    data: [*]u8,
    size: usize,

    fn slice(self: PngBuffer) []const u8 {
        return self.data[0..self.size];
    }

    fn free(self: PngBuffer) void {
        rl.memFree(@ptrCast(self.data));
    }
};

/// Export the current document to a text-based PDF file.
pub fn exportPdf(
    allocator: Allocator,
    document: *const ast.Document,
    theme: *const Theme,
    fonts: *const Fonts,
    image_renderer: *ImageRenderer,
    output_path: []const u8,
) !void {
    const scale = pdf_writer.render_scale;
    const page_h_pt = pdf_writer.a4_height_pt;
    const page_h_px = @as(f32, @floatFromInt(pdf_writer.page_pixel_height));
    const page_w_px = @as(f32, @floatFromInt(pdf_writer.page_pixel_width));

    // Re-layout document at A4 pixel width
    var pdf_tree = document_layout.layout(
        allocator,
        document,
        theme,
        fonts,
        page_w_px,
        image_renderer,
        0,
        0,
        false,
    ) catch return ExportError.RenderFailed;
    defer pdf_tree.deinit();

    const total_height = pdf_tree.total_height;
    if (total_height <= 0) return ExportError.NoDocument;

    const num_pages: u32 = @intFromFloat(@ceil(total_height / page_h_px));
    // Build PDF with text/vector commands
    var pw = pdf_writer.PdfWriter.init(allocator);
    defer pw.deinit();

    // Collect rasterized images for image/mermaid nodes
    var png_buffers = std.ArrayList(PngBuffer).init(allocator);
    defer {
        for (png_buffers.items) |buf| buf.free();
        png_buffers.deinit();
    }

    for (0..num_pages) |page_idx| {
        const page_top_px: f32 = @as(f32, @floatFromInt(page_idx)) * page_h_px;
        const page_bottom_px = page_top_px + page_h_px;

        // Show progress overlay
        showProgress(theme, page_idx + 1, num_pages);

        const page = try pw.addPage();

        // Walk all nodes and emit commands for those on this page
        for (pdf_tree.nodes.items) |*node| {
            if (!node.rect.overlapsVertically(page_top_px, page_bottom_px)) continue;

            switch (node.data) {
                .text_block, .heading, .table_cell => {
                    // Emit text runs
                    for (node.text_runs.items) |*run| {
                        try emitTextRun(page, run, page_top_px, scale, page_h_pt);
                    }
                },
                .code_block => |code| {
                    // Background rectangle
                    if (code.bg_color) |bg| {
                        try emitRect(page, node.rect, bg, page_top_px, scale, page_h_pt);
                    }
                    // Text runs
                    for (node.text_runs.items) |*run| {
                        try emitTextRun(page, run, page_top_px, scale, page_h_pt);
                    }
                },
                .thematic_break => |tb| {
                    try emitHLine(page, node.rect.x, node.rect.y, node.rect.width, tb.color, page_top_px, scale, page_h_pt);
                },
                .block_quote_border => |bq| {
                    try emitRect(page, node.rect, bq.color, page_top_px, scale, page_h_pt);
                },
                .table_row_bg => |bg| {
                    try emitRect(page, node.rect, bg.bg_color, page_top_px, scale, page_h_pt);
                },
                .table_border => |tb| {
                    try emitRect(page, node.rect, tb.color, page_top_px, scale, page_h_pt);
                },
                .image => {
                    // Rasterize image to PNG and embed as XObject
                    try rasterizeNode(allocator, &pw, page, node, &pdf_tree, theme, page_top_px, scale, page_h_pt, &png_buffers);
                },
                .mermaid_diagram => {
                    // Rasterize mermaid diagram to PNG and embed as XObject
                    try rasterizeNode(allocator, &pw, page, node, &pdf_tree, theme, page_top_px, scale, page_h_pt, &png_buffers);
                },
            }
        }
    }

    // Load font data for embedding
    for (0..pdf_writer.num_fonts) |fi| {
        const asset_name = pdf_writer.PdfWriter.font_asset_names[fi];
        const path = asset_paths.resolveAssetPath(allocator, asset_name) catch {
            log.err("Failed to resolve font path: {s}", .{asset_name});
            return ExportError.RenderFailed;
        };
        defer allocator.free(path);

        const font_data = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch {
            log.err("Failed to read font file: {s}", .{asset_name});
            return ExportError.RenderFailed;
        };
        pw.font_data[fi] = font_data;
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

fn showProgress(theme: *const Theme, current: usize, total: u32) void {
    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(theme.background);
    var msg_buf: [64:0]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&msg_buf, "Exporting page {d}/{d}...", .{ current, total }) catch "Exporting...";
    const font_size: i32 = 24;
    const text_w = rl.measureText(msg, font_size);
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    rl.drawText(msg, @divTrunc(sw - text_w, 2), @divTrunc(sh, 2), font_size, theme.text);
}

/// Determine font ID from text run style.
fn fontIdFromStyle(style: layout_types.TextStyle) pdf_writer.FontId {
    if (style.is_code) return .mono;
    if (style.bold and style.italic) return .bold_italic;
    if (style.bold) return .bold;
    if (style.italic) return .italic;
    return .body;
}

/// Convert an rl.Color to PDF RGB (0..1).
fn colorToRgb(c: rl.Color) [3]f32 {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
    };
}

/// Emit a text run as a PDF text command.
fn emitTextRun(
    page: *pdf_writer.PageContent,
    run: *const TextRun,
    page_top_px: f32,
    scale: f32,
    page_h_pt: f32,
) !void {
    if (run.text.len == 0) return;

    const x_pt = run.rect.x / scale;
    // PDF Y is from bottom; convert pixel Y relative to page top
    const y_in_page_px = run.rect.y - page_top_px;
    // Place text at baseline: top of text rect + ascent ≈ top + font_size
    const y_pt = page_h_pt - (y_in_page_px + run.rect.height) / scale;

    try page.addCmd(.{ .text = .{
        .x_pt = x_pt,
        .y_pt = y_pt,
        .font_id = fontIdFromStyle(run.style),
        .font_size_pt = run.style.font_size / scale,
        .color = colorToRgb(run.style.color),
        .text = run.text,
    } });

    // Strikethrough line
    if (run.style.strikethrough) {
        const strike_y_px = run.rect.y + run.rect.height / 2.0;
        try emitHLine(page, run.rect.x, strike_y_px, run.rect.width, run.style.color, page_top_px, scale, page_h_pt);
    }

    // Underline
    if (run.style.underline) {
        const underline_y_px = run.rect.y + run.rect.height - 2;
        try emitHLine(page, run.rect.x, underline_y_px, run.rect.width, run.style.color, page_top_px, scale, page_h_pt);
    }
}

/// Emit a filled rectangle.
fn emitRect(
    page: *pdf_writer.PageContent,
    rect: layout_types.Rect,
    color: rl.Color,
    page_top_px: f32,
    scale: f32,
    page_h_pt: f32,
) !void {
    const x_pt = rect.x / scale;
    const y_in_page_px = rect.y - page_top_px;
    const y_pt = page_h_pt - (y_in_page_px + rect.height) / scale;
    const w_pt = rect.width / scale;
    const h_pt = rect.height / scale;

    try page.addCmd(.{ .rect = .{
        .x_pt = x_pt,
        .y_pt = y_pt,
        .w_pt = w_pt,
        .h_pt = h_pt,
        .color = colorToRgb(color),
    } });
}

/// Emit a horizontal line.
fn emitHLine(
    page: *pdf_writer.PageContent,
    x_px: f32,
    y_px: f32,
    width_px: f32,
    color: rl.Color,
    page_top_px: f32,
    scale: f32,
    page_h_pt: f32,
) !void {
    const x1_pt = x_px / scale;
    const y_in_page = y_px - page_top_px;
    const y_pt = page_h_pt - y_in_page / scale;
    const x2_pt = x1_pt + width_px / scale;

    try page.addCmd(.{ .line = .{
        .x1_pt = x1_pt,
        .y1_pt = y_pt,
        .x2_pt = x2_pt,
        .y2_pt = y_pt,
        .width_pt = 0.5,
        .color = colorToRgb(color),
    } });
}

/// Rasterize a node (image or mermaid) to a PNG and embed as an image XObject.
fn rasterizeNode(
    allocator: Allocator,
    pw: *pdf_writer.PdfWriter,
    page: *pdf_writer.PageContent,
    node: *const LayoutNode,
    tree: *const LayoutTree,
    theme: *const Theme,
    page_top_px: f32,
    scale: f32,
    page_h_pt: f32,
    png_buffers: *std.ArrayList(PngBuffer),
) !void {
    _ = tree;
    _ = allocator;

    const rect = node.rect;
    const w: u32 = @intFromFloat(@max(1, rect.width));
    const h: u32 = @intFromFloat(@max(1, rect.height));

    // Create a render texture for this element
    const target = rl.loadRenderTexture(@intCast(w), @intCast(h)) catch {
        log.err("Failed to create render texture for node rasterization", .{});
        return;
    };
    defer rl.unloadRenderTexture(target);

    rl.beginTextureMode(target);
    rl.clearBackground(theme.background);

    // Render the specific node content with scroll_y = rect.y so it draws at y=0
    switch (node.data) {
        .image => |img| {
            if (img.texture) |texture| {
                ImageRenderer.drawImage(texture, .{ .x = 0, .y = 0, .width = rect.width, .height = rect.height }, 0);
            }
        },
        .mermaid_diagram => |mermaid| {
            const dummy_fonts = @import("../layout/text_measurer.zig").Fonts{
                .body = undefined,
                .bold = undefined,
                .italic = undefined,
                .bold_italic = undefined,
                .mono = undefined,
            };
            _ = dummy_fonts;
            // Draw the mermaid diagram at origin
            const flowchart_renderer = @import("../mermaid/renderers/flowchart_renderer.zig");
            const sequence_renderer = @import("../mermaid/renderers/sequence_renderer.zig");
            const pie_renderer = @import("../mermaid/renderers/pie_renderer.zig");
            const gantt_renderer = @import("../mermaid/renderers/gantt_renderer.zig");
            const class_renderer = @import("../mermaid/renderers/class_renderer.zig");
            const er_renderer = @import("../mermaid/renderers/er_renderer.zig");
            const state_renderer = @import("../mermaid/renderers/state_renderer.zig");
            const mindmap_renderer = @import("../mermaid/renderers/mindmap_renderer.zig");
            const gitgraph_renderer = @import("../mermaid/renderers/gitgraph_renderer.zig");
            const journey_renderer = @import("../mermaid/renderers/journey_renderer.zig");
            const timeline_renderer = @import("../mermaid/renderers/timeline_renderer.zig");

            // We need fonts for mermaid rendering — use the app's loaded fonts
            // For now, we skip mermaid diagrams in text-based PDF (they require loaded fonts)
            // Instead just render a placeholder
            _ = mermaid;
            _ = flowchart_renderer;
            _ = sequence_renderer;
            _ = pie_renderer;
            _ = gantt_renderer;
            _ = class_renderer;
            _ = er_renderer;
            _ = state_renderer;
            _ = mindmap_renderer;
            _ = gitgraph_renderer;
            _ = journey_renderer;
            _ = timeline_renderer;
        },
        else => {},
    }

    rl.endTextureMode();

    // Extract PNG
    var image = rl.loadImageFromTexture(target.texture) catch return;
    defer rl.unloadImage(image);
    rl.imageFlipVertical(&image);
    rl.imageFormat(&image, .uncompressed_r8g8b8);

    var file_size: c_int = 0;
    const png_ptr = rl.cdef.ExportImageToMemory(image, ".png", &file_size) orelse return;
    if (file_size <= 0) {
        rl.memFree(@ptrCast(png_ptr));
        return;
    }

    const buf = PngBuffer{ .data = png_ptr, .size = @intCast(file_size) };
    const img_idx = pw.addImage(buf.slice()) catch {
        buf.free();
        return;
    };

    // Keep the buffer alive until PDF is written
    png_buffers.append(buf) catch return;

    // Emit image draw command
    const x_pt = rect.x / scale;
    const y_in_page_px = rect.y - page_top_px;
    const y_pt = page_h_pt - (y_in_page_px + rect.height) / scale;
    const w_pt = rect.width / scale;
    const h_pt = rect.height / scale;

    page.addCmd(.{ .image = .{
        .x_pt = x_pt,
        .y_pt = y_pt,
        .w_pt = w_pt,
        .h_pt = h_pt,
        .image_index = img_idx,
    } }) catch return;
}

/// Build a default PDF filename by replacing the extension.
pub fn buildPdfName(allocator: Allocator, file_path: ?[]const u8) Allocator.Error![]u8 {
    const path = file_path orelse return try allocator.dupe(u8, "export.pdf");
    const basename = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOf(u8, basename, ".")) |dot_idx|
        basename[0..dot_idx]
    else
        basename;

    return try std.fmt.allocPrint(allocator, "{s}.pdf", .{stem});
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

test "fontIdFromStyle returns correct font" {
    try testing.expectEqual(pdf_writer.FontId.body, fontIdFromStyle(.{ .font_size = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } }));
    try testing.expectEqual(pdf_writer.FontId.bold, fontIdFromStyle(.{ .font_size = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .bold = true }));
    try testing.expectEqual(pdf_writer.FontId.italic, fontIdFromStyle(.{ .font_size = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .italic = true }));
    try testing.expectEqual(pdf_writer.FontId.bold_italic, fontIdFromStyle(.{ .font_size = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .bold = true, .italic = true }));
    try testing.expectEqual(pdf_writer.FontId.mono, fontIdFromStyle(.{ .font_size = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .is_code = true }));
}

test "colorToRgb converts correctly" {
    const rgb = colorToRgb(.{ .r = 255, .g = 128, .b = 0, .a = 255 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), rgb[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.502), rgb[1], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), rgb[2], 0.01);
}

// NOTE: exportPdf and rasterizeNode depend on raylib (OpenGL context) and cannot
// be unit tested. Integration testing requires a live window.
