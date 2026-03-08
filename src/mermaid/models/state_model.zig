const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const Graph = graph_mod.Graph;
const NodeShape = graph_mod.NodeShape;
const Direction = graph_mod.Direction;

pub const StateType = enum {
    normal,
    start, // [*]
    end, // [*] when target
    fork,
    join,
    choice,
    composite,
    history, // [H] — shallow history pseudo-state
    deep_history, // [H*] — deep history pseudo-state
    entry_point, // <<entryPoint>> — UML entry point pseudo-state on composite border
    exit_point, // <<exitPoint>> — UML exit point pseudo-state on composite border
};

pub const NotePosition = enum {
    left,
    right,
};

pub const Note = struct {
    state_id: []const u8,
    position: NotePosition,
    text: []const u8,
};

/// A concurrent region within a composite state.
/// In stateDiagram-v2 syntax, regions are separated by `--` inside a
/// composite state block, representing orthogonal (parallel) substates.
///
/// Example:
///   state MyComposite {
///       [*] --> A
///       A --> B
///       --
///       [*] --> C
///       C --> D
///   }
///
/// This creates two regions that execute concurrently.
pub const Region = struct {
    /// States belonging to this region. Not owned — points into the
    /// parent State's children list.
    states: std.ArrayList(State),
    /// Transitions scoped to this region.
    transitions: std.ArrayList(Transition),

    // Layout fields (set during layout phase)
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(allocator: Allocator) Region {
        return .{
            .states = std.ArrayList(State).init(allocator),
            .transitions = std.ArrayList(Transition).init(allocator),
        };
    }

    pub fn deinit(self: *Region) void {
        for (self.states.items) |*s| {
            deinitStateChildren(s);
        }
        self.states.deinit();
        self.transitions.deinit();
    }

    /// Find a state within this region by id.
    pub fn findStateMut(self: *Region, id: []const u8) ?*State {
        for (self.states.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    /// Ensure a state with the given id exists in this region.
    /// `parent_depth` is the depth of the composite state that owns this region;
    /// new states are created with depth = parent_depth + 1.
    pub fn ensureState(self: *Region, allocator: Allocator, id: []const u8, parent_depth: u32) !*State {
        if (self.findStateMut(id)) |s| return s;

        var state_type: StateType = .normal;
        if (std.mem.eql(u8, id, "[*]")) {
            state_type = .start;
        } else if (std.mem.eql(u8, id, "[H]")) {
            state_type = .history;
        } else if (std.mem.eql(u8, id, "[H*]")) {
            state_type = .deep_history;
        }

        try self.states.append(.{
            .id = id,
            .label = id,
            .state_type = state_type,
            .depth = parent_depth + 1,
            .children = std.ArrayList(State).init(allocator),
            .child_transitions = std.ArrayList(Transition).init(allocator),
            .regions = std.ArrayList(Region).init(allocator),
        });
        return &self.states.items[self.states.items.len - 1];
    }

    /// Total number of states in this region (including nested children).
    pub fn totalStateCount(self: *const Region) usize {
        var count: usize = 0;
        for (self.states.items) |*s| {
            count += countStateRecursiveStatic(s);
        }
        return count;
    }
};

/// Classify a state id to determine its StateType from well-known pseudo-state
/// patterns: `[*]` → start, `[H]` → history, `[H*]` → deep_history, else normal.
fn classifyStateId(id: []const u8) StateType {
    if (std.mem.eql(u8, id, "[*]")) return .start;
    if (std.mem.eql(u8, id, "[H]")) return .history;
    if (std.mem.eql(u8, id, "[H*]")) return .deep_history;
    return .normal;
}

/// Helper: recursively free children/regions of a state (but not the state itself).
fn deinitStateChildren(state: *State) void {
    for (state.children.items) |*child| {
        deinitStateChildren(child);
    }
    state.children.deinit();
    state.child_transitions.deinit();
    for (state.regions.items) |*region| {
        region.deinit();
    }
    state.regions.deinit();
}

/// Count a state plus all its recursive children (used by Region.totalStateCount).
fn countStateRecursiveStatic(state: *const State) usize {
    var count: usize = 1;
    for (state.children.items) |*child| {
        count += countStateRecursiveStatic(child);
    }
    for (state.regions.items) |*region| {
        count += region.totalStateCount();
    }
    return count;
}

pub const State = struct {
    id: []const u8,
    label: []const u8,
    state_type: StateType = .normal,
    description: ?[]const u8 = null,
    /// Child states for composite (nested) states. Owned by this State.
    children: std.ArrayList(State),
    /// Transitions scoped to this composite state's children.
    child_transitions: std.ArrayList(Transition),
    /// Concurrent regions within this composite state.
    /// When non-empty, this state uses orthogonal regions instead of
    /// a flat list of children. The `--` separator in stateDiagram-v2
    /// syntax creates new regions.
    regions: std.ArrayList(Region),

    /// Nesting depth metadata: 0 for top-level states, 1 for direct children
    /// of composite states, 2 for grandchildren, etc.  Set by the parser
    /// during astToModel conversion and used by the layout/renderer for
    /// depth-aware sizing and visual differentiation.
    depth: u32 = 0,

    // Layout fields (set during layout phase)
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    /// Return the display label: description if set, otherwise label.
    pub fn displayLabel(self: *const State) []const u8 {
        return self.description orelse self.label;
    }

    /// Find a direct child by id (mutable).
    pub fn findChildMut(self: *State, id: []const u8) ?*State {
        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.id, id)) return child;
        }
        return null;
    }

    /// Find a state within any of the concurrent regions.
    pub fn findInRegions(self: *State, id: []const u8) ?*State {
        for (self.regions.items) |*region| {
            if (region.findStateMut(id)) |found| return found;
        }
        return null;
    }

    /// Check if this state has any children (is effectively composite).
    pub fn hasChildren(self: *const State) bool {
        return self.children.items.len > 0;
    }

    /// Check if this state has concurrent regions.
    pub fn hasRegions(self: *const State) bool {
        return self.regions.items.len > 0;
    }

    /// Total number of concurrent regions.
    pub fn regionCount(self: *const State) usize {
        return self.regions.items.len;
    }
};

pub const Transition = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8 = null,
};

pub const StateModel = struct {
    /// Top-level states. Composite states hold their children inline.
    states: std.ArrayList(State),
    /// Top-level transitions (between top-level or flattened states).
    transitions: std.ArrayList(Transition),
    /// Notes attached to states.
    notes: std.ArrayList(Note),
    /// Graph representation built from states/transitions for layout.
    graph: Graph,
    allocator: Allocator,
    /// Diagram direction (top-down by default for state diagrams).
    direction: Direction = .td,
    /// Heap-allocated strings owned by this model (e.g. joined multi-line note text).
    /// Freed during deinit. Other string slices in the model borrow from the parser input.
    owned_strings: std.ArrayList([]u8),

    /// Create a new StateModel. Infallible — only sets up ArrayLists.
    pub fn init(allocator: Allocator) StateModel {
        return .{
            .states = std.ArrayList(State).init(allocator),
            .transitions = std.ArrayList(Transition).init(allocator),
            .notes = std.ArrayList(Note).init(allocator),
            .graph = Graph.init(allocator, .td),
            .allocator = allocator,
            .owned_strings = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *StateModel) void {
        for (self.states.items) |*s| {
            deinitStateRecursive(s);
        }
        self.states.deinit();
        self.transitions.deinit();
        self.notes.deinit();
        self.graph.deinit();
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit();
    }

    /// Allocate a copy of `text` owned by this model, freed on deinit.
    /// Used for strings assembled from multiple source fragments
    /// (e.g. multi-line note text joined with newlines).
    pub fn dupeString(self: *StateModel, text: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.owned_strings.append(owned);
        return owned;
    }

    fn deinitStateRecursive(state: *State) void {
        deinitStateChildren(state);
    }

    /// Find a top-level state by id.
    pub fn findStateMut(self: *StateModel, id: []const u8) ?*State {
        for (self.states.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    /// Search for a state recursively within composite states.
    pub fn findStateRecursive(self: *StateModel, id: []const u8) ?*State {
        for (self.states.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) return s;
            if (findInChildren(s, id)) |found| return found;
        }
        return null;
    }

    fn findInChildren(state: *State, id: []const u8) ?*State {
        for (state.children.items) |*child| {
            if (std.mem.eql(u8, child.id, id)) return child;
            if (findInChildren(child, id)) |found| return found;
        }
        // Also search within concurrent regions
        for (state.regions.items) |*region| {
            for (region.states.items) |*rs| {
                if (std.mem.eql(u8, rs.id, id)) return rs;
                if (findInChildren(rs, id)) |found| return found;
            }
        }
        return null;
    }

    /// Ensure a top-level state with the given id exists. Returns a pointer to it.
    /// Pseudo-state ids are auto-typed: `[*]` → start, `[H]` → history, `[H*]` → deep_history.
    pub fn ensureState(self: *StateModel, id: []const u8) !*State {
        if (self.findStateMut(id)) |s| return s;

        const state_type = classifyStateId(id);

        try self.states.append(.{
            .id = id,
            .label = id,
            .state_type = state_type,
            .children = std.ArrayList(State).init(self.allocator),
            .child_transitions = std.ArrayList(Transition).init(self.allocator),
            .regions = std.ArrayList(Region).init(self.allocator),
        });
        return &self.states.items[self.states.items.len - 1];
    }

    /// Ensure a child state exists inside a composite parent.
    /// If the parent is not yet composite, upgrades it automatically.
    /// Also checks within regions if the parent has concurrent regions.
    /// Sets depth = parent.depth + 1 on newly created child states.
    pub fn ensureChildState(self: *StateModel, parent: *State, child_id: []const u8) !*State {
        if (parent.findChildMut(child_id)) |existing| return existing;
        // Also check regions
        if (parent.findInRegions(child_id)) |existing| return existing;

        const state_type = classifyStateId(child_id);

        // Mark parent as composite if not already a special type
        if (parent.state_type == .normal) {
            parent.state_type = .composite;
        }

        try parent.children.append(.{
            .id = child_id,
            .label = child_id,
            .state_type = state_type,
            .depth = parent.depth + 1,
            .children = std.ArrayList(State).init(self.allocator),
            .child_transitions = std.ArrayList(Transition).init(self.allocator),
            .regions = std.ArrayList(Region).init(self.allocator),
        });
        return &parent.children.items[parent.children.items.len - 1];
    }

    /// Add a new concurrent region to a composite state.
    /// The state is automatically marked as composite. Returns a pointer
    /// to the newly created region.
    pub fn addRegion(self: *StateModel, parent: *State) !*Region {
        if (parent.state_type == .normal) {
            parent.state_type = .composite;
        }
        try parent.regions.append(Region.init(self.allocator));
        return &parent.regions.items[parent.regions.items.len - 1];
    }

    /// Add a transition scoped to a composite parent's children.
    pub fn addChildTransition(parent: *State, from: []const u8, to: []const u8, label: ?[]const u8) !void {
        try parent.child_transitions.append(.{
            .from = from,
            .to = to,
            .label = label,
        });
    }

    pub fn addNote(self: *StateModel, state_id: []const u8, position: NotePosition, text: []const u8) !void {
        try self.notes.append(.{
            .state_id = state_id,
            .position = position,
            .text = text,
        });
    }

    // =========================================================================
    // Graph building — converts state/transition model into Graph for layout
    // =========================================================================

    /// Build the internal Graph from states and transitions.
    /// Flattens the hierarchy into graph nodes/edges suitable for dagre layout.
    /// Must be called after all states and transitions have been added.
    pub fn buildGraph(self: *StateModel) !void {
        self.graph.direction = self.direction;

        // Add all states (including nested children) as graph nodes
        try addStatesToGraph(self, self.states.items);

        // Add top-level transitions as graph edges
        for (self.transitions.items) |t| {
            try self.addTransitionEdge(t);
        }

        // Recursively add child transitions from composite states
        for (self.states.items) |*state| {
            try addChildTransitionEdges(self, state);
        }
    }

    /// Recursively add states to the graph as nodes with appropriate shapes/sizes.
    fn addStatesToGraph(self: *StateModel, states: []State) !void {
        for (states) |*state| {
            const shape: NodeShape = switch (state.state_type) {
                .start, .end, .history, .deep_history, .entry_point, .exit_point => .circle,
                .choice => .diamond,
                .fork, .join => .rectangle,
                .composite, .normal => .rounded,
            };
            try self.graph.addNode(state.id, state.displayLabel(), shape);

            // Override sizes for special states
            if (self.graph.nodes.getPtr(state.id)) |gnode| {
                switch (state.state_type) {
                    .start, .end => {
                        gnode.width = 24;
                        gnode.height = 24;
                    },
                    .history, .deep_history => {
                        gnode.width = 28;
                        gnode.height = 28;
                    },
                    .fork, .join => {
                        gnode.width = 80;
                        gnode.height = 8;
                    },
                    .choice => {
                        gnode.width = 30;
                        gnode.height = 30;
                    },
                    // Entry/exit points: small circles used as pseudo-states on composite borders
                    .entry_point, .exit_point => {
                        gnode.width = 20;
                        gnode.height = 20;
                    },
                    else => {},
                }
            }

            // Recursively add children of composite states
            if (state.hasChildren()) {
                try addStatesToGraph(self, state.children.items);
            }

            // Add states from concurrent regions
            for (state.regions.items) |*region| {
                try addStatesToGraph(self, region.states.items);
            }
        }
    }

    /// Add a transition as a graph edge, handling [*] end-state remapping.
    fn addTransitionEdge(self: *StateModel, t: Transition) !void {
        var to = t.to;
        // Remap [*] as target to [*]_end if a separate end node exists
        if (std.mem.eql(u8, t.to, "[*]") and self.graph.nodes.get("[*]_end") != null) {
            var is_source = false;
            for (self.transitions.items) |t2| {
                if (std.mem.eql(u8, t2.from, "[*]")) {
                    is_source = true;
                    break;
                }
            }
            if (is_source) {
                to = "[*]_end";
            }
        }
        var edge = try self.graph.addEdge(t.from, to);
        if (t.label != null) edge.label = t.label;
    }

    /// Recursively add child transitions from composite states as graph edges.
    fn addChildTransitionEdges(self: *StateModel, state: *State) !void {
        for (state.child_transitions.items) |t| {
            var edge = try self.graph.addEdge(t.from, t.to);
            if (t.label != null) edge.label = t.label;
        }
        for (state.children.items) |*child| {
            try addChildTransitionEdges(self, child);
        }
        // Add transitions from concurrent regions
        for (state.regions.items) |*region| {
            for (region.transitions.items) |t| {
                var edge = try self.graph.addEdge(t.from, t.to);
                if (t.label != null) edge.label = t.label;
            }
            for (region.states.items) |*rs| {
                try addChildTransitionEdges(self, rs);
            }
        }
    }

    // =========================================================================
    // Hierarchy utilities
    // =========================================================================

    /// Collect all states (including nested children) into a flat list.
    /// Returns pointers into the existing state tree — does NOT copy.
    pub fn flattenStates(self: *const StateModel, out: *std.ArrayList(*const State)) !void {
        try flattenStateList(self.states.items, out);
    }

    fn flattenStateList(states: []const State, out: *std.ArrayList(*const State)) !void {
        for (states) |*state| {
            try out.append(state);
            if (state.children.items.len > 0) {
                try flattenStateList(state.children.items, out);
            }
            // Include states from concurrent regions
            for (state.regions.items) |*region| {
                try flattenStateList(region.states.items, out);
            }
        }
    }

    /// Count the total number of states including all nested children and regions.
    pub fn totalStateCount(self: *const StateModel) usize {
        var count: usize = 0;
        for (self.states.items) |*s| {
            count += countStateRecursiveStatic(s);
        }
        return count;
    }

    /// Get the maximum depth of the state hierarchy.
    /// Returns 0 for empty, 1 for flat, 2+ for nested.
    /// Regions add one level of depth.
    pub fn maxDepth(self: *const StateModel) usize {
        var depth: usize = 0;
        for (self.states.items) |*s| {
            depth = @max(depth, stateDepth(s));
        }
        return depth;
    }

    fn stateDepth(state: *const State) usize {
        if (state.children.items.len == 0 and state.regions.items.len == 0) return 1;
        var max_child: usize = 0;
        for (state.children.items) |*child| {
            max_child = @max(max_child, stateDepth(child));
        }
        // Regions add a level: composite -> region -> region's children
        for (state.regions.items) |*region| {
            for (region.states.items) |*rs| {
                max_child = @max(max_child, stateDepth(rs));
            }
        }
        return 1 + max_child;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "StateModel dupeString allocates and frees on deinit" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const s = try model.dupeString("hello world");
    try testing.expectEqualStrings("hello world", s);
    // owned_strings should track the allocation
    try testing.expectEqual(@as(usize, 1), model.owned_strings.items.len);
}

test "StateModel dupeString multiple allocations" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.dupeString("first");
    _ = try model.dupeString("second");
    _ = try model.dupeString("third");
    try testing.expectEqual(@as(usize, 3), model.owned_strings.items.len);
}

test "StateModel init owned_strings starts empty" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 0), model.owned_strings.items.len);
}

const testing = std.testing;

test "StateModel init and deinit" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("S1");
    _ = try model.ensureState("S2");
    try testing.expectEqual(@as(usize, 2), model.states.items.len);
}

test "StateModel ensureState deduplicates" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("S1");
    _ = try model.ensureState("S1");
    try testing.expectEqual(@as(usize, 1), model.states.items.len);
}

test "StateModel star state gets start type" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("[*]");
    try testing.expectEqual(StateType.start, model.states.items[0].state_type);
}

test "StateModel recursive deinit with children" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Parent");
    // Use ensureChildState to add children
    const child = try model.ensureChildState(parent, "Child");
    _ = try model.ensureChildState(child, "Grandchild");

    // model.deinit() should recursively free all children without leaks
    try testing.expectEqual(@as(usize, 1), parent.children.items.len);
    try testing.expectEqual(@as(usize, 1), child.children.items.len);
}

test "StateModel addNote stores notes" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("S1");
    try model.addNote("S1", .right, "This is a note");
    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("S1", model.notes.items[0].state_id);
    try testing.expectEqual(NotePosition.right, model.notes.items[0].position);
    try testing.expectEqualStrings("This is a note", model.notes.items[0].text);
}

test "StateModel findStateRecursive finds nested children" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Parent");
    _ = try model.ensureChildState(parent, "Child");

    // Top-level search finds parent
    try testing.expect(model.findStateRecursive("Parent") != null);
    // Recursive search finds child
    try testing.expect(model.findStateRecursive("Child") != null);
    // Missing state returns null
    try testing.expect(model.findStateRecursive("Missing") == null);
}

test "StateModel ensureChildState creates hierarchy" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Parent");
    try testing.expectEqual(StateType.normal, parent.state_type);

    _ = try model.ensureChildState(parent, "Child1");
    // Parent should now be composite
    try testing.expectEqual(StateType.composite, parent.state_type);
    try testing.expectEqual(@as(usize, 1), parent.children.items.len);

    _ = try model.ensureChildState(parent, "Child2");
    try testing.expectEqual(@as(usize, 2), parent.children.items.len);
}

test "StateModel ensureChildState deduplicates" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    _ = try model.ensureChildState(parent, "C");
    _ = try model.ensureChildState(parent, "C");
    try testing.expectEqual(@as(usize, 1), parent.children.items.len);
}

test "StateModel ensureChildState star child gets start type" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    _ = try model.ensureChildState(parent, "[*]");
    try testing.expectEqual(StateType.start, parent.children.items[0].state_type);
}

test "StateModel addChildTransition" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Outer");
    _ = try model.ensureChildState(parent, "A");
    _ = try model.ensureChildState(parent, "B");
    try StateModel.addChildTransition(parent, "A", "B", "go");

    try testing.expectEqual(@as(usize, 1), parent.child_transitions.items.len);
    try testing.expectEqualStrings("A", parent.child_transitions.items[0].from);
    try testing.expectEqualStrings("B", parent.child_transitions.items[0].to);
    try testing.expectEqualStrings("go", parent.child_transitions.items[0].label.?);
}

test "StateModel depth metadata: top-level states have depth 0" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const s = try model.ensureState("S1");
    try testing.expectEqual(@as(u32, 0), s.depth);
}

test "StateModel depth metadata: ensureChildState increments depth" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Parent");
    try testing.expectEqual(@as(u32, 0), parent.depth);

    const child = try model.ensureChildState(parent, "Child");
    try testing.expectEqual(@as(u32, 1), child.depth);

    const grandchild = try model.ensureChildState(child, "Grandchild");
    try testing.expectEqual(@as(u32, 2), grandchild.depth);
}

test "StateModel depth metadata: Region.ensureState uses parent_depth + 1" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    try testing.expectEqual(@as(u32, 0), parent.depth);

    const region = try model.addRegion(parent);
    const rs = try region.ensureState(allocator, "RegState", parent.depth);
    try testing.expectEqual(@as(u32, 1), rs.depth);
}

test "StateModel totalStateCount" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("A");
    const parent_b = try model.ensureState("B");
    _ = try model.ensureChildState(parent_b, "B1");
    _ = try model.ensureChildState(parent_b, "B2");
    _ = try model.ensureState("C");

    // 3 top-level + 2 children = 5
    try testing.expectEqual(@as(usize, 5), model.totalStateCount());
}

test "StateModel maxDepth flat" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("A");
    _ = try model.ensureState("B");
    try testing.expectEqual(@as(usize, 1), model.maxDepth());
}

test "StateModel maxDepth nested" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer");
    const inner = try model.ensureChildState(outer, "Inner");
    _ = try model.ensureChildState(inner, "Deep");

    try testing.expectEqual(@as(usize, 3), model.maxDepth());
}

test "StateModel maxDepth empty" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 0), model.maxDepth());
}

test "StateModel flattenStates" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("A");
    const parent_b = try model.ensureState("B");
    _ = try model.ensureChildState(parent_b, "B1");
    _ = try model.ensureChildState(parent_b, "B2");

    var flat = std.ArrayList(*const State).init(allocator);
    defer flat.deinit();
    try model.flattenStates(&flat);

    try testing.expectEqual(@as(usize, 4), flat.items.len);
    try testing.expectEqualStrings("A", flat.items[0].id);
    try testing.expectEqualStrings("B", flat.items[1].id);
    try testing.expectEqualStrings("B1", flat.items[2].id);
    try testing.expectEqualStrings("B2", flat.items[3].id);
}

test "StateModel flattenStates deep hierarchy" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const a = try model.ensureState("A");
    const b = try model.ensureChildState(a, "B");
    const c = try model.ensureChildState(b, "C");
    _ = try model.ensureChildState(c, "D");

    var flat = std.ArrayList(*const State).init(allocator);
    defer flat.deinit();
    try model.flattenStates(&flat);

    try testing.expectEqual(@as(usize, 4), flat.items.len);
    try testing.expectEqualStrings("A", flat.items[0].id);
    try testing.expectEqualStrings("B", flat.items[1].id);
    try testing.expectEqualStrings("C", flat.items[2].id);
    try testing.expectEqualStrings("D", flat.items[3].id);
}

test "StateModel buildGraph basic" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("Idle");
    _ = try model.ensureState("Active");
    try model.transitions.append(.{ .from = "Idle", .to = "Active", .label = "start" });

    try model.buildGraph();

    try testing.expect(model.graph.nodes.get("Idle") != null);
    try testing.expect(model.graph.nodes.get("Active") != null);
    try testing.expectEqual(@as(usize, 1), model.graph.edges.items.len);
    try testing.expectEqualStrings("start", model.graph.edges.items[0].label.?);
}

test "StateModel buildGraph with special state sizes" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("[*]");
    const fork = try model.ensureState("fork_state");
    fork.state_type = .fork;
    const choice = try model.ensureState("choice_state");
    choice.state_type = .choice;

    try model.buildGraph();

    const start_node = model.graph.nodes.get("[*]").?;
    try testing.expectEqual(@as(f32, 24), start_node.width);
    try testing.expectEqual(@as(f32, 24), start_node.height);

    const fork_node = model.graph.nodes.get("fork_state").?;
    try testing.expectEqual(@as(f32, 80), fork_node.width);
    try testing.expectEqual(@as(f32, 8), fork_node.height);

    const choice_node = model.graph.nodes.get("choice_state").?;
    try testing.expectEqual(@as(f32, 30), choice_node.width);
    try testing.expectEqual(@as(f32, 30), choice_node.height);
}

test "StateModel buildGraph with composite children" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const outer = try model.ensureState("Outer");
    _ = try model.ensureChildState(outer, "Inner1");
    _ = try model.ensureChildState(outer, "Inner2");
    try StateModel.addChildTransition(outer, "Inner1", "Inner2", null);

    try model.buildGraph();

    // All states should be in the graph (flattened)
    try testing.expect(model.graph.nodes.get("Outer") != null);
    try testing.expect(model.graph.nodes.get("Inner1") != null);
    try testing.expect(model.graph.nodes.get("Inner2") != null);

    // Child transition should be an edge
    try testing.expectEqual(@as(usize, 1), model.graph.edges.items.len);
    try testing.expectEqualStrings("Inner1", model.graph.edges.items[0].from);
    try testing.expectEqualStrings("Inner2", model.graph.edges.items[0].to);
}

test "StateModel buildGraph end state remapping" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("[*]");
    _ = try model.ensureState("Active");
    const end_state = try model.ensureState("[*]_end");
    end_state.state_type = .end;
    end_state.label = "[*]";

    // [*] is used as both source and target
    try model.transitions.append(.{ .from = "[*]", .to = "Active", .label = null });
    try model.transitions.append(.{ .from = "Active", .to = "[*]", .label = null });

    try model.buildGraph();

    // The second transition should target [*]_end
    var found_end_edge = false;
    for (model.graph.edges.items) |edge| {
        if (std.mem.eql(u8, edge.to, "[*]_end")) {
            found_end_edge = true;
        }
    }
    try testing.expect(found_end_edge);
}

test "StateModel buildGraph respects direction" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    model.direction = .lr;
    _ = try model.ensureState("A");
    try model.buildGraph();

    try testing.expectEqual(Direction.lr, model.graph.direction);
}

test "StateModel buildGraph empty model" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    try model.buildGraph();
    try testing.expectEqual(@as(usize, 0), model.graph.edges.items.len);
}

test "State displayLabel" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    var s = try model.ensureState("MyState");
    try testing.expectEqualStrings("MyState", s.displayLabel());

    s.description = "My Description";
    try testing.expectEqualStrings("My Description", s.displayLabel());
}

test "State findChildMut and hasChildren" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    var parent = try model.ensureState("P");
    try testing.expect(!parent.hasChildren());

    _ = try model.ensureChildState(parent, "C1");
    try testing.expect(parent.hasChildren());
    try testing.expect(parent.findChildMut("C1") != null);
    try testing.expect(parent.findChildMut("Missing") == null);
}

test "StateModel multiple notes" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("S1");
    _ = try model.ensureState("S2");
    try model.addNote("S1", .right, "Note 1");
    try model.addNote("S1", .left, "Note 2");
    try model.addNote("S2", .right, "Note 3");

    try testing.expectEqual(@as(usize, 3), model.notes.items.len);
}

test "StateModel history pseudo-state" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("[H]");
    try testing.expectEqual(StateType.history, model.states.items[0].state_type);
}

test "StateModel deep history pseudo-state" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("[H*]");
    try testing.expectEqual(StateType.deep_history, model.states.items[0].state_type);
}

test "StateModel classifyStateId for children" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    _ = try model.ensureChildState(parent, "[H]");
    try testing.expectEqual(StateType.history, parent.children.items[0].state_type);

    _ = try model.ensureChildState(parent, "[H*]");
    try testing.expectEqual(StateType.deep_history, parent.children.items[1].state_type);
}

test "Region init and deinit" {
    const allocator = testing.allocator;
    var region = Region.init(allocator);
    defer region.deinit();

    _ = try region.ensureState(allocator, "A", 0);
    _ = try region.ensureState(allocator, "B", 0);
    try region.transitions.append(.{ .from = "A", .to = "B", .label = null });

    try testing.expectEqual(@as(usize, 2), region.states.items.len);
    try testing.expectEqual(@as(usize, 1), region.transitions.items.len);
}

test "Region ensureState deduplicates" {
    const allocator = testing.allocator;
    var region = Region.init(allocator);
    defer region.deinit();

    _ = try region.ensureState(allocator, "A", 0);
    _ = try region.ensureState(allocator, "A", 0);
    try testing.expectEqual(@as(usize, 1), region.states.items.len);
}

test "Region ensureState classifies pseudo-states" {
    const allocator = testing.allocator;
    var region = Region.init(allocator);
    defer region.deinit();

    _ = try region.ensureState(allocator, "[*]", 0);
    _ = try region.ensureState(allocator, "[H]", 0);
    _ = try region.ensureState(allocator, "[H*]", 0);

    try testing.expectEqual(StateType.start, region.states.items[0].state_type);
    try testing.expectEqual(StateType.history, region.states.items[1].state_type);
    try testing.expectEqual(StateType.deep_history, region.states.items[2].state_type);
}

test "Region totalStateCount" {
    const allocator = testing.allocator;
    var region = Region.init(allocator);
    defer region.deinit();

    _ = try region.ensureState(allocator, "A", 0);
    _ = try region.ensureState(allocator, "B", 0);
    try testing.expectEqual(@as(usize, 2), region.totalStateCount());
}

test "StateModel addRegion creates concurrent regions" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Composite");
    // Add both regions first to avoid pointer invalidation
    _ = try model.addRegion(parent);
    _ = try model.addRegion(parent);

    // Access regions by index (pointers from addRegion may be invalidated by
    // subsequent appends to the same ArrayList).
    _ = try parent.regions.items[0].ensureState(allocator, "A", 0);
    _ = try parent.regions.items[0].ensureState(allocator, "B", 0);
    try parent.regions.items[0].transitions.append(.{ .from = "A", .to = "B", .label = null });

    _ = try parent.regions.items[1].ensureState(allocator, "C", 0);
    _ = try parent.regions.items[1].ensureState(allocator, "D", 0);
    try parent.regions.items[1].transitions.append(.{ .from = "C", .to = "D", .label = null });

    try testing.expectEqual(StateType.composite, parent.state_type);
    try testing.expectEqual(@as(usize, 2), parent.regionCount());
    try testing.expect(parent.hasRegions());
}

test "StateModel findInRegions" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    const region = try model.addRegion(parent);
    _ = try region.ensureState(allocator, "RegionState", 0);

    try testing.expect(parent.findInRegions("RegionState") != null);
    try testing.expect(parent.findInRegions("Missing") == null);
}

test "StateModel findStateRecursive searches regions" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    const region = try model.addRegion(parent);
    _ = try region.ensureState(allocator, "Deep", 0);

    try testing.expect(model.findStateRecursive("Deep") != null);
}

test "StateModel flattenStates includes region states" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    const region = try model.addRegion(parent);
    _ = try region.ensureState(allocator, "R1", 0);
    _ = try region.ensureState(allocator, "R2", 0);

    var flat = std.ArrayList(*const State).init(allocator);
    defer flat.deinit();
    try model.flattenStates(&flat);

    // P + R1 + R2 = 3
    try testing.expectEqual(@as(usize, 3), flat.items.len);
}

test "StateModel totalStateCount includes region states" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    const region = try model.addRegion(parent);
    _ = try region.ensureState(allocator, "R1", 0);
    _ = try region.ensureState(allocator, "R2", 0);
    _ = try model.ensureState("Standalone");

    // P(1) + R1(1) + R2(1) + Standalone(1) = 4
    try testing.expectEqual(@as(usize, 4), model.totalStateCount());
}

test "StateModel buildGraph with regions" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("Composite");
    // Add both regions first, then populate by index to avoid pointer invalidation
    _ = try model.addRegion(parent);
    _ = try model.addRegion(parent);

    _ = try parent.regions.items[0].ensureState(allocator, "A", 0);
    _ = try parent.regions.items[0].ensureState(allocator, "B", 0);
    try parent.regions.items[0].transitions.append(.{ .from = "A", .to = "B", .label = "go" });

    _ = try parent.regions.items[1].ensureState(allocator, "C", 0);
    _ = try parent.regions.items[1].ensureState(allocator, "D", 0);
    try parent.regions.items[1].transitions.append(.{ .from = "C", .to = "D", .label = null });

    try model.buildGraph();

    // All states (including region states) should be in the graph
    try testing.expect(model.graph.nodes.get("Composite") != null);
    try testing.expect(model.graph.nodes.get("A") != null);
    try testing.expect(model.graph.nodes.get("B") != null);
    try testing.expect(model.graph.nodes.get("C") != null);
    try testing.expect(model.graph.nodes.get("D") != null);

    // Region transitions should be edges
    try testing.expectEqual(@as(usize, 2), model.graph.edges.items.len);
}

test "StateModel buildGraph history state sizes" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureState("[H]");
    _ = try model.ensureState("[H*]");

    try model.buildGraph();

    const h_node = model.graph.nodes.get("[H]").?;
    try testing.expectEqual(@as(f32, 28), h_node.width);
    try testing.expectEqual(@as(f32, 28), h_node.height);

    const hstar_node = model.graph.nodes.get("[H*]").?;
    try testing.expectEqual(@as(f32, 28), hstar_node.width);
    try testing.expectEqual(@as(f32, 28), hstar_node.height);
}

test "StateModel maxDepth with regions" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const parent = try model.ensureState("P");
    const region = try model.addRegion(parent);
    _ = try region.ensureState(allocator, "R1", 0);

    // P -> region's R1 = depth 2
    try testing.expectEqual(@as(usize, 2), model.maxDepth());
}

test "State hasRegions and regionCount" {
    const allocator = testing.allocator;
    var model = StateModel.init(allocator);
    defer model.deinit();

    const s = try model.ensureState("S");
    try testing.expect(!s.hasRegions());
    try testing.expectEqual(@as(usize, 0), s.regionCount());

    _ = try model.addRegion(s);
    try testing.expect(s.hasRegions());
    try testing.expectEqual(@as(usize, 1), s.regionCount());
}

test "Region findStateMut" {
    const allocator = testing.allocator;
    var region = Region.init(allocator);
    defer region.deinit();

    _ = try region.ensureState(allocator, "X", 0);
    try testing.expect(region.findStateMut("X") != null);
    try testing.expect(region.findStateMut("Y") == null);
}
