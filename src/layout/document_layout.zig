const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");

const ast = @import("../parser/ast.zig");
const lt = @import("layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("text_measurer.zig").Fonts;
const table_layout = @import("table_layout.zig");
const code_block_layout = @import("code_block_layout.zig");
const mermaid_layout = @import("../mermaid/mermaid_layout.zig");
const ImageRenderer = @import("../render/image_renderer.zig").ImageRenderer;

pub const LayoutContext = struct {
    allocator: Allocator,
    theme: *const Theme,
    fonts: *const Fonts,
    content_width: f32,
    content_x: f32,
    cursor_y: f32,
    tree: *lt.LayoutTree,
    // List context
    list_depth: u8 = 0,
    list_type: ast.ListType = .bullet,
    list_item_index: u32 = 0,
    // Task list dimming
    dimmed: bool = false,
    // Footnote tracking
    seen_footnote: bool = false,
    footnote_index: u32 = 0,
    // Image renderer for loading textures
    image_renderer: ?*ImageRenderer = null,

    pub fn init(
        allocator: Allocator,
        theme: *const Theme,
        fonts: *const Fonts,
        window_width: f32,
        tree: *lt.LayoutTree,
    ) LayoutContext {
        const content_width = @min(
            theme.max_content_width,
            window_width - theme.page_margin * 2,
        );
        const content_x = (window_width - content_width) / 2.0;

        return .{
            .allocator = allocator,
            .theme = theme,
            .fonts = fonts,
            .content_width = content_width,
            .content_x = content_x,
            .cursor_y = theme.page_margin,
            .tree = tree,
        };
    }
};

fn layoutInlines(
    ctx: *LayoutContext,
    node: *const ast.Node,
    style: lt.TextStyle,
    layout_node: *lt.LayoutNode,
    cursor_x: *f32,
    line_height: *f32,
) !void {
    for (node.children.items) |*child| {
        switch (child.node_type) {
            .text => {
                if (child.literal) |text| {
                    try layoutTextRun(ctx, text, style, layout_node, cursor_x, line_height);
                }
            },
            .softbreak => {
                // Treat softbreak as a space
                try layoutTextRun(ctx, " ", style, layout_node, cursor_x, line_height);
            },
            .linebreak => {
                // Hard break: move to next line
                cursor_x.* = ctx.content_x;
                ctx.cursor_y += line_height.*;
            },
            .code => {
                if (child.literal) |text| {
                    var code_style = style;
                    code_style.is_code = true;
                    code_style.color = ctx.theme.code_text;
                    code_style.code_bg = ctx.theme.code_background;
                    try layoutTextRun(ctx, text, code_style, layout_node, cursor_x, line_height);
                }
            },
            .emph => {
                var em_style = style;
                em_style.italic = true;
                try layoutInlines(ctx, child, em_style, layout_node, cursor_x, line_height);
            },
            .strong => {
                var strong_style = style;
                strong_style.bold = true;
                try layoutInlines(ctx, child, strong_style, layout_node, cursor_x, line_height);
            },
            .strikethrough => {
                var st_style = style;
                st_style.strikethrough = true;
                try layoutInlines(ctx, child, st_style, layout_node, cursor_x, line_height);
            },
            .link => {
                var link_style = style;
                link_style.color = ctx.theme.link;
                link_style.underline = true;
                link_style.link_url = child.url;
                try layoutInlines(ctx, child, link_style, layout_node, cursor_x, line_height);
            },
            .footnote_reference => {
                // Render as superscript number
                if (child.literal) |ref_text| {
                    var fn_style = style;
                    fn_style.font_size = style.font_size * 0.7;
                    fn_style.color = ctx.theme.link;
                    // Wrap in brackets: [ref] — allocated in arena so it outlives the layout pass
                    const ref_str = try std.fmt.allocPrint(ctx.tree.arena.allocator(), "[{s}]", .{ref_text});
                    try layoutTextRun(ctx, ref_str, fn_style, layout_node, cursor_x, line_height);
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

                var img_node = lt.LayoutNode.init(ctx.allocator);
                errdefer img_node.deinit();
                img_node.kind = .image;

                // Try to load the texture
                var texture: ?rl.Texture2D = null;
                if (child.url) |url| {
                    if (ctx.image_renderer) |ir| {
                        texture = ir.getOrLoad(url);
                    }
                }

                var img_height: f32 = 80; // placeholder height
                if (texture) |tex| {
                    img_node.image_texture = tex;
                    // Scale to fit content width, preserving aspect ratio
                    const tex_w: f32 = @floatFromInt(tex.width);
                    const tex_h: f32 = @floatFromInt(tex.height);
                    if (tex_w > 0 and tex_h > 0) {
                        const scale = @min(1.0, ctx.content_width / tex_w);
                        img_height = tex_h * scale;
                    }
                }

                if (alt_parts.items.len > 0) {
                    img_node.image_alt = try std.mem.concat(arena_alloc, u8, alt_parts.items);
                }

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
            else => {
                // Recurse for any other inline types
                try layoutInlines(ctx, child, style, layout_node, cursor_x, line_height);
            },
        }
    }
}

fn layoutTextRun(
    ctx: *LayoutContext,
    text: []const u8,
    style: lt.TextStyle,
    layout_node: *lt.LayoutNode,
    cursor_x: *f32,
    line_height: *f32,
) !void {
    // Word wrap: split text at spaces and lay out word by word
    const max_x = ctx.content_x + ctx.content_width;
    var remaining = text;

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

        const run = lt.TextRun{
            .text = word,
            .style = style,
            .rect = .{
                .x = cursor_x.*,
                .y = ctx.cursor_y,
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
            for (node.children.items) |*child| {
                try layoutBlock(ctx, child);
            }
        },
        .heading => {
            ctx.cursor_y += ctx.theme.heading_spacing_above;

            var layout_node = lt.LayoutNode.init(ctx.allocator);
            errdefer layout_node.deinit();
            layout_node.kind = .heading;
            layout_node.heading_level = node.heading_level;

            const font_size = ctx.theme.headingSize(node.heading_level);
            const color = ctx.theme.headingColor(node.heading_level);
            const style = lt.TextStyle{
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
            var layout_node = lt.LayoutNode.init(ctx.allocator);
            errdefer layout_node.deinit();
            layout_node.kind = .text_block;

            const text_color = if (ctx.dimmed) blendColor(ctx.theme.text, ctx.theme.background, 0.5) else ctx.theme.text;
            const style = lt.TextStyle{
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
        .code_block => {
            const is_mermaid = if (node.fence_info) |info| std.mem.eql(u8, info, "mermaid") else false;

            if (is_mermaid) {
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
        },
        .thematic_break => {
            var layout_node = lt.LayoutNode.init(ctx.allocator);
            errdefer layout_node.deinit();
            layout_node.kind = .thematic_break;
            layout_node.hr_color = ctx.theme.hr_color;
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
            // Draw left border and indent content
            const saved_x = ctx.content_x;
            const saved_w = ctx.content_width;
            ctx.content_x += ctx.theme.blockquote_indent + 4; // 4px for border
            ctx.content_width -= ctx.theme.blockquote_indent + 4;

            const start_y = ctx.cursor_y;
            for (node.children.items) |*child| {
                try layoutBlock(ctx, child);
            }

            // Add border marker
            var border_node = lt.LayoutNode.init(ctx.allocator);
            errdefer border_node.deinit();
            border_node.kind = .block_quote_border;
            border_node.rect = .{
                .x = saved_x,
                .y = start_y,
                .width = 3,
                .height = ctx.cursor_y - start_y,
            };
            border_node.hr_color = ctx.theme.blockquote_border;
            try ctx.tree.nodes.append(border_node);

            ctx.content_x = saved_x;
            ctx.content_width = saved_w;
        },
        .table => {
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
            var marker_node = lt.LayoutNode.init(ctx.allocator);
            errdefer marker_node.deinit();
            marker_node.kind = .text_block;

            const is_dimmed = node.tasklist_checked orelse false;
            const marker_color = if (is_dimmed) blendColor(ctx.theme.text, ctx.theme.background, 0.5) else ctx.theme.text;
            const marker_style = lt.TextStyle{
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
            // Render footnote definitions at their natural position
            // Add a separator line before the first footnote
            if (!ctx.seen_footnote) {
                ctx.seen_footnote = true;
                ctx.cursor_y += ctx.theme.paragraph_spacing;

                // Thin separator line
                var sep_node = lt.LayoutNode.init(ctx.allocator);
                errdefer sep_node.deinit();
                sep_node.kind = .thematic_break;
                sep_node.hr_color = ctx.theme.hr_color;
                sep_node.rect = .{
                    .x = ctx.content_x,
                    .y = ctx.cursor_y,
                    .width = ctx.content_width * 0.3,
                    .height = 1,
                };
                try ctx.tree.nodes.append(sep_node);
                ctx.cursor_y += 12;
            }

            // Render as a small paragraph with footnote number prefix
            var layout_node = lt.LayoutNode.init(ctx.allocator);
            errdefer layout_node.deinit();
            layout_node.kind = .text_block;

            const small_size = ctx.theme.body_font_size * 0.85;
            const style = lt.TextStyle{
                .font_size = small_size,
                .color = ctx.theme.text,
            };

            var cursor_x = ctx.content_x;
            var lh: f32 = small_size * ctx.theme.line_height;
            const start_y = ctx.cursor_y;

            // Add footnote number prefix — arena-allocated to outlive layout pass
            ctx.footnote_index += 1;
            const fn_str = try std.fmt.allocPrint(ctx.tree.arena.allocator(), "{d}. ", .{ctx.footnote_index});
            const fn_m = ctx.fonts.measure(fn_str, small_size, false, false, false);
            try layout_node.text_runs.append(.{
                .text = fn_str,
                .style = style,
                .rect = .{ .x = cursor_x, .y = ctx.cursor_y, .width = fn_m.x, .height = fn_m.y },
            });
            cursor_x += fn_m.x;

            // Layout the footnote content
            for (node.children.items) |*child| {
                if (child.node_type == .paragraph) {
                    try layoutInlines(ctx, child, style, &layout_node, &cursor_x, &lh);
                }
            }

            layout_node.rect = .{
                .x = ctx.content_x,
                .y = start_y,
                .width = ctx.content_width,
                .height = (ctx.cursor_y - start_y) + lh,
            };

            try ctx.tree.nodes.append(layout_node);
            ctx.cursor_y = start_y + layout_node.rect.height + ctx.theme.paragraph_spacing * 0.5;
        },
        else => {
            // For unhandled block types, recurse into children
            for (node.children.items) |*child| {
                try layoutBlock(ctx, child);
            }
        },
    }
}

pub fn layout(
    allocator: Allocator,
    document: *const ast.Document,
    theme: *const Theme,
    fonts: *const Fonts,
    window_width: f32,
    image_renderer: ?*ImageRenderer,
) !lt.LayoutTree {
    var tree = lt.LayoutTree.init(allocator);
    errdefer tree.deinit();
    var ctx = LayoutContext.init(allocator, theme, fonts, window_width, &tree);
    ctx.image_renderer = image_renderer;

    try layoutBlock(&ctx, &document.root);

    tree.total_height = ctx.cursor_y + theme.page_margin;
    return tree;
}
