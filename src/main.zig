const std = @import("std");
const rl = @import("raylib");
const App = @import("app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Read markdown file
    var file_content: ?[]u8 = null;
    defer if (file_content) |content| allocator.free(content);

    if (args.len > 1) {
        const path = args[1];
        file_content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read file '{s}': {}", .{ path, err });
            return;
        };
    }

    // Init window
    rl.initWindow(960, 720, "Selkie — Markdown Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    rl.setWindowState(.{ .window_resizable = true });

    // Init app
    var app = App.init(allocator);
    defer app.deinit();

    try app.loadFonts();
    defer app.unloadFonts();

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
