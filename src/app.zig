const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const asset_paths = @import("asset_paths.zig");
const ast = @import("parser/ast.zig");
const Theme = @import("theme/theme.zig").Theme;
const defaults = @import("theme/defaults.zig");
const Fonts = @import("layout/text_measurer.zig").Fonts;
const LayoutTree = @import("layout/layout_types.zig").LayoutTree;
const renderer = @import("render/renderer.zig");
const ScrollState = @import("viewport/scroll.zig").ScrollState;
const Viewport = @import("viewport/viewport.zig").Viewport;
const MenuBar = @import("menu_bar.zig").MenuBar;
const TabBar = @import("tab_bar.zig").TabBar;
const Tab = @import("tab.zig").Tab;
const TocSidebar = @import("toc_sidebar.zig").TocSidebar;
const file_dialog = @import("file_dialog.zig");
const pdf_exporter = @import("export/pdf_exporter.zig");
const save_dialog = @import("export/save_dialog.zig");
const searcher = @import("search/searcher.zig");
const search_renderer = @import("render/search_renderer.zig");

pub const App = struct {
    pub const max_file_size = 10 * 1024 * 1024;
    const fade_duration: i64 = 1500;

    allocator: Allocator,
    theme: *const Theme,
    is_dark: bool,
    fonts: ?Fonts,
    viewport: Viewport,
    menu_bar: MenuBar,
    /// Owned custom theme loaded from JSON (null if using built-in themes)
    custom_theme: ?Theme,

    // Tab management
    tabs: std.ArrayList(Tab),
    active_tab: usize,

    // ToC sidebar (shared across all tabs — shows headings for active tab)
    toc_sidebar: TocSidebar,

    pub fn init(allocator: Allocator) App {
        return .{
            .allocator = allocator,
            .theme = &defaults.light,
            .is_dark = false,
            .fonts = null,
            .viewport = Viewport.init(),
            .menu_bar = MenuBar.init(),
            .custom_theme = null,
            .tabs = std.ArrayList(Tab).init(allocator),
            .active_tab = 0,
            .toc_sidebar = TocSidebar.init(allocator),
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
        // Update link handlers on all existing tabs
        for (self.tabs.items) |*tab| {
            tab.link_handler.theme = self.theme;
        }
    }

    const font_files = .{
        .{ "body", "fonts/Inter-Regular.ttf" },
        .{ "bold", "fonts/Inter-Bold.ttf" },
        .{ "italic", "fonts/Inter-Italic.ttf" },
        .{ "bold_italic", "fonts/Inter-BoldItalic.ttf" },
        .{ "mono", "fonts/JetBrainsMono-Regular.ttf" },
    };

    pub fn loadFonts(self: *App) !void {
        const size = 32;
        var fonts: Fonts = undefined;
        var loaded_count: usize = 0;

        // Resolve and store paths so we can free them after loading
        var resolved: [font_files.len][:0]const u8 = undefined;
        var resolved_count: usize = 0;
        defer for (resolved[0..resolved_count]) |p| self.allocator.free(p);

        errdefer {
            var unload_idx: usize = 0;
            inline for (font_files) |entry| {
                if (unload_idx >= loaded_count) break;
                rl.unloadFont(@field(fonts, entry[0]));
                unload_idx += 1;
            }
        }

        inline for (font_files, 0..) |entry, idx| {
            const path = try asset_paths.resolveAssetPath(self.allocator, entry[1]);
            resolved[idx] = path;
            resolved_count = idx + 1;

            @field(fonts, entry[0]) = try rl.loadFontEx(path, size, null);
            rl.setTextureFilter(@field(fonts, entry[0]).texture, .bilinear);
            loaded_count += 1;
        }
        self.fonts = fonts;
    }

    pub fn unloadFonts(self: *App) void {
        const fonts = self.fonts orelse return;
        inline for (font_files) |entry| {
            rl.unloadFont(@field(fonts, entry[0]));
        }
        self.fonts = null;
    }

    // =========================================================================
    // Tab management
    // =========================================================================

    pub fn activeTab(self: *App) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[self.active_tab];
    }

    pub fn newTab(self: *App) !*Tab {
        var tab = Tab.init(self.allocator);
        tab.link_handler.theme = self.theme;
        try self.tabs.append(tab);
        self.active_tab = self.tabs.items.len - 1;
        return &self.tabs.items[self.active_tab];
    }

    pub fn newTabWithFile(self: *App, path: []const u8) !void {
        const tab = try self.newTab();

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, max_file_size) catch |err| {
            std.log.err("Failed to read file '{s}': {}", .{ path, err });
            return;
        };
        defer self.allocator.free(content);

        const dir = std.fs.path.dirname(path) orelse ".";
        tab.setBaseDir(dir) catch |err| {
            std.log.err("Failed to set base dir: {}", .{err});
        };
        tab.setFilePath(path) catch |err| {
            std.log.err("Failed to set file path: {}", .{err});
        };

        tab.loadMarkdown(content) catch |err| {
            std.log.err("Failed to parse markdown from '{s}': {}", .{ path, err });
            return;
        };

        if (self.fonts) |*f| {
            tab.relayout(self.theme, f, self.computeLayoutWidth(), self.computeContentYOffset()) catch |err| {
                std.log.err("Failed to layout document: {}", .{err});
            };
        }

        self.updateWindowTitle();
        self.rebuildToc();
    }

    pub fn closeTab(self: *App, index: usize) void {
        if (self.tabs.items.len <= 1) return; // Don't close last tab
        if (index >= self.tabs.items.len) return;

        var tab = self.tabs.orderedRemove(index);
        tab.deinit();

        if (self.active_tab >= self.tabs.items.len) {
            self.active_tab = self.tabs.items.len - 1;
        } else if (self.active_tab > index) {
            self.active_tab -= 1;
        }

        self.updateWindowTitle();
        self.rebuildToc();
    }

    pub fn cycleTab(self: *App, delta: i32) void {
        if (self.tabs.items.len <= 1) return;
        const len: i32 = @intCast(self.tabs.items.len);
        const current: i32 = @intCast(self.active_tab);
        self.active_tab = @intCast(@mod(current + delta, len));
        self.updateWindowTitle();
        self.rebuildToc();
    }

    fn switchToTab(self: *App, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.active_tab = index;
        self.updateWindowTitle();
        self.rebuildToc();
    }

    fn updateWindowTitle(self: *App) void {
        const tab = self.activeTab() orelse return;
        const name = tab.title();
        var title_buf: [256:0]u8 = undefined;
        const title = std.fmt.bufPrintZ(&title_buf, "Selkie \xe2\x80\x94 {s}", .{name}) catch "Selkie";
        // Only call raylib if a window is open (avoids crash in unit tests)
        if (rl.isWindowReady()) {
            rl.setWindowTitle(title);
        }
    }

    // =========================================================================
    // Layout geometry
    // =========================================================================

    pub fn computeContentYOffset(self: *const App) f32 {
        var y = MenuBar.bar_height;
        if (TabBar.isVisible(self.tabs.items.len)) {
            y += TabBar.bar_height;
        }
        return y;
    }

    pub fn computeLayoutWidth(self: *const App) f32 {
        return self.viewport.width - self.toc_sidebar.effectiveWidth();
    }

    // =========================================================================
    // Document operations (delegate to active tab)
    // =========================================================================

    pub fn loadMarkdown(self: *App, text: []const u8) !void {
        const tab = self.activeTab() orelse return;
        try tab.loadMarkdown(text);
        self.relayoutActiveTab();
    }

    fn relayoutActiveTab(self: *App) void {
        const tab = self.activeTab() orelse return;
        const fonts = &(self.fonts orelse return);
        tab.relayout(self.theme, fonts, self.computeLayoutWidth(), self.computeContentYOffset()) catch |err| {
            std.log.err("Failed to relayout: {}", .{err});
        };
        self.rebuildToc();
    }

    fn relayoutAllTabs(self: *App) void {
        const fonts = &(self.fonts orelse return);
        const width = self.computeLayoutWidth();
        const y_offset = self.computeContentYOffset();
        for (self.tabs.items) |*tab| {
            tab.relayout(self.theme, fonts, width, y_offset) catch |err| {
                std.log.err("Failed to relayout tab: {}", .{err});
            };
        }
        self.rebuildToc();
    }

    fn rebuildToc(self: *App) void {
        const tab = self.activeTab() orelse return;
        if (tab.layout_tree) |*tree| {
            self.toc_sidebar.rebuild(tree);
        }
    }

    pub fn toggleTheme(self: *App) void {
        if (self.custom_theme) |*ct| {
            self.theme = if (self.theme == ct) &defaults.dark else ct;
        } else {
            self.is_dark = !self.is_dark;
            self.theme = if (self.is_dark) &defaults.dark else &defaults.light;
        }
        for (self.tabs.items) |*tab| {
            tab.link_handler.theme = self.theme;
        }
        self.relayoutAllTabs();
    }

    // =========================================================================
    // File dialogs
    // =========================================================================

    fn openFileDialog(self: *App) void {
        self.openFileDialogImpl(false);
    }

    fn openFileDialogNewTab(self: *App) void {
        self.openFileDialogImpl(true);
    }

    fn openFileDialogImpl(self: *App, new_tab: bool) void {
        const selected = file_dialog.openFileDialog(self.allocator) catch |err| {
            std.log.err("File dialog error: {}", .{err});
            return;
        } orelse return;
        defer self.allocator.free(selected);

        const content = std.fs.cwd().readFileAlloc(self.allocator, selected, max_file_size) catch |err| {
            std.log.err("Failed to read file '{s}': {}", .{ selected, err });
            return;
        };
        defer self.allocator.free(content);

        const tab = if (new_tab)
            self.newTab() catch |err| {
                std.log.err("Failed to create new tab: {}", .{err});
                return;
            }
        else
            self.activeTab() orelse return;

        const dir = std.fs.path.dirname(selected) orelse ".";
        tab.setBaseDir(dir) catch |err| {
            std.log.err("Failed to set base dir: {}", .{err});
        };
        tab.loadMarkdown(content) catch |err| {
            std.log.err("Failed to parse markdown: {}", .{err});
            return;
        };
        tab.scroll.y = 0;

        if (!new_tab) {
            // Disable file watching for dialog-opened files
            if (tab.file_watcher) |*watcher| {
                watcher.deinit();
                tab.file_watcher = null;
            }
            if (tab.file_path) |p| self.allocator.free(p);
            tab.file_path = null;
        }

        if (self.fonts) |*f| {
            tab.relayout(self.theme, f, self.computeLayoutWidth(), self.computeContentYOffset()) catch |err| {
                std.log.err("Failed to relayout: {}", .{err});
            };
        }

        self.updateWindowTitle();
        self.rebuildToc();
    }

    fn exportToPdf(self: *App) void {
        const tab = self.activeTab() orelse return;
        const tree = &(tab.layout_tree orelse {
            std.log.warn("No document to export", .{});
            return;
        });
        const fonts_val = self.fonts orelse return;

        const default_name = pdf_exporter.buildPdfName(self.allocator, tab.file_path) catch {
            std.log.err("Failed to build default PDF name", .{});
            return;
        };
        defer self.allocator.free(default_name);

        const output_path = save_dialog.saveFileDialog(self.allocator, default_name) catch |err| {
            std.log.err("Save dialog error: {}", .{err});
            return;
        } orelse return;
        defer self.allocator.free(output_path);

        pdf_exporter.exportPdf(
            self.allocator,
            tree,
            self.theme,
            &fonts_val,
            output_path,
        ) catch |err| {
            std.log.err("PDF export failed: {}", .{err});
            return;
        };

        tab.reload_indicator_ms = std.time.milliTimestamp();
    }

    // =========================================================================
    // Drag and drop
    // =========================================================================

    fn handleFileDrop(self: *App) void {
        if (!rl.isFileDropped()) return;

        const dropped = rl.loadDroppedFiles();
        defer rl.unloadDroppedFiles(dropped);

        for (0..dropped.count) |i| {
            const path_ptr = dropped.paths[i];
            const path = std.mem.span(path_ptr);
            if (isSupportedMarkdownExtension(path)) {
                self.newTabWithFile(path) catch |err| {
                    std.log.err("Failed to open dropped file: {}", .{err});
                };
            }
        }
    }

    pub fn isSupportedMarkdownExtension(path: []const u8) bool {
        const ext = std.fs.path.extension(path);
        const supported = [_][]const u8{ ".md", ".markdown", ".txt", ".mkd" };
        for (supported) |s| {
            if (std.ascii.eqlIgnoreCase(ext, s)) return true;
        }
        return false;
    }

    // =========================================================================
    // Update loop
    // =========================================================================

    pub fn update(self: *App) void {
        const fonts = self.fonts orelse return;

        // Menu bar gets first crack at input
        const menu_action = self.menu_bar.update(&fonts);
        const menu_is_open = self.menu_bar.isOpen();

        if (menu_action) |action| {
            switch (action) {
                .open_file => self.openFileDialog(),
                .open_new_tab => self.openFileDialogNewTab(),
                .export_pdf => self.exportToPdf(),
                .close_app => rl.closeWindow(),
                .toggle_theme => self.toggleTheme(),
                .toggle_toc => {
                    self.toc_sidebar.toggle();
                    self.relayoutAllTabs();
                },
                .open_settings => std.log.info("Settings not yet implemented", .{}),
            }
        }

        // Handle file drag-and-drop early, before capturing tab pointer,
        // since dropping files can append to self.tabs and invalidate pointers.
        self.handleFileDrop();

        // Tab bar interaction
        if (!menu_is_open) {
            const tab_action = TabBar.update(self.tabs.items, self.active_tab);
            switch (tab_action) {
                .switch_tab => |idx| self.switchToTab(idx),
                .close_tab => |idx| self.closeTab(idx),
                .none => {},
            }
        }

        // Get active tab for the rest of the update
        const tab = self.activeTab() orelse return;

        // Keyboard shortcuts — suppressed when menu is open
        if (!menu_is_open) {
            const ctrl_held = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
            const shift_held = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);

            // Ctrl+F opens search
            if (ctrl_held and rl.isKeyPressed(.f)) {
                tab.search.open();
            } else if (tab.search.is_open) {
                self.updateSearch();
            } else {
                // Normal keyboard shortcuts when search is closed
                if (!ctrl_held and !shift_held) {
                    if (rl.isKeyPressed(.t)) {
                        self.toggleTheme();
                    }
                }
                if (ctrl_held) {
                    if (rl.isKeyPressed(.o)) {
                        self.openFileDialog();
                    }
                    if (rl.isKeyPressed(.p)) {
                        self.exportToPdf();
                    }
                    // Tab keybindings
                    if (rl.isKeyPressed(.t)) {
                        if (shift_held) {
                            // Ctrl+Shift+T: toggle ToC sidebar
                            self.toc_sidebar.toggle();
                            self.relayoutAllTabs();
                        } else {
                            // Ctrl+T: open file in new tab
                            self.openFileDialogNewTab();
                        }
                    }
                    if (rl.isKeyPressed(.w)) {
                        self.closeTab(self.active_tab);
                    }
                    if (rl.isKeyPressed(.tab)) {
                        if (shift_held) {
                            self.cycleTab(-1);
                        } else {
                            self.cycleTab(1);
                        }
                    }
                    // Ctrl+1-9 direct tab select
                    inline for (.{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine }, 0..) |key, idx| {
                        if (rl.isKeyPressed(key)) {
                            if (idx < self.tabs.items.len) {
                                self.switchToTab(idx);
                            }
                        }
                    }
                }

                // Vim '/' opens search
                if (!ctrl_held and !shift_held and rl.isKeyPressed(.slash)) {
                    tab.search.open();
                }
            }
        }

        // Scroll/link input when menu is closed.
        // Skip document scroll when mouse is over the ToC sidebar (it has its own scroll).
        if (!menu_is_open) {
            const mouse_over_sidebar = self.toc_sidebar.is_open and
                @as(f32, @floatFromInt(rl.getMouseX())) < self.toc_sidebar.effectiveWidth();
            if (!mouse_over_sidebar) {
                if (tab.search.is_open) {
                    tab.scroll.handleMouseWheel();
                } else {
                    tab.scroll.update();
                }
            }
        }

        // Expire reload indicator on active tab
        if (tab.reload_indicator_ms != 0) {
            const elapsed = std.time.milliTimestamp() - tab.reload_indicator_ms;
            if (elapsed >= fade_duration) {
                tab.reload_indicator_ms = 0;
            }
        }

        // Re-layout all tabs on window resize
        if (self.viewport.updateSize()) {
            self.relayoutAllTabs();
        }

        // Check for file changes on active tab
        if (tab.file_watcher) |*watcher| {
            switch (watcher.checkForChanges()) {
                .file_changed => {
                    const f = &(self.fonts orelse return);
                    tab.reloadFromDisk(self.theme, f, self.computeLayoutWidth(), self.computeContentYOffset());
                    self.rebuildToc();
                },
                .file_deleted => {
                    tab.file_deleted = true;
                    tab.reload_indicator_ms = std.time.milliTimestamp();
                },
                .no_change => {},
            }
        }

        // Link handler
        if (tab.layout_tree) |*tree| {
            const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
            tab.link_handler.update(tree, tab.scroll.y, screen_h);
            const mouse_y: f32 = @floatFromInt(rl.getMouseY());
            const mouse_x: f32 = @floatFromInt(rl.getMouseX());
            if (!menu_is_open and mouse_y >= self.computeContentYOffset() and mouse_x >= self.toc_sidebar.effectiveWidth()) {
                tab.link_handler.handleClick();
            }
        }

        // ToC sidebar interaction
        const toc_action = self.toc_sidebar.update(tab.scroll.y, self.computeContentYOffset());
        switch (toc_action) {
            .scroll_to => |target_y| {
                tab.scroll.y = @max(0, @min(target_y, tab.scroll.maxScroll()));
            },
            .none => {},
        }
    }

    // =========================================================================
    // Draw loop
    // =========================================================================

    pub fn draw(self: *App) void {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(self.theme.background);

        const fonts_val = self.fonts orelse return;
        const content_top_y = self.computeContentYOffset();
        const left_offset = self.toc_sidebar.effectiveWidth();

        if (self.activeTab()) |tab| {
            if (tab.layout_tree) |*tree| {
                renderer.render(tree, self.theme, &fonts_val, tab.scroll.y, content_top_y, left_offset);

                // Search highlights drawn over document content
                search_renderer.drawHighlights(&tab.search, self.theme, tab.scroll.y, content_top_y);
            } else {
                const y_offset: i32 = @intFromFloat(content_top_y + 8);
                rl.drawText("No document loaded. Usage: selkie <file.md>", 20, y_offset, 20, self.theme.text);
            }

            // Draw reload/deletion indicator
            self.drawReloadIndicator(tab, content_top_y);

            // Search bar drawn above document but below menu
            search_renderer.drawSearchBar(&tab.search, self.theme, &fonts_val, content_top_y);
        }

        // ToC sidebar
        self.toc_sidebar.draw(self.theme, &fonts_val, content_top_y);

        // Tab bar
        TabBar.draw(self.tabs.items, self.active_tab, self.theme, &fonts_val);

        // Menu bar drawn last so it's always on top
        self.menu_bar.draw(self.theme, &fonts_val);
    }

    fn drawReloadIndicator(self: *const App, tab: *const Tab, content_top_y: f32) void {
        if (tab.reload_indicator_ms == 0) return;

        const elapsed = std.time.milliTimestamp() - tab.reload_indicator_ms;
        if (elapsed >= fade_duration) return;

        const t: f32 = @floatFromInt(elapsed);
        const d: f32 = @floatFromInt(fade_duration);
        const alpha: u8 = @intFromFloat((1.0 - t / d) * 255.0);

        const text: [:0]const u8 = if (tab.file_deleted) "File deleted" else "Reloaded";
        const color: rl.Color = if (tab.file_deleted)
            .{ .r = 220, .g = 60, .b = 60, .a = alpha }
        else
            .{ .r = self.theme.text.r, .g = self.theme.text.g, .b = self.theme.text.b, .a = alpha };

        const font_size: i32 = 16;
        const screen_w = rl.getScreenWidth();
        const text_w = rl.measureText(text, font_size);
        const indicator_y: i32 = @intFromFloat(content_top_y + 8);
        rl.drawText(text, screen_w - text_w - 16, indicator_y, font_size, color);
    }

    // =========================================================================
    // Search (delegates to active tab)
    // =========================================================================

    fn updateSearch(self: *App) void {
        const tab = self.activeTab() orelse return;
        const shift_held = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);

        if (rl.isKeyPressed(.escape)) {
            tab.search.close();
            return;
        }

        if (rl.isKeyPressed(.enter)) {
            if (shift_held) {
                tab.search.prevMatch();
            } else {
                tab.search.nextMatch();
            }
            self.scrollToCurrentMatch();
            return;
        }

        if (rl.isKeyPressed(.backspace)) {
            if (tab.search.backspace()) {
                self.executeSearch();
            }
            return;
        }

        var char = rl.getCharPressed();
        while (char > 0) {
            if (char >= 32 and char < 127) {
                if (tab.search.appendChar(@intCast(char))) {
                    self.executeSearch();
                }
            }
            char = rl.getCharPressed();
        }
    }

    fn executeSearch(self: *App) void {
        const tab = self.activeTab() orelse return;
        const fonts_val = self.fonts orelse return;
        const tree = &(tab.layout_tree orelse return);

        tab.search.setQuery(tab.search.inputSlice()) catch |err| {
            std.log.err("Failed to set search query: {}", .{err});
            return;
        };

        searcher.search(&tab.search, tree, &fonts_val) catch |err| {
            std.log.err("Search failed: {}", .{err});
            return;
        };

        self.scrollToCurrentMatch();
    }

    fn scrollToCurrentMatch(self: *App) void {
        const tab = self.activeTab() orelse return;
        const rect = (tab.search.currentMatch() orelse return).highlight_rect;
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        const chrome_height = self.computeContentYOffset() + search_renderer.bar_height;
        const visible_h = screen_h - chrome_height;
        const target_y = rect.y - chrome_height - visible_h / 2.0 + rect.height / 2.0;
        tab.scroll.y = @max(0, @min(target_y, tab.scroll.maxScroll()));
    }

    // =========================================================================
    // Cleanup
    // =========================================================================

    pub fn deinit(self: *App) void {
        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit();
        self.toc_sidebar.deinit();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "App.init returns correct default state" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try testing.expect(!app.is_dark);
    try testing.expectEqual(@as(?Fonts, null), app.fonts);
    try testing.expect(!app.menu_bar.isOpen());
    try testing.expectEqual(@as(?Theme, null), app.custom_theme);
    try testing.expectEqual(@as(usize, 0), app.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), app.active_tab);
}

test "App.init uses light theme by default" {
    var app = App.init(testing.allocator);
    defer app.deinit();

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

    app.setTheme(null, false);
    try testing.expectEqual(defaults.light.background.r, app.theme.background.r);
    try testing.expectEqual(defaults.light.background.g, app.theme.background.g);
}

test "App.toggleTheme switches between light and dark" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try testing.expect(!app.is_dark);
    try testing.expectEqual(defaults.light.background.r, app.theme.background.r);

    app.toggleTheme();
    try testing.expect(app.is_dark);
    try testing.expectEqual(defaults.dark.background.r, app.theme.background.r);

    app.toggleTheme();
    try testing.expect(!app.is_dark);
    try testing.expectEqual(defaults.light.background.r, app.theme.background.r);
}

test "App.activeTab returns null when no tabs" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try testing.expect(app.activeTab() == null);
}

test "App.newTab creates a tab and sets it active" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    try testing.expectEqual(@as(usize, 1), app.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), app.active_tab);
    try testing.expect(app.activeTab() != null);

    _ = try app.newTab();
    try testing.expectEqual(@as(usize, 2), app.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), app.active_tab);
}

test "App.closeTab removes tab and adjusts active index" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();
    _ = try app.newTab();
    app.active_tab = 2;

    app.closeTab(1);
    try testing.expectEqual(@as(usize, 2), app.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), app.active_tab);
}

test "App.closeTab closes the active tab itself" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();
    _ = try app.newTab();
    app.active_tab = 1;

    app.closeTab(1);
    try testing.expectEqual(@as(usize, 2), app.tabs.items.len);
    // After closing active tab at index 1, active stays at 1 (now pointing to the former tab 2)
    try testing.expectEqual(@as(usize, 1), app.active_tab);
}

test "App.closeTab closes last tab when active adjusts to previous" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();
    _ = try app.newTab();
    app.active_tab = 2;

    app.closeTab(2);
    try testing.expectEqual(@as(usize, 2), app.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), app.active_tab);
}

test "App.closeTab with out-of-bounds index is no-op" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();

    app.closeTab(5);
    try testing.expectEqual(@as(usize, 2), app.tabs.items.len);
}

test "App.closeTab does not close last tab" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    app.closeTab(0);
    try testing.expectEqual(@as(usize, 1), app.tabs.items.len);
}

test "App.cycleTab wraps around" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();
    _ = try app.newTab();
    app.active_tab = 2;

    app.cycleTab(1);
    try testing.expectEqual(@as(usize, 0), app.active_tab);

    app.cycleTab(-1);
    try testing.expectEqual(@as(usize, 2), app.active_tab);
}

test "App.computeContentYOffset without tab bar" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // 0 or 1 tab: no tab bar
    try testing.expectEqual(MenuBar.bar_height, app.computeContentYOffset());

    _ = try app.newTab();
    try testing.expectEqual(MenuBar.bar_height, app.computeContentYOffset());
}

test "App.computeContentYOffset with tab bar" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();
    try testing.expectEqual(MenuBar.bar_height + TabBar.bar_height, app.computeContentYOffset());
}

test "App.isSupportedMarkdownExtension" {
    try testing.expect(App.isSupportedMarkdownExtension("readme.md"));
    try testing.expect(App.isSupportedMarkdownExtension("doc.markdown"));
    try testing.expect(App.isSupportedMarkdownExtension("notes.txt"));
    try testing.expect(App.isSupportedMarkdownExtension("file.mkd"));
    try testing.expect(App.isSupportedMarkdownExtension("FILE.MD"));
    try testing.expect(!App.isSupportedMarkdownExtension("image.png"));
    try testing.expect(!App.isSupportedMarkdownExtension("script.js"));
    try testing.expect(!App.isSupportedMarkdownExtension("noext"));
}

test "App.deinit cleans up without leaks" {
    var app = App.init(testing.allocator);
    _ = try app.newTab();
    _ = try app.newTab();
    app.deinit();
}
