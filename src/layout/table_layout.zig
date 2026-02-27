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
            const measure_style = layout_types.TextStyle{
                .font_size = font_size,
                .color = theme.text,
                .bold = row.is_header_row,
            };
            var content_w: f32 = 0;
            try measureInlineRuns(cell, fonts, measure_style, &content_w);
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

    // 3. Layout rows and cells
    var y = cursor_y.*;
    var row_idx: usize = 0;

    for (table_node.children.items) |*row| {
        const row_y = y;
        const is_header = row.is_header_row;
        const row_height = line_h + cell_pad * 2;

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

            // Create a text_block-like node for the cell
            var cell_node = layout_types.LayoutNode.init(allocator, .table_cell);
            errdefer cell_node.deinit();

            // Layout inline content within the cell
            const text_x = cell_x + cell_pad;
            const text_y = row_y + cell_pad;
            const available_w = col_w - cell_pad * 2;

            const style = layout_types.TextStyle{
                .font_size = font_size,
                .color = theme.text,
                .bold = is_header,
            };

            try layoutCellInlineContent(
                cell,
                fonts,
                &cell_node,
                style,
                text_x,
                text_y,
                available_w,
                alignment,
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

/// Layout inline content within a table cell using a two-pass approach:
/// first measures total width for alignment, then places text runs.
fn layoutCellInlineContent(
    node: *const ast.Node,
    fonts: *const Fonts,
    layout_node: *layout_types.LayoutNode,
    style: layout_types.TextStyle,
    text_x: f32,
    text_y: f32,
    available_w: f32,
    alignment: ast.Alignment,
) !void {
    // First pass: measure total content width for alignment
    var total_w: f32 = 0;
    try measureInlineRuns(node, fonts, style, &total_w);

    // Calculate alignment offset
    const offset: f32 = switch (alignment) {
        .center => @max(0, (available_w - total_w) / 2.0),
        .right => @max(0, available_w - total_w),
        .none, .left => 0,
    };

    // Second pass: place runs
    var cursor_x = text_x + offset;
    try placeInlineRuns(node, fonts, layout_node, style, &cursor_x, text_y);
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

/// Recursively place inline content as text runs on a layout node.
fn placeInlineRuns(
    node: *const ast.Node,
    fonts: *const Fonts,
    layout_node: *layout_types.LayoutNode,
    style: layout_types.TextStyle,
    cursor_x: *f32,
    text_y: f32,
) !void {
    for (node.children.items) |*child| {
        switch (child.node_type) {
            .text => {
                if (child.literal) |text| {
                    const m = fonts.measure(text, style.font_size, style.bold, style.italic, style.is_code);
                    try layout_node.text_runs.append(.{
                        .text = text,
                        .style = style,
                        .rect = .{ .x = cursor_x.*, .y = text_y, .width = m.x, .height = m.y },
                    });
                    cursor_x.* += m.x;
                }
            },
            .code => {
                if (child.literal) |text| {
                    var code_style = style;
                    code_style.is_code = true;
                    const m = fonts.measure(text, style.font_size, false, false, true);
                    try layout_node.text_runs.append(.{
                        .text = text,
                        .style = code_style,
                        .rect = .{ .x = cursor_x.*, .y = text_y, .width = m.x, .height = m.y },
                    });
                    cursor_x.* += m.x;
                }
            },
            .softbreak => {
                const m = fonts.measure(" ", style.font_size, false, false, false);
                try layout_node.text_runs.append(.{
                    .text = " ",
                    .style = style,
                    .rect = .{ .x = cursor_x.*, .y = text_y, .width = m.x, .height = m.y },
                });
                cursor_x.* += m.x;
            },
            .strong => {
                var s = style;
                s.bold = true;
                try placeInlineRuns(child, fonts, layout_node, s, cursor_x, text_y);
            },
            .emph => {
                var s = style;
                s.italic = true;
                try placeInlineRuns(child, fonts, layout_node, s, cursor_x, text_y);
            },
            .strikethrough => {
                var s = style;
                s.strikethrough = true;
                try placeInlineRuns(child, fonts, layout_node, s, cursor_x, text_y);
            },
            .link => {
                var s = style;
                s.underline = true;
                s.link_url = child.url;
                try placeInlineRuns(child, fonts, layout_node, s, cursor_x, text_y);
            },
            else => {
                try placeInlineRuns(child, fonts, layout_node, style, cursor_x, text_y);
            },
        }
    }
}
