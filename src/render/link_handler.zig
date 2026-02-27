const std = @import("std");
const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const slice_utils = @import("../utils/slice_utils.zig");
const Theme = @import("../theme/theme.zig").Theme;

const log = std.log.scoped(.link_handler);

pub const LinkHandler = struct {
    hovered_url: ?[]const u8 = null,
    theme: *const Theme,

    pub fn init(theme: *const Theme) LinkHandler {
        return .{ .theme = theme };
    }

    /// Check if mouse is hovering over any link text runs in the tree.
    /// Uses frustum culling to skip nodes outside the visible region.
    pub fn update(self: *LinkHandler, tree: *const lt.LayoutTree, scroll_y: f32, screen_h: f32) void {
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        self.hovered_url = null;

        const view_top = scroll_y;
        const view_bottom = scroll_y + screen_h;

        for (tree.nodes.items) |*node| {
            if (!node.rect.overlapsVertically(view_top, view_bottom)) continue;

            for (node.text_runs.items) |*run| {
                if (run.style.link_url) |url| {
                    const draw_y = run.rect.y - scroll_y;
                    if (mouse_x >= run.rect.x and
                        mouse_x <= run.rect.x + run.rect.width and
                        mouse_y >= draw_y and
                        mouse_y <= draw_y + run.rect.height)
                    {
                        self.hovered_url = url;
                        rl.setMouseCursor(.pointing_hand);
                        return;
                    }
                }
            }
        }

        rl.setMouseCursor(.default);
    }

    /// Handle click: if mouse was released on a link, open it.
    pub fn handleClick(self: *LinkHandler) void {
        if (rl.isMouseButtonReleased(.left)) {
            if (self.hovered_url) |url| {
                openUrl(url);
            }
        }
    }
};

fn openUrl(url: []const u8) void {
    if (url.len == 0) return;

    // Need null-terminated string for execve
    var buf: [2048]u8 = undefined;
    const z = slice_utils.sliceToZ(&buf, url);
    const z_ptr: [*:0]const u8 = z.ptr;

    // Double-fork to avoid zombie processes:
    // 1. Parent forks child, immediately waits for it (child exits fast)
    // 2. Child forks grandchild, then exits
    // 3. Grandchild execs xdg-open; adopted by init, auto-reaped on exit
    const pid = std.posix.fork() catch |err| {
        log.err("fork failed: {}", .{err});
        return;
    };

    if (pid == 0) {
        // First child: fork again and exit immediately
        const pid2 = std.posix.fork() catch {
            std.posix.exit(1);
        };

        if (pid2 == 0) {
            // Grandchild: exec xdg-open with inherited environment
            const argv = [_:null]?[*:0]const u8{ "xdg-open", z_ptr, null };
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            const err = std.posix.execvpeZ("xdg-open", &argv, envp);
            log.err("execvpeZ(xdg-open) failed: {}", .{err});
            std.posix.exit(1);
        }

        // First child exits so parent's waitpid returns quickly
        std.posix.exit(0);
    }

    // Parent: reap the first child (exits almost immediately)
    _ = std.posix.waitpid(pid, 0);
}
