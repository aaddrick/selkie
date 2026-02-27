const rl = @import("raylib");
const TextRun = @import("../layout/layout_types.zig").TextRun;
const slice_utils = @import("../utils/slice_utils.zig");
const Fonts = @import("../layout/text_measurer.zig").Fonts;

fn drawTextSlice(font: rl.Font, text: []const u8, pos: rl.Vector2, font_size: f32, spacing: f32, color: rl.Color) void {
    if (text.len == 0) return;
    var buf: [2048]u8 = undefined;
    const z = slice_utils.sliceToZ(&buf, text);
    rl.drawTextEx(font, z, pos, font_size, spacing, color);
}

pub fn drawTextRun(run: *const TextRun, fonts: *const Fonts, scroll_y: f32) void {
    const draw_y = run.rect.y - scroll_y;

    // Skip if off screen
    if (draw_y + run.rect.height < 0) return;
    if (draw_y > @as(f32, @floatFromInt(rl.getScreenHeight()))) return;

    const font = fonts.selectFont(.{
        .bold = run.style.bold,
        .italic = run.style.italic,
        .is_code = run.style.is_code,
    });

    // Draw inline code background
    if (run.style.is_code) {
        if (run.style.code_bg) |bg| {
            const pad: f32 = 2;
            rl.drawRectangleRounded(
                .{
                    .x = run.rect.x - pad,
                    .y = draw_y - pad,
                    .width = run.rect.width + pad * 2,
                    .height = run.rect.height + pad * 2,
                },
                0.2,
                4,
                bg,
            );
        }
    }

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
