const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

pub const NodeShape = enum {
    rounded, // (text)
    square, // [text]
    circle, // ((text))
    cloud, // )text(
    hexagon, // {{text}}
    default_shape, // plain text
};

pub const MindMapNode = struct {
    label: []const u8 = "",
    shape: NodeShape = .default_shape,
    children: std.ArrayList(MindMapNode),
    depth: u32 = 0,
    // Layout fields
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    subtree_height: f32 = 0,
    color: rl.Color = rl.Color{ .r = 100, .g = 100, .b = 200, .a = 255 },

    pub fn init(allocator: Allocator) MindMapNode {
        return .{
            .children = std.ArrayList(MindMapNode).init(allocator),
        };
    }

    pub fn deinit(self: *MindMapNode) void {
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
    }
};

pub const MindMapModel = struct {
    root: ?MindMapNode = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) MindMapModel {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MindMapModel) void {
        if (self.root) |*root| {
            root.deinit();
        }
    }

    /// Uniformly scale all node positions/sizes so the diagram fits within
    /// `target_width`. Returns the scale factor applied.
    pub fn scaleToFit(self: *MindMapModel, natural_width: f32, target_width: f32) f32 {
        if (natural_width <= target_width or natural_width <= 0) return 1.0;
        const scale = target_width / natural_width;
        if (self.root) |*root| {
            scaleNode(root, scale);
        }
        return scale;
    }

    fn scaleNode(node: *MindMapNode, scale: f32) void {
        node.x *= scale;
        node.y *= scale;
        node.width *= scale;
        node.height *= scale;
        node.subtree_height *= scale;
        for (node.children.items) |*child| {
            scaleNode(child, scale);
        }
    }
};

// --- Tests ---

const testing = std.testing;

test "MindMapModel.scaleToFit no-op when natural_width <= target_width" {
    var model = MindMapModel.init(testing.allocator);
    defer model.deinit();

    var root = MindMapNode.init(testing.allocator);
    root.x = 100;
    root.y = 50;
    root.width = 80;
    root.height = 40;
    model.root = root;

    const scale = model.scaleToFit(300, 500);
    try testing.expectEqual(@as(f32, 1.0), scale);
    try testing.expectEqual(@as(f32, 100), model.root.?.x);
    try testing.expectEqual(@as(f32, 50), model.root.?.y);
}

test "MindMapModel.scaleToFit null root does not crash" {
    var model = MindMapModel.init(testing.allocator);
    defer model.deinit();

    try testing.expectEqual(@as(?MindMapNode, null), model.root);
    const scale = model.scaleToFit(1000, 500);
    try testing.expectApproxEqAbs(@as(f32, 0.5), scale, 0.0001);
}

test "MindMapModel.scaleToFit scales single root node" {
    var model = MindMapModel.init(testing.allocator);
    defer model.deinit();

    var root = MindMapNode.init(testing.allocator);
    root.x = 200;
    root.y = 100;
    root.width = 160;
    root.height = 80;
    root.subtree_height = 400;
    model.root = root;

    // natural_width=800, target_width=400 => scale=0.5
    const scale = model.scaleToFit(800, 400);
    try testing.expectApproxEqAbs(@as(f32, 0.5), scale, 0.0001);

    const r = model.root.?;
    try testing.expectApproxEqAbs(@as(f32, 100), r.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 50), r.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 80), r.width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 40), r.height, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 200), r.subtree_height, 0.0001);
}

test "MindMapModel.scaleToFit scales children recursively" {
    var model = MindMapModel.init(testing.allocator);
    defer model.deinit();

    var root = MindMapNode.init(testing.allocator);
    root.x = 100;
    root.y = 0;
    root.width = 80;
    root.height = 40;
    root.subtree_height = 300;

    var child = MindMapNode.init(testing.allocator);
    child.x = 300;
    child.y = 100;
    child.width = 60;
    child.height = 30;
    child.subtree_height = 100;

    var grandchild = MindMapNode.init(testing.allocator);
    grandchild.x = 500;
    grandchild.y = 200;
    grandchild.width = 40;
    grandchild.height = 20;
    grandchild.subtree_height = 20;

    try child.children.append(grandchild);
    try root.children.append(child);
    model.root = root;

    // natural_width=1000, target_width=500 => scale=0.5
    const scale = model.scaleToFit(1000, 500);
    try testing.expectApproxEqAbs(@as(f32, 0.5), scale, 0.0001);

    // Check child
    const c = model.root.?.children.items[0];
    try testing.expectApproxEqAbs(@as(f32, 150), c.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 50), c.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 30), c.width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 15), c.height, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 50), c.subtree_height, 0.0001);

    // Check grandchild
    const gc = c.children.items[0];
    try testing.expectApproxEqAbs(@as(f32, 250), gc.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 100), gc.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 20), gc.width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10), gc.height, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10), gc.subtree_height, 0.0001);
}

test "MindMapModel.scaleToFit returns correct scale factor" {
    var model = MindMapModel.init(testing.allocator);
    defer model.deinit();

    model.root = MindMapNode.init(testing.allocator);

    const scale = model.scaleToFit(750, 250);
    try testing.expectApproxEqAbs(@as(f32, 250.0 / 750.0), scale, 0.0001);
}
