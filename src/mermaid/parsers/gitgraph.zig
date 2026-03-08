const std = @import("std");
const Allocator = std.mem.Allocator;
const pu = @import("../parse_utils.zig");
const gg = @import("../models/gitgraph_model.zig");
const GitGraphModel = gg.GitGraphModel;
const Commit = gg.Commit;
const CommitType = gg.CommitType;

pub fn parse(allocator: Allocator, source: []const u8) !GitGraphModel {
    var model = GitGraphModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    var past_header = false;
    var current_branch: []const u8 = "main";
    var commit_counter: u32 = 0;

    // Ensure main branch exists
    _ = try model.ensureBranch("main");

    for (lines.items) |raw_line| {
        const line = pu.strip(raw_line);
        if (line.len == 0 or pu.isComment(line)) continue;

        if (!past_header) {
            // Accept both "gitGraph" (canonical) and "gitgraph" (GitHub renders both)
            if (std.mem.eql(u8, line, "gitGraph") or pu.startsWith(line, "gitGraph ") or
                std.mem.eql(u8, line, "gitgraph") or pu.startsWith(line, "gitgraph "))
            {
                past_header = true;
                // Check for orientation: gitGraph TB or gitGraph LR
                const header_len: usize = if (pu.startsWith(line, "gitGraph "))
                    "gitGraph ".len
                else if (pu.startsWith(line, "gitgraph "))
                    "gitgraph ".len
                else
                    line.len;
                if (line.len > header_len) {
                    const rest = pu.strip(line[header_len..]);
                    if (std.mem.eql(u8, rest, "TB") or std.mem.eql(u8, rest, "BT")) {
                        model.orientation = .tb;
                    }
                }
                continue;
            }
            past_header = true;
            continue;
        }

        // Skip accessibility directives -- informational only
        if (pu.startsWith(line, "accTitle:") or pu.startsWith(line, "accDescr:")) {
            continue;
        }

        // Parse commands
        if (std.mem.eql(u8, line, "commit") or pu.startsWith(line, "commit ")) {
            var commit = Commit.init(allocator);
            errdefer commit.deinit();
            commit.branch = current_branch;
            commit.seq = commit_counter;
            commit_counter += 1;

            // Set branch lane
            if (model.findBranch(current_branch)) |bidx| {
                commit.lane = model.branches.items[bidx].lane;
            }

            // Parse optional attributes: id: "abc" msg: "message" tag: "v1.0"
            //   type: HIGHLIGHT|REVERSE   order: <uint>
            if (line.len > "commit".len) {
                const attrs = pu.strip(line["commit".len..]);
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
                // `order:` attribute -- explicit visual position override (Mermaid v10+)
                const order_str = parseAttr(attrs, "order:");
                if (order_str.len > 0) {
                    if (std.fmt.parseInt(u32, order_str, 10)) |ord| {
                        commit.explicit_order = ord;
                    } else |_| {} // silently ignore non-integer values
                }
            }

            // Auto-generate id if not provided
            if (commit.id.len == 0) {
                commit.id = autoId(commit_counter - 1);
            }

            // appendCommit wires parent from branch head, updates branch_heads,
            // and registers any tag as a first-class Tag entity.
            try model.appendCommit(&commit);
        } else if (pu.startsWith(line, "branch ")) {
            const branch_name = pu.strip(line["branch ".len..]);
            _ = try model.ensureBranch(branch_name);
            // When creating a branch, inherit the current branch's head so
            // the first commit on the new branch has the correct parent.
            if (model.branch_heads.get(current_branch)) |head_idx| {
                try model.branch_heads.put(branch_name, head_idx);
            }
            current_branch = branch_name;
        } else if (pu.startsWith(line, "checkout ") or pu.startsWith(line, "switch ")) {
            const prefix_len: usize = if (pu.startsWith(line, "checkout ")) "checkout ".len else "switch ".len;
            current_branch = pu.strip(line[prefix_len..]);
        } else if (pu.startsWith(line, "merge ")) {
            const merge_branch = pu.strip(line["merge ".len..]);
            // Get just the branch name (may have tag: or other attrs after)
            const branch_name = firstWord(merge_branch);

            // Create a merge commit on current branch
            var commit = Commit.init(allocator);
            errdefer commit.deinit();
            commit.branch = current_branch;
            commit.seq = commit_counter;
            commit_counter += 1;

            if (model.findBranch(current_branch)) |bidx| {
                commit.lane = model.branches.items[bidx].lane;
            }

            // Parse optional tag and id on the merge line
            commit.tag = parseAttr(merge_branch, "tag:");
            commit.id = parseAttr(merge_branch, "id:");
            if (commit.id.len == 0) {
                commit.id = autoId(commit_counter - 1);
            }

            // appendMergeCommit wires both parents, records MergeInfo, and
            // registers any tag as a first-class Tag entity.
            try model.appendMergeCommit(&commit, branch_name);
        } else if (pu.startsWith(line, "cherry-pick ")) {
            // cherry-pick id: "abc"
            const attrs = pu.strip(line["cherry-pick ".len..]);
            const cherry_id = parseAttr(attrs, "id:");

            var commit = Commit.init(allocator);
            errdefer commit.deinit();
            commit.branch = current_branch;
            commit.seq = commit_counter;
            commit_counter += 1;
            commit.id = if (cherry_id.len > 0) cherry_id else autoId(commit_counter - 1);
            commit.commit_type = .highlight;

            if (model.findBranch(current_branch)) |bidx| {
                commit.lane = model.branches.items[bidx].lane;
            }

            try model.appendCommit(&commit);
        } else if (pu.startsWith(line, "tag ")) {
            // Standalone tag directive — attaches a label to the latest commit on the
            // current branch.
            //
            // Grammar production:
            //   tag-directive  ::= "tag" WS tag-label
            //   tag-label      ::= QUOTED_STRING | IDENTIFIER
            //   QUOTED_STRING  ::= '"' [^"]* '"'
            //   IDENTIFIER     ::= [^\s]+
            //
            // Example:
            //   tag "v1.0"
            //   tag v1.0
            const rest = pu.strip(line["tag ".len..]);
            const tag_label: []const u8 = blk: {
                if (rest.len == 0) break :blk "";
                if (rest[0] == '"') {
                    // Quoted label: extract text between the first pair of double-quotes.
                    const close = pu.indexOfChar(rest[1..], '"') orelse break :blk rest[1..];
                    break :blk rest[1 .. close + 1];
                }
                // Unquoted label: take until first whitespace character.
                const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                break :blk rest[0..end];
            };
            if (tag_label.len > 0) {
                // Look up the latest commit on the current branch.
                if (model.branch_heads.get(current_branch)) |commit_idx| {
                    // Stamp the tag label onto the commit (the commit may have had an
                    // empty tag field from a plain `commit` directive).
                    model.commits.items[commit_idx].tag = tag_label;
                    // Register the tag as a first-class Tag entity so the layout engine
                    // can compute its screen position independently of the commit dot.
                    try model.tags.append(.{
                        .label = tag_label,
                        .commit_idx = commit_idx,
                        .branch = current_branch,
                    });
                }
            }
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
    const idx = pu.indexOfStr(text, key) orelse return "";
    const after = pu.strip(text[idx + key.len ..]);
    if (after.len == 0) return "";

    // Value may be quoted
    if (after[0] == '"') {
        const close = pu.indexOfChar(after[1..], '"') orelse return after[1..];
        return after[1 .. close + 1];
    }

    // Unquoted: take until next space or end
    const end = std.mem.indexOfAny(u8, after, " \t") orelse after.len;
    return after[0..end];
}

fn firstWord(s: []const u8) []const u8 {
    const trimmed = pu.strip(s);
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "gitgraph parse commits" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit
        \\    commit
        \\    commit
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 3), model.commits.items.len);
    try testing.expectEqualStrings("main", model.commits.items[0].branch);
}

test "gitgraph parse branch and checkout" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    commit
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 3), model.commits.items.len);
    try testing.expectEqualStrings("main", model.commits.items[0].branch);
    try testing.expectEqualStrings("develop", model.commits.items[1].branch);
    try testing.expectEqualStrings("main", model.commits.items[2].branch);
    try testing.expectEqual(@as(usize, 2), model.branches.items.len);
}

test "gitgraph parse merge" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit
        \\    branch feature
        \\    commit
        \\    checkout main
        \\    merge feature
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.merges.items.len);
    try testing.expectEqualStrings("feature", model.merges.items[0].from_branch);
    try testing.expectEqualStrings("main", model.merges.items[0].to_branch);
}

test "gitgraph parse commit with attributes" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit id: "abc" msg: "Initial" tag: "v1.0"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.commits.items.len);
    try testing.expectEqualStrings("abc", model.commits.items[0].id);
    try testing.expectEqualStrings("Initial", model.commits.items[0].message);
    try testing.expectEqualStrings("v1.0", model.commits.items[0].tag);
}

test "gitgraph parse empty input" {
    const allocator = testing.allocator;
    var model = try parse(allocator, "");
    defer model.deinit();
    try testing.expectEqual(@as(usize, 0), model.commits.items.len);
}

test "gitgraph parse orientation TB" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph TB
        \\    commit
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(gg.Orientation.tb, model.orientation);
}

test "gitgraph parse lowercase gitgraph header" {
    // GitHub's sample markdown uses lowercase 'gitgraph'
    const allocator = testing.allocator;
    const source =
        \\gitgraph
        \\    commit
        \\    commit
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 2), model.commits.items.len);
    try testing.expectEqual(gg.Orientation.lr, model.orientation);
}

test "gitgraph parse commit with order attribute" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit id: "A" order: 3
        \\    commit id: "B" order: 1
        \\    commit id: "C"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 3), model.commits.items.len);
    try testing.expectEqual(@as(?u32, 3), model.commits.items[0].explicit_order);
    try testing.expectEqual(@as(?u32, 1), model.commits.items[1].explicit_order);
    try testing.expectEqual(@as(?u32, null), model.commits.items[2].explicit_order);
}

test "gitgraph parse tag creates Tag entity" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit id: "init" tag: "v0.1"
        \\    commit id: "feat"
        \\    commit id: "rel" tag: "v1.0"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 2), model.tags.items.len);
    try testing.expectEqualStrings("v0.1", model.tags.items[0].label);
    try testing.expectEqual(@as(usize, 0), model.tags.items[0].commit_idx);
    try testing.expectEqualStrings("v1.0", model.tags.items[1].label);
    try testing.expectEqual(@as(usize, 2), model.tags.items[1].commit_idx);
}

test "gitgraph parse merge with tag creates Tag entity" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit
        \\    branch feature
        \\    commit
        \\    checkout main
        \\    merge feature tag: "release-1"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.tags.items.len);
    try testing.expectEqualStrings("release-1", model.tags.items[0].label);
}

test "gitgraph parse accTitle and accDescr directives skipped" {
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    accTitle: My diagram
        \\    accDescr: A simple git graph
        \\    commit
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.commits.items.len);
}

test "gitgraph parent wiring via branch_heads" {
    // Verify that appendCommit correctly wires parent IDs via branch_heads
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit id: "A"
        \\    commit id: "B"
        \\    branch feature
        \\    commit id: "C"
        \\    checkout main
        \\    commit id: "D"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // A has no parent (first commit)
    try testing.expectEqual(@as(usize, 0), model.commits.items[0].parents.items.len);
    // B's parent is A
    try testing.expectEqualStrings("A", model.commits.items[1].parents.items[0]);
    // C's parent is B (inherited from main when branch was created)
    try testing.expectEqualStrings("B", model.commits.items[2].parents.items[0]);
    // D's parent is B (back on main, last main commit was B)
    try testing.expectEqualStrings("B", model.commits.items[3].parents.items[0]);
}

test "gitgraph docs sample renders without error" {
    // Matches the gitgraph block in docs/github-markdown-samples.md
    const allocator = testing.allocator;
    const source =
        \\gitgraph
        \\    commit
        \\    commit
        \\    branch feature
        \\    checkout feature
        \\    commit
        \\    commit
        \\    checkout main
        \\    merge feature
        \\    commit
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 6), model.commits.items.len);
    try testing.expectEqual(@as(usize, 2), model.branches.items.len);
    try testing.expectEqual(@as(usize, 1), model.merges.items.len);
}

test "gitgraph parse standalone tag directive quoted" {
    // `tag "v1.0"` as a standalone directive must attach a Tag entity to the
    // most recently committed commit on the current branch.
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit id: "A"
        \\    tag "v1.0"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.commits.items.len);
    try testing.expectEqual(@as(usize, 1), model.tags.items.len);
    try testing.expectEqualStrings("v1.0", model.tags.items[0].label);
    try testing.expectEqual(@as(usize, 0), model.tags.items[0].commit_idx);
    try testing.expectEqualStrings("main", model.tags.items[0].branch);
}

test "gitgraph parse standalone tag directive unquoted" {
    // Bare (unquoted) label: `tag v1.0`
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit
        \\    tag v1.0
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.tags.items.len);
    try testing.expectEqualStrings("v1.0", model.tags.items[0].label);
}

test "gitgraph parse standalone tag on feature branch" {
    // Standalone tag should attach to the most recent commit on the CURRENT
    // branch, not necessarily on main.
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit id: "A"
        \\    branch feature
        \\    commit id: "B"
        \\    tag "v1.0"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 2), model.commits.items.len);
    try testing.expectEqual(@as(usize, 1), model.tags.items.len);
    // Tag should be attached to commit B (index 1), which is the latest on feature
    try testing.expectEqual(@as(usize, 1), model.tags.items[0].commit_idx);
    try testing.expectEqualStrings("v1.0", model.tags.items[0].label);
    try testing.expectEqualStrings("feature", model.tags.items[0].branch);
}

test "gitgraph parse standalone tag empty label is silently ignored" {
    // An empty or missing label after `tag` should not produce a Tag entity.
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit
        \\    tag ""
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // Empty-quoted label results in "" which has len == 0 → not registered.
    try testing.expectEqual(@as(usize, 0), model.tags.items.len);
}

test "gitgraph parse standalone tag with no prior commit is silently ignored" {
    // When there is no commit on the current branch yet, standalone `tag`
    // should not crash or produce any Tag entity.
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    tag "orphan"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 0), model.commits.items.len);
    try testing.expectEqual(@as(usize, 0), model.tags.items.len);
}

test "gitgraph parse multiple standalone tags on sequential commits" {
    // Each tag should bind to the immediately preceding commit.
    const allocator = testing.allocator;
    const source =
        \\gitGraph
        \\    commit id: "A"
        \\    tag "v1.0"
        \\    commit id: "B"
        \\    tag "v2.0"
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 2), model.tags.items.len);
    try testing.expectEqualStrings("v1.0", model.tags.items[0].label);
    try testing.expectEqual(@as(usize, 0), model.tags.items[0].commit_idx);
    try testing.expectEqualStrings("v2.0", model.tags.items[1].label);
    try testing.expectEqual(@as(usize, 1), model.tags.items[1].commit_idx);
}
