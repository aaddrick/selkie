const std = @import("std");
const rl = @import("raylib");
const Theme = @import("theme/theme.zig").Theme;

/// A modal dialog that blocks all other input until dismissed.
/// Used for unsaved-change prompts (close tab/app) and external file changes.
pub const ModalDialog = struct {
    kind: Kind,
    target_tab: usize,

    pub const Kind = enum {
        external_change,
        close_tab,
        close_app,
    };

    pub const Response = enum {
        save,
        discard,
        cancel,
        reload,
    };

    pub fn init(kind: Kind, target_tab: usize) ModalDialog {
        return .{
            .kind = kind,
            .target_tab = target_tab,
        };
    }

    /// Process mouse input and return the user's response if a button was
    /// clicked, or null otherwise.
    pub fn update(self: *const ModalDialog) ?Response {
        if (!rl.isMouseButtonPressed(.left)) return null;

        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const geom = computeGeometry();
        const responses: []const Response = switch (self.kind) {
            .external_change => &.{ .reload, .cancel },
            .close_tab => &.{ .save, .discard, .cancel },
            .close_app => &.{ .save, .discard },
        };
        for (responses, 0..) |response, i| {
            if (pointInRect(mouse_x, mouse_y, buttonRect(geom, i, responses.len)))
                return response;
        }
        return null;
    }

    /// Draw the modal overlay and dialog box using theme colors.
    pub fn draw(self: *const ModalDialog, theme: *const Theme) void {
        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());

        // Semi-transparent overlay
        rl.drawRectangle(0, 0, @intFromFloat(screen_w), @intFromFloat(screen_h), overlay_color);

        const geom = computeGeometry();
        const bx: i32 = @intFromFloat(geom.box_x);
        const by: i32 = @intFromFloat(geom.box_y);
        const bw: i32 = @intFromFloat(geom.box_w);
        const bh: i32 = @intFromFloat(geom.box_h);

        // Dialog background and border derived from theme
        rl.drawRectangle(bx, by, bw, bh, theme.menu_active_bg);
        rl.drawRectangleLines(bx, by, bw, bh, theme.tab_border);

        // Title
        const title = self.titleText();
        const title_w = rl.measureText(title, title_font_size);
        const title_x: i32 = @intFromFloat(geom.box_x + (geom.box_w - @as(f32, @floatFromInt(title_w))) / 2);
        const title_y: i32 = @intFromFloat(geom.box_y + padding);
        rl.drawText(title, title_x, title_y, title_font_size, theme.text);

        // Message
        const message = self.messageText();
        const msg_w = rl.measureText(message, msg_font_size);
        const msg_x: i32 = @intFromFloat(geom.box_x + (geom.box_w - @as(f32, @floatFromInt(msg_w))) / 2);
        const msg_y: i32 = @intFromFloat(geom.box_y + padding + @as(f32, @floatFromInt(title_font_size)) + title_msg_gap);
        rl.drawText(message, msg_x, msg_y, msg_font_size, theme.tab_text_inactive);

        // Buttons
        const labels: []const [:0]const u8 = switch (self.kind) {
            .external_change => &.{ "Reload", "Keep Editing" },
            .close_tab => &.{ "Save", "Discard", "Cancel" },
            .close_app => &.{ "Save All", "Discard" },
        };
        for (labels, 0..) |label, i| {
            drawButton(geom, i, labels.len, label, theme);
        }
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    const box_width: f32 = 400;
    const box_height: f32 = 160;
    const padding: f32 = 20;
    const btn_height: f32 = 32;
    const btn_spacing: f32 = 12;
    const title_msg_gap: f32 = 12;
    const btn_y_offset: f32 = box_height - padding - btn_height;
    const title_font_size: i32 = 20;
    const msg_font_size: i32 = 16;

    const overlay_color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 120 };

    const Geometry = struct {
        box_x: f32,
        box_y: f32,
        box_w: f32,
        box_h: f32,
    };

    fn computeGeometry() Geometry {
        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
        return .{
            .box_x = (screen_w - box_width) / 2,
            .box_y = (screen_h - box_height) / 2,
            .box_w = box_width,
            .box_h = box_height,
        };
    }

    const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

    fn buttonRect(geom: Geometry, index: usize, count: usize) Rect {
        const available = geom.box_w - 2 * padding - @as(f32, @floatFromInt(count - 1)) * btn_spacing;
        const btn_w = available / @as(f32, @floatFromInt(count));
        const x = geom.box_x + padding + @as(f32, @floatFromInt(index)) * (btn_w + btn_spacing);
        const y = geom.box_y + btn_y_offset;
        return .{ .x = x, .y = y, .w = btn_w, .h = btn_height };
    }

    fn pointInRect(px: f32, py: f32, r: Rect) bool {
        return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h;
    }

    fn drawButton(geom: Geometry, index: usize, count: usize, label: [:0]const u8, theme: *const Theme) void {
        const r = buttonRect(geom, index, count);
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const hovered = pointInRect(mouse_x, mouse_y, r);

        const rx: i32 = @intFromFloat(r.x);
        const ry: i32 = @intFromFloat(r.y);
        const rw: i32 = @intFromFloat(r.w);
        const rh: i32 = @intFromFloat(r.h);
        const bg = if (hovered) theme.tab_hover_bg else theme.tab_inactive_bg;

        rl.drawRectangle(rx, ry, rw, rh, bg);
        rl.drawRectangleLines(rx, ry, rw, rh, theme.tab_border);

        const text_w = rl.measureText(label, msg_font_size);
        const text_x: i32 = @intFromFloat(r.x + (r.w - @as(f32, @floatFromInt(text_w))) / 2);
        const text_y: i32 = @intFromFloat(r.y + (r.h - @as(f32, @floatFromInt(msg_font_size))) / 2);
        rl.drawText(label, text_x, text_y, msg_font_size, theme.text);
    }

    fn titleText(self: *const ModalDialog) [:0]const u8 {
        return switch (self.kind) {
            .external_change => "File Changed on Disk",
            .close_tab => "Unsaved Changes",
            .close_app => "Unsaved Changes",
        };
    }

    fn messageText(self: *const ModalDialog) [:0]const u8 {
        return switch (self.kind) {
            .external_change => "The file has been modified externally.",
            .close_tab => "Save changes before closing?",
            .close_app => "Save all changes before quitting?",
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ModalDialog.init sets kind and target_tab" {
    const dialog = ModalDialog.init(.external_change, 2);
    try testing.expectEqual(ModalDialog.Kind.external_change, dialog.kind);
    try testing.expectEqual(@as(usize, 2), dialog.target_tab);
}

test "ModalDialog.init close_tab kind" {
    const dialog = ModalDialog.init(.close_tab, 0);
    try testing.expectEqual(ModalDialog.Kind.close_tab, dialog.kind);
    try testing.expectEqual(@as(usize, 0), dialog.target_tab);
}

test "ModalDialog.init close_app kind" {
    const dialog = ModalDialog.init(.close_app, 0);
    try testing.expectEqual(ModalDialog.Kind.close_app, dialog.kind);
}

test "ModalDialog titleText returns correct strings" {
    const d1 = ModalDialog.init(.external_change, 0);
    try testing.expectEqualStrings("File Changed on Disk", d1.titleText());

    const d2 = ModalDialog.init(.close_tab, 0);
    try testing.expectEqualStrings("Unsaved Changes", d2.titleText());

    const d3 = ModalDialog.init(.close_app, 0);
    try testing.expectEqualStrings("Unsaved Changes", d3.titleText());
}

test "ModalDialog messageText returns correct strings" {
    const d1 = ModalDialog.init(.external_change, 0);
    try testing.expectEqualStrings("The file has been modified externally.", d1.messageText());

    const d2 = ModalDialog.init(.close_tab, 0);
    try testing.expectEqualStrings("Save changes before closing?", d2.messageText());

    const d3 = ModalDialog.init(.close_app, 0);
    try testing.expectEqualStrings("Save all changes before quitting?", d3.messageText());
}

test "pointInRect returns true for point inside rect" {
    const r = ModalDialog.Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try testing.expect(ModalDialog.pointInRect(50, 40, r));
}

test "pointInRect returns true for point on boundary" {
    const r = ModalDialog.Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    // Top-left corner
    try testing.expect(ModalDialog.pointInRect(10, 20, r));
    // Bottom-right corner
    try testing.expect(ModalDialog.pointInRect(110, 70, r));
}

test "pointInRect returns false for point outside rect" {
    const r = ModalDialog.Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try testing.expect(!ModalDialog.pointInRect(9, 40, r));
    try testing.expect(!ModalDialog.pointInRect(111, 40, r));
    try testing.expect(!ModalDialog.pointInRect(50, 19, r));
    try testing.expect(!ModalDialog.pointInRect(50, 71, r));
}

test "buttonRect produces non-overlapping buttons" {
    const geom = ModalDialog.Geometry{ .box_x = 100, .box_y = 100, .box_w = 400, .box_h = 160 };
    const r0 = ModalDialog.buttonRect(geom, 0, 3);
    const r1 = ModalDialog.buttonRect(geom, 1, 3);
    const r2 = ModalDialog.buttonRect(geom, 2, 3);

    // All buttons should have positive width and height
    try testing.expect(r0.w > 0);
    try testing.expect(r1.w > 0);
    try testing.expect(r2.w > 0);
    try testing.expect(r0.h > 0);

    // Buttons should not overlap (each starts after the previous ends)
    try testing.expect(r1.x > r0.x + r0.w);
    try testing.expect(r2.x > r1.x + r1.w);

    // All buttons at same y
    try testing.expectEqual(r0.y, r1.y);
    try testing.expectEqual(r1.y, r2.y);
}

test "buttonRect single button spans available width" {
    const geom = ModalDialog.Geometry{ .box_x = 0, .box_y = 0, .box_w = 400, .box_h = 160 };
    const r = ModalDialog.buttonRect(geom, 0, 1);
    const expected_w = geom.box_w - 2 * ModalDialog.padding;
    try testing.expectApproxEqAbs(expected_w, r.w, 0.01);
}

test "buttonRect two buttons are non-overlapping and equal width" {
    const geom = ModalDialog.Geometry{ .box_x = 50, .box_y = 50, .box_w = 400, .box_h = 160 };
    const r0 = ModalDialog.buttonRect(geom, 0, 2);
    const r1 = ModalDialog.buttonRect(geom, 1, 2);

    try testing.expect(r0.w > 0);
    try testing.expectApproxEqAbs(r0.w, r1.w, 0.01);
    try testing.expect(r1.x > r0.x + r0.w);
    try testing.expectEqual(r0.y, r1.y);
}
