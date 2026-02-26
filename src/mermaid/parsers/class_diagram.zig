const std = @import("std");
const Allocator = std.mem.Allocator;
const cm = @import("../models/class_model.zig");
const ClassModel = cm.ClassModel;
const ClassMember = cm.ClassMember;
const ClassRelationship = cm.ClassRelationship;
const Visibility = cm.Visibility;
const RelationshipType = cm.RelationshipType;

pub fn parse(allocator: Allocator, source: []const u8) !ClassModel {
    var model = ClassModel.init(allocator);
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
    var current_class: ?[]const u8 = null;
    var brace_depth: u32 = 0;

    for (lines.items) |raw_line| {
        const line = strip(raw_line);

        if (line.len == 0 or isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "classDiagram") or startsWith(line, "classDiagram ")) {
                past_header = true;
                continue;
            }
            past_header = true;
            continue;
        }

        // Check for class block opening: "class ClassName {"
        if (startsWith(line, "class ")) {
            const rest = strip(line["class ".len..]);
            if (endsWith(rest, "{")) {
                const class_name = strip(rest[0 .. rest.len - 1]);
                _ = try model.ensureClass(class_name);
                current_class = class_name;
                brace_depth = 1;
                continue;
            }
            // "class ClassName" without brace - just declare
            const class_name = rest;
            // Check for generic: "class ClassName~GenericType~"
            if (indexOfChar(class_name, '~')) |tilde| {
                const base_name = class_name[0..tilde];
                _ = try model.ensureClass(base_name);
            } else {
                _ = try model.ensureClass(class_name);
            }
            continue;
        }

        // Inside class block
        if (current_class != null and brace_depth > 0) {
            if (std.mem.eql(u8, line, "}")) {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    current_class = null;
                }
                continue;
            }
            // Parse member
            if (model.findClassMut(current_class.?)) |cls| {
                try cls.members.append(parseMember(line));
            }
            continue;
        }

        // Annotation: <<interface>> ClassName
        if (startsWith(line, "<<")) {
            if (indexOfStr(line, ">>")) |close| {
                const annotation = line[0 .. close + 2];
                const class_name = strip(line[close + 2 ..]);
                if (class_name.len > 0) {
                    var cls = try model.ensureClass(class_name);
                    cls.annotation = annotation;
                }
                continue;
            }
        }

        // Try relationship: "ClassA <|-- ClassB : label" or "ClassA --|> ClassB"
        if (try tryParseRelationship(line, &model)) continue;

        // Member addition: "ClassName : +method()" or "ClassName : -field"
        if (indexOfStr(line, " : ")) |colon_pos| {
            const class_name = strip(line[0..colon_pos]);
            const member_str = strip(line[colon_pos + 3 ..]);
            if (class_name.len > 0 and member_str.len > 0) {
                var cls = try model.ensureClass(class_name);
                try cls.members.append(parseMember(member_str));
                continue;
            }
        }
    }

    // Build graph from classes and relationships
    try buildGraph(&model);

    return model;
}

fn buildGraph(model: *ClassModel) !void {
    for (model.classes.items) |cls| {
        try model.graph.addNode(cls.id, cls.label, .rectangle);
    }
    for (model.relationships.items) |rel| {
        var edge = try model.graph.addEdge(rel.from, rel.to);
        if (rel.label != null) edge.label = rel.label;
        switch (rel.rel_type) {
            .dependency, .realization, .dashed_link => edge.style = .dotted,
            else => edge.style = .solid,
        }
    }
}

fn tryParseRelationship(line: []const u8, model: *ClassModel) !bool {
    // Scan for arrow patterns within the line
    const arrows = [_]struct { pattern: []const u8, rel_type: RelationshipType }{
        .{ .pattern = "<|..", .rel_type = .realization },
        .{ .pattern = "..|>", .rel_type = .realization },
        .{ .pattern = "<|--", .rel_type = .inheritance },
        .{ .pattern = "--|>", .rel_type = .inheritance },
        .{ .pattern = "*--", .rel_type = .composition },
        .{ .pattern = "--*", .rel_type = .composition },
        .{ .pattern = "o--", .rel_type = .aggregation },
        .{ .pattern = "--o", .rel_type = .aggregation },
        .{ .pattern = "-->", .rel_type = .association },
        .{ .pattern = "<--", .rel_type = .association },
        .{ .pattern = "..>", .rel_type = .dependency },
        .{ .pattern = "<..", .rel_type = .dependency },
        .{ .pattern = "..", .rel_type = .dashed_link },
        .{ .pattern = "--", .rel_type = .link },
    };

    for (arrows) |arr| {
        if (indexOfStr(line, arr.pattern)) |pos| {
            const left_part = strip(line[0..pos]);
            const right_part = strip(line[pos + arr.pattern.len ..]);

            if (left_part.len == 0 or right_part.len == 0) continue;

            // Check for label after " : "
            var to_class: []const u8 = right_part;
            var label: ?[]const u8 = null;
            if (indexOfStr(right_part, " : ")) |colon| {
                to_class = strip(right_part[0..colon]);
                label = strip(right_part[colon + 3 ..]);
            }

            // Check for cardinality in quotes: "1" -- "*"
            const from_class = stripQuotes(left_part);
            to_class = stripQuotes(to_class);

            if (from_class.len == 0 or to_class.len == 0) continue;

            // Determine direction based on arrow
            var from = from_class;
            var to = to_class;
            // Arrows pointing left (<|-- , <-- , <..) swap direction
            if (arr.pattern.len > 0 and arr.pattern[0] == '<') {
                from = to_class;
                to = from_class;
            }

            _ = try model.ensureClass(from);
            _ = try model.ensureClass(to);

            try model.relationships.append(.{
                .from = from,
                .to = to,
                .label = label,
                .rel_type = arr.rel_type,
            });
            return true;
        }
    }
    return false;
}

fn parseMember(line: []const u8) ClassMember {
    var text = line;
    var visibility: Visibility = .none;
    var is_method = false;

    if (text.len > 0) {
        switch (text[0]) {
            '+' => {
                visibility = .public;
                text = text[1..];
            },
            '-' => {
                visibility = .private;
                text = text[1..];
            },
            '#' => {
                visibility = .protected;
                text = text[1..];
            },
            '~' => {
                visibility = .package;
                text = text[1..];
            },
            else => {},
        }
    }

    // If it contains parentheses, it's a method
    if (indexOfChar(text, '(') != null) {
        is_method = true;
    }

    return .{
        .name = text,
        .visibility = visibility,
        .is_method = is_method,
    };
}

fn strip(s: []const u8) []const u8 {
    var st: usize = 0;
    while (st < s.len and (s[st] == ' ' or s[st] == '\t' or s[st] == '\r')) : (st += 1) {}
    var end = s.len;
    while (end > st and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[st..end];
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
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

fn indexOfChar(haystack: []const u8, needle: u8) ?usize {
    return std.mem.indexOfScalar(u8, haystack, needle);
}

fn indexOfStr(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}
