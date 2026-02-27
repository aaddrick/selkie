const rl = @import("raylib");

const Fonts = @import("../layout/text_measurer.zig").Fonts;
const Theme = @import("../theme/theme.zig").Theme;
const SearchState = @import("../search/search_state.zig").SearchState;
const slice_utils = @import("../utils/slice_utils.zig");

/// Draw highlight rectangles for all visible search matches.
/// Must be called within the scissor region (after main content, before scissor end).
pub fn drawHighlights(state: *const SearchState, theme: *const Theme, scroll_y: f32, menu_bar_height: f32) void {
    if (!state.is_open) return;
    if (state.matches.items.len == 0) return;

    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const view_bottom = scroll_y + screen_h;

    for (state.matches.items, 0..) |match, idx| {
        const rect = match.highlight_rect;

        // Frustum culling
        if (!rect.overlapsVertically(scroll_y, view_bottom)) continue;

        const draw_y = rect.y - scroll_y;

        // Skip if above menu bar
        if (draw_y + rect.height < menu_bar_height) continue;

        const is_current = if (state.current_idx) |ci| ci == idx else false;
        const color = if (is_current) theme.search_current else theme.search_highlight;

        rl.drawRectangleRounded(
            .{ .x = rect.x, .y = draw_y, .width = rect.width, .height = rect.height },
            0.15,
            4,
            color,
        );
    }
}

/// Draw the search bar overlay at the top of the viewport.
pub fn drawSearchBar(state: *const SearchState, theme: *const Theme, fonts: *const Fonts, menu_bar_height: f32) void {
    if (!state.is_open) return;

    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const bar_y = menu_bar_height;
    const padding: f32 = 8;
    const font_size = theme.body_font_size;
    const spacing = font_size / 10.0;

    // Background
    rl.drawRectangleRec(
        .{ .x = 0, .y = bar_y, .width = screen_w, .height = bar_height },
        theme.search_bar_bg,
    );

    // Bottom border
    rl.drawLineEx(
        .{ .x = 0, .y = bar_y + bar_height },
        .{ .x = screen_w, .y = bar_y + bar_height },
        1.0,
        theme.search_bar_border,
    );

    const font = fonts.selectFont(.{});
    const text_y = bar_y + (bar_height - font_size) / 2.0;

    // "Find: " label (6 chars + null terminator, rounded up)
    const label = "Find: ";
    var label_buf: [8]u8 = undefined;
    const label_z = slice_utils.sliceToZ(&label_buf, label);
    rl.drawTextEx(font, label_z, .{ .x = padding, .y = text_y }, font_size, spacing, theme.search_bar_text);
    const label_w = rl.measureTextEx(font, label_z, font_size, spacing).x;

    // Input text and cursor
    const input = state.inputSlice();
    var input_w: f32 = 0;
    if (input.len > 0) {
        var input_buf: [SearchState.max_query_len + 2]u8 = undefined;
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

    // Match count (right-aligned)
    var count_buf: [64]u8 = undefined;
    const count_str = state.formatMatchCount(&count_buf);
    if (count_str.len > 0) {
        var count_z_buf: [66]u8 = undefined;
        const count_z = slice_utils.sliceToZ(&count_z_buf, count_str);
        const count_w = rl.measureTextEx(font, count_z, font_size, spacing).x;
        rl.drawTextEx(
            font,
            count_z,
            .{ .x = screen_w - count_w - padding, .y = text_y },
            font_size,
            spacing,
            theme.search_bar_text,
        );
    }
}

/// Height of the search bar when visible (used for content offset).
/// Sized to fit body_font_size (default 16) + 2*padding(8) + border(4).
pub const bar_height: f32 = 36;
