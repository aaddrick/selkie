const std = @import("std");
const Allocator = std.mem.Allocator;
const jm = @import("../models/journey_model.zig");
const JourneyModel = jm.JourneyModel;
const JourneySection = jm.JourneySection;
const JourneyTask = jm.JourneyTask;

pub fn parse(allocator: Allocator, source: []const u8) !JourneyModel {
    var model = JourneyModel.init(allocator);
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
            if (std.mem.eql(u8, line, "journey") or startsWith(line, "journey ")) {
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
            var section = JourneySection.init(allocator);
            section.name = strip(line["section ".len..]);
            try model.sections.append(section);
            continue;
        }

        // Task: description: score: actor1, actor2
        if (parseTask(allocator, line)) |task| {
            // Add to current section, or create a default one
            if (model.sections.items.len == 0) {
                var section = JourneySection.init(allocator);
                section.name = "Default";
                try model.sections.append(section);
            }
            try model.sections.items[model.sections.items.len - 1].tasks.append(task);
        }
    }

    return model;
}

fn parseTask(allocator: Allocator, line: []const u8) ?JourneyTask {
    // Format: "Task description: score: actor1, actor2"
    // Find the last colon-separated parts
    // Strategy: split by ':'
    var parts = std.ArrayList([]const u8).init(allocator);
    defer parts.deinit();

    var seg_start: usize = 0;
    for (line, 0..) |ch, i| {
        if (ch == ':') {
            parts.append(line[seg_start..i]) catch return null;
            seg_start = i + 1;
        }
    }
    parts.append(line[seg_start..]) catch return null;

    if (parts.items.len < 2) return null;

    var task = JourneyTask.init(allocator);
    task.description = strip(parts.items[0]);

    // Second part is score
    const score_str = strip(parts.items[1]);
    task.score = @as(u8, @intCast(std.fmt.parseInt(u32, score_str, 10) catch return null));
    if (task.score < 1) task.score = 1;
    if (task.score > 5) task.score = 5;

    // Remaining parts are actors (comma-separated)
    if (parts.items.len >= 3) {
        const actors_str = strip(parts.items[2]);
        // Split by comma
        var actor_start: usize = 0;
        for (actors_str, 0..) |ch, i| {
            if (ch == ',') {
                const actor = strip(actors_str[actor_start..i]);
                if (actor.len > 0) {
                    task.actors.append(actor) catch {};
                }
                actor_start = i + 1;
            }
        }
        const last_actor = strip(actors_str[actor_start..]);
        if (last_actor.len > 0) {
            task.actors.append(last_actor) catch {};
        }
    }

    return task;
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
