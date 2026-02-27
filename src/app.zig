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
        self.scroll.update();

        if (rl.isKeyPressed(.t)) {
            self.toggleTheme();
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
            self.link_handler.handleClick();
        }
    }

    pub fn draw(self: *App) void {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(self.theme.background);

        if (self.layout_tree) |*tree| {
            renderer.render(tree, self.theme, &(self.fonts orelse return), self.scroll.y);
        } else {
            rl.drawText("No document loaded. Usage: selkie <file.md>", 20, 20, 20, self.theme.text);
        }

        // Draw reload/deletion indicator
        self.drawReloadIndicator();
    }

    fn drawReloadIndicator(self: *App) void {
        if (self.reload_indicator_ms == 0) return;

        const now = std.time.milliTimestamp();
        const elapsed = now - self.reload_indicator_ms;

        if (elapsed >= fade_duration) {
            self.reload_indicator_ms = 0;
            return;
        }

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
        rl.drawText(text, screen_w - text_w - 16, 8, font_size, color);
    }

    pub fn deinit(self: *App) void {
        if (self.file_watcher) |*watcher| watcher.deinit();
        if (self.layout_tree) |*tree| tree.deinit();
        if (self.document) |*doc| doc.deinit();
        self.image_renderer.deinit();
    }
};
