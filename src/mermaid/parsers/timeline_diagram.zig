const std = @import("std");
const Allocator = std.mem.Allocator;
const tm = @import("../models/timeline_model.zig");
const TimelineModel = tm.TimelineModel;
const TimelineSection = tm.TimelineSection;
const TimelinePeriod = tm.TimelinePeriod;
const TimelineEvent = tm.TimelineEvent;

pub fn parse(allocator: Allocator, source: []const u8) !TimelineModel {
    var model = TimelineModel.init(allocator);
    errdefer model.deinit();

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

        if (!past_header) {
            if (std.mem.eql(u8, line, "timeline") or startsWith(line, "timeline ")) {
                past_header = true;
                continue;
            }
            past_header = true;
            continue;
        }

        // title
        if (startsWith(line, "title ")) {
            model.title = strip(line["title ".len..]);
            continue;
        }

        // section
        if (startsWith(line, "section ")) {
            var section = TimelineSection.init(allocator);
            section.name = strip(line["section ".len..]);
            try model.sections.append(section);
            continue;
        }

        // Period entry: "period : event1 : event2"
        // Or just "period" with events on following indented lines
        // Check for colon-separated format
        if (std.mem.indexOfScalar(u8, line, ':')) |_| {
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
                period.label = strip(parts.items[0]);

                // Events are the remaining parts
                for (parts.items[1..]) |part| {
                    const event_text = strip(part);
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

fn strip(s: []const u8) []const u8 {
    var st: usize = 0;
    while (st < s.len and (s[st] == ' ' or s[st] == '\t' or s[st] == '\r')) : (st += 1) {}
    var end = s.len;
    while (end > st and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[st..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn isComment(line: []const u8) bool {
    return line.len >= 2 and line[0] == '%' and line[1] == '%';
}
