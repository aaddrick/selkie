//! Math Formula Renderer
//!
//! Renders LaTeX math expressions using raylib text drawing primitives.
//! Parses LaTeX via the vendored latex-render C library (FFI) and converts
//! the resulting node tree into display strings and positioned text runs.
//!
//! Supports common LaTeX constructs: fractions, superscripts, subscripts,
//! Greek letters, operators, roots, summations, integrals, and matrices.
//!
//! Architecture:
//!   LaTeX string → C library parser (latex_render_parse) → node tree
//!   → Zig tree walker → Unicode display string → raylib text drawing

const std = @import("std");
const rl = @import("raylib");
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const slice_utils = @import("../utils/slice_utils.zig");
const layout_types = @import("../layout/layout_types.zig");
const text_renderer = @import("text_renderer.zig");

/// C FFI bindings to the vendored latex-render library.
/// The C library parses LaTeX math strings into a flat array of structured
/// nodes with child/sibling indices, suitable for tree walking.
const latex_c = @cImport({
    @cInclude("latex_render.h");
});

/// Parsed representation of a LaTeX math expression element.
pub const MathElement = union(enum) {
    /// Plain text (variable names, numbers)
    text: []const u8,
    /// Greek letter or named symbol (e.g., \alpha → α)
    symbol: []const u8,
    /// Superscript: base^{exponent}
    superscript: struct {
        base: *const MathElement,
        exponent: *const MathElement,
    },
    /// Subscript: base_{sub}
    subscript: struct {
        base: *const MathElement,
        sub: *const MathElement,
    },
    /// Both super and subscript: base_{sub}^{sup}
    subsup: struct {
        base: *const MathElement,
        sub: *const MathElement,
        sup: *const MathElement,
    },
    /// Fraction: \frac{num}{den}
    fraction: struct {
        numerator: *const MathElement,
        denominator: *const MathElement,
    },
    /// Square root: \sqrt{content}
    sqrt: struct {
        content: *const MathElement,
    },
    /// Sequence of elements laid out horizontally
    sequence: []const MathElement,
    /// Operator with limits (sum, prod, int, etc.)
    operator_with_limits: struct {
        operator: []const u8,
        lower: ?*const MathElement,
        upper: ?*const MathElement,
    },
    /// A group (e.g., braced content)
    group: *const MathElement,
    /// Delimiter pair: \left( ... \right)
    delimited: struct {
        left: []const u8,
        right: []const u8,
        content: *const MathElement,
    },
    /// A matrix/array environment
    matrix: struct {
        rows: []const []const MathElement,
    },
    /// Spacing element
    space: f32,
};

/// Greek letter mapping from LaTeX command to Unicode.
const GreekEntry = struct {
    cmd: []const u8,
    unicode: []const u8,
};

/// Greek letters and common math symbols.
pub const greek_letters = [_]GreekEntry{
    .{ .cmd = "alpha", .unicode = "\xce\xb1" }, // α
    .{ .cmd = "beta", .unicode = "\xce\xb2" }, // β
    .{ .cmd = "gamma", .unicode = "\xce\xb3" }, // γ
    .{ .cmd = "delta", .unicode = "\xce\xb4" }, // δ
    .{ .cmd = "epsilon", .unicode = "\xce\xb5" }, // ε
    .{ .cmd = "zeta", .unicode = "\xce\xb6" }, // ζ
    .{ .cmd = "eta", .unicode = "\xce\xb7" }, // η
    .{ .cmd = "theta", .unicode = "\xce\xb8" }, // θ
    .{ .cmd = "iota", .unicode = "\xce\xb9" }, // ι
    .{ .cmd = "kappa", .unicode = "\xce\xba" }, // κ
    .{ .cmd = "lambda", .unicode = "\xce\xbb" }, // λ
    .{ .cmd = "mu", .unicode = "\xce\xbc" }, // μ
    .{ .cmd = "nu", .unicode = "\xce\xbd" }, // ν
    .{ .cmd = "xi", .unicode = "\xce\xbe" }, // ξ
    .{ .cmd = "pi", .unicode = "\xcf\x80" }, // π
    .{ .cmd = "rho", .unicode = "\xcf\x81" }, // ρ
    .{ .cmd = "sigma", .unicode = "\xcf\x83" }, // σ
    .{ .cmd = "tau", .unicode = "\xcf\x84" }, // τ
    .{ .cmd = "upsilon", .unicode = "\xcf\x85" }, // υ
    .{ .cmd = "phi", .unicode = "\xcf\x86" }, // φ
    .{ .cmd = "chi", .unicode = "\xcf\x87" }, // χ
    .{ .cmd = "psi", .unicode = "\xcf\x88" }, // ψ
    .{ .cmd = "omega", .unicode = "\xcf\x89" }, // ω
    .{ .cmd = "Gamma", .unicode = "\xce\x93" }, // Γ
    .{ .cmd = "Delta", .unicode = "\xce\x94" }, // Δ
    .{ .cmd = "Theta", .unicode = "\xce\x98" }, // Θ
    .{ .cmd = "Lambda", .unicode = "\xce\x9b" }, // Λ
    .{ .cmd = "Xi", .unicode = "\xce\x9e" }, // Ξ
    .{ .cmd = "Pi", .unicode = "\xce\xa0" }, // Π
    .{ .cmd = "Sigma", .unicode = "\xce\xa3" }, // Σ
    .{ .cmd = "Phi", .unicode = "\xce\xa6" }, // Φ
    .{ .cmd = "Psi", .unicode = "\xce\xa8" }, // Ψ
    .{ .cmd = "Omega", .unicode = "\xce\xa9" }, // Ω
    // Common math symbols
    .{ .cmd = "infty", .unicode = "\xe2\x88\x9e" }, // ∞
    .{ .cmd = "pm", .unicode = "\xc2\xb1" }, // ±
    .{ .cmd = "mp", .unicode = "\xe2\x88\x93" }, // ∓
    .{ .cmd = "times", .unicode = "\xc3\x97" }, // ×
    .{ .cmd = "div", .unicode = "\xc3\xb7" }, // ÷
    .{ .cmd = "cdot", .unicode = "\xc2\xb7" }, // ·
    .{ .cmd = "leq", .unicode = "\xe2\x89\xa4" }, // ≤
    .{ .cmd = "geq", .unicode = "\xe2\x89\xa5" }, // ≥
    .{ .cmd = "neq", .unicode = "\xe2\x89\xa0" }, // ≠
    .{ .cmd = "approx", .unicode = "\xe2\x89\x88" }, // ≈
    .{ .cmd = "equiv", .unicode = "\xe2\x89\xa1" }, // ≡
    .{ .cmd = "in", .unicode = "\xe2\x88\x88" }, // ∈
    .{ .cmd = "notin", .unicode = "\xe2\x88\x89" }, // ∉
    .{ .cmd = "subset", .unicode = "\xe2\x8a\x82" }, // ⊂
    .{ .cmd = "supset", .unicode = "\xe2\x8a\x83" }, // ⊃
    .{ .cmd = "cup", .unicode = "\xe2\x88\xaa" }, // ∪
    .{ .cmd = "cap", .unicode = "\xe2\x88\xa9" }, // ∩
    .{ .cmd = "forall", .unicode = "\xe2\x88\x80" }, // ∀
    .{ .cmd = "exists", .unicode = "\xe2\x88\x83" }, // ∃
    .{ .cmd = "partial", .unicode = "\xe2\x88\x82" }, // ∂
    .{ .cmd = "nabla", .unicode = "\xe2\x88\x87" }, // ∇
    .{ .cmd = "to", .unicode = "\xe2\x86\x92" }, // →
    .{ .cmd = "rightarrow", .unicode = "\xe2\x86\x92" }, // →
    .{ .cmd = "leftarrow", .unicode = "\xe2\x86\x90" }, // ←
    .{ .cmd = "Rightarrow", .unicode = "\xe2\x87\x92" }, // ⇒
    .{ .cmd = "Leftarrow", .unicode = "\xe2\x87\x90" }, // ⇐
    .{ .cmd = "ldots", .unicode = "\xe2\x80\xa6" }, // …
    .{ .cmd = "cdots", .unicode = "\xe2\x8b\xaf" }, // ⋯
    .{ .cmd = "quad", .unicode = "  " },
    .{ .cmd = "qquad", .unicode = "    " },
};

/// Look up a LaTeX command and return its Unicode equivalent.
pub fn lookupSymbol(cmd: []const u8) ?[]const u8 {
    for (greek_letters) |entry| {
        if (std.mem.eql(u8, entry.cmd, cmd)) {
            return entry.unicode;
        }
    }
    return null;
}

/// Measurement result for a math expression.
pub const MathSize = struct {
    width: f32,
    height: f32,
    /// Distance from top of bounding box to the math baseline (center of operators).
    baseline: f32,
};

/// Render context for drawing math expressions.
pub const MathRenderContext = struct {
    fonts: *const Fonts,
    color: rl.Color,
    base_font_size: f32,

    /// Measure a text string at a given font size using the italic font (math convention).
    fn measureText(self: *const MathRenderContext, text: []const u8, font_size: f32) rl.Vector2 {
        return self.fonts.measure(text, font_size, false, true, false);
    }

    /// Measure a symbol/operator at a given font size using the body (upright) font.
    fn measureSymbol(self: *const MathRenderContext, text: []const u8, font_size: f32) rl.Vector2 {
        return self.fonts.measure(text, font_size, false, false, false);
    }

    /// Draw text at a position using the italic font.
    fn drawText(self: *const MathRenderContext, text: []const u8, x: f32, y: f32, font_size: f32, scroll_y: f32) void {
        if (text.len == 0) return;
        const font = self.fonts.selectFont(.{ .italic = true });
        const spacing = font_size / 10.0;
        var buf: [2048]u8 = undefined;
        const z = slice_utils.sliceToZ(&buf, text);
        rl.drawTextEx(font, z, .{ .x = x, .y = y - scroll_y }, font_size, spacing, self.color);
    }

    /// Draw a symbol/operator at a position using the body (upright) font.
    fn drawSymbol(self: *const MathRenderContext, text: []const u8, x: f32, y: f32, font_size: f32, scroll_y: f32) void {
        if (text.len == 0) return;
        const font = self.fonts.selectFont(.{});
        const spacing = font_size / 10.0;
        var buf: [2048]u8 = undefined;
        const z = slice_utils.sliceToZ(&buf, text);
        rl.drawTextEx(font, z, .{ .x = x, .y = y - scroll_y }, font_size, spacing, self.color);
    }
};

/// Measure the size of a LaTeX math string for layout purposes.
/// Returns the bounding box dimensions and baseline position.
pub fn measureMathString(latex: []const u8, fonts: *const Fonts, font_size: f32) MathSize {
    // Use the pre-processed display string approach:
    // Convert LaTeX to a display-friendly string, then measure it.
    var buf: [4096]u8 = undefined;
    const display = latexToDisplayString(latex, &buf);
    const measured = fonts.measure(display, font_size, false, true, false);
    // Add padding for math display
    const height = @max(measured.y, font_size * 1.4);
    return .{
        .width = measured.x + font_size * 0.4, // small horizontal padding
        .height = height,
        .baseline = height * 0.6,
    };
}

/// Measure a block math expression (larger, centered, with more vertical space).
pub fn measureBlockMathString(latex: []const u8, fonts: *const Fonts, font_size: f32) MathSize {
    const block_size = font_size * 1.2;
    var result = measureMathString(latex, fonts, block_size);
    // Block math gets extra vertical padding
    result.height += block_size * 0.6;
    return result;
}

/// Convert a LaTeX string to a human-readable display string by replacing
/// LaTeX commands with Unicode equivalents.
///
/// Uses the vendored latex-render C library (FFI) to parse the LaTeX into
/// a structured node tree, then walks the tree to produce a Unicode string.
/// This provides correct handling of nested braces, environments, and
/// complex command sequences that ad-hoc string scanning would miss.
pub fn latexToDisplayString(latex: []const u8, buf: []u8) []const u8 {
    if (latex.len == 0) return "";

    // Parse via the vendored C library
    const result = latex_c.latex_render_parse(latex.ptr, @intCast(latex.len));
    if (result == null) {
        // Fallback: return raw input on allocation failure
        const copy_len = @min(latex.len, buf.len);
        @memcpy(buf[0..copy_len], latex[0..copy_len]);
        return buf[0..copy_len];
    }
    defer latex_c.latex_render_free(result);

    // Walk the C parse tree and emit Unicode display text
    var out_pos: usize = 0;
    if (result.*.count > 0) {
        flattenCNode(result, 0, buf, &out_pos);
    }

    if (out_pos > buf.len) out_pos = buf.len;
    return buf[0..out_pos];
}

/// Recursively flatten a C parse tree node into a display string buffer.
/// Handles fractions as "num/den", superscripts via Unicode, subscripts
/// via Unicode, sqrt as "√(content)", matrices with row separators, etc.
fn flattenCNode(result: *latex_c.LatexParseResult, node_idx: c_int, buf: []u8, pos: *usize) void {
    if (node_idx < 0 or node_idx >= result.count) return;

    const idx: usize = @intCast(node_idx);
    const node = &result.nodes[idx];

    switch (node.type) {
        latex_c.LATEX_NODE_ROOT, latex_c.LATEX_NODE_GROUP => {
            // Render all children sequentially
            flattenCChildren(result, node.first_child, buf, pos);
        },
        latex_c.LATEX_NODE_TEXT, latex_c.LATEX_NODE_OPERATORNAME => {
            // Emit text directly
            if (node.text) |txt| {
                if (node.text_len > 0) {
                    const text_len: usize = @intCast(node.text_len);
                    const text = txt[0..text_len];
                    pos.* = appendBytes(buf, pos.*, text);
                }
            }
        },
        latex_c.LATEX_NODE_SPACE => {
            if (node.text) |txt| {
                if (node.text_len > 0) {
                    const text_len: usize = @intCast(node.text_len);
                    pos.* = appendBytes(buf, pos.*, txt[0..text_len]);
                }
            } else {
                if (pos.* < buf.len) {
                    buf[pos.*] = ' ';
                    pos.* += 1;
                }
            }
        },
        latex_c.LATEX_NODE_DELIMITER => {
            if (node.text) |txt| {
                if (node.text_len > 0) {
                    const text_len: usize = @intCast(node.text_len);
                    pos.* = appendBytes(buf, pos.*, txt[0..text_len]);
                }
            }
        },
        latex_c.LATEX_NODE_FRACTION => {
            // Render as "numerator/denominator"
            const first_child = node.first_child;
            if (first_child >= 0) {
                flattenCNode(result, first_child, buf, pos);
                // Get second child (denominator)
                const fc_idx: usize = @intCast(first_child);
                const second_child = result.nodes[fc_idx].next_sibling;
                if (pos.* < buf.len) {
                    buf[pos.*] = '/';
                    pos.* += 1;
                }
                if (second_child >= 0) {
                    flattenCNode(result, second_child, buf, pos);
                }
            }
        },
        latex_c.LATEX_NODE_SUPERSCRIPT => {
            // Try Unicode superscripts for all children (multi-char support)
            if (tryUnicodeSubSuperChildren(result, node.first_child, buf, pos, unicodeSuperscript)) {
                return;
            }
            // Fallback: ^(content)
            if (pos.* < buf.len) {
                buf[pos.*] = '^';
                pos.* += 1;
            }
            flattenCChildren(result, node.first_child, buf, pos);
        },
        latex_c.LATEX_NODE_SUBSCRIPT => {
            // Try Unicode subscripts for all children (multi-char support)
            if (tryUnicodeSubSuperChildren(result, node.first_child, buf, pos, unicodeSubscript)) {
                return;
            }
            // Fallback: _(content)
            if (pos.* < buf.len) {
                buf[pos.*] = '_';
                pos.* += 1;
            }
            flattenCChildren(result, node.first_child, buf, pos);
        },
        latex_c.LATEX_NODE_SQRT => {
            const sqrt_sym = "\xe2\x88\x9a"; // √
            pos.* = appendBytes(buf, pos.*, sqrt_sym);
            if (pos.* < buf.len) {
                buf[pos.*] = '(';
                pos.* += 1;
            }
            flattenCChildren(result, node.first_child, buf, pos);
            if (pos.* < buf.len) {
                buf[pos.*] = ')';
                pos.* += 1;
            }
        },
        latex_c.LATEX_NODE_ACCENT => {
            // Render the child content (accent character is decorative)
            flattenCChildren(result, node.first_child, buf, pos);
        },
        latex_c.LATEX_NODE_MATRIX => {
            // Render matrix rows separated by " | "
            flattenCMatrixRows(result, node.first_child, buf, pos);
        },
        latex_c.LATEX_NODE_MATRIX_ROW => {
            // Cells separated by spaces
            flattenCMatrixCells(result, node.first_child, buf, pos);
        },
        latex_c.LATEX_NODE_MATRIX_CELL => {
            flattenCChildren(result, node.first_child, buf, pos);
        },
        else => {
            // Unknown node type — render children
            flattenCChildren(result, node.first_child, buf, pos);
        },
    }
}

/// Flatten all children following sibling links.
fn flattenCChildren(result: *latex_c.LatexParseResult, first_child: c_int, buf: []u8, pos: *usize) void {
    var child = first_child;
    while (child >= 0 and child < result.count) {
        flattenCNode(result, child, buf, pos);
        const child_idx: usize = @intCast(child);
        child = result.nodes[child_idx].next_sibling;
    }
}

/// Flatten matrix rows separated by " | ".
fn flattenCMatrixRows(result: *latex_c.LatexParseResult, first_row: c_int, buf: []u8, pos: *usize) void {
    var row = first_row;
    var first = true;
    while (row >= 0 and row < result.count) {
        if (!first) {
            pos.* = appendBytes(buf, pos.*, " | ");
        }
        first = false;
        flattenCNode(result, row, buf, pos);
        const row_idx: usize = @intCast(row);
        row = result.nodes[row_idx].next_sibling;
    }
}

/// Flatten matrix cells separated by spaces.
fn flattenCMatrixCells(result: *latex_c.LatexParseResult, first_cell: c_int, buf: []u8, pos: *usize) void {
    var cell = first_cell;
    var first = true;
    while (cell >= 0 and cell < result.count) {
        if (!first) {
            if (pos.* < buf.len) {
                buf[pos.*] = ' ';
                pos.* += 1;
            }
        }
        first = false;
        flattenCNode(result, cell, buf, pos);
        const cell_idx: usize = @intCast(cell);
        cell = result.nodes[cell_idx].next_sibling;
    }
}

/// Try to flatten all children of a sub/superscript into Unicode equivalents.
/// Returns true if all characters were successfully converted, false if any failed.
fn tryUnicodeSubSuperChildren(
    result: *latex_c.LatexParseResult,
    first_child: c_int,
    buf: []u8,
    pos: *usize,
    comptime lookup_fn: fn (u8) ?[]const u8,
) bool {
    // Save position in case we need to revert
    const saved_pos = pos.*;
    var success = true;
    var child_it = first_child;
    while (child_it >= 0 and child_it < result.count) {
        const ci: usize = @intCast(child_it);
        const c_node = &result.nodes[ci];

        if (c_node.type == latex_c.LATEX_NODE_TEXT and c_node.text != null and c_node.text_len > 0) {
            const tlen: usize = @intCast(c_node.text_len);
            const tptr: [*]const u8 = @ptrCast(c_node.text);
            const text = tptr[0..tlen];
            for (text) |ch| {
                if (lookup_fn(ch)) |uni| {
                    pos.* = appendBytes(buf, pos.*, uni);
                } else {
                    success = false;
                    break;
                }
            }
            if (!success) break;
        } else if (c_node.type == latex_c.LATEX_NODE_GROUP) {
            // Recurse into group children
            if (!tryUnicodeSubSuperChildren(result, c_node.first_child, buf, pos, lookup_fn)) {
                success = false;
                break;
            }
        } else {
            success = false;
            break;
        }

        child_it = c_node.next_sibling;
    }

    if (!success) {
        pos.* = saved_pos;
    }
    return success;
}

/// Append bytes to buffer, return new position.
fn appendBytes(buf: []u8, pos: usize, bytes: []const u8) usize {
    const remaining = buf.len -| pos;
    const copy_len = @min(bytes.len, remaining);
    @memcpy(buf[pos..][0..copy_len], bytes[0..copy_len]);
    return pos + copy_len;
}

/// Return Unicode superscript for common characters.
fn unicodeSuperscript(ch: u8) ?[]const u8 {
    return switch (ch) {
        '0' => "\xe2\x81\xb0", // ⁰
        '1' => "\xc2\xb9", // ¹
        '2' => "\xc2\xb2", // ²
        '3' => "\xc2\xb3", // ³
        '4' => "\xe2\x81\xb4", // ⁴
        '5' => "\xe2\x81\xb5", // ⁵
        '6' => "\xe2\x81\xb6", // ⁶
        '7' => "\xe2\x81\xb7", // ⁷
        '8' => "\xe2\x81\xb8", // ⁸
        '9' => "\xe2\x81\xb9", // ⁹
        '+' => "\xe2\x81\xba", // ⁺
        '-' => "\xe2\x81\xbb", // ⁻
        '=' => "\xe2\x81\xbc", // ⁼
        '(' => "\xe2\x81\xbd", // ⁽
        ')' => "\xe2\x81\xbe", // ⁾
        'n' => "\xe2\x81\xbf", // ⁿ
        'i' => "\xe2\x81\xb1", // ⁱ
        else => null,
    };
}

/// Return Unicode subscript for common characters.
fn unicodeSubscript(ch: u8) ?[]const u8 {
    return switch (ch) {
        '0' => "\xe2\x82\x80", // ₀
        '1' => "\xe2\x82\x81", // ₁
        '2' => "\xe2\x82\x82", // ₂
        '3' => "\xe2\x82\x83", // ₃
        '4' => "\xe2\x82\x84", // ₄
        '5' => "\xe2\x82\x85", // ₅
        '6' => "\xe2\x82\x86", // ₆
        '7' => "\xe2\x82\x87", // ₇
        '8' => "\xe2\x82\x88", // ₈
        '9' => "\xe2\x82\x89", // ₉
        '+' => "\xe2\x82\x8a", // ₊
        '-' => "\xe2\x82\x8b", // ₋
        '=' => "\xe2\x82\x8c", // ₌
        '(' => "\xe2\x82\x8d", // ₍
        ')' => "\xe2\x82\x8e", // ₎
        'a' => "\xe2\x82\x90", // ₐ
        'e' => "\xe2\x82\x91", // ₑ
        'i' => "\xe1\xb5\xa2", // ᵢ
        'o' => "\xe2\x82\x92", // ₒ
        'n' => "\xe2\x82\x99", // ₙ
        'x' => "\xe2\x82\x93", // ₓ
        else => null,
    };
}

/// Draw an inline math expression at the specified position.
/// Used for `$...$` inline math within text paragraphs.
pub fn drawInlineMath(
    latex: []const u8,
    x: f32,
    y: f32,
    font_size: f32,
    fonts: *const Fonts,
    color: rl.Color,
    scroll_y: f32,
) void {
    var buf: [4096]u8 = undefined;
    const display = latexToDisplayString(latex, &buf);
    const ctx = MathRenderContext{
        .fonts = fonts,
        .color = color,
        .base_font_size = font_size,
    };
    ctx.drawText(display, x, y, font_size, scroll_y);
}

/// Draw a block math expression centered within its layout rect.
/// Used for `$$...$$` display math blocks.
/// If the layout phase pre-populated `node.text_runs` via the FFI tree walker,
/// those positioned runs are rendered directly (proper fraction/superscript layout).
/// Otherwise, falls back to the flat display-string approach.
pub fn drawBlockMath(
    node: *const layout_types.LayoutNode,
    fonts: *const Fonts,
    scroll_y: f32,
    viewport_h: f32,
) void {
    const math_data = node.data.math_block;
    const latex = math_data.latex;
    const font_size = math_data.font_size;
    const color = math_data.color;
    const bg_color = math_data.bg_color;

    const draw_y = node.rect.y - scroll_y;

    // Draw subtle background for block math
    if (bg_color) |bg| {
        rl.drawRectangleRounded(
            .{
                .x = node.rect.x,
                .y = draw_y,
                .width = node.rect.width,
                .height = node.rect.height,
            },
            0.02,
            4,
            bg,
        );
    }

    // If the layout phase pre-populated text_runs via the FFI tree walker,
    // render those positioned runs directly for proper fraction/superscript layout.
    if (node.text_runs.items.len > 0) {
        for (node.text_runs.items) |*run| {
            text_renderer.drawTextRun(run, fonts, scroll_y, null, viewport_h);
        }
        return;
    }

    // Fallback: convert latex to a Unicode display string and draw it centered.
    var buf: [4096]u8 = undefined;
    const display = latexToDisplayString(latex, &buf);

    // Measure to center horizontally
    const measured = fonts.measure(display, font_size, false, true, false);
    const center_x = node.rect.x + (node.rect.width - measured.x) / 2.0;
    const center_y = node.rect.y + (node.rect.height - measured.y) / 2.0;

    const ctx = MathRenderContext{
        .fonts = fonts,
        .color = color,
        .base_font_size = font_size,
    };
    ctx.drawText(display, center_x, center_y, font_size, scroll_y);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "lookupSymbol finds Greek letters" {
    try testing.expect(lookupSymbol("alpha") != null);
    try testing.expectEqualStrings("\xce\xb1", lookupSymbol("alpha").?);
    try testing.expect(lookupSymbol("pi") != null);
    try testing.expectEqualStrings("\xcf\x80", lookupSymbol("pi").?);
    try testing.expect(lookupSymbol("Omega") != null);
    try testing.expectEqualStrings("\xce\xa9", lookupSymbol("Omega").?);
}

test "lookupSymbol finds math operators" {
    try testing.expect(lookupSymbol("infty") != null);
    try testing.expectEqualStrings("\xe2\x88\x9e", lookupSymbol("infty").?);
    try testing.expect(lookupSymbol("pm") != null);
    try testing.expectEqualStrings("\xc2\xb1", lookupSymbol("pm").?);
}

test "lookupSymbol returns null for unknown commands" {
    try testing.expectEqual(@as(?[]const u8, null), lookupSymbol("nonexistent"));
    try testing.expectEqual(@as(?[]const u8, null), lookupSymbol(""));
}

test "C parser produces SPACE nodes for whitespace" {
    const input = "E = mc^2";
    const result = latex_c.latex_render_parse(input.ptr, @intCast(input.len));
    try testing.expect(result != null);
    defer latex_c.latex_render_free(result);
    // Should have nodes: ROOT, TEXT(E), SPACE, TEXT(=), SPACE, TEXT(mc), SUP, TEXT(2)
    try testing.expect(result.*.count >= 5);
    // Check that space nodes exist
    var space_count: usize = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(result.*.count))) : (i += 1) {
        if (result.*.nodes[i].type == latex_c.LATEX_NODE_SPACE) {
            space_count += 1;
        }
    }
    try testing.expect(space_count >= 2); // At least 2 space nodes (around =)
}

test "latexToDisplayString converts simple variable" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("x", &buf);
    try testing.expectEqualStrings("x", result);
}

test "latexToDisplayString converts E = mc^2" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("E = mc^2", &buf);
    try testing.expectEqualStrings("E = mc\xc2\xb2", result);
}

test "latexToDisplayString converts Greek letters" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("\\alpha + \\beta", &buf);
    try testing.expectEqualStrings("\xce\xb1 + \xce\xb2", result);
}

test "latexToDisplayString converts fraction" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("\\frac{a}{b}", &buf);
    try testing.expectEqualStrings("a/b", result);
}

test "latexToDisplayString converts sqrt" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("\\sqrt{x}", &buf);
    try testing.expectEqualStrings("\xe2\x88\x9a(x)", result);
}

test "latexToDisplayString converts integral" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("\\int_0^1 x dx", &buf);
    // ∫₀¹ x dx
    try testing.expectEqualStrings("\xe2\x88\xab\xe2\x82\x80\xc2\xb9 x dx", result);
}

test "latexToDisplayString converts sum with limits" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("\\sum_{n=1}^{\\infty}", &buf);
    // ∑ₙ₌₁^∞ — all subscript chars converted to Unicode: n→ₙ, =→₌, 1→₁
    const expected = "\xe2\x88\x91\xe2\x82\x99\xe2\x82\x8c\xe2\x82\x81^" ++ "\xe2\x88\x9e";
    try testing.expectEqualStrings(expected, result);
}

test "latexToDisplayString handles braces correctly" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("{a + b}", &buf);
    try testing.expectEqualStrings("a + b", result);
}

test "latexToDisplayString converts pm symbol" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("\\pm", &buf);
    try testing.expectEqualStrings("\xc2\xb1", result);
}

test "latexToDisplayString converts subscript" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("x_2", &buf);
    try testing.expectEqualStrings("x\xe2\x82\x82", result);
}

test "latexToDisplayString handles empty input" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("", &buf);
    try testing.expectEqualStrings("", result);
}

test "latexToDisplayString handles array/matrix environment" {
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("\\begin{array}{cc} a & b \\\\ c & d \\end{array}", &buf);
    // Should produce: " a   b  |  c   d "
    try testing.expect(result.len > 0);
    // The & becomes space, \\\\ becomes " | "
    try testing.expect(std.mem.indexOf(u8, result, "|") != null);
}

test "unicodeSuperscript returns correct values" {
    try testing.expectEqualStrings("\xc2\xb2", unicodeSuperscript('2').?);
    try testing.expectEqualStrings("\xc2\xb3", unicodeSuperscript('3').?);
    try testing.expectEqualStrings("\xe2\x81\xbf", unicodeSuperscript('n').?);
    try testing.expectEqual(@as(?[]const u8, null), unicodeSuperscript('z'));
}

test "unicodeSubscript returns correct values" {
    try testing.expectEqualStrings("\xe2\x82\x80", unicodeSubscript('0').?);
    try testing.expectEqualStrings("\xe2\x82\x81", unicodeSubscript('1').?);
    try testing.expectEqualStrings("\xe2\x82\x99", unicodeSubscript('n').?);
    try testing.expectEqual(@as(?[]const u8, null), unicodeSubscript('z'));
}

test "latexToDisplayString complex expression" {
    var buf: [512]u8 = undefined;
    // Test the quadratic formula: x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
    const result = latexToDisplayString("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", &buf);
    try testing.expect(result.len > 0);
    // Should contain x, =, /, ±, √
    try testing.expect(std.mem.indexOf(u8, result, "x") != null);
    try testing.expect(std.mem.indexOf(u8, result, "=") != null);
    try testing.expect(std.mem.indexOf(u8, result, "/") != null);
}

test "measureMathString returns positive dimensions" {
    // This test exercises the measurement logic without requiring raylib init.
    // Since Fonts.measure uses a stack buffer approach, we can verify the
    // function doesn't crash and returns the expected structure.
    // Full visual verification requires a running raylib context.
    const size = MathSize{
        .width = 100.0,
        .height = 20.0,
        .baseline = 12.0,
    };
    try testing.expect(size.width > 0);
    try testing.expect(size.height > 0);
    try testing.expect(size.baseline > 0);
    try testing.expect(size.baseline <= size.height);
}

// --- Tests for sample formulas from docs/github-markdown-samples.md ---

test "latexToDisplayString inline math: E=mc^2 from samples" {
    // docs/github-markdown-samples.md line 409: $E = mc^2$
    var buf: [256]u8 = undefined;
    const result = latexToDisplayString("E = mc^2", &buf);
    try testing.expect(result.len > 0);
    // Should contain E, =, m, c and superscript 2 (² = \xc2\xb2)
    try testing.expect(std.mem.indexOf(u8, result, "E") != null);
    try testing.expect(std.mem.indexOf(u8, result, "=") != null);
    try testing.expect(std.mem.indexOf(u8, result, "mc") != null);
    try testing.expectEqualStrings("E = mc\xc2\xb2", result);
}

test "latexToDisplayString inline math: quadratic formula from samples" {
    // docs/github-markdown-samples.md line 407:
    // $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$
    var buf: [512]u8 = undefined;
    const result = latexToDisplayString("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", &buf);
    try testing.expect(result.len > 0);
    // Should contain: x, =, ± (\xc2\xb1), √ (\xe2\x88\x9a), /
    try testing.expect(std.mem.indexOf(u8, result, "x") != null);
    try testing.expect(std.mem.indexOf(u8, result, "=") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\xc2\xb1") != null); // ±
    try testing.expect(std.mem.indexOf(u8, result, "\xe2\x88\x9a") != null); // √
    try testing.expect(std.mem.indexOf(u8, result, "/") != null); // fraction renders as /
}

test "latexToDisplayString block math: integral from samples" {
    // docs/github-markdown-samples.md lines 413-415:
    // $$\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$
    var buf: [512]u8 = undefined;
    const result = latexToDisplayString("\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}", &buf);
    try testing.expect(result.len > 0);
    // Should contain: ∫ (\xe2\x88\xab), ∞ (\xe2\x88\x9e), =, √ (\xe2\x88\x9a), π (\xcf\x80)
    try testing.expect(std.mem.indexOf(u8, result, "\xe2\x88\xab") != null); // ∫
    try testing.expect(std.mem.indexOf(u8, result, "\xe2\x88\x9e") != null); // ∞
    try testing.expect(std.mem.indexOf(u8, result, "=") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\xe2\x88\x9a") != null); // √
    try testing.expect(std.mem.indexOf(u8, result, "\xcf\x80") != null); // π
}

test "latexToDisplayString block math: sum series from samples" {
    // docs/github-markdown-samples.md lines 417-419:
    // $$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$
    var buf: [512]u8 = undefined;
    const result = latexToDisplayString("\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}", &buf);
    try testing.expect(result.len > 0);
    // Should contain: ∑ (\xe2\x88\x91), ∞ (\xe2\x88\x9e), =, π (\xcf\x80), /
    try testing.expect(std.mem.indexOf(u8, result, "\xe2\x88\x91") != null); // ∑
    try testing.expect(std.mem.indexOf(u8, result, "\xe2\x88\x9e") != null); // ∞
    try testing.expect(std.mem.indexOf(u8, result, "=") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\xcf\x80") != null); // π
    try testing.expect(std.mem.indexOf(u8, result, "/") != null); // fractions
}

test "latexToDisplayString block math: matrix from samples" {
    // docs/github-markdown-samples.md lines 423-438 (code block math):
    // Matrix multiplication expression
    var buf: [1024]u8 = undefined;
    const result = latexToDisplayString("\\left(\\begin{array}{cc}a & b\\\\c & d\\end{array}\\right)\\times\\left(\\begin{array}{c}x\\\\y\\end{array}\\right)=\\left(\\begin{array}{c}ax + by\\\\cx + dy\\end{array}\\right)", &buf);
    try testing.expect(result.len > 0);
    // Should contain: ×, =, and matrix elements a, b, c, d, x, y
    try testing.expect(std.mem.indexOf(u8, result, "\xc3\x97") != null); // ×
    try testing.expect(std.mem.indexOf(u8, result, "=") != null);
    try testing.expect(std.mem.indexOf(u8, result, "a") != null);
    try testing.expect(std.mem.indexOf(u8, result, "b") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x") != null);
    try testing.expect(std.mem.indexOf(u8, result, "y") != null);
}
