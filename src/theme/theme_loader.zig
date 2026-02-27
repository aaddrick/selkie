const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;
const Theme = @import("theme.zig").Theme;
const defaults = @import("defaults.zig");

const log = std.log.scoped(.theme_loader);

pub const ThemeLoadError = error{
    InvalidJson,
    InvalidColor,
    FileReadError,
    InvalidValue,
    OutOfMemory,
};

/// Parse a hex color string like "#rrggbb" into an rl.Color.
pub fn parseHexColor(hex: []const u8) ThemeLoadError!rl.Color {
    // Strip leading '#'
    const s = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
    if (s.len != 6) return ThemeLoadError.InvalidColor;

    const r = std.fmt.parseInt(u8, s[0..2], 16) catch return ThemeLoadError.InvalidColor;
    const g = std.fmt.parseInt(u8, s[2..4], 16) catch return ThemeLoadError.InvalidColor;
    const b = std.fmt.parseInt(u8, s[4..6], 16) catch return ThemeLoadError.InvalidColor;
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

/// JSON structures matching the theme file format.
const JsonColors = struct {
    background: ?[]const u8 = null,
    text: ?[]const u8 = null,
    heading: ?[]const []const u8 = null,
    link: ?[]const u8 = null,
    link_hover: ?[]const u8 = null,
    code_text: ?[]const u8 = null,
    code_background: ?[]const u8 = null,
    blockquote_border: ?[]const u8 = null,
    blockquote_text: ?[]const u8 = null,
    table_header_bg: ?[]const u8 = null,
    table_border: ?[]const u8 = null,
    table_alt_row_bg: ?[]const u8 = null,
    hr_color: ?[]const u8 = null,
    scrollbar: ?[]const u8 = null,
    scrollbar_track: ?[]const u8 = null,
    syntax_keyword: ?[]const u8 = null,
    syntax_string: ?[]const u8 = null,
    syntax_comment: ?[]const u8 = null,
    syntax_number: ?[]const u8 = null,
    syntax_type: ?[]const u8 = null,
    syntax_function: ?[]const u8 = null,
    syntax_operator: ?[]const u8 = null,
    syntax_punctuation: ?[]const u8 = null,
    line_number_color: ?[]const u8 = null,
    mermaid_node_fill: ?[]const u8 = null,
    mermaid_node_border: ?[]const u8 = null,
    mermaid_node_text: ?[]const u8 = null,
    mermaid_edge: ?[]const u8 = null,
    mermaid_edge_text: ?[]const u8 = null,
    mermaid_label_bg: ?[]const u8 = null,
    mermaid_subgraph_bg: ?[]const u8 = null,
};

const JsonSizing = struct {
    body_font_size: ?f64 = null,
    heading_scale: ?[]const f64 = null,
    mono_font_size: ?f64 = null,
    line_height: ?f64 = null,
};

const JsonSpacing = struct {
    paragraph_spacing: ?f64 = null,
    heading_spacing_above: ?f64 = null,
    heading_spacing_below: ?f64 = null,
    list_indent: ?f64 = null,
    blockquote_indent: ?f64 = null,
    code_block_padding: ?f64 = null,
    page_margin: ?f64 = null,
    max_content_width: ?f64 = null,
    table_cell_padding: ?f64 = null,
};

const JsonTheme = struct {
    name: ?[]const u8 = null,
    colors: ?JsonColors = null,
    sizing: ?JsonSizing = null,
    spacing: ?JsonSpacing = null,
};

fn colorOrDefault(hex: ?[]const u8, default: rl.Color) rl.Color {
    const h = hex orelse return default;
    return parseHexColor(h) catch default;
}

/// Validate and convert an f64 to f32, rejecting negative values and values
/// outside the f32 representable range. Returns the default if the value is null.
fn f64ToF32(val: ?f64, default: f32) ThemeLoadError!f32 {
    const v = val orelse return default;
    if (v < 0) return ThemeLoadError.InvalidValue;
    if (v > std.math.floatMax(f32)) return ThemeLoadError.InvalidValue;
    return @floatCast(v);
}

/// Validate and convert an f64 scale factor to f32. Scale factors must be
/// positive and within f32 range.
fn validateScale(v: f64) ThemeLoadError!f32 {
    if (v <= 0) return ThemeLoadError.InvalidValue;
    if (v > std.math.floatMax(f32)) return ThemeLoadError.InvalidValue;
    return @floatCast(v);
}

/// Load a theme from a JSON file, falling back to the light theme defaults for missing fields.
pub fn loadFromFile(allocator: Allocator, path: []const u8) !Theme {
    const file_data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
        log.err("Failed to read theme file '{s}': {}", .{ path, err });
        return ThemeLoadError.FileReadError;
    };
    defer allocator.free(file_data);

    return loadFromJson(allocator, file_data);
}

/// Parse a Theme from JSON data, falling back to light theme defaults.
pub fn loadFromJson(allocator: Allocator, json_data: []const u8) !Theme {
    const parsed = std.json.parseFromSlice(JsonTheme, allocator, json_data, .{
        .ignore_unknown_fields = true,
    }) catch return ThemeLoadError.InvalidJson;
    defer parsed.deinit();

    const json = parsed.value;
    const def = defaults.light;

    var theme = def; // Start from defaults

    // Colors
    if (json.colors) |c| {
        theme.background = colorOrDefault(c.background, def.background);
        theme.text = colorOrDefault(c.text, def.text);
        theme.link = colorOrDefault(c.link, def.link);
        theme.link_hover = colorOrDefault(c.link_hover, def.link_hover);
        theme.code_text = colorOrDefault(c.code_text, def.code_text);
        theme.code_background = colorOrDefault(c.code_background, def.code_background);
        theme.blockquote_border = colorOrDefault(c.blockquote_border, def.blockquote_border);
        theme.blockquote_text = colorOrDefault(c.blockquote_text, def.blockquote_text);
        theme.table_header_bg = colorOrDefault(c.table_header_bg, def.table_header_bg);
        theme.table_border = colorOrDefault(c.table_border, def.table_border);
        theme.table_alt_row_bg = colorOrDefault(c.table_alt_row_bg, def.table_alt_row_bg);
        theme.hr_color = colorOrDefault(c.hr_color, def.hr_color);
        theme.scrollbar = colorOrDefault(c.scrollbar, def.scrollbar);
        theme.scrollbar_track = colorOrDefault(c.scrollbar_track, def.scrollbar_track);
        theme.syntax_keyword = colorOrDefault(c.syntax_keyword, def.syntax_keyword);
        theme.syntax_string = colorOrDefault(c.syntax_string, def.syntax_string);
        theme.syntax_comment = colorOrDefault(c.syntax_comment, def.syntax_comment);
        theme.syntax_number = colorOrDefault(c.syntax_number, def.syntax_number);
        theme.syntax_type = colorOrDefault(c.syntax_type, def.syntax_type);
        theme.syntax_function = colorOrDefault(c.syntax_function, def.syntax_function);
        theme.syntax_operator = colorOrDefault(c.syntax_operator, def.syntax_operator);
        theme.syntax_punctuation = colorOrDefault(c.syntax_punctuation, def.syntax_punctuation);
        theme.line_number_color = colorOrDefault(c.line_number_color, def.line_number_color);
        theme.mermaid_node_fill = colorOrDefault(c.mermaid_node_fill, def.mermaid_node_fill);
        theme.mermaid_node_border = colorOrDefault(c.mermaid_node_border, def.mermaid_node_border);
        theme.mermaid_node_text = colorOrDefault(c.mermaid_node_text, def.mermaid_node_text);
        theme.mermaid_edge = colorOrDefault(c.mermaid_edge, def.mermaid_edge);
        theme.mermaid_edge_text = colorOrDefault(c.mermaid_edge_text, def.mermaid_edge_text);
        theme.mermaid_label_bg = colorOrDefault(c.mermaid_label_bg, def.mermaid_label_bg);
        theme.mermaid_subgraph_bg = colorOrDefault(c.mermaid_subgraph_bg, def.mermaid_subgraph_bg);

        // Heading colors array
        if (c.heading) |headings| {
            for (0..@min(6, headings.len)) |i| {
                theme.heading[i] = parseHexColor(headings[i]) catch def.heading[i];
            }
        }
    }

    // Sizing
    if (json.sizing) |s| {
        theme.body_font_size = try f64ToF32(s.body_font_size, def.body_font_size);
        theme.mono_font_size = try f64ToF32(s.mono_font_size, def.mono_font_size);
        theme.line_height = try f64ToF32(s.line_height, def.line_height);

        if (s.heading_scale) |scales| {
            for (0..@min(6, scales.len)) |i| {
                theme.heading_scale[i] = try validateScale(scales[i]);
            }
        }
    }

    // Spacing
    if (json.spacing) |sp| {
        theme.paragraph_spacing = try f64ToF32(sp.paragraph_spacing, def.paragraph_spacing);
        theme.heading_spacing_above = try f64ToF32(sp.heading_spacing_above, def.heading_spacing_above);
        theme.heading_spacing_below = try f64ToF32(sp.heading_spacing_below, def.heading_spacing_below);
        theme.list_indent = try f64ToF32(sp.list_indent, def.list_indent);
        theme.blockquote_indent = try f64ToF32(sp.blockquote_indent, def.blockquote_indent);
        theme.code_block_padding = try f64ToF32(sp.code_block_padding, def.code_block_padding);
        theme.page_margin = try f64ToF32(sp.page_margin, def.page_margin);
        theme.max_content_width = try f64ToF32(sp.max_content_width, def.max_content_width);
        theme.table_cell_padding = try f64ToF32(sp.table_cell_padding, def.table_cell_padding);
    }

    return theme;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "parseHexColor with valid 6-digit hex" {
    const color = try parseHexColor("#ff8040");
    try testing.expectEqual(@as(u8, 255), color.r);
    try testing.expectEqual(@as(u8, 128), color.g);
    try testing.expectEqual(@as(u8, 64), color.b);
    try testing.expectEqual(@as(u8, 255), color.a);
}

test "parseHexColor without hash prefix" {
    const color = try parseHexColor("00ff00");
    try testing.expectEqual(@as(u8, 0), color.r);
    try testing.expectEqual(@as(u8, 255), color.g);
    try testing.expectEqual(@as(u8, 0), color.b);
}

test "parseHexColor with black" {
    const color = try parseHexColor("#000000");
    try testing.expectEqual(@as(u8, 0), color.r);
    try testing.expectEqual(@as(u8, 0), color.g);
    try testing.expectEqual(@as(u8, 0), color.b);
}

test "parseHexColor with white" {
    const color = try parseHexColor("#ffffff");
    try testing.expectEqual(@as(u8, 255), color.r);
    try testing.expectEqual(@as(u8, 255), color.g);
    try testing.expectEqual(@as(u8, 255), color.b);
}

test "parseHexColor rejects short string" {
    try testing.expectError(ThemeLoadError.InvalidColor, parseHexColor("#fff"));
}

test "parseHexColor rejects empty string" {
    try testing.expectError(ThemeLoadError.InvalidColor, parseHexColor(""));
}

test "parseHexColor rejects non-hex characters" {
    try testing.expectError(ThemeLoadError.InvalidColor, parseHexColor("#gggggg"));
}

test "parseHexColor rejects too-long string" {
    try testing.expectError(ThemeLoadError.InvalidColor, parseHexColor("#ff00ff00"));
}

test "loadFromJson with valid minimal JSON uses defaults" {
    const json = "{}";
    const theme = try loadFromJson(testing.allocator, json);
    // Should equal the light theme defaults
    try testing.expectEqual(defaults.light.body_font_size, theme.body_font_size);
    try testing.expectEqual(defaults.light.line_height, theme.line_height);
    try testing.expectEqual(defaults.light.page_margin, theme.page_margin);
    try testing.expectEqual(defaults.light.background.r, theme.background.r);
}

test "loadFromJson with colors overrides defaults" {
    const json =
        \\{"colors": {"background": "#112233", "text": "#aabbcc"}}
    ;
    const theme = try loadFromJson(testing.allocator, json);
    try testing.expectEqual(@as(u8, 0x11), theme.background.r);
    try testing.expectEqual(@as(u8, 0x22), theme.background.g);
    try testing.expectEqual(@as(u8, 0x33), theme.background.b);
    try testing.expectEqual(@as(u8, 0xaa), theme.text.r);
    try testing.expectEqual(@as(u8, 0xbb), theme.text.g);
    try testing.expectEqual(@as(u8, 0xcc), theme.text.b);
}

test "loadFromJson with sizing overrides" {
    const json =
        \\{"sizing": {"body_font_size": 20.0, "line_height": 1.8}}
    ;
    const theme = try loadFromJson(testing.allocator, json);
    try testing.expectEqual(@as(f32, 20.0), theme.body_font_size);
    try testing.expectEqual(@as(f32, 1.8), theme.line_height);
}

test "loadFromJson rejects malformed JSON" {
    try testing.expectError(ThemeLoadError.InvalidJson, loadFromJson(testing.allocator, "{broken"));
}

test "loadFromJson rejects negative sizing values" {
    const json =
        \\{"sizing": {"body_font_size": -5.0}}
    ;
    try testing.expectError(ThemeLoadError.InvalidValue, loadFromJson(testing.allocator, json));
}

test "loadFromJson with missing fields falls back to defaults" {
    const json =
        \\{"colors": {"background": "#000000"}, "sizing": {}}
    ;
    const theme = try loadFromJson(testing.allocator, json);
    // background overridden
    try testing.expectEqual(@as(u8, 0), theme.background.r);
    // text falls back to default
    try testing.expectEqual(defaults.light.text.r, theme.text.r);
    // sizing falls back to defaults
    try testing.expectEqual(defaults.light.body_font_size, theme.body_font_size);
}

test "loadFromJson with invalid color falls back to default" {
    const json =
        \\{"colors": {"background": "not-a-color"}}
    ;
    const theme = try loadFromJson(testing.allocator, json);
    // Invalid color should fall back to default
    try testing.expectEqual(defaults.light.background.r, theme.background.r);
}

test "f64ToF32 returns default for null" {
    const result = try f64ToF32(null, 42.0);
    try testing.expectEqual(@as(f32, 42.0), result);
}

test "f64ToF32 converts valid value" {
    const result = try f64ToF32(16.5, 0);
    try testing.expectEqual(@as(f32, 16.5), result);
}

test "f64ToF32 rejects negative value" {
    try testing.expectError(ThemeLoadError.InvalidValue, f64ToF32(-1.0, 0));
}

test "validateScale rejects zero" {
    try testing.expectError(ThemeLoadError.InvalidValue, validateScale(0));
}

test "validateScale rejects negative" {
    try testing.expectError(ThemeLoadError.InvalidValue, validateScale(-0.5));
}

test "validateScale converts valid value" {
    const result = try validateScale(1.5);
    try testing.expectEqual(@as(f32, 1.5), result);
}
