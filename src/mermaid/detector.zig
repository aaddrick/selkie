const std = @import("std");
const Allocator = std.mem.Allocator;
const tokenizer = @import("tokenizer.zig");
const flowchart_parser = @import("parsers/flowchart.zig");
const sequence_parser = @import("parsers/sequence.zig");
const pie_parser = @import("parsers/pie.zig");
const gantt_parser = @import("parsers/gantt.zig");
const FlowchartModel = @import("models/flowchart_model.zig").FlowchartModel;
const SequenceModel = @import("models/sequence_model.zig").SequenceModel;
const PieModel = @import("models/pie_model.zig").PieModel;
const GanttModel = @import("models/gantt_model.zig").GanttModel;

pub const DiagramType = enum {
    flowchart,
    sequence,
    pie,
    gantt,
    class_diagram,
    unsupported,
};

pub const DetectResult = union(enum) {
    flowchart: FlowchartModel,
    sequence: SequenceModel,
    pie: PieModel,
    gantt: GanttModel,
    unsupported: []const u8,
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
            // Return unsupported for other diagram types
            return .{ .unsupported = tok.text };
        }
        break;
    }

    return .{ .unsupported = "unknown" };
}
