//! Math Expression Layout
//!
//! Converts math AST nodes (math_inline, math_block) into positioned layout nodes.
//! Inline math flows within text paragraphs as styled text runs.
//! Block math creates standalone centered layout nodes with background.

const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");

const layout_types = @import("layout_types.zig");
const math_renderer = @import("../render/math_renderer.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("text_measurer.zig").Fonts;

/// Layout a block math expression ($$...$$ or ```math code block).
/// Creates a centered math_block layout node with background.
/// `cursor_y` is advanced past the block.
pub fn layoutBlockMath(
    allocator: Allocator,
    latex: ?[]const u8,
    theme: *const Theme,
    fonts: *const Fonts,
    content_x: f32,
    content_width: f32,
    cursor_y: *f32,
    tree: *layout_types.LayoutTree,
) !void {
    const source = latex orelse return;
    if (source.len == 0) return;

    // Store the LaTeX source in the arena so it outlives this function
    const arena = tree.arena.allocator();
    const latex_copy = try arena.dupe(u8, source);

    const font_size = theme.body_font_size * 1.2;
    const math_size = math_renderer.measureBlockMathString(source, fonts, theme.body_font_size);

    // Create background color (subtle gray, similar to code blocks)
    const bg_color = rl.Color{
        .r = @min(255, @as(u16, theme.code_background.r) + 10),
        .g = @min(255, @as(u16, theme.code_background.g) + 10),
        .b = @min(255, @as(u16, theme.code_background.b) + 10),
        .a = theme.code_background.a,
    };

    const padding = theme.code_block_padding;
    const block_height = math_size.height + padding * 2;

    var layout_node = layout_types.LayoutNode.init(allocator, .{ .math_block = .{
        .latex = latex_copy,
        .font_size = font_size,
        .color = theme.text,
        .bg_color = bg_color,
    } });
    errdefer layout_node.deinit();

    layout_node.rect = .{
        .x = content_x,
        .y = cursor_y.*,
        .width = content_width,
        .height = block_height,
    };

    try tree.nodes.append(layout_node);
    cursor_y.* += block_height + theme.paragraph_spacing;
}

/// Layout an inline math expression ($...$) as a text run within a paragraph.
/// The math content is converted to a display string and added as a styled
/// text run with the is_math flag set for special rendering.
///
/// Coordinates are absolute (document space): `cursor_x` and `cursor_y` track
/// the current insertion point; `content_x` and `content_width` define the
/// line boundaries for word-wrap decisions.
pub fn layoutInlineMath(
    latex: []const u8,
    style: layout_types.TextStyle,
    layout_node: *layout_types.LayoutNode,
    cursor_x: *f32,
    line_height: *f32,
    content_x: f32,
    content_width: f32,
    cursor_y: *f32,
    arena: Allocator,
    fonts: *const Fonts,
) !void {
    if (latex.len == 0) return;

    // Convert LaTeX to display string
    var buf: [4096]u8 = undefined;
    const display = math_renderer.latexToDisplayString(latex, &buf);

    // Duplicate display string into arena so it outlives layout
    const display_copy = try arena.dupe(u8, display);

    // Measure with italic font (math convention)
    const measured = fonts.measure(display_copy, style.font_size, false, true, false);
    const max_x = content_x + content_width;

    // Wrap if needed
    if (cursor_x.* + measured.x > max_x and cursor_x.* > content_x) {
        cursor_x.* = content_x;
        cursor_y.* += line_height.*;
    }

    var math_style = style;
    math_style.italic = true;
    math_style.is_math = true;

    const run = layout_types.TextRun{
        .text = display_copy,
        .style = math_style,
        .rect = .{
            .x = cursor_x.*,
            .y = cursor_y.* + style.y_offset,
            .width = measured.x,
            .height = measured.y,
        },
    };
    try layout_node.text_runs.append(run);

    line_height.* = @max(line_height.*, measured.y);
    cursor_x.* += measured.x;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "latexToDisplayString converts LaTeX to non-empty display string" {
    // Verifies the C FFI display string conversion used by layoutInlineMath.
    // Full layoutInlineMath testing requires a raylib font context.
    var buf: [256]u8 = undefined;
    const display = math_renderer.latexToDisplayString("E = mc^2", &buf);
    try testing.expect(display.len > 0);
    try testing.expect(std.mem.indexOf(u8, display, "E") != null);
}

test "math_block layout node data stores latex and font_size" {
    var node = layout_types.LayoutNode.init(testing.allocator, .{ .math_block = .{
        .latex = "x^2 + y^2 = r^2",
        .font_size = 19.2,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .bg_color = rl.Color{ .r = 245, .g = 245, .b = 245, .a = 255 },
    } });
    defer node.deinit();

    try testing.expectEqualStrings("x^2 + y^2 = r^2", node.data.math_block.latex);
    try testing.expectEqual(@as(f32, 19.2), node.data.math_block.font_size);
}
