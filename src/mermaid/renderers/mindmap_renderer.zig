const rl = @import("raylib");
const std = @import("std");
const mm = @import("../models/mindmap_model.zig");
const MindMapModel = mm.MindMapModel;
const MindMapNode = mm.MindMapNode;
const NodeShape = mm.NodeShape;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");

pub fn drawMindMap(
    model: *const MindMapModel,
    origin_x: f32,
    origin_y: f32,
    diagram_width: f32,
    diagram_height: f32,
    theme: *const Theme,
    fonts: *const Fonts,
    scroll_y: f32,
) void {
    // Background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    if (model.root == null) return;

    // Draw connections first (behind nodes)
    drawConnections(&model.root.?, origin_x, origin_y, scroll_y);

    // Draw nodes
    drawNode(&model.root.?, origin_x, origin_y, theme, fonts, scroll_y);
}

fn drawConnections(node: *const MindMapNode, ox: f32, oy: f32, scroll_y: f32) void {
    const parent_cy = oy + node.y + node.height / 2 - scroll_y;

    for (node.children.items) |*child| {
        const child_cy = oy + child.y + child.height / 2 - scroll_y;

        // Connection: from right edge of parent to left edge of child
        const start_x = ox + node.x + node.width;
        const start_y = parent_cy;
        const end_x = ox + child.x;
        const end_y = child_cy;

        const mid_x = (start_x + end_x) / 2;

        // Simple curved line: start → mid → end
        const line_color = ru.withAlpha(child.color, 180);
        rl.drawLineEx(
            .{ .x = start_x, .y = start_y },
            .{ .x = mid_x, .y = (start_y + end_y) / 2 },
            2,
            line_color,
        );
        rl.drawLineEx(
            .{ .x = mid_x, .y = (start_y + end_y) / 2 },
            .{ .x = end_x, .y = end_y },
            2,
            line_color,
        );

        // Recurse for child connections
        drawConnections(child, ox, oy, scroll_y);
    }
}

fn drawNode(node: *const MindMapNode, ox: f32, oy: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const nx = ox + node.x;
    const ny = oy + node.y - scroll_y;
    const w = node.width;
    const h = node.height;

    // Draw shape based on type
    switch (node.shape) {
        .rounded, .default_shape => {
            rl.drawRectangleRounded(.{ .x = nx, .y = ny, .width = w, .height = h }, 0.3, 8, node.color);
            rl.drawRectangleRoundedLinesEx(.{ .x = nx, .y = ny, .width = w, .height = h }, 0.3, 8, 2, ru.darken(node.color));
        },
        .square => {
            rl.drawRectangleRec(.{ .x = nx, .y = ny, .width = w, .height = h }, node.color);
            rl.drawRectangleLinesEx(.{ .x = nx, .y = ny, .width = w, .height = h }, 2, ru.darken(node.color));
        },
        .circle => {
            const r = @max(w, h) / 2;
            const cx = nx + w / 2;
            const cy = ny + h / 2;
            rl.drawCircleV(.{ .x = cx, .y = cy }, r, node.color);
            rl.drawCircleLinesV(.{ .x = cx, .y = cy }, r, ru.darken(node.color));
        },
        .hexagon => {
            // Draw hexagon as rectangle with pointed ends
            const inset: f32 = w * 0.15;
            rl.drawRectangleRec(.{ .x = nx + inset, .y = ny, .width = w - inset * 2, .height = h }, node.color);
            // Left triangle
            rl.drawTriangle(
                .{ .x = nx + inset, .y = ny },
                .{ .x = nx, .y = ny + h / 2 },
                .{ .x = nx + inset, .y = ny + h },
                node.color,
            );
            // Right triangle
            rl.drawTriangle(
                .{ .x = nx + w - inset, .y = ny + h },
                .{ .x = nx + w, .y = ny + h / 2 },
                .{ .x = nx + w - inset, .y = ny },
                node.color,
            );
        },
        .cloud => {
            // Approximate cloud as a rounded rectangle with extra roundness
            rl.drawRectangleRounded(.{ .x = nx, .y = ny, .width = w, .height = h }, 0.5, 12, node.color);
            rl.drawRectangleRoundedLinesEx(.{ .x = nx, .y = ny, .width = w, .height = h }, 0.5, 12, 2, ru.darken(node.color));
        },
    }

    // Draw label text centered
    const font_size = @as(f32, switch (node.depth) {
        0 => 16.0,
        1 => 14.0,
        else => 12.0,
    });

    drawTextCentered(node.label, nx, ny, w, h, fonts, font_size, theme.mermaid_node_text, 0);
}

fn drawTextCentered(
    text: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    fonts: *const Fonts,
    font_size: f32,
    color: rl.Color,
    scroll_y: f32,
) void {
    if (text.len == 0) return;

    var buf: [256]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];

    const font = fonts.selectFont(.{});
    const spacing = font_size / 10.0;
    const measured = rl.measureTextEx(font, z, font_size, spacing);

    const tx = x + (w - measured.x) / 2;
    const ty = y - scroll_y + (h - measured.y) / 2;

    rl.drawTextEx(font, z, .{ .x = tx, .y = ty }, font_size, spacing, color);
}

