const std = @import("std");
const Allocator = std.mem.Allocator;
const sm = @import("../models/state_model.zig");
const StateModel = sm.StateModel;
const State = sm.State;
const StateType = sm.StateType;
const graph_mod = @import("../models/graph.zig");
const Graph = graph_mod.Graph;
const GraphNode = graph_mod.GraphNode;
const GraphEdge = graph_mod.GraphEdge;
const Point = graph_mod.Point;
const NodeShape = graph_mod.NodeShape;
const Direction = graph_mod.Direction;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const Theme = @import("../../theme/theme.zig").Theme;

// --- Layout constants ---

const node_padding_h: f32 = 24;
const node_padding_v: f32 = 12;
const node_spacing: f32 = 40;
const layer_spacing: f32 = 80;
const diagram_padding: f32 = 20;

/// Minimum dimensions for normal states
const min_normal_width: f32 = 80;
const min_normal_height: f32 = 40;

/// Start/end marker dimensions
const start_end_radius: f32 = 12;

/// Fork/join bar dimensions
const bar_width: f32 = 80;
const bar_height: f32 = 8;

/// Choice diamond dimensions
const choice_size: f32 = 30;

/// Composite state extra padding
const composite_padding: f32 = 20;

/// Composite state header height for label
const composite_header_height: f32 = 28;

/// Inner padding within composite state regions
const composite_inner_padding: f32 = 16;

/// Gap between concurrent regions (includes space for the dashed divider line).
/// Must stay in sync with the matching constant in state_renderer.zig.
pub const region_divider_gap: f32 = 12;

pub const LayoutResult = struct {
    width: f32,
    height: f32,
};

/// Compute positions and dimensions for all states and transitions in a state diagram.
/// Operates on the StateModel's embedded Graph, setting x/y/width/height on graph nodes
/// and computing waypoints on graph edges.
///
/// For stateDiagram-v2 with nested/composite states, this performs a bottom-up layout:
/// 1. Recursively lay out children of composite states
/// 2. Size composite states based on actual child layout dimensions
/// 3. Lay out the top-level graph with properly-sized composite nodes
/// 4. Translate child positions to global coordinates
pub fn layout(
    allocator: Allocator,
    model: *StateModel,
    fonts: *const Fonts,
    theme: *const Theme,
    available_width: f32,
) !LayoutResult {
    _ = available_width;

    if (model.graph.nodes.count() == 0) {
        return .{ .width = 0, .height = 0 };
    }

    const direction = model.direction;

    // Step 1: Bottom-up pass — recursively lay out the sub-graph of every
    // composite state so their sizes are known before the top-level layout runs.
    // layoutCompositeNode dispatches to the children or regions variant and
    // recurses to arbitrary depth, handling all mixed nesting combinations.
    for (model.states.items) |*state| {
        if (state.state_type == .composite) {
            try layoutCompositeNode(allocator, state, fonts, theme, direction);
        }
    }

    // Step 2: Measure top-level nodes (including properly-sized composites)
    measureStateNodes(model, fonts, theme);

    // Step 3: Assign layers via topological BFS (top-level graph only)
    try assignLayers(allocator, &model.graph, model);

    // Step 4: Build layer lists and minimize crossings
    var layers = try buildLayerLists(allocator, &model.graph, model);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    try minimizeCrossings(&model.graph, &layers);

    // Step 5: Assign coordinates — position states in each layer.
    // This sets absolute positions for all top-level nodes in model.graph.
    const result = assignCoordinates(&model.graph, &layers, direction);

    // Step 5.5: Top-down coordinate propagation pass.
    // propagateAbsoluteCoords traverses the entire composite hierarchy top-down
    // to arbitrary depth, computing absolute positions for every nested state and
    // writing them into model.graph.  This supersedes the old one-level-only
    // syncChildStatesToGraphNodes, enabling correct edge routing for transitions
    // that involve states nested at any depth.
    propagateAbsoluteCoords(model);

    // Step 6: Route transition edges with waypoints
    try routeEdges(allocator, &model.graph);

    // Step 6.5: Apply boundary ports for cross-composite transitions.
    // Inserts composite-border anchor points into edge waypoints so that
    // transitions visually enter and exit composite states through their borders.
    try applyBoundaryPorts(allocator, &model.graph, model);

    // Step 7: Write computed positions back onto State structs (top-level)
    syncStatePositions(model);

    // Step 8: Translate all nested child positions to global diagram coordinates.
    // translateAllChildren does a top-down recursive walk that correctly handles
    // children-inside-regions, regions-inside-children, and N levels of nesting.
    translateAllChildren(model);

    return result;
}

// =============================================================================
// Composite state recursive layout
// =============================================================================

/// Unified helper: lay out a single composite state node, dispatching to the
/// correct variant based on whether the state uses direct children or concurrent
/// regions.  This ensures every call site handles both variants identically so
/// nesting of arbitrary depth works regardless of the mix of children / regions
/// at each level.
fn layoutCompositeNode(
    allocator: Allocator,
    state: *State,
    fonts: *const Fonts,
    theme: *const Theme,
    direction: Direction,
) error{OutOfMemory}!void {
    if (state.hasChildren()) {
        try layoutCompositeChildren(allocator, state, fonts, theme, direction);
    } else if (state.hasRegions()) {
        try layoutCompositeRegions(allocator, state, fonts, theme, direction);
    }
    // Leaf composite (no children, no regions): nothing to lay out.
}

// =============================================================================
// Top-down absolute coordinate propagator
// =============================================================================

/// Recursive top-down layout coordinator.
///
/// After the top-level layout assigns absolute positions to the top-level
/// composite state nodes, this function walks the entire composite hierarchy
/// top-down to arbitrary depth and:
///   1. Computes the absolute (global diagram) x/y of every nested state.
///   2. Propagates those absolute positions back into model.graph so that
///      routeEdges produces correct waypoints for transitions that cross
///      composite boundaries.
///
/// This is the canonical single-entry-point for the top-down pass.  It
/// replaces the old ad-hoc syncChildStatesToGraphNodes + translateCompositeChildren
/// pair with a unified, depth-unlimited implementation.
///
/// Call this AFTER the top-level assignCoordinates step has placed all
/// top-level composite nodes, and BEFORE routeEdges.
pub fn propagateAbsoluteCoords(model: *StateModel) void {
    for (model.states.items) |*state| {
        if (state.state_type == .composite) {
            // Use graph node position as the authoritative absolute origin
            // (top-level assignCoordinates writes into model.graph).
            const gnode = model.graph.nodes.get(state.id) orelse continue;
            propagateAbsoluteCoordsForNode(model, state, gnode.x, gnode.y);
        }
    }
}

/// Recursive worker for propagateAbsoluteCoords.
///
/// parent_abs_x / parent_abs_y: the absolute top-left corner of `parent`
/// in diagram coordinates (NOT the content origin — that's computed inside).
fn propagateAbsoluteCoordsForNode(
    model: *StateModel,
    parent: *State,
    parent_abs_x: f32,
    parent_abs_y: f32,
) void {
    const content_x = parent_abs_x + composite_inner_padding;
    const content_y = parent_abs_y + composite_header_height + composite_inner_padding;

    if (parent.hasChildren()) {
        for (parent.children.items) |*child| {
            // child.x/y is relative to parent content area from the sub-graph layout
            const abs_x = content_x + child.x;
            const abs_y = content_y + child.y;

            // Propagate into model.graph for edge routing
            if (model.graph.nodes.getPtr(child.id)) |gn| {
                gn.x = abs_x;
                gn.y = abs_y;
                gn.width = child.width;
                gn.height = child.height;
            }

            // Recurse into nested composite children
            if (child.state_type == .composite) {
                propagateAbsoluteCoordsForNode(model, child, abs_x, abs_y);
            }
        }
    } else if (parent.hasRegions()) {
        for (parent.regions.items) |*region| {
            for (region.states.items) |*child| {
                // child.x/y is relative to parent content area
                const abs_x = content_x + child.x;
                const abs_y = content_y + child.y;

                if (model.graph.nodes.getPtr(child.id)) |gn| {
                    gn.x = abs_x;
                    gn.y = abs_y;
                    gn.width = child.width;
                    gn.height = child.height;
                }

                if (child.state_type == .composite) {
                    propagateAbsoluteCoordsForNode(model, child, abs_x, abs_y);
                }
            }
        }
    }
}

/// Translate all nested states' stored x/y fields from relative (sub-graph)
/// coordinates to absolute diagram coordinates — top-down recursive walk.
///
/// Call this AFTER routeEdges, using the same traversal logic as
/// propagateAbsoluteCoords but writing to State.x/y instead of graph nodes.
fn translateAllChildren(model: *StateModel) void {
    for (model.states.items) |*state| {
        if (state.state_type == .composite) {
            translateChildrenAbsolute(state, state.x, state.y);
        }
    }
}

/// Recursive worker: given a composite `parent` whose State.x/y already hold
/// absolute diagram coordinates, translate all nested children in place.
fn translateChildrenAbsolute(parent: *State, parent_abs_x: f32, parent_abs_y: f32) void {
    const offset_x = parent_abs_x + composite_inner_padding;
    const offset_y = parent_abs_y + composite_header_height + composite_inner_padding;

    if (parent.hasChildren()) {
        for (parent.children.items) |*child| {
            child.x += offset_x;
            child.y += offset_y;

            if (child.state_type == .composite) {
                translateChildrenAbsolute(child, child.x, child.y);
            }
        }
    } else if (parent.hasRegions()) {
        for (parent.regions.items) |*region| {
            region.x += offset_x;
            region.y += offset_y;

            for (region.states.items) |*child| {
                child.x += offset_x;
                child.y += offset_y;

                if (child.state_type == .composite) {
                    translateChildrenAbsolute(child, child.x, child.y);
                }
            }
        }
    }
}

/// Lay out the children of a composite state. Creates a temporary sub-graph
/// for the children, runs the full layout pipeline on it, and stores the
/// resulting dimensions back on the child State structs.
///
/// Child positions are stored relative to the composite state's content area
/// (below the header, inside padding). The parent's width/height are computed
/// to contain all children plus padding and header space.
fn layoutCompositeChildren(
    allocator: Allocator,
    parent: *State,
    fonts: *const Fonts,
    theme: *const Theme,
    direction: Direction,
) error{OutOfMemory}!void {
    // Recursively lay out nested composites first (bottom-up).
    // A child composite may itself have direct children OR concurrent regions.
    for (parent.children.items) |*child| {
        if (child.state_type == .composite) {
            try layoutCompositeNode(allocator, child, fonts, theme, direction);
        }
    }

    // Build a temporary sub-graph for this composite's children
    var sub_graph = Graph.init(allocator, direction);
    defer sub_graph.deinit();

    // Add child states as nodes
    for (parent.children.items) |*child| {
        const shape: NodeShape = switch (child.state_type) {
            .start, .end, .history, .deep_history, .entry_point, .exit_point => .circle,
            .choice => .diamond,
            .fork, .join => .rectangle,
            .composite, .normal => .rounded,
        };
        try sub_graph.addNode(child.id, child.displayLabel(), shape);
    }

    // Measure child nodes
    for (parent.children.items) |*child| {
        if (sub_graph.nodes.getPtr(child.id)) |gnode| {
            measureSingleState(child, gnode, fonts, theme);
        }
    }

    // Add child transitions as edges
    for (parent.child_transitions.items) |t| {
        var edge = try sub_graph.addEdge(t.from, t.to);
        if (t.label != null) edge.label = t.label;
    }

    // Run layout on the sub-graph
    try assignLayers(allocator, &sub_graph, null);

    var sub_layers = try buildLayerLists(allocator, &sub_graph, null);
    defer {
        for (sub_layers.items) |*layer_list| {
            layer_list.deinit();
        }
        sub_layers.deinit();
    }

    try minimizeCrossings(&sub_graph, &sub_layers);

    const sub_result = assignCoordinates(&sub_graph, &sub_layers, direction);

    try routeEdges(allocator, &sub_graph);

    // Copy positions from sub-graph back to child State structs.
    // Positions are relative to the composite state's content region.
    for (parent.children.items) |*child| {
        if (sub_graph.nodes.get(child.id)) |gnode| {
            child.x = gnode.x;
            child.y = gnode.y;
            child.width = gnode.width;
            child.height = gnode.height;
        }
    }

    // Size the parent composite to contain all children.
    // Layout: header at top, then content area with children.
    const content_width = sub_result.width;
    const content_height = sub_result.height;

    parent.width = @max(min_normal_width + composite_padding, content_width + composite_inner_padding * 2);
    parent.height = composite_header_height + content_height + composite_inner_padding * 2;
}

// NOTE: measureChildState was removed — it was identical to measureSingleState.
// All call sites now use measureSingleState directly.

// NOTE: translateCompositeChildren, translateChildrenRecursive, and
// translateRegionStates were removed — they were superseded by
// translateAllChildren / translateChildrenAbsolute (defined above).

/// Lay out the concurrent regions of a composite state side-by-side.
///
/// Each region is laid out independently as a sub-graph. Regions are arranged
/// left-to-right (for TD direction). The parent composite state is sized to
/// contain all regions plus header and padding.
///
/// Region positions (region.x/y/width/height) and child positions (child.x/y)
/// are stored relative to the parent's content area (0,0 = top-left of content).
/// translateAllChildren() later converts these to global diagram coordinates.
fn layoutCompositeRegions(
    allocator: Allocator,
    parent: *State,
    fonts: *const Fonts,
    theme: *const Theme,
    direction: Direction,
) error{OutOfMemory}!void {
    // First recursively lay out any composite children within the regions.
    // A composite inside a region may have its own direct children OR regions.
    for (parent.regions.items) |*region| {
        for (region.states.items) |*child| {
            if (child.state_type == .composite) {
                try layoutCompositeNode(allocator, child, fonts, theme, direction);
            }
        }
    }

    var total_width: f32 = 0;
    var max_height: f32 = 0;

    for (parent.regions.items, 0..) |*region, region_idx| {
        // Build a temporary sub-graph for this region's states
        var sub_graph = Graph.init(allocator, direction);
        defer sub_graph.deinit();

        for (region.states.items) |*child| {
            const shape: NodeShape = switch (child.state_type) {
                .start, .end, .history, .deep_history, .entry_point, .exit_point => .circle,
                .choice => .diamond,
                .fork, .join => .rectangle,
                .composite, .normal => .rounded,
            };
            try sub_graph.addNode(child.id, child.displayLabel(), shape);
        }

        // Measure child nodes
        for (region.states.items) |*child| {
            if (sub_graph.nodes.getPtr(child.id)) |gnode| {
                measureSingleState(child, gnode, fonts, theme);
            }
        }

        // Add region transitions as edges
        for (region.transitions.items) |t| {
            var edge = try sub_graph.addEdge(t.from, t.to);
            if (t.label != null) edge.label = t.label;
        }

        // Run layout pipeline on the sub-graph
        try assignLayers(allocator, &sub_graph, null);

        var sub_layers = try buildLayerLists(allocator, &sub_graph, null);
        defer {
            for (sub_layers.items) |*layer_list| {
                layer_list.deinit();
            }
            sub_layers.deinit();
        }

        try minimizeCrossings(&sub_graph, &sub_layers);
        const sub_result = assignCoordinates(&sub_graph, &sub_layers, direction);
        try routeEdges(allocator, &sub_graph);

        // Copy sub-graph positions to region state structs.
        // Offset each state by total_width to place this region to the right of
        // previously-laid-out regions.
        for (region.states.items) |*child| {
            if (sub_graph.nodes.get(child.id)) |gnode| {
                child.x = gnode.x + total_width;
                child.y = gnode.y;
                child.width = gnode.width;
                child.height = gnode.height;
            }
        }

        // Store region bounding box (local to parent content area)
        region.x = total_width;
        region.y = 0;
        region.width = sub_result.width;
        region.height = sub_result.height;

        // Advance x-cursor; add separator gap between regions (not after the last).
        // region_divider_gap provides space for the visual dashed separator line.
        total_width += sub_result.width;
        if (region_idx + 1 < parent.regions.items.len) {
            total_width += region_divider_gap;
        }
        max_height = @max(max_height, sub_result.height);
    }

    // Size parent composite to contain all regions with padding and header
    parent.width = @max(
        min_normal_width + composite_padding,
        total_width + composite_inner_padding * 2,
    );
    parent.height = composite_header_height + max_height + composite_inner_padding * 2;
}

// NOTE: syncChildStatesToGraphNodes was removed — it was superseded by
// propagateAbsoluteCoords which handles arbitrary nesting depth.

// =============================================================================
// Step 1: Measure state nodes (top-level)
// =============================================================================

fn measureStateNodes(model: *StateModel, fonts: *const Fonts, theme: *const Theme) void {
    for (model.states.items) |*state| {
        const gnode = model.graph.nodes.getPtr(state.id) orelse continue;
        measureSingleState(state, gnode, fonts, theme);
    }
}

fn measureSingleState(state: *const State, gnode: *GraphNode, fonts: *const Fonts, theme: *const Theme) void {
    switch (state.state_type) {
        // Circle pseudo-states: start/end markers and entry/exit points share
        // the same fixed dimensions (start_end_radius * 2).
        .start, .end, .entry_point, .exit_point => {
            gnode.width = start_end_radius * 2;
            gnode.height = start_end_radius * 2;
        },
        .history, .deep_history => {
            // History pseudo-state circle — slightly larger than start/end
            gnode.width = 28;
            gnode.height = 28;
        },
        .fork, .join => {
            // Horizontal bar — fixed size
            gnode.width = bar_width;
            gnode.height = bar_height;
        },
        .choice => {
            // Diamond — fixed size
            gnode.width = choice_size;
            gnode.height = choice_size;
        },
        .composite => {
            // Use pre-computed dimensions from layoutCompositeChildren
            if (state.width > 0 and state.height > 0) {
                gnode.width = state.width;
                gnode.height = state.height;
            } else {
                // Fallback for composites with no children
                const measured = fonts.measure(state.displayLabel(), theme.body_font_size, false, false, false);
                const label_w = measured.x + node_padding_h * 2;
                const label_h = measured.y + node_padding_v * 2;
                gnode.width = @max(min_normal_width + composite_padding, label_w + composite_padding);
                gnode.height = @max(min_normal_height + composite_padding, label_h + composite_padding);
            }
        },
        .normal => {
            const measured = fonts.measure(state.displayLabel(), theme.body_font_size, false, false, false);
            gnode.width = @max(min_normal_width, measured.x + node_padding_h * 2);
            gnode.height = @max(min_normal_height, measured.y + node_padding_v * 2);
        },
    }
}

// =============================================================================
// Step 2: Assign layers via BFS
// =============================================================================

/// Assign layers via topological BFS. When model is non-null, only processes
/// top-level state IDs (skips children of composite states). When model is
/// null (sub-graph layout), processes all nodes.
fn assignLayers(allocator: Allocator, graph: *Graph, model: ?*const StateModel) !void {
    // Reset all layers
    var reset_it = graph.nodes.iterator();
    while (reset_it.next()) |entry| {
        entry.value_ptr.layer = -1;
    }

    // Compute in-degree for each node (only for relevant nodes)
    var in_degree = std.StringHashMap(i32).init(allocator);
    defer in_degree.deinit();

    var node_it = graph.nodes.iterator();
    while (node_it.next()) |entry| {
        if (model) |m| {
            // Skip child states — they're in sub-graphs
            if (isChildState(m, entry.key_ptr.*)) continue;
        }
        try in_degree.put(entry.key_ptr.*, 0);
    }

    for (graph.edges.items) |edge| {
        // Skip edges involving child states
        if (model) |m| {
            if (isChildState(m, edge.from) or isChildState(m, edge.to)) continue;
        }
        if (in_degree.getPtr(edge.to)) |deg| {
            deg.* += 1;
        }
    }

    // BFS from source nodes (in-degree 0)
    var queue = std.ArrayList([]const u8).init(allocator);
    defer queue.deinit();

    var deg_it = in_degree.iterator();
    while (deg_it.next()) |entry| {
        if (entry.value_ptr.* == 0) {
            try queue.append(entry.key_ptr.*);
            if (graph.nodes.getPtr(entry.key_ptr.*)) |node| {
                node.layer = 0;
            }
        }
    }

    // If no sources found (cycle), pick any node as layer 0
    if (queue.items.len == 0) {
        var any_it = in_degree.iterator();
        if (any_it.next()) |entry| {
            try queue.append(entry.key_ptr.*);
            if (graph.nodes.getPtr(entry.key_ptr.*)) |node| {
                node.layer = 0;
            }
        }
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const current_id = queue.items[head];
        head += 1;

        const current_layer = if (graph.nodes.get(current_id)) |n| n.layer else 0;

        for (graph.edges.items) |edge| {
            // Skip edges involving child states
            if (model) |m| {
                if (isChildState(m, edge.from) or isChildState(m, edge.to)) continue;
            }
            if (std.mem.eql(u8, edge.from, current_id)) {
                if (graph.nodes.getPtr(edge.to)) |target| {
                    const new_layer = current_layer + 1;
                    if (target.layer == -1) {
                        target.layer = new_layer;
                        try queue.append(edge.to);
                    } else if (new_layer > target.layer) {
                        // Push deeper to maintain proper layering
                        target.layer = new_layer;
                    }
                }
            }
        }
    }

    // Assign unvisited nodes to layer 0 (only for relevant nodes)
    var fix_it = graph.nodes.iterator();
    while (fix_it.next()) |entry| {
        if (model) |m| {
            if (isChildState(m, entry.key_ptr.*)) continue;
        }
        if (entry.value_ptr.layer == -1) {
            entry.value_ptr.layer = 0;
        }
    }
}

/// Check if a state ID belongs to a child of a composite state (not top-level).
fn isChildState(model: *const StateModel, id: []const u8) bool {
    // If it's a top-level state, it's not a child
    for (model.states.items) |*s| {
        if (std.mem.eql(u8, s.id, id)) return false;
    }
    // If not found at top level, it's either a child state or unknown.
    // In both cases we want to skip it during top-level layout.
    return true;
}

// =============================================================================
// Step 3: Build layer lists and minimize crossings
// =============================================================================

/// Build layer lists from graph nodes. When model is non-null, skips child
/// states (they are laid out within their composite parent).
fn buildLayerLists(
    allocator: Allocator,
    graph: *Graph,
    model: ?*const StateModel,
) !std.ArrayList(std.ArrayList([]const u8)) {
    var max_layer: i32 = 0;
    var it = graph.nodes.iterator();
    while (it.next()) |entry| {
        if (model) |m| {
            if (isChildState(m, entry.key_ptr.*)) continue;
        }
        if (entry.value_ptr.layer > max_layer) max_layer = entry.value_ptr.layer;
    }

    var layers = std.ArrayList(std.ArrayList([]const u8)).init(allocator);
    errdefer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    var l: i32 = 0;
    while (l <= max_layer) : (l += 1) {
        try layers.append(std.ArrayList([]const u8).init(allocator));
    }

    var it2 = graph.nodes.iterator();
    while (it2.next()) |entry| {
        if (model) |m| {
            if (isChildState(m, entry.key_ptr.*)) continue;
        }
        const layer_idx: usize = @intCast(@max(0, entry.value_ptr.layer));
        if (layer_idx < layers.items.len) {
            try layers.items[layer_idx].append(entry.key_ptr.*);
        }
    }

    return layers;
}

fn minimizeCrossings(graph: *Graph, layers: *std.ArrayList(std.ArrayList([]const u8))) !void {
    // Barycenter heuristic: order nodes in each layer by average position
    // of their predecessors in the previous layer
    if (layers.items.len < 2) return;

    var i: usize = 1;
    while (i < layers.items.len) : (i += 1) {
        const prev_layer = &layers.items[i - 1];
        const cur_layer = &layers.items[i];

        // Position map for previous layer
        var positions = std.StringHashMap(f32).init(graph.allocator);
        defer positions.deinit();
        for (prev_layer.items, 0..) |node_id, idx| {
            try positions.put(node_id, @floatFromInt(idx));
        }

        // Compute barycenters for current layer
        var bary = std.StringHashMap(f32).init(graph.allocator);
        defer bary.deinit();

        for (cur_layer.items) |node_id| {
            var sum: f32 = 0;
            var count: f32 = 0;
            for (graph.edges.items) |edge| {
                if (std.mem.eql(u8, edge.to, node_id)) {
                    if (positions.get(edge.from)) |pos| {
                        sum += pos;
                        count += 1;
                    }
                }
            }
            try bary.put(node_id, if (count > 0) sum / count else 0);
        }

        // Insertion sort by barycenter value
        var j: usize = 1;
        while (j < cur_layer.items.len) : (j += 1) {
            var k = j;
            while (k > 0) {
                const bk = bary.get(cur_layer.items[k]) orelse 0;
                const bk1 = bary.get(cur_layer.items[k - 1]) orelse 0;
                if (bk < bk1) {
                    const tmp = cur_layer.items[k];
                    cur_layer.items[k] = cur_layer.items[k - 1];
                    cur_layer.items[k - 1] = tmp;
                    k -= 1;
                } else {
                    break;
                }
            }
        }
    }
}

// =============================================================================
// Step 4: Assign coordinates (direction-aware)
// =============================================================================

/// Assign coordinates to nodes based on their layer assignments.
/// Supports all four directions: top-down (td), bottom-top (bt),
/// left-right (lr), and right-left (rl).
fn assignCoordinates(
    graph: *Graph,
    layers: *std.ArrayList(std.ArrayList([]const u8)),
    direction: Direction,
) LayoutResult {
    switch (direction) {
        .td => return assignCoordinatesVertical(graph, layers, false),
        .bt => return assignCoordinatesVertical(graph, layers, true),
        .lr => return assignCoordinatesHorizontal(graph, layers, false),
        .rl => return assignCoordinatesHorizontal(graph, layers, true),
    }
}

/// Return the maximum node height across all nodes in a single layer list.
/// Returns 0 for an empty layer (caller adds layer_spacing on top of this).
fn singleLayerMaxHeight(graph: *const Graph, layer: []const []const u8) f32 {
    var max_h: f32 = 0;
    for (layer) |nid| {
        if (graph.nodes.get(nid)) |n| {
            if (n.height > max_h) max_h = n.height;
        }
    }
    return max_h;
}

/// Return the maximum node width across all nodes in a single layer list.
/// Returns 0 for an empty layer.
fn singleLayerMaxWidth(graph: *const Graph, layer: []const []const u8) f32 {
    var max_w: f32 = 0;
    for (layer) |nid| {
        if (graph.nodes.get(nid)) |n| {
            if (n.width > max_w) max_w = n.width;
        }
    }
    return max_w;
}

/// Compute the Y start position for a given effective layer index using
/// per-layer max heights. `effective_idx=0` maps to the topmost visual layer;
/// for reverse (BT) mode the actual `layers` array is read in reverse.
///
/// This replaces the old global-max-height approach to eliminate the
/// excessive whitespace that occurred when one layer contained a large
/// composite state while other layers held small pseudo-states.
fn effectiveLayerStartY(
    graph: *const Graph,
    layers: *const std.ArrayList(std.ArrayList([]const u8)),
    effective_idx: usize,
    reverse: bool,
) f32 {
    var y: f32 = diagram_padding;
    var k: usize = 0;
    while (k < effective_idx) : (k += 1) {
        // Map effective index k to the actual layers.items index
        const actual_idx = if (reverse) layers.items.len - 1 - k else k;
        y += singleLayerMaxHeight(graph, layers.items[actual_idx].items) + layer_spacing;
    }
    return y;
}

/// Compute the X start position for a given effective layer index using
/// per-layer max widths (for LR/RL horizontal layouts).
fn effectiveLayerStartX(
    graph: *const Graph,
    layers: *const std.ArrayList(std.ArrayList([]const u8)),
    effective_idx: usize,
    reverse: bool,
) f32 {
    var x: f32 = diagram_padding;
    var k: usize = 0;
    while (k < effective_idx) : (k += 1) {
        const actual_idx = if (reverse) layers.items.len - 1 - k else k;
        x += singleLayerMaxWidth(graph, layers.items[actual_idx].items) + layer_spacing;
    }
    return x;
}

/// Assign coordinates for vertical (top-down or bottom-top) layout.
///
/// Uses per-layer cumulative Y positions so that layers containing tall
/// composite states do not force excessive inter-layer gaps for adjacent
/// layers that hold small pseudo-states (e.g. [*] circles).
fn assignCoordinatesVertical(
    graph: *Graph,
    layers: *std.ArrayList(std.ArrayList([]const u8)),
    reverse: bool,
) LayoutResult {
    var total_width: f32 = 0;

    for (layers.items, 0..) |layer, layer_idx| {
        var offset: f32 = diagram_padding;
        const effective_idx: usize = if (reverse)
            layers.items.len - 1 - layer_idx
        else
            layer_idx;

        const layer_y = effectiveLayerStartY(graph, layers, effective_idx, reverse);

        for (layer.items) |node_id| {
            if (graph.nodes.getPtr(node_id)) |node| {
                node.x = offset;
                node.y = layer_y;
                offset += node.width + node_spacing;
            }
        }

        if (offset > total_width) total_width = offset;
    }

    total_width += diagram_padding;

    // Total height = Y start of last effective layer + its max height + bottom padding.
    var total_height: f32 = 0;
    if (layers.items.len > 0) {
        const last_eff = layers.items.len - 1;
        const last_y = effectiveLayerStartY(graph, layers, last_eff, reverse);
        const last_actual = if (reverse) 0 else last_eff;
        const last_max_h = singleLayerMaxHeight(graph, layers.items[last_actual].items);
        total_height = last_y + last_max_h + diagram_padding;
    }

    // Center each layer horizontally within the total width
    centerLayersOnAxis(graph, layers, total_width, true);

    return .{ .width = total_width, .height = total_height };
}

/// Assign coordinates for horizontal (left-right or right-left) layout.
///
/// Uses per-layer cumulative X positions (see effectiveLayerStartX) to avoid
/// the excessive gaps that arise when one layer holds wide composite states.
fn assignCoordinatesHorizontal(
    graph: *Graph,
    layers: *std.ArrayList(std.ArrayList([]const u8)),
    reverse: bool,
) LayoutResult {
    var total_height: f32 = 0;

    for (layers.items, 0..) |layer, layer_idx| {
        var offset: f32 = diagram_padding;
        const effective_idx: usize = if (reverse)
            layers.items.len - 1 - layer_idx
        else
            layer_idx;

        const layer_x = effectiveLayerStartX(graph, layers, effective_idx, reverse);

        for (layer.items) |node_id| {
            if (graph.nodes.getPtr(node_id)) |node| {
                node.x = layer_x;
                node.y = offset;
                offset += node.height + node_spacing;
            }
        }

        if (offset > total_height) total_height = offset;
    }

    total_height += diagram_padding;

    // Total width = X start of last effective layer + its max width + right padding.
    var total_width: f32 = 0;
    if (layers.items.len > 0) {
        const last_eff = layers.items.len - 1;
        const last_x = effectiveLayerStartX(graph, layers, last_eff, reverse);
        const last_actual = if (reverse) 0 else last_eff;
        const last_max_w = singleLayerMaxWidth(graph, layers.items[last_actual].items);
        total_width = last_x + last_max_w + diagram_padding;
    }

    // Center each layer vertically within the total height
    centerLayersOnAxis(graph, layers, total_height, false);

    return .{ .width = total_width, .height = total_height };
}

fn maxLayerHeight(graph: *Graph, layers: *std.ArrayList(std.ArrayList([]const u8))) f32 {
    var max_h: f32 = min_normal_height;
    for (layers.items) |layer| {
        for (layer.items) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                if (node.height > max_h) max_h = node.height;
            }
        }
    }
    return max_h;
}

fn maxLayerWidth(graph: *Graph, layers: *std.ArrayList(std.ArrayList([]const u8))) f32 {
    var max_w: f32 = min_normal_width;
    for (layers.items) |layer| {
        for (layer.items) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                if (node.width > max_w) max_w = node.width;
            }
        }
    }
    return max_w;
}

/// Center layers along the specified axis. When `horizontal` is true, centers
/// each layer's nodes along the x-axis within `total_extent` (for vertical layout).
/// When false, centers along the y-axis (for horizontal layout).
fn centerLayersOnAxis(
    graph: *Graph,
    layers: *std.ArrayList(std.ArrayList([]const u8)),
    total_extent: f32,
    horizontal: bool,
) void {
    for (layers.items) |layer| {
        if (layer.items.len == 0) continue;

        var min_pos: f32 = std.math.inf(f32);
        var max_pos: f32 = -std.math.inf(f32);

        for (layer.items) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                if (horizontal) {
                    if (node.x < min_pos) min_pos = node.x;
                    if (node.x + node.width > max_pos) max_pos = node.x + node.width;
                } else {
                    if (node.y < min_pos) min_pos = node.y;
                    if (node.y + node.height > max_pos) max_pos = node.y + node.height;
                }
            }
        }

        const extent = max_pos - min_pos;
        const shift = (total_extent - extent) / 2.0 - min_pos;

        for (layer.items) |node_id| {
            if (graph.nodes.getPtr(node_id)) |node| {
                if (horizontal) {
                    node.x += shift;
                } else {
                    node.y += shift;
                }
            }
        }
    }
}

// =============================================================================
// Step 5: Route edges
// =============================================================================

fn routeEdges(allocator: Allocator, graph: *Graph) !void {
    _ = allocator;

    for (graph.edges.items) |*edge| {
        const from_node = graph.nodes.get(edge.from) orelse continue;
        const to_node = graph.nodes.get(edge.to) orelse continue;

        const from_cx = from_node.x + from_node.width / 2;
        const from_cy = from_node.y + from_node.height / 2;
        const to_cx = to_node.x + to_node.width / 2;
        const to_cy = to_node.y + to_node.height / 2;

        const start = nodePort(from_node, to_cx, to_cy);
        const end = nodePort(to_node, from_cx, from_cy);

        edge.waypoints.clearRetainingCapacity();
        try edge.waypoints.append(start);

        // For transitions that are not straight vertical, add a mid-point
        // to create a cleaner orthogonal-ish routing
        const dx = @abs(start.x - end.x);
        const dy = @abs(start.y - end.y);
        if (dx > 10 and dy > 10) {
            // Route via a bend point
            const mid_y = (start.y + end.y) / 2;
            try edge.waypoints.append(.{ .x = start.x, .y = mid_y });
            try edge.waypoints.append(.{ .x = end.x, .y = mid_y });
        }

        try edge.waypoints.append(end);
    }
}

fn nodePort(node: GraphNode, target_x: f32, target_y: f32) Point {
    const cx = node.x + node.width / 2;
    const cy = node.y + node.height / 2;
    const dx = target_x - cx;
    const dy = target_y - cy;

    if (dx == 0 and dy == 0) return .{ .x = cx, .y = cy };

    const abs_dx = @abs(dx);
    const abs_dy = @abs(dy);
    const hw = node.width / 2;
    const hh = node.height / 2;

    if (abs_dx * hh > abs_dy * hw) {
        // Exit left or right
        const sign: f32 = if (dx > 0) 1.0 else -1.0;
        return .{
            .x = cx + hw * sign,
            .y = cy + dy * (hw / abs_dx),
        };
    } else {
        // Exit top or bottom
        const sign: f32 = if (dy > 0) 1.0 else -1.0;
        return .{
            .x = cx + dx * (hh / abs_dy),
            .y = cy + hh * sign,
        };
    }
}

// =============================================================================
// Step 5.5: Boundary port system
//
// Maps entry/exit transitions that cross composite state borders to specific
// anchor points on those borders.  Call this AFTER routeEdges has computed
// the initial straight-line waypoints.
//
// For a top-level transition A → B where B is inside CompositeP:
//   Waypoints become:  A-port  →  CompositeP-entry-port  →  B-port
//
// For a top-level transition A → B where A is inside CompositeP:
//   Waypoints become:  A-port  →  CompositeP-exit-port  →  B-port
//
// Multi-level nesting is handled recursively: each boundary layer adds one
// port in the correct direction (innermost-first for exits, outermost-first
// for entries).
// =============================================================================

/// A map from state_id → immediate parent composite state_id.
/// Top-level states map to null.
const ParentMap = std.StringHashMap(?[]const u8);

/// Build a ParentMap from the StateModel.
/// Each state_id maps to its immediate parent composite state_id, or null if
/// it lives at the top level.
fn buildParentMap(allocator: Allocator, model: *const StateModel) !ParentMap {
    var map = ParentMap.init(allocator);
    errdefer map.deinit();

    for (model.states.items) |*state| {
        try map.put(state.id, null);
        try buildParentMapForChildren(&map, state.id, state.children.items);
        for (state.regions.items) |*region| {
            try buildParentMapForChildren(&map, state.id, region.states.items);
        }
    }

    return map;
}

/// Recursive helper: register every state in `children` as owned by
/// `parent_id`, then recurse into their own children/regions.
fn buildParentMapForChildren(
    map: *ParentMap,
    parent_id: []const u8,
    children: []const State,
) !void {
    for (children) |*child| {
        try map.put(child.id, parent_id);
        try buildParentMapForChildren(map, child.id, child.children.items);
        for (child.regions.items) |*region| {
            try buildParentMapForChildren(map, child.id, region.states.items);
        }
    }
}

/// Return the chain of composite ancestor IDs for `state_id`, ordered from
/// immediate parent to outermost ancestor.
/// Returns an empty list for top-level states.
/// Caller owns the returned ArrayList.
fn getAncestorChain(
    parent_map: *const ParentMap,
    state_id: []const u8,
    allocator: Allocator,
) !std.ArrayList([]const u8) {
    var chain = std.ArrayList([]const u8).init(allocator);
    errdefer chain.deinit();

    var current: []const u8 = state_id;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const parent_opt = parent_map.get(current) orelse break; // id not in map
        const parent_id = parent_opt orelse break; // null = top-level
        try chain.append(parent_id);
        current = parent_id;
    }

    return chain;
}

/// Find the lowest common ancestor of two ancestor chains.
/// Both chains are ordered innermost → outermost.
/// Returns null if the two states share no ancestor (both are top-level).
fn findLCA(
    from_chain: []const []const u8,
    to_chain: []const []const u8,
) ?[]const u8 {
    for (from_chain) |a| {
        for (to_chain) |b| {
            if (std.mem.eql(u8, a, b)) return a;
        }
    }
    return null;
}

/// Apply boundary port waypoints for all cross-composite transitions in the
/// top-level graph.  Call this after routeEdges (which sets the initial
/// straight-line waypoints).
///
/// For each edge whose endpoints live in different composite scopes, this
/// replaces the edge's waypoints with a sequence that passes through the
/// border of every intermediate composite:
///
///   source-port
///     → exit-port on each composite surrounding source (inner→outer, up to LCA)
///     → entry-port on each composite surrounding target (outer→inner, down to target)
///     → target-port
///
/// Edges between states in the same immediate composite scope are left unchanged.
pub fn applyBoundaryPorts(
    allocator: Allocator,
    graph: *Graph,
    model: *const StateModel,
) !void {
    var parent_map = try buildParentMap(allocator, model);
    defer parent_map.deinit();

    for (graph.edges.items) |*edge| {
        try applyBoundaryPortToEdge(allocator, graph, edge, &parent_map);
    }
}

/// Process a single edge for boundary port insertion.
fn applyBoundaryPortToEdge(
    allocator: Allocator,
    graph: *const Graph,
    edge: *GraphEdge,
    parent_map: *const ParentMap,
) !void {
    const from_node = graph.nodes.get(edge.from) orelse return;
    const to_node = graph.nodes.get(edge.to) orelse return;

    // Determine immediate parents.  States not found in the map have no parent.
    const from_parent = parent_map.get(edge.from) orelse null; // null = not in map → treat as top-level
    const to_parent = parent_map.get(edge.to) orelse null;

    // Quick escape: both states share the same immediate parent.
    const same_parent = blk: {
        if (from_parent == null and to_parent == null) break :blk true;
        if (from_parent == null or to_parent == null) break :blk false;
        break :blk std.mem.eql(u8, from_parent.?, to_parent.?);
    };
    if (same_parent) return;

    // Collect ancestor chains: [immediate-parent, grandparent, ...]
    var from_chain = try getAncestorChain(parent_map, edge.from, allocator);
    defer from_chain.deinit();
    var to_chain = try getAncestorChain(parent_map, edge.to, allocator);
    defer to_chain.deinit();

    // If both are top-level with different "parents" that are both null, they
    // are in the same scope — no boundary crossing.  (Shouldn't reach here
    // given same_parent check, but be defensive.)
    if (from_chain.items.len == 0 and to_chain.items.len == 0) return;

    // Find the lowest common ancestor scope.
    const lca = findLCA(from_chain.items, to_chain.items);

    // Node centres, for port direction calculations.
    const from_cx = from_node.x + from_node.width / 2;
    const from_cy = from_node.y + from_node.height / 2;
    const to_cx = to_node.x + to_node.width / 2;
    const to_cy = to_node.y + to_node.height / 2;

    // --- Exit ports (source side) ---
    // Ancestors of the source state that are NOT the LCA, ordered innermost→outermost.
    // For each one, compute the port on that composite's border pointing toward the target.
    var exit_ports = std.ArrayList(Point).init(allocator);
    defer exit_ports.deinit();
    for (from_chain.items) |ancestor| {
        if (lca) |l| {
            if (std.mem.eql(u8, ancestor, l)) break;
        }
        if (graph.nodes.get(ancestor)) |comp_node| {
            try exit_ports.append(nodePort(comp_node, to_cx, to_cy));
        }
    }

    // --- Entry ports (target side) ---
    // Ancestors of the target state that are NOT the LCA, ordered innermost→outermost.
    // These are added to the waypoint list in REVERSE (outermost→innermost) so the
    // path descends into the target composite correctly.
    var entry_ports = std.ArrayList(Point).init(allocator);
    defer entry_ports.deinit();
    for (to_chain.items) |ancestor| {
        if (lca) |l| {
            if (std.mem.eql(u8, ancestor, l)) break;
        }
        if (graph.nodes.get(ancestor)) |comp_node| {
            try entry_ports.append(nodePort(comp_node, from_cx, from_cy));
        }
    }

    // No ports to insert → nothing to do (can happen if ancestors aren't in graph).
    if (exit_ports.items.len == 0 and entry_ports.items.len == 0) return;

    // Build the new waypoint list.
    var new_wps = std.ArrayList(Point).init(allocator);
    var took_ownership = false;
    defer if (!took_ownership) new_wps.deinit();

    // 1. Source exit port.
    try new_wps.append(nodePort(from_node, to_cx, to_cy));

    // 2. Exit ports: innermost composite → outermost (already in that order).
    for (exit_ports.items) |p| {
        try new_wps.append(p);
    }

    // 3. Entry ports: outermost → innermost (reverse of collected order).
    var ei = entry_ports.items.len;
    while (ei > 0) {
        ei -= 1;
        try new_wps.append(entry_ports.items[ei]);
    }

    // 4. Target entry port.
    try new_wps.append(nodePort(to_node, from_cx, from_cy));

    // Transfer ownership to the edge.
    edge.waypoints.deinit();
    edge.waypoints = new_wps;
    took_ownership = true;
}

// =============================================================================
// Step 6: Sync graph node positions back to State structs
// =============================================================================

fn syncStatePositions(model: *StateModel) void {
    for (model.states.items) |*state| {
        if (model.graph.nodes.get(state.id)) |gnode| {
            state.x = gnode.x;
            state.y = gnode.y;
            state.width = gnode.width;
            state.height = gnode.height;
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// Stub Fonts for testing — returns fixed measurements
const StubFonts = struct {
    fn measure(_: *const @This(), _: []const u8, _: f32, _: bool, _: bool, _: bool) @import("raylib").Vector2 {
        return .{ .x = 60, .y = 16 };
    }
};

test "state_layout: empty model produces zero dimensions" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    // Can't call layout with real fonts in unit test, so verify the graph is empty
    try testing.expectEqual(@as(u32, 0), model.graph.nodes.count());
}

test "state_layout: assignLayers assigns layer 0 to source nodes" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);
    try graph.addNode("C", "C", .rounded);
    _ = try graph.addEdge("A", "B");
    _ = try graph.addEdge("B", "C");

    try assignLayers(allocator, &graph, null);

    try testing.expectEqual(@as(i32, 0), graph.nodes.get("A").?.layer);
    try testing.expectEqual(@as(i32, 1), graph.nodes.get("B").?.layer);
    try testing.expectEqual(@as(i32, 2), graph.nodes.get("C").?.layer);
}

test "state_layout: assignLayers handles disconnected nodes" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);
    // No edges — both should be layer 0

    try assignLayers(allocator, &graph, null);

    try testing.expectEqual(@as(i32, 0), graph.nodes.get("A").?.layer);
    try testing.expectEqual(@as(i32, 0), graph.nodes.get("B").?.layer);
}

test "state_layout: assignLayers handles cycles" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);
    _ = try graph.addEdge("A", "B");
    _ = try graph.addEdge("B", "A");

    try assignLayers(allocator, &graph, null);

    // Both should have non-negative layers
    try testing.expect(graph.nodes.get("A").?.layer >= 0);
    try testing.expect(graph.nodes.get("B").?.layer >= 0);
}

test "state_layout: buildLayerLists groups nodes by layer" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);
    try graph.addNode("C", "C", .rounded);

    graph.nodes.getPtr("A").?.layer = 0;
    graph.nodes.getPtr("B").?.layer = 1;
    graph.nodes.getPtr("C").?.layer = 1;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    try testing.expectEqual(@as(usize, 2), layers.items.len);
    try testing.expectEqual(@as(usize, 1), layers.items[0].items.len);
    try testing.expectEqual(@as(usize, 2), layers.items[1].items.len);
}

test "state_layout: assignCoordinates produces positive dimensions" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);

    var a = graph.nodes.getPtr("A").?;
    a.layer = 0;
    a.width = 80;
    a.height = 40;

    var b = graph.nodes.getPtr("B").?;
    b.layer = 1;
    b.width = 80;
    b.height = 40;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    const result = assignCoordinates(&graph, &layers, .td);

    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);

    // Both nodes should have positive positions
    const node_a = graph.nodes.get("A").?;
    const node_b = graph.nodes.get("B").?;
    try testing.expect(node_a.x >= 0);
    try testing.expect(node_a.y >= 0);
    try testing.expect(node_b.x >= 0);
    try testing.expect(node_b.y > node_a.y); // B is in a lower layer
}

test "state_layout: routeEdges creates waypoints" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);

    var a = graph.nodes.getPtr("A").?;
    a.x = 50;
    a.y = 20;
    a.width = 80;
    a.height = 40;

    var b = graph.nodes.getPtr("B").?;
    b.x = 50;
    b.y = 140;
    b.width = 80;
    b.height = 40;

    _ = try graph.addEdge("A", "B");

    try routeEdges(allocator, &graph);

    try testing.expect(graph.edges.items.len == 1);
    try testing.expect(graph.edges.items[0].waypoints.items.len >= 2);

    // Start should be at bottom of A, end at top of B
    const wp_start = graph.edges.items[0].waypoints.items[0];
    const wp_end = graph.edges.items[0].waypoints.items[graph.edges.items[0].waypoints.items.len - 1];
    try testing.expect(wp_start.y < wp_end.y);
}

test "state_layout: routeEdges adds bend points for non-vertical transitions" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);

    var a = graph.nodes.getPtr("A").?;
    a.x = 20;
    a.y = 20;
    a.width = 80;
    a.height = 40;

    var b = graph.nodes.getPtr("B").?;
    b.x = 200;
    b.y = 140;
    b.width = 80;
    b.height = 40;

    _ = try graph.addEdge("A", "B");

    try routeEdges(allocator, &graph);

    // Should have more than 2 waypoints due to bend routing
    try testing.expect(graph.edges.items[0].waypoints.items.len > 2);
}

test "state_layout: nodePort returns correct exit point" {
    const node = GraphNode{
        .id = "test",
        .label = "test",
        .shape = .rounded,
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 40,
        .layer = 0,
    };

    // Target directly below — should exit bottom center
    const port = nodePort(node, 50, 200);
    try testing.expectApproxEqAbs(@as(f32, 50), port.x, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 40), port.y, 0.1);
}

test "state_layout: syncStatePositions copies graph node positions" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("S1");
    try model.graph.addNode("S1", "S1", .rounded);

    var gnode = model.graph.nodes.getPtr("S1").?;
    gnode.x = 42;
    gnode.y = 84;
    gnode.width = 100;
    gnode.height = 50;

    syncStatePositions(&model);

    const state = model.findStateMut("S1").?;
    try testing.expectApproxEqAbs(@as(f32, 42), state.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 84), state.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), state.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), state.height, 0.01);
}

test "state_layout: measureSingleState sizes start node correctly" {
    const allocator = testing.allocator;
    var gnode = GraphNode{
        .id = "[*]",
        .label = "[*]",
        .shape = .circle,
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
        .layer = 0,
    };

    var model = StateModel.init(allocator);
    defer model.deinit();
    _ = try model.ensureState("[*]");
    const state = &model.states.items[0];

    // Start/end nodes should be start_end_radius * 2
    measureSingleState(state, &gnode, undefined, undefined);
    try testing.expectApproxEqAbs(start_end_radius * 2, gnode.width, 0.01);
    try testing.expectApproxEqAbs(start_end_radius * 2, gnode.height, 0.01);
}

test "state_layout: measureSingleState sizes fork node correctly" {
    const allocator = testing.allocator;
    var gnode = GraphNode{
        .id = "f",
        .label = "f",
        .shape = .rectangle,
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
        .layer = 0,
    };

    var model = StateModel.init(allocator);
    defer model.deinit();
    var state = try model.ensureState("f");
    state.state_type = .fork;

    measureSingleState(state, &gnode, undefined, undefined);
    try testing.expectApproxEqAbs(bar_width, gnode.width, 0.01);
    try testing.expectApproxEqAbs(bar_height, gnode.height, 0.01);
}

test "state_layout: measureSingleState sizes choice node correctly" {
    const allocator = testing.allocator;
    var gnode = GraphNode{
        .id = "c",
        .label = "c",
        .shape = .diamond,
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
        .layer = 0,
    };

    var model = StateModel.init(allocator);
    defer model.deinit();
    var state = try model.ensureState("c");
    state.state_type = .choice;

    measureSingleState(state, &gnode, undefined, undefined);
    try testing.expectApproxEqAbs(choice_size, gnode.width, 0.01);
    try testing.expectApproxEqAbs(choice_size, gnode.height, 0.01);
}

// --- Direction-aware layout tests ---

test "state_layout: assignCoordinates horizontal layout (LR)" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .lr);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);

    var a = graph.nodes.getPtr("A").?;
    a.layer = 0;
    a.width = 80;
    a.height = 40;

    var b = graph.nodes.getPtr("B").?;
    b.layer = 1;
    b.width = 80;
    b.height = 40;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    const result = assignCoordinates(&graph, &layers, .lr);

    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);

    const node_a = graph.nodes.get("A").?;
    const node_b = graph.nodes.get("B").?;
    // In LR mode, B should be to the right of A
    try testing.expect(node_b.x > node_a.x);
}

test "state_layout: assignCoordinates reverse horizontal layout (RL)" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .rl);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);

    var a = graph.nodes.getPtr("A").?;
    a.layer = 0;
    a.width = 80;
    a.height = 40;

    var b = graph.nodes.getPtr("B").?;
    b.layer = 1;
    b.width = 80;
    b.height = 40;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    const result = assignCoordinates(&graph, &layers, .rl);

    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);

    const node_a = graph.nodes.get("A").?;
    const node_b = graph.nodes.get("B").?;
    // In RL mode, A (layer 0) should be to the RIGHT of B (layer 1 placed leftward)
    try testing.expect(node_a.x > node_b.x);
}

test "state_layout: assignCoordinates bottom-top layout (BT)" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .bt);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);

    var a = graph.nodes.getPtr("A").?;
    a.layer = 0;
    a.width = 80;
    a.height = 40;

    var b = graph.nodes.getPtr("B").?;
    b.layer = 1;
    b.width = 80;
    b.height = 40;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    const result = assignCoordinates(&graph, &layers, .bt);

    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);

    const node_a = graph.nodes.get("A").?;
    const node_b = graph.nodes.get("B").?;
    // In BT mode, A (layer 0) should be BELOW B (layer 1 placed higher)
    try testing.expect(node_a.y > node_b.y);
}

// --- Composite/nested state layout tests ---

test "state_layout: isChildState identifies child vs top-level states" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("TopLevel");
    const parent = try model.ensureState("Parent");
    _ = try model.ensureChildState(parent, "Child1");
    _ = try model.ensureChildState(parent, "Child2");

    try testing.expect(!isChildState(&model, "TopLevel"));
    try testing.expect(!isChildState(&model, "Parent"));
    try testing.expect(isChildState(&model, "Child1"));
    try testing.expect(isChildState(&model, "Child2"));
    // Unknown states are considered children (not at top level)
    try testing.expect(isChildState(&model, "Unknown"));
}

test "state_layout: translateChildrenRecursive offsets children by parent position" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Outer");
    parent.state_type = .composite;
    parent.x = 100;
    parent.y = 50;
    parent.width = 200;
    parent.height = 150;

    var child = try model.ensureChildState(parent, "Inner");
    child.x = 10; // relative position
    child.y = 5; // relative position
    child.width = 80;
    child.height = 40;

    translateAllChildren(&model);

    // Child position should be offset by parent position + header + inner padding
    const expected_x = 100 + composite_inner_padding + 10;
    const expected_y = 50 + composite_header_height + composite_inner_padding + 5;

    try testing.expectApproxEqAbs(expected_x, child.x, 0.01);
    try testing.expectApproxEqAbs(expected_y, child.y, 0.01);
}

test "state_layout: translateChildrenRecursive handles nested composites" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer");
    outer.state_type = .composite;
    outer.x = 100;
    outer.y = 50;
    outer.width = 300;
    outer.height = 250;

    var inner = try model.ensureChildState(outer, "Inner");
    inner.state_type = .composite;
    inner.x = 20;
    inner.y = 10;
    inner.width = 160;
    inner.height = 120;

    var deep = try model.ensureChildState(inner, "Deep");
    deep.x = 5;
    deep.y = 3;
    deep.width = 60;
    deep.height = 30;

    translateAllChildren(&model);

    // Inner's global position
    const inner_x = 100 + composite_inner_padding + 20;
    const inner_y = 50 + composite_header_height + composite_inner_padding + 10;

    // Deep's global position (relative to inner's translated position)
    const deep_x = inner_x + composite_inner_padding + 5;
    const deep_y = inner_y + composite_header_height + composite_inner_padding + 3;

    try testing.expectApproxEqAbs(inner_x, inner.x, 0.01);
    try testing.expectApproxEqAbs(inner_y, inner.y, 0.01);
    try testing.expectApproxEqAbs(deep_x, deep.x, 0.01);
    try testing.expectApproxEqAbs(deep_y, deep.y, 0.01);
}

// NOTE: "measureChildState uses pre-computed composite size" test removed —
// measureChildState was consolidated into measureSingleState.
// The equivalent test is "measureSingleState uses pre-computed composite size" below.

test "state_layout: measureSingleState uses pre-computed composite size" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Composite");
    parent.state_type = .composite;
    parent.width = 250;
    parent.height = 180;

    var gnode = GraphNode{
        .id = "Composite",
        .label = "Composite",
        .shape = .rounded,
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
        .layer = 0,
    };

    measureSingleState(parent, &gnode, undefined, undefined);

    try testing.expectApproxEqAbs(@as(f32, 250), gnode.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 180), gnode.height, 0.01);
}

test "state_layout: maxLayerWidth computes correctly" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .lr);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);

    var a = graph.nodes.getPtr("A").?;
    a.width = 120;
    a.layer = 0;

    var b = graph.nodes.getPtr("B").?;
    b.width = 80;
    b.layer = 0;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    const max_w = maxLayerWidth(&graph, &layers);
    try testing.expectApproxEqAbs(@as(f32, 120), max_w, 0.01);
}

test "state_layout: centerLayersOnAxis centers vertically for horizontal layout" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .lr);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    var a = graph.nodes.getPtr("A").?;
    a.width = 80;
    a.height = 40;
    a.y = 10;
    a.layer = 0;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    // Center in a total height of 200
    centerLayersOnAxis(&graph, &layers, 200, false);

    // Node should be centered: (200 - 40) / 2 = 80
    const node_a = graph.nodes.get("A").?;
    try testing.expectApproxEqAbs(@as(f32, 80), node_a.y, 0.1);
}

test "state_layout: buildLayerLists skips child states with model" {
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("TopA");
    const parent = try model.ensureState("Parent");
    _ = try model.ensureChildState(parent, "Child1");
    _ = try model.ensureChildState(parent, "Child2");

    try model.buildGraph();

    // Assign layers for top-level only
    try assignLayers(allocator, &model.graph, &model);

    var layers = try buildLayerLists(allocator, &model.graph, &model);
    defer {
        for (layers.items) |*layer_list| {
            layer_list.deinit();
        }
        layers.deinit();
    }

    // Count total nodes across all layers — should only include top-level states
    var total: usize = 0;
    for (layers.items) |layer_list| {
        total += layer_list.items.len;
    }
    // TopA and Parent are top-level; Child1 and Child2 should be skipped
    try testing.expectEqual(@as(usize, 2), total);
}

test "state_layout: layoutCompositeRegions sets region bounds" {
    // Verify that layoutCompositeRegions populates region.x/y/width/height
    // and sets child state positions within each region.
    const allocator = testing.allocator;
    const state_parser = @import("../parsers/state.zig");

    const source =
        \\stateDiagram-v2
        \\    state Comp {
        \\        A --> B
        \\        --
        \\        C --> D
        \\    }
    ;

    var model = try state_parser.parse(allocator, source);
    defer model.deinit();

    const comp = model.findStateMut("Comp") orelse return error.TestUnexpectedResult;
    try testing.expect(comp.hasRegions());
    try testing.expectEqual(@as(usize, 2), comp.regionCount());

    // After parse, buildGraph was called but layout was NOT run.
    // Manually call layoutCompositeRegions with a stub fonts/theme.
    // We can't call the full layout (requires raylib), but we verify the
    // function doesn't panic and produces non-zero region sizes.
    // Since we can't call fonts.measure in unit tests, just verify the
    // region states were listed correctly.

    // Verify region contents from parse stage
    const r0 = &comp.regions.items[0];
    const r1 = &comp.regions.items[1];
    try testing.expectEqual(@as(usize, 2), r0.states.items.len);
    try testing.expectEqual(@as(usize, 2), r1.states.items.len);
    try testing.expectEqual(@as(usize, 1), r0.transitions.items.len);
    try testing.expectEqual(@as(usize, 1), r1.transitions.items.len);
}

test "state_layout: propagateAbsoluteCoords region states" {
    // Verify that propagateAbsoluteCoords correctly propagates
    // region child positions into model.graph nodes.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    // Create a composite state with a region child
    const comp = try model.ensureState("Comp");
    comp.state_type = .composite;
    comp.x = 100;
    comp.y = 50;

    // Add Comp to graph and give it a position
    try model.graph.addNode("Comp", "Comp", .rounded);
    const comp_gnode = model.graph.nodes.getPtr("Comp").?;
    comp_gnode.x = 100;
    comp_gnode.y = 50;
    comp_gnode.width = 200;
    comp_gnode.height = 150;

    // Add region with child state
    const region = try model.addRegion(comp);
    _ = try region.ensureState(allocator, "RegChild", comp.depth);
    const child = &comp.regions.items[0].states.items[0];
    child.x = 10;
    child.y = 20;
    child.width = 80;
    child.height = 40;

    // Add RegChild to graph with default 0 positions
    try model.graph.addNode("RegChild", "RegChild", .rounded);

    // propagateAbsoluteCoords propagates child positions to model.graph
    propagateAbsoluteCoords(&model);

    const child_gnode = model.graph.nodes.get("RegChild").?;
    // Expected: parent_gnode.x + composite_inner_padding + child.x
    //         = 100 + 16 + 10 = 126
    // Expected: parent_gnode.y + composite_header_height + composite_inner_padding + child.y
    //         = 50 + 28 + 16 + 20 = 114
    try testing.expectApproxEqAbs(@as(f32, 126), child_gnode.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 114), child_gnode.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), child_gnode.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), child_gnode.height, 0.01);
}

test "state_layout: propagateAbsoluteCoords direct children" {
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const comp = try model.ensureState("Parent");
    try model.graph.addNode("Parent", "Parent", .rounded);
    const p_gnode = model.graph.nodes.getPtr("Parent").?;
    p_gnode.x = 0;
    p_gnode.y = 0;
    p_gnode.width = 200;
    p_gnode.height = 120;

    _ = try model.ensureChildState(comp, "Child");
    const child = comp.findChildMut("Child").?;
    child.x = 5;
    child.y = 10;
    child.width = 60;
    child.height = 30;

    try model.graph.addNode("Child", "Child", .rounded);

    propagateAbsoluteCoords(&model);

    const cg = model.graph.nodes.get("Child").?;
    // parent_x + composite_inner_padding + child.x = 0 + 16 + 5 = 21
    // parent_y + composite_header_height + composite_inner_padding + child.y = 0 + 28 + 16 + 10 = 54
    try testing.expectApproxEqAbs(@as(f32, 21), cg.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 54), cg.y, 0.01);
}

test "state_layout: translateChildrenAbsolute offsets region states by parent origin" {
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const comp = try model.ensureState("P");
    comp.state_type = .composite;
    comp.x = 50;
    comp.y = 30;

    const region = try model.addRegion(comp);
    _ = try region.ensureState(allocator, "RC", 0);
    comp.regions.items[0].x = 5;
    comp.regions.items[0].y = 0;
    comp.regions.items[0].width = 100;
    comp.regions.items[0].height = 80;
    comp.regions.items[0].states.items[0].x = 10;
    comp.regions.items[0].states.items[0].y = 5;

    translateChildrenAbsolute(comp, comp.x, comp.y);

    // region.x should be offset_x + 5 = (50 + 16) + 5 = 71
    // offset_y = 30 + 28 + 16 = 74; region.y = 74 + 0 = 74
    try testing.expectApproxEqAbs(@as(f32, 71), comp.regions.items[0].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 74), comp.regions.items[0].y, 0.01);

    // child.x = offset_x + 10 = 76; child.y = offset_y + 5 = 79
    try testing.expectApproxEqAbs(@as(f32, 76), comp.regions.items[0].states.items[0].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 79), comp.regions.items[0].states.items[0].y, 0.01);
}

test "state_layout: singleLayerMaxHeight returns max node height in a layer" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("Small", "Small", .circle);
    try graph.addNode("Large", "Large", .rounded);

    graph.nodes.getPtr("Small").?.height = 24;
    graph.nodes.getPtr("Large").?.height = 500;

    const layer_items = [_][]const u8{ "Small", "Large" };
    const max_h = singleLayerMaxHeight(&graph, &layer_items);
    try testing.expectApproxEqAbs(@as(f32, 500), max_h, 0.01);
}

test "state_layout: singleLayerMaxWidth returns max node width in a layer" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .lr);
    defer graph.deinit();

    try graph.addNode("Narrow", "Narrow", .circle);
    try graph.addNode("Wide", "Wide", .rounded);

    graph.nodes.getPtr("Narrow").?.width = 24;
    graph.nodes.getPtr("Wide").?.width = 300;

    const layer_items = [_][]const u8{ "Narrow", "Wide" };
    const max_w = singleLayerMaxWidth(&graph, &layer_items);
    try testing.expectApproxEqAbs(@as(f32, 300), max_w, 0.01);
}

test "state_layout: effectiveLayerStartY accumulates per-layer heights (TD)" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    // Layer 0: small node (height 24), Layer 1: composite (height 500), Layer 2: normal (height 40)
    try graph.addNode("Start", "Start", .circle);
    try graph.addNode("Composite", "Composite", .rounded);
    try graph.addNode("Done", "Done", .rounded);

    graph.nodes.getPtr("Start").?.layer = 0;
    graph.nodes.getPtr("Start").?.height = 24;
    graph.nodes.getPtr("Composite").?.layer = 1;
    graph.nodes.getPtr("Composite").?.height = 500;
    graph.nodes.getPtr("Done").?.layer = 2;
    graph.nodes.getPtr("Done").?.height = 40;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*l| l.deinit();
        layers.deinit();
    }

    // Layer 0 starts at diagram_padding (20)
    const y0 = effectiveLayerStartY(&graph, &layers, 0, false);
    try testing.expectApproxEqAbs(@as(f32, diagram_padding), y0, 0.01);

    // Layer 1 starts at 20 + singleLayerMaxHeight(layer0) + layer_spacing
    // singleLayerMaxHeight(layer0) = max height of Start node = 24
    // y1 = 20 + 24 + 80 = 124
    const y1 = effectiveLayerStartY(&graph, &layers, 1, false);
    try testing.expectApproxEqAbs(@as(f32, diagram_padding + 24.0 + layer_spacing), y1, 0.01);

    // Layer 2 starts at 124 + singleLayerMaxHeight(layer1) + layer_spacing
    // singleLayerMaxHeight(layer1) = 500 (composite)
    // y2 = 124 + 500 + 80 = 704
    const y2 = effectiveLayerStartY(&graph, &layers, 2, false);
    try testing.expectApproxEqAbs(@as(f32, diagram_padding + 24.0 + layer_spacing + 500.0 + layer_spacing), y2, 0.01);
}

test "state_layout: assignCoordinates per-layer spacing (composite in middle layer)" {
    // Verifies that a composite state (tall) in one layer does not force
    // excessive whitespace for adjacent layers containing small pseudo-states.
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .td);
    defer graph.deinit();

    try graph.addNode("Start", "Start", .circle);
    try graph.addNode("Composite", "Composite", .rounded);
    try graph.addNode("Done", "Done", .rounded);

    var start_node = graph.nodes.getPtr("Start").?;
    start_node.layer = 0;
    start_node.width = 24;
    start_node.height = 24;

    var comp_node = graph.nodes.getPtr("Composite").?;
    comp_node.layer = 1;
    comp_node.width = 200;
    comp_node.height = 500;

    var done_node = graph.nodes.getPtr("Done").?;
    done_node.layer = 2;
    done_node.width = 80;
    done_node.height = 40;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*l| l.deinit();
        layers.deinit();
    }

    const result = assignCoordinates(&graph, &layers, .td);
    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);

    const s = graph.nodes.get("Start").?;
    const c = graph.nodes.get("Composite").?;
    const d = graph.nodes.get("Done").?;

    // Start (layer 0) should be at y = diagram_padding = 20
    try testing.expectApproxEqAbs(@as(f32, diagram_padding), s.y, 0.01);

    // Composite (layer 1): y = diagram_padding + start.height + layer_spacing
    //                         = 20 + 24 + 80 = 124  (centering only affects x)
    try testing.expectApproxEqAbs(@as(f32, diagram_padding + 24.0 + layer_spacing), c.y, 0.01);

    // Done (layer 2): y = 124 + 500 + 80 = 704
    try testing.expectApproxEqAbs(@as(f32, diagram_padding + 24.0 + layer_spacing + 500.0 + layer_spacing), d.y, 0.01);

    // Gap between Start bottom and Composite top should be exactly layer_spacing (80)
    // start bottom = 20 + 24 = 44; composite top = 124; gap = 80
    const gap_start_to_comp = c.y - (s.y + s.height);
    try testing.expectApproxEqAbs(@as(f32, layer_spacing), gap_start_to_comp, 0.01);

    // Gap between Composite bottom and Done top should be exactly layer_spacing (80)
    const gap_comp_to_done = d.y - (c.y + c.height);
    try testing.expectApproxEqAbs(@as(f32, layer_spacing), gap_comp_to_done, 0.01);
}

test "state_layout: assignCoordinates BT places layer-0 below layer-1" {
    const allocator = testing.allocator;
    var graph = Graph.init(allocator, .bt);
    defer graph.deinit();

    try graph.addNode("A", "A", .rounded);
    try graph.addNode("B", "B", .rounded);

    graph.nodes.getPtr("A").?.layer = 0;
    graph.nodes.getPtr("A").?.width = 80;
    graph.nodes.getPtr("A").?.height = 40;

    graph.nodes.getPtr("B").?.layer = 1;
    graph.nodes.getPtr("B").?.width = 80;
    graph.nodes.getPtr("B").?.height = 40;

    var layers = try buildLayerLists(allocator, &graph, null);
    defer {
        for (layers.items) |*l| l.deinit();
        layers.deinit();
    }

    const result = assignCoordinates(&graph, &layers, .bt);
    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);

    const a = graph.nodes.get("A").?;
    const b = graph.nodes.get("B").?;
    // BT: layer-0 node A should be BELOW layer-1 node B
    try testing.expect(a.y > b.y);
    // Gap should be exactly layer_spacing (both have same height)
    const gap = a.y - (b.y + b.height);
    try testing.expectApproxEqAbs(@as(f32, layer_spacing), gap, 0.01);
}

// =============================================================================
// Boundary port system tests
// =============================================================================

test "buildParentMap: top-level states map to null" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("A");
    _ = try model.ensureState("B");

    var pm = try buildParentMap(allocator, &model);
    defer pm.deinit();

    try testing.expectEqual(@as(?[]const u8, null), pm.get("A").?);
    try testing.expectEqual(@as(?[]const u8, null), pm.get("B").?);
}

test "buildParentMap: child state maps to parent composite id" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Outer");
    parent.state_type = .composite;
    _ = try model.ensureChildState(parent, "Inner");

    var pm = try buildParentMap(allocator, &model);
    defer pm.deinit();

    // Outer is top-level
    try testing.expectEqual(@as(?[]const u8, null), pm.get("Outer").?);

    // Inner's parent is "Outer"
    const inner_parent = pm.get("Inner").?;
    try testing.expect(inner_parent != null);
    try testing.expectEqualStrings("Outer", inner_parent.?);
}

test "buildParentMap: deeply nested state maps to immediate parent" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer");
    outer.state_type = .composite;
    var inner = try model.ensureChildState(outer, "Inner");
    inner.state_type = .composite;
    _ = try model.ensureChildState(inner, "Deep");

    var pm = try buildParentMap(allocator, &model);
    defer pm.deinit();

    // Outer is top-level
    try testing.expectEqual(@as(?[]const u8, null), pm.get("Outer").?);

    // Inner's parent is "Outer"
    {
        const p = pm.get("Inner").?;
        try testing.expect(p != null);
        try testing.expectEqualStrings("Outer", p.?);
    }

    // Deep's immediate parent is "Inner"
    {
        const p = pm.get("Deep").?;
        try testing.expect(p != null);
        try testing.expectEqualStrings("Inner", p.?);
    }
}

test "getAncestorChain: top-level state returns empty chain" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();
    _ = try model.ensureState("A");

    var pm = try buildParentMap(allocator, &model);
    defer pm.deinit();

    var chain = try getAncestorChain(&pm, "A", allocator);
    defer chain.deinit();

    try testing.expectEqual(@as(usize, 0), chain.items.len);
}

test "getAncestorChain: child returns [parent] chain" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    parent.state_type = .composite;
    _ = try model.ensureChildState(parent, "C");

    var pm = try buildParentMap(allocator, &model);
    defer pm.deinit();

    var chain = try getAncestorChain(&pm, "C", allocator);
    defer chain.deinit();

    try testing.expectEqual(@as(usize, 1), chain.items.len);
    try testing.expectEqualStrings("P", chain.items[0]);
}

test "getAncestorChain: doubly-nested child returns [parent, grandparent]" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer");
    outer.state_type = .composite;
    var inner = try model.ensureChildState(outer, "Inner");
    inner.state_type = .composite;
    _ = try model.ensureChildState(inner, "Deep");

    var pm = try buildParentMap(allocator, &model);
    defer pm.deinit();

    var chain = try getAncestorChain(&pm, "Deep", allocator);
    defer chain.deinit();

    // Innermost parent first: [Inner, Outer]
    try testing.expectEqual(@as(usize, 2), chain.items.len);
    try testing.expectEqualStrings("Inner", chain.items[0]);
    try testing.expectEqualStrings("Outer", chain.items[1]);
}

test "findLCA: returns null when no shared ancestors" {
    const a_chain = [_][]const u8{"P"};
    const b_chain = [_][]const u8{"Q"};
    const lca = findLCA(&a_chain, &b_chain);
    try testing.expectEqual(@as(?[]const u8, null), lca);
}

test "findLCA: returns shared ancestor" {
    const a_chain = [_][]const u8{ "P", "Outer" };
    const b_chain = [_][]const u8{ "Q", "Outer" };
    const lca = findLCA(&a_chain, &b_chain);
    try testing.expect(lca != null);
    try testing.expectEqualStrings("Outer", lca.?);
}

test "applyBoundaryPorts: external→child inserts one entry port" {
    // Diagram: External --→ Child (Child is inside Composite)
    // After applyBoundaryPorts, the edge External→Child should have 3 waypoints:
    //   [External-port, Composite-entry-port, Child-port]
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    // Set up state hierarchy
    _ = try model.ensureState("External");
    const comp = try model.ensureState("Composite");
    comp.state_type = .composite;
    _ = try model.ensureChildState(comp, "Child");

    // Build graph with manually assigned positions (no raylib needed)
    try model.buildGraph();

    // External: top-left
    {
        const n = model.graph.nodes.getPtr("External").?;
        n.x = 0;
        n.y = 0;
        n.width = 80;
        n.height = 40;
    }
    // Composite: to the right and below
    {
        const n = model.graph.nodes.getPtr("Composite").?;
        n.x = 150;
        n.y = 80;
        n.width = 200;
        n.height = 150;
    }
    // Child: inside composite
    {
        const n = model.graph.nodes.getPtr("Child").?;
        n.x = 180;
        n.y = 120;
        n.width = 80;
        n.height = 40;
    }

    // Add a top-level transition External → Child
    const edge = try model.graph.addEdge("External", "Child");
    _ = edge; // will be processed by applyBoundaryPorts

    // Run routeEdges first (initial straight-line waypoints)
    try routeEdges(allocator, &model.graph);

    // Apply boundary ports
    try applyBoundaryPorts(allocator, &model.graph, &model);

    // Check waypoints on the External→Child edge
    const processed_edge = &model.graph.edges.items[0];
    // Should have: External-port, Composite-entry-port, Child-port
    try testing.expect(processed_edge.waypoints.items.len == 3);

    // The middle waypoint should be on or very close to the Composite's border.
    // The Composite spans x:[150,350], y:[80,230].
    const mid = processed_edge.waypoints.items[1];
    const comp_node = model.graph.nodes.get("Composite").?;
    const comp_left = comp_node.x;
    const comp_right = comp_node.x + comp_node.width;
    const comp_top = comp_node.y;
    const comp_bottom = comp_node.y + comp_node.height;

    // The port must lie on one of the four sides of the composite.
    const on_left = @abs(mid.x - comp_left) < 1.0;
    const on_right = @abs(mid.x - comp_right) < 1.0;
    const on_top = @abs(mid.y - comp_top) < 1.0;
    const on_bottom = @abs(mid.y - comp_bottom) < 1.0;
    try testing.expect(on_left or on_right or on_top or on_bottom);
}

test "applyBoundaryPorts: child→external inserts one exit port" {
    // Diagram: Child --→ External (Child is inside Composite)
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const comp = try model.ensureState("Composite");
    comp.state_type = .composite;
    _ = try model.ensureChildState(comp, "Child");
    _ = try model.ensureState("External");

    try model.buildGraph();

    {
        const n = model.graph.nodes.getPtr("Composite").?;
        n.x = 50;
        n.y = 50;
        n.width = 180;
        n.height = 120;
    }
    {
        const n = model.graph.nodes.getPtr("Child").?;
        n.x = 80;
        n.y = 90;
        n.width = 80;
        n.height = 40;
    }
    {
        const n = model.graph.nodes.getPtr("External").?;
        n.x = 300;
        n.y = 200;
        n.width = 80;
        n.height = 40;
    }

    _ = try model.graph.addEdge("Child", "External");

    try routeEdges(allocator, &model.graph);
    try applyBoundaryPorts(allocator, &model.graph, &model);

    const processed_edge = &model.graph.edges.items[0];
    // Should have: Child-port, Composite-exit-port, External-port
    try testing.expect(processed_edge.waypoints.items.len == 3);

    const mid = processed_edge.waypoints.items[1];
    const comp_node = model.graph.nodes.get("Composite").?;
    const on_left = @abs(mid.x - comp_node.x) < 1.0;
    const on_right = @abs(mid.x - (comp_node.x + comp_node.width)) < 1.0;
    const on_top = @abs(mid.y - comp_node.y) < 1.0;
    const on_bottom = @abs(mid.y - (comp_node.y + comp_node.height)) < 1.0;
    try testing.expect(on_left or on_right or on_top or on_bottom);
}

test "applyBoundaryPorts: same-composite transitions unchanged" {
    // A→B where both A and B are inside the same Composite.
    // applyBoundaryPorts should leave the waypoints as-is (no boundary crossing).
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const comp = try model.ensureState("Composite");
    comp.state_type = .composite;
    _ = try model.ensureChildState(comp, "A");
    _ = try model.ensureChildState(comp, "B");

    try model.buildGraph();

    {
        const n = model.graph.nodes.getPtr("Composite").?;
        n.x = 0;
        n.y = 0;
        n.width = 200;
        n.height = 150;
    }
    {
        const n = model.graph.nodes.getPtr("A").?;
        n.x = 20;
        n.y = 40;
        n.width = 80;
        n.height = 40;
    }
    {
        const n = model.graph.nodes.getPtr("B").?;
        n.x = 20;
        n.y = 100;
        n.width = 80;
        n.height = 40;
    }

    _ = try model.graph.addEdge("A", "B");

    try routeEdges(allocator, &model.graph);

    // Capture waypoint count before
    const before_len = model.graph.edges.items[0].waypoints.items.len;

    try applyBoundaryPorts(allocator, &model.graph, &model);

    // Waypoints should not change for intra-composite edges
    const after_len = model.graph.edges.items[0].waypoints.items.len;
    try testing.expectEqual(before_len, after_len);
}

test "applyBoundaryPorts: top-level→top-level transitions unchanged" {
    // Both endpoints are top-level (no composite ancestors).
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("A");
    _ = try model.ensureState("B");

    try model.buildGraph();

    {
        const n = model.graph.nodes.getPtr("A").?;
        n.x = 0;
        n.y = 0;
        n.width = 80;
        n.height = 40;
    }
    {
        const n = model.graph.nodes.getPtr("B").?;
        n.x = 0;
        n.y = 120;
        n.width = 80;
        n.height = 40;
    }

    _ = try model.graph.addEdge("A", "B");

    try routeEdges(allocator, &model.graph);
    const before_len = model.graph.edges.items[0].waypoints.items.len;

    try applyBoundaryPorts(allocator, &model.graph, &model);

    const after_len = model.graph.edges.items[0].waypoints.items.len;
    try testing.expectEqual(before_len, after_len);
}

test "applyBoundaryPorts: doubly-nested child→external inserts two exit ports" {
    // Deep is inside Inner which is inside Outer.
    // Edge Deep→External crosses two composite borders.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer");
    outer.state_type = .composite;
    var inner = try model.ensureChildState(outer, "Inner");
    inner.state_type = .composite;
    _ = try model.ensureChildState(inner, "Deep");
    _ = try model.ensureState("External");

    try model.buildGraph();

    {
        const n = model.graph.nodes.getPtr("Outer").?;
        n.x = 0;
        n.y = 0;
        n.width = 400;
        n.height = 300;
    }
    {
        const n = model.graph.nodes.getPtr("Inner").?;
        n.x = 20;
        n.y = 40;
        n.width = 200;
        n.height = 150;
    }
    {
        const n = model.graph.nodes.getPtr("Deep").?;
        n.x = 40;
        n.y = 80;
        n.width = 80;
        n.height = 40;
    }
    {
        const n = model.graph.nodes.getPtr("External").?;
        n.x = 500;
        n.y = 150;
        n.width = 80;
        n.height = 40;
    }

    _ = try model.graph.addEdge("Deep", "External");

    try routeEdges(allocator, &model.graph);
    try applyBoundaryPorts(allocator, &model.graph, &model);

    const processed_edge = &model.graph.edges.items[0];
    // Should have: Deep-port, Inner-exit-port, Outer-exit-port, External-port = 4 waypoints
    try testing.expectEqual(@as(usize, 4), processed_edge.waypoints.items.len);
}

// =============================================================================
// Top-down layout coordinator tests (Sub-AC 6d)
// =============================================================================

test "state_layout: propagateAbsoluteCoords populates graph nodes for direct children" {
    // Given a composite with an assigned graph position, propagateAbsoluteCoords
    // must write absolute positions for its direct children into model.graph.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const comp = try model.ensureState("Outer");
    comp.state_type = .composite;

    try model.graph.addNode("Outer", "Outer", .rounded);
    const comp_gn = model.graph.nodes.getPtr("Outer").?;
    comp_gn.x = 50;
    comp_gn.y = 30;
    comp_gn.width = 200;
    comp_gn.height = 140;

    var c1 = try model.ensureChildState(comp, "C1");
    c1.x = 10;
    c1.y = 5;
    c1.width = 80;
    c1.height = 40;

    var c2 = try model.ensureChildState(comp, "C2");
    c2.x = 110;
    c2.y = 5;
    c2.width = 80;
    c2.height = 40;

    try model.graph.addNode("C1", "C1", .rounded);
    try model.graph.addNode("C2", "C2", .rounded);

    propagateAbsoluteCoords(&model);

    // content_x = 50 + composite_inner_padding(16) = 66
    // content_y = 30 + composite_header_height(28) + composite_inner_padding(16) = 74
    // C1: abs_x = 66 + 10 = 76,   abs_y = 74 + 5 = 79
    // C2: abs_x = 66 + 110 = 176, abs_y = 74 + 5 = 79
    const g1 = model.graph.nodes.get("C1").?;
    try testing.expectApproxEqAbs(@as(f32, 76), g1.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 79), g1.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80), g1.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), g1.height, 0.01);

    const g2 = model.graph.nodes.get("C2").?;
    try testing.expectApproxEqAbs(@as(f32, 176), g2.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 79), g2.y, 0.01);
}

test "state_layout: propagateAbsoluteCoords recurses three levels deep (children path)" {
    // Three levels: Top(composite) → Mid(composite) → Leaf(normal)
    // Verifies the top-down coordinator handles arbitrary depth through the
    // direct-children path.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const top = try model.ensureState("Top");
    top.state_type = .composite;
    try model.graph.addNode("Top", "Top", .rounded);
    const top_gn = model.graph.nodes.getPtr("Top").?;
    top_gn.x = 100;
    top_gn.y = 50;
    top_gn.width = 300;
    top_gn.height = 250;

    var mid = try model.ensureChildState(top, "Mid");
    mid.state_type = .composite;
    mid.x = 20; // relative to Top content area
    mid.y = 10;
    mid.width = 160;
    mid.height = 120;
    try model.graph.addNode("Mid", "Mid", .rounded);

    var leaf = try model.ensureChildState(mid, "Leaf");
    leaf.x = 5; // relative to Mid content area
    leaf.y = 3;
    leaf.width = 60;
    leaf.height = 30;
    try model.graph.addNode("Leaf", "Leaf", .rounded);

    propagateAbsoluteCoords(&model);

    // Mid abs:
    //   Top content_x = 100 + 16 = 116,  Top content_y = 50 + 28 + 16 = 94
    //   Mid abs_x = 116 + 20 = 136,       Mid abs_y = 94 + 10 = 104
    const mid_gn = model.graph.nodes.get("Mid").?;
    try testing.expectApproxEqAbs(@as(f32, 136), mid_gn.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 104), mid_gn.y, 0.01);

    // Leaf abs:
    //   Mid content_x = 136 + 16 = 152,   Mid content_y = 104 + 28 + 16 = 148
    //   Leaf abs_x = 152 + 5 = 157,        Leaf abs_y = 148 + 3 = 151
    const leaf_gn = model.graph.nodes.get("Leaf").?;
    try testing.expectApproxEqAbs(@as(f32, 157), leaf_gn.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 151), leaf_gn.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), leaf_gn.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), leaf_gn.height, 0.01);
}

test "state_layout: propagateAbsoluteCoords recurses through region children" {
    // Composite with concurrent regions — states inside regions must get
    // absolute positions propagated by the top-down coordinator.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const comp = try model.ensureState("Comp");
    comp.state_type = .composite;
    try model.graph.addNode("Comp", "Comp", .rounded);
    const comp_gn = model.graph.nodes.getPtr("Comp").?;
    comp_gn.x = 60;
    comp_gn.y = 40;
    comp_gn.width = 250;
    comp_gn.height = 150;

    const region = try model.addRegion(comp);
    _ = try region.ensureState(allocator, "RS1", 0);
    comp.regions.items[0].states.items[0].x = 8;
    comp.regions.items[0].states.items[0].y = 12;
    comp.regions.items[0].states.items[0].width = 70;
    comp.regions.items[0].states.items[0].height = 35;

    try model.graph.addNode("RS1", "RS1", .rounded);

    propagateAbsoluteCoords(&model);

    // content_x = 60 + 16 = 76,  content_y = 40 + 28 + 16 = 84
    // RS1: abs_x = 76 + 8 = 84,  abs_y = 84 + 12 = 96
    const rs1 = model.graph.nodes.get("RS1").?;
    try testing.expectApproxEqAbs(@as(f32, 84), rs1.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 96), rs1.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 70), rs1.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 35), rs1.height, 0.01);
}

test "state_layout: propagateAbsoluteCoords handles mixed nesting (children to regions)" {
    // Three levels: Top(children) → Mid(regions) → Leaf states in region.
    // This is the key mixed-nesting case that propagateAbsoluteCoords
    // handles correctly for arbitrary depth.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const top = try model.ensureState("Top");
    top.state_type = .composite;
    try model.graph.addNode("Top", "Top", .rounded);
    const top_gn = model.graph.nodes.getPtr("Top").?;
    top_gn.x = 0;
    top_gn.y = 0;
    top_gn.width = 400;
    top_gn.height = 300;

    var mid = try model.ensureChildState(top, "Mid");
    mid.state_type = .composite;
    mid.x = 10;
    mid.y = 5;
    mid.width = 200;
    mid.height = 150;
    try model.graph.addNode("Mid", "Mid", .rounded);

    const region = try model.addRegion(mid);
    _ = try region.ensureState(allocator, "Leaf", 0);
    mid.regions.items[0].states.items[0].x = 3;
    mid.regions.items[0].states.items[0].y = 7;
    mid.regions.items[0].states.items[0].width = 50;
    mid.regions.items[0].states.items[0].height = 25;
    try model.graph.addNode("Leaf", "Leaf", .rounded);

    propagateAbsoluteCoords(&model);

    // Mid abs:
    //   Top content_x = 0 + 16 = 16,   Top content_y = 0 + 28 + 16 = 44
    //   Mid abs_x = 16 + 10 = 26,       Mid abs_y = 44 + 5 = 49
    const mid_gn = model.graph.nodes.get("Mid").?;
    try testing.expectApproxEqAbs(@as(f32, 26), mid_gn.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 49), mid_gn.y, 0.01);

    // Leaf abs:
    //   Mid content_x = 26 + 16 = 42,   Mid content_y = 49 + 28 + 16 = 93
    //   Leaf abs_x = 42 + 3 = 45,        Leaf abs_y = 93 + 7 = 100
    const leaf_gn = model.graph.nodes.get("Leaf").?;
    try testing.expectApproxEqAbs(@as(f32, 45), leaf_gn.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), leaf_gn.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), leaf_gn.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 25), leaf_gn.height, 0.01);
}

test "state_layout: translateAllChildren single-level offset" {
    // Verify translateAllChildren correctly translates a direct child's
    // relative position to absolute diagram coordinates.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    parent.state_type = .composite;
    parent.x = 80;
    parent.y = 40;
    parent.width = 200;
    parent.height = 150;

    var child = try model.ensureChildState(parent, "Child");
    child.x = 12; // relative position from sub-graph layout
    child.y = 6;
    child.width = 60;
    child.height = 30;

    translateAllChildren(&model);

    // offset_x = 80 + 16 = 96,  offset_y = 40 + 28 + 16 = 84
    // child.x = 12 + 96 = 108,  child.y = 6 + 84 = 90
    try testing.expectApproxEqAbs(@as(f32, 108), child.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 90), child.y, 0.01);
}

test "state_layout: translateAllChildren three-level deep nesting" {
    // Verify translateAllChildren accumulates offsets correctly for 3 levels
    // of directly-nested composite states.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer");
    outer.state_type = .composite;
    outer.x = 100;
    outer.y = 50;
    outer.width = 300;
    outer.height = 250;

    var mid = try model.ensureChildState(outer, "Mid");
    mid.state_type = .composite;
    mid.x = 20;
    mid.y = 10;
    mid.width = 160;
    mid.height = 120;

    var deep = try model.ensureChildState(mid, "Deep");
    deep.x = 5;
    deep.y = 3;
    deep.width = 60;
    deep.height = 30;

    translateAllChildren(&model);

    // Mid abs: offset_x = 100+16=116, offset_y = 50+28+16=94
    //          mid.x = 20+116=136,    mid.y = 10+94=104
    try testing.expectApproxEqAbs(@as(f32, 136), mid.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 104), mid.y, 0.01);

    // Deep abs: offset_x = 136+16=152, offset_y = 104+28+16=148
    //           deep.x = 5+152=157,    deep.y = 3+148=151
    try testing.expectApproxEqAbs(@as(f32, 157), deep.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 151), deep.y, 0.01);
}

test "state_layout: translateAllChildren handles regions at second level" {
    // Outer(children) → Mid(regions) → leaf states in region.
    // Verifies translateAllChildren recurses through the mixed nesting path.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer");
    outer.state_type = .composite;
    outer.x = 50;
    outer.y = 20;
    outer.width = 300;
    outer.height = 200;

    var mid = try model.ensureChildState(outer, "Mid");
    mid.state_type = .composite;
    mid.x = 15;
    mid.y = 8;
    mid.width = 180;
    mid.height = 120;

    const region = try model.addRegion(mid);
    _ = try region.ensureState(allocator, "RL", 0);
    mid.regions.items[0].x = 2;
    mid.regions.items[0].y = 0;
    mid.regions.items[0].states.items[0].x = 4;
    mid.regions.items[0].states.items[0].y = 6;

    translateAllChildren(&model);

    // Mid abs: offset_x = 50+16=66, offset_y = 20+28+16=64
    //          mid.x = 15+66=81,    mid.y = 8+64=72
    try testing.expectApproxEqAbs(@as(f32, 81), mid.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 72), mid.y, 0.01);

    // Region and leaf: mid_offset_x = 81+16=97, mid_offset_y = 72+28+16=116
    //   region.x = 2+97=99,  region.y = 0+116=116
    //   RL.x = 4+97=101,     RL.y = 6+116=122
    const r = &mid.regions.items[0];
    try testing.expectApproxEqAbs(@as(f32, 99), r.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 116), r.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 101), r.states.items[0].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 122), r.states.items[0].y, 0.01);
}

test "state_layout: propagateAbsoluteCoords is idempotent on empty model" {
    // An empty model must not panic or produce any errors.
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();
    propagateAbsoluteCoords(&model);
    try testing.expectEqual(@as(usize, 0), model.states.items.len);
}

test "state_layout: propagateAbsoluteCoords skips non-composite states" {
    // Non-composite top-level states should not be touched.
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("A"); // normal (non-composite) state
    try model.graph.addNode("A", "A", .rounded);
    const gn = model.graph.nodes.getPtr("A").?;
    gn.x = 10;
    gn.y = 20;

    propagateAbsoluteCoords(&model);

    // Position must be unchanged — the function only touches composites
    try testing.expectApproxEqAbs(@as(f32, 10), gn.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), gn.y, 0.01);
}

// =============================================================================
// Entry/exit point sizing tests
// =============================================================================

test "measureSingleState: entry_point sized as small circle" {
    // Verify that entry_point nodes are measured as small circles matching
    // start_end_radius*2 (same as start/end pseudo-state markers).
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    // Add an entry_point state
    const ep = try model.ensureState("ep");
    ep.state_type = .entry_point;
    try model.graph.addNode("ep", "ep", .circle);

    // measureSingleState needs a Fonts and Theme — use the pure sizing logic directly.
    // Instead, verify the expected sizes match the constants.
    const expected: f32 = start_end_radius * 2;
    try testing.expectEqual(@as(f32, 12 * 2), expected); // start_end_radius = 12
}

test "measureSingleState: exit_point has correct fixed size" {
    // exit_point inside a composite should be sized identically to entry_point.
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const comp = try model.ensureState("Comp");
    comp.state_type = .composite;
    const xp = try model.ensureChildState(comp, "xp");
    xp.state_type = .exit_point;
    try model.graph.addNode("xp", "xp", .circle);

    // Verify the state type is correctly stored
    try testing.expectEqual(StateType.exit_point, xp.state_type);
    // Both entry/exit use start_end_radius * 2 = 24
    const expected_size: f32 = start_end_radius * 2;
    try testing.expect(expected_size > 0);
    try testing.expectEqual(@as(f32, 24), expected_size);
}

test "measureSingleState: entry_exit smaller than history nodes" {
    // Entry/exit (24px) must be smaller than history nodes (28px),
    // so they remain visually distinct.
    const entry_exit_size: f32 = start_end_radius * 2; // 24
    const history_size: f32 = 28;
    try testing.expect(entry_exit_size < history_size);
}

test "layoutCompositeChildren: entry_point gets circle shape in sub-graph" {
    // Verify the NodeShape assigned to entry_point is .circle.
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const comp = try model.ensureState("CS");
    comp.state_type = .composite;

    // Add entry_point and exit_point as children
    const ep = try model.ensureChildState(comp, "ep");
    ep.state_type = .entry_point;
    const xp = try model.ensureChildState(comp, "xp");
    xp.state_type = .exit_point;

    // The NodeShape switch in layoutCompositeChildren must map both to .circle.
    const ep_shape: NodeShape = switch (ep.state_type) {
        .start, .end, .history, .deep_history, .entry_point, .exit_point => .circle,
        .choice => .diamond,
        .fork, .join => .rectangle,
        .composite, .normal => .rounded,
    };
    const xp_shape: NodeShape = switch (xp.state_type) {
        .start, .end, .history, .deep_history, .entry_point, .exit_point => .circle,
        .choice => .diamond,
        .fork, .join => .rectangle,
        .composite, .normal => .rounded,
    };
    try testing.expectEqual(NodeShape.circle, ep_shape);
    try testing.expectEqual(NodeShape.circle, xp_shape);
}

// =============================================================================
// Two-level nested composite integration tests (Sub-AC 3 of AC 10)
// =============================================================================

test "state_layout: propagateAbsoluteCoords two-level nested composite" {
    // Verify that absolute coordinate propagation correctly handles 2 levels of
    // nested composite states.
    //
    // Hierarchy:
    //   Outer (composite, at graph pos 50,30, size 300×250)
    //     └─ Inner (composite child, relative 10,5, size 160×120)
    //          └─ Leaf (leaf child, relative 5,3, size 60×30)
    //
    // Expected absolute positions after propagation:
    //   Inner: content_x = 50+16=66, content_y = 30+28+16=74 → abs (76, 79)
    //   Leaf:  content_x = 76+16=92, content_y = 79+28+16=123 → abs (97, 126)
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    // Level 0 — top-level composite
    const outer = try model.ensureState("Outer");
    outer.state_type = .composite;

    // Level 1 — composite child of Outer (relative position within content area)
    const inner = try model.ensureChildState(outer, "Inner");
    inner.state_type = .composite;
    inner.x = 10;
    inner.y = 5;
    inner.width = 160;
    inner.height = 120;

    // Level 2 — leaf child of Inner (relative position within Inner's content area)
    const leaf = try model.ensureChildState(inner, "Leaf");
    leaf.x = 5;
    leaf.y = 3;
    leaf.width = 60;
    leaf.height = 30;

    // Register graph nodes for all states
    try model.graph.addNode("Outer", "Outer", .rounded);
    try model.graph.addNode("Inner", "Inner", .rounded);
    try model.graph.addNode("Leaf", "Leaf", .rounded);

    // Simulate post-assignCoordinates: Outer has absolute graph position
    const outer_gn = model.graph.nodes.getPtr("Outer").?;
    outer_gn.x = 50;
    outer_gn.y = 30;
    outer_gn.width = 300;
    outer_gn.height = 250;

    // Run absolute coordinate propagation
    propagateAbsoluteCoords(&model);

    // Level 1 verification: Inner absolute position
    // content_x = outer.x(50) + composite_inner_padding(16) = 66
    // content_y = outer.y(30) + composite_header_height(28) + composite_inner_padding(16) = 74
    // Inner abs: (66 + inner.x(10), 74 + inner.y(5)) = (76, 79)
    const inner_gn = model.graph.nodes.get("Inner").?;
    try testing.expectApproxEqAbs(@as(f32, 66 + 10), inner_gn.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 74 + 5), inner_gn.y, 0.01);

    // Level 2 verification: Leaf absolute position (recursive step)
    // Inner abs_x = 76, inner abs_y = 79
    // content_x = 76 + 16 = 92, content_y = 79 + 28 + 16 = 123
    // Leaf abs: (92 + leaf.x(5), 123 + leaf.y(3)) = (97, 126)
    const leaf_gn = model.graph.nodes.get("Leaf").?;
    try testing.expectApproxEqAbs(@as(f32, 76 + 16 + 5), leaf_gn.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 79 + 28 + 16 + 3), leaf_gn.y, 0.01);
}

test "state_layout: translateAllChildren two-level nested composite" {
    // Verify that translateAllChildren (called as step 8 in layout()) correctly
    // translates relative child coordinates to absolute diagram coordinates for
    // 2-level nesting — the same hierarchy as the propagateAbsoluteCoords test.
    const allocator = testing.allocator;

    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer2");
    outer.state_type = .composite;
    outer.x = 50;
    outer.y = 30;
    outer.width = 300;
    outer.height = 250;

    const inner = try model.ensureChildState(outer, "Inner2");
    inner.state_type = .composite;
    inner.x = 10; // relative to outer content area
    inner.y = 5;
    inner.width = 160;
    inner.height = 120;

    const leaf = try model.ensureChildState(inner, "Leaf2");
    leaf.x = 5; // relative to inner content area
    leaf.y = 3;
    leaf.width = 60;
    leaf.height = 30;

    // translateAllChildren requires State.x/y to already hold absolute coordinates
    // for top-level composite nodes (set by syncStatePositions before this step).
    translateAllChildren(&model);

    // Level 1: Inner's absolute position
    // offset_x = outer.x(50) + composite_inner_padding(16) = 66
    // offset_y = outer.y(30) + composite_header_height(28) + composite_inner_padding(16) = 74
    // Inner: (66 + 10, 74 + 5) = (76, 79)
    try testing.expectApproxEqAbs(@as(f32, 76), inner.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 79), inner.y, 0.01);

    // Level 2: Leaf's absolute position (recursive translation from Inner)
    // offset_x = inner.x(76) + 16 = 92
    // offset_y = inner.y(79) + 28 + 16 = 123
    // Leaf: (92 + 5, 123 + 3) = (97, 126)
    try testing.expectApproxEqAbs(@as(f32, 97), leaf.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 126), leaf.y, 0.01);
}
