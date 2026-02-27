const rl = @import("raylib");
const LayoutNode = @import("../layout/layout_types.zig").LayoutNode;
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const text_renderer = @import("text_renderer.zig");
const ImageRenderer = @import("image_renderer.zig").ImageRenderer;

/// Draw a code block: rounded background rectangle, line number gutter, and syntax-highlighted text.
pub fn drawCodeBlock(node: *const LayoutNode, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const code = node.data.code_block;
    const bg = code.bg_color orelse theme.code_background;
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
    if (code.line_number_gutter_width > 0) {
        const gutter_x = node.rect.x + code.line_number_gutter_width;
        const gutter_color = theme.line_number_color;
        rl.drawLineEx(
            .{ .x = gutter_x, .y = draw_y + theme.code_block_padding },
            .{ .x = gutter_x, .y = draw_y + node.rect.height - theme.code_block_padding },
            1.0,
            gutter_color,
        );
    }

    // Code blocks don't contain links; skip hover
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y, null);
    }
}

/// Draw a horizontal rule (thematic break).
pub fn drawThematicBreak(node: *const LayoutNode, scroll_y: f32) void {
    const color = node.data.thematic_break.color;
    rl.drawLineEx(
        .{ .x = node.rect.x, .y = node.rect.y - scroll_y },
        .{ .x = node.rect.x + node.rect.width, .y = node.rect.y - scroll_y },
        1.0,
        color,
    );
}

/// Draw a blockquote left border bar.
pub fn drawBlockQuoteBorder(node: *const LayoutNode, scroll_y: f32) void {
    const color = node.data.block_quote_border.color;
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

/// Draw text runs for a text block or heading. Link runs matching the hover state use hover color.
pub fn drawTextBlock(node: *const LayoutNode, fonts: *const Fonts, scroll_y: f32, hover: ?text_renderer.LinkHoverState) void {
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y, hover);
    }
}

/// Draw an image or placeholder if texture is missing.
pub fn drawImage(node: *const LayoutNode, fonts: *const Fonts, scroll_y: f32) void {
    const img = node.data.image;
    if (img.texture) |texture| {
        ImageRenderer.drawImage(texture, node.rect, scroll_y);
    } else {
        ImageRenderer.drawPlaceholder(node.rect, img.alt, fonts, scroll_y);
    }
}
