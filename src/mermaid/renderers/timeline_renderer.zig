const rl = @import("raylib");
const std = @import("std");
const tm = @import("../models/timeline_model.zig");
const TimelineModel = tm.TimelineModel;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");

const PERIOD_WIDTH: f32 = 120;
const PERIOD_SPACING: f32 = 30;
const AXIS_Y_OFFSET: f32 = 80; // from top of diagram
const EVENT_HEIGHT: f32 = 24;
const EVENT_SPACING: f32 = 6;
const MARKER_RADIUS: f32 = 6;
const DIAGRAM_PADDING: f32 = 20;
const SECTION_GAP: f32 = 20;

const section_colors = [_]rl.Color{
    rl.Color{ .r = 76, .g = 114, .b = 176, .a = 40 },
    rl.Color{ .r = 85, .g = 168, .b = 104, .a = 40 },
    rl.Color{ .r = 221, .g = 132, .b = 82, .a = 40 },
    rl.Color{ .r = 196, .g = 78, .b = 82, .a = 40 },
    rl.Color{ .r = 129, .g = 114, .b = 178, .a = 40 },
};

pub fn drawTimeline(
    model: *const TimelineModel,
    origin_x: f32,
    origin_y: f32,
    diagram_width: f32,
    diagram_height: f32,
    theme: *const Theme,
    fonts: *const Fonts,
    scroll_y: f32,
) void {
    // Background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    var title_offset: f32 = 0;

    // Title
    if (model.title.len > 0) {
        ru.drawText(
            model.title,
            origin_x + diagram_width / 2,
            origin_y + DIAGRAM_PADDING,
            fonts,
            theme.body_font_size * 1.1,
            theme.mermaid_node_text,
            scroll_y,
            true,
        );
        title_offset = theme.body_font_size * 1.1 + 15;
    }

    const axis_y = origin_y + DIAGRAM_PADDING + title_offset + AXIS_Y_OFFSET;

    // Count total periods for positioning
    var total_periods: usize = 0;
    for (model.sections.items) |section| {
        total_periods += section.periods.items.len;
    }
    if (total_periods == 0) return;

    // Draw horizontal axis line
    const axis_start_x = origin_x + DIAGRAM_PADDING + 20;
    const axis_end_x = origin_x + diagram_width - DIAGRAM_PADDING;
    rl.drawLineEx(
        .{ .x = axis_start_x, .y = axis_y - scroll_y },
        .{ .x = axis_end_x, .y = axis_y - scroll_y },
        2,
        theme.mermaid_node_border,
    );

    // Draw periods
    var period_x = axis_start_x + PERIOD_SPACING;
    var section_color_idx: usize = 0;

    for (model.sections.items) |section| {
        // Section background
        if (section.name.len > 0) {
            const section_start_x = period_x - PERIOD_SPACING / 2;
            const section_width = @as(f32, @floatFromInt(section.periods.items.len)) * (PERIOD_WIDTH + PERIOD_SPACING);
            const sec_color = section_colors[section_color_idx % section_colors.len];
            rl.drawRectangleRec(.{
                .x = section_start_x,
                .y = origin_y + DIAGRAM_PADDING + title_offset - scroll_y,
                .width = section_width,
                .height = diagram_height - DIAGRAM_PADDING * 2 - title_offset,
            }, sec_color);

            // Section label at top
            ru.drawText(
                section.name,
                section_start_x + section_width / 2,
                origin_y + DIAGRAM_PADDING + title_offset + 10,
                fonts,
                theme.body_font_size * 0.85,
                theme.mermaid_node_text,
                scroll_y,
                true,
            );
            section_color_idx += 1;
        }

        for (section.periods.items, 0..) |period, pi| {
            _ = pi;
            const cx = period_x + PERIOD_WIDTH / 2;

            // Period marker on axis
            rl.drawCircleV(
                .{ .x = cx, .y = axis_y - scroll_y },
                MARKER_RADIUS,
                theme.mermaid_node_border,
            );

            // Period label below axis
            ru.drawText(
                period.label,
                cx,
                axis_y + MARKER_RADIUS + 10,
                fonts,
                theme.body_font_size * 0.8,
                theme.mermaid_node_text,
                scroll_y,
                true,
            );

            // Events above/below alternating
            for (period.events.items, 0..) |event, ei| {
                const above = (ei % 2 == 0);
                const offset = @as(f32, @floatFromInt(ei / 2 + 1));

                var event_y: f32 = undefined;
                if (above) {
                    event_y = axis_y - MARKER_RADIUS - 15 - offset * (EVENT_HEIGHT + EVENT_SPACING);
                } else {
                    event_y = axis_y + MARKER_RADIUS + 30 + offset * (EVENT_HEIGHT + EVENT_SPACING);
                }

                // Event bubble
                const event_w = PERIOD_WIDTH - 10;
                const event_x = cx - event_w / 2;
                rl.drawRectangleRounded(.{
                    .x = event_x,
                    .y = event_y - scroll_y,
                    .width = event_w,
                    .height = EVENT_HEIGHT,
                }, 0.3, 6, ru.withAlpha(theme.mermaid_node_border, 30));
                rl.drawRectangleRoundedLinesEx(.{
                    .x = event_x,
                    .y = event_y - scroll_y,
                    .width = event_w,
                    .height = EVENT_HEIGHT,
                }, 0.3, 6, 1, ru.withAlpha(theme.mermaid_node_border, 120));

                // Event text
                ru.drawText(
                    event.text,
                    cx,
                    event_y + EVENT_HEIGHT / 2,
                    fonts,
                    theme.body_font_size * 0.7,
                    theme.mermaid_node_text,
                    scroll_y,
                    true,
                );

                // Connecting line from axis to event
                const line_start_y = if (above) axis_y - MARKER_RADIUS else axis_y + MARKER_RADIUS;
                const line_end_y = if (above) event_y + EVENT_HEIGHT else event_y;
                rl.drawLineEx(
                    .{ .x = cx, .y = line_start_y - scroll_y },
                    .{ .x = cx, .y = line_end_y - scroll_y },
                    1,
                    ru.withAlpha(theme.mermaid_node_border, 100),
                );
            }

            period_x += PERIOD_WIDTH + PERIOD_SPACING;
        }

        period_x += SECTION_GAP;
    }
}
