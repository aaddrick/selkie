//! Native file picker dialog using zenity (Linux-only).
//!
//! Spawns `zenity --file-selection` as a child process and reads the selected
//! path from stdout. Requires zenity to be installed on the system.
//! NOTE: This blocks the calling thread while the dialog is open.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.file_dialog);

comptime {
    if (builtin.os.tag != .linux)
        @compileError("file_dialog only supports Linux (requires zenity)");
}

pub const DialogError = error{
    SpawnFailed,
    WaitFailed,
    ReadFailed,
};

/// Open a native file picker dialog. Returns the selected path (caller must free
/// with `allocator.free()`), or null if the user cancelled.
///
/// Blocks the caller until the dialog is closed.
pub fn openFileDialog(allocator: Allocator) (DialogError || Allocator.Error)!?[]u8 {
    const argv = [_][]const u8{
        "zenity",
        "--file-selection",
        "--title=Open Markdown File",
        "--file-filter=Markdown files | *.md *.markdown *.mkd *.mkdn",
        "--file-filter=All files | *",
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| {
        log.err("Failed to launch file dialog (is zenity installed?): {}", .{err});
        return DialogError.SpawnFailed;
    };
    // Always reap the child process, even if reading stdout fails
    defer _ = child.wait() catch {};

    const stdout = child.stdout orelse return DialogError.ReadFailed;
    const output = stdout.reader().readAllAlloc(allocator, 4096) catch |err| {
        log.err("Failed to read file dialog output: {}", .{err});
        return DialogError.ReadFailed;
    };
    defer allocator.free(output);

    // Note: child.wait() is called by the defer above. We need the term result
    // to check the exit code, so we call it explicitly here and the defer will
    // be a no-op (wait on an already-waited child returns immediately).
    const term = child.wait() catch {
        return DialogError.WaitFailed;
    };

    // zenity exits 0 on OK, 1 on Cancel, 5 on timeout
    const exit_code = switch (term) {
        .Exited => |code| code,
        else => return DialogError.WaitFailed,
    };
    if (exit_code != 0) return null;

    // Strip trailing newline and dupe into a properly-sized allocation
    const trimmed = std.mem.trimRight(u8, output, "\n\r");
    if (trimmed.len == 0) return null;

    return try allocator.dupe(u8, trimmed);
}

// =============================================================================
// Tests
// =============================================================================

// NOTE: openFileDialog spawns zenity and requires a display server. It cannot
// be unit tested. Integration testing requires a live desktop environment.
