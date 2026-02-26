const std = @import("std");
const Allocator = std.mem.Allocator;
const lt = @import("../layout/layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const detector = @import("detector.zig");
const dagre = @import("layout/dagre.zig");
const linear_layout = @import("layout/linear_layout.zig");
const FlowchartModel = @import("models/flowchart_model.zig").FlowchartModel;
const SequenceModel = @import("models/sequence_model.zig").SequenceModel;
const PieModel = @import("models/pie_model.zig").PieModel;
const GanttModel = @import("models/gantt_model.zig").GanttModel;

pub fn layoutMermaidBlock(
    allocator: Allocator,
    source: ?[]const u8,
    theme: *const Theme,
    fonts: *const Fonts,
    content_x: f32,
    content_width: f32,
    cursor_y: *f32,
    tree: *lt.LayoutTree,
) !void {
    const src = source orelse "";
    if (src.len == 0) return;

    const result = try detector.detect(allocator, src);

    switch (result) {
        .flowchart => |fc_val| {
            // We need a mutable copy since layout modifies the graph in-place
            var model_ptr = try allocator.create(FlowchartModel);
            model_ptr.* = fc_val;

            // Run layout algorithm
            const layout_result = try dagre.layout(
                allocator,
                &model_ptr.graph,
                fonts,
                theme,
                content_width,
            );

            const diagram_width = @min(layout_result.width, content_width);
            const diagram_height = layout_result.height;

            // Center diagram horizontally
            const diagram_x = content_x + (content_width - diagram_width) / 2;

            var node = lt.LayoutNode.init(allocator);
            node.kind = .mermaid_diagram;
            node.rect = .{
                .x = diagram_x,
                .y = cursor_y.*,
                .width = diagram_width,
                .height = diagram_height,
            };
            node.mermaid_flowchart = model_ptr;

            try tree.nodes.append(node);
            cursor_y.* += diagram_height + theme.paragraph_spacing;
        },
        .sequence => |seq_val| {
            const model_ptr = try allocator.create(SequenceModel);
            model_ptr.* = seq_val;

            const layout_result = try linear_layout.layout(
                allocator,
                model_ptr,
                fonts,
                theme,
                content_width,
            );

            const diagram_width = @min(layout_result.width, content_width);
            const diagram_height = layout_result.height;

            const diagram_x = content_x + (content_width - diagram_width) / 2;

            var node = lt.LayoutNode.init(allocator);
            node.kind = .mermaid_diagram;
            node.rect = .{
                .x = diagram_x,
                .y = cursor_y.*,
                .width = diagram_width,
                .height = diagram_height,
            };
            node.mermaid_sequence = model_ptr;

            try tree.nodes.append(node);
            cursor_y.* += diagram_height + theme.paragraph_spacing;
        },
        .pie => |pie_val| {
            const model_ptr = try allocator.create(PieModel);
            model_ptr.* = pie_val;

            // Pie layout: compute positions
            const pie_padding: f32 = 20;
            const title_space: f32 = if (model_ptr.title.len > 0) 35 else 0;
            const radius: f32 = @min(content_width * 0.25, 120);

            // Measure legend width
            var max_legend_w: f32 = 0;
            for (model_ptr.slices.items) |slice| {
                const measured = fonts.measure(slice.label, theme.body_font_size * 0.85, false, false, false);
                max_legend_w = @max(max_legend_w, measured.x + 30);
            }

            model_ptr.center_x = pie_padding + radius + 10;
            model_ptr.center_y = title_space + pie_padding + radius;
            model_ptr.radius = radius;

            // Compute slice angles (raylib uses degrees, 0 = right, going clockwise)
            var angle: f32 = 0;
            for (model_ptr.slices.items) |*slice| {
                slice.start_angle = angle;
                const sweep: f32 = @floatCast(slice.percentage / 100.0 * 360.0);
                slice.end_angle = angle + sweep;
                angle += sweep;
            }

            const diagram_width = @min(model_ptr.center_x + radius + 30 + max_legend_w + pie_padding, content_width);
            const diagram_height = title_space + pie_padding * 2 + radius * 2;

            const diagram_x = content_x + (content_width - diagram_width) / 2;

            var node = lt.LayoutNode.init(allocator);
            node.kind = .mermaid_diagram;
            node.rect = .{
                .x = diagram_x,
                .y = cursor_y.*,
                .width = diagram_width,
                .height = diagram_height,
            };
            node.mermaid_pie = model_ptr;

            try tree.nodes.append(node);
            cursor_y.* += diagram_height + theme.paragraph_spacing;
        },
        .gantt => |gantt_val| {
            const model_ptr = try allocator.create(GanttModel);
            model_ptr.* = gantt_val;

            // Gantt layout: compute positions
            const gantt_padding: f32 = 20;
            const title_space: f32 = if (model_ptr.title.len > 0) 30 else 0;
            const time_axis_h: f32 = 30;
            const row_h: f32 = 32;
            const section_header_h: f32 = 28;

            // Measure section label widths
            var label_width: f32 = 100;
            for (model_ptr.sections.items) |section| {
                const measured = fonts.measure(section.name, theme.body_font_size * 0.9, false, false, false);
                label_width = @max(label_width, measured.x + 20);
            }
            // Also measure task name widths
            for (model_ptr.tasks.items) |task| {
                const measured = fonts.measure(task.name, theme.body_font_size * 0.8, false, false, false);
                label_width = @max(label_width, measured.x + 20);
            }

            model_ptr.section_label_width = label_width;
            model_ptr.chart_x = label_width;
            model_ptr.chart_width = content_width - label_width - gantt_padding;

            // Compute total height
            var total_rows: f32 = 0;
            if (model_ptr.sections.items.len > 0) {
                for (0..model_ptr.sections.items.len) |sec_idx| {
                    total_rows += section_header_h;
                    for (model_ptr.tasks.items) |task| {
                        if (task.section_idx == sec_idx) {
                            total_rows += row_h;
                        }
                    }
                }
            } else {
                total_rows = @as(f32, @floatFromInt(model_ptr.tasks.items.len)) * row_h;
            }

            const diagram_height = title_space + time_axis_h + total_rows + gantt_padding;

            var node = lt.LayoutNode.init(allocator);
            node.kind = .mermaid_diagram;
            node.rect = .{
                .x = content_x,
                .y = cursor_y.*,
                .width = content_width,
                .height = diagram_height,
            };
            node.mermaid_gantt = model_ptr;

            try tree.nodes.append(node);
            cursor_y.* += diagram_height + theme.paragraph_spacing;
        },
        .unsupported => |diagram_type| {
            // Render placeholder text
            var node = lt.LayoutNode.init(allocator);
            node.kind = .text_block;

            const placeholder = "Unsupported diagram type";
            const measured = fonts.measure(placeholder, theme.body_font_size, false, false, false);
            _ = diagram_type;

            try node.text_runs.append(.{
                .text = placeholder,
                .style = .{
                    .font_size = theme.body_font_size,
                    .color = theme.blockquote_text,
                },
                .rect = .{
                    .x = content_x,
                    .y = cursor_y.*,
                    .width = measured.x,
                    .height = measured.y,
                },
            });

            node.rect = .{
                .x = content_x,
                .y = cursor_y.*,
                .width = content_width,
                .height = measured.y,
            };

            try tree.nodes.append(node);
            cursor_y.* += measured.y + theme.paragraph_spacing;
        },
    }
}
