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
