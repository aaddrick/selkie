const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");

const ast = @import("../parser/ast.zig");
const layout_types = @import("layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("text_measurer.zig").Fonts;

/// Layout a table AST node into LayoutNodes appended to the tree.
pub fn layoutTable(
    allocator: Allocator,
    table_node: *const ast.Node,
    tree: *layout_types.LayoutTree,
    theme: *const Theme,
    fonts: *const Fonts,
    content_x: f32,
    content_width: f32,
    cursor_y: *f32,
) !void {
    const alignments = table_node.table_alignments orelse &[_]ast.Alignment{};
    const num_cols: usize = @intCast(table_node.table_columns);
    if (num_cols == 0) return;

    const cell_pad = theme.table_cell_padding;
    const font_size = theme.body_font_size;
    const line_h = font_size * theme.line_height;

    // 1. Measure natural column widths from content
    var col_widths = try allocator.alloc(f32, num_cols);
    defer allocator.free(col_widths);
    @memset(col_widths, 0);

    for (table_node.children.items) |*row| {
        var col_idx: usize = 0;
        for (row.children.items) |*cell| {
            if (col_idx >= num_cols) break;
            const style = cellTextStyle(theme, font_size, row.is_header_row);
            var content_w: f32 = 0;
            try measureInlineRuns(cell, fonts, style, &content_w);
            const w = content_w + cell_pad * 2;
            col_widths[col_idx] = @max(col_widths[col_idx], w);
            col_idx += 1;
        }
    }

    // 2. Scale columns to fit available width
    var total_natural: f32 = 0;
    for (col_widths) |w| total_natural += w;

    const min_col_width: f32 = 60;
    if (total_natural > content_width) {
        // Proportional scaling
        const scale = content_width / total_natural;
        for (col_widths) |*w| {
            w.* = @max(min_col_width, w.* * scale);
        }
    } else if (total_natural < content_width) {
        // Distribute remaining space proportionally
        const extra = content_width - total_natural;
        const per_col = extra / @as(f32, @floatFromInt(num_cols));
        for (col_widths) |*w| {
            w.* += per_col;
        }
    }

    // 3. Compute per-row heights based on wrapped content
    const num_rows = table_node.children.items.len;
    var row_heights = try allocator.alloc(f32, num_rows);
    defer allocator.free(row_heights);

    for (table_node.children.items, 0..) |*row, ri| {
        var max_lines: usize = 1;
        var col_idx: usize = 0;
        for (row.children.items) |*cell| {
            if (col_idx >= num_cols) break;
            const available_w = col_widths[col_idx] - cell_pad * 2;
            const style = cellTextStyle(theme, font_size, row.is_header_row);

            var line_count: usize = 1;
            var cursor_x: f32 = 0;
            // Uses relative coordinates: line_start=0, max=available_w
            try walkInlineContent(cell, fonts, null, style, &cursor_x, null, 0, available_w, line_h, null, &line_count);

            max_lines = @max(max_lines, line_count);
            col_idx += 1;
        }
        row_heights[ri] = line_h * @as(f32, @floatFromInt(max_lines)) + cell_pad * 2;
    }

    // 4. Layout rows and cells with dynamic heights
    var y = cursor_y.*;
    var row_idx: usize = 0;

    for (table_node.children.items, 0..) |*row, ri| {
        const row_y = y;
        const is_header = row.is_header_row;
        const row_height = row_heights[ri];

        // Row background: header gets header color, even body rows get alternating color
        const row_bg_color: ?rl.Color = if (is_header)
            theme.table_header_bg
        else if (row_idx % 2 == 0)
            theme.table_alt_row_bg
        else
            null;

        if (row_bg_color) |bg_color| {
            var bg_node = layout_types.LayoutNode.init(allocator, .{ .table_row_bg = .{ .bg_color = bg_color } });
            errdefer bg_node.deinit();
            bg_node.rect = .{
                .x = content_x,
                .y = row_y,
                .width = content_width,
                .height = row_height,
            };
            try tree.nodes.append(bg_node);
        }

        // Cells
        var cell_x = content_x;
        var col_idx: usize = 0;
        for (row.children.items) |*cell| {
            if (col_idx >= num_cols) break;
            const col_w = col_widths[col_idx];
            const alignment: ast.Alignment = if (col_idx < alignments.len) alignments[col_idx] else .none;

            var cell_node = layout_types.LayoutNode.init(allocator, .table_cell);
            errdefer cell_node.deinit();

            const text_x = cell_x + cell_pad;
            const text_y = row_y + cell_pad;
            const available_w = col_w - cell_pad * 2;
            const style = cellTextStyle(theme, font_size, is_header);

            try layoutCellInlineContent(
                cell,
                fonts,
                theme,
                &cell_node,
                style,
                text_x,
                text_y,
                available_w,
                alignment,
                line_h,
            );

            cell_node.rect = .{
                .x = cell_x,
                .y = row_y,
                .width = col_w,
                .height = row_height,
            };

            try tree.nodes.append(cell_node);
            cell_x += col_w;
            col_idx += 1;
        }

        // Horizontal border below row
        var h_border = layout_types.LayoutNode.init(allocator, .{ .table_border = .{ .color = theme.table_border } });
        errdefer h_border.deinit();
        h_border.rect = .{
            .x = content_x,
            .y = row_y + row_height,
            .width = content_width,
            .height = 1,
        };
        try tree.nodes.append(h_border);

        y += row_height;
        if (!is_header) row_idx += 1;
    }

    // Top border
    var top_border = layout_types.LayoutNode.init(allocator, .{ .table_border = .{ .color = theme.table_border } });
    errdefer top_border.deinit();
    top_border.rect = .{
        .x = content_x,
        .y = cursor_y.*,
        .width = content_width,
        .height = 1,
    };
    try tree.nodes.append(top_border);

    // Vertical borders
    var vx = content_x;
    for (0..num_cols + 1) |i| {
        var v_border = layout_types.LayoutNode.init(allocator, .{ .table_border = .{ .color = theme.table_border } });
        errdefer v_border.deinit();
        v_border.rect = .{
            .x = vx,
            .y = cursor_y.*,
            .width = 1,
            .height = y - cursor_y.*,
        };
        try tree.nodes.append(v_border);

        if (i < num_cols) vx += col_widths[i];
    }

    cursor_y.* = y + theme.paragraph_spacing;
}

/// Build a TextStyle for table cell text, bold if header row.
fn cellTextStyle(theme: *const Theme, font_size: f32, is_header: bool) layout_types.TextStyle {
    return .{
        .font_size = font_size,
        .color = theme.text,
        .bold = is_header,
    };
}

test "cellTextStyle returns bold for header rows" {
    var theme = std.mem.zeroes(Theme);
    theme.text = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const style = cellTextStyle(&theme, 16.0, true);
    try std.testing.expect(style.bold);
    try std.testing.expectEqual(@as(f32, 16.0), style.font_size);
    try std.testing.expectEqual(theme.text, style.color);
}

test "cellTextStyle returns non-bold for body rows" {
    var theme = std.mem.zeroes(Theme);
    theme.text = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const style = cellTextStyle(&theme, 14.0, false);
    try std.testing.expect(!style.bold);
    try std.testing.expectEqual(@as(f32, 14.0), style.font_size);
    try std.testing.expectEqual(theme.text, style.color);
}

/// Layout inline content within a table cell with word wrapping.
/// Alignment offset applies only when content fits on a single line.
fn layoutCellInlineContent(
    node: *const ast.Node,
    fonts: *const Fonts,
    theme: *const Theme,
    layout_node: *layout_types.LayoutNode,
    style: layout_types.TextStyle,
    text_x: f32,
    text_y: f32,
    available_w: f32,
    alignment: ast.Alignment,
    line_h: f32,
) !void {
    var total_w: f32 = 0;
    try measureInlineRuns(node, fonts, style, &total_w);

    // Alignment offset only applies when content fits on a single line.
    // The counting pass (in layoutTable step 3) uses relative coordinates without
    // alignment offset. This is safe because offset is only non-zero when content
    // fits in one line, meaning no wrapping occurs regardless of offset.
    const max_x = text_x + available_w;
    const offset: f32 = if (total_w <= available_w) switch (alignment) {
        .center => @max(0, (available_w - total_w) / 2.0),
        .right => @max(0, available_w - total_w),
        .none, .left => 0,
    } else 0;

    var cursor_x = text_x + offset;
    var cursor_y = text_y;
    try walkInlineContent(node, fonts, theme, style, &cursor_x, &cursor_y, text_x, max_x, line_h, layout_node, null);
}

/// Recursively measure the total width of inline content within a node.
fn measureInlineRuns(
    node: *const ast.Node,
    fonts: *const Fonts,
    style: layout_types.TextStyle,
    total_w: *f32,
) !void {
    for (node.children.items) |*child| {
        switch (child.node_type) {
            .text => {
                if (child.literal) |text| {
                    const m = fonts.measure(text, style.font_size, style.bold, style.italic, style.is_code);
                    total_w.* += m.x;
                }
            },
            .code => {
                if (child.literal) |text| {
                    const m = fonts.measure(text, style.font_size, false, false, true);
                    total_w.* += m.x;
                }
            },
            .softbreak => {
                const m = fonts.measure(" ", style.font_size, false, false, false);
                total_w.* += m.x;
            },
            .strong => {
                var s = style;
                s.bold = true;
                try measureInlineRuns(child, fonts, s, total_w);
            },
            .emph => {
                var s = style;
                s.italic = true;
                try measureInlineRuns(child, fonts, s, total_w);
            },
            .strikethrough => {
                var s = style;
                s.strikethrough = true;
                try measureInlineRuns(child, fonts, s, total_w);
            },
            .link => {
                var s = style;
                s.underline = true;
                try measureInlineRuns(child, fonts, s, total_w);
            },
            else => {
                try measureInlineRuns(child, fonts, style, total_w);
            },
        }
    }
}

/// Unified recursive walk over inline content with word wrapping.
/// When `layout_node` is non-null, creates text runs (placement pass).
/// When `layout_node` is null, only advances cursors for line counting.
/// `line_start_x` is the left margin for wrap resets; `max_x` is the right edge.
/// All coordinates are in the same space (relative for counting, absolute for placing).
fn walkInlineContent(
    node: *const ast.Node,
    fonts: *const Fonts,
    theme: ?*const Theme,
    style: layout_types.TextStyle,
    cursor_x: *f32,
    cursor_y: ?*f32,
    line_start_x: f32,
    max_x: f32,
    line_h: f32,
    layout_node: ?*layout_types.LayoutNode,
    line_count: ?*usize,
) !void {
    for (node.children.items) |*child| {
        switch (child.node_type) {
            .text => {
                if (child.literal) |text| {
                    try wrapText(text, fonts, style, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count);
                }
            },
            .code => {
                if (child.literal) |text| {
                    var code_style = style;
                    code_style.is_code = true;
                    if (theme) |t| {
                        code_style.color = t.code_text;
                        code_style.code_bg = t.code_background;
                    }
                    try wrapText(text, fonts, code_style, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count);
                }
            },
            .softbreak => {
                const m = fonts.measure(" ", style.font_size, false, false, false);
                // Apply same wrap check as regular text
                if (cursor_x.* + m.x > max_x and cursor_x.* > line_start_x) {
                    cursor_x.* = line_start_x;
                    if (cursor_y) |cy| cy.* += line_h;
                    if (line_count) |lc| lc.* += 1;
                }
                if (layout_node) |ln| {
                    try ln.text_runs.append(.{
                        .text = " ",
                        .style = style,
                        .rect = .{ .x = cursor_x.*, .y = if (cursor_y) |cy| cy.* else 0, .width = m.x, .height = m.y },
                    });
                }
                cursor_x.* += m.x;
            },
            .strong => {
                var s = style;
                s.bold = true;
                try walkInlineContent(child, fonts, theme, s, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count);
            },
            .emph => {
                var s = style;
                s.italic = true;
                try walkInlineContent(child, fonts, theme, s, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count);
            },
            .strikethrough => {
                var s = style;
                s.strikethrough = true;
                try walkInlineContent(child, fonts, theme, s, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count);
            },
            .link => {
                var s = style;
                if (theme) |t| {
                    s.color = t.link;
                }
                s.underline = true;
                s.link_url = child.url;
                try walkInlineContent(child, fonts, theme, s, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count);
            },
            else => {
                try walkInlineContent(child, fonts, theme, style, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count);
            },
        }
    }
}

/// Word-wrap a text string. When `layout_node` is non-null, also creates text runs.
/// Words wider than `max_x - line_start_x` are placed without wrapping to avoid infinite loops.
fn wrapText(
    text: []const u8,
    fonts: *const Fonts,
    style: layout_types.TextStyle,
    cursor_x: *f32,
    cursor_y: ?*f32,
    line_start_x: f32,
    max_x: f32,
    line_h: f32,
    layout_node: ?*layout_types.LayoutNode,
    line_count: ?*usize,
) !void {
    var remaining = text;
    while (remaining.len > 0) {
        var word_end: usize = 0;
        while (word_end < remaining.len and remaining[word_end] != ' ') : (word_end += 1) {}
        const chunk_end = if (word_end < remaining.len) word_end + 1 else word_end;
        const word = remaining[0..chunk_end];
        const measured = fonts.measure(word, style.font_size, style.bold, style.italic, style.is_code);

        // The line_start_x guard prevents wrapping when already at line start,
        // avoiding infinite loops on words wider than the available width.
        if (cursor_x.* + measured.x > max_x and cursor_x.* > line_start_x) {
            cursor_x.* = line_start_x;
            if (cursor_y) |cy| cy.* += line_h;
            if (line_count) |lc| lc.* += 1;
        }

        if (layout_node) |ln| {
            try ln.text_runs.append(.{
                .text = word,
                .style = style,
                .rect = .{ .x = cursor_x.*, .y = if (cursor_y) |cy| cy.* else 0, .width = measured.x, .height = measured.y },
            });
        }
        cursor_x.* += measured.x;
        remaining = remaining[chunk_end..];
    }
}
