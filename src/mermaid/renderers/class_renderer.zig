const rl = @import("raylib");
const std = @import("std");
const cm = @import("../models/class_model.zig");
const ClassModel = cm.ClassModel;
const ClassNode = cm.ClassNode;
const Visibility = cm.Visibility;
const RelationshipType = cm.RelationshipType;
const graph_mod = @import("../models/graph.zig");
const Point = graph_mod.Point;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");

pub fn drawClassDiagram(model: *const ClassModel, origin_x: f32, origin_y: f32, diagram_width: f32, diagram_height: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    // Background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    // Draw edges (relationships)
    for (model.graph.edges.items, 0..) |edge, edge_idx| {
        const rel = if (edge_idx < model.relationships.items.len) &model.relationships.items[edge_idx] else null;
        drawRelationship(&edge, rel, origin_x, origin_y, theme, fonts, scroll_y);
    }

    // Draw class boxes
    for (model.classes.items) |*cls| {
        if (model.graph.nodes.get(cls.id)) |gnode| {
            drawClassBox(cls, gnode.x, gnode.y, gnode.width, gnode.height, origin_x, origin_y, theme, fonts, scroll_y);
        }
    }
}

fn drawClassBox(cls: *const ClassNode, nx: f32, ny: f32, nw: f32, nh: f32, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const x = origin_x + nx;
    const y = origin_y + ny;
    const sy = y - scroll_y;
    const font_size = theme.body_font_size * 0.85;
    const line_h: f32 = font_size + 4;
    const section_pad: f32 = 4;

    // Box background
    rl.drawRectangleRec(.{ .x = x, .y = sy, .width = nw, .height = nh }, theme.mermaid_node_fill);
    rl.drawRectangleLinesEx(.{ .x = x, .y = sy, .width = nw, .height = nh }, 2, theme.mermaid_node_border);

    var cur_y: f32 = sy + section_pad;

    // Annotation (<<interface>> etc.)
    if (cls.annotation) |ann| {
        ru.drawTextCenteredDirect(ann, x, cur_y, nw, fonts, font_size * 0.85, theme.mermaid_node_text);
        cur_y += line_h;
    }

    // Class name (centered)
    ru.drawTextCenteredDirect(cls.label, x, cur_y, nw, fonts, font_size, theme.mermaid_node_text);
    cur_y += line_h + section_pad;

    // Divider after header
    rl.drawLineEx(.{ .x = x, .y = cur_y }, .{ .x = x + nw, .y = cur_y }, 1, theme.mermaid_node_border);
    cur_y += section_pad;

    // Attributes (non-method members)
    var has_attrs = false;
    for (cls.members.items) |member| {
        if (!member.is_method) {
            has_attrs = true;
            drawMember(member, x, cur_y, fonts, font_size, theme);
            cur_y += line_h;
        }
    }
    if (!has_attrs) {
        cur_y += line_h; // empty section placeholder
    }

    // Divider before methods
    cur_y += section_pad;
    rl.drawLineEx(.{ .x = x, .y = cur_y }, .{ .x = x + nw, .y = cur_y }, 1, theme.mermaid_node_border);
    cur_y += section_pad;

    // Methods
    for (cls.members.items) |member| {
        if (member.is_method) {
            drawMember(member, x, cur_y, fonts, font_size, theme);
            cur_y += line_h;
        }
    }
}

fn drawMember(member: cm.ClassMember, x: f32, y: f32, fonts: *const Fonts, font_size: f32, theme: *const Theme) void {
    const vis_char: []const u8 = switch (member.visibility) {
        .public => "+",
        .private => "-",
        .protected => "#",
        .package => "~",
        .none => " ",
    };

    // Draw visibility symbol
    ru.drawTextAt(vis_char, x + 4, y, fonts, font_size, theme.mermaid_node_text);

    // Draw member name
    ru.drawTextAt(member.name, x + 16, y, fonts, font_size * 0.9, theme.mermaid_node_text);
}

fn drawRelationship(edge: *const graph_mod.GraphEdge, rel: ?*const cm.ClassRelationship, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    if (edge.waypoints.items.len < 2) return;

    const color = theme.mermaid_edge;
    const rel_type = if (rel) |r| r.rel_type else RelationshipType.association;

    const is_dashed = switch (rel_type) {
        .dependency, .realization, .dashed_link => true,
        else => false,
    };

    // Draw line segments
    var i: usize = 0;
    while (i < edge.waypoints.items.len - 1) : (i += 1) {
        const p1 = edge.waypoints.items[i];
        const p2 = edge.waypoints.items[i + 1];
        if (is_dashed) {
            ru.drawDashedLine(
                origin_x + p1.x,
                origin_y + p1.y - scroll_y,
                origin_x + p2.x,
                origin_y + p2.y - scroll_y,
                1.5,
                color,
            );
        } else {
            rl.drawLineEx(
                .{ .x = origin_x + p1.x, .y = origin_y + p1.y - scroll_y },
                .{ .x = origin_x + p2.x, .y = origin_y + p2.y - scroll_y },
                1.5,
                color,
            );
        }
    }

    // Draw arrowhead at target end
    if (edge.waypoints.items.len >= 2) {
        const last = edge.waypoints.items[edge.waypoints.items.len - 1];
        const prev = edge.waypoints.items[edge.waypoints.items.len - 2];
        const tip_x = origin_x + last.x;
        const tip_y = origin_y + last.y - scroll_y;
        const from_x = origin_x + prev.x;
        const from_y = origin_y + prev.y - scroll_y;

        switch (rel_type) {
            .inheritance, .realization => drawHollowTriangle(tip_x, tip_y, from_x, from_y, color, theme.mermaid_node_fill),
            .composition => drawFilledDiamond(tip_x, tip_y, from_x, from_y, color),
            .aggregation => drawHollowDiamond(tip_x, tip_y, from_x, from_y, color, theme.mermaid_node_fill),
            .association, .dependency => drawFilledArrow(tip_x, tip_y, from_x, from_y, color),
            .link, .dashed_link => {}, // no arrowhead
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
            ru.drawTextCenteredDirect(label, mx - measured.x / 2, my - measured.y / 2, measured.x, fonts, theme.body_font_size * 0.75, theme.mermaid_edge_text);
        }
    }
}

fn drawFilledArrow(tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, color: rl.Color) void {
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

fn drawHollowTriangle(tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, border: rl.Color, fill: rl.Color) void {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const nx = dx / len;
    const ny = dy / len;
    const sz: f32 = 12;
    const p1 = rl.Vector2{ .x = tip_x - sz * nx + sz * 0.5 * ny, .y = tip_y - sz * ny - sz * 0.5 * nx };
    const p2 = rl.Vector2{ .x = tip_x - sz * nx - sz * 0.5 * ny, .y = tip_y - sz * ny + sz * 0.5 * nx };
    const tip = rl.Vector2{ .x = tip_x, .y = tip_y };
    rl.drawTriangle(tip, p2, p1, fill);
    rl.drawLineEx(tip, p1, 2, border);
    rl.drawLineEx(tip, p2, 2, border);
    rl.drawLineEx(p1, p2, 2, border);
}

fn drawFilledDiamond(tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, color: rl.Color) void {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const nx = dx / len;
    const ny = dy / len;
    const sz: f32 = 10;
    const mid_x = tip_x - sz * nx;
    const mid_y = tip_y - sz * ny;
    const p1 = rl.Vector2{ .x = mid_x + sz * 0.4 * ny, .y = mid_y - sz * 0.4 * nx };
    const p2 = rl.Vector2{ .x = mid_x - sz * 0.4 * ny, .y = mid_y + sz * 0.4 * nx };
    const back = rl.Vector2{ .x = tip_x - sz * 2 * nx, .y = tip_y - sz * 2 * ny };
    const tip = rl.Vector2{ .x = tip_x, .y = tip_y };
    rl.drawTriangle(tip, p2, p1, color);
    rl.drawTriangle(back, p1, p2, color);
}

fn drawHollowDiamond(tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, border: rl.Color, fill: rl.Color) void {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const nx = dx / len;
    const ny = dy / len;
    const sz: f32 = 10;
    const mid_x = tip_x - sz * nx;
    const mid_y = tip_y - sz * ny;
    const p1 = rl.Vector2{ .x = mid_x + sz * 0.4 * ny, .y = mid_y - sz * 0.4 * nx };
    const p2 = rl.Vector2{ .x = mid_x - sz * 0.4 * ny, .y = mid_y + sz * 0.4 * nx };
    const back = rl.Vector2{ .x = tip_x - sz * 2 * nx, .y = tip_y - sz * 2 * ny };
    const tip = rl.Vector2{ .x = tip_x, .y = tip_y };
    rl.drawTriangle(tip, p2, p1, fill);
    rl.drawTriangle(back, p1, p2, fill);
    rl.drawLineEx(tip, p1, 2, border);
    rl.drawLineEx(p1, back, 2, border);
    rl.drawLineEx(back, p2, 2, border);
    rl.drawLineEx(p2, tip, 2, border);
}

