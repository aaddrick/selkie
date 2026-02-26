const rl = @import("raylib");
const std = @import("std");
const gg = @import("../models/gitgraph_model.zig");
const GitGraphModel = gg.GitGraphModel;
const CommitType = gg.CommitType;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;

const LANE_SPACING: f32 = 30;
const COMMIT_SPACING: f32 = 50;
const COMMIT_RADIUS: f32 = 8;
const DIAGRAM_PADDING: f32 = 20;
const BRANCH_LABEL_WIDTH: f32 = 80;
const TAG_HEIGHT: f32 = 20;

pub fn drawGitGraph(
    model: *const GitGraphModel,
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

    if (model.commits.items.len == 0) return;

    const is_lr = model.orientation == .lr;
    const start_x = origin_x + DIAGRAM_PADDING + BRANCH_LABEL_WIDTH;
    const start_y = origin_y + DIAGRAM_PADDING + 20;

    // Draw branch lane lines
    for (model.branches.items) |branch| {
        const lane_f: f32 = @floatFromInt(branch.lane);
        if (is_lr) {
            const ly = start_y + lane_f * LANE_SPACING;
            rl.drawLineEx(
                .{ .x = start_x, .y = ly - scroll_y },
                .{ .x = origin_x + diagram_width - DIAGRAM_PADDING, .y = ly - scroll_y },
                2,
                withAlpha(branch.color, 80),
            );
            // Branch label
            drawText(branch.name, origin_x + DIAGRAM_PADDING, ly, fonts, theme.body_font_size * 0.8, branch.color, scroll_y, false);
        } else {
            const lx = start_x + lane_f * LANE_SPACING;
            rl.drawLineEx(
                .{ .x = lx, .y = start_y - scroll_y },
                .{ .x = lx, .y = origin_y + diagram_height - DIAGRAM_PADDING - scroll_y },
                2,
                withAlpha(branch.color, 80),
            );
            // Branch label
            drawText(branch.name, lx, origin_y + DIAGRAM_PADDING, fonts, theme.body_font_size * 0.8, branch.color, scroll_y, true);
        }
    }

    // Draw merge lines
    for (model.merges.items) |merge| {
        if (merge.from_commit >= model.commits.items.len or merge.to_commit >= model.commits.items.len) continue;

        const from = model.commits.items[merge.from_commit];
        const to = model.commits.items[merge.to_commit];

        var from_x: f32 = undefined;
        var from_y: f32 = undefined;
        var to_x: f32 = undefined;
        var to_y: f32 = undefined;

        if (is_lr) {
            from_x = start_x + @as(f32, @floatFromInt(from.seq)) * COMMIT_SPACING;
            from_y = start_y + @as(f32, @floatFromInt(from.lane)) * LANE_SPACING;
            to_x = start_x + @as(f32, @floatFromInt(to.seq)) * COMMIT_SPACING;
            to_y = start_y + @as(f32, @floatFromInt(to.lane)) * LANE_SPACING;
        } else {
            from_x = start_x + @as(f32, @floatFromInt(from.lane)) * LANE_SPACING;
            from_y = start_y + @as(f32, @floatFromInt(from.seq)) * COMMIT_SPACING;
            to_x = start_x + @as(f32, @floatFromInt(to.lane)) * LANE_SPACING;
            to_y = start_y + @as(f32, @floatFromInt(to.seq)) * COMMIT_SPACING;
        }

        // Determine merge line color from the source branch
        var merge_color = rl.Color{ .r = 150, .g = 150, .b = 150, .a = 200 };
        if (model.findBranch(merge.from_branch)) |bidx| {
            merge_color = withAlpha(model.branches.items[bidx].color, 200);
        }

        rl.drawLineEx(
            .{ .x = from_x, .y = from_y - scroll_y },
            .{ .x = to_x, .y = to_y - scroll_y },
            2,
            merge_color,
        );
    }

    // Draw commits
    for (model.commits.items) |commit| {
        var cx: f32 = undefined;
        var cy: f32 = undefined;

        if (is_lr) {
            cx = start_x + @as(f32, @floatFromInt(commit.seq)) * COMMIT_SPACING;
            cy = start_y + @as(f32, @floatFromInt(commit.lane)) * LANE_SPACING;
        } else {
            cx = start_x + @as(f32, @floatFromInt(commit.lane)) * LANE_SPACING;
            cy = start_y + @as(f32, @floatFromInt(commit.seq)) * COMMIT_SPACING;
        }

        // Get branch color
        var commit_color = rl.Color{ .r = 100, .g = 100, .b = 200, .a = 255 };
        if (model.findBranch(commit.branch)) |bidx| {
            commit_color = model.branches.items[bidx].color;
        }

        const sy = cy - scroll_y;

        // Draw commit dot
        switch (commit.commit_type) {
            .normal => {
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS, commit_color);
                rl.drawCircleLinesV(.{ .x = cx, .y = sy }, COMMIT_RADIUS, darken(commit_color));
            },
            .highlight => {
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS + 2, commit_color);
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS - 2, theme.mermaid_subgraph_bg);
                rl.drawCircleLinesV(.{ .x = cx, .y = sy }, COMMIT_RADIUS + 2, darken(commit_color));
            },
            .reverse => {
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS, darken(commit_color));
                // Cross pattern
                const r: f32 = COMMIT_RADIUS * 0.5;
                rl.drawLineEx(
                    .{ .x = cx - r, .y = sy - r },
                    .{ .x = cx + r, .y = sy + r },
                    2,
                    theme.mermaid_subgraph_bg,
                );
                rl.drawLineEx(
                    .{ .x = cx + r, .y = sy - r },
                    .{ .x = cx - r, .y = sy + r },
                    2,
                    theme.mermaid_subgraph_bg,
                );
            },
        }

        // Draw tag label
        if (commit.tag.len > 0) {
            const tag_y = if (is_lr) sy - COMMIT_RADIUS - TAG_HEIGHT else sy;
            const tag_x = if (is_lr) cx else cx + COMMIT_RADIUS + 4;
            drawTagLabel(commit.tag, tag_x, tag_y, fonts, theme, is_lr);
        }

        // Draw commit id/message below/right of the dot
        const label = if (commit.message.len > 0) commit.message else commit.id;
        if (label.len > 0) {
            if (is_lr) {
                drawText(label, cx - 15, cy + COMMIT_RADIUS + 4, fonts, theme.body_font_size * 0.7, theme.mermaid_node_text, scroll_y, false);
            } else {
                drawText(label, cx + COMMIT_RADIUS + 4, cy, fonts, theme.body_font_size * 0.7, theme.mermaid_node_text, scroll_y, false);
            }
        }
    }
}

fn drawTagLabel(text: []const u8, x: f32, y: f32, fonts: *const Fonts, theme: *const Theme, _: bool) void {
    if (text.len == 0) return;

    var buf: [128]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];

    const font = fonts.selectFont(.{});
    const font_size = theme.body_font_size * 0.7;
    const spacing = font_size / 10.0;
    const measured = rl.measureTextEx(font, z, font_size, spacing);

    const pad: f32 = 4;
    // Tag background
    rl.drawRectangleRounded(.{
        .x = x - pad,
        .y = y - pad,
        .width = measured.x + pad * 2,
        .height = measured.y + pad * 2,
    }, 0.3, 4, rl.Color{ .r = 255, .g = 215, .b = 0, .a = 200 });

    rl.drawTextEx(font, z, .{ .x = x, .y = y }, font_size, spacing, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
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

fn darken(c: rl.Color) rl.Color {
    return .{
        .r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(c.r)) * 0.7)),
        .g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(c.g)) * 0.7)),
        .b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(c.b)) * 0.7)),
        .a = c.a,
    };
}

fn withAlpha(c: rl.Color, a: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}
