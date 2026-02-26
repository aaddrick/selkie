const rl = @import("raylib");

pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,

    pub fn init() Viewport {
        return .{
            .width = @floatFromInt(rl.getScreenWidth()),
            .height = @floatFromInt(rl.getScreenHeight()),
        };
    }

    pub fn updateSize(self: *Viewport) bool {
        const new_w: f32 = @floatFromInt(rl.getScreenWidth());
        const new_h: f32 = @floatFromInt(rl.getScreenHeight());
        if (new_w != self.width or new_h != self.height) {
            self.width = new_w;
            self.height = new_h;
            return true; // size changed, need re-layout
        }
        return false;
    }
};
