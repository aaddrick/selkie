const std = @import("std");

/// Lightweight shutdown timer for measuring application teardown time.
/// Uses monotonic clock to avoid wall-clock drift.
///
/// Usage:
///   var timer = ShutdownTimer.init();
///   // ... cleanup work ...
///   timer.mark("phase_name");
///   // ... more cleanup ...
///   timer.reportShutdownComplete();
pub const ShutdownTimer = struct {
    start_ns: i128,
    last_ns: i128,
    phase_count: usize,
    phases: [max_phases]Phase,

    const max_phases = 16;

    /// Shutdown should complete well under this threshold (milliseconds).
    const target_ms: f64 = 100.0;

    const ns_per_ms = 1_000_000.0;

    const Phase = struct {
        name: []const u8,
        elapsed_ms: f64,
        cumulative_ms: f64,
    };

    fn nsToMs(ns: i128) f64 {
        return @as(f64, @floatFromInt(ns)) / ns_per_ms;
    }

    /// Create a new shutdown timer. Captures the current time as the start point.
    pub fn init() ShutdownTimer {
        const now = std.time.nanoTimestamp();
        return .{
            .start_ns = now,
            .last_ns = now,
            .phase_count = 0,
            .phases = undefined,
        };
    }

    /// Mark the completion of a shutdown phase.
    /// Records the time since the last mark (or init).
    pub fn mark(self: *ShutdownTimer, name: []const u8) void {
        const now = std.time.nanoTimestamp();
        const phase_ns = now - self.last_ns;
        const cumulative_ns = now - self.start_ns;

        if (self.phase_count < max_phases) {
            self.phases[self.phase_count] = .{
                .name = name,
                .elapsed_ms = nsToMs(phase_ns),
                .cumulative_ms = nsToMs(cumulative_ns),
            };
            self.phase_count += 1;
        }

        self.last_ns = now;
    }

    /// Get total elapsed time since init in milliseconds.
    pub fn totalMs(self: *const ShutdownTimer) f64 {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.start_ns;
        return nsToMs(elapsed_ns);
    }

    /// Log shutdown completion with total time and per-phase breakdown.
    /// Emits a warning if shutdown exceeds the target threshold.
    pub fn reportShutdownComplete(self: *ShutdownTimer) void {
        self.mark("done");
        const total = self.totalMs();

        std.log.info("Shutdown complete in {d:.1}ms", .{total});

        // Log per-phase breakdown at debug level
        for (self.phases[0..self.phase_count]) |phase| {
            std.log.debug("  [{d:.1}ms / {d:.1}ms] {s}", .{
                phase.elapsed_ms,
                phase.cumulative_ms,
                phase.name,
            });
        }

        if (total > target_ms) {
            std.log.warn("Shutdown exceeded {d:.0}ms target ({d:.1}ms)", .{ target_ms, total });
        }
    }

    /// Check if shutdown is within the target threshold.
    pub fn isWithinTarget(self: *const ShutdownTimer) bool {
        return self.totalMs() < target_ms;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ShutdownTimer basic lifecycle" {
    var timer = ShutdownTimer.init();
    timer.mark("phase1");
    timer.mark("phase2");

    const total = timer.totalMs();
    try std.testing.expect(total >= 0.0);
    try std.testing.expect(total < 100.0); // Test should complete in well under 100ms
    try std.testing.expectEqual(@as(usize, 2), timer.phase_count);
    try std.testing.expectEqualStrings("phase1", timer.phases[0].name);
    try std.testing.expectEqualStrings("phase2", timer.phases[1].name);
}

test "ShutdownTimer cumulative time is monotonically increasing" {
    var timer = ShutdownTimer.init();
    timer.mark("a");
    timer.mark("b");
    timer.mark("c");

    try std.testing.expect(timer.phases[0].cumulative_ms <= timer.phases[1].cumulative_ms);
    try std.testing.expect(timer.phases[1].cumulative_ms <= timer.phases[2].cumulative_ms);
}

test "ShutdownTimer isWithinTarget returns true for fast shutdown" {
    const timer = ShutdownTimer.init();
    try std.testing.expect(timer.isWithinTarget());
}

test "ShutdownTimer handles max phases gracefully" {
    var timer = ShutdownTimer.init();
    for (0..ShutdownTimer.max_phases) |_| {
        timer.mark("phase");
    }
    // Extra marks beyond max should not crash
    timer.mark("overflow");
    try std.testing.expectEqual(ShutdownTimer.max_phases, timer.phase_count);
}

test "ShutdownTimer reportShutdownComplete does not crash" {
    var timer = ShutdownTimer.init();
    timer.mark("cleanup");
    timer.reportShutdownComplete();
    // Just verify it doesn't panic; the report goes to std.log
}

test "ShutdownTimer target threshold is 100ms" {
    // Verify the constant is set correctly for quick shutdown
    try std.testing.expectEqual(@as(f64, 100.0), ShutdownTimer.target_ms);
}
