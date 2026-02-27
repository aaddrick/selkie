const std = @import("std");

const rl = @import("raylib");
const slice_utils = @import("../utils/slice_utils.zig");

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
        var buf: [2048]u8 = undefined;
        const z = slice_utils.sliceToZ(&buf, text);
        return self.measureZ(z, font_size, is_bold, is_italic, is_code);
    }
};
