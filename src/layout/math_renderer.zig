//! LaTeX Math Renderer
//!
//! Parses LaTeX math strings via the vendored latex-render C library (FFI)
//! and converts the resulting node tree into positioned text runs for
//! rendering with raylib.
//!
//! Supports two modes:
//! - Block math: `$$…$$` or ` ```math ` fenced code blocks → centered, larger
//! - Inline math: `$…$` → inline within paragraph text
//!
//! The C library handles parsing and symbol resolution (Greek letters,
//! operators, etc.). This module walks the parse tree and produces
//! LayoutNode text runs with appropriate positioning for fractions,
//! super/subscripts, square roots, and matrices.

const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");

const layout_types = @import("layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("text_measurer.zig").Fonts;

/// C FFI bindings to the vendored latex-render library.
const c = @cImport({
    @cInclude("latex_render.h");
});

/// Node types from the C library, mirrored for pattern matching.
const NodeType = enum(c_int) {
    root = c.LATEX_NODE_ROOT,
    text = c.LATEX_NODE_TEXT,
    fraction = c.LATEX_NODE_FRACTION,
    superscript = c.LATEX_NODE_SUPERSCRIPT,
    subscript = c.LATEX_NODE_SUBSCRIPT,
    sqrt = c.LATEX_NODE_SQRT,
    group = c.LATEX_NODE_GROUP,
    space = c.LATEX_NODE_SPACE,
    delimiter = c.LATEX_NODE_DELIMITER,
    matrix = c.LATEX_NODE_MATRIX,
    matrix_row = c.LATEX_NODE_MATRIX_ROW,
    matrix_cell = c.LATEX_NODE_MATRIX_CELL,
    accent = c.LATEX_NODE_ACCENT,
    operator_name = c.LATEX_NODE_OPERATORNAME,
    _,
};

/// Context for walking the parse tree and emitting text runs.
const RenderContext = struct {
    /// Arena allocator for strings generated during rendering.
    arena: Allocator,
    /// Font metrics provider.
    fonts: *const Fonts,
    /// Theme for colors and sizing.
    theme: *const Theme,
    /// Target layout node to append text runs to.
    layout_node: *layout_types.LayoutNode,
    /// Current cursor X position (absolute).
    cursor_x: f32,
    /// Current baseline Y position (absolute).
    baseline_y: f32,
    /// Current font size (scaled for sub/superscripts).
    font_size: f32,
    /// Text color.
    color: rl.Color,
    /// C parse result (borrowed — for node access).
    result: *c.LatexParseResult,
    /// Maximum X reached (for width calculation).
    max_x: f32,
    /// Maximum Y reached (for height calculation).
    max_y: f32,
    /// When true, emitText() only updates cursor/max tracking and does NOT
    /// append text_runs. Used by fraction measurement passes to avoid emitting
    /// duplicate runs at incorrect positions.
    measuring: bool = false,
};

/// Measure the width of a text string using the current font.
fn measureText(ctx: *const RenderContext, text: []const u8) f32 {
    const m = ctx.fonts.measure(text, ctx.font_size, false, false, false);
    return m.x;
}

/// Emit a text run at the current cursor position.
/// Text is arena-duped so the run remains valid after the C parse result is freed.
/// In measuring mode (`ctx.measuring == true`), only cursor/max tracking is updated
/// without appending any text run — used by the fraction pre-measurement pass.
fn emitText(ctx: *RenderContext, text: []const u8, y_offset: f32) !void {
    const w = measureText(ctx, text);
    if (!ctx.measuring) {
        // Dupe into the arena so the slice remains valid after c.latex_render_free().
        const owned = try ctx.arena.dupe(u8, text);
        try ctx.layout_node.text_runs.append(.{
            .text = owned,
            .style = .{
                .font_size = ctx.font_size,
                .color = ctx.color,
                .is_math = true,
                .y_offset = y_offset,
            },
            .rect = .{
                .x = ctx.cursor_x,
                .y = ctx.baseline_y + y_offset,
                .width = w,
                .height = ctx.font_size,
            },
        });
    }
    ctx.cursor_x += w;
    ctx.max_x = @max(ctx.max_x, ctx.cursor_x);
    ctx.max_y = @max(ctx.max_y, ctx.baseline_y + y_offset + ctx.font_size);
}

/// Get the text of a C node as a Zig slice. Returns empty string if null.
fn nodeText(ctx: *const RenderContext, node_idx: c_int) []const u8 {
    if (node_idx < 0 or node_idx >= ctx.result.count) return "";
    const idx: usize = @intCast(node_idx);
    const node = &ctx.result.nodes[idx];
    const txt = node.text orelse return "";
    if (node.text_len <= 0) return "";
    return txt[0..@intCast(node.text_len)];
}

/// Walk a node and its children, emitting text runs.
/// Uses explicit error{OutOfMemory} to resolve the mutual-recursion error set.
fn renderNode(ctx: *RenderContext, node_idx: c_int) error{OutOfMemory}!void {
    if (node_idx < 0 or node_idx >= ctx.result.count) return;

    const idx: usize = @intCast(node_idx);
    const node = &ctx.result.nodes[idx];
    const node_type: NodeType = @enumFromInt(node.type);

    switch (node_type) {
        .root, .group => {
            try renderChildren(ctx, node.first_child);
        },
        .text, .delimiter, .operator_name => {
            const text = nodeText(ctx, node_idx);
            if (text.len > 0) {
                try emitText(ctx, text, 0);
            }
        },
        .space => {
            const text = nodeText(ctx, node_idx);
            if (text.len > 0) {
                try emitText(ctx, text, 0);
            } else {
                // Default thin space
                ctx.cursor_x += ctx.font_size * 0.25;
            }
        },
        .superscript => {
            const saved_size = ctx.font_size;
            const saved_y = ctx.baseline_y;
            ctx.font_size = saved_size * 0.7;
            ctx.baseline_y = saved_y - saved_size * 0.35;
            try renderChildren(ctx, node.first_child);
            ctx.font_size = saved_size;
            ctx.baseline_y = saved_y;
        },
        .subscript => {
            const saved_size = ctx.font_size;
            const saved_y = ctx.baseline_y;
            ctx.font_size = saved_size * 0.7;
            ctx.baseline_y = saved_y + saved_size * 0.25;
            try renderChildren(ctx, node.first_child);
            ctx.font_size = saved_size;
            ctx.baseline_y = saved_y;
        },
        .fraction => {
            // Render fraction: numerator over denominator with a line between
            // Save cursor position
            const frac_x = ctx.cursor_x;
            const saved_y = ctx.baseline_y;
            const saved_size = ctx.font_size;
            const frac_font_size = saved_size * 0.8;

            // Measure numerator width — use measuring=true to avoid spurious text_runs.
            var num_ctx = ctx.*;
            num_ctx.font_size = frac_font_size;
            num_ctx.cursor_x = 0;
            num_ctx.max_x = 0;
            num_ctx.measuring = true;
            const first_child = node.first_child;
            if (first_child >= 0) {
                num_ctx.baseline_y = saved_y - saved_size * 0.5;
                try renderNode(&num_ctx, first_child);
            }
            const num_width = num_ctx.max_x;

            // Get second child (denominator)
            var second_child: c_int = -1;
            if (first_child >= 0) {
                second_child = ctx.result.nodes[@as(usize, @intCast(first_child))].next_sibling;
            }

            // Measure denominator width — use measuring=true to avoid spurious text_runs.
            var den_ctx = ctx.*;
            den_ctx.font_size = frac_font_size;
            den_ctx.cursor_x = 0;
            den_ctx.max_x = 0;
            den_ctx.measuring = true;
            if (second_child >= 0) {
                den_ctx.baseline_y = saved_y + saved_size * 0.3;
                try renderNode(&den_ctx, second_child);
            }
            const den_width = den_ctx.max_x;

            // Use the wider of numerator/denominator
            const frac_width = @max(num_width, den_width) + saved_size * 0.2;
            const num_offset = (frac_width - num_width) / 2.0;
            const den_offset = (frac_width - den_width) / 2.0;

            // Now actually render at correct positions
            // Numerator (above the fraction line)
            ctx.font_size = frac_font_size;
            ctx.cursor_x = frac_x + num_offset;
            ctx.baseline_y = saved_y - saved_size * 0.5;
            if (first_child >= 0) {
                try renderNode(ctx, first_child);
            }

            // Fraction line — rendered as a thin "─" text run (skip in measuring mode).
            if (!ctx.measuring) {
                const line_text = "\xe2\x94\x80"; // ─ (BOX DRAWINGS LIGHT HORIZONTAL)
                const line_y = saved_y - saved_size * 0.1;
                try ctx.layout_node.text_runs.append(.{
                    .text = line_text,
                    .style = .{
                        .font_size = saved_size * 0.5,
                        .color = ctx.color,
                        .is_math = true,
                    },
                    .rect = .{
                        .x = frac_x,
                        .y = line_y,
                        .width = frac_width,
                        .height = 1,
                    },
                });
            }

            // Denominator (below the fraction line)
            ctx.cursor_x = frac_x + den_offset;
            ctx.baseline_y = saved_y + saved_size * 0.3;
            if (second_child >= 0) {
                try renderNode(ctx, second_child);
            }

            // Restore and advance cursor
            ctx.font_size = saved_size;
            ctx.baseline_y = saved_y;
            ctx.cursor_x = frac_x + frac_width;
            ctx.max_x = @max(ctx.max_x, ctx.cursor_x);
        },
        .sqrt => {
            // Render √ symbol followed by child content
            const sqrt_sym = "\xe2\x88\x9a"; // √
            try emitText(ctx, sqrt_sym, 0);
            // Render the radicand
            try renderChildren(ctx, node.first_child);
        },
        .accent => {
            // Render the base content, then the accent above it
            try renderChildren(ctx, node.first_child);
            // The accent character is in the node text — we skip rendering it
            // as combining characters since raylib doesn't handle them well.
            // Instead the base content is sufficient for visual correctness.
        },
        .matrix => {
            // Render matrix as a grid of cells
            try renderMatrix(ctx, node_idx);
        },
        .matrix_row, .matrix_cell => {
            // These are handled by renderMatrix
            try renderChildren(ctx, node.first_child);
        },
        _ => {
            // Unknown node type — render children as best-effort fallback
            std.log.debug("math_renderer: unknown node type {d}, rendering children", .{node.type});
            try renderChildren(ctx, node.first_child);
        },
    }
}

/// Render all children of a node (following sibling links).
fn renderChildren(ctx: *RenderContext, first_child: c_int) error{OutOfMemory}!void {
    var child = first_child;
    while (child >= 0 and child < ctx.result.count) {
        try renderNode(ctx, child);
        child = ctx.result.nodes[@as(usize, @intCast(child))].next_sibling;
    }
}

/// Count rows and max columns in a matrix node.
fn countMatrixDims(ctx: *const RenderContext, matrix_idx: c_int) struct { rows: usize, cols: usize } {
    var rows: usize = 0;
    var max_cols: usize = 0;
    var row_child = ctx.result.nodes[@as(usize, @intCast(matrix_idx))].first_child;
    while (row_child >= 0 and row_child < ctx.result.count) {
        const ri: usize = @intCast(row_child);
        rows += 1;
        var cols: usize = 0;
        var cell_child = ctx.result.nodes[ri].first_child;
        while (cell_child >= 0 and cell_child < ctx.result.count) {
            cols += 1;
            cell_child = ctx.result.nodes[@as(usize, @intCast(cell_child))].next_sibling;
        }
        max_cols = @max(max_cols, cols);
        row_child = ctx.result.nodes[ri].next_sibling;
    }
    return .{ .rows = rows, .cols = max_cols };
}

/// Render a matrix by laying out cells in a grid.
fn renderMatrix(ctx: *RenderContext, matrix_idx: c_int) error{OutOfMemory}!void {
    const dims = countMatrixDims(ctx, matrix_idx);
    if (dims.rows == 0 or dims.cols == 0) return;

    const cell_padding = ctx.font_size * 0.5;
    const row_height = ctx.font_size * 1.4;
    const start_x = ctx.cursor_x;
    const start_y = ctx.baseline_y;

    var row_child = ctx.result.nodes[@as(usize, @intCast(matrix_idx))].first_child;
    var row_num: usize = 0;
    while (row_child >= 0 and row_child < ctx.result.count) {
        const ri: usize = @intCast(row_child);
        var cell_child = ctx.result.nodes[ri].first_child;
        var col_num: usize = 0;
        while (cell_child >= 0 and cell_child < ctx.result.count) {
            ctx.cursor_x = start_x + @as(f32, @floatFromInt(col_num)) * (ctx.font_size * 2.5 + cell_padding);
            ctx.baseline_y = start_y + @as(f32, @floatFromInt(row_num)) * row_height;

            const ci: usize = @intCast(cell_child);
            try renderChildren(ctx, ctx.result.nodes[ci].first_child);

            col_num += 1;
            cell_child = ctx.result.nodes[ci].next_sibling;
        }
        row_num += 1;
        row_child = ctx.result.nodes[ri].next_sibling;
    }

    // Update cursor to after the matrix
    ctx.cursor_x = start_x + @as(f32, @floatFromInt(dims.cols)) * (ctx.font_size * 2.5 + cell_padding);
    ctx.baseline_y = start_y;
    const bottom = start_y + @as(f32, @floatFromInt(dims.rows)) * row_height;
    ctx.max_x = @max(ctx.max_x, ctx.cursor_x);
    ctx.max_y = @max(ctx.max_y, bottom);
}

/// Lay out a block math expression (from `$$…$$` or ` ```math ` code blocks).
/// Produces a single LayoutNode with text runs for the rendered math.
pub fn layoutMathBlock(
    allocator: Allocator,
    latex_source: ?[]const u8,
    theme: *const Theme,
    fonts: *const Fonts,
    content_x: f32,
    content_width: f32,
    cursor_y: *f32,
    tree: *layout_types.LayoutTree,
) !void {
    const source = latex_source orelse return;
    if (source.len == 0) return;

    // Parse LaTeX via C library
    const result = c.latex_render_parse(source.ptr, @intCast(source.len));
    if (result == null) return;
    defer c.latex_render_free(result);

    // Arena-dupe the LaTeX source so the node data outlives this function.
    const arena = tree.arena.allocator();
    const latex_copy = try arena.dupe(u8, source);

    // Compute a slightly lighter background for the math block.
    const bg_color = rl.Color{
        .r = @intCast(@min(@as(u16, 255), @as(u16, theme.code_background.r) + 10)),
        .g = @intCast(@min(@as(u16, 255), @as(u16, theme.code_background.g) + 10)),
        .b = @intCast(@min(@as(u16, 255), @as(u16, theme.code_background.b) + 10)),
        .a = theme.code_background.a,
    };

    const font_size = theme.body_font_size * 1.2; // Slightly larger for display math
    const padding = theme.code_block_padding;
    const base_y = cursor_y.* + padding;

    // Create a math_block layout node; text_runs are pre-populated via FFI below.
    var layout_node = layout_types.LayoutNode.init(allocator, .{ .math_block = .{
        .latex = latex_copy,
        .font_size = font_size,
        .color = theme.text,
        .bg_color = bg_color,
    } });
    errdefer layout_node.deinit();

    // Render the math expression into positioned text runs
    var ctx = RenderContext{
        .arena = arena,
        .fonts = fonts,
        .theme = theme,
        .layout_node = &layout_node,
        .cursor_x = content_x + padding,
        .baseline_y = base_y + font_size,
        .font_size = font_size,
        .color = theme.text,
        .result = result,
        .max_x = content_x + padding,
        .max_y = base_y + font_size,
    };

    // Render the root node
    if (result.*.count > 0 and result.*.nodes != null) {
        try renderNode(&ctx, 0);
    }

    // Calculate total height
    const content_height = ctx.max_y - base_y + padding;
    const total_height = content_height + padding;

    // Center the math content horizontally
    const math_width = ctx.max_x - (content_x + padding);
    const center_offset = (content_width - math_width) / 2.0 - padding;
    if (center_offset > 0) {
        for (layout_node.text_runs.items) |*run| {
            run.rect.x += center_offset;
        }
    }

    layout_node.rect = .{
        .x = content_x,
        .y = cursor_y.*,
        .width = content_width,
        .height = total_height,
    };

    try tree.nodes.append(layout_node);
    cursor_y.* += total_height + theme.paragraph_spacing;
}

/// Render an inline math expression and return the rendered width.
/// Appends text runs to the provided layout node at the given cursor position.
pub fn renderInlineMath(
    latex_source: []const u8,
    fonts: *const Fonts,
    theme: *const Theme,
    layout_node: *layout_types.LayoutNode,
    tree: *layout_types.LayoutTree,
    cursor_x: *f32,
    baseline_y: f32,
    font_size: f32,
    color: rl.Color,
) !f32 {
    if (latex_source.len == 0) return 0;

    // Parse LaTeX via C library
    const result = c.latex_render_parse(latex_source.ptr, @intCast(latex_source.len));
    if (result == null) return 0;
    defer c.latex_render_free(result);

    const start_x = cursor_x.*;

    var ctx = RenderContext{
        .arena = tree.arena.allocator(),
        .fonts = fonts,
        .theme = theme,
        .layout_node = layout_node,
        .cursor_x = cursor_x.*,
        .baseline_y = baseline_y,
        .font_size = font_size,
        .color = color,
        .result = result,
        .max_x = cursor_x.*,
        .max_y = baseline_y + font_size,
    };

    if (result.*.count > 0 and result.*.nodes != null) {
        try renderNode(&ctx, 0);
    }

    cursor_x.* = ctx.max_x;
    return ctx.max_x - start_x;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "latex_render_parse returns valid result for simple expression" {
    const result = c.latex_render_parse("x^2", 3);
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    // Should have at least a root node
    try testing.expect(result.*.count > 0);
    // Root node type should be LATEX_NODE_ROOT (0)
    try testing.expectEqual(@as(c_int, c.LATEX_NODE_ROOT), result.*.nodes[0].type);
}

test "latex_render_parse handles Greek letters" {
    const result = c.latex_render_parse("\\alpha + \\beta", 14);
    try testing.expect(result != null);
    defer c.latex_render_free(result);
    try testing.expect(result.*.count > 1);
}

test "latex_render_parse handles fractions" {
    const result = c.latex_render_parse("\\frac{a}{b}", 11);
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    // Should contain a fraction node
    var has_fraction = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        if (result.*.nodes[i].type == c.LATEX_NODE_FRACTION) {
            has_fraction = true;
            break;
        }
    }
    try testing.expect(has_fraction);
}

test "latex_render_parse handles superscripts" {
    const result = c.latex_render_parse("x^{2}", 5);
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    var has_superscript = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        if (result.*.nodes[i].type == c.LATEX_NODE_SUPERSCRIPT) {
            has_superscript = true;
            break;
        }
    }
    try testing.expect(has_superscript);
}

test "latex_render_parse handles subscripts" {
    const result = c.latex_render_parse("x_{n}", 5);
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    var has_subscript = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        if (result.*.nodes[i].type == c.LATEX_NODE_SUBSCRIPT) {
            has_subscript = true;
            break;
        }
    }
    try testing.expect(has_subscript);
}

test "latex_render_parse handles sqrt" {
    const result = c.latex_render_parse("\\sqrt{x}", 8);
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    var has_sqrt = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        if (result.*.nodes[i].type == c.LATEX_NODE_SQRT) {
            has_sqrt = true;
            break;
        }
    }
    try testing.expect(has_sqrt);
}

test "latex_render_parse handles matrix" {
    const input = "\\begin{array}{cc}a & b\\\\c & d\\end{array}";
    const result = c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    var has_matrix = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        if (result.*.nodes[i].type == c.LATEX_NODE_MATRIX) {
            has_matrix = true;
            break;
        }
    }
    try testing.expect(has_matrix);
}

test "latex_render_parse handles empty input" {
    const result = c.latex_render_parse("", 0);
    try testing.expect(result != null);
    defer c.latex_render_free(result);
    // Should have at least a root node
    try testing.expect(result.*.count >= 1);
}

test "latex_render_parse handles null input" {
    const result = c.latex_render_parse(null, 0);
    try testing.expect(result != null);
    defer c.latex_render_free(result);
}

test "latex_render_parse handles complex expression" {
    const input = "\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}";
    const result = c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer c.latex_render_free(result);
    // Should produce a non-trivial tree
    try testing.expect(result.*.count > 5);
}

test "latex_render_free handles null" {
    // Should not crash
    c.latex_render_free(null);
}

test "latex_render_parse handles sum with limits" {
    const input = "\\sum_{n=1}^{\\infty} \\frac{1}{n^2}";
    const result = c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer c.latex_render_free(result);
    try testing.expect(result.*.count > 3);
}

test "latex_render_parse produces text nodes with correct content" {
    const result = c.latex_render_parse("\\alpha", 6);
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    // Find the text node containing alpha
    var found_alpha = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        const node = &result.*.nodes[i];
        if (node.type == c.LATEX_NODE_TEXT and node.text != null and node.text_len > 0) {
            const tlen: usize = @intCast(node.text_len);
            const text: []const u8 = node.text[0..tlen];
            // α is U+03B1 = CE B1 in UTF-8
            if (std.mem.eql(u8, text, "\xce\xb1")) {
                found_alpha = true;
                break;
            }
        }
    }
    try testing.expect(found_alpha);
}

// --- Tests for sample formulas from docs/github-markdown-samples.md ---

test "latex_render_parse inline math: E=mc^2 from samples" {
    // docs/github-markdown-samples.md line 409: $E = mc^2$
    const input = "E = mc^2";
    const result = c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    // Should produce a tree with a superscript node for ^2
    var has_superscript = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        if (result.*.nodes[i].type == c.LATEX_NODE_SUPERSCRIPT) {
            has_superscript = true;
            break;
        }
    }
    try testing.expect(has_superscript);
}

test "latex_render_parse inline math: quadratic formula from samples" {
    // docs/github-markdown-samples.md line 407:
    // $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$
    const input = "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}";
    const result = c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    // Should contain fraction, sqrt, and superscript nodes
    var has_fraction = false;
    var has_sqrt = false;
    var has_superscript = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        const node_type = result.*.nodes[i].type;
        if (node_type == c.LATEX_NODE_FRACTION) has_fraction = true;
        if (node_type == c.LATEX_NODE_SQRT) has_sqrt = true;
        if (node_type == c.LATEX_NODE_SUPERSCRIPT) has_superscript = true;
    }
    try testing.expect(has_fraction);
    try testing.expect(has_sqrt);
    try testing.expect(has_superscript);
}

test "latex_render_parse block math: integral formula from samples" {
    // docs/github-markdown-samples.md lines 413-415:
    // $$\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$
    const input = "\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}";
    const result = c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    // Should contain fraction, sqrt, superscript, and subscript nodes
    var has_fraction = false;
    var has_sqrt = false;
    var has_superscript = false;
    var has_subscript = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        const node_type = result.*.nodes[i].type;
        if (node_type == c.LATEX_NODE_FRACTION) has_fraction = true;
        if (node_type == c.LATEX_NODE_SQRT) has_sqrt = true;
        if (node_type == c.LATEX_NODE_SUPERSCRIPT) has_superscript = true;
        if (node_type == c.LATEX_NODE_SUBSCRIPT) has_subscript = true;
    }
    try testing.expect(has_fraction);
    try testing.expect(has_sqrt);
    try testing.expect(has_superscript);
    try testing.expect(has_subscript);
    // Should produce a rich tree for this complex expression
    try testing.expect(result.*.count > 8);
}

test "latex_render_parse block math: sum series from samples" {
    // docs/github-markdown-samples.md lines 417-419:
    // $$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$
    const input = "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}";
    const result = c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    // Should contain fractions (2 of them), superscript, subscript
    var fraction_count: usize = 0;
    var has_superscript = false;
    var has_subscript = false;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        const node_type = result.*.nodes[i].type;
        if (node_type == c.LATEX_NODE_FRACTION) fraction_count += 1;
        if (node_type == c.LATEX_NODE_SUPERSCRIPT) has_superscript = true;
        if (node_type == c.LATEX_NODE_SUBSCRIPT) has_subscript = true;
    }
    try testing.expect(fraction_count >= 2); // \frac{1}{n^2} and \frac{\pi^2}{6}
    try testing.expect(has_superscript);
    try testing.expect(has_subscript);
}

test "latex_render_parse block math: matrix from samples" {
    // docs/github-markdown-samples.md lines 423-438 (code block with math language):
    // Matrix multiplication with \begin{array}...\end{array}
    const input = "\\left(\\begin{array}{cc}a & b\\\\c & d\\end{array}\\right)\\times\\left(\\begin{array}{c}x\\\\y\\end{array}\\right)=\\left(\\begin{array}{c}ax + by\\\\cx + dy\\end{array}\\right)";
    const result = c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer c.latex_render_free(result);

    // Should contain matrix nodes and delimiter nodes
    var matrix_count: usize = 0;
    var delimiter_count: usize = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        const node_type = result.*.nodes[i].type;
        if (node_type == c.LATEX_NODE_MATRIX) matrix_count += 1;
        if (node_type == c.LATEX_NODE_DELIMITER) delimiter_count += 1;
    }
    try testing.expect(matrix_count >= 3); // Three matrices in the expression
    try testing.expect(delimiter_count >= 2); // \left( \right) delimiters
}
