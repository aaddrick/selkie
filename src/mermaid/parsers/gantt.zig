const std = @import("std");
const Allocator = std.mem.Allocator;
const pu = @import("../parse_utils.zig");
const gm = @import("../models/gantt_model.zig");
const GanttModel = gm.GanttModel;
const GanttTask = gm.GanttTask;
const GanttSection = gm.GanttSection;
const TaskTag = gm.TaskTag;

pub fn parse(allocator: Allocator, source: []const u8) !GanttModel {
    var model = GanttModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    var past_header = false;
    var current_section_idx: ?usize = null;

    // First pass to handle "after" references, we'll need task end days
    // So we do resolution after parsing all tasks

    for (lines.items) |raw_line| {
        const line = pu.strip(raw_line);

        if (line.len == 0 or pu.isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "gantt")) {
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

        // dateFormat
        if (pu.startsWith(line, "dateFormat ")) {
            model.date_format = pu.strip(line["dateFormat ".len..]);
            continue;
        }

        // excludes
        if (pu.startsWith(line, "excludes ")) {
            const exc = pu.strip(line["excludes ".len..]);
            if (std.mem.eql(u8, exc, "weekends")) {
                model.excludes_weekends = true;
            }
            continue;
        }

        // todayMarker
        if (pu.startsWith(line, "todayMarker ")) {
            const val = pu.strip(line["todayMarker ".len..]);
            if (std.mem.eql(u8, val, "off")) {
                model.today_marker = false;
            }
            continue;
        }

        // section
        if (pu.startsWith(line, "section ")) {
            const section_name = pu.strip(line["section ".len..]);
            try model.sections.append(.{
                .name = section_name,
                .task_indices = std.ArrayList(usize).init(allocator),
            });
            current_section_idx = model.sections.items.len - 1;
            continue;
        }

        // Task line: "Task Name :tag1, tag2, id, start, duration"
        if (pu.indexOfChar(line, ':')) |colon_pos| {
            try parseTaskLine(allocator, &model, line, colon_pos, current_section_idx);
            continue;
        }
    }

    // Resolve "after" references and compute date range
    resolveAfterReferences(&model);
    model.computeDateRange();

    return model;
}

fn parseTaskLine(allocator: Allocator, model: *GanttModel, line: []const u8, colon_pos: usize, section_idx: ?usize) !void {
    const name = pu.strip(line[0..colon_pos]);
    const spec = pu.strip(line[colon_pos + 1 ..]);

    // Parse comma-separated fields
    var fields = std.ArrayList([]const u8).init(allocator);
    defer fields.deinit();

    var fstart: usize = 0;
    for (spec, 0..) |ch, i| {
        if (ch == ',') {
            const field = pu.strip(spec[fstart..i]);
            if (field.len > 0) try fields.append(field);
            fstart = i + 1;
        }
    }
    const last_field = pu.strip(spec[fstart..]);
    if (last_field.len > 0) try fields.append(last_field);

    var task = GanttTask{
        .id = "",
        .name = name,
        .tags = std.ArrayList(TaskTag).init(allocator),
        .section_idx = section_idx orelse 0,
    };

    // Parse fields: tags first, then id, then start, then duration/end
    var field_idx: usize = 0;

    // Consume tags
    while (field_idx < fields.items.len) {
        const f = fields.items[field_idx];
        if (std.mem.eql(u8, f, "done")) {
            try task.tags.append(.done);
            field_idx += 1;
        } else if (std.mem.eql(u8, f, "active")) {
            try task.tags.append(.active);
            field_idx += 1;
        } else if (std.mem.eql(u8, f, "crit")) {
            try task.tags.append(.crit);
            field_idx += 1;
        } else if (std.mem.eql(u8, f, "milestone")) {
            try task.tags.append(.milestone);
            field_idx += 1;
        } else {
            break;
        }
    }

    // Next field might be id (not a date, not "after", not a duration)
    if (field_idx < fields.items.len) {
        const f = fields.items[field_idx];
        if (!isDateLike(f) and !pu.startsWith(f, "after ") and gm.parseDuration(f) == null) {
            task.id = f;
            field_idx += 1;
        }
    }

    // If no explicit id, generate one from name
    if (task.id.len == 0) {
        task.id = name;
    }

    // Start: date literal or "after ref_id"
    if (field_idx < fields.items.len) {
        const f = fields.items[field_idx];
        if (pu.startsWith(f, "after ")) {
            // Mark as needing resolution in resolveAfterReferences.
            // The current resolver uses sequential placement (previous task's end_day).
            task.start_day = AFTER_SENTINEL;
        } else if (gm.parseDate(f)) |date| {
            task.start_day = date.toDayNumber();
        }
        field_idx += 1;
    }

    // Duration or end date
    if (field_idx < fields.items.len) {
        const f = fields.items[field_idx];
        if (gm.parseDuration(f)) |days| {
            task.end_day = task.start_day + days;
        } else if (gm.parseDate(f)) |date| {
            task.end_day = date.toDayNumber();
        }
    } else {
        // Default duration: 5 days
        task.end_day = task.start_day + 5;
    }

    // For milestone, end_day = start_day
    if (task.hasTag(.milestone)) {
        task.end_day = task.start_day;
    }

    const task_idx = model.tasks.items.len;
    try model.tasks.append(task);

    if (section_idx) |si| {
        if (si < model.sections.items.len) {
            try model.sections.items[si].task_indices.append(task_idx);
        }
    }
}

// Store after-reference info in a separate pass
// For now, use a simple approach: tasks with start_day == AFTER_SENTINEL
// get their start_day from the previous task's end_day
const AFTER_SENTINEL: i32 = std.math.minInt(i32);

fn resolveAfterReferences(model: *GanttModel) void {
    for (model.tasks.items, 0..) |*task, i| {
        if (task.start_day == AFTER_SENTINEL) {
            // Default: start after the previous task
            if (i > 0) {
                const prev = model.tasks.items[i - 1];
                task.start_day = prev.end_day;
                // Recompute end_day preserving duration
                const duration: i32 = 5; // default
                task.end_day = task.start_day + duration;
            } else {
                task.start_day = 0;
                task.end_day = 5;
            }
        }

        // Ensure tasks without explicit start use sequential placement
        if (task.start_day == 0 and task.end_day == 0 and i > 0) {
            const prev = model.tasks.items[i - 1];
            task.start_day = prev.end_day;
            task.end_day = task.start_day + 5;
        }
    }
}

fn isDateLike(s: []const u8) bool {
    // Check if it looks like YYYY-MM-DD
    if (s.len >= 10 and s[4] == '-' and s[7] == '-') {
        return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "gantt parse basic tasks" {
    const allocator = testing.allocator;
    const source =
        \\gantt
        \\    title Project
        \\    dateFormat YYYY-MM-DD
        \\    section Phase 1
        \\    Task A :2024-01-01, 10d
        \\    Task B :2024-01-11, 5d
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqualStrings("Project", model.title);
    try testing.expectEqual(@as(usize, 1), model.sections.items.len);
    try testing.expectEqual(@as(usize, 2), model.tasks.items.len);
    try testing.expectEqualStrings("Task A", model.tasks.items[0].name);
    try testing.expectEqualStrings("Task B", model.tasks.items[1].name);
}

test "gantt parse task tags" {
    const allocator = testing.allocator;
    const source =
        \\gantt
        \\    Task :done, crit, 2024-01-01, 5d
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.tasks.items.len);
    try testing.expect(model.tasks.items[0].hasTag(.done));
    try testing.expect(model.tasks.items[0].hasTag(.crit));
}

test "gantt parse empty input" {
    const allocator = testing.allocator;
    var model = try parse(allocator, "");
    defer model.deinit();
    try testing.expectEqual(@as(usize, 0), model.tasks.items.len);
}

test "gantt parse date handling" {
    const allocator = testing.allocator;
    const source =
        \\gantt
        \\    Task :2024-06-15, 2024-06-25
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.tasks.items.len);
    // Verify start_day corresponds to 2024-06-15
    const expected_start = gm.SimpleDate{ .year = 2024, .month = 6, .day = 15 };
    try testing.expectEqual(expected_start.toDayNumber(), model.tasks.items[0].start_day);
}

test "gantt parse excludes weekends" {
    const allocator = testing.allocator;
    const source =
        \\gantt
        \\    excludes weekends
        \\    Task :2024-01-01, 5d
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expect(model.excludes_weekends);
}
