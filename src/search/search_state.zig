const std = @import("std");
const Allocator = std.mem.Allocator;

const lt = @import("../layout/layout_types.zig");
const Rect = lt.Rect;

/// A single search match located within a TextRun.
pub const SearchMatch = struct {
    /// Index into LayoutTree.nodes
    node_idx: usize,
    /// Index into the node's text_runs
    run_idx: usize,
    /// Byte offset of match start within TextRun.text
    byte_start: usize,
    /// Byte offset of match end (exclusive) within TextRun.text
    byte_end: usize,
    /// Pre-computed highlight rectangle in world coordinates
    highlight_rect: Rect,
};

/// Manages search query state, match list, and current match navigation.
pub const SearchState = struct {
    allocator: Allocator,
    /// Current search query (heap-allocated copy)
    query: ?[]const u8 = null,
    /// All matches in document order
    matches: std.ArrayList(SearchMatch),
    /// Index of the currently focused match (0-based), null if no matches
    current_idx: ?usize = null,
    /// Whether the search bar is visible
    is_open: bool = false,
    /// Input buffer for the search bar (fixed-size, null-terminated)
    input_buf: [max_query_len]u8 = [_]u8{0} ** max_query_len,
    /// Number of valid bytes in input_buf
    input_len: usize = 0,

    /// Maximum search query length in bytes. appendChar() returns false when full.
    pub const max_query_len = 256;

    pub fn init(allocator: Allocator) SearchState {
        return .{
            .allocator = allocator,
            .matches = std.ArrayList(SearchMatch).init(allocator),
        };
    }

    pub fn deinit(self: *SearchState) void {
        if (self.query) |q| self.allocator.free(q);
        self.matches.deinit();
    }

    /// Open the search bar, focusing it for input.
    pub fn open(self: *SearchState) void {
        self.is_open = true;
    }

    /// Close the search bar and clear all state.
    pub fn close(self: *SearchState) void {
        self.is_open = false;
        self.clearQuery();
    }

    /// Clear query, matches, and input buffer.
    pub fn clearQuery(self: *SearchState) void {
        if (self.query) |q| {
            self.allocator.free(q);
            self.query = null;
        }
        self.matches.clearRetainingCapacity();
        self.current_idx = null;
        @memset(self.input_buf[0..self.input_len], 0);
        self.input_len = 0;
    }

    /// Set a new query string. Dupes the input and clears old matches.
    pub fn setQuery(self: *SearchState, query: []const u8) Allocator.Error!void {
        if (self.query) |q| self.allocator.free(q);
        self.matches.clearRetainingCapacity();
        self.current_idx = null;

        if (query.len == 0) {
            self.query = null;
            return;
        }

        self.query = try self.allocator.dupe(u8, query);
    }

    /// Navigate to the next match, wrapping around.
    pub fn nextMatch(self: *SearchState) void {
        if (self.matches.items.len == 0) return;
        if (self.current_idx) |idx| {
            self.current_idx = (idx + 1) % self.matches.items.len;
        } else {
            self.current_idx = 0;
        }
    }

    /// Navigate to the previous match, wrapping around.
    pub fn prevMatch(self: *SearchState) void {
        if (self.matches.items.len == 0) return;
        if (self.current_idx) |idx| {
            self.current_idx = if (idx == 0) self.matches.items.len - 1 else idx - 1;
        } else {
            self.current_idx = self.matches.items.len - 1;
        }
    }

    /// Get the currently focused match, if any.
    pub fn currentMatch(self: *const SearchState) ?SearchMatch {
        const idx = self.current_idx orelse return null;
        if (idx >= self.matches.items.len) return null;
        return self.matches.items[idx];
    }

    /// Append a character to the input buffer. Returns false if buffer is full.
    pub fn appendChar(self: *SearchState, char: u8) bool {
        if (self.input_len >= max_query_len - 1) return false;
        self.input_buf[self.input_len] = char;
        self.input_len += 1;
        return true;
    }

    /// Remove the last character from the input buffer. Returns false if empty.
    pub fn backspace(self: *SearchState) bool {
        if (self.input_len == 0) return false;
        self.input_len -= 1;
        self.input_buf[self.input_len] = 0;
        return true;
    }

    /// Get the current input as a slice.
    pub fn inputSlice(self: *const SearchState) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    /// Format the match count display string into the provided buffer.
    /// Returns a slice like "3 of 17" or "No matches" or "".
    pub fn formatMatchCount(self: *const SearchState, buf: []u8) []const u8 {
        if (self.query == null or self.input_len == 0) return "";
        if (self.matches.items.len == 0) return "No matches";
        if (self.current_idx) |idx| {
            return std.fmt.bufPrint(buf, "{d} of {d}", .{ idx + 1, self.matches.items.len }) catch "?/?";
        }
        return std.fmt.bufPrint(buf, "{d} matches", .{self.matches.items.len}) catch "?";
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "SearchState init and deinit" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    try testing.expect(!state.is_open);
    try testing.expectEqual(@as(?[]const u8, null), state.query);
    try testing.expectEqual(@as(usize, 0), state.matches.items.len);
    try testing.expectEqual(@as(?usize, null), state.current_idx);
    try testing.expectEqual(@as(usize, 0), state.input_len);
}

test "SearchState open and close" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    state.open();
    try testing.expect(state.is_open);

    state.close();
    try testing.expect(!state.is_open);
}

test "SearchState setQuery stores a copy" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    try state.setQuery("hello");
    try testing.expect(state.query != null);
    try testing.expectEqualStrings("hello", state.query.?);

    // Setting empty clears
    try state.setQuery("");
    try testing.expectEqual(@as(?[]const u8, null), state.query);
}

test "SearchState setQuery replaces previous" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    try state.setQuery("first");
    try state.setQuery("second");
    try testing.expectEqualStrings("second", state.query.?);
}

test "SearchState clearQuery resets all state" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    try state.setQuery("test");
    _ = state.appendChar('t');
    state.current_idx = 0;

    state.clearQuery();

    try testing.expectEqual(@as(?[]const u8, null), state.query);
    try testing.expectEqual(@as(usize, 0), state.matches.items.len);
    try testing.expectEqual(@as(?usize, null), state.current_idx);
    try testing.expectEqual(@as(usize, 0), state.input_len);
}

test "SearchState nextMatch wraps around" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    // Add 3 dummy matches
    for (0..3) |_| {
        try state.matches.append(.{
            .node_idx = 0,
            .run_idx = 0,
            .byte_start = 0,
            .byte_end = 1,
            .highlight_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        });
    }

    // First call sets to 0
    state.nextMatch();
    try testing.expectEqual(@as(?usize, 0), state.current_idx);

    state.nextMatch();
    try testing.expectEqual(@as(?usize, 1), state.current_idx);

    state.nextMatch();
    try testing.expectEqual(@as(?usize, 2), state.current_idx);

    // Wraps back to 0
    state.nextMatch();
    try testing.expectEqual(@as(?usize, 0), state.current_idx);
}

test "SearchState prevMatch wraps around" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    for (0..3) |_| {
        try state.matches.append(.{
            .node_idx = 0,
            .run_idx = 0,
            .byte_start = 0,
            .byte_end = 1,
            .highlight_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        });
    }

    // First call sets to last
    state.prevMatch();
    try testing.expectEqual(@as(?usize, 2), state.current_idx);

    state.prevMatch();
    try testing.expectEqual(@as(?usize, 1), state.current_idx);

    state.prevMatch();
    try testing.expectEqual(@as(?usize, 0), state.current_idx);

    // Wraps to last
    state.prevMatch();
    try testing.expectEqual(@as(?usize, 2), state.current_idx);
}

test "SearchState nextMatch and prevMatch with no matches is no-op" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    state.nextMatch();
    try testing.expectEqual(@as(?usize, null), state.current_idx);

    state.prevMatch();
    try testing.expectEqual(@as(?usize, null), state.current_idx);
}

test "SearchState currentMatch returns correct match" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    const match1 = SearchMatch{
        .node_idx = 1,
        .run_idx = 2,
        .byte_start = 5,
        .byte_end = 10,
        .highlight_rect = .{ .x = 100, .y = 200, .width = 50, .height = 16 },
    };
    try state.matches.append(match1);
    state.current_idx = 0;

    const result = state.currentMatch();
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.node_idx);
    try testing.expectEqual(@as(usize, 2), result.?.run_idx);
}

test "SearchState currentMatch returns null when no current" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    try testing.expectEqual(@as(?SearchMatch, null), state.currentMatch());
}

test "SearchState appendChar and backspace" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    try testing.expect(state.appendChar('h'));
    try testing.expect(state.appendChar('i'));
    try testing.expectEqual(@as(usize, 2), state.input_len);
    try testing.expectEqualStrings("hi", state.inputSlice());

    try testing.expect(state.backspace());
    try testing.expectEqual(@as(usize, 1), state.input_len);
    try testing.expectEqualStrings("h", state.inputSlice());

    try testing.expect(state.backspace());
    try testing.expect(!state.backspace()); // empty
}

test "SearchState formatMatchCount" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    var buf: [64]u8 = undefined;

    // No query — empty string
    try testing.expectEqualStrings("", state.formatMatchCount(&buf));

    // Query with no matches
    try state.setQuery("test");
    state.input_len = 4;
    try testing.expectEqualStrings("No matches", state.formatMatchCount(&buf));

    // Add matches and set current
    for (0..3) |_| {
        try state.matches.append(.{
            .node_idx = 0,
            .run_idx = 0,
            .byte_start = 0,
            .byte_end = 1,
            .highlight_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        });
    }
    state.current_idx = 1;
    try testing.expectEqualStrings("2 of 3", state.formatMatchCount(&buf));

    // Matches present but no current_idx — shows total count
    state.current_idx = null;
    try testing.expectEqualStrings("3 matches", state.formatMatchCount(&buf));
}

test "SearchState currentMatch returns null for out-of-bounds index" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    try state.matches.append(.{
        .node_idx = 0,
        .run_idx = 0,
        .byte_start = 0,
        .byte_end = 1,
        .highlight_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    });
    // Set current_idx beyond match count
    state.current_idx = 5;
    try testing.expectEqual(@as(?SearchMatch, null), state.currentMatch());
}

test "SearchState appendChar returns false when buffer full" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    // Fill buffer to capacity
    for (0..SearchState.max_query_len - 1) |_| {
        try testing.expect(state.appendChar('x'));
    }
    try testing.expectEqual(SearchState.max_query_len - 1, state.input_len);

    // Next append should fail
    try testing.expect(!state.appendChar('y'));
    try testing.expectEqual(SearchState.max_query_len - 1, state.input_len);
}

test "SearchState close clears all query state" {
    var state = SearchState.init(testing.allocator);
    defer state.deinit();

    // Set up state
    state.open();
    try state.setQuery("search term");
    _ = state.appendChar('s');
    _ = state.appendChar('e');
    try state.matches.append(.{
        .node_idx = 0,
        .run_idx = 0,
        .byte_start = 0,
        .byte_end = 1,
        .highlight_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    });
    state.current_idx = 0;

    // Close should clear everything
    state.close();

    try testing.expect(!state.is_open);
    try testing.expectEqual(@as(?[]const u8, null), state.query);
    try testing.expectEqual(@as(usize, 0), state.matches.items.len);
    try testing.expectEqual(@as(?usize, null), state.current_idx);
    try testing.expectEqual(@as(usize, 0), state.input_len);
}
