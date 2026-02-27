const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const ast = @import("parser/ast.zig");
const markdown_parser = @import("parser/markdown_parser.zig");
const Theme = @import("theme/theme.zig").Theme;
const defaults = @import("theme/defaults.zig");
const Fonts = @import("layout/text_measurer.zig").Fonts;
const LayoutTree = @import("layout/layout_types.zig").LayoutTree;
const document_layout = @import("layout/document_layout.zig");
const renderer = @import("render/renderer.zig");
const LinkHandler = @import("render/link_handler.zig").LinkHandler;
const ScrollState = @import("viewport/scroll.zig").ScrollState;
const Viewport = @import("viewport/viewport.zig").Viewport;
const ImageRenderer = @import("render/image_renderer.zig").ImageRenderer;
const FileWatcher = @import("file_watcher.zig").FileWatcher;
const MenuBar = @import("menu_bar.zig").MenuBar;
const file_dialog = @import("file_dialog.zig");

pub const App = struct {
    pub const max_file_size = 10 * 1024 * 1024;
    const fade_duration: i64 = 1500;

    allocator: Allocator,
    document: ?ast.Document,
    layout_tree: ?LayoutTree,
    theme: *const Theme,
    is_dark: bool,
    fonts: ?Fonts,
    scroll: ScrollState,
    viewport: Viewport,
    link_handler: LinkHandler,
    image_renderer: ImageRenderer,
    menu_bar: MenuBar,
    /// Owned custom theme loaded from JSON (null if using built-in themes)
    custom_theme: ?Theme,
    /// File watcher for auto-reload (null if no file path set)
    file_watcher: ?FileWatcher = null,
    /// File path from CLI args (not owned)
    file_path: ?[]const u8 = null,
    /// Timestamp when last reload happened, for visual indicator
    reload_indicator_ms: i64 = 0,
    /// Whether the watched file has been deleted
    file_deleted: bool = false,

    pub fn init(allocator: Allocator) App {
        return .{
            .allocator = allocator,
            .document = null,
            .layout_tree = null,
            .theme = &defaults.light,
            .is_dark = false,
            .fonts = null,
            .scroll = .{},
            .viewport = Viewport.init(),
            .link_handler = LinkHandler.init(&defaults.light),
            .image_renderer = ImageRenderer.init(allocator),
            .menu_bar = MenuBar.init(),
            .custom_theme = null,
        };
    }

    /// Set the initial theme. If custom_theme is provided, it's stored as an owned value.
    pub fn setTheme(self: *App, custom: ?Theme, dark: bool) void {
        if (custom) |ct| {
            self.custom_theme = ct;
            self.theme = &(self.custom_theme orelse unreachable);
        } else if (dark) {
            self.is_dark = true;
            self.theme = &defaults.dark;
        } else {
            self.theme = &defaults.light;
        }
        self.link_handler.theme = self.theme;
    }

    const font_paths = .{
        .{ "body", "assets/fonts/Inter-Regular.ttf" },
        .{ "bold", "assets/fonts/Inter-Bold.ttf" },
        .{ "italic", "assets/fonts/Inter-Italic.ttf" },
        .{ "bold_italic", "assets/fonts/Inter-BoldItalic.ttf" },
        .{ "mono", "assets/fonts/JetBrainsMono-Regular.ttf" },
    };

    pub fn loadFonts(self: *App) !void {
        const size = 32; // Load at high size, scale down when rendering
        var fonts: Fonts = undefined;
        var loaded_count: usize = 0;
        errdefer {
            // Unload any fonts that were successfully loaded before the failure
            var unload_idx: usize = 0;
            inline for (font_paths) |entry| {
                if (unload_idx >= loaded_count) break;
                rl.unloadFont(@field(fonts, entry[0]));
                unload_idx += 1;
            }
        }
        inline for (font_paths) |entry| {
            @field(fonts, entry[0]) = try rl.loadFontEx(entry[1], size, null);
            rl.setTextureFilter(@field(fonts, entry[0]).texture, .bilinear);
            loaded_count += 1;
        }
        self.fonts = fonts;
    }

    pub fn unloadFonts(self: *App) void {
        const fonts = self.fonts orelse return;
        inline for (font_paths) |entry| {
            rl.unloadFont(@field(fonts, entry[0]));
        }
        self.fonts = null;
    }

    pub fn setBaseDir(self: *App, path: []const u8) Allocator.Error!void {
        try self.image_renderer.setBaseDir(path);
    }

    pub fn loadMarkdown(self: *App, text: []const u8) !void {
        // Parse into local first — if parse fails, old document is preserved
        const new_doc = try markdown_parser.parse(self.allocator, text);

        // Parse succeeded — destroy old state and swap in new document.
        // From here, self owns new_doc, so no errdefer (relayout failure is non-fatal).
        if (self.layout_tree) |*tree| tree.deinit();
        self.layout_tree = null;
        if (self.document) |*doc| doc.deinit();
        self.document = new_doc;

        // Best-effort layout — document is valid even if layout fails
        self.relayout() catch |err| {
            std.log.err("Failed to layout document: {}", .{err});
        };
    }

    /// Set the file path and start watching for changes
    pub fn setFilePath(self: *App, path: []const u8) void {
        self.file_path = path;
        self.file_watcher = FileWatcher.init(path);
    }

    /// Reload the markdown file from disk, preserving scroll position
    fn reloadFromDisk(self: *App) void {
        const path = self.file_path orelse return;

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, max_file_size) catch |err| {
            std.log.err("Failed to reload file '{s}': {}", .{ path, err });
            return;
        };
        defer self.allocator.free(content);

        const saved_scroll_y = self.scroll.y;

        self.loadMarkdown(content) catch |err| {
            std.log.err("Failed to parse reloaded markdown: {}", .{err});
            return;
        };

        // Restore scroll position, clamped to new document height
        self.scroll.y = saved_scroll_y;
        self.scroll.clamp();

        self.reload_indicator_ms = std.time.milliTimestamp();
        self.file_deleted = false;
    }

    /// Open a native file dialog and load the selected markdown file.
    /// NOTE: Blocks the render loop while the dialog is open — the window will
    /// be unresponsive until the user selects a file or cancels.
    fn openFileDialog(self: *App) void {
        const selected = file_dialog.openFileDialog(self.allocator) catch |err| {
            std.log.err("File dialog error: {}", .{err});
            return;
        } orelse return; // User cancelled
        defer self.allocator.free(selected);

        const content = std.fs.cwd().readFileAlloc(self.allocator, selected, max_file_size) catch |err| {
            std.log.err("Failed to read file '{s}': {}", .{ selected, err });
            return;
        };
        defer self.allocator.free(content);

        // Set base dir for relative image paths
        const dir = std.fs.path.dirname(selected) orelse ".";
        self.setBaseDir(dir) catch |err| {
            std.log.err("Failed to set base dir: {}", .{err});
        };

        self.loadMarkdown(content) catch |err| {
            std.log.err("Failed to parse markdown from '{s}': {}", .{ selected, err });
            return;
        };

        // Reset scroll to top for new file
        self.scroll.y = 0;

        // Disable file watching for dialog-opened files (we don't own the path long-term)
        if (self.file_watcher) |*watcher| {
            watcher.deinit();
            self.file_watcher = null;
        }
        self.file_path = null;

        // Update window title with filename
        const basename = std.fs.path.basename(selected);
        var title_buf: [256:0]u8 = undefined;
        const title = std.fmt.bufPrintZ(&title_buf, "Selkie \xe2\x80\x94 {s}", .{basename}) catch "Selkie";
        rl.setWindowTitle(title);
    }

    pub fn relayout(self: *App) !void {
        if (self.layout_tree) |*tree| tree.deinit();
        self.layout_tree = null;

        const doc = &(self.document orelse return);
        const fonts = &(self.fonts orelse return);
        const tree = try document_layout.layout(
            self.allocator,
            doc,
            self.theme,
            fonts,
            self.viewport.width,
            &self.image_renderer,
            MenuBar.bar_height,
        );
        self.scroll.total_height = tree.total_height;
        self.layout_tree = tree;
    }

    pub fn toggleTheme(self: *App) void {
        if (self.custom_theme) |*ct| {
            // Toggle between custom theme and built-in dark
            self.theme = if (self.theme == ct) &defaults.dark else ct;
        } else {
            self.is_dark = !self.is_dark;
            self.theme = if (self.is_dark) &defaults.dark else &defaults.light;
        }
        self.link_handler.theme = self.theme;
        // Best-effort relayout — failure here is non-fatal since the old layout remains visible
        self.relayout() catch |err| {
            std.log.err("Failed to relayout after theme toggle: {}", .{err});
        };
    }

    pub fn update(self: *App) void {
        const fonts = self.fonts orelse return;

        // Menu bar gets first crack at input
        const menu_action = self.menu_bar.update(&fonts);
        const menu_is_open = self.menu_bar.isOpen();

        if (menu_action) |action| {
            switch (action) {
                .open_file => self.openFileDialog(),
                .close_app => rl.closeWindow(),
                .toggle_theme => self.toggleTheme(),
                .open_settings => std.log.info("Settings not yet implemented", .{}),
            }
        }

        // Keyboard shortcuts — suppressed when menu is open to avoid confusing UX
        if (!menu_is_open) {
            if (rl.isKeyPressed(.t)) {
                self.toggleTheme();
            }
            if (rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control)) {
                if (rl.isKeyPressed(.o)) {
                    self.openFileDialog();
                }
            }
        }

        // Only process scroll/link input when menu is closed
        if (!menu_is_open) {
            self.scroll.update();
        }

        // Expire reload indicator (state mutation belongs in update, not draw)
        if (self.reload_indicator_ms != 0) {
            const elapsed = std.time.milliTimestamp() - self.reload_indicator_ms;
            if (elapsed >= fade_duration) {
                self.reload_indicator_ms = 0;
            }
        }

        // Re-layout on window resize (best-effort — old layout remains usable on failure)
        if (self.viewport.updateSize()) {
            self.relayout() catch |err| {
                std.log.err("Failed to relayout after window resize: {}", .{err});
            };
        }

        // Check for file changes
        if (self.file_watcher) |*watcher| {
            switch (watcher.checkForChanges()) {
                .file_changed => self.reloadFromDisk(),
                .file_deleted => {
                    self.file_deleted = true;
                    self.reload_indicator_ms = std.time.milliTimestamp();
                },
                .no_change => {},
            }
        }

        if (self.layout_tree) |*tree| {
            const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
            self.link_handler.update(tree, self.scroll.y, screen_h);
            // Don't process link clicks when menu is open or mouse is over menu bar
            const mouse_y: f32 = @floatFromInt(rl.getMouseY());
            if (!menu_is_open and mouse_y >= MenuBar.bar_height) {
                self.link_handler.handleClick();
            }
        }
    }

    pub fn draw(self: *App) void {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(self.theme.background);

        const fonts_val = self.fonts orelse return;

        if (self.layout_tree) |*tree| {
            renderer.render(tree, self.theme, &fonts_val, self.scroll.y, MenuBar.bar_height);
        } else {
            const y_offset: i32 = @intFromFloat(MenuBar.bar_height + 8);
            rl.drawText("No document loaded. Usage: selkie <file.md>", 20, y_offset, 20, self.theme.text);
        }

        // Draw reload/deletion indicator (below menu bar)
        self.drawReloadIndicator();

        // Menu bar drawn last so it's always on top
        self.menu_bar.draw(self.theme, &fonts_val);
    }

    fn drawReloadIndicator(self: *const App) void {
        if (self.reload_indicator_ms == 0) return;

        const elapsed = std.time.milliTimestamp() - self.reload_indicator_ms;
        if (elapsed >= fade_duration) return;

        const t: f32 = @floatFromInt(elapsed);
        const d: f32 = @floatFromInt(fade_duration);
        const alpha: u8 = @intFromFloat((1.0 - t / d) * 255.0);

        const text: [:0]const u8 = if (self.file_deleted) "File deleted" else "Reloaded";
        const color: rl.Color = if (self.file_deleted)
            .{ .r = 220, .g = 60, .b = 60, .a = alpha }
        else
            .{ .r = self.theme.text.r, .g = self.theme.text.g, .b = self.theme.text.b, .a = alpha };

        const font_size: i32 = 16;
        const screen_w = rl.getScreenWidth();
        const text_w = rl.measureText(text, font_size);
        const indicator_y: i32 = @intFromFloat(MenuBar.bar_height + 8);
        rl.drawText(text, screen_w - text_w - 16, indicator_y, font_size, color);
    }

    pub fn deinit(self: *App) void {
        if (self.file_watcher) |*watcher| watcher.deinit();
        if (self.layout_tree) |*tree| tree.deinit();
        if (self.document) |*doc| doc.deinit();
        self.image_renderer.deinit();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "App.init returns correct default state" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try testing.expectEqual(@as(?ast.Document, null), app.document);
    try testing.expectEqual(@as(?LayoutTree, null), app.layout_tree);
    try testing.expect(!app.is_dark);
    try testing.expectEqual(@as(?Fonts, null), app.fonts);
    try testing.expectEqual(@as(f32, 0), app.scroll.y);
    try testing.expect(!app.menu_bar.isOpen());
    try testing.expectEqual(@as(?Theme, null), app.custom_theme);
    try testing.expectEqual(@as(?FileWatcher, null), app.file_watcher);
    try testing.expectEqual(@as(?[]const u8, null), app.file_path);
    try testing.expectEqual(@as(i64, 0), app.reload_indicator_ms);
    try testing.expect(!app.file_deleted);
}

test "App.init uses light theme by default" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // Default theme should be light
    try testing.expectEqual(defaults.light.background.r, app.theme.background.r);
    try testing.expectEqual(defaults.light.background.g, app.theme.background.g);
    try testing.expectEqual(defaults.light.background.b, app.theme.background.b);
}

test "App.setTheme selects dark theme" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    app.setTheme(null, true);

    try testing.expect(app.is_dark);
    try testing.expectEqual(defaults.dark.background.r, app.theme.background.r);
    try testing.expectEqual(defaults.dark.background.g, app.theme.background.g);
    try testing.expectEqual(defaults.dark.background.b, app.theme.background.b);
    // link_handler should also be updated
    try testing.expectEqual(defaults.dark.link.r, app.link_handler.theme.link.r);
}

test "App.setTheme with custom theme stores it" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    var custom = defaults.light;
    custom.background = .{ .r = 1, .g = 2, .b = 3, .a = 255 };

    app.setTheme(custom, false);

    try testing.expect(app.custom_theme != null);
    try testing.expectEqual(@as(u8, 1), app.theme.background.r);
    try testing.expectEqual(@as(u8, 2), app.theme.background.g);
    try testing.expectEqual(@as(u8, 3), app.theme.background.b);
}

test "App.setTheme with light sets light theme" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // setTheme(null, false) selects light theme
    app.setTheme(null, false);
    try testing.expectEqual(defaults.light.background.r, app.theme.background.r);
    try testing.expectEqual(defaults.light.background.g, app.theme.background.g);
    try testing.expectEqual(defaults.light.link.r, app.link_handler.theme.link.r);
}

test "App.toggleTheme switches between light and dark" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // Start light
    try testing.expect(!app.is_dark);
    try testing.expectEqual(defaults.light.background.r, app.theme.background.r);

    // Toggle to dark
    app.toggleTheme();
    try testing.expect(app.is_dark);
    try testing.expectEqual(defaults.dark.background.r, app.theme.background.r);
    try testing.expectEqual(defaults.dark.link.r, app.link_handler.theme.link.r);

    // Toggle back to light
    app.toggleTheme();
    try testing.expect(!app.is_dark);
    try testing.expectEqual(defaults.light.background.r, app.theme.background.r);
}

test "App.deinit cleans up without leaks" {
    // testing.allocator will detect any leaks
    var app = App.init(testing.allocator);
    app.deinit();
}

// NOTE: loadMarkdown(), relayout(), update(), draw(), openFileDialog() depend
// on cmark-gfm, raylib fonts/window, or external processes and cannot be
// meaningfully unit tested. They require integration testing.
