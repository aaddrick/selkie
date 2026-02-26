const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

pub const JourneyTask = struct {
    description: []const u8 = "",
    score: u8 = 3, // 1-5
    actors: std.ArrayList([]const u8),
    // Layout fields
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(allocator: Allocator) JourneyTask {
        return .{
            .actors = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *JourneyTask) void {
        self.actors.deinit();
    }
};

pub const JourneySection = struct {
    name: []const u8 = "",
    tasks: std.ArrayList(JourneyTask),

    pub fn init(allocator: Allocator) JourneySection {
        return .{
            .tasks = std.ArrayList(JourneyTask).init(allocator),
        };
    }

    pub fn deinit(self: *JourneySection) void {
        for (self.tasks.items) |*t| {
            t.deinit();
        }
        self.tasks.deinit();
    }
};

pub const JourneyModel = struct {
    title: []const u8 = "",
    sections: std.ArrayList(JourneySection),
    allocator: Allocator,

    pub fn init(allocator: Allocator) JourneyModel {
        return .{
            .sections = std.ArrayList(JourneySection).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JourneyModel) void {
        for (self.sections.items) |*s| {
            s.deinit();
        }
        self.sections.deinit();
    }
};

/// Score-based color: 1=red, 3=yellow, 5=green
pub fn scoreColor(score: u8) rl.Color {
    return switch (score) {
        1 => rl.Color{ .r = 220, .g = 53, .b = 69, .a = 255 }, // red
        2 => rl.Color{ .r = 253, .g = 126, .b = 20, .a = 255 }, // orange
        3 => rl.Color{ .r = 255, .g = 193, .b = 7, .a = 255 }, // yellow
        4 => rl.Color{ .r = 154, .g = 205, .b = 50, .a = 255 }, // yellow-green
        5 => rl.Color{ .r = 40, .g = 167, .b = 69, .a = 255 }, // green
        else => rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 },
    };
}
