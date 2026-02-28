const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.file_watcher);

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("FileWatcher only supports Linux (requires inotify)");
    }
}

const linux = std.os.linux;

pub const ChangeResult = enum {
    no_change,
    file_changed,
    file_deleted,
};

const WatchMode = enum {
    inotify,
    polling,
};

pub const MtimeResult = union(enum) {
    mtime: i128,
    not_found,
    access_error: std.fs.File.OpenError,
    stat_error: std.fs.File.StatError,
};

pub const FileWatcher = struct {
    file_path: []const u8,
    dir_path: []const u8,
    file_name: []const u8,

    mode: WatchMode,

    // inotify state
    inotify_fd: posix.fd_t = -1,
    watch_fd: i32 = -1,

    // polling state
    last_mtime: i128 = 0,
    last_poll_ms: i64 = 0,

    // debounce
    last_event_ms: i64 = 0,
    pending_change: bool = false,

    // Null-terminated copy of dir path for inotify syscall
    dir_path_z: [std.fs.max_path_bytes:0]u8 = undefined,

    const debounce_ms: i64 = 300;
    const poll_interval_ms: i64 = 500;

    pub fn init(file_path: []const u8) FileWatcher {
        const dir_path = std.fs.path.dirname(file_path) orelse ".";
        const file_name = std.fs.path.basename(file_path);

        // Try inotify first, fall back to polling on any failure
        const flags: u32 = linux.IN.NONBLOCK | linux.IN.CLOEXEC;
        const rc = linux.inotify_init1(flags);
        if (linux.E.init(rc) != .SUCCESS) {
            return initPolling(file_path, dir_path, file_name);
        }

        const fd: posix.fd_t = @intCast(rc);

        var dir_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (dir_path.len > std.fs.max_path_bytes) {
            posix.close(fd);
            return initPolling(file_path, dir_path, file_name);
        }
        @memcpy(dir_z[0..dir_path.len], dir_path);
        dir_z[dir_path.len] = 0;

        const mask: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE;
        const wrc = linux.inotify_add_watch(fd, @ptrCast(&dir_z), mask);
        if (linux.E.init(wrc) != .SUCCESS) {
            posix.close(fd);
            return initPolling(file_path, dir_path, file_name);
        }

        var result = FileWatcher{
            .file_path = file_path,
            .dir_path = dir_path,
            .file_name = file_name,
            .mode = .inotify,
            .inotify_fd = fd,
            .watch_fd = @intCast(wrc),
            .last_mtime = initialMtime(file_path),
            .last_event_ms = std.time.milliTimestamp(),
        };
        result.dir_path_z = dir_z;
        return result;
    }

    fn initPolling(file_path: []const u8, dir_path: []const u8, file_name: []const u8) FileWatcher {
        return .{
            .file_path = file_path,
            .dir_path = dir_path,
            .file_name = file_name,
            .mode = .polling,
            .last_mtime = initialMtime(file_path),
            .last_poll_ms = std.time.milliTimestamp(),
            .last_event_ms = std.time.milliTimestamp(),
        };
    }

    pub fn checkForChanges(self: *FileWatcher) ChangeResult {
        return switch (self.mode) {
            .inotify => self.checkInotify(),
            .polling => self.checkPolling(),
        };
    }

    fn checkInotify(self: *FileWatcher) ChangeResult {
        var pollfds = [_]linux.pollfd{.{
            .fd = self.inotify_fd,
            .events = linux.POLL.IN,
            .revents = 0,
        }};

        const poll_rc = linux.poll(&pollfds, 1, 0);
        if (linux.E.init(poll_rc) != .SUCCESS) return self.checkFileExists();

        if (poll_rc > 0) {
            self.drainInotifyEvents();
        }

        return self.consumePendingChange();
    }

    fn drainInotifyEvents(self: *FileWatcher) void {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        while (true) {
            const read_rc = linux.read(self.inotify_fd, &buf, buf.len);
            if (linux.E.init(read_rc) != .SUCCESS) break;
            if (read_rc == 0) break;
            const bytes_read: usize = @intCast(read_rc);

            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= bytes_read) {
                const event: *const linux.inotify_event = @alignCast(@ptrCast(&buf[offset]));
                offset += @sizeOf(linux.inotify_event) + event.len;

                if (event.getName()) |event_name| {
                    if (std.mem.eql(u8, event_name, self.file_name)) {
                        self.last_event_ms = std.time.milliTimestamp();
                        self.pending_change = true;
                    }
                }
            }
        }
    }

    fn checkPolling(self: *FileWatcher) ChangeResult {
        const now = std.time.milliTimestamp();
        if (now - self.last_poll_ms < poll_interval_ms) {
            return self.consumePendingChange();
        }
        self.last_poll_ms = now;

        switch (getFileMtime(self.file_path)) {
            .mtime => |mtime| {
                if (mtime != self.last_mtime) {
                    self.last_mtime = mtime;
                    self.last_event_ms = now;
                    self.pending_change = true;
                }
            },
            .not_found => return .file_deleted,
            .access_error => |err| {
                logMtimeError(self.file_path, err);
                return .no_change;
            },
            .stat_error => |err| {
                logMtimeError(self.file_path, err);
                return .no_change;
            },
        }

        return self.consumePendingChange();
    }

    fn checkFileExists(self: *FileWatcher) ChangeResult {
        return switch (getFileMtime(self.file_path)) {
            .mtime => .no_change,
            .not_found => .file_deleted,
            .access_error => |err| {
                logMtimeError(self.file_path, err);
                return .no_change;
            },
            .stat_error => |err| {
                logMtimeError(self.file_path, err);
                return .no_change;
            },
        };
    }

    /// Check if a pending change has passed the debounce window and report it.
    /// On debounce expiry, verifies the file still exists before reporting .file_changed.
    fn consumePendingChange(self: *FileWatcher) ChangeResult {
        if (!self.pending_change) return .no_change;

        const now = std.time.milliTimestamp();
        if (now - self.last_event_ms < debounce_ms) return .no_change;

        self.pending_change = false;
        return switch (getFileMtime(self.file_path)) {
            .mtime => |m| {
                self.last_mtime = m;
                return .file_changed;
            },
            .not_found => .file_deleted,
            .access_error => |err| {
                logMtimeError(self.file_path, err);
                return .no_change;
            },
            .stat_error => |err| {
                logMtimeError(self.file_path, err);
                return .no_change;
            },
        };
    }

    /// Refresh last_mtime from disk and clear pending_change. Used after saving
    /// a file to sync the watcher with the newly written mtime, avoiding a
    /// spurious "file changed" notification without tearing down inotify.
    pub fn updateMtime(self: *FileWatcher) void {
        self.last_mtime = switch (getFileMtime(self.file_path)) {
            .mtime => |m| m,
            else => self.last_mtime,
        };
        self.pending_change = false;
    }

    /// Best-effort mtime for initialization; returns 0 if file is inaccessible.
    fn initialMtime(path: []const u8) i128 {
        return switch (getFileMtime(path)) {
            .mtime => |m| m,
            else => 0,
        };
    }

    fn logMtimeError(path: []const u8, err: anytype) void {
        log.err("cannot access {s}: {}", .{ path, err });
    }

    fn getFileMtime(path: []const u8) MtimeResult {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => .not_found,
                else => .{ .access_error = err },
            };
        };
        defer file.close();
        const stat = file.stat() catch |err| {
            return .{ .stat_error = err };
        };
        return .{ .mtime = stat.mtime };
    }

    pub fn deinit(self: *FileWatcher) void {
        if (self.mode == .inotify) {
            if (self.watch_fd >= 0) {
                _ = linux.inotify_rm_watch(self.inotify_fd, self.watch_fd);
            }
            if (self.inotify_fd >= 0) {
                posix.close(self.inotify_fd);
            }
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Helper: create a temp file with content and return its absolute path (caller frees).
fn createTempFile(allocator: std.mem.Allocator, tmp_dir: *std.testing.TmpDir, content: []const u8) ![]const u8 {
    const sub_path = "test_watched_file.md";
    const file = try tmp_dir.dir.createFile(sub_path, .{});
    defer file.close();
    try file.writeAll(content);

    return try tmp_dir.dir.realpathAlloc(allocator, sub_path);
}

test "getFileMtime returns valid mtime for existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("exists.txt", .{});
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "exists.txt");
    defer testing.allocator.free(path);

    const result = FileWatcher.getFileMtime(path);
    switch (result) {
        .mtime => |m| try testing.expect(m > 0),
        else => return error.TestUnexpectedResult,
    }
}

test "getFileMtime returns not_found for missing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    // Build a path to a file that does not exist within the temp dir
    const missing = try std.fmt.allocPrint(testing.allocator, "{s}/no_such_file.txt", .{path});
    defer testing.allocator.free(missing);

    const result = FileWatcher.getFileMtime(missing);
    try testing.expectEqual(.not_found, result);
}

test "getFileMtime returns access_error for unreadable file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("noperm.txt", .{});
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "noperm.txt");
    defer testing.allocator.free(path);

    // Remove all permissions so open fails with AccessDenied
    const sub_path: [:0]const u8 = "noperm.txt";
    try std.posix.fchmodat(tmp_dir.dir.fd, sub_path, @as(std.posix.mode_t, 0), 0);

    const result = FileWatcher.getFileMtime(path);
    switch (result) {
        .access_error => {},
        else => return error.TestUnexpectedResult,
    }
}

test "initialMtime returns 0 for missing file" {
    const mtime = FileWatcher.initialMtime("/tmp/__selkie_nonexistent_test_file__");
    try testing.expectEqual(@as(i128, 0), mtime);
}

test "initialMtime returns nonzero for existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("mtime_test.txt", .{});
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "mtime_test.txt");
    defer testing.allocator.free(path);

    const mtime = FileWatcher.initialMtime(path);
    try testing.expect(mtime > 0);
}

test "consumePendingChange with no pending returns no_change" {
    var watcher = FileWatcher{
        .file_path = "/tmp/__selkie_test__",
        .dir_path = "/tmp",
        .file_name = "__selkie_test__",
        .mode = .polling,
        .last_mtime = 0,
        .last_poll_ms = 0,
        .last_event_ms = 0,
        .pending_change = false,
    };
    try testing.expectEqual(.no_change, watcher.consumePendingChange());
}

test "polling mode returns no_change when file unchanged" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTempFile(testing.allocator, &tmp_dir, "hello");
    defer testing.allocator.free(path);

    var watcher = FileWatcher.initPolling(
        path,
        std.fs.path.dirname(path) orelse ".",
        std.fs.path.basename(path),
    );
    defer watcher.deinit();

    // Reset poll timer so checkPolling actually polls
    watcher.last_poll_ms = 0;

    const result = watcher.checkPolling();
    try testing.expectEqual(.no_change, result);
}

test "polling mode detects file change" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTempFile(testing.allocator, &tmp_dir, "original");
    defer testing.allocator.free(path);

    var watcher = FileWatcher.initPolling(
        path,
        std.fs.path.dirname(path) orelse ".",
        std.fs.path.basename(path),
    );
    defer watcher.deinit();

    // Modify the file — write different content to change mtime
    const file = try tmp_dir.dir.createFile("test_watched_file.md", .{ .truncate = true });
    defer file.close();
    try file.writeAll("modified content");

    // Force poll to fire by resetting timer
    watcher.last_poll_ms = 0;
    // Force mtime to differ (set to 0 so any real mtime triggers change)
    watcher.last_mtime = 0;

    // First poll should detect change and set pending
    _ = watcher.checkPolling();
    try testing.expect(watcher.pending_change);

    // Simulate time past debounce window by backdating last_event_ms
    watcher.last_event_ms = std.time.milliTimestamp() - (FileWatcher.debounce_ms + 100);

    // Now consumePendingChange should return file_changed
    const result = watcher.consumePendingChange();
    try testing.expectEqual(.file_changed, result);
}

test "polling mode detects file deletion" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTempFile(testing.allocator, &tmp_dir, "to be deleted");
    defer testing.allocator.free(path);

    var watcher = FileWatcher.initPolling(
        path,
        std.fs.path.dirname(path) orelse ".",
        std.fs.path.basename(path),
    );
    defer watcher.deinit();

    // Delete the file
    try tmp_dir.dir.deleteFile("test_watched_file.md");

    // Force poll to fire
    watcher.last_poll_ms = 0;

    const result = watcher.checkPolling();
    try testing.expectEqual(.file_deleted, result);
}

test "debounce suppresses rapid changes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTempFile(testing.allocator, &tmp_dir, "initial");
    defer testing.allocator.free(path);

    var watcher = FileWatcher.initPolling(
        path,
        std.fs.path.dirname(path) orelse ".",
        std.fs.path.basename(path),
    );
    defer watcher.deinit();

    // Simulate a pending change that just happened (within debounce window)
    watcher.pending_change = true;
    watcher.last_event_ms = std.time.milliTimestamp();

    // Should return no_change because we're within the 300ms debounce window
    const result = watcher.consumePendingChange();
    try testing.expectEqual(.no_change, result);
    // pending_change should still be true (not consumed)
    try testing.expect(watcher.pending_change);
}

test "updateMtime refreshes mtime and clears pending_change" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTempFile(testing.allocator, &tmp_dir, "initial");
    defer testing.allocator.free(path);

    var watcher = FileWatcher.initPolling(
        path,
        std.fs.path.dirname(path) orelse ".",
        std.fs.path.basename(path),
    );
    defer watcher.deinit();

    // Simulate a pending change
    watcher.pending_change = true;
    watcher.last_mtime = 0;

    watcher.updateMtime();

    // pending_change should be cleared
    try testing.expect(!watcher.pending_change);
    // mtime should be updated to a real value (not 0)
    try testing.expect(watcher.last_mtime > 0);
}

test "updateMtime preserves mtime when file is missing" {
    var watcher = FileWatcher{
        .file_path = "/tmp/__selkie_nonexistent_updateMtime_test__",
        .dir_path = "/tmp",
        .file_name = "__selkie_nonexistent_updateMtime_test__",
        .mode = .polling,
        .last_mtime = 42,
        .last_poll_ms = 0,
        .last_event_ms = 0,
        .pending_change = true,
    };

    watcher.updateMtime();

    // mtime should be preserved (file doesn't exist)
    try testing.expectEqual(@as(i128, 42), watcher.last_mtime);
    // pending_change should still be cleared
    try testing.expect(!watcher.pending_change);
}
