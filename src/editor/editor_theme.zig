const std = @import("std");
const rl = @import("raylib");
const MdHighlighter = @import("md_highlighter.zig").MdHighlighter;

/// Text style for a syntax-highlighted markdown token.
pub const TokenStyle = struct {
    color: rl.Color,
    bold: bool = false,
    italic: bool = false,
};

/// Maps each MdHighlighter.TokenKind to a TokenStyle for editor rendering.
pub const EditorTheme = struct {
    /// Style for each token kind, indexed by @intFromEnum(TokenKind).
    styles: [token_kind_count]TokenStyle,
    editor_bg: rl.Color,
    default_text: rl.Color,
    line_number: rl.Color,
    cursor: rl.Color,
    selection: rl.Color,
    current_line_bg: rl.Color,

    const token_kind_count = @typeInfo(MdHighlighter.TokenKind).@"enum".fields.len;

    pub fn styleFor(self: *const EditorTheme, kind: MdHighlighter.TokenKind) TokenStyle {
        return self.styles[@intFromEnum(kind)];
    }

    pub fn setStyle(self: *EditorTheme, kind: MdHighlighter.TokenKind, style: TokenStyle) void {
        self.styles[@intFromEnum(kind)] = style;
    }
};

fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

/// Convenience to build the styles array from a comptime mapping function.
fn buildStyles(comptime mapFn: fn (MdHighlighter.TokenKind) TokenStyle) [EditorTheme.token_kind_count]TokenStyle {
    var styles: [EditorTheme.token_kind_count]TokenStyle = undefined;
    inline for (@typeInfo(MdHighlighter.TokenKind).@"enum".fields, 0..) |field, i| {
        styles[i] = mapFn(@enumFromInt(field.value));
    }
    return styles;
}

// Light theme — GitHub-inspired colors

fn lightStyleFor(kind: MdHighlighter.TokenKind) TokenStyle {
    return switch (kind) {
        // Plain body text
        .text => .{ .color = rgb(36, 41, 46) },

        // Headings: blue marker, bold dark text
        .heading_marker => .{ .color = rgb(3, 102, 214), .bold = true },
        .heading_text => .{ .color = rgb(36, 41, 46), .bold = true },

        // Emphasis
        .bold => .{ .color = rgb(36, 41, 46), .bold = true },
        .italic => .{ .color = rgb(36, 41, 46), .italic = true },
        .bold_italic => .{ .color = rgb(36, 41, 46), .bold = true, .italic = true },

        // Code: monospace-styled, distinct background implied by renderer
        .code_span => .{ .color = rgb(207, 34, 46) },
        .fence => .{ .color = rgb(106, 115, 125) },
        .code_line => .{ .color = rgb(36, 41, 46) },

        // Links and images
        .link_text => .{ .color = rgb(3, 102, 214) },
        .link_url => .{ .color = rgb(106, 115, 125), .italic = true },
        .image_marker => .{ .color = rgb(130, 80, 223) },

        // Lists
        .list_marker => .{ .color = rgb(207, 34, 46), .bold = true },

        // Blockquotes
        .blockquote_marker => .{ .color = rgb(106, 115, 125), .bold = true },

        // Tables
        .table_pipe => .{ .color = rgb(106, 115, 125) },
        .table_align => .{ .color = rgb(106, 115, 125) },

        // Horizontal rule
        .horizontal_rule => .{ .color = rgb(106, 115, 125) },

        // GFM extensions
        .strikethrough => .{ .color = rgb(106, 115, 125), .italic = true },
        .task_marker => .{ .color = rgb(130, 80, 223), .bold = true },

        // HTML
        .html_tag => .{ .color = rgb(34, 134, 58) },

        // Escape sequences
        .escape => .{ .color = rgb(227, 98, 9) },

        // Autolinks
        .autolink => .{ .color = rgb(3, 102, 214) },

        // Footnotes
        .footnote_ref => .{ .color = rgb(130, 80, 223) },
        .footnote_def => .{ .color = rgb(130, 80, 223), .bold = true },

        // GFM alerts
        .alert_marker => .{ .color = rgb(191, 135, 0), .bold = true },

        // Emoji shortcodes
        .emoji => .{ .color = rgb(227, 98, 9) },
    };
}

/// Built-in light editor theme (GitHub-inspired).
pub const light = EditorTheme{
    .styles = buildStyles(lightStyleFor),
    .editor_bg = rgb(255, 255, 255),
    .default_text = rgb(36, 41, 46),
    .line_number = rgb(175, 184, 193),
    .cursor = rgb(36, 41, 46),
    .selection = rgba(3, 102, 214, 50),
    .current_line_bg = rgba(246, 248, 250, 255),
};

// Dark theme — Catppuccin Mocha-inspired colors

fn darkStyleFor(kind: MdHighlighter.TokenKind) TokenStyle {
    return switch (kind) {
        // Plain body text
        .text => .{ .color = rgb(205, 214, 244) },

        // Headings: blue marker, bold light text
        .heading_marker => .{ .color = rgb(137, 180, 250), .bold = true },
        .heading_text => .{ .color = rgb(205, 214, 244), .bold = true },

        // Emphasis
        .bold => .{ .color = rgb(205, 214, 244), .bold = true },
        .italic => .{ .color = rgb(205, 214, 244), .italic = true },
        .bold_italic => .{ .color = rgb(205, 214, 244), .bold = true, .italic = true },

        // Code
        .code_span => .{ .color = rgb(243, 139, 168) },
        .fence => .{ .color = rgb(108, 112, 134) },
        .code_line => .{ .color = rgb(205, 214, 244) },

        // Links and images
        .link_text => .{ .color = rgb(137, 180, 250) },
        .link_url => .{ .color = rgb(147, 153, 178), .italic = true },
        .image_marker => .{ .color = rgb(203, 166, 247) },

        // Lists
        .list_marker => .{ .color = rgb(243, 139, 168), .bold = true },

        // Blockquotes
        .blockquote_marker => .{ .color = rgb(147, 153, 178), .bold = true },

        // Tables
        .table_pipe => .{ .color = rgb(147, 153, 178) },
        .table_align => .{ .color = rgb(147, 153, 178) },

        // Horizontal rule
        .horizontal_rule => .{ .color = rgb(108, 112, 134) },

        // GFM extensions
        .strikethrough => .{ .color = rgb(147, 153, 178), .italic = true },
        .task_marker => .{ .color = rgb(203, 166, 247), .bold = true },

        // HTML
        .html_tag => .{ .color = rgb(166, 227, 161) },

        // Escape sequences
        .escape => .{ .color = rgb(250, 179, 135) },

        // Autolinks
        .autolink => .{ .color = rgb(137, 180, 250) },

        // Footnotes
        .footnote_ref => .{ .color = rgb(203, 166, 247) },
        .footnote_def => .{ .color = rgb(203, 166, 247), .bold = true },

        // GFM alerts
        .alert_marker => .{ .color = rgb(249, 226, 175), .bold = true },

        // Emoji shortcodes
        .emoji => .{ .color = rgb(250, 179, 135) },
    };
}

/// Built-in dark editor theme (Catppuccin Mocha-inspired).
pub const dark = EditorTheme{
    .styles = buildStyles(darkStyleFor),
    .editor_bg = rgb(30, 30, 46),
    .default_text = rgb(205, 214, 244),
    .line_number = rgb(108, 112, 134),
    .cursor = rgb(205, 214, 244),
    .selection = rgba(137, 180, 250, 50),
    .current_line_bg = rgba(49, 50, 68, 255),
};

const testing = std.testing;

test "EditorTheme light has style for every token kind" {
    inline for (@typeInfo(MdHighlighter.TokenKind).@"enum".fields) |field| {
        const kind: MdHighlighter.TokenKind = @enumFromInt(field.value);
        const style = light.styleFor(kind);
        // Every token must have a non-zero alpha (visible)
        try testing.expect(style.color.a > 0);
    }
}

test "EditorTheme dark has style for every token kind" {
    inline for (@typeInfo(MdHighlighter.TokenKind).@"enum".fields) |field| {
        const kind: MdHighlighter.TokenKind = @enumFromInt(field.value);
        const style = dark.styleFor(kind);
        try testing.expect(style.color.a > 0);
    }
}

test "EditorTheme heading_marker is bold" {
    try testing.expect(light.styleFor(.heading_marker).bold);
    try testing.expect(dark.styleFor(.heading_marker).bold);
}

test "EditorTheme heading_text is bold" {
    try testing.expect(light.styleFor(.heading_text).bold);
    try testing.expect(dark.styleFor(.heading_text).bold);
}

test "EditorTheme bold tokens have bold attribute" {
    try testing.expect(light.styleFor(.bold).bold);
    try testing.expect(dark.styleFor(.bold).bold);
}

test "EditorTheme italic tokens have italic attribute" {
    try testing.expect(light.styleFor(.italic).italic);
    try testing.expect(dark.styleFor(.italic).italic);
}

test "EditorTheme bold_italic has both attributes" {
    const light_bi = light.styleFor(.bold_italic);
    try testing.expect(light_bi.bold);
    try testing.expect(light_bi.italic);

    const dark_bi = dark.styleFor(.bold_italic);
    try testing.expect(dark_bi.bold);
    try testing.expect(dark_bi.italic);
}

test "EditorTheme text token is not bold or italic" {
    const style = light.styleFor(.text);
    try testing.expect(!style.bold);
    try testing.expect(!style.italic);
}

test "EditorTheme link_url is italic" {
    try testing.expect(light.styleFor(.link_url).italic);
    try testing.expect(dark.styleFor(.link_url).italic);
}

test "EditorTheme strikethrough is italic" {
    try testing.expect(light.styleFor(.strikethrough).italic);
    try testing.expect(dark.styleFor(.strikethrough).italic);
}

test "EditorTheme list_marker is bold" {
    try testing.expect(light.styleFor(.list_marker).bold);
    try testing.expect(dark.styleFor(.list_marker).bold);
}

test "EditorTheme task_marker is bold" {
    try testing.expect(light.styleFor(.task_marker).bold);
    try testing.expect(dark.styleFor(.task_marker).bold);
}

test "EditorTheme setStyle modifies style" {
    var theme = light;
    const new_style = TokenStyle{ .color = rgb(255, 0, 0), .bold = true, .italic = true };
    theme.setStyle(.text, new_style);
    const result = theme.styleFor(.text);
    try testing.expectEqual(@as(u8, 255), result.color.r);
    try testing.expect(result.bold);
    try testing.expect(result.italic);
}

test "EditorTheme light and dark have distinct editor backgrounds" {
    try testing.expect(light.editor_bg.r != dark.editor_bg.r or
        light.editor_bg.g != dark.editor_bg.g or
        light.editor_bg.b != dark.editor_bg.b);
}

test "EditorTheme light link_text is blue" {
    const style = light.styleFor(.link_text);
    // Blue channel should be dominant
    try testing.expect(style.color.b > style.color.r);
    try testing.expect(style.color.b > style.color.g);
}

test "EditorTheme code_span has distinct color from text" {
    const text_style = light.styleFor(.text);
    const code_style = light.styleFor(.code_span);
    // code_span should be visually distinct from plain text
    try testing.expect(text_style.color.r != code_style.color.r or
        text_style.color.g != code_style.color.g or
        text_style.color.b != code_style.color.b);
}
