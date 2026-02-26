const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const Graph = graph_mod.Graph;

pub const Visibility = enum {
    public, // +
    private, // -
    protected, // #
    package, // ~
    none,
};

pub const ClassMember = struct {
    name: []const u8,
    visibility: Visibility = .none,
    is_method: bool = false,
};

pub const ClassNode = struct {
    id: []const u8,
    label: []const u8,
    annotation: ?[]const u8 = null, // <<interface>>, <<abstract>>, etc.
    members: std.ArrayList(ClassMember),

    // Layout fields (filled by dagre)
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const RelationshipType = enum {
    inheritance, // --|>
    composition, // --*
    aggregation, // --o
    association, // -->
    dependency, // ..>
    realization, // ..|>
    link, // --
    dashed_link, // ..
};

pub const ClassRelationship = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8 = null,
    rel_type: RelationshipType = .association,
    from_cardinality: ?[]const u8 = null,
    to_cardinality: ?[]const u8 = null,
};

pub const ClassModel = struct {
    classes: std.ArrayList(ClassNode),
    relationships: std.ArrayList(ClassRelationship),
    graph: Graph,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ClassModel {
        return .{
            .classes = std.ArrayList(ClassNode).init(allocator),
            .relationships = std.ArrayList(ClassRelationship).init(allocator),
            .graph = Graph.init(allocator, .TD),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClassModel) void {
        for (self.classes.items) |*cls| {
            cls.members.deinit();
        }
        self.classes.deinit();
        self.relationships.deinit();
        self.graph.deinit();
    }

    pub fn findClass(self: *const ClassModel, id: []const u8) ?*const ClassNode {
        for (self.classes.items) |*cls| {
            if (std.mem.eql(u8, cls.id, id)) return cls;
        }
        return null;
    }

    pub fn findClassMut(self: *ClassModel, id: []const u8) ?*ClassNode {
        for (self.classes.items) |*cls| {
            if (std.mem.eql(u8, cls.id, id)) return cls;
        }
        return null;
    }

    pub fn ensureClass(self: *ClassModel, id: []const u8) !*ClassNode {
        if (self.findClassMut(id)) |cls| return cls;
        try self.classes.append(.{
            .id = id,
            .label = id,
            .members = std.ArrayList(ClassMember).init(self.allocator),
        });
        return &self.classes.items[self.classes.items.len - 1];
    }
};
