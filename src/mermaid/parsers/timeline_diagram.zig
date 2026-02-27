const std = @import("std");
const Allocator = std.mem.Allocator;
const pu = @import("../parse_utils.zig");
const tm = @import("../models/timeline_model.zig");
const TimelineModel = tm.TimelineModel;
const TimelineSection = tm.TimelineSection;
const TimelinePeriod = tm.TimelinePeriod;
const TimelineEvent = tm.TimelineEvent;

pub fn parse(allocator: Allocator, source: []const u8) !TimelineModel {
    var model = TimelineModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    var past_header = false;

    for (lines.items) |raw_line| {
        const line = pu.strip(raw_line);
        if (line.len == 0 or pu.isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "timeline") or pu.startsWith(line, "timeline ")) {
                past_header = true;
                continue;
            }
            past_header = true;
            continue;
        }

        // title
        if (pu.startsWith(line, "title ")) {
            model.title = pu.strip(line["title ".len..]);
            continue;
        }

        // section
        if (pu.startsWith(line, "section ")) {
            var section = TimelineSection.init(allocator);
            section.name = pu.strip(line["section ".len..]);
            try model.sections.append(section);
            continue;
        }

        // Period entry: "period : event1 : event2"
        // Or just "period" with events on following indented lines
        // Check for colon-separated format
        if (pu.indexOfChar(line, ':')) |_| {
            // Split by ':'
            var parts = std.ArrayList([]const u8).init(allocator);
            defer parts.deinit();

            var seg_start: usize = 0;
            for (line, 0..) |ch, i| {
                if (ch == ':') {
                    try parts.append(line[seg_start..i]);
                    seg_start = i + 1;
                }
            }
            try parts.append(line[seg_start..]);

            if (parts.items.len >= 1) {
                var period = TimelinePeriod.init(allocator);
                period.label = pu.strip(parts.items[0]);

                // Events are the remaining parts
                for (parts.items[1..]) |part| {
                    const event_text = pu.strip(part);
                    if (event_text.len > 0) {
                        try period.events.append(.{ .text = event_text });
                    }
                }

                // Ensure a section exists
                if (model.sections.items.len == 0) {
                    var section = TimelineSection.init(allocator);
                    section.name = "";
                    try model.sections.append(section);
                }

                try model.sections.items[model.sections.items.len - 1].periods.append(period);
            }
        } else {
            // Line without colon — treat as a period with no events
            var period = TimelinePeriod.init(allocator);
            period.label = line;

            if (model.sections.items.len == 0) {
                var section = TimelineSection.init(allocator);
                section.name = "";
                try model.sections.append(section);
            }

            try model.sections.items[model.sections.items.len - 1].periods.append(period);
        }
    }

    return model;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "timeline parse sections and periods" {
    const allocator = testing.allocator;
    const source =
        \\timeline
        \\    title History
        \\    section Ancient
        \\    Rome : Founded : Expanded
        \\    section Modern
        \\    Internet : Created
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqualStrings("History", model.title);
    try testing.expectEqual(@as(usize, 2), model.sections.items.len);
    try testing.expectEqualStrings("Ancient", model.sections.items[0].name);
    try testing.expectEqual(@as(usize, 1), model.sections.items[0].periods.items.len);
    try testing.expectEqualStrings("Rome", model.sections.items[0].periods.items[0].label);
    try testing.expectEqual(@as(usize, 2), model.sections.items[0].periods.items[0].events.items.len);
}

test "timeline parse period without events" {
    const allocator = testing.allocator;
    const source =
        \\timeline
        \\    JustAPeriod
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.sections.items.len);
    try testing.expectEqual(@as(usize, 1), model.sections.items[0].periods.items.len);
    try testing.expectEqualStrings("JustAPeriod", model.sections.items[0].periods.items[0].label);
    try testing.expectEqual(@as(usize, 0), model.sections.items[0].periods.items[0].events.items.len);
}

test "timeline parse empty input" {
    const allocator = testing.allocator;
    var model = try parse(allocator, "");
    defer model.deinit();
    try testing.expectEqual(@as(usize, 0), model.sections.items.len);
}

test "timeline parse creates default section" {
    const allocator = testing.allocator;
    const source =
        \\timeline
        \\    Period1 : Event1
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.sections.items.len);
    try testing.expectEqualStrings("", model.sections.items[0].name);
}
