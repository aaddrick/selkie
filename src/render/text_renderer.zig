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
pub fn drawTextRun(run: *const TextRun, fonts: *const Fonts, scroll_y: f32, hover: ?LinkHoverState) void {
    const draw_y = run.rect.y - scroll_y;

    // Skip if off screen
    if (draw_y + run.rect.height < 0) return;
    if (draw_y > @as(f32, @floatFromInt(rl.getScreenHeight()))) return;

    const font = fonts.selectFont(.{
        .bold = run.style.bold,
        .italic = run.style.italic,
        .is_code = run.style.is_code,
    });

    // Draw inline code background
    if (run.style.is_code) {
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

    // Underline (for links)
    if (run.style.underline) {
        const underline_y = draw_y + run.rect.height - 2;
        rl.drawLineEx(
            .{ .x = run.rect.x, .y = underline_y },
            .{ .x = run.rect.x + run.rect.width, .y = underline_y },
            1.0,
            color,
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
