const std = @import("std");
const Allocator = std.mem.Allocator;

/// Persistent store for per-file `<details>` expand/collapse state.
///
/// JSON format on disk:
/// ```json
/// {
///   "/path/to/file.md": {
///     "42": true,
///     "71": false
///   }
/// }
/// ```
/// The outer key is the absolute file path; inner keys are the section_id
/// (source line number of the opening `<details>` tag) serialised as a
/// decimal string; values are `true` (expanded) or `false` (collapsed).
///
/// Owns all key strings in both the outer and inner maps.
pub const DetailsStateStore = struct {
    allocator: Allocator,
    /// Outer map: file_path → (section_id_str → expanded)
    map: std.StringHashMap(std.StringHashMap(bool)),
    /// Path to the JSON file on disk (owned; null means no persistence).
    file_path: ?[]const u8,

    const max_files = 500;

    pub fn init(allocator: Allocator, file_path: ?[]const u8) !DetailsStateStore {
        const owned_path = if (file_path) |p|
            try allocator.dupe(u8, p)
        else
            null;
        errdefer if (owned_path) |p| allocator.free(p);

        return .{
            .allocator = allocator,
            .map = std.StringHashMap(std.StringHashMap(bool)).init(allocator),
            .file_path = owned_path,
        };
    }

    pub fn deinit(self: *DetailsStateStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeInnerMap(self.allocator, entry.value_ptr);
        }
        self.map.deinit();
        if (self.file_path) |p| self.allocator.free(p);
    }

    /// Release all owned keys in an inner (sections) map and call deinit on it.
    fn freeInnerMap(allocator: Allocator, inner: *std.StringHashMap(bool)) void {
        var it = inner.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        inner.deinit();
    }

    /// Load details state from a JSON file.
    /// Returns an empty store if the file does not exist.
    pub fn load(allocator: Allocator, file_path: []const u8) !DetailsStateStore {
        var store = try DetailsStateStore.init(allocator, file_path);
        errdefer store.deinit();

        const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer allocator.free(content);

        store.parseJson(content) catch |err| {
            std.log.warn("Failed to parse details state from '{s}': {}", .{ file_path, err });
            // Return empty store on parse failure — don't lose the file_path
            return store;
        };

        return store;
    }

    fn parseJson(self: *DetailsStateStore, content: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        var it = root.object.iterator();
        while (it.next()) |entry| {
            const file_key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (val != .object) continue;

            // Build inner sections map
            var sections = std.StringHashMap(bool).init(self.allocator);
            errdefer freeInnerMap(self.allocator, &sections);

            var sec_it = val.object.iterator();
            while (sec_it.next()) |sec_entry| {
                const sec_key = sec_entry.key_ptr.*;
                const expanded: bool = switch (sec_entry.value_ptr.*) {
                    .bool => |b| b,
                    else => continue,
                };
                const owned_sec_key = try self.allocator.dupe(u8, sec_key);
                errdefer self.allocator.free(owned_sec_key);
                // Duplicate JSON keys are not expected; if present, later values overwrite earlier ones.
                try sections.put(owned_sec_key, expanded);
            }

            const owned_file_key = try self.allocator.dupe(u8, file_key);
            errdefer self.allocator.free(owned_file_key);
            try self.map.put(owned_file_key, sections);
        }
    }

    /// Save details state to disk atomically (temp file + rename).
    pub fn save(self: *DetailsStateStore) !void {
        const path = self.file_path orelse return;

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        var writer = buf.writer();
        try writer.writeByte('{');

        var first_file = true;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            // Skip files with no recorded section states
            if (entry.value_ptr.count() == 0) continue;

            if (!first_file) try writer.writeByte(',');
            first_file = false;
            try writer.writeByte('\n');
            try writer.writeAll("  ");
            try std.json.encodeJsonString(entry.key_ptr.*, .{}, writer);
            try writer.writeAll(": {");

            var first_sec = true;
            var sec_it = entry.value_ptr.iterator();
            while (sec_it.next()) |sec_entry| {
                if (!first_sec) try writer.writeByte(',');
                first_sec = false;
                try writer.writeByte('\n');
                try writer.writeAll("    ");
                try std.json.encodeJsonString(sec_entry.key_ptr.*, .{}, writer);
                try writer.print(": {}", .{sec_entry.value_ptr.*});
            }
            if (!first_sec) try writer.writeByte('\n');
            try writer.writeAll("  }");
        }
        if (!first_file) try writer.writeByte('\n');
        try writer.writeAll("}\n");

        // Atomic write: temp file + rename
        const dir_path = std.fs.path.dirname(path) orelse ".";
        var dir = std.fs.cwd().openDir(dir_path, .{}) catch |err| {
            std.log.err("Failed to open directory '{s}' for details state: {}", .{ dir_path, err });
            return err;
        };
        defer dir.close();

        const basename = std.fs.path.basename(path);
        var atomic = dir.atomicFile(basename, .{}) catch |err| {
            std.log.err("Failed to create atomic file for details state: {}", .{err});
            return err;
        };
        defer atomic.deinit();
        try atomic.file.writeAll(buf.items);
        try atomic.finish();
    }

    /// Apply stored details state for `file_path` to the tab's `details_state` map.
    /// Only sections with a recorded state are populated; others are left untouched.
    pub fn applyToTab(
        self: *const DetailsStateStore,
        file_path: []const u8,
        details_state: *std.AutoHashMap(u32, bool),
    ) void {
        const sections = self.map.getPtr(file_path) orelse return;
        var it = sections.iterator();
        while (it.next()) |entry| {
            const section_id = std.fmt.parseInt(u32, entry.key_ptr.*, 10) catch continue;
            details_state.put(section_id, entry.value_ptr.*) catch |err| {
                std.log.err("Failed to restore details state for section {d}: {}", .{ section_id, err });
            };
        }
    }

    /// Update the store with the complete `details_state` from a tab.
    /// Replaces any previously stored state for `file_path`.
    /// If `details_state` is empty the file's entry is removed from the store.
    pub fn updateFromTab(
        self: *DetailsStateStore,
        file_path: []const u8,
        details_state: *const std.AutoHashMap(u32, bool),
    ) !void {
        if (details_state.count() == 0) {
            // No toggles recorded — remove any stale entry
            if (self.map.fetchRemove(file_path)) |kv| {
                self.allocator.free(kv.key);
                var old = kv.value;
                freeInnerMap(self.allocator, &old);
            }
            return;
        }

        // Build a fresh inner map
        var new_sections = std.StringHashMap(bool).init(self.allocator);
        var transferred = false;
        errdefer if (!transferred) freeInnerMap(self.allocator, &new_sections);

        var it = details_state.iterator();
        while (it.next()) |entry| {
            var key_buf: [20]u8 = undefined;
            const key_str = std.fmt.bufPrint(&key_buf, "{d}", .{entry.key_ptr.*}) catch continue;
            const owned_key = try self.allocator.dupe(u8, key_str);
            errdefer self.allocator.free(owned_key);
            try new_sections.put(owned_key, entry.value_ptr.*);
        }

        // Install or replace in the outer map
        if (self.map.getPtr(file_path)) |old_sections| {
            // Swap: move new_sections into the map slot, then free the old one
            var old = old_sections.*;
            old_sections.* = new_sections;
            transferred = true;
            freeInnerMap(self.allocator, &old);
        } else {
            const owned_file_key = try self.allocator.dupe(u8, file_path);
            errdefer self.allocator.free(owned_file_key);
            try self.map.put(owned_file_key, new_sections);
            transferred = true;

            if (self.map.count() > max_files) {
                self.evictSmallest();
            }
        }
    }

    /// Evict the file entry whose inner map has the fewest sections (simple heuristic).
    fn evictSmallest(self: *DetailsStateStore) void {
        var min_key: ?[]const u8 = null;
        var min_count: usize = std.math.maxInt(usize);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.count() < min_count) {
                min_count = entry.value_ptr.count();
                min_key = entry.key_ptr.*;
            }
        }

        const key = min_key orelse return;
        if (self.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var old = kv.value;
            freeInnerMap(self.allocator, &old);
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "DetailsStateStore init and deinit" {
    var store = try DetailsStateStore.init(testing.allocator, null);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "DetailsStateStore init with file path" {
    var store = try DetailsStateStore.init(testing.allocator, "/tmp/details.json");
    defer store.deinit();

    try testing.expectEqualStrings("/tmp/details.json", store.file_path.?);
}

test "updateFromTab stores section states" {
    var store = try DetailsStateStore.init(testing.allocator, null);
    defer store.deinit();

    var tab_state = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer tab_state.deinit();
    try tab_state.put(42, true);
    try tab_state.put(71, false);

    try store.updateFromTab("/home/user/readme.md", &tab_state);
    try testing.expectEqual(@as(usize, 1), store.map.count());
}

test "applyToTab restores section states" {
    var store = try DetailsStateStore.init(testing.allocator, null);
    defer store.deinit();

    var tab_state = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer tab_state.deinit();
    try tab_state.put(42, true);
    try tab_state.put(71, false);
    try store.updateFromTab("/home/user/readme.md", &tab_state);

    var restored = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer restored.deinit();
    store.applyToTab("/home/user/readme.md", &restored);

    try testing.expectEqual(@as(usize, 2), restored.count());
    try testing.expectEqual(true, restored.get(42).?);
    try testing.expectEqual(false, restored.get(71).?);
}

test "applyToTab is no-op for unknown file" {
    var store = try DetailsStateStore.init(testing.allocator, null);
    defer store.deinit();

    var restored = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer restored.deinit();
    store.applyToTab("/nonexistent.md", &restored);

    try testing.expectEqual(@as(usize, 0), restored.count());
}

test "updateFromTab with empty state removes file entry" {
    var store = try DetailsStateStore.init(testing.allocator, null);
    defer store.deinit();

    // First add an entry
    var tab_state = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer tab_state.deinit();
    try tab_state.put(10, true);
    try store.updateFromTab("/home/user/readme.md", &tab_state);
    try testing.expectEqual(@as(usize, 1), store.map.count());

    // Now update with empty state — should remove the entry
    var empty_state = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer empty_state.deinit();
    try store.updateFromTab("/home/user/readme.md", &empty_state);
    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "updateFromTab replaces existing state" {
    var store = try DetailsStateStore.init(testing.allocator, null);
    defer store.deinit();

    var tab_state1 = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer tab_state1.deinit();
    try tab_state1.put(42, true);
    try store.updateFromTab("/home/user/readme.md", &tab_state1);

    var tab_state2 = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer tab_state2.deinit();
    try tab_state2.put(42, false); // toggled to collapsed
    try tab_state2.put(100, true); // new section
    try store.updateFromTab("/home/user/readme.md", &tab_state2);

    // Only one file entry still
    try testing.expectEqual(@as(usize, 1), store.map.count());

    var restored = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer restored.deinit();
    store.applyToTab("/home/user/readme.md", &restored);
    try testing.expectEqual(@as(usize, 2), restored.count());
    try testing.expectEqual(false, restored.get(42).?);
    try testing.expectEqual(true, restored.get(100).?);
}

test "save with null path is no-op" {
    var store = try DetailsStateStore.init(testing.allocator, null);
    defer store.deinit();

    var tab_state = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer tab_state.deinit();
    try tab_state.put(1, true);
    try store.updateFromTab("/tmp/test.md", &tab_state);

    // Should succeed without creating a file
    try store.save();
}

test "save and load round-trip" {
    const test_path = "/tmp/selkie-test-details-state.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Save
    {
        var store = try DetailsStateStore.init(testing.allocator, test_path);
        defer store.deinit();

        var tab1 = std.AutoHashMap(u32, bool).init(testing.allocator);
        defer tab1.deinit();
        try tab1.put(42, true);
        try tab1.put(71, false);
        try store.updateFromTab("/home/user/readme.md", &tab1);

        var tab2 = std.AutoHashMap(u32, bool).init(testing.allocator);
        defer tab2.deinit();
        try tab2.put(10, false);
        try store.updateFromTab("/home/user/notes.md", &tab2);

        try store.save();
    }

    // Load
    {
        var store = try DetailsStateStore.load(testing.allocator, test_path);
        defer store.deinit();

        try testing.expectEqual(@as(usize, 2), store.map.count());

        var restored1 = std.AutoHashMap(u32, bool).init(testing.allocator);
        defer restored1.deinit();
        store.applyToTab("/home/user/readme.md", &restored1);
        try testing.expectEqual(@as(usize, 2), restored1.count());
        try testing.expectEqual(true, restored1.get(42).?);
        try testing.expectEqual(false, restored1.get(71).?);

        var restored2 = std.AutoHashMap(u32, bool).init(testing.allocator);
        defer restored2.deinit();
        store.applyToTab("/home/user/notes.md", &restored2);
        try testing.expectEqual(@as(usize, 1), restored2.count());
        try testing.expectEqual(false, restored2.get(10).?);
    }
}

test "load returns empty store for nonexistent file" {
    var store = try DetailsStateStore.load(testing.allocator, "/tmp/selkie-nonexistent-details.json");
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load returns empty store for invalid JSON" {
    const test_path = "/tmp/selkie-test-details-invalid.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = "not valid json" });

    var store = try DetailsStateStore.load(testing.allocator, test_path);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load returns empty store for JSON array root" {
    const test_path = "/tmp/selkie-test-details-array.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = "[]" });

    var store = try DetailsStateStore.load(testing.allocator, test_path);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load skips file entries with non-object value" {
    const test_path = "/tmp/selkie-test-details-wrong-type.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = test_path,
        .data = "{\"/path.md\": \"not_an_object\"}",
    });

    var store = try DetailsStateStore.load(testing.allocator, test_path);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.map.count());
}

test "load skips section entries with non-bool value" {
    const test_path = "/tmp/selkie-test-details-non-bool.json";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = test_path,
        .data = "{\"/path.md\": {\"42\": \"yes\"}}",
    });

    var store = try DetailsStateStore.load(testing.allocator, test_path);
    defer store.deinit();

    // File entry exists but inner map is empty (bad section entry was skipped)
    var restored = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer restored.deinit();
    store.applyToTab("/path.md", &restored);
    try testing.expectEqual(@as(usize, 0), restored.count());
}

test "multiple files are stored independently" {
    var store = try DetailsStateStore.init(testing.allocator, null);
    defer store.deinit();

    var tab_a = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer tab_a.deinit();
    try tab_a.put(1, true);
    try store.updateFromTab("/a.md", &tab_a);

    var tab_b = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer tab_b.deinit();
    try tab_b.put(2, false);
    try store.updateFromTab("/b.md", &tab_b);

    var res_a = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer res_a.deinit();
    store.applyToTab("/a.md", &res_a);
    try testing.expectEqual(@as(usize, 1), res_a.count());
    try testing.expectEqual(true, res_a.get(1).?);

    var res_b = std.AutoHashMap(u32, bool).init(testing.allocator);
    defer res_b.deinit();
    store.applyToTab("/b.md", &res_b);
    try testing.expectEqual(@as(usize, 1), res_b.count());
    try testing.expectEqual(false, res_b.get(2).?);
}
