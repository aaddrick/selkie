const rl = @import("raylib");
const std = @import("std");
const jm = @import("../models/journey_model.zig");
const JourneyModel = jm.JourneyModel;
const JourneySection = jm.JourneySection;
const JourneyTask = jm.JourneyTask;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;

const TASK_WIDTH: f32 = 120;
const TASK_HEIGHT: f32 = 50;
const TASK_SPACING: f32 = 20;
const SECTION_PADDING: f32 = 15;
const SCORE_RADIUS: f32 = 14;
const DIAGRAM_PADDING: f32 = 20;

pub fn drawJourney(
    model: *const JourneyModel,
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

    var cur_y = origin_y + DIAGRAM_PADDING;

    // Title
    if (model.title.len > 0) {
        drawText(
            model.title,
            origin_x + diagram_width / 2,
            cur_y,
            fonts,
            theme.body_font_size * 1.1,
            theme.mermaid_node_text,
            scroll_y,
            true,
        );
        cur_y += theme.body_font_size * 1.1 + 15;
    }

    // Draw sections
    for (model.sections.items) |section| {
        // Section header
        drawText(
            section.name,
            origin_x + DIAGRAM_PADDING,
            cur_y,
            fonts,
            theme.body_font_size * 0.95,
            theme.mermaid_node_text,
            scroll_y,
            false,
        );
        cur_y += theme.body_font_size + SECTION_PADDING;

        // Section divider line
        rl.drawLineEx(
            .{ .x = origin_x + DIAGRAM_PADDING, .y = cur_y - scroll_y - 5 },
            .{ .x = origin_x + diagram_width - DIAGRAM_PADDING, .y = cur_y - scroll_y - 5 },
            1,
            withAlpha(theme.mermaid_node_border, 100),
        );

        // Draw tasks in a horizontal row
        var task_x = origin_x + DIAGRAM_PADDING + 10;
        const task_y = cur_y;

        for (section.tasks.items, 0..) |task, ti| {
            _ = ti;

            // Task background
            const score_color = jm.scoreColor(task.score);
            rl.drawRectangleRounded(.{
                .x = task_x,
                .y = task_y - scroll_y,
                .width = TASK_WIDTH,
                .height = TASK_HEIGHT,
            }, 0.2, 6, withAlpha(score_color, 40));
            rl.drawRectangleRoundedLinesEx(.{
                .x = task_x,
                .y = task_y - scroll_y,
                .width = TASK_WIDTH,
                .height = TASK_HEIGHT,
            }, 0.2, 6, 1.5, score_color);

            // Task description
            drawText(
                task.description,
                task_x + TASK_WIDTH / 2,
                task_y + 10,
                fonts,
                theme.body_font_size * 0.75,
                theme.mermaid_node_text,
                scroll_y,
                true,
            );

            // Score badge
            const badge_x = task_x + TASK_WIDTH / 2;
            const badge_y = task_y + TASK_HEIGHT - SCORE_RADIUS - 4;
            rl.drawCircleV(
                .{ .x = badge_x, .y = badge_y - scroll_y },
                SCORE_RADIUS,
                score_color,
            );
            // Score number
            var score_buf: [4]u8 = undefined;
            const score_str = std.fmt.bufPrint(&score_buf, "{d}", .{task.score}) catch "?";
            drawText(
                score_str,
                badge_x,
                badge_y,
                fonts,
                theme.body_font_size * 0.7,
                rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
                scroll_y,
                true,
            );

            // Draw connecting line to next task
            if (task_x > origin_x + DIAGRAM_PADDING + 10) {
                // Line from previous task to this one
                rl.drawLineEx(
                    .{ .x = task_x - TASK_SPACING, .y = task_y + TASK_HEIGHT / 2 - scroll_y },
                    .{ .x = task_x, .y = task_y + TASK_HEIGHT / 2 - scroll_y },
                    2,
                    withAlpha(theme.mermaid_node_border, 150),
                );
            }

            // Actors below the task
            if (task.actors.items.len > 0) {
                var actor_y = task_y + TASK_HEIGHT + 4;
                for (task.actors.items) |actor| {
                    drawText(
                        actor,
                        task_x + TASK_WIDTH / 2,
                        actor_y,
                        fonts,
                        theme.body_font_size * 0.6,
                        withAlpha(theme.mermaid_node_text, 180),
                        scroll_y,
                        true,
                    );
                    actor_y += theme.body_font_size * 0.6 + 2;
                }
            }

            task_x += TASK_WIDTH + TASK_SPACING;
        }

        cur_y += TASK_HEIGHT + 30;
        // Extra space for actors
        var max_actors: usize = 0;
        for (section.tasks.items) |task| {
            max_actors = @max(max_actors, task.actors.items.len);
        }
        if (max_actors > 0) {
            cur_y += @as(f32, @floatFromInt(max_actors)) * (theme.body_font_size * 0.6 + 2);
        }
    }
}

fn drawText(
    text: []const u8,
    x: f32,
    y: f32,
    fonts: *const Fonts,
    font_size: f32,
    color: rl.Color,
    scroll_y: f32,
    center: bool,
) void {
    if (text.len == 0) return;

    var buf: [256]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];

    const font = fonts.selectFont(.{});
    const spacing = font_size / 10.0;
    const measured = rl.measureTextEx(font, z, font_size, spacing);

    const tx = if (center) x - measured.x / 2 else x;
    const ty = y - scroll_y - measured.y / 2;

    rl.drawTextEx(font, z, .{ .x = tx, .y = ty }, font_size, spacing, color);
}

fn withAlpha(c: rl.Color, a: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}
