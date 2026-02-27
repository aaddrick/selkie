const rl = @import("raylib");
const std = @import("std");
const gm = @import("../models/gantt_model.zig");
const GanttModel = gm.GanttModel;
const GanttTask = gm.GanttTask;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");

const ROW_HEIGHT: f32 = 32;
const ROW_PADDING: f32 = 4;
const BAR_HEIGHT: f32 = 24;
const SECTION_HEADER_HEIGHT: f32 = 28;
const TIME_AXIS_HEIGHT: f32 = 30;
const TITLE_HEIGHT: f32 = 30;

pub fn drawGanttChart(
    model: *const GanttModel,
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

    if (model.tasks.items.len == 0) return;

    // 2. Title
    var y_offset: f32 = 0;
    if (model.title.len > 0) {
        ru.drawText(
            model.title,
            origin_x + diagram_width / 2,
            origin_y + 10,
            fonts,
            theme.body_font_size * 1.1,
            theme.mermaid_node_text,
            scroll_y,
            true,
        );
        y_offset = TITLE_HEIGHT;
    }

    // 3. Time axis
    const chart_x = origin_x + model.section_label_width;
    const chart_w = model.chart_width;
    const axis_y = origin_y + y_offset;
    const day_range: f32 = @floatFromInt(model.max_day - model.min_day);
    if (day_range <= 0) return;

    drawTimeAxis(model, chart_x, axis_y, chart_w, day_range, theme, fonts, scroll_y);

    // 4. Grid lines
    const content_y = axis_y + TIME_AXIS_HEIGHT;
    const content_height = diagram_height - y_offset - TIME_AXIS_HEIGHT;
    drawGridLines(model, chart_x, content_y, chart_w, content_height, day_range, theme, scroll_y);

    // 5. Section backgrounds and task bars
    var row_y = content_y;

    if (model.sections.items.len > 0) {
        for (model.sections.items, 0..) |section, sec_idx| {
            // Section header
            const header_bg = rl.Color{
                .r = @min(255, @as(u16, theme.mermaid_node_fill.r) + 20),
                .g = @min(255, @as(u16, theme.mermaid_node_fill.g) + 20),
                .b = @min(255, @as(u16, theme.mermaid_node_fill.b) + 20),
                .a = 180,
            };
            rl.drawRectangleRec(.{
                .x = origin_x,
                .y = row_y - scroll_y,
                .width = diagram_width,
                .height = SECTION_HEADER_HEIGHT,
            }, header_bg);

            ru.drawText(
                section.name,
                origin_x + 10,
                row_y + SECTION_HEADER_HEIGHT / 2,
                fonts,
                theme.body_font_size * 0.9,
                theme.mermaid_node_text,
                scroll_y,
                false,
            );
            row_y += SECTION_HEADER_HEIGHT;

            // Draw tasks in this section
            for (model.tasks.items) |task| {
                if (task.section_idx == sec_idx) {
                    drawTaskBar(model, &task, chart_x, row_y, chart_w, day_range, theme, fonts, scroll_y);
                    // Task name on the left
                    ru.drawText(
                        task.name,
                        origin_x + 10,
                        row_y + ROW_HEIGHT / 2,
                        fonts,
                        theme.body_font_size * 0.8,
                        theme.mermaid_edge_text,
                        scroll_y,
                        false,
                    );
                    row_y += ROW_HEIGHT;
                }
            }
        }
    } else {
        // No sections, just draw all tasks
        for (model.tasks.items) |task| {
            drawTaskBar(model, &task, chart_x, row_y, chart_w, day_range, theme, fonts, scroll_y);
            ru.drawText(
                task.name,
                origin_x + 10,
                row_y + ROW_HEIGHT / 2,
                fonts,
                theme.body_font_size * 0.8,
                theme.mermaid_edge_text,
                scroll_y,
                false,
            );
            row_y += ROW_HEIGHT;
        }
    }
}

fn drawTaskBar(
    model: *const GanttModel,
    task: *const GanttTask,
    chart_x: f32,
    row_y: f32,
    chart_w: f32,
    day_range: f32,
    theme: *const Theme,
    _: *const Fonts,
    scroll_y: f32,
) void {
    const start_frac = @as(f32, @floatFromInt(task.start_day - model.min_day)) / day_range;
    const end_frac = @as(f32, @floatFromInt(task.end_day - model.min_day)) / day_range;

    const bar_x = chart_x + start_frac * chart_w;
    const bar_w = @max((end_frac - start_frac) * chart_w, 2);
    const bar_y = row_y + ROW_PADDING;

    if (task.hasTag(.milestone)) {
        // Diamond marker
        const cx = bar_x;
        const cy = bar_y + BAR_HEIGHT / 2 - scroll_y;
        const size: f32 = 8;
        const color = if (task.hasTag(.crit))
            rl.Color{ .r = 220, .g = 60, .b = 60, .a = 255 }
        else
            theme.mermaid_node_fill;

        rl.drawTriangle(
            .{ .x = cx, .y = cy - size },
            .{ .x = cx - size, .y = cy },
            .{ .x = cx, .y = cy + size },
            color,
        );
        rl.drawTriangle(
            .{ .x = cx, .y = cy - size },
            .{ .x = cx, .y = cy + size },
            .{ .x = cx + size, .y = cy },
            color,
        );
        return;
    }

    // Determine bar color based on tags
    var fill_color = theme.mermaid_node_fill;
    var border_color = theme.mermaid_node_border;

    if (task.hasTag(.done)) {
        fill_color = rl.Color{
            .r = @as(u8, @intCast(@min(255, @as(u16, theme.mermaid_node_fill.r) / 2 + 64))),
            .g = @as(u8, @intCast(@min(255, @as(u16, theme.mermaid_node_fill.g) / 2 + 64))),
            .b = @as(u8, @intCast(@min(255, @as(u16, theme.mermaid_node_fill.b) / 2 + 64))),
            .a = 180,
        };
    } else if (task.hasTag(.active)) {
        fill_color = rl.Color{
            .r = @min(255, @as(u16, theme.mermaid_node_fill.r) + 30),
            .g = @min(255, @as(u16, theme.mermaid_node_fill.g) + 30),
            .b = @min(255, @as(u16, theme.mermaid_node_fill.b) + 30),
            .a = 255,
        };
    }

    if (task.hasTag(.crit)) {
        border_color = rl.Color{ .r = 220, .g = 60, .b = 60, .a = 255 };
    }

    // Bar fill
    rl.drawRectangleRounded(
        .{ .x = bar_x, .y = bar_y - scroll_y, .width = bar_w, .height = BAR_HEIGHT },
        0.3,
        4,
        fill_color,
    );

    // Bar border
    rl.drawRectangleRoundedLinesEx(
        .{ .x = bar_x, .y = bar_y - scroll_y, .width = bar_w, .height = BAR_HEIGHT },
        0.3,
        4,
        2,
        border_color,
    );
}

fn drawTimeAxis(
    model: *const GanttModel,
    chart_x: f32,
    axis_y: f32,
    chart_w: f32,
    day_range: f32,
    theme: *const Theme,
    fonts: *const Fonts,
    scroll_y: f32,
) void {
    // Draw tick marks and date labels at regular intervals
    const num_ticks: i32 = @min(10, @as(i32, @intFromFloat(day_range)));
    if (num_ticks <= 0) return;

    const tick_interval = day_range / @as(f32, @floatFromInt(num_ticks));

    var i: i32 = 0;
    while (i <= num_ticks) : (i += 1) {
        const day_offset = @as(f32, @floatFromInt(i)) * tick_interval;
        const x = chart_x + (day_offset / day_range) * chart_w;

        // Tick mark
        rl.drawLineEx(
            .{ .x = x, .y = axis_y + TIME_AXIS_HEIGHT - 8 - scroll_y },
            .{ .x = x, .y = axis_y + TIME_AXIS_HEIGHT - scroll_y },
            1,
            theme.mermaid_node_border,
        );

        // Date label
        const day_num = model.min_day + @as(i32, @intFromFloat(day_offset));
        const date = gm.SimpleDate.fromDayNumber(day_num);
        var buf: [32]u8 = undefined;
        const label = date.format(&buf);
        if (label.len > 0) {
            ru.drawText(
                label,
                x,
                axis_y + TIME_AXIS_HEIGHT / 2,
                fonts,
                theme.body_font_size * 0.7,
                theme.mermaid_edge_text,
                scroll_y,
                true,
            );
        }
    }

    // Axis line
    rl.drawLineEx(
        .{ .x = chart_x, .y = axis_y + TIME_AXIS_HEIGHT - scroll_y },
        .{ .x = chart_x + chart_w, .y = axis_y + TIME_AXIS_HEIGHT - scroll_y },
        1,
        theme.mermaid_node_border,
    );
}

fn drawGridLines(
    model: *const GanttModel,
    chart_x: f32,
    content_y: f32,
    chart_w: f32,
    content_height: f32,
    day_range: f32,
    theme: *const Theme,
    scroll_y: f32,
) void {
    const num_lines: i32 = @min(10, @as(i32, @intFromFloat(day_range)));
    if (num_lines <= 0) return;

    const interval = day_range / @as(f32, @floatFromInt(num_lines));
    const grid_color = rl.Color{
        .r = theme.mermaid_node_border.r,
        .g = theme.mermaid_node_border.g,
        .b = theme.mermaid_node_border.b,
        .a = 40,
    };

    _ = model;

    var i: i32 = 1;
    while (i < num_lines) : (i += 1) {
        const x = chart_x + (@as(f32, @floatFromInt(i)) * interval / day_range) * chart_w;
        rl.drawLineEx(
            .{ .x = x, .y = content_y - scroll_y },
            .{ .x = x, .y = content_y + content_height - scroll_y },
            1,
            grid_color,
        );
    }
}
