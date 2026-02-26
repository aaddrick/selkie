const std = @import("std");
const Allocator = std.mem.Allocator;
const em = @import("../models/er_model.zig");
const ERModel = em.ERModel;
const ERAttribute = em.ERAttribute;
const ERRelationship = em.ERRelationship;
const Cardinality = em.Cardinality;

pub fn parse(allocator: Allocator, source: []const u8) !ERModel {
    var model = ERModel.init(allocator);

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
    var current_entity: ?[]const u8 = null;
    var brace_depth: u32 = 0;

    for (lines.items) |raw_line| {
        const line = strip(raw_line);

        if (line.len == 0 or isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "erDiagram") or startsWith(line, "erDiagram ")) {
                past_header = true;
                continue;
            }
            past_header = true;
            continue;
        }

        // Entity block: "ENTITY_NAME {"
        if (endsWith(line, "{")) {
            const entity_name = strip(line[0 .. line.len - 1]);
            if (entity_name.len > 0) {
                _ = try model.ensureEntity(entity_name);
                current_entity = entity_name;
                brace_depth = 1;
                continue;
            }
        }

        // Inside entity block
        if (current_entity != null and brace_depth > 0) {
            if (std.mem.eql(u8, line, "}")) {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    current_entity = null;
                }
                continue;
            }
            // Parse attribute: "type name PK \"comment\""
            if (model.findEntityMut(current_entity.?)) |entity| {
                try entity.attributes.append(parseAttribute(line));
            }
            continue;
        }

        // Relationship: "ENTITY1 ||--o{ ENTITY2 : "label""
        if (try tryParseRelationship(line, &model)) continue;
    }

    // Build graph
    try buildGraph(&model);

    return model;
}

fn buildGraph(model: *ERModel) !void {
    for (model.entities.items) |entity| {
        try model.graph.addNode(entity.name, entity.name, .rectangle);
    }
    for (model.relationships.items) |rel| {
        var edge = try model.graph.addEdge(rel.from, rel.to);
        if (rel.label.len > 0) edge.label = rel.label;
    }
}

fn parseAttribute(line: []const u8) ERAttribute {
    // Format: "type name" or "type name PK" or "type name PK \"comment\""
    var attr = ERAttribute{
        .attr_type = "",
        .name = "",
    };

    var parts = splitSpaces(line);

    if (parts.len >= 1) attr.attr_type = parts.items[0];
    if (parts.len >= 2) attr.name = parts.items[1];
    if (parts.len >= 3) {
        const third = parts.items[2];
        if (std.mem.eql(u8, third, "PK") or std.mem.eql(u8, third, "FK") or std.mem.eql(u8, third, "UK")) {
            attr.key_type = third;
        } else {
            attr.comment = stripQuotes(third);
        }
    }
    if (parts.len >= 4) {
        attr.comment = stripQuotes(parts.items[3]);
    }

    parts.deinit();
    return attr;
}

const SpaceSplit = struct {
    items: [][]const u8,
    buf: [16][]const u8 = undefined,
    len: usize = 0,

    fn deinit(_: *SpaceSplit) void {}
};

fn splitSpaces(line: []const u8) SpaceSplit {
    var result = SpaceSplit{ .items = &.{} };
    var i: usize = 0;
    var count: usize = 0;

    while (i < line.len and count < 16) {
        // skip spaces
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) break;

        // Handle quoted strings
        if (line[i] == '"') {
            const start_pos = i;
            i += 1;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            if (i < line.len) i += 1; // skip closing quote
            result.buf[count] = line[start_pos..i];
            count += 1;
        } else {
            const start_pos = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
            result.buf[count] = line[start_pos..i];
            count += 1;
        }
    }

    result.len = count;
    result.items = result.buf[0..count];
    return result;
}

fn tryParseRelationship(line: []const u8, model: *ERModel) !bool {
    // Pattern: "ENTITY1 <rel> ENTITY2 : label"
    // Relationship patterns: ||--||, ||--o{, }o--||, etc.
    // We look for "--" as the separator between left and right cardinality markers

    const dash_pos = indexOfStr(line, "--") orelse return false;

    // Find space before the relationship marker
    var rel_start: usize = dash_pos;
    while (rel_start > 0 and line[rel_start - 1] != ' ' and line[rel_start - 1] != '\t') : (rel_start -= 1) {}

    // Find space after the relationship marker
    var rel_end: usize = dash_pos + 2;
    while (rel_end < line.len and line[rel_end] != ' ' and line[rel_end] != '\t') : (rel_end += 1) {}

    if (rel_start == 0 or rel_end >= line.len) return false;

    const entity1 = strip(line[0..rel_start]);
    const rel_marker = line[rel_start..rel_end];
    const after_rel = strip(line[rel_end..]);

    if (entity1.len == 0 or after_rel.len == 0) return false;

    // Parse entity2 and label: "ENTITY2 : label"
    var entity2 = after_rel;
    var label: []const u8 = "";
    if (indexOfStr(after_rel, " : ")) |colon| {
        entity2 = strip(after_rel[0..colon]);
        label = stripQuotes(strip(after_rel[colon + 3 ..]));
    }

    if (entity2.len == 0) return false;

    // Parse cardinalities from rel_marker
    const left_card = parseLeftCardinality(rel_marker, dash_pos - rel_start);
    const right_card = parseRightCardinality(rel_marker, dash_pos - rel_start);

    _ = try model.ensureEntity(entity1);
    _ = try model.ensureEntity(entity2);

    try model.relationships.append(.{
        .from = entity1,
        .to = entity2,
        .label = label,
        .from_cardinality = left_card,
        .to_cardinality = right_card,
    });

    return true;
}

fn parseLeftCardinality(marker: []const u8, dash_offset: usize) Cardinality {
    // Left part is before the "--"
    if (dash_offset < 2) return .exactly_one;
    const left = marker[0..dash_offset];
    return parseCardinalityStr(left);
}

fn parseRightCardinality(marker: []const u8, dash_offset: usize) Cardinality {
    // Right part is after the "--"
    if (dash_offset + 2 >= marker.len) return .exactly_one;
    const right = marker[dash_offset + 2 ..];
    return parseCardinalityStr(right);
}

fn parseCardinalityStr(s: []const u8) Cardinality {
    if (s.len == 0) return .exactly_one;
    if (containsStr(s, "}o") or containsStr(s, "o{")) return .zero_or_more;
    if (containsStr(s, "}|") or containsStr(s, "|{")) return .one_or_more;
    if (containsStr(s, "|o") or containsStr(s, "o|")) return .zero_or_one;
    return .exactly_one; // || or other
}

fn strip(s: []const u8) []const u8 {
    var st: usize = 0;
    while (st < s.len and (s[st] == ' ' or s[st] == '\t' or s[st] == '\r')) : (st += 1) {}
    var end = s.len;
    while (end > st and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[st..end];
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.mem.eql(u8, s[s.len - suffix.len ..], suffix);
}

fn isComment(line: []const u8) bool {
    return line.len >= 2 and line[0] == '%' and line[1] == '%';
}

fn indexOfStr(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}
