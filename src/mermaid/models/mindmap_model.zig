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
};
