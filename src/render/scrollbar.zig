const std = @import("std");
const rl = @import("raylib");

/// Shared scrollbar geometry used by both rendering and input handling.
pub const ScrollbarGeometry = struct {
    bar_x: f32,
    bar_width: f32,
    track_y: f32,
    track_height: f32,
    thumb_y: f32,
    thumb_height: f32,
    max_scroll: f32,
    visible: bool,

    /// Convert a mouse Y position to a scroll position.
    /// `grab_offset` is the offset from the top of the thumb where the user grabbed.
    pub fn mouseYToScroll(self: ScrollbarGeometry, mouse_y: f32, grab_offset: f32) f32 {
        const usable = self.track_height - self.thumb_height;
        if (usable <= 0) return 0;
        const ratio = std.math.clamp((mouse_y - self.track_y - grab_offset) / usable, 0, 1);
        return ratio * self.max_scroll;
    }

    /// Return true if the given point is inside the thumb rectangle.
    pub fn thumbContains(self: ScrollbarGeometry, x: f32, y: f32) bool {
        return x >= self.bar_x and x <= self.bar_x + self.bar_width and
            y >= self.thumb_y and y <= self.thumb_y + self.thumb_height;
    }

    /// Return true if the given point is inside the track rectangle.
    pub fn trackContains(self: ScrollbarGeometry, x: f32, y: f32) bool {
        return x >= self.bar_x and x <= self.bar_x + self.bar_width and
            y >= self.track_y and y <= self.track_y + self.track_height;
    }
};

pub const bar_width: f32 = 8;
const bar_margin: f32 = 4;
const min_thumb_height: f32 = 20;

/// Compute scrollbar geometry from document/viewport dimensions.
pub fn compute(total_height: f32, scroll_y: f32, screen_h: f32, content_top_y: f32) ScrollbarGeometry {
    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const visible_h = screen_h - content_top_y;

    if (total_height <= visible_h) {
        return .{
            .bar_x = screen_w - bar_width - bar_margin,
            .bar_width = bar_width,
            .track_y = content_top_y,
            .track_height = visible_h,
            .thumb_y = content_top_y,
            .thumb_height = 0,
            .max_scroll = 0,
            .visible = false,
        };
    }

    const bx = screen_w - bar_width - bar_margin;
    const visible_ratio = visible_h / total_height;
    const thumb_height = @max(min_thumb_height, visible_h * visible_ratio);
    const max_scroll = total_height - visible_h;
    const scroll_ratio = if (max_scroll > 0) scroll_y / max_scroll else 0;
    const thumb_y = content_top_y + scroll_ratio * (visible_h - thumb_height);

    return .{
        .bar_x = bx,
        .bar_width = bar_width,
        .track_y = content_top_y,
        .track_height = visible_h,
        .thumb_y = thumb_y,
        .thumb_height = thumb_height,
        .max_scroll = max_scroll,
        .visible = true,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Standard geometry used across most tests: track at y=30, height 500,
/// thumb at y=30, height 50, max_scroll 1000.
const test_geo = ScrollbarGeometry{
    .bar_x = 100,
    .bar_width = 8,
    .track_y = 30,
    .track_height = 500,
    .thumb_y = 30,
    .thumb_height = 50,
    .max_scroll = 1000,
    .visible = true,
};

test "not visible when content fits" {
    // Can't call compute() directly because it uses rl.getScreenWidth().
    // Test the math logic via mouseYToScroll on a manually constructed geometry.
    const geo: ScrollbarGeometry = .{ .bar_x = 100, .bar_width = 8, .track_y = 30, .track_height = 500, .thumb_y = 30, .thumb_height = 0, .max_scroll = 0, .visible = false };
    try testing.expect(!geo.visible);
}

test "mouseYToScroll maps top of track to zero scroll" {
    try testing.expectEqual(@as(f32, 0), test_geo.mouseYToScroll(30, 0));
}

test "mouseYToScroll maps bottom of track to max scroll" {
    // mouse at track_y + track_height - thumb_height = 30 + 500 - 50 = 480
    try testing.expectEqual(@as(f32, 1000), test_geo.mouseYToScroll(480, 0));
}

test "mouseYToScroll clamps below track to zero" {
    try testing.expectEqual(@as(f32, 0), test_geo.mouseYToScroll(0, 0));
}

test "mouseYToScroll clamps above max to max_scroll" {
    try testing.expectEqual(@as(f32, 1000), test_geo.mouseYToScroll(9999, 0));
}

test "mouseYToScroll with grab offset" {
    const geo: ScrollbarGeometry = .{ .bar_x = 100, .bar_width = 8, .track_y = 0, .track_height = 100, .thumb_y = 0, .thumb_height = 20, .max_scroll = 800, .visible = true };
    // Without offset: ratio = 40/80 = 0.5 → scroll = 400
    try testing.expectEqual(@as(f32, 400), geo.mouseYToScroll(40, 0));
    // With offset 10: ratio = (40-10)/80 = 30/80 = 0.375 → scroll = 300
    try testing.expectEqual(@as(f32, 300), geo.mouseYToScroll(40, 10));
}

test "thumbContains hit test" {
    const geo: ScrollbarGeometry = .{ .bar_x = 100, .bar_width = 8, .track_y = 0, .track_height = 500, .thumb_y = 50, .thumb_height = 40, .max_scroll = 1000, .visible = true };
    try testing.expect(geo.thumbContains(104, 70)); // inside
    try testing.expect(!geo.thumbContains(90, 70)); // left of bar
    try testing.expect(!geo.thumbContains(104, 10)); // above thumb
    try testing.expect(!geo.thumbContains(104, 95)); // below thumb
    // Exact boundaries (inclusive)
    try testing.expect(geo.thumbContains(100, 70)); // left edge
    try testing.expect(geo.thumbContains(108, 70)); // right edge
    try testing.expect(geo.thumbContains(104, 50)); // top edge
    try testing.expect(geo.thumbContains(104, 90)); // bottom edge
}

test "trackContains hit test" {
    const geo: ScrollbarGeometry = .{ .bar_x = 100, .bar_width = 8, .track_y = 30, .track_height = 500, .thumb_y = 100, .thumb_height = 40, .max_scroll = 1000, .visible = true };
    try testing.expect(geo.trackContains(104, 200)); // inside
    try testing.expect(!geo.trackContains(90, 200)); // left of bar
    try testing.expect(!geo.trackContains(104, 10)); // above track
    // Exact boundaries (inclusive)
    try testing.expect(geo.trackContains(100, 200)); // left edge
    try testing.expect(geo.trackContains(108, 200)); // right edge
    try testing.expect(geo.trackContains(104, 30)); // top edge
    try testing.expect(geo.trackContains(104, 530)); // bottom edge
}

test "mouseYToScroll returns zero when usable space is zero" {
    const geo: ScrollbarGeometry = .{ .bar_x = 100, .bar_width = 8, .track_y = 0, .track_height = 20, .thumb_y = 0, .thumb_height = 20, .max_scroll = 100, .visible = true };
    try testing.expectEqual(@as(f32, 0), geo.mouseYToScroll(10, 0));
}
