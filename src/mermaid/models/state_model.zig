const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const Graph = graph_mod.Graph;

pub const StateType = enum {
    normal,
    start, // [*]
    end, // [*] when target
    fork,
    join,
    choice,
    composite,
};

pub const State = struct {
    id: []const u8,
    label: []const u8,
    state_type: StateType = .normal,
    description: ?[]const u8 = null,
    children: std.ArrayList(State),

    // Layout fields
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const Transition = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8 = null,
};

pub const StateModel = struct {
    states: std.ArrayList(State),
    transitions: std.ArrayList(Transition),
    graph: Graph,
    allocator: Allocator,

    pub fn init(allocator: Allocator) StateModel {
        return .{
            .states = std.ArrayList(State).init(allocator),
            .transitions = std.ArrayList(Transition).init(allocator),
            .graph = Graph.init(allocator, .td),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StateModel) void {
        for (self.states.items) |*s| {
            deinitStateRecursive(s);
        }
        self.states.deinit();
        self.transitions.deinit();
        self.graph.deinit();
    }

    fn deinitStateRecursive(state: *State) void {
        for (state.children.items) |*child| {
            deinitStateRecursive(child);
        }
        state.children.deinit();
    }

    pub fn findStateMut(self: *StateModel, id: []const u8) ?*State {
        for (self.states.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    pub fn ensureState(self: *StateModel, id: []const u8) !*State {
        if (self.findStateMut(id)) |s| return s;

        var state_type: StateType = .normal;
        if (std.mem.eql(u8, id, "[*]")) {
            state_type = .start;
        }

        try self.states.append(.{
            .id = id,
            .label = id,
            .state_type = state_type,
            .children = std.ArrayList(State).init(self.allocator),
        });
        return &self.states.items[self.states.items.len - 1];
    }
};
