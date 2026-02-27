/// Application menu bar rendered at the top of the window.
///
/// Provides File (Open, Close), View (Toggle Theme), and Settings menus.
/// Owns its open/closed state and handles mouse interaction for top-level
/// items and dropdown panels. Requires raylib to be initialized before
/// calling `update()` or `draw()`.
const std = @import("std");
const rl = @import("raylib");

const Theme = @import("theme/theme.zig").Theme;
const Fonts = @import("layout/text_measurer.zig").Fonts;

pub const MenuBar = struct {
    /// Fixed height of the menu bar in pixels. Used by other modules to
    /// offset content below the bar. Intentionally not theme-configurable
    /// so that UI chrome remains consistent across themes.
    pub const bar_height: f32 = 32;
    const item_padding: f32 = 12;
    const dropdown_width: f32 = 200;
    const dropdown_item_height: f32 = 28;
    const font_size: f32 = 14;
    const shortcut_font_size: f32 = 12;

    open_menu: ?MenuId = null,

    pub const MenuId = enum { file, view, settings };

    pub const Action = enum {
        open_file,
        export_pdf,
        close_app,
        toggle_theme,
        open_settings,
    };

    const MenuItem = struct {
        label: [:0]const u8,
        shortcut: ?[:0]const u8 = null,
        action: Action,
        enabled: bool = true,
    };

    const MenuEntry = struct {
        id: MenuId,
        label: [:0]const u8,
    };

    const top_level_menus = [_]MenuEntry{
        .{ .id = .file, .label = "File" },
        .{ .id = .view, .label = "View" },
        .{ .id = .settings, .label = "Settings" },
    };

    const file_items = [_]MenuItem{
        .{ .label = "Open", .shortcut = "Ctrl+O", .action = .open_file },
        .{ .label = "Export as PDF...", .shortcut = "Ctrl+P", .action = .export_pdf },
        .{ .label = "Close", .action = .close_app },
    };

    const view_items = [_]MenuItem{
        .{ .label = "Toggle Theme", .shortcut = "T", .action = .toggle_theme },
    };

    const settings_items = [_]MenuItem{
        .{ .label = "Settings...", .action = .open_settings, .enabled = false },
    };

    pub fn init() MenuBar {
        return .{};
    }

    pub fn isOpen(self: *const MenuBar) bool {
        return self.open_menu != null;
    }

    /// Compute the X positions of each top-level menu item using font-based measurement.
    /// Used by both `update()` and `draw()` so hit-testing matches rendered positions.
    fn computeMenuPositions(fonts: *const Fonts) struct { positions: [top_level_menus.len]f32, widths: [top_level_menus.len]f32 } {
        const font = fonts.body;
        const spacing = font_size / 10.0;
        var positions: [top_level_menus.len]f32 = undefined;
        var widths: [top_level_menus.len]f32 = undefined;
        var x: f32 = item_padding;

        for (top_level_menus, 0..) |menu, i| {
            positions[i] = x;
            const measured = rl.measureTextEx(font, menu.label, font_size, spacing);
            widths[i] = measured.x + item_padding * 2;
            x += widths[i];
        }

        return .{ .positions = positions, .widths = widths };
    }

    /// Process mouse input and return the action triggered this frame, if any.
    ///
    /// Reads raylib mouse state — not a pure function. Must be called once per
    /// frame before `draw()`. The caller handles the returned action (e.g.,
    /// opening a file, toggling theme).
    pub fn update(self: *MenuBar, fonts: *const Fonts) ?Action {
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const clicked = rl.isMouseButtonPressed(.left);
        const in_bar = mouse_y >= 0 and mouse_y < bar_height;

        // Compute top-level menu positions and detect hover
        const layout = computeMenuPositions(fonts);
        var hovered_menu: ?MenuId = null;

        for (top_level_menus, 0..) |menu, i| {
            if (in_bar and mouse_x >= layout.positions[i] and mouse_x < layout.positions[i] + layout.widths[i]) {
                hovered_menu = menu.id;
            }
        }

        // Handle top-level click: toggle hovered menu, or close if clicking empty bar area
        if (clicked and in_bar) {
            self.open_menu = if (hovered_menu) |id|
                (if (self.open_menu == id) null else id)
            else
                null;
            return null;
        }

        // Hover-switch: if a menu is open and mouse hovers a different top-level item
        if (self.open_menu != null and hovered_menu != null and in_bar) {
            self.open_menu = hovered_menu;
        }

        // Handle dropdown interaction
        if (self.open_menu) |menu_id| {
            const items = menuItems(menu_id);
            const dropdown_x = layout.positions[@intFromEnum(menu_id)];
            const dropdown_y = bar_height;
            const dropdown_h = @as(f32, @floatFromInt(items.len)) * dropdown_item_height;

            if (mouse_x >= dropdown_x and mouse_x < dropdown_x + dropdown_width and
                mouse_y >= dropdown_y and mouse_y < dropdown_y + dropdown_h)
            {
                if (clicked) {
                    const item_idx: usize = @intFromFloat((mouse_y - dropdown_y) / dropdown_item_height);
                    if (item_idx < items.len and items[item_idx].enabled) {
                        self.open_menu = null;
                        return items[item_idx].action;
                    }
                }
            } else if (clicked) {
                // Click outside dropdown — close menu
                self.open_menu = null;
            }
        }

        return null;
    }

    /// Draw the menu bar and any open dropdown. Should be called after document
    /// rendering so the menu is always visually on top.
    pub fn draw(self: *const MenuBar, theme: *const Theme, fonts: *const Fonts) void {
        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const in_bar = mouse_y >= 0 and mouse_y < bar_height;

        // Bar background
        rl.drawRectangleRec(
            .{ .x = 0, .y = 0, .width = screen_w, .height = bar_height },
            theme.menu_bar_bg,
        );

        // Separator line
        rl.drawLineEx(
            .{ .x = 0, .y = bar_height - 1 },
            .{ .x = screen_w, .y = bar_height - 1 },
            1,
            theme.menu_separator,
        );

        // Top-level items
        const font = fonts.body;
        const spacing = font_size / 10.0;
        const layout = computeMenuPositions(fonts);

        for (top_level_menus, 0..) |menu, i| {
            const x = layout.positions[i];
            const item_w = layout.widths[i];

            const is_open = self.open_menu == menu.id;
            const is_hovered = in_bar and mouse_x >= x and mouse_x < x + item_w;

            // Background highlight
            const highlight_bg: ?rl.Color = if (is_open) theme.menu_active_bg else if (is_hovered) theme.menu_hover_bg else null;
            if (highlight_bg) |bg| {
                rl.drawRectangleRec(.{ .x = x, .y = 0, .width = item_w, .height = bar_height }, bg);
            }

            // Text centered vertically
            const measured = rl.measureTextEx(font, menu.label, font_size, spacing);
            const text_y = (bar_height - measured.y) / 2.0;
            rl.drawTextEx(font, menu.label, .{ .x = x + item_padding, .y = text_y }, font_size, spacing, theme.menu_text);
        }

        // Draw dropdown if open
        if (self.open_menu) |menu_id| {
            const items = menuItems(menu_id);
            const dropdown_x = layout.positions[@intFromEnum(menu_id)];
            const dropdown_y = bar_height;
            const dropdown_h = @as(f32, @floatFromInt(items.len)) * dropdown_item_height;
            const dropdown_rect: rl.Rectangle = .{
                .x = dropdown_x,
                .y = dropdown_y,
                .width = dropdown_width,
                .height = dropdown_h,
            };

            // Dropdown shadow
            rl.drawRectangleRec(
                .{ .x = dropdown_x + 2, .y = dropdown_y + 2, .width = dropdown_width, .height = dropdown_h },
                .{ .r = 0, .g = 0, .b = 0, .a = 40 },
            );

            // Dropdown background and border
            rl.drawRectangleRec(dropdown_rect, theme.menu_bar_bg);
            rl.drawRectangleLinesEx(dropdown_rect, 1, theme.menu_separator);

            // Dropdown items
            for (items, 0..) |item, j| {
                const iy = dropdown_y + @as(f32, @floatFromInt(j)) * dropdown_item_height;

                const item_hovered = mouse_x >= dropdown_x and mouse_x < dropdown_x + dropdown_width and
                    mouse_y >= iy and mouse_y < iy + dropdown_item_height;

                if (item_hovered and item.enabled) {
                    rl.drawRectangleRec(
                        .{ .x = dropdown_x, .y = iy, .width = dropdown_width, .height = dropdown_item_height },
                        theme.menu_hover_bg,
                    );
                }

                const text_color = if (item.enabled)
                    theme.menu_text
                else
                    withAlpha(theme.menu_text, 100);

                // Item label
                const label_measured = rl.measureTextEx(font, item.label, font_size, spacing);
                const label_y = iy + (dropdown_item_height - label_measured.y) / 2.0;
                rl.drawTextEx(
                    font,
                    item.label,
                    .{ .x = dropdown_x + item_padding, .y = label_y },
                    font_size,
                    spacing,
                    text_color,
                );

                // Shortcut text (right-aligned)
                if (item.shortcut) |shortcut| {
                    const sc_measured = rl.measureTextEx(font, shortcut, shortcut_font_size, spacing);
                    const sc_y = iy + (dropdown_item_height - sc_measured.y) / 2.0;
                    rl.drawTextEx(
                        font,
                        shortcut,
                        .{ .x = dropdown_x + dropdown_width - sc_measured.x - item_padding, .y = sc_y },
                        shortcut_font_size,
                        spacing,
                        withAlpha(theme.menu_text, 140),
                    );
                }
            }
        }
    }

    fn withAlpha(color: rl.Color, alpha: u8) rl.Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha };
    }

    fn menuItems(id: MenuId) []const MenuItem {
        return switch (id) {
            .file => &file_items,
            .view => &view_items,
            .settings => &settings_items,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "MenuBar init starts closed with no open menu" {
    const mb = MenuBar.init();
    try testing.expect(!mb.isOpen());
    try testing.expectEqual(@as(?MenuBar.MenuId, null), mb.open_menu);
}

test "MenuBar isOpen reflects open_menu state" {
    var mb = MenuBar.init();
    try testing.expect(!mb.isOpen());

    mb.open_menu = .file;
    try testing.expect(mb.isOpen());

    mb.open_menu = .view;
    try testing.expect(mb.isOpen());

    mb.open_menu = .settings;
    try testing.expect(mb.isOpen());

    mb.open_menu = null;
    try testing.expect(!mb.isOpen());
}

test "MenuBar menuItems returns correct item count per menu" {
    try testing.expectEqual(@as(usize, 3), MenuBar.menuItems(.file).len);
    try testing.expectEqual(@as(usize, 1), MenuBar.menuItems(.view).len);
    try testing.expectEqual(@as(usize, 1), MenuBar.menuItems(.settings).len);
}

test "MenuBar file menu items have correct actions" {
    const items = MenuBar.menuItems(.file);
    try testing.expectEqual(MenuBar.Action.open_file, items[0].action);
    try testing.expectEqual(MenuBar.Action.export_pdf, items[1].action);
    try testing.expectEqual(MenuBar.Action.close_app, items[2].action);
}

test "MenuBar export_pdf item has Ctrl+P shortcut" {
    const items = MenuBar.menuItems(.file);
    try testing.expectEqualStrings("Ctrl+P", items[1].shortcut.?);
}

test "MenuBar view menu has toggle_theme action" {
    const items = MenuBar.menuItems(.view);
    try testing.expectEqual(MenuBar.Action.toggle_theme, items[0].action);
}

test "MenuBar file and view items are all enabled" {
    for (MenuBar.menuItems(.file)) |item| {
        try testing.expect(item.enabled);
    }
    for (MenuBar.menuItems(.view)) |item| {
        try testing.expect(item.enabled);
    }
}

test "MenuBar settings menu item is disabled" {
    const items = MenuBar.menuItems(.settings);
    try testing.expect(!items[0].enabled);
}

test "MenuBar withAlpha preserves RGB and sets alpha" {
    const color = rl.Color{ .r = 10, .g = 20, .b = 30, .a = 255 };
    const result = MenuBar.withAlpha(color, 100);
    try testing.expectEqual(@as(u8, 10), result.r);
    try testing.expectEqual(@as(u8, 20), result.g);
    try testing.expectEqual(@as(u8, 30), result.b);
    try testing.expectEqual(@as(u8, 100), result.a);
}

test "MenuBar withAlpha handles zero alpha" {
    const color = rl.Color{ .r = 255, .g = 128, .b = 64, .a = 200 };
    const result = MenuBar.withAlpha(color, 0);
    try testing.expectEqual(@as(u8, 255), result.r);
    try testing.expectEqual(@as(u8, 128), result.g);
    try testing.expectEqual(@as(u8, 64), result.b);
    try testing.expectEqual(@as(u8, 0), result.a);
}

// NOTE: update() and draw() depend on raylib mouse/window state and cannot
// be unit tested without mocking raylib input. State transitions are tested
// indirectly via integration testing with a live window.
