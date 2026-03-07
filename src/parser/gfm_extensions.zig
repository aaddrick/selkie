//! GFM Extension Utilities
//!
//! Helper functions for extracting GFM-specific data from the cmark-gfm AST.
//! The actual extension registration and parsing is handled in markdown_parser.zig.
//! This module provides convenience functions for working with the parsed AST.

const std = @import("std");
const ast = @import("ast.zig");

/// Extract table structure information from a table AST node.
pub const TableInfo = struct {
    num_columns: u16,
    alignments: []const ast.Alignment,
    header_row: ?*const ast.Node,
    body_rows: []const ast.Node,

    /// Get the alignment for a specific column index.
    /// Returns .none if the index is out of range.
    pub fn getColumnAlignment(self: TableInfo, col: usize) ast.Alignment {
        if (col >= self.alignments.len) return .none;
        return self.alignments[col];
    }

    /// Count total body rows.
    pub fn bodyRowCount(self: TableInfo) usize {
        return self.body_rows.len;
    }

    /// Returns true if this table has a header row.
    pub fn hasHeader(self: TableInfo) bool {
        return self.header_row != null;
    }
};

/// Get structured table info from a table node.
pub fn getTableInfo(table_node: *const ast.Node) ?TableInfo {
    if (table_node.node_type != .table) return null;
    if (table_node.table_columns == 0) return null;

    var header: ?*const ast.Node = null;
    var body_start: usize = 0;

    for (table_node.children.items, 0..) |*row, i| {
        if (row.is_header_row) {
            header = row;
            body_start = i + 1;
            break;
        }
    }

    return .{
        .num_columns = table_node.table_columns,
        .alignments = table_node.table_alignments orelse &[_]ast.Alignment{},
        .header_row = header,
        .body_rows = if (body_start < table_node.children.items.len)
            table_node.children.items[body_start..]
        else
            &[_]ast.Node{},
    };
}

/// Check if a list item node is a task list item.
pub fn isTaskListItem(node: *const ast.Node) bool {
    return node.node_type == .item and node.tasklist_checked != null;
}

/// Check if a list item is checked (returns null if not a task list item).
pub fn isChecked(node: *const ast.Node) ?bool {
    if (node.node_type != .item) return null;
    return node.tasklist_checked;
}

/// Information extracted from a code block's fence info string.
pub const CodeBlockInfo = struct {
    /// The language identifier (first word of the fence info).
    /// Borrowed from the node's fence_info field.
    language: ?[]const u8,
    /// The full fence info string (may include extra metadata after the language).
    /// Borrowed from the node's fence_info field.
    raw_info: ?[]const u8,
};

/// Extract code block info from a code_block AST node.
/// Returns null if the node is not a code_block.
pub fn getCodeBlockInfo(node: *const ast.Node) ?CodeBlockInfo {
    if (node.node_type != .code_block) return null;
    return .{
        .language = extractLanguage(node.fence_info),
        .raw_info = node.fence_info,
    };
}

/// Extract just the language identifier from a fence_info string.
/// The language is the first whitespace-delimited token.
/// Returns null if the input is null or empty.
pub fn extractLanguage(fence_info: ?[]const u8) ?[]const u8 {
    const info = fence_info orelse return null;
    const trimmed = std.mem.trim(u8, info, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfAny(u8, trimmed, " \t")) |idx| {
        return trimmed[0..idx];
    }
    return trimmed;
}

/// Check if a code block has a specific language.
/// Comparison is case-insensitive.
pub fn isCodeBlockLanguage(node: *const ast.Node, language: []const u8) bool {
    const info = getCodeBlockInfo(node) orelse return false;
    const lang = info.language orelse return false;
    return std.ascii.eqlIgnoreCase(lang, language);
}

// --- Autolink helpers ---

/// Check if a link node is an autolink (URL matches the link text content).
/// Returns false for non-link nodes or explicit [text](url) links.
pub fn isAutolink(node: *const ast.Node) bool {
    if (node.node_type != .link) return false;
    const url = node.url orelse return false;

    // Autolinks have exactly one text child whose literal matches the URL
    if (node.children.items.len != 1) return false;
    const child = &node.children.items[0];
    if (child.node_type != .text) return false;
    const literal = child.literal orelse return false;

    // Direct URL autolink: text == url
    if (std.mem.eql(u8, literal, url)) return true;
    // Email autolink: url is "mailto:" + text
    if (std.mem.startsWith(u8, url, "mailto:"))
        return std.mem.eql(u8, literal, url["mailto:".len..]);
    return false;
}

/// Check if a link node is an email autolink (URL starts with "mailto:").
pub fn isEmailAutolink(node: *const ast.Node) bool {
    if (!isAutolink(node)) return false;
    const url = node.url orelse return false;
    return std.mem.startsWith(u8, url, "mailto:");
}

// --- Footnote helpers ---

/// Information about a footnote reference.
pub const FootnoteRefInfo = struct {
    /// The reference label (e.g., "1" for [^1]).
    /// Borrowed from the node's literal field.
    label: []const u8,
};

/// Extract footnote reference information from a footnote_reference node.
/// Returns null if the node is not a footnote_reference or has no label.
pub fn getFootnoteRefInfo(node: *const ast.Node) ?FootnoteRefInfo {
    if (node.node_type != .footnote_reference) return null;
    const label = node.literal orelse return null;
    return .{ .label = label };
}

/// Check if a node is a footnote definition.
pub fn isFootnoteDefinition(node: *const ast.Node) bool {
    return node.node_type == .footnote_definition;
}

/// Check if a node is a footnote reference.
pub fn isFootnoteReference(node: *const ast.Node) bool {
    return node.node_type == .footnote_reference;
}

/// Count footnote definitions in a document root node.
pub fn countFootnoteDefinitions(root: *const ast.Node) usize {
    var count: usize = 0;
    for (root.children.items) |*child| {
        if (child.node_type == .footnote_definition) count += 1;
    }
    return count;
}

/// Count footnote references in a subtree.
pub fn countFootnoteReferences(node: *const ast.Node) usize {
    var count: usize = 0;
    countFootnoteRefsRecursive(node, &count);
    return count;
}

fn countFootnoteRefsRecursive(node: *const ast.Node, count: *usize) void {
    if (node.node_type == .footnote_reference) count.* += 1;
    for (node.children.items) |*child| {
        countFootnoteRefsRecursive(child, count);
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// --- Table tests ---

test "getTableInfo returns null for non-table node" {
    var node = ast.Node.init(testing.allocator, .paragraph);
    defer node.deinit(testing.allocator);
    try testing.expectEqual(null, getTableInfo(&node));
}

test "getTableInfo returns null for table with zero columns" {
    var node = ast.Node.init(testing.allocator, .table);
    defer node.deinit(testing.allocator);
    node.table_columns = 0;
    try testing.expectEqual(null, getTableInfo(&node));
}

test "getTableInfo extracts header and body rows" {
    var table = ast.Node.init(testing.allocator, .table);
    defer table.deinit(testing.allocator);
    table.table_columns = 2;

    // Add a header row
    var header_row = ast.Node.init(testing.allocator, .table_row);
    header_row.is_header_row = true;
    try table.children.append(header_row);

    // Add a body row
    const body_row = ast.Node.init(testing.allocator, .table_row);
    try table.children.append(body_row);

    const info = getTableInfo(&table).?;
    try testing.expectEqual(@as(u16, 2), info.num_columns);
    try testing.expect(info.header_row != null);
    try testing.expect(info.header_row.?.is_header_row);
    try testing.expectEqual(@as(usize, 1), info.body_rows.len);
    try testing.expect(info.hasHeader());
    try testing.expectEqual(@as(usize, 1), info.bodyRowCount());
}

test "getTableInfo with no header row" {
    var table = ast.Node.init(testing.allocator, .table);
    defer table.deinit(testing.allocator);
    table.table_columns = 1;

    const row = ast.Node.init(testing.allocator, .table_row);
    try table.children.append(row);

    const info = getTableInfo(&table).?;
    try testing.expectEqual(null, info.header_row);
    try testing.expect(!info.hasHeader());
    // With no header found, all rows are treated as body rows
    try testing.expectEqual(@as(usize, 1), info.body_rows.len);
}

test "getTableInfo with multiple body rows" {
    var table = ast.Node.init(testing.allocator, .table);
    defer table.deinit(testing.allocator);
    table.table_columns = 3;

    var header_row = ast.Node.init(testing.allocator, .table_row);
    header_row.is_header_row = true;
    try table.children.append(header_row);

    // Add 3 body rows
    for (0..3) |_| {
        const body_row = ast.Node.init(testing.allocator, .table_row);
        try table.children.append(body_row);
    }

    const info = getTableInfo(&table).?;
    try testing.expectEqual(@as(u16, 3), info.num_columns);
    try testing.expectEqual(@as(usize, 3), info.bodyRowCount());
}

test "TableInfo.getColumnAlignment returns correct alignments" {
    var table = ast.Node.init(testing.allocator, .table);
    defer table.deinit(testing.allocator);
    table.table_columns = 3;

    const alignments = try testing.allocator.alloc(ast.Alignment, 3);
    alignments[0] = .left;
    alignments[1] = .center;
    alignments[2] = .right;
    table.table_alignments = alignments;

    var header_row = ast.Node.init(testing.allocator, .table_row);
    header_row.is_header_row = true;
    try table.children.append(header_row);

    const info = getTableInfo(&table).?;
    try testing.expectEqual(ast.Alignment.left, info.getColumnAlignment(0));
    try testing.expectEqual(ast.Alignment.center, info.getColumnAlignment(1));
    try testing.expectEqual(ast.Alignment.right, info.getColumnAlignment(2));
    // Out of range returns .none
    try testing.expectEqual(ast.Alignment.none, info.getColumnAlignment(99));
}

test "TableInfo.getColumnAlignment with no alignments set" {
    var table = ast.Node.init(testing.allocator, .table);
    defer table.deinit(testing.allocator);
    table.table_columns = 2;

    var header_row = ast.Node.init(testing.allocator, .table_row);
    header_row.is_header_row = true;
    try table.children.append(header_row);

    const info = getTableInfo(&table).?;
    // No alignments set, should default to .none
    try testing.expectEqual(ast.Alignment.none, info.getColumnAlignment(0));
    try testing.expectEqual(ast.Alignment.none, info.getColumnAlignment(1));
}

// --- Task list tests ---

test "isTaskListItem identifies task items" {
    var item = ast.Node.init(testing.allocator, .item);
    defer item.deinit(testing.allocator);

    // Not a tasklist item by default
    try testing.expect(!isTaskListItem(&item));

    // Set as checked
    item.tasklist_checked = true;
    try testing.expect(isTaskListItem(&item));

    // Set as unchecked (still a tasklist item)
    item.tasklist_checked = false;
    try testing.expect(isTaskListItem(&item));
}

test "isTaskListItem returns false for non-item node" {
    var para = ast.Node.init(testing.allocator, .paragraph);
    defer para.deinit(testing.allocator);
    try testing.expect(!isTaskListItem(&para));
}

test "isChecked returns null for non-item node" {
    var para = ast.Node.init(testing.allocator, .paragraph);
    defer para.deinit(testing.allocator);
    try testing.expectEqual(null, isChecked(&para));
}

test "isChecked returns the checked state for task items" {
    var item = ast.Node.init(testing.allocator, .item);
    defer item.deinit(testing.allocator);

    // Not a tasklist item
    try testing.expectEqual(null, isChecked(&item));

    item.tasklist_checked = true;
    try testing.expectEqual(true, isChecked(&item).?);

    item.tasklist_checked = false;
    try testing.expectEqual(false, isChecked(&item).?);
}

// --- Code block info tests ---

test "extractLanguage returns null for null input" {
    try testing.expectEqual(null, extractLanguage(null));
}

test "extractLanguage returns null for empty string" {
    try testing.expectEqual(null, extractLanguage(""));
}

test "extractLanguage returns null for whitespace-only string" {
    try testing.expectEqual(null, extractLanguage("   "));
    try testing.expectEqual(null, extractLanguage("\t\t"));
}

test "extractLanguage returns single-word language" {
    try testing.expectEqualStrings("javascript", extractLanguage("javascript").?);
    try testing.expectEqualStrings("python", extractLanguage("python").?);
    try testing.expectEqualStrings("zig", extractLanguage("zig").?);
    try testing.expectEqualStrings("c++", extractLanguage("c++").?);
}

test "extractLanguage extracts first word from multi-word fence info" {
    try testing.expectEqualStrings("javascript", extractLanguage("javascript highlight").?);
    try testing.expectEqualStrings("python", extractLanguage("python linenos=true").?);
    // Comma-separated info is treated as a single word (no space separator)
    try testing.expectEqualStrings("rust,no_run", extractLanguage("rust,no_run").?);
}

test "extractLanguage trims leading/trailing whitespace" {
    try testing.expectEqualStrings("python", extractLanguage("  python  ").?);
    try testing.expectEqualStrings("zig", extractLanguage("\tzig\t").?);
}

test "getCodeBlockInfo returns null for non-code_block node" {
    var node = ast.Node.init(testing.allocator, .paragraph);
    defer node.deinit(testing.allocator);
    try testing.expectEqual(null, getCodeBlockInfo(&node));
}

test "getCodeBlockInfo extracts language from code block" {
    var node = ast.Node.init(testing.allocator, .code_block);
    defer node.deinit(testing.allocator);
    node.fence_info = try testing.allocator.dupe(u8, "python");

    const info = getCodeBlockInfo(&node).?;
    try testing.expectEqualStrings("python", info.language.?);
    try testing.expectEqualStrings("python", info.raw_info.?);
}

test "getCodeBlockInfo with fence info containing extra metadata" {
    var node = ast.Node.init(testing.allocator, .code_block);
    defer node.deinit(testing.allocator);
    node.fence_info = try testing.allocator.dupe(u8, "javascript highlight-line=3");

    const info = getCodeBlockInfo(&node).?;
    try testing.expectEqualStrings("javascript", info.language.?);
    try testing.expectEqualStrings("javascript highlight-line=3", info.raw_info.?);
}

test "getCodeBlockInfo with no fence info" {
    var node = ast.Node.init(testing.allocator, .code_block);
    defer node.deinit(testing.allocator);

    const info = getCodeBlockInfo(&node).?;
    try testing.expectEqual(null, info.language);
    try testing.expectEqual(null, info.raw_info);
}

test "isCodeBlockLanguage matches case-insensitively" {
    var node = ast.Node.init(testing.allocator, .code_block);
    defer node.deinit(testing.allocator);
    node.fence_info = try testing.allocator.dupe(u8, "Python");

    try testing.expect(isCodeBlockLanguage(&node, "python"));
    try testing.expect(isCodeBlockLanguage(&node, "Python"));
    try testing.expect(isCodeBlockLanguage(&node, "PYTHON"));
    try testing.expect(!isCodeBlockLanguage(&node, "javascript"));
}

test "isCodeBlockLanguage returns false for non-code_block node" {
    var node = ast.Node.init(testing.allocator, .paragraph);
    defer node.deinit(testing.allocator);
    try testing.expect(!isCodeBlockLanguage(&node, "python"));
}

test "isCodeBlockLanguage returns false when no fence info" {
    var node = ast.Node.init(testing.allocator, .code_block);
    defer node.deinit(testing.allocator);
    try testing.expect(!isCodeBlockLanguage(&node, "python"));
}

// --- Integration tests using the parser ---

const parser = @import("markdown_parser.zig");

test "parse GFM table with alignments via cmark-gfm" {
    const input = "| Left | Center | Right |\n|:---|:---:|---:|\n| a | b | c |\n| d | e | f |\n";
    var doc = try parser.parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expect(doc.root.children.items.len > 0);
    const table_node = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.table, table_node.node_type);
    try testing.expectEqual(@as(u16, 3), table_node.table_columns);

    // Verify column alignments are extracted
    try testing.expect(table_node.table_alignments != null);
    const aligns = table_node.table_alignments.?;
    try testing.expectEqual(@as(usize, 3), aligns.len);
    try testing.expectEqual(ast.Alignment.left, aligns[0]);
    try testing.expectEqual(ast.Alignment.center, aligns[1]);
    try testing.expectEqual(ast.Alignment.right, aligns[2]);

    // Verify getTableInfo extracts header and body correctly
    const info = getTableInfo(table_node).?;
    try testing.expectEqual(@as(u16, 3), info.num_columns);
    try testing.expect(info.hasHeader());
    try testing.expectEqual(@as(usize, 2), info.bodyRowCount());

    // Verify column alignment helpers
    try testing.expectEqual(ast.Alignment.left, info.getColumnAlignment(0));
    try testing.expectEqual(ast.Alignment.center, info.getColumnAlignment(1));
    try testing.expectEqual(ast.Alignment.right, info.getColumnAlignment(2));

    // Verify header row has cells
    const header = info.header_row.?;
    try testing.expectEqual(@as(usize, 3), header.children.items.len);
    for (header.children.items) |*cell| {
        try testing.expectEqual(ast.NodeType.table_cell, cell.node_type);
    }

    // All rows should be table_rows with cells
    for (table_node.children.items) |*row| {
        try testing.expectEqual(ast.NodeType.table_row, row.node_type);
        try testing.expectEqual(@as(usize, 3), row.children.items.len);
        for (row.children.items) |*cell| {
            try testing.expectEqual(ast.NodeType.table_cell, cell.node_type);
        }
    }
}

test "parse GFM task list items via cmark-gfm" {
    const input = "- [x] Completed task\n- [ ] Incomplete task\n- Regular item\n";
    var doc = try parser.parse(testing.allocator, input);
    defer doc.deinit();

    const list = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.list, list.node_type);
    try testing.expectEqual(@as(usize, 3), list.children.items.len);

    // First item: checked task
    const item0 = &list.children.items[0];
    try testing.expect(isTaskListItem(item0));
    try testing.expectEqual(true, isChecked(item0).?);

    // Second item: unchecked task
    const item1 = &list.children.items[1];
    try testing.expect(isTaskListItem(item1));
    try testing.expectEqual(false, isChecked(item1).?);

    // Third item: regular (not a task list item)
    const item2 = &list.children.items[2];
    try testing.expect(!isTaskListItem(item2));
    try testing.expectEqual(null, isChecked(item2));
}

test "parse fenced code block with language info via cmark-gfm" {
    const input = "```python\ndef hello():\n    print(\"hello\")\n```\n";
    var doc = try parser.parse(testing.allocator, input);
    defer doc.deinit();

    const code_block = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.code_block, code_block.node_type);

    const info = getCodeBlockInfo(code_block).?;
    try testing.expectEqualStrings("python", info.language.?);
    try testing.expect(code_block.literal != null);
    try testing.expect(isCodeBlockLanguage(code_block, "python"));
}

test "parse fenced code block without language info via cmark-gfm" {
    const input = "```\nsome plain code\n```\n";
    var doc = try parser.parse(testing.allocator, input);
    defer doc.deinit();

    const code_block = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.code_block, code_block.node_type);

    const info = getCodeBlockInfo(code_block).?;
    try testing.expectEqual(null, info.language);
    try testing.expect(!isCodeBlockLanguage(code_block, "python"));
}

test "parse multiple code blocks with different languages via cmark-gfm" {
    const input = "```javascript\nconsole.log(\"hi\");\n```\n\n```zig\nconst x = 42;\n```\n";
    var doc = try parser.parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 2), doc.root.children.items.len);

    const js_block = &doc.root.children.items[0];
    try testing.expect(isCodeBlockLanguage(js_block, "javascript"));

    const zig_block = &doc.root.children.items[1];
    try testing.expect(isCodeBlockLanguage(zig_block, "zig"));
}

// --- Autolink tests ---

test "isAutolink returns false for non-link node" {
    var node = ast.Node.init(testing.allocator, .paragraph);
    defer node.deinit(testing.allocator);
    try testing.expect(!isAutolink(&node));
}

test "isAutolink returns false for explicit link" {
    // Explicit link: [click here](https://example.com) — text differs from URL
    var doc = try parser.parse(testing.allocator, "[click here](https://example.com)\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const link = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.link, link.node_type);
    try testing.expect(!isAutolink(link));
}

test "isAutolink detects URL autolink" {
    var doc = try parser.parse(testing.allocator, "https://example.com\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    // Find the autolinked URL
    var found = false;
    for (para.children.items) |*child| {
        if (child.node_type == .link) {
            try testing.expect(isAutolink(child));
            try testing.expect(!isEmailAutolink(child));
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "isAutolink detects email autolink" {
    var doc = try parser.parse(testing.allocator, "<user@example.com>\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    var found = false;
    for (para.children.items) |*child| {
        if (child.node_type == .link) {
            try testing.expect(isAutolink(child));
            try testing.expect(isEmailAutolink(child));
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "isEmailAutolink returns false for URL autolink" {
    var doc = try parser.parse(testing.allocator, "https://example.com\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    for (para.children.items) |*child| {
        if (child.node_type == .link) {
            try testing.expect(!isEmailAutolink(child));
            break;
        }
    }
}

test "autolink URL embedded in text" {
    // Autolink detection within surrounding text
    var doc = try parser.parse(testing.allocator, "Visit https://example.com for info\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    // Should have text + link + text children
    var link_count: usize = 0;
    var text_count: usize = 0;
    for (para.children.items) |*child| {
        if (child.node_type == .link) link_count += 1;
        if (child.node_type == .text) text_count += 1;
    }
    try testing.expect(link_count >= 1);
    try testing.expect(text_count >= 1);
}

// --- Footnote tests ---

test "isFootnoteDefinition identifies footnote definition nodes" {
    var node = ast.Node.init(testing.allocator, .footnote_definition);
    defer node.deinit(testing.allocator);
    try testing.expect(isFootnoteDefinition(&node));
}

test "isFootnoteDefinition returns false for non-footnote nodes" {
    var node = ast.Node.init(testing.allocator, .paragraph);
    defer node.deinit(testing.allocator);
    try testing.expect(!isFootnoteDefinition(&node));
}

test "isFootnoteReference identifies footnote reference nodes" {
    var node = ast.Node.init(testing.allocator, .footnote_reference);
    defer node.deinit(testing.allocator);
    try testing.expect(isFootnoteReference(&node));
}

test "isFootnoteReference returns false for non-footnote nodes" {
    var node = ast.Node.init(testing.allocator, .text);
    defer node.deinit(testing.allocator);
    try testing.expect(!isFootnoteReference(&node));
}

test "getFootnoteRefInfo returns null for non-footnote-reference" {
    var node = ast.Node.init(testing.allocator, .text);
    defer node.deinit(testing.allocator);
    try testing.expectEqual(null, getFootnoteRefInfo(&node));
}

test "getFootnoteRefInfo extracts label" {
    var node = ast.Node.init(testing.allocator, .footnote_reference);
    defer node.deinit(testing.allocator);
    node.literal = try testing.allocator.dupe(u8, "1");
    const info = getFootnoteRefInfo(&node).?;
    try testing.expectEqualStrings("1", info.label);
}

test "parse footnote reference and definition via cmark-gfm" {
    const input = "Text with footnote[^1].\n\n[^1]: This is the footnote content.\n";
    var doc = try parser.parse(testing.allocator, input);
    defer doc.deinit();

    // Should produce paragraph + footnote_definition
    try testing.expect(doc.root.children.items.len >= 2);

    // First child: paragraph with a footnote reference
    const para = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.paragraph, para.node_type);

    // Find the footnote reference in the paragraph
    const ref_count = countFootnoteReferences(para);
    try testing.expect(ref_count >= 1);

    // Second child (or later): footnote_definition
    const fn_def_count = countFootnoteDefinitions(&doc.root);
    try testing.expect(fn_def_count >= 1);
}

test "parse multiple footnotes via cmark-gfm" {
    const input = "First[^a] and second[^b].\n\n[^a]: Footnote A.\n\n[^b]: Footnote B.\n";
    var doc = try parser.parse(testing.allocator, input);
    defer doc.deinit();

    // Should have at least 1 paragraph + 2 footnote definitions
    const fn_def_count = countFootnoteDefinitions(&doc.root);
    try testing.expectEqual(@as(usize, 2), fn_def_count);

    // The paragraph should contain 2 footnote references
    const para = &doc.root.children.items[0];
    const ref_count = countFootnoteReferences(para);
    try testing.expectEqual(@as(usize, 2), ref_count);
}

test "parse footnote with multiline content via cmark-gfm" {
    const input = "Text[^note].\n\n[^note]: First line.\n    Second line.\n";
    var doc = try parser.parse(testing.allocator, input);
    defer doc.deinit();

    // Should parse successfully with footnote definition
    const fn_def_count = countFootnoteDefinitions(&doc.root);
    try testing.expect(fn_def_count >= 1);
}

test "countFootnoteDefinitions returns 0 when none present" {
    var doc = try parser.parse(testing.allocator, "Just a paragraph.\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), countFootnoteDefinitions(&doc.root));
}

test "countFootnoteReferences returns 0 when none present" {
    var doc = try parser.parse(testing.allocator, "Just a paragraph.\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), countFootnoteReferences(&doc.root));
}
