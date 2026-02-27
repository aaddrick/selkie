const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Direction = enum {
    td,
    bt,
    lr,
    rl,
};

pub const NodeShape = enum {
    rectangle,
    rounded,
    diamond,
    circle,
    hexagon,
    parallelogram,
    trapezoid,
    cylinder,
    stadium,
    subroutine,
    asymmetric,
    double_circle,
};

pub const EdgeStyle = enum {
    solid,
    dotted,
    thick,
};

pub const ArrowHead = enum {
    arrow,
    circle,
    cross,
    none,
};

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const GraphNode = struct {
    id: []const u8,
    label: []const u8,
    shape: NodeShape,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    layer: i32 = -1,
};

pub const GraphEdge = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8,
    style: EdgeStyle,
    arrow_head: ArrowHead,
    waypoints: std.ArrayList(Point),

    pub fn init(allocator: Allocator, from: []const u8, to: []const u8) GraphEdge {
        return .{
            .from = from,
            .to = to,
            .label = null,
            .style = .solid,
            .arrow_head = .arrow,
            .waypoints = std.ArrayList(Point).init(allocator),
        };
    }

    pub fn deinit(self: *GraphEdge) void {
        self.waypoints.deinit();
    }
};

pub const Graph = struct {
    nodes: std.StringHashMap(GraphNode),
    edges: std.ArrayList(GraphEdge),
    direction: Direction,
    allocator: Allocator,

    pub fn init(allocator: Allocator, direction: Direction) Graph {
        return .{
            .nodes = std.StringHashMap(GraphNode).init(allocator),
            .edges = std.ArrayList(GraphEdge).init(allocator),
            .direction = direction,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit();
        for (self.edges.items) |*edge| {
            edge.deinit();
        }
        self.edges.deinit();
    }

    pub fn addNode(self: *Graph, id: []const u8, label: []const u8, shape: NodeShape) !void {
        try self.nodes.put(id, .{
            .id = id,
            .label = label,
            .shape = shape,
        });
    }

    pub fn addEdge(self: *Graph, from: []const u8, to: []const u8) !*GraphEdge {
        try self.edges.append(GraphEdge.init(self.allocator, from, to));
        return &self.edges.items[self.edges.items.len - 1];
    }

    /// Uniformly scale all node positions/sizes and edge waypoints so the
    /// diagram fits within `target_width`. Returns the scale factor applied.
    /// Does nothing if the diagram already fits (returns 1.0).
    pub fn scaleToFit(self: *Graph, natural_width: f32, target_width: f32) f32 {
        if (natural_width <= target_width or natural_width <= 0) return 1.0;
        const scale = target_width / natural_width;

        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr;
            node.x *= scale;
            node.y *= scale;
            node.width *= scale;
            node.height *= scale;
        }

        for (self.edges.items) |*edge| {
            for (edge.waypoints.items) |*wp| {
                wp.x *= scale;
                wp.y *= scale;
            }
        }

        return scale;
    }
};

// --- Tests ---

const testing = std.testing;

test "Graph.scaleToFit no-op when natural_width <= target_width" {
    var graph = Graph.init(testing.allocator, .td);
    defer graph.deinit();

    try graph.addNode("a", "A", .rectangle);
    var node_ptr = graph.nodes.getPtr("a").?;
    node_ptr.x = 100;
    node_ptr.y = 50;
    node_ptr.width = 80;
    node_ptr.height = 40;

    const scale = graph.scaleToFit(400, 600);
    try testing.expectEqual(@as(f32, 1.0), scale);

    const node = graph.nodes.get("a").?;
    try testing.expectEqual(@as(f32, 100), node.x);
    try testing.expectEqual(@as(f32, 50), node.y);
    try testing.expectEqual(@as(f32, 80), node.width);
    try testing.expectEqual(@as(f32, 40), node.height);
}

test "Graph.scaleToFit no-op when natural_width is 0" {
    var graph = Graph.init(testing.allocator, .lr);
    defer graph.deinit();

    try graph.addNode("a", "A", .rounded);
    var node_ptr = graph.nodes.getPtr("a").?;
    node_ptr.x = 10;

    const scale = graph.scaleToFit(0, 500);
    try testing.expectEqual(@as(f32, 1.0), scale);
    try testing.expectEqual(@as(f32, 10), graph.nodes.get("a").?.x);
}

test "Graph.scaleToFit scales nodes and edge waypoints" {
    var graph = Graph.init(testing.allocator, .td);
    defer graph.deinit();

    try graph.addNode("a", "A", .rectangle);
    try graph.addNode("b", "B", .diamond);

    var a_ptr = graph.nodes.getPtr("a").?;
    a_ptr.x = 100;
    a_ptr.y = 200;
    a_ptr.width = 80;
    a_ptr.height = 40;

    var b_ptr = graph.nodes.getPtr("b").?;
    b_ptr.x = 300;
    b_ptr.y = 400;
    b_ptr.width = 120;
    b_ptr.height = 60;

    const edge = try graph.addEdge("a", "b");
    try edge.waypoints.append(.{ .x = 150, .y = 250 });
    try edge.waypoints.append(.{ .x = 300, .y = 400 });

    // natural_width=1000, target_width=500 => scale=0.5
    const scale = graph.scaleToFit(1000, 500);
    try testing.expectApproxEqAbs(@as(f32, 0.5), scale, 0.0001);

    const a = graph.nodes.get("a").?;
    try testing.expectApproxEqAbs(@as(f32, 50), a.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 100), a.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 40), a.width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 20), a.height, 0.0001);

    const b = graph.nodes.get("b").?;
    try testing.expectApproxEqAbs(@as(f32, 150), b.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 200), b.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 60), b.width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 30), b.height, 0.0001);

    const wp0 = graph.edges.items[0].waypoints.items[0];
    try testing.expectApproxEqAbs(@as(f32, 75), wp0.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 125), wp0.y, 0.0001);

    const wp1 = graph.edges.items[0].waypoints.items[1];
    try testing.expectApproxEqAbs(@as(f32, 150), wp1.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 200), wp1.y, 0.0001);
}

test "Graph.scaleToFit returns correct scale factor" {
    var graph = Graph.init(testing.allocator, .td);
    defer graph.deinit();

    const scale = graph.scaleToFit(800, 200);
    try testing.expectApproxEqAbs(@as(f32, 0.25), scale, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 200.0 / 800.0), scale, 0.0001);
}
