const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const Fonts = @import("../layout/text_measurer.zig").Fonts;

fn drawTextSlice(font: rl.Font, text: []const u8, pos: rl.Vector2, font_size: f32, spacing: f32, color: rl.Color) void {
    if (text.len == 0) return;
    // Check if naturally null-terminated
    const maybe_sentinel: [*]const u8 = text.ptr;
    if (maybe_sentinel[text.len] == 0) {
        const z: [:0]const u8 = text.ptr[0..text.len :0];
        rl.drawTextEx(font, z, pos, font_size, spacing, color);
        return;
    }
    // Stack buffer fallback
    var buf: [1024]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];
    rl.drawTextEx(font, z, pos, font_size, spacing, color);
}

pub fn drawTextRun(run: *const lt.TextRun, fonts: *const Fonts, scroll_y: f32) void {
    const draw_y = run.rect.y - scroll_y;

    // Skip if off screen
    if (draw_y + run.rect.height < 0) return;
    if (draw_y > @as(f32, @floatFromInt(rl.getScreenHeight()))) return;

    const font = if (run.style.is_code)
        fonts.mono
    else if (run.style.bold)
        fonts.bold
    else
        fonts.body;

    const spacing = run.style.font_size / 10.0;

    drawTextSlice(
        font,
        run.text,
        .{ .x = run.rect.x, .y = draw_y },
        run.style.font_size,
        spacing,
        run.style.color,
    );

    // Strikethrough
    if (run.style.strikethrough) {
        const strike_y = draw_y + run.rect.height / 2.0;
        rl.drawLineEx(
            .{ .x = run.rect.x, .y = strike_y },
            .{ .x = run.rect.x + run.rect.width, .y = strike_y },
            1.0,
            run.style.color,
        );
    }

    // Underline (for links)
    if (run.style.underline) {
        const underline_y = draw_y + run.rect.height - 2;
        rl.drawLineEx(
            .{ .x = run.rect.x, .y = underline_y },
            .{ .x = run.rect.x + run.rect.width, .y = underline_y },
            1.0,
            run.style.color,
        );
    }
}
