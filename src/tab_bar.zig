const std = @import("std");
const rl = @import("raylib");

const Theme = @import("theme/theme.zig").Theme;
const Fonts = @import("layout/text_measurer.zig").Fonts;
const Tab = @import("tab.zig").Tab;
const MenuBar = @import("menu_bar.zig").MenuBar;
const text_utils = @import("utils/text_utils.zig");

pub const TabBar = struct {
    pub const bar_height: f32 = 30;
    const tab_padding: f32 = 12;
    const max_tab_width: f32 = 200;
    const min_tab_width: f32 = 80;
    const close_btn_size: f32 = 16;
    const font_size: f32 = 13;

    pub const Action = union(enum) {
        none: void,
        switch_tab: usize,
        close_tab: usize,
    };

    pub fn isVisible(tab_count: usize) bool {
        return tab_count > 1;
    }

    /// Process mouse input over the tab bar and return any action triggered.
    pub fn update(tabs: []const Tab, active_tab: usize) Action {
        const tab_count = tabs.len;
        if (!isVisible(tab_count)) return .none;

        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const clicked = rl.isMouseButtonPressed(.left);

        const bar_top = MenuBar.bar_height;
        const bar_bottom = bar_top + bar_height;

        if (mouse_y < bar_top or mouse_y >= bar_bottom) return .none;

        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
        const tab_w = computeTabWidth(tab_count, screen_w);

        const idx = @as(usize, @intFromFloat(@max(0, (mouse_x) / tab_w)));
        if (idx >= tab_count) return .none;

        if (clicked) {
            // Check if click is on the close button
            const tab_x = @as(f32, @floatFromInt(idx)) * tab_w;
            const close_x = tab_x + tab_w - close_btn_size - 4;
            if (mouse_x >= close_x and mouse_x < close_x + close_btn_size) {
                return .{ .close_tab = idx };
            }
            if (idx != active_tab) {
                return .{ .switch_tab = idx };
            }
        }

        return .none;
    }

    /// Draw the tab bar with all tabs.
    pub fn draw(tabs: []const Tab, active_tab: usize, theme: *const Theme, fonts: *const Fonts) void {
        const tab_count = tabs.len;
        if (!isVisible(tab_count)) return;

        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
        const bar_top = MenuBar.bar_height;
        const tab_w = computeTabWidth(tab_count, screen_w);
        const font = fonts.body;
        const spacing = font_size / 10.0;

        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const in_bar = mouse_y >= bar_top and mouse_y < bar_top + bar_height;

        // Bar background
        rl.drawRectangleRec(
            .{ .x = 0, .y = bar_top, .width = screen_w, .height = bar_height },
            theme.tab_bar_bg,
        );

        for (tabs, 0..) |*tab, i| {
            const fi: f32 = @floatFromInt(i);
            const tab_x = fi * tab_w;
            const is_active = i == active_tab;
            const is_hovered = in_bar and mouse_x >= tab_x and mouse_x < tab_x + tab_w;

            // Tab background
            const bg = if (is_active) theme.tab_active_bg else if (is_hovered) theme.tab_hover_bg else theme.tab_inactive_bg;
            rl.drawRectangleRec(
                .{ .x = tab_x, .y = bar_top, .width = tab_w, .height = bar_height },
                bg,
            );

            // Right border between tabs
            rl.drawLineEx(
                .{ .x = tab_x + tab_w, .y = bar_top },
                .{ .x = tab_x + tab_w, .y = bar_top + bar_height },
                1,
                theme.tab_border,
            );

            // Tab title (truncated)
            const title_text = tab.title();
            const text_color = if (is_active) theme.tab_text else theme.tab_text_inactive;
            const available_w = tab_w - tab_padding * 2 - close_btn_size - 4;

            var title_buf: [256:0]u8 = undefined;
            const truncated = text_utils.truncateText(title_text, available_w, font, font_size, spacing, &title_buf);

            const measured = rl.measureTextEx(font, truncated, font_size, spacing);
            const text_y = bar_top + (bar_height - measured.y) / 2.0;
            rl.drawTextEx(font, truncated, .{ .x = tab_x + tab_padding, .y = text_y }, font_size, spacing, text_color);

            // Close button "x"
            const close_x = tab_x + tab_w - close_btn_size - 4;
            const close_y = bar_top + (bar_height - close_btn_size) / 2.0;
            const close_hovered = is_hovered and mouse_x >= close_x and mouse_x < close_x + close_btn_size;
            const close_color = if (close_hovered) theme.tab_close_hover else theme.tab_text_inactive;

            // Draw "x" using lines
            const m: f32 = 4; // margin inside close button area
            rl.drawLineEx(
                .{ .x = close_x + m, .y = close_y + m },
                .{ .x = close_x + close_btn_size - m, .y = close_y + close_btn_size - m },
                1.5,
                close_color,
            );
            rl.drawLineEx(
                .{ .x = close_x + close_btn_size - m, .y = close_y + m },
                .{ .x = close_x + m, .y = close_y + close_btn_size - m },
                1.5,
                close_color,
            );
        }

        // Bottom border
        rl.drawLineEx(
            .{ .x = 0, .y = bar_top + bar_height - 1 },
            .{ .x = screen_w, .y = bar_top + bar_height - 1 },
            1,
            theme.tab_border,
        );
    }

    fn computeTabWidth(tab_count: usize, screen_w: f32) f32 {
        const count_f: f32 = @floatFromInt(tab_count);
        const natural = screen_w / count_f;
        return @max(min_tab_width, @min(max_tab_width, natural));
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "TabBar.isVisible returns false for 0 or 1 tabs" {
    try testing.expect(!TabBar.isVisible(0));
    try testing.expect(!TabBar.isVisible(1));
}

test "TabBar.isVisible returns true for 2+ tabs" {
    try testing.expect(TabBar.isVisible(2));
    try testing.expect(TabBar.isVisible(5));
}

test "TabBar.computeTabWidth clamps to max" {
    // 2 tabs on 1000px screen: natural = 500, clamped to max_tab_width = 200
    const w = TabBar.computeTabWidth(2, 1000);
    try testing.expectEqual(@as(f32, 200), w);
}

test "TabBar.computeTabWidth clamps to min" {
    // 100 tabs on 1000px screen: natural = 10, clamped to min_tab_width = 80
    const w = TabBar.computeTabWidth(100, 1000);
    try testing.expectEqual(@as(f32, 80), w);
}

test "TabBar.computeTabWidth uses natural width in range" {
    // 8 tabs on 1000px: natural = 125, within [80, 200]
    const w = TabBar.computeTabWidth(8, 1000);
    try testing.expectEqual(@as(f32, 125), w);
}
