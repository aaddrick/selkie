const rl = @import("raylib");
const LayoutNode = @import("../layout/layout_types.zig").LayoutNode;
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

/// Draw text runs within a table cell. Applies per-cell scissor clipping to
/// prevent right/center-aligned text from visually overflowing into adjacent
/// columns. The scissor region covers the cell rectangle (scrolled).
pub fn drawTableCell(node: *const LayoutNode, fonts: *const Fonts, scroll_y: f32, hover: ?text_renderer.LinkHoverState, viewport_h: f32) void {
    // Apply per-cell scissor to prevent text overflow into adjacent columns.
    // This replaces the outer viewport scissor temporarily; the caller in
    // renderer.zig re-applies the viewport scissor after each table_cell node.
    const clip_x: i32 = @intFromFloat(node.rect.x);
    const clip_y: i32 = @intFromFloat(@max(0, node.rect.y - scroll_y));
    const clip_w: i32 = @intFromFloat(node.rect.width);
    const clip_h: i32 = @intFromFloat(@min(node.rect.height, viewport_h));
    rl.beginScissorMode(clip_x, clip_y, clip_w, clip_h);

    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y, hover, viewport_h);
    }

    rl.endScissorMode();
}
