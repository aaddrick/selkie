//! Native save-as file dialog using zenity (Linux-only).
//!
//! Spawns `zenity --file-selection --save` as a child process and reads the
//! selected path from stdout. Mirrors the pattern in `file_dialog.zig`.
//! NOTE: This blocks the calling thread while the dialog is open.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.save_dialog);

comptime {
    if (builtin.os.tag != .linux)
        @compileError("save_dialog only supports Linux (requires zenity)");
}

pub const DialogError = error{
    SpawnFailed,
    WaitFailed,
    ReadFailed,
};

/// Open a native save-as dialog for PDF export. Returns the selected path
/// (caller must free with `allocator.free()`), or null if the user cancelled.
///
/// `default_name` is the suggested filename shown in the dialog (e.g. "document.pdf").
/// Blocks the caller until the dialog is closed.
pub fn saveFileDialog(allocator: Allocator, default_name: []const u8) (DialogError || Allocator.Error)!?[]u8 {
    // Build the --filename argument with default name
    var filename_buf: [512]u8 = undefined;
    const filename_arg = std.fmt.bufPrint(&filename_buf, "--filename={s}", .{default_name}) catch {
        log.warn("Default filename too long ({d} bytes), falling back to export.pdf", .{default_name.len});
        return saveFileDialogImpl(allocator, "--filename=export.pdf");
    };

    return saveFileDialogImpl(allocator, filename_arg);
}

fn saveFileDialogImpl(allocator: Allocator, filename_arg: []const u8) (DialogError || Allocator.Error)!?[]u8 {
    const argv = [_][]const u8{
        "zenity",
        "--file-selection",
        "--save",
        "--confirm-overwrite",
        "--title=Export as PDF",
        filename_arg,
        "--file-filter=PDF files | *.pdf",
        "--file-filter=All files | *",
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| {
        log.err("Failed to launch save dialog (is zenity installed?): {}", .{err});
        return DialogError.SpawnFailed;
    };

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return DialogError.ReadFailed;
    };
    const output = stdout.reader().readAllAlloc(allocator, 4096) catch |err| {
        log.err("Failed to read save dialog output: {}", .{err});
        _ = child.wait() catch {};
        return DialogError.ReadFailed;
    };
    defer allocator.free(output);

    // zenity exits 0 on OK, 1 on Cancel, 5 on timeout
    const term = child.wait() catch return DialogError.WaitFailed;
    const exit_code = switch (term) {
        .Exited => |code| code,
        else => return DialogError.WaitFailed,
    };
    if (exit_code != 0) return null;

    // Strip trailing newline and dupe into a properly-sized allocation
    const trimmed = std.mem.trimRight(u8, output, "\n\r");
    if (trimmed.len == 0) return null;

    return try ensurePdfExtension(allocator, trimmed);
}

/// Ensure the path ends with ".pdf" (case-insensitive). If it doesn't, append it.
/// Caller must free the returned slice.
pub fn ensurePdfExtension(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".pdf")) {
        return try allocator.dupe(u8, path);
    }
    return try std.fmt.allocPrint(allocator, "{s}.pdf", .{path});
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ensurePdfExtension preserves existing .pdf" {
    const result = try ensurePdfExtension(testing.allocator, "document.pdf");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("document.pdf", result);
}

test "ensurePdfExtension is case-insensitive" {
    const r1 = try ensurePdfExtension(testing.allocator, "document.PDF");
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("document.PDF", r1);

    const r2 = try ensurePdfExtension(testing.allocator, "document.Pdf");
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("document.Pdf", r2);
}

test "ensurePdfExtension appends .pdf to non-pdf paths" {
    const r1 = try ensurePdfExtension(testing.allocator, "document.txt");
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("document.txt.pdf", r1);

    const r2 = try ensurePdfExtension(testing.allocator, "document");
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings("document.pdf", r2);
}

test "ensurePdfExtension handles short and empty inputs" {
    const r1 = try ensurePdfExtension(testing.allocator, "pdf");
    defer testing.allocator.free(r1);
    try testing.expectEqualStrings("pdf.pdf", r1);

    const r2 = try ensurePdfExtension(testing.allocator, "");
    defer testing.allocator.free(r2);
    try testing.expectEqualStrings(".pdf", r2);
}

// NOTE: saveFileDialog spawns zenity and requires a display server. It cannot
// be unit tested. Integration testing requires a live desktop environment.
