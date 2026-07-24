const std = @import("std");

/// Unicode codepoint ranges to load for font rendering.
const Range = struct { start: i32, end: i32 };

/// Eager default set: loaded unconditionally into every font atlas at startup.
/// Covers the codepoints virtually every document needs on first frame —
/// Basic Latin, Latin-1 accented characters/symbols, and common punctuation
/// (em dash, curly quotes, ellipsis).
const default_ranges = [_]Range{
    .{ .start = 0x0020, .end = 0x007E }, // Basic Latin (space through tilde)
    .{ .start = 0x00A0, .end = 0x00FF }, // Latin-1 Supplement (non-breaking space, accented chars, symbols)
    .{ .start = 0x2000, .end = 0x206F }, // General Punctuation (em dash, curly quotes, ellipsis, etc.)
};

/// Lazy remainder pool: not loaded at startup. Loaded on demand (via
/// `App.ensureGlyphs`) the first time a document or user input actually
/// needs one of these codepoints.
const remainder_ranges = [_]Range{
    .{ .start = 0x0100, .end = 0x017F }, // Latin Extended-A (Eastern European)
    .{ .start = 0x0180, .end = 0x024F }, // Latin Extended-B
    .{ .start = 0x0370, .end = 0x03FF }, // Greek and Coptic (α β γ δ π θ σ etc. — required for math)
    .{ .start = 0x2070, .end = 0x209F }, // Superscripts and Subscripts
    .{ .start = 0x20A0, .end = 0x20CF }, // Currency Symbols
    .{ .start = 0x2100, .end = 0x214F }, // Letterlike Symbols
    .{ .start = 0x2190, .end = 0x21FF }, // Arrows
    .{ .start = 0x2200, .end = 0x22FF }, // Mathematical Operators
    .{ .start = 0x2300, .end = 0x23FF }, // Miscellaneous Technical
    .{ .start = 0x25A0, .end = 0x25FF }, // Geometric Shapes
    .{ .start = 0x2600, .end = 0x26FF }, // Miscellaneous Symbols
    .{ .start = 0x2700, .end = 0x27BF }, // Dingbats
    .{ .start = 0xFB00, .end = 0xFB06 }, // Alphabetic Presentation Forms (ligatures: ff, fi, fl, etc.)
    .{ .start = 0xFFFD, .end = 0xFFFD }, // Replacement character
};

/// Number of codepoints covered by `ranges`, computed at comptime.
fn countOf(comptime ranges: []const Range) usize {
    var count: usize = 0;
    for (ranges) |r| {
        count += @as(usize, @intCast(r.end - r.start + 1));
    }
    return count;
}

/// Flatten `ranges` into a sorted array of individual codepoints, built at comptime.
fn buildCodepoints(comptime ranges: []const Range, comptime count: usize) [count]i32 {
    @setEvalBranchQuota(10_000);
    var arr: [count]i32 = undefined;
    var i: usize = 0;
    for (ranges) |r| {
        var cp = r.start;
        while (cp <= r.end) : (cp += 1) {
            arr[i] = cp;
            i += 1;
        }
    }
    return arr;
}

const default_count = countOf(&default_ranges);
const remainder_count = countOf(&remainder_ranges);

/// Codepoints loaded eagerly into every font atlas at startup.
pub const default_codepoints: [default_count]i32 = buildCodepoints(&default_ranges, default_count);

/// Codepoints loaded lazily, on demand, when first needed.
pub const remainder_codepoints: [remainder_count]i32 = buildCodepoints(&remainder_ranges, remainder_count);

/// Growth-only set of codepoints currently loaded into a font's glyph atlas.
///
/// Never shrinks: codepoints are only ever added, mirroring the one-way
/// rebuild-larger-never-smaller nature of atlas expansion (see
/// `App.ensureGlyphs`). Seeded with `default_codepoints` on `init`.
pub const LoadedSet = struct {
    map: std.AutoHashMap(i32, void),

    /// Create a set pre-seeded with the eager default codepoints.
    pub fn init(allocator: std.mem.Allocator) !LoadedSet {
        var map = std.AutoHashMap(i32, void).init(allocator);
        errdefer map.deinit();
        try map.ensureTotalCapacity(default_codepoints.len);
        for (default_codepoints) |cp| {
            map.putAssumeCapacity(cp, {});
        }
        return .{ .map = map };
    }

    pub fn deinit(self: *LoadedSet) void {
        self.map.deinit();
    }

    /// Whether `cp` has already been loaded.
    pub fn contains(self: *const LoadedSet, cp: i32) bool {
        return self.map.contains(cp);
    }

    /// Add `cp` to the set. Returns `true` if it was newly added (the set
    /// grew) and `false` if it was already present.
    pub fn add(self: *LoadedSet, cp: i32) !bool {
        const result = try self.map.getOrPut(cp);
        return !result.found_existing;
    }
};

test "default codepoints contains ASCII printable range" {
    for (0x20..0x7F) |cp| {
        try std.testing.expect(containsCp(&default_codepoints, @intCast(cp)));
    }
}

test "default codepoints contains em dash and curly quotes" {
    try std.testing.expect(containsCp(&default_codepoints, 0x2014)); // em dash
    try std.testing.expect(containsCp(&default_codepoints, 0x2013)); // en dash
    try std.testing.expect(containsCp(&default_codepoints, 0x2018)); // left single quote
    try std.testing.expect(containsCp(&default_codepoints, 0x2019)); // right single quote
    try std.testing.expect(containsCp(&default_codepoints, 0x201C)); // left double quote
    try std.testing.expect(containsCp(&default_codepoints, 0x201D)); // right double quote
    try std.testing.expect(containsCp(&default_codepoints, 0x2026)); // horizontal ellipsis
}

test "default codepoints contains accented Latin characters" {
    try std.testing.expect(containsCp(&default_codepoints, 0x00E9)); // é
    try std.testing.expect(containsCp(&default_codepoints, 0x00F1)); // ñ
    try std.testing.expect(containsCp(&default_codepoints, 0x00FC)); // ü
    try std.testing.expect(containsCp(&default_codepoints, 0x00C0)); // À
}

test "default codepoints contains Latin-1 symbols" {
    try std.testing.expect(containsCp(&default_codepoints, 0x00A9)); // copyright ©
    try std.testing.expect(containsCp(&default_codepoints, 0x00AE)); // registered ®
    try std.testing.expect(containsCp(&default_codepoints, 0x00A0)); // non-breaking space
}

test "default codepoints excludes control characters and remainder ranges" {
    try std.testing.expect(!containsCp(&default_codepoints, 0x0000)); // null
    try std.testing.expect(!containsCp(&default_codepoints, 0x0019)); // end of C0 control range
    try std.testing.expect(!containsCp(&default_codepoints, 0x007F)); // DEL
    try std.testing.expect(!containsCp(&default_codepoints, 0x0080)); // start of C1 control range
    try std.testing.expect(!containsCp(&default_codepoints, 0x009F)); // end of C1 control range
    try std.testing.expect(!containsCp(&default_codepoints, 0x0100)); // Latin Extended-A (remainder)
    try std.testing.expect(!containsCp(&default_codepoints, 0x03C0)); // π (remainder)
    try std.testing.expect(!containsCp(&default_codepoints, 0x20AC)); // euro (remainder)
    try std.testing.expect(!containsCp(&default_codepoints, 0x2192)); // rightwards arrow (remainder)
    try std.testing.expect(!containsCp(&default_codepoints, 0xFFFD)); // replacement character (remainder)
}

test "remainder codepoints contains extended Latin and Greek" {
    try std.testing.expect(containsCp(&remainder_codepoints, 0x0100)); // Ā — Latin Extended-A
    try std.testing.expect(containsCp(&remainder_codepoints, 0x0180)); // Latin Extended-B
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03C0)); // π (pi)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03B1)); // α (alpha)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03B2)); // β (beta)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03B3)); // γ (gamma)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03B4)); // δ (delta)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03B8)); // θ (theta)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03C3)); // σ (sigma)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03A3)); // Σ (Sigma — uppercase sum)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03A0)); // Π (Pi — uppercase)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x03A9)); // Ω (Omega)
}

test "remainder codepoints contains symbol and technical blocks" {
    try std.testing.expect(containsCp(&remainder_codepoints, 0x2070)); // superscript zero
    try std.testing.expect(containsCp(&remainder_codepoints, 0x20AC)); // euro €
    try std.testing.expect(containsCp(&remainder_codepoints, 0x2122)); // trademark ™ (letterlike)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x2192)); // rightwards arrow →
    try std.testing.expect(containsCp(&remainder_codepoints, 0x2211)); // n-ary summation (math operators)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x2318)); // place of interest sign (misc technical)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x25A0)); // black square (geometric shapes)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x2600)); // black sun with rays (misc symbols)
    try std.testing.expect(containsCp(&remainder_codepoints, 0x2713)); // check mark ✓ (dingbats)
}

test "remainder codepoints contains ligatures and replacement character" {
    try std.testing.expect(containsCp(&remainder_codepoints, 0xFB00)); // ﬀ ligature
    try std.testing.expect(containsCp(&remainder_codepoints, 0xFB06)); // ﬆ ligature
    try std.testing.expect(containsCp(&remainder_codepoints, 0xFFFD)); // replacement character �
}

test "remainder codepoints excludes control characters and gaps" {
    try std.testing.expect(!containsCp(&remainder_codepoints, 0x0250)); // gap between Latin Extended-B and Greek
    try std.testing.expect(!containsCp(&remainder_codepoints, 0x036F)); // just before Greek and Coptic block
    try std.testing.expect(!containsCp(&remainder_codepoints, 0x1FFF)); // just before General Punctuation
    try std.testing.expect(!containsCp(&remainder_codepoints, 0x20D0)); // just past Currency Symbols
    try std.testing.expect(!containsCp(&remainder_codepoints, 0x27C0)); // just past Dingbats
    try std.testing.expect(!containsCp(&remainder_codepoints, 0xFB07)); // just past ligatures
    try std.testing.expect(!containsCp(&remainder_codepoints, 0xFFFE)); // just before replacement character
}

test "default and remainder codepoints do not overlap" {
    for (default_codepoints) |cp| {
        try std.testing.expect(!containsCp(&remainder_codepoints, cp));
    }
    for (remainder_codepoints) |cp| {
        try std.testing.expect(!containsCp(&default_codepoints, cp));
    }
}

test "default codepoint count matches expected value" {
    // Hardcoded to catch accidental range additions/removals.
    // Update this value when intentionally changing default_ranges.
    try std.testing.expectEqual(@as(usize, 303), default_codepoints.len);
}

test "remainder codepoint count matches expected value" {
    // Hardcoded to catch accidental range additions/removals.
    // Update this value when intentionally changing remainder_ranges.
    try std.testing.expectEqual(@as(usize, 1832), remainder_codepoints.len);
}

test "LoadedSet is seeded with the default codepoints" {
    var set = try LoadedSet.init(std.testing.allocator);
    defer set.deinit();
    for (default_codepoints) |cp| {
        try std.testing.expect(set.contains(cp));
    }
}

test "LoadedSet does not contain remainder codepoints until added" {
    var set = try LoadedSet.init(std.testing.allocator);
    defer set.deinit();
    try std.testing.expect(!set.contains(remainder_codepoints[0]));
}

test "LoadedSet.add grows the set and is idempotent" {
    var set = try LoadedSet.init(std.testing.allocator);
    defer set.deinit();
    const cp = remainder_codepoints[0];

    try std.testing.expect(!set.contains(cp));
    const grew_first = try set.add(cp);
    try std.testing.expect(grew_first);
    try std.testing.expect(set.contains(cp));

    const grew_second = try set.add(cp);
    try std.testing.expect(!grew_second);
}

// Test helper — linear scan, not for production use.
fn containsCp(haystack: []const i32, needle: i32) bool {
    for (haystack) |cp| {
        if (cp == needle) return true;
    }
    return false;
}
