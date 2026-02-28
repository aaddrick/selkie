const std = @import("std");
const Allocator = std.mem.Allocator;

/// Manages editor data for in-app markdown editing: cursor position,
/// line splitting, dirty state tracking, and text reconstruction.
pub const EditorState = struct {
    allocator: Allocator,
    lines: [][]u8,
    cursor_line: usize,
    cursor_col: usize,
    is_dirty: bool,
    is_open: bool,

    /// Initialize from raw source text by splitting into owned lines.
    pub fn initFromSource(allocator: Allocator, source_text: []const u8) Allocator.Error!EditorState {
        var line_list = std.ArrayList([]u8).init(allocator);
        errdefer {
            for (line_list.items) |line| allocator.free(line);
            line_list.deinit();
        }

        var iter = std.mem.splitScalar(u8, source_text, '\n');
        while (iter.next()) |segment| {
            const owned = try allocator.dupe(u8, segment);
            errdefer allocator.free(owned);
            try line_list.append(owned);
        }

        return .{
            .allocator = allocator,
            .lines = try line_list.toOwnedSlice(),
            .cursor_line = 0,
            .cursor_col = 0,
            .is_dirty = false,
            .is_open = false,
        };
    }

    /// Free all owned lines and the line array.
    pub fn deinit(self: *EditorState) void {
        for (self.lines) |line| self.allocator.free(line);
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    /// Rebuild source text from lines by joining with newlines.
    /// Caller owns the returned slice and must free it with the provided allocator.
    pub fn toSource(self: *const EditorState, allocator: Allocator) Allocator.Error![]u8 {
        if (self.lines.len == 0) return try allocator.dupe(u8, "");

        var total_len: usize = self.lines.len - 1; // newline separators
        for (self.lines) |line| total_len += line.len;

        const buf = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (self.lines, 0..) |line, i| {
            @memcpy(buf[pos..][0..line.len], line);
            pos += line.len;
            if (i < self.lines.len - 1) {
                buf[pos] = '\n';
                pos += 1;
            }
        }

        return buf;
    }

    /// Number of lines in the editor.
    pub fn lineCount(self: *const EditorState) usize {
        return self.lines.len;
    }

    /// Get the text of the current cursor line, or null if out of bounds.
    pub fn currentLineText(self: *const EditorState) ?[]const u8 {
        if (self.cursor_line >= self.lines.len) return null;
        return self.lines[self.cursor_line];
    }

    /// Get the text of a specific line by index, or null if out of bounds.
    pub fn getLineText(self: *const EditorState, index: usize) ?[]const u8 {
        if (index >= self.lines.len) return null;
        return self.lines[index];
    }

    /// Clamp cursor position to valid bounds within the current lines.
    /// Note: the zero-lines branch is defensive; initFromSource always produces at least one line.
    pub fn clampCursor(self: *EditorState) void {
        if (self.lines.len == 0) {
            self.cursor_line = 0;
            self.cursor_col = 0;
            return;
        }
        self.cursor_line = @min(self.cursor_line, self.lines.len - 1);
        self.cursor_col = @min(self.cursor_col, self.lines[self.cursor_line].len);
    }

    /// Set cursor position, clamping to valid bounds.
    pub fn setCursor(self: *EditorState, line: usize, col: usize) void {
        self.cursor_line = line;
        self.cursor_col = col;
        self.clampCursor();
    }

    // =========================================================================
    // UTF-8 helpers
    // =========================================================================

    /// Encode a Unicode codepoint to UTF-8, returning the byte sequence and length.
    /// Invalid codepoints (> U+10FFFF) fall back to '?' to avoid undefined bytes.
    pub fn encodeCodepoint(codepoint: u21) struct { bytes: [4]u8, len: u3 } {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
            buf[0] = '?';
            return .{ .bytes = buf, .len = 1 };
        };
        return .{ .bytes = buf, .len = len };
    }

    /// Return the byte length of the UTF-8 character starting at `pos` in `line`.
    /// Returns 1 for invalid lead bytes (treats as single-byte).
    fn charLenAt(line: []const u8, pos: usize) usize {
        if (pos >= line.len) return 0;
        return std.unicode.utf8ByteSequenceLength(line[pos]) catch 1;
    }

    /// Return the byte length of the UTF-8 character ending at `pos` (exclusive) in `line`.
    /// Caps the backward scan to 4 bytes (max UTF-8 sequence length). If the line
    /// contains malformed UTF-8 (e.g., bare continuation bytes), the scan stops at
    /// the 4-byte limit or the start of the line, whichever comes first.
    fn charLenBefore(line: []const u8, pos: usize) usize {
        if (pos == 0 or pos > line.len) return 0;
        var i = pos - 1;
        while (i > 0 and (pos - i) < 4 and line[i] & 0xC0 == 0x80) : (i -= 1) {}
        return pos - i;
    }

    // =========================================================================
    // Text mutation
    // =========================================================================

    /// Insert UTF-8 bytes at cursor position in the current line, advance cursor.
    pub fn insertBytes(self: *EditorState, bytes: []const u8) Allocator.Error!void {
        if (bytes.len == 0) return;
        if (self.cursor_line >= self.lines.len) return;
        const line = self.lines[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        const new_line = try self.allocator.alloc(u8, line.len + bytes.len);
        @memcpy(new_line[0..col], line[0..col]);
        @memcpy(new_line[col..][0..bytes.len], bytes);
        @memcpy(new_line[col + bytes.len ..], line[col..]);

        self.allocator.free(line);
        self.lines[self.cursor_line] = new_line;
        self.cursor_col = col + bytes.len;
        self.is_dirty = true;
    }

    /// Insert a Unicode codepoint (encoded as UTF-8) at cursor, advance cursor.
    pub fn insertChar(self: *EditorState, codepoint: u21) Allocator.Error!void {
        const encoded = encodeCodepoint(codepoint);
        try self.insertBytes(encoded.bytes[0..encoded.len]);
    }

    /// Delete the UTF-8 character before the cursor (backspace).
    /// If at column 0, merges current line with previous line.
    pub fn deleteCharBefore(self: *EditorState) Allocator.Error!void {
        if (self.cursor_line >= self.lines.len) return;

        if (self.cursor_col > 0) {
            const line = self.lines[self.cursor_line];
            const col = @min(self.cursor_col, line.len);
            const char_len = charLenBefore(line, col);
            const start = col - char_len;

            const new_line = try self.allocator.alloc(u8, line.len - char_len);
            @memcpy(new_line[0..start], line[0..start]);
            @memcpy(new_line[start..], line[col..]);

            self.allocator.free(line);
            self.lines[self.cursor_line] = new_line;
            self.cursor_col = start;
            self.is_dirty = true;
        } else if (self.cursor_line > 0) {
            // Merge with previous line
            try self.mergeLineWithPrevious(self.cursor_line);
        }
    }

    /// Delete the UTF-8 character at the cursor (delete key).
    /// If at end of line, merges next line into current line.
    pub fn deleteCharAt(self: *EditorState) Allocator.Error!void {
        if (self.cursor_line >= self.lines.len) return;

        const line = self.lines[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        if (col < line.len) {
            const char_len = charLenAt(line, col);
            const new_line = try self.allocator.alloc(u8, line.len - char_len);
            @memcpy(new_line[0..col], line[0..col]);
            @memcpy(new_line[col..], line[col + char_len ..]);

            self.allocator.free(line);
            self.lines[self.cursor_line] = new_line;
            self.is_dirty = true;
        } else if (self.cursor_line + 1 < self.lines.len) {
            // Merge next line into current
            try self.mergeLineWithPrevious(self.cursor_line + 1);
        }
    }

    /// Merge line at `line_idx` into the previous line, removing line_idx.
    /// Allocates the new lines array first so that failure leaves state intact.
    fn mergeLineWithPrevious(self: *EditorState, line_idx: usize) Allocator.Error!void {
        if (line_idx == 0 or line_idx >= self.lines.len) return;

        const prev = self.lines[line_idx - 1];
        const curr = self.lines[line_idx];
        const prev_len = prev.len;

        // Allocate new lines array first — if this fails, state is unchanged.
        const new_lines = try self.allocator.alloc([]u8, self.lines.len - 1);
        errdefer self.allocator.free(new_lines);

        const merged = try self.allocator.alloc(u8, prev.len + curr.len);
        @memcpy(merged[0..prev.len], prev);
        @memcpy(merged[prev.len..], curr);

        // All allocations succeeded — now mutate state (no more failure points).
        self.allocator.free(prev);
        self.allocator.free(curr);

        // Build the new lines array, skipping line_idx.
        @memcpy(new_lines[0 .. line_idx - 1], self.lines[0 .. line_idx - 1]);
        new_lines[line_idx - 1] = merged;
        if (line_idx < new_lines.len) {
            @memcpy(new_lines[line_idx..], self.lines[line_idx + 1 ..]);
        }
        self.allocator.free(self.lines);
        self.lines = new_lines;

        self.cursor_line = line_idx - 1;
        self.cursor_col = prev_len;
        self.is_dirty = true;
    }

    /// Insert a newline at cursor position (Enter key), splitting the current line.
    pub fn insertNewline(self: *EditorState) Allocator.Error!void {
        if (self.cursor_line >= self.lines.len) return;

        const line = self.lines[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        // Create two new lines from the split
        const before = try self.allocator.dupe(u8, line[0..col]);
        errdefer self.allocator.free(before);
        const after = try self.allocator.dupe(u8, line[col..]);
        errdefer self.allocator.free(after);

        // Grow the lines array by one
        const new_lines = try self.allocator.alloc([]u8, self.lines.len + 1);
        // Copy lines before cursor_line
        @memcpy(new_lines[0..self.cursor_line], self.lines[0..self.cursor_line]);
        // Insert the split lines
        new_lines[self.cursor_line] = before;
        new_lines[self.cursor_line + 1] = after;
        // Copy lines after cursor_line
        if (self.cursor_line + 1 < self.lines.len) {
            @memcpy(new_lines[self.cursor_line + 2 ..], self.lines[self.cursor_line + 1 ..]);
        }

        self.allocator.free(line);
        self.allocator.free(self.lines);
        self.lines = new_lines;
        self.cursor_line += 1;
        self.cursor_col = 0;
        self.is_dirty = true;
    }

    /// Insert spaces for a tab at the cursor position.
    pub fn insertTab(self: *EditorState) Allocator.Error!void {
        const tab_width = 4;
        const spaces_needed = tab_width - (self.cursor_col % tab_width);
        const spaces = "    "; // 4 spaces max
        try self.insertBytes(spaces[0..spaces_needed]);
    }

    // =========================================================================
    // Cursor movement
    // =========================================================================

    /// Move cursor left by one UTF-8 character. Wraps to end of previous line.
    pub fn moveCursorLeft(self: *EditorState) void {
        if (self.cursor_line >= self.lines.len) return;
        const line = self.lines[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        if (col > 0) {
            self.cursor_col = col - charLenBefore(line, col);
        } else if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            self.cursor_col = self.lines[self.cursor_line].len;
        }
    }

    /// Move cursor right by one UTF-8 character. Wraps to start of next line.
    pub fn moveCursorRight(self: *EditorState) void {
        if (self.cursor_line >= self.lines.len) return;
        const line = self.lines[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        if (col < line.len) {
            self.cursor_col = col + charLenAt(line, col);
        } else if (self.cursor_line + 1 < self.lines.len) {
            self.cursor_line += 1;
            self.cursor_col = 0;
        }
    }

    /// Move cursor up one line, clamping column to the new line's length.
    pub fn moveCursorUp(self: *EditorState) void {
        if (self.cursor_line > 0) {
            self.cursor_line -= 1;
            self.cursor_col = @min(self.cursor_col, self.lines[self.cursor_line].len);
        }
    }

    /// Move cursor down one line, clamping column to the new line's length.
    pub fn moveCursorDown(self: *EditorState) void {
        if (self.cursor_line + 1 < self.lines.len) {
            self.cursor_line += 1;
            self.cursor_col = @min(self.cursor_col, self.lines[self.cursor_line].len);
        }
    }

    /// Move cursor to the start of the current line.
    pub fn moveCursorHome(self: *EditorState) void {
        self.cursor_col = 0;
    }

    /// Move cursor to the end of the current line.
    pub fn moveCursorEnd(self: *EditorState) void {
        if (self.cursor_line < self.lines.len) {
            self.cursor_col = self.lines[self.cursor_line].len;
        }
    }

    /// Move cursor up by `page_size` lines.
    pub fn moveCursorPageUp(self: *EditorState, page_size: usize) void {
        if (self.lines.len == 0) return;
        self.cursor_line -|= page_size;
        self.cursor_col = @min(self.cursor_col, self.lines[self.cursor_line].len);
    }

    /// Move cursor down by `page_size` lines.
    pub fn moveCursorPageDown(self: *EditorState, page_size: usize) void {
        if (self.lines.len == 0) return;
        self.cursor_line = @min(self.cursor_line +| page_size, self.lines.len - 1);
        self.cursor_col = @min(self.cursor_col, self.lines[self.cursor_line].len);
    }
};

const testing = std.testing;

test "initFromSource splits empty string into one empty line" {
    var state = try EditorState.initFromSource(testing.allocator, "");
    defer state.deinit();

    try testing.expectEqual(1, state.lineCount());
    try testing.expectEqualStrings("", state.currentLineText().?);
}

test "initFromSource splits single line" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();

    try testing.expectEqual(1, state.lineCount());
    try testing.expectEqualStrings("hello world", state.getLineText(0).?);
}

test "initFromSource splits multi-line text" {
    var state = try EditorState.initFromSource(testing.allocator, "line1\nline2\nline3");
    defer state.deinit();

    try testing.expectEqual(3, state.lineCount());
    try testing.expectEqualStrings("line1", state.getLineText(0).?);
    try testing.expectEqualStrings("line2", state.getLineText(1).?);
    try testing.expectEqualStrings("line3", state.getLineText(2).?);
}

test "initFromSource handles trailing newline" {
    var state = try EditorState.initFromSource(testing.allocator, "line1\nline2\n");
    defer state.deinit();

    try testing.expectEqual(3, state.lineCount());
    try testing.expectEqualStrings("line1", state.getLineText(0).?);
    try testing.expectEqualStrings("line2", state.getLineText(1).?);
    try testing.expectEqualStrings("", state.getLineText(2).?);
}

test "toSource round-trips empty string" {
    var state = try EditorState.initFromSource(testing.allocator, "");
    defer state.deinit();

    const source = try state.toSource(testing.allocator);
    defer testing.allocator.free(source);
    try testing.expectEqualStrings("", source);
}

test "toSource round-trips single line" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();

    const source = try state.toSource(testing.allocator);
    defer testing.allocator.free(source);
    try testing.expectEqualStrings("hello", source);
}

test "toSource round-trips multi-line text" {
    const input = "# Title\n\nSome text\n- item1\n- item2";
    var state = try EditorState.initFromSource(testing.allocator, input);
    defer state.deinit();

    const source = try state.toSource(testing.allocator);
    defer testing.allocator.free(source);
    try testing.expectEqualStrings(input, source);
}

test "toSource round-trips trailing newline" {
    const input = "line1\nline2\n";
    var state = try EditorState.initFromSource(testing.allocator, input);
    defer state.deinit();

    const source = try state.toSource(testing.allocator);
    defer testing.allocator.free(source);
    try testing.expectEqualStrings(input, source);
}

test "toSource round-trips consecutive newlines" {
    const input = "\n\n\n";
    var state = try EditorState.initFromSource(testing.allocator, input);
    defer state.deinit();

    try testing.expectEqual(4, state.lineCount());
    const source = try state.toSource(testing.allocator);
    defer testing.allocator.free(source);
    try testing.expectEqualStrings(input, source);
}

test "cursor starts at 0,0" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
}

test "setCursor clamps line beyond bounds" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(10, 0);
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
}

test "setCursor clamps column beyond line length" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(0, 100);
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(3, state.cursor_col);
}

test "setCursor clamps both line and column" {
    var state = try EditorState.initFromSource(testing.allocator, "ab\ncde\nf");
    defer state.deinit();

    state.setCursor(99, 99);
    try testing.expectEqual(2, state.cursor_line);
    try testing.expectEqual(1, state.cursor_col);
}

test "dirty flag starts false" {
    var state = try EditorState.initFromSource(testing.allocator, "test");
    defer state.deinit();

    try testing.expect(!state.is_dirty);
}

test "dirty flag can be set" {
    var state = try EditorState.initFromSource(testing.allocator, "test");
    defer state.deinit();

    state.is_dirty = true;
    try testing.expect(state.is_dirty);
    state.is_dirty = false;
    try testing.expect(!state.is_dirty);
}

test "is_open starts false" {
    var state = try EditorState.initFromSource(testing.allocator, "test");
    defer state.deinit();

    try testing.expect(!state.is_open);
}

test "getLineText returns null for out of bounds" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    try testing.expectEqual(@as(?[]const u8, null), state.getLineText(5));
}

test "currentLineText returns null when cursor is out of bounds" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    // Bypass setCursor to set cursor_line directly past bounds
    state.cursor_line = 5;
    try testing.expectEqual(@as(?[]const u8, null), state.currentLineText());
}

test "setCursor to exact boundary positions does not clamp" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    // Column equal to line length (cursor after last char) is valid
    state.setCursor(1, 3);
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(3, state.cursor_col);

    // Last line, last valid column
    state.setCursor(1, 0);
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
}

test "initFromSource owns lines independently of input" {
    var buf = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(buf);

    var state = try EditorState.initFromSource(testing.allocator, buf);
    defer state.deinit();

    // Mutate original -- state should be unaffected
    buf[0] = 'X';
    try testing.expectEqualStrings("hello", state.getLineText(0).?);
}

// =========================================================================
// Text mutation tests
// =========================================================================

test "insertChar inserts ASCII at start of line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    try state.insertChar('X');
    try testing.expectEqualStrings("Xabc", state.getLineText(0).?);
    try testing.expectEqual(1, state.cursor_col);
    try testing.expect(state.is_dirty);
}

test "insertChar inserts at middle of line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 2);
    try state.insertChar('X');
    try testing.expectEqualStrings("abXc", state.getLineText(0).?);
    try testing.expectEqual(3, state.cursor_col);
}

test "insertChar inserts at end of line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.insertChar('X');
    try testing.expectEqualStrings("abcX", state.getLineText(0).?);
    try testing.expectEqual(4, state.cursor_col);
}

test "insertChar inserts multi-byte UTF-8 character" {
    var state = try EditorState.initFromSource(testing.allocator, "ab");
    defer state.deinit();

    state.setCursor(0, 1);
    // U+00E9 (é) = 2-byte UTF-8 sequence: 0xC3 0xA9
    try state.insertChar(0x00E9);
    try testing.expectEqualStrings("a\xC3\xA9b", state.getLineText(0).?);
    try testing.expectEqual(3, state.cursor_col); // 1 + 2 bytes
}

test "insertChar inserts 3-byte UTF-8 character" {
    var state = try EditorState.initFromSource(testing.allocator, "ab");
    defer state.deinit();

    state.setCursor(0, 1);
    // U+4E16 (世) = 3-byte UTF-8
    try state.insertChar(0x4E16);
    const line = state.getLineText(0).?;
    try testing.expectEqual(@as(usize, 5), line.len); // 1 + 3 + 1
    try testing.expectEqual(4, state.cursor_col); // 1 + 3
}

test "insertChar inserts 4-byte UTF-8 character (emoji)" {
    var state = try EditorState.initFromSource(testing.allocator, "hi");
    defer state.deinit();

    state.setCursor(0, 2);
    // U+1F600 (😀) = 4-byte UTF-8
    try state.insertChar(0x1F600);
    const line = state.getLineText(0).?;
    try testing.expectEqual(@as(usize, 6), line.len); // 2 + 4
    try testing.expectEqual(6, state.cursor_col);
}

test "deleteCharBefore at middle of line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 2);
    try state.deleteCharBefore();
    try testing.expectEqualStrings("ac", state.getLineText(0).?);
    try testing.expectEqual(1, state.cursor_col);
    try testing.expect(state.is_dirty);
}

test "deleteCharBefore at end of line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.deleteCharBefore();
    try testing.expectEqualStrings("ab", state.getLineText(0).?);
    try testing.expectEqual(2, state.cursor_col);
}

test "deleteCharBefore at start of line merges with previous" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(1, 0);
    try state.deleteCharBefore();
    try testing.expectEqual(1, state.lineCount());
    try testing.expectEqualStrings("abcdef", state.getLineText(0).?);
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(3, state.cursor_col);
}

test "deleteCharBefore at start of first line is no-op" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    try state.deleteCharBefore();
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqual(0, state.cursor_col);
    try testing.expect(!state.is_dirty);
}

test "deleteCharBefore removes multi-byte UTF-8 character" {
    var state = try EditorState.initFromSource(testing.allocator, "a\xC3\xA9b");
    defer state.deinit();

    state.setCursor(0, 3); // After the é (2 bytes)
    try state.deleteCharBefore();
    try testing.expectEqualStrings("ab", state.getLineText(0).?);
    try testing.expectEqual(1, state.cursor_col);
}

test "deleteCharAt at middle of line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 1);
    try state.deleteCharAt();
    try testing.expectEqualStrings("ac", state.getLineText(0).?);
    try testing.expectEqual(1, state.cursor_col);
    try testing.expect(state.is_dirty);
}

test "deleteCharAt at start of line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    try state.deleteCharAt();
    try testing.expectEqualStrings("bc", state.getLineText(0).?);
    try testing.expectEqual(0, state.cursor_col);
}

test "deleteCharAt at end of line merges with next" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.deleteCharAt();
    try testing.expectEqual(1, state.lineCount());
    try testing.expectEqualStrings("abcdef", state.getLineText(0).?);
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(3, state.cursor_col);
}

test "deleteCharAt at end of last line is no-op" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.deleteCharAt();
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expect(!state.is_dirty);
}

test "insertNewline splits line at cursor" {
    var state = try EditorState.initFromSource(testing.allocator, "abcdef");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.insertNewline();
    try testing.expectEqual(2, state.lineCount());
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqualStrings("def", state.getLineText(1).?);
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
    try testing.expect(state.is_dirty);
}

test "insertNewline at start of line creates empty line before" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    try state.insertNewline();
    try testing.expectEqual(2, state.lineCount());
    try testing.expectEqualStrings("", state.getLineText(0).?);
    try testing.expectEqualStrings("abc", state.getLineText(1).?);
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
}

test "insertNewline at end of line creates empty line after" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.insertNewline();
    try testing.expectEqual(2, state.lineCount());
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqualStrings("", state.getLineText(1).?);
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
}

test "insertNewline preserves lines after split point" {
    var state = try EditorState.initFromSource(testing.allocator, "first\nsecond\nthird");
    defer state.deinit();

    state.setCursor(1, 3); // middle of "second"
    try state.insertNewline();
    try testing.expectEqual(4, state.lineCount());
    try testing.expectEqualStrings("first", state.getLineText(0).?);
    try testing.expectEqualStrings("sec", state.getLineText(1).?);
    try testing.expectEqualStrings("ond", state.getLineText(2).?);
    try testing.expectEqualStrings("third", state.getLineText(3).?);
}

test "insertTab inserts spaces to next tab stop" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 0);
    try state.insertTab();
    try testing.expectEqualStrings("    abc", state.getLineText(0).?);
    try testing.expectEqual(4, state.cursor_col);
}

test "insertTab aligns to tab stop" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 1);
    try state.insertTab();
    // col 1 -> next tab stop at 4, so 3 spaces
    try testing.expectEqualStrings("a   bc", state.getLineText(0).?);
    try testing.expectEqual(4, state.cursor_col);
}

test "toSource round-trips after edits" {
    var state = try EditorState.initFromSource(testing.allocator, "hello\nworld");
    defer state.deinit();

    state.setCursor(0, 5);
    try state.insertChar('!');
    state.setCursor(1, 0);
    try state.insertChar('W');
    try state.deleteCharAt(); // remove the old 'w'

    const source = try state.toSource(testing.allocator);
    defer testing.allocator.free(source);
    try testing.expectEqualStrings("hello!\nWorld", source);
}

// =========================================================================
// Cursor movement tests
// =========================================================================

test "moveCursorLeft moves within line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 2);
    state.moveCursorLeft();
    try testing.expectEqual(1, state.cursor_col);
}

test "moveCursorLeft wraps to previous line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(1, 0);
    state.moveCursorLeft();
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(3, state.cursor_col);
}

test "moveCursorLeft at start of first line is no-op" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.moveCursorLeft();
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
}

test "moveCursorLeft skips multi-byte UTF-8" {
    // "aé" = 'a' + 0xC3 0xA9 = 3 bytes
    var state = try EditorState.initFromSource(testing.allocator, "a\xC3\xA9");
    defer state.deinit();

    state.setCursor(0, 3); // After é
    state.moveCursorLeft();
    try testing.expectEqual(1, state.cursor_col); // Before é
}

test "moveCursorRight moves within line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.moveCursorRight();
    try testing.expectEqual(1, state.cursor_col);
}

test "moveCursorRight wraps to next line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(0, 3);
    state.moveCursorRight();
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
}

test "moveCursorRight at end of last line is no-op" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 3);
    state.moveCursorRight();
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(3, state.cursor_col);
}

test "moveCursorRight skips multi-byte UTF-8" {
    var state = try EditorState.initFromSource(testing.allocator, "\xC3\xA9b");
    defer state.deinit();

    state.moveCursorRight();
    try testing.expectEqual(2, state.cursor_col); // After 2-byte é
}

test "moveCursorUp moves to previous line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(1, 1);
    state.moveCursorUp();
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(1, state.cursor_col);
}

test "moveCursorUp clamps column to shorter line" {
    var state = try EditorState.initFromSource(testing.allocator, "ab\ncdefg");
    defer state.deinit();

    state.setCursor(1, 5);
    state.moveCursorUp();
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(2, state.cursor_col); // "ab" has len 2
}

test "moveCursorUp at first line is no-op" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.moveCursorUp();
    try testing.expectEqual(0, state.cursor_line);
}

test "moveCursorDown moves to next line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.moveCursorDown();
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(0, state.cursor_col);
}

test "moveCursorDown clamps column to shorter line" {
    var state = try EditorState.initFromSource(testing.allocator, "abcdef\ngh");
    defer state.deinit();

    state.setCursor(0, 5);
    state.moveCursorDown();
    try testing.expectEqual(1, state.cursor_line);
    try testing.expectEqual(2, state.cursor_col); // "gh" has len 2
}

test "moveCursorDown at last line is no-op" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.moveCursorDown();
    try testing.expectEqual(0, state.cursor_line);
}

test "moveCursorHome moves to column 0" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 2);
    state.moveCursorHome();
    try testing.expectEqual(0, state.cursor_col);
}

test "moveCursorEnd moves to end of line" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.moveCursorEnd();
    try testing.expectEqual(3, state.cursor_col);
}

test "moveCursorPageUp moves by page size" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj");
    defer state.deinit();

    state.setCursor(8, 0);
    state.moveCursorPageUp(5);
    try testing.expectEqual(3, state.cursor_line);
}

test "moveCursorPageUp clamps to first line" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.setCursor(1, 0);
    state.moveCursorPageUp(10);
    try testing.expectEqual(0, state.cursor_line);
}

test "moveCursorPageDown moves by page size" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj");
    defer state.deinit();

    state.setCursor(2, 0);
    state.moveCursorPageDown(5);
    try testing.expectEqual(7, state.cursor_line);
}

test "moveCursorPageDown clamps to last line" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.setCursor(1, 0);
    state.moveCursorPageDown(10);
    try testing.expectEqual(2, state.cursor_line);
}

// =========================================================================
// UTF-8 encoding tests
// =========================================================================

test "encodeCodepoint encodes ASCII" {
    const result = EditorState.encodeCodepoint('A');
    try testing.expectEqual(@as(u3, 1), result.len);
    try testing.expectEqual(@as(u8, 'A'), result.bytes[0]);
}

test "encodeCodepoint encodes 2-byte sequence" {
    const result = EditorState.encodeCodepoint(0x00E9); // é
    try testing.expectEqual(@as(u3, 2), result.len);
    try testing.expectEqual(@as(u8, 0xC3), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0xA9), result.bytes[1]);
}

test "encodeCodepoint encodes 3-byte sequence" {
    const result = EditorState.encodeCodepoint(0x4E16); // 世
    try testing.expectEqual(@as(u3, 3), result.len);
    try testing.expectEqual(@as(u8, 0xE4), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0xB8), result.bytes[1]);
    try testing.expectEqual(@as(u8, 0x96), result.bytes[2]);
}

test "encodeCodepoint encodes 4-byte sequence" {
    const result = EditorState.encodeCodepoint(0x1F600); // 😀
    try testing.expectEqual(@as(u3, 4), result.len);
    try testing.expectEqual(@as(u8, 0xF0), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x9F), result.bytes[1]);
    try testing.expectEqual(@as(u8, 0x98), result.bytes[2]);
    try testing.expectEqual(@as(u8, 0x80), result.bytes[3]);
}

test "encodeCodepoint falls back to '?' for surrogate codepoint" {
    const result = EditorState.encodeCodepoint(0xD800);
    try testing.expectEqual(@as(u3, 1), result.len);
    try testing.expectEqual(@as(u8, '?'), result.bytes[0]);
}

test "insertTab at tab-stop-aligned column inserts full tab width" {
    var state = try EditorState.initFromSource(testing.allocator, "12345678");
    defer state.deinit();

    state.setCursor(0, 4);
    try state.insertTab();
    try testing.expectEqual(8, state.cursor_col);
    try testing.expectEqualStrings("1234    5678", state.getLineText(0).?);
}

test "moveCursorPageUp clamps column to shorter target line" {
    // Lines of varying length: line 0 is "ab" (len 2), lines 1-5 are longer
    var state = try EditorState.initFromSource(testing.allocator, "ab\ncdefgh\ncdefgh\ncdefgh\ncdefgh\ncdefgh");
    defer state.deinit();

    state.setCursor(5, 6); // on last line at col 6
    state.moveCursorPageUp(5);
    try testing.expectEqual(0, state.cursor_line);
    try testing.expectEqual(2, state.cursor_col); // clamped to "ab".len
}

test "moveCursorPageDown clamps column to shorter target line" {
    var state = try EditorState.initFromSource(testing.allocator, "cdefgh\ncdefgh\ncdefgh\ncdefgh\ncdefgh\nab");
    defer state.deinit();

    state.setCursor(0, 6); // on first line at col 6
    state.moveCursorPageDown(5);
    try testing.expectEqual(5, state.cursor_line);
    try testing.expectEqual(2, state.cursor_col); // clamped to "ab".len
}

test "charLenBefore caps scan at 4 bytes for malformed UTF-8" {
    // 5 bare continuation bytes followed by 'X' — charLenBefore should not
    // walk past 4 bytes back, even though all preceding bytes are continuations.
    const line = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 'X' };
    const result = EditorState.charLenBefore(&line, 5); // before 'X'
    try testing.expectEqual(@as(usize, 4), result);
}

test "insertBytes with empty slice is no-op" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 1);
    try state.insertBytes("");
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqual(1, state.cursor_col);
    try testing.expect(!state.is_dirty);
}

test "deleteCharBefore clamps cursor_col beyond line length" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    // Bypass setCursor to set cursor_col past line length
    state.cursor_col = 10;
    try state.deleteCharBefore();
    // Should clamp to line.len (3), then delete the char before it
    try testing.expectEqualStrings("ab", state.getLineText(0).?);
    try testing.expectEqual(2, state.cursor_col);
}

test "deleteCharAt with cursor_col beyond line length at end merges next" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.cursor_col = 10; // beyond "abc" length
    try state.deleteCharAt();
    // col clamped to 3 (line.len), which is at end of line, so merges with next
    try testing.expectEqual(1, state.lineCount());
    try testing.expectEqualStrings("abcdef", state.getLineText(0).?);
}
