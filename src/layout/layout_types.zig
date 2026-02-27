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
            .rect = std.mem.zeroes(Rect),
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
