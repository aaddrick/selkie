const std = @import("std");

/// Unicode codepoint ranges to load for font rendering.
/// Covers common Latin text, punctuation, symbols, and mathematical operators.
const Range = struct { start: i32, end: i32 };

const ranges = [_]Range{
    .{ .start = 0x0020, .end = 0x007E }, // Basic Latin (space through tilde)
    .{ .start = 0x00A0, .end = 0x00FF }, // Latin-1 Supplement (non-breaking space, accented chars, symbols)
    .{ .start = 0x0100, .end = 0x017F }, // Latin Extended-A (Eastern European)
    .{ .start = 0x0180, .end = 0x024F }, // Latin Extended-B
    .{ .start = 0x2000, .end = 0x206F }, // General Punctuation (em dash, curly quotes, ellipsis, etc.)
    .{ .start = 0x2070, .end = 0x209F }, // Superscripts and Subscripts
    .{ .start = 0x20A0, .end = 0x20CF }, // Currency Symbols
    .{ .start = 0x2100, .end = 0x214F }, // Letterlike Symbols
    .{ .start = 0x2190, .end = 0x21FF }, // Arrows
    .{ .start = 0x2200, .end = 0x22FF }, // Mathematical Operators
    .{ .start = 0x2300, .end = 0x23FF }, // Miscellaneous Technical
    .{ .start = 0x25A0, .end = 0x25FF }, // Geometric Shapes
    .{ .start = 0x2600, .end = 0x26FF }, // Miscellaneous Symbols
    .{ .start = 0x2700, .end = 0x27BF }, // Dingbats
    .{ .start = 0xFB00, .end = 0xFB06 }, // Alphabetic Presentation Forms (ligatures: ff, fi, fl, etc.)
    .{ .start = 0xFFFD, .end = 0xFFFD }, // Replacement character
};

const total_count = blk: {
    var count: usize = 0;
    for (ranges) |r| {
        count += @as(usize, @intCast(r.end - r.start + 1));
    }
    break :blk count;
};

/// Flat array of all codepoints to load, built at comptime.
pub const codepoints: [total_count]i32 = blk: {
    @setEvalBranchQuota(10_000);
    var arr: [total_count]i32 = undefined;
    var i: usize = 0;
    for (ranges) |r| {
        var cp = r.start;
        while (cp <= r.end) : (cp += 1) {
            arr[i] = cp;
            i += 1;
        }
    }
    break :blk arr;
};

test "codepoints contains ASCII printable range" {
    for (0x20..0x7F) |cp| {
        try std.testing.expect(contains(@intCast(cp)));
    }
}

test "codepoints contains em dash and curly quotes" {
    try std.testing.expect(contains(0x2014)); // em dash
    try std.testing.expect(contains(0x2013)); // en dash
    try std.testing.expect(contains(0x2018)); // left single quote
    try std.testing.expect(contains(0x2019)); // right single quote
    try std.testing.expect(contains(0x201C)); // left double quote
    try std.testing.expect(contains(0x201D)); // right double quote
    try std.testing.expect(contains(0x2026)); // horizontal ellipsis
}

test "codepoints contains accented Latin characters" {
    try std.testing.expect(contains(0x00E9)); // é
    try std.testing.expect(contains(0x00F1)); // ñ
    try std.testing.expect(contains(0x00FC)); // ü
    try std.testing.expect(contains(0x00C0)); // À
}

test "codepoints contains common symbols" {
    try std.testing.expect(contains(0x00A9)); // copyright ©
    try std.testing.expect(contains(0x00AE)); // registered ®
    try std.testing.expect(contains(0x20AC)); // euro €
    try std.testing.expect(contains(0x2192)); // rightwards arrow →
    try std.testing.expect(contains(0x2713)); // check mark ✓
    try std.testing.expect(contains(0xFFFD)); // replacement character �
}

test "codepoints excludes control characters and gaps" {
    try std.testing.expect(!contains(0x0000)); // null
    try std.testing.expect(!contains(0x0019)); // end of C0 control range
    try std.testing.expect(!contains(0x007F)); // DEL
    try std.testing.expect(!contains(0x0080)); // start of C1 control range
    try std.testing.expect(!contains(0x009F)); // end of C1 control range
    try std.testing.expect(!contains(0x0250)); // just past Latin Extended-B
    try std.testing.expect(!contains(0x1FFF)); // just before General Punctuation
    try std.testing.expect(!contains(0x20D0)); // just past Currency Symbols
    try std.testing.expect(!contains(0x27C0)); // just past Dingbats
    try std.testing.expect(!contains(0xFB07)); // just past ligatures
    try std.testing.expect(!contains(0xFFFE)); // just before replacement character
}

test "total codepoint count matches expected value" {
    // Hardcoded to catch accidental range additions/removals.
    // Update this value when intentionally changing the ranges.
    try std.testing.expectEqual(@as(usize, 1991), codepoints.len);
}

// Test helper — linear scan, not for production use.
fn contains(needle: i32) bool {
    for (codepoints) |cp| {
        if (cp == needle) return true;
    }
    return false;
}
