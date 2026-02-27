const std = @import("std");
const Allocator = std.mem.Allocator;
const pu = @import("../parse_utils.zig");
const sm = @import("../models/state_model.zig");
const StateModel = sm.StateModel;
const State = sm.State;
const StateType = sm.StateType;
const Transition = sm.Transition;

pub fn parse(allocator: Allocator, source: []const u8) !StateModel {
    var model = StateModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    var past_header = false;

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

        // State declaration: "state "Description" as StateId"
        if (pu.startsWith(line, "state ")) {
            try parseStateDeclaration(line, &model);
            continue;
        }

        // Transition: "StateA --> StateB" or "StateA --> StateB : label"
        if (try tryParseTransition(line, &model)) continue;

        // Note: "note right of StateA" etc. - skip for now
        if (pu.startsWith(line, "note ")) continue;
        if (pu.startsWith(line, "end note")) continue;
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

    // Build graph
    try buildGraph(&model);

    return model;
}

fn buildGraph(model: *StateModel) !void {
    for (model.states.items) |state| {
        const shape = switch (state.state_type) {
            .start, .end => graph_mod.NodeShape.circle,
            .choice => graph_mod.NodeShape.diamond,
            .fork, .join => graph_mod.NodeShape.rectangle,
            else => graph_mod.NodeShape.rounded,
        };
        try model.graph.addNode(state.id, state.label, shape);

        // Override sizes for special states
        if (model.graph.nodes.getPtr(state.id)) |gnode| {
            switch (state.state_type) {
                .start, .end => {
                    gnode.width = 24;
                    gnode.height = 24;
                },
                .fork, .join => {
                    gnode.width = 80;
                    gnode.height = 8;
                },
                .choice => {
                    gnode.width = 30;
                    gnode.height = 30;
                },
                else => {},
            }
        }
    }
    for (model.transitions.items) |t| {
        // Remap [*] as target to [*]_end
        var to = t.to;
        if (std.mem.eql(u8, t.to, "[*]") and model.graph.nodes.get("[*]_end") != null) {
            // Check if this is a transition TO [*] (end) - need to check if [*] is also a source
            var is_source = false;
            for (model.transitions.items) |t2| {
                if (std.mem.eql(u8, t2.from, "[*]")) {
                    is_source = true;
                    break;
                }
            }
            if (is_source) {
                to = "[*]_end";
            }
        }
        var edge = try model.graph.addEdge(t.from, to);
        if (t.label != null) edge.label = t.label;
    }
}

const graph_mod = @import("../models/graph.zig");

fn parseStateDeclaration(line: []const u8, model: *StateModel) !void {
    const rest = pu.strip(line["state ".len..]);

    // "state "Description" as StateId"
    if (rest.len > 0 and rest[0] == '"') {
        if (pu.indexOfCharFrom(rest, '"', 1)) |close_quote| {
            const desc = rest[1..close_quote];
            const after = pu.strip(rest[close_quote + 1 ..]);
            if (pu.startsWith(after, "as ")) {
                const state_id = pu.strip(after["as ".len..]);
                if (state_id.len > 0) {
                    var state = try model.ensureState(state_id);
                    state.label = desc;
                    state.description = desc;
                    return;
                }
            }
        }
    }

    // "state StateId" - just declaration
    // Check for "state StateId {" (composite - we skip body for now)
    if (pu.endsWith(rest, "{")) {
        const state_id = pu.strip(rest[0 .. rest.len - 1]);
        if (state_id.len > 0) {
            var state = try model.ensureState(state_id);
            state.state_type = .composite;
        }
        return;
    }

    // "state fork_state <<fork>>"
    if (pu.indexOfStr(rest, "<<fork>>")) |_| {
        const state_id = pu.strip(rest[0..pu.indexOfStr(rest, "<<").?]);
        if (state_id.len > 0) {
            var state = try model.ensureState(state_id);
            state.state_type = .fork;
        }
        return;
    }
    if (pu.indexOfStr(rest, "<<join>>")) |_| {
        const state_id = pu.strip(rest[0..pu.indexOfStr(rest, "<<").?]);
        if (state_id.len > 0) {
            var state = try model.ensureState(state_id);
            state.state_type = .join;
        }
        return;
    }
    if (pu.indexOfStr(rest, "<<choice>>")) |_| {
        const state_id = pu.strip(rest[0..pu.indexOfStr(rest, "<<").?]);
        if (state_id.len > 0) {
            var state = try model.ensureState(state_id);
            state.state_type = .choice;
        }
        return;
    }

    // Simple declaration
    if (rest.len > 0) {
        _ = try model.ensureState(rest);
    }
}

fn tryParseTransition(line: []const u8, model: *StateModel) !bool {
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

    _ = try model.ensureState(from);
    _ = try model.ensureState(to);

    try model.transitions.append(.{
        .from = from,
        .to = to,
        .label = label,
    });

    return true;
}
