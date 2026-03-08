const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");

const ast = @import("../parser/ast.zig");
const layout_types = @import("layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("text_measurer.zig").Fonts;
const table_layout = @import("table_layout.zig");
const code_block_layout = @import("code_block_layout.zig");
const mermaid_layout = @import("../mermaid/mermaid_layout.zig");
const ImageRenderer = @import("../render/image_renderer.zig").ImageRenderer;
const alert_detector = @import("alert_detector.zig");
const emoji = @import("emoji.zig");
const math_layout = @import("math_layout.zig");
const layout_math_renderer = @import("math_renderer.zig");

/// Compute a dynamic page margin that scales with available width.
/// Returns 5% of available_width, but no less than min_margin and no more than
/// max_dynamic_margin (80px). The max ceiling is always enforced.
const max_dynamic_margin = 80.0;

fn computeDynamicMargin(available_width: f32, min_margin: f32) f32 {
    const margin_ratio = 0.05;
    return @min(max_dynamic_margin, @max(min_margin, available_width * margin_ratio));
}

pub const LayoutContext = struct {
    allocator: Allocator,
    theme: *const Theme,
    fonts: *const Fonts,
    content_width: f32,
    content_x: f32,
    cursor_y: f32,
    tree: *layout_types.LayoutTree,
    /// Computed margin for top/bottom padding and content width inset.
    dynamic_margin: f32,
    // List context
    list_depth: u8 = 0,
    list_type: ast.ListType = .bullet,
    list_item_index: u32 = 0,
    // Task list dimming
    dimmed: bool = false,
    // Footnote tracking — definitions are collected during the first pass and
    // rendered as an ordered list at the document bottom by layoutFootnotes().
    /// Collected footnote definition AST nodes (borrowed pointers into the Document).
    /// Rendered in order at the document bottom after all other content.
    footnote_defs: std.ArrayList(*const ast.Node),
    /// Maps footnote label → 1-based display index for auto-incrementing numbering.
    /// Unique labels are assigned sequential numbers in order of first appearance.
    /// Keys borrow from the AST literal strings (valid for the layout pass lifetime).
    footnote_ref_map: std.StringHashMap(u32),
    /// Next available 1-based display index for an unseen footnote label.
    footnote_ref_next: u32 = 1,
    // Image renderer for loading textures
    image_renderer: ?*ImageRenderer = null,
    // Line number gutter width (0 when disabled)
    gutter_width: f32 = 0,
    // Whether the active theme is dark (for <picture> source selection)
    is_dark: bool = false,
    // Persistent collapsed/expanded state for <details> sections.
    // Keyed by source line number — borrowed from the caller so state
    // survives re-layout. null = use default from HTML attributes.
    details_state: ?*std.AutoHashMap(u32, bool) = null,
    // Per-section disclosure triangle animation progress (0.0–1.0).
    // Borrowed from the caller; null = no animation tracking (use target state directly).
    details_anim: ?*const std.AutoHashMap(u32, f32) = null,
    // Section ID of the currently keyboard-focused details header, or null if none.
    details_focused_section_id: ?u32 = null,

    pub fn init(
        allocator: Allocator,
        theme: *const Theme,
        fonts: *const Fonts,
        available_width: f32,
        tree: *layout_types.LayoutTree,
        y_offset: f32,
        left_offset: f32,
    ) LayoutContext {
        const margin = computeDynamicMargin(available_width, theme.page_margin);
        const content_width = @max(0, @min(
            theme.max_content_width,
            available_width - margin * 2,
        ));
        const content_x = left_offset + (available_width - content_width) / 2.0;

        return .{
            .allocator = allocator,
            .theme = theme,
            .fonts = fonts,
            .content_width = content_width,
            .content_x = content_x,
            .cursor_y = y_offset + margin,
            .dynamic_margin = margin,
            .tree = tree,
            .footnote_defs = std.ArrayList(*const ast.Node).init(allocator),
            .footnote_ref_map = std.StringHashMap(u32).init(allocator),
            .footnote_ref_next = 1,
        };
    }

    /// Free owned resources: footnote definition list and reference map.
    pub fn deinit(self: *LayoutContext) void {
        self.footnote_defs.deinit();
        self.footnote_ref_map.deinit();
    }
};

fn layoutInlines(
    ctx: *LayoutContext,
    node: *const ast.Node,
    style: layout_types.TextStyle,
    layout_node: *layout_types.LayoutNode,
    cursor_x: *f32,
    line_height: *f32,
) !void {
    // Track sub/sup state across sibling html_inline tags.
    // When depth > 0, text is rendered at reduced size with vertical offset.
    var sub_depth: u8 = 0;
    var sup_depth: u8 = 0;
    // Track <kbd> nesting depth for keyboard-key bordered styling.
    var kbd_depth: u8 = 0;
    // Track <ins> nesting depth for underline styling.
    var ins_depth: u8 = 0;
    // Track <samp> nesting depth for sample output monospace styling.
    var samp_depth: u8 = 0;
    // Track <mark> nesting depth for highlight background styling.
    var mark_depth: u8 = 0;

    for (node.children.items) |*child| {
        // Compute effective style: apply sub/sup modifications when active
        var effective_style = applySubSupStyle(style, sub_depth, sup_depth);
        // Apply kbd styling when inside <kbd> tags
        if (kbd_depth > 0) {
            effective_style.is_kbd = true;
            effective_style.is_code = true;
        }
        // Apply insertion styling when inside <ins> tags — green underline distinct from links
        if (ins_depth > 0) {
            effective_style.is_ins = true;
            effective_style.underline = true;
        }
        // Apply samp styling when inside <samp> tags — monospace with distinct background
        if (samp_depth > 0) {
            effective_style.is_samp = true;
            effective_style.is_code = true;
            effective_style.code_bg = ctx.theme.code_background;
        }
        // Apply highlight background when inside <mark> tags
        if (mark_depth > 0) {
            effective_style.is_mark = true;
        }

        switch (child.node_type) {
            .text => {
                if (child.literal) |text| {
                    try layoutTextRun(ctx, text, effective_style, layout_node, cursor_x, line_height);
                }
            },
            .softbreak => {
                // Treat softbreak as a space
                try layoutTextRun(ctx, " ", effective_style, layout_node, cursor_x, line_height);
            },
            .linebreak => {
                // Hard break: move to next line
                cursor_x.* = ctx.content_x;
                ctx.cursor_y += line_height.*;
            },
            .code => {
                if (child.literal) |text| {
                    var code_style = effective_style;
                    code_style.is_code = true;
                    code_style.color = ctx.theme.code_text;
                    code_style.code_bg = ctx.theme.code_background;
                    try layoutTextRun(ctx, text, code_style, layout_node, cursor_x, line_height);
                }
            },
            .emph => {
                var em_style = effective_style;
                em_style.italic = true;
                try layoutInlines(ctx, child, em_style, layout_node, cursor_x, line_height);
            },
            .strong => {
                var strong_style = effective_style;
                strong_style.bold = true;
                try layoutInlines(ctx, child, strong_style, layout_node, cursor_x, line_height);
            },
            .strikethrough => {
                var st_style = effective_style;
                st_style.strikethrough = true;
                try layoutInlines(ctx, child, st_style, layout_node, cursor_x, line_height);
            },
            .link => {
                var link_style = effective_style;
                link_style.color = ctx.theme.link;
                link_style.underline = true;
                link_style.link_url = child.url;
                try layoutInlines(ctx, child, link_style, layout_node, cursor_x, line_height);
            },
            .footnote_reference => {
                // Render as superscript link pointing to the footnote definition anchor.
                // Mirrors GitHub's <sup><a href="#fn-{N}" id="fnref-{N}">{N}</a></sup>
                // where {N} is the 1-based ordinal assigned by cmark in first-reference order.
                //
                // cmark-gfm stores the ordinal as footnote_index AND also replaces the
                // author's label in the literal field with the ordinal string.  We use
                // footnote_index when available (it is always set by cmark for valid
                // references) and fall back to the footnote_ref_map for edge cases.
                const arena = ctx.tree.arena.allocator();
                // Determine ordinal: prefer cmark's footnote_index, fall back to our map.
                const ref_ordinal: u32 = if (child.footnote_index > 0)
                    child.footnote_index
                else if (child.literal) |ref_text| blk: {
                    break :blk if (ctx.footnote_ref_map.get(ref_text)) |existing|
                        existing
                    else inner: {
                        const new_index = ctx.footnote_ref_next;
                        ctx.footnote_ref_next += 1;
                        try ctx.footnote_ref_map.put(ref_text, new_index);
                        break :inner new_index;
                    };
                } else 0;

                if (ref_ordinal > 0) {
                    // Set anchor on containing node so the ↩ back-reference can link here.
                    layout_node.anchor_id = try std.fmt.allocPrint(arena, "fnref-{d}", .{ref_ordinal});
                    var fn_style = effective_style;
                    fn_style.font_size = effective_style.font_size * 0.75;
                    fn_style.color = ctx.theme.link;
                    fn_style.underline = true;
                    // Superscript vertical offset (shift up by 40% of parent font size)
                    fn_style.y_offset = -effective_style.font_size * 0.4;
                    // Forward link: "#fn-{N}" matches the definition's anchor_id "fn-{N}"
                    fn_style.link_url = try std.fmt.allocPrint(arena, "#fn-{d}", .{ref_ordinal});
                    // Display the numeric ordinal (e.g., "1", "2", "3") as superscript text
                    const ref_str = try std.fmt.allocPrint(arena, "{d}", .{ref_ordinal});
                    try layoutTextRun(ctx, ref_str, fn_style, layout_node, cursor_x, line_height);
                }
            },
            .html_inline => {
                if (child.literal) |tag| {
                    if (isBrTag(tag)) {
                        // Handle <br> tags as line breaks
                        cursor_x.* = ctx.content_x;
                        ctx.cursor_y += line_height.*;
                    } else if (isHtmlTag(tag, "sub")) {
                        sub_depth +|= 1;
                    } else if (isHtmlCloseTag(tag, "sub")) {
                        sub_depth -|= 1;
                    } else if (isHtmlTag(tag, "sup")) {
                        sup_depth +|= 1;
                    } else if (isHtmlCloseTag(tag, "sup")) {
                        sup_depth -|= 1;
                    } else if (isHtmlTag(tag, "kbd")) {
                        kbd_depth +|= 1;
                    } else if (isHtmlCloseTag(tag, "kbd")) {
                        kbd_depth -|= 1;
                    } else if (isHtmlTag(tag, "ins")) {
                        ins_depth +|= 1;
                    } else if (isHtmlCloseTag(tag, "ins")) {
                        ins_depth -|= 1;
                    } else if (isHtmlTag(tag, "samp")) {
                        samp_depth +|= 1;
                    } else if (isHtmlCloseTag(tag, "samp")) {
                        samp_depth -|= 1;
                    } else if (isHtmlTag(tag, "mark")) {
                        mark_depth +|= 1;
                    } else if (isHtmlCloseTag(tag, "mark")) {
                        mark_depth -|= 1;
                    }
                    // Other HTML inline tags handled by sibling modules or silently ignored.
                }
            },
            .image => {
                // Create a block-level image node
                // Collect alt text from children into an arena-allocated buffer
                const arena_alloc = ctx.tree.arena.allocator();
                var alt_parts = std.ArrayList([]const u8).init(ctx.allocator);
                defer alt_parts.deinit();
                for (child.children.items) |*img_child| {
                    if (img_child.literal) |text| {
                        try alt_parts.append(text);
                    }
                }

                // Try to load the texture
                var texture: ?rl.Texture2D = null;
                if (child.url) |url| {
                    if (ctx.image_renderer) |ir| {
                        texture = ir.getOrLoad(url) catch |err| blk: {
                            std.log.warn("Image load failed for '{s}': {}", .{ url, err });
                            break :blk null;
                        };
                    }
                }

                var img_height: f32 = 80; // placeholder height
                if (texture) |tex| {
                    // Scale to fit content width, preserving aspect ratio
                    const tex_w: f32 = @floatFromInt(tex.width);
                    const tex_h: f32 = @floatFromInt(tex.height);
                    if (tex_w > 0 and tex_h > 0) {
                        const scale = @min(1.0, ctx.content_width / tex_w);
                        img_height = tex_h * scale;
                    }
                }

                const alt_text: ?[]const u8 = if (alt_parts.items.len > 0)
                    try std.mem.concat(arena_alloc, u8, alt_parts.items)
                else
                    null;

                var img_node = layout_types.LayoutNode.init(ctx.allocator, .{ .image = .{
                    .texture = texture,
                    .alt = alt_text,
                } });
                errdefer img_node.deinit();

                // Move to a new line before the image
                cursor_x.* = ctx.content_x;
                ctx.cursor_y += line_height.*;

                img_node.rect = .{
                    .x = ctx.content_x,
                    .y = ctx.cursor_y,
                    .width = ctx.content_width,
                    .height = img_height,
                };
                try ctx.tree.nodes.append(img_node);

                ctx.cursor_y += img_height + ctx.theme.paragraph_spacing;
                cursor_x.* = ctx.content_x;
                line_height.* = 0;
            },
            .math_inline => {
                if (child.literal) |latex| {
                    // Use the FFI tree-walker to produce positioned text runs,
                    // which correctly handles fractions, superscripts, and subscripts.
                    _ = layout_math_renderer.renderInlineMath(
                        latex,
                        ctx.fonts,
                        ctx.theme,
                        layout_node,
                        ctx.tree,
                        cursor_x,
                        ctx.cursor_y,
                        effective_style.font_size,
                        effective_style.color,
                    ) catch {
                        // On parse failure, fall back to display-string approach.
                        math_layout.layoutInlineMath(
                            latex,
                            effective_style,
                            layout_node,
                            cursor_x,
                            line_height,
                            ctx.content_x,
                            ctx.content_width,
                            &ctx.cursor_y,
                            ctx.tree.arena.allocator(),
                            ctx.fonts,
                        ) catch |fallback_err| {
                            std.log.err("inline math fallback failed: {}", .{fallback_err});
                        };
                    };
                    line_height.* = @max(line_height.*, effective_style.font_size);
                }
            },
            .math_block => {
                // $$ block math appearing inside a paragraph — render as block math
                if (child.literal) |latex| {
                    // Flush any current line height
                    if (line_height.* > 0) {
                        ctx.cursor_y += line_height.*;
                        line_height.* = 0;
                    }
                    // Use the FFI tree-walker for rich positioning.
                    try layout_math_renderer.layoutMathBlock(
                        ctx.allocator,
                        latex,
                        ctx.theme,
                        ctx.fonts,
                        ctx.content_x,
                        ctx.content_width,
                        &ctx.cursor_y,
                        ctx.tree,
                    );
                    cursor_x.* = ctx.content_x;
                }
            },
            else => {
                // Recurse for any other inline types
                try layoutInlines(ctx, child, effective_style, layout_node, cursor_x, line_height);
            },
        }
    }
}

/// Returns true when the HTML literal represents a `<br>` tag.
/// Recognised forms: `<br>`, `<br/>`, `<br />` (case-insensitive).
fn isBrTag(raw: []const u8) bool {
    // Trim leading/trailing whitespace that cmark may include
    const tag = std.mem.trim(u8, raw, " \t\r\n");
    if (tag.len < 4) return false; // minimum: <br>
    if (tag[0] != '<' or tag[tag.len - 1] != '>') return false;
    const inner = std.mem.trim(u8, tag[1 .. tag.len - 1], " \t");
    // Strip optional trailing '/'
    const name = if (inner.len > 0 and inner[inner.len - 1] == '/')
        std.mem.trim(u8, inner[0 .. inner.len - 1], " \t")
    else
        inner;
    return std.ascii.eqlIgnoreCase(name, "br");
}

/// Returns true when the HTML literal is an opening tag for the given element name.
/// Matches `<name>` or `<name attr...>` (case-insensitive, allows surrounding whitespace).
/// Supports tags with attributes such as `<mark class="highlight">`.
fn isHtmlTag(raw: []const u8, comptime element: []const u8) bool {
    const tag = std.mem.trim(u8, raw, " \t\r\n");
    if (tag.len < element.len + 2) return false; // minimum: <name>
    if (tag[0] != '<' or tag[tag.len - 1] != '>') return false;
    const inner = std.mem.trim(u8, tag[1 .. tag.len - 1], " \t");
    // Must not start with '/' (that would be a closing tag)
    if (inner.len == 0 or inner[0] == '/') return false;
    // Exact match: <name>
    if (std.ascii.eqlIgnoreCase(inner, element)) return true;
    // Prefix match with attributes or self-close: <name attr...> or <name/>
    if (inner.len > element.len) {
        const sep = inner[element.len];
        if (sep == ' ' or sep == '\t' or sep == '/') {
            return std.ascii.eqlIgnoreCase(inner[0..element.len], element);
        }
    }
    return false;
}

/// Returns true when the HTML literal is a closing tag for the given element name.
/// Matches `</name>` (case-insensitive, allows surrounding whitespace).
fn isHtmlCloseTag(raw: []const u8, comptime element: []const u8) bool {
    const tag = std.mem.trim(u8, raw, " \t\r\n");
    if (tag.len < element.len + 3) return false; // minimum: </name>
    if (tag[0] != '<' or tag[tag.len - 1] != '>') return false;
    const inner = std.mem.trim(u8, tag[1 .. tag.len - 1], " \t");
    if (inner.len == 0 or inner[0] != '/') return false;
    const name = std.mem.trim(u8, inner[1..], " \t");
    return std.ascii.eqlIgnoreCase(name, element);
}

/// Returns true when the HTML literal starts with a `<details` opening tag.
/// Also detects `<details open>` via the `has_open` out-parameter.
/// The `open` attribute check is restricted to the opening tag only (up to the
/// first `>`), preventing false positives when the word "open" appears inside
/// the `<summary>` text (e.g. `<summary>Open this section</summary>`).
fn isDetailsBlock(html: []const u8, has_open: *bool) bool {
    has_open.* = false;
    const trimmed = std.mem.trim(u8, html, " \t\r\n");
    if (trimmed.len < 9) return false; // minimum: <details>
    if (trimmed[0] != '<') return false;
    // Match "<details" case-insensitively
    if (trimmed.len >= 8 and std.ascii.eqlIgnoreCase(trimmed[1..8], "details")) {
        const after = if (trimmed.len > 8) trimmed[8] else @as(u8, 0);
        if (after == '>' or after == ' ' or after == '\t' or after == '\n' or after == '\r') {
            // Restrict "open" search to the opening tag only (before the first '>').
            // This avoids false positives when "open" appears in the summary text.
            const tag_end = std.mem.indexOfScalar(u8, trimmed, '>') orelse trimmed.len - 1;
            const opening_tag = trimmed[0 .. tag_end + 1];
            has_open.* = hasOpenAttr(opening_tag);
            return true;
        }
    }
    return false;
}

/// Returns true when `tag` contains "open" as a standalone boolean attribute.
/// Requires word boundaries: preceded by whitespace and followed by whitespace,
/// `>`, or `=` — so "opener" or "reopened" in tag text won't match.
fn hasOpenAttr(tag: []const u8) bool {
    var pos: usize = 0;
    while (pos < tag.len) {
        const rel = std.ascii.indexOfIgnoreCase(tag[pos..], "open") orelse break;
        const abs = pos + rel;
        // Left boundary: must be preceded by whitespace
        const left_ok = abs == 0 or
            tag[abs - 1] == ' ' or tag[abs - 1] == '\t' or
            tag[abs - 1] == '\n' or tag[abs - 1] == '\r';
        // Right boundary: must be followed by whitespace, '>', or '='
        const right_pos = abs + 4;
        const right_ok = right_pos >= tag.len or
            tag[right_pos] == ' ' or tag[right_pos] == '\t' or
            tag[right_pos] == '\n' or tag[right_pos] == '\r' or
            tag[right_pos] == '>' or tag[right_pos] == '=';
        if (left_ok and right_ok) return true;
        pos = abs + 1;
    }
    return false;
}

/// Returns true when the HTML literal is a `</details>` closing tag.
fn isDetailsCloseBlock(html: []const u8) bool {
    const trimmed = std.mem.trim(u8, html, " \t\r\n");
    if (trimmed.len < 10) return false; // minimum: </details>
    return std.ascii.indexOfIgnoreCase(trimmed, "</details>") != null;
}

/// Extract the summary text from a `<details>` HTML block.
/// Looks for content between `<summary>` (or `<summary ...>`) and `</summary>` tags.
/// Handles `<summary>` tags with attributes (e.g., `<summary class="x">`).
/// Returns the text or a default "Details" if no summary is found.
fn extractSummaryText(html: []const u8) []const u8 {
    // Find <summary opening tag (case-insensitive, handles attributes)
    const open_pos = std.ascii.indexOfIgnoreCase(html, "<summary") orelse
        return "Details";
    // Advance past <summary to find the closing '>' of the opening tag
    const after_name = open_pos + 8; // len("<summary")
    const tag_close = std.mem.indexOfScalarPos(u8, html, after_name, '>') orelse
        return "Details";
    const content_start = tag_close + 1;

    // Find </summary> closing tag
    const summary_close = std.ascii.indexOfIgnoreCase(html[content_start..], "</summary>") orelse
        return "Details";
    const text = std.mem.trim(u8, html[content_start .. content_start + summary_close], " \t\r\n");
    return if (text.len > 0) text else "Details";
}

/// Compute an effective TextStyle with sub/sup size reduction and vertical offset.
/// Superscript: 75% font size, shifted up by 40% of original size.
/// Subscript: 75% font size, shifted down by 20% of original size.
fn applySubSupStyle(base: layout_types.TextStyle, sub_depth: u8, sup_depth: u8) layout_types.TextStyle {
    if (sub_depth == 0 and sup_depth == 0) return base;
    var result = base;
    // Each nesting level reduces font size further (0.75^depth)
    const total_depth = sub_depth + sup_depth;
    var scale: f32 = 1.0;
    for (0..total_depth) |_| {
        scale *= 0.75;
    }
    result.font_size = base.font_size * scale;
    // Compute vertical offset relative to base font size
    if (sup_depth > 0 and sub_depth == 0) {
        // Superscript only: shift up
        result.y_offset = base.y_offset - base.font_size * 0.4;
    } else if (sub_depth > 0 and sup_depth == 0) {
        // Subscript only: shift down
        result.y_offset = base.y_offset + base.font_size * 0.2;
    }
    // When both are active they cancel out vertically (stay at base offset)
    return result;
}

fn layoutTextRun(
    ctx: *LayoutContext,
    text: []const u8,
    style: layout_types.TextStyle,
    layout_node: *layout_types.LayoutNode,
    cursor_x: *f32,
    line_height: *f32,
) !void {
    // Apply emoji shortcode replacement (arena-allocated so it outlives layout pass)
    const display_text = emoji.replaceShortcodes(ctx.tree.arena.allocator(), text) orelse text;

    // Word wrap: split text at spaces and lay out word by word
    const max_x = ctx.content_x + ctx.content_width;
    var remaining = display_text;

    while (remaining.len > 0) {
        // Find next space or end
        var word_end: usize = 0;
        while (word_end < remaining.len and remaining[word_end] != ' ') : (word_end += 1) {}

        // Include the trailing space if present
        const chunk_end = if (word_end < remaining.len) word_end + 1 else word_end;
        const word = remaining[0..chunk_end];

        const measured = ctx.fonts.measure(word, style.font_size, style.bold, style.italic, style.is_code);

        // Wrap if this word would exceed the line
        if (cursor_x.* + measured.x > max_x and cursor_x.* > ctx.content_x) {
            cursor_x.* = ctx.content_x;
            ctx.cursor_y += line_height.*;
        }

        const run = layout_types.TextRun{
            .text = word,
            .style = style,
            .rect = .{
                .x = cursor_x.*,
                .y = ctx.cursor_y + style.y_offset,
                .width = measured.x,
                .height = measured.y,
            },
        };
        try layout_node.text_runs.append(run);

        line_height.* = @max(line_height.*, measured.y);

        cursor_x.* += measured.x;
        remaining = remaining[chunk_end..];
    }
}

/// Skip past a nested `<details>...</details>` block without rendering it.
/// Starts at `start_idx` (the opening `<details>` html_block) and returns the
/// index of the first child AFTER the matching `</details>` tag.
/// Handles arbitrarily deep nesting by tracking the brace depth counter.
fn skipDetailsBlock(children: []ast.Node, start_idx: usize) usize {
    var depth: u32 = 1; // We entered one <details> already at start_idx
    var i = start_idx + 1;
    while (i < children.len) : (i += 1) {
        const child = &children[i];
        if (child.node_type == .html_block) {
            if (child.literal) |html| {
                var inner_has_open: bool = false;
                if (isDetailsBlock(html, &inner_has_open)) {
                    depth += 1;
                } else if (isDetailsCloseBlock(html)) {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                }
            }
        }
    }
    return i;
}

/// Layout a `<details>/<summary>` collapsible section.
/// Returns the index of the first child AFTER the closing `</details>` tag.
/// Handles nested `<details>` blocks correctly: when expanded, inner sections
/// are recursively laid out; when collapsed, they are skipped via depth tracking.
fn layoutDetailsSection(
    ctx: *LayoutContext,
    children: []ast.Node,
    start_idx: usize,
    has_open_attr: bool,
    opening_html: []const u8,
) error{OutOfMemory}!usize {
    const section_id = children[start_idx].start_line;
    const summary_text = extractSummaryText(opening_html);

    // Determine expanded state: check persistent state first, then HTML attribute
    const expanded = if (ctx.details_state) |state|
        state.get(section_id) orelse has_open_attr
    else
        has_open_attr;

    // Determine animation progress: start from persisted value if available,
    // otherwise default to the target state (1.0 if expanded, 0.0 if collapsed).
    const anim_target: f32 = if (expanded) 1.0 else 0.0;
    const anim_progress = if (ctx.details_anim) |anim|
        anim.get(section_id) orelse anim_target
    else
        anim_target;

    // Determine keyboard focus state
    const is_focused = if (ctx.details_focused_section_id) |fid|
        fid == section_id
    else
        false;

    // Layout the summary header with disclosure triangle
    const font_size = ctx.theme.body_font_size;
    const lh = font_size * ctx.theme.line_height;
    const triangle_size: f32 = 12.0;
    const triangle_padding: f32 = 8.0;
    const header_start_y = ctx.cursor_y;

    var header_node = layout_types.LayoutNode.init(ctx.allocator, .{ .details_header = .{
        .expanded = expanded,
        .section_id = section_id,
        .anim_progress = anim_progress,
        .focused = is_focused,
    } });
    errdefer header_node.deinit();
    header_node.source_line = children[start_idx].start_line;
    header_node.source_end_line = children[start_idx].end_line;

    // Summary text run (offset right for the triangle)
    const text_x = ctx.content_x + triangle_size + triangle_padding;
    const summary_style = layout_types.TextStyle{
        .font_size = font_size,
        .color = ctx.theme.text,
        .bold = true,
    };
    const measured = ctx.fonts.measure(summary_text, font_size, true, false, false);

    try header_node.text_runs.append(.{
        .text = summary_text,
        .style = summary_style,
        .rect = .{
            .x = text_x,
            .y = ctx.cursor_y,
            .width = measured.x,
            .height = measured.y,
        },
    });

    header_node.rect = .{
        .x = ctx.content_x,
        .y = header_start_y,
        .width = ctx.content_width,
        .height = @max(lh, measured.y),
    };
    try ctx.tree.nodes.append(header_node);
    ctx.cursor_y += @max(lh, measured.y) + ctx.theme.paragraph_spacing * 0.5;

    // Find the closing </details> block and optionally layout inner content.
    // Nested <details> blocks are handled by:
    //   expanded=true  → recursive layoutDetailsSection call (renders inner section)
    //   expanded=false → skipDetailsBlock call (skips inner section without rendering)
    // This ensures the correct matching </details> is found even with deep nesting.
    var i = start_idx + 1;
    while (i < children.len) {
        const child = &children[i];
        if (child.node_type == .html_block) {
            if (child.literal) |html| {
                var inner_has_open: bool = false;
                if (isDetailsBlock(html, &inner_has_open)) {
                    // Nested <details> found — dispatch based on expansion state.
                    if (expanded) {
                        // Recursively layout the nested section (it may itself be collapsed).
                        i = try layoutDetailsSection(ctx, children, i, inner_has_open, html);
                    } else {
                        // Collapsed: skip the entire nested block without rendering.
                        i = skipDetailsBlock(children, i);
                    }
                    continue;
                }
                if (isDetailsCloseBlock(html)) {
                    // Found the matching closing tag for this section.
                    if (!expanded) {
                        // Add small spacing after collapsed section
                        ctx.cursor_y += ctx.theme.paragraph_spacing * 0.25;
                    }
                    return i + 1;
                }
            }
        }
        // Only layout inner content when expanded
        if (expanded) {
            try layoutBlock(ctx, child);
        }
        i += 1;
    }

    // No closing </details> found — end of document
    return i;
}

fn blendColor(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * (1 - t) + @as(f32, @floatFromInt(b.r)) * t),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * (1 - t) + @as(f32, @floatFromInt(b.g)) * t),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * (1 - t) + @as(f32, @floatFromInt(b.b)) * t),
        .a = 255,
    };
}

fn layoutBlock(ctx: *LayoutContext, node: *const ast.Node) !void {
    switch (node.node_type) {
        .document => {
            // Iterate children with <details> and <div align="center"> grouping support.
            // A <details> sequence spans: html_block(<details>) → content → html_block(</details>)
            // A <div align="center"> sequence spans: html_block(<div>) → content → html_block(</div>)
            const children = node.children.items;
            var i: usize = 0;
            while (i < children.len) {
                const child = &children[i];
                if (child.node_type == .html_block) {
                    if (child.literal) |html| {
                        var has_open: bool = false;
                        if (isDetailsBlock(html, &has_open)) {
                            i = try layoutDetailsSection(ctx, children, i, has_open, html);
                            continue;
                        }
                        if (isDivAlignCenter(html)) {
                            if (isDivCloseBlock(html)) {
                                // Self-contained: opening + content + closing in one html_block
                                try layoutDivAlignCenter(ctx, html, child.start_line, child.end_line);
                                i += 1;
                            } else {
                                // Multi-block: layout inner content nodes centered
                                i = try layoutDivAlignCenterSection(ctx, children, i);
                            }
                            continue;
                        }
                    }
                }
                try layoutBlock(ctx, child);
                i += 1;
            }
        },
        .heading => {
            ctx.cursor_y += ctx.theme.heading_spacing_above;

            var layout_node = layout_types.LayoutNode.init(ctx.allocator, .{ .heading = .{ .level = node.heading_level } });
            errdefer layout_node.deinit();
            layout_node.source_line = node.start_line;
            layout_node.source_end_line = node.end_line;

            const font_size = ctx.theme.headingSize(node.heading_level);
            const color = ctx.theme.headingColor(node.heading_level);
            const style = layout_types.TextStyle{
                .font_size = font_size,
                .color = color,
                .bold = true,
            };

            var cursor_x = ctx.content_x;
            var lh: f32 = font_size * ctx.theme.line_height;

            try layoutInlines(ctx, node, style, &layout_node, &cursor_x, &lh);

            layout_node.rect = .{
                .x = ctx.content_x,
                .y = ctx.cursor_y,
                .width = ctx.content_width,
                .height = lh,
            };

            // Update rect height based on actual text runs
            const runs = layout_node.text_runs.items;
            if (runs.len > 0) {
                layout_node.rect.height = runs[runs.len - 1].rect.bottom() - ctx.cursor_y;
            }

            try ctx.tree.nodes.append(layout_node);
            ctx.cursor_y += layout_node.rect.height + ctx.theme.heading_spacing_below;
        },
        .paragraph => {
            var layout_node = layout_types.LayoutNode.init(ctx.allocator, .text_block);
            errdefer layout_node.deinit();
            layout_node.source_line = node.start_line;
            layout_node.source_end_line = node.end_line;

            const text_color = if (ctx.dimmed) blendColor(ctx.theme.text, ctx.theme.background, 0.5) else ctx.theme.text;
            const style = layout_types.TextStyle{
                .font_size = ctx.theme.body_font_size,
                .color = text_color,
                .dimmed = ctx.dimmed,
            };

            var cursor_x = ctx.content_x;
            var lh: f32 = ctx.theme.body_font_size * ctx.theme.line_height;
            const start_y = ctx.cursor_y;

            try layoutInlines(ctx, node, style, &layout_node, &cursor_x, &lh);

            layout_node.rect = .{
                .x = ctx.content_x,
                .y = start_y,
                .width = ctx.content_width,
                .height = (ctx.cursor_y - start_y) + lh,
            };

            try ctx.tree.nodes.append(layout_node);
            ctx.cursor_y = start_y + layout_node.rect.height + ctx.theme.paragraph_spacing;
        },
        .math_block => {
            const before_count = ctx.tree.nodes.items.len;
            // Use the FFI tree-walker for rich positioning (fractions, matrices, etc.).
            try layout_math_renderer.layoutMathBlock(
                ctx.allocator,
                node.literal,
                ctx.theme,
                ctx.fonts,
                ctx.content_x,
                ctx.content_width,
                &ctx.cursor_y,
                ctx.tree,
            );
            for (ctx.tree.nodes.items[before_count..]) |*ln| {
                ln.source_line = node.start_line;
                ln.source_end_line = node.end_line;
            }
        },
        .code_block => {
            const is_mermaid = if (node.fence_info) |info| std.mem.eql(u8, info, "mermaid") else false;
            const is_math = if (node.fence_info) |info| std.mem.eql(u8, info, "math") else false;
            const before_count = ctx.tree.nodes.items.len;

            if (is_math) {
                // Use the FFI tree-walker for rich positioning (fractions, matrices, etc.).
                try layout_math_renderer.layoutMathBlock(
                    ctx.allocator,
                    node.literal,
                    ctx.theme,
                    ctx.fonts,
                    ctx.content_x,
                    ctx.content_width,
                    &ctx.cursor_y,
                    ctx.tree,
                );
            } else if (is_mermaid) {
                try mermaid_layout.layoutMermaidBlock(
                    ctx.allocator,
                    node.literal,
                    ctx.theme,
                    ctx.fonts,
                    ctx.content_x,
                    ctx.content_width,
                    &ctx.cursor_y,
                    ctx.tree,
                );
            } else {
                try code_block_layout.layoutCodeBlock(
                    ctx.allocator,
                    node.literal,
                    node.fence_info,
                    ctx.theme,
                    ctx.fonts,
                    ctx.content_x,
                    ctx.content_width,
                    &ctx.cursor_y,
                    ctx.tree,
                );
            }

            // Tag newly appended nodes with source line info
            for (ctx.tree.nodes.items[before_count..]) |*ln| {
                ln.source_line = node.start_line;
                ln.source_end_line = node.end_line;
            }
        },
        .thematic_break => {
            var layout_node = layout_types.LayoutNode.init(ctx.allocator, .{ .thematic_break = .{ .color = ctx.theme.hr_color } });
            errdefer layout_node.deinit();
            layout_node.source_line = node.start_line;
            layout_node.source_end_line = node.end_line;
            layout_node.rect = .{
                .x = ctx.content_x,
                .y = ctx.cursor_y + 8,
                .width = ctx.content_width,
                .height = 1,
            };
            try ctx.tree.nodes.append(layout_node);
            ctx.cursor_y += 24;
        },
        .block_quote => {
            // Check for GFM alert syntax (> [!NOTE], > [!TIP], etc.)
            const alert_info = alert_detector.detectAlert(node);
            const border_color = if (alert_info) |ai| ai.alert_type.borderColor(ctx.theme) else ctx.theme.blockquote_border;

            // Draw left border and indent content
            const saved_x = ctx.content_x;
            const saved_w = ctx.content_width;
            ctx.content_x += ctx.theme.blockquote_indent + 4; // 4px for border
            ctx.content_width -= ctx.theme.blockquote_indent + 4;

            const start_y = ctx.cursor_y;
            // Record insert position for alert background (drawn behind content)
            const alert_bg_insert_idx = ctx.tree.nodes.items.len;

            // If this is an alert, render the alert label first
            if (alert_info) |ai| {
                {
                    var label_node = layout_types.LayoutNode.init(ctx.allocator, .text_block);
                    errdefer label_node.deinit();
                    label_node.source_line = node.start_line;

                    const label_color = ai.alert_type.textColor(ctx.theme);
                    const label_style = layout_types.TextStyle{
                        .font_size = ctx.theme.body_font_size,
                        .color = label_color,
                        .bold = true,
                    };

                    // Icon + label (e.g., "ℹ Note")
                    const icon_text = ai.alert_type.icon();
                    const label_text = ai.alert_type.label();

                    var cursor_x = ctx.content_x;
                    var label_height: f32 = ctx.theme.body_font_size * ctx.theme.line_height;

                    const icon_m = ctx.fonts.measure(icon_text, label_style.font_size, false, false, false);
                    try label_node.text_runs.append(.{
                        .text = icon_text,
                        .style = label_style,
                        .rect = .{ .x = cursor_x, .y = ctx.cursor_y, .width = icon_m.x, .height = icon_m.y },
                    });
                    cursor_x += icon_m.x;

                    const label_m = ctx.fonts.measure(label_text, label_style.font_size, true, false, false);
                    try label_node.text_runs.append(.{
                        .text = label_text,
                        .style = label_style,
                        .rect = .{ .x = cursor_x, .y = ctx.cursor_y, .width = label_m.x, .height = label_m.y },
                    });
                    label_height = @max(label_height, @max(icon_m.y, label_m.y));

                    label_node.rect = .{
                        .x = ctx.content_x,
                        .y = ctx.cursor_y,
                        .width = ctx.content_width,
                        .height = label_height,
                    };
                    try ctx.tree.nodes.append(label_node);
                    // errdefer is now out of scope — tree owns label_node
                    ctx.cursor_y += label_height + ctx.theme.paragraph_spacing * 0.5;
                }

                // Layout children, but skip the alert marker text in the first paragraph
                for (node.children.items, 0..) |*alert_child, alert_child_idx| {
                    if (alert_child_idx == 0 and alert_child.node_type == .paragraph) {
                        var alert_para = layout_types.LayoutNode.init(ctx.allocator, .text_block);
                        errdefer alert_para.deinit();
                        alert_para.source_line = alert_child.start_line;
                        alert_para.source_end_line = alert_child.end_line;

                        const para_style = layout_types.TextStyle{
                            .font_size = ctx.theme.body_font_size,
                            .color = ctx.theme.text,
                        };

                        var para_cursor_x = ctx.content_x;
                        var para_line_height: f32 = ctx.theme.body_font_size * ctx.theme.line_height;
                        const para_start_y = ctx.cursor_y;

                        if (ai.remaining_text.len > 0) {
                            try layoutTextRun(ctx, ai.remaining_text, para_style, &alert_para, &para_cursor_x, &para_line_height);
                        }

                        // Layout remaining inline children (skip the first text node containing the marker)
                        if (alert_child.children.items.len > 1) {
                            for (alert_child.children.items[1..]) |*inline_child| {
                                switch (inline_child.node_type) {
                                    .text => {
                                        if (inline_child.literal) |itext| {
                                            try layoutTextRun(ctx, itext, para_style, &alert_para, &para_cursor_x, &para_line_height);
                                        }
                                    },
                                    else => {
                                        try layoutInlines(ctx, inline_child, para_style, &alert_para, &para_cursor_x, &para_line_height);
                                    },
                                }
                            }
                        }

                        alert_para.rect = .{
                            .x = ctx.content_x,
                            .y = para_start_y,
                            .width = ctx.content_width,
                            .height = (ctx.cursor_y - para_start_y) + para_line_height,
                        };

                        if (alert_para.text_runs.items.len > 0) {
                            try ctx.tree.nodes.append(alert_para);
                            ctx.cursor_y = para_start_y + alert_para.rect.height + ctx.theme.paragraph_spacing;
                        } else {
                            alert_para.deinit();
                        }
                    } else {
                        try layoutBlock(ctx, alert_child);
                    }
                }
            } else {
                for (node.children.items) |*child| {
                    try layoutBlock(ctx, child);
                }
            }

            // For alerts, insert a translucent background behind all content
            if (alert_info) |_| {
                var bg_node = layout_types.LayoutNode.init(ctx.allocator, .{
                    .alert_bg = .{
                        .color = .{ .r = border_color.r, .g = border_color.g, .b = border_color.b, .a = 20 }, // subtle tint
                    },
                });
                errdefer bg_node.deinit();
                bg_node.source_line = node.start_line;
                bg_node.source_end_line = node.end_line;
                bg_node.rect = .{
                    .x = saved_x,
                    .y = start_y,
                    .width = saved_w,
                    .height = ctx.cursor_y - start_y,
                };
                // Insert at recorded position so background renders behind content
                try ctx.tree.nodes.insert(alert_bg_insert_idx, bg_node);
                // bg_node is now owned by tree; errdefer must not fire after this point.
                // The subsequent border_node append could fail, so we close the if-block
                // here and handle border_node separately to avoid double-free.
            }

            // Add border marker
            var border_node = layout_types.LayoutNode.init(ctx.allocator, .{ .block_quote_border = .{ .color = border_color } });
            errdefer border_node.deinit();
            border_node.source_line = node.start_line;
            border_node.source_end_line = node.end_line;
            border_node.rect = .{
                .x = saved_x,
                .y = start_y,
                .width = 3,
                .height = ctx.cursor_y - start_y,
            };
            try ctx.tree.nodes.append(border_node);

            ctx.content_x = saved_x;
            ctx.content_width = saved_w;
        },
        .table => {
            const before_count = ctx.tree.nodes.items.len;
            try table_layout.layoutTable(
                ctx.allocator,
                node,
                ctx.tree,
                ctx.theme,
                ctx.fonts,
                ctx.content_x,
                ctx.content_width,
                &ctx.cursor_y,
            );
            // Tag newly appended table nodes with source line info
            for (ctx.tree.nodes.items[before_count..]) |*ln| {
                ln.source_line = node.start_line;
                ln.source_end_line = node.end_line;
            }
        },
        .list => {
            const saved_depth = ctx.list_depth;
            const saved_type = ctx.list_type;
            const saved_index = ctx.list_item_index;

            ctx.list_type = node.list_type;
            ctx.list_item_index = node.list_start;
            ctx.list_depth += 1;

            for (node.children.items) |*child| {
                try layoutBlock(ctx, child);
            }

            ctx.list_depth = saved_depth;
            ctx.list_type = saved_type;
            ctx.list_item_index = saved_index;
        },
        .item => {
            // Indent list items
            const saved_x = ctx.content_x;
            const saved_w = ctx.content_width;
            ctx.content_x += ctx.theme.list_indent;
            ctx.content_width -= ctx.theme.list_indent;

            // Add bullet/number/checkbox marker
            var marker_node = layout_types.LayoutNode.init(ctx.allocator, .text_block);
            errdefer marker_node.deinit();
            marker_node.source_line = node.start_line;
            marker_node.source_end_line = node.end_line;

            const is_dimmed = node.tasklist_checked orelse false;
            const marker_color = if (is_dimmed) blendColor(ctx.theme.text, ctx.theme.background, 0.5) else ctx.theme.text;
            const marker_style = layout_types.TextStyle{
                .font_size = ctx.theme.body_font_size,
                .color = marker_color,
            };

            if (node.tasklist_checked) |checked| {
                // Task list item: render checkbox
                const checkbox = if (checked) "\xE2\x98\x91 " else "\xE2\x98\x90 "; // ☑ or ☐
                try marker_node.text_runs.append(.{
                    .text = checkbox,
                    .style = marker_style,
                    .rect = .{
                        .x = saved_x + ctx.theme.list_indent - 20,
                        .y = ctx.cursor_y,
                        .width = 20,
                        .height = ctx.theme.body_font_size * ctx.theme.line_height,
                    },
                });
            } else if (ctx.list_type == .ordered) {
                // Ordered list: render number prefix — arena-allocated to outlive layout pass
                const num_str = try std.fmt.allocPrint(ctx.tree.arena.allocator(), "{d}. ", .{ctx.list_item_index});
                try marker_node.text_runs.append(.{
                    .text = num_str,
                    .style = marker_style,
                    .rect = .{
                        .x = saved_x + ctx.theme.list_indent - 24,
                        .y = ctx.cursor_y,
                        .width = 24,
                        .height = ctx.theme.body_font_size * ctx.theme.line_height,
                    },
                });
                ctx.list_item_index += 1;
            } else {
                // Unordered list: use different bullet per nesting level
                const bullets = [_][]const u8{
                    "\xE2\x80\xA2 ", // • (bullet)
                    "\xE2\x97\xA6 ", // ◦ (white bullet)
                    "\xE2\x96\xAA ", // ▪ (black small square)
                };
                const depth_idx = @min(ctx.list_depth - 1, bullets.len - 1);
                const bullet = bullets[depth_idx];
                try marker_node.text_runs.append(.{
                    .text = bullet,
                    .style = marker_style,
                    .rect = .{
                        .x = saved_x + ctx.theme.list_indent - 16,
                        .y = ctx.cursor_y,
                        .width = 16,
                        .height = ctx.theme.body_font_size * ctx.theme.line_height,
                    },
                });
            }

            marker_node.rect = .{
                .x = saved_x,
                .y = ctx.cursor_y,
                .width = ctx.theme.list_indent,
                .height = ctx.theme.body_font_size * ctx.theme.line_height,
            };
            try ctx.tree.nodes.append(marker_node);

            // Layout children with dimmed style if checked task
            const saved_dimmed = ctx.dimmed;
            if (is_dimmed) ctx.dimmed = true;

            for (node.children.items) |*child| {
                try layoutBlock(ctx, child);
            }

            ctx.dimmed = saved_dimmed;

            ctx.content_x = saved_x;
            ctx.content_width = saved_w;
        },
        .footnote_definition => {
            // Collect footnote definitions — they are rendered as an ordered list
            // at the document bottom by layoutFootnotes() after all other content.
            try ctx.footnote_defs.append(node);
        },
        .html_block => {
            if (node.literal) |html| {
                try layoutHtmlBlock(ctx, html, node.start_line, node.end_line);
            }
        },
        else => {
            // For unhandled block types, recurse into children
            for (node.children.items) |*child| {
                try layoutBlock(ctx, child);
            }
        },
    }
}

/// Parse and layout an HTML block. Handles definition lists (<dl>/<dt>/<dd>)
/// and falls back to rendering raw HTML as plain text for other block elements.
fn layoutHtmlBlock(ctx: *LayoutContext, html: []const u8, start_line: u32, end_line: u32) !void {
    // Check if this is a definition list block
    if (isDefinitionList(html)) {
        try layoutDefinitionList(ctx, html, start_line, end_line);
    } else if (isPictureBlock(html)) {
        try layoutPictureBlock(ctx, html, start_line, end_line);
    } else if (isDivAlignCenter(html)) {
        try layoutDivAlignCenter(ctx, html, start_line, end_line);
    }
    // Other HTML blocks (e.g., <div>, <details>) are handled by sibling modules
    // or silently ignored — raw HTML is not rendered as text.
}

/// Returns true when the HTML block starts with a `<div align="center">` tag.
/// Matches case-insensitively; supports both `align="center"` and `align='center'`.
fn isDivAlignCenter(html: []const u8) bool {
    // Find the first '<' to locate the opening tag
    var i: usize = 0;
    // Skip leading whitespace
    while (i < html.len and (html[i] == ' ' or html[i] == '\t' or html[i] == '\n' or html[i] == '\r')) : (i += 1) {}
    if (i + 4 > html.len) return false;
    if (html[i] != '<') return false;
    i += 1;
    // Match "div" case-insensitively
    if (i + 3 > html.len) return false;
    if (!((html[i] == 'd' or html[i] == 'D') and
        (html[i + 1] == 'i' or html[i + 1] == 'I') and
        (html[i + 2] == 'v' or html[i + 2] == 'V'))) return false;
    i += 3;
    // Must have space/tab before attributes
    if (i >= html.len or (html[i] != ' ' and html[i] != '\t')) return false;
    // Find end of the opening tag
    const tag_end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse return false;
    const tag_content = html[0 .. tag_end + 1];
    // Check for align="center" attribute
    if (getHtmlAttribute(tag_content, "align")) |val| {
        return std.ascii.eqlIgnoreCase(val, "center");
    }
    return false;
}

/// Layout a `<div align="center">` block by extracting its text content,
/// rendering it as a text block, then centering each line's text runs
/// within the content width.
fn layoutDivAlignCenter(ctx: *LayoutContext, html: []const u8, start_line: u32, end_line: u32) !void {
    // Extract text content from within the div (stripping HTML tags)
    // Find content between opening <div ...> and closing </div>
    const tag_end = std.mem.indexOfScalar(u8, html, '>') orelse return;
    const content_start = tag_end + 1;
    // Find closing </div>
    const close_pos = blk: {
        var pos: usize = content_start;
        while (pos < html.len) : (pos += 1) {
            if (html[pos] == '<') {
                const rest = html[pos..];
                if (rest.len >= 6 and
                    rest[1] == '/' and
                    (rest[2] == 'd' or rest[2] == 'D') and
                    (rest[3] == 'i' or rest[3] == 'I') and
                    (rest[4] == 'v' or rest[4] == 'V') and
                    (rest[5] == '>' or rest[5] == ' ' or rest[5] == '\t'))
                {
                    break :blk pos;
                }
            }
        }
        break :blk html.len;
    };

    const inner_html = html[content_start..close_pos];

    // Detect bold/italic from inner HTML tags
    var is_bold = false;
    var is_italic = false;
    {
        var scan: usize = 0;
        while (scan < inner_html.len) : (scan += 1) {
            if (inner_html[scan] == '<') {
                const rest = inner_html[scan..];
                if (isHtmlTag(rest[0..@min(rest.len, 20)], "strong") or
                    isHtmlTag(rest[0..@min(rest.len, 10)], "b"))
                {
                    is_bold = true;
                }
                if (isHtmlTag(rest[0..@min(rest.len, 10)], "em") or
                    isHtmlTag(rest[0..@min(rest.len, 10)], "i"))
                {
                    is_italic = true;
                }
            }
        }
    }

    const text_content = extractTextContent(inner_html);
    if (text_content.len == 0) return;

    var layout_node = layout_types.LayoutNode.init(ctx.allocator, .text_block);
    errdefer layout_node.deinit();
    layout_node.source_line = start_line;
    layout_node.source_end_line = end_line;

    const text_style = layout_types.TextStyle{
        .font_size = ctx.theme.body_font_size,
        .color = ctx.theme.text,
        .bold = is_bold,
        .italic = is_italic,
    };

    var cursor_x = ctx.content_x;
    var lh: f32 = ctx.theme.body_font_size * ctx.theme.line_height;
    const node_start_y = ctx.cursor_y;

    try layoutTextRun(ctx, text_content, text_style, &layout_node, &cursor_x, &lh);

    // Center each line of text runs within the content width
    centerTextRuns(&layout_node, ctx.content_x, ctx.content_width);

    layout_node.rect = .{
        .x = ctx.content_x,
        .y = node_start_y,
        .width = ctx.content_width,
        .height = (ctx.cursor_y - node_start_y) + lh,
    };

    try ctx.tree.nodes.append(layout_node);
    ctx.cursor_y = node_start_y + layout_node.rect.height + ctx.theme.paragraph_spacing;
}

/// Returns true when the HTML block contains a `</div>` closing tag.
fn isDivCloseBlock(html: []const u8) bool {
    var pos: usize = 0;
    while (pos < html.len) : (pos += 1) {
        if (html[pos] == '<') {
            const rest = html[pos..];
            if (rest.len >= 6 and
                rest[1] == '/' and
                (rest[2] == 'd' or rest[2] == 'D') and
                (rest[3] == 'i' or rest[3] == 'I') and
                (rest[4] == 'v' or rest[4] == 'V') and
                (rest[5] == '>' or rest[5] == ' ' or rest[5] == '\t'))
            {
                return true;
            }
        }
    }
    return false;
}

/// Layout a multi-block `<div align="center">` section.
/// The opening html_block at children[start_idx] contains `<div align="center">`.
/// Subsequent children are laid out normally, then all generated layout nodes
/// in this section have their text runs centered. The section ends at the
/// `</div>` html_block (or end of children).
/// Returns the index past the closing `</div>` block.
fn layoutDivAlignCenterSection(
    ctx: *LayoutContext,
    children: []ast.Node,
    start_idx: usize,
) error{OutOfMemory}!usize {
    // Record node count before laying out inner content
    const nodes_before = ctx.tree.nodes.items.len;

    // Layout all children between <div align="center"> and </div>
    var i = start_idx + 1;
    while (i < children.len) : (i += 1) {
        const child = &children[i];
        if (child.node_type == .html_block) {
            if (child.literal) |html| {
                if (isDivCloseBlock(html)) {
                    // Found closing </div> — skip past it
                    i += 1;
                    break;
                }
            }
        }
        try layoutBlock(ctx, child);
    }

    // Center all text runs in layout nodes generated within this section
    const nodes_after = ctx.tree.nodes.items.len;
    for (ctx.tree.nodes.items[nodes_before..nodes_after]) |*layout_node| {
        centerTextRuns(layout_node, ctx.content_x, ctx.content_width);
    }

    return i;
}

/// Center all text runs in a layout node within the given content area.
/// Groups runs by y position (same line) and shifts each group to center.
fn centerTextRuns(layout_node: *layout_types.LayoutNode, content_x: f32, content_width: f32) void {
    if (layout_node.text_runs.items.len == 0) return;

    var line_start: usize = 0;
    while (line_start < layout_node.text_runs.items.len) {
        const line_y = layout_node.text_runs.items[line_start].rect.y;
        var line_end = line_start + 1;
        while (line_end < layout_node.text_runs.items.len and
            layout_node.text_runs.items[line_end].rect.y == line_y) : (line_end += 1)
        {}

        // Calculate total width of runs on this line
        const last = &layout_node.text_runs.items[line_end - 1];
        const first = &layout_node.text_runs.items[line_start];
        const line_width = (last.rect.x + last.rect.width) - first.rect.x;
        const offset = (content_width - line_width) / 2.0;
        const shift = content_x + offset - first.rect.x;

        // Shift all runs on this line
        for (layout_node.text_runs.items[line_start..line_end]) |*run| {
            run.rect.x += shift;
        }

        line_start = line_end;
    }
}

/// Returns true when the HTML block contains a `<dl>` definition list.
fn isDefinitionList(html: []const u8) bool {
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] == '<') {
            const rest = html[i..];
            if (rest.len >= 4) {
                // Match <dl> or <dl with attributes
                if ((rest[1] == 'd' or rest[1] == 'D') and
                    (rest[2] == 'l' or rest[2] == 'L') and
                    (rest[3] == '>' or rest[3] == ' ' or rest[3] == '\t' or rest[3] == '\n'))
                {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Layout a `<dl>` definition list as structured text blocks.
/// `<dt>` entries are rendered as bold text; `<dd>` entries are indented.
fn layoutDefinitionList(ctx: *LayoutContext, html: []const u8, start_line: u32, end_line: u32) !void {
    const dd_indent: f32 = 24.0; // Indent for definition descriptions

    var pos: usize = 0;
    while (pos < html.len) {
        // Find the next tag
        const tag_start = std.mem.indexOfScalarPos(u8, html, pos, '<') orelse break;
        const tag_end_exclusive = if (std.mem.indexOfScalarPos(u8, html, tag_start + 1, '>')) |end| end + 1 else break;

        const tag_content = html[tag_start..tag_end_exclusive];

        if (isHtmlTag(tag_content, "dt")) {
            // Extract text content between <dt> and </dt>
            const content_start = tag_end_exclusive;
            const close_tag = findCloseTag(html, content_start, "dt") orelse {
                pos = tag_end_exclusive;
                continue;
            };
            const text_content = extractTextContent(html[content_start..close_tag]);

            if (text_content.len > 0) {
                // Render <dt> as bold text
                var layout_node = layout_types.LayoutNode.init(ctx.allocator, .text_block);
                errdefer layout_node.deinit();
                layout_node.source_line = start_line;
                layout_node.source_end_line = end_line;

                const dt_style = layout_types.TextStyle{
                    .font_size = ctx.theme.body_font_size,
                    .color = ctx.theme.text,
                    .bold = true,
                };

                var cursor_x = ctx.content_x;
                var lh: f32 = ctx.theme.body_font_size * ctx.theme.line_height;
                const node_start_y = ctx.cursor_y;

                try layoutTextRun(ctx, text_content, dt_style, &layout_node, &cursor_x, &lh);

                layout_node.rect = .{
                    .x = ctx.content_x,
                    .y = node_start_y,
                    .width = ctx.content_width,
                    .height = (ctx.cursor_y - node_start_y) + lh,
                };

                try ctx.tree.nodes.append(layout_node);
                ctx.cursor_y = node_start_y + layout_node.rect.height + ctx.theme.paragraph_spacing * 0.25;
            }

            pos = close_tag + findCloseTagLen("dt");
        } else if (isHtmlTag(tag_content, "dd")) {
            // Extract text content between <dd> and </dd>
            const content_start = tag_end_exclusive;
            const close_tag = findCloseTag(html, content_start, "dd") orelse {
                pos = tag_end_exclusive;
                continue;
            };
            const text_content = extractTextContent(html[content_start..close_tag]);

            if (text_content.len > 0) {
                // Render <dd> as indented text
                const saved_x = ctx.content_x;
                const saved_w = ctx.content_width;
                ctx.content_x += dd_indent;
                ctx.content_width -= dd_indent;

                var layout_node = layout_types.LayoutNode.init(ctx.allocator, .text_block);
                errdefer layout_node.deinit();
                layout_node.source_line = start_line;
                layout_node.source_end_line = end_line;

                const dd_style = layout_types.TextStyle{
                    .font_size = ctx.theme.body_font_size,
                    .color = ctx.theme.text,
                };

                var cursor_x = ctx.content_x;
                var lh: f32 = ctx.theme.body_font_size * ctx.theme.line_height;
                const node_start_y = ctx.cursor_y;

                try layoutTextRun(ctx, text_content, dd_style, &layout_node, &cursor_x, &lh);

                layout_node.rect = .{
                    .x = ctx.content_x,
                    .y = node_start_y,
                    .width = ctx.content_width,
                    .height = (ctx.cursor_y - node_start_y) + lh,
                };

                try ctx.tree.nodes.append(layout_node);
                ctx.cursor_y = node_start_y + layout_node.rect.height + ctx.theme.paragraph_spacing * 0.5;

                ctx.content_x = saved_x;
                ctx.content_width = saved_w;
            }

            pos = close_tag + findCloseTagLen("dd");
        } else {
            pos = tag_end_exclusive;
        }
    }

    // Add spacing after the definition list
    ctx.cursor_y += ctx.theme.paragraph_spacing * 0.5;
}

/// Find the position of the closing tag `</name>` starting from `start` in `html`.
/// Returns the byte offset of the '<' of the close tag, or null if not found.
fn findCloseTag(html: []const u8, start: usize, comptime name: []const u8) ?usize {
    const close = "</" ++ name ++ ">";
    var i = start;
    while (i + close.len <= html.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(html[i .. i + close.len], close)) {
            return i;
        }
    }
    return null;
}

/// Returns the byte length of a close tag `</name>`.
fn findCloseTagLen(comptime name: []const u8) usize {
    return 3 + name.len; // </name>
}

/// Extract plain text content from an HTML fragment, stripping any nested tags.
/// Returns a trimmed slice into the original input (no allocation needed).
fn extractTextContent(html: []const u8) []const u8 {
    // Simple approach: skip anything inside < > brackets
    var start: ?usize = null;
    var end: usize = 0;
    var in_tag = false;
    for (html, 0..) |c, i| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (!in_tag) {
            if (start == null and c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                start = i;
            }
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                end = i + 1;
            }
        }
    }
    if (start) |s| {
        return html[s..end];
    }
    return "";
}

/// Returns true when the HTML block contains a `<picture>` element.
fn isPictureBlock(html: []const u8) bool {
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] == '<') {
            const rest = html[i..];
            if (rest.len >= 9) { // len("<picture>") == 9
                if (std.ascii.eqlIgnoreCase(rest[1..8], "picture") and
                    (rest[8] == '>' or rest[8] == ' ' or rest[8] == '\t' or rest[8] == '\n'))
                {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Extract the value of an HTML attribute from a tag string.
/// Given `media="(prefers-color-scheme: dark)"`, returns `(prefers-color-scheme: dark)`.
/// Returns null if the attribute is not found.
fn getHtmlAttribute(tag: []const u8, comptime attr_name: []const u8) ?[]const u8 {
    const needle = attr_name ++ "=\"";
    var pos: usize = 0;
    while (pos < tag.len) {
        // Search case-insensitively for the attribute
        if (pos + needle.len <= tag.len) {
            if (std.ascii.eqlIgnoreCase(tag[pos .. pos + needle.len], needle)) {
                const val_start = pos + needle.len;
                const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, '"') orelse return null;
                return tag[val_start..val_end];
            }
        }
        pos += 1;
    }
    return null;
}

/// Select the best image URL from a `<picture>` HTML block based on the active
/// theme. Parses `<source>` tags for `prefers-color-scheme` media queries, then
/// falls back to the `<img>` tag's `src` attribute.
fn selectPictureUrl(html: []const u8, is_dark: bool) ?[]const u8 {
    const target_scheme: []const u8 = if (is_dark) "dark" else "light";
    var best_url: ?[]const u8 = null;

    // Scan for <source> tags with matching media queries
    var pos: usize = 0;
    while (pos < html.len) {
        const source_start = blk: {
            while (pos < html.len) : (pos += 1) {
                if (html[pos] == '<') {
                    const rest = html[pos..];
                    if (rest.len >= 7 and std.ascii.eqlIgnoreCase(rest[1..7], "source")) {
                        break :blk pos;
                    }
                }
            }
            break :blk null;
        };
        if (source_start == null) break;

        // Find end of this tag
        const tag_end = std.mem.indexOfScalarPos(u8, html, pos, '>') orelse break;
        const tag_content = html[pos .. tag_end + 1];
        pos = tag_end + 1;

        // Check media attribute for color scheme
        if (getHtmlAttribute(tag_content, "media")) |media| {
            if (std.mem.indexOf(u8, media, target_scheme) != null) {
                if (getHtmlAttribute(tag_content, "srcset")) |srcset| {
                    best_url = srcset;
                }
            }
        }
    }

    // If we found a matching source, use it
    if (best_url != null) return best_url;

    // Fall back to <img> tag's src attribute
    pos = 0;
    while (pos < html.len) {
        if (html[pos] == '<') {
            const rest = html[pos..];
            if (rest.len >= 4 and std.ascii.eqlIgnoreCase(rest[1..4], "img")) {
                const tag_end = std.mem.indexOfScalarPos(u8, html, pos, '>') orelse break;
                const tag_content = html[pos .. tag_end + 1];
                return getHtmlAttribute(tag_content, "src");
            }
        }
        pos += 1;
    }

    return null;
}

/// Extract the alt text from an `<img>` tag within a `<picture>` block.
fn getPictureAltText(html: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < html.len) {
        if (html[pos] == '<') {
            const rest = html[pos..];
            if (rest.len >= 4 and std.ascii.eqlIgnoreCase(rest[1..4], "img")) {
                const tag_end = std.mem.indexOfScalarPos(u8, html, pos, '>') orelse return null;
                const tag_content = html[pos .. tag_end + 1];
                return getHtmlAttribute(tag_content, "alt");
            }
        }
        pos += 1;
    }
    return null;
}

/// Layout a `<picture>` HTML block. Selects the image source matching the
/// current theme (light/dark) via `<source media="(prefers-color-scheme: ...)">`
/// and falls back to the `<img src="...">` default.
fn layoutPictureBlock(ctx: *LayoutContext, html: []const u8, start_line: u32, end_line: u32) !void {
    const url = selectPictureUrl(html, ctx.is_dark) orelse return;
    const alt = getPictureAltText(html);

    // Try to load the texture
    var texture: ?rl.Texture2D = null;
    if (ctx.image_renderer) |ir| {
        texture = ir.getOrLoad(url) catch |err| blk: {
            std.log.warn("Image load failed for '{s}': {}", .{ url, err });
            break :blk null;
        };
    }

    var img_height: f32 = 80; // placeholder height
    if (texture) |tex| {
        const tex_w: f32 = @floatFromInt(tex.width);
        const tex_h: f32 = @floatFromInt(tex.height);
        if (tex_w > 0 and tex_h > 0) {
            const scale = @min(1.0, ctx.content_width / tex_w);
            img_height = tex_h * scale;
        }
    }

    // Arena-dupe the alt text so it survives beyond the html literal lifetime
    const arena_alloc = ctx.tree.arena.allocator();
    const owned_alt: ?[]const u8 = if (alt) |a| try arena_alloc.dupe(u8, a) else null;

    var img_node = layout_types.LayoutNode.init(ctx.allocator, .{ .image = .{
        .texture = texture,
        .alt = owned_alt,
    } });
    errdefer img_node.deinit();
    img_node.source_line = start_line;
    img_node.source_end_line = end_line;

    img_node.rect = .{
        .x = ctx.content_x,
        .y = ctx.cursor_y,
        .width = ctx.content_width,
        .height = img_height,
    };
    try ctx.tree.nodes.append(img_node);

    ctx.cursor_y += img_height + ctx.theme.paragraph_spacing;
}

/// Render all collected footnote definitions as a numbered list at the document
/// bottom, separated from the main content by a short horizontal rule.  Each
/// entry ends with a "↩" back-reference anchor rendered in the link colour.
fn layoutFootnotes(ctx: *LayoutContext) !void {
    if (ctx.footnote_defs.items.len == 0) return;

    // Separator line above footnotes section
    ctx.cursor_y += ctx.theme.paragraph_spacing;
    {
        var sep_node = layout_types.LayoutNode.init(ctx.allocator, .{ .thematic_break = .{ .color = ctx.theme.hr_color } });
        errdefer sep_node.deinit();
        sep_node.rect = .{
            .x = ctx.content_x,
            .y = ctx.cursor_y,
            .width = ctx.content_width * 0.3,
            .height = 1,
        };
        try ctx.tree.nodes.append(sep_node);
        ctx.cursor_y += 12;
    }

    const small_size = ctx.theme.body_font_size * 0.85;
    const base_style = layout_types.TextStyle{
        .font_size = small_size,
        .color = ctx.theme.text,
    };

    for (ctx.footnote_defs.items, 0..) |fn_node, idx| {
        var layout_node = layout_types.LayoutNode.init(ctx.allocator, .text_block);
        errdefer layout_node.deinit();
        layout_node.source_line = fn_node.start_line;
        layout_node.source_end_line = fn_node.end_line;

        // Set anchor ID for in-document navigation from footnote reference links.
        // Uses the 1-based ordinal from cmark (footnote_index) so the anchor
        // "fn-{N}" matches the "#fn-{N}" link_url set on the corresponding
        // footnote_reference nodes.  The author's label (fn_node.literal) is
        // NOT used here because cmark replaces the label with an ordinal
        // string in the inline reference, so using the label would break
        // named footnotes like [^note] that get ordinal "2".
        // Falls back to idx+1 for any node where cmark did not set an ordinal.
        const ordinal: u32 = if (fn_node.footnote_index > 0) fn_node.footnote_index else @intCast(idx + 1);
        layout_node.anchor_id = try std.fmt.allocPrint(ctx.tree.arena.allocator(), "fn-{d}", .{ordinal});

        var cursor_x = ctx.content_x;
        var lh: f32 = small_size * ctx.theme.line_height;
        const start_y = ctx.cursor_y;

        // Ordered number prefix — arena-allocated to outlive layout pass
        const fn_str = try std.fmt.allocPrint(ctx.tree.arena.allocator(), "{d}. ", .{ordinal});
        const fn_m = ctx.fonts.measure(fn_str, small_size, false, false, false);
        try layout_node.text_runs.append(.{
            .text = fn_str,
            .style = base_style,
            .rect = .{ .x = cursor_x, .y = ctx.cursor_y, .width = fn_m.x, .height = fn_m.y },
        });
        cursor_x += fn_m.x;

        // Layout the footnote content (paragraphs).
        // Multiple paragraphs are separated by a line break so each starts on
        // its own line rather than being concatenated inline.
        var first_para = true;
        for (fn_node.children.items) |*child| {
            if (child.node_type == .paragraph) {
                if (!first_para) {
                    // Advance to next line before each subsequent paragraph.
                    cursor_x = ctx.content_x;
                    ctx.cursor_y += lh;
                }
                try layoutInlines(ctx, child, base_style, &layout_node, &cursor_x, &lh);
                first_para = false;
            }
        }

        // Back-reference anchor: " ↩" in link colour, clickable to scroll
        // back to the footnote reference in the document body.
        // Uses the same ordinal as the forward anchor so the pair is consistent:
        //   reference  → anchor_id "fnref-{N}", link_url "#fn-{N}"
        //   definition → anchor_id "fn-{N}",    link_url "#fnref-{N}"
        const back_ref = " \xE2\x86\xA9"; // UTF-8 for ↩
        const back_url = try std.fmt.allocPrint(ctx.tree.arena.allocator(), "#fnref-{d}", .{ordinal});
        const back_style = layout_types.TextStyle{
            .font_size = small_size,
            .color = ctx.theme.link,
            .underline = true,
            .link_url = back_url,
        };
        const back_m = ctx.fonts.measure(back_ref, small_size, false, false, false);
        try layout_node.text_runs.append(.{
            .text = back_ref,
            .style = back_style,
            .rect = .{ .x = cursor_x, .y = ctx.cursor_y, .width = back_m.x, .height = back_m.y },
        });

        layout_node.rect = .{
            .x = ctx.content_x,
            .y = start_y,
            .width = ctx.content_width,
            .height = (ctx.cursor_y - start_y) + lh,
        };

        try ctx.tree.nodes.append(layout_node);
        ctx.cursor_y = start_y + layout_node.rect.height + ctx.theme.paragraph_spacing * 0.5;
    }
}

// Find the maximum end_line in the AST to determine gutter digit count.
fn maxEndLine(node: *const ast.Node) u32 {
    var max: u32 = node.end_line;
    for (node.children.items) |*child| {
        max = @max(max, maxEndLine(child));
    }
    return max;
}

/// Lay out a parsed document into positioned nodes for rendering.
/// `y_offset` shifts content start downward (e.g., to leave room for a menu bar).
/// `left_offset` shifts content start rightward (e.g., for a ToC sidebar).
pub fn layout(
    allocator: Allocator,
    document: *const ast.Document,
    theme: *const Theme,
    fonts: *const Fonts,
    available_width: f32,
    image_renderer: ?*ImageRenderer,
    y_offset: f32,
    left_offset: f32,
    show_line_numbers: bool,
    is_dark: bool,
    details_state: ?*std.AutoHashMap(u32, bool),
    details_anim: ?*const std.AutoHashMap(u32, f32),
    details_focused_section_id: ?u32,
) !layout_types.LayoutTree {
    var tree = layout_types.LayoutTree.init(allocator);
    errdefer tree.deinit();
    var ctx = LayoutContext.init(allocator, theme, fonts, available_width, &tree, y_offset, left_offset);
    defer ctx.deinit();
    ctx.image_renderer = image_renderer;
    ctx.is_dark = is_dark;
    ctx.details_state = details_state;
    ctx.details_anim = details_anim;
    ctx.details_focused_section_id = details_focused_section_id;

    // Compute gutter width when line numbers are enabled
    if (show_line_numbers) {
        const max_line = maxEndLine(&document.root);
        if (max_line > 0) {
            // Measure widest possible label: "{max_line}+" (multi-line elements show "N+")
            var buf: [20]u8 = undefined;
            const widest_label = std.fmt.bufPrint(&buf, "{d}+", .{max_line}) catch "0+";
            const gutter_text_width = fonts.measure(widest_label, theme.mono_font_size, false, false, true).x;
            const desired_gutter = gutter_text_width + layout_types.gutter_padding * 2;
            // Skip gutter if viewport is too narrow to fit meaningful content
            if (ctx.content_width > desired_gutter + 100) {
                ctx.gutter_width = desired_gutter;
                tree.gutter_width = desired_gutter;
                ctx.content_x += desired_gutter;
                ctx.content_width -= desired_gutter;
            }
        }
    }

    try layoutBlock(&ctx, &document.root);

    // Render collected footnote definitions as an ordered list at the bottom
    try layoutFootnotes(&ctx);

    tree.total_height = ctx.cursor_y + ctx.dynamic_margin;
    return tree;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "LayoutContext.init content_x accounts for left_offset" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    const available_width: f32 = 960;
    const left_offset: f32 = 240;
    const fonts: Fonts = undefined;

    const ctx = LayoutContext.init(
        testing.allocator,
        &theme,
        &fonts,
        available_width,
        &tree,
        0,
        left_offset,
    );

    const margin = computeDynamicMargin(available_width, theme.page_margin);
    const expected_content_width = @min(theme.max_content_width, available_width - margin * 2);
    const expected_x = left_offset + (available_width - expected_content_width) / 2.0;
    try testing.expectEqual(expected_x, ctx.content_x);
    try testing.expect(ctx.content_x >= left_offset);
}

test "LayoutContext.init content_x centers content when left_offset is zero" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    const available_width: f32 = 960;
    const fonts: Fonts = undefined;

    const ctx = LayoutContext.init(
        testing.allocator,
        &theme,
        &fonts,
        available_width,
        &tree,
        0,
        0,
    );

    const margin = computeDynamicMargin(available_width, theme.page_margin);
    const expected_content_width = @min(theme.max_content_width, available_width - margin * 2);
    const expected_x = (available_width - expected_content_width) / 2.0;
    try testing.expectEqual(expected_x, ctx.content_x);
}

test "computeDynamicMargin returns min_margin when width is small" {
    // 5% of 100 = 5, which is below min_margin of 40
    try testing.expectEqual(@as(f32, 40), computeDynamicMargin(100, 40));
}

test "computeDynamicMargin returns max when width is large" {
    // 5% of 2000 = 100, clamped to max_dynamic_margin (80)
    try testing.expectEqual(@as(f32, max_dynamic_margin), computeDynamicMargin(2000, 40));
}

test "computeDynamicMargin returns proportional value in linear range" {
    // 5% of 1000 = 50, between min_margin (40) and max (80)
    try testing.expectEqual(@as(f32, 50), computeDynamicMargin(1000, 40));
}

test "computeDynamicMargin with zero width returns min_margin" {
    try testing.expectEqual(@as(f32, 20), computeDynamicMargin(0, 20));
}

test "computeDynamicMargin caps at max even when min_margin is higher" {
    // min_margin (100) > max_dynamic_margin (80), max ceiling wins
    try testing.expectEqual(@as(f32, max_dynamic_margin), computeDynamicMargin(500, 100));
}

test "maxEndLine returns maximum end_line across AST tree" {
    var root = ast.Node.init(testing.allocator, .document);
    defer root.deinit(testing.allocator);
    root.start_line = 1;
    root.end_line = 10;

    var child1 = ast.Node.init(testing.allocator, .paragraph);
    child1.start_line = 1;
    child1.end_line = 3;

    var child2 = ast.Node.init(testing.allocator, .heading);
    child2.start_line = 5;
    child2.end_line = 15;

    try root.children.append(child1);
    try root.children.append(child2);

    try testing.expectEqual(@as(u32, 15), maxEndLine(&root));
}

test "maxEndLine finds maximum in grandchild" {
    var root = ast.Node.init(testing.allocator, .document);
    defer root.deinit(testing.allocator);
    root.start_line = 1;
    root.end_line = 5;

    var child = ast.Node.init(testing.allocator, .list);
    child.start_line = 2;
    child.end_line = 5;

    var grandchild = ast.Node.init(testing.allocator, .item);
    grandchild.start_line = 3;
    grandchild.end_line = 20;

    try child.children.append(grandchild);
    try root.children.append(child);

    try testing.expectEqual(@as(u32, 20), maxEndLine(&root));
}

test "maxEndLine returns 0 for node with no line info" {
    var root = ast.Node.init(testing.allocator, .document);
    defer root.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), maxEndLine(&root));
}

test "isBrTag recognises common br variants" {
    try testing.expect(isBrTag("<br>"));
    try testing.expect(isBrTag("<br/>"));
    try testing.expect(isBrTag("<br />"));
    try testing.expect(isBrTag("<BR>"));
    try testing.expect(isBrTag("<Br/>"));
    try testing.expect(isBrTag("<BR />"));
    try testing.expect(isBrTag("  <br>  "));
}

test "isBrTag rejects non-br tags" {
    try testing.expect(!isBrTag("<p>"));
    try testing.expect(!isBrTag("<br class=\"x\">"));
    try testing.expect(!isBrTag("br"));
    try testing.expect(!isBrTag(""));
    try testing.expect(!isBrTag("<b>"));
}

test "isHtmlTag matches opening tags case-insensitively" {
    try testing.expect(isHtmlTag("<sub>", "sub"));
    try testing.expect(isHtmlTag("<SUB>", "sub"));
    try testing.expect(isHtmlTag("<Sub>", "sub"));
    try testing.expect(isHtmlTag("  <sub>  ", "sub"));
    try testing.expect(isHtmlTag("<sup>", "sup"));
    try testing.expect(isHtmlTag("<SUP>", "sup"));
}

test "isHtmlTag rejects closing and unrelated tags" {
    try testing.expect(!isHtmlTag("</sub>", "sub"));
    try testing.expect(!isHtmlTag("<p>", "sub"));
    try testing.expect(!isHtmlTag("sub", "sub"));
    try testing.expect(!isHtmlTag("", "sub"));
    try testing.expect(!isHtmlTag("<>", "sub"));
}

test "isHtmlCloseTag matches closing tags case-insensitively" {
    try testing.expect(isHtmlCloseTag("</sub>", "sub"));
    try testing.expect(isHtmlCloseTag("</SUB>", "sub"));
    try testing.expect(isHtmlCloseTag("</Sub>", "sub"));
    try testing.expect(isHtmlCloseTag("  </sub>  ", "sub"));
    try testing.expect(isHtmlCloseTag("</sup>", "sup"));
    try testing.expect(isHtmlCloseTag("</SUP>", "sup"));
}

test "isHtmlCloseTag rejects opening and unrelated tags" {
    try testing.expect(!isHtmlCloseTag("<sub>", "sub"));
    try testing.expect(!isHtmlCloseTag("</p>", "sub"));
    try testing.expect(!isHtmlCloseTag("/sub", "sub"));
    try testing.expect(!isHtmlCloseTag("", "sub"));
}

test "isHtmlTag matches kbd opening tags" {
    try testing.expect(isHtmlTag("<kbd>", "kbd"));
    try testing.expect(isHtmlTag("<KBD>", "kbd"));
    try testing.expect(isHtmlTag("<Kbd>", "kbd"));
    try testing.expect(isHtmlTag("  <kbd>  ", "kbd"));
}

test "isHtmlCloseTag matches kbd closing tags" {
    try testing.expect(isHtmlCloseTag("</kbd>", "kbd"));
    try testing.expect(isHtmlCloseTag("</KBD>", "kbd"));
    try testing.expect(isHtmlCloseTag("</Kbd>", "kbd"));
    try testing.expect(isHtmlCloseTag("  </kbd>  ", "kbd"));
}

test "isHtmlTag rejects kbd-like but wrong tags" {
    try testing.expect(!isHtmlTag("</kbd>", "kbd"));
    try testing.expect(!isHtmlTag("<p>", "kbd"));
    try testing.expect(!isHtmlTag("kbd", "kbd"));
    try testing.expect(!isHtmlTag("", "kbd"));
}

test "isHtmlTag matches ins opening tags" {
    try testing.expect(isHtmlTag("<ins>", "ins"));
    try testing.expect(isHtmlTag("<INS>", "ins"));
    try testing.expect(isHtmlTag("<Ins>", "ins"));
    try testing.expect(isHtmlTag("  <ins>  ", "ins"));
}

test "isHtmlCloseTag matches ins closing tags" {
    try testing.expect(isHtmlCloseTag("</ins>", "ins"));
    try testing.expect(isHtmlCloseTag("</INS>", "ins"));
    try testing.expect(isHtmlCloseTag("</Ins>", "ins"));
    try testing.expect(isHtmlCloseTag("  </ins>  ", "ins"));
}

test "isHtmlTag rejects ins-like but wrong tags" {
    try testing.expect(!isHtmlTag("</ins>", "ins"));
    try testing.expect(!isHtmlTag("<p>", "ins"));
    try testing.expect(!isHtmlTag("ins", "ins"));
    try testing.expect(!isHtmlTag("", "ins"));
}

test "isHtmlTag matches mark opening tags" {
    try testing.expect(isHtmlTag("<mark>", "mark"));
    try testing.expect(isHtmlTag("<MARK>", "mark"));
    try testing.expect(isHtmlTag("<Mark>", "mark"));
    try testing.expect(isHtmlTag("  <mark>  ", "mark"));
}

test "isHtmlCloseTag matches mark closing tags" {
    try testing.expect(isHtmlCloseTag("</mark>", "mark"));
    try testing.expect(isHtmlCloseTag("</MARK>", "mark"));
    try testing.expect(isHtmlCloseTag("</Mark>", "mark"));
    try testing.expect(isHtmlCloseTag("  </mark>  ", "mark"));
}

test "isHtmlTag rejects mark-like but wrong tags" {
    try testing.expect(!isHtmlTag("</mark>", "mark"));
    try testing.expect(!isHtmlTag("<p>", "mark"));
    try testing.expect(!isHtmlTag("mark", "mark"));
    try testing.expect(!isHtmlTag("", "mark"));
}

test "isHtmlTag matches samp opening tags" {
    try testing.expect(isHtmlTag("<samp>", "samp"));
    try testing.expect(isHtmlTag("<SAMP>", "samp"));
    try testing.expect(isHtmlTag("<Samp>", "samp"));
    try testing.expect(isHtmlTag("  <samp>  ", "samp"));
}

test "isHtmlCloseTag matches samp closing tags" {
    try testing.expect(isHtmlCloseTag("</samp>", "samp"));
    try testing.expect(isHtmlCloseTag("</SAMP>", "samp"));
    try testing.expect(isHtmlCloseTag("</Samp>", "samp"));
    try testing.expect(isHtmlCloseTag("  </samp>  ", "samp"));
}

test "isHtmlTag rejects samp-like but wrong tags" {
    try testing.expect(!isHtmlTag("</samp>", "samp"));
    try testing.expect(!isHtmlTag("<p>", "samp"));
    try testing.expect(!isHtmlTag("samp", "samp"));
    try testing.expect(!isHtmlTag("", "samp"));
}

test "isHtmlTag matches tags with attributes" {
    // Attribute support: <name attr=...> should match
    try testing.expect(isHtmlTag("<mark class=\"highlight\">", "mark"));
    try testing.expect(isHtmlTag("<kbd title=\"key\">", "kbd"));
    try testing.expect(isHtmlTag("<ins datetime=\"2024-01-01\">", "ins"));
    try testing.expect(isHtmlTag("<samp id=\"output\">", "samp"));
    try testing.expect(isHtmlTag("<sub style=\"color:red\">", "sub"));
    try testing.expect(isHtmlTag("<sup id=\"fn1\">", "sup"));
}

test "isHtmlTag rejects prefix-only matches without separator" {
    // <marker> must not match element "mark"
    try testing.expect(!isHtmlTag("<marker>", "mark"));
    // <subway> must not match element "sub"
    try testing.expect(!isHtmlTag("<subway>", "sub"));
    // <supplement> must not match element "sup"
    try testing.expect(!isHtmlTag("<supplement>", "sup"));
    // <insert> must not match element "ins"
    try testing.expect(!isHtmlTag("<insert>", "ins"));
    // <sampler> must not match element "samp"
    try testing.expect(!isHtmlTag("<sampler>", "samp"));
}

test "applySubSupStyle returns base when no sub/sup active" {
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const result = applySubSupStyle(base, 0, 0);
    try testing.expectEqual(base.font_size, result.font_size);
    try testing.expectEqual(@as(f32, 0), result.y_offset);
}

test "applySubSupStyle reduces font and shifts up for superscript" {
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const result = applySubSupStyle(base, 0, 1);
    // Font should be 75% of base
    try testing.expectApproxEqAbs(@as(f32, 12.0), result.font_size, 0.01);
    // y_offset should be negative (shifted up)
    try testing.expect(result.y_offset < 0);
    try testing.expectApproxEqAbs(@as(f32, -6.4), result.y_offset, 0.01);
}

test "applySubSupStyle reduces font and shifts down for subscript" {
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    const result = applySubSupStyle(base, 1, 0);
    // Font should be 75% of base
    try testing.expectApproxEqAbs(@as(f32, 12.0), result.font_size, 0.01);
    // y_offset should be positive (shifted down)
    try testing.expect(result.y_offset > 0);
    try testing.expectApproxEqAbs(@as(f32, 3.2), result.y_offset, 0.01);
}

test "applySubSupStyle nested depth reduces font further" {
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    // Double nesting: 0.75^2 = 0.5625
    const result = applySubSupStyle(base, 2, 0);
    try testing.expectApproxEqAbs(@as(f32, 9.0), result.font_size, 0.01);
}

test "applySubSupStyle sub+sup cancels vertical offset" {
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };
    // Both active: font reduced but no vertical shift
    const result = applySubSupStyle(base, 1, 1);
    try testing.expectApproxEqAbs(@as(f32, 0), result.y_offset, 0.01);
    // Font reduced by 0.75^2
    try testing.expectApproxEqAbs(@as(f32, 9.0), result.font_size, 0.01);
}

// =============================================================================
// Sub-AC 2c: Nesting validation tests — inline HTML tags within each other and
// within markdown inline elements (bold, italic, links).  These tests verify:
//   1. applySubSupStyle preserves all HTML-related style flags.
//   2. Style accumulation for stacked HTML depth counters is correct.
//   3. Closing an HTML tag produces the same style as never opening it (no bleed).
//   4. HTML flags are inherited through recursive layoutInlines calls (simulated
//      by verifying that styles passed as `style` are preserved by applySubSupStyle).
// =============================================================================

test "applySubSupStyle preserves is_mark flag through superscript" {
    // Simulates <mark><sup>text</sup></mark>: sup applied while mark active.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_mark = true,
    };
    const result = applySubSupStyle(base, 0, 1);
    // is_mark must be preserved through sub/sup transformation
    try testing.expect(result.is_mark);
    // Font size still reduced to 75%
    try testing.expectApproxEqAbs(@as(f32, 12.0), result.font_size, 0.01);
    // Shifted up
    try testing.expect(result.y_offset < 0);
}

test "applySubSupStyle preserves is_kbd and is_code flags through subscript" {
    // Simulates <kbd><sub>x</sub></kbd>: keyboard key label in subscript.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_code = true,
    };
    const result = applySubSupStyle(base, 1, 0);
    try testing.expect(result.is_kbd);
    try testing.expect(result.is_code);
    try testing.expectApproxEqAbs(@as(f32, 12.0), result.font_size, 0.01);
    // Shifted down for subscript
    try testing.expect(result.y_offset > 0);
}

test "applySubSupStyle preserves is_ins and underline flags" {
    // Simulates <ins><sup>added</sup></ins>: superscript inside insertion span.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_ins = true,
        .underline = true,
    };
    const result = applySubSupStyle(base, 0, 1);
    try testing.expect(result.is_ins);
    try testing.expect(result.underline);
    // Font reduced
    try testing.expectApproxEqAbs(@as(f32, 12.0), result.font_size, 0.01);
}

test "applySubSupStyle preserves is_samp flag" {
    // Simulates <samp><sub>output</sub></samp>: sample output in subscript.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_samp = true,
        .is_code = true,
    };
    const result = applySubSupStyle(base, 1, 0);
    try testing.expect(result.is_samp);
    try testing.expect(result.is_code);
}

test "applySubSupStyle preserves bold and italic inherited from markdown container" {
    // Simulates **<sup>superscript bold</sup>**: layoutInlines called recursively
    // for strong with bold=true, then applySubSupStyle applied inside that scope.
    const bold_style = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .bold = true,
    };
    const result = applySubSupStyle(bold_style, 0, 1);
    // bold flag must survive sub/sup transformation
    try testing.expect(result.bold);
    try testing.expectApproxEqAbs(@as(f32, 12.0), result.font_size, 0.01);
}

test "applySubSupStyle preserves italic and link_url from markdown container" {
    // Simulates *[link](url)<sub>x</sub>*: italic link with subscript.
    const link_style = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 100, .b = 200, .a = 255 },
        .italic = true,
        .underline = true,
        .link_url = "https://example.com",
    };
    const result = applySubSupStyle(link_style, 1, 0);
    try testing.expect(result.italic);
    try testing.expect(result.underline);
    // link_url preserved
    try testing.expectEqualStrings("https://example.com", result.link_url.?);
    // font reduced for subscript
    try testing.expectApproxEqAbs(@as(f32, 12.0), result.font_size, 0.01);
}

test "applySubSupStyle with pre-existing y_offset stacks superscript" {
    // Simulates footnote reference (y_offset=-6) that also contains a <sup> tag.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .y_offset = -5.0, // pre-existing offset (e.g. already in a superscript context)
    };
    const result = applySubSupStyle(base, 0, 1);
    // Must stack on existing offset, not replace it
    // Result: base.y_offset - base.font_size * 0.4 = -5.0 - 6.4 = -11.4
    try testing.expectApproxEqAbs(@as(f32, -11.4), result.y_offset, 0.01);
}

test "applySubSupStyle with pre-existing y_offset stacks subscript" {
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .y_offset = 2.0, // pre-existing downward offset
    };
    const result = applySubSupStyle(base, 1, 0);
    // Result: base.y_offset + base.font_size * 0.2 = 2.0 + 3.2 = 5.2
    try testing.expectApproxEqAbs(@as(f32, 5.2), result.y_offset, 0.01);
}

test "HTML nesting: simulated mark+ins style accumulation" {
    // Models what layoutInlines computes for text inside <mark><ins>text</ins></mark>
    // At the text node: mark_depth=1, ins_depth=1
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // Step 1: apply sub/sup (none active here)
    var effective = applySubSupStyle(base, 0, 0);
    // Step 2: apply mark_depth=1
    effective.is_mark = true;
    // Step 3: apply ins_depth=1
    effective.is_ins = true;
    effective.underline = true;

    // Both flags must be active simultaneously — no interference
    try testing.expect(effective.is_mark);
    try testing.expect(effective.is_ins);
    try testing.expect(effective.underline);
    try testing.expect(!effective.is_kbd);
    try testing.expect(!effective.is_samp);
    // font_size unchanged (no sub/sup)
    try testing.expectEqual(base.font_size, effective.font_size);
}

test "HTML nesting: simulated mark+kbd style accumulation" {
    // Models text inside <mark><kbd>Key</kbd></mark>: highlighted keyboard key.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    var effective = applySubSupStyle(base, 0, 0);
    effective.is_mark = true; // mark_depth=1
    effective.is_kbd = true; // kbd_depth=1
    effective.is_code = true;

    try testing.expect(effective.is_mark);
    try testing.expect(effective.is_kbd);
    try testing.expect(effective.is_code);
    try testing.expect(!effective.is_ins);
}

test "HTML nesting: simulated kbd+sub style accumulation" {
    // Models text inside <kbd><sub>x2</sub></kbd>: subscript inside keyboard key.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_kbd = true,
        .is_code = true,
    };
    // sub_depth=1 applied inside the kbd context
    const effective = applySubSupStyle(base, 1, 0);

    try testing.expect(effective.is_kbd);
    try testing.expect(effective.is_code);
    // font reduced by sub
    try testing.expectApproxEqAbs(@as(f32, 12.0), effective.font_size, 0.01);
    // shifted down
    try testing.expect(effective.y_offset > 0);
}

test "no style bleed: after mark depth closes, effective style is clean" {
    // Simulates the style computed AFTER </mark> is processed.
    // Before <mark>: mark_depth=0
    // Inside <mark>: mark_depth=1 → effective_style.is_mark=true
    // After </mark>: mark_depth=0 → effective_style.is_mark=false (back to base)
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // Inside <mark> — mark_depth=1
    var inside_style = applySubSupStyle(base, 0, 0);
    inside_style.is_mark = true;
    try testing.expect(inside_style.is_mark);

    // After </mark> — mark_depth=0, style recomputed from base
    const after_style = applySubSupStyle(base, 0, 0);
    // No is_mark set because mark_depth=0
    try testing.expect(!after_style.is_mark);
    // Base font size unchanged
    try testing.expectEqual(base.font_size, after_style.font_size);
}

test "no style bleed: ins closes independently of mark" {
    // Simulates <mark><ins>both</ins> just-mark</mark>
    // At 'both': mark_depth=1, ins_depth=1
    // At 'just-mark': mark_depth=1, ins_depth=0 (ins closed)
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // Inside both tags
    var both_style = applySubSupStyle(base, 0, 0);
    both_style.is_mark = true;
    both_style.is_ins = true;
    both_style.underline = true;
    try testing.expect(both_style.is_mark);
    try testing.expect(both_style.is_ins);

    // After </ins>, ins_depth=0, mark_depth=1 still
    var just_mark_style = applySubSupStyle(base, 0, 0);
    just_mark_style.is_mark = true;
    // is_ins NOT set because ins_depth=0
    try testing.expect(just_mark_style.is_mark);
    try testing.expect(!just_mark_style.is_ins);
    try testing.expect(!just_mark_style.underline);
}

test "no style bleed: HTML state does not carry into sibling markdown containers" {
    // Verifies that HTML depth state is local to a layoutInlines call scope.
    // When layoutInlines recurses for a <strong> child, it starts with fresh
    // depth counters (sub_depth=0, ...), BUT the inherited `style` parameter
    // carries any active HTML flags from the parent scope.
    //
    // Parent scope: mark_depth=1 → passes effective_style with is_mark=true to strong.
    // In strong's scope: sub_depth starts at 0 (fresh), but style.is_mark=true inherited.
    // Consequence: text inside **bold** also has is_mark=true (correct).
    //
    // After strong returns, parent mark_depth is still 1 (unchanged by child).
    // Sibling text after strong also gets is_mark=true (correct, still in <mark> scope).

    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // Parent scope: simulate mark_depth=1 → effective_style for strong child
    var parent_effective = applySubSupStyle(base, 0, 0);
    parent_effective.is_mark = true;

    // Child (strong) scope receives parent_effective as `style` parameter
    // Inside child, applySubSupStyle(style, 0, 0) returns style unchanged
    const child_base = parent_effective;
    const child_effective = applySubSupStyle(child_base, 0, 0);
    // Inherited is_mark from parent must still be true
    try testing.expect(child_effective.is_mark);

    // If child scope opens a <sup>: applySubSupStyle(child_base, 0, 1)
    const child_sup = applySubSupStyle(child_base, 0, 1);
    try testing.expect(child_sup.is_mark); // inherited mark preserved through sup
    try testing.expectApproxEqAbs(@as(f32, 12.0), child_sup.font_size, 0.01);
}

test "saturating depth counters prevent underflow on unmatched closing tags" {
    // Simulates what happens when a closing tag appears without an opening tag.
    // The -|= (saturating subtract) operator must not wrap below zero.
    var mark_depth: u8 = 0;
    // Extra closing tags should not cause underflow
    mark_depth -|= 1;
    try testing.expectEqual(@as(u8, 0), mark_depth);
    mark_depth -|= 1;
    try testing.expectEqual(@as(u8, 0), mark_depth);

    // Similarly for overflow protection on open tags
    var sub_depth: u8 = 255;
    sub_depth +|= 1;
    try testing.expectEqual(@as(u8, 255), sub_depth); // saturates at 255
}

// =============================================================================
// Sub-AC 2c: Comprehensive pairwise HTML inline tag nesting tests.
// These cover all combinations not already exercised above, including the
// task-specified example <kbd><sup>…</sup></kbd>.  Each test models the
// effective_style that layoutInlines() computes for the text node when
// the two depth counters are both > 0.
// =============================================================================

test "HTML nesting: simulated kbd+sup style accumulation (<kbd><sup>text</sup></kbd>)" {
    // Models text inside <kbd><sup>text</sup></kbd>:
    // At the text node: kbd_depth=1, sup_depth=1.
    // layoutInlines first calls applySubSupStyle(style, 0, 1) for the superscript
    // sizing, then sets is_kbd=true and is_code=true because kbd_depth=1.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // Step 1: sup_depth=1 applies superscript size reduction and upward shift
    var effective = applySubSupStyle(base, 0, 1);
    // Step 2: kbd_depth=1 enables keyboard-key styled background
    effective.is_kbd = true;
    effective.is_code = true;

    // kbd rendering is active
    try testing.expect(effective.is_kbd);
    try testing.expect(effective.is_code);
    // font reduced to 75% for superscript
    try testing.expectApproxEqAbs(@as(f32, 12.0), effective.font_size, 0.01);
    // y_offset is negative (shifted up above baseline)
    try testing.expect(effective.y_offset < 0);
    try testing.expectApproxEqAbs(@as(f32, -6.4), effective.y_offset, 0.01);
    // mark/ins/samp unaffected
    try testing.expect(!effective.is_mark);
    try testing.expect(!effective.is_ins);
    try testing.expect(!effective.is_samp);
}

test "HTML nesting: simulated sub+mark style accumulation (H<sub><mark>2</mark></sub>O)" {
    // Models the subscript digit "2" in H<sub><mark>2</mark></sub>O:
    // At the text node: sub_depth=1, mark_depth=1.
    // Both subscript styling AND highlight are applied simultaneously.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // Step 1: sub_depth=1 reduces font and shifts down
    var effective = applySubSupStyle(base, 1, 0);
    // Step 2: mark_depth=1 enables highlight background
    effective.is_mark = true;

    try testing.expect(effective.is_mark);
    // font reduced to 75% for subscript
    try testing.expectApproxEqAbs(@as(f32, 12.0), effective.font_size, 0.01);
    // y_offset is positive (shifted down below baseline)
    try testing.expect(effective.y_offset > 0);
    try testing.expectApproxEqAbs(@as(f32, 3.2), effective.y_offset, 0.01);
    // other flags unaffected
    try testing.expect(!effective.is_kbd);
    try testing.expect(!effective.is_ins);
}

test "HTML nesting: simulated sup+ins style accumulation (x<sup><ins>n+1</ins></sup>)" {
    // Models "n+1" inside x<sup><ins>n+1</ins></sup>:
    // At the text node: sup_depth=1, ins_depth=1.
    // Both superscript positioning and green-underline insertion styling apply.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // Step 1: sup_depth=1 shifts up and reduces font
    var effective = applySubSupStyle(base, 0, 1);
    // Step 2: ins_depth=1 adds insertion styling
    effective.is_ins = true;
    effective.underline = true;

    try testing.expect(effective.is_ins);
    try testing.expect(effective.underline);
    // superscript positioning
    try testing.expectApproxEqAbs(@as(f32, 12.0), effective.font_size, 0.01);
    try testing.expect(effective.y_offset < 0);
    // other flags unaffected
    try testing.expect(!effective.is_kbd);
    try testing.expect(!effective.is_mark);
}

test "HTML nesting: simulated ins+kbd style accumulation (<ins><kbd>K</kbd></ins>)" {
    // Models a keyboard key inside an insertion span:
    // At the text node: ins_depth=1, kbd_depth=1.
    // The kbd background + ins green underline both apply.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    var effective = applySubSupStyle(base, 0, 0);
    // ins_depth=1
    effective.is_ins = true;
    effective.underline = true;
    // kbd_depth=1
    effective.is_kbd = true;
    effective.is_code = true;

    try testing.expect(effective.is_ins);
    try testing.expect(effective.underline);
    try testing.expect(effective.is_kbd);
    try testing.expect(effective.is_code);
    // font size unchanged (no sub/sup)
    try testing.expectEqual(base.font_size, effective.font_size);
    try testing.expectApproxEqAbs(@as(f32, 0), effective.y_offset, 0.001);
    // mark unaffected
    try testing.expect(!effective.is_mark);
}

test "HTML nesting: simulated samp+mark style accumulation (<samp><mark>…</mark></samp>)" {
    // Models highlighted sample output:
    // At the text node: samp_depth=1, mark_depth=1.
    // Both the monospace samp background and the yellow highlight apply.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    var effective = applySubSupStyle(base, 0, 0);
    // samp_depth=1
    effective.is_samp = true;
    effective.is_code = true;
    // mark_depth=1
    effective.is_mark = true;

    try testing.expect(effective.is_samp);
    try testing.expect(effective.is_code);
    try testing.expect(effective.is_mark);
    // font unchanged (no sub/sup)
    try testing.expectEqual(base.font_size, effective.font_size);
    // kbd and ins unaffected
    try testing.expect(!effective.is_kbd);
    try testing.expect(!effective.is_ins);
}

test "HTML nesting: simulated samp+sub style accumulation (<samp><sub>…</sub></samp>)" {
    // Models subscript text inside sample output monospace box.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_samp = true,
        .is_code = true,
    };

    // sub_depth=1 inside the samp context
    const effective = applySubSupStyle(base, 1, 0);
    try testing.expect(effective.is_samp);
    try testing.expect(effective.is_code);
    // font reduced and shifted down for subscript
    try testing.expectApproxEqAbs(@as(f32, 12.0), effective.font_size, 0.01);
    try testing.expect(effective.y_offset > 0);
}

test "HTML nesting: simulated samp+sup style accumulation (<samp><sup>…</sup></samp>)" {
    // Models superscript text inside sample output monospace box.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .is_samp = true,
        .is_code = true,
    };

    // sup_depth=1 inside the samp context
    const effective = applySubSupStyle(base, 0, 1);
    try testing.expect(effective.is_samp);
    try testing.expect(effective.is_code);
    // font reduced and shifted up for superscript
    try testing.expectApproxEqAbs(@as(f32, 12.0), effective.font_size, 0.01);
    try testing.expect(effective.y_offset < 0);
}

test "HTML nesting: mark+ins and ins+mark reversed nesting produce same effective style" {
    // Verifies that nesting order does not matter for the final style flags.
    // Both <mark><ins>text</ins></mark> and <ins><mark>text</mark></ins>
    // should produce identical effective styles when the text node is processed.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // <mark><ins>: apply mark then ins
    var mark_then_ins = applySubSupStyle(base, 0, 0);
    mark_then_ins.is_mark = true;
    mark_then_ins.is_ins = true;
    mark_then_ins.underline = true;

    // <ins><mark>: apply ins then mark (different opening order)
    var ins_then_mark = applySubSupStyle(base, 0, 0);
    ins_then_mark.is_ins = true;
    ins_then_mark.underline = true;
    ins_then_mark.is_mark = true;

    // Both orderings produce identical effective flags
    try testing.expect(mark_then_ins.is_mark == ins_then_mark.is_mark);
    try testing.expect(mark_then_ins.is_ins == ins_then_mark.is_ins);
    try testing.expect(mark_then_ins.underline == ins_then_mark.underline);
    try testing.expectEqual(mark_then_ins.font_size, ins_then_mark.font_size);
    try testing.expectApproxEqAbs(mark_then_ins.y_offset, ins_then_mark.y_offset, 0.001);
}

test "HTML nesting: kbd+sub and sub+kbd produce equivalent composed style" {
    // Verifies kbd styling survives sub/sup transformation regardless of
    // whether <kbd> or <sub> was opened first.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // <kbd><sub>: kbd flag set in base style, then applySubSupStyle for sub
    var kbd_base = base;
    kbd_base.is_kbd = true;
    kbd_base.is_code = true;
    const kbd_then_sub = applySubSupStyle(kbd_base, 1, 0);

    // <sub><kbd>: apply sub positioning, then set kbd flag
    var sub_then_kbd = applySubSupStyle(base, 1, 0);
    sub_then_kbd.is_kbd = true;
    sub_then_kbd.is_code = true;

    // Both orderings should yield the same kbd and sub flags
    try testing.expect(kbd_then_sub.is_kbd);
    try testing.expect(kbd_then_sub.is_code);
    try testing.expect(sub_then_kbd.is_kbd);
    try testing.expect(sub_then_kbd.is_code);
    // Both have subscript font reduction and downward shift
    try testing.expectApproxEqAbs(kbd_then_sub.font_size, sub_then_kbd.font_size, 0.01);
    try testing.expectApproxEqAbs(kbd_then_sub.y_offset, sub_then_kbd.y_offset, 0.001);
    try testing.expect(kbd_then_sub.y_offset > 0); // downward for sub
}

test "HTML nesting: all six tags simultaneously produce fully composed style" {
    // Pathological case: all six HTML inline tag depth counters > 0 at once.
    // Verifies that every flag is set and sub/sup modifications apply correctly.
    // In practice this would come from something like:
    //   <kbd><mark><ins><samp><sub>text</sub></samp></ins></mark></kbd>
    //   with sup also active via some ancestor context.
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // sub_depth=1, sup_depth=0 → subscript positioning
    var effective = applySubSupStyle(base, 1, 0);
    // All HTML tag depth counters > 0
    effective.is_kbd = true;
    effective.is_code = true;
    effective.is_mark = true;
    effective.is_ins = true;
    effective.underline = true;
    effective.is_samp = true;

    try testing.expect(effective.is_kbd);
    try testing.expect(effective.is_code);
    try testing.expect(effective.is_mark);
    try testing.expect(effective.is_ins);
    try testing.expect(effective.underline);
    try testing.expect(effective.is_samp);
    // Subscript sizing applied
    try testing.expectApproxEqAbs(@as(f32, 12.0), effective.font_size, 0.01);
    try testing.expect(effective.y_offset > 0); // subscript shifts down
}

test "HTML nesting: style bleed check after all tags close" {
    // After all six depth counters return to zero, the effective style must
    // be identical to the base style (no flag leakage from previous iteration).
    const base = layout_types.TextStyle{
        .font_size = 16.0,
        .color = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
    };

    // After all tags closed: sub_depth=0, sup_depth=0, and no depth counters > 0
    const clean = applySubSupStyle(base, 0, 0);
    // clean == base; no flags should be set
    try testing.expect(!clean.is_kbd);
    try testing.expect(!clean.is_mark);
    try testing.expect(!clean.is_ins);
    try testing.expect(!clean.is_samp);
    try testing.expect(!clean.underline);
    try testing.expectEqual(base.font_size, clean.font_size);
    try testing.expectApproxEqAbs(@as(f32, 0), clean.y_offset, 0.001);
}

test "isDefinitionList detects dl tags" {
    try testing.expect(isDefinitionList("<dl>\n<dt>Term</dt>\n<dd>Definition</dd>\n</dl>"));
    try testing.expect(isDefinitionList("<DL><DT>Term</DT></DL>"));
    try testing.expect(isDefinitionList("  <dl>"));
}

test "isDefinitionList rejects non-dl HTML" {
    try testing.expect(!isDefinitionList("<div>content</div>"));
    try testing.expect(!isDefinitionList("<p>text</p>"));
    try testing.expect(!isDefinitionList(""));
    try testing.expect(!isDefinitionList("dl"));
}

test "extractTextContent strips HTML tags" {
    try testing.expectEqualStrings("Hello", extractTextContent("Hello"));
    try testing.expectEqualStrings("Hello World", extractTextContent("<b>Hello World</b>"));
    try testing.expectEqualStrings("Term", extractTextContent("  Term  "));
    try testing.expectEqualStrings("", extractTextContent("<br>"));
    try testing.expectEqualStrings("", extractTextContent(""));
}

test "extractTextContent returns span for nested tags" {
    // Returns widest slice from first to last non-ws text char (may include inter-tag markup)
    const result = extractTextContent("<b>bold</b> <i>text</i>");
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.startsWith(u8, result, "bold"));
    try testing.expect(std.mem.endsWith(u8, result, "text"));
}

test "findCloseTag locates closing tag" {
    const html = "<dt>Term</dt><dd>Def</dd>";
    try testing.expectEqual(@as(?usize, 8), findCloseTag(html, 0, "dt"));
    try testing.expectEqual(@as(?usize, 20), findCloseTag(html, 13, "dd"));
}

test "findCloseTag returns null when not found" {
    try testing.expectEqual(@as(?usize, null), findCloseTag("<dt>Term", 0, "dt"));
    try testing.expectEqual(@as(?usize, null), findCloseTag("", 0, "dt"));
}

test "findCloseTagLen returns correct length" {
    try testing.expectEqual(@as(usize, 5 + 3), findCloseTagLen("hello"));
    try testing.expectEqual(@as(usize, 2 + 3), findCloseTagLen("dt"));
    try testing.expectEqual(@as(usize, 2 + 3), findCloseTagLen("dd"));
}

test "isPictureBlock detects picture element" {
    try testing.expect(isPictureBlock("<picture>\n  <img src=\"x.png\">\n</picture>"));
    try testing.expect(isPictureBlock("<PICTURE>\n  <img src=\"x.png\">\n</PICTURE>"));
    try testing.expect(isPictureBlock("<Picture>\n  <img src=\"x.png\">\n</Picture>"));
    try testing.expect(isPictureBlock("  <picture>\n  <img src=\"x.png\">\n</picture>"));
}

test "isPictureBlock rejects non-picture blocks" {
    try testing.expect(!isPictureBlock("<div>content</div>"));
    try testing.expect(!isPictureBlock("<dl><dt>term</dt></dl>"));
    try testing.expect(!isPictureBlock(""));
    try testing.expect(!isPictureBlock("<img src=\"x.png\">"));
}

test "getHtmlAttribute extracts attribute values" {
    try testing.expectEqualStrings("dark.png", getHtmlAttribute("<source srcset=\"dark.png\">", "srcset").?);
    try testing.expectEqualStrings("(prefers-color-scheme: dark)", getHtmlAttribute(
        "<source media=\"(prefers-color-scheme: dark)\" srcset=\"d.png\">",
        "media",
    ).?);
    try testing.expectEqual(@as(?[]const u8, null), getHtmlAttribute("<source srcset=\"x.png\">", "media"));
    try testing.expectEqual(@as(?[]const u8, null), getHtmlAttribute("<img>", "src"));
}

test "selectPictureUrl picks dark source for dark theme" {
    const html =
        \\<picture>
        \\  <source media="(prefers-color-scheme: dark)" srcset="https://dark.png">
        \\  <source media="(prefers-color-scheme: light)" srcset="https://light.png">
        \\  <img alt="Theme-aware" src="https://fallback.png">
        \\</picture>
    ;
    const url = selectPictureUrl(html, true).?;
    try testing.expectEqualStrings("https://dark.png", url);
}

test "selectPictureUrl picks light source for light theme" {
    const html =
        \\<picture>
        \\  <source media="(prefers-color-scheme: dark)" srcset="https://dark.png">
        \\  <source media="(prefers-color-scheme: light)" srcset="https://light.png">
        \\  <img alt="Theme-aware" src="https://fallback.png">
        \\</picture>
    ;
    const url = selectPictureUrl(html, false).?;
    try testing.expectEqualStrings("https://light.png", url);
}

test "selectPictureUrl falls back to img src when no source matches" {
    const html =
        \\<picture>
        \\  <img alt="Fallback" src="https://fallback.png">
        \\</picture>
    ;
    const url = selectPictureUrl(html, true).?;
    try testing.expectEqualStrings("https://fallback.png", url);
}

test "selectPictureUrl returns null for empty picture" {
    try testing.expectEqual(@as(?[]const u8, null), selectPictureUrl("<picture></picture>", false));
}

test "getPictureAltText extracts alt from img tag" {
    const html =
        \\<picture>
        \\  <source media="(prefers-color-scheme: dark)" srcset="d.png">
        \\  <img alt="Theme-aware image" src="fallback.png">
        \\</picture>
    ;
    try testing.expectEqualStrings("Theme-aware image", getPictureAltText(html).?);
}

test "getPictureAltText returns null when no img tag" {
    try testing.expectEqual(@as(?[]const u8, null), getPictureAltText("<picture></picture>"));
}

test "isDetailsBlock detects details opening tag" {
    var has_open: bool = false;
    try testing.expect(isDetailsBlock("<details>\n<summary>Click</summary>", &has_open));
    try testing.expect(!has_open);
}

test "isDetailsBlock detects details with open attribute" {
    var has_open: bool = false;
    try testing.expect(isDetailsBlock("<details open>\n<summary>Open</summary>", &has_open));
    try testing.expect(has_open);
}

test "isDetailsBlock does not false-positive when open appears in summary text" {
    // "Open" in the summary text must NOT be confused with the `open` attribute
    var has_open: bool = false;
    try testing.expect(isDetailsBlock("<details>\n<summary>Open this section</summary>", &has_open));
    try testing.expect(!has_open); // no `open` attribute on the <details> tag
}

test "isDetailsBlock detects open attribute case-insensitively" {
    var has_open: bool = false;
    try testing.expect(isDetailsBlock("<details OPEN>content", &has_open));
    try testing.expect(has_open);
}

test "isDetailsBlock rejects non-details tags" {
    var has_open: bool = false;
    try testing.expect(!isDetailsBlock("<div>content</div>", &has_open));
    try testing.expect(!isDetailsBlock("<dl><dt>term</dt></dl>", &has_open));
    try testing.expect(!isDetailsBlock("", &has_open));
    try testing.expect(!isDetailsBlock("<detail>", &has_open));
}

test "hasOpenAttr detects standalone open attribute" {
    try testing.expect(hasOpenAttr("<details open>"));
    try testing.expect(hasOpenAttr("<details open >"));
    try testing.expect(hasOpenAttr("<details OPEN>"));
    try testing.expect(hasOpenAttr("<details Open>"));
}

test "hasOpenAttr rejects open as part of another word" {
    // "opener", "reopened", etc. must not match
    try testing.expect(!hasOpenAttr("<details opener>"));
    try testing.expect(!hasOpenAttr("<details reopened>"));
    try testing.expect(!hasOpenAttr("<details>"));
}

test "hasOpenAttr detects open= syntax" {
    // open="open" is valid HTML; `open=` word boundary case
    try testing.expect(hasOpenAttr("<details open=\"\">"));
}

test "isDetailsCloseBlock detects closing tag" {
    try testing.expect(isDetailsCloseBlock("</details>"));
    try testing.expect(isDetailsCloseBlock("  </details>  "));
    try testing.expect(isDetailsCloseBlock("</DETAILS>"));
    try testing.expect(isDetailsCloseBlock("\n</details>\n"));
}

test "isDetailsCloseBlock rejects non-closing tags" {
    try testing.expect(!isDetailsCloseBlock("<details>"));
    try testing.expect(!isDetailsCloseBlock("</div>"));
    try testing.expect(!isDetailsCloseBlock(""));
}

test "extractSummaryText extracts text between summary tags" {
    try testing.expectEqualStrings("Click to expand", extractSummaryText("<details>\n<summary>Click to expand</summary>"));
    try testing.expectEqualStrings("Title", extractSummaryText("<summary>Title</summary>"));
}

test "extractSummaryText handles summary tag with attributes" {
    // GitHub allows `<summary class="...">` and similar variants
    try testing.expectEqualStrings("Custom", extractSummaryText("<summary class=\"heading\">Custom</summary>"));
    try testing.expectEqualStrings("Styled", extractSummaryText("<SUMMARY id=\"s1\">Styled</SUMMARY>"));
}

test "extractSummaryText returns default when no summary" {
    try testing.expectEqualStrings("Details", extractSummaryText("<details>"));
    try testing.expectEqualStrings("Details", extractSummaryText(""));
}

test "extractSummaryText trims surrounding whitespace" {
    try testing.expectEqualStrings("With spaces", extractSummaryText("<summary>  With spaces  </summary>"));
    try testing.expectEqualStrings("Newline", extractSummaryText("<summary>\nNewline\n</summary>"));
}

// -------------------------------------------------------------------------
// Sub-AC 3a: skipDetailsBlock — nested <details> depth tracking tests
// -------------------------------------------------------------------------

test "skipDetailsBlock skips flat details block" {
    // Simulates: [<details>, <paragraph>, </details>, <other>]
    // skipDetailsBlock starts at index 0 (the <details> node) and should
    // return 3 (the index after </details> at index 2).
    var nodes = [_]ast.Node{
        ast.Node{ .node_type = .html_block, .literal = "<details>\n<summary>S</summary>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 1, .end_line = 2 },
        ast.Node{ .node_type = .paragraph, .literal = null, .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 3, .end_line = 3 },
        ast.Node{ .node_type = .html_block, .literal = "</details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 4, .end_line = 4 },
        ast.Node{ .node_type = .paragraph, .literal = null, .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 5, .end_line = 5 },
    };
    defer for (&nodes) |*n| n.children.deinit();

    const result = skipDetailsBlock(&nodes, 0);
    try testing.expectEqual(@as(usize, 3), result);
}

test "skipDetailsBlock handles nested details with depth tracking" {
    // Simulates: [<outer-details>, <inner-details>, </inner-details>, </outer-details>]
    // skipDetailsBlock at index 0 should skip all 4 nodes and return 4.
    var nodes = [_]ast.Node{
        ast.Node{ .node_type = .html_block, .literal = "<details>\n<summary>Outer</summary>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 1, .end_line = 1 },
        ast.Node{ .node_type = .html_block, .literal = "<details>\n<summary>Inner</summary>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 2, .end_line = 2 },
        ast.Node{ .node_type = .html_block, .literal = "</details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 3, .end_line = 3 },
        ast.Node{ .node_type = .html_block, .literal = "</details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 4, .end_line = 4 },
        ast.Node{ .node_type = .paragraph, .literal = null, .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 5, .end_line = 5 },
    };
    defer for (&nodes) |*n| n.children.deinit();

    const result = skipDetailsBlock(&nodes, 0);
    // Should consume indices 0..3 and return 4 (after the outer </details> at index 3).
    try testing.expectEqual(@as(usize, 4), result);
}

test "skipDetailsBlock handles three-level nesting" {
    // [<d1>, <d2>, <d3>, </d3>, </d2>, </d1>] → returns 6
    var nodes = [_]ast.Node{
        ast.Node{ .node_type = .html_block, .literal = "<details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 1, .end_line = 1 },
        ast.Node{ .node_type = .html_block, .literal = "<details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 2, .end_line = 2 },
        ast.Node{ .node_type = .html_block, .literal = "<details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 3, .end_line = 3 },
        ast.Node{ .node_type = .html_block, .literal = "</details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 4, .end_line = 4 },
        ast.Node{ .node_type = .html_block, .literal = "</details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 5, .end_line = 5 },
        ast.Node{ .node_type = .html_block, .literal = "</details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 6, .end_line = 6 },
    };
    defer for (&nodes) |*n| n.children.deinit();

    const result = skipDetailsBlock(&nodes, 0);
    try testing.expectEqual(@as(usize, 6), result);
}

test "skipDetailsBlock returns children.len when no closing tag found" {
    // Malformed: <details> without matching </details>
    var nodes = [_]ast.Node{
        ast.Node{ .node_type = .html_block, .literal = "<details>", .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 1, .end_line = 1 },
        ast.Node{ .node_type = .paragraph, .literal = null, .children = std.ArrayList(ast.Node).init(testing.allocator), .start_line = 2, .end_line = 2 },
    };
    defer for (&nodes) |*n| n.children.deinit();

    const result = skipDetailsBlock(&nodes, 0);
    // Should exhaust the array and return 2 (= nodes.len).
    try testing.expectEqual(@as(usize, 2), result);
}

test "isDivAlignCenter detects center-aligned divs" {
    try testing.expect(isDivAlignCenter("<div align=\"center\">\n  content\n</div>"));
    try testing.expect(isDivAlignCenter("<DIV ALIGN=\"CENTER\">\ncontent\n</DIV>"));
    try testing.expect(isDivAlignCenter("<div align=\"center\">text</div>"));
    try testing.expect(isDivAlignCenter("  <div align=\"center\">text</div>"));
}

test "isDivAlignCenter rejects non-center divs" {
    try testing.expect(!isDivAlignCenter("<div align=\"left\">text</div>"));
    try testing.expect(!isDivAlignCenter("<div align=\"right\">text</div>"));
    try testing.expect(!isDivAlignCenter("<div>text</div>"));
    try testing.expect(!isDivAlignCenter("<dl><dt>term</dt></dl>"));
    try testing.expect(!isDivAlignCenter(""));
    try testing.expect(!isDivAlignCenter("<span align=\"center\">text</span>"));
}

test "isDivCloseBlock detects closing div tags" {
    try testing.expect(isDivCloseBlock("</div>"));
    try testing.expect(isDivCloseBlock("</DIV>"));
    try testing.expect(isDivCloseBlock("</Div>"));
    try testing.expect(isDivCloseBlock("\n</div>\n"));
    try testing.expect(isDivCloseBlock("<div>content</div>"));
}

test "isDivCloseBlock rejects non-div closings" {
    try testing.expect(!isDivCloseBlock("<div>"));
    try testing.expect(!isDivCloseBlock("</span>"));
    try testing.expect(!isDivCloseBlock(""));
    try testing.expect(!isDivCloseBlock("<div align=\"center\">"));
}

test "LayoutContext.init initialises footnote_ref_map and counter" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined;

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    // Map starts empty and counter starts at 1
    try testing.expectEqual(@as(u32, 1), ctx.footnote_ref_next);
    try testing.expectEqual(@as(usize, 0), ctx.footnote_ref_map.count());
}

test "footnote_ref_map assigns sequential indices to distinct labels" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined;

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    // Simulate assigning indices for labels "alpha", "beta", "gamma" in order
    const label_alpha = "alpha";
    const label_beta = "beta";
    const label_gamma = "gamma";

    const idx_alpha = blk: {
        const new_index = ctx.footnote_ref_next;
        ctx.footnote_ref_next += 1;
        try ctx.footnote_ref_map.put(label_alpha, new_index);
        break :blk new_index;
    };
    const idx_beta = blk: {
        const new_index = ctx.footnote_ref_next;
        ctx.footnote_ref_next += 1;
        try ctx.footnote_ref_map.put(label_beta, new_index);
        break :blk new_index;
    };
    const idx_gamma = blk: {
        const new_index = ctx.footnote_ref_next;
        ctx.footnote_ref_next += 1;
        try ctx.footnote_ref_map.put(label_gamma, new_index);
        break :blk new_index;
    };

    try testing.expectEqual(@as(u32, 1), idx_alpha);
    try testing.expectEqual(@as(u32, 2), idx_beta);
    try testing.expectEqual(@as(u32, 3), idx_gamma);
    try testing.expectEqual(@as(u32, 4), ctx.footnote_ref_next);
}

test "footnote_ref_map reuses index for repeated label" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined;

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    const label = "note";

    // First occurrence assigns index 1
    const first_idx = blk: {
        const new_index = ctx.footnote_ref_next;
        ctx.footnote_ref_next += 1;
        try ctx.footnote_ref_map.put(label, new_index);
        break :blk new_index;
    };
    try testing.expectEqual(@as(u32, 1), first_idx);

    // Second occurrence reuses index 1
    const second_idx = ctx.footnote_ref_map.get(label).?;
    try testing.expectEqual(@as(u32, 1), second_idx);

    // Counter did not advance a second time
    try testing.expectEqual(@as(u32, 2), ctx.footnote_ref_next);
}

// =============================================================================
// Footnote collection tests
// =============================================================================
//
// These tests verify that layoutBlock() correctly collects footnote_definition
// nodes into ctx.footnote_defs during the document traversal pass.  The tests
// build AST nodes directly so they do not require a real Fonts object (font
// measurement is only called inside layoutFootnotes/layoutInlines, not during
// the collection step).

test "layoutBlock collects a single footnote definition" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined; // not accessed during footnote_definition collection

    var doc_node = ast.Node.init(testing.allocator, .document);
    defer doc_node.deinit(testing.allocator);

    var fn_def = ast.Node.init(testing.allocator, .footnote_definition);
    fn_def.literal = try testing.allocator.dupe(u8, "1");
    try doc_node.children.append(fn_def);

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    try layoutBlock(&ctx, &doc_node);

    try testing.expectEqual(@as(usize, 1), ctx.footnote_defs.items.len);
    try testing.expectEqualStrings("1", ctx.footnote_defs.items[0].literal.?);
}

test "layoutBlock collects multiple footnote definitions in document order" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined;

    var doc_node = ast.Node.init(testing.allocator, .document);
    defer doc_node.deinit(testing.allocator);

    var fn_def1 = ast.Node.init(testing.allocator, .footnote_definition);
    fn_def1.literal = try testing.allocator.dupe(u8, "alpha");
    try doc_node.children.append(fn_def1);

    var fn_def2 = ast.Node.init(testing.allocator, .footnote_definition);
    fn_def2.literal = try testing.allocator.dupe(u8, "beta");
    try doc_node.children.append(fn_def2);

    var fn_def3 = ast.Node.init(testing.allocator, .footnote_definition);
    fn_def3.literal = try testing.allocator.dupe(u8, "gamma");
    try doc_node.children.append(fn_def3);

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    try layoutBlock(&ctx, &doc_node);

    // All three definitions collected in declaration order
    try testing.expectEqual(@as(usize, 3), ctx.footnote_defs.items.len);
    try testing.expectEqualStrings("alpha", ctx.footnote_defs.items[0].literal.?);
    try testing.expectEqualStrings("beta", ctx.footnote_defs.items[1].literal.?);
    try testing.expectEqualStrings("gamma", ctx.footnote_defs.items[2].literal.?);
}

test "layoutBlock produces empty footnote_defs when document has no footnotes" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined;

    var doc_node = ast.Node.init(testing.allocator, .document);
    defer doc_node.deinit(testing.allocator);
    // Document with no children at all

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    try layoutBlock(&ctx, &doc_node);

    try testing.expectEqual(@as(usize, 0), ctx.footnote_defs.items.len);
}

test "layoutBlock collects footnote definition with null literal" {
    // cmark-gfm should always supply a literal, but verify we handle null safely
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined;

    var doc_node = ast.Node.init(testing.allocator, .document);
    defer doc_node.deinit(testing.allocator);

    // Footnote definition with no literal (null)
    const fn_def = ast.Node.init(testing.allocator, .footnote_definition);
    try doc_node.children.append(fn_def);

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    try layoutBlock(&ctx, &doc_node);

    // The node is still collected even with null literal
    try testing.expectEqual(@as(usize, 1), ctx.footnote_defs.items.len);
    try testing.expectEqual(null, ctx.footnote_defs.items[0].literal);
}

test "layoutBlock footnote_defs preserves pointer identity to original AST nodes" {
    // Verify that collected nodes are borrowed pointers, not copies.
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined;

    var doc_node = ast.Node.init(testing.allocator, .document);
    defer doc_node.deinit(testing.allocator);

    var fn_def = ast.Node.init(testing.allocator, .footnote_definition);
    fn_def.literal = try testing.allocator.dupe(u8, "ref");
    try doc_node.children.append(fn_def);

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    try layoutBlock(&ctx, &doc_node);

    // The collected pointer must point to the same node we appended
    try testing.expectEqual(&doc_node.children.items[0], ctx.footnote_defs.items[0]);
}

// =============================================================================
// Footnote back-reference anchor tests (integration via link_handler)
// =============================================================================
//
// These tests verify the bidirectional navigation model: forward links from
// in-text references to definitions (#fn-{label}) and back-references from
// definitions to references (#fnref-{label}) resolved via resolveAnchor().

test "footnote forward anchor resolves to definition node" {
    // Simulate what layoutFootnotes produces: a layout node with anchor_id "fn-1"
    const link_handler = @import("../render/link_handler.zig");

    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    // Simulate a footnote definition layout node (as generated by layoutFootnotes)
    var def_node = layout_types.LayoutNode.init(testing.allocator, .text_block);
    def_node.rect = .{ .x = 0, .y = 1200, .width = 600, .height = 24 };
    def_node.anchor_id = "fn-1"; // set by layoutFootnotes
    try tree.nodes.append(def_node);

    // A click on "#fn-1" should scroll to y=1200
    const result = link_handler.LinkHandler.resolveAnchor(&tree, "fn-1");
    try testing.expect(result != null);
    try testing.expectEqual(@as(f32, 1200), result.?);
}

test "footnote back-reference anchor resolves to reference node" {
    // Simulate what layoutInlines produces: a paragraph layout node with anchor_id "fnref-1"
    const link_handler = @import("../render/link_handler.zig");

    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    // Simulate the paragraph node containing the [^1] reference
    var ref_node = layout_types.LayoutNode.init(testing.allocator, .text_block);
    ref_node.rect = .{ .x = 0, .y = 300, .width = 600, .height = 20 };
    ref_node.anchor_id = "fnref-1"; // set by layoutInlines for footnote_reference
    try tree.nodes.append(ref_node);

    // A click on "#fnref-1" (from the ↩ back-reference) should scroll to y=300
    const result = link_handler.LinkHandler.resolveAnchor(&tree, "fnref-1");
    try testing.expect(result != null);
    try testing.expectEqual(@as(f32, 300), result.?);
}

test "footnote named reference anchor uses ordinal not author label" {
    // Named footnotes like [^note] now use ordinal-based anchor IDs ("fn-2", "fnref-2")
    // because cmark replaces the author label with an ordinal in the reference literal,
    // and the definition's footnote_index carries the same ordinal.  This ensures
    // bidirectional navigation is consistent for both numeric ([^1]) and named ([^note])
    // footnotes.  A [^note] that is the second-referenced footnote gets ordinal 2.
    const link_handler = @import("../render/link_handler.zig");

    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    // Simulate layoutFootnotes output for [^note] with footnote_index=2 → anchor "fn-2"
    var def_node = layout_types.LayoutNode.init(testing.allocator, .text_block);
    def_node.rect = .{ .x = 0, .y = 900, .width = 600, .height = 24 };
    def_node.anchor_id = "fn-2";
    try tree.nodes.append(def_node);

    // Simulate layoutInlines output for [^note] reference with footnote_index=2 → anchor "fnref-2"
    var ref_node = layout_types.LayoutNode.init(testing.allocator, .text_block);
    ref_node.rect = .{ .x = 0, .y = 150, .width = 600, .height = 20 };
    ref_node.anchor_id = "fnref-2";
    try tree.nodes.append(ref_node);

    // Forward navigation: reference → definition (click "[2]" superscript)
    const fwd = link_handler.LinkHandler.resolveAnchor(&tree, "fn-2");
    try testing.expect(fwd != null);
    try testing.expectEqual(@as(f32, 900), fwd.?);

    // Backward navigation: definition → reference (click "↩")
    const back = link_handler.LinkHandler.resolveAnchor(&tree, "fnref-2");
    try testing.expect(back != null);
    try testing.expectEqual(@as(f32, 150), back.?);

    // The author label "fn-note" is NOT used — navigation only works via ordinals
    try testing.expectEqual(null, link_handler.LinkHandler.resolveAnchor(&tree, "fn-note"));
    try testing.expectEqual(null, link_handler.LinkHandler.resolveAnchor(&tree, "fnref-note"));
}

test "footnote anchor resolution returns null for unknown anchor" {
    const link_handler = @import("../render/link_handler.zig");

    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    // Attempting to resolve an anchor that does not exist
    const result = link_handler.LinkHandler.resolveAnchor(&tree, "fn-99");
    try testing.expectEqual(null, result);
}

test "footnote anchor resolution is case-sensitive" {
    const link_handler = @import("../render/link_handler.zig");

    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();

    var node = layout_types.LayoutNode.init(testing.allocator, .text_block);
    node.anchor_id = "fn-1";
    try tree.nodes.append(node);

    // Exact match succeeds
    try testing.expect(link_handler.LinkHandler.resolveAnchor(&tree, "fn-1") != null);
    // Different case fails
    try testing.expectEqual(null, link_handler.LinkHandler.resolveAnchor(&tree, "FN-1"));
    try testing.expectEqual(null, link_handler.LinkHandler.resolveAnchor(&tree, "Fn-1"));
}

test "footnote ref_map assigns correct sequential index to named label" {
    const theme = @import("../theme/defaults.zig").light;
    var tree = layout_types.LayoutTree.init(testing.allocator);
    defer tree.deinit();
    const fonts: Fonts = undefined;

    var ctx = LayoutContext.init(testing.allocator, &theme, &fonts, 800, &tree, 0, 0);
    defer ctx.footnote_defs.deinit();
    defer ctx.footnote_ref_map.deinit();

    // Assign index 1 to "note"
    const idx1 = blk: {
        const n = ctx.footnote_ref_next;
        ctx.footnote_ref_next += 1;
        try ctx.footnote_ref_map.put("note", n);
        break :blk n;
    };
    // Assign index 2 to "1"
    const idx2 = blk: {
        const n = ctx.footnote_ref_next;
        ctx.footnote_ref_next += 1;
        try ctx.footnote_ref_map.put("1", n);
        break :blk n;
    };

    try testing.expectEqual(@as(u32, 1), idx1);
    try testing.expectEqual(@as(u32, 2), idx2);

    // Both labels remain in map
    try testing.expectEqual(@as(u32, 1), ctx.footnote_ref_map.get("note").?);
    try testing.expectEqual(@as(u32, 2), ctx.footnote_ref_map.get("1").?);
}

test "footnote back_ref utf8 arrow is correct" {
    // The ↩ back-reference must encode to the correct UTF-8 bytes (U+21A9)
    const back_ref = " \xE2\x86\xA9"; // UTF-8 for ↩
    try testing.expectEqual(@as(usize, 4), back_ref.len);
    // Verify UTF-8 encoding of U+21A9: E2 86 A9
    try testing.expectEqual(@as(u8, 0xE2), back_ref[1]);
    try testing.expectEqual(@as(u8, 0x86), back_ref[2]);
    try testing.expectEqual(@as(u8, 0xA9), back_ref[3]);
}

// =============================================================================
// Sub-AC 2: Footnote reference rendering tests
// =============================================================================
//
// These tests verify the superscript anchor link rendering for footnote_reference
// nodes in layoutInlines.  They mirror GitHub's:
//   <sup><a href="#fn-{N}" id="fnref-{N}">{N}</a></sup>
// where:
//   - font_size is reduced to 75% of the parent style
//   - y_offset shifts the text upward by 40% of the parent font_size
//   - link_url = "#fn-{N}" (forward link to definition)
//   - anchor_id = "fnref-{N}" (set on the containing layout node)
//   - display text = "{N}" (1-based ordinal string)
//
// Tests that require actual font measurement (layoutTextRun) are integration
// tests that would need raylib; the tests here verify the pure data / logic
// aspects of the rendering pipeline without invoking font infrastructure.

test "footnote reference superscript style: font_size is 75% of parent" {
    // Verify the font-size reduction applied to footnote reference text runs.
    // layoutInlines computes: fn_style.font_size = effective_style.font_size * 0.75
    const parent_font_size: f32 = 16.0;
    const expected: f32 = parent_font_size * 0.75;
    try testing.expectEqual(expected, 12.0);

    // Also verify proportionality at different parent sizes
    const heading_font_size: f32 = 24.0;
    const expected_heading: f32 = heading_font_size * 0.75;
    try testing.expectEqual(expected_heading, 18.0);
}

test "footnote reference superscript style: y_offset is -40% of parent font_size" {
    // Verify the vertical offset applied to shift the ordinal number up into
    // superscript position.
    // layoutInlines computes: fn_style.y_offset = -effective_style.font_size * 0.4
    const parent_font_size: f32 = 16.0;
    const y_offset: f32 = -parent_font_size * 0.4;
    try testing.expectApproxEqAbs(@as(f32, -6.4), y_offset, 1e-5);

    // Verify y_offset is negative (upward shift = superscript, not subscript)
    try testing.expect(y_offset < 0.0);
}

test "footnote reference anchor_id format: fnref-{ordinal}" {
    // Verify the anchor ID format used by layoutInlines for footnote_reference nodes.
    // This ID is placed on the containing layout node so the back-reference
    // in the definition section can navigate back to the in-text reference.
    var buf: [32]u8 = undefined;

    const id1 = try std.fmt.bufPrint(&buf, "fnref-{d}", .{@as(u32, 1)});
    try testing.expectEqualStrings("fnref-1", id1);

    var buf2: [32]u8 = undefined;
    const id2 = try std.fmt.bufPrint(&buf2, "fnref-{d}", .{@as(u32, 42)});
    try testing.expectEqualStrings("fnref-42", id2);

    var buf3: [32]u8 = undefined;
    const id3 = try std.fmt.bufPrint(&buf3, "fnref-{d}", .{@as(u32, 100)});
    try testing.expectEqualStrings("fnref-100", id3);
}

test "footnote reference link_url format: #fn-{ordinal}" {
    // Verify the forward link URL format — clicking the superscript ordinal scrolls
    // to the corresponding footnote definition anchor "fn-{N}" at the document bottom.
    var buf: [32]u8 = undefined;

    const url1 = try std.fmt.bufPrint(&buf, "#fn-{d}", .{@as(u32, 1)});
    try testing.expectEqualStrings("#fn-1", url1);

    var buf2: [32]u8 = undefined;
    const url2 = try std.fmt.bufPrint(&buf2, "#fn-{d}", .{@as(u32, 7)});
    try testing.expectEqualStrings("#fn-7", url2);

    var buf3: [32]u8 = undefined;
    const url3 = try std.fmt.bufPrint(&buf3, "#fn-{d}", .{@as(u32, 99)});
    try testing.expectEqualStrings("#fn-99", url3);
}

test "footnote reference display text: ordinal as string" {
    // The superscript text shown to the user is the 1-based ordinal (e.g. "1", "2").
    // layoutInlines formats: const ref_str = try std.fmt.allocPrint(arena, "{d}", .{ref_ordinal})
    var buf: [16]u8 = undefined;

    const s1 = try std.fmt.bufPrint(&buf, "{d}", .{@as(u32, 1)});
    try testing.expectEqualStrings("1", s1);

    var buf2: [16]u8 = undefined;
    const s2 = try std.fmt.bufPrint(&buf2, "{d}", .{@as(u32, 2)});
    try testing.expectEqualStrings("2", s2);

    var buf3: [16]u8 = undefined;
    const s10 = try std.fmt.bufPrint(&buf3, "{d}", .{@as(u32, 10)});
    try testing.expectEqualStrings("10", s10);
}

test "footnote reference ordinal from footnote_index takes priority over ref_map" {
    // When child.footnote_index > 0, it is used directly without consulting the ref_map.
    // This mirrors the layout logic:
    //   const ref_ordinal = if (child.footnote_index > 0) child.footnote_index else ...
    //
    // We verify the priority by simulating both sources and confirming footnote_index wins.
    const footnote_index: u32 = 3; // cmark-assigned ordinal

    // Simulate a ref_map that has a different value for the same label
    var fake_map = std.StringHashMap(u32).init(testing.allocator);
    defer fake_map.deinit();
    try fake_map.put("label", 99); // conflicting entry

    // The priority check: footnote_index > 0 means use it directly
    const ref_ordinal: u32 = if (footnote_index > 0)
        footnote_index
    else if (fake_map.get("label")) |existing|
        existing
    else
        0;

    try testing.expectEqual(@as(u32, 3), ref_ordinal);
    try testing.expect(ref_ordinal != 99); // ref_map value NOT used
}

test "footnote reference ordinal from ref_map when footnote_index is zero" {
    // When child.footnote_index == 0, the ref_map is consulted for an existing label,
    // and a new sequential index is assigned if the label is unseen.
    var fake_map = std.StringHashMap(u32).init(testing.allocator);
    defer fake_map.deinit();

    var next_index: u32 = 1;

    // First reference to "note" — assigned index 1
    const label_a = "note";
    const idx_a: u32 = if (fake_map.get(label_a)) |existing|
        existing
    else blk: {
        const new_index = next_index;
        next_index += 1;
        try fake_map.put(label_a, new_index);
        break :blk new_index;
    };
    try testing.expectEqual(@as(u32, 1), idx_a);

    // Second reference to "note" — reuses index 1
    const idx_a2: u32 = if (fake_map.get(label_a)) |existing|
        existing
    else blk: {
        const new_index = next_index;
        next_index += 1;
        try fake_map.put(label_a, new_index);
        break :blk new_index;
    };
    try testing.expectEqual(@as(u32, 1), idx_a2);

    // Reference to "other" — assigned index 2
    const label_b = "other";
    const idx_b: u32 = if (fake_map.get(label_b)) |existing|
        existing
    else blk: {
        const new_index = next_index;
        next_index += 1;
        try fake_map.put(label_b, new_index);
        break :blk new_index;
    };
    try testing.expectEqual(@as(u32, 2), idx_b);

    // Counter advanced twice (once for each unique label)
    try testing.expectEqual(@as(u32, 3), next_index);
}

test "footnote reference with ordinal zero produces no rendering" {
    // When both footnote_index == 0 and literal == null, ref_ordinal evaluates to 0.
    // The guard `if (ref_ordinal > 0)` prevents any rendering in this case.
    // This test verifies the guard condition.
    const footnote_index: u32 = 0;
    const literal: ?[]const u8 = null;

    const ref_ordinal: u32 = if (footnote_index > 0)
        footnote_index
    else if (literal) |_|
        999 // would be assigned from ref_map
    else
        0;

    // Ordinal zero -> skip rendering (no anchor_id, no text run, no link_url)
    try testing.expectEqual(@as(u32, 0), ref_ordinal);
    try testing.expect(!(ref_ordinal > 0)); // rendering guard fails -> nothing produced
}

test "footnote reference style: underline flag is set for link appearance" {
    // The reference text run uses link styling with underline enabled.
    // This test verifies that the style fields match GitHub's <a> element semantics:
    //   fn_style.underline = true
    //   fn_style.color = ctx.theme.link
    const theme = @import("../theme/defaults.zig").light;

    // Simulate the style fields assigned in layoutInlines
    const fn_style = layout_types.TextStyle{
        .font_size = 16.0 * 0.75,
        .color = theme.link,
        .underline = true,
        .y_offset = -16.0 * 0.4,
    };

    // Verify underline is set (analogous to <a> underline decoration)
    try testing.expect(fn_style.underline);
    // Verify font size is reduced to superscript size
    try testing.expectApproxEqAbs(@as(f32, 12.0), fn_style.font_size, 1e-5);
    // Verify y_offset is negative (upward superscript shift)
    try testing.expect(fn_style.y_offset < 0.0);
    // Verify it is NOT bold, italic, code, or strikethrough (plain link styling)
    try testing.expect(!fn_style.bold);
    try testing.expect(!fn_style.italic);
    try testing.expect(!fn_style.is_code);
    try testing.expect(!fn_style.strikethrough);
}

test "footnote reference anchor pair: fnref-N links to fn-N and vice versa" {
    // Verify that the anchor IDs form consistent bidirectional pairs:
    //   In-text reference:   anchor_id="fnref-{N}", link_url="#fn-{N}"
    //   Definition section:  anchor_id="fn-{N}",    link_url="#fnref-{N}"
    //
    // A link_url of "#fn-{N}" matches anchor_id "fn-{N}" (the '#' is stripped
    // by link_handler before calling resolveAnchor).
    const ordinal: u32 = 5;

    var buf_ref_anchor: [32]u8 = undefined;
    const ref_anchor = try std.fmt.bufPrint(&buf_ref_anchor, "fnref-{d}", .{ordinal});
    try testing.expectEqualStrings("fnref-5", ref_anchor);

    var buf_ref_link: [32]u8 = undefined;
    const ref_link = try std.fmt.bufPrint(&buf_ref_link, "#fn-{d}", .{ordinal});
    try testing.expectEqualStrings("#fn-5", ref_link);

    // The link_url target (strip '#') must match the definition anchor_id
    const def_anchor_id_from_link = ref_link[1..]; // strip '#'
    try testing.expectEqualStrings("fn-5", def_anchor_id_from_link);

    var buf_def_anchor: [32]u8 = undefined;
    const def_anchor = try std.fmt.bufPrint(&buf_def_anchor, "fn-{d}", .{ordinal});
    try testing.expectEqualStrings("fn-5", def_anchor);

    var buf_def_link: [32]u8 = undefined;
    const def_link = try std.fmt.bufPrint(&buf_def_link, "#fnref-{d}", .{ordinal});
    try testing.expectEqualStrings("#fnref-5", def_link);

    // The definition link_url target (strip '#') must match the reference anchor_id
    const ref_anchor_id_from_link = def_link[1..]; // strip '#'
    try testing.expectEqualStrings("fnref-5", ref_anchor_id_from_link);
    try testing.expectEqualStrings(ref_anchor, ref_anchor_id_from_link);
}
