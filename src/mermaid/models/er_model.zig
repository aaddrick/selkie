const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const Graph = graph_mod.Graph;

pub const ERAttribute = struct {
    attr_type: []const u8, // e.g. "string", "int"
    name: []const u8,
    key_type: ?[]const u8 = null, // "PK", "FK", "UK"
    comment: ?[]const u8 = null,
};

pub const EREntity = struct {
    name: []const u8,
    attributes: std.ArrayList(ERAttribute),

    // Layout fields
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const Cardinality = enum {
    zero_or_one, // |o or o|
    exactly_one, // ||
    zero_or_more, // }o or o{
    one_or_more, // }| or |{
};

pub const ERRelationship = struct {
    from: []const u8,
    to: []const u8,
    label: []const u8 = "",
    from_cardinality: Cardinality = .exactly_one,
    to_cardinality: Cardinality = .exactly_one,
};

pub const ERModel = struct {
    entities: std.ArrayList(EREntity),
    relationships: std.ArrayList(ERRelationship),
    graph: Graph,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ERModel {
        return .{
            .entities = std.ArrayList(EREntity).init(allocator),
            .relationships = std.ArrayList(ERRelationship).init(allocator),
            .graph = Graph.init(allocator, .TD),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ERModel) void {
        for (self.entities.items) |*e| {
            e.attributes.deinit();
        }
        self.entities.deinit();
        self.relationships.deinit();
        self.graph.deinit();
    }

    pub fn findEntityMut(self: *ERModel, name: []const u8) ?*EREntity {
        for (self.entities.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    pub fn ensureEntity(self: *ERModel, name: []const u8) !*EREntity {
        if (self.findEntityMut(name)) |e| return e;
        try self.entities.append(.{
            .name = name,
            .attributes = std.ArrayList(ERAttribute).init(self.allocator),
        });
        return &self.entities.items[self.entities.items.len - 1];
    }
};
