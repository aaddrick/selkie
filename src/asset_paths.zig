const std = @import("std");
const Allocator = std.mem.Allocator;

const xdg = @import("xdg.zig");

pub const AssetPathError = error{
    AssetNotFound,
    OutOfMemory,
};

/// Resolve an asset path by searching a fallback chain:
/// 1. Exe-relative: <exe_dir>/../share/selkie/<relative_path>  (FHS install)
/// 2. XDG data home: $XDG_DATA_HOME/selkie/<relative_path>     (user overrides)
/// 3. CWD-relative: assets/<relative_path>                      (development)
///
/// Returns a null-terminated path string owned by the caller.
/// The caller must free the returned slice with the same allocator.
pub fn resolveAssetPath(allocator: Allocator, relative_path: []const u8) AssetPathError![:0]const u8 {
    // 1. Try exe-relative: <exe_dir>/../share/selkie/<relative_path>
    if (tryExeRelative(allocator, relative_path)) |path| {
        return path;
    }

    // 2. Try XDG data home: $XDG_DATA_HOME/selkie/<relative_path>
    if (tryXdgDataHome(allocator, relative_path)) |path| {
        return path;
    }

    // 3. Try CWD-relative: assets/<relative_path>
    if (tryCwdRelative(allocator, relative_path)) |path| {
        return path;
    }

    return AssetPathError.AssetNotFound;
}

fn tryExeRelative(allocator: Allocator, relative_path: []const u8) ?[:0]const u8 {
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir_path = std.fs.selfExeDirPath(&exe_dir_buf) catch return null;

    // Build: <exe_dir>/../share/selkie/<relative_path>
    const full_path = std.fs.path.resolve(allocator, &.{ exe_dir_path, "../share/selkie", relative_path }) catch return null;
    defer allocator.free(full_path);

    // Check if the file exists
    std.fs.cwd().access(full_path, .{}) catch return null;

    // Return as null-terminated
    return allocator.dupeZ(u8, full_path) catch return null;
}

fn tryXdgDataHome(allocator: Allocator, relative_path: []const u8) ?[:0]const u8 {
    const data_home = xdg.getDataHome(allocator) catch return null;
    defer allocator.free(data_home);

    const full_path = std.fs.path.join(allocator, &.{ data_home, relative_path }) catch return null;
    defer allocator.free(full_path);

    // Check if the file exists
    std.fs.cwd().access(full_path, .{}) catch return null;

    // Return as null-terminated
    return allocator.dupeZ(u8, full_path) catch return null;
}

fn tryCwdRelative(allocator: Allocator, relative_path: []const u8) ?[:0]const u8 {
    const cwd_path = std.fmt.allocPrintZ(allocator, "assets/{s}", .{relative_path}) catch return null;

    // Check if the file exists
    std.fs.cwd().access(cwd_path, .{}) catch {
        allocator.free(cwd_path);
        return null;
    };

    return cwd_path;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "resolveAssetPath finds CWD-relative fonts in dev tree" {
    // This test only passes when run from the project root (zig build test does this)
    const path = resolveAssetPath(testing.allocator, "fonts/Inter-Regular.ttf") catch |err| {
        // If assets aren't available (e.g. CI without assets), skip gracefully
        if (err == AssetPathError.AssetNotFound) return;
        return err;
    };
    defer testing.allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "Inter-Regular.ttf"));
}

test "resolveAssetPath returns AssetNotFound for missing file" {
    const result = resolveAssetPath(testing.allocator, "fonts/nonexistent-font.ttf");
    try testing.expectError(AssetPathError.AssetNotFound, result);
}

test "tryCwdRelative returns null for missing file" {
    const result = tryCwdRelative(testing.allocator, "fonts/does-not-exist.ttf");
    try testing.expect(result == null);
}

test "tryCwdRelative finds existing asset" {
    // Only works when run from project root
    const result = tryCwdRelative(testing.allocator, "fonts/Inter-Regular.ttf") orelse return;
    defer testing.allocator.free(result);

    try testing.expect(std.mem.endsWith(u8, result, "assets/fonts/Inter-Regular.ttf"));
}

test "tryExeRelative returns null when share dir does not exist" {
    // The test binary's exe dir won't have ../share/selkie/, so this should return null
    const result = tryExeRelative(testing.allocator, "fonts/Inter-Regular.ttf");
    try testing.expect(result == null);
}
