const std = @import("std");
const rl = @import("raylib");

pub const ScrollState = struct {
    y: f32 = 0,
    total_height: f32 = 0,
    scroll_speed: f32 = 40,

    pub fn update(self: *ScrollState) void {
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            self.y -= wheel * self.scroll_speed;
            self.clamp();
        }

        // Page Up / Page Down
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        if (rl.isKeyPressed(.page_down)) {
            self.y += screen_h * 0.9;
            self.clamp();
        }
        if (rl.isKeyPressed(.page_up)) {
            self.y -= screen_h * 0.9;
            self.clamp();
        }
        if (rl.isKeyPressed(.home)) {
            self.y = 0;
        }
        if (rl.isKeyPressed(.end)) {
            self.y = self.maxScroll();
        }
    }

    fn maxScroll(self: ScrollState) f32 {
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        return maxScrollForHeight(self.total_height, screen_h);
    }

    /// Pure math: compute maximum scroll given content height and viewport height.
    pub fn maxScrollForHeight(total_height: f32, screen_height: f32) f32 {
        return @max(0, total_height - screen_height);
    }

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
    try testing.expectEqual(@as(f32, 40), scroll.scroll_speed);
}
