const std = @import("std");
const Allocator = std.mem.Allocator;
const cmark = @import("cmark_import.zig").c;
const ast = @import("ast.zig");

pub const ParseError = error{
    ParserCreationFailed,
    ParseFailed,
    ExtensionNotFound,
    OutOfMemory,
};

fn dupeString(allocator: Allocator, c_str: ?[*:0]const u8) !?[]const u8 {
    const ptr = c_str orelse return null;
    const slice = std.mem.span(ptr);
    if (slice.len == 0) return null;
    return try allocator.dupe(u8, slice);
}

fn mapNodeType(cmark_type: cmark.cmark_node_type, type_string: ?[]const u8) ?ast.NodeType {
    // Check for GFM extension types by type string
    if (type_string) |name| {
        if (std.mem.eql(u8, name, "table")) return .table;
        if (std.mem.eql(u8, name, "table_row")) return .table_row;
        if (std.mem.eql(u8, name, "table_cell")) return .table_cell;
        if (std.mem.eql(u8, name, "strikethrough")) return .strikethrough;
    }

    return switch (cmark_type) {
        cmark.CMARK_NODE_DOCUMENT => .document,
        cmark.CMARK_NODE_BLOCK_QUOTE => .block_quote,
        cmark.CMARK_NODE_LIST => .list,
        cmark.CMARK_NODE_ITEM => .item,
        cmark.CMARK_NODE_CODE_BLOCK => .code_block,
        cmark.CMARK_NODE_HTML_BLOCK => .html_block,
        cmark.CMARK_NODE_PARAGRAPH => .paragraph,
        cmark.CMARK_NODE_HEADING => .heading,
        cmark.CMARK_NODE_THEMATIC_BREAK => .thematic_break,
        cmark.CMARK_NODE_FOOTNOTE_DEFINITION => .footnote_definition,
        cmark.CMARK_NODE_TEXT => .text,
        cmark.CMARK_NODE_SOFTBREAK => .softbreak,
        cmark.CMARK_NODE_LINEBREAK => .linebreak,
        cmark.CMARK_NODE_CODE => .code,
        cmark.CMARK_NODE_HTML_INLINE => .html_inline,
        cmark.CMARK_NODE_EMPH => .emph,
        cmark.CMARK_NODE_STRONG => .strong,
        cmark.CMARK_NODE_LINK => .link,
        cmark.CMARK_NODE_IMAGE => .image,
        cmark.CMARK_NODE_FOOTNOTE_REFERENCE => .footnote_reference,
        else => null,
    };
}

fn getNodeTypeString(cmark_node: *cmark.cmark_node) ?[]const u8 {
    const type_str = cmark.cmark_node_get_type_string(cmark_node);
    if (type_str) |s| return std.mem.span(s);
    return null;
}

fn convertNode(allocator: Allocator, cmark_node: *cmark.cmark_node) ParseError!ast.Node {
    const cmark_type = cmark.cmark_node_get_type(cmark_node);
    const type_string = getNodeTypeString(cmark_node);
    const node_type = mapNodeType(cmark_type, type_string) orelse .paragraph;

    var node = ast.Node.init(allocator, node_type);

    // Extract content based on type
    switch (node_type) {
        .text, .code, .html_block, .html_inline => {
            node.literal = dupeString(allocator, cmark.cmark_node_get_literal(cmark_node)) catch return ParseError.OutOfMemory;
        },
        .code_block => {
            node.literal = dupeString(allocator, cmark.cmark_node_get_literal(cmark_node)) catch return ParseError.OutOfMemory;
            node.fence_info = dupeString(allocator, cmark.cmark_node_get_fence_info(cmark_node)) catch return ParseError.OutOfMemory;
        },
        .heading => {
            node.heading_level = @intCast(cmark.cmark_node_get_heading_level(cmark_node));
        },
        .list => {
            node.list_type = if (cmark.cmark_node_get_list_type(cmark_node) == cmark.CMARK_ORDERED_LIST)
                .ordered
            else
                .bullet;
            node.list_start = @intCast(cmark.cmark_node_get_list_start(cmark_node));
            node.list_tight = cmark.cmark_node_get_list_tight(cmark_node) != 0;
        },
        .link, .image => {
            node.url = dupeString(allocator, cmark.cmark_node_get_url(cmark_node)) catch return ParseError.OutOfMemory;
            node.title = dupeString(allocator, cmark.cmark_node_get_title(cmark_node)) catch return ParseError.OutOfMemory;
        },
        .table => {
            const ncols = cmark.cmark_gfm_extensions_get_table_columns(cmark_node);
            node.table_columns = ncols;
            if (ncols > 0) {
                const c_aligns = cmark.cmark_gfm_extensions_get_table_alignments(cmark_node);
                if (c_aligns) |aligns_ptr| {
                    const alignments = allocator.alloc(ast.Alignment, ncols) catch return ParseError.OutOfMemory;
                    for (0..ncols) |i| {
                        alignments[i] = switch (aligns_ptr[i]) {
                            'l' => .left,
                            'c' => .center,
                            'r' => .right,
                            else => .none,
                        };
                    }
                    node.table_alignments = alignments;
                }
            }
        },
        .table_row => {
            node.is_header_row = cmark.cmark_gfm_extensions_get_table_row_is_header(cmark_node) != 0;
        },
        .item => {
            // Check if this is a tasklist item
            const parent = cmark.cmark_node_parent(cmark_node);
            if (parent) |p| {
                _ = p;
                // tasklist extension sets a property on the item node
                if (cmark.cmark_gfm_extensions_get_tasklist_item_checked(cmark_node)) {
                    node.tasklist_checked = true;
                } else {
                    // Distinguish between "unchecked" and "not a tasklist item"
                    // cmark-gfm returns false for both - check type string
                    const item_type_str = getNodeTypeString(cmark_node);
                    if (item_type_str) |ts| {
                        if (std.mem.eql(u8, ts, "tasklist")) {
                            node.tasklist_checked = false;
                        }
                    }
                }
            }
        },
        else => {},
    }

    // Recursively convert children
    var child = cmark.cmark_node_first_child(cmark_node);
    while (child) |c_node| {
        const child_node = try convertNode(allocator, c_node);
        node.children.append(child_node) catch return ParseError.OutOfMemory;
        child = cmark.cmark_node_next(c_node);
    }

    return node;
}

fn attachExtension(parser: *cmark.cmark_parser, name: [*:0]const u8) ParseError!void {
    const ext = cmark.cmark_find_syntax_extension(name) orelse return ParseError.ExtensionNotFound;
    _ = cmark.cmark_parser_attach_syntax_extension(parser, ext);
}

pub fn parse(allocator: Allocator, text: []const u8) ParseError!ast.Document {
    // Register GFM extensions
    cmark.cmark_gfm_core_extensions_ensure_registered();

    const options = cmark.CMARK_OPT_DEFAULT | cmark.CMARK_OPT_FOOTNOTES | cmark.CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE;

    const parser = cmark.cmark_parser_new(options) orelse return ParseError.ParserCreationFailed;
    defer cmark.cmark_parser_free(parser);

    // Attach GFM extensions
    try attachExtension(parser, "table");
    try attachExtension(parser, "autolink");
    try attachExtension(parser, "strikethrough");
    try attachExtension(parser, "tasklist");
    try attachExtension(parser, "tagfilter");

    // Parse
    cmark.cmark_parser_feed(parser, text.ptr, text.len);
    const doc = cmark.cmark_parser_finish(parser) orelse return ParseError.ParseFailed;
    defer cmark.cmark_node_free(doc);

    // Convert cmark tree to Zig AST
    const root = try convertNode(allocator, doc);

    return ast.Document{
        .root = root,
        .allocator = allocator,
    };
}
