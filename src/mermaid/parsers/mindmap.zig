const std = @import("std");
const Allocator = std.mem.Allocator;
const pu = @import("../parse_utils.zig");
const mm = @import("../models/mindmap_model.zig");
const MindMapModel = mm.MindMapModel;
const MindMapNode = mm.MindMapNode;
const NodeShape = mm.NodeShape;

pub fn parse(allocator: Allocator, source: []const u8) !MindMapModel {
    var model = MindMapModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    // Stack of (node_ptr, indent_level) for tracking parent hierarchy
    var stack = std.ArrayList(StackEntry).init(allocator);
    defer stack.deinit();

    var past_header = false;

    for (lines.items) |raw_line| {
        // Skip empty lines and comments
        const trimmed = pu.strip(raw_line);
        if (trimmed.len == 0 or pu.isComment(trimmed)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, trimmed, "mindmap") or pu.startsWith(trimmed, "mindmap ")) {
                past_header = true;
                continue;
            }
            past_header = true;
            continue;
        }

        // Determine indentation level (count leading spaces/tabs)
        const indent = countIndent(raw_line);
        const content = pu.strip(raw_line);
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

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "mindmap parse tree structure" {
    const allocator = testing.allocator;
    const source =
        \\mindmap
        \\    Root
        \\        Child1
        \\        Child2
        \\            Grandchild
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expect(model.root != null);
    try testing.expectEqualStrings("Root", model.root.?.label);
    try testing.expectEqual(@as(usize, 2), model.root.?.children.items.len);
    try testing.expectEqualStrings("Child1", model.root.?.children.items[0].label);
    try testing.expectEqualStrings("Child2", model.root.?.children.items[1].label);
    try testing.expectEqual(@as(usize, 1), model.root.?.children.items[1].children.items.len);
}

test "mindmap parse node shapes" {
    const allocator = testing.allocator;
    const source =
        \\mindmap
        \\    (Rounded)
        \\        [Square]
        \\        ((Circle))
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expect(model.root != null);
    try testing.expectEqual(mm.NodeShape.rounded, model.root.?.shape);
    try testing.expectEqual(mm.NodeShape.square, model.root.?.children.items[0].shape);
    try testing.expectEqual(mm.NodeShape.circle, model.root.?.children.items[1].shape);
}

test "mindmap parse empty input" {
    const allocator = testing.allocator;
    var model = try parse(allocator, "");
    defer model.deinit();
    try testing.expect(model.root == null);
}

test "mindmap parse indentation determines hierarchy" {
    const allocator = testing.allocator;
    const source =
        \\mindmap
        \\    Root
        \\        A
        \\        B
        \\        C
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expect(model.root != null);
    try testing.expectEqual(@as(usize, 3), model.root.?.children.items.len);
}
