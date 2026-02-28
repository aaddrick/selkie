const std = @import("std");
const rl = @import("raylib");

const EditorState = @import("../editor/editor_state.zig").EditorState;
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const slice_utils = @import("../utils/slice_utils.zig");

/// Padding between gutter right edge and text content.
pub const gutter_text_padding: f32 = 12;
/// Padding inside the gutter (right of line numbers).
const gutter_inner_padding: f32 = 8;
/// Left margin before gutter numbers.
const gutter_left_margin: f32 = 8;
/// Horizontal scroll margin — keeps cursor this far from the edge.
const horizontal_scroll_margin: f32 = 40;
/// Alpha for the cursor line highlight overlay.
const cursor_line_highlight_alpha: u8 = 20;
/// Maximum line length (bytes) supported for rendering and cursor measurement.
const max_line_bytes: usize = 8192;

/// Compute the width of the line number gutter based on the total number of lines.
pub fn gutterWidth(line_count: usize, font: rl.Font, font_size: f32, spacing: f32) f32 {
    // Format the largest line number to measure its width
    var buf: [12:0]u8 = undefined;
    const label = std.fmt.bufPrintZ(&buf, "{d}", .{line_count}) catch return 60;
    const measured = rl.measureTextEx(font, label, font_size, spacing);
    return gutter_left_margin + measured.x + gutter_inner_padding;
}

/// Compute the pixel X offset for a cursor at `byte_col` in `line_text`.
/// Measures the substring from 0..byte_col using the monospace font.
pub fn cursorPixelX(line_text: []const u8, byte_col: usize, font: rl.Font, font_size: f32, spacing: f32) f32 {
    const col = @min(byte_col, line_text.len);
    if (col == 0) return 0;

    const prefix = line_text[0..col];
    var buf: [max_line_bytes]u8 = undefined;
    if (prefix.len >= buf.len) return 0;
    const z = slice_utils.sliceToZ(&buf, prefix);
    return rl.measureTextEx(font, z, font_size, spacing).x;
}

/// Compute the Y position of a line relative to the editor content area origin.
pub fn lineY(line_index: usize, line_height: f32) f32 {
    return @as(f32, @floatFromInt(line_index)) * line_height;
}

/// Draw the editor view: raw source text with line numbers and blinking cursor.
/// Caller must ensure the editor is open before calling.
pub fn drawEditor(
    editor: *const EditorState,
    theme: *const Theme,
    fonts: *const Fonts,
    scroll_y: f32,
    scroll_x: f32,
    content_top_y: f32,
    left_offset: f32,
) void {
    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const font = fonts.mono;
    const font_size = theme.mono_font_size;
    const spacing = font_size / 10.0;
    const line_height = font_size * theme.line_height;

    const editor_width = screen_w - left_offset;
    const editor_height = screen_h - content_top_y;

    // Bail out if editor area has no usable dimensions
    if (editor_width <= 0 or editor_height <= 0 or line_height <= 0) return;

    rl.drawRectangleRec(
        .{ .x = left_offset, .y = content_top_y, .width = editor_width, .height = editor_height },
        theme.code_background,
    );

    const gutter_w = gutterWidth(editor.lineCount(), font, font_size, spacing);
    const text_area_x = left_offset + gutter_w + gutter_text_padding;
    const text_area_w = @max(0, screen_w - text_area_x);

    // Visible line range
    const first_visible: usize = @intFromFloat(@max(0, @floor(scroll_y / line_height)));
    const visible_lines: usize = @intFromFloat(@max(0, @floor(editor_height / line_height) + 2));
    const last_visible = @min(first_visible + visible_lines, editor.lineCount());

    // Gutter background (same color now, but drawn separately for future theming)
    rl.drawRectangleRec(
        .{ .x = left_offset, .y = content_top_y, .width = gutter_w, .height = editor_height },
        theme.code_background,
    );

    // Scissor region for the text content area (excludes gutter)
    rl.beginScissorMode(
        @intFromFloat(@max(0, text_area_x)),
        @intFromFloat(@max(0, content_top_y)),
        @intFromFloat(text_area_w),
        @intFromFloat(@max(0, editor_height)),
    );

    // Draw visible lines
    for (first_visible..last_visible) |i| {
        const y = content_top_y + lineY(i, line_height) - scroll_y;
        const line_text = editor.getLineText(i) orelse continue;

        // Highlight cursor line
        if (i == editor.cursor_line) {
            rl.drawRectangleRec(
                .{ .x = text_area_x, .y = y, .width = screen_w - text_area_x, .height = line_height },
                .{ .r = theme.code_text.r, .g = theme.code_text.g, .b = theme.code_text.b, .a = cursor_line_highlight_alpha },
            );
        }

        if (line_text.len > 0) {
            var text_buf: [max_line_bytes]u8 = undefined;
            const text_z = slice_utils.sliceToZ(&text_buf, line_text);
            rl.drawTextEx(
                font,
                text_z,
                .{ .x = text_area_x - scroll_x, .y = y },
                font_size,
                spacing,
                theme.code_text,
            );
        }
    }

    // Draw blinking cursor
    if (@mod(rl.getTime(), 1.0) < 0.5) {
        const cursor_x = text_area_x - scroll_x + cursorPixelX(
            editor.getLineText(editor.cursor_line) orelse "",
            editor.cursor_col,
            font,
            font_size,
            spacing,
        );
        const cursor_y = content_top_y + lineY(editor.cursor_line, line_height) - scroll_y;

        rl.drawRectangleRec(
            .{ .x = cursor_x, .y = cursor_y, .width = 2, .height = font_size },
            theme.code_text,
        );
    }

    rl.endScissorMode();

    // Draw gutter line numbers (separate scissor region)
    rl.beginScissorMode(
        @intFromFloat(@max(0, left_offset)),
        @intFromFloat(@max(0, content_top_y)),
        @intFromFloat(@max(0, gutter_w)),
        @intFromFloat(@max(0, editor_height)),
    );

    const gutter_right = left_offset + gutter_w;
    for (first_visible..last_visible) |i| {
        const y = content_top_y + lineY(i, line_height) - scroll_y;

        var num_buf: [12:0]u8 = undefined;
        const label = std.fmt.bufPrintZ(&num_buf, "{d}", .{i + 1}) catch continue;
        const measured = rl.measureTextEx(font, label, font_size, spacing);
        const x = gutter_right - gutter_inner_padding - measured.x;
        rl.drawTextEx(font, label, .{ .x = x, .y = y }, font_size, spacing, theme.line_number_color);
    }

    // Gutter separator line
    rl.drawLineEx(
        .{ .x = gutter_right, .y = content_top_y },
        .{ .x = gutter_right, .y = content_top_y + editor_height },
        1.0,
        theme.line_number_color,
    );

    rl.endScissorMode();
}

/// Compute the total content height of the editor (all lines).
pub fn totalHeight(line_count: usize, font_size: f32, line_height_factor: f32) f32 {
    return @as(f32, @floatFromInt(line_count)) * font_size * line_height_factor;
}

/// Compute the horizontal scroll offset needed to keep the cursor visible.
pub fn scrollXForCursor(
    cursor_pixel_x: f32,
    current_scroll_x: f32,
    text_area_width: f32,
) f32 {
    // Cursor is to the right of visible area
    if (cursor_pixel_x - current_scroll_x > text_area_width - horizontal_scroll_margin) {
        return cursor_pixel_x - text_area_width + horizontal_scroll_margin;
    }
    // Cursor is to the left of visible area
    if (cursor_pixel_x - current_scroll_x < horizontal_scroll_margin) {
        return @max(0, cursor_pixel_x - horizontal_scroll_margin);
    }
    return current_scroll_x;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "lineY returns correct position for line index" {
    try testing.expectEqual(@as(f32, 0), lineY(0, 20.0));
    try testing.expectEqual(@as(f32, 20.0), lineY(1, 20.0));
    try testing.expectEqual(@as(f32, 100.0), lineY(5, 20.0));
}

test "totalHeight computes total content height" {
    // 10 lines * 16.0 font_size * 1.5 line_height = 240.0
    try testing.expectEqual(@as(f32, 240.0), totalHeight(10, 16.0, 1.5));
}

test "totalHeight for zero lines" {
    try testing.expectEqual(@as(f32, 0), totalHeight(0, 16.0, 1.5));
}

test "scrollXForCursor keeps cursor visible on the right" {
    // cursor at 500px, viewport width 400px, margin 40px
    // 500 - 0 = 500 > 400 - 40 = 360 → scroll to 500 - 400 + 40 = 140
    const result = scrollXForCursor(500, 0, 400);
    try testing.expectEqual(@as(f32, 140), result);
}

test "scrollXForCursor keeps cursor visible on the left" {
    // cursor at 20px, current scroll at 100, margin 40px
    // 20 - 100 = -80 < 40 → scroll to max(0, 20 - 40) = 0
    const result = scrollXForCursor(20, 100, 400);
    try testing.expectEqual(@as(f32, 0), result);
}

test "scrollXForCursor no change when cursor is visible" {
    // cursor at 200px, current scroll at 50, viewport 400px, margin 40px
    // 200 - 50 = 150, which is between 40 and 360 → no change
    const result = scrollXForCursor(200, 50, 400);
    try testing.expectEqual(@as(f32, 50), result);
}

test "scrollXForCursor no change at exact left margin boundary" {
    // cursor_pixel_x - current_scroll_x == 40 (margin), not < 40 → no change
    const result = scrollXForCursor(90, 50, 400);
    try testing.expectEqual(@as(f32, 50), result);
}

test "scrollXForCursor no change at exact right margin boundary" {
    // cursor_pixel_x - current_scroll_x == 360 (400 - 40), not > 360 → no change
    const result = scrollXForCursor(410, 50, 400);
    try testing.expectEqual(@as(f32, 50), result);
}
