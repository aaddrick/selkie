const std = @import("std");
const Allocator = std.mem.Allocator;
const sm = @import("../models/sequence_model.zig");
const SequenceModel = sm.SequenceModel;
const Participant = sm.Participant;
const ParticipantKind = sm.ParticipantKind;
const ArrowType = sm.ArrowType;
const Message = sm.Message;
const NotePosition = sm.NotePosition;
const Note = sm.Note;
const BlockType = sm.BlockType;
const BlockSection = sm.BlockSection;
const Block = sm.Block;
const ActivationEvent = sm.ActivationEvent;
const Event = sm.Event;

pub fn parse(allocator: Allocator, source: []const u8) !SequenceModel {
    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .model = SequenceModel.init(allocator),
    };

    // Split source into lines
    parser.lines = std.ArrayList([]const u8).init(allocator);
    defer parser.lines.deinit();

    var start: usize = 0;
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
            try parser.lines.append(source[start..i]);
            start = i + 1;
        }
    }
    if (start < source.len) {
        try parser.lines.append(source[start..]);
    }

    parser.line_idx = 0;

    // Skip sequenceDiagram header
    while (parser.line_idx < parser.lines.items.len) {
        const line = strip(parser.lines.items[parser.line_idx]);
        if (line.len == 0 or isComment(line)) {
            parser.line_idx += 1;
            continue;
        }
        if (std.mem.eql(u8, line, "sequenceDiagram")) {
            parser.line_idx += 1;
            break;
        }
        // If first non-empty line isn't the header, just skip it
        parser.line_idx += 1;
        break;
    }

    try parser.parseEvents(&parser.model.events);
    return parser.model;
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    model: SequenceModel,
    lines: std.ArrayList([]const u8) = undefined,
    line_idx: usize = 0,

    const ParseError = Allocator.Error;

    fn parseEvents(self: *Parser, events: *std.ArrayList(Event)) ParseError!void {
        while (self.line_idx < self.lines.items.len) {
            const raw_line = self.lines.items[self.line_idx];
            const line = strip(raw_line);

            if (line.len == 0 or isComment(line)) {
                self.line_idx += 1;
                continue;
            }

            // Check for block-end keywords
            if (std.mem.eql(u8, line, "end")) {
                return; // caller handles advancing past 'end'
            }
            if (startsWith(line, "else") or startsWith(line, "and")) {
                return; // section separator — caller handles
            }

            // autonumber
            if (std.mem.eql(u8, line, "autonumber")) {
                self.model.autonumber = true;
                self.line_idx += 1;
                continue;
            }

            // participant / actor
            if (startsWith(line, "participant ") or startsWith(line, "actor ")) {
                try self.parseParticipant(line);
                self.line_idx += 1;
                continue;
            }

            // Note
            if (startsWith(line, "Note ") or startsWith(line, "note ")) {
                try self.parseNote(line, events);
                self.line_idx += 1;
                continue;
            }

            // activate / deactivate
            if (startsWith(line, "activate ")) {
                const id = strip(line["activate ".len..]);
                _ = try self.model.ensureParticipant(id);
                try events.append(.{ .activation = .{ .participant_id = id, .activate = true } });
                self.line_idx += 1;
                continue;
            }
            if (startsWith(line, "deactivate ")) {
                const id = strip(line["deactivate ".len..]);
                try events.append(.{ .activation = .{ .participant_id = id, .activate = false } });
                self.line_idx += 1;
                continue;
            }

            // Block keywords
            if (self.tryParseBlockStart(line)) |block_type| {
                try self.parseBlock(block_type, line, events);
                continue;
            }

            // Try parsing as message (contains arrow)
            if (try self.tryParseMessage(line)) |msg| {
                try events.append(.{ .message = msg });
                self.line_idx += 1;
                continue;
            }

            // Unknown line, skip
            self.line_idx += 1;
        }
    }

    fn parseParticipant(self: *Parser, line: []const u8) ParseError!void {
        const is_actor = startsWith(line, "actor ");
        const kind: ParticipantKind = if (is_actor) .actor else .participant;
        const prefix_len: usize = if (is_actor) "actor ".len else "participant ".len;
        const rest = strip(line[prefix_len..]);

        // Check for "as" alias: "participant A as Alice"
        var id: []const u8 = rest;
        var alias: []const u8 = rest;

        if (indexOf(rest, " as ")) |as_pos| {
            id = strip(rest[0..as_pos]);
            alias = strip(rest[as_pos + " as ".len ..]);
        }

        // Remove surrounding quotes from alias if present
        alias = stripQuotes(alias);
        id = stripQuotes(id);

        // Check if already exists
        for (self.model.participants.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                p.alias = alias;
                p.kind = kind;
                return;
            }
        }

        try self.model.participants.append(.{
            .id = id,
            .alias = alias,
            .kind = kind,
        });
    }

    fn parseNote(self: *Parser, line: []const u8, events: *std.ArrayList(Event)) ParseError!void {
        // "Note left of A: text" / "Note right of B: text" / "Note over A,B: text"
        const after_note = strip(line[if (line[0] == 'N') @as(usize, 5) else 5..]);

        var position: NotePosition = .over;
        var participants_str: []const u8 = "";
        var text: []const u8 = "";

        if (startsWith(after_note, "left of ")) {
            position = .left_of;
            const rest = after_note["left of ".len..];
            if (indexOfChar(rest, ':')) |colon| {
                participants_str = strip(rest[0..colon]);
                text = strip(rest[colon + 1 ..]);
            }
        } else if (startsWith(after_note, "right of ")) {
            position = .right_of;
            const rest = after_note["right of ".len..];
            if (indexOfChar(rest, ':')) |colon| {
                participants_str = strip(rest[0..colon]);
                text = strip(rest[colon + 1 ..]);
            }
        } else if (startsWith(after_note, "over ")) {
            position = .over;
            const rest = after_note["over ".len..];
            if (indexOfChar(rest, ':')) |colon| {
                participants_str = strip(rest[0..colon]);
                text = strip(rest[colon + 1 ..]);
            }
        }

        // Parse comma-separated participant list
        var over_parts = std.ArrayList([]const u8).init(self.allocator);
        var pstart: usize = 0;
        for (participants_str, 0..) |ch, i| {
            if (ch == ',') {
                const p = strip(participants_str[pstart..i]);
                if (p.len > 0) {
                    _ = try self.model.ensureParticipant(p);
                    try over_parts.append(p);
                }
                pstart = i + 1;
            }
        }
        const last_p = strip(participants_str[pstart..]);
        if (last_p.len > 0) {
            _ = try self.model.ensureParticipant(last_p);
            try over_parts.append(last_p);
        }

        try events.append(.{
            .note = .{
                .position = position,
                .over_participants = over_parts,
                .text = text,
            },
        });
    }

    fn tryParseBlockStart(_: *Parser, line: []const u8) ?BlockType {
        if (startsWith(line, "loop ")) return .loop_block;
        if (startsWith(line, "alt ")) return .alt;
        if (startsWith(line, "opt ")) return .opt;
        if (startsWith(line, "par ")) return .par;
        if (startsWith(line, "critical ")) return .critical;
        if (startsWith(line, "break ")) return .break_block;
        if (startsWith(line, "rect ")) return .rect;
        // Also handle keyword-only (no label)
        if (std.mem.eql(u8, line, "loop")) return .loop_block;
        if (std.mem.eql(u8, line, "alt")) return .alt;
        if (std.mem.eql(u8, line, "opt")) return .opt;
        if (std.mem.eql(u8, line, "par")) return .par;
        if (std.mem.eql(u8, line, "critical")) return .critical;
        if (std.mem.eql(u8, line, "break")) return .break_block;
        if (std.mem.eql(u8, line, "rect")) return .rect;
        return null;
    }

    fn parseBlock(self: *Parser, block_type: BlockType, line: []const u8, events: *std.ArrayList(Event)) ParseError!void {
        // Extract label after keyword
        const keyword_len = blockKeywordLen(block_type);
        const label = if (line.len > keyword_len) strip(line[keyword_len..]) else "";

        var block = Block{
            .block_type = block_type,
            .label = label,
            .sections = std.ArrayList(BlockSection).init(self.allocator),
        };

        // First section
        self.line_idx += 1;
        var section_events = std.ArrayList(Event).init(self.allocator);
        try self.parseEvents(&section_events);

        try block.sections.append(.{
            .label = label,
            .events = section_events,
        });

        // Handle else/and sections
        while (self.line_idx < self.lines.items.len) {
            const next_line = strip(self.lines.items[self.line_idx]);
            if (startsWith(next_line, "else") or startsWith(next_line, "and")) {
                const sep_label = blk: {
                    // "else condition" or "and description"
                    const keyword = if (startsWith(next_line, "else")) "else" else "and";
                    if (next_line.len > keyword.len) {
                        const after = strip(next_line[keyword.len..]);
                        break :blk after;
                    }
                    break :blk @as([]const u8, "");
                };

                self.line_idx += 1;
                var sec_events = std.ArrayList(Event).init(self.allocator);
                try self.parseEvents(&sec_events);

                try block.sections.append(.{
                    .label = sep_label,
                    .events = sec_events,
                });
                continue;
            }
            break;
        }

        // Expect 'end'
        if (self.line_idx < self.lines.items.len) {
            const end_line = strip(self.lines.items[self.line_idx]);
            if (std.mem.eql(u8, end_line, "end")) {
                self.line_idx += 1;
            }
        }

        try events.append(.{ .block = block });
    }

    fn tryParseMessage(self: *Parser, line: []const u8) ParseError!?Message {
        // Scan for arrow patterns, longest match first
        // Arrows: ->>, -->>, -x, --x, -), --), <<->>, <<-->>, ->, -->
        var best_start: ?usize = null;
        var best_end: usize = 0;
        var best_arrow: ArrowType = .solid;

        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (tryMatchArrow(line, i)) |result| {
                if (best_start == null or result.len > (best_end - best_start.?)) {
                    best_start = i;
                    best_end = i + result.len;
                    best_arrow = result.arrow_type;
                }
                // Move past this position to find the longest at this position
                // Actually we want the first valid arrow, left to right
                break;
            }
        }

        if (best_start) |arrow_start| {
            var from_str = strip(line[0..arrow_start]);
            const after_arrow = line[best_end..];

            // Check for +/- prefix on from
            var deactivate_source = false;
            if (from_str.len > 0 and from_str[from_str.len - 1] == '-') {
                deactivate_source = true;
                from_str = strip(from_str[0 .. from_str.len - 1]);
            }

            // Parse "to: text" part
            var to_str: []const u8 = "";
            var msg_text: []const u8 = "";
            var activate_target = false;

            if (indexOfChar(after_arrow, ':')) |colon| {
                to_str = strip(after_arrow[0..colon]);
                msg_text = strip(after_arrow[colon + 1 ..]);
            } else {
                to_str = strip(after_arrow);
            }

            // Check for +/- suffix on to
            if (to_str.len > 0 and to_str[0] == '+') {
                activate_target = true;
                to_str = strip(to_str[1..]);
            } else if (to_str.len > 0 and to_str[0] == '-') {
                deactivate_source = true;
                to_str = strip(to_str[1..]);
            }
            // Also check trailing +/-
            if (to_str.len > 0 and to_str[to_str.len - 1] == '+') {
                activate_target = true;
                to_str = strip(to_str[0 .. to_str.len - 1]);
            } else if (to_str.len > 0 and to_str[to_str.len - 1] == '-') {
                deactivate_source = true;
                to_str = strip(to_str[0 .. to_str.len - 1]);
            }

            if (from_str.len == 0 or to_str.len == 0) return null;

            // Ensure participants exist
            _ = try self.model.ensureParticipant(from_str);
            _ = try self.model.ensureParticipant(to_str);

            return Message{
                .from = from_str,
                .to = to_str,
                .text = msg_text,
                .arrow_type = best_arrow,
                .activate_target = activate_target,
                .deactivate_source = deactivate_source,
            };
        }

        return null;
    }
};

const ArrowMatch = struct {
    len: usize,
    arrow_type: ArrowType,
};

fn tryMatchArrow(line: []const u8, pos: usize) ?ArrowMatch {
    const remaining = line.len - pos;

    // Bidirectional arrows (longest first)
    // <<-->>
    if (remaining >= 6 and std.mem.eql(u8, line[pos .. pos + 6], "<<-->>")) {
        return .{ .len = 6, .arrow_type = .bidir_dotted };
    }
    // <<->>
    if (remaining >= 5 and std.mem.eql(u8, line[pos .. pos + 5], "<<->>")) {
        return .{ .len = 5, .arrow_type = .bidir_solid };
    }

    // Dotted arrows (longer match first)
    // -->>
    if (remaining >= 4 and std.mem.eql(u8, line[pos .. pos + 4], "-->>")) {
        return .{ .len = 4, .arrow_type = .dotted_arrow };
    }
    // --x
    if (remaining >= 3 and std.mem.eql(u8, line[pos .. pos + 3], "--x")) {
        return .{ .len = 3, .arrow_type = .dotted_cross };
    }
    // --)
    if (remaining >= 3 and std.mem.eql(u8, line[pos .. pos + 3], "--)")) {
        return .{ .len = 3, .arrow_type = .dotted_open };
    }
    // -->
    if (remaining >= 3 and std.mem.eql(u8, line[pos .. pos + 3], "-->")) {
        return .{ .len = 3, .arrow_type = .dotted };
    }

    // Solid arrows
    // ->>
    if (remaining >= 3 and std.mem.eql(u8, line[pos .. pos + 3], "->>")) {
        return .{ .len = 3, .arrow_type = .solid_arrow };
    }
    // -x
    if (remaining >= 2 and std.mem.eql(u8, line[pos .. pos + 2], "-x")) {
        // Make sure it's not part of a longer identifier
        if (pos + 2 < line.len and isIdentChar(line[pos + 2])) return null;
        return .{ .len = 2, .arrow_type = .solid_cross };
    }
    // -)
    if (remaining >= 2 and std.mem.eql(u8, line[pos .. pos + 2], "-)")) {
        return .{ .len = 2, .arrow_type = .solid_open };
    }
    // ->
    if (remaining >= 2 and std.mem.eql(u8, line[pos .. pos + 2], "->")) {
        // Make sure it's not ->> which we already checked
        return .{ .len = 2, .arrow_type = .solid };
    }

    return null;
}

fn blockKeywordLen(block_type: BlockType) usize {
    return switch (block_type) {
        .loop_block => 4, // "loop"
        .alt => 3,
        .opt => 3,
        .par => 3,
        .critical => 8,
        .break_block => 5, // "break"
        .rect => 4,
    };
}

fn strip(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r')) : (start += 1) {}
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn indexOfChar(haystack: []const u8, needle: u8) ?usize {
    return std.mem.indexOfScalar(u8, haystack, needle);
}

fn isComment(line: []const u8) bool {
    return line.len >= 2 and line[0] == '%' and line[1] == '%';
}

fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_';
}
