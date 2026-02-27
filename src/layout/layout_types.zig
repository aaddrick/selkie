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

pub const LayoutNodeKind = enum {
    text_block,
    heading,
    code_block,
    thematic_break,
    block_quote_border,
    table_cell,
    table_border,
    table_row_bg,
    image,
    mermaid_diagram,
};

pub const LayoutNode = struct {
    kind: LayoutNodeKind,
    rect: Rect,
    allocator: Allocator,
    text_runs: std.ArrayList(TextRun),
    // Code block content
    code_text: ?[]const u8 = null,
    code_bg_color: ?rl.Color = null,
    code_lang: ?[]const u8 = null,
    line_number_gutter_width: f32 = 0,
    // Heading level for styling
    heading_level: u8 = 0,
    // Block quote depth
    blockquote_depth: u8 = 0,
    // HR color
    hr_color: ?rl.Color = null,
    // Image data
    image_texture: ?rl.Texture2D = null,
    image_alt: ?[]const u8 = null,
    // Mermaid diagram data
    mermaid_flowchart: ?*FlowchartModel = null,
    mermaid_sequence: ?*SequenceModel = null,
    mermaid_pie: ?*PieModel = null,
    mermaid_gantt: ?*GanttModel = null,
    mermaid_class: ?*ClassModel = null,
    mermaid_er: ?*ERModel = null,
    mermaid_state: ?*StateModel = null,
    mermaid_mindmap: ?*MindMapModel = null,
    mermaid_gitgraph: ?*GitGraphModel = null,
    mermaid_journey: ?*JourneyModel = null,
    mermaid_timeline: ?*TimelineModel = null,

    pub fn init(allocator: Allocator) LayoutNode {
        return .{
            .kind = .text_block,
            .rect = std.mem.zeroes(Rect),
            .allocator = allocator,
            .text_runs = std.ArrayList(TextRun).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutNode) void {
        self.text_runs.deinit();

        // Free heap-allocated mermaid models (created via allocator.create() in mermaid_layout.zig)
        inline for (.{
            "mermaid_flowchart",
            "mermaid_sequence",
            "mermaid_pie",
            "mermaid_gantt",
            "mermaid_class",
            "mermaid_er",
            "mermaid_state",
            "mermaid_mindmap",
            "mermaid_gitgraph",
            "mermaid_journey",
            "mermaid_timeline",
        }) |field_name| {
            if (@field(self, field_name)) |model| {
                model.deinit();
                self.allocator.destroy(model);
            }
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
