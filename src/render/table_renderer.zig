const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const text_renderer = @import("text_renderer.zig");

/// Draw a table row background (header bg or alternating row bg).
pub fn drawTableRowBg(node: *const lt.LayoutNode, scroll_y: f32) void {
    const bg = node.code_bg_color orelse return;
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
pub fn drawTableBorder(node: *const lt.LayoutNode, theme: *const Theme, scroll_y: f32) void {
    const color = node.hr_color orelse theme.table_border;
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
pub fn drawTableCell(node: *const lt.LayoutNode, fonts: *const Fonts, scroll_y: f32) void {
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y);
    }
}
