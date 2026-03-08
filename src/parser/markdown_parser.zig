const std = @import("std");
const Allocator = std.mem.Allocator;
const cmark = @import("cmark_import.zig").c;
const ast = @import("ast.zig");
const math_parser = @import("math_parser.zig");

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
        if (std.mem.eql(u8, name, "table_header")) return .table_row;
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
    const node_type = mapNodeType(cmark_type, type_string) orelse blk: {
        std.log.warn("unknown cmark node type {d} (type_string={s}), falling back to paragraph", .{
            cmark_type,
            type_string orelse "<null>",
        });
        break :blk .paragraph;
    };

    var node = ast.Node.init(allocator, node_type);
    errdefer node.deinit(allocator);

    // Capture source line positions (1-based) from cmark-gfm.
    // cmark returns 0 for no position; > 0 guard also skips any negative error values.
    const sl = cmark.cmark_node_get_start_line(cmark_node);
    const el = cmark.cmark_node_get_end_line(cmark_node);
    if (sl > 0) node.start_line = @intCast(sl);
    if (el > 0) node.end_line = @intCast(el);

    switch (node_type) {
        .text, .code, .html_block, .html_inline => {
            node.literal = try dupeString(allocator, cmark.cmark_node_get_literal(cmark_node));
        },
        // footnote_reference: literal is the 1-based ordinal string from cmark (e.g. "1", "2")
        // footnote_definition: literal is the author-supplied label (e.g. "note");
        //   ordinal is assigned post-children in the document node handler below
        .footnote_reference, .footnote_definition => {
            node.literal = try dupeString(allocator, cmark.cmark_node_get_literal(cmark_node));
            if (node_type == .footnote_reference) {
                if (node.literal) |lit| {
                    node.footnote_index = std.fmt.parseInt(u32, lit, 10) catch 0;
                }
            }
        },
        .code_block => {
            node.literal = try dupeString(allocator, cmark.cmark_node_get_literal(cmark_node));
            node.fence_info = try dupeString(allocator, cmark.cmark_node_get_fence_info(cmark_node));
        },
        .heading => {
            const level = cmark.cmark_node_get_heading_level(cmark_node);
            // cmark returns int; valid heading levels are 1-6, 0 means error.
            // Clamp to u8 range defensively.
            node.heading_level = if (level >= 1 and level <= 6) @intCast(level) else 1;
        },
        .list => {
            node.list_type = if (cmark.cmark_node_get_list_type(cmark_node) == cmark.CMARK_ORDERED_LIST)
                .ordered
            else
                .bullet;
            const list_start_raw = cmark.cmark_node_get_list_start(cmark_node);
            // cmark returns int; negative values indicate error. Default to 1.
            node.list_start = if (list_start_raw >= 0) @intCast(list_start_raw) else 1;
            node.list_tight = cmark.cmark_node_get_list_tight(cmark_node) != 0;
        },
        .link, .image => {
            node.url = try dupeString(allocator, cmark.cmark_node_get_url(cmark_node));
            node.title = try dupeString(allocator, cmark.cmark_node_get_title(cmark_node));
        },
        .table => {
            // C returns uint16_t which maps directly to Zig u16 — no cast needed.
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

    // Post-process document node: assign sequential ordinals to footnote definitions.
    // cmark appends footnote_definition children to the document root in the order they
    // are first referenced, so scanning them in children order gives the correct ordinals.
    if (node_type == .document) {
        var fn_index: u32 = 0;
        for (node.children.items) |*c| {
            if (c.node_type == .footnote_definition) {
                fn_index += 1;
                c.footnote_index = fn_index;
            }
        }
    }

    return node;
}

fn attachExtension(parser: *cmark.cmark_parser, name: [*:0]const u8) ParseError!void {
    const ext = cmark.cmark_find_syntax_extension(name) orelse return ParseError.ExtensionNotFound;
    _ = cmark.cmark_parser_attach_syntax_extension(parser, ext);
}

/// Parse a GFM markdown string into a Zig AST document.
///
/// Registers cmark-gfm extensions (table, autolink, strikethrough, tasklist,
/// tagfilter), parses the input, converts the cmark tree to a Zig AST, and
/// post-processes for LaTeX math nodes. Caller owns the returned Document
/// and must call `deinit()` to free all resources.
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
    var root = try convertNode(allocator, doc);
    errdefer root.deinit(allocator);

    // Post-process: detect and extract LaTeX math ($...$, $$...$$, ```math)
    try math_parser.processMathNodes(allocator, &root);

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
    const result = try dupeString(testing.allocator, c_str) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
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
    try testing.expectEqual(ast.NodeType.table_row, mapNodeType(0, "table_header").?);
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
    const has_strike = for (para.children.items) |*child| {
        if (child.node_type == .strikethrough) break true;
    } else false;
    try testing.expect(has_strike);
}

test "parse extracts source line numbers from cmark-gfm" {
    const input = "# Heading\n\nParagraph\n\n- item\n";
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    // Heading on line 1
    const heading = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.heading, heading.node_type);
    try testing.expectEqual(@as(u32, 1), heading.start_line);

    // Paragraph on line 3
    const para = &doc.root.children.items[1];
    try testing.expectEqual(ast.NodeType.paragraph, para.node_type);
    try testing.expectEqual(@as(u32, 3), para.start_line);

    // List starts on line 5
    const list = &doc.root.children.items[2];
    try testing.expectEqual(ast.NodeType.list, list.node_type);
    try testing.expectEqual(@as(u32, 5), list.start_line);
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

test "parse GFM autolink URL" {
    var doc = try parse(testing.allocator, "Check https://example.com now\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.paragraph, para.node_type);

    // cmark-gfm should produce a link node for the autolinked URL
    var found_link = false;
    for (para.children.items) |*child| {
        if (child.node_type == .link) {
            try testing.expectEqualStrings("https://example.com", child.url.?);
            // Autolink text child matches the URL
            try testing.expect(child.children.items.len > 0);
            const text = &child.children.items[0];
            try testing.expectEqual(ast.NodeType.text, text.node_type);
            try testing.expectEqualStrings("https://example.com", text.literal.?);
            found_link = true;
            break;
        }
    }
    try testing.expect(found_link);
}

test "parse GFM autolink email" {
    var doc = try parse(testing.allocator, "Email <user@example.com> now\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    var found_email_link = false;
    for (para.children.items) |*child| {
        if (child.node_type == .link) {
            const url = child.url.?;
            try testing.expect(std.mem.startsWith(u8, url, "mailto:"));
            found_email_link = true;
            break;
        }
    }
    try testing.expect(found_email_link);
}

test "parse footnote reference produces footnote_reference node" {
    const input = "Some text[^1].\n\n[^1]: Footnote content.\n";
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    // Paragraph should contain a footnote_reference
    const para = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.paragraph, para.node_type);

    var found_ref = false;
    for (para.children.items) |*child| {
        if (child.node_type == .footnote_reference) {
            found_ref = true;
            break;
        }
    }
    try testing.expect(found_ref);
}

test "parse footnote definition produces footnote_definition node" {
    const input = "Text[^fn].\n\n[^fn]: Definition here.\n";
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    // Should have a footnote_definition among root children
    var found_def = false;
    for (doc.root.children.items) |*child| {
        if (child.node_type == .footnote_definition) {
            found_def = true;
            // Footnote definition should contain paragraph children with the content
            try testing.expect(child.children.items.len > 0);
            break;
        }
    }
    try testing.expect(found_def);
}

test "parse footnote reference has literal label" {
    const input = "Text[^1].\n\n[^1]: Footnote.\n";
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    for (para.children.items) |*child| {
        if (child.node_type == .footnote_reference) {
            // cmark-gfm populates the literal with the reference label
            try testing.expect(child.literal != null);
            try testing.expectEqualStrings("1", child.literal.?);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "parse footnote definition has literal label" {
    const input = "Text[^note].\n\n[^note]: Definition.\n";
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    for (doc.root.children.items) |*child| {
        if (child.node_type == .footnote_definition) {
            // cmark-gfm populates the literal with the definition label
            try testing.expect(child.literal != null);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "mapNodeType maps footnote types" {
    try testing.expectEqual(ast.NodeType.footnote_definition, mapNodeType(cmark.CMARK_NODE_FOOTNOTE_DEFINITION, null).?);
    try testing.expectEqual(ast.NodeType.footnote_reference, mapNodeType(cmark.CMARK_NODE_FOOTNOTE_REFERENCE, null).?);
}

test "footnote_reference gets footnote_index populated" {
    const input = "Text[^1].\n\n[^1]: Footnote.\n";
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    for (para.children.items) |*child| {
        if (child.node_type == .footnote_reference) {
            // cmark replaces the label literal with the ordinal string "1"
            // which is also parsed into footnote_index
            try testing.expectEqual(@as(u32, 1), child.footnote_index);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "footnote_definition gets footnote_index assigned sequentially" {
    const input = "Text[^a].\n\n[^a]: Definition A.\n";
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    for (doc.root.children.items) |*child| {
        if (child.node_type == .footnote_definition) {
            // First (and only) definition should get index 1
            try testing.expectEqual(@as(u32, 1), child.footnote_index);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "two footnote definitions get indices 1 and 2" {
    const input = "First[^a] second[^b].\n\n[^a]: A.\n\n[^b]: B.\n";
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    var idx: u32 = 0;
    for (doc.root.children.items) |*child| {
        if (child.node_type == .footnote_definition) {
            idx += 1;
            try testing.expectEqual(idx, child.footnote_index);
        }
    }
    try testing.expectEqual(@as(u32, 2), idx);
}

test "parse preserves sub and sup as html_inline nodes" {
    // cmark-gfm must NOT filter or escape <sub>/<sup> tags — they pass through
    // as html_inline nodes so the layout layer can apply subscript/superscript styling.
    var doc = try parse(testing.allocator, "H<sub>2</sub>O and x<sup>2</sup>\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.paragraph, para.node_type);

    var sub_open: usize = 0;
    var sub_close: usize = 0;
    var sup_open: usize = 0;
    var sup_close: usize = 0;
    for (para.children.items) |*child| {
        if (child.node_type == .html_inline) {
            if (child.literal) |lit| {
                if (std.mem.eql(u8, lit, "<sub>")) sub_open += 1;
                if (std.mem.eql(u8, lit, "</sub>")) sub_close += 1;
                if (std.mem.eql(u8, lit, "<sup>")) sup_open += 1;
                if (std.mem.eql(u8, lit, "</sup>")) sup_close += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 1), sub_open);
    try testing.expectEqual(@as(usize, 1), sub_close);
    try testing.expectEqual(@as(usize, 1), sup_open);
    try testing.expectEqual(@as(usize, 1), sup_close);
}

test "parse preserves kbd ins samp mark as html_inline nodes" {
    // These tags must pass through as html_inline so the layout layer can apply
    // keyboard-key, underline, monospace-sample, and highlight styling respectively.
    const input =
        \\Press <kbd>Enter</kbd> to submit.
        \\<ins>inserted</ins> text.
        \\<samp>output</samp> here.
        \\<mark>highlighted</mark> word.
        \\
    ;
    var doc = try parse(testing.allocator, input);
    defer doc.deinit();

    // Collect all html_inline literals from the first paragraph
    var found_kbd_open = false;
    var found_kbd_close = false;
    var found_ins_open = false;
    var found_ins_close = false;
    var found_samp_open = false;
    var found_samp_close = false;
    var found_mark_open = false;
    var found_mark_close = false;

    for (doc.root.children.items) |*block| {
        for (block.children.items) |*child| {
            if (child.node_type == .html_inline) {
                if (child.literal) |lit| {
                    if (std.mem.eql(u8, lit, "<kbd>")) found_kbd_open = true;
                    if (std.mem.eql(u8, lit, "</kbd>")) found_kbd_close = true;
                    if (std.mem.eql(u8, lit, "<ins>")) found_ins_open = true;
                    if (std.mem.eql(u8, lit, "</ins>")) found_ins_close = true;
                    if (std.mem.eql(u8, lit, "<samp>")) found_samp_open = true;
                    if (std.mem.eql(u8, lit, "</samp>")) found_samp_close = true;
                    if (std.mem.eql(u8, lit, "<mark>")) found_mark_open = true;
                    if (std.mem.eql(u8, lit, "</mark>")) found_mark_close = true;
                }
            }
        }
    }

    try testing.expect(found_kbd_open);
    try testing.expect(found_kbd_close);
    try testing.expect(found_ins_open);
    try testing.expect(found_ins_close);
    try testing.expect(found_samp_open);
    try testing.expect(found_samp_close);
    try testing.expect(found_mark_open);
    try testing.expect(found_mark_close);
}
