const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const LayoutTree = @import("layout/layout_types.zig").LayoutTree;
const Theme = @import("theme/theme.zig").Theme;
const Fonts = @import("layout/text_measurer.zig").Fonts;
const text_utils = @import("utils/text_utils.zig");

pub const TocEntry = struct {
    level: u8,
    text: []const u8, // owned by entry_arena
    y: f32, // y position in the document (world coordinates)
};

pub const TocSidebar = struct {
    pub const sidebar_width: f32 = 240;
    const entry_height: f32 = 28;
    const padding: f32 = 8;
    const font_size: f32 = 13;
    const indent_per_level: f32 = 16;

    allocator: Allocator,
    is_open: bool,
    entries: std.ArrayList(TocEntry),
    entry_arena: std.heap.ArenaAllocator,
    scroll_y: f32,
    active_entry: ?usize,

    pub const Action = union(enum) {
        none: void,
        scroll_to: f32,
    };

    pub fn init(allocator: Allocator) TocSidebar {
        return .{
            .allocator = allocator,
            .is_open = false,
            .entries = std.ArrayList(TocEntry).init(allocator),
            .entry_arena = std.heap.ArenaAllocator.init(allocator),
            .scroll_y = 0,
            .active_entry = null,
        };
    }

    pub fn deinit(self: *TocSidebar) void {
        self.entries.deinit();
        self.entry_arena.deinit();
    }

    pub fn toggle(self: *TocSidebar) void {
        self.is_open = !self.is_open;
    }

    pub fn effectiveWidth(self: *const TocSidebar) f32 {
        return if (self.is_open) sidebar_width else 0;
    }

    /// Clear existing entries and re-extract headings from the layout tree.
    pub fn rebuild(self: *TocSidebar, tree: *const LayoutTree) void {
        self.entries.clearRetainingCapacity();
        _ = self.entry_arena.reset(.retain_capacity);

        const arena_alloc = self.entry_arena.allocator();
        var logged_oom = false;

        for (tree.nodes.items) |*node| {
            switch (node.data) {
                .heading => |h| {
                    // Collect text from text runs (use arena for temp list too)
                    var text_parts = std.ArrayList([]const u8).init(arena_alloc);
                    for (node.text_runs.items) |*run| {
                        text_parts.append(run.text) catch {
                            if (!logged_oom) {
                                std.log.warn("ToC: allocation failure, some headings may be missing", .{});
                                logged_oom = true;
                            }
                            continue;
                        };
                    }
                    const joined = std.mem.concat(arena_alloc, u8, text_parts.items) catch continue;

                    self.entries.append(.{
                        .level = h.level,
                        .text = joined,
                        .y = node.rect.y,
                    }) catch continue;
                },
                else => {},
            }
        }
    }

    /// Handle mouse interaction and track the active heading based on scroll position.
    pub fn update(self: *TocSidebar, doc_scroll_y: f32, content_top_y: f32) Action {
        if (!self.is_open) return .none;

        // Update active entry based on document scroll position
        self.active_entry = null;
        for (self.entries.items, 0..) |entry, i| {
            if (entry.y <= doc_scroll_y + content_top_y + 50) {
                self.active_entry = i;
            }
        }

        // Handle mouse interaction
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());

        if (mouse_x >= sidebar_width) return .none;
        if (mouse_y < content_top_y) return .none;

        // Sidebar scroll with mouse wheel
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            self.scroll_y -= wheel * 30;
            const max_scroll = self.maxScroll(content_top_y);
            self.scroll_y = @max(0, @min(self.scroll_y, max_scroll));
        }

        // Click on an entry
        if (rl.isMouseButtonPressed(.left)) {
            const relative_y = mouse_y - content_top_y + self.scroll_y;
            const idx = @as(usize, @intFromFloat(@max(0, relative_y / entry_height)));
            if (idx < self.entries.items.len) {
                // Scroll the document so the heading is near the top
                const heading_y = self.entries.items[idx].y;
                return .{ .scroll_to = heading_y - content_top_y - 10 };
            }
        }

        return .none;
    }

    /// Draw the sidebar.
    pub fn draw(self: *const TocSidebar, theme: *const Theme, fonts: *const Fonts, content_top_y: f32) void {
        if (!self.is_open) return;

        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());

        // Background
        rl.drawRectangleRec(
            .{ .x = 0, .y = content_top_y, .width = sidebar_width, .height = screen_h - content_top_y },
            theme.sidebar_bg,
        );

        // Right border
        rl.drawLineEx(
            .{ .x = sidebar_width - 1, .y = content_top_y },
            .{ .x = sidebar_width - 1, .y = screen_h },
            1,
            theme.sidebar_border,
        );

        // Clip to sidebar area
        rl.beginScissorMode(
            0,
            @intFromFloat(content_top_y),
            @intFromFloat(sidebar_width - 1),
            @intFromFloat(screen_h - content_top_y),
        );
        defer rl.endScissorMode();

        const font = fonts.body;
        const spacing = font_size / 10.0;

        for (self.entries.items, 0..) |entry, i| {
            const fi: f32 = @floatFromInt(i);
            const entry_y = content_top_y + fi * entry_height - self.scroll_y;

            // Skip entries outside visible area
            if (entry_y + entry_height < content_top_y) continue;
            if (entry_y > screen_h) break;

            const is_active = if (self.active_entry) |a| a == i else false;
            const is_hovered = mouse_x < sidebar_width and mouse_y >= entry_y and mouse_y < entry_y + entry_height;

            // Highlight background
            if (is_active) {
                rl.drawRectangleRec(
                    .{ .x = 0, .y = entry_y, .width = sidebar_width - 1, .height = entry_height },
                    theme.sidebar_active_bg,
                );
            } else if (is_hovered) {
                rl.drawRectangleRec(
                    .{ .x = 0, .y = entry_y, .width = sidebar_width - 1, .height = entry_height },
                    theme.sidebar_hover_bg,
                );
            }

            // Indent lines for nested headings
            const level = @min(entry.level, 6);
            if (level > 1) {
                const indent_x = padding + @as(f32, @floatFromInt(level - 2)) * indent_per_level + 4;
                rl.drawLineEx(
                    .{ .x = indent_x, .y = entry_y + 4 },
                    .{ .x = indent_x, .y = entry_y + entry_height - 4 },
                    1,
                    theme.sidebar_indent_line,
                );
            }

            // Entry text
            const indent = padding + @as(f32, @floatFromInt(@min(level -| 1, 5))) * indent_per_level;

            // Truncate and null-terminate text for drawing
            const available_w = sidebar_width - indent - padding;
            var text_buf: [256:0]u8 = undefined;
            const display_text = text_utils.truncateText(entry.text, available_w, font, font_size, spacing, &text_buf);

            const measured = rl.measureTextEx(font, display_text, font_size, spacing);
            const text_y = entry_y + (entry_height - measured.y) / 2.0;
            rl.drawTextEx(font, display_text, .{ .x = indent, .y = text_y }, font_size, spacing, theme.sidebar_text);
        }
    }

    fn maxScroll(self: *const TocSidebar, content_top_y: f32) f32 {
        const total = @as(f32, @floatFromInt(self.entries.items.len)) * entry_height;
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        const visible = screen_h - content_top_y;
        return @max(0, total - visible);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "TocSidebar.init starts closed with no entries" {
    var sidebar = TocSidebar.init(testing.allocator);
    defer sidebar.deinit();

    try testing.expect(!sidebar.is_open);
    try testing.expectEqual(@as(usize, 0), sidebar.entries.items.len);
    try testing.expectEqual(@as(f32, 0), sidebar.effectiveWidth());
}

test "TocSidebar.toggle toggles open state" {
    var sidebar = TocSidebar.init(testing.allocator);
    defer sidebar.deinit();

    sidebar.toggle();
    try testing.expect(sidebar.is_open);
    try testing.expectEqual(TocSidebar.sidebar_width, sidebar.effectiveWidth());

    sidebar.toggle();
    try testing.expect(!sidebar.is_open);
    try testing.expectEqual(@as(f32, 0), sidebar.effectiveWidth());
}

test "TocSidebar.effectiveWidth returns 0 when closed" {
    var sidebar = TocSidebar.init(testing.allocator);
    defer sidebar.deinit();

    try testing.expectEqual(@as(f32, 0), sidebar.effectiveWidth());
}

test "TocSidebar.effectiveWidth returns sidebar_width when open" {
    var sidebar = TocSidebar.init(testing.allocator);
    defer sidebar.deinit();
    sidebar.is_open = true;

    try testing.expectEqual(TocSidebar.sidebar_width, sidebar.effectiveWidth());
}

test "TocSidebar.deinit cleans up without leaks" {
    var sidebar = TocSidebar.init(testing.allocator);
    sidebar.deinit();
}

const layout_types = @import("layout/layout_types.zig");

fn makeHeadingNode(allocator: std.mem.Allocator, level: u8, text: []const u8, y: f32) !layout_types.LayoutNode {
    var node = layout_types.LayoutNode.init(allocator, .{ .heading = .{ .level = level } });
    node.rect.y = y;
    try node.text_runs.append(.{
        .text = text,
        .style = .{ .font_size = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        .rect = .{ .x = 0, .y = y, .width = 100, .height = 20 },
    });
    return node;
}

test "TocSidebar.rebuild extracts headings from layout tree" {
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    const h1 = try makeHeadingNode(testing.allocator, 1, "Introduction", 100);
    try tree.nodes.append(h1);

    const para = layout_types.LayoutNode.init(testing.allocator, .text_block);
    try tree.nodes.append(para);

    const h2 = try makeHeadingNode(testing.allocator, 2, "Details", 300);
    try tree.nodes.append(h2);

    var sidebar = TocSidebar.init(testing.allocator);
    defer sidebar.deinit();

    sidebar.rebuild(&tree);

    try testing.expectEqual(@as(usize, 2), sidebar.entries.items.len);
    try testing.expectEqual(@as(u8, 1), sidebar.entries.items[0].level);
    try testing.expectEqualStrings("Introduction", sidebar.entries.items[0].text);
    try testing.expectEqual(@as(f32, 100), sidebar.entries.items[0].y);
    try testing.expectEqual(@as(u8, 2), sidebar.entries.items[1].level);
    try testing.expectEqualStrings("Details", sidebar.entries.items[1].text);
    try testing.expectEqual(@as(f32, 300), sidebar.entries.items[1].y);
}

test "TocSidebar.rebuild with empty tree produces no entries" {
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    var sidebar = TocSidebar.init(testing.allocator);
    defer sidebar.deinit();

    sidebar.rebuild(&tree);
    try testing.expectEqual(@as(usize, 0), sidebar.entries.items.len);
}

test "TocSidebar.rebuild clears previous entries" {
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    const h1 = try makeHeadingNode(testing.allocator, 1, "First", 50);
    try tree.nodes.append(h1);

    var sidebar = TocSidebar.init(testing.allocator);
    defer sidebar.deinit();

    sidebar.rebuild(&tree);
    try testing.expectEqual(@as(usize, 1), sidebar.entries.items.len);

    // Rebuild with empty tree — should clear
    var empty_tree = layout_types.LayoutTree.init(testing.allocator);
    defer empty_tree.deinit();

    sidebar.rebuild(&empty_tree);
    try testing.expectEqual(@as(usize, 0), sidebar.entries.items.len);
}

test "TocSidebar.rebuild joins multiple text runs in a heading" {
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    const style = layout_types.TextStyle{ .font_size = 16, .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 } };
    const rect = layout_types.Rect{ .x = 0, .y = 0, .width = 50, .height = 20 };

    var node = layout_types.LayoutNode.init(testing.allocator, .{ .heading = .{ .level = 3 } });
    node.rect.y = 200;
    try node.text_runs.append(.{ .text = "Hello ", .style = style, .rect = rect });
    try node.text_runs.append(.{ .text = "World", .style = style, .rect = rect });
    try tree.nodes.append(node);

    var sidebar = TocSidebar.init(testing.allocator);
    defer sidebar.deinit();

    sidebar.rebuild(&tree);
    try testing.expectEqual(@as(usize, 1), sidebar.entries.items.len);
    try testing.expectEqualStrings("Hello World", sidebar.entries.items[0].text);
    try testing.expectEqual(@as(u8, 3), sidebar.entries.items[0].level);
}
