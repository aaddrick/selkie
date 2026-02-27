const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");

const FlowchartModel = @import("../mermaid/models/flowchart_model.zig").FlowchartModel;
const SequenceModel = @import("../mermaid/models/sequence_model.zig").SequenceModel;
const PieModel = @import("../mermaid/models/pie_model.zig").PieModel;
const GanttModel = @import("../mermaid/models/gantt_model.zig").GanttModel;
const ClassModel = @import("../mermaid/models/class_model.zig").ClassModel;
const ERModel = @import("../mermaid/models/er_model.zig").ERModel;
const StateModel = @import("../mermaid/models/state_model.zig").StateModel;
const MindMapModel = @import("../mermaid/models/mindmap_model.zig").MindMapModel;
const GitGraphModel = @import("../mermaid/models/gitgraph_model.zig").GitGraphModel;
const JourneyModel = @import("../mermaid/models/journey_model.zig").JourneyModel;
const TimelineModel = @import("../mermaid/models/timeline_model.zig").TimelineModel;

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn bottom(self: Rect) f32 {
        return self.y + self.height;
    }

    pub fn right(self: Rect) f32 {
        return self.x + self.width;
    }

    pub fn overlapsVertically(self: Rect, view_top: f32, view_bottom: f32) bool {
        return self.bottom() > view_top and self.y < view_bottom;
    }
};

pub const TextStyle = struct {
    font_size: f32,
    color: rl.Color,
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
    is_code: bool = false,
    code_bg: ?rl.Color = null,
    link_url: ?[]const u8 = null,
    dimmed: bool = false,
};

pub const TextRun = struct {
    text: []const u8,
    style: TextStyle,
    rect: Rect,
};

pub const MermaidModel = union(enum) {
    flowchart: *FlowchartModel,
    sequence: *SequenceModel,
    pie: *PieModel,
    gantt: *GanttModel,
    class_diagram: *ClassModel,
    er: *ERModel,
    state: *StateModel,
    mindmap: *MindMapModel,
    gitgraph: *GitGraphModel,
    journey: *JourneyModel,
    timeline: *TimelineModel,
};

pub const NodeData = union(enum) {
    text_block: void,
    heading: struct { level: u8 },
    code_block: struct {
        bg_color: ?rl.Color,
        lang: ?[]const u8,
        line_number_gutter_width: f32,
    },
    thematic_break: struct { color: rl.Color },
    block_quote_border: struct { color: rl.Color },
    table_cell: void,
    table_border: struct { color: rl.Color },
    table_row_bg: struct { bg_color: rl.Color },
    image: struct {
        texture: ?rl.Texture2D,
        alt: ?[]const u8,
    },
    mermaid_diagram: MermaidModel,
};

pub const LayoutNode = struct {
    rect: Rect,
    allocator: Allocator,
    text_runs: std.ArrayList(TextRun),
    data: NodeData,

    pub fn init(allocator: Allocator, data: NodeData) LayoutNode {
        return .{
            .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .allocator = allocator,
            .text_runs = std.ArrayList(TextRun).init(allocator),
            .data = data,
        };
    }

    pub fn deinit(self: *LayoutNode) void {
        self.text_runs.deinit();

        // Free heap-allocated mermaid models (created via allocator.create() in mermaid_layout.zig)
        switch (self.data) {
            .mermaid_diagram => |mermaid| {
                switch (mermaid) {
                    inline else => |model| {
                        model.deinit();
                        self.allocator.destroy(model);
                    },
                }
            },
            else => {},
        }
    }
};

pub const LayoutTree = struct {
    nodes: std.ArrayList(LayoutNode),
    total_height: f32,
    allocator: Allocator,
    /// Arena for strings generated during layout (formatted numbers, alt text, etc.).
    /// Freed in bulk by deinit(), so individual strings need no cleanup.
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) LayoutTree {
        return .{
            .nodes = std.ArrayList(LayoutNode).init(allocator),
            .total_height = 0,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *LayoutTree) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit();
        self.arena.deinit();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Rect.bottom returns y + height" {
    const r = Rect{ .x = 10, .y = 20, .width = 100, .height = 50 };
    try testing.expectEqual(@as(f32, 70), r.bottom());
}

test "Rect.right returns x + width" {
    const r = Rect{ .x = 10, .y = 20, .width = 100, .height = 50 };
    try testing.expectEqual(@as(f32, 110), r.right());
}

test "Rect.overlapsVertically detects overlap" {
    const r = Rect{ .x = 0, .y = 100, .width = 50, .height = 50 };
    // Rect spans y=100..150

    // Fully inside
    try testing.expect(r.overlapsVertically(110, 140));
    // Partial overlap top
    try testing.expect(r.overlapsVertically(90, 120));
    // Partial overlap bottom
    try testing.expect(r.overlapsVertically(130, 200));
    // Fully containing
    try testing.expect(r.overlapsVertically(50, 200));
}

test "Rect.overlapsVertically detects no overlap" {
    const r = Rect{ .x = 0, .y = 100, .width = 50, .height = 50 };
    // Rect spans y=100..150

    // Entirely above
    try testing.expect(!r.overlapsVertically(0, 100));
    // Entirely below
    try testing.expect(!r.overlapsVertically(150, 200));
    // Far away
    try testing.expect(!r.overlapsVertically(300, 400));
}

test "Rect with zero dimensions" {
    const r = Rect{ .x = 5, .y = 10, .width = 0, .height = 0 };
    try testing.expectEqual(@as(f32, 10), r.bottom());
    try testing.expectEqual(@as(f32, 5), r.right());
    // Zero-height rect at y=10: bottom=10, does not overlap (10,20)
    try testing.expect(!r.overlapsVertically(10, 20));
}

test "LayoutNode init and deinit with text_block" {
    var node = LayoutNode.init(testing.allocator, .text_block);
    defer node.deinit();
    try testing.expectEqual(@as(f32, 0), node.rect.x);
    try testing.expectEqual(@as(usize, 0), node.text_runs.items.len);
}

test "LayoutTree init and deinit" {
    var tree = LayoutTree.init(testing.allocator);
    defer tree.deinit();
    try testing.expectEqual(@as(f32, 0), tree.total_height);
    try testing.expectEqual(@as(usize, 0), tree.nodes.items.len);
}

test "LayoutTree append nodes" {
    var tree = LayoutTree.init(testing.allocator);
    defer tree.deinit();

    var node = LayoutNode.init(testing.allocator, .text_block);
    node.rect = .{ .x = 0, .y = 0, .width = 100, .height = 50 };
    try tree.nodes.append(node);

    try testing.expectEqual(@as(usize, 1), tree.nodes.items.len);
}
