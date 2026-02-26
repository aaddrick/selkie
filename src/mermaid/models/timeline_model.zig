const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

pub const TimelineEvent = struct {
    text: []const u8 = "",
};

pub const TimelinePeriod = struct {
    label: []const u8 = "",
    events: std.ArrayList(TimelineEvent),
    // Layout fields
    x: f32 = 0,
    width: f32 = 0,

    pub fn init(allocator: Allocator) TimelinePeriod {
        return .{
            .events = std.ArrayList(TimelineEvent).init(allocator),
        };
    }

    pub fn deinit(self: *TimelinePeriod) void {
        self.events.deinit();
    }
};

pub const TimelineSection = struct {
    name: []const u8 = "",
    periods: std.ArrayList(TimelinePeriod),

    pub fn init(allocator: Allocator) TimelineSection {
        return .{
            .periods = std.ArrayList(TimelinePeriod).init(allocator),
        };
    }

    pub fn deinit(self: *TimelineSection) void {
        for (self.periods.items) |*p| {
            p.deinit();
        }
        self.periods.deinit();
    }
};

pub const TimelineModel = struct {
    title: []const u8 = "",
    sections: std.ArrayList(TimelineSection),
    allocator: Allocator,

    pub fn init(allocator: Allocator) TimelineModel {
        return .{
            .sections = std.ArrayList(TimelineSection).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TimelineModel) void {
        for (self.sections.items) |*s| {
            s.deinit();
        }
        self.sections.deinit();
    }
};
