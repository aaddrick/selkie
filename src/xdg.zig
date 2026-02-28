const std = @import("std");
const Allocator = std.mem.Allocator;

pub const XdgError = error{
    HomeNotSet,
    OutOfMemory,
};

/// Returns the XDG data home for Selkie: `$XDG_DATA_HOME/selkie` or `~/.local/share/selkie`.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn getDataHome(allocator: Allocator) XdgError![]const u8 {
    return resolveDir(allocator, "XDG_DATA_HOME", ".local/share/selkie");
}

/// Returns the XDG config home for Selkie: `$XDG_CONFIG_HOME/selkie` or `~/.config/selkie`.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn getConfigHome(allocator: Allocator) XdgError![]const u8 {
    return resolveDir(allocator, "XDG_CONFIG_HOME", ".config/selkie");
}

/// Create directory (and parents) if it doesn't exist.
pub fn ensureDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn resolveDir(allocator: Allocator, env_var: []const u8, fallback_suffix: []const u8) XdgError![]const u8 {
    // Try the XDG env var first, then fall back to $HOME/<suffix>
    const candidates = .{
        .{ std.posix.getenv(env_var), "selkie" },
        .{ std.posix.getenv("HOME"), fallback_suffix },
    };
    inline for (candidates) |candidate| {
        const base, const suffix = candidate;
        if (base) |b| {
            if (b.len > 0)
                return std.fs.path.join(allocator, &.{ b, suffix }) catch return error.OutOfMemory;
        }
    }
    return error.HomeNotSet;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "getDataHome returns path ending with selkie" {
    const path = getDataHome(testing.allocator) catch |err| {
        // In CI or environments without HOME, skip gracefully
        if (err == XdgError.HomeNotSet) return;
        return err;
    };
    defer testing.allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "selkie"));
    try testing.expect(path.len > "selkie".len);
}

test "getConfigHome returns path ending with selkie" {
    const path = getConfigHome(testing.allocator) catch |err| {
        if (err == XdgError.HomeNotSet) return;
        return err;
    };
    defer testing.allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "selkie"));
    try testing.expect(path.len > "selkie".len);
}

test "ensureDir creates and tolerates existing directory" {
    // Use a temp path under /tmp to avoid polluting the project
    const test_path = "/tmp/selkie-test-xdg-ensure-dir";
    defer std.fs.cwd().deleteTree(test_path) catch {};

    // First call creates
    try ensureDir(test_path);
    // Second call tolerates existing
    try ensureDir(test_path);

    // Verify it exists
    var dir = try std.fs.cwd().openDir(test_path, .{});
    dir.close();
}
