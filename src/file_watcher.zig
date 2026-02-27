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

        const initial_mtime = switch (getFileMtime(file_path)) {
            .mtime => |m| m,
            else => 0,
        };

        var result = FileWatcher{
            .file_path = file_path,
            .dir_path = dir_path,
            .file_name = file_name,
            .mode = .inotify,
            .inotify_fd = fd,
            .watch_fd = @intCast(wrc),
            .last_mtime = initial_mtime,
            .last_event_ms = std.time.milliTimestamp(),
        };
        result.dir_path_z = dir_z;
        return result;
    }

    fn initPolling(file_path: []const u8, dir_path: []const u8, file_name: []const u8) FileWatcher {
        const initial_mtime = switch (getFileMtime(file_path)) {
            .mtime => |m| m,
            else => 0,
        };

        return .{
            .file_path = file_path,
            .dir_path = dir_path,
            .file_name = file_name,
            .mode = .polling,
            .last_mtime = initial_mtime,
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
            // Drain all inotify events
            self.drainInotifyEvents();
        }

        // If we have a pending change and the debounce window has elapsed, report it
        if (self.pending_change) {
            const now = std.time.milliTimestamp();
            if (now - self.last_event_ms >= debounce_ms) {
                self.pending_change = false;
                // Verify file still exists and update mtime
                return switch (getFileMtime(self.file_path)) {
                    .mtime => |m| {
                        self.last_mtime = m;
                        return .file_changed;
                    },
                    .not_found => .file_deleted,
                    .access_error => |err| {
                        log.err("cannot access {s}: {}", .{ self.file_path, err });
                        return .no_change;
                    },
                    .stat_error => |err| {
                        log.err("cannot stat {s}: {}", .{ self.file_path, err });
                        return .no_change;
                    },
                };
            }
        }

        return .no_change;
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
                        // Record the event time and set pending flag
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
            // Even if not polling yet, check pending debounce
            if (self.pending_change and now - self.last_event_ms >= debounce_ms) {
                self.pending_change = false;
                return .file_changed;
            }
            return .no_change;
        }
        self.last_poll_ms = now;

        return switch (getFileMtime(self.file_path)) {
            .mtime => |mtime| {
                if (mtime != self.last_mtime) {
                    self.last_mtime = mtime;
                    // Set pending and record time for debounce
                    self.last_event_ms = now;
                    self.pending_change = true;
                }
                // Check if debounce window has elapsed for any pending change
                if (self.pending_change and now - self.last_event_ms >= debounce_ms) {
                    self.pending_change = false;
                    return .file_changed;
                }
                return .no_change;
            },
            .not_found => .file_deleted,
            .access_error => |err| {
                log.err("cannot access {s}: {}", .{ self.file_path, err });
                return .no_change;
            },
            .stat_error => |err| {
                log.err("cannot stat {s}: {}", .{ self.file_path, err });
                return .no_change;
            },
        };
    }

    fn checkFileExists(self: *FileWatcher) ChangeResult {
        return switch (getFileMtime(self.file_path)) {
            .mtime => .no_change,
            .not_found => .file_deleted,
            .access_error => |err| {
                log.err("cannot access {s}: {}", .{ self.file_path, err });
                return .no_change;
            },
            .stat_error => |err| {
                log.err("cannot stat {s}: {}", .{ self.file_path, err });
                return .no_change;
            },
        };
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
