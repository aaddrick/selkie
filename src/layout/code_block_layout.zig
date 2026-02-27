const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");

const lt = @import("layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("text_measurer.zig").Fonts;
const syntax = @import("../render/syntax_highlight.zig");

/// Lay out a code block with line numbers and syntax highlighting.
/// Produces a single LayoutNode with text_runs for each highlighted token
/// and each line number.
pub fn layoutCodeBlock(
    allocator: Allocator,
    code_text: ?[]const u8,
    fence_info: ?[]const u8,
    theme: *const Theme,
    fonts: *const Fonts,
    content_x: f32,
    content_width: f32,
    cursor_y: *f32,
    tree: *lt.LayoutTree,
) !void {
    const source = code_text orelse "";
    const padding = theme.code_block_padding;
    const font_size = theme.mono_font_size;
    const line_h = font_size * theme.line_height;
    const spacing = font_size / 10.0;

    var line_count: u32 = 1;
    for (source) |ch| {
        if (ch == '\n') line_count += 1;
    }
    // cmark often includes a trailing newline; don't count it as an extra empty line
    if (source.len > 0 and source[source.len - 1] == '\n') {
        line_count -= 1;
        if (line_count == 0) line_count = 1;
    }

    // Measure the widest line number string to size the gutter
    var digit_buf: [16]u8 = undefined;
    const digit_str = std.fmt.bufPrint(&digit_buf, "{d}", .{line_count}) catch "0";
    const gutter_text_width = fonts.measure(digit_str, font_size, false, false, true).x;
    const gutter_padding: f32 = 12;
    const gutter_width = gutter_text_width + gutter_padding * 2;

    // Total code block height
    const code_height = @as(f32, @floatFromInt(line_count)) * line_h;
    const total_height = code_height + padding * 2;

    var layout_node = lt.LayoutNode.init(allocator, .{ .code_block = .{
        .bg_color = theme.code_background,
        .lang = fence_info,
        .line_number_gutter_width = gutter_width,
    } });
    errdefer layout_node.deinit();

    layout_node.rect = .{
        .x = content_x,
        .y = cursor_y.*,
        .width = content_width,
        .height = total_height,
    };

    // Add line number text runs — each string arena-allocated to outlive layout pass
    const gutter_x = content_x + gutter_padding;
    const code_x = content_x + gutter_width + spacing * 2; // small gap after gutter
    const line_y = cursor_y.* + padding;
    const arena_alloc = tree.arena.allocator();
    var line_idx: u32 = 1;
    while (line_idx <= line_count) : (line_idx += 1) {
        const num_str = try std.fmt.allocPrint(arena_alloc, "{d}", .{line_idx});
        const num_width = fonts.measure(num_str, font_size, false, false, true).x;
        // Right-align line numbers within gutter
        const num_x = gutter_x + (gutter_text_width - num_width);
        try layout_node.text_runs.append(.{
            .text = num_str,
            .style = .{
                .font_size = font_size,
                .color = theme.line_number_color,
                .is_code = true,
            },
            .rect = .{
                .x = num_x,
                .y = line_y + @as(f32, @floatFromInt(line_idx - 1)) * line_h,
                .width = num_width,
                .height = line_h,
            },
        });
    }

    // Tokenize and lay out code with syntax highlighting
    const lang_def = if (fence_info) |fi| syntax.getLangDef(fi) else null;

    if (lang_def) |ld| {
        const tokens = try syntax.tokenize(allocator, source, ld);
        defer allocator.free(tokens);

        var cur_line: u32 = 0;
        var cur_x: f32 = code_x;

        for (tokens) |token| {
            const token_text = source[token.start..token.end];
            const color = tokenColor(token.kind, theme);

            var seg_start: usize = 0;
            for (token_text, 0..) |tch, ti| {
                if (tch == '\n') {
                    if (ti > seg_start) {
                        cur_x += try appendCodeRun(&layout_node, fonts, token_text[seg_start..ti], color, font_size, cur_x, line_y, cur_line, line_h);
                    }
                    cur_line += 1;
                    cur_x = code_x;
                    seg_start = ti + 1;
                }
            }
            if (seg_start < token_text.len) {
                cur_x += try appendCodeRun(&layout_node, fonts, token_text[seg_start..], color, font_size, cur_x, line_y, cur_line, line_h);
            }
        }
    } else {
        // No highlighting: render line by line in plain code_text color
        var cur_line: u32 = 0;
        var line_start: usize = 0;
        for (source, 0..) |ch, si| {
            if (ch == '\n') {
                if (si > line_start) {
                    _ = try appendCodeRun(&layout_node, fonts, source[line_start..si], theme.code_text, font_size, code_x, line_y, cur_line, line_h);
                }
                cur_line += 1;
                line_start = si + 1;
            }
        }
        if (line_start < source.len) {
            _ = try appendCodeRun(&layout_node, fonts, source[line_start..], theme.code_text, font_size, code_x, line_y, cur_line, line_h);
        }
    }

    try tree.nodes.append(layout_node);
    cursor_y.* += total_height + theme.paragraph_spacing;
}

/// Append a single code text run and return its measured width.
fn appendCodeRun(
    layout_node: *lt.LayoutNode,
    fonts: *const Fonts,
    text: []const u8,
    color: rl.Color,
    font_size: f32,
    x: f32,
    base_y: f32,
    line: u32,
    line_h: f32,
) !f32 {
    const seg_w = fonts.measure(text, font_size, false, false, true).x;
    try layout_node.text_runs.append(.{
        .text = text,
        .style = .{
            .font_size = font_size,
            .color = color,
            .is_code = true,
        },
        .rect = .{
            .x = x,
            .y = base_y + @as(f32, @floatFromInt(line)) * line_h,
            .width = seg_w,
            .height = line_h,
        },
    });
    return seg_w;
}

fn tokenColor(kind: syntax.TokenKind, theme: *const Theme) rl.Color {
    return switch (kind) {
        .keyword => theme.syntax_keyword,
        .string => theme.syntax_string,
        .comment => theme.syntax_comment,
        .number => theme.syntax_number,
        .type_name => theme.syntax_type,
        .function => theme.syntax_function,
        .operator => theme.syntax_operator,
        .punctuation => theme.syntax_punctuation,
        .text => theme.code_text,
    };
}
