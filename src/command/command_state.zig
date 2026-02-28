const std = @import("std");

/// Manages the `:` command bar state for vim-style go-to-line.
/// No heap allocations — uses a fixed buffer for input.
pub const CommandState = struct {
    /// Whether the command bar is visible.
    is_open: bool = false,
    /// Fixed buffer for digit input (last byte reserved for null terminator used by renderer's sliceToZ).
    input_buf: [max_input_len]u8 = [_]u8{0} ** max_input_len,
    /// Number of valid bytes in input_buf.
    input_len: usize = 0,

    pub const max_input_len = 16;

    pub fn open(self: *CommandState) void {
        self.reset();
        self.is_open = true;
    }

    pub fn close(self: *CommandState) void {
        self.reset();
    }

    fn reset(self: *CommandState) void {
        self.is_open = false;
        self.input_len = 0;
        @memset(&self.input_buf, 0);
    }

    /// Append a digit character. Returns false if buffer is full or char is not a digit.
    pub fn appendChar(self: *CommandState, char: u8) bool {
        if (!std.ascii.isDigit(char)) return false;
        if (self.input_len >= max_input_len - 1) return false;
        self.input_buf[self.input_len] = char;
        self.input_len += 1;
        return true;
    }

    /// Remove the last character. Returns false if empty.
    pub fn backspace(self: *CommandState) bool {
        if (self.input_len == 0) return false;
        self.input_len -= 1;
        self.input_buf[self.input_len] = 0;
        return true;
    }

    /// Get the current input as a slice.
    pub fn inputSlice(self: *const CommandState) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    /// Parse the input as a line number. Returns null if empty or invalid.
    pub fn lineNumber(self: *const CommandState) ?u32 {
        if (self.input_len == 0) return null;
        return std.fmt.parseInt(u32, self.inputSlice(), 10) catch null;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "CommandState defaults" {
    const state = CommandState{};
    try testing.expect(!state.is_open);
    try testing.expectEqual(@as(usize, 0), state.input_len);
}

test "CommandState open and close" {
    var state = CommandState{};

    state.open();
    try testing.expect(state.is_open);
    try testing.expectEqual(@as(usize, 0), state.input_len);

    // Add some input, then close — should clear
    try testing.expect(state.appendChar('5'));
    state.close();
    try testing.expect(!state.is_open);
    try testing.expectEqual(@as(usize, 0), state.input_len);
}

test "CommandState appendChar accepts digits only" {
    var state = CommandState{};
    state.open();

    try testing.expect(state.appendChar('1'));
    try testing.expect(state.appendChar('2'));
    try testing.expect(state.appendChar('3'));
    try testing.expectEqualStrings("123", state.inputSlice());

    // Non-digit rejected
    try testing.expect(!state.appendChar('a'));
    try testing.expect(!state.appendChar('/'));
    try testing.expect(!state.appendChar(' '));
    try testing.expectEqualStrings("123", state.inputSlice());
}

test "CommandState appendChar returns false when full" {
    var state = CommandState{};
    state.open();

    for (0..CommandState.max_input_len - 1) |_| {
        try testing.expect(state.appendChar('9'));
    }
    try testing.expect(!state.appendChar('0'));
    try testing.expectEqual(CommandState.max_input_len - 1, state.input_len);
}

test "CommandState backspace" {
    var state = CommandState{};
    state.open();

    try testing.expect(!state.backspace()); // empty

    try testing.expect(state.appendChar('4'));
    try testing.expect(state.appendChar('2'));
    try testing.expectEqualStrings("42", state.inputSlice());

    try testing.expect(state.backspace());
    try testing.expectEqualStrings("4", state.inputSlice());

    try testing.expect(state.backspace());
    try testing.expectEqualStrings("", state.inputSlice());

    try testing.expect(!state.backspace()); // empty again
}

test "CommandState lineNumber parses valid input" {
    var state = CommandState{};
    state.open();

    try testing.expectEqual(@as(?u32, null), state.lineNumber()); // empty

    try testing.expect(state.appendChar('4'));
    try testing.expect(state.appendChar('2'));
    try testing.expectEqual(@as(?u32, 42), state.lineNumber());
}

test "CommandState lineNumber returns null for empty" {
    const state = CommandState{};
    try testing.expectEqual(@as(?u32, null), state.lineNumber());
}

test "CommandState open clears previous input" {
    var state = CommandState{};
    state.open();
    try testing.expect(state.appendChar('7'));
    try testing.expect(state.appendChar('7'));

    // Re-open should clear
    state.open();
    try testing.expectEqual(@as(usize, 0), state.input_len);
    try testing.expectEqual(@as(?u32, null), state.lineNumber());
}

test "CommandState lineNumber returns null for u32 overflow" {
    var state = CommandState{};
    state.open();

    // Fill buffer with '9's — "999999999999999" exceeds u32 max (4294967295)
    for (0..CommandState.max_input_len - 1) |_| {
        try testing.expect(state.appendChar('9'));
    }
    try testing.expectEqual(@as(?u32, null), state.lineNumber());
}
