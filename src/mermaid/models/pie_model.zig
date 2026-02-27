const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

pub const PieSlice = struct {
    label: []const u8,
    value: f64,
    percentage: f64 = 0,
    color: rl.Color = rl.Color{ .r = 100, .g = 100, .b = 200, .a = 255 },
    // Layout fields (filled by pie layout)
    start_angle: f32 = 0,
    end_angle: f32 = 0,
    label_x: f32 = 0,
    label_y: f32 = 0,
};

pub const PieModel = struct {
    title: []const u8 = "",
    slices: std.ArrayList(PieSlice),
    show_data: bool = false,
    // Layout fields
    center_x: f32 = 0,
    center_y: f32 = 0,
    radius: f32 = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) PieModel {
        return .{
            .slices = std.ArrayList(PieSlice).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PieModel) void {
        self.slices.deinit();
    }

    /// Compute percentages from raw values and assign colors from a palette.
    pub fn computePercentages(self: *PieModel) void {
        var total: f64 = 0;
        for (self.slices.items) |s| {
            total += s.value;
        }
        if (total <= 0) return;

        const palette = [_]rl.Color{
            rl.Color{ .r = 76, .g = 114, .b = 176, .a = 255 }, // blue
            rl.Color{ .r = 221, .g = 132, .b = 82, .a = 255 }, // orange
            rl.Color{ .r = 85, .g = 168, .b = 104, .a = 255 }, // green
            rl.Color{ .r = 196, .g = 78, .b = 82, .a = 255 }, // red
            rl.Color{ .r = 129, .g = 114, .b = 178, .a = 255 }, // purple
            rl.Color{ .r = 147, .g = 120, .b = 96, .a = 255 }, // brown
            rl.Color{ .r = 218, .g = 139, .b = 195, .a = 255 }, // pink
            rl.Color{ .r = 140, .g = 140, .b = 140, .a = 255 }, // gray
        };

        for (self.slices.items, 0..) |*s, i| {
            s.percentage = (s.value / total) * 100.0;
            s.color = palette[i % palette.len];
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "computePercentages with normal values" {
    const allocator = testing.allocator;
    var model = PieModel.init(allocator);
    defer model.deinit();

    try model.slices.append(.{ .label = "A", .value = 50 });
    try model.slices.append(.{ .label = "B", .value = 50 });
    model.computePercentages();

    try testing.expectApproxEqAbs(@as(f64, 50.0), model.slices.items[0].percentage, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 50.0), model.slices.items[1].percentage, 0.01);
}

test "computePercentages with zero total leaves percentages at zero" {
    const allocator = testing.allocator;
    var model = PieModel.init(allocator);
    defer model.deinit();

    try model.slices.append(.{ .label = "A", .value = 0 });
    model.computePercentages();

    try testing.expectApproxEqAbs(@as(f64, 0.0), model.slices.items[0].percentage, 0.01);
}

test "computePercentages with empty slices does not panic" {
    const allocator = testing.allocator;
    var model = PieModel.init(allocator);
    defer model.deinit();
    model.computePercentages(); // should not panic
}

test "computePercentages assigns colors from palette" {
    const allocator = testing.allocator;
    var model = PieModel.init(allocator);
    defer model.deinit();

    try model.slices.append(.{ .label = "A", .value = 30 });
    try model.slices.append(.{ .label = "B", .value = 70 });
    model.computePercentages();

    // First slice gets blue (76, 114, 176)
    try testing.expectEqual(@as(u8, 76), model.slices.items[0].color.r);
    // Second slice gets orange (221, 132, 82)
    try testing.expectEqual(@as(u8, 221), model.slices.items[1].color.r);
}
