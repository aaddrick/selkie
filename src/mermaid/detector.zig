const std = @import("std");
const Allocator = std.mem.Allocator;
const tokenizer = @import("tokenizer.zig");
const flowchart_parser = @import("parsers/flowchart.zig");
const sequence_parser = @import("parsers/sequence.zig");
const pie_parser = @import("parsers/pie.zig");
const gantt_parser = @import("parsers/gantt.zig");
const class_parser = @import("parsers/class_diagram.zig");
const er_parser = @import("parsers/er.zig");
const state_parser = @import("parsers/state.zig");
const mindmap_parser = @import("parsers/mindmap.zig");
const gitgraph_parser = @import("parsers/gitgraph.zig");
const journey_parser = @import("parsers/journey.zig");
const timeline_parser = @import("parsers/timeline_diagram.zig");
const FlowchartModel = @import("models/flowchart_model.zig").FlowchartModel;
const SequenceModel = @import("models/sequence_model.zig").SequenceModel;
const PieModel = @import("models/pie_model.zig").PieModel;
const GanttModel = @import("models/gantt_model.zig").GanttModel;
const ClassModel = @import("models/class_model.zig").ClassModel;
const ERModel = @import("models/er_model.zig").ERModel;
const StateModel = @import("models/state_model.zig").StateModel;
const MindMapModel = @import("models/mindmap_model.zig").MindMapModel;
const GitGraphModel = @import("models/gitgraph_model.zig").GitGraphModel;
const JourneyModel = @import("models/journey_model.zig").JourneyModel;
const TimelineModel = @import("models/timeline_model.zig").TimelineModel;

pub const DiagramType = enum {
    flowchart,
    sequence,
    pie,
    gantt,
    class_diagram,
    er_diagram,
    state_diagram,
    mindmap,
    gitgraph,
    journey,
    timeline,
    unsupported,
};

pub const DetectResult = union(enum) {
    flowchart: FlowchartModel,
    sequence: SequenceModel,
    pie: PieModel,
    gantt: GanttModel,
    class_diagram: ClassModel,
    er_diagram: ERModel,
    state_diagram: StateModel,
    mindmap: MindMapModel,
    gitgraph: GitGraphModel,
    journey: JourneyModel,
    timeline: TimelineModel,
    unsupported: []const u8,

    /// Deinit the contained model. Call this when the DetectResult is not
    /// transferred to a heap-allocated model pointer (i.e. on error paths
    /// or when the caller decides not to use the result).
    pub fn deinit(self: *DetectResult) void {
        switch (self.*) {
            .unsupported => {},
            inline else => |*model| model.deinit(),
        }
    }
};

pub fn detect(allocator: Allocator, source: []const u8) !DetectResult {
    var tokens = try tokenizer.tokenize(allocator, source);
    defer tokens.deinit();

    // Find first non-newline, non-comment token to determine diagram type
    var i: usize = 0;
    while (i < tokens.items.len) : (i += 1) {
        const tok = tokens.items[i];
        if (tok.type == .newline or tok.type == .comment) continue;
        if (tok.type == .keyword or tok.type == .identifier) {
            if (std.mem.eql(u8, tok.text, "graph") or std.mem.eql(u8, tok.text, "flowchart")) {
                const model = try flowchart_parser.parse(allocator, tokens);
                return .{ .flowchart = model };
            }
            if (std.mem.eql(u8, tok.text, "sequenceDiagram")) {
                const model = try sequence_parser.parse(allocator, source);
                return .{ .sequence = model };
            }
            if (std.mem.eql(u8, tok.text, "pie")) {
                const model = try pie_parser.parse(allocator, source);
                return .{ .pie = model };
            }
            if (std.mem.eql(u8, tok.text, "gantt")) {
                const model = try gantt_parser.parse(allocator, source);
                return .{ .gantt = model };
            }
            if (std.mem.eql(u8, tok.text, "classDiagram")) {
                const model = try class_parser.parse(allocator, source);
                return .{ .class_diagram = model };
            }
            if (std.mem.eql(u8, tok.text, "erDiagram")) {
                const model = try er_parser.parse(allocator, source);
                return .{ .er_diagram = model };
            }
            // stateDiagram or stateDiagram-v2 — tokenizer may split on hyphen
            if (std.mem.eql(u8, tok.text, "stateDiagram")) {
                const model = try state_parser.parse(allocator, source);
                return .{ .state_diagram = model };
            }
            if (std.mem.eql(u8, tok.text, "mindmap")) {
                const model = try mindmap_parser.parse(allocator, source);
                return .{ .mindmap = model };
            }
            if (std.mem.eql(u8, tok.text, "gitGraph")) {
                const model = try gitgraph_parser.parse(allocator, source);
                return .{ .gitgraph = model };
            }
            if (std.mem.eql(u8, tok.text, "journey")) {
                const model = try journey_parser.parse(allocator, source);
                return .{ .journey = model };
            }
            if (std.mem.eql(u8, tok.text, "timeline")) {
                const model = try timeline_parser.parse(allocator, source);
                return .{ .timeline = model };
            }
            // Return unsupported for other diagram types
            return .{ .unsupported = tok.text };
        }
        break;
    }

    return .{ .unsupported = "unknown" };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "detect flowchart" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "graph TD\nA --> B");
    defer result.deinit();
    try testing.expect(result == .flowchart);
}

test "detect flowchart keyword" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "flowchart LR\nA --> B");
    defer result.deinit();
    try testing.expect(result == .flowchart);
}

test "detect sequenceDiagram" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "sequenceDiagram\nAlice->>Bob: Hi");
    defer result.deinit();
    try testing.expect(result == .sequence);
}

test "detect pie" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "pie\n\"A\" : 50");
    defer result.deinit();
    try testing.expect(result == .pie);
}

test "detect gantt" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "gantt\ntitle Test\nTask :2024-01-01, 5d");
    defer result.deinit();
    try testing.expect(result == .gantt);
}

test "detect classDiagram" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "classDiagram\nA <|-- B");
    defer result.deinit();
    try testing.expect(result == .class_diagram);
}

test "detect erDiagram" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "erDiagram\nA ||--o{ B : has");
    defer result.deinit();
    try testing.expect(result == .er_diagram);
}

test "detect stateDiagram" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "stateDiagram\n[*] --> S1");
    defer result.deinit();
    try testing.expect(result == .state_diagram);
}

test "detect mindmap" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "mindmap\n  Root\n    Child");
    defer result.deinit();
    try testing.expect(result == .mindmap);
}

test "detect gitGraph" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "gitGraph\ncommit");
    defer result.deinit();
    try testing.expect(result == .gitgraph);
}

test "detect journey" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "journey\ntitle Test");
    defer result.deinit();
    try testing.expect(result == .journey);
}

test "detect timeline" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "timeline\ntitle Test");
    defer result.deinit();
    try testing.expect(result == .timeline);
}

test "detect unsupported diagram type" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "unknownDiagram\nfoo bar");
    defer result.deinit();
    try testing.expect(result == .unsupported);
}

test "detect empty input" {
    const allocator = testing.allocator;
    var result = try detect(allocator, "");
    defer result.deinit();
    try testing.expect(result == .unsupported);
}
