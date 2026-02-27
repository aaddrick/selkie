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
};
