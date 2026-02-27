const std = @import("std");
const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const slice_utils = @import("../utils/slice_utils.zig");
const Theme = @import("../theme/theme.zig").Theme;

pub const LinkHandler = struct {
    hovered_url: ?[]const u8 = null,
    theme: *const Theme,

    pub fn init(theme: *const Theme) LinkHandler {
        return .{ .theme = theme };
    }

    /// Check if mouse is hovering over any link text runs in the tree.
    pub fn update(self: *LinkHandler, tree: *const lt.LayoutTree, scroll_y: f32) void {
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        self.hovered_url = null;

        for (tree.nodes.items) |*node| {
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

    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        // Child process: exec xdg-open
        const argv = [_:null]?[*:0]const u8{ "xdg-open", z_ptr, null };
        const envp = [_:null]?[*:0]const u8{null};
        std.posix.execvpeZ("xdg-open", &argv, &envp) catch {};
        std.posix.exit(1);
    }
    // Parent: fire and forget
}
