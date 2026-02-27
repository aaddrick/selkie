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

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "pie parse basic slices" {
    const allocator = testing.allocator;
    const source =
        \\pie
        \\    "Dogs" : 30
        \\    "Cats" : 70
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 2), model.slices.items.len);
    try testing.expectEqualStrings("Dogs", model.slices.items[0].label);
    try testing.expectApproxEqAbs(@as(f64, 30.0), model.slices.items[0].value, 0.01);
    try testing.expectEqualStrings("Cats", model.slices.items[1].label);
    try testing.expectApproxEqAbs(@as(f64, 70.0), model.slices.items[1].value, 0.01);
}

test "pie parse computes percentages" {
    const allocator = testing.allocator;
    const source =
        \\pie
        \\    "A" : 25
        \\    "B" : 75
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectApproxEqAbs(@as(f64, 25.0), model.slices.items[0].percentage, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 75.0), model.slices.items[1].percentage, 0.01);
}

test "pie parse with title and showData" {
    const allocator = testing.allocator;
    const source =
        \\pie showData
        \\    title My Pie
        \\    "A" : 50
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expect(model.show_data);
    try testing.expectEqualStrings("My Pie", model.title);
}

test "pie parse empty input" {
    const allocator = testing.allocator;
    var model = try parse(allocator, "");
    defer model.deinit();
    try testing.expectEqual(@as(usize, 0), model.slices.items.len);
}

test "pie parse malformed slices are skipped" {
    const allocator = testing.allocator;
    const source =
        \\pie
        \\    "Valid" : 42
        \\    not a slice
        \\    "Also valid" : 8
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 2), model.slices.items.len);
}
