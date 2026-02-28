const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ScrollEntry = struct {
    scroll_y: f32,
    timestamp: i64,
};

/// Persistent store for per-file scroll positions.
/// Owns all key strings in the map.
pub const ScrollPositionStore = struct {
    allocator: Allocator,
    map: std.StringHashMap(ScrollEntry),
    file_path: ?[]const u8,

    const max_entries = 500;

    pub fn init(allocator: Allocator, file_path: ?[]const u8) !ScrollPositionStore {
        const owned_path = if (file_path) |p|
            try allocator.dupe(u8, p)
        else
            null;
        errdefer if (owned_path) |p| allocator.free(p);

        return .{
            .allocator = allocator,
            .map = std.StringHashMap(ScrollEntry).init(allocator),
            .file_path = owned_path,
        };
    }

    pub fn deinit(self: *ScrollPositionStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
        if (self.file_path) |p| self.allocator.free(p);
    }

    /// Load scroll positions from a JSON file. Returns an empty store if the file doesn't exist.
    pub fn load(allocator: Allocator, file_path: []const u8) !ScrollPositionStore {
        var store = try ScrollPositionStore.init(allocator, file_path);
        errdefer store.deinit();

        const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer allocator.free(content);

        store.parseJson(content) catch |err| {
            std.log.warn("Failed to parse scroll positions from '{s}': {}", .{ file_path, err });
            // Return empty store on parse failure — don't lose the file_path
            return store;
        };

        return store;
    }

    fn parseJson(self: *ScrollPositionStore, content: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        var it = root.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            if (val != .object) continue;

            const scroll_y_val = val.object.get("scroll_y") orelse continue;
            const timestamp_val = val.object.get("timestamp") orelse continue;

            const scroll_y: f32 = switch (scroll_y_val) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => continue,
            };
            const timestamp: i64 = switch (timestamp_val) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => continue,
            };

            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            try self.map.put(owned_key, .{ .scroll_y = scroll_y, .timestamp = timestamp });
        }
    }

    /// Save scroll positions to disk. Writes to a temp file then renames for atomicity.
    pub fn save(self: *ScrollPositionStore) !void {
        const path = self.file_path orelse return;

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        var writer = buf.writer();
        try writer.writeByte('{');

        var first = true;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.writeByte(',');
            first = false;
            const val = entry.value_ptr.*;
            try writer.writeByte('\n');
            try writer.writeAll("  ");
            try std.json.encodeJsonString(entry.key_ptr.*, .{}, writer);
            try writer.print(": {{\"scroll_y\": {d}, \"timestamp\": {d}}}", .{ val.scroll_y, val.timestamp });
        }
        if (!first) try writer.writeByte('\n');
        try writer.writeAll("}\n");

        // Atomic write: temp file + rename
        const dir_path = std.fs.path.dirname(path) orelse ".";
        var dir = std.fs.cwd().openDir(dir_path, .{}) catch |err| {
            std.log.err("Failed to open directory '{s}' for scroll positions: {}", .{ dir_path, err });
            return err;
        };
        defer dir.close();

        const basename = std.fs.path.basename(path);
        var atomic = dir.atomicFile(basename, .{}) catch |err| {
            std.log.err("Failed to create atomic file for scroll positions: {}", .{err});
            return err;
        };
        defer atomic.deinit();
        try atomic.file.writeAll(buf.items);
        try atomic.finish();
    }

    /// Look up the saved scroll Y position for a file path.
    pub fn getPosition(self: *const ScrollPositionStore, path: []const u8) ?f32 {
        const entry = self.map.get(path) orelse return null;
        return entry.scroll_y;
    }

    /// Store or update the scroll position for a file path.
    pub fn setPosition(self: *ScrollPositionStore, path: []const u8, scroll_y: f32) !void {
        const timestamp = std.time.timestamp();

        if (self.map.getPtr(path)) |existing| {
            existing.* = .{ .scroll_y = scroll_y, .timestamp = timestamp };
        } else {
            const owned_key = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned_key);
            try self.map.put(owned_key, .{ .scroll_y = scroll_y, .timestamp = timestamp });
        }

        if (self.map.count() > max_entries) {
            self.evictOldest();
        }
    }

    /// Evict the entry with the oldest timestamp.
    fn evictOldest(self: *ScrollPositionStore) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_ts: i64 = std.math.maxInt(i64);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.timestamp < oldest_ts) {
                oldest_ts = entry.value_ptr.timestamp;
                oldest_key = entry.key_ptr.*;
            }
        }

        const key = oldest_key orelse return;
        if (self.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ScrollPositionStore init and deinit" {
    var store = try ScrollPositionStore.init(testing.allocator, null);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "setPosition and getPosition" {
    var store = try ScrollPositionStore.init(testing.allocator, null);
    defer store.deinit();

    try store.setPosition("/tmp/test.md", 42.5);
    const pos = store.getPosition("/tmp/test.md");
    try testing.expect(pos != null);
    try testing.expectApproxEqAbs(@as(f32, 42.5), pos.?, 0.01);
}

test "getPosition returns null for unknown path" {
    var store = try ScrollPositionStore.init(testing.allocator, null);
    defer store.deinit();

    try testing.expect(store.getPosition("/nonexistent") == null);
}

test "setPosition updates existing entry" {
    var store = try ScrollPositionStore.init(testing.allocator, null);
    defer store.deinit();

    try store.setPosition("/tmp/test.md", 10.0);
    try store.setPosition("/tmp/test.md", 99.0);
    const pos = store.getPosition("/tmp/test.md");
    try testing.expectApproxEqAbs(@as(f32, 99.0), pos.?, 0.01);
    try testing.expectEqual(@as(usize, 1), store.map.count());
}

test "save and load round-trip" {
    const test_path = "/tmp/selkie-test-scroll-positions.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Save
    {
        var store = try ScrollPositionStore.init(testing.allocator, test_path);
        defer store.deinit();

        try store.setPosition("/home/user/readme.md", 123.5);
        try store.setPosition("/home/user/notes.md", 456.0);
        try store.save();
    }

    // Load
    {
        var store = try ScrollPositionStore.load(testing.allocator, test_path);
        defer store.deinit();

        try testing.expectEqual(@as(usize, 2), store.map.count());

        const pos1 = store.getPosition("/home/user/readme.md");
        try testing.expect(pos1 != null);
        try testing.expectApproxEqAbs(@as(f32, 123.5), pos1.?, 0.1);

        const pos2 = store.getPosition("/home/user/notes.md");
        try testing.expect(pos2 != null);
        try testing.expectApproxEqAbs(@as(f32, 456.0), pos2.?, 0.1);
    }
}

test "load returns empty store for nonexistent file" {
    var store = try ScrollPositionStore.load(testing.allocator, "/tmp/selkie-nonexistent-scroll.json");
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "evictOldest removes oldest entry" {
    var store = try ScrollPositionStore.init(testing.allocator, null);
    defer store.deinit();

    // Manually insert entries with controlled timestamps
    const key1 = try testing.allocator.dupe(u8, "/old");
    try store.map.put(key1, .{ .scroll_y = 1.0, .timestamp = 100 });
    const key2 = try testing.allocator.dupe(u8, "/new");
    try store.map.put(key2, .{ .scroll_y = 2.0, .timestamp = 200 });

    store.evictOldest();

    try testing.expectEqual(@as(usize, 1), store.map.count());
    try testing.expect(store.getPosition("/old") == null);
    try testing.expect(store.getPosition("/new") != null);
}

test "load returns empty store for invalid JSON" {
    const test_path = "/tmp/selkie-test-scroll-invalid-json.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = "not valid json" });

    var store = try ScrollPositionStore.load(testing.allocator, test_path);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load returns empty store for JSON array root" {
    const test_path = "/tmp/selkie-test-scroll-array-root.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = "[]" });

    var store = try ScrollPositionStore.load(testing.allocator, test_path);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load skips entries with wrong value type" {
    const test_path = "/tmp/selkie-test-scroll-wrong-type.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = test_path,
        .data = "{\"key\": \"string_not_object\"}",
    });

    var store = try ScrollPositionStore.load(testing.allocator, test_path);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load skips entries with missing fields" {
    const test_path = "/tmp/selkie-test-scroll-missing-fields.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = test_path,
        .data = "{\"/path\": {\"scroll_y\": 1.0}}",
    });

    var store = try ScrollPositionStore.load(testing.allocator, test_path);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "setPosition triggers eviction at max_entries" {
    var store = try ScrollPositionStore.init(testing.allocator, null);
    defer store.deinit();

    // Insert max_entries entries with old timestamps
    var key_buf: [64]u8 = undefined;
    for (0..ScrollPositionStore.max_entries) |i| {
        const key_len = std.fmt.bufPrint(&key_buf, "/path/{d}", .{i}) catch unreachable;
        const owned_key = try testing.allocator.dupe(u8, key_len);
        try store.map.put(owned_key, .{
            .scroll_y = @floatFromInt(i),
            .timestamp = @intCast(i),
        });
    }

    try testing.expectEqual(@as(usize, ScrollPositionStore.max_entries), store.map.count());

    // Add one more via setPosition — should trigger eviction
    try store.setPosition("/path/new_entry", 999.0);

    try testing.expectEqual(@as(usize, ScrollPositionStore.max_entries), store.map.count());

    // The entry with timestamp 0 ("/path/0") should have been evicted
    try testing.expect(store.getPosition("/path/0") == null);

    // The new entry should exist
    try testing.expect(store.getPosition("/path/new_entry") != null);
}

test "save with null path returns without error" {
    var store = try ScrollPositionStore.init(testing.allocator, null);
    defer store.deinit();

    try store.setPosition("/tmp/test.md", 42.5);
    try store.save();

    // No file should be created — null path means save is a no-op
    try testing.expect(store.file_path == null);
}
