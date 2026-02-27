const std = @import("std");
const Allocator = std.mem.Allocator;
const layout_types = @import("../layout/layout_types.zig");
const Theme = @import("../theme/theme.zig").Theme;
const Fonts = @import("../layout/text_measurer.zig").Fonts;
const detector = @import("detector.zig");
const dagre = @import("layout/dagre.zig");
const linear_layout = @import("layout/linear_layout.zig");
const FlowchartModel = @import("models/flowchart_model.zig").FlowchartModel;
const SequenceModel = @import("models/sequence_model.zig").SequenceModel;
const PieModel = @import("models/pie_model.zig").PieModel;
const GanttModel = @import("models/gantt_model.zig").GanttModel;
const ClassModel = @import("models/class_model.zig").ClassModel;
const ERModel = @import("models/er_model.zig").ERModel;
const StateModel = @import("models/state_model.zig").StateModel;
const MindMapModel = @import("models/mindmap_model.zig").MindMapModel;
const GitGraphModel = @import("models/gitgraph_model.zig").GitGraphModel;
const JourneyModel = @import("models/journey_model.zig").JourneyModel;
const TimelineModel = @import("models/timeline_model.zig").TimelineModel;
const tree_layout = @import("layout/tree_layout.zig");

/// Create a LayoutNode for a diagram, set its rect, append to the tree, and advance the cursor.
/// Caller retains ownership of any heap-allocated model inside `data` on error —
/// only the node's text_runs list is cleaned up here.
fn appendDiagramNode(
    allocator: Allocator,
    data: layout_types.NodeData,
    x: f32,
    y: *f32,
    width: f32,
    height: f32,
    tree: *layout_types.LayoutTree,
    spacing: f32,
) !void {
    var node = layout_types.LayoutNode.init(allocator, data);
    errdefer node.text_runs.deinit();
    node.rect = .{ .x = x, .y = y.*, .width = width, .height = height };
    try tree.nodes.append(node);
    y.* += height + spacing;
}

pub fn layoutMermaidBlock(
    allocator: Allocator,
    source: ?[]const u8,
    theme: *const Theme,
    fonts: *const Fonts,
    content_x: f32,
    content_width: f32,
    cursor_y: *f32,
    tree: *layout_types.LayoutTree,
) !void {
    const src = source orelse "";
    if (src.len == 0) return;

    const result = try detector.detect(allocator, src);

    switch (result) {
        .flowchart => |fc_val| {
            // We need a mutable copy since layout modifies the graph in-place
            var model_ptr = try allocator.create(FlowchartModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = fc_val;

            // Run layout algorithm
            const layout_result = try dagre.layout(
                allocator,
                &model_ptr.graph,
                fonts,
                theme,
                content_width,
            );

            const scale = model_ptr.graph.scaleToFit(layout_result.width, content_width);
            const diagram_width = @min(layout_result.width, content_width);
            const diagram_height = layout_result.height * scale;

            const diagram_x = content_x + (content_width - diagram_width) / 2;
            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .flowchart = model_ptr } }, diagram_x, cursor_y, diagram_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .sequence => |seq_val| {
            const model_ptr = try allocator.create(SequenceModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = seq_val;

            const layout_result = try linear_layout.layout(
                allocator,
                model_ptr,
                fonts,
                theme,
                content_width,
            );

            const scale = model_ptr.scaleToFit(layout_result.width, content_width);
            const diagram_width = @min(layout_result.width, content_width);
            const diagram_height = layout_result.height * scale;

            const diagram_x = content_x + (content_width - diagram_width) / 2;
            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .sequence = model_ptr } }, diagram_x, cursor_y, diagram_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .pie => |pie_val| {
            const model_ptr = try allocator.create(PieModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
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
            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .pie = model_ptr } }, diagram_x, cursor_y, diagram_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .gantt => |gantt_val| {
            const model_ptr = try allocator.create(GanttModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
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

            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .gantt = model_ptr } }, content_x, cursor_y, content_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .class_diagram => |cls_val| {
            var model_ptr = try allocator.create(ClassModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = cls_val;

            // Pre-compute node sizes based on class content
            precomputeClassNodeSizes(model_ptr, fonts, theme);

            const layout_result = try dagre.layout(
                allocator,
                &model_ptr.graph,
                fonts,
                theme,
                content_width,
            );

            const scale = model_ptr.graph.scaleToFit(layout_result.width, content_width);
            const diagram_width = @min(layout_result.width, content_width);
            const diagram_height = layout_result.height * scale;
            const diagram_x = content_x + (content_width - diagram_width) / 2;
            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .class_diagram = model_ptr } }, diagram_x, cursor_y, diagram_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .er_diagram => |er_val| {
            var model_ptr = try allocator.create(ERModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = er_val;

            // Pre-compute node sizes based on entity content
            precomputeERNodeSizes(model_ptr, fonts, theme);

            const layout_result = try dagre.layout(
                allocator,
                &model_ptr.graph,
                fonts,
                theme,
                content_width,
            );

            const scale = model_ptr.graph.scaleToFit(layout_result.width, content_width);
            const diagram_width = @min(layout_result.width, content_width);
            const diagram_height = layout_result.height * scale;
            const diagram_x = content_x + (content_width - diagram_width) / 2;
            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .er = model_ptr } }, diagram_x, cursor_y, diagram_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .state_diagram => |st_val| {
            var model_ptr = try allocator.create(StateModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = st_val;

            const layout_result = try dagre.layout(
                allocator,
                &model_ptr.graph,
                fonts,
                theme,
                content_width,
            );

            const scale = model_ptr.graph.scaleToFit(layout_result.width, content_width);
            const diagram_width = @min(layout_result.width, content_width);
            const diagram_height = layout_result.height * scale;
            const diagram_x = content_x + (content_width - diagram_width) / 2;
            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .state = model_ptr } }, diagram_x, cursor_y, diagram_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .mindmap => |mm_val| {
            const model_ptr = try allocator.create(MindMapModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = mm_val;

            const layout_result = tree_layout.layout(model_ptr, fonts, theme, content_width);

            const scale = model_ptr.scaleToFit(layout_result.width, content_width);
            const diagram_width = @min(layout_result.width, content_width);
            const diagram_height = layout_result.height * scale;
            const diagram_x = content_x + (content_width - diagram_width) / 2;
            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .mindmap = model_ptr } }, diagram_x, cursor_y, diagram_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .gitgraph => |gg_val| {
            const model_ptr = try allocator.create(GitGraphModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = gg_val;

            // Compute layout dimensions
            const padding: f32 = 20;
            const branch_label_w: f32 = 80;
            const lane_spacing: f32 = 30;
            const commit_spacing: f32 = 50;

            const num_branches: f32 = @floatFromInt(@max(model_ptr.branches.items.len, @as(usize, 1)));
            const num_commits: f32 = @floatFromInt(@max(model_ptr.commits.items.len, @as(usize, 1)));

            const is_lr = model_ptr.orientation == .lr;

            const cols = if (is_lr) num_commits else num_branches;
            const rows = if (is_lr) num_branches else num_commits;
            const col_spacing = if (is_lr) commit_spacing else lane_spacing;
            const row_spacing = if (is_lr) lane_spacing else commit_spacing;

            const natural_width = padding * 2 + branch_label_w + cols * col_spacing + 40;
            const natural_height = padding * 2 + 20 + rows * row_spacing + 40;

            // Pre-compute commit positions
            const start_x = padding + branch_label_w;
            const start_y = padding + 20;
            for (model_ptr.commits.items) |*commit| {
                const seq_f: f32 = @floatFromInt(commit.seq);
                const lane_f: f32 = @floatFromInt(commit.lane);
                if (is_lr) {
                    commit.x = start_x + seq_f * commit_spacing;
                    commit.y = start_y + lane_f * lane_spacing;
                } else {
                    commit.x = start_x + lane_f * lane_spacing;
                    commit.y = start_y + seq_f * commit_spacing;
                }
            }

            const scale = if (natural_width > content_width and natural_width > 0) content_width / natural_width else 1.0;
            const diagram_width = @min(natural_width, content_width);
            const diagram_height = natural_height * scale;

            // Scale pre-computed positions
            if (scale < 1.0) {
                for (model_ptr.commits.items) |*commit| {
                    commit.x *= scale;
                    commit.y *= scale;
                }
            }

            // Store all effective layout values for the renderer
            model_ptr.effective_lane_spacing = lane_spacing * scale;
            model_ptr.effective_commit_spacing = commit_spacing * scale;
            model_ptr.effective_padding = padding * scale;
            model_ptr.effective_branch_label_w = branch_label_w * scale;
            model_ptr.effective_header_offset = 20 * scale;

            const diagram_x = content_x + (content_width - diagram_width) / 2;
            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .gitgraph = model_ptr } }, diagram_x, cursor_y, diagram_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .journey => |j_val| {
            const model_ptr = try allocator.create(JourneyModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = j_val;

            // Compute layout dimensions
            const padding: f32 = 20;
            const title_space: f32 = if (model_ptr.title.len > 0) 35 else 0;
            const task_h: f32 = 50;
            const section_header_h: f32 = 30;
            const actor_h: f32 = 15;

            var total_height: f32 = padding + title_space;
            for (model_ptr.sections.items) |section| {
                total_height += section_header_h + padding;
                total_height += task_h + 30;
                // Actors
                var max_actors: usize = 0;
                for (section.tasks.items) |task| {
                    max_actors = @max(max_actors, task.actors.items.len);
                }
                if (max_actors > 0) {
                    total_height += @as(f32, @floatFromInt(max_actors)) * actor_h;
                }
            }
            total_height += padding;

            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .journey = model_ptr } }, content_x, cursor_y, content_width, total_height, tree, theme.paragraph_spacing);
        },
        .timeline => |tl_val| {
            const model_ptr = try allocator.create(TimelineModel);
            errdefer {
                model_ptr.deinit();
                allocator.destroy(model_ptr);
            }
            model_ptr.* = tl_val;

            // Compute layout dimensions
            const padding: f32 = 20;
            const title_space: f32 = if (model_ptr.title.len > 0) 35 else 0;
            const axis_offset: f32 = 80;
            const event_h: f32 = 24;
            const event_spacing: f32 = 6;

            // Find max events in any period
            var max_events: usize = 0;
            for (model_ptr.sections.items) |section| {
                for (section.periods.items) |period| {
                    max_events = @max(max_events, period.events.items.len);
                }
            }

            const events_above = @as(f32, @floatFromInt((max_events + 1) / 2));
            const events_below = @as(f32, @floatFromInt(max_events / 2));
            const space_above = events_above * (event_h + event_spacing) + 20;
            const space_below = events_below * (event_h + event_spacing) + 40;

            const diagram_height = padding * 2 + title_space + axis_offset + space_above + space_below;

            try appendDiagramNode(allocator, .{ .mermaid_diagram = .{ .timeline = model_ptr } }, content_x, cursor_y, content_width, diagram_height, tree, theme.paragraph_spacing);
        },
        .unsupported => {
            // Render placeholder text
            var node = layout_types.LayoutNode.init(allocator, .text_block);
            errdefer node.deinit();

            const placeholder = "Unsupported diagram type";
            const measured = fonts.measure(placeholder, theme.body_font_size, false, false, false);

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

fn precomputeClassNodeSizes(model: *ClassModel, fonts: *const Fonts, theme: *const Theme) void {
    const font_size = theme.body_font_size * 0.85;
    const line_h: f32 = font_size + 4;
    const section_pad: f32 = 4;
    const min_width: f32 = 100;

    for (model.classes.items) |cls| {
        // Compute width from class name and member names
        var max_w: f32 = fonts.measure(cls.label, font_size, false, false, false).x;
        if (cls.annotation) |ann| {
            const ann_w = fonts.measure(ann, font_size * 0.85, false, false, false).x;
            max_w = @max(max_w, ann_w);
        }
        for (cls.members.items) |member| {
            const m_w = fonts.measure(member.name, font_size * 0.9, false, false, false).x + 20; // visibility prefix
            max_w = @max(max_w, m_w);
        }
        const width = @max(min_width, max_w + 30);

        // Compute height: header + divider + attrs + divider + methods
        var height: f32 = section_pad; // top padding
        if (cls.annotation != null) height += line_h;
        height += line_h + section_pad; // class name + padding
        height += section_pad + 1; // divider

        var attr_count: f32 = 0;
        var method_count: f32 = 0;
        for (cls.members.items) |member| {
            if (member.is_method) {
                method_count += 1;
            } else {
                attr_count += 1;
            }
        }
        height += @max(1, attr_count) * line_h;
        height += section_pad + 1 + section_pad; // divider
        height += @max(1, method_count) * line_h;
        height += section_pad; // bottom padding

        // Set on the graph node
        if (model.graph.nodes.getPtr(cls.id)) |gnode| {
            gnode.width = width;
            gnode.height = height;
        }
    }
}

fn precomputeERNodeSizes(model: *ERModel, fonts: *const Fonts, theme: *const Theme) void {
    const font_size = theme.body_font_size * 0.85;
    const header_h: f32 = font_size + 10;
    const row_h: f32 = font_size + 6;
    const min_width: f32 = 100;

    for (model.entities.items) |entity| {
        // Width from entity name and attribute text
        var max_w: f32 = fonts.measure(entity.name, font_size, false, false, false).x;
        for (entity.attributes.items) |attr| {
            const type_w = fonts.measure(attr.attr_type, font_size * 0.8, false, false, false).x;
            const name_w = fonts.measure(attr.name, font_size * 0.8, false, false, false).x;
            const row_w: f32 = 30 + type_w + 6 + name_w + 10; // key prefix + type + gap + name + padding
            max_w = @max(max_w, row_w);
        }
        const width = @max(min_width, max_w + 20);

        // Height: header + attribute rows
        const attr_h: f32 = @as(f32, @floatFromInt(@max(entity.attributes.items.len, @as(usize, 1)))) * row_h;
        const height = header_h + attr_h + 4;

        if (model.graph.nodes.getPtr(entity.name)) |gnode| {
            gnode.width = width;
            gnode.height = height;
        }
    }
}
