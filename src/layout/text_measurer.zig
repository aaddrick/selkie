const rl = @import("raylib");
const std = @import("std");

pub const Fonts = struct {
    body: rl.Font,
    bold: rl.Font,
    italic: rl.Font,
    bold_italic: rl.Font,
    mono: rl.Font,

    pub fn selectFont(self: Fonts, style: struct { bold: bool = false, italic: bool = false, is_code: bool = false }) rl.Font {
        if (style.is_code) return self.mono;
        if (style.bold and style.italic) return self.bold_italic;
        if (style.bold) return self.bold;
        if (style.italic) return self.italic;
        return self.body;
    }

    /// Measure text that is guaranteed to be null-terminated ([:0]const u8).
    pub fn measureZ(self: Fonts, text: [:0]const u8, font_size: f32, is_bold: bool, is_italic: bool, is_code: bool) rl.Vector2 {
        const font = self.selectFont(.{ .bold = is_bold, .italic = is_italic, .is_code = is_code });
        const spacing = font_size / 10.0;
        return rl.measureTextEx(font, text, font_size, spacing);
    }

    /// Measure a slice by using a stack buffer for null termination.
    pub fn measure(self: Fonts, text: []const u8, font_size: f32, is_bold: bool, is_italic: bool, is_code: bool) rl.Vector2 {
        if (text.len == 0) return .{ .x = 0, .y = font_size };
        // Check if the byte after the slice is already 0 (common for cmark strings)
        const maybe_sentinel: [*]const u8 = text.ptr;
        if (maybe_sentinel[text.len] == 0) {
            const z: [:0]const u8 = text.ptr[0..text.len :0];
            return self.measureZ(z, font_size, is_bold, is_italic, is_code);
        }
        // Fallback: use a stack buffer
        var buf: [1024]u8 = undefined;
        const len = @min(text.len, buf.len - 1);
        @memcpy(buf[0..len], text[0..len]);
        buf[len] = 0;
        const z: [:0]const u8 = buf[0..len :0];
        return self.measureZ(z, font_size, is_bold, is_italic, is_code);
    }
};
