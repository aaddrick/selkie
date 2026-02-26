const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const block_renderer = @import("block_renderer.zig");
const table_renderer = @import("table_renderer.zig");
const image_renderer = @import("image_renderer.zig");

pub fn render(tree: *const lt.LayoutTree, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const view_top = scroll_y;
    const view_bottom = scroll_y + screen_h;

    for (tree.nodes.items) |*node| {
        // Frustum culling
        if (!node.rect.overlapsVertically(view_top, view_bottom)) continue;

        switch (node.kind) {
            .text_block, .heading => block_renderer.drawTextBlock(node, fonts, scroll_y),
            .code_block => block_renderer.drawCodeBlock(node, theme, fonts, scroll_y),
            .thematic_break => block_renderer.drawThematicBreak(node, theme, scroll_y),
            .block_quote_border => block_renderer.drawBlockQuoteBorder(node, theme, scroll_y),
            .table_row_bg => table_renderer.drawTableRowBg(node, scroll_y),
            .table_border => table_renderer.drawTableBorder(node, theme, scroll_y),
            .table_cell => table_renderer.drawTableCell(node, fonts, scroll_y),
            .image => block_renderer.drawImage(node, fonts, scroll_y),
        }
    }

    // Draw scrollbar
    drawScrollbar(tree.total_height, scroll_y, screen_h, theme);
}

fn drawScrollbar(total_height: f32, scroll_y: f32, screen_h: f32, theme: *const Theme) void {
    if (total_height <= screen_h) return;

    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const bar_width: f32 = 8;
    const bar_x = screen_w - bar_width - 4;

    // Track
    rl.drawRectangleRec(
        .{ .x = bar_x, .y = 0, .width = bar_width, .height = screen_h },
        theme.scrollbar_track,
    );

    // Thumb
    const visible_ratio = screen_h / total_height;
    const thumb_height = @max(20, screen_h * visible_ratio);
    const scroll_ratio = scroll_y / (total_height - screen_h);
    const thumb_y = scroll_ratio * (screen_h - thumb_height);

    rl.drawRectangleRounded(
        .{ .x = bar_x, .y = thumb_y, .width = bar_width, .height = thumb_height },
        0.5,
        4,
        theme.scrollbar,
    );
}
