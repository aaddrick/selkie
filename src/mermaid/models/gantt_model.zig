const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

pub const TaskTag = enum {
    done,
    active,
    crit,
    milestone,
};

pub const GanttTask = struct {
    id: []const u8,
    name: []const u8,
    tags: std.ArrayList(TaskTag),
    start_day: i32 = 0, // days since epoch (relative)
    end_day: i32 = 0,
    section_idx: usize = 0,
    // Layout fields
    bar_x: f32 = 0,
    bar_y: f32 = 0,
    bar_width: f32 = 0,
    bar_height: f32 = 0,

    pub fn hasTag(self: *const GanttTask, tag: TaskTag) bool {
        for (self.tags.items) |t| {
            if (t == tag) return true;
        }
        return false;
    }

    pub fn deinit(self: *GanttTask) void {
        self.tags.deinit();
    }
};

pub const GanttSection = struct {
    name: []const u8,
    task_indices: std.ArrayList(usize), // indices into GanttModel.tasks

    pub fn deinit(self: *GanttSection) void {
        self.task_indices.deinit();
    }
};

pub const SimpleDate = struct {
    year: i32,
    month: u8, // 1-12
    day: u8, // 1-31

    /// Convert to a day number for linear mapping.
    pub fn toDayNumber(self: SimpleDate) i32 {
        // Simple approximation: year*365 + month*30 + day
        return self.year * 365 + @as(i32, self.month) * 30 + @as(i32, self.day);
    }

    pub fn fromDayNumber(dn: i32) SimpleDate {
        var remaining = dn;
        const year = @divTrunc(remaining, 365);
        remaining -= year * 365;
        const raw_month = @divTrunc(remaining, 30);
        remaining -= raw_month * 30;
        const month = std.math.clamp(raw_month, 1, 12);
        const day = std.math.clamp(remaining, 1, 31);
        return .{
            .year = year,
            .month = @intCast(month),
            .day = @intCast(day),
        };
    }

    pub fn format(self: SimpleDate, buf: []u8) []const u8 {
        const result = std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{
            self.year,
            self.month,
            self.day,
        }) catch return "";
        return result;
    }
};

pub fn parseDate(s: []const u8) ?SimpleDate {
    // Parse YYYY-MM-DD
    if (s.len < 10) return null;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return .{ .year = year, .month = month, .day = day };
}

pub fn parseDuration(s: []const u8) ?i32 {
    if (s.len < 2) return null;
    const last = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = std.fmt.parseInt(i32, num_str, 10) catch return null;
    if (last == 'd') return num;
    if (last == 'w') return num * 7;
    return null;
}

pub const GanttModel = struct {
    title: []const u8 = "",
    date_format: []const u8 = "YYYY-MM-DD",
    sections: std.ArrayList(GanttSection),
    tasks: std.ArrayList(GanttTask),
    excludes_weekends: bool = false,
    today_marker: bool = true,
    min_day: i32 = std.math.maxInt(i32),
    max_day: i32 = std.math.minInt(i32),
    // Layout fields
    time_axis_y: f32 = 0,
    chart_x: f32 = 0,
    chart_width: f32 = 0,
    section_label_width: f32 = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) GanttModel {
        return .{
            .sections = std.ArrayList(GanttSection).init(allocator),
            .tasks = std.ArrayList(GanttTask).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GanttModel) void {
        for (self.tasks.items) |*t| {
            t.deinit();
        }
        self.tasks.deinit();
        for (self.sections.items) |*s| {
            s.deinit();
        }
        self.sections.deinit();
    }

    /// Compute the min/max day range across all tasks.
    pub fn computeDateRange(self: *GanttModel) void {
        if (self.tasks.items.len == 0) {
            self.min_day = 0;
            self.max_day = 1;
            return;
        }
        for (self.tasks.items) |task| {
            self.min_day = @min(self.min_day, task.start_day);
            self.max_day = @max(self.max_day, task.end_day);
        }
        // Ensure at least 1 day range
        if (self.max_day <= self.min_day) {
            self.max_day = self.min_day + 1;
        }
    }

    /// Find task index by id.
    pub fn findTaskById(self: *const GanttModel, id: []const u8) ?usize {
        for (self.tasks.items, 0..) |task, i| {
            if (std.mem.eql(u8, task.id, id)) return i;
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "SimpleDate.toDayNumber and fromDayNumber roundtrip" {
    const date = SimpleDate{ .year = 2024, .month = 6, .day = 15 };
    const dn = date.toDayNumber();
    const restored = SimpleDate.fromDayNumber(dn);
    try testing.expectEqual(date.year, restored.year);
    try testing.expectEqual(date.month, restored.month);
    try testing.expectEqual(date.day, restored.day);
}

test "SimpleDate.toDayNumber ordering" {
    const d1 = SimpleDate{ .year = 2024, .month = 1, .day = 1 };
    const d2 = SimpleDate{ .year = 2024, .month = 6, .day = 15 };
    try testing.expect(d1.toDayNumber() < d2.toDayNumber());
}

test "SimpleDate.format produces YYYY-MM-DD" {
    const date = SimpleDate{ .year = 2024, .month = 3, .day = 7 };
    var buf: [32]u8 = undefined;
    const result = date.format(&buf);
    try testing.expectEqualStrings("2024-03-07", result);
}

test "parseDate valid date" {
    const date = parseDate("2024-06-15") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 2024), date.year);
    try testing.expectEqual(@as(u8, 6), date.month);
    try testing.expectEqual(@as(u8, 15), date.day);
}

test "parseDate invalid formats" {
    try testing.expect(parseDate("not-a-date") == null);
    try testing.expect(parseDate("2024/06/15") == null);
    try testing.expect(parseDate("short") == null);
    try testing.expect(parseDate("2024-13-01") == null); // invalid month
    try testing.expect(parseDate("2024-00-01") == null); // zero month
}

test "parseDuration days and weeks" {
    try testing.expectEqual(@as(?i32, 5), parseDuration("5d"));
    try testing.expectEqual(@as(?i32, 14), parseDuration("2w"));
    try testing.expect(parseDuration("abc") == null);
    try testing.expect(parseDuration("5") == null);
    try testing.expect(parseDuration("") == null);
}

test "GanttModel computeDateRange" {
    const allocator = testing.allocator;
    var model = GanttModel.init(allocator);
    defer model.deinit();

    try model.tasks.append(.{
        .id = "t1",
        .name = "Task 1",
        .tags = std.ArrayList(TaskTag).init(allocator),
        .start_day = 10,
        .end_day = 20,
    });

    model.computeDateRange();
    try testing.expectEqual(@as(i32, 10), model.min_day);
    try testing.expectEqual(@as(i32, 20), model.max_day);
}

test "GanttModel findTaskById returns matching index" {
    const allocator = testing.allocator;
    var model = GanttModel.init(allocator);
    defer model.deinit();

    try model.tasks.append(.{
        .id = "task_a",
        .name = "Task A",
        .tags = std.ArrayList(TaskTag).init(allocator),
        .start_day = 0,
        .end_day = 5,
    });
    try model.tasks.append(.{
        .id = "task_b",
        .name = "Task B",
        .tags = std.ArrayList(TaskTag).init(allocator),
        .start_day = 5,
        .end_day = 10,
    });

    const idx = model.findTaskById("task_b") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expectEqualStrings("Task B", model.tasks.items[idx].name);
}

test "GanttModel findTaskById returns null for missing id" {
    const allocator = testing.allocator;
    var model = GanttModel.init(allocator);
    defer model.deinit();

    try model.tasks.append(.{
        .id = "task_a",
        .name = "Task A",
        .tags = std.ArrayList(TaskTag).init(allocator),
    });

    try testing.expect(model.findTaskById("nonexistent") == null);
}
