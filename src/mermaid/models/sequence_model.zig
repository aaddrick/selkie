const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParticipantKind = enum {
    participant,
    actor,
};

pub const Participant = struct {
    id: []const u8,
    alias: []const u8,
    kind: ParticipantKind,
    // Layout fields (filled by linear_layout)
    center_x: f32 = 0,
    box_width: f32 = 0,
    box_height: f32 = 0,
};

pub const ArrowType = enum {
    solid, // ->
    dotted, // -->
    solid_arrow, // ->>
    dotted_arrow, // -->>
    solid_cross, // -x
    dotted_cross, // --x
    solid_open, // -)
    dotted_open, // --)
    bidir_solid, // <<->>
    bidir_dotted, // <<-->>
};

pub const Message = struct {
    from: []const u8,
    to: []const u8,
    text: []const u8,
    arrow_type: ArrowType,
    activate_target: bool = false,
    deactivate_source: bool = false,
    // Layout field
    y: f32 = 0,
};

pub const NotePosition = enum {
    left_of,
    right_of,
    over,
};

pub const Note = struct {
    position: NotePosition,
    over_participants: std.ArrayList([]const u8),
    text: []const u8,
    // Layout fields
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn deinit(self: *Note) void {
        self.over_participants.deinit();
    }
};

pub const BlockType = enum {
    loop_block,
    alt,
    opt,
    par,
    critical,
    break_block,
    rect,
};

pub const BlockSection = struct {
    label: []const u8,
    events: std.ArrayList(Event),

    pub fn deinit(self: *BlockSection) void {
        for (self.events.items) |*ev| {
            ev.deinit();
        }
        self.events.deinit();
    }
};

pub const Block = struct {
    block_type: BlockType,
    label: []const u8,
    sections: std.ArrayList(BlockSection),
    rect_color: ?[]const u8 = null,
    // Layout fields
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn deinit(self: *Block) void {
        for (self.sections.items) |*sec| {
            sec.deinit();
        }
        self.sections.deinit();
    }
};

pub const ActivationEvent = struct {
    participant_id: []const u8,
    activate: bool,
};

pub const Event = union(enum) {
    message: Message,
    note: Note,
    block: Block,
    activation: ActivationEvent,

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .note => |*n| n.deinit(),
            .block => |*b| b.deinit(),
            .message, .activation => {},
        }
    }
};

pub const ActivationSpan = struct {
    participant_id: []const u8,
    y_start: f32 = 0,
    y_end: f32 = 0,
    depth: u32 = 0,
};

pub const SequenceModel = struct {
    participants: std.ArrayList(Participant),
    events: std.ArrayList(Event),
    autonumber: bool = false,
    activation_spans: std.ArrayList(ActivationSpan),
    lifeline_end_y: f32 = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SequenceModel {
        return .{
            .participants = std.ArrayList(Participant).init(allocator),
            .events = std.ArrayList(Event).init(allocator),
            .activation_spans = std.ArrayList(ActivationSpan).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SequenceModel) void {
        self.participants.deinit();
        for (self.events.items) |*ev| {
            ev.deinit();
        }
        self.events.deinit();
        self.activation_spans.deinit();
    }

    /// Add a participant if not already present. Returns the participant.
    pub fn ensureParticipant(self: *SequenceModel, id: []const u8) !*Participant {
        for (self.participants.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        try self.participants.append(.{
            .id = id,
            .alias = id,
            .kind = .participant,
        });
        return &self.participants.items[self.participants.items.len - 1];
    }

    /// Find a participant by id.
    pub fn findParticipant(self: *const SequenceModel, id: []const u8) ?*const Participant {
        for (self.participants.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }

    /// Uniformly scale all layout positions so the diagram fits within
    /// `target_width`. Returns the scale factor applied.
    pub fn scaleToFit(self: *SequenceModel, natural_width: f32, target_width: f32) f32 {
        if (natural_width <= target_width or natural_width <= 0) return 1.0;
        const scale = target_width / natural_width;

        for (self.participants.items) |*p| {
            p.center_x *= scale;
            p.box_width *= scale;
            p.box_height *= scale;
        }

        scaleEvents(&self.events, scale);

        for (self.activation_spans.items) |*span| {
            span.y_start *= scale;
            span.y_end *= scale;
        }

        self.lifeline_end_y *= scale;

        return scale;
    }

    /// Recursively scale positions within events, including nested block sections.
    fn scaleEvents(events: *std.ArrayList(Event), scale: f32) void {
        for (events.items) |*event| {
            switch (event.*) {
                .message => |*msg| {
                    msg.y *= scale;
                },
                .note => |*note| {
                    note.x *= scale;
                    note.y *= scale;
                    note.width *= scale;
                    note.height *= scale;
                },
                .block => |*block| {
                    block.x *= scale;
                    block.y *= scale;
                    block.width *= scale;
                    block.height *= scale;
                    for (block.sections.items) |*section| {
                        scaleEvents(&section.events, scale);
                    }
                },
                .activation => {},
            }
        }
    }
};

// --- Tests ---

const testing = std.testing;

test "SequenceModel.scaleToFit no-op when natural_width <= target_width" {
    var model = SequenceModel.init(testing.allocator);
    defer model.deinit();

    const p = try model.ensureParticipant("Alice");
    p.center_x = 100;
    p.box_width = 80;
    p.box_height = 30;
    model.lifeline_end_y = 500;

    const scale = model.scaleToFit(400, 600);
    try testing.expectEqual(@as(f32, 1.0), scale);
    try testing.expectEqual(@as(f32, 100), model.participants.items[0].center_x);
    try testing.expectEqual(@as(f32, 80), model.participants.items[0].box_width);
    try testing.expectEqual(@as(f32, 500), model.lifeline_end_y);
}

test "SequenceModel.scaleToFit scales participants" {
    var model = SequenceModel.init(testing.allocator);
    defer model.deinit();

    const alice = try model.ensureParticipant("Alice");
    alice.center_x = 200;
    alice.box_width = 100;
    alice.box_height = 40;

    const bob = try model.ensureParticipant("Bob");
    bob.center_x = 600;
    bob.box_width = 120;
    bob.box_height = 40;

    // natural_width=800, target_width=400 => scale=0.5
    const scale = model.scaleToFit(800, 400);
    try testing.expectApproxEqAbs(@as(f32, 0.5), scale, 0.0001);

    try testing.expectApproxEqAbs(@as(f32, 100), model.participants.items[0].center_x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 50), model.participants.items[0].box_width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 20), model.participants.items[0].box_height, 0.0001);

    try testing.expectApproxEqAbs(@as(f32, 300), model.participants.items[1].center_x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 60), model.participants.items[1].box_width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 20), model.participants.items[1].box_height, 0.0001);
}

test "SequenceModel.scaleToFit scales message y and lifeline_end_y" {
    var model = SequenceModel.init(testing.allocator);
    defer model.deinit();

    try model.events.append(.{ .message = .{
        .from = "A",
        .to = "B",
        .text = "hello",
        .arrow_type = .solid,
        .y = 300,
    } });

    model.lifeline_end_y = 600;

    // natural_width=1000, target_width=250 => scale=0.25
    const scale = model.scaleToFit(1000, 250);
    try testing.expectApproxEqAbs(@as(f32, 0.25), scale, 0.0001);

    const msg = model.events.items[0].message;
    try testing.expectApproxEqAbs(@as(f32, 75), msg.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 150), model.lifeline_end_y, 0.0001);
}

test "SequenceModel.scaleToFit scales note and block events" {
    var model = SequenceModel.init(testing.allocator);
    defer model.deinit();

    // Add a note event
    var over = std.ArrayList([]const u8).init(testing.allocator);
    try over.append("A");
    try model.events.append(.{ .note = .{
        .position = .over,
        .over_participants = over,
        .text = "test",
        .x = 100,
        .y = 200,
        .width = 80,
        .height = 40,
    } });

    // Add a block event with a nested message
    var section_events = std.ArrayList(Event).init(testing.allocator);
    try section_events.append(.{ .message = .{
        .from = "A",
        .to = "B",
        .text = "inner",
        .arrow_type = .solid,
        .y = 500,
    } });
    var sections = std.ArrayList(BlockSection).init(testing.allocator);
    try sections.append(.{ .label = "alt", .events = section_events });
    try model.events.append(.{ .block = .{
        .block_type = .alt,
        .label = "condition",
        .sections = sections,
        .x = 50,
        .y = 300,
        .width = 400,
        .height = 200,
    } });

    // Add an activation span
    try model.activation_spans.append(.{
        .participant_id = "A",
        .y_start = 100,
        .y_end = 400,
        .depth = 0,
    });

    // natural_width=1000, target_width=500 => scale=0.5
    _ = model.scaleToFit(1000, 500);

    // Check note
    const note = model.events.items[0].note;
    try testing.expectApproxEqAbs(@as(f32, 50), note.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 100), note.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 40), note.width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 20), note.height, 0.0001);

    // Check block
    const block = model.events.items[1].block;
    try testing.expectApproxEqAbs(@as(f32, 25), block.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 150), block.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 200), block.width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 100), block.height, 0.0001);

    // Check nested message inside block section
    const inner_msg = block.sections.items[0].events.items[0].message;
    try testing.expectApproxEqAbs(@as(f32, 250), inner_msg.y, 0.0001);

    // Check activation span
    const span = model.activation_spans.items[0];
    try testing.expectApproxEqAbs(@as(f32, 50), span.y_start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 200), span.y_end, 0.0001);
}

test "SequenceModel.scaleToFit returns correct scale factor" {
    var model = SequenceModel.init(testing.allocator);
    defer model.deinit();

    const scale = model.scaleToFit(900, 300);
    try testing.expectApproxEqAbs(@as(f32, 300.0 / 900.0), scale, 0.0001);
}

test "SequenceModel.scaleToFit no-op for negative natural_width" {
    var model = SequenceModel.init(testing.allocator);
    defer model.deinit();

    const scale = model.scaleToFit(-100, 500);
    try testing.expectEqual(@as(f32, 1.0), scale);
}
