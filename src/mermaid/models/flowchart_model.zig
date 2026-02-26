const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
pub const Graph = graph_mod.Graph;
pub const Direction = graph_mod.Direction;

pub const Subgraph = struct {
    id: []const u8,
    title: []const u8,
    node_ids: std.ArrayList([]const u8),
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(allocator: Allocator, id: []const u8, title: []const u8) Subgraph {
        return .{
            .id = id,
            .title = title,
            .node_ids = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Subgraph) void {
        self.node_ids.deinit();
    }
};

pub const FlowchartModel = struct {
    graph: Graph,
    subgraphs: std.ArrayList(Subgraph),
    allocator: Allocator,

    pub fn init(allocator: Allocator, direction: Direction) FlowchartModel {
        return .{
            .graph = Graph.init(allocator, direction),
            .subgraphs = std.ArrayList(Subgraph).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FlowchartModel) void {
        self.graph.deinit();
        for (self.subgraphs.items) |*sg| {
            sg.deinit();
        }
        self.subgraphs.deinit();
    }
};
