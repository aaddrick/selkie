const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const text_renderer = @import("text_renderer.zig");

/// Draw a code block: rounded background rectangle with monospace text.
pub fn drawCodeBlock(node: *const lt.LayoutNode, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const bg = node.code_bg_color orelse theme.code_background;
    rl.drawRectangleRounded(
        .{
            .x = node.rect.x,
            .y = node.rect.y - scroll_y,
            .width = node.rect.width,
            .height = node.rect.height,
        },
        0.02,
        4,
        bg,
    );

    if (node.code_text) |code| {
        const spacing = theme.mono_font_size / 10.0;
        drawCodeText(
            fonts.mono,
            code,
            .{
                .x = node.rect.x + theme.code_block_padding,
                .y = node.rect.y + theme.code_block_padding - scroll_y,
            },
            theme.mono_font_size,
            spacing,
            theme.code_text,
        );
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

fn drawCodeText(font: rl.Font, text: []const u8, pos: rl.Vector2, font_size: f32, spacing: f32, color: rl.Color) void {
    if (text.len == 0) return;
    const maybe_sentinel: [*]const u8 = text.ptr;
    if (maybe_sentinel[text.len] == 0) {
        const z: [:0]const u8 = text.ptr[0..text.len :0];
        rl.drawTextEx(font, z, pos, font_size, spacing, color);
        return;
    }
    var buf: [4096]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];
    rl.drawTextEx(font, z, pos, font_size, spacing, color);
}
