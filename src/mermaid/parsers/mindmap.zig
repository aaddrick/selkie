const std = @import("std");
const Allocator = std.mem.Allocator;
const mm = @import("../models/mindmap_model.zig");
const MindMapModel = mm.MindMapModel;
const MindMapNode = mm.MindMapNode;
const NodeShape = mm.NodeShape;

pub fn parse(allocator: Allocator, source: []const u8) !MindMapModel {
    var model = MindMapModel.init(allocator);
    errdefer model.deinit();

    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();

    var start: usize = 0;
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
            try lines.append(source[start..i]);
            start = i + 1;
        }
    }
    if (start < source.len) {
        try lines.append(source[start..]);
    }

    // Stack of (node_ptr, indent_level) for tracking parent hierarchy
    var stack = std.ArrayList(StackEntry).init(allocator);
    defer stack.deinit();

    var past_header = false;

    for (lines.items) |raw_line| {
        // Skip empty lines and comments
        const trimmed = strip(raw_line);
        if (trimmed.len == 0 or isComment(trimmed)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, trimmed, "mindmap") or startsWith(trimmed, "mindmap ")) {
                past_header = true;
                continue;
            }
            past_header = true;
            continue;
        }

        // Determine indentation level (count leading spaces/tabs)
        const indent = countIndent(raw_line);
        const content = strip(raw_line);
        if (content.len == 0) continue;

        // Parse node shape and label
        var shape: NodeShape = .default_shape;
        var label: []const u8 = content;

        if (content.len >= 4 and content[0] == '(' and content[1] == '(' and content[content.len - 1] == ')' and content[content.len - 2] == ')') {
            shape = .circle;
            label = content[2 .. content.len - 2];
        } else if (content.len >= 4 and content[0] == '{' and content[1] == '{' and content[content.len - 1] == '}' and content[content.len - 2] == '}') {
            shape = .hexagon;
            label = content[2 .. content.len - 2];
        } else if (content.len >= 2 and content[0] == '(' and content[content.len - 1] == ')') {
            shape = .rounded;
            label = content[1 .. content.len - 1];
        } else if (content.len >= 2 and content[0] == '[' and content[content.len - 1] == ']') {
            shape = .square;
            label = content[1 .. content.len - 1];
        } else if (content.len >= 2 and content[0] == ')' and content[content.len - 1] == '(') {
            shape = .cloud;
            label = content[1 .. content.len - 1];
        }

        var node = MindMapNode.init(allocator);
        node.label = label;
        node.shape = shape;

        if (model.root == null) {
            // First node is the root
            node.depth = 0;
            model.root = node;
            try stack.append(.{ .indent = indent, .depth = 0 });
        } else {
            // Find parent: pop stack until we find an indent level less than current
            while (stack.items.len > 1 and stack.items[stack.items.len - 1].indent >= indent) {
                _ = stack.pop();
            }

            const parent_depth = stack.items[stack.items.len - 1].depth;
            node.depth = parent_depth + 1;

            // Navigate to parent node
            const parent = getNodeAtDepthPath(&model, stack);
            if (parent) |p| {
                try p.children.append(node);
            }
            try stack.append(.{ .indent = indent, .depth = node.depth });
        }
    }

    return model;
}

const StackEntry = struct {
    indent: usize,
    depth: u32,
};

fn getNodeAtDepthPath(model: *MindMapModel, stack: std.ArrayList(StackEntry)) ?*MindMapNode {
    if (model.root == null) return null;
    var current: *MindMapNode = &model.root.?;

    // Skip root (index 0), navigate through children
    for (stack.items[1..]) |_| {
        if (current.children.items.len == 0) return current;
        current = &current.children.items[current.children.items.len - 1];
    }
    return current;
}

fn countIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ') {
            count += 1;
        } else if (ch == '\t') {
            count += 4;
        } else {
            break;
        }
    }
    return count;
}

fn strip(s: []const u8) []const u8 {
    var st: usize = 0;
    while (st < s.len and (s[st] == ' ' or s[st] == '\t' or s[st] == '\r')) : (st += 1) {}
    var end = s.len;
    while (end > st and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[st..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn isComment(line: []const u8) bool {
    return line.len >= 2 and line[0] == '%' and line[1] == '%';
}
