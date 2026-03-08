const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");

const ast = @import("../parser/ast.zig");
const layout_types = @import("layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("text_measurer.zig").Fonts;
/// Used for LaTeX→display-string conversion in table cells containing math_inline nodes.
const display_math = @import("../render/math_renderer.zig");

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
    // Arena allocator for persistent strings (e.g. math display strings in text runs).
    const arena = tree.arena.allocator();

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
            // Uses relative coordinates: line_start=0, max=available_w.
            // layout_node=null means counting-only pass -- math_inline display strings
            // are measured but never arena-duped, so `allocator` is safe to pass here.
            try walkInlineContent(cell, fonts, null, style, &cursor_x, null, 0, available_w, line_h, null, &line_count, allocator);

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
                arena,
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

/// Layout inline content within a table cell with word wrapping.
/// Alignment offset applies only when content fits on a single line.
/// `arena` is the LayoutTree arena allocator, used to persist math display strings
/// in text runs. The arena is owned by the LayoutTree and lives for the entire
/// layout pass.
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
    arena: Allocator,
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
    try walkInlineContent(node, fonts, theme, style, &cursor_x, &cursor_y, text_x, max_x, line_h, layout_node, null, arena);

    // Post-layout clamp: ensure no text run extends beyond the right cell edge.
    // This corrects for measurement discrepancies between measureInlineRuns (whole-string)
    // and wrapText (word-by-word) that can cause right/center-aligned text to overflow.
    const cell_right = text_x + available_w;
    var max_right: f32 = 0;
    for (layout_node.text_runs.items) |run| {
        const run_right = run.rect.x + run.rect.width;
        max_right = @max(max_right, run_right);
    }
    if (max_right > cell_right + 0.5) { // 0.5 tolerance for float rounding
        const shift = max_right - cell_right;
        for (layout_node.text_runs.items) |*run| {
            run.rect.x -= shift;
        }
    }
}

/// Recursively measure the total width of inline content within a node.
/// Uses a local stack buffer for math display strings -- measurement only, no allocation.
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
            .math_inline => {
                // Convert LaTeX to display string using a local stack buffer (measurement only).
                // The C library (latex_render_parse) resolves Greek letters, operators,
                // fractions, super/subscripts, etc. No allocation is needed here because
                // we only measure the width -- the buffer is discarded after this call.
                if (child.literal) |latex| {
                    var buf: [4096]u8 = undefined;
                    const display = display_math.latexToDisplayString(latex, &buf);
                    // Math is rendered italic by convention; measure with the italic font.
                    const m = fonts.measure(display, style.font_size, false, true, false);
                    total_w.* += m.x;
                }
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
/// `arena` is used to dupe math display strings into persistent storage when
/// `layout_node` is non-null. In the counting pass (layout_node == null) no
/// arena allocation occurs, so any allocator may be safely passed.
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
    arena: Allocator,
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
                try walkInlineContent(child, fonts, theme, s, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count, arena);
            },
            .emph => {
                var s = style;
                s.italic = true;
                try walkInlineContent(child, fonts, theme, s, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count, arena);
            },
            .strikethrough => {
                var s = style;
                s.strikethrough = true;
                try walkInlineContent(child, fonts, theme, s, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count, arena);
            },
            .link => {
                var s = style;
                if (theme) |t| {
                    s.color = t.link;
                }
                s.underline = true;
                s.link_url = child.url;
                try walkInlineContent(child, fonts, theme, s, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count, arena);
            },
            .math_inline => {
                // Convert LaTeX to Unicode display string via the C library FFI.
                // The C library (latex_render_parse) handles Greek letters, operators,
                // fractions, super/subscripts, sqrt, and other LaTeX constructs.
                // The result is rendered italic with a subtle background (is_math = true).
                if (child.literal) |latex| {
                    var buf: [4096]u8 = undefined;
                    const display_str = display_math.latexToDisplayString(latex, &buf);
                    // Measure with the italic font (math rendering convention).
                    const measured = fonts.measure(display_str, style.font_size, false, true, false);

                    // Wrap if this math expression would exceed the current line boundary.
                    if (cursor_x.* + measured.x > max_x and cursor_x.* > line_start_x) {
                        cursor_x.* = line_start_x;
                        if (cursor_y) |cy| cy.* += line_h;
                        if (line_count) |lc| lc.* += 1;
                    }

                    if (layout_node) |ln| {
                        // Dupe the display string into the LayoutTree arena so it
                        // outlives the local stack buffer `buf`. The arena is alive
                        // for the entire layout pass, so text run slices remain valid.
                        const text = try arena.dupe(u8, display_str);
                        var math_style = style;
                        math_style.italic = true;
                        math_style.is_math = true;
                        try ln.text_runs.append(.{
                            .text = text,
                            .style = math_style,
                            .rect = .{
                                .x = cursor_x.*,
                                .y = if (cursor_y) |cy| cy.* else 0,
                                .width = measured.x,
                                .height = measured.y,
                            },
                        });
                    }
                    cursor_x.* += measured.x;
                }
            },
            else => {
                try walkInlineContent(child, fonts, theme, style, cursor_x, cursor_y, line_start_x, max_x, line_h, layout_node, line_count, arena);
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

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "cellTextStyle returns bold for header rows" {
    var theme = std.mem.zeroes(Theme);
    theme.text = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const style = cellTextStyle(&theme, 16.0, true);
    try testing.expect(style.bold);
    try testing.expectEqual(@as(f32, 16.0), style.font_size);
    try testing.expectEqual(theme.text, style.color);
}

test "cellTextStyle returns non-bold for body rows" {
    var theme = std.mem.zeroes(Theme);
    theme.text = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const style = cellTextStyle(&theme, 14.0, false);
    try testing.expect(!style.bold);
    try testing.expectEqual(@as(f32, 14.0), style.font_size);
    try testing.expectEqual(theme.text, style.color);
}

// --- Alignment offset calculation tests ---

/// Mirror the alignment offset logic from layoutCellInlineContent so we can
/// unit-test it without constructing a full AST.
fn computeAlignmentOffset(total_w: f32, available_w: f32, alignment: ast.Alignment) f32 {
    if (total_w > available_w) return 0;
    return switch (alignment) {
        .center => @max(0, (available_w - total_w) / 2.0),
        .right => @max(0, available_w - total_w),
        .none, .left => 0,
    };
}

test "alignment offset: left and none produce zero offset" {
    try testing.expectEqual(@as(f32, 0), computeAlignmentOffset(50, 100, .left));
    try testing.expectEqual(@as(f32, 0), computeAlignmentOffset(50, 100, .none));
}

test "alignment offset: right aligns text to the cell right edge" {
    // Content width 50, available 100: right offset is 50 (text starts at 50)
    try testing.expectApproxEqAbs(@as(f32, 50), computeAlignmentOffset(50, 100, .right), 0.01);
    // Content equals available -- zero offset
    try testing.expectApproxEqAbs(@as(f32, 0), computeAlignmentOffset(100, 100, .right), 0.01);
}

test "alignment offset: center centers text within the available width" {
    // Content width 60, available 100: center offset is 20
    try testing.expectApproxEqAbs(@as(f32, 20), computeAlignmentOffset(60, 100, .center), 0.01);
    // Content equals available -- center offset is 0
    try testing.expectApproxEqAbs(@as(f32, 0), computeAlignmentOffset(100, 100, .center), 0.01);
}

test "alignment offset: overflow content gets zero offset (not negative)" {
    // Content wider than available -- offset is clamped to 0 for all alignments
    try testing.expectEqual(@as(f32, 0), computeAlignmentOffset(120, 100, .right));
    try testing.expectEqual(@as(f32, 0), computeAlignmentOffset(120, 100, .center));
    try testing.expectEqual(@as(f32, 0), computeAlignmentOffset(120, 100, .left));
}

// --- Math display string integration tests ---

test "math display: E=mc^2 produces superscript 2 via C library" {
    // Verifies the latexToDisplayString integration for the sample table:
    // | Math | `$x^2$` | $x^2$ | LaTeX |
    var buf: [256]u8 = undefined;
    const display = display_math.latexToDisplayString("E = mc^2", &buf);
    // C library converts ^2 -> superscript 2 (U+00B2 = \xc2\xb2)
    try testing.expectEqualStrings("E = mc\xc2\xb2", display);
}

test "math display: quadratic formula from github-markdown-samples.md" {
    // Verifies display string for: $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$
    var buf: [512]u8 = undefined;
    const display = display_math.latexToDisplayString("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", &buf);
    try testing.expect(display.len > 0);
    // Should contain plus-minus sign (U+00B1) and square root sign (U+221A)
    try testing.expect(std.mem.indexOf(u8, display, "\xc2\xb1") != null); // +-
    try testing.expect(std.mem.indexOf(u8, display, "\xe2\x88\x9a") != null); // sqrt
}

test "math display: integral formula symbols present" {
    // docs/github-markdown-samples.md lines 413-415:
    // $$\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$
    var buf: [512]u8 = undefined;
    const display = display_math.latexToDisplayString("\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}", &buf);
    try testing.expect(display.len > 0);
    try testing.expect(std.mem.indexOf(u8, display, "\xe2\x88\xab") != null); // integral sign
    try testing.expect(std.mem.indexOf(u8, display, "\xe2\x88\x9e") != null); // infinity
    try testing.expect(std.mem.indexOf(u8, display, "\xcf\x80") != null); // pi
}
