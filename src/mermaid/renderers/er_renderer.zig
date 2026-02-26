const rl = @import("raylib");
const std = @import("std");
const em = @import("../models/er_model.zig");
const ERModel = em.ERModel;
const EREntity = em.EREntity;
const Cardinality = em.Cardinality;
const graph_mod = @import("../models/graph.zig");
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const shapes = @import("shapes.zig");

pub fn drawERDiagram(model: *const ERModel, origin_x: f32, origin_y: f32, diagram_width: f32, diagram_height: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    // Background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    // Draw edges (relationships) first
    for (model.graph.edges.items, 0..) |edge, edge_idx| {
        const rel = if (edge_idx < model.relationships.items.len) &model.relationships.items[edge_idx] else null;
        drawRelationship(&edge, rel, origin_x, origin_y, theme, fonts, scroll_y);
    }

    // Draw entity boxes
    for (model.entities.items) |*entity| {
        if (model.graph.nodes.get(entity.name)) |gnode| {
            drawEntityBox(entity, gnode.x, gnode.y, gnode.width, gnode.height, origin_x, origin_y, theme, fonts, scroll_y);
        }
    }
}

fn drawEntityBox(entity: *const EREntity, nx: f32, ny: f32, nw: f32, nh: f32, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const x = origin_x + nx;
    const y = origin_y + ny;
    const sy = y - scroll_y;
    const font_size = theme.body_font_size * 0.85;
    const header_h: f32 = font_size + 10;
    const row_h: f32 = font_size + 6;

    // Box background
    rl.drawRectangleRec(.{ .x = x, .y = sy, .width = nw, .height = nh }, theme.mermaid_node_fill);
    rl.drawRectangleLinesEx(.{ .x = x, .y = sy, .width = nw, .height = nh }, 2, theme.mermaid_node_border);

    // Header with entity name
    rl.drawRectangleRec(.{ .x = x, .y = sy, .width = nw, .height = header_h }, theme.mermaid_node_border);
    drawTextCenteredDirect(entity.name, x, sy + 3, nw, fonts, font_size, theme.mermaid_node_fill);

    // Divider
    rl.drawLineEx(.{ .x = x, .y = sy + header_h }, .{ .x = x + nw, .y = sy + header_h }, 1, theme.mermaid_node_border);

    // Attribute rows
    var cur_y: f32 = sy + header_h + 2;
    for (entity.attributes.items) |attr| {
        // Key type badge
        if (attr.key_type) |kt| {
            drawTextAt(kt, x + 4, cur_y + 1, fonts, font_size * 0.75, theme.mermaid_edge_text);
        }

        // Type + name
        const type_x: f32 = x + 30;
        drawTextAt(attr.attr_type, type_x, cur_y + 1, fonts, font_size * 0.8, theme.mermaid_node_text);

        const type_measured = fonts.measure(attr.attr_type, font_size * 0.8, false, false, false);
        drawTextAt(attr.name, type_x + type_measured.x + 6, cur_y + 1, fonts, font_size * 0.8, theme.mermaid_node_text);

        cur_y += row_h;
    }
}

fn drawRelationship(edge: *const graph_mod.GraphEdge, rel: ?*const em.ERRelationship, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
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

    // Draw crow's foot notation at both ends
    if (rel) |r| {
        if (edge.waypoints.items.len >= 2) {
            // From end (first waypoint)
            const first = edge.waypoints.items[0];
            const second = edge.waypoints.items[1];
            drawCrowsFoot(
                r.from_cardinality,
                origin_x + first.x,
                origin_y + first.y - scroll_y,
                origin_x + second.x,
                origin_y + second.y - scroll_y,
                color,
            );

            // To end (last waypoint)
            const last = edge.waypoints.items[edge.waypoints.items.len - 1];
            const prev = edge.waypoints.items[edge.waypoints.items.len - 2];
            drawCrowsFoot(
                r.to_cardinality,
                origin_x + last.x,
                origin_y + last.y - scroll_y,
                origin_x + prev.x,
                origin_y + prev.y - scroll_y,
                color,
            );
        }
    }

    // Draw label
    if (edge.label) |label| {
        if (edge.waypoints.items.len >= 2) {
            const mid_idx = edge.waypoints.items.len / 2;
            const p1 = edge.waypoints.items[mid_idx - 1];
            const p2 = edge.waypoints.items[mid_idx];
            const mx = origin_x + (p1.x + p2.x) / 2;
            const my = origin_y + (p1.y + p2.y) / 2 - scroll_y;

            const measured = fonts.measure(label, theme.body_font_size * 0.75, false, false, false);
            rl.drawRectangleRec(.{
                .x = mx - measured.x / 2 - 3,
                .y = my - measured.y / 2 - 2,
                .width = measured.x + 6,
                .height = measured.y + 4,
            }, theme.mermaid_label_bg);
            drawTextCenteredDirect(label, mx - measured.x / 2, my - measured.y / 2, measured.x, fonts, theme.body_font_size * 0.75, theme.mermaid_edge_text);
        }
    }
}

fn drawCrowsFoot(card: Cardinality, tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, color: rl.Color) void {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const nx = dx / len;
    const ny = dy / len;
    const sz: f32 = 12;

    switch (card) {
        .exactly_one => {
            // Two short perpendicular lines (||)
            const px = tip_x - sz * 0.3 * nx;
            const py = tip_y - sz * 0.3 * ny;
            rl.drawLineEx(
                .{ .x = px + sz * 0.4 * ny, .y = py - sz * 0.4 * nx },
                .{ .x = px - sz * 0.4 * ny, .y = py + sz * 0.4 * nx },
                2,
                color,
            );
            const px2 = tip_x - sz * 0.6 * nx;
            const py2 = tip_y - sz * 0.6 * ny;
            rl.drawLineEx(
                .{ .x = px2 + sz * 0.4 * ny, .y = py2 - sz * 0.4 * nx },
                .{ .x = px2 - sz * 0.4 * ny, .y = py2 + sz * 0.4 * nx },
                2,
                color,
            );
        },
        .zero_or_one => {
            // One line + circle
            const px = tip_x - sz * 0.3 * nx;
            const py = tip_y - sz * 0.3 * ny;
            rl.drawLineEx(
                .{ .x = px + sz * 0.4 * ny, .y = py - sz * 0.4 * nx },
                .{ .x = px - sz * 0.4 * ny, .y = py + sz * 0.4 * nx },
                2,
                color,
            );
            rl.drawCircleLinesV(.{ .x = tip_x - sz * 0.7 * nx, .y = tip_y - sz * 0.7 * ny }, 4, color);
        },
        .one_or_more => {
            // One line + crow's foot (three lines fanning out)
            const px = tip_x - sz * 0.6 * nx;
            const py = tip_y - sz * 0.6 * ny;
            rl.drawLineEx(
                .{ .x = px + sz * 0.4 * ny, .y = py - sz * 0.4 * nx },
                .{ .x = px - sz * 0.4 * ny, .y = py + sz * 0.4 * nx },
                2,
                color,
            );
            // Fan lines from tip to spread points
            rl.drawLineEx(.{ .x = tip_x, .y = tip_y }, .{ .x = px + sz * 0.5 * ny, .y = py - sz * 0.5 * nx }, 1.5, color);
            rl.drawLineEx(.{ .x = tip_x, .y = tip_y }, .{ .x = px - sz * 0.5 * ny, .y = py + sz * 0.5 * nx }, 1.5, color);
        },
        .zero_or_more => {
            // Circle + crow's foot
            const base_x = tip_x - sz * 0.8 * nx;
            const base_y = tip_y - sz * 0.8 * ny;
            rl.drawCircleLinesV(.{ .x = base_x, .y = base_y }, 4, color);
            // Fan lines
            const px = tip_x - sz * 0.4 * nx;
            const py = tip_y - sz * 0.4 * ny;
            rl.drawLineEx(.{ .x = tip_x, .y = tip_y }, .{ .x = px + sz * 0.5 * ny, .y = py - sz * 0.5 * nx }, 1.5, color);
            rl.drawLineEx(.{ .x = tip_x, .y = tip_y }, .{ .x = px - sz * 0.5 * ny, .y = py + sz * 0.5 * nx }, 1.5, color);
        },
    }
}

fn drawTextAt(text: []const u8, x: f32, y: f32, fonts: *const Fonts, font_size: f32, color: rl.Color) void {
    if (text.len == 0) return;
    const font = fonts.selectFont(.{});
    const spacing = font_size / 10.0;
    var buf: [512]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];
    rl.drawTextEx(font, z, .{ .x = x, .y = y }, font_size, spacing, color);
}

fn drawTextCenteredDirect(text: []const u8, x: f32, y: f32, w: f32, fonts: *const Fonts, font_size: f32, color: rl.Color) void {
    if (text.len == 0) return;
    const measured = fonts.measure(text, font_size, false, false, false);
    const tx = x + (w - measured.x) / 2;
    drawTextAt(text, tx, y, fonts, font_size, color);
}
