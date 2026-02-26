const std = @import("std");
const Allocator = std.mem.Allocator;
const sm = @import("../models/sequence_model.zig");
const SequenceModel = sm.SequenceModel;
const Event = sm.Event;
const BlockSection = sm.BlockSection;
const Fonts = @import("../../layout/text_measurer.zig").Fonts;
const Theme = @import("../../theme/theme.zig").Theme;

const PARTICIPANT_PADDING_H: f32 = 20;
const PARTICIPANT_PADDING_V: f32 = 10;
const PARTICIPANT_SPACING: f32 = 60;
const MESSAGE_STEP: f32 = 40;
const SELF_MESSAGE_EXTRA: f32 = 30;
const NOTE_PADDING: f32 = 10;
const BLOCK_PADDING: f32 = 10;
const BLOCK_LABEL_HEIGHT: f32 = 24;
const DIAGRAM_PADDING: f32 = 20;
const ACTIVATION_WIDTH: f32 = 12;
const MIN_PARTICIPANT_WIDTH: f32 = 80;
const SECTION_DIVIDER_STEP: f32 = 10;

pub const LayoutResult = struct {
    width: f32,
    height: f32,
};

pub fn layout(allocator: Allocator, model: *SequenceModel, fonts: *const Fonts, theme: *const Theme, available_width: f32) !LayoutResult {
    _ = available_width;

    if (model.participants.items.len == 0) {
        return .{ .width = 0, .height = 0 };
    }

    // Step 1: Measure participant box sizes
    for (model.participants.items) |*p| {
        const measured = fonts.measure(p.alias, theme.body_font_size, false, false, false);
        p.box_width = @max(measured.x + PARTICIPANT_PADDING_H * 2, MIN_PARTICIPANT_WIDTH);
        p.box_height = measured.y + PARTICIPANT_PADDING_V * 2;
        if (p.kind == .actor) {
            // Actors (stick figures) need more vertical space
            p.box_height = @max(p.box_height, 60);
        }
    }

    // Step 2: Space participants horizontally
    var x_cursor: f32 = DIAGRAM_PADDING;
    for (model.participants.items) |*p| {
        p.center_x = x_cursor + p.box_width / 2;
        x_cursor += p.box_width + PARTICIPANT_SPACING;
    }
    const total_width = x_cursor - PARTICIPANT_SPACING + DIAGRAM_PADDING;

    // Step 3: Walk events top-to-bottom
    const max_box_height = blk: {
        var max_h: f32 = 0;
        for (model.participants.items) |p| {
            max_h = @max(max_h, p.box_height);
        }
        break :blk max_h;
    };

    var y_cursor: f32 = DIAGRAM_PADDING + max_box_height + 20;

    // Track activations per participant for depth
    var activation_stacks = std.StringHashMap(std.ArrayList(usize)).init(allocator);
    defer {
        var it = activation_stacks.valueIterator();
        while (it.next()) |stack| {
            stack.deinit();
        }
        activation_stacks.deinit();
    }

    try layoutEvents(allocator, model, &model.events, &y_cursor, &activation_stacks, fonts, theme);

    y_cursor += 20; // bottom spacing before participant boxes repeat
    model.lifeline_end_y = y_cursor;

    // Add space for bottom participant boxes
    y_cursor += max_box_height + DIAGRAM_PADDING;

    return .{
        .width = total_width,
        .height = y_cursor,
    };
}

fn layoutEvents(
    allocator: Allocator,
    model: *SequenceModel,
    events: *std.ArrayList(Event),
    y_cursor: *f32,
    activation_stacks: *std.StringHashMap(std.ArrayList(usize)),
    fonts: *const Fonts,
    theme: *const Theme,
) !void {
    for (events.items) |*event| {
        switch (event.*) {
            .message => |*msg| {
                msg.y = y_cursor.*;

                // Handle activation/deactivation from +/- shorthand
                if (msg.activate_target) {
                    const depth = getActivationDepth(activation_stacks, msg.to);
                    try model.activation_spans.append(.{
                        .participant_id = msg.to,
                        .y_start = y_cursor.*,
                        .depth = depth,
                    });
                    var stack = try getOrCreateStack(allocator, activation_stacks, msg.to);
                    try stack.append(model.activation_spans.items.len - 1);
                }
                if (msg.deactivate_source) {
                    closeActivation(activation_stacks, &model.activation_spans, msg.from, y_cursor.*);
                }

                // Self-messages need extra space
                if (std.mem.eql(u8, msg.from, msg.to)) {
                    y_cursor.* += MESSAGE_STEP + SELF_MESSAGE_EXTRA;
                } else {
                    y_cursor.* += MESSAGE_STEP;
                }
            },
            .note => |*note| {
                const measured = fonts.measure(note.text, theme.body_font_size * 0.85, false, false, false);
                note.width = measured.x + NOTE_PADDING * 2;
                note.height = measured.y + NOTE_PADDING * 2;

                // Position based on participants
                if (note.over_participants.items.len > 0) {
                    const first_id = note.over_participants.items[0];
                    if (model.findParticipant(first_id)) |first_p| {
                        switch (note.position) {
                            .left_of => {
                                note.x = first_p.center_x - first_p.box_width / 2 - note.width - 5;
                            },
                            .right_of => {
                                note.x = first_p.center_x + first_p.box_width / 2 + 5;
                            },
                            .over => {
                                if (note.over_participants.items.len > 1) {
                                    const last_id = note.over_participants.items[note.over_participants.items.len - 1];
                                    if (model.findParticipant(last_id)) |last_p| {
                                        const center = (first_p.center_x + last_p.center_x) / 2;
                                        note.x = center - note.width / 2;
                                    } else {
                                        note.x = first_p.center_x - note.width / 2;
                                    }
                                } else {
                                    note.x = first_p.center_x - note.width / 2;
                                }
                            },
                        }
                    }
                }

                note.y = y_cursor.*;
                y_cursor.* += note.height + 10;
            },
            .block => |*block| {
                block.y = y_cursor.*;

                // Find leftmost and rightmost referenced participants
                var left_x: f32 = std.math.inf(f32);
                var right_x: f32 = 0;
                findBlockExtents(model, &block.sections, &left_x, &right_x);

                // Default to full diagram width if no participants found
                if (left_x == std.math.inf(f32)) {
                    left_x = DIAGRAM_PADDING;
                    right_x = blk: {
                        if (model.participants.items.len > 0) {
                            const last_p = model.participants.items[model.participants.items.len - 1];
                            break :blk last_p.center_x + last_p.box_width / 2;
                        }
                        break :blk 200;
                    };
                }

                block.x = left_x - BLOCK_PADDING;
                block.width = (right_x - left_x) + BLOCK_PADDING * 2;

                y_cursor.* += BLOCK_LABEL_HEIGHT;

                // Layout each section
                for (block.sections.items) |*section| {
                    try layoutEvents(allocator, model, &section.events, y_cursor, activation_stacks, fonts, theme);
                    y_cursor.* += SECTION_DIVIDER_STEP;
                }

                block.height = y_cursor.* - block.y + BLOCK_PADDING;
                y_cursor.* += BLOCK_PADDING;
            },
            .activation => |act| {
                if (act.activate) {
                    const depth = getActivationDepth(activation_stacks, act.participant_id);
                    try model.activation_spans.append(.{
                        .participant_id = act.participant_id,
                        .y_start = y_cursor.*,
                        .depth = depth,
                    });
                    var stack = try getOrCreateStack(allocator, activation_stacks, act.participant_id);
                    try stack.append(model.activation_spans.items.len - 1);
                } else {
                    closeActivation(activation_stacks, &model.activation_spans, act.participant_id, y_cursor.*);
                }
            },
        }
    }
}

fn findBlockExtents(model: *const SequenceModel, sections: *const std.ArrayList(BlockSection), left_x: *f32, right_x: *f32) void {
    for (sections.items) |section| {
        for (section.events.items) |event| {
            switch (event) {
                .message => |msg| {
                    if (model.findParticipant(msg.from)) |p| {
                        left_x.* = @min(left_x.*, p.center_x - p.box_width / 2);
                        right_x.* = @max(right_x.*, p.center_x + p.box_width / 2);
                    }
                    if (model.findParticipant(msg.to)) |p| {
                        left_x.* = @min(left_x.*, p.center_x - p.box_width / 2);
                        right_x.* = @max(right_x.*, p.center_x + p.box_width / 2);
                    }
                },
                .note => |note| {
                    for (note.over_participants.items) |pid| {
                        if (model.findParticipant(pid)) |p| {
                            left_x.* = @min(left_x.*, p.center_x - p.box_width / 2);
                            right_x.* = @max(right_x.*, p.center_x + p.box_width / 2);
                        }
                    }
                },
                .block => |blk| {
                    findBlockExtents(model, &blk.sections, left_x, right_x);
                },
                .activation => {},
            }
        }
    }
}

fn getActivationDepth(stacks: *std.StringHashMap(std.ArrayList(usize)), participant_id: []const u8) u32 {
    if (stacks.get(participant_id)) |stack| {
        return @intCast(stack.items.len);
    }
    return 0;
}

fn getOrCreateStack(allocator: Allocator, stacks: *std.StringHashMap(std.ArrayList(usize)), participant_id: []const u8) !*std.ArrayList(usize) {
    const result = try stacks.getOrPut(participant_id);
    if (!result.found_existing) {
        result.value_ptr.* = std.ArrayList(usize).init(allocator);
    }
    return result.value_ptr;
}

fn closeActivation(stacks: *std.StringHashMap(std.ArrayList(usize)), spans: *std.ArrayList(sm.ActivationSpan), participant_id: []const u8, y: f32) void {
    if (stacks.getPtr(participant_id)) |stack| {
        if (stack.items.len > 0) {
            const span_idx = stack.getLast();
            stack.items.len -= 1;
            if (span_idx < spans.items.len) {
                spans.items[span_idx].y_end = y;
            }
        }
    }
}
