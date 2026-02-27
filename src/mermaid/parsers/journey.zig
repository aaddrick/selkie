const std = @import("std");
const Allocator = std.mem.Allocator;
const pu = @import("../parse_utils.zig");
const jm = @import("../models/journey_model.zig");
const JourneyModel = jm.JourneyModel;
const JourneySection = jm.JourneySection;
const JourneyTask = jm.JourneyTask;

pub fn parse(allocator: Allocator, source: []const u8) !JourneyModel {
    var model = JourneyModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    var past_header = false;

    for (lines.items) |raw_line| {
        const line = pu.strip(raw_line);
        if (line.len == 0 or pu.isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "journey") or pu.startsWith(line, "journey ")) {
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
            var section = JourneySection.init(allocator);
            section.name = pu.strip(line["section ".len..]);
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
    task.description = pu.strip(parts.items[0]);

    // Second part is score
    const score_str = pu.strip(parts.items[1]);
    task.score = std.fmt.parseInt(u8, score_str, 10) catch return null;
    if (task.score < 1) task.score = 1;
    if (task.score > 5) task.score = 5;

    // Remaining parts are actors (comma-separated)
    if (parts.items.len >= 3) {
        const actors_str = pu.strip(parts.items[2]);
        var actor_start: usize = 0;
        for (actors_str, 0..) |ch, i| {
            if (ch == ',') {
                const actor = pu.strip(actors_str[actor_start..i]);
                if (actor.len > 0) {
                    task.actors.append(actor) catch return null;
                }
                actor_start = i + 1;
            }
        }
        const last_actor = pu.strip(actors_str[actor_start..]);
        if (last_actor.len > 0) {
            task.actors.append(last_actor) catch return null;
        }
    }

    return task;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "journey parse tasks and scores" {
    const allocator = testing.allocator;
    const source =
        \\journey
        \\    title My Journey
        \\    section Getting Started
        \\    Sign up: 5: Me
        \\    Log in: 3: Me
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqualStrings("My Journey", model.title);
    try testing.expectEqual(@as(usize, 1), model.sections.items.len);
    try testing.expectEqualStrings("Getting Started", model.sections.items[0].name);
    try testing.expectEqual(@as(usize, 2), model.sections.items[0].tasks.items.len);

    const task1 = model.sections.items[0].tasks.items[0];
    try testing.expectEqualStrings("Sign up", task1.description);
    try testing.expectEqual(@as(u8, 5), task1.score);
    try testing.expectEqual(@as(usize, 1), task1.actors.items.len);
    try testing.expectEqualStrings("Me", task1.actors.items[0]);
}

test "journey parse score clamping" {
    const allocator = testing.allocator;
    // Score 0 should be clamped up to 1, score 9 should be clamped down to 5
    const source =
        \\journey
        \\    section Test
        \\    Low task: 0: Actor
        \\    High task: 9: Actor
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const tasks = model.sections.items[0].tasks.items;
    try testing.expectEqual(@as(usize, 2), tasks.len);
    try testing.expectEqual(@as(u8, 1), tasks[0].score); // 0 clamped to min 1
    try testing.expectEqual(@as(u8, 5), tasks[1].score); // 9 clamped to max 5
}

test "journey parse empty input" {
    const allocator = testing.allocator;
    var model = try parse(allocator, "");
    defer model.deinit();
    try testing.expectEqual(@as(usize, 0), model.sections.items.len);
}

test "journey parse creates default section for orphan tasks" {
    const allocator = testing.allocator;
    const source =
        \\journey
        \\    Orphan task: 4: Nobody
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.sections.items.len);
    try testing.expectEqualStrings("Default", model.sections.items[0].name);
}

test "journey parse multiple actors" {
    const allocator = testing.allocator;
    const source =
        \\journey
        \\    section S
        \\    Do thing: 3: Alice, Bob, Charlie
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const task = model.sections.items[0].tasks.items[0];
    try testing.expectEqual(@as(usize, 3), task.actors.items.len);
    try testing.expectEqualStrings("Alice", task.actors.items[0]);
    try testing.expectEqualStrings("Bob", task.actors.items[1]);
    try testing.expectEqualStrings("Charlie", task.actors.items[2]);
}
