const std = @import("std");
const rl = @import("raylib");

pub const ScrollState = struct {
    y: f32 = 0,
    total_height: f32 = 0,
    viewport_height: f32 = 0,
    scroll_speed: f32 = 40,

    /// Timestamp (seconds) of last `g` press for `gg` chord detection.
    /// null means no `g` press is pending.
    g_press_time: ?f64 = null,

    /// Accumulated numeric prefix for vim motions (e.g., `5j` scrolls 5 steps).
    /// Zero means no prefix has been entered.
    pending_count: u32 = 0,

    /// Maximum digit accumulation threshold; values are clamped to this ceiling.
    const max_count: u32 = 9999;

    /// Maximum seconds between two `g` presses to register as `gg`.
    const gg_timeout: f64 = 0.5;
    /// Fraction of viewport height for Page Up/Down.
    const page_scroll_fraction: f32 = 0.9;
    /// Fraction of viewport height for half-page scroll (d/u).
    const half_page_fraction: f32 = 0.5;

    /// Return true on initial press AND on OS auto-repeat while held.
    /// raylib's `isKeyPressed` fires once on keydown; `isKeyPressedRepeat` fires
    /// only on OS repeat events. Combining both gives tap + hold behavior.
    fn isKeyPressedOrRepeat(key: rl.KeyboardKey) bool {
        return rl.isKeyPressed(key) or rl.isKeyPressedRepeat(key);
    }

    /// Process only mouse wheel input (used when search bar consumes keyboard).
    pub fn handleMouseWheel(self: *ScrollState) void {
        self.viewport_height = @floatFromInt(rl.getScreenHeight());
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) self.scrollBy(-wheel * self.scroll_speed);
    }

    /// Process input events and update scroll position.
    pub fn update(self: *ScrollState) void {
        self.viewport_height = @floatFromInt(rl.getScreenHeight());
        const now = rl.getTime();

        // Mouse wheel
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) self.scrollBy(-wheel * self.scroll_speed);

        // Modifier state — used to suppress vim keys and digit accumulation
        // when Ctrl/Shift are held (avoids conflicts with app shortcuts).
        const ctrl_held = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        const shift_held = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);

        // Accumulate numeric prefix digits from the character input queue.
        if (!ctrl_held and !shift_held) {
            self.consumeDigitChars();
        }

        const count = self.consumeCount();

        // Page Up / Page Down / Home / End (repeat on hold)
        if (isKeyPressedOrRepeat(.page_down)) self.scrollBy(self.viewport_height * page_scroll_fraction * count);
        if (isKeyPressedOrRepeat(.page_up)) self.scrollBy(-self.viewport_height * page_scroll_fraction * count);
        if (isKeyPressedOrRepeat(.home)) self.y = 0;
        if (isKeyPressedOrRepeat(.end)) self.y = self.maxScroll();

        if (!ctrl_held and !shift_held) {
            // j/k — step scroll (repeat on hold)
            if (isKeyPressedOrRepeat(.j)) self.scrollBy(self.scroll_speed * count);
            if (isKeyPressedOrRepeat(.k)) self.scrollBy(-self.scroll_speed * count);

            // d/u — half-page scroll (repeat on hold)
            if (isKeyPressedOrRepeat(.d)) self.scrollBy(self.viewport_height * half_page_fraction * count);
            if (isKeyPressedOrRepeat(.u)) self.scrollBy(-self.viewport_height * half_page_fraction * count);
        }

        // Ctrl+D / Ctrl+U — half-page scroll (standard vim modifier variant, repeat on hold)
        if (ctrl_held) {
            if (isKeyPressedOrRepeat(.d)) self.scrollBy(self.viewport_height * half_page_fraction * count);
            if (isKeyPressedOrRepeat(.u)) self.scrollBy(-self.viewport_height * half_page_fraction * count);
        }

        // Expire stale g press before processing new g input
        self.expireGChord(now);

        // Vim: G (Shift+g) — jump to bottom, gg — jump to top
        if (rl.isKeyPressed(.g)) {
            self.handleGPress(shift_held, now);
        }
    }

    /// Drain the character input queue, accumulating digit characters into pending_count.
    /// WARNING: This consumes ALL characters from `getCharPressed()`, including non-digits.
    /// It must be called before any other code that relies on the character queue in
    /// the same frame. Currently, when search is closed, no other code reads the
    /// character queue — vim motions and app shortcuts use `isKeyPressed` (key state).
    fn consumeDigitChars(self: *ScrollState) void {
        while (true) {
            const char = rl.getCharPressed();
            if (char == 0) break;
            if (char > 0) self.accumulateDigit(@intCast(char));
        }
    }

    /// Accumulate a single character into pending_count if it is a digit ('0'-'9').
    /// Non-digit characters are ignored.
    fn accumulateDigit(self: *ScrollState, char: u21) void {
        if (char >= '0' and char <= '9') {
            const digit: u32 = @intCast(char - '0');
            self.pending_count = @min(self.pending_count *| 10 +| digit, max_count);
        }
    }

    /// Return the pending count as a float multiplier (minimum 1).
    /// Resets `pending_count` only if a motion key is pressed this frame;
    /// otherwise preserves it for the next frame.
    fn consumeCount(self: *ScrollState) f32 {
        if (self.pending_count == 0) return 1;
        if (!hasMotionKey()) return 1;
        const count = self.pending_count;
        self.pending_count = 0;
        return @floatFromInt(count);
    }

    /// Check if any count-consuming motion key is pressed this frame.
    /// raylib's `isKeyPressed`/`isKeyPressedRepeat` return state without consuming it.
    /// Must match the motion keys in `update()` that use the `count` multiplier.
    /// Home/End are excluded since count has no meaning for absolute jumps.
    fn hasMotionKey() bool {
        return isKeyPressedOrRepeat(.j) or isKeyPressedOrRepeat(.k) or
            isKeyPressedOrRepeat(.d) or isKeyPressedOrRepeat(.u) or
            rl.isKeyPressed(.g) or
            isKeyPressedOrRepeat(.page_down) or isKeyPressedOrRepeat(.page_up);
    }

    /// Apply a relative scroll delta and clamp to valid range.
    fn scrollBy(self: *ScrollState, delta: f32) void {
        self.y += delta;
        self.clamp();
    }

    /// Expire a stale `g` press if it has exceeded the chord timeout.
    fn expireGChord(self: *ScrollState, now: f64) void {
        if (self.g_press_time) |prev_time| {
            if (now - prev_time > gg_timeout) {
                self.g_press_time = null;
            }
        }
    }

    /// Handle a `g` key press: Shift+G jumps to bottom, gg chord jumps to top.
    /// Called after `expireGChord`, so any non-null `g_press_time` is within the
    /// timeout window.
    fn handleGPress(self: *ScrollState, shift_held: bool, now: f64) void {
        if (shift_held) {
            self.y = self.maxScroll();
            self.g_press_time = null;
            return;
        }

        // Plain g — complete gg chord or start a new one
        if (self.g_press_time != null) {
            // Second g within timeout — jump to top
            self.y = 0;
            self.g_press_time = null;
        } else {
            self.g_press_time = now;
        }
    }

    /// Compute the maximum valid scroll offset for the current content and viewport.
    pub fn maxScroll(self: ScrollState) f32 {
        return maxScrollForHeight(self.total_height, self.viewport_height);
    }

    /// Pure math: compute maximum scroll given content height and viewport height.
    pub fn maxScrollForHeight(total_height: f32, screen_height: f32) f32 {
        return @max(0, total_height - screen_height);
    }

    /// Clamp scroll position to the valid range [0, maxScroll].
    pub fn clamp(self: *ScrollState) void {
        self.y = @max(0, @min(self.y, self.maxScroll()));
    }

    /// Pure math: clamp a scroll value to valid range.
    pub fn clampValue(scroll_y: f32, total_height: f32, screen_height: f32) f32 {
        const max = maxScrollForHeight(total_height, screen_height);
        return @max(0, @min(scroll_y, max));
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "maxScrollForHeight with content taller than screen" {
    try testing.expectEqual(@as(f32, 500), ScrollState.maxScrollForHeight(1000, 500));
}

test "maxScrollForHeight with content shorter than screen" {
    try testing.expectEqual(@as(f32, 0), ScrollState.maxScrollForHeight(300, 500));
}

test "maxScrollForHeight with equal content and screen" {
    try testing.expectEqual(@as(f32, 0), ScrollState.maxScrollForHeight(500, 500));
}

test "maxScrollForHeight with zero content" {
    try testing.expectEqual(@as(f32, 0), ScrollState.maxScrollForHeight(0, 500));
}

test "clampValue clamps negative scroll to zero" {
    try testing.expectEqual(@as(f32, 0), ScrollState.clampValue(-100, 1000, 500));
}

test "clampValue clamps overshoot to max" {
    // max scroll = 1000 - 500 = 500
    try testing.expectEqual(@as(f32, 500), ScrollState.clampValue(999, 1000, 500));
}

test "clampValue keeps valid scroll unchanged" {
    try testing.expectEqual(@as(f32, 250), ScrollState.clampValue(250, 1000, 500));
}

test "clampValue with content shorter than screen clamps to zero" {
    try testing.expectEqual(@as(f32, 0), ScrollState.clampValue(100, 300, 500));
}

test "ScrollState default initialization" {
    const scroll = ScrollState{};
    try testing.expectEqual(@as(f32, 0), scroll.y);
    try testing.expectEqual(@as(f32, 0), scroll.total_height);
    try testing.expectEqual(@as(f32, 0), scroll.viewport_height);
    try testing.expectEqual(@as(f32, 40), scroll.scroll_speed);
    try testing.expectEqual(@as(?f64, null), scroll.g_press_time);
    try testing.expectEqual(@as(u32, 0), scroll.pending_count);
}

test "scrollBy with half_page_fraction scrolls half viewport" {
    var s = ScrollState{ .total_height = 2000, .viewport_height = 600 };
    s.scrollBy(s.viewport_height * ScrollState.half_page_fraction);
    try testing.expectEqual(@as(f32, 300), s.y);
}

test "scrollBy with page_scroll_fraction scrolls most of viewport" {
    var s = ScrollState{ .total_height = 2000, .viewport_height = 600 };
    s.scrollBy(s.viewport_height * ScrollState.page_scroll_fraction);
    try testing.expectEqual(@as(f32, 540), s.y);
}

test "scrollBy positive delta scrolls down and clamps" {
    var s = ScrollState{ .total_height = 1000, .viewport_height = 500 };
    s.scrollBy(100);
    try testing.expectEqual(@as(f32, 100), s.y);
}

test "scrollBy negative delta scrolls up and clamps to zero" {
    var s = ScrollState{ .total_height = 1000, .viewport_height = 500, .y = 50 };
    s.scrollBy(-200);
    try testing.expectEqual(@as(f32, 0), s.y);
}

test "scrollBy clamps to max scroll" {
    var s = ScrollState{ .total_height = 1000, .viewport_height = 500, .y = 400 };
    s.scrollBy(200);
    // max scroll = 1000 - 500 = 500
    try testing.expectEqual(@as(f32, 500), s.y);
}

test "expireGChord clears stale g press" {
    var s = ScrollState{};
    s.g_press_time = 1.0;
    s.expireGChord(1.6); // 0.6s > 0.5s timeout
    try testing.expectEqual(@as(?f64, null), s.g_press_time);
}

test "expireGChord keeps fresh g press" {
    var s = ScrollState{};
    s.g_press_time = 1.0;
    s.expireGChord(1.3); // 0.3s <= 0.5s timeout
    try testing.expectEqual(@as(?f64, 1.0), s.g_press_time);
}

test "expireGChord at exact boundary keeps g press" {
    var s = ScrollState{};
    s.g_press_time = 1.0;
    s.expireGChord(1.5); // exactly 0.5s == gg_timeout, uses > not >=
    try testing.expectEqual(@as(?f64, 1.0), s.g_press_time);
}

test "expireGChord is no-op when no g press pending" {
    var s = ScrollState{};
    s.expireGChord(5.0);
    try testing.expectEqual(@as(?f64, null), s.g_press_time);
}

test "handleGPress with shift jumps to bottom" {
    var s = ScrollState{ .total_height = 1000, .viewport_height = 500, .y = 100 };
    s.handleGPress(true, 1.0);
    try testing.expectEqual(@as(f32, 500), s.y);
    try testing.expectEqual(@as(?f64, null), s.g_press_time);
}

test "handleGPress with shift clears pending g chord" {
    var s = ScrollState{ .total_height = 1000, .viewport_height = 500 };
    s.g_press_time = 0.5;
    s.handleGPress(true, 1.0);
    try testing.expectEqual(@as(?f64, null), s.g_press_time);
}

test "handleGPress first plain g starts chord" {
    var s = ScrollState{};
    s.handleGPress(false, 2.0);
    try testing.expectEqual(@as(?f64, 2.0), s.g_press_time);
}

test "handleGPress second plain g within timeout jumps to top" {
    var s = ScrollState{ .total_height = 1000, .viewport_height = 500, .y = 300 };
    s.g_press_time = 1.8; // first g at 1.8s
    s.handleGPress(false, 2.1); // second g at 2.1s (0.3s < 0.5s timeout)
    try testing.expectEqual(@as(f32, 0), s.y);
    try testing.expectEqual(@as(?f64, null), s.g_press_time);
}

test "handleGPress second plain g after expired timeout starts new chord" {
    // Simulate: expireGChord already cleared g_press_time
    var s = ScrollState{ .total_height = 1000, .viewport_height = 500, .y = 300 };
    s.g_press_time = null; // expired by expireGChord
    s.handleGPress(false, 2.0);
    // Should start a new chord, not jump
    try testing.expectEqual(@as(f32, 300), s.y);
    try testing.expectEqual(@as(?f64, 2.0), s.g_press_time);
}

// =============================================================================
// Numeric prefix tests
// =============================================================================

test "accumulateDigit accumulates digits" {
    var s = ScrollState{};
    s.accumulateDigit('1');
    try testing.expectEqual(@as(u32, 1), s.pending_count);
    s.accumulateDigit('2');
    try testing.expectEqual(@as(u32, 12), s.pending_count);
}

test "accumulateDigit ignores non-digit characters" {
    var s = ScrollState{};
    s.accumulateDigit('a');
    s.accumulateDigit('/');
    s.accumulateDigit('g');
    try testing.expectEqual(@as(u32, 0), s.pending_count);
}

test "accumulateDigit leading zero leaves pending_count at zero" {
    var s = ScrollState{};
    s.accumulateDigit('0');
    try testing.expectEqual(@as(u32, 0), s.pending_count);
}

test "accumulateDigit leading zero then digit gives digit value" {
    var s = ScrollState{};
    s.accumulateDigit('0');
    s.accumulateDigit('3');
    try testing.expectEqual(@as(u32, 3), s.pending_count);
}

test "accumulateDigit clamps to max_count" {
    var s = ScrollState{};
    s.pending_count = ScrollState.max_count;
    s.accumulateDigit('5');
    try testing.expectEqual(ScrollState.max_count, s.pending_count);
}

test "scrollBy with multiplied delta" {
    var s = ScrollState{ .total_height = 10000, .viewport_height = 500 };
    // 5 * scroll_speed(40) = 200
    const count: f32 = 5;
    s.scrollBy(s.scroll_speed * count);
    try testing.expectEqual(@as(f32, 200), s.y);
}

test "scrollBy with multiplied half-page delta" {
    var s = ScrollState{ .total_height = 10000, .viewport_height = 600 };
    // 3 * half_page(300) = 900
    const count: f32 = 3;
    s.scrollBy(s.viewport_height * ScrollState.half_page_fraction * count);
    try testing.expectEqual(@as(f32, 900), s.y);
}

test "scrollBy with large multiplier clamps to max scroll" {
    var s = ScrollState{ .total_height = 1000, .viewport_height = 500 };
    const count: f32 = 100;
    s.scrollBy(s.scroll_speed * count);
    try testing.expectEqual(@as(f32, 500), s.y);
}
