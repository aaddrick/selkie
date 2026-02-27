const rl = @import("raylib");
const LayoutNode = @import("../layout/layout_types.zig").LayoutNode;
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const text_renderer = @import("text_renderer.zig");

/// Draw a table row background (header bg or alternating row bg).
pub fn drawTableRowBg(node: *const LayoutNode, scroll_y: f32) void {
    const bg = node.data.table_row_bg.bg_color;
    rl.drawRectangleRec(
        .{
            .x = node.rect.x,
            .y = node.rect.y - scroll_y,
            .width = node.rect.width,
            .height = node.rect.height,
        },
        bg,
    );
}

/// Draw table grid lines (borders).
pub fn drawTableBorder(node: *const LayoutNode, scroll_y: f32) void {
    const color = node.data.table_border.color;
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

/// Draw text runs within a table cell.
pub fn drawTableCell(node: *const LayoutNode, fonts: *const Fonts, scroll_y: f32) void {
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y);
    }
}
