const std = @import("std");
const Allocator = std.mem.Allocator;

const lt = @import("../layout/layout_types.zig");
const LayoutTree = lt.LayoutTree;
const Rect = lt.Rect;
const TextRun = lt.TextRun;
const Fonts = @import("../layout/text_measurer.zig").Fonts;

const SearchState = @import("search_state.zig").SearchState;

/// Search all text runs in the layout tree for the given query (case-insensitive).
/// Populates state.matches with all found matches and sets current_idx to 0 if any.
pub fn search(state: *SearchState, tree: *const LayoutTree, fonts: *const Fonts) Allocator.Error!void {
    state.matches.clearRetainingCapacity();
    state.current_idx = null;

    const query = state.query orelse return;
    if (query.len == 0) return;

    // Pre-lowercase the query for case-insensitive comparison.
    // SearchState enforces max_query_len, so this should never exceed the buffer.
    var lower_query_buf: [SearchState.max_query_len]u8 = undefined;
    std.debug.assert(query.len <= lower_query_buf.len);
    const lower_query = toLowerSlice(query, &lower_query_buf);

    for (tree.nodes.items, 0..) |*node, node_idx| {
        for (node.text_runs.items, 0..) |*run, run_idx| {
            try searchInRun(state, run, node_idx, run_idx, lower_query, fonts);
        }
    }

    if (state.matches.items.len > 0) {
        state.current_idx = 0;
    }
}

/// Find all occurrences of lower_query within a single TextRun.
fn searchInRun(
    state: *SearchState,
    run: *const TextRun,
    node_idx: usize,
    run_idx: usize,
    lower_query: []const u8,
    fonts: *const Fonts,
) Allocator.Error!void {
    const text = run.text;
    if (text.len < lower_query.len) return;

    var pos: usize = 0;
    while (pos + lower_query.len <= text.len) {
        if (matchAtPosition(text, pos, lower_query)) {
            const byte_end = pos + lower_query.len;
            const highlight_rect = computeHighlightRect(run, pos, byte_end, fonts);
            try state.matches.append(.{
                .node_idx = node_idx,
                .run_idx = run_idx,
                .byte_start = pos,
                .byte_end = byte_end,
                .highlight_rect = highlight_rect,
            });
            // Non-overlapping: advance past this match. Searching "aa" in "aaa"
            // yields one match, not two. This matches common editor behavior.
            pos = byte_end;
        } else {
            pos += 1;
        }
    }
}

/// Case-insensitive match at a specific position in text.
fn matchAtPosition(text: []const u8, pos: usize, lower_query: []const u8) bool {
    for (lower_query, 0..) |qc, i| {
        if (pos + i >= text.len) return false;
        if (toLowerAscii(text[pos + i]) != qc) return false;
    }
    return true;
}

/// Compute the highlight rectangle for a match within a TextRun.
/// Measures the text before the match to get x offset, and the match text for width.
fn computeHighlightRect(run: *const TextRun, byte_start: usize, byte_end: usize, fonts: *const Fonts) Rect {
    const s = run.style;
    const prefix_width = fonts.measure(run.text[0..byte_start], s.font_size, s.bold, s.italic, s.is_code).x;
    const match_width = fonts.measure(run.text[byte_start..byte_end], s.font_size, s.bold, s.italic, s.is_code).x;

    return .{
        .x = run.rect.x + prefix_width,
        .y = run.rect.y,
        .width = match_width,
        .height = run.rect.height,
    };
}

/// Convert a single ASCII byte to lowercase.
/// TODO: Unicode-aware case folding for non-ASCII text.
fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Convert a slice to lowercase ASCII, writing into the provided buffer.
/// Returns a slice of the buffer with the same length as input.
fn toLowerSlice(input: []const u8, buf: []u8) []const u8 {
    const len = @min(input.len, buf.len);
    for (input[0..len], buf[0..len]) |c, *out| {
        out.* = toLowerAscii(c);
    }
    return buf[0..len];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "toLowerAscii converts uppercase" {
    try testing.expectEqual(@as(u8, 'a'), toLowerAscii('A'));
    try testing.expectEqual(@as(u8, 'z'), toLowerAscii('Z'));
    try testing.expectEqual(@as(u8, 'a'), toLowerAscii('a'));
    try testing.expectEqual(@as(u8, '1'), toLowerAscii('1'));
}

test "toLowerSlice converts string" {
    var buf: [32]u8 = undefined;
    const result = toLowerSlice("Hello World", &buf);
    try testing.expectEqualStrings("hello world", result);
}

test "matchAtPosition finds case-insensitive match" {
    try testing.expect(matchAtPosition("Hello World", 0, "hello"));
    try testing.expect(matchAtPosition("Hello World", 6, "world"));
    try testing.expect(!matchAtPosition("Hello World", 0, "world"));
}

test "matchAtPosition with partial overlap at end" {
    try testing.expect(!matchAtPosition("He", 0, "hello"));
}

test "toLowerSlice with empty input" {
    var buf: [32]u8 = undefined;
    const result = toLowerSlice("", &buf);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "toLowerSlice with input longer than buffer truncates" {
    var buf: [4]u8 = undefined;
    const result = toLowerSlice("ABCDEF", &buf);
    try testing.expectEqualStrings("abcd", result);
}

test "toLowerSlice preserves non-ASCII bytes" {
    var buf: [32]u8 = undefined;
    const result = toLowerSlice("caf\xc3\xa9", &buf);
    try testing.expectEqualStrings("caf\xc3\xa9", result);
}

test "matchAtPosition with empty query matches trivially" {
    try testing.expect(matchAtPosition("anything", 0, ""));
    try testing.expect(matchAtPosition("anything", 5, ""));
}

test "matchAtPosition at exact end of string" {
    // "abc" length 3, match "c" at position 2
    try testing.expect(matchAtPosition("abc", 2, "c"));
    // Position at text length should not match
    try testing.expect(!matchAtPosition("abc", 3, "c"));
}

test "matchAtPosition with non-ASCII bytes" {
    // Multi-byte UTF-8 sequences compare byte-by-byte (ASCII lowering only)
    try testing.expect(matchAtPosition("caf\xc3\xa9", 0, "caf"));
    try testing.expect(matchAtPosition("caf\xc3\xa9", 3, "\xc3\xa9"));
}

// Integration tests for search/searchInRun/computeHighlightRect require Fonts
// (raylib) and cannot run in pure unit test mode. The search algorithm is
// validated through the component tests above.
