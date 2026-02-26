const std = @import("std");
const Allocator = std.mem.Allocator;
const tokenizer = @import("tokenizer.zig");
const flowchart_parser = @import("parsers/flowchart.zig");
const FlowchartModel = @import("models/flowchart_model.zig").FlowchartModel;

pub const DiagramType = enum {
    flowchart,
    sequence,
    class_diagram,
    unsupported,
};

pub const DetectResult = union(enum) {
    flowchart: FlowchartModel,
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
            // Return unsupported for other diagram types
            return .{ .unsupported = tok.text };
        }
        break;
    }

    return .{ .unsupported = "unknown" };
}
