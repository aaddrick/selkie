const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");
const ast = @import("../parser/ast.zig");
const lt = @import("layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("text_measurer.zig").Fonts;

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

    pub fn init(
        allocator: Allocator,
        theme: *const Theme,
        fonts: *const Fonts,
        window_width: f32,
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
            .tree = undefined,
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
                try layoutInlines(ctx, child, link_style, layout_node, cursor_x, line_height);
            },
            .image => {
                // For now, render alt text
                try layoutInlines(ctx, child, style, layout_node, cursor_x, line_height);
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

        if (measured.y > line_height.*) {
            line_height.* = measured.y;
        }

        cursor_x.* += measured.x;
        remaining = remaining[chunk_end..];
    }
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
            if (layout_node.text_runs.items.len > 0) {
                const last_run = layout_node.text_runs.items[layout_node.text_runs.items.len - 1];
                const actual_bottom = last_run.rect.y + last_run.rect.height;
                layout_node.rect.height = actual_bottom - ctx.cursor_y;
            }

            try ctx.tree.nodes.append(layout_node);
            ctx.cursor_y += layout_node.rect.height + ctx.theme.heading_spacing_below;
        },
        .paragraph => {
            var layout_node = lt.LayoutNode.init(ctx.allocator);
            layout_node.kind = .text_block;

            const style = lt.TextStyle{
                .font_size = ctx.theme.body_font_size,
                .color = ctx.theme.text,
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
            var layout_node = lt.LayoutNode.init(ctx.allocator);
            layout_node.kind = .code_block;
            layout_node.code_text = node.literal;
            layout_node.code_bg_color = ctx.theme.code_background;

            // Measure code block height
            const code_text = node.literal orelse "";
            var line_count: f32 = 1;
            for (code_text) |ch| {
                if (ch == '\n') line_count += 1;
            }
            const code_height = line_count * ctx.theme.mono_font_size * ctx.theme.line_height;
            const total_height = code_height + ctx.theme.code_block_padding * 2;

            layout_node.rect = .{
                .x = ctx.content_x,
                .y = ctx.cursor_y,
                .width = ctx.content_width,
                .height = total_height,
            };

            try ctx.tree.nodes.append(layout_node);
            ctx.cursor_y += total_height + ctx.theme.paragraph_spacing;
        },
        .thematic_break => {
            var layout_node = lt.LayoutNode.init(ctx.allocator);
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

            // Add bullet/number marker
            var marker_node = lt.LayoutNode.init(ctx.allocator);
            marker_node.kind = .text_block;

            const marker_style = lt.TextStyle{
                .font_size = ctx.theme.body_font_size,
                .color = ctx.theme.text,
            };

            if (ctx.list_type == .ordered) {
                // Ordered list: render number prefix
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}. ", .{ctx.list_item_index}) catch "? ";
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

            for (node.children.items) |*child| {
                try layoutBlock(ctx, child);
            }

            ctx.content_x = saved_x;
            ctx.content_width = saved_w;
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
) !lt.LayoutTree {
    var tree = lt.LayoutTree.init(allocator);
    var ctx = LayoutContext.init(allocator, theme, fonts, window_width);
    ctx.tree = &tree;

    try layoutBlock(&ctx, &document.root);

    tree.total_height = ctx.cursor_y + theme.page_margin;
    return tree;
}
