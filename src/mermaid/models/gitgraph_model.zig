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
    tag: []const u8 = "",
    commit_type: CommitType = .normal,
    branch: []const u8 = "",
    parents: std.ArrayList([]const u8),
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
    // Layout fields
    label_x: f32 = 0,
    label_y: f32 = 0,
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
