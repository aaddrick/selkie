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

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

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
}

test "getTableInfo with no header row" {
    var table = ast.Node.init(testing.allocator, .table);
    defer table.deinit(testing.allocator);
    table.table_columns = 1;

    const row = ast.Node.init(testing.allocator, .table_row);
    try table.children.append(row);

    const info = getTableInfo(&table).?;
    try testing.expectEqual(null, info.header_row);
    // With no header found, body_start stays 0, so all rows are "body"
    // Actually, the loop doesn't find a header, so body_start is 0
    try testing.expectEqual(@as(usize, 1), info.body_rows.len);
}

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
