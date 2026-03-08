const std = @import("std");
const rl = @import("raylib");
const layout_types = @import("../layout/layout_types.zig");
const LayoutTree = layout_types.LayoutTree;
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
    pub fn update(self: *LinkHandler, tree: *const LayoutTree, scroll_y: f32, screen_h: f32) void {
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

    /// Handle click: if mouse was released on a link, open it or scroll to anchor.
    /// Returns a scroll target y-position when the link is an in-document anchor
    /// (e.g., "#fn-1" for footnotes), or null for external links.
    pub fn handleClick(self: *LinkHandler, tree: *const LayoutTree) ?f32 {
        if (rl.isMouseButtonReleased(.left)) {
            if (self.hovered_url) |url| {
                // In-document anchor links (e.g., "#fn-1") scroll to the target node
                if (std.mem.startsWith(u8, url, "#")) {
                    return resolveAnchor(tree, url[1..]);
                }
                openUrl(url);
            }
        }
        return null;
    }

    /// Find the y-position of a layout node with a matching anchor_id.
    /// Returns the node's y coordinate for scrolling, or null if not found.
    pub fn resolveAnchor(tree: *const LayoutTree, anchor_id: []const u8) ?f32 {
        if (anchor_id.len == 0) return null;
        for (tree.nodes.items) |*node| {
            if (node.anchor_id) |id| {
                if (std.mem.eql(u8, id, anchor_id)) {
                    return node.rect.y;
                }
            }
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "resolveAnchor finds node by anchor_id" {
    var tree = LayoutTree.init(testing.allocator);
    defer tree.deinit();

    // Add a node with an anchor_id
    var node = layout_types.LayoutNode.init(testing.allocator, .text_block);
    node.rect = .{ .x = 0, .y = 500, .width = 100, .height = 20 };
    node.anchor_id = "fn-1";
    try tree.nodes.append(node);

    const result = LinkHandler.resolveAnchor(&tree, "fn-1");
    try testing.expect(result != null);
    try testing.expectEqual(@as(f32, 500), result.?);
}

test "resolveAnchor returns null for unknown anchor" {
    var tree = LayoutTree.init(testing.allocator);
    defer tree.deinit();

    var node = layout_types.LayoutNode.init(testing.allocator, .text_block);
    node.anchor_id = "fn-1";
    try tree.nodes.append(node);

    const result = LinkHandler.resolveAnchor(&tree, "fn-99");
    try testing.expectEqual(null, result);
}

test "resolveAnchor returns null for empty anchor_id" {
    var tree = LayoutTree.init(testing.allocator);
    defer tree.deinit();

    const result = LinkHandler.resolveAnchor(&tree, "");
    try testing.expectEqual(null, result);
}

test "resolveAnchor skips nodes without anchor_id" {
    var tree = LayoutTree.init(testing.allocator);
    defer tree.deinit();

    // Node without anchor
    var node1 = layout_types.LayoutNode.init(testing.allocator, .text_block);
    node1.rect = .{ .x = 0, .y = 100, .width = 100, .height = 20 };
    try tree.nodes.append(node1);

    // Node with matching anchor
    var node2 = layout_types.LayoutNode.init(testing.allocator, .text_block);
    node2.rect = .{ .x = 0, .y = 800, .width = 100, .height = 20 };
    node2.anchor_id = "fn-2";
    try tree.nodes.append(node2);

    const result = LinkHandler.resolveAnchor(&tree, "fn-2");
    try testing.expect(result != null);
    try testing.expectEqual(@as(f32, 800), result.?);
}

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
