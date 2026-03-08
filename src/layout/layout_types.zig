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

/// Axis-aligned rectangle in document coordinates (pixels).
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

/// Visual properties for a span of text: font size, color, and inline formatting flags.
pub const TextStyle = struct {
    font_size: f32,
    color: rl.Color,
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
    is_code: bool = false,
    is_kbd: bool = false,
    is_samp: bool = false,
    is_mark: bool = false,
    is_math: bool = false,
    /// Set when text is inside an <ins> tag. Renders with a green underline to
    /// visually indicate insertion, distinct from link underlines (blue) and
    /// plain underline (text color).
    is_ins: bool = false,
    code_bg: ?rl.Color = null,
    link_url: ?[]const u8 = null,
    dimmed: bool = false,
    /// Vertical offset from baseline: negative = up (superscript), positive = down (subscript).
    y_offset: f32 = 0,
};

/// A positioned span of text with uniform styling within a layout node.
pub const TextRun = struct {
    text: []const u8,
    style: TextStyle,
    rect: Rect,
};

/// Tagged union of parsed Mermaid diagram models, one variant per supported diagram type.
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

/// Per-node payload discriminating the visual element type (text, code, image, etc.).
pub const NodeData = union(enum) {
    text_block: void,
    heading: struct { level: u8 },
    code_block: struct {
        bg_color: ?rl.Color,
        lang: ?[]const u8,
        line_number_gutter_width: f32,
    },
    /// Language label header above a code block (e.g., "python", "javascript").
    code_block_header: struct {
        bg_color: rl.Color,
        /// Display label for the language (arena-allocated).
        label: []const u8,
    },
    thematic_break: struct { color: rl.Color },
    block_quote_border: struct { color: rl.Color },
    /// Translucent background fill for a GFM alert/admonition block.
    alert_bg: struct { color: rl.Color },
    table_cell: void,
    table_border: struct { color: rl.Color },
    table_row_bg: struct { bg_color: rl.Color },
    image: struct {
        texture: ?rl.Texture2D,
        alt: ?[]const u8,
    },
    mermaid_diagram: MermaidModel,
    /// Collapsible details/summary section header with disclosure triangle.
    /// `expanded` reflects the current toggle state; `section_id` keys the
    /// persistent collapsed-state map so it survives re-layout.
    /// `anim_progress` is 0.0 when fully collapsed (▶) and 1.0 when fully
    /// expanded (▼); values between drive the smooth triangle rotation.
    /// `focused` is true when this header has keyboard focus (draws a focus ring).
    details_header: struct {
        expanded: bool,
        section_id: u32,
        /// Triangle animation progress: 0.0 = ▶ (collapsed), 1.0 = ▼ (expanded).
        /// Updated in-place each frame by the app; does not require re-layout.
        anim_progress: f32 = 0,
        /// True when this header is the current keyboard-focus target.
        focused: bool = false,
    },
    /// Block-level math expression ($$...$$ or ```math code blocks).
    /// `latex` is the raw LaTeX source (arena-allocated).
    /// `font_size` is the computed display size.
    math_block: struct {
        latex: []const u8,
        font_size: f32,
        color: rl.Color,
        bg_color: ?rl.Color,
    },
};

/// A positioned document element with bounding rect, styled text runs, and type-specific data.
pub const LayoutNode = struct {
    rect: Rect,
    allocator: Allocator,
    text_runs: std.ArrayList(TextRun),
    data: NodeData,
    /// Source file line number (1-based, 0 = unknown). For multi-line elements,
    /// source_end_line > source_line indicates a span (rendered as "N+").
    source_line: u32 = 0,
    source_end_line: u32 = 0,
    /// Optional anchor ID for in-document navigation (e.g., "fn-1" for footnote definitions).
    /// Arena-allocated — freed in bulk by LayoutTree.deinit().
    anchor_id: ?[]const u8 = null,

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

/// Padding inside the source line number gutter (used by layout and renderer).
pub const gutter_padding: f32 = 8;

/// The complete layout result: a flat list of positioned nodes with a string arena.
pub const LayoutTree = struct {
    nodes: std.ArrayList(LayoutNode),
    total_height: f32,
    allocator: Allocator,
    /// Arena for strings generated during layout (formatted numbers, alt text, etc.).
    /// Freed in bulk by deinit(), so individual strings need no cleanup.
    arena: std.heap.ArenaAllocator,
    /// Width of the source line number gutter (0 when line numbers are hidden).
    gutter_width: f32 = 0,

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

test "TextStyle is_kbd defaults to false" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    try testing.expect(!style.is_kbd);
    try testing.expect(!style.is_code);
}

test "TextStyle is_kbd can be set independently" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_code = true,
    };
    try testing.expect(style.is_kbd);
    try testing.expect(style.is_code);
}

test "TextStyle is_samp defaults to false" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    try testing.expect(!style.is_samp);
}

test "TextStyle is_samp can be set independently" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_samp = true,
        .is_code = true,
    };
    try testing.expect(style.is_samp);
    try testing.expect(style.is_code);
    try testing.expect(!style.is_kbd);
}

test "TextStyle is_mark defaults to false" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    try testing.expect(!style.is_mark);
}

test "TextStyle is_mark can be set independently" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_mark = true,
    };
    try testing.expect(style.is_mark);
    try testing.expect(!style.is_kbd);
    try testing.expect(!style.is_code);
}

test "TextStyle is_ins defaults to false" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    try testing.expect(!style.is_ins);
    try testing.expect(!style.is_mark);
    try testing.expect(!style.underline);
}

test "TextStyle is_ins can be set independently of underline" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_ins = true,
        .underline = true,
    };
    try testing.expect(style.is_ins);
    try testing.expect(style.underline);
    try testing.expect(!style.is_kbd);
    try testing.expect(!style.is_mark);
}

test "TextStyle is_ins does not enable is_code or is_samp" {
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_ins = true,
    };
    try testing.expect(style.is_ins);
    try testing.expect(!style.is_code);
    try testing.expect(!style.is_samp);
}

// -------------------------------------------------------------------------
// Sub-AC 2c: Combined HTML flag and markdown style interaction tests.
// These verify that all HTML inline flags can coexist with each other and
// with markdown-derived style properties (bold, italic, underline, link_url).
// -------------------------------------------------------------------------

test "TextStyle: all HTML inline flags can be set simultaneously" {
    // Simulates deeply nested HTML: <mark><ins><sub> where all three are active.
    const style = TextStyle{
        .font_size = 14.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_mark = true,
        .is_ins = true,
        .underline = true,
    };
    try testing.expect(style.is_mark);
    try testing.expect(style.is_ins);
    try testing.expect(style.underline);
    // kbd and samp flags remain unaffected
    try testing.expect(!style.is_kbd);
    try testing.expect(!style.is_samp);
}

test "TextStyle: bold markdown + HTML mark flag combine without interference" {
    // Simulates **<mark>bold highlighted</mark>**:
    // layoutInlines recurses for strong with bold=true, then mark_depth=1 sets is_mark.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .bold = true,
        .is_mark = true,
    };
    try testing.expect(style.bold);
    try testing.expect(style.is_mark);
    try testing.expect(!style.italic);
    try testing.expect(!style.is_ins);
}

test "TextStyle: italic markdown + HTML ins flag combine correctly" {
    // Simulates *<ins>italic inserted</ins>*:
    // layoutInlines recurses for emph with italic=true, then ins_depth=1 sets is_ins.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .italic = true,
        .is_ins = true,
        .underline = true,
    };
    try testing.expect(style.italic);
    try testing.expect(style.is_ins);
    try testing.expect(style.underline);
    try testing.expect(!style.bold);
}

test "TextStyle: link style + HTML mark flag: two sources of underline" {
    // Simulates <mark>[link text](url)</mark>:
    // Link sets underline=true and link_url; mark sets is_mark=true.
    // Both underline sources coexist — no conflict.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 100, .b = 200, .a = 255 },
        .underline = true,
        .link_url = "https://example.com",
        .is_mark = true,
    };
    try testing.expect(style.underline);
    try testing.expect(style.is_mark);
    try testing.expectEqualStrings("https://example.com", style.link_url.?);
    try testing.expect(!style.is_ins); // ins underline is separate
}

test "TextStyle: bold + italic + HTML mark + HTML ins: all flags orthogonal" {
    // Simulates **_<mark><ins>text</ins></mark>_**:
    // Tests that all four flags can be set at once without clobbering each other.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .bold = true,
        .italic = true,
        .is_mark = true,
        .is_ins = true,
        .underline = true,
    };
    try testing.expect(style.bold);
    try testing.expect(style.italic);
    try testing.expect(style.is_mark);
    try testing.expect(style.is_ins);
    try testing.expect(style.underline);
    try testing.expect(!style.strikethrough);
    try testing.expect(!style.is_kbd);
    try testing.expect(!style.is_samp);
}

test "TextStyle: kbd + samp are mutually exclusive in practice" {
    // A text run should not be rendered with both kbd and samp active,
    // as the renderer uses else-if chaining (kbd wins). Verify the flags
    // themselves can be set but document that kbd rendering takes precedence.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_samp = true,
        .is_code = true,
    };
    // Both flags can be stored in the struct
    try testing.expect(style.is_kbd);
    try testing.expect(style.is_samp);
    // In text_renderer.zig, is_kbd is checked first (else-if), so kbd bg renders.
    // is_samp rendering is skipped when is_kbd is set. This is the correct priority.
}

test "TextStyle: dimmed flag is independent of HTML inline flags" {
    // Simulates a task-list item where the content is dimmed AND marked.
    const style = TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .dimmed = true,
        .is_mark = true,
    };
    try testing.expect(style.dimmed);
    try testing.expect(style.is_mark);
    try testing.expect(!style.is_ins);
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

test "LayoutNode init and deinit with details_header" {
    var node = LayoutNode.init(testing.allocator, .{ .details_header = .{
        .expanded = true,
        .section_id = 42,
    } });
    defer node.deinit();
    try testing.expectEqual(@as(f32, 0), node.rect.x);
    try testing.expectEqual(@as(usize, 0), node.text_runs.items.len);
}

test "details_header stores expanded state and section_id" {
    var node = LayoutNode.init(testing.allocator, .{ .details_header = .{
        .expanded = false,
        .section_id = 7,
    } });
    defer node.deinit();
    try testing.expect(!node.data.details_header.expanded);
    try testing.expectEqual(@as(u32, 7), node.data.details_header.section_id);
}

// Sub-AC 3b: animated transitions and keyboard focus tests.

test "details_header anim_progress defaults to 0" {
    var node = LayoutNode.init(testing.allocator, .{ .details_header = .{
        .expanded = true,
        .section_id = 42,
    } });
    defer node.deinit();
    // Default anim_progress is 0 regardless of expanded state (set by app/layout).
    try testing.expectEqual(@as(f32, 0), node.data.details_header.anim_progress);
}

test "details_header anim_progress can be set explicitly" {
    var node = LayoutNode.init(testing.allocator, .{ .details_header = .{
        .expanded = true,
        .section_id = 1,
        .anim_progress = 0.5,
    } });
    defer node.deinit();
    try testing.expectApproxEqAbs(@as(f32, 0.5), node.data.details_header.anim_progress, 0.001);
}

test "details_header focused defaults to false" {
    var node = LayoutNode.init(testing.allocator, .{ .details_header = .{
        .expanded = false,
        .section_id = 3,
    } });
    defer node.deinit();
    try testing.expect(!node.data.details_header.focused);
}

test "details_header focused can be set to true" {
    var node = LayoutNode.init(testing.allocator, .{ .details_header = .{
        .expanded = true,
        .section_id = 5,
        .focused = true,
    } });
    defer node.deinit();
    try testing.expect(node.data.details_header.focused);
}

test "details_header anim_progress and focused are independent of expanded" {
    // Collapsed header can have anim_progress at 1.0 while animating back to 0.
    var node = LayoutNode.init(testing.allocator, .{
        .details_header = .{
            .expanded = false,
            .section_id = 10,
            .anim_progress = 1.0, // mid-collapse animation
            .focused = true,
        },
    });
    defer node.deinit();
    try testing.expect(!node.data.details_header.expanded);
    try testing.expectApproxEqAbs(@as(f32, 1.0), node.data.details_header.anim_progress, 0.001);
    try testing.expect(node.data.details_header.focused);
}

test "details_header in-place anim_progress update" {
    // Simulate one animation frame: update anim_progress in-place.
    var node = LayoutNode.init(testing.allocator, .{
        .details_header = .{
            .expanded = true, // target = 1.0
            .section_id = 20,
            .anim_progress = 0.0, // starting collapsed
        },
    });
    defer node.deinit();

    // Simulate lerp step toward 1.0
    const target: f32 = 1.0;
    const factor: f32 = 0.43; // approximate 60fps factor for time_constant=0.12
    const new_prog = node.data.details_header.anim_progress + (target - node.data.details_header.anim_progress) * factor;
    node.data.details_header.anim_progress = new_prog;

    // Progress should have advanced toward 1.0
    try testing.expect(node.data.details_header.anim_progress > 0.0);
    try testing.expect(node.data.details_header.anim_progress < 1.0);
}

test "details_header in-place focused update" {
    // Simulate focus change: update focused in-place without re-layout.
    var node = LayoutNode.init(testing.allocator, .{ .details_header = .{
        .expanded = false,
        .section_id = 30,
        .focused = false,
    } });
    defer node.deinit();

    // Gain focus
    node.data.details_header.focused = true;
    try testing.expect(node.data.details_header.focused);

    // Lose focus
    node.data.details_header.focused = false;
    try testing.expect(!node.data.details_header.focused);
}
