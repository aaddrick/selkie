const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const text_renderer = @import("text_renderer.zig");

pub fn render(tree: *const lt.LayoutTree, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const view_top = scroll_y;
    const view_bottom = scroll_y + screen_h;

    for (tree.nodes.items) |*node| {
        // Frustum culling
        if (!node.rect.overlapsVertically(view_top, view_bottom)) continue;

        switch (node.kind) {
            .text_block, .heading => {
                for (node.text_runs.items) |*run| {
                    text_renderer.drawTextRun(run, fonts, scroll_y);
                }
            },
            .code_block => {
                // Draw background
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

                // Draw code text
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
            },
            .thematic_break => {
                const color = node.hr_color orelse theme.hr_color;
                rl.drawLineEx(
                    .{ .x = node.rect.x, .y = node.rect.y - scroll_y },
                    .{ .x = node.rect.x + node.rect.width, .y = node.rect.y - scroll_y },
                    1.0,
                    color,
                );
            },
            .block_quote_border => {
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
            },
        }
    }

    // Draw scrollbar
    drawScrollbar(tree.total_height, scroll_y, screen_h, theme);
}

fn drawCodeText(font: rl.Font, text: []const u8, pos: rl.Vector2, font_size: f32, spacing: f32, color: rl.Color) void {
    if (text.len == 0) return;
    // Check if naturally null-terminated
    const maybe_sentinel: [*]const u8 = text.ptr;
    if (maybe_sentinel[text.len] == 0) {
        const z: [:0]const u8 = text.ptr[0..text.len :0];
        rl.drawTextEx(font, z, pos, font_size, spacing, color);
        return;
    }
    // Stack buffer fallback for code blocks (larger buffer)
    var buf: [4096]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];
    rl.drawTextEx(font, z, pos, font_size, spacing, color);
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
