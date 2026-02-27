const std = @import("std");
const Allocator = std.mem.Allocator;
const pu = @import("../parse_utils.zig");
const cm = @import("../models/class_model.zig");
const ClassModel = cm.ClassModel;
const ClassMember = cm.ClassMember;
const ClassRelationship = cm.ClassRelationship;
const Visibility = cm.Visibility;
const RelationshipType = cm.RelationshipType;

pub fn parse(allocator: Allocator, source: []const u8) !ClassModel {
    var model = ClassModel.init(allocator);
    errdefer model.deinit();

    var lines = try pu.splitLines(allocator, source);
    defer lines.deinit();

    var past_header = false;
    var current_class: ?[]const u8 = null;
    var brace_depth: u32 = 0;

    for (lines.items) |raw_line| {
        const line = pu.strip(raw_line);

        if (line.len == 0 or pu.isComment(line)) continue;

        if (!past_header) {
            if (std.mem.eql(u8, line, "classDiagram") or pu.startsWith(line, "classDiagram ")) {
                past_header = true;
                continue;
            }
            past_header = true;
            continue;
        }

        // Check for class block opening: "class ClassName {"
        if (pu.startsWith(line, "class ")) {
            const rest = pu.strip(line["class ".len..]);
            if (pu.endsWith(rest, "{")) {
                const class_name = pu.strip(rest[0 .. rest.len - 1]);
                _ = try model.ensureClass(class_name);
                current_class = class_name;
                brace_depth = 1;
                continue;
            }
            // "class ClassName" without brace - just declare
            const class_name = rest;
            // Check for generic: "class ClassName~GenericType~"
            if (pu.indexOfChar(class_name, '~')) |tilde| {
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
        if (pu.startsWith(line, "<<")) {
            if (pu.indexOfStr(line, ">>")) |close| {
                const annotation = line[0 .. close + 2];
                const class_name = pu.strip(line[close + 2 ..]);
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
        if (pu.indexOfStr(line, " : ")) |colon_pos| {
            const class_name = pu.strip(line[0..colon_pos]);
            const member_str = pu.strip(line[colon_pos + 3 ..]);
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
        if (pu.indexOfStr(line, arr.pattern)) |pos| {
            const left_part = pu.strip(line[0..pos]);
            const right_part = pu.strip(line[pos + arr.pattern.len ..]);

            if (left_part.len == 0 or right_part.len == 0) continue;

            // Check for label after " : "
            var to_class: []const u8 = right_part;
            var label: ?[]const u8 = null;
            if (pu.indexOfStr(right_part, " : ")) |colon| {
                to_class = pu.strip(right_part[0..colon]);
                label = pu.strip(right_part[colon + 3 ..]);
            }

            // Check for cardinality in quotes: "1" -- "*"
            const from_class = pu.stripQuotes(left_part);
            to_class = pu.stripQuotes(to_class);

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
    if (pu.indexOfChar(text, '(') != null) {
        is_method = true;
    }

    return .{
        .name = text,
        .visibility = visibility,
        .is_method = is_method,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "class diagram parse classes and relationship" {
    const allocator = testing.allocator;
    const source =
        \\classDiagram
        \\    Animal <|-- Dog
        \\    Animal <|-- Cat
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    // Animal, Dog, Cat
    try testing.expectEqual(@as(usize, 3), model.classes.items.len);
    try testing.expectEqual(@as(usize, 2), model.relationships.items.len);
    try testing.expectEqual(cm.RelationshipType.inheritance, model.relationships.items[0].rel_type);
}

test "class diagram parse members via colon syntax" {
    const allocator = testing.allocator;
    const source =
        \\classDiagram
        \\    Animal : +name
        \\    Animal : +eat()
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const cls = model.findClass("Animal") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), cls.members.items.len);
    try testing.expectEqual(cm.Visibility.public, cls.members.items[0].visibility);
    try testing.expect(!cls.members.items[0].is_method);
    try testing.expect(cls.members.items[1].is_method);
}

test "class diagram parse class block" {
    const allocator = testing.allocator;
    const source =
        \\classDiagram
        \\    class Duck {
        \\        +swim()
        \\        -size
        \\    }
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    const cls = model.findClass("Duck") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), cls.members.items.len);
    try testing.expectEqual(cm.Visibility.public, cls.members.items[0].visibility);
    try testing.expectEqual(cm.Visibility.private, cls.members.items[1].visibility);
}

test "class diagram parse empty input" {
    const allocator = testing.allocator;
    var model = try parse(allocator, "");
    defer model.deinit();
    try testing.expectEqual(@as(usize, 0), model.classes.items.len);
}

test "class diagram parse relationship with label" {
    const allocator = testing.allocator;
    const source =
        \\classDiagram
        \\    Animal --> Food : eats
    ;
    var model = try parse(allocator, source);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.relationships.items.len);
    try testing.expectEqualStrings("eats", model.relationships.items[0].label orelse "");
}
