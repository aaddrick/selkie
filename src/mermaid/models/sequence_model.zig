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
};
