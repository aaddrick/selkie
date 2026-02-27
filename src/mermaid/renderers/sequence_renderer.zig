const rl = @import("raylib");
const std = @import("std");
const sm = @import("../models/sequence_model.zig");
const SequenceModel = sm.SequenceModel;
const ArrowType = sm.ArrowType;
const Event = sm.Event;
const BlockSection = sm.BlockSection;
const Theme = @import("../../theme/theme.zig").Theme;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const ru = @import("../render_utils.zig");
const shapes = @import("shapes.zig");

pub fn drawSequenceDiagram(
    model: *const SequenceModel,
    origin_x: f32,
    origin_y: f32,
    diagram_width: f32,
    diagram_height: f32,
    theme: *const Theme,
    fonts: *const Fonts,
    scroll_y: f32,
) void {
    // 1. Background
    rl.drawRectangleRec(.{
        .x = origin_x,
        .y = origin_y - scroll_y,
        .width = diagram_width,
        .height = diagram_height,
    }, theme.mermaid_subgraph_bg);

    // 2. Block backgrounds
    drawBlockBackgrounds(model, &model.events, origin_x, origin_y, theme, fonts, scroll_y);

    // 3. Dashed vertical lifelines
    const max_box_height = blk: {
        var max_h: f32 = 0;
        for (model.participants.items) |p| {
            max_h = @max(max_h, p.box_height);
        }
        break :blk max_h;
    };
    const lifeline_top = origin_y + 20 + max_box_height;
    const lifeline_bottom = origin_y + model.lifeline_end_y;

    for (model.participants.items) |p| {
        ru.drawDashedLine(
            origin_x + p.center_x,
            lifeline_top - scroll_y,
            origin_x + p.center_x,
            lifeline_bottom - scroll_y,
            1,
            theme.mermaid_edge,
        );
    }

    // 4. Activation bars
    for (model.activation_spans.items) |span| {
        if (model.findParticipant(span.participant_id)) |p| {
            const bar_width: f32 = 12;
            const offset: f32 = @as(f32, @floatFromInt(span.depth)) * 4;
            const bx = origin_x + p.center_x - bar_width / 2 + offset;
            const by = origin_y + span.y_start - scroll_y;
            const bh = if (span.y_end > span.y_start) span.y_end - span.y_start else 20;

            rl.drawRectangleRec(.{
                .x = bx,
                .y = by,
                .width = bar_width,
                .height = bh,
            }, theme.mermaid_node_fill);
            rl.drawRectangleLinesEx(.{
                .x = bx,
                .y = by,
                .width = bar_width,
                .height = bh,
            }, 1, theme.mermaid_node_border);
        }
    }

    // 5. Messages (arrows)
    var msg_num: u32 = 0;
    drawMessages(model, &model.events, origin_x, origin_y, theme, fonts, scroll_y, &msg_num);

    // 6. Notes
    drawNotes(&model.events, origin_x, origin_y, theme, fonts, scroll_y);

    // 7. Participant boxes (top)
    drawParticipantBoxes(model, origin_x, origin_y + 20, theme, fonts, scroll_y);

    // 8. Participant boxes (bottom)
    drawParticipantBoxes(model, origin_x, origin_y + model.lifeline_end_y, theme, fonts, scroll_y);
}

fn drawParticipantBoxes(model: *const SequenceModel, origin_x: f32, y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    for (model.participants.items) |p| {
        const bx = origin_x + p.center_x - p.box_width / 2;
        const by = y;

        if (p.kind == .actor) {
            drawStickFigure(origin_x + p.center_x, by, p.box_height, theme, fonts, p.alias, scroll_y);
        } else {
            rl.drawRectangleRec(.{
                .x = bx,
                .y = by - scroll_y,
                .width = p.box_width,
                .height = p.box_height,
            }, theme.mermaid_node_fill);
            rl.drawRectangleLinesEx(.{
                .x = bx,
                .y = by - scroll_y,
                .width = p.box_width,
                .height = p.box_height,
            }, 2, theme.mermaid_node_border);

            shapes.drawTextCentered(
                p.alias,
                bx,
                by,
                p.box_width,
                p.box_height,
                fonts,
                theme.body_font_size,
                theme.mermaid_node_text,
                scroll_y,
            );
        }
    }
}

fn drawStickFigure(cx: f32, y: f32, _: f32, theme: *const Theme, fonts: *const Fonts, alias: []const u8, scroll_y: f32) void {
    const color = theme.mermaid_node_border;
    const sy = y - scroll_y;

    // Head
    const head_r: f32 = 10;
    const head_cy = sy + head_r + 2;
    rl.drawCircleLinesV(.{ .x = cx, .y = head_cy }, head_r, color);

    // Body
    const body_top = head_cy + head_r;
    const body_bottom = body_top + 20;
    rl.drawLineEx(.{ .x = cx, .y = body_top }, .{ .x = cx, .y = body_bottom }, 2, color);

    // Arms
    const arm_y = body_top + 8;
    rl.drawLineEx(.{ .x = cx - 15, .y = arm_y }, .{ .x = cx + 15, .y = arm_y }, 2, color);

    // Legs
    rl.drawLineEx(.{ .x = cx, .y = body_bottom }, .{ .x = cx - 12, .y = body_bottom + 15 }, 2, color);
    rl.drawLineEx(.{ .x = cx, .y = body_bottom }, .{ .x = cx + 12, .y = body_bottom + 15 }, 2, color);

    // Label below
    const measured = fonts.measure(alias, theme.body_font_size * 0.85, false, false, false);
    const tx = cx - measured.x / 2;
    const ty = body_bottom + 17;

    var buf: [256]u8 = undefined;
    const len = @min(alias.len, buf.len - 1);
    @memcpy(buf[0..len], alias[0..len]);
    buf[len] = 0;
    const z: [:0]const u8 = buf[0..len :0];

    const font = fonts.selectFont(.{});
    const font_size = theme.body_font_size * 0.85;
    const spacing = font_size / 10.0;
    rl.drawTextEx(font, z, .{ .x = tx, .y = ty }, font_size, spacing, theme.mermaid_node_text);
}

fn drawMessages(model: *const SequenceModel, events: *const std.ArrayList(Event), origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32, msg_num: *u32) void {
    for (events.items) |event| {
        switch (event) {
            .message => |msg| {
                const from_p = model.findParticipant(msg.from) orelse continue;
                const to_p = model.findParticipant(msg.to) orelse continue;

                const from_x = origin_x + from_p.center_x;
                const to_x = origin_x + to_p.center_x;
                const y = origin_y + msg.y - scroll_y;

                const is_self = std.mem.eql(u8, msg.from, msg.to);

                if (is_self) {
                    // Self-message: loop to the right and back
                    const loop_w: f32 = 40;
                    const loop_h: f32 = 25;
                    const is_dotted = isDottedArrow(msg.arrow_type);
                    const color = theme.mermaid_edge;

                    if (is_dotted) {
                        ru.drawDashedLine(from_x, y, from_x + loop_w, y, 1.5, color);
                        ru.drawDashedLine(from_x + loop_w, y, from_x + loop_w, y + loop_h, 1.5, color);
                        ru.drawDashedLine(from_x + loop_w, y + loop_h, from_x, y + loop_h, 1.5, color);
                    } else {
                        rl.drawLineEx(.{ .x = from_x, .y = y }, .{ .x = from_x + loop_w, .y = y }, 1.5, color);
                        rl.drawLineEx(.{ .x = from_x + loop_w, .y = y }, .{ .x = from_x + loop_w, .y = y + loop_h }, 1.5, color);
                        rl.drawLineEx(.{ .x = from_x + loop_w, .y = y + loop_h }, .{ .x = from_x, .y = y + loop_h }, 1.5, color);
                    }

                    // Arrowhead at end
                    drawArrowHead(msg.arrow_type, from_x, y + loop_h, from_x + loop_w, y + loop_h, theme.mermaid_edge);

                    // Label
                    if (msg.text.len > 0) {
                        drawMessageLabel(msg.text, from_x + loop_w + 5, y + loop_h / 2, fonts, theme, msg_num, model.autonumber);
                    }
                } else {
                    // Normal message
                    const is_dotted = isDottedArrow(msg.arrow_type);
                    const color = theme.mermaid_edge;

                    if (is_dotted) {
                        ru.drawDashedLine(from_x, y, to_x, y, 1.5, color);
                    } else {
                        rl.drawLineEx(.{ .x = from_x, .y = y }, .{ .x = to_x, .y = y }, 1.5, color);
                    }

                    // Arrowhead
                    drawArrowHead(msg.arrow_type, to_x, y, from_x, y, theme.mermaid_edge);

                    // Bidirectional: also draw arrow at from end
                    if (msg.arrow_type == .bidir_solid or msg.arrow_type == .bidir_dotted) {
                        drawArrowHead(msg.arrow_type, from_x, y, to_x, y, theme.mermaid_edge);
                    }

                    // Label centered above the line
                    if (msg.text.len > 0) {
                        const mid_x = (from_x + to_x) / 2;
                        drawMessageLabel(msg.text, mid_x, y - 18, fonts, theme, msg_num, model.autonumber);
                    }
                }

                if (model.autonumber) {
                    msg_num.* += 1;
                }
            },
            .block => |blk| {
                for (blk.sections.items) |section| {
                    drawMessages(model, &section.events, origin_x, origin_y, theme, fonts, scroll_y, msg_num);
                }
            },
            .note, .activation => {},
        }
    }
}

fn drawMessageLabel(text: []const u8, x: f32, y: f32, fonts: *const Fonts, theme: *const Theme, msg_num: *u32, autonumber: bool) void {
    const font_size = theme.body_font_size * 0.8;

    var buf: [512]u8 = undefined;
    var label_len: usize = 0;

    // Prepend number if autonumber
    if (autonumber) {
        const num_str = std.fmt.bufPrint(buf[0..20], "{d}. ", .{msg_num.* + 1}) catch "";
        label_len = num_str.len;
    }

    const copy_len = @min(text.len, buf.len - label_len - 1);
    @memcpy(buf[label_len .. label_len + copy_len], text[0..copy_len]);
    label_len += copy_len;
    buf[label_len] = 0;
    const z: [:0]const u8 = buf[0..label_len :0];

    const measured = fonts.measure(z, font_size, false, false, false);

    // Background
    const bg_x = x - measured.x / 2 - 3;
    const bg_y = y - measured.y / 2 - 1;
    rl.drawRectangleRec(.{
        .x = bg_x,
        .y = bg_y,
        .width = measured.x + 6,
        .height = measured.y + 2,
    }, theme.mermaid_label_bg);

    const font = fonts.selectFont(.{});
    const spacing = font_size / 10.0;
    rl.drawTextEx(font, z, .{
        .x = x - measured.x / 2,
        .y = y - measured.y / 2,
    }, font_size, spacing, theme.mermaid_edge_text);
}

fn drawNotes(events: *const std.ArrayList(Event), origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    for (events.items) |event| {
        switch (event) {
            .note => |note| {
                const nx = origin_x + note.x;
                const ny = origin_y + note.y - scroll_y;

                // Yellow-ish note background
                const note_bg = rl.Color{ .r = 255, .g = 255, .b = 204, .a = 230 };
                const note_border = rl.Color{ .r = 180, .g = 180, .b = 100, .a = 255 };

                rl.drawRectangleRec(.{
                    .x = nx,
                    .y = ny,
                    .width = note.width,
                    .height = note.height,
                }, note_bg);
                rl.drawRectangleLinesEx(.{
                    .x = nx,
                    .y = ny,
                    .width = note.width,
                    .height = note.height,
                }, 1, note_border);

                // Dog-ear (folded corner)
                const fold: f32 = 8;
                const fx = nx + note.width - fold;
                const fy = ny;
                rl.drawTriangle(
                    .{ .x = fx, .y = fy },
                    .{ .x = fx, .y = fy + fold },
                    .{ .x = fx + fold, .y = fy + fold },
                    note_border,
                );

                // Text
                shapes.drawTextCentered(
                    note.text,
                    nx,
                    origin_y + note.y,
                    note.width,
                    note.height,
                    fonts,
                    theme.body_font_size * 0.85,
                    theme.mermaid_node_text,
                    scroll_y,
                );
            },
            .block => |blk| {
                for (blk.sections.items) |section| {
                    drawNotes(&section.events, origin_x, origin_y, theme, fonts, scroll_y);
                }
            },
            .message, .activation => {},
        }
    }
}

fn drawBlockBackgrounds(model: *const SequenceModel, events: *const std.ArrayList(Event), origin_x: f32, origin_y: f32, theme: *const Theme, fonts: *const Fonts, scroll_y: f32) void {
    for (events.items) |event| {
        switch (event) {
            .block => |blk| {
                const bx = origin_x + blk.x;
                const by = origin_y + blk.y - scroll_y;

                // Block background
                const block_bg = rl.Color{
                    .r = @min(255, @as(u16, theme.mermaid_subgraph_bg.r) + 8),
                    .g = @min(255, @as(u16, theme.mermaid_subgraph_bg.g) + 8),
                    .b = @min(255, @as(u16, theme.mermaid_subgraph_bg.b) + 8),
                    .a = 180,
                };
                rl.drawRectangleRec(.{
                    .x = bx,
                    .y = by,
                    .width = blk.width,
                    .height = blk.height,
                }, block_bg);
                rl.drawRectangleLinesEx(.{
                    .x = bx,
                    .y = by,
                    .width = blk.width,
                    .height = blk.height,
                }, 1, theme.mermaid_node_border);

                // Label tab
                const label_text = blockTypeLabel(blk.block_type);
                const measured = fonts.measure(label_text, theme.body_font_size * 0.75, false, false, false);
                const tab_w = measured.x + 16;
                const tab_h: f32 = 20;

                rl.drawRectangleRec(.{
                    .x = bx,
                    .y = by,
                    .width = tab_w,
                    .height = tab_h,
                }, theme.mermaid_node_border);

                // Label text in tab
                var buf: [64]u8 = undefined;
                const len = @min(label_text.len, buf.len - 1);
                @memcpy(buf[0..len], label_text[0..len]);
                buf[len] = 0;
                const z: [:0]const u8 = buf[0..len :0];

                const font = fonts.selectFont(.{ .bold = true });
                const font_size = theme.body_font_size * 0.75;
                const spacing = font_size / 10.0;
                rl.drawTextEx(font, z, .{
                    .x = bx + 4,
                    .y = by + 2,
                }, font_size, spacing, theme.mermaid_label_bg);

                // Block condition/label next to tab
                if (blk.label.len > 0) {
                    var lbuf: [256]u8 = undefined;
                    const llen = @min(blk.label.len, lbuf.len - 1);
                    @memcpy(lbuf[0..llen], blk.label[0..llen]);
                    lbuf[llen] = 0;
                    const lz: [:0]const u8 = lbuf[0..llen :0];

                    const lfont = fonts.selectFont(.{});
                    rl.drawTextEx(lfont, lz, .{
                        .x = bx + tab_w + 8,
                        .y = by + 3,
                    }, font_size, spacing, theme.mermaid_edge_text);
                }

                // Section dividers (for alt/else, par/and)
                if (blk.sections.items.len > 1) {
                    var section_y = origin_y + blk.y;
                    // Skip the first section; draw dividers between sections
                    for (blk.sections.items, 0..) |section, idx| {
                        if (idx == 0) {
                            // Approximate where first section ends
                            section_y += estimateSectionHeight(model, &section);
                            continue;
                        }

                        // Dashed horizontal divider
                        ru.drawDashedLine(
                            bx,
                            section_y - scroll_y,
                            bx + blk.width,
                            section_y - scroll_y,
                            1,
                            theme.mermaid_node_border,
                        );

                        // Section label
                        if (section.label.len > 0) {
                            var sbuf: [256]u8 = undefined;
                            const slen = @min(section.label.len, sbuf.len - 1);
                            @memcpy(sbuf[0..slen], section.label[0..slen]);
                            sbuf[slen] = 0;
                            const sz: [:0]const u8 = sbuf[0..slen :0];

                            const sfont = fonts.selectFont(.{});
                            rl.drawTextEx(sfont, sz, .{
                                .x = bx + 8,
                                .y = section_y - scroll_y + 2,
                            }, font_size, spacing, theme.mermaid_edge_text);
                        }

                        section_y += estimateSectionHeight(model, &section);
                    }
                }

                // Recurse into section events
                for (blk.sections.items) |section| {
                    drawBlockBackgrounds(model, &section.events, origin_x, origin_y, theme, fonts, scroll_y);
                }
            },
            .message, .note, .activation => {},
        }
    }
}

fn estimateSectionHeight(_: *const SequenceModel, section: *const BlockSection) f32 {
    var h: f32 = 24; // label height
    for (section.events.items) |event| {
        switch (event) {
            .message => |msg| {
                if (std.mem.eql(u8, msg.from, msg.to)) {
                    h += 70; // self-message
                } else {
                    h += 40; // normal message
                }
            },
            .note => |note| {
                h += note.height + 10;
            },
            .block => |blk| {
                h += blk.height;
            },
            .activation => {},
        }
    }
    h += 10; // section divider step
    return h;
}

fn isDottedArrow(arrow: ArrowType) bool {
    return switch (arrow) {
        .dotted, .dotted_arrow, .dotted_cross, .dotted_open, .bidir_dotted => true,
        else => false,
    };
}

fn drawArrowHead(arrow_type: ArrowType, tip_x: f32, tip_y: f32, from_x: f32, from_y: f32, color: rl.Color) void {
    const dx = tip_x - from_x;
    const dy = tip_y - from_y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;

    const nx = dx / len;
    const ny = dy / len;
    const arrow_size: f32 = 10;

    switch (arrow_type) {
        .solid_cross, .dotted_cross => {
            // X at the tip
            rl.drawLineEx(
                .{ .x = tip_x - 5, .y = tip_y - 5 },
                .{ .x = tip_x + 5, .y = tip_y + 5 },
                2,
                color,
            );
            rl.drawLineEx(
                .{ .x = tip_x - 5, .y = tip_y + 5 },
                .{ .x = tip_x + 5, .y = tip_y - 5 },
                2,
                color,
            );
        },
        .solid_open, .dotted_open => {
            // Open arrowhead (just two lines, no fill)
            const p1x = tip_x - arrow_size * nx + arrow_size * 0.4 * ny;
            const p1y = tip_y - arrow_size * ny - arrow_size * 0.4 * nx;
            const p2x = tip_x - arrow_size * nx - arrow_size * 0.4 * ny;
            const p2y = tip_y - arrow_size * ny + arrow_size * 0.4 * nx;
            rl.drawLineEx(.{ .x = p1x, .y = p1y }, .{ .x = tip_x, .y = tip_y }, 1.5, color);
            rl.drawLineEx(.{ .x = p2x, .y = p2y }, .{ .x = tip_x, .y = tip_y }, 1.5, color);
        },
        .solid, .dotted => {
            // Simple open arrow (two lines)
            const p1x = tip_x - arrow_size * nx + arrow_size * 0.4 * ny;
            const p1y = tip_y - arrow_size * ny - arrow_size * 0.4 * nx;
            const p2x = tip_x - arrow_size * nx - arrow_size * 0.4 * ny;
            const p2y = tip_y - arrow_size * ny + arrow_size * 0.4 * nx;
            rl.drawLineEx(.{ .x = p1x, .y = p1y }, .{ .x = tip_x, .y = tip_y }, 1.5, color);
            rl.drawLineEx(.{ .x = p2x, .y = p2y }, .{ .x = tip_x, .y = tip_y }, 1.5, color);
        },
        else => {
            // Filled triangle arrowhead
            const p1 = rl.Vector2{
                .x = tip_x - arrow_size * nx + arrow_size * 0.5 * ny,
                .y = tip_y - arrow_size * ny - arrow_size * 0.5 * nx,
            };
            const p2 = rl.Vector2{
                .x = tip_x - arrow_size * nx - arrow_size * 0.5 * ny,
                .y = tip_y - arrow_size * ny + arrow_size * 0.5 * nx,
            };
            const tip = rl.Vector2{ .x = tip_x, .y = tip_y };
            rl.drawTriangle(tip, p2, p1, color);
        },
    }
}

fn blockTypeLabel(block_type: sm.BlockType) []const u8 {
    return switch (block_type) {
        .loop_block => "loop",
        .alt => "alt",
        .opt => "opt",
        .par => "par",
        .critical => "critical",
        .break_block => "break",
        .rect => "rect",
    };
}
