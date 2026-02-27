const rl = @import("raylib");
const std = @import("std");
const sm = @import("../models/state_model.zig");
const StateModel = sm.StateModel;
const State = sm.State;
const StateType = sm.StateType;
const graph_mod = @import("../models/graph.zig");
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");
const shapes = @import("shapes.zig");

pub fn drawStateDiagram(model: *const StateModel, origin_x: f32, origin_y: f32, diagram_width: f32, diagram_height: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    // Background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    // Draw edges (transitions)
    for (model.graph.edges.items) |edge| {
        drawTransition(&edge, origin_x, origin_y, theme, fonts, scroll_y);
    }

    // Draw states
    for (model.states.items) |*state| {
        if (model.graph.nodes.get(state.id)) |gnode| {
            drawState(state, gnode.x, gnode.y, gnode.width, gnode.height, origin_x, origin_y, theme, fonts, scroll_y);
        }
    }
}

fn drawState(state: *const State, nx: f32, ny: f32, nw: f32, nh: f32, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const x = origin_x + nx;
    const y = origin_y + ny;
    const sy = y - scroll_y;

    switch (state.state_type) {
        .start => {
            // Filled black circle
            const cx = x + nw / 2;
            const cy = sy + nh / 2;
            rl.drawCircleV(.{ .x = cx, .y = cy }, 10, theme.mermaid_node_border);
        },
        .end => {
            // Circle with inner filled circle (bullseye)
            const cx = x + nw / 2;
            const cy = sy + nh / 2;
            rl.drawCircleLinesV(.{ .x = cx, .y = cy }, 10, theme.mermaid_node_border);
            rl.drawCircleV(.{ .x = cx, .y = cy }, 6, theme.mermaid_node_border);
        },
        .fork, .join => {
            // Horizontal bar
            rl.drawRectangleRec(.{ .x = x, .y = sy, .width = nw, .height = nh }, theme.mermaid_node_border);
        },
        .choice => {
            // Diamond
            shapes.drawShape(.diamond, x, y, nw, nh, theme.mermaid_node_fill, theme.mermaid_node_border, scroll_y);
        },
        .composite => {
            // Dashed rounded rectangle with label
            rl.drawRectangleRounded(.{ .x = x, .y = sy, .width = nw, .height = nh }, 0.15, 6, theme.mermaid_node_fill);
            drawDashedRect(x, sy, nw, nh, theme.mermaid_node_border);
            // Label
            const label = if (state.description) |d| d else state.label;
            shapes.drawTextCentered(label, x, y, nw, nh, fonts, theme.body_font_size, theme.mermaid_node_text, scroll_y);
        },
        .normal => {
            // Rounded rectangle
            rl.drawRectangleRounded(.{ .x = x, .y = sy, .width = nw, .height = nh }, 0.3, 6, theme.mermaid_node_fill);
            rl.drawRectangleRoundedLinesEx(.{ .x = x, .y = sy, .width = nw, .height = nh }, 0.3, 6, 2, theme.mermaid_node_border);
            // Label
            const label = if (state.description) |d| d else state.label;
            shapes.drawTextCentered(label, x, y, nw, nh, fonts, theme.body_font_size, theme.mermaid_node_text, scroll_y);
        },
    }
}

fn drawTransition(edge: *const graph_mod.GraphEdge, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    if (edge.waypoints.items.len < 2) return;

    const color = theme.mermaid_edge;

    // Draw line segments
    var i: usize = 0;
    while (i < edge.waypoints.items.len - 1) : (i += 1) {
        const p1 = edge.waypoints.items[i];
        const p2 = edge.waypoints.items[i + 1];
        rl.drawLineEx(
            .{ .x = origin_x + p1.x, .y = origin_y + p1.y - scroll_y },
            .{ .x = origin_x + p2.x, .y = origin_y + p2.y - scroll_y },
            1.5,
            color,
        );
    }

    // Arrowhead at target
    if (edge.waypoints.items.len >= 2) {
        const last = edge.waypoints.items[edge.waypoints.items.len - 1];
        const prev = edge.waypoints.items[edge.waypoints.items.len - 2];
        drawArrowHead(
            origin_x + last.x,
            origin_y + last.y - scroll_y,
            origin_x + prev.x,
            origin_y + prev.y - scroll_y,
            color,
        );
    }

    // Label
    if (edge.label) |label| {
        if (edge.waypoints.items.len >= 2) {
            const mid_idx = edge.waypoints.items.len / 2;
            const p1 = edge.waypoints.items[mid_idx - 1];
            const p2 = edge.waypoints.items[mid_idx];
            const mx = origin_x + (p1.x + p2.x) / 2;
            const my = origin_y + (p1.y + p2.y) / 2 - scroll_y;

            const measured = fonts.measure(label, theme.body_font_size * 0.8, false, false, false);
            rl.drawRectangleRec(.{
                .x = mx - measured.x / 2 - 3,
                .y = my - measured.y / 2 - 2,
                .width = measured.x + 6,
                .height = measured.y + 4,
            }, theme.mermaid_label_bg);
            ru.drawTextCenteredDirect(label, mx - measured.x / 2, my - measured.y / 2, measured.x, fonts, theme.body_font_size * 0.8, theme.mermaid_edge_text);
        }
    }
}

fn drawArrowHead(tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, color: rl.Color) void {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const nx = dx / len;
    const ny = dy / len;
    const sz: f32 = 10;
    const p1 = rl.Vector2{ .x = tip_x - sz * nx + sz * 0.5 * ny, .y = tip_y - sz * ny - sz * 0.5 * nx };
    const p2 = rl.Vector2{ .x = tip_x - sz * nx - sz * 0.5 * ny, .y = tip_y - sz * ny + sz * 0.5 * nx };
    rl.drawTriangle(.{ .x = tip_x, .y = tip_y }, p2, p1, color);
}

fn drawDashedRect(x: f32, y: f32, w: f32, h: f32, color: rl.Color) void {
    ru.drawDashedLine(x, y, x + w, y, 2, color);
    ru.drawDashedLine(x + w, y, x + w, y + h, 2, color);
    ru.drawDashedLine(x + w, y + h, x, y + h, 2, color);
    ru.drawDashedLine(x, y + h, x, y, 2, color);
}

