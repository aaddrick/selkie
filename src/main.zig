const std = @import("std");
const rl = @import("raylib");
const App = @import("app.zig").App;
const theme_loader = @import("theme/theme_loader.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args
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
                return;
            }
        } else if (std.mem.eql(u8, arg, "--dark")) {
            use_dark = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            file_path = arg;
        }
    }

    // Read markdown file
    var file_content: ?[]u8 = null;
    defer if (file_content) |content| allocator.free(content);

    if (file_path) |path| {
        file_content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read file '{s}': {}", .{ path, err });
            return;
        };
    }

    // Load custom theme if specified
    var custom_theme: ?@import("theme/theme.zig").Theme = null;
    if (theme_path) |tp| {
        custom_theme = theme_loader.loadFromFile(allocator, tp) catch |err| {
            std.log.err("Failed to load theme '{s}': {}", .{ tp, err });
            return;
        };
    }

    // Init window
    rl.initWindow(960, 720, "Selkie \xe2\x80\x94 Markdown Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    rl.setWindowState(.{ .window_resizable = true });

    // Init app
    var app = App.init(allocator);
    defer app.deinit();

    app.setTheme(custom_theme, use_dark);

    try app.loadFonts();
    defer app.unloadFonts();

    // Set base directory for relative image paths
    if (file_path) |path| {
        const dir = std.fs.path.dirname(path) orelse ".";
        app.setBaseDir(dir);
    }

    // Load document
    if (file_content) |content| {
        app.loadMarkdown(content) catch |err| {
            std.log.err("Failed to parse markdown: {}", .{err});
        };
    }

    // Main loop
    while (!rl.windowShouldClose()) {
        app.update();
        app.draw();
    }
}
