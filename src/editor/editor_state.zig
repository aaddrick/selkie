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
    /// Vertical scroll offset in pixels for the editor view.
    scroll_y: f32,
    /// Horizontal scroll offset in pixels for the editor view.
    scroll_x: f32,
    /// Selection anchor point (where selection started). When non-null,
    /// the selection spans from this anchor to the current cursor position.
    selection_anchor: ?Position = null,
    /// Undo history stack.
    undo_stack: std.ArrayList(UndoEntry),
    /// Redo history stack.
    redo_stack: std.ArrayList(UndoEntry),
    /// When false, mutations do not push undo entries (used during undo/redo replay).
    recording_undo: bool = true,

    /// Maximum number of entries in each undo/redo stack.
    const max_undo_stack_size: usize = 1000;

    pub const Position = struct {
        line: usize,
        col: usize,
    };

    /// An undo entry captures the inverse of a text mutation so it can be reversed.
    pub const UndoEntry = struct {
        kind: Kind,
        /// Cursor position before the mutation.
        cursor_before: Position,
        /// Cursor position after the mutation.
        cursor_after: Position,

        pub const Kind = union(enum) {
            /// Undo: delete `text` starting at `pos`. Redo: re-insert it.
            insert: struct {
                pos: Position,
                text: []const u8, // owned
            },
            /// Undo: insert `text` at `pos`. Redo: re-delete it.
            delete: struct {
                pos: Position,
                text: []const u8, // owned
            },
            /// A group of entries applied together.
            compound: struct {
                entries: []UndoEntry, // owned slice of owned entries
            },
        };

        pub fn deinit(self: *UndoEntry, allocator: Allocator) void {
            switch (self.kind) {
                .insert => |*ins| allocator.free(ins.text),
                .delete => |*del| allocator.free(del.text),
                .compound => |*comp| {
                    for (comp.entries) |*entry| entry.deinit(allocator);
                    allocator.free(comp.entries);
                },
            }
        }
    };

    /// Ordered selection range from start to end. Both are cursor positions (byte offsets).
    /// end_line is inclusive; end_col is exclusive (like a cursor between characters).
    pub const SelectionRange = struct {
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    };

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
            .scroll_y = 0,
            .scroll_x = 0,
            .selection_anchor = null,
            .undo_stack = std.ArrayList(UndoEntry).init(allocator),
            .redo_stack = std.ArrayList(UndoEntry).init(allocator),
        };
    }

    /// Free all owned lines, the line array, and undo/redo stacks.
    pub fn deinit(self: *EditorState) void {
        for (self.undo_stack.items) |*entry| entry.deinit(self.allocator);
        self.undo_stack.deinit();
        for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
        self.redo_stack.deinit();
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
    // Undo / Redo
    // =========================================================================

    /// Clear the redo stack, freeing all entries. Called when a new edit is made.
    fn clearRedoStack(self: *EditorState) void {
        for (self.redo_stack.items) |*entry| entry.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Push an entry onto a stack, evicting the oldest entry if at capacity.
    /// Note: orderedRemove(0) is O(n) but acceptable for max_undo_stack_size of 1000.
    fn pushToStack(self: *EditorState, stack: *std.ArrayList(UndoEntry), entry: UndoEntry) Allocator.Error!void {
        if (stack.items.len >= max_undo_stack_size) {
            var oldest = stack.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        try stack.append(entry);
    }

    /// Record an undo entry for a just-completed insertion (the undo action is
    /// "delete the inserted text"). Supports coalescing adjacent single-char inserts.
    fn recordInsert(self: *EditorState, pos: Position, text: []const u8, cursor_before: Position, cursor_after: Position) Allocator.Error!void {
        if (!self.recording_undo) return;
        self.clearRedoStack();

        // Attempt to coalesce with the previous entry if it was a single-char
        // insert at the adjacent position on the same line.
        if (text.len == 1 and text[0] != '\n' and text[0] != '\t') {
            if (self.tryCoalesceInsert(pos, text, cursor_after)) return;
        }

        const owned_text = try self.allocator.dupe(u8, text);
        try self.pushToStack(&self.undo_stack, .{
            .kind = .{ .insert = .{ .pos = pos, .text = owned_text } },
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        });
    }

    /// Try to extend the last undo entry with an adjacent single-char insert.
    /// Returns true if coalescing succeeded.
    fn tryCoalesceInsert(self: *EditorState, pos: Position, text: []const u8, cursor_after: Position) bool {
        const items = self.undo_stack.items;
        if (items.len == 0) return false;
        const last = &items[items.len - 1];
        if (last.kind != .insert) return false;
        const last_ins = &last.kind.insert;
        // Adjacent if the last insert ended where this one starts.
        if (last_ins.pos.line != pos.line or
            last_ins.pos.col + last_ins.text.len != pos.col) return false;

        // Extend the existing entry's text by appending the new character.
        // OOM here is non-fatal: caller will create a separate undo entry.
        const old_text = last_ins.text;
        const new_text = self.allocator.alloc(u8, old_text.len + text.len) catch return false;
        @memcpy(new_text[0..old_text.len], old_text);
        @memcpy(new_text[old_text.len..], text);
        self.allocator.free(old_text);
        last_ins.text = new_text;
        last.cursor_after = cursor_after;
        return true;
    }

    /// Record an undo entry for a just-completed deletion (the undo action is
    /// "re-insert the deleted text").
    fn recordDelete(self: *EditorState, pos: Position, text: []const u8, cursor_before: Position, cursor_after: Position) Allocator.Error!void {
        if (!self.recording_undo) return;
        self.clearRedoStack();

        const owned_text = try self.allocator.dupe(u8, text);
        try self.pushToStack(&self.undo_stack, .{
            .kind = .{ .delete = .{ .pos = pos, .text = owned_text } },
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        });
    }

    /// Apply an undo entry's action without recording a new undo entry.
    /// Returns the inverse entry to push onto the opposite stack.
    fn applyEntry(self: *EditorState, entry: *const UndoEntry, comptime is_undo: bool) Allocator.Error!UndoEntry {
        const kind: UndoEntry.Kind = switch (entry.kind) {
            .insert => |ins| blk: {
                self.cursor_line = ins.pos.line;
                self.cursor_col = ins.pos.col;
                // Undo an insert by deleting; redo by re-inserting.
                if (is_undo) try self.rawDeleteText(ins.pos, ins.text.len) else try self.rawInsertText(ins.text);
                break :blk .{ .insert = .{ .pos = ins.pos, .text = try self.allocator.dupe(u8, ins.text) } };
            },
            .delete => |del| blk: {
                self.cursor_line = del.pos.line;
                self.cursor_col = del.pos.col;
                // Undo a delete by re-inserting; redo by re-deleting.
                if (is_undo) try self.rawInsertText(del.text) else try self.rawDeleteText(del.pos, del.text.len);
                break :blk .{ .delete = .{ .pos = del.pos, .text = try self.allocator.dupe(u8, del.text) } };
            },
            .compound => |comp| blk: {
                // Apply sub-entries in reverse order for undo, forward for redo.
                // Inverse entries are stored in reversed order so the opposite
                // operation applies them in the correct sequence.
                const n = comp.entries.len;
                var inverse_entries = try self.allocator.alloc(UndoEntry, n);
                var applied: usize = 0;
                errdefer {
                    for (inverse_entries[0..applied]) |*e| e.deinit(self.allocator);
                    self.allocator.free(inverse_entries);
                }

                for (0..n) |fwd_idx| {
                    // For undo: iterate backwards, store at mirrored position.
                    // For redo: iterate forwards, store at mirrored position.
                    const src = if (is_undo) n - 1 - fwd_idx else fwd_idx;
                    const dst = if (is_undo) src else n - 1 - fwd_idx;
                    inverse_entries[dst] = try self.applyEntry(&comp.entries[src], is_undo);
                    applied += 1;
                }

                break :blk .{ .compound = .{ .entries = inverse_entries } };
            },
        };

        return .{
            .kind = kind,
            .cursor_before = entry.cursor_before,
            .cursor_after = entry.cursor_after,
        };
    }

    /// Insert text at the current cursor position without recording undo.
    /// Handles embedded newlines by splitting lines.
    fn rawInsertText(self: *EditorState, text: []const u8) Allocator.Error!void {
        var iter = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (iter.next()) |segment| {
            if (!first) {
                try self.rawInsertNewline();
            }
            if (segment.len > 0) {
                try self.rawInsertBytes(segment);
            }
            first = false;
        }
    }

    /// Insert bytes at cursor on the current line (no newline handling).
    fn rawInsertBytes(self: *EditorState, bytes: []const u8) Allocator.Error!void {
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

    /// Insert a newline at cursor without recording undo.
    fn rawInsertNewline(self: *EditorState) Allocator.Error!void {
        if (self.cursor_line >= self.lines.len) return;
        const line = self.lines[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        const before = try self.allocator.dupe(u8, line[0..col]);
        errdefer self.allocator.free(before);
        const after = try self.allocator.dupe(u8, line[col..]);
        errdefer self.allocator.free(after);

        const new_lines = try self.allocator.alloc([]u8, self.lines.len + 1);
        @memcpy(new_lines[0..self.cursor_line], self.lines[0..self.cursor_line]);
        new_lines[self.cursor_line] = before;
        new_lines[self.cursor_line + 1] = after;
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

    /// Delete `byte_count` bytes of text starting at `pos`, handling newlines
    /// (merging lines as needed). Used by undo/redo replay.
    fn rawDeleteText(self: *EditorState, pos: Position, byte_count: usize) Allocator.Error!void {
        self.cursor_line = pos.line;
        self.cursor_col = pos.col;
        var remaining = byte_count;
        while (remaining > 0) {
            if (self.cursor_line >= self.lines.len) break;
            const line = self.lines[self.cursor_line];
            const col = @min(self.cursor_col, line.len);
            const avail = line.len - col;
            if (avail > 0) {
                const to_delete = @min(remaining, avail);
                const new_line = try self.allocator.alloc(u8, line.len - to_delete);
                @memcpy(new_line[0..col], line[0..col]);
                @memcpy(new_line[col..], line[col + to_delete ..]);
                self.allocator.free(line);
                self.lines[self.cursor_line] = new_line;
                remaining -= to_delete;
            } else if (self.cursor_line + 1 < self.lines.len) {
                // At end of line — consume one newline byte by merging with next line.
                try self.rawMergeLineWithNext();
                remaining -= 1; // the newline character
            } else {
                break;
            }
        }
    }

    /// Merge the next line into the current cursor line (no undo recording).
    fn rawMergeLineWithNext(self: *EditorState) Allocator.Error!void {
        const line_idx = self.cursor_line + 1;
        if (line_idx >= self.lines.len) return;

        const curr = self.lines[self.cursor_line];
        const next = self.lines[line_idx];

        const new_lines = try self.allocator.alloc([]u8, self.lines.len - 1);
        errdefer self.allocator.free(new_lines);

        const merged = try self.allocator.alloc(u8, curr.len + next.len);
        @memcpy(merged[0..curr.len], curr);
        @memcpy(merged[curr.len..], next);

        self.allocator.free(curr);
        self.allocator.free(next);

        @memcpy(new_lines[0..self.cursor_line], self.lines[0..self.cursor_line]);
        new_lines[self.cursor_line] = merged;
        if (line_idx < new_lines.len) {
            @memcpy(new_lines[line_idx..], self.lines[line_idx + 1 ..]);
        }
        self.allocator.free(self.lines);
        self.lines = new_lines;
        // cursor_col stays at current position (end of old curr line)
        self.is_dirty = true;
    }

    /// Undo the last edit. Returns true if an undo was performed.
    /// May return `Allocator.Error` if building the inverse entry fails (OOM).
    pub fn undo(self: *EditorState) Allocator.Error!bool {
        return self.applyUndoRedo(&self.undo_stack, &self.redo_stack, true);
    }

    /// Redo the last undone edit. Returns true if a redo was performed.
    /// May return `Allocator.Error` if building the inverse entry fails (OOM).
    pub fn redo(self: *EditorState) Allocator.Error!bool {
        return self.applyUndoRedo(&self.redo_stack, &self.undo_stack, false);
    }

    /// Shared implementation for undo and redo: pop from `from_stack`, apply the
    /// entry, restore cursor, and push the inverse onto `to_stack`.
    fn applyUndoRedo(
        self: *EditorState,
        from_stack: *std.ArrayList(UndoEntry),
        to_stack: *std.ArrayList(UndoEntry),
        comptime is_undo: bool,
    ) Allocator.Error!bool {
        if (from_stack.items.len == 0) return false;

        var entry = from_stack.pop().?;
        defer entry.deinit(self.allocator);

        const was_recording = self.recording_undo;
        self.recording_undo = false;
        defer self.recording_undo = was_recording;

        var inverse = try self.applyEntry(&entry, is_undo);
        errdefer inverse.deinit(self.allocator);

        const restore = if (is_undo) entry.cursor_before else entry.cursor_after;
        self.cursor_line = restore.line;
        self.cursor_col = restore.col;
        self.selection_anchor = null;

        try self.pushToStack(to_stack, inverse);
        return true;
    }

    // =========================================================================
    // Text mutation
    // =========================================================================

    /// Insert UTF-8 bytes at cursor position in the current line, advance cursor.
    pub fn insertBytes(self: *EditorState, bytes: []const u8) Allocator.Error!void {
        if (bytes.len == 0) return;
        if (self.cursor_line >= self.lines.len) return;

        const cursor_before = Position{ .line = self.cursor_line, .col = @min(self.cursor_col, self.lines[self.cursor_line].len) };
        const insert_pos = cursor_before;

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

        const cursor_after = Position{ .line = self.cursor_line, .col = self.cursor_col };
        try self.recordInsert(insert_pos, bytes, cursor_before, cursor_after);
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

        const cursor_before = Position{ .line = self.cursor_line, .col = @min(self.cursor_col, self.lines[self.cursor_line].len) };

        if (self.cursor_col > 0) {
            const line = self.lines[self.cursor_line];
            const col = @min(self.cursor_col, line.len);
            const char_len = charLenBefore(line, col);
            const start = col - char_len;

            // Capture the deleted text before mutation.
            const deleted_text = try self.allocator.dupe(u8, line[start..col]);
            errdefer self.allocator.free(deleted_text);

            const new_line = try self.allocator.alloc(u8, line.len - char_len);
            @memcpy(new_line[0..start], line[0..start]);
            @memcpy(new_line[start..], line[col..]);

            self.allocator.free(line);
            self.lines[self.cursor_line] = new_line;
            self.cursor_col = start;
            self.is_dirty = true;

            const cursor_after = Position{ .line = self.cursor_line, .col = self.cursor_col };
            const delete_pos = cursor_after; // text was at the new cursor position
            defer self.allocator.free(deleted_text);
            try self.recordDelete(delete_pos, deleted_text, cursor_before, cursor_after);
        } else if (self.cursor_line > 0) {
            // Merge with previous line — record a delete of the newline character.
            const prev_len = self.lines[self.cursor_line - 1].len;
            try self.mergeLineWithPrevious(self.cursor_line);
            const cursor_after = Position{ .line = self.cursor_line, .col = self.cursor_col };
            // The deleted character is a newline. Position is at the merge point.
            const delete_pos = Position{ .line = self.cursor_line, .col = prev_len };
            try self.recordDelete(delete_pos, "\n", cursor_before, cursor_after);
        }
    }

    /// Delete the UTF-8 character at the cursor (delete key).
    /// If at end of line, merges next line into current line.
    pub fn deleteCharAt(self: *EditorState) Allocator.Error!void {
        if (self.cursor_line >= self.lines.len) return;

        const cursor_before = Position{ .line = self.cursor_line, .col = @min(self.cursor_col, self.lines[self.cursor_line].len) };

        const line = self.lines[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        if (col < line.len) {
            const char_len = charLenAt(line, col);
            const deleted_text = try self.allocator.dupe(u8, line[col .. col + char_len]);
            errdefer self.allocator.free(deleted_text);

            const new_line = try self.allocator.alloc(u8, line.len - char_len);
            @memcpy(new_line[0..col], line[0..col]);
            @memcpy(new_line[col..], line[col + char_len ..]);

            self.allocator.free(line);
            self.lines[self.cursor_line] = new_line;
            self.is_dirty = true;

            const cursor_after = Position{ .line = self.cursor_line, .col = self.cursor_col };
            const delete_pos = cursor_after; // text was at current cursor position
            defer self.allocator.free(deleted_text);
            try self.recordDelete(delete_pos, deleted_text, cursor_before, cursor_after);
        } else if (self.cursor_line + 1 < self.lines.len) {
            // Merge next line into current — delete the newline.
            try self.mergeLineWithPrevious(self.cursor_line + 1);
            const cursor_after = Position{ .line = self.cursor_line, .col = self.cursor_col };
            const delete_pos = Position{ .line = self.cursor_line, .col = col };
            try self.recordDelete(delete_pos, "\n", cursor_before, cursor_after);
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

        const cursor_before = Position{ .line = self.cursor_line, .col = @min(self.cursor_col, self.lines[self.cursor_line].len) };
        const insert_pos = cursor_before;

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

        const cursor_after = Position{ .line = self.cursor_line, .col = self.cursor_col };
        try self.recordInsert(insert_pos, "\n", cursor_before, cursor_after);
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

    // =========================================================================
    // Scroll management
    // =========================================================================

    /// Apply a scroll delta (e.g. from mouse wheel) to the editor's vertical scroll offset.
    /// Clamps the result to [0, max_scroll] where max_scroll = total_height - viewport_height.
    pub fn applyScrollDelta(self: *EditorState, delta: f32, total_height: f32, viewport_height: f32) void {
        if (delta == 0 or viewport_height <= 0) return;
        self.scroll_y += delta;
        const max_scroll = @max(0, total_height - viewport_height);
        self.scroll_y = std.math.clamp(self.scroll_y, 0, max_scroll);
    }

    /// Ensure the cursor line is visible by adjusting scroll_y if needed.
    pub fn ensureCursorVisible(self: *EditorState, line_height: f32, viewport_height: f32) void {
        if (line_height <= 0 or viewport_height <= 0) return;

        const cursor_y = @as(f32, @floatFromInt(self.cursor_line)) * line_height;

        // Cursor is above visible area
        if (cursor_y < self.scroll_y) {
            self.scroll_y = cursor_y;
        }
        // Cursor is below visible area
        if (cursor_y + line_height > self.scroll_y + viewport_height) {
            self.scroll_y = cursor_y + line_height - viewport_height;
        }
        self.scroll_y = @max(0, self.scroll_y);
    }

    // =========================================================================
    // Selection
    // =========================================================================

    /// Returns true if there is an active selection (anchor differs from cursor).
    pub fn hasSelection(self: *const EditorState) bool {
        const anchor = self.selection_anchor orelse return false;
        return anchor.line != self.cursor_line or anchor.col != self.cursor_col;
    }

    /// Returns the ordered selection range (start <= end), or null if no selection.
    pub fn selectionRange(self: *const EditorState) ?SelectionRange {
        const anchor = self.selection_anchor orelse return null;
        if (anchor.line == self.cursor_line and anchor.col == self.cursor_col) return null;

        const a_before = anchor.line < self.cursor_line or
            (anchor.line == self.cursor_line and anchor.col < self.cursor_col);

        return if (a_before) .{
            .start_line = anchor.line,
            .start_col = anchor.col,
            .end_line = self.cursor_line,
            .end_col = self.cursor_col,
        } else .{
            .start_line = self.cursor_line,
            .start_col = self.cursor_col,
            .end_line = anchor.line,
            .end_col = anchor.col,
        };
    }

    /// Clear the selection anchor.
    pub fn clearSelection(self: *EditorState) void {
        self.selection_anchor = null;
    }

    /// Set the selection anchor to the current cursor position (if not already set).
    pub fn startSelection(self: *EditorState) void {
        if (self.selection_anchor == null) {
            self.selection_anchor = .{ .line = self.cursor_line, .col = self.cursor_col };
        }
    }

    /// Select all text: anchor at start, cursor at end.
    pub fn selectAll(self: *EditorState) void {
        self.selection_anchor = .{ .line = 0, .col = 0 };
        if (self.lines.len > 0) {
            self.cursor_line = self.lines.len - 1;
            self.cursor_col = self.lines[self.cursor_line].len;
        } else {
            self.cursor_line = 0;
            self.cursor_col = 0;
        }
    }

    /// Extract the selected text as a newly allocated string, or null if no selection.
    /// Caller owns the returned slice and must free it with `self.allocator`.
    pub fn selectedText(self: *const EditorState) Allocator.Error!?[]u8 {
        const range = self.selectionRange() orelse return null;

        if (range.start_line == range.end_line) {
            const line = self.lines[range.start_line];
            const start = @min(range.start_col, line.len);
            const end = @min(range.end_col, line.len);
            return try self.allocator.dupe(u8, line[start..end]);
        }

        // Multi-line: compute total length
        var total: usize = 0;
        for (range.start_line..range.end_line + 1) |i| {
            const line = self.lines[i];
            if (i == range.start_line) {
                total += line.len - @min(range.start_col, line.len);
            } else if (i == range.end_line) {
                total += @min(range.end_col, line.len);
            } else {
                total += line.len;
            }
            if (i < range.end_line) total += 1; // newline separator
        }

        const buf = try self.allocator.alloc(u8, total);
        var pos: usize = 0;
        for (range.start_line..range.end_line + 1) |i| {
            const line = self.lines[i];
            if (i == range.start_line) {
                const start = @min(range.start_col, line.len);
                const chunk = line[start..];
                @memcpy(buf[pos..][0..chunk.len], chunk);
                pos += chunk.len;
            } else if (i == range.end_line) {
                const end = @min(range.end_col, line.len);
                @memcpy(buf[pos..][0..end], line[0..end]);
                pos += end;
            } else {
                @memcpy(buf[pos..][0..line.len], line);
                pos += line.len;
            }
            if (i < range.end_line) {
                buf[pos] = '\n';
                pos += 1;
            }
        }

        return buf;
    }

    /// Delete the selected text. Cursor moves to start of selection.
    pub fn deleteSelection(self: *EditorState) Allocator.Error!void {
        const range = self.selectionRange() orelse return;

        const cursor_before = Position{ .line = self.cursor_line, .col = self.cursor_col };

        // Capture the selected text before deletion for undo.
        const selected = try self.selectedText();
        defer if (selected) |s| self.allocator.free(s);

        self.selection_anchor = null;

        if (range.start_line == range.end_line) {
            // Single-line deletion
            const line = self.lines[range.start_line];
            const start = @min(range.start_col, line.len);
            const end = @min(range.end_col, line.len);
            const new_line = try self.allocator.alloc(u8, line.len - (end - start));
            @memcpy(new_line[0..start], line[0..start]);
            @memcpy(new_line[start..], line[end..]);
            self.allocator.free(line);
            self.lines[range.start_line] = new_line;
            self.cursor_line = range.start_line;
            self.cursor_col = start;
            self.is_dirty = true;
        } else {
            // Multi-line deletion: merge first and last line fragments, remove middle lines.
            const first_line = self.lines[range.start_line];
            const last_line = self.lines[range.end_line];
            const keep_start = @min(range.start_col, first_line.len);
            const keep_end_start = @min(range.end_col, last_line.len);

            const lines_removed = range.end_line - range.start_line;
            const new_lines = try self.allocator.alloc([]u8, self.lines.len - lines_removed);
            errdefer self.allocator.free(new_lines);

            const merged = try self.allocator.alloc(u8, keep_start + (last_line.len - keep_end_start));
            @memcpy(merged[0..keep_start], first_line[0..keep_start]);
            @memcpy(merged[keep_start..], last_line[keep_end_start..]);

            for (range.start_line..range.end_line + 1) |i| {
                self.allocator.free(self.lines[i]);
            }

            @memcpy(new_lines[0..range.start_line], self.lines[0..range.start_line]);
            new_lines[range.start_line] = merged;
            if (range.end_line + 1 < self.lines.len) {
                @memcpy(new_lines[range.start_line + 1 ..], self.lines[range.end_line + 1 ..]);
            }
            self.allocator.free(self.lines);
            self.lines = new_lines;

            self.cursor_line = range.start_line;
            self.cursor_col = keep_start;
            self.is_dirty = true;
        }

        const cursor_after = Position{ .line = self.cursor_line, .col = self.cursor_col };
        const delete_pos = cursor_after;
        if (selected) |sel_text| {
            try self.recordDelete(delete_pos, sel_text, cursor_before, cursor_after);
        }
    }

    /// Replace the selected text with new content. If no selection, inserts at cursor.
    pub fn replaceSelection(self: *EditorState, text: []const u8) Allocator.Error!void {
        const has_sel = self.hasSelection();

        if (!has_sel) {
            // No selection — just insert. insertBytes/insertNewline record their own entries.
            var iter = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (iter.next()) |segment| {
                if (!first) {
                    try self.insertNewline();
                }
                if (segment.len > 0) {
                    try self.insertBytes(segment);
                }
                first = false;
            }
            return;
        }

        // Has selection — capture state, build compound undo entry.
        const cursor_before = Position{ .line = self.cursor_line, .col = self.cursor_col };
        const old_text = try self.selectedText();
        const old_text_val = old_text orelse "";
        defer if (old_text) |t| self.allocator.free(t);

        const range = self.selectionRange().?;
        const delete_pos = Position{ .line = range.start_line, .col = range.start_col };

        // Disable recording so sub-operations don't push individual entries.
        const was_recording = self.recording_undo;
        self.recording_undo = false;
        defer self.recording_undo = was_recording;

        // Perform the actual operations.
        try self.deleteSelection();
        var iter = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (iter.next()) |segment| {
            if (!first) {
                try self.insertNewline();
            }
            if (segment.len > 0) {
                try self.insertBytes(segment);
            }
            first = false;
        }

        const cursor_after = Position{ .line = self.cursor_line, .col = self.cursor_col };

        if (!was_recording) return;

        // Build compound undo entry with two sub-entries:
        // 1. An "insert" entry for the new text (undo = delete it)
        // 2. A "delete" entry for the old text (undo = re-insert it)
        // When undoing, sub-entries are applied in reverse order:
        //   first delete the new text, then re-insert the old text.
        var entries = try self.allocator.alloc(UndoEntry, 2);
        errdefer self.allocator.free(entries);

        const new_text_owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(new_text_owned);
        const old_text_owned = try self.allocator.dupe(u8, old_text_val);
        errdefer self.allocator.free(old_text_owned);

        entries[0] = .{
            .kind = .{ .delete = .{ .pos = delete_pos, .text = old_text_owned } },
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        };
        entries[1] = .{
            .kind = .{ .insert = .{ .pos = delete_pos, .text = new_text_owned } },
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        };

        self.clearRedoStack();
        try self.pushToStack(&self.undo_stack, .{
            .kind = .{ .compound = .{ .entries = entries } },
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
        });
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

// =========================================================================
// Scroll management tests
// =========================================================================

test "applyScrollDelta scrolls down and clamps" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.applyScrollDelta(50, 200, 100);
    try testing.expectEqual(@as(f32, 50), state.scroll_y);
}

test "applyScrollDelta clamps to max scroll" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.applyScrollDelta(500, 200, 100);
    // max_scroll = 200 - 100 = 100
    try testing.expectEqual(@as(f32, 100), state.scroll_y);
}

test "applyScrollDelta clamps to zero" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.scroll_y = 50;
    state.applyScrollDelta(-200, 200, 100);
    try testing.expectEqual(@as(f32, 0), state.scroll_y);
}

test "applyScrollDelta ignores zero delta" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.scroll_y = 30;
    state.applyScrollDelta(0, 200, 100);
    try testing.expectEqual(@as(f32, 30), state.scroll_y);
}

test "applyScrollDelta ignores non-positive viewport" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.scroll_y = 30;
    state.applyScrollDelta(10, 200, 0);
    try testing.expectEqual(@as(f32, 30), state.scroll_y);
}

test "ensureCursorVisible scrolls down when cursor is below viewport" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc\nd\ne");
    defer state.deinit();

    state.cursor_line = 4;
    state.ensureCursorVisible(20, 60);
    // cursor_y = 4 * 20 = 80, 80 + 20 = 100 > 0 + 60 → scroll_y = 100 - 60 = 40
    try testing.expectEqual(@as(f32, 40), state.scroll_y);
}

test "ensureCursorVisible scrolls up when cursor is above viewport" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc\nd\ne");
    defer state.deinit();

    state.scroll_y = 80;
    state.cursor_line = 1;
    state.ensureCursorVisible(20, 60);
    // cursor_y = 1 * 20 = 20 < 80 → scroll_y = 20
    try testing.expectEqual(@as(f32, 20), state.scroll_y);
}

test "ensureCursorVisible is no-op when cursor is visible" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc\nd\ne");
    defer state.deinit();

    state.scroll_y = 10;
    state.cursor_line = 1;
    state.ensureCursorVisible(20, 60);
    // cursor_y = 20, 20 >= 10 (not above), 20 + 20 = 40 <= 10 + 60 = 70 (not below)
    try testing.expectEqual(@as(f32, 10), state.scroll_y);
}

test "ensureCursorVisible ignores zero line_height" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.scroll_y = 30;
    state.ensureCursorVisible(0, 60);
    try testing.expectEqual(@as(f32, 30), state.scroll_y);
}

test "ensureCursorVisible ignores zero viewport_height" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.scroll_y = 30;
    state.ensureCursorVisible(20, 0);
    try testing.expectEqual(@as(f32, 30), state.scroll_y);
}

test "applyScrollDelta ignores negative viewport" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.scroll_y = 30;
    state.applyScrollDelta(10, 200, -50);
    try testing.expectEqual(@as(f32, 30), state.scroll_y);
}

test "applyScrollDelta clamps when content shorter than viewport" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    // total_height (50) < viewport_height (200) → max_scroll = 0
    state.applyScrollDelta(100, 50, 200);
    try testing.expectEqual(@as(f32, 0), state.scroll_y);
}

test "ensureCursorVisible ignores negative line_height" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.scroll_y = 30;
    state.ensureCursorVisible(-10, 60);
    try testing.expectEqual(@as(f32, 30), state.scroll_y);
}

test "ensureCursorVisible ignores negative viewport_height" {
    var state = try EditorState.initFromSource(testing.allocator, "a\nb\nc");
    defer state.deinit();

    state.scroll_y = 30;
    state.ensureCursorVisible(20, -100);
    try testing.expectEqual(@as(f32, 30), state.scroll_y);
}

// =========================================================================
// Selection tests
// =========================================================================

test "hasSelection returns false with no anchor" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    try testing.expect(!state.hasSelection());
}

test "hasSelection returns false when anchor equals cursor" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 0 };
    try testing.expect(!state.hasSelection());
}

test "hasSelection returns true when anchor differs from cursor" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 0 };
    state.cursor_col = 3;
    try testing.expect(state.hasSelection());
}

test "selectionRange orders anchor before cursor" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 0 };
    state.cursor_col = 3;
    const range = state.selectionRange().?;
    try testing.expectEqual(@as(usize, 0), range.start_col);
    try testing.expectEqual(@as(usize, 3), range.end_col);
}

test "selectionRange orders cursor before anchor" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 4 };
    state.cursor_col = 1;
    const range = state.selectionRange().?;
    try testing.expectEqual(@as(usize, 1), range.start_col);
    try testing.expectEqual(@as(usize, 4), range.end_col);
}

test "selectionRange multi-line ordering" {
    var state = try EditorState.initFromSource(testing.allocator, "aaa\nbbb\nccc");
    defer state.deinit();
    // Anchor on line 2, cursor on line 0
    state.selection_anchor = .{ .line = 2, .col = 1 };
    state.cursor_line = 0;
    state.cursor_col = 2;
    const range = state.selectionRange().?;
    try testing.expectEqual(@as(usize, 0), range.start_line);
    try testing.expectEqual(@as(usize, 2), range.start_col);
    try testing.expectEqual(@as(usize, 2), range.end_line);
    try testing.expectEqual(@as(usize, 1), range.end_col);
}

test "startSelection sets anchor only once" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    state.cursor_col = 2;
    state.startSelection();
    try testing.expectEqual(@as(usize, 2), state.selection_anchor.?.col);
    state.cursor_col = 4;
    state.startSelection(); // should not overwrite
    try testing.expectEqual(@as(usize, 2), state.selection_anchor.?.col);
}

test "clearSelection removes anchor" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 0 };
    state.clearSelection();
    try testing.expect(state.selection_anchor == null);
}

test "selectAll selects entire text" {
    var state = try EditorState.initFromSource(testing.allocator, "aaa\nbbb\nccc");
    defer state.deinit();
    state.selectAll();
    try testing.expectEqual(@as(usize, 0), state.selection_anchor.?.line);
    try testing.expectEqual(@as(usize, 0), state.selection_anchor.?.col);
    try testing.expectEqual(@as(usize, 2), state.cursor_line);
    try testing.expectEqual(@as(usize, 3), state.cursor_col);
}

test "selectedText single line" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 0 };
    state.cursor_col = 5;
    const text = (try state.selectedText()).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hello", text);
}

test "selectedText multi-line" {
    var state = try EditorState.initFromSource(testing.allocator, "aaa\nbbb\nccc");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 1 };
    state.cursor_line = 2;
    state.cursor_col = 2;
    const text = (try state.selectedText()).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("aa\nbbb\ncc", text);
}

test "selectedText returns null with no selection" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    const text = try state.selectedText();
    try testing.expect(text == null);
}

test "deleteSelection single line" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 5 };
    state.cursor_col = 11;
    try state.deleteSelection();
    try testing.expectEqualStrings("hello", state.lines[0]);
    try testing.expectEqual(@as(usize, 5), state.cursor_col);
    try testing.expect(state.is_dirty);
    try testing.expect(state.selection_anchor == null);
}

test "deleteSelection multi-line" {
    var state = try EditorState.initFromSource(testing.allocator, "aaa\nbbb\nccc\nddd");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 1 };
    state.cursor_line = 2;
    state.cursor_col = 2;
    try state.deleteSelection();
    try testing.expectEqual(@as(usize, 2), state.lines.len);
    try testing.expectEqualStrings("ac", state.lines[0]);
    try testing.expectEqualStrings("ddd", state.lines[1]);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 1), state.cursor_col);
}

test "deleteSelection entire content" {
    var state = try EditorState.initFromSource(testing.allocator, "aaa\nbbb");
    defer state.deinit();
    state.selectAll();
    try state.deleteSelection();
    try testing.expectEqual(@as(usize, 1), state.lines.len);
    try testing.expectEqualStrings("", state.lines[0]);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 0), state.cursor_col);
}

test "replaceSelection with text" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 5 };
    state.cursor_col = 11;
    try state.replaceSelection("!");
    try testing.expectEqualStrings("hello!", state.lines[0]);
}

test "replaceSelection with multi-line text" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 5 };
    state.cursor_col = 11;
    try state.replaceSelection(" big\nwide");
    try testing.expectEqual(@as(usize, 2), state.lines.len);
    try testing.expectEqualStrings("hello big", state.lines[0]);
    try testing.expectEqualStrings("wide", state.lines[1]);
}

test "replaceSelection without selection inserts at cursor" {
    var state = try EditorState.initFromSource(testing.allocator, "helloworld");
    defer state.deinit();
    state.cursor_col = 5;
    try state.replaceSelection(" ");
    try testing.expectEqualStrings("hello world", state.lines[0]);
}

test "selectionRange returns null when anchor equals cursor" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 0 };
    try testing.expect(state.selectionRange() == null);
}

test "selectAll on empty content selects nothing" {
    var state = try EditorState.initFromSource(testing.allocator, "");
    defer state.deinit();
    state.selectAll();
    // initFromSource("") produces one empty line, so anchor == cursor at (0,0)
    try testing.expect(!state.hasSelection());
}

test "deleteSelection with no selection is no-op" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();
    try state.deleteSelection();
    try testing.expectEqualStrings("hello", state.lines[0]);
    try testing.expect(!state.is_dirty);
}

test "replaceSelection cursor position after single-line replacement" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 5 };
    state.cursor_col = 11;
    try state.replaceSelection("!");
    try testing.expectEqualStrings("hello!", state.lines[0]);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 6), state.cursor_col);
}

test "replaceSelection cursor position after multi-line replacement" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 5 };
    state.cursor_col = 11;
    try state.replaceSelection(" big\nwide");
    try testing.expectEqual(@as(usize, 2), state.lines.len);
    try testing.expectEqualStrings("hello big", state.lines[0]);
    try testing.expectEqualStrings("wide", state.lines[1]);
    try testing.expectEqual(@as(usize, 1), state.cursor_line);
    try testing.expectEqual(@as(usize, 4), state.cursor_col);
}

test "replaceSelection multi-line selection with multi-line text" {
    var state = try EditorState.initFromSource(testing.allocator, "aaa\nbbb\nccc");
    defer state.deinit();
    state.selection_anchor = .{ .line = 0, .col = 1 };
    state.cursor_line = 2;
    state.cursor_col = 2;
    try state.replaceSelection("XX\nYY");
    try testing.expectEqual(@as(usize, 2), state.lines.len);
    try testing.expectEqualStrings("aXX", state.lines[0]);
    try testing.expectEqualStrings("YYc", state.lines[1]);
    try testing.expectEqual(@as(usize, 1), state.cursor_line);
    try testing.expectEqual(@as(usize, 2), state.cursor_col);
}

// =========================================================================
// Undo / Redo tests
// =========================================================================

test "undo of character insert" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 1);
    try state.insertChar('X');
    try testing.expectEqualStrings("aXbc", state.getLineText(0).?);

    const did_undo = try state.undo();
    try testing.expect(did_undo);
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 1), state.cursor_col);
}

test "undo of character delete (backspace)" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 2);
    try state.deleteCharBefore();
    try testing.expectEqualStrings("ac", state.getLineText(0).?);

    const did_undo = try state.undo();
    try testing.expect(did_undo);
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 2), state.cursor_col);
}

test "undo of delete-at (delete key)" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 1);
    try state.deleteCharAt();
    try testing.expectEqualStrings("ac", state.getLineText(0).?);

    const did_undo = try state.undo();
    try testing.expect(did_undo);
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 1), state.cursor_col);
}

test "undo of newline insertion" {
    var state = try EditorState.initFromSource(testing.allocator, "abcdef");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.insertNewline();
    try testing.expectEqual(@as(usize, 2), state.lineCount());
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqualStrings("def", state.getLineText(1).?);

    const did_undo = try state.undo();
    try testing.expect(did_undo);
    try testing.expectEqual(@as(usize, 1), state.lineCount());
    try testing.expectEqualStrings("abcdef", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 3), state.cursor_col);
}

test "undo of line merge (backspace at start of line)" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(1, 0);
    try state.deleteCharBefore();
    try testing.expectEqual(@as(usize, 1), state.lineCount());
    try testing.expectEqualStrings("abcdef", state.getLineText(0).?);

    const did_undo = try state.undo();
    try testing.expect(did_undo);
    try testing.expectEqual(@as(usize, 2), state.lineCount());
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqualStrings("def", state.getLineText(1).?);
    try testing.expectEqual(@as(usize, 1), state.cursor_line);
    try testing.expectEqual(@as(usize, 0), state.cursor_col);
}

test "redo after undo" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.insertChar('X');
    try testing.expectEqualStrings("abcX", state.getLineText(0).?);

    _ = try state.undo();
    try testing.expectEqualStrings("abc", state.getLineText(0).?);

    const did_redo = try state.redo();
    try testing.expect(did_redo);
    try testing.expectEqualStrings("abcX", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 4), state.cursor_col);
}

test "redo stack cleared on new edit after undo" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    try state.insertChar('X');
    _ = try state.undo();
    try testing.expectEqual(@as(usize, 1), state.redo_stack.items.len);

    // New edit should clear redo stack.
    try state.insertChar('Y');
    try testing.expectEqual(@as(usize, 0), state.redo_stack.items.len);

    const did_redo = try state.redo();
    try testing.expect(!did_redo);
}

test "multiple undo/redo in sequence" {
    var state = try EditorState.initFromSource(testing.allocator, "");
    defer state.deinit();

    // Type 'a', 'b', 'c' one by one (but break coalescing with newlines between).
    try state.insertChar('a');
    try state.insertNewline();
    try state.insertChar('b');

    // Now: "a\nb"
    try testing.expectEqual(@as(usize, 2), state.lineCount());
    try testing.expectEqualStrings("a", state.getLineText(0).?);
    try testing.expectEqualStrings("b", state.getLineText(1).?);

    // Undo 'b'
    _ = try state.undo();
    try testing.expectEqualStrings("", state.getLineText(1).?);

    // Undo newline
    _ = try state.undo();
    try testing.expectEqual(@as(usize, 1), state.lineCount());
    try testing.expectEqualStrings("a", state.getLineText(0).?);

    // Undo 'a'
    _ = try state.undo();
    try testing.expectEqualStrings("", state.getLineText(0).?);

    // Redo all three
    _ = try state.redo(); // 'a'
    try testing.expectEqualStrings("a", state.getLineText(0).?);
    _ = try state.redo(); // newline
    try testing.expectEqual(@as(usize, 2), state.lineCount());
    _ = try state.redo(); // 'b'
    try testing.expectEqualStrings("b", state.getLineText(1).?);
}

test "cursor position restored on undo/redo" {
    var state = try EditorState.initFromSource(testing.allocator, "hello");
    defer state.deinit();

    state.setCursor(0, 5);
    try state.insertChar('!');
    try testing.expectEqual(@as(usize, 6), state.cursor_col);

    _ = try state.undo();
    try testing.expectEqual(@as(usize, 5), state.cursor_col);

    _ = try state.redo();
    try testing.expectEqual(@as(usize, 6), state.cursor_col);
}

test "undo stack cap enforcement" {
    var state = try EditorState.initFromSource(testing.allocator, "x");
    defer state.deinit();

    // Fill the undo stack beyond capacity. Each insertChar at position 0
    // produces a single-char insert that would coalesce — to avoid that,
    // alternate with newline insertions.
    // Actually, simpler: insert at different positions by moving cursor.
    for (0..EditorState.max_undo_stack_size + 50) |_| {
        state.setCursor(0, 0);
        try state.insertNewline(); // each newline is a separate entry
    }

    // Stack should be capped.
    try testing.expect(state.undo_stack.items.len <= EditorState.max_undo_stack_size);
}

test "coalescing: multiple chars grouped into one undo" {
    var state = try EditorState.initFromSource(testing.allocator, "");
    defer state.deinit();

    // Type "hello" character by character — should coalesce into one entry.
    try state.insertChar('h');
    try state.insertChar('e');
    try state.insertChar('l');
    try state.insertChar('l');
    try state.insertChar('o');
    try testing.expectEqualStrings("hello", state.getLineText(0).?);

    // Should be a single undo entry.
    try testing.expectEqual(@as(usize, 1), state.undo_stack.items.len);

    _ = try state.undo();
    try testing.expectEqualStrings("", state.getLineText(0).?);
}

test "coalescing breaks on newline" {
    var state = try EditorState.initFromSource(testing.allocator, "");
    defer state.deinit();

    try state.insertChar('a');
    try state.insertChar('b');
    // These two should coalesce.
    const entries_before_newline = state.undo_stack.items.len;
    try testing.expectEqual(@as(usize, 1), entries_before_newline);

    try state.insertNewline();
    // Newline should be a separate entry.
    try testing.expectEqual(@as(usize, 2), state.undo_stack.items.len);

    try state.insertChar('c');
    // 'c' is on a new line, cannot coalesce with the newline entry.
    try testing.expectEqual(@as(usize, 3), state.undo_stack.items.len);
}

test "undo of selection delete" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();

    state.selection_anchor = .{ .line = 0, .col = 5 };
    state.cursor_col = 11;
    try state.deleteSelection();
    try testing.expectEqualStrings("hello", state.getLineText(0).?);

    _ = try state.undo();
    try testing.expectEqualStrings("hello world", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 11), state.cursor_col);
}

test "compound undo of replaceSelection" {
    var state = try EditorState.initFromSource(testing.allocator, "hello world");
    defer state.deinit();

    state.selection_anchor = .{ .line = 0, .col = 6 };
    state.cursor_col = 11;
    try state.replaceSelection("zig");
    try testing.expectEqualStrings("hello zig", state.getLineText(0).?);

    _ = try state.undo();
    try testing.expectEqualStrings("hello world", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 11), state.cursor_col);

    _ = try state.redo();
    try testing.expectEqualStrings("hello zig", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 9), state.cursor_col);
}

test "undo returns false when stack is empty" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    const did_undo = try state.undo();
    try testing.expect(!did_undo);
}

test "redo returns false when stack is empty" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    const did_redo = try state.redo();
    try testing.expect(!did_redo);
}

test "undo of delete key at end of line (line merge)" {
    var state = try EditorState.initFromSource(testing.allocator, "abc\ndef");
    defer state.deinit();

    state.setCursor(0, 3);
    try state.deleteCharAt();
    try testing.expectEqual(@as(usize, 1), state.lineCount());
    try testing.expectEqualStrings("abcdef", state.getLineText(0).?);

    _ = try state.undo();
    try testing.expectEqual(@as(usize, 2), state.lineCount());
    try testing.expectEqualStrings("abc", state.getLineText(0).?);
    try testing.expectEqualStrings("def", state.getLineText(1).?);
    try testing.expectEqual(@as(usize, 0), state.cursor_line);
    try testing.expectEqual(@as(usize, 3), state.cursor_col);
}

test "undo of multi-line selection delete" {
    var state = try EditorState.initFromSource(testing.allocator, "aaa\nbbb\nccc");
    defer state.deinit();

    state.selection_anchor = .{ .line = 0, .col = 1 };
    state.cursor_line = 2;
    state.cursor_col = 2;
    try state.deleteSelection();
    try testing.expectEqual(@as(usize, 1), state.lines.len);
    try testing.expectEqualStrings("ac", state.lines[0]);

    _ = try state.undo();
    try testing.expectEqual(@as(usize, 3), state.lines.len);
    try testing.expectEqualStrings("aaa", state.lines[0]);
    try testing.expectEqualStrings("bbb", state.lines[1]);
    try testing.expectEqualStrings("ccc", state.lines[2]);
    try testing.expectEqual(@as(usize, 2), state.cursor_line);
    try testing.expectEqual(@as(usize, 2), state.cursor_col);
}

test "coalescing breaks when cursor moves between inserts" {
    var state = try EditorState.initFromSource(testing.allocator, "abc");
    defer state.deinit();

    state.setCursor(0, 1);
    try state.insertChar('X'); // "aXbc"
    state.setCursor(0, 4);
    try state.insertChar('Y'); // "aXbcY" — not adjacent to 'X'

    // Should be two separate undo entries since positions are non-adjacent.
    try testing.expectEqual(@as(usize, 2), state.undo_stack.items.len);
}

test "undo of insertBytes (multi-char paste)" {
    var state = try EditorState.initFromSource(testing.allocator, "ac");
    defer state.deinit();

    state.setCursor(0, 1);
    try state.insertBytes("XYZ");
    try testing.expectEqualStrings("aXYZc", state.getLineText(0).?);

    _ = try state.undo();
    try testing.expectEqualStrings("ac", state.getLineText(0).?);
    try testing.expectEqual(@as(usize, 1), state.cursor_col);
}

test "compound undo of replaceSelection with multi-line text" {
    var state = try EditorState.initFromSource(testing.allocator, "aaa\nbbb\nccc");
    defer state.deinit();

    state.selection_anchor = .{ .line = 0, .col = 1 };
    state.cursor_line = 2;
    state.cursor_col = 2;
    try state.replaceSelection("XX\nYY");
    try testing.expectEqual(@as(usize, 2), state.lines.len);
    try testing.expectEqualStrings("aXX", state.lines[0]);
    try testing.expectEqualStrings("YYc", state.lines[1]);

    _ = try state.undo();
    try testing.expectEqual(@as(usize, 3), state.lines.len);
    try testing.expectEqualStrings("aaa", state.lines[0]);
    try testing.expectEqualStrings("bbb", state.lines[1]);
    try testing.expectEqualStrings("ccc", state.lines[2]);

    _ = try state.redo();
    try testing.expectEqual(@as(usize, 2), state.lines.len);
    try testing.expectEqualStrings("aXX", state.lines[0]);
    try testing.expectEqualStrings("YYc", state.lines[1]);
}
