const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

pub const CommitType = enum {
    normal,
    highlight,
    reverse,
};

pub const Commit = struct {
    id: []const u8 = "",
    message: []const u8 = "",
    /// Inline tag label (e.g. "v1.0"). When non-empty, `appendCommit` /
    /// `appendMergeCommit` automatically registers a corresponding `Tag`
    /// entity in `GitGraphModel.tags` so the layout engine can position it
    /// independently of the commit dot.
    tag: []const u8 = "",
    commit_type: CommitType = .normal,
    branch: []const u8 = "",
    parents: std.ArrayList([]const u8),
    /// Optional explicit visual ordering index (from the `order:` attribute in
    /// newer Mermaid gitGraph syntax). When non-null the layout engine may use
    /// this value to override the default sequential insertion order.
    explicit_order: ?u32 = null,
    // Layout fields
    x: f32 = 0,
    y: f32 = 0,
    lane: u32 = 0,
    seq: u32 = 0,

    pub fn init(allocator: Allocator) Commit {
        return .{
            .parents = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Commit) void {
        self.parents.deinit();
    }
};

pub const Branch = struct {
    name: []const u8 = "",
    lane: u32 = 0,
    color: rl.Color = rl.Color{ .r = 100, .g = 100, .b = 200, .a = 255 },
    // Layout fields set by the layout engine
    label_x: f32 = 0,
    label_y: f32 = 0,
    /// Start coordinate of the branch lane line (commit-axis direction).
    /// In LR orientation this is an x value; in TB it is a y value.
    /// Set to the position of the parent-branch commit from which this branch
    /// diverged, so the lane line begins at the fork point rather than at the
    /// left/top edge of the diagram.
    lane_start_x: f32 = 0,
    lane_start_y: f32 = 0,
};

/// A named tag marker attached to a specific commit.  Tags are first-class
/// entities in the model (alongside Commit, Branch, and MergeInfo), so the
/// layout engine can compute their screen positions independently of commit
/// dots and the renderer can draw them with accurate coordinates.
///
/// Relationship: every Tag references exactly one Commit (via `commit_idx`),
/// and in standard Mermaid gitGraph syntax a Commit carries at most one Tag.
/// The `branch` field is a convenience copy from the tagged commit so
/// renderers can inherit branch colour without an extra lookup.
pub const Tag = struct {
    /// The display text shown in the gold badge (e.g. "v1.0").
    label: []const u8 = "",
    /// Index into `GitGraphModel.commits` for the commit this tag belongs to.
    commit_idx: usize = 0,
    /// Branch of the tagged commit — copied from `Commit.branch` for O(1)
    /// colour lookup during rendering without a secondary find call.
    branch: []const u8 = "",
    // Layout fields — populated by the layout engine after commit positions
    // are finalised, enabling the renderer to place the badge without
    // re-deriving coordinates from commit x/y and orientation.
    x: f32 = 0,
    y: f32 = 0,
};

pub const MergeInfo = struct {
    from_commit: usize, // index in commits
    to_commit: usize, // index in commits
    from_branch: []const u8 = "",
    to_branch: []const u8 = "",
};

pub const Orientation = enum {
    lr, // left-to-right (default)
    tb, // top-to-bottom
};

pub const GitGraphModel = struct {
    branches: std.ArrayList(Branch),
    commits: std.ArrayList(Commit),
    merges: std.ArrayList(MergeInfo),
    /// All tag entities in insertion order (mirrors commit insertion order).
    /// Populated automatically by `appendCommit` / `appendMergeCommit` when a
    /// commit carries a non-empty `tag` field.  The layout engine reads this
    /// list to compute `Tag.x` / `Tag.y` after commit positions are finalised.
    tags: std.ArrayList(Tag),
    /// Maps branch name -> index of the latest commit on that branch.
    /// Maintained by the parser as commits are appended, enabling O(1)
    /// parent lookup when creating new commits or merges.
    branch_heads: std.StringHashMap(usize),
    orientation: Orientation = .lr,
    title: []const u8 = "",
    allocator: Allocator,
    // Layout fields set by mermaid_layout after computing positions
    effective_lane_spacing: f32 = 0,
    effective_commit_spacing: f32 = 0,
    effective_padding: f32 = 0,
    effective_branch_label_w: f32 = 0,
    effective_header_offset: f32 = 0,

    pub fn init(allocator: Allocator) GitGraphModel {
        return .{
            .branches = std.ArrayList(Branch).init(allocator),
            .commits = std.ArrayList(Commit).init(allocator),
            .merges = std.ArrayList(MergeInfo).init(allocator),
            .tags = std.ArrayList(Tag).init(allocator),
            .branch_heads = std.StringHashMap(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitGraphModel) void {
        for (self.commits.items) |*c| {
            c.deinit();
        }
        self.commits.deinit();
        self.branches.deinit();
        self.merges.deinit();
        self.tags.deinit();
        self.branch_heads.deinit();
    }

    pub fn findBranch(self: *const GitGraphModel, name: []const u8) ?usize {
        for (self.branches.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, name)) return i;
        }
        return null;
    }

    pub fn ensureBranch(self: *GitGraphModel, name: []const u8) !usize {
        if (self.findBranch(name)) |idx| return idx;
        const lane: u32 = @intCast(self.branches.items.len);
        try self.branches.append(.{
            .name = name,
            .lane = lane,
            .color = branch_palette[lane % branch_palette.len],
        });
        return self.branches.items.len - 1;
    }

    /// Append a commit to the graph, automatically wiring its parent to the
    /// current head of the commit's branch (if any). Updates branch_heads to
    /// point at the newly added commit. Caller must set `branch` on the
    /// commit before calling this.
    ///
    /// If `commit.tag` is non-empty a `Tag` entity is registered in `self.tags`
    /// so the layout engine can compute its screen position independently of
    /// the commit dot.
    pub fn appendCommit(self: *GitGraphModel, commit: *Commit) !void {
        // Wire parent: the previous head of this commit's branch
        if (self.branch_heads.get(commit.branch)) |parent_idx| {
            try commit.parents.append(self.commits.items[parent_idx].id);
        }

        const idx = self.commits.items.len;
        try self.commits.append(commit.*);

        // Update head pointer for this branch
        try self.branch_heads.put(commit.branch, idx);

        // Register tag as a first-class entity when the commit carries one.
        if (commit.tag.len > 0) {
            try self.tags.append(.{
                .label = commit.tag,
                .commit_idx = idx,
                .branch = commit.branch,
            });
        }
    }

    /// Append a merge commit. The merge commit gets two parents: the current
    /// head of `commit.branch` (the target branch) and the current head of
    /// `from_branch` (the source branch). A `MergeInfo` record is also created.
    ///
    /// If `commit.tag` is non-empty a `Tag` entity is registered in `self.tags`.
    pub fn appendMergeCommit(self: *GitGraphModel, commit: *Commit, from_branch: []const u8) !void {
        // Wire parent from target branch (current branch head)
        if (self.branch_heads.get(commit.branch)) |parent_idx| {
            try commit.parents.append(self.commits.items[parent_idx].id);
        }

        // Wire second parent from source branch
        var from_idx: ?usize = null;
        if (self.branch_heads.get(from_branch)) |src_idx| {
            try commit.parents.append(self.commits.items[src_idx].id);
            from_idx = src_idx;
        }

        const to_idx = self.commits.items.len;
        try self.commits.append(commit.*);

        // Update head pointer for the target branch
        try self.branch_heads.put(commit.branch, to_idx);

        // Record merge info
        if (from_idx) |fi| {
            try self.merges.append(.{
                .from_commit = fi,
                .to_commit = to_idx,
                .from_branch = from_branch,
                .to_branch = commit.branch,
            });
        }

        // Register tag as a first-class entity when the merge commit carries one.
        if (commit.tag.len > 0) {
            try self.tags.append(.{
                .label = commit.tag,
                .commit_idx = to_idx,
                .branch = commit.branch,
            });
        }
    }

    /// Find a commit by its id. Returns the index into `commits` or null.
    pub fn findCommitById(self: *const GitGraphModel, id: []const u8) ?usize {
        for (self.commits.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.id, id)) return i;
        }
        return null;
    }

    /// Return the tag entity attached to the commit at `commit_idx`, or null
    /// if that commit has no tag.  Because at most one tag can be attached per
    /// commit in standard Mermaid gitGraph syntax this returns a single
    /// optional rather than an iterator.
    pub fn findTagForCommit(self: *const GitGraphModel, commit_idx: usize) ?*const Tag {
        for (self.tags.items) |*t| {
            if (t.commit_idx == commit_idx) return t;
        }
        return null;
    }

    /// Return an iterator over all commits that are children of the commit
    /// identified by `parent_id` in the DAG.
    pub fn findChildren(self: *const GitGraphModel, parent_id: []const u8) ChildIterator {
        return .{ .model = self, .parent_id = parent_id, .pos = 0 };
    }

    /// Return the index of the current head commit for a given branch, or null
    /// if the branch has no commits yet.
    pub fn getBranchHead(self: *const GitGraphModel, branch_name: []const u8) ?usize {
        return self.branch_heads.get(branch_name);
    }

    pub const ChildIterator = struct {
        model: *const GitGraphModel,
        parent_id: []const u8,
        pos: usize,

        /// Returns the next child commit index, or null when exhausted.
        pub fn next(self: *ChildIterator) ?usize {
            while (self.pos < self.model.commits.items.len) {
                const commit = self.model.commits.items[self.pos];
                const idx = self.pos;
                self.pos += 1;
                for (commit.parents.items) |pid| {
                    if (std.mem.eql(u8, pid, self.parent_id)) return idx;
                }
            }
            return null;
        }
    };
};

const branch_palette = [_]rl.Color{
    rl.Color{ .r = 76, .g = 114, .b = 176, .a = 255 }, // blue (main)
    rl.Color{ .r = 85, .g = 168, .b = 104, .a = 255 }, // green
    rl.Color{ .r = 221, .g = 132, .b = 82, .a = 255 }, // orange
    rl.Color{ .r = 196, .g = 78, .b = 82, .a = 255 }, // red
    rl.Color{ .r = 129, .g = 114, .b = 178, .a = 255 }, // purple
    rl.Color{ .r = 218, .g = 139, .b = 195, .a = 255 }, // pink
    rl.Color{ .r = 147, .g = 120, .b = 96, .a = 255 }, // brown
    rl.Color{ .r = 140, .g = 140, .b = 140, .a = 255 }, // gray
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "GitGraphModel init/deinit round-trip" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 0), model.commits.items.len);
    try testing.expectEqual(@as(usize, 0), model.branches.items.len);
    try testing.expectEqual(@as(usize, 0), model.merges.items.len);
    try testing.expectEqual(@as(usize, 0), model.tags.items.len);
}

test "GitGraphModel ensureBranch assigns incrementing lanes" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    const main_idx = try model.ensureBranch("main");
    const dev_idx = try model.ensureBranch("develop");
    const feat_idx = try model.ensureBranch("feature");

    try testing.expectEqual(@as(usize, 0), main_idx);
    try testing.expectEqual(@as(usize, 1), dev_idx);
    try testing.expectEqual(@as(usize, 2), feat_idx);
    try testing.expectEqual(@as(u32, 0), model.branches.items[0].lane);
    try testing.expectEqual(@as(u32, 1), model.branches.items[1].lane);
    try testing.expectEqual(@as(u32, 2), model.branches.items[2].lane);

    // Duplicate returns existing index without adding a new branch
    const dup = try model.ensureBranch("develop");
    try testing.expectEqual(@as(usize, 1), dup);
    try testing.expectEqual(@as(usize, 3), model.branches.items.len);
}

test "GitGraphModel appendCommit wires parent from branch head" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    // First commit -- no parent
    var c1 = Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    try model.appendCommit(&c1);

    try testing.expectEqual(@as(usize, 0), model.commits.items[0].parents.items.len);

    // Second commit -- parent is c1
    var c2 = Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "main";
    try model.appendCommit(&c2);

    try testing.expectEqual(@as(usize, 1), model.commits.items[1].parents.items.len);
    try testing.expectEqualStrings("c1", model.commits.items[1].parents.items[0]);

    // Third commit -- parent is c2
    var c3 = Commit.init(allocator);
    c3.id = "c3";
    c3.branch = "main";
    try model.appendCommit(&c3);

    try testing.expectEqualStrings("c2", model.commits.items[2].parents.items[0]);
}

test "GitGraphModel appendMergeCommit wires two parents" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feature");

    var c1 = Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    try model.appendCommit(&c1);

    // Branch feature inherits main head
    try model.branch_heads.put("feature", model.branch_heads.get("main").?);

    var c2 = Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "feature";
    try model.appendCommit(&c2);

    var merge = Commit.init(allocator);
    merge.id = "m1";
    merge.branch = "main";
    try model.appendMergeCommit(&merge, "feature");

    const mc = model.commits.items[2];
    try testing.expectEqual(@as(usize, 2), mc.parents.items.len);
    try testing.expectEqualStrings("c1", mc.parents.items[0]);
    try testing.expectEqualStrings("c2", mc.parents.items[1]);

    try testing.expectEqual(@as(usize, 1), model.merges.items.len);
    try testing.expectEqualStrings("feature", model.merges.items[0].from_branch);
    try testing.expectEqualStrings("main", model.merges.items[0].to_branch);
}

test "GitGraphModel findCommitById" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c1 = Commit.init(allocator);
    c1.id = "abc";
    c1.branch = "main";
    try model.appendCommit(&c1);

    var c2 = Commit.init(allocator);
    c2.id = "def";
    c2.branch = "main";
    try model.appendCommit(&c2);

    try testing.expectEqual(@as(?usize, 0), model.findCommitById("abc"));
    try testing.expectEqual(@as(?usize, 1), model.findCommitById("def"));
    try testing.expectEqual(@as(?usize, null), model.findCommitById("xyz"));
}

test "GitGraphModel findChildren iterator" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c1 = Commit.init(allocator);
    c1.id = "root";
    c1.branch = "main";
    try model.appendCommit(&c1);

    var c2 = Commit.init(allocator);
    c2.id = "child1";
    c2.branch = "main";
    try model.appendCommit(&c2);

    var c3 = Commit.init(allocator);
    c3.id = "child2";
    c3.branch = "main";
    try model.appendCommit(&c3);

    var iter = model.findChildren("root");
    try testing.expectEqual(@as(?usize, 1), iter.next()); // child1
    try testing.expectEqual(@as(?usize, null), iter.next()); // root has no other children
}

test "GitGraphModel getBranchHead tracks latest commit" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    try testing.expectEqual(@as(?usize, null), model.getBranchHead("main"));

    var c1 = Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    try model.appendCommit(&c1);
    try testing.expectEqual(@as(?usize, 0), model.getBranchHead("main"));

    var c2 = Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "main";
    try model.appendCommit(&c2);
    try testing.expectEqual(@as(?usize, 1), model.getBranchHead("main"));
}

test "Tag entity registered when commit has tag" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c1 = Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    try model.appendCommit(&c1);
    try testing.expectEqual(@as(usize, 0), model.tags.items.len);

    var c2 = Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "main";
    c2.tag = "v1.0";
    try model.appendCommit(&c2);
    try testing.expectEqual(@as(usize, 1), model.tags.items.len);
    try testing.expectEqualStrings("v1.0", model.tags.items[0].label);
    try testing.expectEqual(@as(usize, 1), model.tags.items[0].commit_idx);
    try testing.expectEqualStrings("main", model.tags.items[0].branch);
}

test "Tag entity registered on merge commit with tag" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");
    _ = try model.ensureBranch("feature");

    var c1 = Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    try model.appendCommit(&c1);

    try model.branch_heads.put("feature", model.branch_heads.get("main").?);

    var c2 = Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "feature";
    try model.appendCommit(&c2);

    var merge = Commit.init(allocator);
    merge.id = "m1";
    merge.branch = "main";
    merge.tag = "v2.0";
    try model.appendMergeCommit(&merge, "feature");

    try testing.expectEqual(@as(usize, 1), model.tags.items.len);
    try testing.expectEqualStrings("v2.0", model.tags.items[0].label);
    try testing.expectEqual(@as(usize, 2), model.tags.items[0].commit_idx);
    try testing.expectEqualStrings("main", model.tags.items[0].branch);
}

test "findTagForCommit returns correct tag entity" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c1 = Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    try model.appendCommit(&c1);

    var c2 = Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "main";
    c2.tag = "v1.0";
    try model.appendCommit(&c2);

    var c3 = Commit.init(allocator);
    c3.id = "c3";
    c3.branch = "main";
    c3.tag = "v1.1";
    try model.appendCommit(&c3);

    try testing.expectEqual(@as(?*const Tag, null), model.findTagForCommit(0));

    const t1 = model.findTagForCommit(1);
    try testing.expect(t1 != null);
    try testing.expectEqualStrings("v1.0", t1.?.label);

    const t2 = model.findTagForCommit(2);
    try testing.expect(t2 != null);
    try testing.expectEqualStrings("v1.1", t2.?.label);
}

test "Multiple tags across commits are ordered by insertion" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c0 = Commit.init(allocator);
    c0.id = "c0";
    c0.branch = "main";
    c0.tag = "alpha";
    try model.appendCommit(&c0);

    var c1 = Commit.init(allocator);
    c1.id = "c1";
    c1.branch = "main";
    try model.appendCommit(&c1);

    var c2 = Commit.init(allocator);
    c2.id = "c2";
    c2.branch = "main";
    c2.tag = "beta";
    try model.appendCommit(&c2);

    try testing.expectEqual(@as(usize, 2), model.tags.items.len);
    try testing.expectEqualStrings("alpha", model.tags.items[0].label);
    try testing.expectEqual(@as(usize, 0), model.tags.items[0].commit_idx);
    try testing.expectEqualStrings("beta", model.tags.items[1].label);
    try testing.expectEqual(@as(usize, 2), model.tags.items[1].commit_idx);
}

test "Commit explicit_order field defaults to null" {
    const allocator = testing.allocator;
    var c = Commit.init(allocator);
    defer c.deinit();
    try testing.expectEqual(@as(?u32, null), c.explicit_order);
}

test "Commit explicit_order can be set and stored" {
    const allocator = testing.allocator;
    var model = GitGraphModel.init(allocator);
    defer model.deinit();

    _ = try model.ensureBranch("main");

    var c = Commit.init(allocator);
    c.id = "c1";
    c.branch = "main";
    c.explicit_order = 5;
    try model.appendCommit(&c);

    try testing.expectEqual(@as(?u32, 5), model.commits.items[0].explicit_order);
}

test "Tag layout fields initialise to zero" {
    const tag = Tag{};
    try testing.expectEqual(@as(f32, 0), tag.x);
    try testing.expectEqual(@as(f32, 0), tag.y);
    try testing.expectEqualStrings("", tag.label);
    try testing.expectEqual(@as(usize, 0), tag.commit_idx);
}

test "Branch lane_start fields initialise to zero" {
    const b = Branch{};
    try testing.expectEqual(@as(f32, 0), b.lane_start_x);
    try testing.expectEqual(@as(f32, 0), b.lane_start_y);
}
