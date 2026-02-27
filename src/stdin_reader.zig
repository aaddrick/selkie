const std = @import("std");
const Allocator = std.mem.Allocator;

const chunk_size = 8192;

/// Read all content from stdin into an allocator-backed buffer.
/// Returns null if stdin is a TTY (interactive terminal).
/// Returns error on read failure or if input exceeds `max_size`.
pub fn readStdin(allocator: Allocator, max_size: usize) !?[]u8 {
    const stdin = std.io.getStdIn();

    // If stdin is a TTY, there's no piped content to read
    if (stdin.isTty()) return null;

    return try readAllBounded(allocator, stdin.reader(), max_size);
}

/// Read all bytes from `reader` into an allocated buffer.
/// Returns error if input is empty or exceeds `max_size`.
pub fn readAllBounded(allocator: Allocator, reader: anytype, max_size: usize) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const limit = std.math.add(usize, max_size, 1) catch return error.StdinTooLarge;
    while (true) {
        const remaining = limit -| buf.items.len;
        if (remaining == 0) return error.StdinTooLarge;
        const to_read = @min(chunk_size, remaining);
        try buf.ensureTotalCapacity(buf.items.len + to_read);

        const dest = buf.unusedCapacitySlice()[0..to_read];
        const bytes_read = try reader.read(dest);
        buf.items.len += bytes_read;

        if (bytes_read == 0) break;
        if (buf.items.len > max_size) return error.StdinTooLarge;
    }

    if (buf.items.len == 0) return error.EmptyStdin;

    return buf.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "readAllBounded returns complete content for normal input" {
    const input = "# Hello World\n\nThis is **markdown** content.";
    var stream = std.io.fixedBufferStream(input);

    const result = try readAllBounded(testing.allocator, stream.reader(), 10 * 1024 * 1024);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(input, result);
}

test "readAllBounded returns error.EmptyStdin for empty input" {
    var stream = std.io.fixedBufferStream("");

    const result = readAllBounded(testing.allocator, stream.reader(), 10 * 1024 * 1024);
    try testing.expectError(error.EmptyStdin, result);
}

test "readAllBounded returns error.StdinTooLarge when input exceeds limit" {
    const limit = 64;
    const input = "x" ** (limit + 1);
    var stream = std.io.fixedBufferStream(input);

    const result = readAllBounded(testing.allocator, stream.reader(), limit);
    try testing.expectError(error.StdinTooLarge, result);
}

test "readAllBounded handles content exactly at size limit" {
    const limit = 32;
    const input = "a" ** limit;
    var stream = std.io.fixedBufferStream(input);

    const result = try readAllBounded(testing.allocator, stream.reader(), limit);
    defer testing.allocator.free(result);

    try testing.expectEqual(limit, result.len);
    try testing.expectEqualStrings(input, result);
}

test "readAllBounded handles multi-chunk content" {
    // Content larger than chunk_size (8192) to test chunked reading
    const size = 16384;
    const input = "A" ** size;
    var stream = std.io.fixedBufferStream(input);

    const result = try readAllBounded(testing.allocator, stream.reader(), 10 * 1024 * 1024);
    defer testing.allocator.free(result);

    try testing.expectEqual(size, result.len);
    try testing.expectEqualStrings(input, result);
}
