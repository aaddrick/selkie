const std = @import("std");
const Allocator = std.mem.Allocator;
const PieModel = @import("../models/pie_model.zig").PieModel;
const PieSlice = @import("../models/pie_model.zig").PieSlice;
const utils = @import("../parse_utils.zig");

pub fn parse(allocator: Allocator, source: []const u8) !PieModel {
    var model = PieModel.init(allocator);
    errdefer model.deinit();

    var lines = try utils.splitLines(allocator, source);
    defer lines.deinit();

    var past_header = false;
    for (lines.items) |raw_line| {
        const line = utils.strip(raw_line);

        if (line.len == 0 or utils.isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "pie") or std.mem.startsWith(u8, line, "pie ")) {
                past_header = true;
                if (std.mem.indexOf(u8, line, "showData") != null) {
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

        if (std.mem.startsWith(u8, line, "title ")) {
            model.title = utils.stripQuotes(utils.strip(line["title ".len..]));
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
    const close_quote = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse return null;
    const label = line[1..close_quote];

    // Find colon after the quote
    const after_quote = line[close_quote + 1 ..];
    const colon_pos = std.mem.indexOfScalar(u8, after_quote, ':') orelse return null;
    const value_str = utils.strip(after_quote[colon_pos + 1 ..]);

    const value = std.fmt.parseFloat(f64, value_str) catch return null;

    return .{
        .label = label,
        .value = value,
    };
}
