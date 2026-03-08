const rl = @import("raylib");
const std = @import("std");
const gg = @import("../models/gitgraph_model.zig");
const GitGraphModel = gg.GitGraphModel;
const CommitType = gg.CommitType;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");

const COMMIT_RADIUS: f32 = 8;
const TAG_HEIGHT: f32 = 20;
const ARROW_SIZE: f32 = 8;
const MERGE_LINE_WIDTH: f32 = 2;
/// Alpha for branch origin connector lines (semi-transparent, lighter than branch connectors)
const BRANCH_ORIGIN_ALPHA: u8 = 160;
/// Alpha for same-branch connector lines
const BRANCH_CONNECTOR_ALPHA: u8 = 200;

// =============================================================================
// Pure geometry helpers (no raylib drawing side effects)
// =============================================================================

/// Triangle vertices for an arrowhead.
/// Exposed so geometry can be tested without a raylib OpenGL context.
const ArrowHeadPoints = struct {
    tip: rl.Vector2,
    /// Left wing vertex (relative to arrow direction)
    p1: rl.Vector2,
    /// Right wing vertex (relative to arrow direction)
    p2: rl.Vector2,
};

/// Compute the triangle vertices for a filled arrowhead that points from
/// `(from_x, from_y)` toward `(tip_x, tip_y)`.
///
/// Returns null when the source and tip positions are identical (zero-length
/// direction vector).  This is a pure function — no drawing side effects.
fn computeArrowHeadPoints(tip_x: f32, tip_y: f32, from_x: f32, from_y: f32) ?ArrowHeadPoints {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return null;

    const nx = dx / len;
    const ny = dy / len;
    const half_w: f32 = ARROW_SIZE * 0.5;

    return .{
        .tip = .{ .x = tip_x, .y = tip_y },
        .p1 = .{
            .x = tip_x - ARROW_SIZE * nx + half_w * ny,
            .y = tip_y - ARROW_SIZE * ny - half_w * nx,
        },
        .p2 = .{
            .x = tip_x - ARROW_SIZE * nx - half_w * ny,
            .y = tip_y - ARROW_SIZE * ny + half_w * nx,
        },
    };
}

/// Elbow routing points for a merge/origin connector line.
/// `from` is the start of the first segment, `elbow` is the bend corner,
/// and `to` is the end of the second segment.
const ElbowPoints = struct {
    from: rl.Vector2,
    elbow: rl.Vector2,
    to: rl.Vector2,
};

/// Compute the three anchor points of an elbow-style connector.
///
/// For LR orientation the first segment runs horizontally (along the commit
/// axis) to `(to_x, from_y)`, then vertically to `(to_x, to_y)`.
/// For TB orientation the first segment runs vertically to `(from_x, to_y)`,
/// then horizontally to `(to_x, to_y)`.
///
/// `scroll_y` is applied to y values so the returned coordinates are in
/// screen space.  Pure function — no drawing side effects.
fn computeElbowPoints(
    from_x: f32,
    from_y: f32,
    to_x: f32,
    to_y: f32,
    scroll_y: f32,
    is_lr: bool,
) ElbowPoints {
    const sy_from = from_y - scroll_y;
    const sy_to = to_y - scroll_y;
    if (is_lr) {
        return .{
            .from = .{ .x = from_x, .y = sy_from },
            .elbow = .{ .x = to_x, .y = sy_from },
            .to = .{ .x = to_x, .y = sy_to },
        };
    } else {
        return .{
            .from = .{ .x = from_x, .y = sy_from },
            .elbow = .{ .x = from_x, .y = sy_to },
            .to = .{ .x = to_x, .y = sy_to },
        };
    }
}

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
    const lane_spacing = model.effective_lane_spacing;
    const eff_padding = model.effective_padding;
    const eff_label_w = model.effective_branch_label_w;
    const eff_header = model.effective_header_offset;

    // Draw branch lane lines (faded background guides) and branch labels.
    // The lane line starts at `branch.lane_start_x` (LR) / `branch.lane_start_y`
    // (TB), which the layout engine sets to the commit from which this branch
    // diverged.  For the first branch (main) this equals the diagram's left/top
    // edge; for feature branches it is the x/y of the parent-branch commit at
    // the point of divergence.
    for (model.branches.items) |branch| {
        const lane_f: f32 = @floatFromInt(branch.lane);
        if (is_lr) {
            const ly = origin_y + eff_padding + eff_header + lane_f * lane_spacing;
            // Use the layout-computed lane start position so the line begins at
            // the branch divergence point, not always at the diagram left edge.
            const ls_x = origin_x + branch.lane_start_x;
            rl.drawLineEx(
                .{ .x = ls_x, .y = ly - scroll_y },
                .{ .x = origin_x + diagram_width - eff_padding, .y = ly - scroll_y },
                1.5,
                ru.withAlpha(branch.color, 60),
            );
            // Branch label (left margin, always at the fixed label column)
            ru.drawText(branch.name, origin_x + eff_padding, ly, fonts, theme.body_font_size * 0.8, branch.color, scroll_y, false);
        } else {
            const lx = origin_x + eff_padding + eff_label_w + lane_f * lane_spacing;
            // Use the layout-computed lane start position for TB orientation.
            const ls_y = origin_y + branch.lane_start_y;
            rl.drawLineEx(
                .{ .x = lx, .y = ls_y - scroll_y },
                .{ .x = lx, .y = origin_y + diagram_height - eff_padding - scroll_y },
                1.5,
                ru.withAlpha(branch.color, 60),
            );
            // Branch label (top margin)
            ru.drawText(branch.name, lx, origin_y + eff_padding, fonts, theme.body_font_size * 0.8, branch.color, scroll_y, true);
        }
    }

    // Draw branch origin connectors: elbow lines from a parent commit on one branch
    // to the first commit on a child branch. These visually show where branches
    // diverge. Drawn before branch connectors so they appear underneath.
    drawBranchOriginConnectors(model, origin_x, origin_y, scroll_y, is_lr);

    // Draw connector lines between consecutive commits on the same branch.
    // This visually links commits along a branch with the branch color.
    drawBranchConnectors(model, origin_x, origin_y, scroll_y);

    // Draw merge arrows (elbow-style with arrowhead at target)
    for (model.merges.items) |merge| {
        if (merge.from_commit >= model.commits.items.len or merge.to_commit >= model.commits.items.len) continue;

        const from = model.commits.items[merge.from_commit];
        const to = model.commits.items[merge.to_commit];

        const from_x = origin_x + from.x;
        const from_y = origin_y + from.y;
        const to_x = origin_x + to.x;
        const to_y = origin_y + to.y;

        // Determine merge line color from the source branch
        var merge_color = rl.Color{ .r = 150, .g = 150, .b = 150, .a = 200 };
        if (model.findBranch(merge.from_branch)) |bidx| {
            merge_color = ru.withAlpha(model.branches.items[bidx].color, 200);
        }

        // Draw elbow-style merge line with arrowhead
        drawMergeArrow(from_x, from_y, to_x, to_y, merge_color, scroll_y, is_lr);
    }

    // Draw commits (on top of lines so they're visually prominent)
    for (model.commits.items) |commit| {
        const cx = origin_x + commit.x;
        const cy = origin_y + commit.y;

        // Get branch color
        var commit_color = rl.Color{ .r = 100, .g = 100, .b = 200, .a = 255 };
        if (model.findBranch(commit.branch)) |bidx| {
            commit_color = model.branches.items[bidx].color;
        }

        const sy = cy - scroll_y;

        // Draw commit dot with style based on commit type
        switch (commit.commit_type) {
            .normal => {
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS, commit_color);
                rl.drawCircleLinesV(.{ .x = cx, .y = sy }, COMMIT_RADIUS, ru.darken(commit_color));
            },
            .highlight => {
                // Double-ring style: outer ring + inner dot + inner background
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS + 3, commit_color);
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS, theme.mermaid_subgraph_bg);
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS - 3, commit_color);
                rl.drawCircleLinesV(.{ .x = cx, .y = sy }, COMMIT_RADIUS + 3, ru.darken(commit_color));
            },
            .reverse => {
                // Dark filled circle with X pattern (inverted commit)
                rl.drawCircleV(.{ .x = cx, .y = sy }, COMMIT_RADIUS, ru.darken(commit_color));
                rl.drawCircleLinesV(.{ .x = cx, .y = sy }, COMMIT_RADIUS, commit_color);
                // Cross pattern
                const r: f32 = COMMIT_RADIUS * 0.55;
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

        // Draw commit id/message below (LR) or to the right (TB) of the dot
        const label = if (commit.message.len > 0) commit.message else commit.id;
        if (label.len > 0) {
            if (is_lr) {
                ru.drawText(label, cx, cy + COMMIT_RADIUS + 10, fonts, theme.body_font_size * 0.7, theme.mermaid_node_text, scroll_y, true);
            } else {
                ru.drawText(label, cx + COMMIT_RADIUS + 6, cy, fonts, theme.body_font_size * 0.7, theme.mermaid_node_text, scroll_y, false);
            }
        }
    }

    // Draw tag badges using the layout-computed positions from model.tags.
    // Drawing tags last ensures they appear above commit dots and connectors.
    for (model.tags.items) |tag| {
        const tx = origin_x + tag.x;
        const ty = origin_y + tag.y - scroll_y;
        drawTagLabel(tag.label, tx, ty, fonts, theme);
    }
}

/// Draw elbow-style connectors from a commit on one branch to the first commit
/// on a branch that diverged from it. These "branch origin" lines show visually
/// where new branches split off from their parent branch.
///
/// Algorithm: iterate every commit's parent list. If a parent commit is on a
/// *different* branch than the current commit, and it is NOT already rendered as
/// a merge arrow (i.e. it is not the `from_commit` of any MergeInfo targeting
/// this commit), draw an elbow from the parent to the current commit using the
/// child branch's color.
fn drawBranchOriginConnectors(
    model: *const GitGraphModel,
    origin_x: f32,
    origin_y: f32,
    scroll_y: f32,
    is_lr: bool,
) void {
    for (model.commits.items, 0..) |commit, commit_idx| {
        for (commit.parents.items) |parent_id| {
            const parent_idx = model.findCommitById(parent_id) orelse continue;
            const parent = model.commits.items[parent_idx];

            // Only draw for cross-branch parent relationships
            if (std.mem.eql(u8, parent.branch, commit.branch)) continue;

            // Skip if this cross-branch connection is already a merge arrow.
            // A merge arrow is drawn for MergeInfo entries where from_commit=parent_idx
            // and to_commit=commit_idx.
            var is_merge_arrow = false;
            for (model.merges.items) |merge| {
                if (merge.from_commit == parent_idx and merge.to_commit == commit_idx) {
                    is_merge_arrow = true;
                    break;
                }
            }
            if (is_merge_arrow) continue;

            // Use the child branch color for the origin connector
            var color = rl.Color{ .r = 150, .g = 150, .b = 150, .a = BRANCH_ORIGIN_ALPHA };
            if (model.findBranch(commit.branch)) |bidx| {
                color = ru.withAlpha(model.branches.items[bidx].color, BRANCH_ORIGIN_ALPHA);
            }

            const from_x = origin_x + parent.x;
            const from_y = origin_y + parent.y;
            const to_x = origin_x + commit.x;
            const to_y = origin_y + commit.y;

            // Draw elbow-style line (same routing as merge arrows, but no arrowhead)
            drawElbowLine(from_x, from_y, to_x, to_y, color, scroll_y, is_lr, MERGE_LINE_WIDTH);
        }
    }
}

/// Draw connector lines between consecutive commits on the same branch.
/// Connects each commit to the next commit on its branch with a solid colored line.
fn drawBranchConnectors(model: *const GitGraphModel, origin_x: f32, origin_y: f32, scroll_y: f32) void {
    const commits = model.commits.items;
    if (commits.len < 2) return;

    // For each commit, find the next commit on the same branch and draw a connector
    for (commits, 0..) |commit, i| {
        // Look forward for the next commit on the same branch
        for (commits[i + 1 ..]) |next| {
            if (std.mem.eql(u8, commit.branch, next.branch)) {
                const from_x = origin_x + commit.x;
                const from_y = origin_y + commit.y - scroll_y;
                const to_x = origin_x + next.x;
                const to_y = origin_y + next.y - scroll_y;

                var color = rl.Color{ .r = 100, .g = 100, .b = 200, .a = 255 };
                if (model.findBranch(commit.branch)) |bidx| {
                    color = model.branches.items[bidx].color;
                }

                rl.drawLineEx(
                    .{ .x = from_x, .y = from_y },
                    .{ .x = to_x, .y = to_y },
                    MERGE_LINE_WIDTH,
                    ru.withAlpha(color, BRANCH_CONNECTOR_ALPHA),
                );
                break; // only connect to the immediately next commit on same branch
            }
        }
    }
}

/// Draw a merge arrow with an elbow-style path and arrowhead.
///
/// For LR (left-to-right) orientation:
///   from -> horizontal to target x -> vertical to target y (with arrow)
/// For TB (top-to-bottom) orientation:
///   from -> vertical to target y -> horizontal to target x (with arrow)
///
/// The arrowhead points toward the merge target commit.
fn drawMergeArrow(
    from_x: f32,
    from_y: f32,
    to_x: f32,
    to_y: f32,
    color: rl.Color,
    scroll_y: f32,
    is_lr: bool,
) void {
    const ep = computeElbowPoints(from_x, from_y, to_x, to_y, scroll_y, is_lr);
    // First segment: from → elbow
    rl.drawLineEx(ep.from, ep.elbow, MERGE_LINE_WIDTH, color);
    // Second segment: elbow → to
    rl.drawLineEx(ep.elbow, ep.to, MERGE_LINE_WIDTH, color);
    // Arrowhead at the target end, pointing from the elbow corner
    drawArrowHead(ep.to.x, ep.to.y, ep.elbow.x, ep.elbow.y, color);
}

/// Draw an elbow-style line (same routing as merge arrows) but WITHOUT an arrowhead.
/// Used for branch origin connectors.
fn drawElbowLine(
    from_x: f32,
    from_y: f32,
    to_x: f32,
    to_y: f32,
    color: rl.Color,
    scroll_y: f32,
    is_lr: bool,
    line_width: f32,
) void {
    const ep = computeElbowPoints(from_x, from_y, to_x, to_y, scroll_y, is_lr);
    rl.drawLineEx(ep.from, ep.elbow, line_width, color);
    rl.drawLineEx(ep.elbow, ep.to, line_width, color);
}

/// Draw a filled triangular arrowhead at the tip, pointing from `from` toward `tip`.
fn drawArrowHead(tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, color: rl.Color) void {
    const pts = computeArrowHeadPoints(tip_x, tip_y, from_x, from_y) orelse return;
    rl.drawTriangle(pts.tip, pts.p2, pts.p1, color);
}

/// Draw a tag label box above/beside a commit dot.
/// Uses a golden background with rounded corners to visually distinguish tags.
fn drawTagLabel(text: []const u8, x: f32, y: f32, fonts: *const Fonts, theme: *const Theme) void {
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
    // Tag background (golden rounded rectangle)
    rl.drawRectangleRounded(.{
        .x = x - pad,
        .y = y - pad,
        .width = measured.x + pad * 2,
        .height = measured.y + pad * 2,
    }, 0.3, 4, rl.Color{ .r = 255, .g = 215, .b = 0, .a = 220 });

    // Tag border (slightly darker gold)
    rl.drawRectangleRoundedLinesEx(.{
        .x = x - pad,
        .y = y - pad,
        .width = measured.x + pad * 2,
        .height = measured.y + pad * 2,
    }, 0.3, 4, 1.5, rl.Color{ .r = 180, .g = 140, .b = 0, .a = 220 });

    // Tag text (black for contrast against gold background)
    rl.drawTextEx(font, z, .{ .x = x, .y = y }, font_size, spacing, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// ---------------------------------------------------------------------------
// Pure geometry tests (no raylib context required)
// ---------------------------------------------------------------------------

test "computeArrowHeadPoints returns null for zero-length vector" {
    // When tip == from the direction vector is undefined; must return null.
    const result = computeArrowHeadPoints(100, 100, 100, 100);
    try testing.expect(result == null);
}

test "computeArrowHeadPoints tip is preserved exactly" {
    const pts = computeArrowHeadPoints(200, 100, 100, 100).?;
    try testing.expectEqual(@as(f32, 200), pts.tip.x);
    try testing.expectEqual(@as(f32, 100), pts.tip.y);
}

test "computeArrowHeadPoints wing vertices symmetric for horizontal arrow" {
    // Arrow pointing right: from (100,100) to tip (200,100).
    const pts = computeArrowHeadPoints(200, 100, 100, 100).?;
    // p1 and p2 should be symmetric about the horizontal axis.
    try testing.expectApproxEqAbs(pts.p1.y + pts.p2.y, 2.0 * pts.tip.y - 2.0 * ARROW_SIZE * 0.0, 0.01);
    // Both wing-points must lie to the LEFT of the tip (behind the arrowhead).
    try testing.expect(pts.p1.x < pts.tip.x);
    try testing.expect(pts.p2.x < pts.tip.x);
}

test "computeArrowHeadPoints wing separation equals ARROW_SIZE" {
    // The distance between p1 and p2 (the "base width" of the triangle)
    // should be ARROW_SIZE because half_w = ARROW_SIZE * 0.5 on each side.
    const pts = computeArrowHeadPoints(200, 100, 100, 100).?;
    const dx = pts.p1.x - pts.p2.x;
    const dy = pts.p1.y - pts.p2.y;
    const wing_len = @sqrt(dx * dx + dy * dy);
    try testing.expectApproxEqAbs(wing_len, ARROW_SIZE, 0.01);
}

test "computeArrowHeadPoints works for vertical arrow" {
    // Arrow pointing down: from (100,100) to tip (100,200).
    const pts = computeArrowHeadPoints(100, 200, 100, 100).?;
    try testing.expectEqual(@as(f32, 100), pts.tip.x);
    try testing.expectEqual(@as(f32, 200), pts.tip.y);
    // Both wings should be above the tip (y < tip.y).
    try testing.expect(pts.p1.y < pts.tip.y);
    try testing.expect(pts.p2.y < pts.tip.y);
}

test "computeArrowHeadPoints works for diagonal arrow" {
    const pts = computeArrowHeadPoints(150, 150, 100, 100).?;
    try testing.expect(pts.p1.x != pts.tip.x or pts.p1.y != pts.tip.y);
    try testing.expect(pts.p2.x != pts.tip.x or pts.p2.y != pts.tip.y);
    // p1 ≠ p2
    try testing.expect(pts.p1.x != pts.p2.x or pts.p1.y != pts.p2.y);
}

test "computeElbowPoints LR: first segment horizontal, second vertical" {
    const ep = computeElbowPoints(100, 100, 200, 150, 0, true);
    // In LR mode: from.y == elbow.y (horizontal segment)
    try testing.expectEqual(ep.from.y, ep.elbow.y);
    // elbow.x == to.x (vertical second segment)
    try testing.expectEqual(ep.elbow.x, ep.to.x);
    // Endpoints match input (no scroll)
    try testing.expectEqual(@as(f32, 100), ep.from.x);
    try testing.expectEqual(@as(f32, 100), ep.from.y);
    try testing.expectEqual(@as(f32, 200), ep.to.x);
    try testing.expectEqual(@as(f32, 150), ep.to.y);
}

test "computeElbowPoints TB: first segment vertical, second horizontal" {
    const ep = computeElbowPoints(100, 100, 150, 200, 0, false);
    // In TB mode: from.x == elbow.x (vertical segment)
    try testing.expectEqual(ep.from.x, ep.elbow.x);
    // elbow.y == to.y (horizontal second segment)
    try testing.expectEqual(ep.elbow.y, ep.to.y);
    try testing.expectEqual(@as(f32, 100), ep.from.x);
    try testing.expectEqual(@as(f32, 100), ep.from.y);
    try testing.expectEqual(@as(f32, 150), ep.to.x);
    try testing.expectEqual(@as(f32, 200), ep.to.y);
}

test "computeElbowPoints scroll_y applied to y coordinates" {
    const ep = computeElbowPoints(100, 200, 200, 300, 50, true);
    // All y values should be shifted by -scroll_y
    try testing.expectEqual(@as(f32, 150), ep.from.y); // 200 - 50
    try testing.expectEqual(@as(f32, 150), ep.elbow.y); // 200 - 50
    try testing.expectEqual(@as(f32, 250), ep.to.y); // 300 - 50
    // x values unaffected
    try testing.expectEqual(@as(f32, 100), ep.from.x);
    try testing.expectEqual(@as(f32, 200), ep.to.x);
}

test "computeElbowPoints same from/to coordinates does not crash" {
    const ep_lr = computeElbowPoints(100, 100, 100, 100, 0, true);
    try testing.expectEqual(ep_lr.from.x, ep_lr.to.x);
    try testing.expectEqual(ep_lr.from.y, ep_lr.to.y);

    const ep_tb = computeElbowPoints(100, 100, 100, 100, 0, false);
    try testing.expectEqual(ep_tb.from.x, ep_tb.to.x);
    try testing.expectEqual(ep_tb.from.y, ep_tb.to.y);
}

// ---------------------------------------------------------------------------
// Drawing function tests (require raylib context — skipped in unit tests)
// ---------------------------------------------------------------------------

test "drawArrowHead does not crash with zero-length vector" {
    // When tip == from, computeArrowHeadPoints returns null → early return.
    // Safe without a raylib context since no drawing is performed.
    drawArrowHead(100, 100, 100, 100, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "drawArrowHead does not crash with valid points" {
    if (!rl.isWindowReady()) return; // Requires an active OpenGL context
    drawArrowHead(200, 100, 100, 100, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
    drawArrowHead(100, 200, 100, 100, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
    drawArrowHead(150, 150, 100, 100, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "drawMergeArrow does not crash LR orientation" {
    if (!rl.isWindowReady()) return;
    drawMergeArrow(100, 100, 200, 150, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 200 }, 0, true);
}

test "drawMergeArrow does not crash TB orientation" {
    if (!rl.isWindowReady()) return;
    drawMergeArrow(100, 100, 150, 200, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 200 }, 0, false);
}

test "drawMergeArrow same position does not crash" {
    if (!rl.isWindowReady()) return;
    drawMergeArrow(100, 100, 100, 100, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 200 }, 0, true);
    drawMergeArrow(100, 100, 100, 100, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 200 }, 0, false);
}

test "drawMergeArrow with scroll offset" {
    if (!rl.isWindowReady()) return;
    drawMergeArrow(100, 200, 200, 300, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 200 }, 50, true);
}

test "drawElbowLine does not crash LR" {
    if (!rl.isWindowReady()) return;
    drawElbowLine(50, 50, 200, 100, rl.Color{ .r = 100, .g = 180, .b = 100, .a = 160 }, 0, true, 2);
}

test "drawElbowLine does not crash TB" {
    if (!rl.isWindowReady()) return;
    drawElbowLine(50, 50, 100, 200, rl.Color{ .r = 100, .g = 180, .b = 100, .a = 160 }, 0, false, 2);
}

test "drawElbowLine same position does not crash" {
    if (!rl.isWindowReady()) return;
    drawElbowLine(100, 100, 100, 100, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 160 }, 0, true, 2);
}

test "drawElbowLine with scroll offset" {
    if (!rl.isWindowReady()) return;
    drawElbowLine(100, 200, 250, 300, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 160 }, 75, true, 2);
}

test "drawBranchOriginConnectors does not crash on empty model" {
    const allocator = testing.allocator;
    var model = gg.GitGraphModel.init(allocator);
    defer model.deinit();
    // No commits → nothing to draw, should return immediately
    drawBranchOriginConnectors(&model, 0, 0, 0, true);
}

test "drawBranchOriginConnectors does not crash with single-branch commits" {
    const allocator = testing.allocator;
    var model = gg.GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c1 = gg.Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    c1.x = 100;
    c1.y = 50;
    try model.appendCommit(&c1);

    var c2 = gg.Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "main";
    c2.x = 150;
    c2.y = 50;
    try model.appendCommit(&c2);

    // All commits are on the same branch → no origin connectors to draw
    drawBranchOriginConnectors(&model, 0, 0, 0, true);
}

test "drawBranchOriginConnectors does not crash with cross-branch parent" {
    const allocator = testing.allocator;
    var model = gg.GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feature");

    var c1 = gg.Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    c1.x = 100;
    c1.y = 30;
    try model.appendCommit(&c1);

    // Branch origin: first feature commit has c1 (on main) as parent
    // Simulate by setting feature head to c1 before adding c2
    try model.branch_heads.put("feature", 0);

    var c2 = gg.Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "feature";
    c2.x = 150;
    c2.y = 60;
    try model.appendCommit(&c2);

    // c2 should have c1 as parent (cross-branch) → origin connector drawn
    if (!rl.isWindowReady()) return; // drawElbowLine requires OpenGL context
    drawBranchOriginConnectors(&model, 0, 0, 0, true);
    drawBranchOriginConnectors(&model, 0, 0, 0, false);
}

test "drawBranchOriginConnectors skips merge connections" {
    const allocator = testing.allocator;
    var model = gg.GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feature");

    // c1 on main
    var c1 = gg.Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    c1.x = 100;
    c1.y = 30;
    try model.appendCommit(&c1);

    // c2 on feature (branch origin from c1)
    try model.branch_heads.put("feature", 0);
    var c2 = gg.Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "feature";
    c2.x = 150;
    c2.y = 60;
    try model.appendCommit(&c2);

    // Merge commit on main: parents are c1 (main) and c2 (feature)
    var merge_c = gg.Commit.init(allocator);
    merge_c.id = "m1";
    merge_c.branch = "main";
    merge_c.x = 200;
    merge_c.y = 30;
    try model.appendMergeCommit(&merge_c, "feature");

    // Should not crash — merge connections are filtered out, only c1→c2 origin drawn
    if (!rl.isWindowReady()) return; // drawElbowLine requires OpenGL context
    drawBranchOriginConnectors(&model, 0, 0, 0, true);
}

test "drawBranchConnectors does not crash on empty model" {
    const allocator = testing.allocator;
    var model = gg.GitGraphModel.init(allocator);
    defer model.deinit();
    drawBranchConnectors(&model, 0, 0, 0);
}

test "drawBranchConnectors does not crash with single commit" {
    const allocator = testing.allocator;
    var model = gg.GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    var c = gg.Commit.init(allocator);
    c.id = "c1";
    c.branch = "main";
    c.x = 100;
    c.y = 50;
    try model.appendCommit(&c);

    drawBranchConnectors(&model, 0, 0, 0);
}
