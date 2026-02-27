const rl = @import("raylib");
const std = @import("std");
const FlowchartModel = @import("../models/flowchart_model.zig").FlowchartModel;
const graph_mod = @import("../models/graph.zig");
const EdgeStyle = graph_mod.EdgeStyle;
const ArrowHead = graph_mod.ArrowHead;
const Point = graph_mod.Point;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");
const shapes = @import("shapes.zig");

pub fn drawFlowchart(model: *const FlowchartModel, origin_x: f32, origin_y: f32, diagram_width: f32, diagram_height: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    // 1. Draw background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    // 2. Draw subgraph backgrounds
    for (model.subgraphs.items) |sg| {
        if (sg.width > 0 and sg.height > 0) {
            // Subgraph background with slightly lighter fill
            const sg_fill = rl.Color{
                .r = @min(255, @as(u16, theme.mermaid_subgraph_bg.r) + 10),
                .g = @min(255, @as(u16, theme.mermaid_subgraph_bg.g) + 10),
                .b = @min(255, @as(u16, theme.mermaid_subgraph_bg.b) + 10),
                .a = 200,
            };
            rl.drawRectangleRec(.{
                .x = origin_x + sg.x,
                .y = origin_y + sg.y - scroll_y,
                .width = sg.width,
                .height = sg.height,
            }, sg_fill);
            rl.drawRectangleLinesEx(.{
                .x = origin_x + sg.x,
                .y = origin_y + sg.y - scroll_y,
                .width = sg.width,
                .height = sg.height,
            }, 1, theme.mermaid_node_border);

            // Subgraph title
            shapes.drawTextCentered(
                sg.title,
                origin_x + sg.x,
                origin_y + sg.y,
                sg.width,
                20,
                fonts,
                theme.body_font_size * 0.85,
                theme.mermaid_node_text,
                scroll_y,
            );
        }
    }

    // 3. Draw edges
    for (model.graph.edges.items) |edge| {
        drawEdge(&edge, origin_x, origin_y, theme, fonts, scroll_y);
    }

    // 4. Draw nodes
    var node_it = model.graph.nodes.iterator();
    while (node_it.next()) |entry| {
        const node = entry.value_ptr;
        shapes.drawShape(
            node.shape,
            origin_x + node.x,
            origin_y + node.y,
            node.width,
            node.height,
            theme.mermaid_node_fill,
            theme.mermaid_node_border,
            scroll_y,
        );

        // Draw node label
        shapes.drawTextCentered(
            node.label,
            origin_x + node.x,
            origin_y + node.y,
            node.width,
            node.height,
            fonts,
            theme.body_font_size,
            theme.mermaid_node_text,
            scroll_y,
        );
    }
}

fn drawEdge(edge: *const graph_mod.GraphEdge, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    if (edge.waypoints.items.len < 2) return;

    const line_width: f32 = switch (edge.style) {
        .thick => 3.0,
        else => 1.5,
    };

    const color = theme.mermaid_edge;

    if (edge.style == .dotted) {
        // Draw dashed line
        var i: usize = 0;
        while (i < edge.waypoints.items.len - 1) : (i += 1) {
            const p1 = edge.waypoints.items[i];
            const p2 = edge.waypoints.items[i + 1];
            ru.drawDashedLine(
                origin_x + p1.x,
                origin_y + p1.y - scroll_y,
                origin_x + p2.x,
                origin_y + p2.y - scroll_y,
                line_width,
                color,
            );
        }
    } else {
        // Draw solid/thick line
        var i: usize = 0;
        while (i < edge.waypoints.items.len - 1) : (i += 1) {
            const p1 = edge.waypoints.items[i];
            const p2 = edge.waypoints.items[i + 1];
            rl.drawLineEx(
                .{ .x = origin_x + p1.x, .y = origin_y + p1.y - scroll_y },
                .{ .x = origin_x + p2.x, .y = origin_y + p2.y - scroll_y },
                line_width,
                color,
            );
        }
    }

    // Draw arrowhead at the last waypoint
    if (edge.arrow_head != .none and edge.waypoints.items.len >= 2) {
        const last = edge.waypoints.items[edge.waypoints.items.len - 1];
        const prev = edge.waypoints.items[edge.waypoints.items.len - 2];
        drawArrowHead(
            edge.arrow_head,
            origin_x + last.x,
            origin_y + last.y - scroll_y,
            origin_x + prev.x,
            origin_y + prev.y - scroll_y,
            color,
        );
    }

    // Draw edge label
    if (edge.label) |label| {
        if (edge.waypoints.items.len >= 2) {
            const mid_idx = edge.waypoints.items.len / 2;
            const p1 = edge.waypoints.items[mid_idx - 1];
            const p2 = edge.waypoints.items[mid_idx];
            const mx = origin_x + (p1.x + p2.x) / 2;
            const my = origin_y + (p1.y + p2.y) / 2 - scroll_y;

            const measured = fonts.measure(label, theme.body_font_size * 0.8, false, false, false);
            const lw = measured.x + 8;
            const lh = measured.y + 4;

            // Label background
            rl.drawRectangleRec(.{
                .x = mx - lw / 2,
                .y = my - lh / 2,
                .width = lw,
                .height = lh,
            }, theme.mermaid_label_bg);

            // Label text (need to center without scroll_y adjustment since my already adjusted)
            const font = fonts.selectFont(.{});
            const font_size = theme.body_font_size * 0.8;
            const spacing = font_size / 10.0;

            var buf: [256]u8 = undefined;
            const len = @min(label.len, buf.len - 1);
            @memcpy(buf[0..len], label[0..len]);
            buf[len] = 0;
            const z: [:0]const u8 = buf[0..len :0];

            rl.drawTextEx(font, z, .{
                .x = mx - measured.x / 2,
                .y = my - measured.y / 2,
            }, font_size, spacing, theme.mermaid_edge_text);
        }
    }
}

fn drawArrowHead(head: ArrowHead, tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, color: rl.Color) void {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;

    const nx = dx / len;
    const ny = dy / len;
    const arrow_size: f32 = 10;

    switch (head) {
        .arrow => {
            const p1 = rl.Vector2{
                .x = tip_x - arrow_size * nx + arrow_size * 0.5 * ny,
                .y = tip_y - arrow_size * ny - arrow_size * 0.5 * nx,
            };
            const p2 = rl.Vector2{
                .x = tip_x - arrow_size * nx - arrow_size * 0.5 * ny,
                .y = tip_y - arrow_size * ny + arrow_size * 0.5 * nx,
            };
            const tip = rl.Vector2{ .x = tip_x, .y = tip_y };
            rl.drawTriangle(tip, p2, p1, color);
        },
        .circle => {
            rl.drawCircleV(.{ .x = tip_x, .y = tip_y }, 4, color);
        },
        .cross => {
            rl.drawLineEx(
                .{ .x = tip_x - 5, .y = tip_y - 5 },
                .{ .x = tip_x + 5, .y = tip_y + 5 },
                2,
                color,
            );
            rl.drawLineEx(
                .{ .x = tip_x - 5, .y = tip_y + 5 },
                .{ .x = tip_x + 5, .y = tip_y - 5 },
                2,
                color,
            );
        },
        .none => {},
    }
}

