const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("parser/ast.zig");
const markdown_parser = @import("parser/markdown_parser.zig");
const Theme = @import("theme/theme.zig").Theme;
const Fonts = @import("layout/text_measurer.zig").Fonts;
const LayoutTree = @import("layout/layout_types.zig").LayoutTree;
const document_layout = @import("layout/document_layout.zig");
const ScrollState = @import("viewport/scroll.zig").ScrollState;
const ImageRenderer = @import("render/image_renderer.zig").ImageRenderer;
const FileWatcher = @import("file_watcher.zig").FileWatcher;
const SearchState = @import("search/search_state.zig").SearchState;
const LinkHandler = @import("render/link_handler.zig").LinkHandler;
const defaults = @import("theme/defaults.zig");
const App = @import("app.zig").App;

pub const Tab = struct {
    allocator: Allocator,
    document: ?ast.Document,
    layout_tree: ?LayoutTree,
    scroll: ScrollState,
    file_watcher: ?FileWatcher,
    /// Owned/duped file path (null if no file)
    file_path: ?[]const u8,
    /// Owned/duped base directory for relative image resolution
    base_dir: ?[]const u8,
    image_renderer: ImageRenderer,
    search: SearchState,
    link_handler: LinkHandler,
    reload_indicator_ms: i64,
    file_deleted: bool,

    pub fn init(allocator: Allocator) Tab {
        return .{
            .allocator = allocator,
            .document = null,
            .layout_tree = null,
            .scroll = .{},
            .file_watcher = null,
            .file_path = null,
            .base_dir = null,
            .image_renderer = ImageRenderer.init(allocator),
            .search = SearchState.init(allocator),
            .link_handler = LinkHandler.init(&defaults.light),
            .reload_indicator_ms = 0,
            .file_deleted = false,
        };
    }

    pub fn deinit(self: *Tab) void {
        self.search.deinit();
        if (self.file_watcher) |*watcher| watcher.deinit();
        if (self.layout_tree) |*tree| tree.deinit();
        if (self.document) |*doc| doc.deinit();
        self.image_renderer.deinit();
        if (self.file_path) |p| self.allocator.free(p);
        if (self.base_dir) |d| self.allocator.free(d);
    }

    /// Parse markdown text into a document, replacing any existing document.
    /// The old document and layout tree are destroyed on success; on parse
    /// failure the existing state is preserved.
    pub fn loadMarkdown(self: *Tab, text: []const u8) !void {
        const new_doc = try markdown_parser.parse(self.allocator, text);

        if (self.layout_tree) |*tree| tree.deinit();
        self.layout_tree = null;
        if (self.document) |*doc| doc.deinit();
        self.document = new_doc;
    }

    /// Lay out the current document using the given theme, fonts, and dimensions.
    /// Replaces any existing layout tree.
    pub fn relayout(self: *Tab, theme: *const Theme, fonts: *const Fonts, layout_width: f32, y_offset: f32) !void {
        if (self.layout_tree) |*tree| tree.deinit();
        self.layout_tree = null;

        const doc = &(self.document orelse return);
        const tree = try document_layout.layout(
            self.allocator,
            doc,
            theme,
            fonts,
            layout_width,
            &self.image_renderer,
            y_offset,
        );
        self.scroll.total_height = tree.total_height;
        self.layout_tree = tree;
    }

    /// Set the file path and start watching for changes.
    /// Dupes and owns the path string.
    pub fn setFilePath(self: *Tab, path: []const u8) !void {
        if (self.file_path) |old| self.allocator.free(old);
        self.file_path = null;
        self.file_path = try self.allocator.dupe(u8, path);
        self.file_watcher = FileWatcher.init(self.file_path.?);
    }

    /// Set the base directory for resolving relative image paths.
    /// Dupes and owns the path string.
    pub fn setBaseDir(self: *Tab, path: []const u8) !void {
        if (self.base_dir) |old| self.allocator.free(old);
        self.base_dir = null;
        self.base_dir = try self.allocator.dupe(u8, path);
        errdefer {
            self.allocator.free(self.base_dir.?);
            self.base_dir = null;
        }
        try self.image_renderer.setBaseDir(path);
    }

    /// Reload the markdown file from disk, preserving scroll position.
    pub fn reloadFromDisk(self: *Tab, theme: *const Theme, fonts: *const Fonts, layout_width: f32, y_offset: f32) void {
        const path = self.file_path orelse return;

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, App.max_file_size) catch |err| {
            std.log.err("Failed to reload file '{s}': {}", .{ path, err });
            return;
        };
        defer self.allocator.free(content);

        const saved_scroll_y = self.scroll.y;

        self.loadMarkdown(content) catch |err| {
            std.log.err("Failed to parse reloaded markdown: {}", .{err});
            return;
        };

        self.relayout(theme, fonts, layout_width, y_offset) catch |err| {
            std.log.err("Failed to layout reloaded document: {}", .{err});
        };

        self.scroll.y = saved_scroll_y;
        self.scroll.clamp();

        self.reload_indicator_ms = std.time.milliTimestamp();
        self.file_deleted = false;
    }

    /// Return a display title for the tab (basename of file path, or "Untitled").
    pub fn title(self: *const Tab) []const u8 {
        const path = self.file_path orelse return "Untitled";
        return std.fs.path.basename(path);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Tab.init returns correct default state" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try testing.expectEqual(@as(?ast.Document, null), tab.document);
    try testing.expectEqual(@as(?LayoutTree, null), tab.layout_tree);
    try testing.expectEqual(@as(f32, 0), tab.scroll.y);
    try testing.expectEqual(@as(?FileWatcher, null), tab.file_watcher);
    try testing.expectEqual(@as(?[]const u8, null), tab.file_path);
    try testing.expectEqual(@as(?[]const u8, null), tab.base_dir);
    try testing.expectEqual(@as(i64, 0), tab.reload_indicator_ms);
    try testing.expect(!tab.file_deleted);
}

test "Tab.title returns Untitled when no file path" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try testing.expectEqualStrings("Untitled", tab.title());
}

test "Tab.title returns basename of file path" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setFilePath("/home/user/docs/readme.md");
    try testing.expectEqualStrings("readme.md", tab.title());
}

test "Tab.setFilePath dupes and owns the path" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    var buf: [32]u8 = undefined;
    const path = "test.md";
    @memcpy(buf[0..path.len], path);
    try tab.setFilePath(buf[0..path.len]);

    // Mutate the original buffer — tab should still have the original value
    buf[0] = 'X';
    try testing.expectEqualStrings("test.md", tab.file_path.?);
}

test "Tab.setBaseDir dupes and owns the path" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setBaseDir("/home/user/docs");
    try testing.expectEqualStrings("/home/user/docs", tab.base_dir.?);
}

test "Tab.setFilePath replaces old path without leaking" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setFilePath("/first/path.md");
    try testing.expectEqualStrings("path.md", tab.title());

    try tab.setFilePath("/second/other.md");
    try testing.expectEqualStrings("other.md", tab.title());
}

test "Tab.setBaseDir replaces old dir without leaking" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setBaseDir("/first/dir");
    try testing.expectEqualStrings("/first/dir", tab.base_dir.?);

    try tab.setBaseDir("/second/dir");
    try testing.expectEqualStrings("/second/dir", tab.base_dir.?);
}

test "Tab.loadMarkdown parses valid markdown" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# Hello\n\nWorld");
    try testing.expect(tab.document != null);
}

test "Tab.loadMarkdown replaces previous document without leaking" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# First");
    try testing.expect(tab.document != null);

    try tab.loadMarkdown("# Second");
    try testing.expect(tab.document != null);
}

test "Tab.loadMarkdown with empty string" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("");
    try testing.expect(tab.document != null);
}

test "Tab.deinit cleans up without leaks" {
    var tab = Tab.init(testing.allocator);
    try tab.setFilePath("/tmp/test.md");
    try tab.setBaseDir("/tmp");
    tab.deinit();
}
