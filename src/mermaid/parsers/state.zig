const std = @import("std");
const Allocator = std.mem.Allocator;
const pu = @import("../parse_utils.zig");
const sm = @import("../models/state_model.zig");
const StateModel = sm.StateModel;
const State = sm.State;
const StateType = sm.StateType;
const NotePosition = sm.NotePosition;
const Transition = sm.Transition;
const Region = sm.Region;
const graph_mod = @import("../models/graph.zig");

/// Context for parsing nested composite states. Tracks the current
/// parent state and brace depth so that states declared inside a
/// `state Foo { ... }` block are added as children of Foo.
///
/// When a `--` separator is encountered inside a composite state,
/// the parser switches to region-aware mode: existing children and
/// transitions are moved into the first region, and a new region is
/// started for subsequent content. The `active_region_index` tracks
/// which region to add states/transitions to.
const ParseContext = struct {
    /// Stack of parent state ids for nested composite states.
    /// null means top-level.
    parent_stack: std.ArrayList(?[]const u8),
    /// Parallel stack tracking the active region index within each
    /// composite parent. null means no regions (use children/child_transitions).
    /// A numeric value means we are in region mode for that parent.
    region_index_stack: std.ArrayList(?usize),
    allocator: Allocator,

    fn init(allocator: Allocator) ParseContext {
        return .{
            .parent_stack = std.ArrayList(?[]const u8).init(allocator),
            .region_index_stack = std.ArrayList(?usize).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ParseContext) void {
        self.parent_stack.deinit();
        self.region_index_stack.deinit();
    }

    fn currentParent(self: *const ParseContext) ?[]const u8 {
        if (self.parent_stack.items.len == 0) return null;
        return self.parent_stack.items[self.parent_stack.items.len - 1];
    }

    /// Get the active region index for the current composite state.
    /// Returns null if the current parent doesn't use regions.
    fn currentRegionIndex(self: *const ParseContext) ?usize {
        if (self.region_index_stack.items.len == 0) return null;
        return self.region_index_stack.items[self.region_index_stack.items.len - 1];
    }

    /// Set the active region index for the current composite state.
    fn setCurrentRegionIndex(self: *ParseContext, idx: usize) void {
        if (self.region_index_stack.items.len > 0) {
            self.region_index_stack.items[self.region_index_stack.items.len - 1] = idx;
        }
    }

    fn push(self: *ParseContext, parent_id: ?[]const u8) !void {
        try self.parent_stack.append(parent_id);
        try self.region_index_stack.append(null); // No regions initially
    }

    fn pop(self: *ParseContext) void {
        if (self.parent_stack.items.len > 0) {
            _ = self.parent_stack.pop();
            _ = self.region_index_stack.pop();
        }
    }

    fn depth(self: *const ParseContext) usize {
        return self.parent_stack.items.len;
    }
};

pub fn parse(allocator: Allocator, source: []const u8) !StateModel {
    var model = StateModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    var ctx = ParseContext.init(allocator);
    defer ctx.deinit();

    var past_header = false;
    var in_multiline_note = false;
    var note_state_id: ?[]const u8 = null;
    var note_position: NotePosition = .right;
    var note_lines = std.ArrayList([]const u8).init(allocator);
    defer note_lines.deinit();

    for (lines.items) |raw_line| {
        const line = pu.strip(raw_line);

        if (line.len == 0 or pu.isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "stateDiagram-v2") or
                std.mem.eql(u8, line, "stateDiagram") or
                pu.startsWith(line, "stateDiagram-v2 ") or
                pu.startsWith(line, "stateDiagram "))
            {
                past_header = true;
                continue;
            }
            past_header = true;
            continue;
        }

        // Handle multi-line note continuation
        if (in_multiline_note) {
            if (std.mem.eql(u8, line, "end note")) {
                // Finalize the multi-line note
                if (note_state_id) |sid| {
                    const text = try joinNoteLines(&model, note_lines.items);
                    try model.addNote(sid, note_position, text);
                }
                in_multiline_note = false;
                note_state_id = null;
                note_lines.clearRetainingCapacity();
                continue;
            }
            try note_lines.append(line);
            continue;
        }

        // Closing brace: pop composite state context
        if (std.mem.eql(u8, line, "}")) {
            ctx.pop();
            continue;
        }

        // Concurrency separator: `--` inside a composite state creates
        // parallel (orthogonal) regions. The first `--` moves any existing
        // children/transitions into region 0 and starts region 1. Subsequent
        // `--` lines increment the active region index.
        if (std.mem.eql(u8, line, "--")) {
            const parent_id = ctx.currentParent();
            if (parent_id) |pid| {
                if (model.findStateRecursive(pid)) |parent| {
                    if (ctx.currentRegionIndex() == null) {
                        // First `--`: migrate existing children/transitions into region 0
                        var r0 = try model.addRegion(parent);

                        // Move existing children into region 0
                        for (parent.children.items) |child| {
                            try r0.states.append(child);
                        }
                        // Clear parent children without deinit (ownership moved)
                        parent.children.clearRetainingCapacity();

                        // Move existing child_transitions into region 0
                        for (parent.child_transitions.items) |t| {
                            try r0.transitions.append(t);
                        }
                        parent.child_transitions.clearRetainingCapacity();

                        // Create region 1 for subsequent content
                        _ = try model.addRegion(parent);
                        ctx.setCurrentRegionIndex(1);
                    } else {
                        // Subsequent `--`: start a new region
                        _ = try model.addRegion(parent);
                        ctx.setCurrentRegionIndex(parent.regions.items.len - 1);
                    }
                }
            }
            continue;
        }

        // Direction directive
        if (std.mem.eql(u8, line, "direction LR") or std.mem.eql(u8, line, "direction lr")) {
            model.direction = .lr;
            continue;
        }
        if (std.mem.eql(u8, line, "direction RL") or std.mem.eql(u8, line, "direction rl")) {
            model.direction = .rl;
            continue;
        }
        if (std.mem.eql(u8, line, "direction TB") or std.mem.eql(u8, line, "direction tb") or
            std.mem.eql(u8, line, "direction TD") or std.mem.eql(u8, line, "direction td"))
        {
            model.direction = .td;
            continue;
        }
        if (std.mem.eql(u8, line, "direction BT") or std.mem.eql(u8, line, "direction bt")) {
            model.direction = .bt;
            continue;
        }

        // Note handling: "note right of StateId : text" or "note right of StateId"
        if (pu.startsWith(line, "note ")) {
            try parseNote(line, &model, &in_multiline_note, &note_state_id, &note_position);
            continue;
        }

        // State declaration: "state "Description" as StateId" or "state Foo {" etc.
        if (pu.startsWith(line, "state ")) {
            try parseStateDeclaration(line, &model, &ctx);
            continue;
        }

        // Transition: "StateA --> StateB" or "StateA --> StateB : label"
        if (try tryParseTransition(line, &model, &ctx)) continue;
    }

    // Handle [*] states: determine if start or end based on usage
    for (model.transitions.items) |t| {
        if (std.mem.eql(u8, t.to, "[*]")) {
            // This [*] is used as an end state
            if (model.findStateMut("[*]_end")) |_| {} else {
                // Create a separate end state node
                var end_state = try model.ensureState("[*]_end");
                end_state.state_type = .end;
                end_state.label = "[*]";
            }
        }
    }

    // Build graph from the state/transition model
    try model.buildGraph();

    return model;
}

/// Join multiple note lines into a single string separated by newlines.
/// For a single line, returns the slice directly (no allocation needed).
/// For multiple lines, allocates a new buffer owned by `model` via
/// `dupeString` — the buffer is freed when the model is deinited.
fn joinNoteLines(model: *StateModel, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";
    if (lines.len == 1) return lines[0];

    // Calculate total buffer size: sum of line lengths + (n-1) newline chars
    var total: usize = 0;
    for (lines) |l| total += l.len;
    total += lines.len - 1;

    const buf = try model.allocator.alloc(u8, total);
    errdefer model.allocator.free(buf);

    var pos: usize = 0;
    for (lines, 0..) |l, i| {
        @memcpy(buf[pos .. pos + l.len], l);
        pos += l.len;
        if (i < lines.len - 1) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    // Transfer ownership to the model so the buffer is freed on deinit
    try model.owned_strings.append(buf);
    return buf;
}

fn parseNote(
    line: []const u8,
    model: *StateModel,
    in_multiline_note: *bool,
    note_state_id: *?[]const u8,
    note_position: *NotePosition,
) !void {
    const rest = pu.strip(line["note ".len..]);

    // Parse position: "right of" or "left of"
    var position: NotePosition = .right;
    var after_position: []const u8 = rest;

    if (pu.startsWith(rest, "right of ")) {
        position = .right;
        after_position = pu.strip(rest["right of ".len..]);
    } else if (pu.startsWith(rest, "left of ")) {
        position = .left;
        after_position = pu.strip(rest["left of ".len..]);
    } else {
        // Unrecognized note format, skip
        return;
    }

    // Check for inline note: "note right of StateId : text"
    if (pu.indexOfStr(after_position, " : ")) |colon_pos| {
        const state_id = pu.strip(after_position[0..colon_pos]);
        const text = pu.strip(after_position[colon_pos + 3 ..]);
        if (state_id.len > 0 and text.len > 0) {
            try model.addNote(state_id, position, text);
        }
        return;
    }

    // Check for inline note with colon (no space): "note right of StateId: text"
    if (pu.indexOfChar(after_position, ':')) |colon_pos| {
        const state_id = pu.strip(after_position[0..colon_pos]);
        const text = pu.strip(after_position[colon_pos + 1 ..]);
        if (state_id.len > 0 and text.len > 0) {
            try model.addNote(state_id, position, text);
            return;
        }
    }

    // Multi-line note: "note right of StateId" followed by lines until "end note"
    const state_id = pu.strip(after_position);
    if (state_id.len > 0) {
        in_multiline_note.* = true;
        note_state_id.* = state_id;
        note_position.* = position;
    }
}

fn parseStateDeclaration(line: []const u8, model: *StateModel, ctx: *ParseContext) !void {
    const rest = pu.strip(line["state ".len..]);

    // "state "Description" as StateId" — possibly with trailing "{"
    if (rest.len > 0 and rest[0] == '"') {
        if (pu.indexOfCharFrom(rest, '"', 1)) |close_quote| {
            const desc = rest[1..close_quote];
            const after = pu.strip(rest[close_quote + 1 ..]);
            if (pu.startsWith(after, "as ")) {
                var id_part = pu.strip(after["as ".len..]);
                // Check for trailing brace (composite with description)
                const is_composite = pu.endsWith(id_part, "{");
                if (is_composite) {
                    id_part = pu.strip(id_part[0 .. id_part.len - 1]);
                }
                if (id_part.len > 0) {
                    var state = try ensureStateInContext(model, ctx, id_part);
                    state.label = desc;
                    state.description = desc;
                    if (is_composite) {
                        state.state_type = .composite;
                        try ctx.push(id_part);
                    }
                    return;
                }
            }
        }
    }

    // "state StateId {" (composite state, push context)
    if (pu.endsWith(rest, "{")) {
        const state_id = pu.strip(rest[0 .. rest.len - 1]);
        if (state_id.len > 0) {
            var state = try ensureStateInContext(model, ctx, state_id);
            state.state_type = .composite;
            try ctx.push(state_id);
        }
        return;
    }

    // "state fork_state <<fork>>"
    if (pu.indexOfStr(rest, "<<fork>>")) |_| {
        const state_id = pu.strip(rest[0..pu.indexOfStr(rest, "<<").?]);
        if (state_id.len > 0) {
            var state = try ensureStateInContext(model, ctx, state_id);
            state.state_type = .fork;
        }
        return;
    }
    if (pu.indexOfStr(rest, "<<join>>")) |_| {
        const state_id = pu.strip(rest[0..pu.indexOfStr(rest, "<<").?]);
        if (state_id.len > 0) {
            var state = try ensureStateInContext(model, ctx, state_id);
            state.state_type = .join;
        }
        return;
    }
    if (pu.indexOfStr(rest, "<<choice>>")) |_| {
        const state_id = pu.strip(rest[0..pu.indexOfStr(rest, "<<").?]);
        if (state_id.len > 0) {
            var state = try ensureStateInContext(model, ctx, state_id);
            state.state_type = .choice;
        }
        return;
    }

    // Simple declaration
    if (rest.len > 0) {
        _ = try ensureStateInContext(model, ctx, rest);
    }
}

/// Classify a state id to its StateType based on well-known pseudo-state patterns.
/// `[*]` → start, `[H]` → history, `[H*]` → deep_history, else normal.
/// Mirrors the private classifyStateId in state_model.zig for use within the parser.
fn classifyChildStateId(id: []const u8) StateType {
    if (std.mem.eql(u8, id, "[*]")) return .start;
    if (std.mem.eql(u8, id, "[H]")) return .history;
    if (std.mem.eql(u8, id, "[H*]")) return .deep_history;
    return .normal;
}

/// Ensure a state exists. If we are inside a composite state (ctx has a parent),
/// add the new state as a child of that parent (or its active region). Otherwise
/// add at top level.
fn ensureStateInContext(model: *StateModel, ctx: *const ParseContext, id: []const u8) !*State {
    const parent_id = ctx.currentParent();

    if (parent_id) |pid| {
        // Find the parent state and add child to it
        if (model.findStateRecursive(pid)) |parent| {
            // If we are in region mode, add to the active region
            if (ctx.currentRegionIndex()) |region_idx| {
                if (region_idx < parent.regions.items.len) {
                    var region = &parent.regions.items[region_idx];
                    return region.ensureState(model.allocator, id, parent.depth);
                }
            }

            // Non-region mode: add as direct child
            // Check if child already exists
            for (parent.children.items) |*child| {
                if (std.mem.eql(u8, child.id, id)) return child;
            }

            // Classify pseudo-state ids: [*] → start, [H] → history, [H*] → deep_history
            const state_type = classifyChildStateId(id);

            try parent.children.append(.{
                .id = id,
                .label = id,
                .state_type = state_type,
                .depth = parent.depth + 1,
                .children = std.ArrayList(State).init(model.allocator),
                .child_transitions = std.ArrayList(Transition).init(model.allocator),
                .regions = std.ArrayList(Region).init(model.allocator),
            });
            return &parent.children.items[parent.children.items.len - 1];
        }
    }

    // Top-level state
    return model.ensureState(id);
}

fn tryParseTransition(line: []const u8, model: *StateModel, ctx: *ParseContext) !bool {
    const arrow_pos = pu.indexOfStr(line, "-->") orelse return false;

    const from = pu.strip(line[0..arrow_pos]);
    const after_arrow = pu.strip(line[arrow_pos + 3 ..]);

    if (from.len == 0 or after_arrow.len == 0) return false;

    var to = after_arrow;
    var label: ?[]const u8 = null;

    if (pu.indexOfStr(after_arrow, " : ")) |colon| {
        to = pu.strip(after_arrow[0..colon]);
        label = pu.strip(after_arrow[colon + 3 ..]);
    }

    if (to.len == 0) return false;

    _ = try ensureStateInContext(model, ctx, from);
    _ = try ensureStateInContext(model, ctx, to);

    // If inside a composite state, add as a child transition or region transition;
    // otherwise add as a top-level transition.
    const parent_id = ctx.currentParent();
    if (parent_id) |pid| {
        if (model.findStateRecursive(pid)) |parent| {
            // If in region mode, add transition to the active region
            if (ctx.currentRegionIndex()) |region_idx| {
                if (region_idx < parent.regions.items.len) {
                    try parent.regions.items[region_idx].transitions.append(.{
                        .from = from,
                        .to = to,
                        .label = label,
                    });
                    return true;
                }
            }
            try StateModel.addChildTransition(parent, from, to, label);
            return true;
        }
    }

    try model.transitions.append(.{
        .from = from,
        .to = to,
        .label = label,
    });

    return true;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "state parse states and transitions" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Active : start
        \\    Active --> [*]
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 3), model.transitions.items.len);
    // [*], Idle, Active should all exist
    try testing.expect(model.findStateMut("[*]") != null);
    try testing.expect(model.findStateMut("Idle") != null);
    try testing.expect(model.findStateMut("Active") != null);
}

test "state parse transition label" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    A --> B : go
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.transitions.items.len);
    try testing.expectEqualStrings("go", model.transitions.items[0].label orelse "");
}

test "state parse state declaration with description" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state "Waiting for input" as Wait
        \\    Wait --> Done
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const wait = model.findStateMut("Wait") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Waiting for input", wait.label);
}

test "state parse fork and join" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state fork_state <<fork>>
        \\    state join_state <<join>>
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const fork = model.findStateMut("fork_state") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.fork, fork.state_type);
    const join = model.findStateMut("join_state") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.join, join.state_type);
}

test "state parse empty input" {
    const allocator = testing.allocator;
    var model = try parse(allocator, "");
    defer model.deinit();
    try testing.expectEqual(@as(usize, 0), model.states.items.len);
}

test "state parse nested composite states" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Outer {
        \\        A --> B
        \\        state Inner {
        \\            C --> D
        \\        }
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const outer = model.findStateMut("Outer") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.composite, outer.state_type);
    // Outer should have children: A, B, Inner
    try testing.expect(outer.children.items.len >= 2);

    // Inner should be a composite child of Outer
    var found_inner = false;
    for (outer.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "Inner")) {
            found_inner = true;
            try testing.expectEqual(sm.StateType.composite, child.state_type);
            // Inner should have children: C, D
            try testing.expect(child.children.items.len >= 2);
        }
    }
    try testing.expect(found_inner);
}

test "state parse inline note" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> Active
        \\    note right of Active : This is active
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("Active", model.notes.items[0].state_id);
    try testing.expectEqual(sm.NotePosition.right, model.notes.items[0].position);
    try testing.expectEqualStrings("This is active", model.notes.items[0].text);
}

test "state parse left note" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> Active
        \\    note left of Active : Left side note
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqual(sm.NotePosition.left, model.notes.items[0].position);
    try testing.expectEqualStrings("Left side note", model.notes.items[0].text);
}

test "state parse multiline note" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> Active
        \\    note right of Active
        \\        This is line 1
        \\    end note
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("Active", model.notes.items[0].state_id);
    try testing.expectEqualStrings("This is line 1", model.notes.items[0].text);
}

test "state parse choice pseudostate" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state is_ready <<choice>>
        \\    [*] --> is_ready
        \\    is_ready --> Yes : ready
        \\    is_ready --> No : not ready
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const choice = model.findStateMut("is_ready") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.choice, choice.state_type);
    try testing.expectEqual(@as(usize, 3), model.transitions.items.len);
}

test "state parse direction directive" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    direction LR
        \\    [*] --> A
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(graph_mod.Direction.lr, model.direction);
    try testing.expectEqual(graph_mod.Direction.lr, model.graph.direction);
}

test "state parse fork join with transitions" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state fork_state <<fork>>
        \\    state join_state <<join>>
        \\    [*] --> fork_state
        \\    fork_state --> A
        \\    fork_state --> B
        \\    A --> join_state
        \\    B --> join_state
        \\    join_state --> [*]
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const fork = model.findStateMut("fork_state") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.fork, fork.state_type);
    const join = model.findStateMut("join_state") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.join, join.state_type);
    try testing.expectEqual(@as(usize, 6), model.transitions.items.len);
}

test "state parse comments are skipped" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    %% This is a comment
        \\    A --> B
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.transitions.items.len);
    try testing.expectEqual(@as(usize, 2), model.states.items.len);
}

test "state parse composite with description and brace" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state "Processing Phase" as Processing {
        \\        [*] --> Validate
        \\        Validate --> Execute
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const proc = model.findStateMut("Processing") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.composite, proc.state_type);
    try testing.expectEqualStrings("Processing Phase", proc.label);
    // Should have children: [*], Validate, Execute
    try testing.expect(proc.children.items.len >= 2);
    // Should have child transitions
    try testing.expect(proc.child_transitions.items.len >= 2);
}

test "state parse stateDiagram (without v2)" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram
        \\    [*] --> A
        \\    A --> B
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 2), model.transitions.items.len);
}

test "state totalStateCount includes nested" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Outer {
        \\        A --> B
        \\    }
        \\    C --> D
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // Outer, A, B (children of Outer), C, D (top-level)
    try testing.expectEqual(@as(usize, 5), model.totalStateCount());
}

test "state maxDepth for nested composites" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Outer {
        \\        state Inner {
        \\            A --> B
        \\        }
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // Outer -> Inner -> A/B = depth 3
    try testing.expectEqual(@as(usize, 3), model.maxDepth());
}

test "state parse start and end star states" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> Active
        \\    Active --> [*]
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const start = model.findStateMut("[*]") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.start, start.state_type);

    // End state should be created as [*]_end
    const end = model.findStateMut("[*]_end") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.end, end.state_type);
}

// =============================================================================
// Concurrency (--) tests
// =============================================================================

test "state parse concurrency separator creates two regions" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Active {
        \\        [*] --> Processing
        \\        Processing --> Done
        \\        --
        \\        [*] --> Monitoring
        \\        Monitoring --> Alert
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const active = model.findStateMut("Active") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.composite, active.state_type);

    // Should have 2 regions
    try testing.expect(active.hasRegions());
    try testing.expectEqual(@as(usize, 2), active.regionCount());

    // Children should have been migrated to regions (empty direct children)
    try testing.expectEqual(@as(usize, 0), active.children.items.len);
    try testing.expectEqual(@as(usize, 0), active.child_transitions.items.len);

    // Region 0: [*], Processing, Done with 2 transitions
    const r0 = &active.regions.items[0];
    try testing.expectEqual(@as(usize, 3), r0.states.items.len);
    try testing.expectEqual(@as(usize, 2), r0.transitions.items.len);

    // Region 1: [*], Monitoring, Alert with 2 transitions
    const r1 = &active.regions.items[1];
    try testing.expectEqual(@as(usize, 3), r1.states.items.len);
    try testing.expectEqual(@as(usize, 2), r1.transitions.items.len);
}

test "state parse concurrency with three regions" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Parallel {
        \\        A --> B
        \\        --
        \\        C --> D
        \\        --
        \\        E --> F
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const par = model.findStateMut("Parallel") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), par.regionCount());

    // Each region has 2 states and 1 transition
    for (par.regions.items) |*region| {
        try testing.expectEqual(@as(usize, 2), region.states.items.len);
        try testing.expectEqual(@as(usize, 1), region.transitions.items.len);
    }
}

test "state parse concurrency states findable via findStateRecursive" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Active {
        \\        A --> B
        \\        --
        \\        C --> D
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // All states in regions should be findable recursively
    try testing.expect(model.findStateRecursive("A") != null);
    try testing.expect(model.findStateRecursive("B") != null);
    try testing.expect(model.findStateRecursive("C") != null);
    try testing.expect(model.findStateRecursive("D") != null);
}

test "state parse concurrency builds graph correctly" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Active {
        \\        A --> B
        \\        --
        \\        C --> D
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // Graph should contain all states including region states
    try testing.expect(model.graph.nodes.get("Active") != null);
    try testing.expect(model.graph.nodes.get("A") != null);
    try testing.expect(model.graph.nodes.get("B") != null);
    try testing.expect(model.graph.nodes.get("C") != null);
    try testing.expect(model.graph.nodes.get("D") != null);

    // Graph should have 2 edges from region transitions
    try testing.expectEqual(@as(usize, 2), model.graph.edges.items.len);
}

test "state parse concurrency with labeled transitions" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Comp {
        \\        X --> Y : process
        \\        --
        \\        P --> Q : monitor
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const comp = model.findStateMut("Comp") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), comp.regionCount());

    // Check transition labels in regions
    const r0 = &comp.regions.items[0];
    try testing.expectEqual(@as(usize, 1), r0.transitions.items.len);
    try testing.expectEqualStrings("process", r0.transitions.items[0].label orelse "");

    const r1 = &comp.regions.items[1];
    try testing.expectEqual(@as(usize, 1), r1.transitions.items.len);
    try testing.expectEqualStrings("monitor", r1.transitions.items[0].label orelse "");
}

test "state parse no concurrency without separator" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Comp {
        \\        A --> B
        \\        B --> C
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const comp = model.findStateMut("Comp") orelse return error.TestUnexpectedResult;
    // No regions — states are in children
    try testing.expect(!comp.hasRegions());
    try testing.expectEqual(@as(usize, 3), comp.children.items.len);
    try testing.expectEqual(@as(usize, 2), comp.child_transitions.items.len);
}

test "state parse concurrency totalStateCount" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Comp {
        \\        A --> B
        \\        --
        \\        C --> D
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // Comp(1) + A(1) + B(1) + C(1) + D(1) = 5
    try testing.expectEqual(@as(usize, 5), model.totalStateCount());
}

// =============================================================================
// Multi-line note concatenation tests
// =============================================================================

test "state parse multiline note two lines concatenated" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> Active
        \\    note right of Active
        \\        Line one
        \\        Line two
        \\    end note
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("Active", model.notes.items[0].state_id);
    // Both lines should be joined with a newline
    try testing.expectEqualStrings("Line one\nLine two", model.notes.items[0].text);
}

test "state parse multiline note three lines" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> S
        \\    note left of S
        \\        First line
        \\        Second line
        \\        Third line
        \\    end note
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("First line\nSecond line\nThird line", model.notes.items[0].text);
    try testing.expectEqual(sm.NotePosition.left, model.notes.items[0].position);
}

test "state parse multiline note single line no allocation" {
    // A single-line multi-line note block should not allocate extra memory
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> S
        \\    note right of S
        \\        Only line
        \\    end note
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("Only line", model.notes.items[0].text);
    // No owned strings should have been allocated (single-line borrows from source)
    try testing.expectEqual(@as(usize, 0), model.owned_strings.items.len);
}

// =============================================================================
// Additional stateDiagram-v2 edge case tests
// =============================================================================

test "state parse accTitle directive is silently ignored" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    accTitle: My State Machine
        \\    [*] --> S1
        \\    S1 --> [*]
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // accTitle should not create a state or error
    try testing.expectEqual(@as(usize, 2), model.transitions.items.len);
    try testing.expect(model.findStateMut("S1") != null);
}

test "state parse accDescr directive is silently ignored" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    accDescr: A description of the state machine
        \\    A --> B
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.transitions.items.len);
}

test "state parse self-transition" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    Idle --> Idle : keepalive
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.transitions.items.len);
    try testing.expectEqualStrings("Idle", model.transitions.items[0].from);
    try testing.expectEqualStrings("Idle", model.transitions.items[0].to);
    try testing.expectEqualStrings("keepalive", model.transitions.items[0].label.?);
}

test "state parse history and deep history pseudo-states" {
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    state Outer {
        \\        [*] --> [H]
        \\        [H] --> Inner
        \\    }
        \\    state Outer2 {
        \\        [*] --> [H*]
        \\        [H*] --> Deep
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const outer = model.findStateMut("Outer") orelse return error.TestUnexpectedResult;
    var found_h = false;
    for (outer.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "[H]")) {
            try testing.expectEqual(sm.StateType.history, child.state_type);
            found_h = true;
        }
    }
    try testing.expect(found_h);

    const outer2 = model.findStateMut("Outer2") orelse return error.TestUnexpectedResult;
    var found_hstar = false;
    for (outer2.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "[H*]")) {
            try testing.expectEqual(sm.StateType.deep_history, child.state_type);
            found_hstar = true;
        }
    }
    try testing.expect(found_hstar);
}

test "state parse note with colon variant" {
    // "note right of X: text" (colon immediately after id, no space before colon)
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> S
        \\    note right of S: Inline text
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("S", model.notes.items[0].state_id);
    try testing.expectEqualStrings("Inline text", model.notes.items[0].text);
}

test "state parse complex diagram with all v2 features" {
    // A comprehensive stateDiagram-v2 diagram combining all supported features
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    direction LR
        \\    state "Initializing" as Init
        \\    state Active {
        \\        [*] --> Processing
        \\        Processing --> Done
        \\        --
        \\        [*] --> Monitoring
        \\        Monitoring --> Alert
        \\    }
        \\    state fork_s <<fork>>
        \\    state join_s <<join>>
        \\    state choice_s <<choice>>
        \\    [*] --> Init
        \\    Init --> fork_s
        \\    fork_s --> Active
        \\    fork_s --> Idle
        \\    Active --> join_s
        \\    Idle --> join_s
        \\    join_s --> choice_s
        \\    choice_s --> [*] : complete
        \\    choice_s --> Init : retry
        \\    note right of Active : Runs concurrent regions
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // Direction should be LR as specified
    try testing.expectEqual(@import("../models/graph.zig").Direction.lr, model.direction);

    // State with description
    const init_state = model.findStateMut("Init") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Initializing", init_state.label);

    // Fork/join/choice
    const fork = model.findStateMut("fork_s") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.fork, fork.state_type);
    const join = model.findStateMut("join_s") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.join, join.state_type);
    const choice = model.findStateMut("choice_s") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.choice, choice.state_type);

    // Composite with concurrent regions
    const active = model.findStateMut("Active") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.composite, active.state_type);
    try testing.expectEqual(@as(usize, 2), active.regionCount());

    // Note
    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("Active", model.notes.items[0].state_id);
}

test "state parse two-level nested composite states" {
    // Verifies that the parser correctly builds 2 levels of nested composite states.
    // Level 0 (top): Active is a composite state.
    // Level 1 (inside Active): Working is a composite state (child of Active).
    // Level 2 (inside Working): Processing, Validating, Done are leaf states.
    const allocator = testing.allocator;
    const source =
        \\stateDiagram-v2
        \\    [*] --> Active
        \\    state Active {
        \\        [*] --> Idle
        \\        Idle --> Working : start
        \\        state Working {
        \\            [*] --> Processing
        \\            Processing --> Validating
        \\            Validating --> Done
        \\            Done --> [*]
        \\        }
        \\        Working --> Idle : finish
        \\        Working --> Failed : error
        \\    }
        \\    Active --> Cleanup : shutdown
        \\    Cleanup --> [*]
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // Top-level Active must be a composite state
    const active = model.findStateMut("Active") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.composite, active.state_type);

    // Level 1: Working is a direct child of Active and must also be composite
    var working_state: ?*sm.State = null;
    for (active.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "Working")) {
            working_state = child;
            break;
        }
    }
    const working = working_state orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.composite, working.state_type);

    // Level 2: Processing must be a child of Working (leaf state)
    var found_processing = false;
    var found_validating = false;
    var found_done = false;
    for (working.children.items) |*grandchild| {
        if (std.mem.eql(u8, grandchild.id, "Processing")) found_processing = true;
        if (std.mem.eql(u8, grandchild.id, "Validating")) found_validating = true;
        if (std.mem.eql(u8, grandchild.id, "Done")) found_done = true;
    }
    try testing.expect(found_processing);
    try testing.expect(found_validating);
    try testing.expect(found_done);

    // Top-level Cleanup and its transition from Active must be present
    const cleanup = model.findStateMut("Cleanup") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sm.StateType.normal, cleanup.state_type);

    // Active --> Cleanup transition should exist at top level
    var found_shutdown_transition = false;
    for (model.transitions.items) |t| {
        if (std.mem.eql(u8, t.from, "Active") and std.mem.eql(u8, t.to, "Cleanup")) {
            found_shutdown_transition = true;
        }
    }
    try testing.expect(found_shutdown_transition);
}
