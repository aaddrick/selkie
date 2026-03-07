//! Emoji Shortcode Replacement
//!
//! Replaces GitHub-style emoji shortcodes (e.g., `:smile:`) with their Unicode equivalents.
//! Covers the most commonly used emoji shortcodes in GitHub Flavored Markdown.

const std = @import("std");

/// Map of shortcode names to UTF-8 emoji strings.
/// Sorted by name for binary search.
const EmojiEntry = struct {
    name: []const u8,
    emoji: []const u8,
};

/// Common emoji shortcodes used on GitHub, sorted alphabetically for binary search.
const emoji_table = [_]EmojiEntry{
    .{ .name = "+1", .emoji = "\xf0\x9f\x91\x8d" }, // 👍
    .{ .name = "-1", .emoji = "\xf0\x9f\x91\x8e" }, // 👎
    .{ .name = "100", .emoji = "\xf0\x9f\x92\xaf" }, // 💯
    .{ .name = "arrow_down", .emoji = "\xe2\xac\x87\xef\xb8\x8f" }, // ⬇️
    .{ .name = "arrow_left", .emoji = "\xe2\xac\x85\xef\xb8\x8f" }, // ⬅️
    .{ .name = "arrow_right", .emoji = "\xe2\x9e\xa1\xef\xb8\x8f" }, // ➡️
    .{ .name = "arrow_up", .emoji = "\xe2\xac\x86\xef\xb8\x8f" }, // ⬆️
    .{ .name = "bangbang", .emoji = "\xe2\x80\xbc\xef\xb8\x8f" }, // ‼️
    .{ .name = "blue_book", .emoji = "\xf0\x9f\x93\x98" }, // 📘
    .{ .name = "boom", .emoji = "\xf0\x9f\x92\xa5" }, // 💥
    .{ .name = "bug", .emoji = "\xf0\x9f\x90\x9b" }, // 🐛
    .{ .name = "bulb", .emoji = "\xf0\x9f\x92\xa1" }, // 💡
    .{ .name = "calendar", .emoji = "\xf0\x9f\x93\x85" }, // 📅
    .{ .name = "check", .emoji = "\xe2\x9c\x94\xef\xb8\x8f" }, // ✔️
    .{ .name = "checkered_flag", .emoji = "\xf0\x9f\x8f\x81" }, // 🏁
    .{ .name = "clipboard", .emoji = "\xf0\x9f\x93\x8b" }, // 📋
    .{ .name = "clown_face", .emoji = "\xf0\x9f\xa4\xa1" }, // 🤡
    .{ .name = "coffee", .emoji = "\xe2\x98\x95" }, // ☕
    .{ .name = "computer", .emoji = "\xf0\x9f\x92\xbb" }, // 💻
    .{ .name = "construction", .emoji = "\xf0\x9f\x9a\xa7" }, // 🚧
    .{ .name = "crossed_fingers", .emoji = "\xf0\x9f\xa4\x9e" }, // 🤞
    .{ .name = "cry", .emoji = "\xf0\x9f\x98\xa2" }, // 😢
    .{ .name = "dart", .emoji = "\xf0\x9f\x8e\xaf" }, // 🎯
    .{ .name = "disappointed", .emoji = "\xf0\x9f\x98\x9e" }, // 😞
    .{ .name = "dizzy", .emoji = "\xf0\x9f\x92\xab" }, // 💫
    .{ .name = "exclamation", .emoji = "\xe2\x9d\x97" }, // ❗
    .{ .name = "eyes", .emoji = "\xf0\x9f\x91\x80" }, // 👀
    .{ .name = "fire", .emoji = "\xf0\x9f\x94\xa5" }, // 🔥
    .{ .name = "gear", .emoji = "\xe2\x9a\x99\xef\xb8\x8f" }, // ⚙️
    .{ .name = "gift", .emoji = "\xf0\x9f\x8e\x81" }, // 🎁
    .{ .name = "green_book", .emoji = "\xf0\x9f\x93\x97" }, // 📗
    .{ .name = "green_heart", .emoji = "\xf0\x9f\x92\x9a" }, // 💚
    .{ .name = "grin", .emoji = "\xf0\x9f\x98\x81" }, // 😁
    .{ .name = "grinning", .emoji = "\xf0\x9f\x98\x80" }, // 😀
    .{ .name = "hammer", .emoji = "\xf0\x9f\x94\xa8" }, // 🔨
    .{ .name = "heart", .emoji = "\xe2\x9d\xa4\xef\xb8\x8f" }, // ❤️
    .{ .name = "heart_eyes", .emoji = "\xf0\x9f\x98\x8d" }, // 😍
    .{ .name = "heavy_check_mark", .emoji = "\xe2\x9c\x94\xef\xb8\x8f" }, // ✔️
    .{ .name = "heavy_multiplication_x", .emoji = "\xe2\x9c\x96\xef\xb8\x8f" }, // ✖️
    .{ .name = "information_source", .emoji = "\xe2\x84\xb9\xef\xb8\x8f" }, // ℹ️
    .{ .name = "joy", .emoji = "\xf0\x9f\x98\x82" }, // 😂
    .{ .name = "key", .emoji = "\xf0\x9f\x94\x91" }, // 🔑
    .{ .name = "laughing", .emoji = "\xf0\x9f\x98\x86" }, // 😆
    .{ .name = "link", .emoji = "\xf0\x9f\x94\x97" }, // 🔗
    .{ .name = "lock", .emoji = "\xf0\x9f\x94\x92" }, // 🔒
    .{ .name = "mag", .emoji = "\xf0\x9f\x94\x8d" }, // 🔍
    .{ .name = "memo", .emoji = "\xf0\x9f\x93\x9d" }, // 📝
    .{ .name = "muscle", .emoji = "\xf0\x9f\x92\xaa" }, // 💪
    .{ .name = "ok_hand", .emoji = "\xf0\x9f\x91\x8c" }, // 👌
    .{ .name = "package", .emoji = "\xf0\x9f\x93\xa6" }, // 📦
    .{ .name = "palm_tree", .emoji = "\xf0\x9f\x8c\xb4" }, // 🌴
    .{ .name = "pencil", .emoji = "\xf0\x9f\x93\x9d" }, // 📝
    .{ .name = "point_right", .emoji = "\xf0\x9f\x91\x89" }, // 👉
    .{ .name = "pray", .emoji = "\xf0\x9f\x99\x8f" }, // 🙏
    .{ .name = "pushpin", .emoji = "\xf0\x9f\x93\x8c" }, // 📌
    .{ .name = "question", .emoji = "\xe2\x9d\x93" }, // ❓
    .{ .name = "rage", .emoji = "\xf0\x9f\x98\xa1" }, // 😡
    .{ .name = "relaxed", .emoji = "\xe2\x98\xba\xef\xb8\x8f" }, // ☺️
    .{ .name = "rocket", .emoji = "\xf0\x9f\x9a\x80" }, // 🚀
    .{ .name = "rotating_light", .emoji = "\xf0\x9f\x9a\xa8" }, // 🚨
    .{ .name = "skull", .emoji = "\xf0\x9f\x92\x80" }, // 💀
    .{ .name = "smile", .emoji = "\xf0\x9f\x98\x84" }, // 😄
    .{ .name = "smiley", .emoji = "\xf0\x9f\x98\x83" }, // 😃
    .{ .name = "sparkles", .emoji = "\xe2\x9c\xa8" }, // ✨
    .{ .name = "star", .emoji = "\xe2\xad\x90" }, // ⭐
    .{ .name = "tada", .emoji = "\xf0\x9f\x8e\x89" }, // 🎉
    .{ .name = "thinking", .emoji = "\xf0\x9f\xa4\x94" }, // 🤔
    .{ .name = "thumbsdown", .emoji = "\xf0\x9f\x91\x8e" }, // 👎
    .{ .name = "thumbsup", .emoji = "\xf0\x9f\x91\x8d" }, // 👍
    .{ .name = "trophy", .emoji = "\xf0\x9f\x8f\x86" }, // 🏆
    .{ .name = "unlock", .emoji = "\xf0\x9f\x94\x93" }, // 🔓
    .{ .name = "v", .emoji = "\xe2\x9c\x8c\xef\xb8\x8f" }, // ✌️
    .{ .name = "warning", .emoji = "\xe2\x9a\xa0\xef\xb8\x8f" }, // ⚠️
    .{ .name = "wave", .emoji = "\xf0\x9f\x91\x8b" }, // 👋
    .{ .name = "white_check_mark", .emoji = "\xe2\x9c\x85" }, // ✅
    .{ .name = "wrench", .emoji = "\xf0\x9f\x94\xa7" }, // 🔧
    .{ .name = "x", .emoji = "\xe2\x9d\x8c" }, // ❌
    .{ .name = "zap", .emoji = "\xe2\x9a\xa1" }, // ⚡
};

/// Look up an emoji shortcode name (without colons).
/// Returns the UTF-8 emoji string, or null if not found.
pub fn lookupShortcode(name: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high: usize = emoji_table.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const cmp = std.mem.order(u8, emoji_table[mid].name, name);
        switch (cmp) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return emoji_table[mid].emoji,
        }
    }
    return null;
}

/// Replace all emoji shortcodes in `text` with their Unicode equivalents.
/// Allocates the result with the given arena allocator.
/// Returns null if no shortcodes were found (caller can use original text).
pub fn replaceShortcodes(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    // Quick scan: does the text contain any colons?
    if (std.mem.indexOfScalar(u8, text, ':') == null) return null;

    var result = std.ArrayList(u8).init(arena);
    var found_any = false;
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] == ':') {
            // Look for closing colon
            if (std.mem.indexOfScalar(u8, text[i + 1 ..], ':')) |end_offset| {
                const name = text[i + 1 .. i + 1 + end_offset];
                // Shortcode names are alphanumeric + underscore + hyphen + digits
                if (isValidShortcodeName(name)) {
                    if (lookupShortcode(name)) |emoji| {
                        // Arena OOM during emoji replacement is non-fatal; return unmodified text
                        result.appendSlice(emoji) catch return null;
                        found_any = true;
                        i += end_offset + 2; // Skip past closing colon
                        continue;
                    }
                }
            }
        }
        result.append(text[i]) catch return null; // Arena OOM; non-fatal
        i += 1;
    }

    if (!found_any) return null;
    return result.items;
}

fn isValidShortcodeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 50) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '+') return false;
    }
    return true;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "lookupShortcode finds known emoji" {
    try testing.expect(lookupShortcode("smile") != null);
    try testing.expect(lookupShortcode("rocket") != null);
    try testing.expect(lookupShortcode("heart") != null);
    try testing.expect(lookupShortcode("+1") != null);
    try testing.expect(lookupShortcode("fire") != null);
    try testing.expect(lookupShortcode("tada") != null);
}

test "lookupShortcode returns null for unknown" {
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode("nonexistent_emoji"));
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode(""));
}

test "lookupShortcode returns correct emoji" {
    // Rocket is 🚀 = F0 9F 9A 80
    const rocket = lookupShortcode("rocket").?;
    try testing.expectEqualStrings("\xf0\x9f\x9a\x80", rocket);
}

test "replaceShortcodes replaces known shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), "Hello :rocket: world").?;
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x9a\x80") != null);
    try testing.expect(std.mem.indexOf(u8, result, ":rocket:") == null);
}

test "replaceShortcodes returns null when no shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), replaceShortcodes(arena.allocator(), "No emoji here"));
}

test "replaceShortcodes returns null when no colons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), replaceShortcodes(arena.allocator(), "plain text"));
}

test "replaceShortcodes preserves unknown shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), "Hello :unknown_code: world");
    // No known shortcode found, returns null
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "replaceShortcodes handles multiple shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), ":fire: and :rocket:").?;
    // Should contain both emoji
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x94\xa5") != null); // fire
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x9a\x80") != null); // rocket
}

test "replaceShortcodes handles colon in non-shortcode context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), "time: 12:30 :smile:");
    // Should still find and replace :smile: even with other colons
    try testing.expect(result != null);
    if (result) |r| {
        try testing.expect(std.mem.indexOf(u8, r, "\xf0\x9f\x98\x84") != null); // smile
    }
}

test "isValidShortcodeName rejects empty" {
    try testing.expect(!isValidShortcodeName(""));
}

test "isValidShortcodeName accepts valid names" {
    try testing.expect(isValidShortcodeName("smile"));
    try testing.expect(isValidShortcodeName("+1"));
    try testing.expect(isValidShortcodeName("heart_eyes"));
    try testing.expect(isValidShortcodeName("ok_hand"));
}

test "isValidShortcodeName rejects names with spaces" {
    try testing.expect(!isValidShortcodeName("not valid"));
}

test "emoji_table is sorted" {
    for (1..emoji_table.len) |i| {
        const order = std.mem.order(u8, emoji_table[i - 1].name, emoji_table[i].name);
        try testing.expect(order == .lt);
    }
}
