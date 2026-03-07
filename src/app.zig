const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const asset_paths = @import("asset_paths.zig");
const unicode_codepoints = @import("unicode_codepoints.zig");
const ast = @import("parser/ast.zig");
const Theme = @import("theme/theme.zig").Theme;
const defaults = @import("theme/defaults.zig");
const Fonts = @import("layout/text_measurer.zig").Fonts;
const LayoutTree = @import("layout/layout_types.zig").LayoutTree;
const renderer = @import("render/renderer.zig");
const scrollbar = @import("render/scrollbar.zig");
const ScrollState = @import("viewport/scroll.zig").ScrollState;
const Viewport = @import("viewport/viewport.zig").Viewport;
const MenuBar = @import("menu_bar.zig").MenuBar;
const TabBar = @import("tab_bar.zig").TabBar;
const Tab = @import("tab.zig").Tab;
const FileWatcher = @import("file_watcher.zig").FileWatcher;
const TocSidebar = @import("toc_sidebar.zig").TocSidebar;
const file_dialog = @import("file_dialog.zig");
const pdf_exporter = @import("export/pdf_exporter.zig");
const screenshot_capture = @import("export/screenshot_capture.zig");
const full_document_capture = @import("export/full_document_capture.zig");
const save_dialog = @import("export/save_dialog.zig");
const searcher = @import("search/searcher.zig");
const search_renderer = @import("render/search_renderer.zig");
const editor_renderer = @import("render/editor_renderer.zig");
const command_renderer = @import("render/command_renderer.zig");
const CommandState = @import("command/command_state.zig").CommandState;
const EditorState = @import("editor/editor_state.zig").EditorState;
const ModalDialog = @import("modal_dialog.zig").ModalDialog;
const ScrollPositionStore = @import("scroll_positions.zig").ScrollPositionStore;
const SplitPane = @import("split_pane.zig").SplitPane;

pub const App = struct {
    pub const max_file_size = 10 * 1024 * 1024;
    const reload_indicator_duration: i64 = 1500;
    const notification_duration: i64 = 3000;

    /// Display mode for the main content area.
    pub const ViewMode = enum {
        /// Show only the rendered preview (default when no editor is active)
        preview_only,
        /// Show only the editor
        editor_only,
        /// Show editor on the left, rendered preview on the right
        split,

        /// Cycle to the next view mode: preview → editor → split → preview
        pub fn next(self: ViewMode) ViewMode {
            return switch (self) {
                .preview_only => .editor_only,
                .editor_only => .split,
                .split => .preview_only,
            };
        }

        /// Human-readable label for display in menus/notifications.
        pub fn label(self: ViewMode) [:0]const u8 {
            return switch (self) {
                .preview_only => "Preview",
                .editor_only => "Editor",
                .split => "Split",
            };
        }
    };

    allocator: Allocator,
    theme: *const Theme,
    is_dark: bool,
    fonts: ?Fonts,
    viewport: Viewport,
    menu_bar: MenuBar,
    /// Owned custom theme loaded from JSON (null if using built-in themes)
    custom_theme: ?Theme,
    /// Base theme pointer (before zoom scaling) — points to defaults or custom_theme
    base_theme: *const Theme,
    /// Mutable copy of the base theme with font_size_scale applied
    active_theme: Theme,
    /// Zoom scale factor for font sizes (1.0 = 100%)
    font_size_scale: f32 = 1.0,

    // Tab management
    tabs: std.ArrayList(Tab),
    active_tab: usize,

    // ToC sidebar (shared across all tabs — shows headings for active tab)
    toc_sidebar: TocSidebar,

    // Source line numbers gutter
    show_line_numbers: bool = false,

    // View mode: editor-only, preview-only, or split
    view_mode: ViewMode = .preview_only,

    // Split-pane layout (manages divider position and drag interaction)
    split_pane: SplitPane = SplitPane.init(),

    // Scroll position persistence
    scroll_store: ?*ScrollPositionStore = null,

    // Modal dialog state
    active_dialog: ?ModalDialog = null,
    should_quit: bool = false,
    close_requested: bool = false,

    // Notification overlay (e.g. "zenity not installed")
    /// Static string literal -- not owned, do not allocate.
    notification_text: ?[:0]const u8 = null,
    notification_start_ms: i64 = 0,

    /// Create an App with default light theme. Caller MUST call `setTheme()`
    /// before reading `self.theme`, as `init()` returns by value and cannot
    /// establish the `self.theme -> &self.active_theme` pointer.
    pub fn init(allocator: Allocator) App {
        return .{
            .allocator = allocator,
            .theme = &defaults.light, // placeholder; setTheme() establishes the real pointer
            .is_dark = false,
            .fonts = null,
            .viewport = Viewport.init(),
            .menu_bar = MenuBar.init(),
            .custom_theme = null,
            .base_theme = &defaults.light,
            .active_theme = defaults.light,
            .tabs = std.ArrayList(Tab).init(allocator),
            .active_tab = 0,
            .toc_sidebar = TocSidebar.init(allocator),
        };
    }

    /// Set the initial theme. If custom_theme is provided, it's stored as an owned value.
    /// Does not call relayoutAllTabs() — intended to be called before tabs are loaded.
    pub fn setTheme(self: *App, custom: ?Theme, dark: bool) void {
        if (custom) |ct| {
            self.custom_theme = ct;
            self.base_theme = &self.custom_theme.?;
        } else if (dark) {
            self.is_dark = true;
            self.base_theme = &defaults.dark;
        } else {
            self.base_theme = &defaults.light;
        }
        self.rebuildActiveTheme();
    }

    /// Set the scroll position store for persisting scroll positions across sessions.
    /// The store is owned externally (by main.zig); App does not free it.
    pub fn setScrollPositions(self: *App, store: *ScrollPositionStore) void {
        self.scroll_store = store;
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

            // Safety: raylib only reads from the codepoints array; @constCast needed
            // because raylib-zig's loadFontEx signature takes ?[]i32 (mutable).
            @field(fonts, entry[0]) = try rl.loadFontEx(path, size, @constCast(&unicode_codepoints.codepoints));
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
            tab.relayout(self.theme, f, self.computeLayoutWidth(), self.computeContentYOffset(), self.computeContentLeftOffset(), self.show_line_numbers) catch |err| {
                std.log.err("Failed to layout document: {}", .{err});
            };
        }

        // Restore saved scroll position if available
        if (self.scroll_store) |store| {
            if (tab.file_path) |fp| {
                if (store.getPosition(fp)) |saved_y| {
                    tab.scroll.jumpTo(saved_y);
                }
            }
        }

        self.updateWindowTitle();
        self.rebuildToc();
    }

    pub fn closeTab(self: *App, index: usize) void {
        if (self.tabs.items.len <= 1) return; // Don't close last tab
        if (index >= self.tabs.items.len) return;

        // Save scroll position before closing
        self.saveTabScrollPosition(index);

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
        var indicator_buf: [260]u8 = undefined;
        const name = tab.titleWithIndicator(&indicator_buf);
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

    /// Return the available width for document layout (viewport minus sidebar).
    /// Must stay in sync with `computeContentLeftOffset` — layout centers content
    /// within this width, then shifts it right by the left offset.
    pub fn computeLayoutWidth(self: *const App) f32 {
        return self.viewport.width - self.toc_sidebar.effectiveWidth();
    }

    /// Return the horizontal offset for content to account for the ToC sidebar.
    /// Must stay in sync with `computeLayoutWidth` — both derive from sidebar width.
    pub fn computeContentLeftOffset(self: *const App) f32 {
        return self.toc_sidebar.effectiveWidth();
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
        tab.relayout(self.theme, fonts, self.computeLayoutWidth(), self.computeContentYOffset(), self.computeContentLeftOffset(), self.show_line_numbers) catch |err| {
            std.log.err("Failed to relayout: {}", .{err});
        };
        self.rebuildToc();
    }

    fn relayoutAllTabs(self: *App) void {
        const fonts = &(self.fonts orelse return);
        const width = self.computeLayoutWidth();
        const y_offset = self.computeContentYOffset();
        const left_offset = self.computeContentLeftOffset();
        for (self.tabs.items) |*tab| {
            tab.relayout(self.theme, fonts, width, y_offset, left_offset, self.show_line_numbers) catch |err| {
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
            self.base_theme = if (self.base_theme == @as(*const Theme, ct)) &defaults.dark else ct;
        } else {
            self.is_dark = !self.is_dark;
            self.base_theme = if (self.is_dark) &defaults.dark else &defaults.light;
        }
        self.rebuildActiveTheme();
        self.relayoutAllTabs();
    }

    /// Rebuild active_theme from base_theme with font_size_scale applied.
    /// Scales font sizes and spacing fields proportionally so the layout
    /// remains visually consistent at all zoom levels.
    fn rebuildActiveTheme(self: *App) void {
        self.active_theme = self.base_theme.*;
        const s = self.font_size_scale;
        self.active_theme.body_font_size *= s;
        self.active_theme.mono_font_size *= s;
        self.active_theme.paragraph_spacing *= s;
        self.active_theme.heading_spacing_above *= s;
        self.active_theme.heading_spacing_below *= s;
        self.active_theme.list_indent *= s;
        self.active_theme.blockquote_indent *= s;
        self.active_theme.code_block_padding *= s;
        self.active_theme.table_cell_padding *= s;
        self.theme = &self.active_theme;
        for (self.tabs.items) |*tab| {
            tab.link_handler.theme = self.theme;
        }
    }

    // =========================================================================
    // Zoom
    // =========================================================================

    const min_zoom: f32 = 0.5;
    const max_zoom: f32 = 3.0;
    const zoom_step: f32 = 0.1;

    /// Round to nearest 0.1 to avoid IEEE 754 drift from repeated addition.
    fn roundScale(scale: f32) f32 {
        return @round(scale * 10.0) / 10.0;
    }

    /// Increase font size by one zoom step.
    fn zoomIn(self: *App) void {
        self.setZoom(@min(roundScale(self.font_size_scale + zoom_step), max_zoom));
    }

    /// Decrease font size by one zoom step.
    fn zoomOut(self: *App) void {
        self.setZoom(@max(roundScale(self.font_size_scale - zoom_step), min_zoom));
    }

    /// Reset font size to default (100%).
    fn resetZoom(self: *App) void {
        self.setZoom(1.0);
    }

    /// Apply the given zoom scale, rebuild the theme, and relayout all tabs.
    fn setZoom(self: *App, scale: f32) void {
        self.font_size_scale = scale;
        self.rebuildActiveTheme();
        self.relayoutAllTabs();
    }

    // =========================================================================
    // Edit mode / View mode
    // =========================================================================

    /// Returns true if the active tab has edit mode open.
    fn isEditorActive(self: *App) bool {
        const tab = self.activeTab() orelse return false;
        const editor = tab.editor orelse return false;
        return editor.is_open;
    }

    /// Returns true if the editor pane should be visible in the current view mode.
    fn isEditorVisible(self: *App) bool {
        return (self.view_mode == .editor_only or self.view_mode == .split) and self.isEditorActive();
    }

    /// Returns true if the preview pane should be visible in the current view mode.
    fn isPreviewVisible(self: *App) bool {
        return self.view_mode == .preview_only or self.view_mode == .split;
    }

    /// Cycle the view mode: preview → editor → split → preview.
    /// When cycling into a mode that shows the editor, ensures the editor
    /// is initialized for the active tab. When cycling into split mode,
    /// re-parses the editor buffer so the preview is up-to-date.
    fn cycleViewMode(self: *App) void {
        self.setViewMode(self.view_mode.next());
    }

    /// Set the view mode explicitly, ensuring the editor is initialized
    /// when entering a mode that requires it, and re-parsing the buffer
    /// for the preview pane when entering split mode.
    pub fn setViewMode(self: *App, mode: ViewMode) void {
        const tab = self.activeTab() orelse return;
        const needs_editor = mode == .editor_only or mode == .split;

        if (needs_editor) {
            // Ensure editor is initialized and open
            if (tab.editor) |*ed| {
                if (!ed.is_open) {
                    ed.is_open = true;
                    tab.search.close();
                }
            } else {
                tab.toggleEditMode() catch |err| {
                    std.log.err("Failed to initialize editor for view mode: {}", .{err});
                    return;
                };
                tab.search.close();
            }
        }

        // When entering split mode or preview_only from a dirty editor,
        // re-parse so the preview is up-to-date.
        const show_preview = mode == .preview_only or mode == .split;
        if (show_preview and tab.isDirty()) {
            tab.reparseFromEditor() catch |err| {
                std.log.err("Failed to re-parse editor buffer for preview: {}", .{err});
            };
            self.relayoutActiveTab();
        }

        self.view_mode = mode;
        self.split_pane.is_active = (mode == .split);
    }

    /// Returns true if any open tab has unsaved edits.
    pub fn hasAnyDirtyTab(self: *const App) bool {
        for (self.tabs.items) |*tab| {
            if (tab.isDirty()) return true;
        }
        return false;
    }

    /// Save all tabs that have unsaved edits.
    fn saveAllDirtyTabs(self: *App) void {
        const original_active = self.active_tab;
        for (self.tabs.items, 0..) |*tab, i| {
            if (tab.isDirty()) {
                self.active_tab = i;
                self.saveActiveTab();
            }
        }
        self.active_tab = if (self.tabs.items.len > 0)
            @min(original_active, self.tabs.items.len - 1)
        else
            0;
    }

    /// Handle a request to close the application (e.g. window X button).
    /// If there are dirty tabs, shows a dialog instead of quitting immediately.
    pub fn requestClose(self: *App) void {
        if (self.close_requested) return;
        if (!self.hasAnyDirtyTab()) {
            self.should_quit = true;
            return;
        }
        self.close_requested = true;
        self.active_dialog = ModalDialog.init(.close_app, 0);
    }

    /// Request to close a specific tab, showing a dialog if it has unsaved changes.
    fn requestCloseTab(self: *App, index: usize) void {
        if (index >= self.tabs.items.len) return;
        if (self.tabs.items.len <= 1) return;
        const tab = &self.tabs.items[index];
        if (tab.isDirty()) {
            self.active_dialog = ModalDialog.init(.close_tab, index);
        } else {
            self.closeTab(index);
        }
    }

    /// Save the active tab's editor buffer to disk. On success, re-parses
    /// and relayouts the document so view mode reflects the saved changes.
    fn saveActiveTab(self: *App) void {
        const tab = self.activeTab() orelse return;
        if (!tab.isDirty()) return;

        tab.save() catch |err| {
            std.log.err("Failed to save file: {}", .{err});
            return;
        };

        // Sync watcher mtime so our own write doesn't trigger a reload.
        if (tab.file_watcher) |*watcher| {
            watcher.updateMtime();
        }

        // Re-parse and relayout so view mode shows saved content.
        // Dupe source_text before passing to loadMarkdown, since loadMarkdown
        // frees the old source_text and the slice would alias freed memory.
        if (tab.source_text) |source| {
            const source_copy = self.allocator.dupe(u8, source) catch |err| {
                std.log.err("Failed to dupe source for re-parse: {}", .{err});
                return;
            };
            defer self.allocator.free(source_copy);
            tab.loadMarkdown(source_copy) catch |err| {
                std.log.err("Failed to re-parse after save: {}", .{err});
            };
        }
        self.relayoutActiveTab();
        self.updateWindowTitle();
    }

    /// Toggle edit mode on the active tab, closing search if entering.
    /// When entering edit mode, switches to split view so the live preview
    /// pane is visible alongside the editor. When leaving edit mode,
    /// re-parses any dirty editor buffer so preview shows current content,
    /// then switches back to preview-only view.
    fn toggleEditMode(self: *App) void {
        const tab = self.activeTab() orelse return;
        // Close search bar when entering edit mode (mutual exclusion).
        // The editor is about to open if it doesn't exist yet or is currently closed.
        const entering = if (tab.editor) |ed| !ed.is_open else true;
        if (entering) {
            tab.search.close();
        }
        // toggleEditMode only flips is_open, does not destroy the editor.
        const leaving_dirty = !entering and tab.isDirty();
        tab.toggleEditMode() catch |err| {
            std.log.err("Failed to toggle edit mode: {}", .{err});
            return;
        };
        if (leaving_dirty) {
            tab.reparseFromEditor() catch |err| {
                std.log.err("Failed to re-parse editor buffer for preview: {}", .{err});
            };
            self.relayoutActiveTab();
        }
        // Entering edit → split view (live preview visible alongside editor).
        // Leaving edit → preview-only view.
        self.setViewMode(if (entering) .split else .preview_only);
    }

    const editor_page_size = 20;
    const editor_scroll_speed: f32 = 40;

    /// Handle all editor input: character insertion, cursor movement, selection,
    /// clipboard operations, and special keys.
    /// Returns early if no editor is active.
    fn updateEditor(self: *App) void {
        const tab = self.activeTab() orelse return;
        const editor = &(tab.editor orelse return);

        const pressedOrRepeat = struct {
            fn f(key: rl.KeyboardKey) bool {
                return rl.isKeyPressed(key) or rl.isKeyPressedRepeat(key);
            }
        }.f;

        const ctrl_held = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        const shift_held = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);

        // Ctrl+key shortcuts for clipboard and selection
        if (ctrl_held) {
            var handled = false;
            if (rl.isKeyPressed(.a)) {
                editor.selectAll();
                handled = true;
            } else if (rl.isKeyPressed(.c)) {
                editorCopy(editor);
                handled = true;
            } else if (rl.isKeyPressed(.x)) {
                editorCopy(editor);
                editor.deleteSelection() catch |err| {
                    std.log.err("Editor cut failed: {}", .{err});
                };
                handled = true;
            } else if (rl.isKeyPressed(.v)) {
                const clipboard: []const u8 = rl.getClipboardText();
                if (clipboard.len > 0) {
                    editor.replaceSelection(clipboard) catch |err| {
                        std.log.err("Editor paste failed: {}", .{err});
                    };
                }
                handled = true;
            } else if (rl.isKeyPressed(.z)) {
                if (shift_held) {
                    _ = editor.redo() catch |err| {
                        std.log.err("Editor redo failed: {}", .{err});
                    };
                } else {
                    _ = editor.undo() catch |err| {
                        std.log.err("Editor undo failed: {}", .{err});
                    };
                }
                handled = true;
            }
            // Drain char queue when ctrl is held to prevent stray insertions
            while (rl.getCharPressed() > 0) {}
            if (handled) {
                self.updateEditorScroll(editor);
                return;
            }
        }

        // Deletion keys — selection-aware
        if (pressedOrRepeat(.backspace)) {
            if (editor.hasSelection()) {
                editor.deleteSelection() catch |err| {
                    std.log.err("Editor delete selection failed: {}", .{err});
                };
            } else {
                editor.deleteCharBefore() catch |err| {
                    std.log.err("Editor backspace failed: {}", .{err});
                };
            }
        } else if (pressedOrRepeat(.delete)) {
            if (editor.hasSelection()) {
                editor.deleteSelection() catch |err| {
                    std.log.err("Editor delete selection failed: {}", .{err});
                };
            } else {
                editor.deleteCharAt() catch |err| {
                    std.log.err("Editor delete failed: {}", .{err});
                };
            }
        } else if (pressedOrRepeat(.enter) or pressedOrRepeat(.kp_enter)) {
            if (editor.hasSelection()) {
                editor.deleteSelection() catch |err| {
                    std.log.err("Editor delete selection failed: {}", .{err});
                };
            }
            editor.insertNewline() catch |err| {
                std.log.err("Editor newline failed: {}", .{err});
            };
        } else if (pressedOrRepeat(.tab)) {
            if (editor.hasSelection()) {
                editor.deleteSelection() catch |err| {
                    std.log.err("Editor delete selection failed: {}", .{err});
                };
            }
            editor.insertTab() catch |err| {
                std.log.err("Editor tab failed: {}", .{err});
            };
        } else if (pressedOrRepeat(.left)) {
            if (shift_held) {
                editor.startSelection();
                editor.moveCursorLeft();
            } else if (editor.selectionRange()) |sel| {
                editor.setCursor(sel.start_line, sel.start_col);
                editor.clearSelection();
            } else {
                editor.moveCursorLeft();
            }
        } else if (pressedOrRepeat(.right)) {
            if (shift_held) {
                editor.startSelection();
                editor.moveCursorRight();
            } else if (editor.selectionRange()) |sel| {
                editor.setCursor(sel.end_line, sel.end_col);
                editor.clearSelection();
            } else {
                editor.moveCursorRight();
            }
        } else if (pressedOrRepeat(.up)) {
            if (shift_held) {
                editor.startSelection();
                editor.moveCursorUp();
            } else if (editor.selectionRange()) |sel| {
                editor.setCursor(sel.start_line, sel.start_col);
                editor.clearSelection();
            } else {
                editor.moveCursorUp();
            }
        } else if (pressedOrRepeat(.down)) {
            if (shift_held) {
                editor.startSelection();
                editor.moveCursorDown();
            } else if (editor.selectionRange()) |sel| {
                editor.setCursor(sel.end_line, sel.end_col);
                editor.clearSelection();
            } else {
                editor.moveCursorDown();
            }
        } else if (pressedOrRepeat(.home)) {
            if (shift_held) {
                editor.startSelection();
            } else {
                editor.clearSelection();
            }
            editor.moveCursorHome();
        } else if (pressedOrRepeat(.end)) {
            if (shift_held) {
                editor.startSelection();
            } else {
                editor.clearSelection();
            }
            editor.moveCursorEnd();
        } else if (pressedOrRepeat(.page_up)) {
            if (shift_held) {
                editor.startSelection();
            } else {
                editor.clearSelection();
            }
            editor.moveCursorPageUp(editor_page_size);
        } else if (pressedOrRepeat(.page_down)) {
            if (shift_held) {
                editor.startSelection();
            } else {
                editor.clearSelection();
            }
            editor.moveCursorPageDown(editor_page_size);
        }

        // Mouse-based cursor positioning and selection
        self.updateEditorMouse(editor);

        // Character input — drain the queue (Unicode codepoints)
        // Typing with selection replaces the selected text.
        var char = rl.getCharPressed();
        while (char > 0) {
            if (char >= 32) {
                if (editor.hasSelection()) {
                    editor.deleteSelection() catch |err| {
                        std.log.err("Editor delete selection failed: {}", .{err});
                    };
                }
                editor.insertChar(@intCast(char)) catch |err| {
                    std.log.err("Editor insert failed: {}", .{err});
                };
            }
            char = rl.getCharPressed();
        }

        self.updateEditorScroll(editor);
    }

    /// Copy selected text to system clipboard.
    fn editorCopy(editor: *EditorState) void {
        const text = editor.selectedText() catch |err| {
            std.log.err("Editor copy failed: {}", .{err});
            return;
        } orelse return;
        defer editor.allocator.free(text);
        const z = editor.allocator.dupeZ(u8, text) catch |err| {
            std.log.err("Editor copy failed: {}", .{err});
            return;
        };
        defer editor.allocator.free(z);
        rl.setClipboardText(z);
    }

    /// Update editor scroll to keep cursor visible (called at end of updateEditor).
    fn updateEditorScroll(self: *App, editor: *EditorState) void {
        const font_size = self.theme.mono_font_size;
        const lh = font_size * self.theme.line_height;
        const content_y = self.computeContentYOffset();
        const vh: f32 = @floatFromInt(rl.getScreenHeight());
        editor.ensureCursorVisible(lh, vh - content_y);

        const fonts_val = self.fonts orelse return;
        const spacing = font_size / 10.0;
        const cursor_px = editor_renderer.cursorPixelX(
            editor.getLineText(editor.cursor_line) orelse "",
            editor.cursor_col,
            fonts_val.mono,
            font_size,
            spacing,
        );
        const gutter_w = editor_renderer.gutterWidth(editor.lineCount(), fonts_val.mono, font_size, spacing);
        const left_off = self.toc_sidebar.effectiveWidth();
        const vw: f32 = @floatFromInt(rl.getScreenWidth());
        const text_area_width = vw - left_off - gutter_w - editor_renderer.gutter_text_padding;
        editor.scroll_x = editor_renderer.scrollXForCursor(cursor_px, editor.scroll_x, text_area_width);
    }

    /// Handle mouse click, drag, and shift+click in the editor text area.
    /// Left-click positions cursor, drag selects text, shift+click extends selection.
    fn updateEditorMouse(self: *App, editor: *EditorState) void {
        const fonts_val = self.fonts orelse return;
        const font = fonts_val.mono;
        const font_size = self.theme.mono_font_size;
        const spacing = font_size / 10.0;
        const line_height = font_size * self.theme.line_height;
        if (line_height <= 0) return;

        const content_top_y = self.computeContentYOffset();
        const left_offset = self.computeContentLeftOffset();
        const gutter_w = editor_renderer.gutterWidth(editor.lineCount(), font, font_size, spacing);
        const text_area_x = left_offset + gutter_w + editor_renderer.gutter_text_padding;

        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());

        // Convert mouse position to editor line and column
        const rel_y = mouse_y - content_top_y + editor.scroll_y;
        const target_line: usize = if (rel_y < 0)
            0
        else
            @min(@as(usize, @intFromFloat(@min(rel_y / line_height, 1_000_000.0))), if (editor.lineCount() > 0) editor.lineCount() - 1 else 0);

        const rel_x = mouse_x - text_area_x + editor.scroll_x;
        const line_text = editor.getLineText(target_line) orelse "";
        const target_col = editor_renderer.byteColFromPixelX(line_text, rel_x, font, font_size, spacing);

        // Check if click is within the editor text area
        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        const in_text_area = mouse_x >= text_area_x and mouse_x < screen_w and
            mouse_y >= content_top_y and mouse_y < screen_h;

        if (rl.isMouseButtonPressed(.left) and in_text_area) {
            const shift_held = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
            if (shift_held) {
                // Shift+click extends selection from current cursor to click position
                editor.startSelection();
                editor.setCursor(target_line, target_col);
            } else {
                // Plain click — position cursor, clear selection, start potential drag
                editor.clearSelection();
                editor.setCursor(target_line, target_col);
            }
            editor.mouse_dragging = true;
        } else if (rl.isMouseButtonDown(.left) and editor.mouse_dragging) {
            // Drag — extend selection
            editor.startSelection();
            editor.setCursor(target_line, target_col);
        }

        if (rl.isMouseButtonReleased(.left)) {
            editor.mouse_dragging = false;
        }
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
        if (!file_dialog.isZenityAvailable()) {
            self.showNotification("File dialog requires zenity (not installed)");
            return;
        }

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
        tab.setFilePath(selected) catch |err| {
            std.log.err("Failed to set file path: {}", .{err});
        };
        tab.loadMarkdown(content) catch |err| {
            std.log.err("Failed to parse markdown: {}", .{err});
            return;
        };
        tab.scroll.jumpTo(0);

        if (self.fonts) |*f| {
            tab.relayout(self.theme, f, self.computeLayoutWidth(), self.computeContentYOffset(), self.computeContentLeftOffset(), self.show_line_numbers) catch |err| {
                std.log.err("Failed to relayout: {}", .{err});
            };
        }

        self.updateWindowTitle();
        self.rebuildToc();
    }

    fn exportToPdf(self: *App) void {
        const tab = self.activeTab() orelse return;
        const document = &(tab.document orelse {
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
            document,
            self.theme,
            &fonts_val,
            &tab.image_renderer,
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

        // Handle active modal dialog — suppresses all other input
        if (self.active_dialog) |*dialog| {
            if (dialog.update()) |response| {
                self.handleDialogResponse(dialog.kind, dialog.target_tab, response);
            }
            return;
        }

        // Menu bar gets first crack at input
        const menu_action = self.menu_bar.update(&fonts);
        const menu_is_open = self.menu_bar.isOpen();

        if (menu_action) |action| {
            switch (action) {
                .open_file => self.openFileDialog(),
                .open_new_tab => self.openFileDialogNewTab(),
                .export_pdf => self.exportToPdf(),
                .close_app => self.requestClose(),
                .toggle_theme => self.toggleTheme(),
                .toggle_toc => {
                    self.toc_sidebar.toggle();
                    self.relayoutAllTabs();
                },
                .toggle_line_numbers => {
                    self.show_line_numbers = !self.show_line_numbers;
                    self.relayoutAllTabs();
                },
                .toggle_edit_mode => self.toggleEditMode(),
                .cycle_view_mode => self.cycleViewMode(),
                .zoom_in => self.zoomIn(),
                .zoom_out => self.zoomOut(),
                .reset_zoom => self.resetZoom(),
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
                .close_tab => |idx| self.requestCloseTab(idx),
                .none => {},
            }
        }

        // Get active tab for the rest of the update
        const tab = self.activeTab() orelse return;

        // Keyboard shortcuts — suppressed when menu is open
        if (!menu_is_open) {
            const ctrl_held = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
            const shift_held = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
            const editor_active = self.isEditorActive();

            // Ctrl+E toggles edit mode (always available)
            if (ctrl_held and rl.isKeyPressed(.e)) {
                self.toggleEditMode();
            } else if (ctrl_held and rl.isKeyPressed(.backslash)) {
                // Ctrl+\ cycles view mode: preview → editor → split
                self.cycleViewMode();
            } else if (ctrl_held and rl.isKeyPressed(.s)) {
                // Ctrl+S saves editor buffer (works in both edit and view mode)
                self.saveActiveTab();
            } else if (ctrl_held and rl.isKeyPressed(.equal)) {
                // Ctrl+= (or Ctrl+Shift+= i.e. Ctrl++) zoom in
                self.zoomIn();
            } else if (ctrl_held and rl.isKeyPressed(.minus)) {
                // Ctrl+- zoom out
                self.zoomOut();
            } else if (ctrl_held and rl.isKeyPressed(.zero)) {
                // Ctrl+0 reset zoom
                self.resetZoom();
            } else if (editor_active) {
                // Editor is active — suppress all other keyboard input
                // (including Ctrl+F search). Only Ctrl+E, Ctrl+S, and
                // Ctrl+=/Ctrl+-/Ctrl+0 (zoom) above pass through.
                self.updateEditor();
            } else if (ctrl_held and rl.isKeyPressed(.f)) {
                // Ctrl+F opens search (close command bar if open)
                tab.command.close();
                tab.search.open();
            } else if (tab.command.is_open) {
                self.updateCommand();
            } else if (tab.search.is_open) {
                self.updateSearch();
            } else {
                // Normal keyboard shortcuts when search, command, and editor are closed
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
                    if (rl.isKeyPressed(.l)) {
                        self.show_line_numbers = !self.show_line_numbers;
                        self.relayoutAllTabs();
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
                        self.requestCloseTab(self.active_tab);
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

                // Vim ':' opens command bar (Shift+semicolon)
                if (!ctrl_held and shift_held and rl.isKeyPressed(.semicolon)) {
                    tab.search.close();
                    tab.command.open();
                }
            }
        }

        // Scrollbar interaction (takes priority over other scroll input)
        const scrollbar_active = if (!menu_is_open) self.handleScrollbarInput(tab) else false;

        // Split-pane divider drag interaction (takes priority over scroll)
        const split_divider_active = if (!menu_is_open and self.view_mode == .split) blk: {
            const sp_content_top = self.computeContentYOffset();
            const sp_left_off = self.toc_sidebar.effectiveWidth();
            const sp_screen_w: f32 = @floatFromInt(rl.getScreenWidth());
            const sp_screen_h: f32 = @floatFromInt(rl.getScreenHeight());
            const sp_area_w = sp_screen_w - sp_left_off;
            const sp_area_h = sp_screen_h - sp_content_top;
            break :blk self.split_pane.handleInput(sp_left_off, sp_content_top, sp_area_w, sp_area_h);
        } else false;

        // Ctrl+scroll zooms font size (intercept before normal scroll handling)
        const zoom_handled = blk: {
            if (menu_is_open) break :blk false;
            const ctrl_held = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
            if (!ctrl_held) break :blk false;
            const wheel = rl.getMouseWheelMove();
            if (wheel == 0) break :blk false;
            if (wheel > 0) self.zoomIn() else self.zoomOut();
            break :blk true;
        };

        // Scroll/link input when menu is closed.
        // Skip document scroll when mouse is over the ToC sidebar (it has its own scroll)
        // or when the scrollbar is being dragged.
        if (!menu_is_open and !scrollbar_active and !zoom_handled and !split_divider_active) {
            const mouse_over_sidebar = self.toc_sidebar.is_open and
                @as(f32, @floatFromInt(rl.getMouseX())) < self.toc_sidebar.effectiveWidth();
            if (!mouse_over_sidebar) {
                if (self.isEditorActive()) {
                    // Editor active — scroll the editor view, not the document.
                    if (tab.editor) |*ed| {
                        const wheel = rl.getMouseWheelMove();
                        if (wheel != 0) {
                            const font_size = self.theme.mono_font_size;
                            const content_y = self.computeContentYOffset();
                            const vh: f32 = @floatFromInt(rl.getScreenHeight());
                            const total_h = editor_renderer.totalHeight(ed.lineCount(), font_size, self.theme.line_height);
                            ed.applyScrollDelta(-wheel * editor_scroll_speed, total_h, vh - content_y);
                        }
                    }
                } else if (tab.search.is_open or tab.command.is_open) {
                    // Search/command active — only allow mouse wheel scrolling,
                    // suppress vim keys (j/k/d/u/g) that scroll.update() handles.
                    tab.scroll.handleMouseWheel();
                } else {
                    tab.scroll.update();
                }
            }
        }

        // Animate smooth scroll toward target position
        tab.scroll.animate(rl.getFrameTime());

        // Expire reload indicator on active tab
        if (tab.reload_indicator_ms != 0) {
            const elapsed = std.time.milliTimestamp() - tab.reload_indicator_ms;
            if (elapsed >= reload_indicator_duration) {
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
                    if (tab.isDirty()) {
                        // Tab has unsaved edits — ask user instead of auto-reloading
                        self.active_dialog = ModalDialog.init(.external_change, self.active_tab);
                    } else {
                        const f = &(self.fonts orelse return);
                        tab.reloadFromDisk(self.theme, f, self.computeLayoutWidth(), self.computeContentYOffset(), self.computeContentLeftOffset(), self.show_line_numbers);
                        self.rebuildToc();
                    }
                },
                .file_deleted => {
                    tab.file_deleted = true;
                    tab.reload_indicator_ms = std.time.milliTimestamp();
                },
                .no_change => {},
            }
        }

        // Link handler (skip when scrollbar is active to avoid cursor conflict)
        if (!scrollbar_active) {
            if (tab.layout_tree) |*tree| {
                const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
                tab.link_handler.update(tree, tab.scroll.y, screen_h);
                const mouse_y: f32 = @floatFromInt(rl.getMouseY());
                const mouse_x: f32 = @floatFromInt(rl.getMouseX());
                if (!menu_is_open and mouse_y >= self.computeContentYOffset() and mouse_x >= self.toc_sidebar.effectiveWidth()) {
                    tab.link_handler.handleClick();
                }
            }
        }

        // Live preview: re-parse and re-layout when editor buffer changes.
        // Checked every frame but only triggers work when edit_version advances.
        if (tab.previewNeedsUpdate()) {
            tab.updatePreviewFromEditor() catch |err| {
                std.log.err("Live preview re-parse failed: {}", .{err});
            };
            self.relayoutActiveTab();
        }

        // ToC sidebar interaction
        const toc_action = self.toc_sidebar.update(tab.scroll.y, self.computeContentYOffset());
        switch (toc_action) {
            .scroll_to => |toc_target| {
                tab.scroll.jumpTo(toc_target);
            },
            .none => {},
        }
    }

    // =========================================================================
    // Dialog response handling
    // =========================================================================

    fn handleDialogResponse(self: *App, kind: ModalDialog.Kind, target_tab: usize, response: ModalDialog.Response) void {
        // Every handled response dismisses the dialog and resets close state
        self.active_dialog = null;
        self.close_requested = false;

        switch (kind) {
            .external_change => switch (response) {
                .reload => {
                    if (target_tab >= self.tabs.items.len) return;
                    const tab = &self.tabs.items[target_tab];
                    const f = &(self.fonts orelse return);
                    tab.reloadFromDisk(self.theme, f, self.computeLayoutWidth(), self.computeContentYOffset(), self.computeContentLeftOffset(), self.show_line_numbers);
                    if (tab.editor) |*ed| {
                        ed.is_dirty = false;
                    }
                    self.rebuildToc();
                },
                .cancel, .save, .discard => {},
            },
            .close_tab => switch (response) {
                .save => {
                    const original = self.active_tab;
                    self.active_tab = target_tab;
                    self.saveActiveTab();
                    // Only close if save succeeded (tab is no longer dirty)
                    const saved = !self.tabs.items[target_tab].isDirty();
                    self.active_tab = original;
                    if (saved) self.closeTab(target_tab);
                },
                .discard => self.closeTab(target_tab),
                .cancel, .reload => {},
            },
            .close_app => switch (response) {
                .save => {
                    self.saveAllDirtyTabs();
                    if (!self.hasAnyDirtyTab()) {
                        self.should_quit = true;
                    }
                },
                .discard => {
                    self.should_quit = true;
                },
                .cancel, .reload => {},
            },
        }
    }

    // =========================================================================
    // Scrollbar interaction
    // =========================================================================

    /// Handle scrollbar drag, click-to-jump, and hover cursor. Returns true if
    /// the scrollbar consumed mouse input this frame (suppresses normal scroll
    /// and link handler).
    fn handleScrollbarInput(self: *App, tab: *Tab) bool {
        const tree = &(tab.layout_tree orelse return false);
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        const content_top_y = self.computeContentYOffset();
        const geo = scrollbar.compute(tree.total_height, tab.scroll.y, screen_h, content_top_y);
        if (!geo.visible) {
            tab.scroll.scrollbar_dragging = false;
            return false;
        }

        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());

        // Continue active drag
        if (tab.scroll.scrollbar_dragging) {
            if (rl.isMouseButtonDown(.left)) {
                tab.scroll.jumpTo(geo.mouseYToScroll(mouse_y, tab.scroll.scrollbar_drag_offset));
                rl.setMouseCursor(.resize_ns);
                return true;
            }
            // Mouse released — stop dragging
            tab.scroll.scrollbar_dragging = false;
        }

        // Hover cursor feedback
        if (geo.trackContains(mouse_x, mouse_y)) {
            rl.setMouseCursor(.resize_ns);

            if (rl.isMouseButtonPressed(.left)) {
                if (geo.thumbContains(mouse_x, mouse_y)) {
                    // Start dragging — record grab offset within the thumb
                    tab.scroll.scrollbar_dragging = true;
                    tab.scroll.scrollbar_drag_offset = mouse_y - geo.thumb_y;
                } else {
                    // Click on track — jump so thumb centers on click point
                    tab.scroll.jumpTo(geo.mouseYToScroll(mouse_y, geo.thumb_height / 2));
                }
                return true;
            }

            return true; // Hovering over scrollbar — suppress other scroll input
        }

        // Mouse not over scrollbar — reset cursor to default so it doesn't
        // persist from a previous frame's hover. The link handler may override
        // this to pointing_hand when it runs afterward.
        rl.setMouseCursor(.default);
        return false;
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
            if (self.view_mode == .split) {
                // Split-pane mode: editor on the left, rendered preview on the right
                const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
                const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
                const area_width = screen_w - left_offset;
                const area_height = screen_h - content_top_y;
                const layout = self.split_pane.computeLayout(left_offset, content_top_y, area_width, area_height);

                // Left pane: editor (constrained to left pane width)
                if (tab.editor) |*ed| {
                    if (ed.is_open) {
                        editor_renderer.drawEditorConstrained(self.allocator, ed, self.theme, &fonts_val, ed.scroll_y, ed.scroll_x, content_top_y, layout.left.x, layout.left.width);
                    }
                }

                // Right pane: rendered preview
                if (tab.layout_tree) |*tree| {
                    renderer.render(tree, self.theme, &fonts_val, tab.scroll.y, content_top_y, layout.right.x, tab.link_handler.hovered_url, layout.right.x + layout.right.width, screen_h);

                    // Search highlights drawn over document content
                    search_renderer.drawHighlights(&tab.search, self.theme, tab.scroll.y, content_top_y);
                }

                // Draw the split divider
                self.split_pane.drawDivider(left_offset, content_top_y, area_width, area_height);
            } else {
                // Single-pane modes: editor-only or preview-only
                if (tab.editor) |*ed| {
                    if (ed.is_open and self.view_mode == .editor_only) {
                        editor_renderer.drawEditor(self.allocator, ed, self.theme, &fonts_val, ed.scroll_y, ed.scroll_x, content_top_y, left_offset);
                    }
                }

                if (self.isPreviewVisible()) {
                    if (tab.layout_tree) |*tree| {
                        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
                        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
                        renderer.render(tree, self.theme, &fonts_val, tab.scroll.y, content_top_y, left_offset, tab.link_handler.hovered_url, screen_w, screen_h);

                        // Search highlights drawn over document content
                        search_renderer.drawHighlights(&tab.search, self.theme, tab.scroll.y, content_top_y);
                    } else {
                        const y_offset: i32 = @intFromFloat(content_top_y + 8);
                        rl.drawText("No document loaded. Usage: selkie <file.md>", 20, y_offset, 20, self.theme.text);
                    }
                }
            }

            // Draw reload/deletion indicator
            self.drawReloadIndicator(tab, content_top_y);

            // Draw notification overlay (e.g. missing zenity)
            self.drawNotification(content_top_y);

            // Search bar drawn above document but below menu
            search_renderer.drawSearchBar(&tab.search, self.theme, &fonts_val, content_top_y);

            // Command bar drawn at bottom of viewport
            command_renderer.drawCommandBar(&tab.command, self.theme, &fonts_val);
        }

        // ToC sidebar
        self.toc_sidebar.draw(self.theme, &fonts_val, content_top_y);

        // Tab bar
        TabBar.draw(self.tabs.items, self.active_tab, self.theme, &fonts_val);

        // Menu bar drawn last so it's always on top
        self.menu_bar.draw(self.theme, &fonts_val);

        // Modal dialog drawn on top of everything
        if (self.active_dialog) |*dialog| {
            dialog.draw(self.theme);
        }
    }

    fn drawReloadIndicator(self: *const App, tab: *const Tab, content_top_y: f32) void {
        if (tab.reload_indicator_ms == 0) return;

        const elapsed = std.time.milliTimestamp() - tab.reload_indicator_ms;
        if (elapsed >= reload_indicator_duration) return;

        const t: f32 = @floatFromInt(elapsed);
        const d: f32 = @floatFromInt(reload_indicator_duration);
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

    /// Set the notification text and record the current timestamp.
    /// The notification will fade out over `notification_duration` milliseconds.
    fn showNotification(self: *App, text: [:0]const u8) void {
        self.notification_text = text;
        self.notification_start_ms = std.time.milliTimestamp();
    }

    /// Draw the notification overlay if one is active and has not expired.
    /// Clears stale notification state once the duration elapses.
    fn drawNotification(self: *App, content_top_y: f32) void {
        const text = self.notification_text orelse return;
        if (self.notification_start_ms == 0) return;

        const elapsed = std.time.milliTimestamp() - self.notification_start_ms;
        if (elapsed < 0 or elapsed >= notification_duration) {
            self.notification_text = null;
            self.notification_start_ms = 0;
            return;
        }

        const t: f32 = @floatFromInt(elapsed);
        const d: f32 = @floatFromInt(notification_duration);
        const alpha: u8 = @intFromFloat(@max(0.0, (1.0 - t / d)) * 255.0);

        const color: rl.Color = .{ .r = 220, .g = 60, .b = 60, .a = alpha };

        const font_size: i32 = 16;
        const screen_w = rl.getScreenWidth();
        const text_w = rl.measureText(text, font_size);
        const indicator_y: i32 = @intFromFloat(content_top_y + 28);
        rl.drawText(text, screen_w - text_w - 16, indicator_y, font_size, color);
    }

    // =========================================================================
    // Screenshot / PNG export
    // =========================================================================

    /// Draw only the document or editor content (no UI chrome) into the current
    /// render target at the given pixel dimensions. Used by content-only PNG capture.
    ///
    /// This is a static-compatible wrapper: `context` must point to an `*App`.
    pub fn drawContentOnly(width: u32, height: u32, context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        const fonts_val = self.fonts orelse return;

        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);

        rl.clearBackground(self.theme.background);

        const tab = self.activeTab() orelse return;

        if (tab.editor) |*ed| {
            if (ed.is_open) {
                // Editor mode: draw editor content at origin (no chrome offset)
                editor_renderer.drawEditor(self.allocator, ed, self.theme, &fonts_val, ed.scroll_y, ed.scroll_x, 0, 0);
                return;
            }
        }

        // Render mode: draw document content (no scrollbar in content-only export)
        if (tab.layout_tree) |*tree| {
            renderer.renderEx(tree, self.theme, &fonts_val, tab.scroll.y, 0, 0, tab.link_handler.hovered_url, w, h, false);
        }
    }

    /// Capture the current viewport (including UI chrome) as a PNG.
    /// Returns a CaptureResult that the caller must deinit().
    pub fn captureViewportScreenshot(_: *App) screenshot_capture.CaptureError!screenshot_capture.CaptureResult {
        return screenshot_capture.captureViewport();
    }

    /// Capture only the content area (no UI chrome) as a PNG.
    /// Renders the active tab's content into an offscreen texture.
    pub fn captureContentScreenshot(self: *App, params: screenshot_capture.ContentCaptureParams) screenshot_capture.CaptureError!screenshot_capture.CaptureResult {
        return screenshot_capture.captureContent(params, &App.drawContentOnly, @ptrCast(@alignCast(self)));
    }

    /// Capture the viewport with full UI chrome (menu bar, tab bar, scrollbar)
    /// rendered into an offscreen texture at the specified dimensions.
    ///
    /// Unlike `captureViewportScreenshot` (which reads the screen framebuffer),
    /// this renders chrome into a dedicated render texture, allowing capture at
    /// arbitrary dimensions independent of the actual window size.
    pub fn captureWithChrome(self: *App, params: screenshot_capture.ContentCaptureParams) screenshot_capture.CaptureError!screenshot_capture.CaptureResult {
        return screenshot_capture.captureContent(params, &App.drawWithChrome, @ptrCast(@alignCast(self)));
    }

    /// Draw the full UI (content + chrome) into the current render target.
    ///
    /// Renders menu bar, tab bar, document/editor content, scrollbar, and
    /// ToC sidebar — the complete application UI. Used by chrome-included
    /// PNG export to capture the full visual appearance.
    ///
    /// This is a static-compatible wrapper: `context` must point to an `*App`.
    pub fn drawWithChrome(width: u32, height: u32, context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        const fonts_val = self.fonts orelse return;

        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);

        rl.clearBackground(self.theme.background);

        const content_top_y = self.computeContentYOffset();
        const left_offset = self.toc_sidebar.effectiveWidth();

        const tab = self.activeTab() orelse return;

        // Draw document/editor content area
        if (tab.editor) |*ed| {
            if (ed.is_open) {
                editor_renderer.drawEditor(self.allocator, ed, self.theme, &fonts_val, ed.scroll_y, ed.scroll_x, content_top_y, left_offset);
            }
        }

        if (self.isPreviewVisible()) {
            if (tab.layout_tree) |*tree| {
                renderer.render(tree, self.theme, &fonts_val, tab.scroll.y, content_top_y, left_offset, tab.link_handler.hovered_url, w, h);
            }
        }

        // Draw chrome elements on top
        self.toc_sidebar.draw(self.theme, &fonts_val, content_top_y);
        TabBar.draw(self.tabs.items, self.active_tab, self.theme, &fonts_val);
        self.menu_bar.draw(self.theme, &fonts_val);
    }

    /// Draw the full UI with chrome at a given scroll offset.
    ///
    /// Used by full-document + chrome tiled capture: renders chrome elements
    /// (menu bar, tab bar) at the top and document content at the specified
    /// scroll offset. The chrome is only drawn on the first tile (scroll_y == 0).
    ///
    /// This is a static-compatible wrapper matching `full_document_capture.TileDrawFn`.
    pub fn drawWithChromeAtScroll(width: u32, height: u32, scroll_y: f32, context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        const fonts_val = self.fonts orelse return;

        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);

        rl.clearBackground(self.theme.background);

        const chrome_height = self.computeContentYOffset();
        const left_offset = self.toc_sidebar.effectiveWidth();

        const tab = self.activeTab() orelse return;

        // For the first tile (scroll_y near zero), render chrome at the top
        // and offset content below it. For subsequent tiles, render content
        // starting from the adjusted scroll offset.
        if (scroll_y < chrome_height) {
            // First tile: draw chrome and content below it
            if (tab.editor) |*ed| {
                if (ed.is_open) {
                    editor_renderer.drawEditor(self.allocator, ed, self.theme, &fonts_val, 0, ed.scroll_x, chrome_height, left_offset);
                }
            }

            if (self.isPreviewVisible()) {
                if (tab.layout_tree) |*tree| {
                    renderer.render(tree, self.theme, &fonts_val, 0, chrome_height, left_offset, tab.link_handler.hovered_url, w, h);
                }
            }

            // Draw chrome on top
            self.toc_sidebar.draw(self.theme, &fonts_val, chrome_height);
            TabBar.draw(self.tabs.items, self.active_tab, self.theme, &fonts_val);
            self.menu_bar.draw(self.theme, &fonts_val);
        } else {
            // Subsequent tiles: render content only, adjusted for chrome offset
            const adjusted_scroll = scroll_y - chrome_height;

            if (tab.editor) |*ed| {
                if (ed.is_open) {
                    editor_renderer.drawEditor(self.allocator, ed, self.theme, &fonts_val, adjusted_scroll, 0, 0, 0);
                    return;
                }
            }

            if (tab.layout_tree) |*tree| {
                renderer.renderEx(tree, self.theme, &fonts_val, adjusted_scroll, 0, 0, tab.link_handler.hovered_url, w, h, false);
            }
        }
    }

    /// Draw document/editor content at a given scroll offset (no UI chrome).
    ///
    /// Used by the tiled full-document capture: each tile calls this with
    /// the tile's scroll_y offset so the renderer draws the correct vertical
    /// slice of the document into the current render target.
    ///
    /// This is a static-compatible wrapper matching `full_document_capture.TileDrawFn`:
    ///   fn(width: u32, height: u32, scroll_y: f32, context: *anyopaque) void
    pub fn drawContentAtScroll(width: u32, height: u32, scroll_y: f32, context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        const fonts_val = self.fonts orelse return;

        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);

        rl.clearBackground(self.theme.background);

        const tab = self.activeTab() orelse return;

        if (tab.editor) |*ed| {
            if (ed.is_open) {
                // Editor mode: draw editor content at the given scroll offset
                editor_renderer.drawEditor(self.allocator, ed, self.theme, &fonts_val, scroll_y, 0, 0, 0);
                return;
            }
        }

        // Render mode: draw document content at the given scroll offset (no scrollbar in content-only export)
        if (tab.layout_tree) |*tree| {
            renderer.renderEx(tree, self.theme, &fonts_val, scroll_y, 0, 0, tab.link_handler.hovered_url, w, h, false);
        }
    }

    /// Draw the full document content (no UI chrome) with scroll_y=0 so that
    /// the entire document is rendered from top to bottom. Used by content-only
    /// PNG capture when the full document fits in a single render texture.
    ///
    /// This is a static-compatible wrapper: `context` must point to an `*App`.
    pub fn drawFullDocumentContent(width: u32, height: u32, context: *anyopaque) void {
        drawContentAtScroll(width, height, 0, context);
    }

    /// Get the total content height for the active tab's document or editor.
    /// Returns null if no content is loaded.
    pub fn getContentHeight(self: *App) ?f32 {
        const tab = self.activeTab() orelse return null;

        if (tab.editor) |*ed| {
            if (ed.is_open) {
                const font_size = self.theme.mono_font_size;
                const line_height_factor = self.theme.line_height;
                return editor_renderer.totalHeight(ed.lineCount(), font_size, line_height_factor);
            }
        }

        if (tab.layout_tree) |tree| {
            return tree.total_height;
        }

        return null;
    }

    /// Capture the full document (all content, not just viewport) as a PNG.
    ///
    /// Uses tiled rendering to handle documents taller than the GPU's maximum
    /// texture size. Width defaults to current viewport width.
    pub fn captureFullDocument(self: *App) full_document_capture.FullCaptureError!full_document_capture.FullCaptureResult {
        return self.captureFullDocumentImpl(@intCast(rl.getScreenWidth()), false);
    }

    /// Capture the full document with a specified width.
    pub fn captureFullDocumentWithWidth(self: *App, width: u32) full_document_capture.FullCaptureError!full_document_capture.FullCaptureResult {
        return self.captureFullDocumentImpl(width, false);
    }

    /// Capture the full document with UI chrome (menu bar, tab bar, scrollbar).
    /// Total height = chrome_height + doc_height. Uses current viewport width.
    pub fn captureFullDocumentWithChrome(self: *App) full_document_capture.FullCaptureError!full_document_capture.FullCaptureResult {
        return self.captureFullDocumentImpl(@intCast(rl.getScreenWidth()), true);
    }

    /// Capture the full document with UI chrome at a specified width.
    pub fn captureFullDocumentWithChromeAndWidth(self: *App, width: u32) full_document_capture.FullCaptureError!full_document_capture.FullCaptureResult {
        return self.captureFullDocumentImpl(width, true);
    }

    /// Shared implementation for all full-document capture variants.
    fn captureFullDocumentImpl(self: *App, width: u32, include_chrome: bool) full_document_capture.FullCaptureError!full_document_capture.FullCaptureResult {
        const content_h = self.getContentHeight() orelse return full_document_capture.FullCaptureError.EmptyDocument;
        const doc_height = full_document_capture.documentHeightFromLayout(content_h);
        if (doc_height == 0) return full_document_capture.FullCaptureError.EmptyDocument;

        const chrome_extra: u32 = if (include_chrome) @intFromFloat(@ceil(self.computeContentYOffset())) else 0;
        const draw_fn: full_document_capture.TileDrawFn = if (include_chrome) &App.drawWithChromeAtScroll else &App.drawContentAtScroll;

        return full_document_capture.captureFullDocument(
            self.allocator,
            .{ .width = width, .document_height = doc_height + chrome_extra },
            draw_fn,
            @ptrCast(@alignCast(self)),
        );
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
        const search_target = rect.y - chrome_height - visible_h / 2.0 + rect.height / 2.0;
        tab.scroll.jumpTo(search_target);
    }

    // =========================================================================
    // Command bar (`:` go-to-line)
    // =========================================================================

    fn updateCommand(self: *App) void {
        const tab = self.activeTab() orelse return;

        if (rl.isKeyPressed(.escape)) {
            tab.command.close();
            return;
        }

        if (rl.isKeyPressed(.enter)) {
            self.executeCommand();
            tab.command.close();
            return;
        }

        if (rl.isKeyPressed(.backspace)) {
            _ = tab.command.backspace();
            return;
        }

        // Feed printable ASCII digits to command state
        var char = rl.getCharPressed();
        while (char > 0) {
            if (char >= '0' and char <= '9') {
                _ = tab.command.appendChar(@intCast(char));
            }
            char = rl.getCharPressed();
        }
    }

    fn executeCommand(self: *App) void {
        const tab = self.activeTab() orelse return;
        const target_line = tab.command.lineNumber() orelse return;
        if (target_line == 0) return; // source lines are 1-based
        const tree = tab.layout_tree orelse return;

        // Find first node whose source_line >= target (nodes are in document order)
        for (tree.nodes.items) |node| {
            if (node.source_line > 0 and node.source_line >= target_line) {
                // Scroll so the node is vertically centered in the visible area
                const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
                const chrome_height = self.computeContentYOffset();
                const visible_h = screen_h - chrome_height;
                tab.scroll.jumpTo(node.rect.y - chrome_height - visible_h / 2.0 + node.rect.height / 2.0);
                return;
            }
        }
    }

    // =========================================================================
    // Cleanup
    // =========================================================================

    pub fn deinit(self: *App) void {
        // Persist scroll positions for all open tabs before shutdown
        if (self.scroll_store) |store| {
            for (0..self.tabs.items.len) |i| {
                self.saveTabScrollPosition(i);
            }
            store.save() catch |err| {
                std.log.err("Failed to save scroll positions: {}", .{err});
            };
        }

        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit();
        self.toc_sidebar.deinit();
    }

    /// Save the scroll position for a tab at the given index.
    fn saveTabScrollPosition(self: *App, index: usize) void {
        const store = self.scroll_store orelse return;
        if (index >= self.tabs.items.len) return;
        const tab = &self.tabs.items[index];
        if (tab.file_path) |fp| {
            store.setPosition(fp, tab.scroll.y) catch |err| {
                std.log.err("Failed to store scroll position for '{s}': {}", .{ fp, err });
            };
        }
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

test "App.computeContentLeftOffset returns 0 when sidebar closed" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try testing.expectEqual(@as(f32, 0), app.computeContentLeftOffset());
}

test "App.computeContentLeftOffset returns sidebar width when open" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    app.toc_sidebar.toggle();
    try testing.expectEqual(TocSidebar.sidebar_width, app.computeContentLeftOffset());
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

test "App.isEditorActive returns false with no tabs" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try testing.expect(!app.isEditorActive());
}

test "App.isEditorActive returns false when editor not initialized" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    try testing.expect(!app.isEditorActive());
}

test "App.isEditorActive returns true when editor is open" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const tab = try app.newTab();
    try tab.loadMarkdown("# Test");
    try tab.toggleEditMode();
    try testing.expect(app.isEditorActive());
}

test "App.isEditorActive returns false when editor is closed" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const tab = try app.newTab();
    try tab.loadMarkdown("# Test");
    try tab.toggleEditMode(); // open
    try tab.toggleEditMode(); // close
    try testing.expect(!app.isEditorActive());
}

test "App.deinit cleans up without leaks" {
    var app = App.init(testing.allocator);
    _ = try app.newTab();
    _ = try app.newTab();
    app.deinit();
}

test "App.deinit cleans up editor state without leaks" {
    var app = App.init(testing.allocator);
    const tab = try app.newTab();
    try tab.loadMarkdown("# Editor cleanup");
    try tab.toggleEditMode();
    app.deinit();
}

test "App.hasAnyDirtyTab returns false with no dirty tabs" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();
    try testing.expect(!app.hasAnyDirtyTab());
}

test "App.hasAnyDirtyTab returns true when a tab is dirty" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    const tab = try app.newTab();
    try tab.loadMarkdown("# Test");
    try tab.toggleEditMode();
    tab.editor.?.is_dirty = true;
    try testing.expect(app.hasAnyDirtyTab());
}

test "App.requestClose sets should_quit when no dirty tabs" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    try testing.expect(!app.should_quit);

    app.requestClose();
    try testing.expect(app.should_quit);
    try testing.expect(app.active_dialog == null);
}

test "App.requestClose shows dialog when dirty tab exists" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const tab = try app.newTab();
    try tab.loadMarkdown("# Dirty");
    try tab.toggleEditMode();
    tab.editor.?.is_dirty = true;

    app.requestClose();
    try testing.expect(!app.should_quit);
    try testing.expect(app.active_dialog != null);
    try testing.expectEqual(ModalDialog.Kind.close_app, app.active_dialog.?.kind);
}

test "App.requestCloseTab closes clean tab directly" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();
    try testing.expectEqual(@as(usize, 2), app.tabs.items.len);

    app.requestCloseTab(0);
    try testing.expectEqual(@as(usize, 1), app.tabs.items.len);
    try testing.expect(app.active_dialog == null);
}

test "App.requestCloseTab shows dialog for dirty tab" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    const tab = try app.newTab();
    try tab.loadMarkdown("# Dirty");
    try tab.toggleEditMode();
    tab.editor.?.is_dirty = true;

    app.requestCloseTab(1);
    try testing.expectEqual(@as(usize, 2), app.tabs.items.len);
    try testing.expect(app.active_dialog != null);
    try testing.expectEqual(ModalDialog.Kind.close_tab, app.active_dialog.?.kind);
    try testing.expectEqual(@as(usize, 1), app.active_dialog.?.target_tab);
}

test "App.init has no active dialog" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try testing.expect(app.active_dialog == null);
    try testing.expect(!app.should_quit);
    try testing.expect(!app.close_requested);
}

test "App.requestCloseTab with out-of-bounds index is no-op" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();
    _ = try app.newTab();

    app.requestCloseTab(5);
    try testing.expectEqual(@as(usize, 2), app.tabs.items.len);
    try testing.expect(app.active_dialog == null);
}

test "App.requestCloseTab on last remaining tab is no-op" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    _ = try app.newTab();

    app.requestCloseTab(0);
    try testing.expectEqual(@as(usize, 1), app.tabs.items.len);
    try testing.expect(app.active_dialog == null);
}

test "App.requestClose is idempotent with dirty tabs" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const tab = try app.newTab();
    try tab.loadMarkdown("# Dirty");
    try tab.toggleEditMode();
    tab.editor.?.is_dirty = true;

    app.requestClose();
    try testing.expect(app.active_dialog != null);
    try testing.expect(app.close_requested);

    // Second call should be a no-op
    app.requestClose();
    try testing.expect(app.active_dialog != null);
    try testing.expectEqual(ModalDialog.Kind.close_app, app.active_dialog.?.kind);
}

test "App.zoomIn increases font_size_scale" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);

    try testing.expectApproxEqAbs(@as(f32, 1.0), app.font_size_scale, 0.001);
    app.zoomIn();
    try testing.expectApproxEqAbs(@as(f32, 1.1), app.font_size_scale, 0.001);
}

test "App.zoomOut decreases font_size_scale" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);

    app.zoomOut();
    try testing.expectApproxEqAbs(@as(f32, 0.9), app.font_size_scale, 0.001);
}

test "App.resetZoom restores default scale" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);

    app.zoomIn();
    app.zoomIn();
    try testing.expectApproxEqAbs(@as(f32, 1.2), app.font_size_scale, 0.001);

    app.resetZoom();
    try testing.expectApproxEqAbs(@as(f32, 1.0), app.font_size_scale, 0.001);
}

test "App.zoomIn clamps at max_zoom" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);

    var i: usize = 0;
    while (i < 30) : (i += 1) app.zoomIn();

    try testing.expectApproxEqAbs(@as(f32, App.max_zoom), app.font_size_scale, 0.001);
}

test "App.zoomOut clamps at min_zoom" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);

    var i: usize = 0;
    while (i < 30) : (i += 1) app.zoomOut();

    try testing.expectApproxEqAbs(@as(f32, App.min_zoom), app.font_size_scale, 0.001);
}

test "App zoom applies scale to active theme font sizes and spacing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);

    const base = defaults.light;
    const s: f32 = 1.1;

    app.zoomIn(); // 1.1x
    try testing.expectApproxEqAbs(base.body_font_size * s, app.theme.body_font_size, 0.01);
    try testing.expectApproxEqAbs(base.mono_font_size * s, app.theme.mono_font_size, 0.01);
    try testing.expectApproxEqAbs(base.paragraph_spacing * s, app.theme.paragraph_spacing, 0.01);
    try testing.expectApproxEqAbs(base.heading_spacing_above * s, app.theme.heading_spacing_above, 0.01);
    try testing.expectApproxEqAbs(base.heading_spacing_below * s, app.theme.heading_spacing_below, 0.01);
    try testing.expectApproxEqAbs(base.list_indent * s, app.theme.list_indent, 0.01);
    try testing.expectApproxEqAbs(base.blockquote_indent * s, app.theme.blockquote_indent, 0.01);
    try testing.expectApproxEqAbs(base.code_block_padding * s, app.theme.code_block_padding, 0.01);
    try testing.expectApproxEqAbs(base.table_cell_padding * s, app.theme.table_cell_padding, 0.01);
}

test "App zoom persists across theme toggle round-trip" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);

    app.zoomIn(); // 1.1x
    app.toggleTheme(); // switch to dark

    try testing.expectApproxEqAbs(@as(f32, 1.1), app.font_size_scale, 0.001);
    try testing.expectApproxEqAbs(defaults.dark.body_font_size * 1.1, app.theme.body_font_size, 0.01);

    app.toggleTheme(); // back to light
    try testing.expectApproxEqAbs(@as(f32, 1.1), app.font_size_scale, 0.001);
    try testing.expectApproxEqAbs(defaults.light.body_font_size * 1.1, app.theme.body_font_size, 0.01);
}

test "App.showNotification sets notification fields" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);

    try testing.expect(app.notification_text == null);
    try testing.expectEqual(@as(i64, 0), app.notification_start_ms);

    app.showNotification("test message");
    try testing.expect(app.notification_text != null);
    try testing.expect(app.notification_start_ms > 0);
    try testing.expectEqualStrings("test message", app.notification_text.?);
}

// =========================================================================
// ViewMode tests
// =========================================================================

test "ViewMode.next cycles preview → editor → split → preview" {
    const VM = App.ViewMode;
    try testing.expectEqual(VM.editor_only, VM.preview_only.next());
    try testing.expectEqual(VM.split, VM.editor_only.next());
    try testing.expectEqual(VM.preview_only, VM.split.next());
}

test "ViewMode.next is a 3-cycle" {
    const VM = App.ViewMode;
    // Applying next three times returns to the original mode
    const start = VM.preview_only;
    try testing.expectEqual(start, start.next().next().next());
}

test "ViewMode.label returns descriptive names" {
    const VM = App.ViewMode;
    try testing.expectEqualStrings("Preview", VM.preview_only.label());
    try testing.expectEqualStrings("Editor", VM.editor_only.label());
    try testing.expectEqualStrings("Split", VM.split.label());
}

test "App.init defaults to preview_only view mode" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);
    try testing.expectEqual(App.ViewMode.preview_only, app.view_mode);
}

test "App.isPreviewVisible returns true for preview_only" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);
    app.view_mode = .preview_only;
    try testing.expect(app.isPreviewVisible());
}

test "App.isPreviewVisible returns true for split" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);
    app.view_mode = .split;
    try testing.expect(app.isPreviewVisible());
}

test "App.isPreviewVisible returns false for editor_only" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);
    app.view_mode = .editor_only;
    try testing.expect(!app.isPreviewVisible());
}

test "App.isEditorVisible returns false without editor initialized" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);
    _ = try app.newTab();
    app.view_mode = .editor_only;
    // No editor initialized, so should return false
    try testing.expect(!app.isEditorVisible());
}

test "App.isEditorVisible returns true when editor is open and mode is editor_only" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);
    _ = try app.newTab();
    const tab = app.activeTab().?;
    try tab.toggleEditMode();
    app.view_mode = .editor_only;
    try testing.expect(app.isEditorVisible());
}

test "App.isEditorVisible returns true when editor is open and mode is split" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.setTheme(null, false);
    _ = try app.newTab();
    const tab = app.activeTab().?;
    try tab.toggleEditMode();
    app.view_mode = .split;
    try testing.expect(app.isEditorVisible());
}
