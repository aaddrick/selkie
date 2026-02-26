const rl = @import("raylib");
const Fonts = @import("../layout/text_measurer.zig").Fonts;

/// Draw a dashed line between two points.
pub fn drawDashedLine(x1: f32, y1: f32, x2: f32, y2: f32, width: f32, color: rl.Color) void {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const total_len = @sqrt(dx * dx + dy * dy);
    if (total_len == 0) return;

    const dash_len: f32 = 6;
    const gap_len: f32 = 4;
    const segment = dash_len + gap_len;
    const nx = dx / total_len;
    const ny = dy / total_len;

    var pos: f32 = 0;
    while (pos < total_len) {
        const end = @min(pos + dash_len, total_len);
        rl.drawLineEx(
            .{ .x = x1 + nx * pos, .y = y1 + ny * pos },
            .{ .x = x1 + nx * end, .y = y1 + ny * end },
            width,
            color,
        );
        pos += segment;
    }
}

/// Draw text at a position, optionally centered horizontally.
/// The y coordinate is vertically centered around the text's midpoint.
pub fn drawText(
    text: []const u8,
    x: f32,
    y: f32,
    fonts: *const Fonts,
    font_size: f32,
    color: rl.Color,
    scroll_y: f32,
    center: bool,
) void {
    if (text.len == 0) return;

    var buf: [256]u8 = undefined;
    const z = nullTerminate(text, &buf);

    const font = fonts.selectFont(.{});
    const spacing = font_size / 10.0;
    const measured = rl.measureTextEx(font, z, font_size, spacing);

    const tx = if (center) x - measured.x / 2 else x;
    const ty = y - scroll_y - measured.y / 2;

    rl.drawTextEx(font, z, .{ .x = tx, .y = ty }, font_size, spacing, color);
}

/// Draw text at an exact position (no centering, no scroll adjustment).
pub fn drawTextAt(text: []const u8, x: f32, y: f32, fonts: *const Fonts, font_size: f32, color: rl.Color) void {
    if (text.len == 0) return;
    const font = fonts.selectFont(.{});
    const spacing = font_size / 10.0;
    var buf: [512]u8 = undefined;
    const z = nullTerminate(text, &buf);
    rl.drawTextEx(font, z, .{ .x = x, .y = y }, font_size, spacing, color);
}

/// Draw text centered horizontally within a width, at an exact y (no scroll adjustment).
pub fn drawTextCenteredDirect(text: []const u8, x: f32, y: f32, w: f32, fonts: *const Fonts, font_size: f32, color: rl.Color) void {
    if (text.len == 0) return;
    const measured = fonts.measure(text, font_size, false, false, false);
    const tx = x + (w - measured.x) / 2;
    drawTextAt(text, tx, y, fonts, font_size, color);
}

/// Darken a color by multiplying RGB channels by 0.7.
pub fn darken(c: rl.Color) rl.Color {
    return .{
        .r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(c.r)) * 0.7)),
        .g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(c.g)) * 0.7)),
        .b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(c.b)) * 0.7)),
        .a = c.a,
    };
}

/// Return a copy of a color with a different alpha value.
pub fn withAlpha(c: rl.Color, a: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

/// Null-terminate a string slice into a stack buffer for raylib.
pub fn nullTerminate(text: []const u8, buf: []u8) [:0]const u8 {
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    return buf[0..len :0];
}
