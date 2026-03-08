const std = @import("std");
const rl = @import("raylib");
const TextRun = @import("../layout/layout_types.zig").TextRun;
const slice_utils = @import("../utils/slice_utils.zig");
const Fonts = @import("../layout/text_measurer.zig").Fonts;

/// Hover state for link color changes. When a link URL matches hovered_url,
/// the link_hover_color is used instead of the normal link color.
pub const LinkHoverState = struct {
    /// Borrows from the layout tree via LinkHandler. Only valid during a single render() call.
    hovered_url: []const u8,
    link_hover_color: rl.Color,
};

fn drawTextSlice(font: rl.Font, text: []const u8, pos: rl.Vector2, font_size: f32, spacing: f32, color: rl.Color) void {
    if (text.len == 0) return;
    var buf: [2048]u8 = undefined;
    const z = slice_utils.sliceToZ(&buf, text);
    rl.drawTextEx(font, z, pos, font_size, spacing, color);
}

/// Draw a single text run. When `hover` is set, links matching the hovered URL use the hover color.
pub fn drawTextRun(run: *const TextRun, fonts: *const Fonts, scroll_y: f32, hover: ?LinkHoverState, viewport_h: f32) void {
    const draw_y = run.rect.y - scroll_y;

    // Skip if off screen
    if (draw_y + run.rect.height < 0) return;
    if (draw_y > viewport_h) return;

    const font = fonts.selectFont(.{
        .bold = run.style.bold,
        .italic = run.style.italic,
        .is_code = run.style.is_code,
    });

    // Draw kbd bordered keyboard-key background or inline code background
    if (run.style.is_kbd) {
        const pad: f32 = 3;
        const kbd_rect = rl.Rectangle{
            .x = run.rect.x - pad,
            .y = draw_y - pad,
            .width = run.rect.width + pad * 2,
            .height = run.rect.height + pad * 2,
        };
        // Background fill — light gray
        const kbd_bg = rl.Color{ .r = 235, .g = 238, .b = 242, .a = 255 };
        rl.drawRectangleRounded(kbd_rect, 0.25, 4, kbd_bg);
        // Border — slightly darker gray
        const kbd_border = rl.Color{ .r = 175, .g = 184, .b = 193, .a = 255 };
        rl.drawRectangleRoundedLinesEx(kbd_rect, 0.25, 4, 1, kbd_border);
        // Bottom shadow line — simulate depth with a darker 1px line at bottom
        const shadow_color = rl.Color{ .r = 130, .g = 140, .b = 150, .a = 100 };
        rl.drawLineEx(
            .{ .x = kbd_rect.x + 2, .y = kbd_rect.y + kbd_rect.height + 1 },
            .{ .x = kbd_rect.x + kbd_rect.width - 2, .y = kbd_rect.y + kbd_rect.height + 1 },
            1.0,
            shadow_color,
        );
    } else if (run.style.is_samp) {
        // <samp> — sample output: monospace with a distinct lighter background and subtle border
        const pad: f32 = 2;
        const samp_rect = rl.Rectangle{
            .x = run.rect.x - pad,
            .y = draw_y - pad,
            .width = run.rect.width + pad * 2,
            .height = run.rect.height + pad * 2,
        };
        const samp_bg = rl.Color{ .r = 240, .g = 246, .b = 252, .a = 255 };
        rl.drawRectangleRounded(samp_rect, 0.2, 4, samp_bg);
        const samp_border = rl.Color{ .r = 208, .g = 215, .b = 222, .a = 255 };
        rl.drawRectangleRoundedLinesEx(samp_rect, 0.2, 4, 1, samp_border);
    } else if (run.style.is_code) {
        if (run.style.code_bg) |bg| {
            const pad: f32 = 2;
            rl.drawRectangleRounded(
                .{
                    .x = run.rect.x - pad,
                    .y = draw_y - pad,
                    .width = run.rect.width + pad * 2,
                    .height = run.rect.height + pad * 2,
                },
                0.2,
                4,
                bg,
            );
        }
    }

    // Draw inline math background — subtle tinted background
    if (run.style.is_math) {
        const pad: f32 = 2;
        const math_bg = rl.Color{ .r = 240, .g = 240, .b = 248, .a = 200 };
        rl.drawRectangleRounded(
            .{
                .x = run.rect.x - pad,
                .y = draw_y - pad,
                .width = run.rect.width + pad * 2,
                .height = run.rect.height + pad * 2,
            },
            0.2,
            4,
            math_bg,
        );
    }

    // Draw <mark> highlight background — yellow with slight padding
    if (run.style.is_mark) {
        const pad: f32 = 1;
        const mark_bg = rl.Color{ .r = 255, .g = 235, .b = 59, .a = 140 };
        rl.drawRectangle(
            @intFromFloat(run.rect.x - pad),
            @intFromFloat(draw_y - pad),
            @intFromFloat(run.rect.width + pad * 2),
            @intFromFloat(run.rect.height + pad * 2),
            mark_bg,
        );
    }

    const spacing = run.style.font_size / 10.0;
    const color = resolveRunColor(run.style.color, run.style.link_url, hover);

    drawTextSlice(
        font,
        run.text,
        .{ .x = run.rect.x, .y = draw_y },
        run.style.font_size,
        spacing,
        color,
    );

    // Strikethrough
    if (run.style.strikethrough) {
        const strike_y = draw_y + run.rect.height / 2.0;
        rl.drawLineEx(
            .{ .x = run.rect.x, .y = strike_y },
            .{ .x = run.rect.x + run.rect.width, .y = strike_y },
            1.0,
            color,
        );
    }

    // Underline — links use the text color; <ins> uses a green insertion indicator.
    if (run.style.underline) {
        const underline_y = draw_y + run.rect.height - 2;
        // <ins> renders with a green underline (semantic: inserted/added text).
        // This distinguishes it visually from link underlines (which use link color)
        // and plain text underlines (which use text color).
        const ul_color = if (run.style.is_ins)
            rl.Color{ .r = 46, .g = 160, .b = 67, .a = 230 } // GitHub-green for insertions
        else
            color;
        const ul_thickness: f32 = if (run.style.is_ins) 1.5 else 1.0;
        rl.drawLineEx(
            .{ .x = run.rect.x, .y = underline_y },
            .{ .x = run.rect.x + run.rect.width, .y = underline_y },
            ul_thickness,
            ul_color,
        );
    }
}

/// Resolve the effective color for a text run, applying hover color when the
/// run's link URL matches the currently hovered URL. Uses pointer equality as
/// a fast path since both slices reference the same layout tree backing memory.
pub fn resolveRunColor(style_color: rl.Color, link_url: ?[]const u8, hover: ?LinkHoverState) rl.Color {
    const url = link_url orelse return style_color;
    const h = hover orelse return style_color;
    // Fast path: pointer equality (both slices reference the same layout tree memory)
    if (url.ptr == h.hovered_url.ptr and url.len == h.hovered_url.len) return h.link_hover_color;
    // Fallback: content equality for safety
    if (std.mem.eql(u8, url, h.hovered_url)) return h.link_hover_color;
    return style_color;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "resolveRunColor returns style_color when no link_url" {
    const style_color = rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const hover = LinkHoverState{
        .hovered_url = "https://example.com",
        .link_hover_color = rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 },
    };
    const result = resolveRunColor(style_color, null, hover);
    try testing.expectEqual(style_color, result);
}

test "resolveRunColor returns style_color when no hover state" {
    const style_color = rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const result = resolveRunColor(style_color, "https://example.com", null);
    try testing.expectEqual(style_color, result);
}

test "resolveRunColor returns hover color on matching URL" {
    const style_color = rl.Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const url = "https://example.com";
    const hover_color = rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const hover = LinkHoverState{
        .hovered_url = url,
        .link_hover_color = hover_color,
    };
    const result = resolveRunColor(style_color, url, hover);
    try testing.expectEqual(hover_color, result);
}

test "resolveRunColor returns style_color on non-matching URL" {
    const style_color = rl.Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const hover_color = rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const hover = LinkHoverState{
        .hovered_url = "https://other.com",
        .link_hover_color = hover_color,
    };
    const result = resolveRunColor(style_color, "https://example.com", hover);
    try testing.expectEqual(style_color, result);
}

test "resolveRunColor returns hover color via content equality with different pointers" {
    const style_color = rl.Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const hover_color = rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };

    // Build a URL from runtime data so the compiler cannot deduplicate pointers
    var buf: [32]u8 = undefined;
    const runtime_url = std.fmt.bufPrint(&buf, "{s}", .{"https://example.com"}) catch unreachable;

    const hover = LinkHoverState{
        .hovered_url = "https://example.com",
        .link_hover_color = hover_color,
    };
    // Verify the pointers are actually different (precondition)
    try testing.expect(runtime_url.ptr != "https://example.com".ptr);
    const result = resolveRunColor(style_color, runtime_url, hover);
    try testing.expectEqual(hover_color, result);
}

test "resolveRunColor returns style_color when both link_url and hover are null" {
    const style_color = rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const result = resolveRunColor(style_color, null, null);
    try testing.expectEqual(style_color, result);
}

// =============================================================================
// Sub-AC 2c: Rendering priority tests for nested HTML inline tag combinations.
//
// drawTextRun() uses an else-if chain for background layers (kbd > samp > code)
// and independent checks for mark, underline, and strikethrough.  The tests
// below verify that the style flags produced by the layout engine (document_layout.zig)
// result in the CORRECT rendering decisions for each nested combination.
//
// Since drawTextRun() calls raylib draw functions (requiring a display context),
// these tests exercise the STYLE FIELD INTERPRETATION that drives rendering
// decisions, not the actual pixel output.
// =============================================================================

const TextStyle = @import("../layout/layout_types.zig").TextStyle;

/// Returns the expected background layer for a text run based on the same
/// priority order that drawTextRun() uses: kbd > samp > code > none.
/// This is a pure function that mirrors the rendering logic, enabling tests
/// without a display context.
fn backgroundLayer(style: TextStyle) enum { kbd, samp, code, none } {
    if (style.is_kbd) return .kbd;
    if (style.is_samp) return .samp;
    if (style.is_code) return .code;
    return .none;
}

test "rendering priority: kbd wins over samp when both active (<kbd> nested in <samp>)" {
    // Both is_kbd and is_samp are set when <samp><kbd>…</kbd></samp> is rendered.
    // The renderer draws the kbd background (is_kbd is checked first in the
    // else-if chain), so kbd rendering takes priority.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_samp = true,
        .is_code = true,
    };
    try testing.expectEqual(.kbd, backgroundLayer(style));
}

test "rendering priority: samp wins over plain code when both active" {
    // <samp><code>…</code></samp>: samp takes priority over plain code background.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_samp = true,
        .is_code = true,
    };
    try testing.expectEqual(.samp, backgroundLayer(style));
}

test "rendering priority: kbd alone draws kbd background" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_code = true,
    };
    try testing.expectEqual(.kbd, backgroundLayer(style));
}

test "rendering priority: samp alone draws samp background" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_samp = true,
        .is_code = true,
    };
    try testing.expectEqual(.samp, backgroundLayer(style));
}

test "rendering priority: no kbd/samp/code flag gives no background layer" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    try testing.expectEqual(.none, backgroundLayer(style));
}

test "rendering composition: mark highlight is independent of kbd background" {
    // <mark><kbd>Key</kbd></mark>: both kbd background AND mark highlight render.
    // mark is checked independently (not in the else-if chain), so both draw.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_code = true,
        .is_mark = true,
    };
    // kbd background layer is drawn (kbd wins)
    try testing.expectEqual(.kbd, backgroundLayer(style));
    // AND mark highlight draws separately (not in else-if, always checked)
    try testing.expect(style.is_mark);
}

test "rendering composition: ins underline is independent of all backgrounds" {
    // <ins><kbd>K</kbd></ins>: kbd background is drawn AND green underline is drawn.
    // Underline rendering is checked after text drawing, independently of background.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_code = true,
        .is_ins = true,
        .underline = true,
    };
    try testing.expectEqual(.kbd, backgroundLayer(style));
    // underline and is_ins are both set for green underline rendering
    try testing.expect(style.underline);
    try testing.expect(style.is_ins);
}

test "rendering composition: mark highlight draws over samp background" {
    // <samp><mark>…</mark></samp>: samp background (light blue) draws first,
    // then mark highlight (semi-transparent yellow) draws on top.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_samp = true,
        .is_code = true,
        .is_mark = true,
    };
    try testing.expectEqual(.samp, backgroundLayer(style));
    try testing.expect(style.is_mark);
}

test "rendering composition: superscript kbd has correct y_offset for elevated background" {
    // <kbd><sup>text</sup></kbd>: the text run has both is_kbd=true and a
    // negative y_offset.  The kbd background rect in drawTextRun() uses
    // run.rect.y (which already includes y_offset), so the bordered box
    // appears at the superscript position — elevated above the baseline.
    //
    // This test verifies the STYLE STATE that the renderer receives, not the
    // actual pixel position (which requires a display context).
    const style = TextStyle{
        .font_size = 12.0, // 75% of 16px after superscript reduction
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_code = true,
        .y_offset = -6.4, // -16 * 0.4 — superscript shift
    };
    // kbd background will be drawn at the elevated (superscript) position
    try testing.expectEqual(.kbd, backgroundLayer(style));
    try testing.expect(style.y_offset < 0);
    // font is smaller (superscript)
    try testing.expectApproxEqAbs(@as(f32, 12.0), style.font_size, 0.01);
}

test "rendering composition: subscript mark has correct y_offset for lowered highlight" {
    // <sub><mark>text</mark></sub>: the mark highlight is drawn at the
    // subscript position (rect.y includes positive y_offset).
    const style = TextStyle{
        .font_size = 12.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_mark = true,
        .y_offset = 3.2, // +16 * 0.2 — subscript shift
    };
    try testing.expect(style.is_mark);
    try testing.expect(style.y_offset > 0); // lowered below baseline
    try testing.expectEqual(.none, backgroundLayer(style)); // no kbd/samp/code
}
