//! PNG export module for Selkie.
//!
//! Provides CLI-driven PNG export of the current viewport or full document
//! in both edit and render modes. Supports configurable dimensions and
//! output path for automation by external tools (e.g., Claude Code).
//!
//! Encoding paths:
//! 1. From raw RGBA pixel buffers ([]const u8 with width/height)
//! 2. From raylib Image structs (e.g. captured via loadImageFromTexture)
//!
//! Uses raylib's built-in PNG encoder (stb_image_write) for encoding.

const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.png_exporter);

/// PNG export configuration parsed from CLI flags.
pub const PngExportConfig = struct {
    /// Output file path ("-" means stdout)
    output_path: []const u8,
    width: u32 = default_width,
    height: u32 = default_height,
    mode: ExportMode = .render,
    include_chrome: bool = false,
    full_document: bool = false,
    quiet: bool = false,

    pub fn isStdout(self: PngExportConfig) bool {
        return std.mem.eql(u8, self.output_path, "-");
    }

    pub const default_width: u32 = 1200;
    pub const default_height: u32 = 900;
    pub const min_dimension: u32 = 32;
    pub const max_dimension: u32 = 16384;

    pub const ExportMode = enum {
        render,
        edit,
    };

    /// Parse PNG export flags from CLI args.
    /// Returns null if --export-png is not present.
    /// Returns error for malformed arguments.
    ///
    /// Flags can appear in any order — --width/--height work both before
    /// and after --export-png.
    pub fn parseFromArgs(args: []const []const u8) ParseError!?PngExportConfig {
        // Two-pass approach: first check if --export-png is present at all,
        // then parse all flags into the config. This makes flag order irrelevant.
        var has_export = false;
        var export_path: ?[]const u8 = null;

        // Pass 1: find --export-png and its value
        {
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--export-png")) {
                    i += 1;
                    if (i >= args.len) return ParseError.MissingValue;
                    has_export = true;
                    export_path = args[i];
                    break;
                }
            }
        }

        if (!has_export) {
            // Still validate that any --width/--height values are well-formed,
            // even when not exporting (fail early on typos).
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "--height")) {
                    i += 1;
                    if (i >= args.len) return ParseError.MissingValue;
                    _ = try parseDimension(args[i]);
                } else if (std.mem.eql(u8, arg, "--export-mode")) {
                    i += 1;
                    if (i >= args.len) return ParseError.MissingValue;
                    if (!std.mem.eql(u8, args[i], "render") and !std.mem.eql(u8, args[i], "edit")) {
                        return ParseError.InvalidMode;
                    }
                }
            }
            return null;
        }

        // Pass 2: parse all export-related flags into config
        var config = PngExportConfig{
            .output_path = export_path.?,
        };

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--export-png")) {
                i += 1; // skip value (already captured)
            } else if (std.mem.eql(u8, arg, "--width")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                config.width = try parseDimension(args[i]);
            } else if (std.mem.eql(u8, arg, "--height")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                config.height = try parseDimension(args[i]);
            } else if (std.mem.eql(u8, arg, "--export-mode")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingValue;
                const mode_str = args[i];
                if (std.mem.eql(u8, mode_str, "render")) {
                    config.mode = .render;
                } else if (std.mem.eql(u8, mode_str, "edit")) {
                    config.mode = .edit;
                } else {
                    return ParseError.InvalidMode;
                }
            } else if (std.mem.eql(u8, arg, "--include-chrome")) {
                config.include_chrome = true;
            } else if (std.mem.eql(u8, arg, "--full-document")) {
                config.full_document = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                config.quiet = true;
            }
        }
        return config;
    }

    /// Parse and validate a dimension value from a CLI argument string.
    pub fn parseDimension(value: []const u8) ParseError!u32 {
        const val = std.fmt.parseInt(u32, value, 10) catch return ParseError.InvalidNumber;
        if (val < min_dimension or val > max_dimension) return ParseError.InvalidNumber;
        return val;
    }

    pub const ParseError = error{
        MissingValue,
        InvalidNumber,
        InvalidMode,
    };
};

/// Returns the raylib ConfigFlags needed for headless PNG export.
///
/// When exporting PNG via CLI, we want a hidden window: an OpenGL context
/// is created (required for rendering/framebuffer capture) but the window
/// is never shown on screen, so there is no visible flash.
pub fn headlessWindowFlags() rl.ConfigFlags {
    return .{ .window_hidden = true };
}

/// Build a default PNG filename by replacing the extension of the input file.
/// If `file_path` is null, uses `fallback_name` as the output filename.
pub fn buildPngName(allocator: Allocator, file_path: ?[]const u8, fallback_name: []const u8) Allocator.Error![]u8 {
    const path = file_path orelse return try allocator.dupe(u8, fallback_name);
    const basename = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOf(u8, basename, ".")) |dot_idx|
        basename[0..dot_idx]
    else
        basename;

    return try std.fmt.allocPrint(allocator, "{s}.png", .{stem});
}

/// Take a screenshot of the current raylib framebuffer and save as PNG.
/// This captures exactly what is on screen (viewport mode).
pub fn exportScreenshot(output_path: [:0]const u8) ExportError!void {
    rl.takeScreenshot(output_path);
    log.info("Exported viewport screenshot to '{s}'", .{output_path});
}

pub const ExportError = error{
    RenderFailed,
    WriteFailed,
    EncodeFailed,
    InvalidDimensions,
    InvalidPixelData,
};

/// Owned PNG buffer. Caller must call deinit() to free.
pub const PngBuffer = struct {
    data: []const u8, // owned
    allocator: Allocator,

    pub fn deinit(self: *PngBuffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

/// Encode raw RGBA pixel data to PNG and write to a file.
///
/// `pixels` must contain exactly `width * height * 4` bytes in RGBA order.
/// The file is created (or overwritten) at `output_path`.
pub fn exportPixelsToFile(
    pixels: []const u8,
    width: u32,
    height: u32,
    output_path: []const u8,
) ExportError!void {
    if (width == 0 or height == 0) return ExportError.InvalidDimensions;

    const expected_len: usize = @as(usize, width) * @as(usize, height) * 4;
    if (pixels.len != expected_len) return ExportError.InvalidPixelData;

    // Build a raylib Image from the raw pixel buffer.
    // raylib's ExportImageToMemory expects a mutable data pointer but does not modify it.
    var image = rl.Image{
        .data = @constCast(@ptrCast(pixels.ptr)),
        .width = @intCast(width),
        .height = @intCast(height),
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };

    return exportImageToFile(&image, output_path);
}

/// Encode a raylib Image to PNG and write to a file.
///
/// The Image is not modified or freed — caller retains ownership.
pub fn exportImageToFile(
    image: *rl.Image,
    output_path: []const u8,
) ExportError!void {
    // Use raylib's ExportImageToMemory to get PNG bytes, then write via std fs.
    // This avoids raylib's file path handling (which uses C strings) and gives
    // us proper Zig error reporting.
    var file_size: c_int = 0;
    const png_ptr = rl.cdef.ExportImageToMemory(image.*, ".png", &file_size) orelse {
        log.err("raylib PNG encoding failed", .{});
        return ExportError.EncodeFailed;
    };
    defer rl.memFree(@ptrCast(png_ptr));

    if (file_size <= 0) {
        log.err("raylib PNG encoding produced empty output", .{});
        return ExportError.EncodeFailed;
    }

    const png_data = png_ptr[0..@intCast(file_size)];

    writePngFile(output_path, png_data) catch return ExportError.WriteFailed;

    log.info("Exported PNG ({d}x{d}) to '{s}' ({d} bytes)", .{
        image.width, image.height, output_path, file_size,
    });
}

/// Encode raw RGBA pixel data to PNG in memory.
///
/// Returns an owned PngBuffer. Caller must call deinit() to free.
pub fn encodePixelsToPng(
    allocator: Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) (ExportError || Allocator.Error)!PngBuffer {
    if (width == 0 or height == 0) return ExportError.InvalidDimensions;

    const expected_len: usize = @as(usize, width) * @as(usize, height) * 4;
    if (pixels.len != expected_len) return ExportError.InvalidPixelData;

    var image = rl.Image{
        .data = @constCast(@ptrCast(pixels.ptr)),
        .width = @intCast(width),
        .height = @intCast(height),
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };

    return encodeImageToPng(allocator, &image);
}

/// Encode a raylib Image to PNG in memory.
///
/// Returns an owned PngBuffer. Caller must call deinit() to free.
pub fn encodeImageToPng(
    allocator: Allocator,
    image: *rl.Image,
) (ExportError || Allocator.Error)!PngBuffer {
    var file_size: c_int = 0;
    const png_ptr = rl.cdef.ExportImageToMemory(image.*, ".png", &file_size) orelse {
        log.err("raylib PNG encoding failed", .{});
        return ExportError.EncodeFailed;
    };
    defer rl.memFree(@ptrCast(png_ptr));

    if (file_size <= 0) {
        log.err("raylib PNG encoding produced empty output", .{});
        return ExportError.EncodeFailed;
    }

    const size: usize = @intCast(file_size);
    const owned = try allocator.alloc(u8, size);
    errdefer allocator.free(owned);
    @memcpy(owned, png_ptr[0..size]);

    return PngBuffer{
        .data = owned,
        .allocator = allocator,
    };
}

/// Write raw bytes to a file, creating or overwriting it.
fn writePngFile(path: []const u8, data: []const u8) !void {
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        log.err("Failed to create file '{s}': {}", .{ path, err });
        return err;
    };
    defer file.close();
    file.writeAll(data) catch |err| {
        log.err("Failed to write to '{s}': {}", .{ path, err });
        return err;
    };
}

/// Write PNG data to stdout (for `--export-png -` piping mode).
///
/// Writes raw PNG bytes directly to stdout. In quiet mode, no log messages
/// are emitted, making the output suitable for piping to other tools.
pub fn writePngToStdout(data: []const u8) ExportError!void {
    const stdout = std.io.getStdOut();
    stdout.writeAll(data) catch {
        log.err("Failed to write PNG data to stdout", .{});
        return ExportError.WriteFailed;
    };
}

/// Write a JSON status message to stderr for machine consumption.
///
/// This is used in headless/scripting mode so that Claude Code and other
/// automation tools can parse structured output from PNG export operations.
/// Output goes to stderr so it doesn't interfere with PNG data on stdout.
///
/// Format: `{"status":"ok","path":"<path>","width":<w>,"height":<h>}`
/// Or on error: `{"status":"error","message":"<msg>"}`
pub fn writeHeadlessResult(
    output_path: []const u8,
    width: u32,
    height: u32,
) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(
        \\{{"status":"ok","path":"{s}","width":{d},"height":{d}}}
    , .{ output_path, width, height }) catch {};
    stderr.writeByte('\n') catch {};
}

/// Write a JSON error message to stderr for machine consumption.
pub fn writeHeadlessError(message: []const u8) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(
        \\{{"status":"error","message":"{s}"}}
    , .{message}) catch {};
    stderr.writeByte('\n') catch {};
}

const testing = std.testing;

test "PngExportConfig.parseFromArgs returns null when no export flag" {
    const args = [_][]const u8{ "--dark", "file.md" };
    const config = try PngExportConfig.parseFromArgs(&args);
    try testing.expect(config == null);
}

test "PngExportConfig.parseFromArgs parses --export-png with path" {
    const args = [_][]const u8{ "--export-png", "output.png" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqualStrings("output.png", config.output_path);
    try testing.expectEqual(PngExportConfig.default_width, config.width);
    try testing.expectEqual(PngExportConfig.default_height, config.height);
    try testing.expectEqual(PngExportConfig.ExportMode.render, config.mode);
    try testing.expect(!config.include_chrome);
    try testing.expect(!config.full_document);
}

test "PngExportConfig default dimensions are 1200x900" {
    try testing.expectEqual(@as(u32, 1200), PngExportConfig.default_width);
    try testing.expectEqual(@as(u32, 900), PngExportConfig.default_height);
}

test "PngExportConfig.parseFromArgs parses all flags" {
    const args = [_][]const u8{
        "--export-png",     "out.png",
        "--width",          "1920",
        "--height",         "1080",
        "--export-mode",    "edit",
        "--include-chrome", "--full-document",
    };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqualStrings("out.png", config.output_path);
    try testing.expectEqual(@as(u32, 1920), config.width);
    try testing.expectEqual(@as(u32, 1080), config.height);
    try testing.expectEqual(PngExportConfig.ExportMode.edit, config.mode);
    try testing.expect(config.include_chrome);
    try testing.expect(config.full_document);
}

test "PngExportConfig.parseFromArgs errors on missing export path" {
    const args = [_][]const u8{"--export-png"};
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.MissingValue, result);
}

test "PngExportConfig.parseFromArgs errors on invalid width" {
    const args = [_][]const u8{ "--export-png", "out.png", "--width", "abc" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, result);
}

test "PngExportConfig.parseFromArgs errors on zero width" {
    const args = [_][]const u8{ "--export-png", "out.png", "--width", "0" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, result);
}

test "PngExportConfig.parseFromArgs errors on invalid mode" {
    const args = [_][]const u8{ "--export-png", "out.png", "--export-mode", "preview" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.InvalidMode, result);
}

test "PngExportConfig.parseFromArgs errors on missing width value" {
    const args = [_][]const u8{ "--export-png", "out.png", "--width" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.MissingValue, result);
}

test "PngExportConfig.parseFromArgs errors on missing height value" {
    const args = [_][]const u8{ "--export-png", "out.png", "--height" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.MissingValue, result);
}

test "PngExportConfig.parseFromArgs errors on missing mode value" {
    const args = [_][]const u8{ "--export-png", "out.png", "--export-mode" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.MissingValue, result);
}

test "PngExportConfig.parseFromArgs ignores unrelated flags" {
    const args = [_][]const u8{ "--dark", "--export-png", "out.png", "--theme", "mytheme.json" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqualStrings("out.png", config.output_path);
}

test "PngExportConfig width/height ignored without --export-png" {
    const args = [_][]const u8{ "--width", "1920", "--height", "1080" };
    const config = try PngExportConfig.parseFromArgs(&args);
    try testing.expect(config == null);
}

test "PngExportConfig.parseFromArgs accepts --width/--height before --export-png" {
    const args = [_][]const u8{ "--width", "1920", "--height", "1080", "--export-png", "out.png" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqualStrings("out.png", config.output_path);
    try testing.expectEqual(@as(u32, 1920), config.width);
    try testing.expectEqual(@as(u32, 1080), config.height);
}

test "PngExportConfig.parseFromArgs rejects dimension below minimum" {
    const args = [_][]const u8{ "--export-png", "out.png", "--width", "16" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, result);
}

test "PngExportConfig.parseFromArgs rejects dimension above maximum" {
    const args = [_][]const u8{ "--export-png", "out.png", "--height", "99999" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, result);
}

test "PngExportConfig.parseFromArgs accepts boundary dimensions" {
    const args = [_][]const u8{ "--export-png", "out.png", "--width", "32", "--height", "16384" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqual(@as(u32, 32), config.width);
    try testing.expectEqual(@as(u32, 16384), config.height);
}

test "PngExportConfig.parseFromArgs validates width/height even without export" {
    // Invalid width value should error even when --export-png is absent
    const args = [_][]const u8{ "--width", "abc" };
    const result = PngExportConfig.parseFromArgs(&args);
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, result);
}

test "PngExportConfig.parseDimension validates range" {
    // min_dimension boundary
    try testing.expectEqual(@as(u32, 32), try PngExportConfig.parseDimension("32"));
    // max_dimension boundary
    try testing.expectEqual(@as(u32, 16384), try PngExportConfig.parseDimension("16384"));
    // typical values
    try testing.expectEqual(@as(u32, 1200), try PngExportConfig.parseDimension("1200"));
    try testing.expectEqual(@as(u32, 1920), try PngExportConfig.parseDimension("1920"));
    // below min
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, PngExportConfig.parseDimension("0"));
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, PngExportConfig.parseDimension("31"));
    // above max
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, PngExportConfig.parseDimension("16385"));
    // non-numeric
    try testing.expectError(PngExportConfig.ParseError.InvalidNumber, PngExportConfig.parseDimension("abc"));
}

test "PngExportConfig.parseFromArgs only width specified uses default height" {
    const args = [_][]const u8{ "--export-png", "out.png", "--width", "1920" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqual(@as(u32, 1920), config.width);
    try testing.expectEqual(PngExportConfig.default_height, config.height);
}

test "PngExportConfig.parseFromArgs only height specified uses default width" {
    const args = [_][]const u8{ "--export-png", "out.png", "--height", "1080" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqual(PngExportConfig.default_width, config.width);
    try testing.expectEqual(@as(u32, 1080), config.height);
}

test "buildPngName with .md extension" {
    const name = try buildPngName(testing.allocator, "document.md", "export.png");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("document.png", name);
}

test "buildPngName with path" {
    const name = try buildPngName(testing.allocator, "/home/user/notes/readme.md", "export.png");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("readme.png", name);
}

test "buildPngName with no extension" {
    const name = try buildPngName(testing.allocator, "README", "export.png");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("README.png", name);
}

test "buildPngName with null path uses fallback" {
    const name = try buildPngName(testing.allocator, null, "export.png");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("export.png", name);
}

test "buildPngName with null path uses custom fallback" {
    const name = try buildPngName(testing.allocator, null, "screenshot.png");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("screenshot.png", name);
}

test "buildPngName with multiple dots" {
    const name = try buildPngName(testing.allocator, "my.notes.v2.md", "export.png");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("my.notes.v2.png", name);
}

test "buildPngName with dot-only filename" {
    const name = try buildPngName(testing.allocator, ".hidden", "export.png");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings(".png", name);
}

test "buildPngName with empty string" {
    const name = try buildPngName(testing.allocator, "", "export.png");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings(".png", name);
}

test "exportPixelsToFile rejects zero dimensions" {
    const err = exportPixelsToFile(&.{}, 0, 0, "out.png");
    try testing.expectError(ExportError.InvalidDimensions, err);
}

test "exportPixelsToFile rejects zero width" {
    const err = exportPixelsToFile(&.{}, 0, 10, "out.png");
    try testing.expectError(ExportError.InvalidDimensions, err);
}

test "exportPixelsToFile rejects zero height" {
    const err = exportPixelsToFile(&.{}, 10, 0, "out.png");
    try testing.expectError(ExportError.InvalidDimensions, err);
}

test "exportPixelsToFile rejects wrong pixel buffer size" {
    // 2x2 RGBA = 16 bytes, but we provide 8
    var buf: [8]u8 = undefined;
    const err = exportPixelsToFile(&buf, 2, 2, "out.png");
    try testing.expectError(ExportError.InvalidPixelData, err);
}

test "encodePixelsToPng rejects zero dimensions" {
    const err = encodePixelsToPng(testing.allocator, &.{}, 0, 0);
    try testing.expectError(ExportError.InvalidDimensions, err);
}

test "encodePixelsToPng rejects wrong buffer size" {
    var buf: [4]u8 = undefined;
    const err = encodePixelsToPng(testing.allocator, &buf, 2, 2);
    try testing.expectError(ExportError.InvalidPixelData, err);
}

test "PngBuffer deinit frees memory" {
    const data = try testing.allocator.alloc(u8, 16);
    var buf = PngBuffer{
        .data = data,
        .allocator = testing.allocator,
    };
    buf.deinit();
    // testing.allocator detects leaks — if deinit didn't free, test fails
}

test "headlessWindowFlags sets window_hidden" {
    const flags = headlessWindowFlags();
    try testing.expect(flags.window_hidden);
    // Ensure no other flags are accidentally set
    try testing.expect(!flags.fullscreen_mode);
    try testing.expect(!flags.window_resizable);
    try testing.expect(!flags.window_minimized);
    try testing.expect(!flags.window_maximized);
}

test "writePngFile creates file with correct content" {
    const tmp_path = "/tmp/selkie-test-png-write.bin";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const test_data = "PNG_TEST_BYTES_1234567890";
    try writePngFile(tmp_path, test_data);

    // Read back and verify
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try testing.expectEqualStrings(test_data, buf[0..n]);
}

test "writePngFile overwrites existing file" {
    const tmp_path = "/tmp/selkie-test-png-overwrite.bin";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Write first version
    try writePngFile(tmp_path, "FIRST");
    // Overwrite with second version
    try writePngFile(tmp_path, "SECOND_LONGER_DATA");

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try testing.expectEqualStrings("SECOND_LONGER_DATA", buf[0..n]);
}

test "exportPixelsToFile rejects oversized buffer" {
    // 2x2 RGBA = 16 bytes, but we provide 32
    var buf: [32]u8 = undefined;
    const err = exportPixelsToFile(&buf, 2, 2, "out.png");
    try testing.expectError(ExportError.InvalidPixelData, err);
}

test "exportPixelsToFile writes valid PNG for 1x1 red pixel" {
    const tmp_path = "/tmp/selkie-test-1px.png";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var buf = [_]u8{ 0xFF, 0x00, 0x00, 0xFF }; // red pixel RGBA
    try exportPixelsToFile(&buf, 1, 1, tmp_path);

    // Verify file was created and starts with PNG magic bytes
    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var header: [8]u8 = undefined;
    const n = try file.readAll(&header);
    try testing.expectEqual(@as(usize, 8), n);
    // PNG magic: 0x89 P N G \r \n 0x1A \n
    try testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, &header);
}

test "encodePixelsToPng rejects oversized buffer" {
    var buf: [32]u8 = undefined;
    const err = encodePixelsToPng(testing.allocator, &buf, 2, 2);
    try testing.expectError(ExportError.InvalidPixelData, err);
}

test "PngExportConfig.isStdout returns true for dash" {
    const cfg = PngExportConfig{ .output_path = "-" };
    try testing.expect(cfg.isStdout());
}

test "PngExportConfig.isStdout returns false for file path" {
    const cfg = PngExportConfig{ .output_path = "output.png" };
    try testing.expect(!cfg.isStdout());
}

test "PngExportConfig.isStdout returns false for empty string" {
    const cfg = PngExportConfig{ .output_path = "" };
    try testing.expect(!cfg.isStdout());
}

test "PngExportConfig.parseFromArgs parses --quiet flag" {
    const args = [_][]const u8{ "--export-png", "out.png", "--quiet" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expect(config.quiet);
}

test "PngExportConfig.parseFromArgs parses -q flag" {
    const args = [_][]const u8{ "--export-png", "out.png", "-q" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expect(config.quiet);
}

test "PngExportConfig.parseFromArgs quiet defaults to false" {
    const args = [_][]const u8{ "--export-png", "out.png" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expect(!config.quiet);
}

test "PngExportConfig.parseFromArgs accepts stdout dash as path" {
    const args = [_][]const u8{ "--export-png", "-" };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqualStrings("-", config.output_path);
    try testing.expect(config.isStdout());
}

test "PngExportConfig.parseFromArgs parses all flags including quiet" {
    const args = [_][]const u8{
        "--export-png",     "out.png",
        "--width",          "1920",
        "--height",         "1080",
        "--export-mode",    "edit",
        "--include-chrome", "--full-document",
        "--quiet",
    };
    const config = (try PngExportConfig.parseFromArgs(&args)).?;
    try testing.expectEqualStrings("out.png", config.output_path);
    try testing.expectEqual(@as(u32, 1920), config.width);
    try testing.expectEqual(@as(u32, 1080), config.height);
    try testing.expectEqual(PngExportConfig.ExportMode.edit, config.mode);
    try testing.expect(config.include_chrome);
    try testing.expect(config.full_document);
    try testing.expect(config.quiet);
}

// NOTE: Tests that call raylib encoding functions with valid pixel data and
// an active OpenGL context (encodePixelsToPng producing actual PNG output,
// exportImageToFile writing real PNGs) are tested via integration tests.
// NOTE: writePngToStdout, writeHeadlessResult, writeHeadlessError write to
// real file descriptors (stdout/stderr) and are tested via integration tests.
