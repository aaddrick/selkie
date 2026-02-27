//! Minimal pure-Zig PDF generator that embeds rasterized PNG pages.
//!
//! Produces a valid PDF 1.4 file where each page contains a single PNG image
//! scaled to fill the page. Uses the FlateDecode filter — PNG's internal zlib
//! stream is extracted and embedded directly as a PDF image XObject.
//!
//! PDF structure:
//!   1: Catalog → 2: Pages → [page objects] → [image XObjects]
//!   Each page has a Contents stream that paints its image.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A4 page size in PDF points (1 point = 1/72 inch).
pub const a4_width_pt: f32 = 595.276;
pub const a4_height_pt: f32 = 841.890;

/// Render resolution: pixels per PDF point. At 2×, A4 = 1191×1684 pixels.
pub const render_scale: f32 = 2.0;

/// Render dimensions in pixels for one A4 page.
pub const page_pixel_width: u32 = @intFromFloat(a4_width_pt * render_scale);
pub const page_pixel_height: u32 = @intFromFloat(a4_height_pt * render_scale);

/// A single page to be embedded in the PDF.
pub const Page = struct {
    /// Raw PNG file bytes (owned by the caller — PdfWriter does not free these).
    png_data: []const u8,
};

/// Accumulates pages and writes a valid PDF file.
pub const PdfWriter = struct {
    pages: std.ArrayList(Page),
    allocator: Allocator,

    pub fn init(allocator: Allocator) PdfWriter {
        return .{
            .pages = std.ArrayList(Page).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PdfWriter) void {
        self.pages.deinit();
    }

    pub fn addPage(self: *PdfWriter, png_data: []const u8) Allocator.Error!void {
        try self.pages.append(.{ .png_data = png_data });
    }

    /// Write a complete PDF to `writer`. Each page embeds its PNG image.
    ///
    /// PDF object layout (1-indexed):
    ///   1           — Catalog
    ///   2           — Pages
    ///   3..3+N-1    — Page objects (N = page count)
    ///   3+N..3+2N-1 — Image XObjects
    ///   3+2N..3+3N-1 — Contents streams (drawing commands)
    pub fn write(self: *const PdfWriter, writer: anytype) !void {
        const n = self.pages.items.len;
        if (n == 0) return error.NoPages;

        // Track byte offsets of each object for the xref table
        var offsets = try self.allocator.alloc(u64, 3 * n + 2);
        defer self.allocator.free(offsets);

        var counting = std.io.countingWriter(writer);
        const w = counting.writer();

        // Header
        try w.writeAll("%PDF-1.4\n%\xc3\xa4\xc3\xbc\xc3\xb6\xc3\x9f\n");

        // Object 1: Catalog
        offsets[0] = counting.bytes_written;
        try w.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

        // Object 2: Pages — list of page refs
        offsets[1] = counting.bytes_written;
        try w.writeAll("2 0 obj\n<< /Type /Pages /Kids [");
        for (0..n) |i| {
            const obj_num = 3 + i;
            try w.print(" {d} 0 R", .{obj_num});
        }
        try w.print("] /Count {d} >>\nendobj\n", .{n});

        // Page objects (3..3+N-1)
        for (0..n) |i| {
            const page_obj = 3 + i;
            const image_obj = 3 + n + i;
            const contents_obj = 3 + 2 * n + i;

            offsets[page_obj - 1] = counting.bytes_written;
            try w.print(
                "{d} 0 obj\n<< /Type /Page /Parent 2 0 R" ++
                    " /MediaBox [0 0 {d:.3} {d:.3}]" ++
                    " /Contents {d} 0 R" ++
                    " /Resources << /XObject << /Img{d} {d} 0 R >> >> >>\nendobj\n",
                .{
                    page_obj,
                    a4_width_pt,
                    a4_height_pt,
                    contents_obj,
                    i,
                    image_obj,
                },
            );
        }

        // Image XObjects (3+N..3+2N-1) — embed PNG IDAT zlib streams as FlateDecode images
        for (0..n) |i| {
            const image_obj = 3 + n + i;
            const page = self.pages.items[i];

            const png_info = try parsePngInfo(page.png_data);

            offsets[image_obj - 1] = counting.bytes_written;

            // Our renders have opaque backgrounds, so alpha (type 6) is ignored.
            const color_space: []const u8 = if (png_info.color_type == 0)
                "/DeviceGray"
            else
                "/DeviceRGB";
            try w.print(
                "{d} 0 obj\n<< /Type /XObject /Subtype /Image" ++
                    " /Width {d} /Height {d}" ++
                    " /ColorSpace {s}" ++
                    " /BitsPerComponent {d}" ++
                    " /Filter /FlateDecode" ++
                    " /DecodeParms << /Predictor 15 /Colors {d} /BitsPerComponent {d} /Columns {d} >>" ++
                    " /Length {d} >>\nstream\n",
                .{
                    image_obj,
                    png_info.width,
                    png_info.height,
                    color_space,
                    png_info.bit_depth,
                    try png_info.channels(),
                    png_info.bit_depth,
                    png_info.width,
                    png_info.idat_len,
                },
            );
            try writePngIdatData(page.png_data, w);
            try w.writeAll("\nendstream\nendobj\n");
        }

        // Contents streams (3+2N..3+3N-1) — each draws one image
        for (0..n) |i| {
            const contents_obj = 3 + 2 * n + i;
            // PDF drawing command: scale image to page size and paint
            var draw_cmd_buf: [256]u8 = undefined;
            const draw_cmd = try std.fmt.bufPrint(&draw_cmd_buf, "q {d:.3} 0 0 {d:.3} 0 0 cm /Img{d} Do Q", .{
                a4_width_pt,
                a4_height_pt,
                i,
            });

            offsets[contents_obj - 1] = counting.bytes_written;
            try w.print("{d} 0 obj\n<< /Length {d} >>\nstream\n", .{ contents_obj, draw_cmd.len });
            try w.writeAll(draw_cmd);
            try w.writeAll("\nendstream\nendobj\n");
        }

        // Cross-reference table
        const xref_offset = counting.bytes_written;
        const total_objects = 3 * n + 2;
        try w.print("xref\n0 {d}\n", .{total_objects + 1});
        try w.writeAll("0000000000 65535 f \n");
        for (0..total_objects) |i| {
            try w.print("{d:0>10} 00000 n \n", .{offsets[i]});
        }

        // Trailer
        try w.print(
            "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n",
            .{ total_objects + 1, xref_offset },
        );
    }
};

/// Parsed PNG header fields needed for PDF image embedding.
const PngInfo = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    idat_len: u64,

    fn channels(self: PngInfo) error{InvalidPng}!u8 {
        return switch (self.color_type) {
            0 => 1, // Grayscale
            2 => 3, // RGB
            3 => 1, // Palette (indexed)
            4 => 2, // Grayscale + Alpha
            6 => 4, // RGBA
            else => error.InvalidPng,
        };
    }
};

/// PNG signature bytes.
const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Iterates over PNG chunks after the 8-byte signature, yielding (type, data) pairs.
/// Stops after IEND. Returns `error.InvalidPng` if a chunk length overflows the data.
const PngChunkIterator = struct {
    data: []const u8,
    pos: usize,

    const Chunk = struct {
        chunk_type: *const [4]u8,
        data: []const u8,
    };

    fn next(self: *PngChunkIterator) error{InvalidPng}!?Chunk {
        if (self.pos + 8 > self.data.len) return null;

        const chunk_len = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        const chunk_type: *const [4]u8 = self.data[self.pos + 4 ..][0..4];
        self.pos += 8;

        if (self.pos + chunk_len > self.data.len) return error.InvalidPng;
        const chunk_data = self.data[self.pos .. self.pos + chunk_len];

        if (std.mem.eql(u8, chunk_type, "IEND")) {
            self.pos = self.data.len; // ensure next call returns null
            return .{ .chunk_type = chunk_type, .data = chunk_data };
        }

        // Skip chunk data + CRC (4 bytes)
        const advance = @as(usize, chunk_len) + 4;
        if (advance > self.data.len - self.pos) return error.InvalidPng;
        self.pos += advance;

        return .{ .chunk_type = chunk_type, .data = chunk_data };
    }
};

/// Create a chunk iterator over PNG data. Returns null if the signature is invalid.
fn pngChunkIterator(data: []const u8) ?PngChunkIterator {
    if (data.len < 8) return null;
    if (!std.mem.eql(u8, data[0..8], &png_signature)) return null;
    return .{ .data = data, .pos = 8 };
}

/// Parse PNG header (IHDR) and compute total IDAT data length.
/// Returns `error.InvalidPng` if the data is not a valid PNG or has no IDAT chunks.
fn parsePngInfo(data: []const u8) !PngInfo {
    if (data.len < 33) return error.InvalidPng; // Minimum: sig(8) + IHDR chunk(25)
    if (!std.mem.eql(u8, data[0..8], &png_signature)) return error.InvalidPng;

    // IHDR is always first chunk after signature
    const ihdr_len = std.mem.readInt(u32, data[8..12], .big);
    if (ihdr_len != 13) return error.InvalidPng;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return error.InvalidPng;

    const width = std.mem.readInt(u32, data[16..20], .big);
    const height = std.mem.readInt(u32, data[20..24], .big);
    const bit_depth = data[24];
    const color_type = data[25];

    // Walk chunks to sum IDAT lengths
    var idat_total: u64 = 0;
    var it = pngChunkIterator(data) orelse return error.InvalidPng;
    while (try it.next()) |chunk| {
        if (std.mem.eql(u8, chunk.chunk_type, "IDAT")) {
            idat_total += chunk.data.len;
        }
    }

    if (idat_total == 0) return error.InvalidPng;

    return .{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .idat_len = idat_total,
    };
}

/// Write concatenated IDAT chunk data (raw zlib stream) to the writer.
/// Multiple IDAT chunks are concatenated in order to form a single zlib stream.
fn writePngIdatData(data: []const u8, writer: anytype) !void {
    var it = pngChunkIterator(data) orelse return error.InvalidPng;
    while (try it.next()) |chunk| {
        if (std.mem.eql(u8, chunk.chunk_type, "IDAT")) {
            try writer.writeAll(chunk.data);
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Create a minimal valid PNG for testing. This generates a 2×2 RGB PNG.
fn makeTestPng(allocator: Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // PNG signature
    try buf.appendSlice(&png_signature);

    // IHDR chunk: width=2, height=2, bit_depth=8, color_type=2 (RGB)
    const ihdr_data = [13]u8{
        0, 0, 0, 2, // width
        0, 0, 0, 2, // height
        8, // bit depth
        2, // color type (RGB)
        0, // compression
        0, // filter
        0, // interlace
    };
    try writeChunk(&buf, "IHDR", &ihdr_data);

    // IDAT chunk: zlib-compressed image data
    // Each row: filter_byte(0) + 3 bytes per pixel × 2 pixels = 7 bytes per row
    // Two rows = 14 bytes raw
    const raw_image = [_]u8{
        0, 255, 0, 0, 0, 255, 0, // Row 1: filter=None, red, green
        0, 0, 0, 255, 255, 255, 255, // Row 2: filter=None, blue, white
    };

    // Compress with zlib
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(&raw_image);
    try compressor.finish();

    try writeChunk(&buf, "IDAT", compressed.items);

    // IEND chunk
    try writeChunk(&buf, "IEND", &[0]u8{});

    return buf.toOwnedSlice();
}

fn writeChunk(buf: *std.ArrayList(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    // Length (4 bytes, big endian)
    const len: u32 = @intCast(data.len);
    try buf.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, len)));

    // Type (4 bytes)
    try buf.appendSlice(chunk_type);

    // Data
    try buf.appendSlice(data);

    // CRC32 over type + data
    var hasher = std.hash.Crc32.init();
    hasher.update(chunk_type);
    hasher.update(data);
    const crc = hasher.final();
    try buf.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, crc)));
}

test "PdfWriter init and deinit without pages" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();
    try testing.expectEqual(0, pw.pages.items.len);
}

test "PdfWriter addPage increments page count" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();

    const png = try makeTestPng(testing.allocator);
    defer testing.allocator.free(png);

    try pw.addPage(png);
    try testing.expectEqual(1, pw.pages.items.len);

    try pw.addPage(png);
    try testing.expectEqual(2, pw.pages.items.len);
}

test "PdfWriter write with no pages returns error" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();

    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();

    const result = pw.write(output.writer());
    try testing.expectError(error.NoPages, result);
}

test "PdfWriter write produces valid PDF header and trailer" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();

    const png = try makeTestPng(testing.allocator);
    defer testing.allocator.free(png);

    try pw.addPage(png);

    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();

    try pw.write(output.writer());
    const pdf = output.items;

    // Check PDF header
    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4\n"));

    // Check trailer markers
    try testing.expect(std.mem.indexOf(u8, pdf, "xref") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "trailer") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "startxref") != null);
    try testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));

    // Check catalog and pages
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Catalog") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Pages") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Page") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /XObject") != null);
}

test "PdfWriter write with multiple pages has correct page count" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();

    const png = try makeTestPng(testing.allocator);
    defer testing.allocator.free(png);

    try pw.addPage(png);
    try pw.addPage(png);
    try pw.addPage(png);

    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();

    try pw.write(output.writer());
    const pdf = output.items;

    // Should have /Count 3
    try testing.expect(std.mem.indexOf(u8, pdf, "/Count 3") != null);
}

test "parsePngInfo extracts correct dimensions from test PNG" {
    const png = try makeTestPng(testing.allocator);
    defer testing.allocator.free(png);

    const info = try parsePngInfo(png);
    try testing.expectEqual(2, info.width);
    try testing.expectEqual(2, info.height);
    try testing.expectEqual(8, info.bit_depth);
    try testing.expectEqual(2, info.color_type); // RGB
    try testing.expect(info.idat_len > 0);
}

test "parsePngInfo rejects non-PNG data" {
    const bad_data = "This is not a PNG file at all!!!!";
    try testing.expectError(error.InvalidPng, parsePngInfo(bad_data));
}

test "parsePngInfo rejects truncated data" {
    try testing.expectError(error.InvalidPng, parsePngInfo("short"));
}

test "parsePngInfo rejects bad IHDR length" {
    var data: [33]u8 = @splat(0);
    @memcpy(data[0..8], &png_signature);
    std.mem.writeInt(u32, data[8..12], 12, .big); // Should be 13
    @memcpy(data[12..16], "IHDR");
    try testing.expectError(error.InvalidPng, parsePngInfo(&data));
}

test "parsePngInfo rejects missing IHDR tag" {
    var data: [33]u8 = @splat(0);
    @memcpy(data[0..8], &png_signature);
    std.mem.writeInt(u32, data[8..12], 13, .big);
    @memcpy(data[12..16], "FAKE");
    try testing.expectError(error.InvalidPng, parsePngInfo(&data));
}

test "parsePngInfo rejects PNG with no IDAT chunks" {
    // Build a PNG with only IHDR + IEND (no IDAT)
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buf.appendSlice(&png_signature);
    const ihdr_data = [13]u8{ 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0 };
    try writeChunk(&buf, "IHDR", &ihdr_data);
    try writeChunk(&buf, "IEND", &[0]u8{});
    try testing.expectError(error.InvalidPng, parsePngInfo(buf.items));
}

test "parsePngInfo rejects malformed chunk with oversized length" {
    // Build a PNG with IHDR followed by a chunk whose length exceeds remaining data
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buf.appendSlice(&png_signature);
    const ihdr_data = [13]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0 };
    try writeChunk(&buf, "IHDR", &ihdr_data);
    // Add a fake chunk with length 0xFFFFFFFF (way too large)
    try buf.appendSlice(&[4]u8{ 0xFF, 0xFF, 0xFF, 0xFF });
    try buf.appendSlice("tEXt");
    try testing.expectError(error.InvalidPng, parsePngInfo(buf.items));
}

test "writePngIdatData extracts correct IDAT bytes and decompresses to original pixels" {
    const png = try makeTestPng(testing.allocator);
    defer testing.allocator.free(png);

    const info = try parsePngInfo(png);

    var idat_buf = std.ArrayList(u8).init(testing.allocator);
    defer idat_buf.deinit();
    try writePngIdatData(png, idat_buf.writer());

    // Extracted IDAT length should match parsePngInfo's calculation
    try testing.expectEqual(info.idat_len, idat_buf.items.len);

    // Decompress the zlib data and verify it matches the original raw pixel data
    var idat_stream = std.io.fixedBufferStream(idat_buf.items);
    var decompressor = std.compress.zlib.decompressor(idat_stream.reader());
    var decompressed = std.ArrayList(u8).init(testing.allocator);
    defer decompressed.deinit();
    while (true) {
        var read_buf: [256]u8 = undefined;
        const n = try decompressor.read(&read_buf);
        if (n == 0) break;
        try decompressed.appendSlice(read_buf[0..n]);
    }

    // Original raw image data from makeTestPng: 2×2 RGB, filter=None per row
    const expected = [_]u8{
        0, 255, 0, 0, 0, 255, 0, // Row 1: filter=None, red, green
        0, 0, 0, 255, 255, 255, 255, // Row 2: filter=None, blue, white
    };
    try testing.expectEqualSlices(u8, &expected, decompressed.items);
}

test "writePngIdatData concatenates multiple IDAT chunks" {
    // Build a PNG with IHDR + two IDAT chunks + IEND
    const raw_image = [_]u8{
        0, 255, 0, 0, 0, 255, 0,
        0, 0, 0, 255, 255, 255, 255,
    };

    var compressed = std.ArrayList(u8).init(testing.allocator);
    defer compressed.deinit();
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(&raw_image);
    try compressor.finish();

    // Split compressed data into two halves for two IDAT chunks
    const split = compressed.items.len / 2;
    const part1 = compressed.items[0..split];
    const part2 = compressed.items[split..];

    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buf.appendSlice(&png_signature);
    const ihdr_data = [13]u8{ 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0 };
    try writeChunk(&buf, "IHDR", &ihdr_data);
    try writeChunk(&buf, "IDAT", part1);
    try writeChunk(&buf, "IDAT", part2);
    try writeChunk(&buf, "IEND", &[0]u8{});

    // parsePngInfo should report the total of both IDAT chunks
    const info = try parsePngInfo(buf.items);
    try testing.expectEqual(compressed.items.len, info.idat_len);

    // writePngIdatData should concatenate both chunks
    var idat_buf = std.ArrayList(u8).init(testing.allocator);
    defer idat_buf.deinit();
    try writePngIdatData(buf.items, idat_buf.writer());
    try testing.expectEqualSlices(u8, compressed.items, idat_buf.items);
}

test "PngInfo channels returns correct value per color type" {
    const ch = struct {
        fn f(color_type: u8) error{InvalidPng}!u8 {
            return (PngInfo{ .width = 1, .height = 1, .bit_depth = 8, .color_type = color_type, .idat_len = 1 }).channels();
        }
    }.f;
    try testing.expectEqual(1, try ch(0)); // Grayscale
    try testing.expectEqual(3, try ch(2)); // RGB
    try testing.expectEqual(1, try ch(3)); // Palette
    try testing.expectEqual(2, try ch(4)); // Grayscale + Alpha
    try testing.expectEqual(4, try ch(6)); // RGBA
    try testing.expectError(error.InvalidPng, ch(99)); // Unknown -> error
}
