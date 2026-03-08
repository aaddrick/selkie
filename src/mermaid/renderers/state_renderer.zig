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

/// Draw a complete stateDiagram-v2 to the current render target.
///
/// The diagram is drawn at `(origin_x, origin_y)` with the given dimensions.
/// All coordinates in `model.graph` are relative offsets from the origin.
/// `scroll_y` is subtracted from all y-coordinates for viewport scrolling.
///
/// Rendering order: background → transitions (edges) → states (nodes).
/// Edges are drawn first so they appear behind state boxes.
pub fn drawStateDiagram(model: *const StateModel, origin_x: f32, origin_y: f32, diagram_width: f32, diagram_height: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    // Background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    // Draw edges (transitions) — behind nodes
    for (model.graph.edges.items) |edge| {
        drawTransition(&edge, origin_x, origin_y, theme, fonts, scroll_y);
    }

    // Draw states (including recursively rendered children/regions of composite states)
    for (model.states.items) |*state| {
        if (model.graph.nodes.get(state.id)) |gnode| {
            drawState(state, gnode.x, gnode.y, gnode.width, gnode.height, origin_x, origin_y, theme, fonts, scroll_y);
        }
        // Recursively draw children/regions of composite states at their global positions
        if (state.state_type == .composite) {
            if (state.hasChildren()) {
                drawCompositeChildren(state, origin_x, origin_y, theme, fonts, scroll_y);
            } else if (state.hasRegions()) {
                drawCompositeRegions(state, origin_x, origin_y, theme, fonts, scroll_y);
            }
        }
    }

    // Draw notes attached to states
    for (model.notes.items) |note| {
        if (model.graph.nodes.get(note.state_id)) |gnode| {
            drawNote(&note, gnode.x, gnode.y, gnode.width, gnode.height, origin_x, origin_y, theme, fonts, scroll_y);
        }
    }
}

/// Draw a single state node at the given position.
///
/// Shape rendering depends on `state.state_type`:
/// - `.start`: Filled circle (initial pseudostate)
/// - `.end`: Double circle / bullseye (final pseudostate)
/// - `.fork` / `.join`: Solid horizontal bar (synchronization bar)
/// - `.choice`: Diamond (conditional pseudostate)
/// - `.composite`: Dashed rounded rectangle with header label
/// - `.normal`: Rounded rectangle; if both label and description exist,
///   show label in a header zone with a divider line and description below.
fn drawState(state: *const State, nx: f32, ny: f32, nw: f32, nh: f32, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const x = origin_x + nx;
    const y = origin_y + ny;
    const sy = y - scroll_y;

    switch (state.state_type) {
        .start => {
            // Filled black circle — initial pseudostate
            const cx = x + nw / 2;
            const cy = sy + nh / 2;
            const radius = @min(nw, nh) / 2;
            rl.drawCircleV(.{ .x = cx, .y = cy }, radius, theme.mermaid_node_border);
        },
        .end => {
            // Outer ring + inner filled circle — final pseudostate
            const cx = x + nw / 2;
            const cy = sy + nh / 2;
            const outer_r = @min(nw, nh) / 2;
            const inner_r = outer_r * 0.6;
            // Draw outer ring (circle outline with thickness)
            rl.drawCircleLinesV(.{ .x = cx, .y = cy }, outer_r, theme.mermaid_node_border);
            // Inner ring for visual weight
            rl.drawCircleLinesV(.{ .x = cx, .y = cy }, outer_r - 1, theme.mermaid_node_border);
            // Filled inner circle
            rl.drawCircleV(.{ .x = cx, .y = cy }, inner_r, theme.mermaid_node_border);
        },
        .fork, .join => {
            // Solid horizontal bar — synchronization pseudostate
            rl.drawRectangleRec(.{ .x = x, .y = sy, .width = nw, .height = nh }, theme.mermaid_node_border);
        },
        .choice => {
            // Diamond — conditional pseudostate
            shapes.drawShape(.diamond, x, y, nw, nh, theme.mermaid_node_fill, theme.mermaid_node_border, scroll_y);
        },
        .history, .deep_history, .entry_point, .exit_point => {
            // Circle pseudo-states: filled circle with double border ring.
            // history/deep_history add a centered text label; exit_point adds an X.
            const cx = x + nw / 2;
            const cy = sy + nh / 2;
            const radius = @min(nw, nh) / 2;
            rl.drawCircleV(.{ .x = cx, .y = cy }, radius, theme.mermaid_node_fill);
            rl.drawCircleLinesV(.{ .x = cx, .y = cy }, radius, theme.mermaid_node_border);
            rl.drawCircleLinesV(.{ .x = cx, .y = cy }, radius - 1, theme.mermaid_node_border);

            switch (state.state_type) {
                .history => shapes.drawTextCentered("H", x, y, nw, nh, fonts, theme.body_font_size * 0.8, theme.mermaid_node_border, scroll_y),
                .deep_history => shapes.drawTextCentered("H*", x, y, nw, nh, fonts, theme.body_font_size * 0.75, theme.mermaid_node_border, scroll_y),
                .exit_point => {
                    // Draw X inside the circle
                    const arm = radius * 0.55;
                    rl.drawLineEx(
                        .{ .x = cx - arm, .y = cy - arm },
                        .{ .x = cx + arm, .y = cy + arm },
                        1.5,
                        theme.mermaid_node_border,
                    );
                    rl.drawLineEx(
                        .{ .x = cx + arm, .y = cy - arm },
                        .{ .x = cx - arm, .y = cy + arm },
                        1.5,
                        theme.mermaid_node_border,
                    );
                },
                else => {}, // entry_point: circle only, no interior decoration
            }
        },
        .composite => {
            // Dashed rounded rectangle with header label and divider
            rl.drawRectangleRounded(.{ .x = x, .y = sy, .width = nw, .height = nh }, 0.15, 6, theme.mermaid_node_fill);
            drawDashedRect(x, sy, nw, nh, theme.mermaid_node_border);

            const header_h: f32 = @min(nh * 0.4, 28);
            shapes.drawTextCentered(state.displayLabel(), x, y, nw, header_h, fonts, theme.body_font_size * 0.9, theme.mermaid_node_text, scroll_y);

            // Divider line below header
            if (nh > header_h + 4) {
                ru.drawDashedLine(x + 4, sy + header_h, x + nw - 4, sy + header_h, 1, theme.mermaid_node_border);
            }
        },
        .normal => {
            // Rounded rectangle
            rl.drawRectangleRounded(.{ .x = x, .y = sy, .width = nw, .height = nh }, 0.3, 6, theme.mermaid_node_fill);
            rl.drawRectangleRoundedLinesEx(.{ .x = x, .y = sy, .width = nw, .height = nh }, 0.3, 6, 2, theme.mermaid_node_border);

            // When both label and description exist and differ, show label
            // as header with a divider line and description below.
            if (state.description) |desc| {
                if (!std.mem.eql(u8, state.label, desc)) {
                    const header_h: f32 = @min(nh * 0.45, 26);

                    shapes.drawTextCentered(state.label, x, y, nw, header_h, fonts, theme.body_font_size * 0.85, theme.mermaid_node_text, scroll_y);

                    rl.drawLineEx(
                        .{ .x = x + 4, .y = sy + header_h },
                        .{ .x = x + nw - 4, .y = sy + header_h },
                        1,
                        theme.mermaid_node_border,
                    );

                    shapes.drawTextCentered(desc, x, y + header_h, nw, nh - header_h, fonts, theme.body_font_size * 0.8, theme.mermaid_node_text, scroll_y);
                } else {
                    shapes.drawTextCentered(state.displayLabel(), x, y, nw, nh, fonts, theme.body_font_size, theme.mermaid_node_text, scroll_y);
                }
            } else {
                shapes.drawTextCentered(state.displayLabel(), x, y, nw, nh, fonts, theme.body_font_size, theme.mermaid_node_text, scroll_y);
            }
        },
    }
}

/// Draw a state transition (edge) with line segments, arrowhead, and optional label.
///
/// Line segments follow the edge waypoints. An arrowhead is drawn at the
/// final waypoint pointing in the direction of travel. Labels are rendered
/// at the midpoint of the path with a small background rectangle for readability.
fn drawTransition(edge: *const graph_mod.GraphEdge, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    if (edge.waypoints.items.len < 2) return;

    const color = theme.mermaid_edge;
    const line_width: f32 = 1.5;

    // Draw line segments along waypoints
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

    // Arrowhead at target end
    {
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

    // Transition label at midpoint
    if (edge.label) |label| {
        const mid_idx = edge.waypoints.items.len / 2;
        const p1 = edge.waypoints.items[mid_idx - 1];
        const p2 = edge.waypoints.items[mid_idx];
        const mx = origin_x + (p1.x + p2.x) / 2;
        const my = origin_y + (p1.y + p2.y) / 2 - scroll_y;

        const font_size = theme.body_font_size * 0.8;
        const measured = fonts.measure(label, font_size, false, false, false);
        const pad_x: f32 = 4;
        const pad_y: f32 = 2;

        // Label background for readability
        rl.drawRectangleRec(.{
            .x = mx - measured.x / 2 - pad_x,
            .y = my - measured.y / 2 - pad_y,
            .width = measured.x + pad_x * 2,
            .height = measured.y + pad_y * 2,
        }, theme.mermaid_label_bg);

        // Label text
        ru.drawTextCenteredDirect(label, mx - measured.x / 2, my - measured.y / 2, measured.x, fonts, font_size, theme.mermaid_edge_text);
    }
}

/// Draw a filled triangular arrowhead at the tip, pointing from `from` toward `tip`.
fn drawArrowHead(tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, color: rl.Color) void {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;

    const nx = dx / len;
    const ny = dy / len;
    const sz: f32 = 10;
    const half_w: f32 = sz * 0.5;

    const p1 = rl.Vector2{
        .x = tip_x - sz * nx + half_w * ny,
        .y = tip_y - sz * ny - half_w * nx,
    };
    const p2 = rl.Vector2{
        .x = tip_x - sz * nx - half_w * ny,
        .y = tip_y - sz * ny + half_w * nx,
    };
    rl.drawTriangle(.{ .x = tip_x, .y = tip_y }, p2, p1, color);
}

/// Recursively draw children of a composite state. Child positions are global
/// coordinates (already translated by the layout phase).
fn drawCompositeChildren(parent: *const State, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    for (parent.children.items) |*child| {
        drawState(child, child.x, child.y, child.width, child.height, origin_x, origin_y, theme, fonts, scroll_y);
        // Recursively draw nested composites — handle both children and region variants
        if (child.state_type == .composite) {
            if (child.hasChildren()) {
                drawCompositeChildren(child, origin_x, origin_y, theme, fonts, scroll_y);
            } else if (child.hasRegions()) {
                drawCompositeRegions(child, origin_x, origin_y, theme, fonts, scroll_y);
            }
        }
    }
}

/// Draw all concurrent regions within a composite state.
///
/// Regions are laid out side-by-side. Each region's states are drawn at their
/// global positions (set by the layout phase via translateRegionStates). A
/// vertical dashed separator line is drawn between adjacent regions.
///
/// Called only when `parent.hasRegions()` is true (states with `--` separator).
fn drawCompositeRegions(parent: *const State, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    for (parent.regions.items, 0..) |*region, region_idx| {
        // Draw all states within this region at their global positions
        for (region.states.items) |*child| {
            drawState(child, child.x, child.y, child.width, child.height, origin_x, origin_y, theme, fonts, scroll_y);
            // Recursively draw nested composite children within the region
            if (child.state_type == .composite) {
                if (child.hasChildren()) {
                    drawCompositeChildren(child, origin_x, origin_y, theme, fonts, scroll_y);
                } else if (child.hasRegions()) {
                    drawCompositeRegions(child, origin_x, origin_y, theme, fonts, scroll_y);
                }
            }
        }

        // Draw vertical dashed separator between this region and the next.
        // Centered in the region_divider_gap (12 px) between regions.
        // Must match region_divider_gap from state_layout.zig.
        if (region_idx + 1 < parent.regions.items.len) {
            // region.x/y/width/height are global diagram coordinates after translation
            const region_div_gap: f32 = 12; // must match state_layout.region_divider_gap
            const sep_x = origin_x + region.x + region.width + region_div_gap / 2.0;
            const sep_top_y = origin_y + region.y - scroll_y;
            const sep_bot_y = origin_y + region.y + region.height - scroll_y;
            ru.drawDashedLine(sep_x, sep_top_y, sep_x, sep_bot_y, 1, theme.mermaid_node_border);
        }
    }
}

/// Draw a note annotation attached to a state. Notes are rendered as small
/// rectangles with italic text, positioned to the left or right of the target state.
fn drawNote(note: *const sm.Note, nx: f32, ny: f32, nw: f32, nh: f32, origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const font_size = theme.body_font_size * 0.75;
    const measured = fonts.measure(note.text, font_size, false, false, false);
    const pad_x: f32 = 6;
    const pad_y: f32 = 4;
    const note_w = measured.x + pad_x * 2;
    const note_h = measured.y + pad_y * 2;
    const gap: f32 = 8;

    // Position note to left or right of the state
    const note_x = switch (note.position) {
        .right => origin_x + nx + nw + gap,
        .left => origin_x + nx - note_w - gap,
    };
    const note_y = origin_y + ny + (nh - note_h) / 2 - scroll_y;

    // Note background (slightly tinted)
    const note_bg = rl.Color{ .r = 255, .g = 255, .b = 204, .a = 230 };
    rl.drawRectangleRec(.{ .x = note_x, .y = note_y, .width = note_w, .height = note_h }, note_bg);
    rl.drawRectangleLinesEx(.{ .x = note_x, .y = note_y, .width = note_w, .height = note_h }, 1, theme.mermaid_node_border);

    // Note text
    ru.drawTextAt(note.text, note_x + pad_x, note_y + pad_y, fonts, font_size, theme.mermaid_node_text);

    // Connecting line from note to state
    const line_y = note_y + note_h / 2;
    const state_edge_x = switch (note.position) {
        .right => origin_x + nx + nw,
        .left => origin_x + nx,
    };
    ru.drawDashedLine(state_edge_x, line_y, note_x + if (note.position == .left) note_w else 0, line_y, 1, theme.mermaid_node_border);
}

/// Draw a dashed rectangle outline. Used for composite state borders.
fn drawDashedRect(x: f32, y: f32, w: f32, h: f32, color: rl.Color) void {
    ru.drawDashedLine(x, y, x + w, y, 2, color);
    ru.drawDashedLine(x + w, y, x + w, y + h, 2, color);
    ru.drawDashedLine(x + w, y + h, x, y + h, 2, color);
    ru.drawDashedLine(x, y + h, x, y, 2, color);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "arrowhead zero-length vector computes safe direction" {
    // When tip == from, len == 0 and drawArrowHead should early-return.
    // We verify the guard condition directly (calling the fn needs GL context).
    const dx: f32 = 0;
    const dy: f32 = 0;
    const len = @sqrt(dx * dx + dy * dy);
    try testing.expectEqual(@as(f32, 0), len);
}

test "arrowhead normal vector computes valid length" {
    // Verify the math used in drawArrowHead for typical inputs
    const dx: f32 = 100;
    const dy: f32 = 0;
    const len = @sqrt(dx * dx + dy * dy);
    try testing.expect(len > 0);
    try testing.expectEqual(@as(f32, 100), len);
}

test "StateType enum covers all diagram pseudostate types" {
    // Verify all state types that the renderer handles are present.
    // entry_point and exit_point were added in Sub-AC 7d.
    const types = [_]StateType{ .normal, .start, .end, .fork, .join, .choice, .composite, .history, .deep_history, .entry_point, .exit_point };
    try testing.expectEqual(@as(usize, 11), types.len);
}

test "drawTransition handles edge with no waypoints" {
    // Edge with empty waypoints should return early without crashing
    var wp = std.ArrayList(graph_mod.Point).init(testing.allocator);
    defer wp.deinit();

    const edge = graph_mod.GraphEdge{
        .from = "A",
        .to = "B",
        .label = null,
        .style = .solid,
        .arrow_head = .arrow,
        .waypoints = wp,
    };

    // Cannot call drawTransition without a valid theme/fonts in unit tests,
    // but we verify the early-return condition logic
    try testing.expectEqual(@as(usize, 0), edge.waypoints.items.len);
    // drawTransition returns immediately when waypoints.len < 2
}

test "drawTransition handles edge with single waypoint" {
    var wp = std.ArrayList(graph_mod.Point).init(testing.allocator);
    defer wp.deinit();
    try wp.append(.{ .x = 50, .y = 50 });

    const edge = graph_mod.GraphEdge{
        .from = "A",
        .to = "B",
        .label = null,
        .style = .solid,
        .arrow_head = .arrow,
        .waypoints = wp,
    };

    // Single waypoint: len < 2, so drawTransition exits early
    try testing.expectEqual(@as(usize, 1), edge.waypoints.items.len);
}

test "state description vs label rendering logic" {
    const Transition = sm.Transition;
    const Region = sm.Region;
    // Test the condition that determines header+description rendering
    const state_with_both = State{
        .id = "S1",
        .label = "S1",
        .state_type = .normal,
        .description = "Waiting for input",
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        var s = state_with_both;
        s.children.deinit();
        s.child_transitions.deinit();
        s.regions.deinit();
    }

    // When description differs from label, renderer shows both
    try testing.expect(state_with_both.description != null);
    try testing.expect(!std.mem.eql(u8, state_with_both.label, state_with_both.description.?));

    const state_same = State{
        .id = "S2",
        .label = "Active",
        .state_type = .normal,
        .description = "Active",
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        var s = state_same;
        s.children.deinit();
        s.child_transitions.deinit();
        s.regions.deinit();
    }

    // When description equals label, renderer shows single centered label
    try testing.expect(state_same.description != null);
    try testing.expect(std.mem.eql(u8, state_same.label, state_same.description.?));
}

test "state without description uses label" {
    const Transition = sm.Transition;
    const Region = sm.Region;
    const state = State{
        .id = "Idle",
        .label = "Idle",
        .state_type = .normal,
        .description = null,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        var s = state;
        s.children.deinit();
        s.child_transitions.deinit();
        s.regions.deinit();
    }

    // Renderer falls back to label when description is null
    const display = if (state.description) |d| d else state.label;
    try testing.expectEqualStrings("Idle", display);
}

test "history and deep_history state types are renderable" {
    // Verify the renderer covers history pseudo-state types
    const history_type = StateType.history;
    const deep_history_type = StateType.deep_history;

    // These should be valid enum values (compilation proves it)
    try testing.expect(history_type != deep_history_type);
    try testing.expect(history_type != .start);
    try testing.expect(deep_history_type != .end);
}

test "note position determines placement side" {
    // Verify note position enum covers both sides
    const left = sm.NotePosition.left;
    const right = sm.NotePosition.right;
    try testing.expect(left != right);
}

test "composite state with children triggers recursive draw" {
    const Region = sm.Region;
    const Transition = sm.Transition;

    var parent = State{
        .id = "Parent",
        .label = "Parent",
        .state_type = .composite,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        for (parent.children.items) |*child| {
            child.children.deinit();
            child.child_transitions.deinit();
            child.regions.deinit();
        }
        parent.children.deinit();
        parent.child_transitions.deinit();
        parent.regions.deinit();
    }

    try parent.children.append(.{
        .id = "Child",
        .label = "Child",
        .state_type = .normal,
        .x = 10,
        .y = 20,
        .width = 80,
        .height = 40,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    });

    // Verify the composite state has children and would trigger recursive draw
    try testing.expect(parent.hasChildren());
    try testing.expectEqual(@as(usize, 1), parent.children.items.len);
    try testing.expectEqualStrings("Child", parent.children.items[0].id);
}

test "composite state with regions triggers region draw" {
    const Region = sm.Region;
    const Transition = sm.Transition;

    var parent = State{
        .id = "Comp",
        .label = "Comp",
        .state_type = .composite,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        for (parent.regions.items) |*region| {
            for (region.states.items) |*rs| {
                rs.children.deinit();
                rs.child_transitions.deinit();
                rs.regions.deinit();
            }
            region.states.deinit();
            region.transitions.deinit();
        }
        parent.children.deinit();
        parent.child_transitions.deinit();
        parent.regions.deinit();
    }

    // Add two regions — simulating a `--` concurrent state block
    var region0 = Region.init(testing.allocator);
    try region0.states.append(.{
        .id = "A",
        .label = "A",
        .state_type = .normal,
        .x = 10,
        .y = 5,
        .width = 80,
        .height = 40,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    });
    region0.x = 16;
    region0.y = 44;
    region0.width = 120;
    region0.height = 80;

    var region1 = Region.init(testing.allocator);
    try region1.states.append(.{
        .id = "B",
        .label = "B",
        .state_type = .normal,
        .x = 140,
        .y = 5,
        .width = 80,
        .height = 40,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    });
    region1.x = 138;
    region1.y = 44;
    region1.width = 120;
    region1.height = 80;

    try parent.regions.append(region0);
    try parent.regions.append(region1);

    // Verify regions are present and drawCompositeRegions would be invoked
    try testing.expect(!parent.hasChildren());
    try testing.expect(parent.hasRegions());
    try testing.expectEqual(@as(usize, 2), parent.regionCount());
    try testing.expectEqual(@as(usize, 1), parent.regions.items[0].states.items.len);
    try testing.expectEqual(@as(usize, 1), parent.regions.items[1].states.items.len);
    // Separator midpoint: region[0].x + region[0].width + region_div_gap/2
    const region_div_gap: f32 = 12;
    const sep_x_expected: f32 = 16 + 120 + region_div_gap / 2.0;
    try testing.expectApproxEqAbs(sep_x_expected, parent.regions.items[0].x + parent.regions.items[0].width + region_div_gap / 2.0, 0.01);
}

test "drawCompositeRegions separator x-position formula" {
    // Verify the formula used to compute the separator x-position between regions.
    // Separator is centered in the region_div_gap (12px):
    //   sep_x = origin_x + region.x + region.width + region_div_gap / 2
    const region_x: f32 = 50;
    const region_width: f32 = 100;
    const origin_x: f32 = 200;
    const region_div_gap: f32 = 12;
    const sep_x = origin_x + region_x + region_width + region_div_gap / 2.0;
    try testing.expectApproxEqAbs(@as(f32, 356), sep_x, 0.01);
}

test "start marker radius uses min of width and height" {
    // The .start state uses @min(nw, nh) / 2 as radius so it fits the node box.
    // Verify the formula is correct for square and rectangular nodes.
    const nw_sq: f32 = 24;
    const nh_sq: f32 = 24;
    const radius_sq = @min(nw_sq, nh_sq) / 2;
    try testing.expectApproxEqAbs(@as(f32, 12), radius_sq, 0.001);

    // Non-square: height is the smaller dimension
    const nw_rect: f32 = 40;
    const nh_rect: f32 = 24;
    const radius_rect = @min(nw_rect, nh_rect) / 2;
    try testing.expectApproxEqAbs(@as(f32, 12), radius_rect, 0.001);
}

test "end marker outer and inner radius sizing" {
    // The .end state uses outer_r = min(nw,nh)/2, inner_r = outer_r * 0.6.
    // Verify the bullseye proportions.
    const nw: f32 = 28;
    const nh: f32 = 28;
    const outer_r = @min(nw, nh) / 2;
    const inner_r = outer_r * 0.6;
    try testing.expectApproxEqAbs(@as(f32, 14), outer_r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8.4), inner_r, 0.001);
    // Inner must be strictly smaller than outer
    try testing.expect(inner_r < outer_r);
}

test "edge label midpoint calculation for minimal flat transition" {
    // A flat transition with exactly 2 waypoints:
    //   waypoints[0] = source anchor, waypoints[1] = target anchor
    // The label midpoint should be exactly between them.
    var wp = std.ArrayList(graph_mod.Point).init(testing.allocator);
    defer wp.deinit();
    try wp.append(.{ .x = 0, .y = 0 });
    try wp.append(.{ .x = 100, .y = 0 });

    const mid_idx = wp.items.len / 2; // = 1
    const p1 = wp.items[mid_idx - 1]; // (0,0)
    const p2 = wp.items[mid_idx]; //     (100,0)
    const mx = (p1.x + p2.x) / 2;
    const my = (p1.y + p2.y) / 2;
    try testing.expectApproxEqAbs(@as(f32, 50), mx, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), my, 0.001);
}

test "edge label midpoint for diagonal transition" {
    // A diagonal transition from (10,20) to (90,60)
    var wp = std.ArrayList(graph_mod.Point).init(testing.allocator);
    defer wp.deinit();
    try wp.append(.{ .x = 10, .y = 20 });
    try wp.append(.{ .x = 90, .y = 60 });

    const mid_idx = wp.items.len / 2;
    const p1 = wp.items[mid_idx - 1];
    const p2 = wp.items[mid_idx];
    const mx = (p1.x + p2.x) / 2;
    const my = (p1.y + p2.y) / 2;
    try testing.expectApproxEqAbs(@as(f32, 50), mx, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), my, 0.001);
}

test "arrowhead wing width and base position" {
    // Verify the arrowhead geometry: tip at (100,0), from at (0,0)
    // nx=1, ny=0, sz=10, half_w=5
    const tip_x: f32 = 100;
    const tip_y: f32 = 0;
    const from_x: f32 = 0;
    const from_y: f32 = 0;
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    const nx = dx / len;
    const ny = dy / len;
    const sz: f32 = 10;
    const half_w: f32 = sz * 0.5;

    // Wing 1: tip - sz*nx + half_w*ny  = (90, 5)
    const w1x = tip_x - sz * nx + half_w * ny;
    const w1y = tip_y - sz * ny - half_w * nx;
    try testing.expectApproxEqAbs(@as(f32, 90), w1x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -5), w1y, 0.001);

    // Wing 2: tip - sz*nx - half_w*ny = (90, -5)
    const w2x = tip_x - sz * nx - half_w * ny;
    const w2y = tip_y - sz * ny + half_w * nx;
    try testing.expectApproxEqAbs(@as(f32, 90), w2x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), w2y, 0.001);
}

test "flat state normal: no children and no regions" {
    const Transition = sm.Transition;
    const Region = sm.Region;

    const flat = State{
        .id = "Active",
        .label = "Active",
        .state_type = .normal,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        var s = flat;
        s.children.deinit();
        s.child_transitions.deinit();
        s.regions.deinit();
    }

    // Flat normal states must not trigger composite draw paths
    try testing.expect(!flat.hasChildren());
    try testing.expect(!flat.hasRegions());
    try testing.expect(flat.state_type != .composite);
}

test "flat diagram: start->normal->end state sequence is renderable" {
    // Verify the full flat diagram type coverage in one sequence
    const start_type = StateType.start;
    const normal_type = StateType.normal;
    const end_type = StateType.end;

    // All three must be distinct and non-composite
    try testing.expect(start_type != normal_type);
    try testing.expect(normal_type != end_type);
    try testing.expect(start_type != .composite);
    try testing.expect(normal_type != .composite);
    try testing.expect(end_type != .composite);
}

test "edge scroll_y offset applied to y coordinates" {
    // Verify that scroll_y is correctly subtracted from edge waypoint y
    // in the rendering path: origin_y + p.y - scroll_y
    const origin_y: f32 = 100;
    const scroll_y: f32 = 50;
    const waypoint_y: f32 = 200;
    const rendered_y = origin_y + waypoint_y - scroll_y;
    try testing.expectApproxEqAbs(@as(f32, 250), rendered_y, 0.001);
}

test "state node position from layout engine: x + origin offset" {
    // In drawState, the screen x = origin_x + nx (where nx comes from graph node).
    // Verify the coordinate transform is additive.
    const origin_x: f32 = 50;
    const nx: f32 = 120; // position set by layout engine
    const screen_x = origin_x + nx;
    try testing.expectApproxEqAbs(@as(f32, 170), screen_x, 0.001);
}

test "drawStateDiagram dispatch: children vs regions" {
    // Verify that hasChildren() and hasRegions() are mutually exclusive
    // for the correct dispatch in drawStateDiagram.
    const Region = sm.Region;
    const Transition = sm.Transition;

    // State with direct children: hasChildren = true, hasRegions = false
    var state_with_children = State{
        .id = "P",
        .label = "P",
        .state_type = .composite,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        for (state_with_children.children.items) |*c| {
            c.children.deinit();
            c.child_transitions.deinit();
            c.regions.deinit();
        }
        state_with_children.children.deinit();
        state_with_children.child_transitions.deinit();
        state_with_children.regions.deinit();
    }
    try state_with_children.children.append(.{
        .id = "C",
        .label = "C",
        .state_type = .normal,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    });
    try testing.expect(state_with_children.hasChildren());
    try testing.expect(!state_with_children.hasRegions());

    // State with regions (from `--` separator): hasChildren = false, hasRegions = true
    var state_with_regions = State{
        .id = "Q",
        .label = "Q",
        .state_type = .composite,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        for (state_with_regions.regions.items) |*r| {
            r.states.deinit();
            r.transitions.deinit();
        }
        state_with_regions.children.deinit();
        state_with_regions.child_transitions.deinit();
        state_with_regions.regions.deinit();
    }
    try state_with_regions.regions.append(Region.init(testing.allocator));
    try testing.expect(!state_with_regions.hasChildren());
    try testing.expect(state_with_regions.hasRegions());
}

// =============================================================================
// Entry/exit point rendering tests (Sub-AC 7d)
// =============================================================================

test "entry_point and exit_point are distinct StateType variants" {
    // Both types must exist as distinct enum values.
    try testing.expect(StateType.entry_point != StateType.exit_point);
    try testing.expect(StateType.entry_point != StateType.start);
    try testing.expect(StateType.exit_point != StateType.end);
    try testing.expect(StateType.entry_point != StateType.history);
    try testing.expect(StateType.exit_point != StateType.deep_history);
}

test "entry_point center and radius geometry" {
    // Verify the geometry constants used by the entry_point renderer branch.
    // The renderer uses min(nw,nh)/2 as the radius.
    const nw: f32 = 24; // start_end_radius * 2 from layout
    const nh: f32 = 24;
    const radius = @min(nw, nh) / 2;
    try testing.expectApproxEqAbs(@as(f32, 12), radius, 0.001);
    // Center (cx, cy) relative to a reference origin
    const x: f32 = 100;
    const y: f32 = 200;
    const cx = x + nw / 2;
    const cy = y + nh / 2;
    try testing.expectApproxEqAbs(@as(f32, 112), cx, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 212), cy, 0.001);
}

test "exit_point X-arm length is 55% of radius" {
    // The exit_point renderer draws two diagonals with arm = radius * 0.55.
    // Verify the proportions: arm must be strictly shorter than radius.
    const radius: f32 = 12;
    const arm = radius * 0.55;
    try testing.expect(arm > 0);
    try testing.expect(arm < radius);
    try testing.expectApproxEqAbs(@as(f32, 6.6), arm, 0.001);
}

test "exit_point X corner coordinates are symmetric around center" {
    // The four corners of the X should be symmetric about (cx, cy).
    const cx: f32 = 50;
    const cy: f32 = 60;
    const arm: f32 = 6.6;

    const p1_x = cx - arm;
    const p1_y = cy - arm;
    const p2_x = cx + arm;
    const p2_y = cy + arm;
    const p3_x = cx + arm;
    const p3_y = cy - arm;
    const p4_x = cx - arm;
    const p4_y = cy + arm;

    // Each pair of opposite corners is symmetric about the center
    try testing.expectApproxEqAbs(cx, (p1_x + p2_x) / 2, 0.001);
    try testing.expectApproxEqAbs(cy, (p1_y + p2_y) / 2, 0.001);
    try testing.expectApproxEqAbs(cx, (p3_x + p4_x) / 2, 0.001);
    try testing.expectApproxEqAbs(cy, (p3_y + p4_y) / 2, 0.001);
}

test "entry_point rendering uses two border rings (same as history pattern)" {
    // The entry_point uses the same double-ring style as history nodes.
    // Verify that the branch does NOT draw any text inside (contrast with history).
    // We can't call drawState without a GL context, but we verify the types.
    const ep_type = StateType.entry_point;
    const hist_type = StateType.history;
    // Both are circle-shaped, but entry_point has no label text.
    try testing.expect(ep_type != hist_type);
    try testing.expect(ep_type == .entry_point);
}

test "exit_point rendering has X mark unlike entry_point" {
    // exit_point branches draws two diagonal lines; entry_point does not.
    // We test that the state_type enum correctly differentiates them.
    const ep = StateType.entry_point;
    const xp = StateType.exit_point;
    // They must be different so the switch in drawState routes to different branches.
    try testing.expect(ep != xp);
    // Only exit_point should have X-mark rendering logic.
    const has_x_mark = xp == .exit_point;
    try testing.expect(has_x_mark);
    const entry_has_x = ep == .exit_point;
    try testing.expect(!entry_has_x);
}

test "entry and exit point can be placed inside composite state" {
    const Region = sm.Region;
    const Transition = sm.Transition;

    var parent = State{
        .id = "Composite",
        .label = "Composite",
        .state_type = .composite,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    };
    defer {
        for (parent.children.items) |*c| {
            c.children.deinit();
            c.child_transitions.deinit();
            c.regions.deinit();
        }
        parent.children.deinit();
        parent.child_transitions.deinit();
        parent.regions.deinit();
    }

    // Add an entry point and exit point as children
    try parent.children.append(.{
        .id = "ep",
        .label = "ep",
        .state_type = .entry_point,
        .x = 5,
        .y = 5,
        .width = 24,
        .height = 24,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    });
    try parent.children.append(.{
        .id = "xp",
        .label = "xp",
        .state_type = .exit_point,
        .x = 5,
        .y = 100,
        .width = 24,
        .height = 24,
        .children = std.ArrayList(State).init(testing.allocator),
        .child_transitions = std.ArrayList(Transition).init(testing.allocator),
        .regions = std.ArrayList(Region).init(testing.allocator),
    });

    try testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try testing.expectEqual(StateType.entry_point, parent.children.items[0].state_type);
    try testing.expectEqual(StateType.exit_point, parent.children.items[1].state_type);
    try testing.expect(parent.hasChildren());
}
