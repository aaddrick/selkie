const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const text_renderer = @import("text_renderer.zig");
const ImageRenderer = @import("image_renderer.zig").ImageRenderer;

/// Draw a code block: rounded background rectangle, line number gutter, and syntax-highlighted text.
pub fn drawCodeBlock(node: *const lt.LayoutNode, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const bg = node.code_bg_color orelse theme.code_background;
    const draw_y = node.rect.y - scroll_y;

    // Background rectangle
    rl.drawRectangleRounded(
        .{
            .x = node.rect.x,
            .y = draw_y,
            .width = node.rect.width,
            .height = node.rect.height,
        },
        0.02,
        4,
        bg,
    );

    // Gutter separator line
    if (node.line_number_gutter_width > 0) {
        const gutter_x = node.rect.x + node.line_number_gutter_width;
        const gutter_color = theme.line_number_color;
        rl.drawLineEx(
            .{ .x = gutter_x, .y = draw_y + theme.code_block_padding },
            .{ .x = gutter_x, .y = draw_y + node.rect.height - theme.code_block_padding },
            1.0,
            gutter_color,
        );
    }

    // Draw all text runs (line numbers + syntax-highlighted code)
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y);
    }
}

/// Draw a horizontal rule (thematic break).
pub fn drawThematicBreak(node: *const lt.LayoutNode, theme: *const Theme, scroll_y: f32) void {
    const color = node.hr_color orelse theme.hr_color;
    rl.drawLineEx(
        .{ .x = node.rect.x, .y = node.rect.y - scroll_y },
        .{ .x = node.rect.x + node.rect.width, .y = node.rect.y - scroll_y },
        1.0,
        color,
    );
}

/// Draw a blockquote left border bar.
pub fn drawBlockQuoteBorder(node: *const lt.LayoutNode, theme: *const Theme, scroll_y: f32) void {
    const color = node.hr_color orelse theme.blockquote_border;
    rl.drawRectangleRec(
        .{
            .x = node.rect.x,
            .y = node.rect.y - scroll_y,
            .width = node.rect.width,
            .height = node.rect.height,
        },
        color,
    );
}

/// Draw text runs for a text block or heading.
pub fn drawTextBlock(node: *const lt.LayoutNode, fonts: *const Fonts, scroll_y: f32) void {
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y);
    }
}

/// Draw an image or placeholder if texture is missing.
pub fn drawImage(node: *const lt.LayoutNode, fonts: *const Fonts, scroll_y: f32) void {
    if (node.image_texture) |texture| {
        ImageRenderer.drawImage(texture, node.rect, scroll_y);
    } else {
        ImageRenderer.drawPlaceholder(node.rect, node.image_alt, fonts, scroll_y);
    }
}

