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
const EditorState = @import("editor/editor_state.zig").EditorState;
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
    /// Owned copy of the raw markdown source text (null until first successful loadMarkdown call)
    source_text: ?[]u8,
    /// Editor buffer for in-app editing (null until first toggle into edit mode)
    editor: ?EditorState,

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
            .source_text = null,
            .editor = null,
        };
    }

    /// Release all owned resources.
    pub fn deinit(self: *Tab) void {
        self.search.deinit();
        if (self.file_watcher) |*watcher| watcher.deinit();
        if (self.layout_tree) |*tree| tree.deinit();
        if (self.document) |*doc| doc.deinit();
        self.image_renderer.deinit();
        if (self.editor) |*ed| ed.deinit();
        if (self.source_text) |source| self.allocator.free(source);
        if (self.file_path) |path| self.allocator.free(path);
        if (self.base_dir) |dir| self.allocator.free(dir);
    }

    /// Parse markdown text into a document, replacing any existing document.
    /// The old document and layout tree are destroyed on success; on parse
    /// failure the existing state is preserved.
    pub fn loadMarkdown(self: *Tab, text: []const u8) !void {
        var new_doc = try markdown_parser.parse(self.allocator, text);
        errdefer new_doc.deinit();
        const new_source = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(new_source);

        // Point of no return: swap old state for new (infallible below)
        if (self.layout_tree) |*tree| tree.deinit();
        self.layout_tree = null;
        if (self.document) |*doc| doc.deinit();
        self.document = new_doc;
        if (self.source_text) |old| self.allocator.free(old);
        self.source_text = new_source;
    }

    /// Lay out the current document using the given theme, fonts, and dimensions.
    /// Replaces any existing layout tree.
    pub fn relayout(self: *Tab, theme: *const Theme, fonts: *const Fonts, layout_width: f32, y_offset: f32, left_offset: f32, show_line_numbers: bool) !void {
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
            left_offset,
            show_line_numbers,
        );
        self.scroll.total_height = tree.total_height;
        self.layout_tree = tree;
    }

    /// Set the file path and start watching for changes.
    /// Dupes and owns the path string.
    pub fn setFilePath(self: *Tab, path: []const u8) !void {
        const new_path = try self.allocator.dupe(u8, path);
        if (self.file_path) |old| self.allocator.free(old);
        self.file_path = new_path;
        self.file_watcher = FileWatcher.init(self.file_path.?);
    }

    /// Set the base directory for resolving relative image paths.
    /// Dupes and owns the path string.
    pub fn setBaseDir(self: *Tab, path: []const u8) !void {
        const new_dir = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(new_dir);
        try self.image_renderer.setBaseDir(path);
        if (self.base_dir) |old| self.allocator.free(old);
        self.base_dir = new_dir;
    }

    /// Reload the markdown file from disk, preserving scroll position.
    pub fn reloadFromDisk(self: *Tab, theme: *const Theme, fonts: *const Fonts, layout_width: f32, y_offset: f32, left_offset: f32, show_line_numbers: bool) void {
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

        self.relayout(theme, fonts, layout_width, y_offset, left_offset, show_line_numbers) catch |err| {
            std.log.err("Failed to layout reloaded document: {}", .{err});
        };

        self.scroll.y = saved_scroll_y;
        self.scroll.clamp();

        self.reload_indicator_ms = std.time.milliTimestamp();
        self.file_deleted = false;
    }

    /// Toggle edit mode on or off. On first entry, initializes the editor
    /// buffer from source_text. Subsequent toggles re-open/close the existing
    /// buffer without destroying edits.
    pub fn toggleEditMode(self: *Tab) !void {
        if (self.editor) |*ed| {
            ed.is_open = !ed.is_open;
        } else {
            const source = self.source_text orelse "";
            var ed = try EditorState.initFromSource(self.allocator, source);
            ed.is_open = true;
            self.editor = ed;
        }
    }

    /// Save the editor buffer to disk. Rebuilds source text from editor lines,
    /// writes to file_path, updates tab.source_text, and clears the dirty flag.
    /// Uses atomic write-to-temp + rename to avoid corrupting the file on partial writes.
    pub const SaveError = error{
        NoFilePath,
        NoEditor,
    };

    pub fn save(self: *Tab) !void {
        const editor = &(self.editor orelse return SaveError.NoEditor);
        const path = self.file_path orelse return SaveError.NoFilePath;

        const new_source = try editor.toSource(self.allocator);
        errdefer self.allocator.free(new_source);

        // Atomic write: write to a sibling temp file, then rename over the target.
        const dir = std.fs.cwd();
        var atomic = try dir.atomicFile(path, .{});
        defer atomic.deinit();
        try atomic.file.writeAll(new_source);
        try atomic.finish();

        // Update source_text
        if (self.source_text) |old| self.allocator.free(old);
        self.source_text = new_source;

        editor.is_dirty = false;
    }

    /// Return a display title for the tab (basename of file path, or "Untitled").
    pub fn title(self: *const Tab) []const u8 {
        const path = self.file_path orelse return "Untitled";
        return std.fs.path.basename(path);
    }

    /// Return true if an editor exists and has unsaved changes.
    pub fn isDirty(self: *const Tab) bool {
        const editor = self.editor orelse return false;
        return editor.is_dirty;
    }

    /// Return the display title with " *" appended if dirty.
    /// Writes into the provided buffer (must be at least `title().len + 2` bytes).
    /// Falls back to the plain title if the buffer is too small.
    pub fn titleWithIndicator(self: *const Tab, buf: []u8) []const u8 {
        const base = self.title();
        if (!self.isDirty()) return base;
        return std.fmt.bufPrint(buf, "{s} *", .{base}) catch base;
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
    try testing.expectEqual(@as(?[]u8, null), tab.source_text);
    try testing.expectEqual(@as(?EditorState, null), tab.editor);
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

test "Tab.loadMarkdown stores source_text" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    const md = "# Hello\n\nWorld";
    try tab.loadMarkdown(md);
    try testing.expect(tab.source_text != null);
    try testing.expectEqualStrings(md, tab.source_text.?);
}

test "Tab.loadMarkdown replaces source_text without leaking" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# First");
    try testing.expect(tab.source_text != null);
    try testing.expectEqualStrings("# First", tab.source_text.?);

    try tab.loadMarkdown("# Second");
    try testing.expect(tab.source_text != null);
    try testing.expectEqualStrings("# Second", tab.source_text.?);
}

test "Tab.loadMarkdown with empty string stores empty source_text" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("");
    try testing.expect(tab.source_text != null);
    try testing.expectEqual(@as(usize, 0), tab.source_text.?.len);
}

test "Tab.source_text is independent copy of input" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    var buf: [16]u8 = undefined;
    const text = "# Test";
    @memcpy(buf[0..text.len], text);
    try tab.loadMarkdown(buf[0..text.len]);

    // Mutate the original buffer — tab should still have the original value
    buf[0] = 'X';
    try testing.expect(tab.source_text != null);
    try testing.expectEqualStrings("# Test", tab.source_text.?);
}

test "Tab.deinit cleans up without leaks" {
    var tab = Tab.init(testing.allocator);
    try tab.setFilePath("/tmp/test.md");
    try tab.setBaseDir("/tmp");
    try tab.loadMarkdown("# Test source_text cleanup");
    tab.deinit();
}

test "Tab.toggleEditMode initializes editor from source_text on first call" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# Hello\n\nWorld");
    try testing.expectEqual(@as(?EditorState, null), tab.editor);

    try tab.toggleEditMode();
    try testing.expect(tab.editor != null);
    try testing.expect(tab.editor.?.is_open);
    try testing.expectEqualStrings("# Hello", tab.editor.?.getLineText(0).?);
}

test "Tab.toggleEditMode toggles off without destroying buffer" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# Test");
    try tab.toggleEditMode(); // open
    try testing.expect(tab.editor.?.is_open);

    try tab.toggleEditMode(); // close
    try testing.expect(!tab.editor.?.is_open);
    // Buffer still exists — editor is not null
    try testing.expect(tab.editor != null);
}

test "Tab.toggleEditMode re-opens existing buffer" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# Test");
    try tab.toggleEditMode(); // open — creates editor
    try tab.toggleEditMode(); // close
    try tab.toggleEditMode(); // re-open

    try testing.expect(tab.editor.?.is_open);
    // Same content preserved
    try testing.expectEqualStrings("# Test", tab.editor.?.getLineText(0).?);
}

test "Tab.toggleEditMode with no source_text creates editor from empty string" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    // No loadMarkdown called — source_text is null
    try tab.toggleEditMode();
    try testing.expect(tab.editor != null);
    try testing.expect(tab.editor.?.is_open);
    try testing.expectEqual(@as(usize, 1), tab.editor.?.lineCount());
    try testing.expectEqualStrings("", tab.editor.?.getLineText(0).?);
}

test "Tab.deinit cleans up editor without leaks" {
    var tab = Tab.init(testing.allocator);
    try tab.loadMarkdown("# Editor cleanup test");
    try tab.toggleEditMode();
    tab.deinit();
}

test "Tab.isDirty returns false when no editor" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try testing.expect(!tab.isDirty());
}

test "Tab.isDirty returns false for clean editor" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# Hello");
    try tab.toggleEditMode();
    try testing.expect(!tab.isDirty());
}

test "Tab.isDirty returns true after editing" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# Hello");
    try tab.toggleEditMode();
    try tab.editor.?.insertChar('x');
    try testing.expect(tab.isDirty());
}

test "Tab.titleWithIndicator returns plain title when clean" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setFilePath("/home/user/readme.md");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("readme.md", tab.titleWithIndicator(&buf));
}

test "Tab.titleWithIndicator appends * when dirty" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setFilePath("/home/user/readme.md");
    try tab.loadMarkdown("# Hello");
    try tab.toggleEditMode();
    try tab.editor.?.insertChar('x');

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("readme.md *", tab.titleWithIndicator(&buf));
}

test "Tab.titleWithIndicator with Untitled when dirty" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.toggleEditMode();
    try tab.editor.?.insertChar('x');

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Untitled *", tab.titleWithIndicator(&buf));
}

test "Tab.save returns NoEditor when no editor" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setFilePath("/tmp/test_save.md");
    const result = tab.save();
    try testing.expectError(Tab.SaveError.NoEditor, result);
}

test "Tab.save returns NoFilePath when file_path is null" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.loadMarkdown("# Test");
    try tab.toggleEditMode();
    const result = tab.save();
    try testing.expectError(Tab.SaveError.NoFilePath, result);
}

test "Tab.save writes content and clears dirty flag" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    // Create a temp file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "test.md", .data = "# Original" });
    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.md");
    defer testing.allocator.free(path);

    try tab.setFilePath(path);
    try tab.loadMarkdown("# Original");
    try tab.toggleEditMode();

    // Make an edit
    tab.editor.?.setCursor(0, 10);
    try tab.editor.?.insertBytes(" Modified");
    try testing.expect(tab.isDirty());

    // Save
    try tab.save();
    try testing.expect(!tab.isDirty());

    // Verify file contents
    const saved = try tmp_dir.dir.readFileAlloc(testing.allocator, "test.md", 4096);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("# Original Modified", saved);

    // Verify source_text was updated
    try testing.expectEqualStrings("# Original Modified", tab.source_text.?);
}

test "Tab.titleWithIndicator falls back to plain title when buffer too small" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setFilePath("/home/user/readme.md");
    try tab.toggleEditMode();
    try tab.editor.?.insertChar('x');

    // Buffer too small for "readme.md *" (11 bytes)
    var tiny_buf: [1]u8 = undefined;
    try testing.expectEqualStrings("readme.md", tab.titleWithIndicator(&tiny_buf));
}

test "Tab.save returns error for non-existent file path" {
    var tab = Tab.init(testing.allocator);
    defer tab.deinit();

    try tab.setFilePath("/tmp/nonexistent_dir_12345/nosuchfile.md");
    try tab.loadMarkdown("# Test");
    try tab.toggleEditMode();
    try tab.editor.?.insertChar('x');

    const result = tab.save();
    // Exact error type depends on OS and atomicFile internals, so check any-error.
    try testing.expect(std.meta.isError(result));
    // Dirty flag should NOT be cleared on error
    try testing.expect(tab.isDirty());
}
