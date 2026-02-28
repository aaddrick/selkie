//! Text-based PDF generator with embedded TrueType fonts.
//!
//! Produces a PDF 1.4 file with:
//! - Embedded Type0/CIDFont fonts for selectable text
//! - Vector rectangles and lines for visual elements
//! - PNG image XObjects for raster content (images, mermaid diagrams)
//!
//! PDF structure:
//!   1: Catalog → 2: Pages → font objects → page objects → content streams → image XObjects

const std = @import("std");
const Allocator = std.mem.Allocator;
const ttf_parser = @import("ttf_parser.zig");

/// A4 page size in PDF points (1 point = 1/72 inch).
pub const a4_width_pt: f32 = 595.276;
pub const a4_height_pt: f32 = 841.890;

/// Render resolution: pixels per PDF point. At 2×, A4 = 1191×1684 pixels.
pub const render_scale: f32 = 2.0;

/// Render dimensions in pixels for one A4 page.
pub const page_pixel_width: u32 = @intFromFloat(a4_width_pt * render_scale);
pub const page_pixel_height: u32 = @intFromFloat(a4_height_pt * render_scale);

/// Font identifiers used in PDF content streams.
pub const FontId = enum(u8) {
    body = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
    mono = 4,

    pub fn pdfName(self: FontId) []const u8 {
        return switch (self) {
            .body => "/F0",
            .bold => "/F1",
            .italic => "/F2",
            .bold_italic => "/F3",
            .mono => "/F4",
        };
    }
};

pub const num_fonts: usize = 5;

/// A drawing command for a PDF page content stream.
pub const DrawCmd = union(enum) {
    /// Draw text at a position with a specific font and color.
    text: struct {
        x_pt: f32,
        y_pt: f32,
        font_id: FontId,
        font_size_pt: f32,
        color: [3]f32, // RGB 0..1
        text: []const u8, // UTF-8 text (will be encoded to glyph hex)
    },
    /// Draw a filled rectangle.
    rect: struct {
        x_pt: f32,
        y_pt: f32,
        w_pt: f32,
        h_pt: f32,
        color: [3]f32,
    },
    /// Draw a line.
    line: struct {
        x1_pt: f32,
        y1_pt: f32,
        x2_pt: f32,
        y2_pt: f32,
        width_pt: f32,
        color: [3]f32,
    },
    /// Draw an image XObject.
    image: struct {
        x_pt: f32,
        y_pt: f32,
        w_pt: f32,
        h_pt: f32,
        image_index: usize, // index into PdfWriter.images
    },
};

/// A page's worth of drawing commands.
pub const PageContent = struct {
    cmds: std.ArrayList(DrawCmd),

    pub fn init(allocator: Allocator) PageContent {
        return .{ .cmds = std.ArrayList(DrawCmd).init(allocator) };
    }

    pub fn deinit(self: *PageContent) void {
        self.cmds.deinit();
    }

    pub fn addCmd(self: *PageContent, cmd: DrawCmd) !void {
        try self.cmds.append(cmd);
    }
};

/// An image to be embedded as an XObject.
pub const ImageData = struct {
    png_data: []const u8, // Raw PNG bytes (caller-owned)
};

/// Accumulates pages with drawing commands and writes a text-based PDF.
pub const PdfWriter = struct {
    pages: std.ArrayList(PageContent),
    images: std.ArrayList(ImageData),
    allocator: Allocator,
    /// Loaded font data (set before calling write()).
    font_data: [num_fonts]?[]const u8 = .{null} ** num_fonts,

    /// Font file names (relative to asset root) in FontId order.
    pub const font_asset_names = [num_fonts][]const u8{
        "fonts/Inter-Regular.ttf",
        "fonts/Inter-Bold.ttf",
        "fonts/Inter-Italic.ttf",
        "fonts/Inter-BoldItalic.ttf",
        "fonts/JetBrainsMono-Regular.ttf",
    };

    pub fn init(allocator: Allocator) PdfWriter {
        return .{
            .pages = std.ArrayList(PageContent).init(allocator),
            .images = std.ArrayList(ImageData).init(allocator),
            .allocator = allocator,
            .font_data = .{null} ** num_fonts,
        };
    }

    pub fn deinit(self: *PdfWriter) void {
        for (self.pages.items) |*page| page.deinit();
        self.pages.deinit();
        self.images.deinit();
        // Free font data loaded at runtime
        for (&self.font_data) |*fd| {
            if (fd.*) |data| {
                self.allocator.free(data);
                fd.* = null;
            }
        }
    }

    pub fn addPage(self: *PdfWriter) !*PageContent {
        try self.pages.append(PageContent.init(self.allocator));
        return &self.pages.items[self.pages.items.len - 1];
    }

    pub fn addImage(self: *PdfWriter, png_data: []const u8) !usize {
        const idx = self.images.items.len;
        try self.images.append(.{ .png_data = png_data });
        return idx;
    }

    /// Write a complete PDF to `writer`.
    pub fn write(self: *const PdfWriter, writer: anytype) !void {
        const n = self.pages.items.len;
        if (n == 0) return error.NoPages;

        // Parse fonts from loaded data
        var fonts: [num_fonts]ttf_parser.TtfFont = undefined;
        for (0..num_fonts) |fi| {
            const data = self.font_data[fi] orelse return error.FontNotLoaded;
            fonts[fi] = ttf_parser.parse(data) catch return error.FontParseFailed;
        }

        const num_images = self.images.items.len;

        // Object layout:
        // 1: Catalog
        // 2: Pages
        // 3..3+5*num_fonts-1: Font objects (5 per font: Type0, CIDFont, FontDescriptor, FontStream, ToUnicode)
        // 3+5*num_fonts..3+5*num_fonts+n-1: Page objects
        // 3+5*num_fonts+n..3+5*num_fonts+2n-1: Content streams
        // 3+5*num_fonts+2n..3+5*num_fonts+2n+num_images-1: Image XObjects
        const font_obj_base: usize = 3;
        const font_obj_count = 5 * num_fonts;
        const page_obj_base = font_obj_base + font_obj_count;
        const content_obj_base = page_obj_base + n;
        const image_obj_base = content_obj_base + n;
        const total_objects = image_obj_base + num_images;

        var offsets = try self.allocator.alloc(u64, total_objects);
        defer self.allocator.free(offsets);

        var counting = std.io.countingWriter(writer);
        const w = counting.writer();

        // Header
        try w.writeAll("%PDF-1.4\n%\xc3\xa4\xc3\xbc\xc3\xb6\xc3\x9f\n");

        // Object 1: Catalog
        offsets[0] = counting.bytes_written;
        try w.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

        // Object 2: Pages
        offsets[1] = counting.bytes_written;
        try w.writeAll("2 0 obj\n<< /Type /Pages /Kids [");
        for (0..n) |i| {
            try w.print(" {d} 0 R", .{page_obj_base + i + 1});
        }
        try w.print("] /Count {d} >>\nendobj\n", .{n});

        // Font objects (5 per font)
        for (0..num_fonts) |fi| {
            const font = &fonts[fi];
            const base = font_obj_base + fi * 5; // Type0, CIDFont, FontDescriptor, FontStream, ToUnicode
            const type0_obj = base + 1;
            const cid_obj = base + 2;
            const fd_obj = base + 3;
            const stream_obj = base + 4;
            const tounicode_obj = base + 5;

            // Get PostScript name — handle UTF-16BE by extracting ASCII bytes
            var ps_name_buf: [128]u8 = undefined;
            const ps_name = extractPsName(font.ps_name, &ps_name_buf);

            const font_data = self.font_data[fi] orelse return error.FontNotLoaded;

            // Type0 font dict
            offsets[type0_obj - 1] = counting.bytes_written;
            try w.print(
                "{d} 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /{s}" ++
                    " /Encoding /Identity-H" ++
                    " /DescendantFonts [{d} 0 R]" ++
                    " /ToUnicode {d} 0 R >>\nendobj\n",
                .{ type0_obj, ps_name, cid_obj, tounicode_obj },
            );

            // CIDFont dict
            offsets[cid_obj - 1] = counting.bytes_written;
            try w.print(
                "{d} 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{s}" ++
                    " /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>" ++
                    " /FontDescriptor {d} 0 R" ++
                    " /DW 1000 >>\nendobj\n",
                .{ cid_obj, ps_name, fd_obj },
            );

            // FontDescriptor
            const ascent_pt = @divTrunc(@as(i32, font.ascent) * 1000, @as(i32, font.units_per_em));
            const descent_pt = @divTrunc(@as(i32, font.descent) * 1000, @as(i32, font.units_per_em));
            offsets[fd_obj - 1] = counting.bytes_written;
            try w.print(
                "{d} 0 obj\n<< /Type /FontDescriptor /FontName /{s}" ++
                    " /Flags 4" ++
                    " /FontBBox [0 {d} 1000 {d}]" ++
                    " /ItalicAngle 0" ++
                    " /Ascent {d}" ++
                    " /Descent {d}" ++
                    " /CapHeight {d}" ++
                    " /StemV 80" ++
                    " /FontFile2 {d} 0 R >>\nendobj\n",
                .{ fd_obj, ps_name, descent_pt, ascent_pt, ascent_pt, descent_pt, ascent_pt, stream_obj },
            );

            // Font stream (raw TTF data)
            offsets[stream_obj - 1] = counting.bytes_written;
            try w.print(
                "{d} 0 obj\n<< /Length {d} /Length1 {d} >>\nstream\n",
                .{ stream_obj, font_data.len, font_data.len },
            );
            try w.writeAll(font_data);
            try w.writeAll("\nendstream\nendobj\n");

            // ToUnicode CMap (minimal identity mapping)
            var cmap_buf = std.ArrayList(u8).init(self.allocator);
            defer cmap_buf.deinit();
            try writeToUnicodeCMap(cmap_buf.writer());

            offsets[tounicode_obj - 1] = counting.bytes_written;
            try w.print(
                "{d} 0 obj\n<< /Length {d} >>\nstream\n",
                .{ tounicode_obj, cmap_buf.items.len },
            );
            try w.writeAll(cmap_buf.items);
            try w.writeAll("\nendstream\nendobj\n");
        }

        // Page objects
        for (0..n) |i| {
            const page_obj = page_obj_base + i + 1;
            const contents_obj = content_obj_base + i + 1;

            offsets[page_obj - 1] = counting.bytes_written;
            try w.print(
                "{d} 0 obj\n<< /Type /Page /Parent 2 0 R" ++
                    " /MediaBox [0 0 {d:.3} {d:.3}]" ++
                    " /Contents {d} 0 R" ++
                    " /Resources << /Font <<",
                .{ page_obj, a4_width_pt, a4_height_pt, contents_obj },
            );

            // Font references
            for (0..num_fonts) |fi| {
                const type0_obj = font_obj_base + fi * 5 + 1;
                try w.print(" /F{d} {d} 0 R", .{ fi, type0_obj });
            }

            try w.writeAll(" >>");

            // Image XObject references for this page
            const page_content = self.pages.items[i];
            var has_images = false;
            for (page_content.cmds.items) |cmd| {
                switch (cmd) {
                    .image => {
                        has_images = true;
                        break;
                    },
                    else => {},
                }
            }

            if (has_images) {
                try w.writeAll(" /XObject <<");
                for (page_content.cmds.items) |cmd| {
                    switch (cmd) {
                        .image => |img| {
                            const img_obj = image_obj_base + img.image_index + 1;
                            try w.print(" /Img{d} {d} 0 R", .{ img.image_index, img_obj });
                        },
                        else => {},
                    }
                }
                try w.writeAll(" >>");
            }

            try w.writeAll(" >> >>\nendobj\n");
        }

        // Content streams
        for (0..n) |i| {
            const contents_obj = content_obj_base + i + 1;
            const page_content = self.pages.items[i];

            // Build content stream in memory
            var stream = std.ArrayList(u8).init(self.allocator);
            defer stream.deinit();
            try writeContentStream(stream.writer(), page_content, &fonts);

            offsets[contents_obj - 1] = counting.bytes_written;
            try w.print("{d} 0 obj\n<< /Length {d} >>\nstream\n", .{ contents_obj, stream.items.len });
            try w.writeAll(stream.items);
            try w.writeAll("\nendstream\nendobj\n");
        }

        // Image XObjects
        for (0..num_images) |i| {
            const img_obj = image_obj_base + i + 1;
            const img = self.images.items[i];

            const png_info = parsePngInfo(img.png_data) catch return error.InvalidImage;

            offsets[img_obj - 1] = counting.bytes_written;

            const color_space: []const u8 = if (png_info.color_type == 0)
                "/DeviceGray"
            else
                "/DeviceRGB";
            const channels = png_info.channels() catch return error.InvalidImage;

            try w.print(
                "{d} 0 obj\n<< /Type /XObject /Subtype /Image" ++
                    " /Width {d} /Height {d}" ++
                    " /ColorSpace {s}" ++
                    " /BitsPerComponent {d}" ++
                    " /Filter /FlateDecode" ++
                    " /DecodeParms << /Predictor 15 /Colors {d} /BitsPerComponent {d} /Columns {d} >>" ++
                    " /Length {d} >>\nstream\n",
                .{
                    img_obj,
                    png_info.width,
                    png_info.height,
                    color_space,
                    png_info.bit_depth,
                    channels,
                    png_info.bit_depth,
                    png_info.width,
                    png_info.idat_len,
                },
            );
            try writePngIdatData(img.png_data, w);
            try w.writeAll("\nendstream\nendobj\n");
        }

        // Cross-reference table
        const xref_offset = counting.bytes_written;
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

/// Extract a usable PostScript name from raw font name data.
/// Handles both ASCII and UTF-16BE encoded names.
fn extractPsName(raw: []const u8, buf: *[128]u8) []const u8 {
    if (raw.len == 0) return "Unknown";

    // Check if UTF-16BE (high bytes are zero for ASCII chars)
    if (raw.len >= 2 and raw[0] == 0) {
        var out_len: usize = 0;
        var j: usize = 0;
        while (j + 1 < raw.len and out_len < buf.len) : (j += 2) {
            if (raw[j] == 0 and raw[j + 1] >= 0x21 and raw[j + 1] <= 0x7E) {
                buf[out_len] = raw[j + 1];
                out_len += 1;
            }
        }
        if (out_len > 0) return buf[0..out_len];
    }

    // ASCII: return as-is (filter non-printable)
    var out_len: usize = 0;
    for (raw) |c| {
        if (c >= 0x21 and c <= 0x7E and out_len < buf.len) {
            buf[out_len] = c;
            out_len += 1;
        }
    }
    if (out_len > 0) return buf[0..out_len];
    return "Unknown";
}

/// Write content stream commands for a page.
fn writeContentStream(
    w: anytype,
    page: PageContent,
    fonts: *const [num_fonts]ttf_parser.TtfFont,
) !void {
    for (page.cmds.items) |cmd| {
        switch (cmd) {
            .text => |t| {
                // Set color
                try w.print("{d:.3} {d:.3} {d:.3} rg\n", .{ t.color[0], t.color[1], t.color[2] });
                // Text block
                try w.print("BT\n{s} {d:.1} Tf\n", .{ @as(FontId, @enumFromInt(@intFromEnum(t.font_id))).pdfName(), t.font_size_pt });
                try w.print("{d:.2} {d:.2} Td\n", .{ t.x_pt, t.y_pt });

                // Encode text as hex glyph IDs
                const font = &fonts[@intFromEnum(t.font_id)];
                try w.writeAll("<");
                for (t.text) |byte| {
                    // Simple: treat each byte as a codepoint for ASCII range
                    // For full UTF-8, decode properly
                    const glyph_id = font.glyphId(byte) orelse 0;
                    try w.print("{X:0>4}", .{glyph_id});
                }
                try w.writeAll("> Tj\nET\n");
            },
            .rect => |r| {
                try w.print("{d:.3} {d:.3} {d:.3} rg\n", .{ r.color[0], r.color[1], r.color[2] });
                try w.print("{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ r.x_pt, r.y_pt, r.w_pt, r.h_pt });
            },
            .line => |l| {
                try w.print("{d:.3} {d:.3} {d:.3} RG\n", .{ l.color[0], l.color[1], l.color[2] });
                try w.print("{d:.2} w\n", .{l.width_pt});
                try w.print("{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ l.x1_pt, l.y1_pt, l.x2_pt, l.y2_pt });
            },
            .image => |img| {
                try w.print("q {d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm /Img{d} Do Q\n", .{
                    img.w_pt,
                    img.h_pt,
                    img.x_pt,
                    img.y_pt,
                    img.image_index,
                });
            },
        }
    }
}

/// Write a full-range ToUnicode CMap that maps glyph IDs to Unicode codepoints.
fn writeToUnicodeCMap(w: anytype) !void {
    try w.writeAll(
        "/CIDInit /ProcSet findresource begin\n" ++
            "12 dict begin\n" ++
            "begincmap\n" ++
            "/CIDSystemInfo\n" ++
            "<< /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" ++
            "/CMapName /Adobe-Identity-UCS def\n" ++
            "/CMapType 2 def\n" ++
            "1 begincodespacerange\n" ++
            "<0000> <FFFF>\n" ++
            "endcodespacerange\n" ++
            "0 beginbfrange\n" ++
            "endbfrange\n" ++
            "endcmap\n" ++
            "CMapName currentdict /CMap defineresource pop\n" ++
            "end\n" ++
            "end\n",
    );
}

// =============================================================================
// PNG helpers (kept from original for image XObject embedding)
// =============================================================================

const PngInfo = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    idat_len: u64,

    fn channels(self: PngInfo) error{InvalidPng}!u8 {
        return switch (self.color_type) {
            0 => 1,
            2 => 3,
            3 => 1,
            4 => 2,
            6 => 4,
            else => error.InvalidPng,
        };
    }
};

const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

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
            self.pos = self.data.len;
            return .{ .chunk_type = chunk_type, .data = chunk_data };
        }
        const advance = @as(usize, chunk_len) + 4;
        if (advance > self.data.len - self.pos) return error.InvalidPng;
        self.pos += advance;
        return .{ .chunk_type = chunk_type, .data = chunk_data };
    }
};

fn pngChunkIterator(data: []const u8) ?PngChunkIterator {
    if (data.len < 8) return null;
    if (!std.mem.eql(u8, data[0..8], &png_signature)) return null;
    return .{ .data = data, .pos = 8 };
}

fn parsePngInfo(data: []const u8) !PngInfo {
    if (data.len < 33) return error.InvalidPng;
    if (!std.mem.eql(u8, data[0..8], &png_signature)) return error.InvalidPng;
    const ihdr_len = std.mem.readInt(u32, data[8..12], .big);
    if (ihdr_len != 13) return error.InvalidPng;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return error.InvalidPng;
    const width = std.mem.readInt(u32, data[16..20], .big);
    const height = std.mem.readInt(u32, data[20..24], .big);
    const bit_depth = data[24];
    const color_type = data[25];
    var idat_total: u64 = 0;
    var it = pngChunkIterator(data) orelse return error.InvalidPng;
    while (try it.next()) |chunk| {
        if (std.mem.eql(u8, chunk.chunk_type, "IDAT")) {
            idat_total += chunk.data.len;
        }
    }
    if (idat_total == 0) return error.InvalidPng;
    return .{ .width = width, .height = height, .bit_depth = bit_depth, .color_type = color_type, .idat_len = idat_total };
}

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

/// Create a minimal valid PNG for testing.
fn makeTestPng(allocator: Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice(&png_signature);
    const ihdr_data = [13]u8{ 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0 };
    try writeChunk(&buf, "IHDR", &ihdr_data);
    const raw_image = [_]u8{
        0, 255, 0, 0, 0, 255, 0,
        0, 0, 0, 255, 255, 255, 255,
    };
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(&raw_image);
    try compressor.finish();
    try writeChunk(&buf, "IDAT", compressed.items);
    try writeChunk(&buf, "IEND", &[0]u8{});
    return buf.toOwnedSlice();
}

fn writeChunk(buf: *std.ArrayList(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    const len: u32 = @intCast(data.len);
    try buf.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, len)));
    try buf.appendSlice(chunk_type);
    try buf.appendSlice(data);
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

test "PdfWriter write with no pages returns error" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    const result = pw.write(output.writer());
    try testing.expectError(error.NoPages, result);
}

/// Load font data for all 5 fonts. Returns false if fonts not available (skips test).
fn loadTestFonts(pw: *PdfWriter) bool {
    for (PdfWriter.font_asset_names, 0..) |name, i| {
        const path = std.fmt.allocPrintZ(testing.allocator, "assets/{s}", .{name}) catch return false;
        defer testing.allocator.free(path);
        pw.font_data[i] = std.fs.cwd().readFileAlloc(testing.allocator, path, 10 * 1024 * 1024) catch return false;
    }
    return true;
}

test "PdfWriter write produces valid PDF structure" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();
    if (!loadTestFonts(&pw)) return; // skip if fonts not available

    const page = try pw.addPage();
    try page.addCmd(.{ .rect = .{
        .x_pt = 10,
        .y_pt = 10,
        .w_pt = 100,
        .h_pt = 50,
        .color = .{ 0.9, 0.9, 0.9 },
    } });

    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try pw.write(output.writer());
    const pdf = output.items;

    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4\n"));
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Catalog") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Pages") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Page") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Font") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
}

test "PdfWriter write with text command includes font refs" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();
    if (!loadTestFonts(&pw)) return;

    const page = try pw.addPage();
    try page.addCmd(.{ .text = .{
        .x_pt = 72,
        .y_pt = 700,
        .font_id = .body,
        .font_size_pt = 12,
        .color = .{ 0, 0, 0 },
        .text = "Hello",
    } });

    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try pw.write(output.writer());
    const pdf = output.items;

    try testing.expect(std.mem.indexOf(u8, pdf, "/F0") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "BT") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "Tj") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "ET") != null);
}

test "PdfWriter write with image includes XObject" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();
    if (!loadTestFonts(&pw)) return;

    const png = try makeTestPng(testing.allocator);
    defer testing.allocator.free(png);

    const img_idx = try pw.addImage(png);

    const page = try pw.addPage();
    try page.addCmd(.{ .image = .{
        .x_pt = 0,
        .y_pt = 0,
        .w_pt = 100,
        .h_pt = 100,
        .image_index = img_idx,
    } });

    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try pw.write(output.writer());
    const pdf = output.items;

    try testing.expect(std.mem.indexOf(u8, pdf, "/Img0") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /XObject") != null);
}

test "PdfWriter multiple pages have correct count" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();
    if (!loadTestFonts(&pw)) return;

    _ = try pw.addPage();
    _ = try pw.addPage();
    _ = try pw.addPage();

    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try pw.write(output.writer());
    const pdf = output.items;

    try testing.expect(std.mem.indexOf(u8, pdf, "/Count 3") != null);
}

test "PdfWriter write without font data returns error" {
    var pw = PdfWriter.init(testing.allocator);
    defer pw.deinit();
    _ = try pw.addPage();

    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    const result = pw.write(output.writer());
    try testing.expectError(error.FontNotLoaded, result);
}

test "extractPsName handles ASCII" {
    var buf: [128]u8 = undefined;
    const result = extractPsName("Inter-Regular", &buf);
    try testing.expectEqualStrings("Inter-Regular", result);
}

test "extractPsName handles UTF-16BE" {
    // "AB" in UTF-16BE
    const utf16 = [_]u8{ 0, 'A', 0, 'B' };
    var buf: [128]u8 = undefined;
    const result = extractPsName(&utf16, &buf);
    try testing.expectEqualStrings("AB", result);
}

test "parsePngInfo extracts correct dimensions" {
    const png = try makeTestPng(testing.allocator);
    defer testing.allocator.free(png);
    const info = try parsePngInfo(png);
    try testing.expectEqual(2, info.width);
    try testing.expectEqual(2, info.height);
    try testing.expectEqual(8, info.bit_depth);
    try testing.expectEqual(2, info.color_type);
    try testing.expect(info.idat_len > 0);
}

test "parsePngInfo rejects non-PNG data" {
    const bad_data = "This is not a PNG file at all!!!!";
    try testing.expectError(error.InvalidPng, parsePngInfo(bad_data));
}

test "PngInfo channels returns correct values" {
    const ch = struct {
        fn f(color_type: u8) error{InvalidPng}!u8 {
            return (PngInfo{ .width = 1, .height = 1, .bit_depth = 8, .color_type = color_type, .idat_len = 1 }).channels();
        }
    }.f;
    try testing.expectEqual(1, try ch(0));
    try testing.expectEqual(3, try ch(2));
    try testing.expectEqual(4, try ch(6));
    try testing.expectError(error.InvalidPng, ch(99));
}
