const std = @import("std");
const rl = @import("raylib");

/// Split-pane layout system that divides the window into left (editor) and
/// right (preview) panes with a configurable split ratio and visible divider.
///
/// No allocations — pure value type that computes pane geometry from the
/// available content area each frame.
pub const SplitPane = struct {
    /// Visual width of the divider bar in pixels.
    pub const divider_width: f32 = 4;
    /// Minimum pane width as a fraction of the available area.
    const min_ratio: f32 = 0.15;
    /// Maximum pane width as a fraction of the available area.
    const max_ratio: f32 = 0.85;
    /// Hit-test padding on each side of the divider for easier grabbing.
    const drag_hit_padding: f32 = 4;
    /// Default split ratio (50/50).
    const default_ratio: f32 = 0.5;

    /// Fraction of the available width assigned to the left (editor) pane.
    /// Range: [min_ratio, max_ratio].
    ratio: f32,

    /// Whether split-pane mode is active. When false, the full area is used
    /// for whichever single mode (editor or render) is active.
    is_active: bool,

    /// True while the user is dragging the divider.
    is_dragging: bool,

    /// Divider color (cached from theme or set explicitly).
    divider_color: rl.Color,

    /// Divider hover/drag highlight color.
    divider_hover_color: rl.Color,

    pub fn init() SplitPane {
        return .{
            .ratio = default_ratio,
            .is_active = false,
            .is_dragging = false,
            .divider_color = .{ .r = 60, .g = 60, .b = 60, .a = 255 },
            .divider_hover_color = .{ .r = 100, .g = 140, .b = 200, .a = 255 },
        };
    }

    /// Toggle split-pane mode on/off.
    pub fn toggle(self: *SplitPane) void {
        self.is_active = !self.is_active;
        if (!self.is_active) {
            self.is_dragging = false;
        }
    }

    /// Reset the split ratio to the default 50/50.
    pub fn resetRatio(self: *SplitPane) void {
        self.ratio = default_ratio;
    }

    /// Set the split ratio, clamping to [min_ratio, max_ratio].
    pub fn setRatio(self: *SplitPane, new_ratio: f32) void {
        self.ratio = std.math.clamp(new_ratio, min_ratio, max_ratio);
    }

    /// Rectangle describing a pane's position and size.
    pub const PaneRect = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,

        /// Convert to a raylib Rectangle for drawing.
        pub fn toRl(self: PaneRect) rl.Rectangle {
            return .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height };
        }
    };

    /// Computed layout for both panes and the divider.
    pub const Layout = struct {
        /// Left pane (editor).
        left: PaneRect,
        /// Right pane (preview/render).
        right: PaneRect,
        /// Divider bar rectangle.
        divider: PaneRect,
    };

    /// Compute the pane layout for the given content area.
    /// `area_x`, `area_y` define the top-left of the available content area
    /// (below menu/tab bar, right of any sidebar).
    /// `area_width`, `area_height` define the size of the available area.
    pub fn computeLayout(self: *const SplitPane, area_x: f32, area_y: f32, area_width: f32, area_height: f32) Layout {
        const usable_width = @max(0, area_width - divider_width);
        const left_width = usable_width * self.ratio;
        const right_width = usable_width - left_width;

        return .{
            .left = .{
                .x = area_x,
                .y = area_y,
                .width = left_width,
                .height = area_height,
            },
            .divider = .{
                .x = area_x + left_width,
                .y = area_y,
                .width = divider_width,
                .height = area_height,
            },
            .right = .{
                .x = area_x + left_width + divider_width,
                .y = area_y,
                .width = right_width,
                .height = area_height,
            },
        };
    }

    /// Returns true if the given mouse position is over the divider hit area.
    pub fn isOverDivider(self: *const SplitPane, mouse_x: f32, mouse_y: f32, area_x: f32, area_y: f32, area_width: f32, area_height: f32) bool {
        if (!self.is_active) return false;
        const layout = self.computeLayout(area_x, area_y, area_width, area_height);
        const hit_left = layout.divider.x - drag_hit_padding;
        const hit_right = layout.divider.x + layout.divider.width + drag_hit_padding;
        return mouse_x >= hit_left and mouse_x <= hit_right and
            mouse_y >= layout.divider.y and mouse_y <= layout.divider.y + layout.divider.height;
    }

    /// Handle mouse input for divider dragging. Call once per frame.
    /// Returns true if the divider is being interacted with (hovered or dragged).
    pub fn handleInput(self: *SplitPane, area_x: f32, area_y: f32, area_width: f32, area_height: f32) bool {
        if (!self.is_active) return false;

        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const hovered = self.isOverDivider(mouse_x, mouse_y, area_x, area_y, area_width, area_height);

        if (rl.isMouseButtonPressed(.left) and hovered) {
            self.is_dragging = true;
        }

        if (rl.isMouseButtonReleased(.left)) {
            self.is_dragging = false;
        }

        if (self.is_dragging) {
            // Convert mouse X to a ratio within the content area
            const relative_x = mouse_x - area_x;
            const new_ratio = relative_x / @max(1, area_width);
            self.setRatio(new_ratio);
            rl.setMouseCursor(.resize_ew);
            return true;
        }

        if (hovered) {
            rl.setMouseCursor(.resize_ew);
            return true;
        }

        return false;
    }

    /// Draw the divider bar. Call during the draw phase.
    pub fn drawDivider(self: *const SplitPane, area_x: f32, area_y: f32, area_width: f32, area_height: f32) void {
        if (!self.is_active) return;

        const layout = self.computeLayout(area_x, area_y, area_width, area_height);
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const hovered = self.isOverDivider(mouse_x, mouse_y, area_x, area_y, area_width, area_height);

        const color = if (self.is_dragging or hovered) self.divider_hover_color else self.divider_color;

        rl.drawRectangleRec(layout.divider.toRl(), color);

        // Draw grip dots in the center of the divider for visual affordance
        const center_x = layout.divider.x + layout.divider.width / 2.0;
        const center_y = layout.divider.y + layout.divider.height / 2.0;
        const dot_radius: f32 = 1.5;
        const dot_spacing: f32 = 8;
        const dot_color: rl.Color = if (self.is_dragging or hovered)
            .{ .r = 220, .g = 220, .b = 220, .a = 255 }
        else
            .{ .r = 120, .g = 120, .b = 120, .a = 255 };

        // Draw 3 dots vertically centered
        for ([_]f32{ -1, 0, 1 }) |dy| {
            rl.drawCircleV(
                .{ .x = center_x, .y = center_y + dy * dot_spacing },
                dot_radius,
                dot_color,
            );
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "SplitPane.init has correct defaults" {
    const pane = SplitPane.init();
    try testing.expectEqual(@as(f32, 0.5), pane.ratio);
    try testing.expect(!pane.is_active);
    try testing.expect(!pane.is_dragging);
}

test "SplitPane.toggle flips is_active" {
    var pane = SplitPane.init();
    try testing.expect(!pane.is_active);
    pane.toggle();
    try testing.expect(pane.is_active);
    pane.toggle();
    try testing.expect(!pane.is_active);
}

test "SplitPane.toggle clears is_dragging when deactivating" {
    var pane = SplitPane.init();
    pane.is_active = true;
    pane.is_dragging = true;
    pane.toggle(); // deactivate
    try testing.expect(!pane.is_dragging);
}

test "SplitPane.setRatio clamps to min" {
    var pane = SplitPane.init();
    pane.setRatio(0.0);
    try testing.expectEqual(SplitPane.min_ratio, pane.ratio);
}

test "SplitPane.setRatio clamps to max" {
    var pane = SplitPane.init();
    pane.setRatio(1.0);
    try testing.expectEqual(SplitPane.max_ratio, pane.ratio);
}

test "SplitPane.setRatio accepts valid ratio" {
    var pane = SplitPane.init();
    pane.setRatio(0.3);
    try testing.expectApproxEqAbs(@as(f32, 0.3), pane.ratio, 0.001);
}

test "SplitPane.resetRatio restores default" {
    var pane = SplitPane.init();
    pane.setRatio(0.7);
    pane.resetRatio();
    try testing.expectEqual(@as(f32, 0.5), pane.ratio);
}

test "SplitPane.computeLayout at 50% splits evenly" {
    var pane = SplitPane.init();
    pane.ratio = 0.5;
    const layout = pane.computeLayout(0, 0, 1000, 600);

    // Usable width = 1000 - 4 (divider) = 996
    const usable: f32 = 1000 - SplitPane.divider_width;
    const expected_left_w = usable * 0.5;
    const expected_right_w = usable - expected_left_w;

    try testing.expectApproxEqAbs(expected_left_w, layout.left.width, 0.01);
    try testing.expectApproxEqAbs(expected_right_w, layout.right.width, 0.01);
    try testing.expectApproxEqAbs(SplitPane.divider_width, layout.divider.width, 0.01);

    // Panes should tile horizontally with no gaps
    try testing.expectApproxEqAbs(@as(f32, 0), layout.left.x, 0.01);
    try testing.expectApproxEqAbs(layout.left.width, layout.divider.x, 0.01);
    try testing.expectApproxEqAbs(layout.left.width + SplitPane.divider_width, layout.right.x, 0.01);

    // Total should equal area width
    const total = layout.left.width + layout.divider.width + layout.right.width;
    try testing.expectApproxEqAbs(@as(f32, 1000), total, 0.01);
}

test "SplitPane.computeLayout respects area offset" {
    var pane = SplitPane.init();
    pane.ratio = 0.5;
    const layout = pane.computeLayout(100, 50, 800, 400);

    try testing.expectApproxEqAbs(@as(f32, 100), layout.left.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), layout.left.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 400), layout.left.height, 0.01);
}

test "SplitPane.computeLayout at 30% gives 30/70 split" {
    var pane = SplitPane.init();
    pane.ratio = 0.3;
    const layout = pane.computeLayout(0, 0, 1000, 600);

    const usable: f32 = 1000 - SplitPane.divider_width;
    try testing.expectApproxEqAbs(usable * 0.3, layout.left.width, 0.01);
    try testing.expectApproxEqAbs(usable * 0.7, layout.right.width, 0.01);
}

test "SplitPane.isOverDivider returns false when inactive" {
    const pane = SplitPane.init(); // is_active defaults to false
    try testing.expect(!pane.isOverDivider(500, 300, 0, 0, 1000, 600));
}

test "PaneRect.toRl converts correctly" {
    const rect = SplitPane.PaneRect{
        .x = 10,
        .y = 20,
        .width = 300,
        .height = 400,
    };
    const rl_rect = rect.toRl();
    try testing.expectApproxEqAbs(@as(f32, 10), rl_rect.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), rl_rect.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 300), rl_rect.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 400), rl_rect.height, 0.01);
}
