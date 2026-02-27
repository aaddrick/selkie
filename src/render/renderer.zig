const rl = @import("raylib");
const LayoutTree = @import("../layout/layout_types.zig").LayoutTree;
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const scrollbar = @import("scrollbar.zig");
const gutter_renderer = @import("gutter_renderer.zig");
const block_renderer = @import("block_renderer.zig");
const table_renderer = @import("table_renderer.zig");
const text_renderer = @import("text_renderer.zig");
const image_renderer = @import("image_renderer.zig");
const flowchart_renderer = @import("../mermaid/renderers/flowchart_renderer.zig");
const sequence_renderer = @import("../mermaid/renderers/sequence_renderer.zig");
const pie_renderer = @import("../mermaid/renderers/pie_renderer.zig");
const gantt_renderer = @import("../mermaid/renderers/gantt_renderer.zig");
const class_renderer = @import("../mermaid/renderers/class_renderer.zig");
const er_renderer = @import("../mermaid/renderers/er_renderer.zig");
const state_renderer = @import("../mermaid/renderers/state_renderer.zig");
const mindmap_renderer = @import("../mermaid/renderers/mindmap_renderer.zig");
const gitgraph_renderer = @import("../mermaid/renderers/gitgraph_renderer.zig");
const journey_renderer = @import("../mermaid/renderers/journey_renderer.zig");
const timeline_renderer = @import("../mermaid/renderers/timeline_renderer.zig");

/// Render the document layout tree with frustum culling and scrollbar.
/// `content_top_y` offsets the scissor clip region so content does not
/// draw over the menu bar or tab bar area.
/// `left_offset` shifts the content area to the right (e.g., for a sidebar).
pub fn render(tree: *const LayoutTree, theme: *const Theme, fonts: *const Fonts, scroll_y: f32, content_top_y: f32, left_offset: f32, hovered_url: ?[]const u8) void {
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const view_top = scroll_y;
    const view_bottom = scroll_y + screen_h;

    // Clip rendering to below chrome and right of sidebar
    rl.beginScissorMode(
        @intFromFloat(left_offset),
        @intFromFloat(content_top_y),
        @intFromFloat(screen_w - left_offset),
        @intFromFloat(screen_h - content_top_y),
    );
    defer rl.endScissorMode();

    const hover: ?text_renderer.LinkHoverState = if (hovered_url) |url|
        .{ .hovered_url = url, .link_hover_color = theme.link_hover }
    else
        null;

    for (tree.nodes.items) |*node| {
        // Frustum culling
        if (!node.rect.overlapsVertically(view_top, view_bottom)) continue;

        switch (node.data) {
            .text_block, .heading => block_renderer.drawTextBlock(node, fonts, scroll_y, hover),
            .code_block => block_renderer.drawCodeBlock(node, theme, fonts, scroll_y),
            .thematic_break => block_renderer.drawThematicBreak(node, scroll_y),
            .block_quote_border => block_renderer.drawBlockQuoteBorder(node, scroll_y),
            .table_row_bg => table_renderer.drawTableRowBg(node, scroll_y),
            .table_border => table_renderer.drawTableBorder(node, scroll_y),
            .table_cell => table_renderer.drawTableCell(node, fonts, scroll_y, hover),
            .image => block_renderer.drawImage(node, fonts, scroll_y),
            .mermaid_diagram => |mermaid| {
                const r = node.rect;
                switch (mermaid) {
                    .flowchart => |model| flowchart_renderer.drawFlowchart(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .sequence => |model| sequence_renderer.drawSequenceDiagram(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .pie => |model| pie_renderer.drawPieChart(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .gantt => |model| gantt_renderer.drawGanttChart(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .class_diagram => |model| class_renderer.drawClassDiagram(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .er => |model| er_renderer.drawERDiagram(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .state => |model| state_renderer.drawStateDiagram(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .mindmap => |model| mindmap_renderer.drawMindMap(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .gitgraph => |model| gitgraph_renderer.drawGitGraph(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .journey => |model| journey_renderer.drawJourney(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                    .timeline => |model| timeline_renderer.drawTimeline(model, r.x, r.y, r.width, r.height, theme, fonts, scroll_y),
                }
            },
        }
    }

    // Draw source line number gutter (if enabled)
    gutter_renderer.drawGutter(tree, theme, fonts, scroll_y, content_top_y, left_offset);

    // Draw scrollbar (starts below chrome, right-aligned)
    drawScrollbar(tree.total_height, scroll_y, screen_h, content_top_y, theme);
}

fn drawScrollbar(total_height: f32, scroll_y: f32, screen_h: f32, content_top_y: f32, theme: *const Theme) void {
    const geo = scrollbar.compute(total_height, scroll_y, screen_h, content_top_y);
    if (!geo.visible) return;

    // Track
    rl.drawRectangleRec(
        .{ .x = geo.bar_x, .y = geo.track_y, .width = geo.bar_width, .height = geo.track_height },
        theme.scrollbar_track,
    );

    // Thumb
    rl.drawRectangleRounded(
        .{ .x = geo.bar_x, .y = geo.thumb_y, .width = geo.bar_width, .height = geo.thumb_height },
        0.5,
        4,
        theme.scrollbar,
    );
}
