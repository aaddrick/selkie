const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NodeType = enum {
    // Block
    document,
    block_quote,
    list,
    item,
    code_block,
    html_block,
    paragraph,
    heading,
    thematic_break,
    footnote_definition,
    // GFM extensions (block)
    table,
    table_row,
    table_cell,
    // Inline
    text,
    softbreak,
    linebreak,
    code,
    html_inline,
    emph,
    strong,
    strikethrough,
    link,
    image,
    footnote_reference,
};

pub const ListType = enum {
    bullet,
    ordered,
};

pub const Alignment = enum {
    none,
    left,
    center,
    right,
};

pub const Node = struct {
    node_type: NodeType,
    children: std.ArrayList(Node),

    // Content
    literal: ?[]const u8 = null,
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,

    // Heading
    heading_level: u8 = 0,

    // List
    list_type: ListType = .bullet,
    list_start: u32 = 1,
    list_tight: bool = false,

    // Table
    table_alignments: ?[]Alignment = null,
    table_columns: u16 = 0,
    is_header_row: bool = false,

    // Task list
    tasklist_checked: ?bool = null,

    // Code block
    fence_info: ?[]const u8 = null,

    pub fn init(allocator: Allocator, node_type: NodeType) Node {
        return .{
            .node_type = node_type,
            .children = std.ArrayList(Node).init(allocator),
        };
    }

    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit();
        if (self.literal) |lit| allocator.free(lit);
        if (self.url) |u| allocator.free(u);
        if (self.title) |t| allocator.free(t);
        if (self.fence_info) |fi| allocator.free(fi);
        if (self.table_alignments) |a| allocator.free(a);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Node.deinit frees all optional fields" {
    const allocator = testing.allocator;
    var node = Node.init(allocator, .code_block);

    // Populate all 5 optional heap-owned fields
    node.literal = try allocator.dupe(u8, "some literal");
    node.url = try allocator.dupe(u8, "https://example.com");
    node.title = try allocator.dupe(u8, "a title");
    node.fence_info = try allocator.dupe(u8, "zig");
    node.table_alignments = try allocator.dupe(Alignment, &[_]Alignment{ .left, .center, .right });

    // Add a child to exercise recursive deinit
    var child = Node.init(allocator, .text);
    child.literal = try allocator.dupe(u8, "child text");
    try node.children.append(child);

    // deinit should free everything; testing.allocator will detect leaks
    node.deinit(allocator);
}

pub const Document = struct {
    root: Node,
    allocator: Allocator,

    pub fn deinit(self: *Document) void {
        self.root.deinit(self.allocator);
    }
};
