const rl = @import("raylib");

/// Truncate text to fit within max_width pixels, appending "..." if needed.
/// Returns a null-terminated slice from the provided buffer.
pub fn truncateText(text: []const u8, max_width: f32, font: rl.Font, font_size: f32, spacing: f32, buf: *[256:0]u8) [:0]const u8 {
    if (text.len == 0) {
        buf[0] = 0;
        return buf[0..0 :0];
    }

    const full_len = @min(text.len, 255);
    @memcpy(buf[0..full_len], text[0..full_len]);
    buf[full_len] = 0;
    const full_z: [:0]const u8 = buf[0..full_len :0];

    const full_w = rl.measureTextEx(font, full_z, font_size, spacing).x;
    if (full_w <= max_width) return full_z;

    const ellipsis = "...";
    var end: usize = @min(full_len, 252);
    while (end > 0) {
        @memcpy(buf[0..end], text[0..end]);
        @memcpy(buf[end .. end + 3], ellipsis);
        buf[end + 3] = 0;
        const trunc_z: [:0]const u8 = buf[0 .. end + 3 :0];
        const w = rl.measureTextEx(font, trunc_z, font_size, spacing).x;
        if (w <= max_width) return trunc_z;
        end -= 1;
    }

    @memcpy(buf[0..3], ellipsis);
    buf[3] = 0;
    return buf[0..3 :0];
}

// NOTE: Full truncation behavior requires raylib font measurement (rl.measureTextEx)
// and cannot be unit tested without a window. Only the empty-string path is pure logic.

const testing = @import("std").testing;

test "truncateText returns empty null-terminated string for empty input" {
    var buf: [256:0]u8 = undefined;
    const result = truncateText("", 100, undefined, 16, 1.6, &buf);
    try testing.expectEqual(@as(usize, 0), result.len);
    try testing.expectEqual(@as(u8, 0), buf[0]);
}
