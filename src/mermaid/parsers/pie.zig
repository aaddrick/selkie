const std = @import("std");
const Allocator = std.mem.Allocator;
const PieModel = @import("../models/pie_model.zig").PieModel;
const PieSlice = @import("../models/pie_model.zig").PieSlice;
const pu = @import("../parse_utils.zig");

pub fn parse(allocator: Allocator, source: []const u8) !PieModel {
    var model = PieModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    var past_header = false;
    for (lines.items) |raw_line| {
        const line = pu.strip(raw_line);

        if (line.len == 0 or pu.isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "pie") or pu.startsWith(line, "pie ")) {
                past_header = true;
                if (pu.containsStr(line, "showData")) {
                    model.show_data = true;
                }
                continue;
            }
            past_header = true;
            continue;
        }

        if (std.mem.eql(u8, line, "showData")) {
            model.show_data = true;
            continue;
        }

        if (pu.startsWith(line, "title ")) {
            model.title = pu.stripQuotes(pu.strip(line["title ".len..]));
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

fn parseSlice(line: []const u8) ?PieSlice {
    // Find closing quote
    const close_quote = pu.indexOfCharFrom(line, '"', 1) orelse return null;
    const label = line[1..close_quote];

    // Find colon after the quote
    const after_quote = line[close_quote + 1 ..];
    const colon_pos = pu.indexOfChar(after_quote, ':') orelse return null;
    const value_str = pu.strip(after_quote[colon_pos + 1 ..]);

    const value = std.fmt.parseFloat(f64, value_str) catch return null;

    return .{
        .label = label,
        .value = value,
    };
}
