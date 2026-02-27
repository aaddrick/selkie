const rl = @import("raylib");
const std = @import("std");
const pm = @import("../models/pie_model.zig");
const PieModel = pm.PieModel;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");

const LEGEND_SWATCH_SIZE: f32 = 14;
const LEGEND_LINE_HEIGHT: f32 = 22;
const LEGEND_PADDING: f32 = 15;

pub fn drawPieChart(
    model: *const PieModel,
    origin_x: f32,
    origin_y: f32,
    diagram_width: f32,
    diagram_height: f32,
    theme: *const Theme,
    fonts: *const Fonts,
    scroll_y: f32,
) void {
    // 1. Background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    // 2. Title
    if (model.title.len > 0) {
        ru.drawText(
            model.title,
            origin_x + diagram_width / 2,
            origin_y + 15,
            fonts,
            theme.body_font_size * 1.1,
            theme.mermaid_node_text,
            scroll_y,
            true,
        );
    }

    if (model.slices.items.len == 0) return;

    // 3. Draw pie slices
    const cx = origin_x + model.center_x;
    const cy = origin_y + model.center_y;
    const radius = model.radius;

    for (model.slices.items) |slice| {
        rl.drawCircleSector(
            .{ .x = cx, .y = cy - scroll_y },
            radius,
            slice.start_angle,
            slice.end_angle,
            36,
            slice.color,
        );

        // Sector border
        rl.drawCircleSectorLines(
            .{ .x = cx, .y = cy - scroll_y },
            radius,
            slice.start_angle,
            slice.end_angle,
            36,
            theme.mermaid_subgraph_bg,
        );
    }

    // 4. Slice labels (percentage outside the pie)
    for (model.slices.items) |slice| {
        const mid_angle = (slice.start_angle + slice.end_angle) / 2.0;
        const angle_span = slice.end_angle - slice.start_angle;

        // Only show label if slice is big enough
        if (angle_span < 8) continue;

        // Label inside the pie at 60% radius
        const label_r = radius * 0.65;
        const rad = mid_angle * std.math.pi / 180.0;
        const lx = cx + label_r * @cos(rad);
        const ly = cy - scroll_y + label_r * @sin(rad);

        // Format percentage
        var buf: [32]u8 = undefined;
        const pct_int: u32 = @intFromFloat(@round(slice.percentage));
        const pct_str = std.fmt.bufPrint(&buf, "{d}%", .{pct_int}) catch continue;
        ru.drawText(
            pct_str,
            lx,
            ly,
            fonts,
            theme.body_font_size * 0.8,
            rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
            0, // already scroll-adjusted
            true,
        );
    }

    // 5. Legend
    const legend_x = origin_x + model.center_x + radius + LEGEND_PADDING + 20;
    var legend_y = origin_y + model.center_y - (@as(f32, @floatFromInt(model.slices.items.len)) * LEGEND_LINE_HEIGHT) / 2;

    for (model.slices.items) |slice| {
        // Color swatch
        rl.drawRectangleRec(.{
            .x = legend_x,
            .y = legend_y - scroll_y,
            .width = LEGEND_SWATCH_SIZE,
            .height = LEGEND_SWATCH_SIZE,
        }, slice.color);
        rl.drawRectangleLinesEx(.{
            .x = legend_x,
            .y = legend_y - scroll_y,
            .width = LEGEND_SWATCH_SIZE,
            .height = LEGEND_SWATCH_SIZE,
        }, 1, theme.mermaid_node_border);

        // Label text
        var label_buf: [256]u8 = undefined;
        var label_len: usize = 0;

        const copy_len = @min(slice.label.len, label_buf.len - 20);
        @memcpy(label_buf[0..copy_len], slice.label[0..copy_len]);
        label_len = copy_len;

        if (model.show_data) {
            const val_int: u32 = @intFromFloat(@round(slice.value));
            const val_str = std.fmt.bufPrint(label_buf[label_len .. label_buf.len - 1], " ({d})", .{val_int}) catch "";
            label_len += val_str.len;
        }

        label_buf[label_len] = 0;
        const z: [:0]const u8 = label_buf[0..label_len :0];

        const font = fonts.selectFont(.{});
        const font_size = theme.body_font_size * 0.85;
        const spacing = font_size / 10.0;
        rl.drawTextEx(font, z, .{
            .x = legend_x + LEGEND_SWATCH_SIZE + 6,
            .y = legend_y - scroll_y,
        }, font_size, spacing, theme.mermaid_node_text);

        legend_y += LEGEND_LINE_HEIGHT;
    }
}
