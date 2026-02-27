const std = @import("std");
const rl = @import("raylib");

const App = @import("app.zig").App;
const Theme = @import("theme/theme.zig").Theme;
const theme_loader = @import("theme/theme_loader.zig");

// Test imports: ensure the test runner discovers tests in all subsystems.
// These are only referenced at comptime during `zig build test`.
test {
    _ = @import("parser/markdown_parser.zig");
    _ = @import("parser/gfm_extensions.zig");
    _ = @import("parser/ast.zig");
    _ = @import("layout/layout_types.zig");
    _ = @import("theme/theme_loader.zig");
    _ = @import("viewport/scroll.zig");
    _ = @import("render/syntax_highlight.zig");
    _ = @import("utils/slice_utils.zig");
    _ = @import("file_watcher.zig");
    _ = @import("menu_bar.zig");
    _ = @import("file_dialog.zig");
    _ = @import("app.zig");
    // Search subsystem tests
    _ = @import("search/search_state.zig");
    _ = @import("search/searcher.zig");
    // Mermaid subsystem tests
    _ = @import("mermaid/parse_utils.zig");
    _ = @import("mermaid/tokenizer.zig");
    _ = @import("mermaid/detector.zig");
    _ = @import("mermaid/models/pie_model.zig");
    _ = @import("mermaid/models/gantt_model.zig");
    _ = @import("mermaid/models/state_model.zig");
    _ = @import("mermaid/parsers/flowchart.zig");
    _ = @import("mermaid/parsers/sequence.zig");
    _ = @import("mermaid/parsers/pie.zig");
    _ = @import("mermaid/parsers/gantt.zig");
    _ = @import("mermaid/parsers/class_diagram.zig");
    _ = @import("mermaid/parsers/er.zig");
    _ = @import("mermaid/parsers/state.zig");
    _ = @import("mermaid/parsers/mindmap.zig");
    _ = @import("mermaid/parsers/gitgraph.zig");
    _ = @import("mermaid/parsers/journey.zig");
    _ = @import("mermaid/parsers/timeline_diagram.zig");
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.log.err("Memory leak detected by GeneralPurposeAllocator", .{});
        }
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var file_path: ?[]const u8 = null;
    var theme_path: ?[]const u8 = null;
    var use_dark: bool = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i < args.len) {
                theme_path = args[i];
            } else {
                std.log.err("--theme requires a path argument", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "--dark")) {
            use_dark = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            file_path = arg;
        }
    }

    const file_content: ?[]u8 = if (file_path) |path|
        std.fs.cwd().readFileAlloc(allocator, path, App.max_file_size) catch |err| {
            std.log.err("Failed to read file '{s}': {}", .{ path, err });
            return 1;
        }
    else
        null;
    defer if (file_content) |content| allocator.free(content);

    const custom_theme: ?Theme = if (theme_path) |tp|
        theme_loader.loadFromFile(allocator, tp) catch |err| {
            std.log.err("Failed to load theme '{s}': {}", .{ tp, err });
            return 1;
        }
    else
        null;

    rl.initWindow(960, 720, "Selkie \xe2\x80\x94 Markdown Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    rl.setWindowState(.{ .window_resizable = true });

    var app = App.init(allocator);
    defer app.deinit();

    app.setTheme(custom_theme, use_dark);

    try app.loadFonts();
    defer app.unloadFonts();

    if (file_path) |path| {
        const dir = std.fs.path.dirname(path) orelse ".";
        try app.setBaseDir(dir);
        app.setFilePath(path);
    }

    if (file_content) |content| {
        app.loadMarkdown(content) catch |err| {
            std.log.err("Failed to parse markdown: {}", .{err});
        };
    }

    while (!rl.windowShouldClose()) {
        app.update();
        app.draw();
    }

    return 0;
}
