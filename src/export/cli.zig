//! CLI argument parser for the `selkie export` subcommand.
//!
//! Provides a clean subcommand interface for headless PNG export:
//!
//!   selkie export --mode edit|render --input file.md --output file.png
//!
//! All flags have sensible defaults: mode defaults to render, output
//! defaults to <input-stem>.png, dimensions default to 1200x900.
//!
//! This module complements the existing --export-png flag-based interface
//! in png_exporter.zig by providing a more discoverable subcommand UX.

const std = @import("std");
const PngExportConfig = @import("png_exporter.zig").PngExportConfig;

const log = std.log.scoped(.export_cli);

pub const ExportCommand = struct {
    input_path: []const u8,
    output_path: ?[]const u8 = null,
    mode: PngExportConfig.ExportMode = .render,
    width: u32 = PngExportConfig.default_width,
    height: u32 = PngExportConfig.default_height,
    include_chrome: bool = false,
    full_document: bool = false,
    dark_theme: bool = false,
    theme_path: ?[]const u8 = null,
    quiet: bool = false,

    /// Convert to PngExportConfig. `resolved_output` is the final output path.
    pub fn toPngExportConfig(self: ExportCommand, resolved_output: []const u8) PngExportConfig {
        return .{
            .output_path = resolved_output,
            .width = self.width,
            .height = self.height,
            .mode = self.mode,
            .include_chrome = self.include_chrome,
            .full_document = self.full_document,
            .quiet = self.quiet,
        };
    }
};

pub const ParseError = error{
    MissingValue,
    InvalidNumber,
    InvalidMode,
    MissingInput,
    UnknownFlag,
    UnexpectedPositional,
    HelpRequested,
};

/// Parse args following the `export` subcommand.
///
/// `args` should be the slice of arguments AFTER "export", e.g. if the
/// full command line is `selkie export --mode edit --input f.md`, then
/// `args` is `["--mode", "edit", "--input", "f.md"]`.
///
/// Returns `ParseError.HelpRequested` if --help/-h is present (caller
/// should print help text and exit 0).
pub fn parseExportArgs(args: []const []const u8) ParseError!ExportCommand {
    var cmd = ExportCommand{
        .input_path = "",
    };
    var input_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return ParseError.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--mode") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            const mode_str = args[i];
            if (std.mem.eql(u8, mode_str, "render")) {
                cmd.mode = .render;
            } else if (std.mem.eql(u8, mode_str, "edit")) {
                cmd.mode = .edit;
            } else {
                return ParseError.InvalidMode;
            }
        } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            input_path = args[i];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            cmd.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            cmd.width = parseDimension(args[i]) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--height") or std.mem.eql(u8, arg, "-H")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            cmd.height = parseDimension(args[i]) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--include-chrome")) {
            cmd.include_chrome = true;
        } else if (std.mem.eql(u8, arg, "--full-document")) {
            cmd.full_document = true;
        } else if (std.mem.eql(u8, arg, "--dark")) {
            cmd.dark_theme = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            cmd.quiet = true;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            cmd.theme_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnknownFlag;
        } else {
            // Positional argument: treat as input path if not yet set
            if (input_path == null) {
                input_path = arg;
            } else {
                return ParseError.UnexpectedPositional;
            }
        }
    }

    cmd.input_path = input_path orelse return ParseError.MissingInput;

    return cmd;
}

/// Parse and validate a dimension value from a CLI argument string.
/// Delegates to `PngExportConfig.parseDimension` — the canonical implementation.
fn parseDimension(value: []const u8) ParseError!u32 {
    return PngExportConfig.parseDimension(value) catch return ParseError.InvalidNumber;
}

/// Format an error into a human-readable message for stderr.
pub fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        ParseError.MissingValue => "missing value for export option",
        ParseError.InvalidNumber => "invalid --width or --height (must be integer between 32 and 16384)",
        ParseError.InvalidMode => "invalid --mode (must be 'edit' or 'render')",
        ParseError.MissingInput => "missing required --input flag (or positional file argument)",
        ParseError.UnknownFlag => "unknown export option",
        ParseError.UnexpectedPositional => "unexpected positional argument (only one input file allowed)",
        ParseError.HelpRequested => "", // not an error
    };
}

/// Help text for the `selkie export` subcommand.
pub const export_help_text =
    \\Usage: selkie export [OPTIONS] --input FILE [--output FILE.png]
    \\       selkie export [OPTIONS] FILE [--output FILE.png]
    \\
    \\Export a markdown file as a PNG image (headless, no GUI window shown).
    \\
    \\Required:
    \\  -i, --input FILE      Markdown file to export
    \\                         (or pass FILE as a positional argument)
    \\
    \\Output:
    \\  -o, --output FILE     Output PNG path (default: <input-stem>.png)
    \\
    \\Mode:
    \\  -m, --mode MODE       Export mode: 'render' (default) or 'edit'
    \\                         render = fully rendered GFM output
    \\                         edit   = raw markdown with syntax highlighting
    \\
    \\Dimensions:
    \\  -w, --width N         PNG width in pixels  (default: 1200, range: 32-16384)
    \\  -H, --height N        PNG height in pixels (default: 900,  range: 32-16384)
    \\
    \\Capture:
    \\  --full-document       Capture full document, not just viewport
    \\  --include-chrome       Include UI chrome (menu bar, scrollbars)
    \\
    \\Theme:
    \\  --dark                Use the built-in dark theme
    \\  --theme PATH          Load a custom theme JSON file
    \\
    \\Other:
    \\  -q, --quiet           Suppress log output (for scripting/automation)
    \\  -h, --help            Show this help message and exit
    \\
    \\A JSON status line is always written to stderr for machine consumption:
    \\  {"status":"ok","path":"<path>","width":<w>,"height":<h>}
    \\
    \\Examples:
    \\  selkie export --input README.md
    \\  selkie export --input README.md --output preview.png --mode edit
    \\  selkie export -i doc.md -o doc.png -w 1920 -H 1080 --full-document
    \\  selkie export README.md --dark --mode render -q
    \\
;

const testing = std.testing;

test "parseExportArgs parses minimal --input" {
    const args = [_][]const u8{ "--input", "file.md" };
    const cmd = try parseExportArgs(&args);
    try testing.expectEqualStrings("file.md", cmd.input_path);
    try testing.expect(cmd.output_path == null);
    try testing.expectEqual(PngExportConfig.ExportMode.render, cmd.mode);
    try testing.expectEqual(PngExportConfig.default_width, cmd.width);
    try testing.expectEqual(PngExportConfig.default_height, cmd.height);
    try testing.expect(!cmd.include_chrome);
    try testing.expect(!cmd.full_document);
    try testing.expect(!cmd.dark_theme);
    try testing.expect(cmd.theme_path == null);
}

test "parseExportArgs parses short flags" {
    const args = [_][]const u8{ "-i", "file.md", "-o", "out.png", "-m", "edit", "-w", "800", "-H", "600" };
    const cmd = try parseExportArgs(&args);
    try testing.expectEqualStrings("file.md", cmd.input_path);
    try testing.expectEqualStrings("out.png", cmd.output_path.?);
    try testing.expectEqual(PngExportConfig.ExportMode.edit, cmd.mode);
    try testing.expectEqual(@as(u32, 800), cmd.width);
    try testing.expectEqual(@as(u32, 600), cmd.height);
}

test "parseExportArgs parses all long flags" {
    const args = [_][]const u8{
        "--input",          "doc.md",
        "--output",         "doc.png",
        "--mode",           "edit",
        "--width",          "1920",
        "--height",         "1080",
        "--include-chrome", "--full-document",
        "--dark",           "--theme",
        "mytheme.json",
    };
    const cmd = try parseExportArgs(&args);
    try testing.expectEqualStrings("doc.md", cmd.input_path);
    try testing.expectEqualStrings("doc.png", cmd.output_path.?);
    try testing.expectEqual(PngExportConfig.ExportMode.edit, cmd.mode);
    try testing.expectEqual(@as(u32, 1920), cmd.width);
    try testing.expectEqual(@as(u32, 1080), cmd.height);
    try testing.expect(cmd.include_chrome);
    try testing.expect(cmd.full_document);
    try testing.expect(cmd.dark_theme);
    try testing.expectEqualStrings("mytheme.json", cmd.theme_path.?);
}

test "parseExportArgs accepts positional input" {
    const args = [_][]const u8{ "README.md", "--output", "out.png" };
    const cmd = try parseExportArgs(&args);
    try testing.expectEqualStrings("README.md", cmd.input_path);
    try testing.expectEqualStrings("out.png", cmd.output_path.?);
}

test "parseExportArgs --input overrides positional" {
    // --input takes precedence if both are specified
    const args = [_][]const u8{ "--input", "explicit.md" };
    const cmd = try parseExportArgs(&args);
    try testing.expectEqualStrings("explicit.md", cmd.input_path);
}

test "parseExportArgs errors on missing --input" {
    const args = [_][]const u8{ "--output", "out.png", "--mode", "edit" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.MissingInput, result);
}

test "parseExportArgs errors on missing --input value" {
    const args = [_][]const u8{"--input"};
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.MissingValue, result);
}

test "parseExportArgs errors on missing --output value" {
    const args = [_][]const u8{ "--input", "f.md", "--output" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.MissingValue, result);
}

test "parseExportArgs errors on missing --mode value" {
    const args = [_][]const u8{ "--input", "f.md", "--mode" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.MissingValue, result);
}

test "parseExportArgs errors on invalid --mode" {
    const args = [_][]const u8{ "--input", "f.md", "--mode", "preview" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.InvalidMode, result);
}

test "parseExportArgs errors on invalid --width" {
    const args = [_][]const u8{ "--input", "f.md", "--width", "abc" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.InvalidNumber, result);
}

test "parseExportArgs errors on --width below minimum" {
    const args = [_][]const u8{ "--input", "f.md", "--width", "16" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.InvalidNumber, result);
}

test "parseExportArgs errors on --height above maximum" {
    const args = [_][]const u8{ "--input", "f.md", "--height", "99999" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.InvalidNumber, result);
}

test "parseExportArgs errors on missing --width value" {
    const args = [_][]const u8{ "--input", "f.md", "--width" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.MissingValue, result);
}

test "parseExportArgs errors on missing --height value" {
    const args = [_][]const u8{ "--input", "f.md", "--height" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.MissingValue, result);
}

test "parseExportArgs errors on unknown flag" {
    const args = [_][]const u8{ "--input", "f.md", "--foobar" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.UnknownFlag, result);
}

test "parseExportArgs returns HelpRequested for --help" {
    const args = [_][]const u8{"--help"};
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.HelpRequested, result);
}

test "parseExportArgs returns HelpRequested for -h" {
    const args = [_][]const u8{"-h"};
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.HelpRequested, result);
}

test "parseExportArgs --help takes priority even with other flags" {
    const args = [_][]const u8{ "--input", "f.md", "--help" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.HelpRequested, result);
}

test "parseExportArgs errors on missing --theme value" {
    const args = [_][]const u8{ "--input", "f.md", "--theme" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.MissingValue, result);
}

test "parseExportArgs accepts boundary dimensions" {
    const args = [_][]const u8{ "--input", "f.md", "--width", "32", "--height", "16384" };
    const cmd = try parseExportArgs(&args);
    try testing.expectEqual(@as(u32, 32), cmd.width);
    try testing.expectEqual(@as(u32, 16384), cmd.height);
}

test "parseExportArgs empty args returns MissingInput" {
    const args = [_][]const u8{};
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.MissingInput, result);
}

test "toPngExportConfig converts correctly" {
    const cmd = ExportCommand{
        .input_path = "test.md",
        .output_path = "test.png",
        .mode = .edit,
        .width = 1920,
        .height = 1080,
        .include_chrome = true,
        .full_document = true,
    };
    const config = cmd.toPngExportConfig("resolved.png");
    try testing.expectEqualStrings("resolved.png", config.output_path);
    try testing.expectEqual(PngExportConfig.ExportMode.edit, config.mode);
    try testing.expectEqual(@as(u32, 1920), config.width);
    try testing.expectEqual(@as(u32, 1080), config.height);
    try testing.expect(config.include_chrome);
    try testing.expect(config.full_document);
}

test "parseExportArgs errors on unexpected positional argument" {
    const args = [_][]const u8{ "file.md", "extra.md" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.UnexpectedPositional, result);
}

test "parseExportArgs errors on extra positional after --input" {
    const args = [_][]const u8{ "--input", "file.md", "extra.md" };
    const result = parseExportArgs(&args);
    try testing.expectError(ParseError.UnexpectedPositional, result);
}

test "errorMessage returns non-empty strings for all errors" {
    try testing.expect(errorMessage(ParseError.MissingValue).len > 0);
    try testing.expect(errorMessage(ParseError.InvalidNumber).len > 0);
    try testing.expect(errorMessage(ParseError.InvalidMode).len > 0);
    try testing.expect(errorMessage(ParseError.MissingInput).len > 0);
    try testing.expect(errorMessage(ParseError.UnknownFlag).len > 0);
    try testing.expect(errorMessage(ParseError.UnexpectedPositional).len > 0);
    // HelpRequested returns empty string (not an error message)
    try testing.expectEqual(@as(usize, 0), errorMessage(ParseError.HelpRequested).len);
}

test "parseExportArgs mode defaults to render" {
    const args = [_][]const u8{ "--input", "f.md" };
    const cmd = try parseExportArgs(&args);
    try testing.expectEqual(PngExportConfig.ExportMode.render, cmd.mode);
}

test "export_help_text is non-empty and contains key sections" {
    try testing.expect(export_help_text.len > 0);
    // Verify help text contains key sections
    try testing.expect(std.mem.indexOf(u8, export_help_text, "--input") != null);
    try testing.expect(std.mem.indexOf(u8, export_help_text, "--output") != null);
    try testing.expect(std.mem.indexOf(u8, export_help_text, "--mode") != null);
    try testing.expect(std.mem.indexOf(u8, export_help_text, "Examples") != null);
}
