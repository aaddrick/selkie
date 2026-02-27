const std = @import("std");
const Allocator = std.mem.Allocator;

/// Trim leading and trailing whitespace (spaces, tabs, carriage returns).
pub fn strip(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Strip surrounding double quotes if present.
pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Check if a line is a Mermaid comment (%%).
pub fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "%%");
}

/// Split source into lines by newline characters.
/// Caller owns the returned ArrayList and must call deinit().
pub fn splitLines(allocator: Allocator, source: []const u8) !std.ArrayList([]const u8) {
    var lines = std.ArrayList([]const u8).init(allocator);
    errdefer lines.deinit();
    var start: usize = 0;
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
            try lines.append(source[start..i]);
            start = i + 1;
        }
    }
    if (start < source.len) {
        try lines.append(source[start..]);
    }
    return lines;
}

/// Check if a string starts with a prefix.
pub fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

/// Check if a string ends with a suffix.
pub fn endsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

/// Find the first occurrence of a scalar value in a slice.
pub fn indexOfChar(haystack: []const u8, needle: u8) ?usize {
    return std.mem.indexOfScalar(u8, haystack, needle);
}

/// Find the first occurrence of a scalar value starting from an offset.
pub fn indexOfCharFrom(haystack: []const u8, needle: u8, from: usize) ?usize {
    if (from >= haystack.len) return null;
    const result = std.mem.indexOfScalar(u8, haystack[from..], needle);
    if (result) |r| return r + from;
    return null;
}

/// Find the first occurrence of a substring in a string.
pub fn indexOfStr(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

/// Check if a string contains a substring.
pub fn containsStr(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Null-terminate a string slice into a stack buffer for raylib.
/// Returns the sentinel-terminated slice, truncated if necessary.
pub fn nullTerminate(text: []const u8, buf: []u8) [:0]const u8 {
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    return buf[0..len :0];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "strip removes leading and trailing whitespace" {
    try testing.expectEqualStrings("hello", strip("  hello  "));
    try testing.expectEqualStrings("hello", strip("\thello\t"));
    try testing.expectEqualStrings("", strip("   "));
    try testing.expectEqualStrings("hello world", strip("  hello world  "));
}

test "strip preserves strings without whitespace" {
    try testing.expectEqualStrings("hello", strip("hello"));
    try testing.expectEqualStrings("", strip(""));
}

test "stripQuotes removes surrounding double quotes" {
    try testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
    try testing.expectEqualStrings("hello", stripQuotes("hello"));
    try testing.expectEqualStrings("\"", stripQuotes("\""));
    try testing.expectEqualStrings("", stripQuotes("\"\""));
    try testing.expectEqualStrings("", stripQuotes(""));
}

test "isComment detects mermaid comments" {
    try testing.expect(isComment("%% this is a comment"));
    try testing.expect(isComment("%%"));
    try testing.expect(!isComment("% not a comment"));
    try testing.expect(!isComment("hello"));
    try testing.expect(!isComment(""));
}

test "splitLines splits on newlines" {
    const allocator = testing.allocator;
    var lines = try splitLines(allocator, "line1\nline2\nline3");
    defer lines.deinit();
    try testing.expectEqual(@as(usize, 3), lines.items.len);
    try testing.expectEqualStrings("line1", lines.items[0]);
    try testing.expectEqualStrings("line2", lines.items[1]);
    try testing.expectEqualStrings("line3", lines.items[2]);
}

test "splitLines handles empty input" {
    const allocator = testing.allocator;
    var lines = try splitLines(allocator, "");
    defer lines.deinit();
    try testing.expectEqual(@as(usize, 0), lines.items.len);
}

test "splitLines handles trailing newline" {
    const allocator = testing.allocator;
    var lines = try splitLines(allocator, "a\nb\n");
    defer lines.deinit();
    try testing.expectEqual(@as(usize, 2), lines.items.len);
    try testing.expectEqualStrings("a", lines.items[0]);
    try testing.expectEqualStrings("b", lines.items[1]);
}

test "splitLines single line no newline" {
    const allocator = testing.allocator;
    var lines = try splitLines(allocator, "single");
    defer lines.deinit();
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("single", lines.items[0]);
}

test "startsWith and endsWith" {
    try testing.expect(startsWith("hello world", "hello"));
    try testing.expect(!startsWith("hello world", "world"));
    try testing.expect(endsWith("hello world", "world"));
    try testing.expect(!endsWith("hello world", "hello"));
}

test "indexOfChar and indexOfCharFrom" {
    try testing.expectEqual(@as(?usize, 5), indexOfChar("hello:world", ':'));
    try testing.expectEqual(@as(?usize, null), indexOfChar("hello", ':'));
    try testing.expectEqual(@as(?usize, 5), indexOfCharFrom("a:b:c:d", ':', 4));
    try testing.expectEqual(@as(?usize, null), indexOfCharFrom("abc", ':', 10));
}

test "indexOfStr and containsStr" {
    try testing.expectEqual(@as(?usize, 6), indexOfStr("hello world", "world"));
    try testing.expectEqual(@as(?usize, null), indexOfStr("hello", "world"));
    try testing.expect(containsStr("hello world", "world"));
    try testing.expect(!containsStr("hello", "world"));
}

test "nullTerminate produces valid sentinel-terminated string" {
    var buf: [32]u8 = undefined;
    const result = nullTerminate("hello", &buf);
    try testing.expectEqualStrings("hello", result);
    try testing.expectEqual(@as(u8, 0), buf[5]);
}

test "nullTerminate truncates long input" {
    var buf: [4]u8 = undefined;
    const result = nullTerminate("hello", &buf);
    try testing.expectEqualStrings("hel", result);
    try testing.expectEqual(@as(u8, 0), buf[3]);
}

test "functions handle multi-byte UTF-8 input" {
    const allocator = testing.allocator;

    // strip preserves interior multi-byte characters
    try testing.expectEqualStrings("caf\xc3\xa9", strip("  caf\xc3\xa9  "));

    // splitLines splits correctly around multi-byte characters
    var lines = try splitLines(allocator, "\xc3\xa9\n\xc3\xbc\xc3\x9f");
    defer lines.deinit();
    try testing.expectEqual(@as(usize, 2), lines.items.len);
    try testing.expectEqualStrings("\xc3\xa9", lines.items[0]);
    try testing.expectEqualStrings("\xc3\xbc\xc3\x9f", lines.items[1]);

    // indexOfChar finds ASCII byte within multi-byte surroundings
    try testing.expectEqual(@as(?usize, 5), indexOfChar("caf\xc3\xa9:ok", ':'));

    // containsStr finds ASCII substring in multi-byte context
    try testing.expect(containsStr("hello \xe4\xb8\x96\xe7\x95\x8c world", "world"));

    // startsWith/endsWith work with multi-byte prefixes/suffixes
    try testing.expect(startsWith("\xc3\xa9tape", "\xc3\xa9"));
    try testing.expect(endsWith("caf\xc3\xa9", "\xc3\xa9"));
}
