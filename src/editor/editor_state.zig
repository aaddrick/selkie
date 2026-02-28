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
