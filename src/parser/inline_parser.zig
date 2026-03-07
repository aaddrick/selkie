//! GFM Inline Parsing Utilities
//!
//! Provides convenience functions for working with inline elements in the
//! parsed AST. All inline parsing is performed by cmark-gfm; this module
//! offers structured access to emphasis, bold, strikethrough, code spans,
//! links, autolinks, and images.
//!
//! Inline nodes in the AST follow a tree structure:
//!   paragraph
//!     -> text "Hello "
//!     -> strong
//!        -> text "bold"
//!     -> text " and "
//!     -> emph
//!        -> text "italic"
//!
//! Autolinks (e.g., https://example.com) are parsed by cmark-gfm's autolink
//! extension and appear as `link` nodes with url set to the autolinked URL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

/// Information about a link or autolink inline node.
pub const LinkInfo = struct {
    url: []const u8,
    title: ?[]const u8,
    /// Whether this is an autolink (URL equals the link text content).
    is_autolink: bool,
};

/// Information about an image inline node.
pub const ImageInfo = struct {
    url: []const u8,
    title: ?[]const u8,
    alt_text: ?[]const u8,
};

/// Style flags accumulated from the inline node ancestry.
pub const InlineStyle = struct {
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    code: bool = false,
    link_url: ?[]const u8 = null,
};

/// Check if a node type is an inline element.
pub fn isInlineNode(node_type: ast.NodeType) bool {
    return switch (node_type) {
        .text, .softbreak, .linebreak, .code, .html_inline, .emph, .strong, .strikethrough, .link, .image, .footnote_reference => true,
        else => false,
    };
}

/// Check if a node is a container inline (can have inline children).
pub fn isInlineContainer(node_type: ast.NodeType) bool {
    return switch (node_type) {
        .emph, .strong, .strikethrough, .link, .image => true,
        else => false,
    };
}

/// Extract link information from a link node.
/// Returns null if the node is not a link or has no URL.
pub fn getLinkInfo(node: *const ast.Node) ?LinkInfo {
    if (node.node_type != .link) return null;
    const url = node.url orelse return null;

    // Determine if this is an autolink by comparing URL with text content
    const is_autolink = blk: {
        if (node.children.items.len != 1) break :blk false;
        const child = &node.children.items[0];
        if (child.node_type != .text) break :blk false;
        const literal = child.literal orelse break :blk false;
        // Autolinks: the text matches the URL exactly, or URL is "mailto:" + text
        if (std.mem.eql(u8, literal, url)) break :blk true;
        if (std.mem.startsWith(u8, url, "mailto:")) {
            if (std.mem.eql(u8, literal, url["mailto:".len..])) break :blk true;
        }
        break :blk false;
    };

    return .{
        .url = url,
        .title = node.title,
        .is_autolink = is_autolink,
    };
}

/// Extract image information from an image node.
/// Returns null if the node is not an image or has no URL.
pub fn getImageInfo(allocator: Allocator, node: *const ast.Node) !?ImageInfo {
    if (node.node_type != .image) return null;
    const url = node.url orelse return null;

    // Collect alt text from text children
    const alt_text = try collectPlainText(allocator, node);

    return .{
        .url = url,
        .title = node.title,
        .alt_text = alt_text,
    };
}

/// Collect plain text content from all descendant text nodes.
/// Caller owns the returned slice and must free it with the same allocator.
/// Returns null if no text content is found.
pub fn collectPlainText(allocator: Allocator, node: *const ast.Node) !?[]const u8 {
    var parts = std.ArrayList([]const u8).init(allocator);
    defer parts.deinit();

    collectPlainTextRecursive(node, &parts);

    if (parts.items.len == 0) return null;

    var total_len: usize = 0;
    for (parts.items) |part| {
        total_len += part.len;
    }

    const result = try allocator.alloc(u8, total_len);
    errdefer allocator.free(result);
    var offset: usize = 0;
    for (parts.items) |part| {
        @memcpy(result[offset .. offset + part.len], part);
        offset += part.len;
    }

    return result;
}

fn collectPlainTextRecursive(node: *const ast.Node, parts: *std.ArrayList([]const u8)) void {
    if (node.literal) |text| {
        // Best-effort collection; OOM during alt-text gathering is non-fatal
        parts.append(text) catch return;
    }
    for (node.children.items) |*child| {
        collectPlainTextRecursive(child, parts);
    }
}

/// Count inline nodes of a specific type within a node tree.
pub fn countInlineType(node: *const ast.Node, target_type: ast.NodeType) usize {
    var count: usize = 0;
    countInlineTypeRecursive(node, target_type, &count);
    return count;
}

fn countInlineTypeRecursive(node: *const ast.Node, target_type: ast.NodeType, count: *usize) void {
    if (node.node_type == target_type) {
        count.* += 1;
    }
    for (node.children.items) |*child| {
        countInlineTypeRecursive(child, target_type, count);
    }
}

/// Find all link nodes within a subtree. Returns a list of pointers to link nodes.
/// Caller owns the returned ArrayList and must call deinit().
pub fn findLinks(allocator: Allocator, node: *const ast.Node) !std.ArrayList(*const ast.Node) {
    var links = std.ArrayList(*const ast.Node).init(allocator);
    errdefer links.deinit();
    try findLinksRecursive(node, &links);
    return links;
}

fn findLinksRecursive(node: *const ast.Node, links: *std.ArrayList(*const ast.Node)) !void {
    if (node.node_type == .link) {
        try links.append(node);
    }
    for (node.children.items) |*child| {
        try findLinksRecursive(child, links);
    }
}

/// Find all image nodes within a subtree.
/// Caller owns the returned ArrayList and must call deinit().
pub fn findImages(allocator: Allocator, node: *const ast.Node) !std.ArrayList(*const ast.Node) {
    var images = std.ArrayList(*const ast.Node).init(allocator);
    errdefer images.deinit();
    try findImagesRecursive(node, &images);
    return images;
}

fn findImagesRecursive(node: *const ast.Node, images: *std.ArrayList(*const ast.Node)) !void {
    if (node.node_type == .image) {
        try images.append(node);
    }
    for (node.children.items) |*child| {
        try findImagesRecursive(child, images);
    }
}

/// Applies the style contribution of a single inline node on top of a
/// parent style. This is useful for determining the effective style of
/// nested inline elements like **_bold italic_** by calling this
/// function at each level of the tree.
pub fn resolveInlineStyle(node: *const ast.Node, parent_style: InlineStyle) InlineStyle {
    var style = parent_style;
    switch (node.node_type) {
        .emph => style.italic = true,
        .strong => style.bold = true,
        .strikethrough => style.strikethrough = true,
        .code => style.code = true,
        .link => style.link_url = node.url,
        else => {},
    }
    return style;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const markdown_parser = @import("markdown_parser.zig");

test "isInlineNode identifies inline types" {
    try testing.expect(isInlineNode(.text));
    try testing.expect(isInlineNode(.emph));
    try testing.expect(isInlineNode(.strong));
    try testing.expect(isInlineNode(.strikethrough));
    try testing.expect(isInlineNode(.code));
    try testing.expect(isInlineNode(.link));
    try testing.expect(isInlineNode(.image));
    try testing.expect(isInlineNode(.softbreak));
    try testing.expect(isInlineNode(.linebreak));
    try testing.expect(isInlineNode(.html_inline));
    try testing.expect(isInlineNode(.footnote_reference));
}

test "isInlineNode rejects block types" {
    try testing.expect(!isInlineNode(.document));
    try testing.expect(!isInlineNode(.paragraph));
    try testing.expect(!isInlineNode(.heading));
    try testing.expect(!isInlineNode(.code_block));
    try testing.expect(!isInlineNode(.list));
    try testing.expect(!isInlineNode(.table));
    try testing.expect(!isInlineNode(.block_quote));
}

test "isInlineContainer identifies container inlines" {
    try testing.expect(isInlineContainer(.emph));
    try testing.expect(isInlineContainer(.strong));
    try testing.expect(isInlineContainer(.strikethrough));
    try testing.expect(isInlineContainer(.link));
    try testing.expect(isInlineContainer(.image));
    try testing.expect(!isInlineContainer(.text));
    try testing.expect(!isInlineContainer(.code));
    try testing.expect(!isInlineContainer(.paragraph));
}

test "parse emphasis produces emph node" {
    var doc = try markdown_parser.parse(testing.allocator, "*italic text*\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    try testing.expectEqual(ast.NodeType.paragraph, para.node_type);

    // Should contain an emph child with text
    try testing.expect(para.children.items.len > 0);
    const emph = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.emph, emph.node_type);

    // Emph should contain text
    try testing.expect(emph.children.items.len > 0);
    const text_node = &emph.children.items[0];
    try testing.expectEqual(ast.NodeType.text, text_node.node_type);
    try testing.expectEqualStrings("italic text", text_node.literal.?);
}

test "parse bold produces strong node" {
    var doc = try markdown_parser.parse(testing.allocator, "**bold text**\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    try testing.expect(para.children.items.len > 0);
    const strong = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.strong, strong.node_type);

    const text_node = &strong.children.items[0];
    try testing.expectEqualStrings("bold text", text_node.literal.?);
}

test "parse bold italic nesting" {
    var doc = try markdown_parser.parse(testing.allocator, "***bold and italic***\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    // cmark-gfm produces emph > strong or strong > emph nesting
    const outer = &para.children.items[0];
    const is_nested = (outer.node_type == .emph or outer.node_type == .strong);
    try testing.expect(is_nested);

    // The inner node should be the other style
    try testing.expect(outer.children.items.len > 0);
    const inner = &outer.children.items[0];
    const inner_is_style = (inner.node_type == .emph or inner.node_type == .strong);
    try testing.expect(inner_is_style);

    // Ensure both bold and italic are present (different types)
    try testing.expect(outer.node_type != inner.node_type);
}

test "parse strikethrough produces strikethrough node" {
    var doc = try markdown_parser.parse(testing.allocator, "~~deleted text~~\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const strike = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.strikethrough, strike.node_type);

    try testing.expect(strike.children.items.len > 0);
    const text_node = &strike.children.items[0];
    try testing.expectEqualStrings("deleted text", text_node.literal.?);
}

test "parse code span produces code node" {
    var doc = try markdown_parser.parse(testing.allocator, "`inline code`\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const code_node = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.code, code_node.node_type);
    try testing.expectEqualStrings("inline code", code_node.literal.?);
}

test "parse code span with backtick escaping" {
    var doc = try markdown_parser.parse(testing.allocator, "`` `backtick` ``\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const code_node = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.code, code_node.node_type);
    try testing.expectEqualStrings("`backtick`", code_node.literal.?);
}

test "parse link produces link node with url and title" {
    var doc = try markdown_parser.parse(testing.allocator, "[click here](https://example.com \"Example\")\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const link = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.link, link.node_type);
    try testing.expectEqualStrings("https://example.com", link.url.?);
    try testing.expectEqualStrings("Example", link.title.?);

    // Link text child
    try testing.expect(link.children.items.len > 0);
    const text_node = &link.children.items[0];
    try testing.expectEqualStrings("click here", text_node.literal.?);
}

test "parse link without title" {
    var doc = try markdown_parser.parse(testing.allocator, "[click](https://example.com)\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const link = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.link, link.node_type);
    try testing.expectEqualStrings("https://example.com", link.url.?);
    try testing.expectEqual(null, link.title);
}

test "parse autolink URL" {
    var doc = try markdown_parser.parse(testing.allocator, "Visit https://example.com for more\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    // Autolinks should produce a link node among the paragraph children
    var found_link = false;
    for (para.children.items) |*child| {
        if (child.node_type == .link) {
            found_link = true;
            try testing.expectEqualStrings("https://example.com", child.url.?);
            break;
        }
    }
    try testing.expect(found_link);
}

test "parse autolink email" {
    var doc = try markdown_parser.parse(testing.allocator, "Contact <user@example.com> now\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    var found_link = false;
    for (para.children.items) |*child| {
        if (child.node_type == .link) {
            found_link = true;
            // cmark wraps email autolinks with mailto:
            const url = child.url.?;
            try testing.expect(std.mem.indexOf(u8, url, "example.com") != null);
            break;
        }
    }
    try testing.expect(found_link);
}

test "parse image produces image node" {
    var doc = try markdown_parser.parse(testing.allocator, "![alt text](image.png \"title\")\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const img = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.image, img.node_type);
    try testing.expectEqualStrings("image.png", img.url.?);
    try testing.expectEqualStrings("title", img.title.?);

    // Alt text stored as text child
    try testing.expect(img.children.items.len > 0);
    const alt_node = &img.children.items[0];
    try testing.expectEqualStrings("alt text", alt_node.literal.?);
}

test "parse image without title" {
    var doc = try markdown_parser.parse(testing.allocator, "![screenshot](pic.jpg)\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const img = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.image, img.node_type);
    try testing.expectEqualStrings("pic.jpg", img.url.?);
    try testing.expectEqual(null, img.title);
}

test "getLinkInfo returns info for link node" {
    var doc = try markdown_parser.parse(testing.allocator, "[text](https://test.com \"Title\")\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const link = &para.children.items[0];
    const info = getLinkInfo(link).?;
    try testing.expectEqualStrings("https://test.com", info.url);
    try testing.expectEqualStrings("Title", info.title.?);
    try testing.expect(!info.is_autolink);
}

test "getLinkInfo detects autolink" {
    var doc = try markdown_parser.parse(testing.allocator, "https://auto.com\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    // Find the link node
    for (para.children.items) |*child| {
        if (child.node_type == .link) {
            const info = getLinkInfo(child).?;
            try testing.expect(info.is_autolink);
            return;
        }
    }
    // Should have found a link
    try testing.expect(false);
}

test "getLinkInfo returns null for non-link" {
    var node = ast.Node.init(testing.allocator, .text);
    defer node.deinit(testing.allocator);
    try testing.expectEqual(null, getLinkInfo(&node));
}

test "getImageInfo extracts image details" {
    var doc = try markdown_parser.parse(testing.allocator, "![my alt](photo.png)\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const img = &para.children.items[0];
    const info = (try getImageInfo(testing.allocator, img)).?;
    defer if (info.alt_text) |alt| testing.allocator.free(alt);
    try testing.expectEqualStrings("photo.png", info.url);
    try testing.expectEqualStrings("my alt", info.alt_text.?);
}

test "getImageInfo returns null for non-image" {
    var node = ast.Node.init(testing.allocator, .paragraph);
    defer node.deinit(testing.allocator);
    const result = try getImageInfo(testing.allocator, &node);
    try testing.expectEqual(null, result);
}

test "collectPlainText extracts text from nested inlines" {
    var doc = try markdown_parser.parse(testing.allocator, "**bold** and *italic*\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const text = (try collectPlainText(testing.allocator, para)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("bold and italic", text);
}

test "collectPlainText returns null for empty node" {
    var node = ast.Node.init(testing.allocator, .paragraph);
    defer node.deinit(testing.allocator);
    const result = try collectPlainText(testing.allocator, &node);
    try testing.expectEqual(null, result);
}

test "countInlineType counts matching nodes" {
    var doc = try markdown_parser.parse(testing.allocator, "**a** and **b** and **c**\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    try testing.expectEqual(@as(usize, 3), countInlineType(para, .strong));
}

test "findLinks returns all link nodes" {
    var doc = try markdown_parser.parse(testing.allocator, "[a](x.com) text [b](y.com)\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    var links = try findLinks(testing.allocator, para);
    defer links.deinit();
    try testing.expectEqual(@as(usize, 2), links.items.len);
}

test "findImages returns all image nodes" {
    var doc = try markdown_parser.parse(testing.allocator, "![a](x.png) and ![b](y.png)\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    var images = try findImages(testing.allocator, para);
    defer images.deinit();
    try testing.expectEqual(@as(usize, 2), images.items.len);
}

test "resolveInlineStyle accumulates styles" {
    const base = InlineStyle{};

    // Emph adds italic
    var emph_node = ast.Node.init(testing.allocator, .emph);
    defer emph_node.deinit(testing.allocator);
    const emph_style = resolveInlineStyle(&emph_node, base);
    try testing.expect(emph_style.italic);
    try testing.expect(!emph_style.bold);

    // Strong adds bold on top of italic
    var strong_node = ast.Node.init(testing.allocator, .strong);
    defer strong_node.deinit(testing.allocator);
    const bold_italic = resolveInlineStyle(&strong_node, emph_style);
    try testing.expect(bold_italic.italic);
    try testing.expect(bold_italic.bold);
}

test "parse mixed inline formatting" {
    // Test complex inline nesting: bold with strikethrough inside
    var doc = try markdown_parser.parse(testing.allocator, "**bold ~~strike~~ text**\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const strong = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.strong, strong.node_type);

    // Should have text, strikethrough, text as children
    var has_strike = false;
    for (strong.children.items) |*child| {
        if (child.node_type == .strikethrough) {
            has_strike = true;
        }
    }
    try testing.expect(has_strike);
}

test "parse link with emphasis in text" {
    var doc = try markdown_parser.parse(testing.allocator, "[*emphasized link*](url.com)\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const link = &para.children.items[0];
    try testing.expectEqual(ast.NodeType.link, link.node_type);

    // Link should contain emph child
    var has_emph = false;
    for (link.children.items) |*child| {
        if (child.node_type == .emph) {
            has_emph = true;
        }
    }
    try testing.expect(has_emph);
}

test "parse multiple code spans in paragraph" {
    var doc = try markdown_parser.parse(testing.allocator, "Use `foo` and `bar` functions\n");
    defer doc.deinit();

    const para = &doc.root.children.items[0];
    const code_count = countInlineType(para, .code);
    try testing.expectEqual(@as(usize, 2), code_count);
}
