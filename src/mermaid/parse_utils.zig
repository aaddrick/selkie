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

/// Null-terminate a string slice into a stack buffer for raylib.
/// Returns the sentinel-terminated slice, truncated if necessary.
pub fn nullTerminate(text: []const u8, buf: []u8) [:0]const u8 {
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    return buf[0..len :0];
}
