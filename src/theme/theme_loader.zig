const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;
const Theme = @import("theme.zig").Theme;
const defaults = @import("defaults.zig");

pub const ThemeLoadError = error{
    InvalidJson,
    InvalidColor,
    FileReadError,
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
    if (hex) |h| {
        return parseHexColor(h) catch default;
    }
    return default;
}

fn f64ToF32(val: ?f64, default: f32) f32 {
    if (val) |v| return @floatCast(v);
    return default;
}

/// Load a theme from a JSON file, falling back to the light theme defaults for missing fields.
pub fn loadFromFile(allocator: Allocator, path: []const u8) !Theme {
    const file_data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return ThemeLoadError.FileReadError;
    defer allocator.free(file_data);

    return loadFromJson(file_data);
}

/// Parse a Theme from JSON data, falling back to light theme defaults.
pub fn loadFromJson(json_data: []const u8) !Theme {
    const parsed = std.json.parseFromSlice(JsonTheme, std.heap.page_allocator, json_data, .{
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

        // Heading colors array
        if (c.heading) |headings| {
            var i: usize = 0;
            while (i < 6 and i < headings.len) : (i += 1) {
                theme.heading[i] = parseHexColor(headings[i]) catch def.heading[i];
            }
        }
    }

    // Sizing
    if (json.sizing) |s| {
        theme.body_font_size = f64ToF32(s.body_font_size, def.body_font_size);
        theme.mono_font_size = f64ToF32(s.mono_font_size, def.mono_font_size);
        theme.line_height = f64ToF32(s.line_height, def.line_height);

        if (s.heading_scale) |scales| {
            var i: usize = 0;
            while (i < 6 and i < scales.len) : (i += 1) {
                theme.heading_scale[i] = @floatCast(scales[i]);
            }
        }
    }

    // Spacing
    if (json.spacing) |sp| {
        theme.paragraph_spacing = f64ToF32(sp.paragraph_spacing, def.paragraph_spacing);
        theme.heading_spacing_above = f64ToF32(sp.heading_spacing_above, def.heading_spacing_above);
        theme.heading_spacing_below = f64ToF32(sp.heading_spacing_below, def.heading_spacing_below);
        theme.list_indent = f64ToF32(sp.list_indent, def.list_indent);
        theme.blockquote_indent = f64ToF32(sp.blockquote_indent, def.blockquote_indent);
        theme.code_block_padding = f64ToF32(sp.code_block_padding, def.code_block_padding);
        theme.page_margin = f64ToF32(sp.page_margin, def.page_margin);
        theme.max_content_width = f64ToF32(sp.max_content_width, def.max_content_width);
        theme.table_cell_padding = f64ToF32(sp.table_cell_padding, def.table_cell_padding);
    }

    return theme;
}
