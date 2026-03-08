const std = @import("std");
const rl = @import("raylib");
const LayoutNode = @import("../layout/layout_types.zig").LayoutNode;
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const text_renderer = @import("text_renderer.zig");
const ImageRenderer = @import("image_renderer.zig").ImageRenderer;

/// Draw a code block: rounded background rectangle, line number gutter, and syntax-highlighted text.
pub fn drawCodeBlock(node: *const LayoutNode, theme: *const Theme, fonts: *const Fonts, scroll_y: f32, viewport_h: f32) void {
    const code = node.data.code_block;
    const bg = code.bg_color orelse theme.code_background;
    const draw_y = node.rect.y - scroll_y;

    // Background rectangle
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

    // Gutter separator line
    if (code.line_number_gutter_width > 0) {
        const gutter_x = node.rect.x + code.line_number_gutter_width;
        const gutter_color = theme.line_number_color;
        rl.drawLineEx(
            .{ .x = gutter_x, .y = draw_y + theme.code_block_padding },
            .{ .x = gutter_x, .y = draw_y + node.rect.height - theme.code_block_padding },
            1.0,
            gutter_color,
        );
    }

    // Code blocks don't contain links; skip hover
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y, null, viewport_h);
    }
}

/// Draw a code block language label header (e.g., "python", "javascript").
pub fn drawCodeBlockHeader(node: *const LayoutNode, fonts: *const Fonts, scroll_y: f32) void {
    const header = node.data.code_block_header;
    const draw_y = node.rect.y - scroll_y;

    // Draw a slightly darker background strip for the header
    rl.drawRectangleRounded(
        .{
            .x = node.rect.x,
            .y = draw_y,
            .width = node.rect.width,
            .height = node.rect.height,
        },
        0.02,
        4,
        header.bg_color,
    );

    // Draw the language label text
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y, null, 0);
    }
}

/// Draw an alert background fill (translucent tinted rectangle).
pub fn drawAlertBg(node: *const LayoutNode, scroll_y: f32) void {
    const alert = node.data.alert_bg;
    rl.drawRectangleRounded(
        .{
            .x = node.rect.x,
            .y = node.rect.y - scroll_y,
            .width = node.rect.width,
            .height = node.rect.height,
        },
        0.02,
        4,
        alert.color,
    );
}

/// Draw a horizontal rule (thematic break).
pub fn drawThematicBreak(node: *const LayoutNode, scroll_y: f32) void {
    const color = node.data.thematic_break.color;
    rl.drawLineEx(
        .{ .x = node.rect.x, .y = node.rect.y - scroll_y },
        .{ .x = node.rect.x + node.rect.width, .y = node.rect.y - scroll_y },
        1.0,
        color,
    );
}

/// Draw a blockquote left border bar.
pub fn drawBlockQuoteBorder(node: *const LayoutNode, scroll_y: f32) void {
    const color = node.data.block_quote_border.color;
    rl.drawRectangleRec(
        .{
            .x = node.rect.x,
            .y = node.rect.y - scroll_y,
            .width = node.rect.width,
            .height = node.rect.height,
        },
        color,
    );
}

/// Draw a `<details>/<summary>` collapsible section header.
/// Renders a smoothly-animated disclosure triangle (▶ collapsed / ▼ expanded),
/// an optional keyboard-focus ring, and the summary text.
///
/// Animation: `anim_progress` in [0.0, 1.0] linearly interpolates the three
/// triangle vertices between the collapsed (▶) and expanded (▼) positions.
/// This is updated in-place each frame by the app without requiring a re-layout.
pub fn drawDetailsHeader(node: *const LayoutNode, theme: *const Theme, fonts: *const Fonts, scroll_y: f32, viewport_h: f32) void {
    const details = node.data.details_header;
    const draw_y = node.rect.y - scroll_y;

    // Focus ring: draw a rounded-rectangle outline when this header has keyboard focus.
    if (details.focused) {
        const focus_padding: f32 = 2.0;
        const focus_rect = rl.Rectangle{
            .x = node.rect.x - focus_padding,
            .y = draw_y - focus_padding,
            .width = node.rect.width + focus_padding * 2,
            .height = node.rect.height + focus_padding * 2,
        };
        // Semi-transparent focus ring using the link/accent colour
        const focus_color = rl.Color{
            .r = theme.link.r,
            .g = theme.link.g,
            .b = theme.link.b,
            .a = 200,
        };
        rl.drawRectangleLinesEx(focus_rect, 2.0, focus_color);
    }

    // Animated disclosure triangle.
    // p = 0.0 → ▶ (collapsed), p = 1.0 → ▼ (expanded).
    // The three vertices are linearly interpolated between the two states.
    const p = std.math.clamp(details.anim_progress, 0.0, 1.0);
    const tri_size: f32 = 10.0;
    const tri_center_x = node.rect.x + 6.0;
    const tri_center_y = draw_y + node.rect.height / 2.0;

    // Collapsed (▶ pointing right) vertex positions
    const cx1 = rl.Vector2{ .x = tri_center_x - tri_size * 0.3, .y = tri_center_y - tri_size * 0.5 };
    const cx2 = rl.Vector2{ .x = tri_center_x - tri_size * 0.3, .y = tri_center_y + tri_size * 0.5 };
    const cx3 = rl.Vector2{ .x = tri_center_x + tri_size * 0.4, .y = tri_center_y };

    // Expanded (▼ pointing down) vertex positions
    const ex1 = rl.Vector2{ .x = tri_center_x - tri_size * 0.5, .y = tri_center_y - tri_size * 0.3 };
    const ex2 = rl.Vector2{ .x = tri_center_x + tri_size * 0.5, .y = tri_center_y - tri_size * 0.3 };
    const ex3 = rl.Vector2{ .x = tri_center_x, .y = tri_center_y + tri_size * 0.4 };

    // Interpolate
    const v1 = rl.Vector2{ .x = cx1.x + (ex1.x - cx1.x) * p, .y = cx1.y + (ex1.y - cx1.y) * p };
    const v2 = rl.Vector2{ .x = cx2.x + (ex2.x - cx2.x) * p, .y = cx2.y + (ex2.y - cx2.y) * p };
    const v3 = rl.Vector2{ .x = cx3.x + (ex3.x - cx3.x) * p, .y = cx3.y + (ex3.y - cx3.y) * p };

    rl.drawTriangle(v1, v2, v3, theme.text);

    // Draw summary text — pass viewport_h so the off-screen culling in drawTextRun
    // uses the correct viewport height rather than 0 (which would cull all text).
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y, null, viewport_h);
    }
}

/// Draw text runs for a text block or heading. Link runs matching the hover state use hover color.
pub fn drawTextBlock(node: *const LayoutNode, fonts: *const Fonts, scroll_y: f32, hover: ?text_renderer.LinkHoverState, viewport_h: f32) void {
    for (node.text_runs.items) |*run| {
        text_renderer.drawTextRun(run, fonts, scroll_y, hover, viewport_h);
    }
}

/// Draw an image or placeholder if texture is missing.
pub fn drawImage(node: *const LayoutNode, fonts: *const Fonts, scroll_y: f32) void {
    const img = node.data.image;
    if (img.texture) |texture| {
        ImageRenderer.drawImage(texture, node.rect, scroll_y);
    } else {
        ImageRenderer.drawPlaceholder(node.rect, img.alt, fonts, scroll_y);
    }
}
