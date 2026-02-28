const rl = @import("raylib");

const Fonts = @import("../layout/text_measurer.zig").Fonts;
const Theme = @import("../theme/theme.zig").Theme;
const CommandState = @import("../command/command_state.zig").CommandState;
const slice_utils = @import("../utils/slice_utils.zig");

/// Draw the command bar at the bottom of the viewport.
pub fn drawCommandBar(state: *const CommandState, theme: *const Theme, fonts: *const Fonts) void {
    if (!state.is_open) return;

    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const bar_y = screen_h - bar_height;
    const padding: f32 = 8;
    const font_size = theme.body_font_size;
    const spacing = font_size / 10.0;

    // Background (reuses search bar theme colors intentionally)
    rl.drawRectangleRec(
        .{ .x = 0, .y = bar_y, .width = screen_w, .height = bar_height },
        theme.search_bar_bg,
    );

    // Top border
    rl.drawLineEx(
        .{ .x = 0, .y = bar_y },
        .{ .x = screen_w, .y = bar_y },
        1.0,
        theme.search_bar_border,
    );

    const font = fonts.selectFont(.{});
    const text_y = bar_y + (bar_height - font_size) / 2.0;

    // ":" label
    const label = ":";
    var label_buf: [4]u8 = undefined;
    const label_z = slice_utils.sliceToZ(&label_buf, label);
    rl.drawTextEx(font, label_z, .{ .x = padding, .y = text_y }, font_size, spacing, theme.search_bar_text);
    const label_w = rl.measureTextEx(font, label_z, font_size, spacing).x;

    // Input text
    const input = state.inputSlice();
    var input_w: f32 = 0;
    if (input.len > 0) {
        var input_buf: [CommandState.max_input_len + 2]u8 = undefined;
        const input_z = slice_utils.sliceToZ(&input_buf, input);
        rl.drawTextEx(font, input_z, .{ .x = padding + label_w, .y = text_y }, font_size, spacing, theme.search_bar_text);
        input_w = rl.measureTextEx(font, input_z, font_size, spacing).x;
    }

    // Cursor (blinking)
    if (@mod(rl.getTime(), 1.0) < 0.5) {
        const cursor_x = padding + label_w + input_w;
        rl.drawLineEx(
            .{ .x = cursor_x, .y = text_y },
            .{ .x = cursor_x, .y = text_y + font_size },
            1.5,
            theme.search_bar_text,
        );
    }
}

/// Height of the command bar when visible.
pub const bar_height: f32 = 36;
