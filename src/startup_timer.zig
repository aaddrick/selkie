const std = @import("std");

/// Lightweight startup timer for measuring application load time.
/// Uses monotonic clock to avoid wall-clock drift.
///
/// Usage:
///   var timer = StartupTimer.init();
///   // ... do work ...
///   timer.mark("phase_name");
///   // ... do more work ...
///   timer.reportStartupComplete();
pub const StartupTimer = struct {
    start_ns: i128,
    last_ns: i128,
    phase_count: usize,
    phases: [max_phases]Phase,

    const max_phases = 16;

    /// Startup should complete within this threshold (milliseconds).
    const target_ms: f64 = 1000.0;

    const ns_per_ms = 1_000_000.0;

    const Phase = struct {
        name: []const u8,
        elapsed_ms: f64,
        cumulative_ms: f64,
    };

    fn nsToMs(ns: i128) f64 {
        return @as(f64, @floatFromInt(ns)) / ns_per_ms;
    }

    /// Create a new startup timer. Captures the current time as the start point.
    pub fn init() StartupTimer {
        const now = std.time.nanoTimestamp();
        return .{
            .start_ns = now,
            .last_ns = now,
            .phase_count = 0,
            .phases = undefined,
        };
    }

    /// Mark the completion of a startup phase.
    /// Records the time since the last mark (or init).
    pub fn mark(self: *StartupTimer, name: []const u8) void {
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
    pub fn totalMs(self: *const StartupTimer) f64 {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.start_ns;
        return nsToMs(elapsed_ns);
    }

    /// Log startup completion with total time and per-phase breakdown.
    /// Emits a warning if startup exceeds the target threshold.
    pub fn reportStartupComplete(self: *StartupTimer) void {
        self.mark("ready");
        const total = self.totalMs();

        std.log.info("Startup complete in {d:.1}ms", .{total});

        // Log per-phase breakdown at debug level
        for (self.phases[0..self.phase_count]) |phase| {
            std.log.debug("  [{d:.1}ms / {d:.1}ms] {s}", .{
                phase.elapsed_ms,
                phase.cumulative_ms,
                phase.name,
            });
        }

        if (total > target_ms) {
            std.log.warn("Startup exceeded {d:.0}ms target ({d:.1}ms)", .{ target_ms, total });
        }
    }

    /// Check if startup is within the target threshold.
    pub fn isWithinTarget(self: *const StartupTimer) bool {
        return self.totalMs() < target_ms;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "StartupTimer basic lifecycle" {
    var timer = StartupTimer.init();
    timer.mark("phase1");
    timer.mark("phase2");

    const total = timer.totalMs();
    try std.testing.expect(total >= 0.0);
    try std.testing.expect(total < 1000.0); // Test should complete in well under 1s
    try std.testing.expectEqual(@as(usize, 2), timer.phase_count);
    try std.testing.expectEqualStrings("phase1", timer.phases[0].name);
    try std.testing.expectEqualStrings("phase2", timer.phases[1].name);
}

test "StartupTimer cumulative time is monotonically increasing" {
    var timer = StartupTimer.init();
    timer.mark("a");
    timer.mark("b");
    timer.mark("c");

    try std.testing.expect(timer.phases[0].cumulative_ms <= timer.phases[1].cumulative_ms);
    try std.testing.expect(timer.phases[1].cumulative_ms <= timer.phases[2].cumulative_ms);
}

test "StartupTimer isWithinTarget returns true for fast startup" {
    const timer = StartupTimer.init();
    try std.testing.expect(timer.isWithinTarget());
}

test "StartupTimer handles max phases gracefully" {
    var timer = StartupTimer.init();
    // Fill all phase slots
    for (0..StartupTimer.max_phases) |_| {
        timer.mark("phase");
    }
    // Extra marks beyond max should not crash
    timer.mark("overflow");
    try std.testing.expectEqual(StartupTimer.max_phases, timer.phase_count);
}

test "StartupTimer reportStartupComplete does not crash" {
    var timer = StartupTimer.init();
    timer.mark("init");
    timer.reportStartupComplete();
    // Just verify it doesn't panic; the report goes to std.log
}

test "StartupTimer target threshold is 1000ms" {
    try std.testing.expectEqual(@as(f64, 1000.0), StartupTimer.target_ms);
}
