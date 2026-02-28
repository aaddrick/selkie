const std = @import("std");
const rl = @import("raylib");
const layout_types = @import("../layout/layout_types.zig");
const LayoutTree = layout_types.LayoutTree;
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;

/// Draw source line numbers in the gutter area to the left of document content.
/// Each visible layout node with a non-zero source_line gets a line number.
/// Multi-line elements (source_end_line > source_line) show "N+" format.
/// `left_offset` accounts for sidebar width (gutter is drawn starting there).
pub fn drawGutter(tree: *const LayoutTree, theme: *const Theme, fonts: *const Fonts, scroll_y: f32, content_top_y: f32, left_offset: f32, viewport_h: f32) void {
    if (tree.gutter_width == 0) return;

    const screen_h: f32 = viewport_h;
    const view_top = scroll_y;
    const view_bottom = scroll_y + screen_h;
    const font_size = theme.mono_font_size;
    const spacing = font_size / 10.0;
    const font = fonts.mono;
    const gutter_right = left_offset + tree.gutter_width;
    const padding = layout_types.gutter_padding;

    // Clip to gutter area below chrome
    rl.beginScissorMode(
        @intFromFloat(left_offset),
        @intFromFloat(content_top_y),
        @intFromFloat(tree.gutter_width),
        @intFromFloat(screen_h - content_top_y),
    );
    defer rl.endScissorMode();

    // Track last drawn line number to avoid duplicates from multi-node elements
    // (e.g., table rows, code block nodes that share the same source line)
    var last_drawn_line: u32 = 0;

    for (tree.nodes.items) |*node| {
        if (!node.rect.overlapsVertically(view_top, view_bottom)) continue;
        if (node.source_line == 0) continue;
        if (node.source_line == last_drawn_line) continue;

        last_drawn_line = node.source_line;

        // max u32 is 10 digits + "+" + null = 12; 24 is generous
        var buf: [24:0]u8 = undefined;
        const is_multiline = node.source_end_line > node.source_line;
        const label = if (is_multiline)
            std.fmt.bufPrintZ(&buf, "{d}+", .{node.source_line}) catch continue
        else
            std.fmt.bufPrintZ(&buf, "{d}", .{node.source_line}) catch continue;

        const measured = rl.measureTextEx(font, label, font_size, spacing);
        const x = gutter_right - padding - measured.x;
        const y = node.rect.y - scroll_y;

        rl.drawTextEx(font, label, .{ .x = x, .y = y }, font_size, spacing, theme.line_number_color);
    }
}
