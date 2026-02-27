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

pub fn dupeString(allocator: Allocator, c_str: ?[*:0]const u8) !?[]const u8 {
    const ptr = c_str orelse return null;
    const slice = std.mem.span(ptr);
    if (slice.len == 0) return null;
    return try allocator.dupe(u8, slice);
}

pub fn mapNodeType(cmark_type: cmark.cmark_node_type, type_string: ?[]const u8) ?ast.NodeType {
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
    return if (cmark.cmark_node_get_type_string(cmark_node)) |s| std.mem.span(s) else null;
}

fn convertNode(allocator: Allocator, cmark_node: *cmark.cmark_node) ParseError!ast.Node {
    const cmark_type = cmark.cmark_node_get_type(cmark_node);
    const type_string = getNodeTypeString(cmark_node);
    const node_type = mapNodeType(cmark_type, type_string) orelse .paragraph;

    var node = ast.Node.init(allocator, node_type);
    errdefer node.deinit(allocator);

    switch (node_type) {
        .text, .code, .html_block, .html_inline => {
            node.literal = try dupeString(allocator, cmark.cmark_node_get_literal(cmark_node));
        },
        .code_block => {
            node.literal = try dupeString(allocator, cmark.cmark_node_get_literal(cmark_node));
            node.fence_info = try dupeString(allocator, cmark.cmark_node_get_fence_info(cmark_node));
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
            node.url = try dupeString(allocator, cmark.cmark_node_get_url(cmark_node));
            node.title = try dupeString(allocator, cmark.cmark_node_get_title(cmark_node));
        },
        .table => {
            const ncols = cmark.cmark_gfm_extensions_get_table_columns(cmark_node);
            node.table_columns = ncols;
            if (ncols > 0) {
                const c_aligns = cmark.cmark_gfm_extensions_get_table_alignments(cmark_node);
                if (c_aligns) |aligns_ptr| {
                    const alignments = try allocator.alloc(ast.Alignment, ncols);
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
            if (cmark.cmark_gfm_extensions_get_tasklist_item_checked(cmark_node)) {
                node.tasklist_checked = true;
            } else if (getNodeTypeString(cmark_node)) |ts| {
                // Distinguish "unchecked" from "not a tasklist item":
                // cmark-gfm returns false for both, so check the type string
                if (std.mem.eql(u8, ts, "tasklist")) {
                    node.tasklist_checked = false;
                }
            }
        },
        else => {},
    }

    // Recursively convert children
    var child = cmark.cmark_node_first_child(cmark_node);
    while (child) |c_node| {
        var child_node = try convertNode(allocator, c_node);
        errdefer child_node.deinit(allocator);
        try node.children.append(child_node);
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

    cmark.cmark_parser_feed(parser, text.ptr, text.len);
    const doc = cmark.cmark_parser_finish(parser) orelse return ParseError.ParseFailed;
    defer cmark.cmark_node_free(doc);

    // Convert cmark tree to Zig AST
    const root = try convertNode(allocator, doc);

    return .{ .root = root, .allocator = allocator };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "dupeString returns null for null input" {
    const result = try dupeString(testing.allocator, null);
    try testing.expectEqual(null, result);
}

test "dupeString returns null for empty string" {
    const empty: [*:0]const u8 = "";
    const result = try dupeString(testing.allocator, empty);
    try testing.expectEqual(null, result);
}

test "dupeString duplicates a valid string" {
    const c_str: [*:0]const u8 = "hello world";
    const result = try dupeString(testing.allocator, c_str);
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result != null);
    try testing.expectEqualStrings("hello world", result.?);
}

test "mapNodeType maps known cmark types" {
    try testing.expectEqual(ast.NodeType.document, mapNodeType(cmark.CMARK_NODE_DOCUMENT, null).?);
    try testing.expectEqual(ast.NodeType.paragraph, mapNodeType(cmark.CMARK_NODE_PARAGRAPH, null).?);
    try testing.expectEqual(ast.NodeType.heading, mapNodeType(cmark.CMARK_NODE_HEADING, null).?);
    try testing.expectEqual(ast.NodeType.code_block, mapNodeType(cmark.CMARK_NODE_CODE_BLOCK, null).?);
    try testing.expectEqual(ast.NodeType.list, mapNodeType(cmark.CMARK_NODE_LIST, null).?);
    try testing.expectEqual(ast.NodeType.item, mapNodeType(cmark.CMARK_NODE_ITEM, null).?);
    try testing.expectEqual(ast.NodeType.text, mapNodeType(cmark.CMARK_NODE_TEXT, null).?);
    try testing.expectEqual(ast.NodeType.emph, mapNodeType(cmark.CMARK_NODE_EMPH, null).?);
    try testing.expectEqual(ast.NodeType.strong, mapNodeType(cmark.CMARK_NODE_STRONG, null).?);
    try testing.expectEqual(ast.NodeType.link, mapNodeType(cmark.CMARK_NODE_LINK, null).?);
    try testing.expectEqual(ast.NodeType.image, mapNodeType(cmark.CMARK_NODE_IMAGE, null).?);
    try testing.expectEqual(ast.NodeType.block_quote, mapNodeType(cmark.CMARK_NODE_BLOCK_QUOTE, null).?);
    try testing.expectEqual(ast.NodeType.thematic_break, mapNodeType(cmark.CMARK_NODE_THEMATIC_BREAK, null).?);
    try testing.expectEqual(ast.NodeType.softbreak, mapNodeType(cmark.CMARK_NODE_SOFTBREAK, null).?);
    try testing.expectEqual(ast.NodeType.linebreak, mapNodeType(cmark.CMARK_NODE_LINEBREAK, null).?);
    try testing.expectEqual(ast.NodeType.code, mapNodeType(cmark.CMARK_NODE_CODE, null).?);
    try testing.expectEqual(ast.NodeType.html_block, mapNodeType(cmark.CMARK_NODE_HTML_BLOCK, null).?);
    try testing.expectEqual(ast.NodeType.html_inline, mapNodeType(cmark.CMARK_NODE_HTML_INLINE, null).?);
}

test "mapNodeType returns null for unknown cmark type" {
    try testing.expectEqual(null, mapNodeType(9999, null));
}

test "mapNodeType maps GFM extension types by type string" {
    try testing.expectEqual(ast.NodeType.table, mapNodeType(0, "table").?);
    try testing.expectEqual(ast.NodeType.table_row, mapNodeType(0, "table_row").?);
    try testing.expectEqual(ast.NodeType.table_cell, mapNodeType(0, "table_cell").?);
    try testing.expectEqual(ast.NodeType.strikethrough, mapNodeType(0, "strikethrough").?);
}

test "parse with empty input produces a document node" {
    var doc = try parse(testing.allocator, "");
    defer doc.deinit();
    try testing.expectEqual(ast.NodeType.document, doc.root.node_type);
}

test "parse heading produces correct AST" {
    var doc = try parse(testing.allocator, "# Hello\n");
    defer doc.deinit();

    try testing.expectEqual(ast.NodeType.document, doc.root.node_type);
    try testing.expect(doc.root.children.items.len > 0);

    const heading = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.heading, heading.node_type);
    try testing.expectEqual(@as(u8, 1), heading.heading_level);
}

test "parse paragraph produces correct AST" {
    var doc = try parse(testing.allocator, "Hello world\n");
    defer doc.deinit();

    try testing.expect(doc.root.children.items.len > 0);
    const para = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.paragraph, para.node_type);

    // Paragraph should have a text child
    try testing.expect(para.children.items.len > 0);
    const text_node = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.text, text_node.node_type);
    try testing.expectEqualStrings("Hello world", text_node.literal.?);
}

test "parse bullet list" {
    var doc = try parse(testing.allocator, "- one\n- two\n- three\n");
    defer doc.deinit();

    try testing.expect(doc.root.children.items.len > 0);
    const list = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.list, list.node_type);
    try testing.expectEqual(ast.ListType.bullet, list.list_type);
    try testing.expectEqual(@as(usize, 3), list.children.items.len);
}

test "parse GFM table" {
    const input =
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
        \\
    ;
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expect(doc.root.children.items.len > 0);
    const table = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.table, table.node_type);
    try testing.expectEqual(@as(u16, 2), table.table_columns);
}

test "parse GFM strikethrough" {
    var doc = try parse(testing.allocator, "~~deleted~~\n");
    defer doc.deinit();

    try testing.expect(doc.root.children.items.len > 0);
    const para = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.paragraph, para.node_type);

    // Should contain a strikethrough child
    var found_strike = false;
    for (para.children.items) |*child| {
        if (child.node_type == .strikethrough) {
            found_strike = true;
            break;
        }
    }
    try testing.expect(found_strike);
}

test "parse GFM tasklist" {
    const input =
        \\- [x] done
        \\- [ ] not done
        \\
    ;
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    const list = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.list, list.node_type);
    try testing.expectEqual(@as(usize, 2), list.children.items.len);

    const item0 = &list.children.items[0];
    try testing.expectEqual(true, item0.tasklist_checked.?);

    const item1 = &list.children.items[1];
    try testing.expectEqual(false, item1.tasklist_checked.?);
}
