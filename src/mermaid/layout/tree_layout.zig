const std = @import("std");
const Allocator = std.mem.Allocator;
const mm = @import("../models/mindmap_model.zig");
const MindMapNode = mm.MindMapNode;
const MindMapModel = mm.MindMapModel;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const Theme = @import("../../theme/theme.zig").Theme;
const rl = @import("raylib");

pub const LayoutResult = struct {
    width: f32,
    height: f32,
};

const node_padding_h: f32 = 16;
const node_padding_v: f32 = 8;
const sibling_spacing: f32 = 16;
const level_spacing: f32 = 60;
const min_node_width: f32 = 50;
const min_node_height: f32 = 30;
const diagram_padding: f32 = 20;

/// Color palette for depth levels
const depth_palette = [_]rl.Color{
    rl.Color{ .r = 76, .g = 114, .b = 176, .a = 255 }, // blue (root)
    rl.Color{ .r = 85, .g = 168, .b = 104, .a = 255 }, // green
    rl.Color{ .r = 221, .g = 132, .b = 82, .a = 255 }, // orange
    rl.Color{ .r = 196, .g = 78, .b = 82, .a = 255 }, // red
    rl.Color{ .r = 129, .g = 114, .b = 178, .a = 255 }, // purple
    rl.Color{ .r = 218, .g = 139, .b = 195, .a = 255 }, // pink
    rl.Color{ .r = 147, .g = 120, .b = 96, .a = 255 }, // brown
    rl.Color{ .r = 140, .g = 140, .b = 140, .a = 255 }, // gray
};

/// Layout a mind map tree. The algorithm:
/// 1. Measure all nodes (label text → width, height)
/// 2. Compute subtree heights bottom-up
/// 3. Assign positions: root centered, children spread vertically to the right
pub fn layout(
    model: *MindMapModel,
    fonts: *const Fonts,
    theme: *const Theme,
    max_width: f32,
) LayoutResult {
    if (model.root == null) return .{ .width = 100, .height = 50 };

    // Step 1: Measure all node sizes
    measureNode(&model.root.?, fonts, theme);

    // Step 2: Compute subtree heights
    computeSubtreeHeight(&model.root.?);

    // Step 3: Assign positions — root at left-center, children spread right
    const total_height = model.root.?.subtree_height;
    const start_x = diagram_padding;
    const start_y = diagram_padding;

    assignPositions(&model.root.?, start_x, start_y, total_height);

    // Step 4: Compute bounds
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    computeBounds(&model.root.?, &max_x, &max_y);

    const width = @min(max_x + diagram_padding, max_width);
    const height = max_y + diagram_padding;

    return .{ .width = width, .height = height };
}

fn measureNode(node: *MindMapNode, fonts: *const Fonts, theme: *const Theme) void {
    const font_size = theme.body_font_size * switch (node.depth) {
        0 => @as(f32, 1.2),
        1 => @as(f32, 1.0),
        else => @as(f32, 0.85),
    };

    const measured = fonts.measure(node.label, font_size, node.depth == 0, false, false);
    node.width = @max(min_node_width, measured.x + node_padding_h * 2);
    node.height = @max(min_node_height, measured.y + node_padding_v * 2);
    node.color = depth_palette[node.depth % depth_palette.len];

    for (node.children.items) |*child| {
        measureNode(child, fonts, theme);
    }
}

fn computeSubtreeHeight(node: *MindMapNode) void {
    if (node.children.items.len == 0) {
        node.subtree_height = node.height;
        return;
    }

    var total: f32 = 0;
    for (node.children.items) |*child| {
        computeSubtreeHeight(child);
        total += child.subtree_height;
    }
    // Add spacing between siblings
    total += @as(f32, @floatFromInt(node.children.items.len -| 1)) * sibling_spacing;

    node.subtree_height = @max(node.height, total);
}

fn assignPositions(node: *MindMapNode, x: f32, y: f32, available_height: f32) void {
    // Center this node vertically in its available space
    node.x = x;
    node.y = y + (available_height - node.height) / 2;

    if (node.children.items.len == 0) return;

    // Children start to the right
    const child_x = x + node.width + level_spacing;

    // Total height needed by children
    var children_total: f32 = 0;
    for (node.children.items) |child| {
        children_total += child.subtree_height;
    }
    children_total += @as(f32, @floatFromInt(node.children.items.len -| 1)) * sibling_spacing;

    // Center children vertically relative to this node's center
    var child_y = node.y + node.height / 2 - children_total / 2;

    for (node.children.items) |*child| {
        assignPositions(child, child_x, child_y, child.subtree_height);
        child_y += child.subtree_height + sibling_spacing;
    }
}

fn computeBounds(node: *const MindMapNode, max_x: *f32, max_y: *f32) void {
    max_x.* = @max(max_x.*, node.x + node.width);
    max_y.* = @max(max_y.*, node.y + node.height);

    for (node.children.items) |*child| {
        computeBounds(child, max_x, max_y);
    }
}
