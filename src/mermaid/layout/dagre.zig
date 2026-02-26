const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("../models/graph.zig");
const Graph = graph_mod.Graph;
const GraphNode = graph_mod.GraphNode;
const GraphEdge = graph_mod.GraphEdge;
const Point = graph_mod.Point;
const Direction = graph_mod.Direction;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const Theme = @import("../../theme/theme.zig").Theme;

const NODE_PADDING_H: f32 = 20;
const NODE_PADDING_V: f32 = 10;
const NODE_SPACING: f32 = 40;
const LAYER_SPACING: f32 = 80;
const MIN_NODE_WIDTH: f32 = 60;
const MIN_NODE_HEIGHT: f32 = 40;
const DIAGRAM_PADDING: f32 = 20;

pub const LayoutResult = struct {
    width: f32,
    height: f32,
};

pub fn layout(allocator: Allocator, graph: *Graph, fonts: *const Fonts, theme: *const Theme, available_width: f32) !LayoutResult {
    _ = available_width;

    if (graph.nodes.count() == 0) {
        return .{ .width = 0, .height = 0 };
    }

    // Step 1: Measure nodes
    measureNodes(graph, fonts, theme);

    // Step 2: Layer assignment via BFS
    try assignLayers(allocator, graph);

    // Step 3: Order nodes within layers (barycenter heuristic)
    var layers = try buildLayerLists(allocator, graph);
    defer {
        for (layers.items) |*layer| {
            layer.deinit();
        }
        layers.deinit();
    }

    try minimizeCrossings(graph, &layers);

    // Step 4: Assign coordinates
    const is_horizontal = (graph.direction == .LR or graph.direction == .RL);
    const result = assignCoordinates(graph, &layers, is_horizontal);

    // Step 5: Route edges
    try routeEdges(allocator, graph);

    return result;
}

fn measureNodes(graph: *Graph, fonts: *const Fonts, theme: *const Theme) void {
    var it = graph.nodes.iterator();
    while (it.next()) |entry| {
        var node = entry.value_ptr;
        const font_size = theme.body_font_size;
        const measured = fonts.measure(node.label, font_size, false, false, false);
        node.width = @max(MIN_NODE_WIDTH, measured.x + NODE_PADDING_H * 2);
        node.height = @max(MIN_NODE_HEIGHT, measured.y + NODE_PADDING_V * 2);

        // Adjust dimensions for specific shapes
        switch (node.shape) {
            .diamond => {
                // Diamond needs more space since content is rotated
                node.width = @max(node.width, node.height) * 1.4;
                node.height = node.width;
            },
            .circle, .double_circle => {
                const diameter = @max(node.width, node.height);
                node.width = diameter;
                node.height = diameter;
            },
            .hexagon => {
                node.width += 20; // extra space for angled sides
            },
            else => {},
        }
    }
}

fn assignLayers(allocator: Allocator, graph: *Graph) !void {
    // Compute in-degree for each node
    var in_degree = std.StringHashMap(i32).init(allocator);
    defer in_degree.deinit();

    var node_it = graph.nodes.iterator();
    while (node_it.next()) |entry| {
        try in_degree.put(entry.key_ptr.*, 0);
    }

    for (graph.edges.items) |edge| {
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
        var any_it = graph.nodes.iterator();
        if (any_it.next()) |entry| {
            try queue.append(entry.key_ptr.*);
            entry.value_ptr.layer = 0;
        }
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const current_id = queue.items[head];
        head += 1;

        const current_layer = if (graph.nodes.get(current_id)) |n| n.layer else 0;

        for (graph.edges.items) |edge| {
            if (std.mem.eql(u8, edge.from, current_id)) {
                if (graph.nodes.getPtr(edge.to)) |target| {
                    if (target.layer == -1) {
                        target.layer = current_layer + 1;
                        try queue.append(edge.to);
                    }
                }
            }
        }
    }

    // Assign unvisited nodes to layer 0
    var fix_it = graph.nodes.iterator();
    while (fix_it.next()) |entry| {
        if (entry.value_ptr.layer == -1) {
            entry.value_ptr.layer = 0;
        }
    }
}

fn buildLayerLists(allocator: Allocator, graph: *Graph) !std.ArrayList(std.ArrayList([]const u8)) {
    // Find max layer
    var max_layer: i32 = 0;
    var it = graph.nodes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.layer > max_layer) max_layer = entry.value_ptr.layer;
    }

    var layers = std.ArrayList(std.ArrayList([]const u8)).init(allocator);
    errdefer {
        for (layers.items) |*layer| {
            layer.deinit();
        }
        layers.deinit();
    }
    var l: i32 = 0;
    while (l <= max_layer) : (l += 1) {
        try layers.append(std.ArrayList([]const u8).init(allocator));
    }

    var it2 = graph.nodes.iterator();
    while (it2.next()) |entry| {
        const layer_idx: usize = @intCast(entry.value_ptr.layer);
        if (layer_idx < layers.items.len) {
            try layers.items[layer_idx].append(entry.key_ptr.*);
        }
    }

    return layers;
}

fn minimizeCrossings(graph: *Graph, layers: *std.ArrayList(std.ArrayList([]const u8))) !void {
    // Single-pass barycenter heuristic
    if (layers.items.len < 2) return;

    var i: usize = 1;
    while (i < layers.items.len) : (i += 1) {
        // For each node in this layer, compute barycenter (avg position of neighbors in prev layer)
        const prev_layer = &layers.items[i - 1];
        const cur_layer = &layers.items[i];

        // Build position map for prev layer
        var positions = std.StringHashMap(f32).init(graph.allocator);
        defer positions.deinit();
        for (prev_layer.items, 0..) |node_id, idx| {
            try positions.put(node_id, @floatFromInt(idx));
        }

        // Compute barycenters
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
            if (count > 0) {
                try bary.put(node_id, sum / count);
            } else {
                try bary.put(node_id, 0);
            }
        }

        // Sort current layer by barycenter (simple insertion sort)
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

fn assignCoordinates(graph: *Graph, layers: *std.ArrayList(std.ArrayList([]const u8)), is_horizontal: bool) LayoutResult {
    var total_width: f32 = 0;
    var total_height: f32 = 0;

    for (layers.items, 0..) |layer, layer_idx| {
        // Compute total width of this layer
        var layer_extent: f32 = 0;
        for (layer.items) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                if (is_horizontal) {
                    layer_extent += node.height + NODE_SPACING;
                } else {
                    layer_extent += node.width + NODE_SPACING;
                }
            }
        }
        if (layer.items.len > 0) layer_extent -= NODE_SPACING;

        // Position nodes centered
        var offset: f32 = DIAGRAM_PADDING;
        // Center the layer
        if (!is_horizontal) {
            // For vertical layout, center horizontally
            // We'll adjust after computing all layers
        }

        for (layer.items) |node_id| {
            if (graph.nodes.getPtr(node_id)) |node| {
                if (is_horizontal) {
                    node.x = DIAGRAM_PADDING + @as(f32, @floatFromInt(layer_idx)) * (maxNodeWidth(graph, layers, true) + LAYER_SPACING);
                    node.y = offset;
                    offset += node.height + NODE_SPACING;
                } else {
                    node.x = offset;
                    node.y = DIAGRAM_PADDING + @as(f32, @floatFromInt(layer_idx)) * (maxNodeHeight(graph, layers, false) + LAYER_SPACING);
                    offset += node.width + NODE_SPACING;
                }
            }
        }

        if (is_horizontal) {
            if (offset > total_height) total_height = offset;
        } else {
            if (offset > total_width) total_width = offset;
        }
    }

    // Compute final bounds
    if (is_horizontal) {
        if (layers.items.len > 0) {
            total_width = DIAGRAM_PADDING * 2 + @as(f32, @floatFromInt(layers.items.len)) * (maxNodeWidth(graph, layers, true) + LAYER_SPACING) - LAYER_SPACING;
        }
        total_height += DIAGRAM_PADDING;
    } else {
        if (layers.items.len > 0) {
            total_height = DIAGRAM_PADDING * 2 + @as(f32, @floatFromInt(layers.items.len)) * (maxNodeHeight(graph, layers, false) + LAYER_SPACING) - LAYER_SPACING;
        }
        total_width += DIAGRAM_PADDING;
    }

    // Center layers
    centerLayers(graph, layers, total_width, total_height, is_horizontal);

    // Handle RL/BT by mirroring
    if (graph.direction == .RL) {
        var it = graph.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.x = total_width - entry.value_ptr.x - entry.value_ptr.width;
        }
    } else if (graph.direction == .BT) {
        var it = graph.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.y = total_height - entry.value_ptr.y - entry.value_ptr.height;
        }
    }

    return .{ .width = total_width, .height = total_height };
}

fn maxNodeWidth(graph: *Graph, layers: *std.ArrayList(std.ArrayList([]const u8)), _: bool) f32 {
    var max_w: f32 = MIN_NODE_WIDTH;
    for (layers.items) |layer| {
        for (layer.items) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                if (node.width > max_w) max_w = node.width;
            }
        }
    }
    return max_w;
}

fn maxNodeHeight(graph: *Graph, layers: *std.ArrayList(std.ArrayList([]const u8)), _: bool) f32 {
    var max_h: f32 = MIN_NODE_HEIGHT;
    for (layers.items) |layer| {
        for (layer.items) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                if (node.height > max_h) max_h = node.height;
            }
        }
    }
    return max_h;
}

fn centerLayers(graph: *Graph, layers: *std.ArrayList(std.ArrayList([]const u8)), total_width: f32, total_height: f32, is_horizontal: bool) void {
    for (layers.items) |layer| {
        if (layer.items.len == 0) continue;

        // Find current extent of this layer
        var min_pos: f32 = std.math.inf(f32);
        var max_pos: f32 = -std.math.inf(f32);

        for (layer.items) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                if (is_horizontal) {
                    if (node.y < min_pos) min_pos = node.y;
                    if (node.y + node.height > max_pos) max_pos = node.y + node.height;
                } else {
                    if (node.x < min_pos) min_pos = node.x;
                    if (node.x + node.width > max_pos) max_pos = node.x + node.width;
                }
            }
        }

        const extent = max_pos - min_pos;
        const available = if (is_horizontal) total_height else total_width;
        const shift = (available - extent) / 2.0 - min_pos;

        for (layer.items) |node_id| {
            if (graph.nodes.getPtr(node_id)) |node| {
                if (is_horizontal) {
                    node.y += shift;
                } else {
                    node.x += shift;
                }
            }
        }
    }
}

fn routeEdges(allocator: Allocator, graph: *Graph) !void {
    for (graph.edges.items) |*edge| {
        const from_node = graph.nodes.get(edge.from) orelse continue;
        const to_node = graph.nodes.get(edge.to) orelse continue;

        // Compute center points
        const from_cx = from_node.x + from_node.width / 2;
        const from_cy = from_node.y + from_node.height / 2;
        const to_cx = to_node.x + to_node.width / 2;
        const to_cy = to_node.y + to_node.height / 2;

        // Compute edge ports (intersection with node boundary)
        const start = nodePort(from_node, to_cx, to_cy);
        const end = nodePort(to_node, from_cx, from_cy);

        edge.waypoints.clearRetainingCapacity();
        try edge.waypoints.append(start);
        _ = allocator;
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

    // Determine which side the edge exits from
    const hw = node.width / 2;
    const hh = node.height / 2;

    if (abs_dx * hh > abs_dy * hw) {
        // Exits left or right
        const sign: f32 = if (dx > 0) 1.0 else -1.0;
        return .{
            .x = cx + hw * sign,
            .y = cy + dy * (hw / abs_dx),
        };
    } else {
        // Exits top or bottom
        const sign: f32 = if (dy > 0) 1.0 else -1.0;
        return .{
            .x = cx + dx * (hh / abs_dy),
            .y = cy + hh * sign,
        };
    }
}
