const rl = @import("raylib");
const lt = @import("../layout/layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const block_renderer = @import("block_renderer.zig");
const table_renderer = @import("table_renderer.zig");
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

pub fn render(tree: *const lt.LayoutTree, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    const screen_h: f32 = @floatFromInt(rl.getScreenHeight());
    const view_top = scroll_y;
    const view_bottom = scroll_y + screen_h;

    for (tree.nodes.items) |*node| {
        // Frustum culling
        if (!node.rect.overlapsVertically(view_top, view_bottom)) continue;

        switch (node.kind) {
            .text_block, .heading => block_renderer.drawTextBlock(node, fonts, scroll_y),
            .code_block => block_renderer.drawCodeBlock(node, theme, fonts, scroll_y),
            .thematic_break => block_renderer.drawThematicBreak(node, theme, scroll_y),
            .block_quote_border => block_renderer.drawBlockQuoteBorder(node, theme, scroll_y),
            .table_row_bg => table_renderer.drawTableRowBg(node, scroll_y),
            .table_border => table_renderer.drawTableBorder(node, theme, scroll_y),
            .table_cell => table_renderer.drawTableCell(node, fonts, scroll_y),
            .image => block_renderer.drawImage(node, fonts, scroll_y),
            .mermaid_diagram => {
                if (node.mermaid_flowchart) |model| {
                    flowchart_renderer.drawFlowchart(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_sequence) |model| {
                    sequence_renderer.drawSequenceDiagram(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_pie) |model| {
                    pie_renderer.drawPieChart(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_gantt) |model| {
                    gantt_renderer.drawGanttChart(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_class) |model| {
                    class_renderer.drawClassDiagram(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_er) |model| {
                    er_renderer.drawERDiagram(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_state) |model| {
                    state_renderer.drawStateDiagram(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_mindmap) |model| {
                    mindmap_renderer.drawMindMap(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_gitgraph) |model| {
                    gitgraph_renderer.drawGitGraph(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_journey) |model| {
                    journey_renderer.drawJourney(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                } else if (node.mermaid_timeline) |model| {
                    timeline_renderer.drawTimeline(
                        model,
                        node.rect.x,
                        node.rect.y,
                        node.rect.width,
                        node.rect.height,
                        theme,
                        fonts,
                        scroll_y,
                    );
                }
            },
        }
    }

    // Draw scrollbar
    drawScrollbar(tree.total_height, scroll_y, screen_h, theme);
}

fn drawScrollbar(total_height: f32, scroll_y: f32, screen_h: f32, theme: *const Theme) void {
    if (total_height <= screen_h) return;

    const screen_w: f32 = @floatFromInt(rl.getScreenWidth());
    const bar_width: f32 = 8;
    const bar_x = screen_w - bar_width - 4;

    // Track
    rl.drawRectangleRec(
        .{ .x = bar_x, .y = 0, .width = bar_width, .height = screen_h },
        theme.scrollbar_track,
    );

    // Thumb
    const visible_ratio = screen_h / total_height;
    const thumb_height = @max(20, screen_h * visible_ratio);
    const scroll_ratio = scroll_y / (total_height - screen_h);
    const thumb_y = scroll_ratio * (screen_h - thumb_height);

    rl.drawRectangleRounded(
        .{ .x = bar_x, .y = thumb_y, .width = bar_width, .height = thumb_height },
        0.5,
        4,
        theme.scrollbar,
    );
}
