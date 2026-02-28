const std = @import("std");
const rl = @import("raylib");

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
        pending,
    };

    pub fn init(kind: Kind, target_tab: usize) ModalDialog {
        return .{
            .kind = kind,
            .target_tab = target_tab,
        };
    }

    /// Process mouse input and return a response if a button was clicked.
    pub fn update(self: *const ModalDialog) ?Response {
        if (!rl.isMouseButtonPressed(.left)) return null;

        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const geom = computeGeometry();

        return switch (self.kind) {
            .external_change => {
                // Two buttons: Reload | Keep Editing
                const btn1 = buttonRect(geom, 0, 2);
                const btn2 = buttonRect(geom, 1, 2);
                if (pointInRect(mouse_x, mouse_y, btn1)) return .reload;
                if (pointInRect(mouse_x, mouse_y, btn2)) return .cancel;
                return null;
            },
            .close_tab => {
                // Three buttons: Save | Discard | Cancel
                const btn1 = buttonRect(geom, 0, 3);
                const btn2 = buttonRect(geom, 1, 3);
                const btn3 = buttonRect(geom, 2, 3);
                if (pointInRect(mouse_x, mouse_y, btn1)) return .save;
                if (pointInRect(mouse_x, mouse_y, btn2)) return .discard;
                if (pointInRect(mouse_x, mouse_y, btn3)) return .cancel;
                return null;
            },
            .close_app => {
                // Two buttons: Save All | Discard
                const btn1 = buttonRect(geom, 0, 2);
                const btn2 = buttonRect(geom, 1, 2);
                if (pointInRect(mouse_x, mouse_y, btn1)) return .save;
                if (pointInRect(mouse_x, mouse_y, btn2)) return .discard;
                return null;
            },
        };
    }

    /// Draw the modal overlay and dialog box.
    pub fn draw(self: *const ModalDialog) void {
        const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
        const screen_h: f32 = @floatFromInt(rl.getScreenHeight());

        // Semi-transparent overlay
        rl.drawRectangle(0, 0, @intFromFloat(screen_w), @intFromFloat(screen_h), rl.Color{ .r = 0, .g = 0, .b = 0, .a = 120 });

        const geom = computeGeometry();

        // Dialog box background
        rl.drawRectangle(
            @intFromFloat(geom.box_x),
            @intFromFloat(geom.box_y),
            @intFromFloat(geom.box_w),
            @intFromFloat(geom.box_h),
            rl.Color{ .r = 240, .g = 240, .b = 240, .a = 255 },
        );
        // Dialog box border
        rl.drawRectangleLines(
            @intFromFloat(geom.box_x),
            @intFromFloat(geom.box_y),
            @intFromFloat(geom.box_w),
            @intFromFloat(geom.box_h),
            rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 },
        );

        // Title
        const title = self.titleText();
        const title_w = rl.measureText(title, title_font_size);
        const title_x: i32 = @intFromFloat(geom.box_x + (geom.box_w - @as(f32, @floatFromInt(title_w))) / 2);
        const title_y: i32 = @intFromFloat(geom.box_y + padding);
        rl.drawText(title, title_x, title_y, title_font_size, rl.Color{ .r = 30, .g = 30, .b = 30, .a = 255 });

        // Message
        const message = self.messageText();
        const msg_w = rl.measureText(message, msg_font_size);
        const msg_x: i32 = @intFromFloat(geom.box_x + (geom.box_w - @as(f32, @floatFromInt(msg_w))) / 2);
        const msg_y: i32 = @intFromFloat(geom.box_y + padding + @as(f32, @floatFromInt(title_font_size)) + 12);
        rl.drawText(message, msg_x, msg_y, msg_font_size, rl.Color{ .r = 80, .g = 80, .b = 80, .a = 255 });

        // Buttons
        switch (self.kind) {
            .external_change => {
                self.drawButton(geom, 0, 2, "Reload");
                self.drawButton(geom, 1, 2, "Keep Editing");
            },
            .close_tab => {
                self.drawButton(geom, 0, 3, "Save");
                self.drawButton(geom, 1, 3, "Discard");
                self.drawButton(geom, 2, 3, "Cancel");
            },
            .close_app => {
                self.drawButton(geom, 0, 2, "Save All");
                self.drawButton(geom, 1, 2, "Discard");
            },
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
    const btn_y_offset: f32 = box_height - padding - btn_height;
    const title_font_size: i32 = 20;
    const msg_font_size: i32 = 16;

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

    fn drawButton(self: *const ModalDialog, geom: Geometry, index: usize, count: usize, label: [:0]const u8) void {
        _ = self;
        const r = buttonRect(geom, index, count);
        const mouse_x: f32 = @floatFromInt(rl.getMouseX());
        const mouse_y: f32 = @floatFromInt(rl.getMouseY());
        const hovered = pointInRect(mouse_x, mouse_y, r);

        const bg = if (hovered)
            rl.Color{ .r = 200, .g = 200, .b = 210, .a = 255 }
        else
            rl.Color{ .r = 220, .g = 220, .b = 220, .a = 255 };

        rl.drawRectangle(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.w), @intFromFloat(r.h), bg);
        rl.drawRectangleLines(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.w), @intFromFloat(r.h), rl.Color{ .r = 120, .g = 120, .b = 120, .a = 255 });

        const text_w = rl.measureText(label, msg_font_size);
        const text_x: i32 = @intFromFloat(r.x + (r.w - @as(f32, @floatFromInt(text_w))) / 2);
        const text_y: i32 = @intFromFloat(r.y + (r.h - @as(f32, @floatFromInt(msg_font_size))) / 2);
        rl.drawText(label, text_x, text_y, msg_font_size, rl.Color{ .r = 30, .g = 30, .b = 30, .a = 255 });
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
