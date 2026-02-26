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
        return @max(0, self.total_height - screen_h);
    }

    pub fn clamp(self: *ScrollState) void {
        self.y = @max(0, @min(self.y, self.maxScroll()));
    }
};
