//! GFM Alert Detection
//!
//! Detects GitHub Flavored Markdown alert syntax in blockquotes.
//! Alerts use the pattern: `> [!TYPE]` where TYPE is NOTE, TIP, IMPORTANT, WARNING, or CAUTION.
//! The first paragraph of the blockquote is checked for this pattern.

const std = @import("std");
const rl = @import("raylib");
const ast = @import("../parser/ast.zig");
const Theme = @import("../theme/theme.zig").Theme;

pub const AlertType = enum {
    note,
    tip,
    important,
    warning,
    caution,

    /// Return the display label for this alert type.
    pub fn label(self: AlertType) []const u8 {
        return switch (self) {
            .note => "Note",
            .tip => "Tip",
            .important => "Important",
            .warning => "Warning",
            .caution => "Caution",
        };
    }

    /// Return the Unicode icon prefix for this alert type.
    pub fn icon(self: AlertType) []const u8 {
        return switch (self) {
            .note => "\xe2\x84\xb9 ", // ℹ
            .tip => "\xf0\x9f\x92\xa1 ", // 💡
            .important => "\xe2\x9d\x97 ", // ❗
            .warning => "\xe2\x9a\xa0 ", // ⚠
            .caution => "\xe2\x9b\x94 ", // ⛔
        };
    }

    /// Return the border color for this alert type from the theme.
    pub fn borderColor(self: AlertType, theme: *const Theme) rl.Color {
        return switch (self) {
            .note => theme.alert_note_border,
            .tip => theme.alert_tip_border,
            .important => theme.alert_important_border,
            .warning => theme.alert_warning_border,
            .caution => theme.alert_caution_border,
        };
    }

    /// Return the text color for this alert type from the theme.
    pub fn textColor(self: AlertType, theme: *const Theme) rl.Color {
        return switch (self) {
            .note => theme.alert_note_text,
            .tip => theme.alert_tip_text,
            .important => theme.alert_important_text,
            .warning => theme.alert_warning_text,
            .caution => theme.alert_caution_text,
        };
    }
};

/// Detect if a blockquote AST node contains a GFM alert.
/// Returns the alert type and the index of the text node containing the marker
/// so the layout engine can strip it from rendered output.
pub const AlertInfo = struct {
    alert_type: AlertType,
    /// The text after the `[!TYPE]` marker on the same line (may be empty).
    remaining_text: []const u8,
};

/// Check if a blockquote node starts with a GFM alert marker.
/// The pattern is: first child is a paragraph whose first text child starts with `[!TYPE]`.
pub fn detectAlert(blockquote: *const ast.Node) ?AlertInfo {
    if (blockquote.node_type != .block_quote) return null;
    if (blockquote.children.items.len == 0) return null;

    const first_child = &blockquote.children.items[0];
    if (first_child.node_type != .paragraph) return null;
    if (first_child.children.items.len == 0) return null;

    const first_inline = &first_child.children.items[0];
    if (first_inline.node_type != .text) return null;

    const text = first_inline.literal orelse return null;
    return parseAlertMarker(text);
}

/// Parse a text string for a GFM alert marker pattern `[!TYPE]`.
/// Returns the alert type and any remaining text after the marker.
pub fn parseAlertMarker(text: []const u8) ?AlertInfo {
    const trimmed = std.mem.trimLeft(u8, text, " \t");
    if (trimmed.len < 3) return null;
    if (trimmed[0] != '[' or trimmed[1] != '!') return null;

    // Find the closing bracket
    const close_idx = std.mem.indexOfScalar(u8, trimmed, ']') orelse return null;
    const type_str = trimmed[2..close_idx];

    const alert_type = parseAlertType(type_str) orelse return null;

    // Text after the marker (skip optional newline/space)
    var remaining = trimmed[close_idx + 1 ..];
    remaining = std.mem.trimLeft(u8, remaining, " \t\n\r");

    return .{
        .alert_type = alert_type,
        .remaining_text = remaining,
    };
}

fn parseAlertType(type_str: []const u8) ?AlertType {
    if (std.ascii.eqlIgnoreCase(type_str, "NOTE")) return .note;
    if (std.ascii.eqlIgnoreCase(type_str, "TIP")) return .tip;
    if (std.ascii.eqlIgnoreCase(type_str, "IMPORTANT")) return .important;
    if (std.ascii.eqlIgnoreCase(type_str, "WARNING")) return .warning;
    if (std.ascii.eqlIgnoreCase(type_str, "CAUTION")) return .caution;
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "parseAlertMarker detects NOTE" {
    const result = parseAlertMarker("[!NOTE]").?;
    try testing.expectEqual(AlertType.note, result.alert_type);
    try testing.expectEqualStrings("", result.remaining_text);
}

test "parseAlertMarker detects TIP" {
    const result = parseAlertMarker("[!TIP]").?;
    try testing.expectEqual(AlertType.tip, result.alert_type);
}

test "parseAlertMarker detects IMPORTANT" {
    const result = parseAlertMarker("[!IMPORTANT]").?;
    try testing.expectEqual(AlertType.important, result.alert_type);
}

test "parseAlertMarker detects WARNING" {
    const result = parseAlertMarker("[!WARNING]").?;
    try testing.expectEqual(AlertType.warning, result.alert_type);
}

test "parseAlertMarker detects CAUTION" {
    const result = parseAlertMarker("[!CAUTION]").?;
    try testing.expectEqual(AlertType.caution, result.alert_type);
}

test "parseAlertMarker preserves remaining text" {
    const result = parseAlertMarker("[!NOTE]\nSome extra text").?;
    try testing.expectEqual(AlertType.note, result.alert_type);
    try testing.expectEqualStrings("Some extra text", result.remaining_text);
}

test "parseAlertMarker is case-insensitive" {
    const result = parseAlertMarker("[!note]").?;
    try testing.expectEqual(AlertType.note, result.alert_type);
}

test "parseAlertMarker returns null for non-alert text" {
    try testing.expectEqual(@as(?AlertInfo, null), parseAlertMarker("Just text"));
    try testing.expectEqual(@as(?AlertInfo, null), parseAlertMarker("[not an alert]"));
    try testing.expectEqual(@as(?AlertInfo, null), parseAlertMarker("[!UNKNOWN]"));
    try testing.expectEqual(@as(?AlertInfo, null), parseAlertMarker(""));
    try testing.expectEqual(@as(?AlertInfo, null), parseAlertMarker("[!"));
}

test "parseAlertMarker handles leading whitespace" {
    const result = parseAlertMarker("  [!TIP]").?;
    try testing.expectEqual(AlertType.tip, result.alert_type);
}

test "AlertType.label returns display name" {
    try testing.expectEqualStrings("Note", AlertType.note.label());
    try testing.expectEqualStrings("Tip", AlertType.tip.label());
    try testing.expectEqualStrings("Important", AlertType.important.label());
    try testing.expectEqualStrings("Warning", AlertType.warning.label());
    try testing.expectEqualStrings("Caution", AlertType.caution.label());
}

test "AlertType.icon returns non-empty string" {
    try testing.expect(AlertType.note.icon().len > 0);
    try testing.expect(AlertType.tip.icon().len > 0);
    try testing.expect(AlertType.important.icon().len > 0);
    try testing.expect(AlertType.warning.icon().len > 0);
    try testing.expect(AlertType.caution.icon().len > 0);
}

test "detectAlert on blockquote with alert marker" {
    var bq = ast.Node.init(testing.allocator, .block_quote);
    defer bq.deinit(testing.allocator);

    var para = ast.Node.init(testing.allocator, .paragraph);
    var text_node = ast.Node.init(testing.allocator, .text);
    text_node.literal = try testing.allocator.dupe(u8, "[!NOTE]");
    try para.children.append(text_node);
    try bq.children.append(para);

    const result = detectAlert(&bq).?;
    try testing.expectEqual(AlertType.note, result.alert_type);
}

test "detectAlert returns null for regular blockquote" {
    var bq = ast.Node.init(testing.allocator, .block_quote);
    defer bq.deinit(testing.allocator);

    var para = ast.Node.init(testing.allocator, .paragraph);
    var text_node = ast.Node.init(testing.allocator, .text);
    text_node.literal = try testing.allocator.dupe(u8, "Just a regular quote");
    try para.children.append(text_node);
    try bq.children.append(para);

    try testing.expectEqual(@as(?AlertInfo, null), detectAlert(&bq));
}

test "detectAlert returns null for non-blockquote" {
    var para = ast.Node.init(testing.allocator, .paragraph);
    defer para.deinit(testing.allocator);
    try testing.expectEqual(@as(?AlertInfo, null), detectAlert(&para));
}

test "detectAlert returns null for empty blockquote" {
    var bq = ast.Node.init(testing.allocator, .block_quote);
    defer bq.deinit(testing.allocator);
    try testing.expectEqual(@as(?AlertInfo, null), detectAlert(&bq));
}
