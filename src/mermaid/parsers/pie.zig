const std = @import("std");
const Allocator = std.mem.Allocator;
const PieModel = @import("../models/pie_model.zig").PieModel;

pub fn parse(allocator: Allocator, source: []const u8) !PieModel {
    var model = PieModel.init(allocator);

    // Split source into lines
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();

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

    var past_header = false;
    for (lines.items) |raw_line| {
        const line = strip(raw_line);

        if (line.len == 0 or isComment(line)) continue;

        // Skip the "pie" header line
        if (!past_header) {
            if (std.mem.eql(u8, line, "pie") or startsWith(line, "pie ")) {
                past_header = true;
                // Check for inline "pie showData"
                if (indexOf(line, "showData")) |_| {
                    model.show_data = true;
                }
                continue;
            }
            // First non-empty line isn't "pie" - skip anyway
            past_header = true;
            continue;
        }

        // showData on its own line
        if (std.mem.eql(u8, line, "showData")) {
            model.show_data = true;
            continue;
        }

        // title "Chart Title"
        if (startsWith(line, "title ")) {
            const title_text = strip(line["title ".len..]);
            model.title = stripQuotes(title_text);
            continue;
        }

        // Slice: "Label" : value
        if (line[0] == '"') {
            if (parseSlice(line)) |slice| {
                try model.slices.append(slice);
            }
            continue;
        }
    }

    model.computePercentages();
    return model;
}

fn parseSlice(line: []const u8) ?@import("../models/pie_model.zig").PieSlice {
    // Find closing quote
    const close_quote = indexOfCharFrom(line, '"', 1) orelse return null;
    const label = line[1..close_quote];

    // Find colon after the quote
    const after_quote = line[close_quote + 1 ..];
    const colon_pos = indexOfChar(after_quote, ':') orelse return null;
    const value_str = strip(after_quote[colon_pos + 1 ..]);

    const value = std.fmt.parseFloat(f64, value_str) catch return null;

    return .{
        .label = label,
        .value = value,
    };
}

fn strip(s: []const u8) []const u8 {
    var st: usize = 0;
    while (st < s.len and (s[st] == ' ' or s[st] == '\t' or s[st] == '\r')) : (st += 1) {}
    var end = s.len;
    while (end > st and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[st..end];
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn isComment(line: []const u8) bool {
    return line.len >= 2 and line[0] == '%' and line[1] == '%';
}

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn indexOfChar(haystack: []const u8, needle: u8) ?usize {
    return std.mem.indexOfScalar(u8, haystack, needle);
}

fn indexOfCharFrom(haystack: []const u8, needle: u8, from: usize) ?usize {
    if (from >= haystack.len) return null;
    const result = std.mem.indexOfScalar(u8, haystack[from..], needle);
    if (result) |r| return r + from;
    return null;
}
