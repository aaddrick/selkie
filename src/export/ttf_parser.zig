//! Minimal TrueType font parser for PDF embedding.
//!
//! Parses the subset of TTF tables needed to embed fonts in a PDF:
//! - `head`: unitsPerEm for coordinate scaling
//! - `hhea`: ascent, descent, numberOfHMetrics
//! - `hmtx`: per-glyph advance widths (for PDF /W array)
//! - `cmap`: Unicode codepoint → glyph ID mapping (format 4 and 12)
//! - `name`: PostScript font name (for PDF /BaseFont)
//! - `OS/2`: font weight class and flags

const std = @import("std");

pub const ParseError = error{
    InvalidFont,
    TableNotFound,
    UnsupportedCmapFormat,
};

pub const TtfFont = struct {
    data: []const u8,
    units_per_em: u16,
    ascent: i16,
    descent: i16,
    num_h_metrics: u16,
    ps_name: []const u8,
    weight_class: u16,
    // Table offsets for lazy access
    cmap_offset: u32,
    cmap_length: u32,
    hmtx_offset: u32,
    hmtx_length: u32,
    // Parsed cmap subtable info
    cmap_subtable_offset: u32,
    cmap_format: u16,

    /// Map a Unicode codepoint to a glyph ID.
    pub fn glyphId(self: *const TtfFont, codepoint: u32) ?u16 {
        return switch (self.cmap_format) {
            4 => self.cmapFormat4Lookup(codepoint),
            12 => self.cmapFormat12Lookup(codepoint),
            else => null,
        };
    }

    /// Get the advance width of a glyph in font units.
    pub fn glyphWidth(self: *const TtfFont, glyph_id: u16) u16 {
        const offset = self.hmtx_offset;
        const num = self.num_h_metrics;

        if (glyph_id < num) {
            const entry_offset = offset + @as(u32, glyph_id) * 4;
            if (entry_offset + 2 > self.data.len) return 0;
            return readU16(self.data, entry_offset);
        }
        // Glyph IDs >= numberOfHMetrics use the last entry's advance width
        if (num == 0) return 0;
        const last_offset = offset + (@as(u32, num) - 1) * 4;
        if (last_offset + 2 > self.data.len) return 0;
        return readU16(self.data, last_offset);
    }

    fn cmapFormat4Lookup(self: *const TtfFont, codepoint: u32) ?u16 {
        if (codepoint > 0xFFFF) return null;
        const cp: u16 = @intCast(codepoint);
        const base = self.cmap_subtable_offset;
        const data = self.data;

        if (base + 14 > data.len) return null;
        const seg_count_x2 = readU16(data, base + 6);
        const seg_count = seg_count_x2 / 2;

        const end_codes_offset = base + 14;
        // +2 for reservedPad
        const start_codes_offset = end_codes_offset + seg_count_x2 + 2;
        const id_delta_offset = start_codes_offset + seg_count_x2;
        const id_range_offset_base = id_delta_offset + seg_count_x2;

        var i: u32 = 0;
        while (i < seg_count) : (i += 1) {
            const end_code = readU16(data, end_codes_offset + i * 2);
            if (end_code < cp) continue;

            const start_code = readU16(data, start_codes_offset + i * 2);
            if (start_code > cp) return null;

            const id_delta = readI16(data, id_delta_offset + i * 2);
            const id_range_off_pos = id_range_offset_base + i * 2;
            const id_range_offset = readU16(data, id_range_off_pos);

            if (id_range_offset == 0) {
                const result = @as(i32, cp) + @as(i32, id_delta);
                return @intCast(@as(u16, @truncate(@as(u32, @bitCast(result)))));
            } else {
                const glyph_offset = id_range_off_pos + id_range_offset + (cp - start_code) * 2;
                if (glyph_offset + 2 > data.len) return null;
                const glyph_id = readU16(data, glyph_offset);
                if (glyph_id == 0) return null;
                const result = @as(i32, glyph_id) + @as(i32, id_delta);
                return @intCast(@as(u16, @truncate(@as(u32, @bitCast(result)))));
            }
        }
        return null;
    }

    fn cmapFormat12Lookup(self: *const TtfFont, codepoint: u32) ?u16 {
        const base = self.cmap_subtable_offset;
        const data = self.data;

        if (base + 16 > data.len) return null;
        const num_groups = readU32(data, base + 12);

        var i: u32 = 0;
        while (i < num_groups) : (i += 1) {
            const group_offset = base + 16 + i * 12;
            if (group_offset + 12 > data.len) return null;
            const start_char = readU32(data, group_offset);
            const end_char = readU32(data, group_offset + 4);
            const start_glyph = readU32(data, group_offset + 8);

            if (codepoint >= start_char and codepoint <= end_char) {
                const glyph_id = start_glyph + (codepoint - start_char);
                if (glyph_id > 0xFFFF) return null;
                return @intCast(glyph_id);
            }
        }
        return null;
    }
};

pub fn parse(data: []const u8) !TtfFont {
    if (data.len < 12) return ParseError.InvalidFont;

    // Read offset table
    const num_tables = readU16(data, 4);

    // Find required tables
    var head_off: ?u32 = null;
    var head_len: ?u32 = null;
    var hhea_off: ?u32 = null;
    var hmtx_off: ?u32 = null;
    var hmtx_len: ?u32 = null;
    var cmap_off: ?u32 = null;
    var cmap_len: ?u32 = null;
    var name_off: ?u32 = null;
    var name_len: ?u32 = null;
    var os2_off: ?u32 = null;

    var i: u32 = 0;
    while (i < num_tables) : (i += 1) {
        const rec = 12 + i * 16;
        if (rec + 16 > data.len) return ParseError.InvalidFont;
        const tag = data[rec..][0..4];
        const offset = readU32(data, rec + 8);
        const length = readU32(data, rec + 12);

        if (std.mem.eql(u8, tag, "head")) {
            head_off = offset;
            head_len = length;
        } else if (std.mem.eql(u8, tag, "hhea")) {
            hhea_off = offset;
        } else if (std.mem.eql(u8, tag, "hmtx")) {
            hmtx_off = offset;
            hmtx_len = length;
        } else if (std.mem.eql(u8, tag, "cmap")) {
            cmap_off = offset;
            cmap_len = length;
        } else if (std.mem.eql(u8, tag, "name")) {
            name_off = offset;
            name_len = length;
        } else if (std.mem.eql(u8, tag, "OS/2")) {
            os2_off = offset;
        }
    }

    // Parse head table
    const head = head_off orelse return ParseError.TableNotFound;
    if (head + 18 > data.len) return ParseError.InvalidFont;
    const units_per_em = readU16(data, head + 18);

    // Parse hhea table
    const hhea = hhea_off orelse return ParseError.TableNotFound;
    if (hhea + 36 > data.len) return ParseError.InvalidFont;
    const ascent = readI16(data, hhea + 4);
    const descent = readI16(data, hhea + 6);
    const num_h_metrics = readU16(data, hhea + 34);

    // Parse cmap table — find best subtable (prefer format 12, then format 4)
    const cmap = cmap_off orelse return ParseError.TableNotFound;
    const cmap_l = cmap_len orelse return ParseError.TableNotFound;
    if (cmap + 4 > data.len) return ParseError.InvalidFont;
    const num_cmap_tables = readU16(data, cmap + 2);

    var best_subtable_offset: ?u32 = null;
    var best_format: u16 = 0;

    var ci: u32 = 0;
    while (ci < num_cmap_tables) : (ci += 1) {
        const entry = cmap + 4 + ci * 8;
        if (entry + 8 > data.len) break;
        const platform_id = readU16(data, entry);
        const encoding_id = readU16(data, entry + 2);
        const subtable_off = readU32(data, entry + 4);
        const abs_off = cmap + subtable_off;

        // Accept Unicode (0,3) or Windows Unicode BMP (3,1) or Windows Unicode Full (3,10)
        const is_unicode = (platform_id == 0 and encoding_id == 3) or
            (platform_id == 3 and encoding_id == 1) or
            (platform_id == 3 and encoding_id == 10) or
            (platform_id == 0 and encoding_id == 4);

        if (!is_unicode) continue;
        if (abs_off + 2 > data.len) continue;

        const fmt = readU16(data, abs_off);
        if (fmt == 12 and best_format != 12) {
            best_subtable_offset = abs_off;
            best_format = 12;
        } else if (fmt == 4 and best_subtable_offset == null) {
            best_subtable_offset = abs_off;
            best_format = 4;
        }
    }

    if (best_subtable_offset == null) return ParseError.UnsupportedCmapFormat;

    // Parse name table — find PostScript name (name ID 6)
    const name_t = name_off orelse return ParseError.TableNotFound;
    const name_l = name_len orelse return ParseError.TableNotFound;
    _ = name_l;
    var ps_name: []const u8 = "Unknown";

    if (name_t + 6 <= data.len) {
        const name_count = readU16(data, name_t + 2);
        const string_offset = readU16(data, name_t + 4);
        const storage_start = name_t + string_offset;

        var ni: u32 = 0;
        while (ni < name_count) : (ni += 1) {
            const rec_off = name_t + 6 + ni * 12;
            if (rec_off + 12 > data.len) break;
            const name_id = readU16(data, rec_off + 6);
            if (name_id != 6) continue; // PostScript name

            const platform = readU16(data, rec_off);
            const str_length = readU16(data, rec_off + 8);
            const str_offset = readU16(data, rec_off + 10);
            const str_start = storage_start + str_offset;

            if (str_start + str_length > data.len) continue;
            const raw = data[str_start .. str_start + str_length];

            // Platform 1 (Mac) = ASCII, Platform 3 (Windows) = UTF-16BE
            if (platform == 1 and raw.len > 0) {
                ps_name = raw;
                break; // Prefer Mac platform for simplicity
            } else if (platform == 3 or platform == 0) {
                // UTF-16BE: check if it's ASCII-safe (all high bytes zero)
                if (raw.len >= 2 and isAsciiUtf16Be(raw)) {
                    ps_name = raw;
                    // Don't break — prefer Mac if found later
                }
            }
        }
    }

    // Parse OS/2 table
    var weight_class: u16 = 400; // Default to Regular
    if (os2_off) |os2| {
        if (os2 + 6 <= data.len) {
            weight_class = readU16(data, os2 + 4);
        }
    }

    return TtfFont{
        .data = data,
        .units_per_em = units_per_em,
        .ascent = ascent,
        .descent = descent,
        .num_h_metrics = num_h_metrics,
        .ps_name = ps_name,
        .weight_class = weight_class,
        .cmap_offset = cmap,
        .cmap_length = cmap_l,
        .hmtx_offset = hmtx_off orelse return ParseError.TableNotFound,
        .hmtx_length = hmtx_len orelse return ParseError.TableNotFound,
        .cmap_subtable_offset = best_subtable_offset.?,
        .cmap_format = best_format,
    };
}

fn isAsciiUtf16Be(raw: []const u8) bool {
    var j: usize = 0;
    while (j + 1 < raw.len) : (j += 2) {
        if (raw[j] != 0) return false;
    }
    return true;
}

fn readU16(data: []const u8, offset: u32) u16 {
    if (offset + 2 > data.len) return 0;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn readI16(data: []const u8, offset: u32) i16 {
    if (offset + 2 > data.len) return 0;
    return std.mem.readInt(i16, data[offset..][0..2], .big);
}

fn readU32(data: []const u8, offset: u32) u32 {
    if (offset + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn loadTestFont() ![]u8 {
    return std.fs.cwd().readFileAlloc(testing.allocator, "assets/fonts/Inter-Regular.ttf", 10 * 1024 * 1024);
}

test "parse succeeds on Inter-Regular" {
    const test_font_data = loadTestFont() catch return; // skip if not in project root
    defer testing.allocator.free(test_font_data);
    const font = try parse(test_font_data);
    try testing.expect(font.units_per_em > 0);
    try testing.expect(font.ascent > 0);
    try testing.expect(font.descent < 0);
    try testing.expect(font.num_h_metrics > 0);
    try testing.expect(font.ps_name.len > 0);
}

test "glyphId returns non-null for ASCII characters" {
    const test_font_data = loadTestFont() catch return;
    defer testing.allocator.free(test_font_data);
    const font = try parse(test_font_data);
    // 'A' should have a glyph
    const glyph_a = font.glyphId('A');
    try testing.expect(glyph_a != null);
    try testing.expect(glyph_a.? > 0);

    // Space should have a glyph
    const glyph_space = font.glyphId(' ');
    try testing.expect(glyph_space != null);
}

test "glyphId returns different IDs for different characters" {
    const test_font_data = loadTestFont() catch return;
    defer testing.allocator.free(test_font_data);
    const font = try parse(test_font_data);
    const glyph_a = font.glyphId('A').?;
    const glyph_b = font.glyphId('B').?;
    try testing.expect(glyph_a != glyph_b);
}

test "glyphWidth returns non-zero for valid glyphs" {
    const test_font_data = loadTestFont() catch return;
    defer testing.allocator.free(test_font_data);
    const font = try parse(test_font_data);
    const glyph_a = font.glyphId('A').?;
    const width = font.glyphWidth(glyph_a);
    try testing.expect(width > 0);
}

test "glyphWidth for space is less than for M" {
    const test_font_data = loadTestFont() catch return;
    defer testing.allocator.free(test_font_data);
    const font = try parse(test_font_data);
    const space_glyph = font.glyphId(' ').?;
    const m_glyph = font.glyphId('M').?;
    const space_w = font.glyphWidth(space_glyph);
    const m_w = font.glyphWidth(m_glyph);
    try testing.expect(space_w < m_w);
}

test "parse rejects truncated data" {
    try testing.expectError(ParseError.InvalidFont, parse("short"));
}

test "parse rejects empty data" {
    try testing.expectError(ParseError.InvalidFont, parse(""));
}

test "units_per_em is typical value" {
    const test_font_data = loadTestFont() catch return;
    defer testing.allocator.free(test_font_data);
    const font = try parse(test_font_data);
    // Most fonts use 1000 or 2048
    try testing.expect(font.units_per_em == 1000 or font.units_per_em == 2048);
}
