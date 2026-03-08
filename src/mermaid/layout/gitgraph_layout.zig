const std = @import("std");
const Allocator = std.mem.Allocator;
const gg = @import("../models/gitgraph_model.zig");
const GitGraphModel = gg.GitGraphModel;
const Commit = gg.Commit;
const Branch = gg.Branch;
const Orientation = gg.Orientation;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const Theme = @import("../../theme/theme.zig").Theme;

// ---------------------------------------------------------------------------
// Visual constants kept in sync with gitgraph_renderer.zig
// ---------------------------------------------------------------------------
const commit_radius: f32 = 8;
const tag_height: f32 = 20;

// ---------------------------------------------------------------------------
// Layout constants — tuned for readable gitgraph diagrams
// ---------------------------------------------------------------------------
const default_lane_spacing: f32 = 30;
/// Wider spacing used when at least one commit carries a tag annotation.
/// The badge is drawn above (LR) or beside (TB) the commit dot; without extra
/// clearance it would overlap the adjacent branch lane line.
const tagged_lane_spacing: f32 = tag_height + commit_radius * 2 + 10; // ≈46
const default_commit_spacing: f32 = 50;
const padding: f32 = 20;
const min_branch_label_w: f32 = 80;
const header_offset: f32 = 20;
/// Extra top margin (LR) reserved for tag badges above the first commit row.
const tag_top_margin: f32 = tag_height + 4;
const tail_margin: f32 = 40;

pub const LayoutResult = struct {
    width: f32,
    height: f32,
};

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Assign x/y positions to every commit, tag badge, and branch label/lane-start,
/// then store effective spacing values on the model for the renderer.
///
/// ## Algorithm
///
/// 1. Determine adaptive lane spacing: wider when any commit carries a tag badge.
/// 2. Measure branch label widths to determine the left-margin column size.
/// 3. Compute topological slot positions for every commit via a single forward
///    pass over the insertion-order commit list (already topologically sorted):
///      - slot(commit) = max(slot(parent)) + 1   when parents are wired.
///      - slot(commit) = commit.seq               for parentless commits
///                                                (backward-compat for test data).
///    Two commits with the same sole parent land in the same slot, producing a
///    compact "diamond" shape for parallel branches diverging from one point.
///    Merge targets always appear right of / below both their parents.
/// 4. Assign (x, y) coordinates from (slot, lane) pairs:
///      LR orientation → x = commit-axis, y = lane-axis.
///      TB orientation → x = lane-axis,   y = commit-axis.
/// 5. Assign branch label positions beside their respective lane lines.
/// 6. Compute branch lane-start positions: each branch's lane line begins at
///    the parent-branch commit from which it diverged, not at the diagram edge.
/// 7. Compute tag badge positions (stored on Tag entities in model.tags):
///      LR → badge is commit_radius + tag_height above the commit dot.
///      TB → badge is commit_radius + 4 to the right of the commit dot.
/// 8. Scale all positions proportionally when the natural width > available_width.
/// 9. Store effective (post-scale) spacing constants on the model.
///
/// Merge edge paths are rendered directly between from/to commit coordinates
/// stored in MergeInfo; no additional routing is done here.
pub fn layout(
    model: *GitGraphModel,
    fonts: *const Fonts,
    theme: *const Theme,
    available_width: f32,
) LayoutResult {
    if (model.commits.items.len == 0) {
        return .{ .width = padding * 2, .height = padding * 2 };
    }

    const is_lr = model.orientation == .lr;

    // --- Step 1: Adaptive lane spacing based on tag presence -----------------
    const has_tags = model.tags.items.len > 0;
    const lane_spacing = if (has_tags) tagged_lane_spacing else default_lane_spacing;
    const commit_spacing = default_commit_spacing;
    // Add extra top-margin in LR mode so tag badges don't clip the top edge.
    const top_margin = if (has_tags and is_lr) header_offset + tag_top_margin else header_offset;

    // --- Step 2: Measure branch label widths ---------------------------------
    const branch_label_w = measureBranchLabels(model, fonts, theme);

    // --- Step 3: Compute topological slot positions --------------------------
    const slots_opt = computeTopoSlots(model) catch |err| blk: {
        std.log.err("gitgraph_layout: computeTopoSlots failed: {s}; falling back to seq ordering", .{@errorName(err)});
        break :blk null;
    };
    defer if (slots_opt) |s| model.allocator.free(s);

    const max_slot: u32 = blk: {
        var m: u32 = 0;
        if (slots_opt) |s| {
            for (s) |slot| m = @max(m, slot);
        } else {
            for (model.commits.items) |c| m = @max(m, c.seq);
        }
        break :blk m;
    };
    const num_slots: f32 = @as(f32, @floatFromInt(max_slot + 1));
    const num_branches: f32 = @floatFromInt(@max(model.branches.items.len, @as(usize, 1)));

    // --- Step 4: Compute natural diagram extents -----------------------------
    const cols = if (is_lr) num_slots else num_branches;
    const rows = if (is_lr) num_branches else num_slots;
    const col_spacing = if (is_lr) commit_spacing else lane_spacing;
    const row_spacing = if (is_lr) lane_spacing else commit_spacing;

    const natural_width = padding * 2 + branch_label_w + cols * col_spacing + tail_margin;
    const natural_height = padding * 2 + top_margin + rows * row_spacing + tail_margin;

    // --- Step 5: Assign commit (x, y) positions ------------------------------
    const start_x = padding + branch_label_w;
    const start_y = padding + top_margin;

    for (model.commits.items, 0..) |*commit, i| {
        const slot: u32 = if (slots_opt) |s| s[i] else commit.seq;
        const slot_f: f32 = @floatFromInt(slot);
        const lane_f: f32 = @floatFromInt(commit.lane);
        if (is_lr) {
            commit.x = start_x + slot_f * commit_spacing;
            commit.y = start_y + lane_f * lane_spacing;
        } else {
            commit.x = start_x + lane_f * lane_spacing;
            commit.y = start_y + slot_f * commit_spacing;
        }
    }

    // --- Step 6: Assign branch label positions -------------------------------
    for (model.branches.items) |*branch| {
        const lane_f: f32 = @floatFromInt(branch.lane);
        if (is_lr) {
            branch.label_x = padding;
            branch.label_y = start_y + lane_f * lane_spacing;
        } else {
            branch.label_x = start_x + lane_f * lane_spacing;
            branch.label_y = padding;
        }
    }

    // --- Step 7: Compute branch lane-start positions -------------------------
    // Each branch's lane line starts at the divergence point (the parent commit
    // on another branch), not at the diagram left/top edge.
    computeLaneStarts(model, is_lr, start_x, start_y);

    // --- Step 8: Compute tag badge positions ---------------------------------
    // Badges are positioned relative to the commit dot, offset so they don't
    // overlap the dot itself.  In LR mode badges sit above the dot; in TB mode
    // they sit to the right.
    for (model.tags.items) |*tag| {
        if (tag.commit_idx >= model.commits.items.len) continue;
        const commit = model.commits.items[tag.commit_idx];
        if (is_lr) {
            // Badge centre aligned with commit x; top edge commit_radius + 2px
            // above the commit dot, i.e. badge bottom = commit.y - commit_radius - 2.
            tag.x = commit.x;
            tag.y = commit.y - commit_radius - tag_height;
        } else {
            // Badge left edge just to the right of the commit dot.
            tag.x = commit.x + commit_radius + 4;
            tag.y = commit.y;
        }
    }

    // --- Step 9: Scale to fit available width --------------------------------
    const scale: f32 = if (natural_width > available_width and natural_width > 0)
        available_width / natural_width
    else
        1.0;

    if (scale < 1.0) {
        for (model.commits.items) |*commit| {
            commit.x *= scale;
            commit.y *= scale;
        }
        for (model.branches.items) |*branch| {
            branch.label_x *= scale;
            branch.label_y *= scale;
            branch.lane_start_x *= scale;
            branch.lane_start_y *= scale;
        }
        for (model.tags.items) |*tag| {
            tag.x *= scale;
            tag.y *= scale;
        }
    }

    // --- Step 10: Store effective layout values for the renderer -------------
    model.effective_lane_spacing = lane_spacing * scale;
    model.effective_commit_spacing = commit_spacing * scale;
    model.effective_padding = padding * scale;
    model.effective_branch_label_w = branch_label_w * scale;
    model.effective_header_offset = top_margin * scale;

    const diagram_width = @min(natural_width, available_width);
    const diagram_height = natural_height * scale;

    return .{ .width = diagram_width, .height = diagram_height };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Compute topological slot positions for every commit in insertion order.
///
/// Because the parser always appends commits in source order (parents before
/// children), a single forward scan suffices:
///
///   slot(i) = max(slot(parent_j)) + 1   for all parents j of commit i
///
/// Commits that share the same sole parent receive the same slot, placing them
/// in the same visual column — the expected "diamond" pattern for diverging
/// branches.
///
/// When a commit's parents list is empty (e.g. hand-crafted test data or a
/// genuine root commit), the commit's `seq` field is used as the slot to
/// preserve backward-compatible behaviour.
///
/// Returns an owned slice indexed by commit position.
/// Caller must free with `model.allocator.free(slice)`.
fn computeTopoSlots(model: *const GitGraphModel) ![]u32 {
    const n = model.commits.items.len;
    const slots = try model.allocator.alloc(u32, n);
    errdefer model.allocator.free(slots);

    // Build id → commit-index map for O(1) parent lookup.
    var id_map = std.StringHashMap(usize).init(model.allocator);
    defer id_map.deinit();
    for (model.commits.items, 0..) |c, i| {
        if (c.id.len > 0) {
            try id_map.put(c.id, i);
        }
    }

    for (model.commits.items, 0..) |commit, i| {
        if (commit.parents.items.len == 0) {
            // No parent info: honour the parser-assigned seq value so that
            // hand-crafted test models continue to work as expected.
            slots[i] = commit.seq;
            continue;
        }

        var max_parent_slot: u32 = 0;
        var found_any: bool = false;
        for (commit.parents.items) |pid| {
            const pidx = id_map.get(pid) orelse continue;
            if (!found_any or slots[pidx] > max_parent_slot) {
                max_parent_slot = slots[pidx];
                found_any = true;
            }
        }
        slots[i] = if (found_any) max_parent_slot + 1 else commit.seq;
    }

    return slots;
}

/// Compute `lane_start_x` / `lane_start_y` for every branch.
///
/// The lane line for a branch should begin at the commit from which the branch
/// diverged (its first cross-lane parent), not at the left/top diagram edge.
/// This makes divergence points visually obvious.
///
/// Algorithm:
///   For each branch we inspect the FIRST commit on that branch (lowest
///   insertion index).  If that commit has any parent on a different lane, we
///   set lane_start to the maximum x (LR) / y (TB) among all cross-lane
///   parents.  Otherwise the lane starts at the diagram edge (`start_x`/`start_y`).
///
/// Commit positions must be finalised before calling this function.
fn computeLaneStarts(
    model: *GitGraphModel,
    is_lr: bool,
    start_x: f32,
    start_y: f32,
) void {
    // Initialise all lane_start fields to the diagram edge.
    for (model.branches.items) |*branch| {
        branch.lane_start_x = start_x;
        branch.lane_start_y = start_y;
    }

    // Build a compact id → index map.  Use a FixedBufferAllocator so that an
    // allocation failure here cannot propagate; any IDs that don't fit simply
    // keep the default start position (diagram edge), which is always safe.
    var id_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&id_buf);
    var id_map = std.StringHashMap(usize).init(fba.allocator());
    for (model.commits.items, 0..) |c, i| {
        // OOM from FixedBufferAllocator is expected and safe: IDs that don't
        // fit simply keep the default lane_start position (diagram edge).
        id_map.put(c.id, i) catch {};
    }

    // Process commits in insertion order; only the FIRST commit on each branch
    // determines that branch's lane-start position.
    var seen = std.StaticBitSet(64).initEmpty();

    for (model.commits.items) |commit| {
        const lane = commit.lane;
        if (lane >= 64) continue;
        if (seen.isSet(lane)) continue;
        seen.set(lane);

        // Find the rightmost (LR) or bottommost (TB) cross-lane parent.
        var best_pos: f32 = if (is_lr) start_x else start_y;
        var found_cross = false;

        for (commit.parents.items) |pid| {
            const pidx = id_map.get(pid) orelse continue;
            const parent = model.commits.items[pidx];
            if (parent.lane == lane) continue;

            const pos: f32 = if (is_lr) parent.x else parent.y;
            if (!found_cross or pos > best_pos) {
                best_pos = pos;
                found_cross = true;
            }
        }

        if (found_cross) {
            if (model.findBranch(commit.branch)) |bidx| {
                if (is_lr) {
                    model.branches.items[bidx].lane_start_x = best_pos;
                } else {
                    model.branches.items[bidx].lane_start_y = best_pos;
                }
            }
        }
    }
}

/// Measure the widest branch label and return the label column width.
fn measureBranchLabels(
    model: *const GitGraphModel,
    fonts: *const Fonts,
    theme: *const Theme,
) f32 {
    var max_w: f32 = 0;
    const font_size = if (theme.body_font_size > 0) theme.body_font_size * 0.8 else 12.8;
    for (model.branches.items) |branch| {
        const measured = safeMeasure(fonts, branch.name, font_size);
        max_w = @max(max_w, measured.x);
    }
    return @max(min_branch_label_w, max_w + 10);
}

/// Measure text width safely — falls back to a character-width estimate when
/// fonts are not loaded (e.g. in unit tests where Raylib is not initialised).
fn safeMeasure(fonts: *const Fonts, text: []const u8, font_size: f32) @import("raylib").Vector2 {
    if (fonts.body.glyphCount == 0) {
        const w: f32 = @as(f32, @floatFromInt(text.len)) * font_size * 0.6;
        return .{ .x = w, .y = font_size };
    }
    return fonts.measure(text, font_size, false, false, false);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const StubFonts = struct {
    fn make() Fonts {
        return std.mem.zeroes(Fonts);
    }
};

fn makeTheme() Theme {
    var t = std.mem.zeroes(Theme);
    t.body_font_size = 16;
    t.paragraph_spacing = 10;
    return t;
}

// ---- Compatibility tests (must not regress) ---------------------------------

test "gitgraph_layout: empty model returns minimal size" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    const fonts = StubFonts.make();
    const theme = makeTheme();
    const result = layout(&model, &fonts, &theme, 800);

    try testing.expect(result.width > 0);
    try testing.expect(result.height > 0);
}

test "gitgraph_layout: commits with explicit seq fall back correctly" {
    // Commits appended directly (no parent wiring) keep their seq-based ordering.
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    for (0..3) |i| {
        var c = Commit.init(testing.allocator);
        c.branch = "main";
        c.lane = 0;
        c.seq = @intCast(i);
        try model.commits.append(c);
    }

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    // Strictly increasing x on same lane.
    try testing.expect(model.commits.items[1].x > model.commits.items[0].x);
    try testing.expect(model.commits.items[2].x > model.commits.items[1].x);
    try testing.expectEqual(model.commits.items[0].y, model.commits.items[1].y);
    try testing.expectEqual(model.commits.items[0].y, model.commits.items[2].y);
}

test "gitgraph_layout: different branches get different y in LR mode" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("develop");

    var c0 = Commit.init(testing.allocator);
    c0.branch = "main";
    c0.lane = 0;
    c0.seq = 0;
    try model.commits.append(c0);

    var c1 = Commit.init(testing.allocator);
    c1.branch = "develop";
    c1.lane = 1;
    c1.seq = 1;
    try model.commits.append(c1);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expect(model.commits.items[1].y > model.commits.items[0].y);
}

test "gitgraph_layout: TB orientation swaps axes" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();
    model.orientation = .tb;

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feature");

    var c0 = Commit.init(testing.allocator);
    c0.branch = "main";
    c0.lane = 0;
    c0.seq = 0;
    try model.commits.append(c0);

    var c1 = Commit.init(testing.allocator);
    c1.branch = "feature";
    c1.lane = 1;
    c1.seq = 1;
    try model.commits.append(c1);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expect(model.commits.items[1].x > model.commits.items[0].x);
    try testing.expect(model.commits.items[1].y > model.commits.items[0].y);
}

test "gitgraph_layout: scaling reduces positions when width exceeded" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    for (0..20) |i| {
        var c = Commit.init(testing.allocator);
        c.branch = "main";
        c.lane = 0;
        c.seq = @intCast(i);
        try model.commits.append(c);
    }

    const fonts = StubFonts.make();
    const theme = makeTheme();
    const result = layout(&model, &fonts, &theme, 400);

    for (model.commits.items) |commit| {
        try testing.expect(commit.x <= result.width + 1);
    }
}

test "gitgraph_layout: branch label positions are assigned" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("develop");

    var c = Commit.init(testing.allocator);
    c.branch = "main";
    c.lane = 0;
    c.seq = 0;
    try model.commits.append(c);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 800);

    try testing.expect(model.branches.items[0].label_x >= 0);
    try testing.expect(model.branches.items[1].label_y > model.branches.items[0].label_y);
}

test "gitgraph_layout: effective values stored on model" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c = Commit.init(testing.allocator);
    c.branch = "main";
    c.lane = 0;
    c.seq = 0;
    try model.commits.append(c);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expect(model.effective_lane_spacing > 0);
    try testing.expect(model.effective_commit_spacing > 0);
    try testing.expect(model.effective_padding > 0);
    try testing.expect(model.effective_branch_label_w > 0);
    try testing.expect(model.effective_header_offset > 0);
}

// ---- Topological ordering tests ---------------------------------------------

test "gitgraph_layout: topo sort sequential chain on one branch" {
    // c0 → c1 → c2 chained on main.  Slots: 0, 1, 2 → strictly increasing x.
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    try model.appendCommit(&c0);

    var c1 = Commit.init(testing.allocator);
    c1.id = "c1";
    c1.branch = "main";
    c1.lane = 0;
    try model.appendCommit(&c1);

    var c2 = Commit.init(testing.allocator);
    c2.id = "c2";
    c2.branch = "main";
    c2.lane = 0;
    try model.appendCommit(&c2);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expect(model.commits.items[1].x > model.commits.items[0].x);
    try testing.expect(model.commits.items[2].x > model.commits.items[1].x);
    try testing.expectEqual(model.commits.items[0].y, model.commits.items[1].y);
}

test "gitgraph_layout: topo sort merge commit after both parents" {
    // c0(main) → c1(feat) and c0 → merge(main, parents=[c0,c1]).
    // Slots: c0=0, c1=1, merge=2  ⇒  merge.x > c0.x and merge.x > c1.x.
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feat");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    try model.appendCommit(&c0);

    try model.branch_heads.put("feat", model.branch_heads.get("main").?);

    var c1 = Commit.init(testing.allocator);
    c1.id = "c1";
    c1.branch = "feat";
    c1.lane = 1;
    try model.appendCommit(&c1);

    var m = Commit.init(testing.allocator);
    m.id = "m1";
    m.branch = "main";
    m.lane = 0;
    try model.appendMergeCommit(&m, "feat");

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    const cxm = model.commits.items[2].x;
    try testing.expect(cxm > model.commits.items[0].x);
    try testing.expect(cxm > model.commits.items[1].x);
}

test "gitgraph_layout: topo sort parallel commits share x column" {
    // c1 and c2 are both direct children of c0 on different branches.
    // They must land in the same slot (1) and thus have the same x in LR.
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feat");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    try model.appendCommit(&c0);

    try model.branch_heads.put("feat", model.branch_heads.get("main").?);

    // c1 on feat: parent = c0 (via appendCommit)
    var c1 = Commit.init(testing.allocator);
    c1.id = "c1";
    c1.branch = "feat";
    c1.lane = 1;
    try model.appendCommit(&c1);

    // c2 on main: manually wire parent = c0 (simulating checkout main + commit)
    var c2 = Commit.init(testing.allocator);
    c2.id = "c2";
    c2.branch = "main";
    c2.lane = 0;
    try c2.parents.append("c0");
    const c2_idx = model.commits.items.len;
    try model.commits.append(c2);
    try model.branch_heads.put("main", c2_idx);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    // Same parent → same slot → same x.
    try testing.expectEqual(model.commits.items[1].x, model.commits.items[2].x);
    // But different y (different lanes).
    try testing.expect(model.commits.items[2].y != model.commits.items[1].y);
}

// ---- Branch divergence (lane_start) tests -----------------------------------

test "gitgraph_layout: main branch lane_start_x at diagram left edge" {
    // main has no cross-lane parent; its lane_start_x should equal start_x
    // (i.e. no further right than c0.x, which sits at start_x + 0*spacing).
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    try model.appendCommit(&c0);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 800);

    const main_idx = model.findBranch("main").?;
    const lane_start = model.branches.items[main_idx].lane_start_x;
    try testing.expect(lane_start > 0);
    // Must not exceed c0.x (c0 is at start_x, which equals lane_start_x
    // for the first branch).
    try testing.expect(lane_start <= model.commits.items[0].x + 1);
}

test "gitgraph_layout: feature branch lane_start_x at parent commit position" {
    // feat branches from main at c0; feat's lane line should start at c0.x.
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feat");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    try model.appendCommit(&c0);

    try model.branch_heads.put("feat", model.branch_heads.get("main").?);

    var c1 = Commit.init(testing.allocator);
    c1.id = "c1";
    c1.branch = "feat";
    c1.lane = 1;
    try model.appendCommit(&c1); // c1.parents = ["c0"] on lane 0

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    const c0_x = model.commits.items[0].x;
    const feat_idx = model.findBranch("feat").?;
    const feat_start_x = model.branches.items[feat_idx].lane_start_x;

    // feat's lane line starts at c0's x (the fork point).
    try testing.expectEqual(c0_x, feat_start_x);
    try testing.expect(c0_x > 0);
}

test "gitgraph_layout: lane_start_x is scaled with the diagram" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feat");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    try model.appendCommit(&c0);

    try model.branch_heads.put("feat", model.branch_heads.get("main").?);

    var c1 = Commit.init(testing.allocator);
    c1.id = "c1";
    c1.branch = "feat";
    c1.lane = 1;
    try model.appendCommit(&c1);

    // Force scaling with many commits.
    for (0..15) |_| {
        var cx = Commit.init(testing.allocator);
        cx.id = "cx";
        cx.branch = "main";
        cx.lane = 0;
        try model.appendCommit(&cx);
    }

    const fonts = StubFonts.make();
    const theme = makeTheme();
    const result = layout(&model, &fonts, &theme, 200);

    for (model.branches.items) |branch| {
        try testing.expect(branch.lane_start_x <= result.width + 1);
    }
}

// ---- Tag annotation space tests ---------------------------------------------

test "gitgraph_layout: no tags uses default lane spacing" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c = Commit.init(testing.allocator);
    c.id = "c0";
    c.branch = "main";
    c.lane = 0;
    try model.appendCommit(&c);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expectEqual(default_lane_spacing, model.effective_lane_spacing);
}

test "gitgraph_layout: tagged commit uses wider lane spacing" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feat");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    c0.tag = "v1.0";
    try model.appendCommit(&c0);

    var c1 = Commit.init(testing.allocator);
    c1.id = "c1";
    c1.branch = "feat";
    c1.lane = 1;
    try model.appendCommit(&c1);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expectEqual(tagged_lane_spacing, model.effective_lane_spacing);
    try testing.expect(model.effective_lane_spacing > default_lane_spacing);
}

test "gitgraph_layout: tagged lanes are further apart than untagged" {
    var no_tag = GitGraphModel.init(testing.allocator);
    defer no_tag.deinit();
    var tagged = GitGraphModel.init(testing.allocator);
    defer tagged.deinit();

    for (&[_]*GitGraphModel{ &no_tag, &tagged }) |m| {
        _ = try m.ensureBranch("main");
        _ = try m.ensureBranch("feat");
        var c0 = Commit.init(testing.allocator);
        c0.id = "c0";
        c0.branch = "main";
        c0.lane = 0;
        try m.appendCommit(&c0);
        try m.branch_heads.put("feat", m.branch_heads.get("main").?);
        var c1 = Commit.init(testing.allocator);
        c1.id = "c1";
        c1.branch = "feat";
        c1.lane = 1;
        try m.appendCommit(&c1);
    }
    tagged.commits.items[0].tag = "v1.0";
    // Re-register the tag so it appears in model.tags (in a real parse, the
    // parser would do this; here we simulate it directly).
    try tagged.tags.append(.{
        .label = "v1.0",
        .commit_idx = 0,
        .branch = "main",
    });

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&no_tag, &fonts, &theme, 2000);
    _ = layout(&tagged, &fonts, &theme, 2000);

    const no_dy = no_tag.commits.items[1].y - no_tag.commits.items[0].y;
    const tag_dy = tagged.commits.items[1].y - tagged.commits.items[0].y;
    try testing.expect(tag_dy > no_dy);
}

// ---- Tag badge position tests -----------------------------------------------

test "gitgraph_layout: tag badge above commit dot in LR mode" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    c0.tag = "v1.0";
    try model.appendCommit(&c0); // tag auto-registered in model.tags

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expectEqual(@as(usize, 1), model.tags.items.len);
    const tag = model.tags.items[0];
    // In LR mode, badge sits above the commit dot.
    try testing.expect(tag.x > 0);
    try testing.expect(tag.y < model.commits.items[0].y); // above the dot
}

test "gitgraph_layout: tag badge to right of commit dot in TB mode" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();
    model.orientation = .tb;

    _ = try model.ensureBranch("main");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    c0.tag = "v1.0";
    try model.appendCommit(&c0);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expectEqual(@as(usize, 1), model.tags.items.len);
    const tag = model.tags.items[0];
    // In TB mode, badge sits to the right of the commit dot.
    try testing.expect(tag.x > model.commits.items[0].x);
    try testing.expectEqual(model.commits.items[0].y, tag.y);
}

test "gitgraph_layout: tag badge scaled with diagram" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    // Force wide diagram so scaling kicks in.
    for (0..20) |i| {
        var c = Commit.init(testing.allocator);
        c.id = if (i == 0) "c0" else "cx";
        c.branch = "main";
        c.lane = 0;
        if (i == 0) c.tag = "v1.0";
        try model.appendCommit(&c);
    }

    const fonts = StubFonts.make();
    const theme = makeTheme();
    const result = layout(&model, &fonts, &theme, 300);

    for (model.tags.items) |tag| {
        try testing.expect(tag.x <= result.width + 1);
    }
}

test "gitgraph_layout: multiple tags get independent positions" {
    var model = GitGraphModel.init(testing.allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c0 = Commit.init(testing.allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.lane = 0;
    c0.tag = "v1.0";
    try model.appendCommit(&c0);

    var c1 = Commit.init(testing.allocator);
    c1.id = "c1";
    c1.branch = "main";
    c1.lane = 0;
    try model.appendCommit(&c1); // no tag

    var c2 = Commit.init(testing.allocator);
    c2.id = "c2";
    c2.branch = "main";
    c2.lane = 0;
    c2.tag = "v2.0";
    try model.appendCommit(&c2);

    const fonts = StubFonts.make();
    const theme = makeTheme();
    _ = layout(&model, &fonts, &theme, 2000);

    try testing.expectEqual(@as(usize, 2), model.tags.items.len);
    // Tags for c0 and c2 should have different x positions (different slots).
    try testing.expect(model.tags.items[1].x > model.tags.items[0].x);
    // Both should be above their respective commit dots (LR mode).
    try testing.expect(model.tags.items[0].y < model.commits.items[0].y);
    try testing.expect(model.tags.items[1].y < model.commits.items[2].y);
}
