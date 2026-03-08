//! LaTeX Math Parser
//!
//! Post-processes the cmark-gfm AST to detect and extract inline math ($...$)
//! and block math ($$...$$) delimiters into dedicated AST nodes.
//!
//! cmark-gfm does not natively support LaTeX math syntax, so dollar-sign
//! delimited math expressions appear as plain text nodes. This module walks
//! the AST after cmark parsing and splits text nodes containing math
//! delimiters into sequences of text and math_inline/math_block nodes.
//!
//! Additionally, fenced code blocks with `math` as the language identifier
//! are converted to math_block nodes (GitHub renders these as display math).
//!
//! Edge cases handled:
//! - Escaped dollars (`\$`) are not treated as delimiters
//! - Single `$` without a closing match is left as text
//! - `$$` blocks within paragraphs become math_block children
//! - Empty math expressions are ignored (treated as literal text)
//! - Math inside code spans is not processed (already handled by cmark)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

pub const MathParseError = error{
    OutOfMemory,
};

/// Classification of a text segment after math delimiter scanning.
const SegmentKind = enum { text, math_inline, math_block };

/// A segment of text that has been classified as either plain text or math.
const Segment = struct {
    content: []const u8,
    kind: SegmentKind,
};

/// Scan a text string for math delimiters and return segments.
/// The returned segments borrow slices from the input `text`.
/// Caller owns the returned ArrayList and must call deinit().
fn segmentMathDelimiters(allocator: Allocator, text: []const u8) MathParseError!std.ArrayList(Segment) {
    var segments = std.ArrayList(Segment).init(allocator);
    errdefer segments.deinit();

    var i: usize = 0;
    var text_start: usize = 0;

    while (i < text.len) {
        // Skip escaped dollars
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '$') {
            i += 2;
            continue;
        }

        if (text[i] == '$') {
            // Check for $$ (block math)
            if (i + 1 < text.len and text[i + 1] == '$') {
                // Find closing $$
                if (findClosingDoubleDollar(text, i + 2)) |close_pos| {
                    const math_content = text[i + 2 .. close_pos];
                    if (math_content.len > 0) {
                        // Emit preceding text
                        if (i > text_start) {
                            try segments.append(.{ .content = text[text_start..i], .kind = .text });
                        }
                        try segments.append(.{ .content = math_content, .kind = .math_block });
                        i = close_pos + 2;
                        text_start = i;
                        continue;
                    }
                }
                // No closing $$ found or empty content — treat as text
                i += 2;
                continue;
            }

            // Single $ (inline math)
            if (findClosingSingleDollar(text, i + 1)) |close_pos| {
                const math_content = text[i + 1 .. close_pos];
                if (math_content.len > 0) {
                    // Emit preceding text
                    if (i > text_start) {
                        try segments.append(.{ .content = text[text_start..i], .kind = .text });
                    }
                    try segments.append(.{ .content = math_content, .kind = .math_inline });
                    i = close_pos + 1;
                    text_start = i;
                    continue;
                }
            }
            // No closing $ found or empty — treat as text
            i += 1;
            continue;
        }

        i += 1;
    }

    // Emit trailing text
    if (text_start < text.len) {
        try segments.append(.{ .content = text[text_start..], .kind = .text });
    }

    return segments;
}

/// Find the position of a closing `$$` starting from `start`.
/// Returns the index of the first `$` of the closing `$$`, or null.
fn findClosingDoubleDollar(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < text.len) {
        // Skip escaped dollars — i+1 bounds already checked by while condition
        if (text[i] == '\\' and text[i + 1] == '$') {
            i += 2;
            continue;
        }
        if (text[i] == '$' and text[i + 1] == '$') {
            return i;
        }
        i += 1;
    }
    return null;
}

/// Find the position of a closing single `$` starting from `start`.
/// The closing `$` must not be preceded by a backslash escape.
/// The closing `$` must not be immediately followed by another `$` (that would be `$$`).
/// The opening content must not start with a space, and the closing must not end with a space
/// (GitHub behavior for inline math).
fn findClosingSingleDollar(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    // Content must not start with a space (GitHub rule)
    if (text[start] == ' ') return null;

    var i = start;
    while (i < text.len) {
        // Skip escaped dollars
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '$') {
            i += 2;
            continue;
        }
        if (text[i] == '$') {
            // Must not be followed by another $ (that would be $$)
            if (i + 1 < text.len and text[i + 1] == '$') {
                i += 2;
                continue;
            }
            // Content must not end with a space (GitHub rule)
            if (i > start and text[i - 1] == ' ') {
                i += 1;
                continue;
            }
            return i;
        }
        i += 1;
    }
    return null;
}

/// Process a single text node: if it contains math delimiters, replace it
/// with a sequence of text/math nodes in the parent's children list.
/// Returns the new nodes to insert (caller must replace the original node).
fn processTextNode(allocator: Allocator, literal: []const u8) MathParseError!?std.ArrayList(ast.Node) {
    var segments = try segmentMathDelimiters(allocator, literal);
    defer segments.deinit();

    // Only proceed if at least one segment is math
    const has_math = for (segments.items) |seg| {
        if (seg.kind != .text) break true;
    } else false;
    if (!has_math) return null;

    var nodes = std.ArrayList(ast.Node).init(allocator);
    errdefer {
        for (nodes.items) |*n| n.deinit(allocator);
        nodes.deinit();
    }

    for (segments.items) |seg| {
        const node_type: ast.NodeType = switch (seg.kind) {
            .text => .text,
            .math_inline => .math_inline,
            .math_block => .math_block,
        };
        var node = ast.Node.init(allocator, node_type);
        errdefer node.deinit(allocator);
        node.literal = try allocator.dupe(u8, seg.content);
        try nodes.append(node);
    }

    return nodes;
}

/// Walk the AST and transform text nodes containing math delimiters into
/// proper math_inline / math_block AST nodes. Also converts fenced code
/// blocks with `math` language to math_block nodes.
///
/// This function modifies the AST in-place. The caller must ensure the
/// document's allocator matches the one used here.
///
/// NOTE: On OOM, the AST may be left in a partially modified state. The
/// caller (markdown_parser.parse) uses `errdefer root.deinit(allocator)` to
/// ensure the entire tree is freed even if processing is interrupted.
pub fn processMathNodes(allocator: Allocator, root: *ast.Node) MathParseError!void {
    // Process code blocks with `math` fence info → math_block
    convertMathCodeBlocks(allocator, root);

    // Process inline math in text nodes (recursive, bottom-up)
    try processNodeChildren(allocator, root);
}

/// Convert code_block nodes with fence_info "math" to math_block nodes.
fn convertMathCodeBlocks(allocator: Allocator, node: *ast.Node) void {
    for (node.children.items) |*child| {
        if (child.node_type == .code_block) {
            if (child.fence_info) |info| {
                const trimmed = std.mem.trim(u8, info, " \t\r\n");
                if (std.ascii.eqlIgnoreCase(trimmed, "math")) {
                    child.node_type = .math_block;
                    // Free the fence_info since math_block doesn't need it
                    allocator.free(info);
                    child.fence_info = null;
                }
            }
        }
        // Recurse into children for nested structures
        convertMathCodeBlocks(allocator, child);
    }
}

/// Recursively process children of a node, splitting text nodes that contain
/// math delimiters into sequences of text + math nodes.
fn processNodeChildren(allocator: Allocator, node: *ast.Node) MathParseError!void {
    // First recurse into children (bottom-up processing)
    for (node.children.items) |*child| {
        try processNodeChildren(allocator, child);
    }

    // Pre-pass: detect multi-node $$ block math.
    // cmark splits paragraph lines into text + softbreak sequences, so
    // $$\ncontent\n$$ becomes: text("$$"), softbreak, text(content), softbreak, text("$$")
    try mergeMultiNodeBlockMath(allocator, node);

    // Now process this node's children for math in text nodes
    var i: usize = 0;
    while (i < node.children.items.len) {
        const child = &node.children.items[i];
        if (child.node_type == .text) {
            if (child.literal) |literal| {
                if (try processTextNode(allocator, literal)) |replacement_nodes| {
                    var replacements = replacement_nodes;
                    defer replacements.deinit();

                    // Free the original text node's literal
                    allocator.free(literal);
                    child.literal = null;

                    // Replace the original node: put first replacement in place,
                    // insert the rest after it
                    if (replacements.items.len > 0) {
                        // Deinit the original node's children list (should be empty for text)
                        child.children.deinit();

                        // Replace in-place with first replacement
                        node.children.items[i] = replacements.items[0];

                        // Insert remaining replacements after position i.
                        // On OOM during insert, free any nodes that were not yet
                        // inserted into the parent's children list.
                        var insert_idx = i + 1;
                        for (replacements.items[1..], 0..) |replacement, offset| {
                            node.children.insert(insert_idx, replacement) catch |err| {
                                // Free nodes that haven't been inserted yet
                                for (replacements.items[1 + offset..]) |*leftover| {
                                    leftover.deinit(allocator);
                                }
                                return err;
                            };
                            insert_idx += 1;
                        }

                        // Skip past all inserted nodes
                        i = insert_idx;
                        continue;
                    }
                }
            }
        }
        i += 1;
    }
}

/// Merge multi-node $$ block math sequences.
/// In cmark AST, a paragraph like:
///   $$
///   \int_0^\infty ...
///   $$
/// becomes children: [text("$$"), softbreak, text("\\int..."), softbreak, text("$$")]
/// This function detects such patterns and merges them into a single math_block node.
///
/// NOTE: Escape handling inconsistency — the inline path (`segmentMathDelimiters`)
/// skips `\$` sequences during delimiter scanning, so escaped dollars are preserved
/// as-is in the content. This multi-node path concatenates raw text node literals
/// which have already been through cmark's text processing. Since the `$$` delimiters
/// are on separate lines (separate text nodes), escaped dollars within the content
/// text nodes are passed through verbatim. The caller (`unescapeDollars`) handles
/// unescaping at render time for both paths.
fn mergeMultiNodeBlockMath(allocator: Allocator, node: *ast.Node) MathParseError!void {
    var i: usize = 0;
    while (i < node.children.items.len) {
        const child = &node.children.items[i];

        // Look for a text node that is exactly "$$" or starts with "$$"
        if (child.node_type == .text) {
            if (child.literal) |lit| {
                const trimmed = std.mem.trim(u8, lit, " \t");
                if (std.mem.eql(u8, trimmed, "$$")) {
                    // Found opening $$, search forward for closing $$
                    if (findClosingBlockMathNode(node.children.items, i + 1)) |close_idx| {
                        // Collect content between opening and closing $$
                        var content = std.ArrayList(u8).init(allocator);
                        defer content.deinit();

                        var j = i + 1;
                        while (j < close_idx) : (j += 1) {
                            const n = &node.children.items[j];
                            if (n.node_type == .softbreak or n.node_type == .linebreak) {
                                try content.append('\n');
                            } else if (n.node_type == .text) {
                                if (n.literal) |text_lit| {
                                    try content.appendSlice(text_lit);
                                }
                            }
                        }

                        // Trim leading/trailing whitespace from content
                        const math_content = std.mem.trim(u8, content.items, " \t\r\n");
                        if (math_content.len > 0) {
                            // Create math_block node
                            var math_node = ast.Node.init(allocator, .math_block);
                            errdefer math_node.deinit(allocator);
                            math_node.literal = try allocator.dupe(u8, math_content);

                            // Free nodes from i+1 to close_idx (inclusive)
                            // Remove in reverse order to keep indices valid
                            var k = close_idx;
                            while (k > i) : (k -= 1) {
                                var removed = node.children.orderedRemove(k);
                                removed.deinit(allocator);
                            }

                            // Replace the opening $$ text node with math_block
                            node.children.items[i].deinit(allocator);
                            node.children.items[i] = math_node;

                            // Don't advance i — the math_block is now at position i
                            // and we should check the next node
                            i += 1;
                            continue;
                        }
                    }
                }
            }
        }
        i += 1;
    }
}

/// Search forward from `start` for a text node that is exactly "$$",
/// skipping over softbreaks and text nodes (the math content).
/// Returns the index of the closing $$ text node, or null.
fn findClosingBlockMathNode(children: []const ast.Node, start: usize) ?usize {
    var j = start;
    while (j < children.len) : (j += 1) {
        const n = &children[j];
        if (n.node_type == .text) {
            if (n.literal) |lit| {
                const trimmed = std.mem.trim(u8, lit, " \t");
                if (std.mem.eql(u8, trimmed, "$$")) {
                    return j;
                }
            }
        } else if (n.node_type == .softbreak or n.node_type == .linebreak) {
            // These are expected between math content lines
            continue;
        } else {
            // Non-text, non-break node — not a valid block math sequence
            return null;
        }
    }
    return null;
}

/// Remove backslash escapes from dollar signs in math content.
/// Caller owns the returned string.
pub fn unescapeDollars(allocator: Allocator, text: []const u8) MathParseError![]const u8 {
    // Quick check: if no escaped dollars, return a dupe
    if (std.mem.indexOf(u8, text, "\\$") == null) {
        return try allocator.dupe(u8, text);
    }

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '$') {
            try result.append('$');
            i += 2;
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// --- segmentMathDelimiters tests ---

test "segmentMathDelimiters with no math returns single text segment" {
    var segments = try segmentMathDelimiters(testing.allocator, "plain text here");
    defer segments.deinit();
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expectEqualStrings("plain text here", segments.items[0].content);
    try testing.expect(segments.items[0].kind == .text);
}

test "segmentMathDelimiters with inline math" {
    var segments = try segmentMathDelimiters(testing.allocator, "before $x^2$ after");
    defer segments.deinit();
    try testing.expectEqual(@as(usize, 3), segments.items.len);
    try testing.expectEqualStrings("before ", segments.items[0].content);
    try testing.expect(segments.items[0].kind == .text);
    try testing.expectEqualStrings("x^2", segments.items[1].content);
    try testing.expect(segments.items[1].kind == .math_inline);
    try testing.expectEqualStrings(" after", segments.items[2].content);
    try testing.expect(segments.items[2].kind == .text);
}

test "segmentMathDelimiters with block math" {
    var segments = try segmentMathDelimiters(testing.allocator, "before $$E=mc^2$$ after");
    defer segments.deinit();
    try testing.expectEqual(@as(usize, 3), segments.items.len);
    try testing.expectEqualStrings("before ", segments.items[0].content);
    try testing.expect(segments.items[0].kind == .text);
    try testing.expectEqualStrings("E=mc^2", segments.items[1].content);
    try testing.expect(segments.items[1].kind == .math_block);
    try testing.expectEqualStrings(" after", segments.items[2].content);
    try testing.expect(segments.items[2].kind == .text);
}

test "segmentMathDelimiters with escaped dollar signs" {
    var segments = try segmentMathDelimiters(testing.allocator, "price is \\$10");
    defer segments.deinit();
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expectEqualStrings("price is \\$10", segments.items[0].content);
    try testing.expect(segments.items[0].kind == .text);
}

test "segmentMathDelimiters with only math" {
    var segments = try segmentMathDelimiters(testing.allocator, "$a + b$");
    defer segments.deinit();
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expectEqualStrings("a + b", segments.items[0].content);
    try testing.expect(segments.items[0].kind == .math_inline);
}

test "segmentMathDelimiters with empty math is ignored" {
    var segments = try segmentMathDelimiters(testing.allocator, "before $$ after");
    defer segments.deinit();
    // $$ without closing is treated as text
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expect(segments.items[0].kind == .text);
}

test "segmentMathDelimiters with multiple inline math expressions" {
    var segments = try segmentMathDelimiters(testing.allocator, "$a$ and $b$");
    defer segments.deinit();
    try testing.expectEqual(@as(usize, 3), segments.items.len);
    try testing.expectEqualStrings("a", segments.items[0].content);
    try testing.expect(segments.items[0].kind == .math_inline);
    try testing.expectEqualStrings(" and ", segments.items[1].content);
    try testing.expect(segments.items[1].kind == .text);
    try testing.expectEqualStrings("b", segments.items[2].content);
    try testing.expect(segments.items[2].kind == .math_inline);
}

test "segmentMathDelimiters inline math must not start with space" {
    var segments = try segmentMathDelimiters(testing.allocator, "$ not math$");
    defer segments.deinit();
    // Should not be treated as math because content starts with space
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expect(segments.items[0].kind == .text);
}

test "segmentMathDelimiters inline math must not end with space" {
    var segments = try segmentMathDelimiters(testing.allocator, "$not math $");
    defer segments.deinit();
    // Should not be treated as math because content ends with space
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expect(segments.items[0].kind == .text);
}

test "segmentMathDelimiters unmatched single dollar" {
    var segments = try segmentMathDelimiters(testing.allocator, "costs $5 today");
    defer segments.deinit();
    // Single $ without closing should remain as text
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expect(segments.items[0].kind == .text);
}

// --- processTextNode tests ---

test "processTextNode returns null for plain text" {
    const result = try processTextNode(testing.allocator, "plain text");
    try testing.expectEqual(null, result);
}

test "processTextNode splits text with inline math" {
    var nodes = (try processTextNode(testing.allocator, "before $x$ after")).?;
    defer {
        for (nodes.items) |*n| n.deinit(testing.allocator);
        nodes.deinit();
    }
    try testing.expectEqual(@as(usize, 3), nodes.items.len);
    try testing.expectEqual(ast.NodeType.text, nodes.items[0].node_type);
    try testing.expectEqualStrings("before ", nodes.items[0].literal.?);
    try testing.expectEqual(ast.NodeType.math_inline, nodes.items[1].node_type);
    try testing.expectEqualStrings("x", nodes.items[1].literal.?);
    try testing.expectEqual(ast.NodeType.text, nodes.items[2].node_type);
    try testing.expectEqualStrings(" after", nodes.items[2].literal.?);
}

test "processTextNode splits text with block math" {
    var nodes = (try processTextNode(testing.allocator, "$$E=mc^2$$")).?;
    defer {
        for (nodes.items) |*n| n.deinit(testing.allocator);
        nodes.deinit();
    }
    try testing.expectEqual(@as(usize, 1), nodes.items.len);
    try testing.expectEqual(ast.NodeType.math_block, nodes.items[0].node_type);
    try testing.expectEqualStrings("E=mc^2", nodes.items[0].literal.?);
}

// --- processMathNodes integration tests ---

test "processMathNodes transforms inline math in paragraph" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "The formula $x^2 + y^2 = z^2$ is famous");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    try testing.expectEqual(@as(usize, 3), p.children.items.len);
    try testing.expectEqual(ast.NodeType.text, p.children.items[0].node_type);
    try testing.expectEqualStrings("The formula ", p.children.items[0].literal.?);
    try testing.expectEqual(ast.NodeType.math_inline, p.children.items[1].node_type);
    try testing.expectEqualStrings("x^2 + y^2 = z^2", p.children.items[1].literal.?);
    try testing.expectEqual(ast.NodeType.text, p.children.items[2].node_type);
    try testing.expectEqualStrings(" is famous", p.children.items[2].literal.?);
}

test "processMathNodes transforms block math in paragraph" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(ast.NodeType.math_block, p.children.items[0].node_type);
}

test "processMathNodes converts math code blocks" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var code_block = ast.Node.init(allocator, .code_block);
    code_block.literal = try allocator.dupe(u8, "E = mc^2");
    code_block.fence_info = try allocator.dupe(u8, "math");
    try root.children.append(code_block);

    try processMathNodes(allocator, &root);

    const block = &root.children.items[0];
    try testing.expectEqual(ast.NodeType.math_block, block.node_type);
    try testing.expectEqualStrings("E = mc^2", block.literal.?);
    try testing.expectEqual(null, block.fence_info);
}

test "processMathNodes leaves non-math text unchanged" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "Just normal text here");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(ast.NodeType.text, p.children.items[0].node_type);
    try testing.expectEqualStrings("Just normal text here", p.children.items[0].literal.?);
}

test "processMathNodes leaves code blocks with other languages unchanged" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var code_block = ast.Node.init(allocator, .code_block);
    code_block.literal = try allocator.dupe(u8, "fn main() {}");
    code_block.fence_info = try allocator.dupe(u8, "zig");
    try root.children.append(code_block);

    try processMathNodes(allocator, &root);

    const block = &root.children.items[0];
    try testing.expectEqual(ast.NodeType.code_block, block.node_type);
    try testing.expectEqualStrings("zig", block.fence_info.?);
}

test "processMathNodes handles multiple math expressions in one text node" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "$a$ plus $b$ equals $c$");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    // Should be: math(a), text(" plus "), math(b), text(" equals "), math(c)
    try testing.expectEqual(@as(usize, 5), p.children.items.len);
    try testing.expectEqual(ast.NodeType.math_inline, p.children.items[0].node_type);
    try testing.expectEqual(ast.NodeType.text, p.children.items[1].node_type);
    try testing.expectEqual(ast.NodeType.math_inline, p.children.items[2].node_type);
    try testing.expectEqual(ast.NodeType.text, p.children.items[3].node_type);
    try testing.expectEqual(ast.NodeType.math_inline, p.children.items[4].node_type);
}

test "processMathNodes handles escaped dollars" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "Price is \\$5 not math");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    // Escaped dollar should not trigger math parsing
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(ast.NodeType.text, p.children.items[0].node_type);
}

// --- unescapeDollars tests ---

test "unescapeDollars with no escapes" {
    const result = try unescapeDollars(testing.allocator, "x + y");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("x + y", result);
}

test "unescapeDollars removes backslash before dollar" {
    const result = try unescapeDollars(testing.allocator, "\\$5 and \\$10");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("$5 and $10", result);
}

test "unescapeDollars preserves other backslashes" {
    const result = try unescapeDollars(testing.allocator, "\\n and \\$");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("\\n and $", result);
}

// --- findClosingDoubleDollar tests ---

test "findClosingDoubleDollar finds closing position" {
    try testing.expectEqual(@as(?usize, 5), findClosingDoubleDollar("abcde$$", 0));
    try testing.expectEqual(@as(?usize, 3), findClosingDoubleDollar("abc$$", 0));
}

test "findClosingDoubleDollar returns null when not found" {
    try testing.expectEqual(@as(?usize, null), findClosingDoubleDollar("abc$", 0));
    try testing.expectEqual(@as(?usize, null), findClosingDoubleDollar("abcde", 0));
}

test "findClosingDoubleDollar skips escaped dollars" {
    // \$$ should not match as closing
    try testing.expectEqual(@as(?usize, null), findClosingDoubleDollar("abc\\$$", 0));
}

// --- findClosingSingleDollar tests ---

test "findClosingSingleDollar finds closing position" {
    try testing.expectEqual(@as(?usize, 3), findClosingSingleDollar("abc$", 0));
}

test "findClosingSingleDollar returns null when not found" {
    try testing.expectEqual(@as(?usize, null), findClosingSingleDollar("abcde", 0));
}

test "findClosingSingleDollar returns null when starting with space" {
    try testing.expectEqual(@as(?usize, null), findClosingSingleDollar(" abc$", 0));
}

test "findClosingSingleDollar skips when ending with space" {
    try testing.expectEqual(@as(?usize, null), findClosingSingleDollar("abc $", 0));
}

test "findClosingSingleDollar skips escaped dollar" {
    try testing.expectEqual(@as(?usize, null), findClosingSingleDollar("abc\\$", 0));
}

test "findClosingSingleDollar skips double dollar" {
    // $$ should not be matched by single dollar finder
    try testing.expectEqual(@as(?usize, null), findClosingSingleDollar("abc$$", 0));
}

// --- Tests for sample formulas from docs/github-markdown-samples.md ---

test "segmentMathDelimiters inline math: quadratic formula from samples" {
    // From docs/github-markdown-samples.md line 407:
    // "The quadratic formula is $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$ and is widely used."
    const input = "The quadratic formula is $x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$ and is widely used.";
    var segments = try segmentMathDelimiters(testing.allocator, input);
    defer segments.deinit();

    try testing.expectEqual(@as(usize, 3), segments.items.len);
    try testing.expect(segments.items[0].kind == .text);
    try testing.expectEqualStrings("The quadratic formula is ", segments.items[0].content);
    try testing.expect(segments.items[1].kind == .math_inline);
    try testing.expectEqualStrings("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", segments.items[1].content);
    try testing.expect(segments.items[2].kind == .text);
    try testing.expectEqualStrings(" and is widely used.", segments.items[2].content);
}

test "segmentMathDelimiters inline math: E=mc^2 from samples" {
    // From docs/github-markdown-samples.md line 409:
    // "Einstein's famous equation: $E = mc^2$"
    const input = "Einstein's famous equation: $E = mc^2$";
    var segments = try segmentMathDelimiters(testing.allocator, input);
    defer segments.deinit();

    try testing.expectEqual(@as(usize, 2), segments.items.len);
    try testing.expect(segments.items[0].kind == .text);
    try testing.expectEqualStrings("Einstein's famous equation: ", segments.items[0].content);
    try testing.expect(segments.items[1].kind == .math_inline);
    try testing.expectEqualStrings("E = mc^2", segments.items[1].content);
}

test "segmentMathDelimiters block math: integral from samples" {
    // From docs/github-markdown-samples.md lines 413-415:
    // $$\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$
    const input = "$$\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}$$";
    var segments = try segmentMathDelimiters(testing.allocator, input);
    defer segments.deinit();

    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expect(segments.items[0].kind == .math_block);
    try testing.expectEqualStrings("\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}", segments.items[0].content);
}

test "segmentMathDelimiters block math: sum series from samples" {
    // From docs/github-markdown-samples.md lines 417-419:
    // $$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$
    const input = "$$\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}$$";
    var segments = try segmentMathDelimiters(testing.allocator, input);
    defer segments.deinit();

    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expect(segments.items[0].kind == .math_block);
    try testing.expectEqualStrings("\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}", segments.items[0].content);
}

test "processMathNodes inline quadratic formula from samples" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "The quadratic formula is $x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$ and is widely used.");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    try testing.expectEqual(@as(usize, 3), p.children.items.len);
    try testing.expectEqual(ast.NodeType.text, p.children.items[0].node_type);
    try testing.expectEqual(ast.NodeType.math_inline, p.children.items[1].node_type);
    try testing.expectEqualStrings("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", p.children.items[1].literal.?);
    try testing.expectEqual(ast.NodeType.text, p.children.items[2].node_type);
}

test "processMathNodes inline E=mc^2 from samples" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "Einstein's famous equation: $E = mc^2$");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    try testing.expectEqual(@as(usize, 2), p.children.items.len);
    try testing.expectEqual(ast.NodeType.text, p.children.items[0].node_type);
    try testing.expectEqual(ast.NodeType.math_inline, p.children.items[1].node_type);
    try testing.expectEqualStrings("E = mc^2", p.children.items[1].literal.?);
}

test "processMathNodes block math integral from samples" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "$$\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}$$");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(ast.NodeType.math_block, p.children.items[0].node_type);
    try testing.expectEqualStrings("\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}", p.children.items[0].literal.?);
}

test "processMathNodes block math sum series from samples" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    var para = ast.Node.init(allocator, .paragraph);
    var text_node = ast.Node.init(allocator, .text);
    text_node.literal = try allocator.dupe(u8, "$$\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}$$");
    try para.children.append(text_node);
    try root.children.append(para);

    try processMathNodes(allocator, &root);

    const p = &root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(ast.NodeType.math_block, p.children.items[0].node_type);
    try testing.expectEqualStrings("\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}", p.children.items[0].literal.?);
}

test "processMathNodes code block math: matrix from samples" {
    const allocator = testing.allocator;
    var root = ast.Node.init(allocator, .document);
    defer root.deinit(allocator);

    // Simulate a fenced code block with language "math" (matrix from samples lines 423-438)
    var code_block = ast.Node.init(allocator, .code_block);
    code_block.fence_info = try allocator.dupe(u8, "math");
    code_block.literal = try allocator.dupe(
        u8,
        "\\left(\\begin{array}{cc}\na & b \\\\\nc & d\n\\end{array}\\right)\n\\times\n\\left(\\begin{array}{c}\nx \\\\\ny\n\\end{array}\\right)\n=\n\\left(\\begin{array}{c}\nax + by \\\\\ncx + dy\n\\end{array}\\right)\n",
    );
    try root.children.append(code_block);

    try processMathNodes(allocator, &root);

    // Code block with "math" language should be converted to math_block
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expectEqual(ast.NodeType.math_block, root.children.items[0].node_type);
    // The literal should contain the matrix LaTeX
    const literal = root.children.items[0].literal.?;
    try testing.expect(std.mem.indexOf(u8, literal, "\\begin{array}") != null);
    try testing.expect(std.mem.indexOf(u8, literal, "\\times") != null);
}

test "mergeMultiNodeBlockMath merges multi-node $$ pattern" {
    // Simulate cmark output for:
    //   $$
    //   \int_0^\infty x dx
    //   $$
    // cmark produces: text("$$"), softbreak, text("\\int_0^\\infty x dx"), softbreak, text("$$")
    const allocator = testing.allocator;
    var para = ast.Node.init(allocator, .paragraph);
    defer para.deinit(allocator);

    var open = ast.Node.init(allocator, .text);
    open.literal = try allocator.dupe(u8, "$$");
    try para.children.append(open);

    const sb1 = ast.Node.init(allocator, .softbreak);
    try para.children.append(sb1);

    var content_node = ast.Node.init(allocator, .text);
    content_node.literal = try allocator.dupe(u8, "\\int_0^\\infty x dx");
    try para.children.append(content_node);

    const sb2 = ast.Node.init(allocator, .softbreak);
    try para.children.append(sb2);

    var close = ast.Node.init(allocator, .text);
    close.literal = try allocator.dupe(u8, "$$");
    try para.children.append(close);

    try processMathNodes(allocator, &para);

    // Should be merged into a single math_block node
    try testing.expectEqual(@as(usize, 1), para.children.items.len);
    try testing.expectEqual(ast.NodeType.math_block, para.children.items[0].node_type);
    try testing.expectEqualStrings("\\int_0^\\infty x dx", para.children.items[0].literal.?);
}
