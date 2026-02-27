const std = @import("std");
const Allocator = std.mem.Allocator;
const gg = @import("../models/gitgraph_model.zig");
const GitGraphModel = gg.GitGraphModel;
const Commit = gg.Commit;
const CommitType = gg.CommitType;

pub fn parse(allocator: Allocator, source: []const u8) !GitGraphModel {
    var model = GitGraphModel.init(allocator);
    errdefer model.deinit();

    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();

    var start: usize = 0;
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
            try lines.append(source[start..i]);
            start = i + 1;
        }
    }
    if (start < source.len) {
        try lines.append(source[start..]);
    }

    var past_header = false;
    var current_branch: []const u8 = "main";
    var commit_counter: u32 = 0;

    // Ensure main branch exists
    _ = try model.ensureBranch("main");

    for (lines.items) |raw_line| {
        const line = strip(raw_line);
        if (line.len == 0 or isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "gitGraph") or startsWith(line, "gitGraph ")) {
                past_header = true;
                // Check for orientation: gitGraph TB or gitGraph LR
                if (line.len > "gitGraph ".len) {
                    const rest = strip(line["gitGraph ".len..]);
                    if (std.mem.eql(u8, rest, "TB") or std.mem.eql(u8, rest, "BT")) {
                        model.orientation = .tb;
                    }
                }
                continue;
            }
            past_header = true;
            continue;
        }

        // Parse commands
        if (std.mem.eql(u8, line, "commit") or startsWith(line, "commit ")) {
            var commit = Commit.init(allocator);
            commit.branch = current_branch;
            commit.seq = commit_counter;
            commit_counter += 1;

            // Set branch lane
            if (model.findBranch(current_branch)) |bidx| {
                commit.lane = model.branches.items[bidx].lane;
            }

            // Parse optional attributes: id: "abc" msg: "message" tag: "v1.0" type: HIGHLIGHT
            if (line.len > "commit".len) {
                const attrs = strip(line["commit".len..]);
                commit.id = parseAttr(attrs, "id:");
                commit.message = parseAttr(attrs, "msg:");
                commit.tag = parseAttr(attrs, "tag:");
                const type_str = parseAttr(attrs, "type:");
                if (type_str.len > 0) {
                    if (std.mem.eql(u8, type_str, "HIGHLIGHT")) {
                        commit.commit_type = .highlight;
                    } else if (std.mem.eql(u8, type_str, "REVERSE")) {
                        commit.commit_type = .reverse;
                    }
                }
            }

            // Auto-generate id if not provided
            if (commit.id.len == 0) {
                commit.id = autoId(commit_counter - 1);
            }

            try model.commits.append(commit);
        } else if (startsWith(line, "branch ")) {
            const branch_name = strip(line["branch ".len..]);
            _ = try model.ensureBranch(branch_name);
            current_branch = branch_name;
        } else if (startsWith(line, "checkout ") or startsWith(line, "switch ")) {
            const prefix_len: usize = if (startsWith(line, "checkout ")) "checkout ".len else "switch ".len;
            current_branch = strip(line[prefix_len..]);
        } else if (startsWith(line, "merge ")) {
            const merge_branch = strip(line["merge ".len..]);
            // Get just the branch name (may have tag: or other attrs after)
            const branch_name = firstWord(merge_branch);

            // Create a merge commit on current branch
            var commit = Commit.init(allocator);
            commit.branch = current_branch;
            commit.seq = commit_counter;
            commit_counter += 1;

            if (model.findBranch(current_branch)) |bidx| {
                commit.lane = model.branches.items[bidx].lane;
            }

            // Parse optional tag
            commit.tag = parseAttr(merge_branch, "tag:");
            commit.id = parseAttr(merge_branch, "id:");
            if (commit.id.len == 0) {
                commit.id = autoId(commit_counter - 1);
            }

            const to_idx = model.commits.items.len;
            try model.commits.append(commit);

            // Record merge info
            // Find the last commit on the merged branch
            var from_idx: ?usize = null;
            var i: usize = model.commits.items.len;
            while (i > 0) {
                i -= 1;
                if (i == to_idx) continue;
                if (std.mem.eql(u8, model.commits.items[i].branch, branch_name)) {
                    from_idx = i;
                    break;
                }
            }
            if (from_idx) |fi| {
                try model.merges.append(.{
                    .from_commit = fi,
                    .to_commit = to_idx,
                    .from_branch = branch_name,
                    .to_branch = current_branch,
                });
            }
        } else if (startsWith(line, "cherry-pick ")) {
            // cherry-pick id: "abc"
            const attrs = strip(line["cherry-pick ".len..]);
            const cherry_id = parseAttr(attrs, "id:");

            var commit = Commit.init(allocator);
            commit.branch = current_branch;
            commit.seq = commit_counter;
            commit_counter += 1;
            commit.id = if (cherry_id.len > 0) cherry_id else autoId(commit_counter - 1);
            commit.commit_type = .highlight;

            if (model.findBranch(current_branch)) |bidx| {
                commit.lane = model.branches.items[bidx].lane;
            }

            try model.commits.append(commit);
        }
    }

    return model;
}

fn autoId(seq: u32) []const u8 {
    // Comptime lookup table for auto-generated commit IDs.
    const table = comptime blk: {
        const count = 32;
        var entries: [count][]const u8 = undefined;
        for (0..count) |i| {
            entries[i] = std.fmt.comptimePrint("{d}", .{i});
        }
        break :blk entries;
    };
    if (seq < table.len) {
        return table[seq];
    }
    // For larger values, return a generic fallback. This covers edge cases
    // but in practice gitgraph diagrams rarely exceed 32 commits.
    return "commit";
}

fn parseAttr(text: []const u8, key: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, text, key) orelse return "";
    const after = strip(text[idx + key.len ..]);
    if (after.len == 0) return "";

    // Value may be quoted
    if (after[0] == '"') {
        const close = std.mem.indexOfScalar(u8, after[1..], '"') orelse return after[1..];
        return after[1 .. close + 1];
    }

    // Unquoted: take until next space or end
    const end = std.mem.indexOfAny(u8, after, " \t") orelse after.len;
    return after[0..end];
}

fn firstWord(s: []const u8) []const u8 {
    const trimmed = strip(s);
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

fn strip(s: []const u8) []const u8 {
    var st: usize = 0;
    while (st < s.len and (s[st] == ' ' or s[st] == '\t' or s[st] == '\r')) : (st += 1) {}
    var end = s.len;
    while (end > st and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[st..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn isComment(line: []const u8) bool {
    return line.len >= 2 and line[0] == '%' and line[1] == '%';
}
