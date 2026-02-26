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
