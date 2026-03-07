const std = @import("std");
const rl = @import("raylib");
const build_options = @import("build_options");

const App = @import("app.zig").App;
const Theme = @import("theme/theme.zig").Theme;
const theme_loader = @import("theme/theme_loader.zig");
const stdin_reader = @import("stdin_reader.zig");
const xdg = @import("xdg.zig");
const ScrollPositionStore = @import("scroll_positions.zig").ScrollPositionStore;
const png_exporter = @import("export/png_exporter.zig");
const PngExportConfig = png_exporter.PngExportConfig;
const export_cli = @import("export/cli.zig");
const screenshot_capture = @import("export/screenshot_capture.zig");

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
    _ = @import("render/scrollbar.zig");
    _ = @import("utils/slice_utils.zig");
    _ = @import("utils/text_utils.zig");
    _ = @import("file_watcher.zig");
    _ = @import("menu_bar.zig");
    _ = @import("file_dialog.zig");
    _ = @import("app.zig");
    _ = @import("asset_paths.zig");
    _ = @import("xdg.zig");
    _ = @import("scroll_positions.zig");
    _ = @import("stdin_reader.zig");
    _ = @import("tab.zig");
    _ = @import("tab_bar.zig");
    _ = @import("toc_sidebar.zig");
    // Search subsystem tests
    _ = @import("search/search_state.zig");
    _ = @import("search/searcher.zig");
    // Export subsystem tests
    _ = @import("export/pdf_writer.zig");
    _ = @import("export/pdf_exporter.zig");
    _ = @import("export/save_dialog.zig");
    _ = @import("export/cli.zig");
    _ = @import("export/png_exporter.zig");
    _ = @import("export/screenshot_capture.zig");
    _ = @import("export/full_document_capture.zig");
    // Mermaid subsystem tests
    _ = @import("mermaid/parse_utils.zig");
    _ = @import("mermaid/tokenizer.zig");
    _ = @import("mermaid/detector.zig");
    _ = @import("mermaid/models/pie_model.zig");
    _ = @import("mermaid/models/gantt_model.zig");
    _ = @import("mermaid/models/state_model.zig");
    _ = @import("mermaid/models/graph.zig");
    _ = @import("mermaid/models/sequence_model.zig");
    _ = @import("mermaid/models/mindmap_model.zig");
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
    // Editor subsystem tests
    _ = @import("editor/editor_state.zig");
    // Command subsystem tests
    _ = @import("command/command_state.zig");
    // Modal dialog tests
    _ = @import("modal_dialog.zig");
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

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // Check for `selkie export` subcommand before general flag parsing
    if (args.len > 1 and std.mem.eql(u8, args[1], "export")) {
        return runExportSubcommand(allocator, args[2..], stdout, stderr);
    }

    // Collect all positional args as file paths
    var file_paths = std.ArrayList([]const u8).init(allocator);
    defer file_paths.deinit();

    var theme_path: ?[]const u8 = null;
    var use_dark = false;
    var explicit_stdin = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            stdout.writeAll(usage_text) catch {}; // broken pipe is fine
            return 0;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            stdout.print("selkie {s}\n", .{build_options.version}) catch {}; // broken pipe is fine
            return 0;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i < args.len) {
                theme_path = args[i];
            } else {
                std.log.err("--theme requires a path argument", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "--dark")) {
            use_dark = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            explicit_stdin = true;
        } else if (std.mem.eql(u8, arg, "--export-png") or
            std.mem.eql(u8, arg, "--width") or
            std.mem.eql(u8, arg, "--height") or
            std.mem.eql(u8, arg, "--export-mode"))
        {
            // These flags take a value argument; skip the next arg
            i += 1;
        } else if (std.mem.eql(u8, arg, "--include-chrome") or
            std.mem.eql(u8, arg, "--full-document") or
            std.mem.eql(u8, arg, "--quiet") or
            std.mem.eql(u8, arg, "-q"))
        {
            // Boolean flags for PNG export / headless mode; no value to skip
        } else if (std.mem.startsWith(u8, arg, "-")) {
            stderr.print("selkie: unknown option '{s}'\n", .{arg}) catch return 1;
            stderr.writeAll("Try 'selkie --help' for more information.\n") catch return 1;
            return 1;
        } else {
            try file_paths.append(arg);
        }
    }

    // Parse PNG export configuration from CLI args (--export-png flag interface)
    const png_export_config: ?PngExportConfig = PngExportConfig.parseFromArgs(args[1..]) catch |err| {
        const msg: []const u8 = switch (err) {
            error.MissingValue => "missing value for PNG export option",
            error.InvalidNumber => "invalid --width or --height (must be integer between 32 and 16384)",
            error.InvalidMode => "invalid --export-mode (must be 'render' or 'edit')",
        };
        stderr.print("selkie: {s}\n", .{msg}) catch return 1;
        stderr.writeAll("Try 'selkie --help' for more information.\n") catch return 1;
        return 1;
    };

    // Headless mode: when --export-png is specified, suppress raylib's internal
    // log output to keep stdout/stderr clean for piping and machine consumption.
    if (png_export_config != null) {
        rl.setTraceLogLevel(.none);
    }

    // Read stdin content if no file args given
    const stdin_content: ?[]u8 = if (file_paths.items.len == 0) blk: {
        const result = stdin_reader.readStdin(allocator, App.max_file_size) catch |err| switch (err) {
            error.EmptyStdin => break :blk null,
            error.StdinTooLarge => {
                std.log.err("Stdin input exceeds maximum size ({d} bytes)", .{App.max_file_size});
                return 1;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.err("Failed to read stdin: {}", .{err});
                return 1;
            },
        };
        if (result == null and explicit_stdin) {
            std.log.err("stdin is a terminal \u{2014} pipe content or use redirection", .{});
            return 1;
        }
        break :blk result;
    } else null;
    defer if (stdin_content) |s| allocator.free(s);

    const source_is_stdin = file_paths.items.len == 0 and stdin_content != null;

    const custom_theme: ?Theme = if (theme_path) |tp|
        theme_loader.loadFromFile(allocator, tp) catch |err| {
            std.log.err("Failed to load theme '{s}': {}", .{ tp, err });
            return 1;
        }
    else
        null;

    // Buffer declared in outer scope so the formatted title outlives initWindow
    var title_buf: [256:0]u8 = undefined;
    const window_title: [:0]const u8 = if (source_is_stdin)
        "Selkie \u{2014} stdin"
    else if (file_paths.items.len == 1)
        std.fmt.bufPrintZ(&title_buf, "Selkie \xe2\x80\x94 {s}", .{std.fs.path.basename(file_paths.items[0])}) catch "Selkie"
    else
        "Selkie \u{2014} Markdown Viewer";

    // Use export dimensions for window size when in headless export mode
    const window_width: c_int = if (png_export_config) |cfg| @intCast(cfg.width) else 960;
    const window_height: c_int = if (png_export_config) |cfg| @intCast(cfg.height) else 720;

    // Hidden window mode: when exporting PNG via CLI, hide the window so no
    // visible UI flashes on screen. The OpenGL context is still created and
    // fully functional for rendering and framebuffer capture.
    if (png_export_config != null) {
        rl.setConfigFlags(png_exporter.headlessWindowFlags());
    }

    rl.initWindow(window_width, window_height, window_title);
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    // Only make the window resizable in interactive mode
    if (png_export_config == null) {
        rl.setWindowState(.{ .window_resizable = true });
    }

    var app = App.init(allocator);
    defer app.deinit();

    // Load saved scroll positions from XDG data directory (heap-allocated for stable pointer).
    // Skipped in headless mode — scroll positions are irrelevant for CLI export.
    const scroll_store: ?*ScrollPositionStore = if (png_export_config != null) null else blk: {
        const data_home = xdg.getDataHome(allocator) catch |err| {
            std.log.warn("Could not resolve XDG data home: {}", .{err});
            break :blk null;
        };
        defer allocator.free(data_home);

        xdg.ensureDir(data_home) catch |err| {
            std.log.warn("Could not create data directory '{s}': {}", .{ data_home, err });
            break :blk null;
        };

        const positions_path = std.fs.path.join(allocator, &.{ data_home, "positions.json" }) catch {
            std.log.warn("Could not allocate path for scroll positions", .{});
            break :blk null;
        };
        defer allocator.free(positions_path);

        const store = allocator.create(ScrollPositionStore) catch {
            std.log.warn("Could not allocate scroll position store", .{});
            break :blk null;
        };
        store.* = ScrollPositionStore.load(allocator, positions_path) catch |err| {
            std.log.warn("Could not load scroll positions: {}", .{err});
            allocator.destroy(store);
            break :blk null;
        };
        break :blk store;
    };
    defer if (scroll_store) |s| {
        s.deinit();
        allocator.destroy(s);
    };

    if (scroll_store) |s| {
        app.setScrollPositions(s);
    }

    app.setTheme(custom_theme, use_dark);

    try app.loadFonts();
    defer app.unloadFonts();

    // Open files in tabs
    if (file_paths.items.len > 0) {
        for (file_paths.items) |path| {
            app.newTabWithFile(path) catch |err| {
                std.log.err("Failed to open '{s}': {}", .{ path, err });
            };
        }
    } else {
        // Create a default tab for stdin or empty state
        _ = app.newTab() catch |err| {
            std.log.err("Failed to create tab: {}", .{err});
            return 1;
        };

        if (stdin_content) |c| {
            app.loadMarkdown(c) catch |err| {
                std.log.err("Failed to parse markdown: {}", .{err});
            };
        }
    }

    // Headless PNG export path: render one frame, capture, write PNG, exit
    if (png_export_config) |cfg| {
        return performHeadlessExport(&app, cfg);
    }

    // Interactive main loop
    while (!app.should_quit) {
        if (rl.windowShouldClose()) {
            app.requestClose();
        }
        app.update();
        app.draw();
    }

    return 0;
}

/// Perform headless PNG export: set mode, render one frame, capture, write, exit.
///
/// Returns 0 on success, 1 on failure. Errors are logged to stderr unless
/// `cfg.quiet` is set. A JSON status line is always written to stderr for
/// machine consumption by Claude Code and other automation tools.
fn performHeadlessExport(app: *App, cfg: PngExportConfig) u8 {
    // Set the view mode based on export config
    switch (cfg.mode) {
        .edit => app.setViewMode(.editor_only),
        .render => app.setViewMode(.preview_only),
    }

    // Render one frame so the content is drawn to the framebuffer
    app.update();
    app.draw();

    const result: u8 = if (cfg.full_document)
        performFullDocumentExport(app, cfg)
    else
        performViewportExport(app, cfg);

    // Emit machine-readable JSON status to stderr for Claude Code / scripting.
    // Always emitted (even in quiet mode) so automation tools can reliably
    // parse the result regardless of log verbosity settings.
    if (result == 0) {
        const out_label: []const u8 = if (cfg.isStdout()) "-" else cfg.output_path;
        png_exporter.writeHeadlessResult(out_label, cfg.width, cfg.height);
    }

    return result;
}

/// Export the full document (tiled capture for documents taller than viewport).
///
/// When `include_chrome` is set, the output includes UI chrome (menu bar,
/// tab bar) at the top of the image, increasing total height by the chrome
/// height. Without it, only the document content is captured.
fn performFullDocumentExport(app: *App, cfg: PngExportConfig) u8 {
    const err_label = if (cfg.include_chrome) "Full-document PNG export (with chrome)" else "Full-document PNG export";
    var capture = blk: {
        break :blk (if (cfg.include_chrome)
            if (cfg.width > 0) app.captureFullDocumentWithChromeAndWidth(cfg.width) else app.captureFullDocumentWithChrome()
        else if (cfg.width > 0) app.captureFullDocumentWithWidth(cfg.width) else app.captureFullDocument()) catch |err| {
            std.log.err("{s} failed: {}", .{ err_label, err });
            return 1;
        };
    };
    defer capture.deinit();

    if (cfg.isStdout()) {
        // Encode to PNG in memory and write to stdout for piping
        var png_buf = png_exporter.encodePixelsToPng(
            app.allocator,
            capture.pixels,
            capture.width,
            capture.height,
        ) catch |err| {
            if (!cfg.quiet) std.log.err("PNG encoding failed: {}", .{err});
            png_exporter.writeHeadlessError("PNG encoding failed");
            return 1;
        };
        defer png_buf.deinit();

        png_exporter.writePngToStdout(png_buf.data) catch {
            png_exporter.writeHeadlessError("failed to write PNG to stdout");
            return 1;
        };
    } else {
        // Encode the pixel buffer as PNG and write to disk
        png_exporter.exportPixelsToFile(
            capture.pixels,
            capture.width,
            capture.height,
            cfg.output_path,
        ) catch |err| {
            if (!cfg.quiet) std.log.err("Failed to write PNG to '{s}': {}", .{ cfg.output_path, err });
            png_exporter.writeHeadlessError("failed to write PNG file");
            return 1;
        };
    }

    if (!cfg.quiet) std.log.info("Full-document PNG exported to '{s}' ({d}x{d})", .{ cfg.output_path, capture.width, capture.height });
    return 0;
}

/// Export the current viewport (single framebuffer capture).
///
/// Supports writing to a file or to stdout (when output_path is "-").
/// In quiet mode, log messages are suppressed; JSON error status is still
/// emitted to stderr on failure for machine consumption.
fn performViewportExport(app: *App, cfg: PngExportConfig) u8 {
    const capture_params = screenshot_capture.ContentCaptureParams{
        .width = cfg.width,
        .height = cfg.height,
    };
    const result = if (cfg.include_chrome)
        app.captureWithChrome(capture_params)
    else
        app.captureContentScreenshot(capture_params);

    var captured = result catch |err| {
        const label = if (cfg.include_chrome) "Chrome-included" else "Content-only";
        if (!cfg.quiet) std.log.err("{s} PNG export failed: {}", .{ label, err });
        png_exporter.writeHeadlessError(if (cfg.include_chrome) "chrome-included capture failed" else "content capture failed");
        return 1;
    };
    defer captured.deinit();

    if (cfg.isStdout()) {
        png_exporter.writePngToStdout(captured.slice()) catch {
            png_exporter.writeHeadlessError("failed to write PNG to stdout");
            return 1;
        };
    } else {
        captured.writeToFile(cfg.output_path) catch |err| {
            if (!cfg.quiet) std.log.err("Failed to write PNG to '{s}': {}", .{ cfg.output_path, err });
            png_exporter.writeHeadlessError("failed to write PNG file");
            return 1;
        };
    }

    if (!cfg.quiet) std.log.info("PNG exported to '{s}' ({d}x{d})", .{ cfg.output_path, cfg.width, cfg.height });
    return 0;
}

/// Handle the `selkie export` subcommand.
///
/// Parses export-specific arguments, sets up a hidden window with OpenGL context,
/// loads the input file, renders one frame, captures the output as PNG, and exits.
fn runExportSubcommand(
    allocator: std.mem.Allocator,
    sub_args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Parse export subcommand arguments
    const cmd = export_cli.parseExportArgs(sub_args) catch |err| {
        if (err == export_cli.ParseError.HelpRequested) {
            stdout.writeAll(export_cli.export_help_text) catch {};
            return 0;
        }
        stderr.print("selkie export: {s}\n", .{export_cli.errorMessage(err)}) catch return 1;
        stderr.writeAll("Try 'selkie export --help' for more information.\n") catch return 1;
        return 1;
    };

    // Resolve output path: use explicit --output or derive from input filename.
    // Track the allocated name separately so we can free it without @constCast.
    const allocated_name: ?[]u8 = if (cmd.output_path == null)
        png_exporter.buildPngName(allocator, cmd.input_path, "export.png") catch {
            std.log.err("Failed to allocate output path", .{});
            return 1;
        }
    else
        null;
    defer if (allocated_name) |name| allocator.free(name);
    const output_path: []const u8 = cmd.output_path orelse allocated_name.?;

    // Build the PngExportConfig for the export pipeline
    const cfg = cmd.toPngExportConfig(output_path);

    // Suppress raylib trace logs in headless mode
    rl.setTraceLogLevel(.none);

    // Create a hidden window with OpenGL context for rendering
    rl.setConfigFlags(png_exporter.headlessWindowFlags());
    rl.initWindow(@intCast(cfg.width), @intCast(cfg.height), "Selkie Export");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var app = App.init(allocator);
    defer app.deinit();

    // Apply theme settings
    const custom_theme: ?Theme = if (cmd.theme_path) |tp|
        theme_loader.loadFromFile(allocator, tp) catch |err| {
            std.log.err("Failed to load theme '{s}': {}", .{ tp, err });
            return 1;
        }
    else
        null;
    app.setTheme(custom_theme, cmd.dark_theme);

    try app.loadFonts();
    defer app.unloadFonts();

    // Validate input file exists before creating the window/tab.
    // newTabWithFile swallows file-read errors (returns void), so we
    // check upfront to produce a clear exit code 1 for missing files.
    std.fs.cwd().access(cmd.input_path, .{}) catch {
        std.log.err("Cannot access input file '{s}'", .{cmd.input_path});
        return 1;
    };

    // Open the input file
    app.newTabWithFile(cmd.input_path) catch |err| {
        std.log.err("Failed to open '{s}': {}", .{ cmd.input_path, err });
        return 1;
    };

    // Perform the headless export (sets mode, renders frame, captures PNG)
    return performHeadlessExport(&app, cfg);
}

const usage_text =
    \\Usage: selkie [OPTIONS] [FILE...]
    \\       selkie export [EXPORT_OPTIONS] --input FILE
    \\
    \\A markdown viewer with GFM support and Mermaid chart rendering.
    \\
    \\Arguments:
    \\  FILE...           Markdown files to open (opens in tabs)
    \\  -                 Read markdown from stdin
    \\
    \\Options:
    \\  --theme PATH      Load a custom theme JSON file
    \\  --dark            Use the built-in dark theme
    \\  -h, --help        Show this help message and exit
    \\  -V, --version     Show version and exit
    \\
    \\PNG Export (headless):
    \\  --export-png PATH Export current view as PNG and exit (use '-' for stdout)
    \\  --width N         PNG width in pixels (default: 1200, range: 32-16384)
    \\  --height N        PNG height in pixels (default: 900, range: 32-16384)
    \\  --export-mode M   Export mode: 'render' (default) or 'edit'
    \\  --include-chrome  Include UI chrome (menu bar, scrollbars)
    \\  --full-document   Capture full document, not just viewport
    \\  -q, --quiet       Suppress log output (for scripting/automation)
    \\
    \\PNG Export (subcommand):
    \\  selkie export     Headless PNG export (run 'selkie export --help')
    \\
    \\Headless mode runs without showing a window. Output goes to the specified
    \\file, or to stdout when PATH is '-'. A JSON status line is always written
    \\to stderr for machine consumption:
    \\  {"status":"ok","path":"<path>","width":<w>,"height":<h>}
    \\
    \\Examples:
    \\  selkie --export-png output.png document.md
    \\  selkie --export-png - document.md > screenshot.png
    \\  selkie --export-png out.png --width 1920 --height 1080 -q doc.md
    \\  cat README.md | selkie --export-png - --full-document > full.png
    \\
;
