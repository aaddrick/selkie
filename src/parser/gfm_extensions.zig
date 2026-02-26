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
