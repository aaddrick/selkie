const std = @import("std");

/// Maximum stack buffer size for null-terminating slices.
/// Strings longer than this will be truncated with a warning logged.
const max_stack_buf = 2048;

/// Result of null-terminating a slice. Holds either a stack-buffered
/// sentinel pointer or the original pointer if already sentinel-terminated.
pub const ZSlice = struct {
    ptr: [:0]const u8,
};

/// Convert a `[]const u8` slice into a `[:0]const u8` suitable for C APIs.
///
/// Uses a caller-provided stack buffer to avoid heap allocation. If the text
/// exceeds the buffer size, it is truncated and a warning is logged.
///
/// The returned slice is only valid for the lifetime of `buf`.
pub fn sliceToZ(buf: []u8, text: []const u8) [:0]const u8 {
    std.debug.assert(buf.len >= 1);
    if (text.len == 0) {
        buf[0] = 0;
        return buf[0..0 :0];
    }
    const len = @min(text.len, buf.len - 1);
    if (len < text.len) {
        std.log.warn("sliceToZ: truncating {d}-byte string to {d} bytes", .{ text.len, len });
    }
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    return buf[0..len :0];
}
