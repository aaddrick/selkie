const rl = @import("raylib");
const std = @import("std");
const Allocator = std.mem.Allocator;

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
};

pub const LayoutNode = struct {
    kind: LayoutNodeKind,
    rect: Rect,
    text_runs: std.ArrayList(TextRun),
    // Code block content
    code_text: ?[]const u8 = null,
    code_bg_color: ?rl.Color = null,
    // Heading level for styling
    heading_level: u8 = 0,
    // Block quote depth
    blockquote_depth: u8 = 0,
    // HR color
    hr_color: ?rl.Color = null,

    pub fn init(allocator: Allocator) LayoutNode {
        return .{
            .kind = .text_block,
            .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .text_runs = std.ArrayList(TextRun).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutNode) void {
        self.text_runs.deinit();
    }
};

pub const LayoutTree = struct {
    nodes: std.ArrayList(LayoutNode),
    total_height: f32,
    allocator: Allocator,

    pub fn init(allocator: Allocator) LayoutTree {
        return .{
            .nodes = std.ArrayList(LayoutNode).init(allocator),
            .total_height = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LayoutTree) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit();
    }
};
