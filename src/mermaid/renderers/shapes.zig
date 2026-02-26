const rl = @import("raylib");
const std = @import("std");
const graph_mod = @import("../models/graph.zig");
const NodeShape = graph_mod.NodeShape;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;

pub fn drawShape(shape: NodeShape, x: f32, y: f32, w: f32, h: f32, fill: rl.Color, border: rl.Color, scroll_y: f32) void {
    const sy = y - scroll_y;

    switch (shape) {
        .rectangle => {
            rl.drawRectangleRec(.{ .x = x, .y = sy, .width = w, .height = h }, fill);
            rl.drawRectangleLinesEx(.{ .x = x, .y = sy, .width = w, .height = h }, 2, border);
        },
        .rounded, .stadium => {
            const roundness: f32 = if (shape == .stadium) 1.0 else 0.3;
            rl.drawRectangleRounded(.{ .x = x, .y = sy, .width = w, .height = h }, roundness, 6, fill);
            rl.drawRectangleRoundedLinesEx(.{ .x = x, .y = sy, .width = w, .height = h }, roundness, 6, 2, border);
        },
        .diamond => {
            const cx = x + w / 2;
            const cy = sy + h / 2;
            const hw = w / 2;
            const hh = h / 2;
            // Fill with 4 triangles
            const top = rl.Vector2{ .x = cx, .y = cy - hh };
            const right = rl.Vector2{ .x = cx + hw, .y = cy };
            const bottom = rl.Vector2{ .x = cx, .y = cy + hh };
            const left = rl.Vector2{ .x = cx - hw, .y = cy };
            rl.drawTriangle(top, left, bottom, fill);
            rl.drawTriangle(top, bottom, right, fill);
            // Border
            rl.drawLineEx(top, right, 2, border);
            rl.drawLineEx(right, bottom, 2, border);
            rl.drawLineEx(bottom, left, 2, border);
            rl.drawLineEx(left, top, 2, border);
        },
        .circle, .double_circle => {
            const cx = x + w / 2;
            const cy = sy + h / 2;
            const radius = @min(w, h) / 2;
            rl.drawCircleV(.{ .x = cx, .y = cy }, radius, fill);
            rl.drawCircleLinesV(.{ .x = cx, .y = cy }, radius, border);
            if (shape == .double_circle) {
                rl.drawCircleLinesV(.{ .x = cx, .y = cy }, radius - 4, border);
            }
        },
        .hexagon => {
            const cx = x + w / 2;
            const cy = sy + h / 2;
            const hw = w / 2;
            const hh = h / 2;
            const indent: f32 = 15;
            // Six points
            const p1 = rl.Vector2{ .x = x + indent, .y = cy - hh };
            const p2 = rl.Vector2{ .x = cx + hw - indent, .y = cy - hh };
            const p3 = rl.Vector2{ .x = cx + hw, .y = cy };
            const p4 = rl.Vector2{ .x = cx + hw - indent, .y = cy + hh };
            const p5 = rl.Vector2{ .x = x + indent, .y = cy + hh };
            const p6 = rl.Vector2{ .x = x, .y = cy };
            // Fill as triangles
            rl.drawTriangle(p1, p6, p5, fill);
            rl.drawTriangle(p1, p5, p4, fill);
            rl.drawTriangle(p1, p4, p2, fill);
            rl.drawTriangle(p2, p4, p3, fill);
            // Border
            rl.drawLineEx(p1, p2, 2, border);
            rl.drawLineEx(p2, p3, 2, border);
            rl.drawLineEx(p3, p4, 2, border);
            rl.drawLineEx(p4, p5, 2, border);
            rl.drawLineEx(p5, p6, 2, border);
            rl.drawLineEx(p6, p1, 2, border);
        },
        .parallelogram => {
            const slant: f32 = 15;
            const p1 = rl.Vector2{ .x = x + slant, .y = sy };
            const p2 = rl.Vector2{ .x = x + w, .y = sy };
            const p3 = rl.Vector2{ .x = x + w - slant, .y = sy + h };
            const p4 = rl.Vector2{ .x = x, .y = sy + h };
            rl.drawTriangle(p1, p4, p3, fill);
            rl.drawTriangle(p1, p3, p2, fill);
            rl.drawLineEx(p1, p2, 2, border);
            rl.drawLineEx(p2, p3, 2, border);
            rl.drawLineEx(p3, p4, 2, border);
            rl.drawLineEx(p4, p1, 2, border);
        },
        .trapezoid => {
            const slant: f32 = 15;
            const p1 = rl.Vector2{ .x = x, .y = sy };
            const p2 = rl.Vector2{ .x = x + w, .y = sy };
            const p3 = rl.Vector2{ .x = x + w - slant, .y = sy + h };
            const p4 = rl.Vector2{ .x = x + slant, .y = sy + h };
            rl.drawTriangle(p1, p4, p3, fill);
            rl.drawTriangle(p1, p3, p2, fill);
            rl.drawLineEx(p1, p2, 2, border);
            rl.drawLineEx(p2, p3, 2, border);
            rl.drawLineEx(p3, p4, 2, border);
            rl.drawLineEx(p4, p1, 2, border);
        },
        .cylinder => {
            // Rectangle body + ellipses top and bottom
            const ellipse_h: f32 = 8;
            rl.drawRectangleRec(.{ .x = x, .y = sy + ellipse_h, .width = w, .height = h - ellipse_h * 2 }, fill);
            // Top ellipse
            rl.drawEllipse(@intFromFloat(x + w / 2), @intFromFloat(sy + ellipse_h), w / 2, ellipse_h, fill);
            rl.drawEllipseLines(@intFromFloat(x + w / 2), @intFromFloat(sy + ellipse_h), w / 2, ellipse_h, border);
            // Bottom ellipse
            rl.drawEllipse(@intFromFloat(x + w / 2), @intFromFloat(sy + h - ellipse_h), w / 2, ellipse_h, fill);
            rl.drawEllipseLines(@intFromFloat(x + w / 2), @intFromFloat(sy + h - ellipse_h), w / 2, ellipse_h, border);
            // Side lines
            rl.drawLineEx(.{ .x = x, .y = sy + ellipse_h }, .{ .x = x, .y = sy + h - ellipse_h }, 2, border);
            rl.drawLineEx(.{ .x = x + w, .y = sy + ellipse_h }, .{ .x = x + w, .y = sy + h - ellipse_h }, 2, border);
        },
        .subroutine => {
            // Rectangle with double vertical lines on sides
            rl.drawRectangleRec(.{ .x = x, .y = sy, .width = w, .height = h }, fill);
            rl.drawRectangleLinesEx(.{ .x = x, .y = sy, .width = w, .height = h }, 2, border);
            // Inner vertical lines
            rl.drawLineEx(.{ .x = x + 6, .y = sy }, .{ .x = x + 6, .y = sy + h }, 2, border);
            rl.drawLineEx(.{ .x = x + w - 6, .y = sy }, .{ .x = x + w - 6, .y = sy + h }, 2, border);
        },
        .asymmetric => {
            // Flag shape: rectangle with pointed right side
            const point: f32 = 15;
            const p1 = rl.Vector2{ .x = x, .y = sy };
            const p2 = rl.Vector2{ .x = x + w - point, .y = sy };
            const p3 = rl.Vector2{ .x = x + w, .y = sy + h / 2 };
            const p4 = rl.Vector2{ .x = x + w - point, .y = sy + h };
            const p5 = rl.Vector2{ .x = x, .y = sy + h };
            rl.drawTriangle(p1, p5, p4, fill);
            rl.drawTriangle(p1, p4, p2, fill);
            rl.drawTriangle(p2, p4, p3, fill);
            rl.drawLineEx(p1, p2, 2, border);
            rl.drawLineEx(p2, p3, 2, border);
            rl.drawLineEx(p3, p4, 2, border);
            rl.drawLineEx(p4, p5, 2, border);
            rl.drawLineEx(p5, p1, 2, border);
        },
    }
}

pub fn drawTextCentered(text: []const u8, x: f32, y: f32, w: f32, h: f32, fonts: *const Fonts, font_size: f32, color: rl.Color, scroll_y: f32) void {
    if (text.len == 0) return;

    const measured = fonts.measure(text, font_size, false, false, false);
    const tx = x + (w - measured.x) / 2;
    const ty = y - scroll_y + (h - measured.y) / 2;

    const font = fonts.selectFont(.{});
    const spacing = font_size / 10.0;

    // Null-terminate for raylib
    var buf: [512]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];

    rl.drawTextEx(font, z, .{ .x = tx, .y = ty }, font_size, spacing, color);
}
