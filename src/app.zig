const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const ast = @import("parser/ast.zig");
const markdown_parser = @import("parser/markdown_parser.zig");
const Theme = @import("theme/theme.zig").Theme;
const defaults = @import("theme/defaults.zig");
const Fonts = @import("layout/text_measurer.zig").Fonts;
const lt = @import("layout/layout_types.zig");
const document_layout = @import("layout/document_layout.zig");
const renderer = @import("render/renderer.zig");
const ScrollState = @import("viewport/scroll.zig").ScrollState;
const Viewport = @import("viewport/viewport.zig").Viewport;

pub const App = struct {
    allocator: Allocator,
    document: ?ast.Document,
    layout_tree: ?lt.LayoutTree,
    theme: *const Theme,
    is_dark: bool,
    fonts: Fonts,
    scroll: ScrollState,
    viewport: Viewport,

    pub fn init(allocator: Allocator) App {
        return .{
            .allocator = allocator,
            .document = null,
            .layout_tree = null,
            .theme = &defaults.light,
            .is_dark = false,
            .fonts = undefined,
            .scroll = .{},
            .viewport = Viewport.init(),
        };
    }

    pub fn loadFonts(self: *App) !void {
        const size = 32; // Load at high size, scale down when rendering
        self.fonts = .{
            .body = try rl.loadFontEx("assets/fonts/Inter-Regular.ttf", size, null),
            .bold = try rl.loadFontEx("assets/fonts/Inter-Bold.ttf", size, null),
            .mono = try rl.loadFontEx("assets/fonts/JetBrainsMono-Regular.ttf", size, null),
        };

        // Use bilinear filtering for clean text
        rl.setTextureFilter(self.fonts.body.texture, .bilinear);
        rl.setTextureFilter(self.fonts.bold.texture, .bilinear);
        rl.setTextureFilter(self.fonts.mono.texture, .bilinear);
    }

    pub fn unloadFonts(self: *App) void {
        rl.unloadFont(self.fonts.body);
        rl.unloadFont(self.fonts.bold);
        rl.unloadFont(self.fonts.mono);
    }

    pub fn loadMarkdown(self: *App, text: []const u8) !void {
        // Free existing document
        if (self.document) |*doc| doc.deinit();
        if (self.layout_tree) |*tree| tree.deinit();

        self.document = try markdown_parser.parse(self.allocator, text);
        try self.relayout();
    }

    pub fn relayout(self: *App) !void {
        if (self.layout_tree) |*tree| tree.deinit();

        if (self.document) |*doc| {
            self.layout_tree = try document_layout.layout(
                self.allocator,
                doc,
                self.theme,
                &self.fonts,
                self.viewport.width,
            );
            self.scroll.total_height = self.layout_tree.?.total_height;
        }
    }

    pub fn toggleTheme(self: *App) void {
        self.is_dark = !self.is_dark;
        self.theme = if (self.is_dark) &defaults.dark else &defaults.light;
        self.relayout() catch {};
    }

    pub fn update(self: *App) void {
        // Handle input
        self.scroll.update();

        // Toggle theme with T key
        if (rl.isKeyPressed(.t)) {
            self.toggleTheme();
        }

        // Re-layout on window resize
        if (self.viewport.updateSize()) {
            self.relayout() catch {};
        }
    }

    pub fn draw(self: *App) void {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(self.theme.background);

        if (self.layout_tree) |*tree| {
            renderer.render(tree, self.theme, &self.fonts, self.scroll.y);
        } else {
            rl.drawText("No document loaded. Usage: selkie <file.md>", 20, 20, 20, self.theme.text);
        }
    }

    pub fn deinit(self: *App) void {
        if (self.layout_tree) |*tree| tree.deinit();
        if (self.document) |*doc| doc.deinit();
    }
};
