/// Lexer / tokenizer for the stateDiagram-v2 sub-language.
///
/// Grammar production rules (informal EBNF):
///
///   diagram          ::= header NEWLINE statement*
///   header           ::= KW_STATE_DIAGRAM_V2 | KW_STATE_DIAGRAM
///
///   statement        ::= direction_stmt
///                      | note_stmt
///                      | state_decl
///                      | transition_stmt
///                      | REGION_SEP NEWLINE
///                      | CLOSE_BRACE NEWLINE
///                      | COMMENT
///                      | NEWLINE
///
///   direction_stmt   ::= KW_DIRECTION IDENTIFIER NEWLINE
///                        (IDENTIFIER ∈ { "LR", "RL", "TB", "TD", "BT" })
///
///   state_decl       ::= KW_STATE (STRING_LITERAL KW_AS)? IDENTIFIER
///                        (OPEN_BRACE | (STEREO_OPEN IDENTIFIER STEREO_CLOSE))?
///
///   composite_block  ::= OPEN_BRACE statement* region_sep_stmt* CLOSE_BRACE
///   region_sep_stmt  ::= REGION_SEP NEWLINE
///
///   transition_stmt  ::= state_ref TRANSITION_OP state_ref
///                        (COLON label_text)? NEWLINE
///   state_ref        ::= PSEUDO_START_END
///                      | PSEUDO_DEEP_HISTORY
///                      | PSEUDO_HISTORY
///                      | IDENTIFIER
///
///   label_text       ::= (guard | IDENTIFIER | STRING_LITERAL)*
///   guard            ::= GUARD_OPEN guard_content GUARD_CLOSE
///   guard_content    ::= GUARD_CONTENT      (any text up to the closing ']')
///
///   note_stmt        ::= KW_NOTE (KW_RIGHT | KW_LEFT) KW_OF state_ref
///                        (COLON label_text NEWLINE
///                        | NEWLINE note_body KW_END KW_NOTE NEWLINE)
///   note_body        ::= IDENTIFIER* NEWLINE (informal: any lines until "end note")
///
///   Self-referential transitions (A --> A) are valid syntactically and are
///   detected at the parser or semantic-analysis level; the lexer emits two
///   separate IDENTIFIER tokens (from and to) and the TRANSITION_OP between them.
///
const std = @import("std");
const Allocator = std.mem.Allocator;

/// All token types produced by the stateDiagram-v2 lexer.
pub const TokenType = enum {
    // ---- Diagram header ----
    /// "stateDiagram-v2"
    kw_state_diagram_v2,
    /// "stateDiagram"
    kw_state_diagram,

    // ---- Statement keywords ----
    /// "state"
    kw_state,
    /// "direction"
    kw_direction,
    /// "note"
    kw_note,
    /// "as"
    kw_as,
    /// "end"  (also precedes "note" to end multi-line notes)
    kw_end,
    /// "of"  (used in note position: "right of", "left of")
    kw_of,
    /// "right" (note position)
    kw_right,
    /// "left" (note position)
    kw_left,

    // ---- Identifiers and literals ----
    /// State identifier or unrecognised word (alphanumeric + underscore)
    identifier,
    /// Quoted string: `"some label"`
    string_literal,

    // ---- Pseudo-state references ----
    /// `[*]`  — initial / terminal pseudo-state
    pseudo_start_end,
    /// `[H]`  — shallow history pseudo-state
    pseudo_history,
    /// `[H*]` — deep history pseudo-state
    pseudo_deep_history,

    // ---- Operators ----
    /// `-->` — state transition arrow
    transition_op,
    /// `--`  — concurrent region separator inside a composite block
    region_sep,

    // ---- Guard / condition syntax ----
    /// `[`  opening a guard / condition expression (not a pseudo-state)
    guard_open,
    /// Text content between `[` and `]`
    guard_content,
    /// `]`  closing a guard / condition expression
    guard_close,

    // ---- Stereotype syntax ----
    /// `<<`
    stereo_open,
    /// `>>`
    stereo_close,

    // ---- Block delimiters ----
    /// `{`  opening a composite state block
    open_brace,
    /// `}`  closing a composite state block
    close_brace,

    // ---- Punctuation ----
    /// `:` separating a transition from its label
    colon,

    // ---- Structural ----
    /// `\n`
    newline,
    /// `%% ...`  Mermaid comment to end of line
    comment,
    /// Sentinel token at end of input
    eof,
};

/// A single token produced by the lexer.
///
/// `text` is a slice into the original source string (zero-copy).
/// `line` is the 1-based source line number where the token starts.
pub const Token = struct {
    type: TokenType,
    /// Slice into the original source; no allocation required.
    text: []const u8,
    /// 1-based source line number (useful for error reporting and layout).
    line: u32 = 1,
};

/// Tokenise a stateDiagram-v2 source string.
///
/// Returns an `ArrayList(Token)` that the caller owns and must `deinit()`.
/// The token texts are slices into `source` — they remain valid as long as
/// `source` is alive.
///
/// Errors:
///   `Allocator.Error` if memory allocation fails.
pub fn tokenize(allocator: Allocator, source: []const u8) !std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    var line_num: u32 = 1;

    while (i < source.len) {
        const ch = source[i];

        // ----------------------------------------------------------------
        // Skip whitespace (spaces, tabs, carriage returns)
        // ----------------------------------------------------------------
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            i += 1;
            continue;
        }

        // ----------------------------------------------------------------
        // Newline
        // ----------------------------------------------------------------
        if (ch == '\n') {
            try tokens.append(.{ .type = .newline, .text = source[i .. i + 1], .line = line_num });
            line_num += 1;
            i += 1;
            continue;
        }

        // ----------------------------------------------------------------
        // Comments: %% to end of line
        // ----------------------------------------------------------------
        if (ch == '%' and i + 1 < source.len and source[i + 1] == '%') {
            const start = i;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            try tokens.append(.{ .type = .comment, .text = source[start..i], .line = line_num });
            continue;
        }

        // ----------------------------------------------------------------
        // Pseudo-states and guard brackets: [
        // The lexer must distinguish [*], [H], [H*] (pseudo-states) from
        // [condition] (guard expressions).
        // ----------------------------------------------------------------
        if (ch == '[') {
            // [*] — initial/terminal pseudo-state
            if (i + 2 < source.len and source[i + 1] == '*' and source[i + 2] == ']') {
                try tokens.append(.{
                    .type = .pseudo_start_end,
                    .text = source[i .. i + 3],
                    .line = line_num,
                });
                i += 3;
                continue;
            }

            // [H*] — deep history pseudo-state (must be checked before [H])
            if (i + 3 < source.len and
                source[i + 1] == 'H' and
                source[i + 2] == '*' and
                source[i + 3] == ']')
            {
                try tokens.append(.{
                    .type = .pseudo_deep_history,
                    .text = source[i .. i + 4],
                    .line = line_num,
                });
                i += 4;
                continue;
            }

            // [H] — shallow history pseudo-state
            if (i + 2 < source.len and source[i + 1] == 'H' and source[i + 2] == ']') {
                try tokens.append(.{
                    .type = .pseudo_history,
                    .text = source[i .. i + 3],
                    .line = line_num,
                });
                i += 3;
                continue;
            }

            // Guard expression: [condition text]
            // Emit GUARD_OPEN, GUARD_CONTENT (optional), GUARD_CLOSE.
            try tokens.append(.{ .type = .guard_open, .text = source[i .. i + 1], .line = line_num });
            i += 1;

            const content_start = i;
            // Consume guard content until ']' or newline
            while (i < source.len and source[i] != ']' and source[i] != '\n') : (i += 1) {}
            if (content_start < i) {
                try tokens.append(.{
                    .type = .guard_content,
                    .text = source[content_start..i],
                    .line = line_num,
                });
            }
            if (i < source.len and source[i] == ']') {
                try tokens.append(.{ .type = .guard_close, .text = source[i .. i + 1], .line = line_num });
                i += 1;
            }
            continue;
        }

        // ----------------------------------------------------------------
        // Transition operator --> and region separator --
        // These must be checked BEFORE identifier parsing because '--'
        // could otherwise be mistaken for hyphens in an identifier.
        // ----------------------------------------------------------------
        if (ch == '-' and i + 1 < source.len and source[i + 1] == '-') {
            // --> transition operator (3 chars)
            if (i + 2 < source.len and source[i + 2] == '>') {
                try tokens.append(.{
                    .type = .transition_op,
                    .text = source[i .. i + 3],
                    .line = line_num,
                });
                i += 3;
                continue;
            }
            // -- region separator (2 chars)
            try tokens.append(.{ .type = .region_sep, .text = source[i .. i + 2], .line = line_num });
            i += 2;
            continue;
        }

        // ----------------------------------------------------------------
        // Stereotype delimiters: << and >>
        // ----------------------------------------------------------------
        if (ch == '<' and i + 1 < source.len and source[i + 1] == '<') {
            try tokens.append(.{ .type = .stereo_open, .text = source[i .. i + 2], .line = line_num });
            i += 2;
            continue;
        }
        if (ch == '>' and i + 1 < source.len and source[i + 1] == '>') {
            try tokens.append(.{ .type = .stereo_close, .text = source[i .. i + 2], .line = line_num });
            i += 2;
            continue;
        }

        // ----------------------------------------------------------------
        // Composite block delimiters: { and }
        // ----------------------------------------------------------------
        if (ch == '{') {
            try tokens.append(.{ .type = .open_brace, .text = source[i .. i + 1], .line = line_num });
            i += 1;
            continue;
        }
        if (ch == '}') {
            try tokens.append(.{ .type = .close_brace, .text = source[i .. i + 1], .line = line_num });
            i += 1;
            continue;
        }

        // ----------------------------------------------------------------
        // Colon: : (transition label separator)
        // ----------------------------------------------------------------
        if (ch == ':') {
            try tokens.append(.{ .type = .colon, .text = source[i .. i + 1], .line = line_num });
            i += 1;
            continue;
        }

        // ----------------------------------------------------------------
        // Quoted string literal: "..."
        // ----------------------------------------------------------------
        if (ch == '"') {
            const start = i;
            i += 1; // skip opening quote
            while (i < source.len and source[i] != '"' and source[i] != '\n') : (i += 1) {}
            if (i < source.len and source[i] == '"') i += 1; // skip closing quote
            try tokens.append(.{ .type = .string_literal, .text = source[start..i], .line = line_num });
            continue;
        }

        // ----------------------------------------------------------------
        // Identifiers and keywords.
        //
        // Identifier chars: letters and underscores to start, then letters,
        // digits, and underscores.  A trailing hyphen-digit suffix is handled
        // as a special case to recognise "stateDiagram-v2" as one token.
        // ----------------------------------------------------------------
        if (isIdentStart(ch)) {
            const start = i;
            while (i < source.len and isIdentContinue(source[i])) : (i += 1) {}
            const word = source[start..i];

            // Special-case: "stateDiagram-v2" is a single keyword token.
            // After consuming "stateDiagram", check for the "-v2" suffix.
            if (std.mem.eql(u8, word, "stateDiagram") and
                i + 3 <= source.len and
                source[i] == '-' and
                source[i + 1] == 'v' and
                source[i + 2] == '2' and
                (i + 3 >= source.len or !isIdentContinue(source[i + 3])))
            {
                i += 3; // consume "-v2"
                try tokens.append(.{
                    .type = .kw_state_diagram_v2,
                    .text = source[start..i],
                    .line = line_num,
                });
                continue;
            }

            const tok_type = classifyKeyword(word);
            try tokens.append(.{ .type = tok_type, .text = word, .line = line_num });
            continue;
        }

        // ----------------------------------------------------------------
        // Unknown / unparseable characters — skip silently.
        // ----------------------------------------------------------------
        i += 1;
    }

    try tokens.append(.{ .type = .eof, .text = "", .line = line_num });
    return tokens;
}

// ---------------------------------------------------------------------------
// Character-class helpers
// ---------------------------------------------------------------------------

/// Returns true for characters that may start an identifier.
inline fn isIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        ch == '_';
}

/// Returns true for characters that may continue (not start) an identifier.
inline fn isIdentContinue(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_';
}

// ---------------------------------------------------------------------------
// Keyword classification
// ---------------------------------------------------------------------------

/// Maps a word to the appropriate `TokenType`, defaulting to `.identifier`.
fn classifyKeyword(word: []const u8) TokenType {
    if (std.mem.eql(u8, word, "stateDiagram")) return .kw_state_diagram;
    if (std.mem.eql(u8, word, "state")) return .kw_state;
    if (std.mem.eql(u8, word, "direction")) return .kw_direction;
    if (std.mem.eql(u8, word, "note")) return .kw_note;
    if (std.mem.eql(u8, word, "as")) return .kw_as;
    if (std.mem.eql(u8, word, "end")) return .kw_end;
    if (std.mem.eql(u8, word, "of")) return .kw_of;
    if (std.mem.eql(u8, word, "right")) return .kw_right;
    if (std.mem.eql(u8, word, "left")) return .kw_left;
    return .identifier;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "empty input produces only eof" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "");
    defer tokens.deinit();

    try testing.expectEqual(@as(usize, 1), tokens.items.len);
    try testing.expectEqual(TokenType.eof, tokens.items[0].type);
}

test "whitespace-only input produces only eof" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "   \t  \r\n  ");
    defer tokens.deinit();

    // Should have newline + eof
    var found_eof = false;
    for (tokens.items) |tok| {
        if (tok.type == .eof) {
            found_eof = true;
        }
        try testing.expect(tok.type == .newline or tok.type == .eof);
    }
    try testing.expect(found_eof);
}

test "header stateDiagram-v2" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "stateDiagram-v2");
    defer tokens.deinit();

    try testing.expect(tokens.items.len >= 2);
    try testing.expectEqual(TokenType.kw_state_diagram_v2, tokens.items[0].type);
    try testing.expectEqualStrings("stateDiagram-v2", tokens.items[0].text);
}

test "header stateDiagram (v1)" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "stateDiagram");
    defer tokens.deinit();

    try testing.expect(tokens.items.len >= 2);
    try testing.expectEqual(TokenType.kw_state_diagram, tokens.items[0].type);
    try testing.expectEqualStrings("stateDiagram", tokens.items[0].text);
}

test "stateDiagram-v2 not confused with stateDiagram-v20" {
    // "stateDiagram-v20" should NOT match the -v2 suffix because 'v2' is
    // followed by '0' (an ident-continue character).
    const allocator = testing.allocator;
    // We check the text only — a real diagram would have this as an identifier.
    var tokens = try tokenize(allocator, "stateDiagram-v20");
    defer tokens.deinit();
    try testing.expect(tokens.items[0].type != .kw_state_diagram_v2);
}

test "transition operator -->" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "A --> B");
    defer tokens.deinit();

    // A, -->, B, eof
    try testing.expect(tokens.items.len >= 4);
    try testing.expectEqual(TokenType.identifier, tokens.items[0].type);
    try testing.expectEqualStrings("A", tokens.items[0].text);
    try testing.expectEqual(TokenType.transition_op, tokens.items[1].type);
    try testing.expectEqualStrings("-->", tokens.items[1].text);
    try testing.expectEqual(TokenType.identifier, tokens.items[2].type);
    try testing.expectEqualStrings("B", tokens.items[2].text);
}

test "self-referential transition A --> A" {
    // Self-referential transitions are syntactically identical to regular
    // transitions; the lexer produces identifier, transition_op, identifier
    // and the parser detects from == to.
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "A --> A");
    defer tokens.deinit();

    try testing.expect(tokens.items.len >= 4);
    try testing.expectEqual(TokenType.identifier, tokens.items[0].type);
    try testing.expectEqualStrings("A", tokens.items[0].text);
    try testing.expectEqual(TokenType.transition_op, tokens.items[1].type);
    try testing.expectEqual(TokenType.identifier, tokens.items[2].type);
    try testing.expectEqualStrings("A", tokens.items[2].text);
}

test "transition with colon label" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "A --> B : my label");
    defer tokens.deinit();

    // A, -->, B, :, my, label, eof
    var found_colon = false;
    for (tokens.items) |tok| {
        if (tok.type == .colon) found_colon = true;
    }
    try testing.expect(found_colon);
}

test "transition with guard condition [cond]" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "A --> B : [n > 0]");
    defer tokens.deinit();

    // Verify guard_open, guard_content, guard_close are present
    var found_guard_open = false;
    var found_guard_content = false;
    var found_guard_close = false;
    var guard_text: []const u8 = "";

    for (tokens.items) |tok| {
        switch (tok.type) {
            .guard_open => found_guard_open = true,
            .guard_content => {
                found_guard_content = true;
                guard_text = tok.text;
            },
            .guard_close => found_guard_close = true,
            else => {},
        }
    }

    try testing.expect(found_guard_open);
    try testing.expect(found_guard_content);
    try testing.expect(found_guard_close);
    // Guard content should include the text between brackets
    try testing.expectEqualStrings("n > 0", guard_text);
}

test "guard with no content []" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "[]");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.guard_open, tokens.items[0].type);
    try testing.expectEqual(TokenType.guard_close, tokens.items[1].type);
}

test "pseudo-state [*]" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "[*] --> A");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.pseudo_start_end, tokens.items[0].type);
    try testing.expectEqualStrings("[*]", tokens.items[0].text);
    try testing.expectEqual(TokenType.transition_op, tokens.items[1].type);
}

test "pseudo-state [H]" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "[H]");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.pseudo_history, tokens.items[0].type);
    try testing.expectEqualStrings("[H]", tokens.items[0].text);
}

test "pseudo-state [H*]" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "[H*]");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.pseudo_deep_history, tokens.items[0].type);
    try testing.expectEqualStrings("[H*]", tokens.items[0].text);
}

test "region separator --" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "--");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.region_sep, tokens.items[0].type);
    try testing.expectEqualStrings("--", tokens.items[0].text);
}

test "region separator -- vs transition -->" {
    // Make sure -- and --> produce different token types
    const allocator = testing.allocator;

    var t1 = try tokenize(allocator, "--");
    defer t1.deinit();
    try testing.expectEqual(TokenType.region_sep, t1.items[0].type);

    var t2 = try tokenize(allocator, "-->");
    defer t2.deinit();
    try testing.expectEqual(TokenType.transition_op, t2.items[0].type);
}

test "composite block open and close braces" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "state Foo {\n}");
    defer tokens.deinit();

    var found_open = false;
    var found_close = false;
    for (tokens.items) |tok| {
        if (tok.type == .open_brace) found_open = true;
        if (tok.type == .close_brace) found_close = true;
    }
    try testing.expect(found_open);
    try testing.expect(found_close);
}

test "state keyword followed by identifier" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "state Idle");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.kw_state, tokens.items[0].type);
    try testing.expectEqualStrings("state", tokens.items[0].text);
    try testing.expectEqual(TokenType.identifier, tokens.items[1].type);
    try testing.expectEqualStrings("Idle", tokens.items[1].text);
}

test "state declaration with quoted label and as" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "state \"My Label\" as myState");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.kw_state, tokens.items[0].type);
    try testing.expectEqual(TokenType.string_literal, tokens.items[1].type);
    try testing.expectEqualStrings("\"My Label\"", tokens.items[1].text);
    try testing.expectEqual(TokenType.kw_as, tokens.items[2].type);
    try testing.expectEqual(TokenType.identifier, tokens.items[3].type);
    try testing.expectEqualStrings("myState", tokens.items[3].text);
}

test "state declaration with composite brace on same line" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "state MyComp {");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.kw_state, tokens.items[0].type);
    try testing.expectEqual(TokenType.identifier, tokens.items[1].type);
    try testing.expectEqualStrings("MyComp", tokens.items[1].text);
    try testing.expectEqual(TokenType.open_brace, tokens.items[2].type);
}

test "stereotype << fork >>" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "state forkState <<fork>>");
    defer tokens.deinit();

    var found_stereo_open = false;
    var found_stereo_close = false;
    var found_fork = false;

    for (tokens.items) |tok| {
        switch (tok.type) {
            .stereo_open => found_stereo_open = true,
            .stereo_close => found_stereo_close = true,
            .identifier => if (std.mem.eql(u8, tok.text, "fork")) {
                found_fork = true;
            },
            else => {},
        }
    }
    try testing.expect(found_stereo_open);
    try testing.expect(found_stereo_close);
    try testing.expect(found_fork);
}

test "direction keyword" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "direction LR");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.kw_direction, tokens.items[0].type);
    try testing.expectEqual(TokenType.identifier, tokens.items[1].type);
    try testing.expectEqualStrings("LR", tokens.items[1].text);
}

test "note keyword with position and of" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "note right of StateA : some text");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.kw_note, tokens.items[0].type);
    try testing.expectEqual(TokenType.kw_right, tokens.items[1].type);
    try testing.expectEqual(TokenType.kw_of, tokens.items[2].type);
    try testing.expectEqual(TokenType.identifier, tokens.items[3].type);
    try testing.expectEqualStrings("StateA", tokens.items[3].text);
    try testing.expectEqual(TokenType.colon, tokens.items[4].type);
}

test "note left of" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "note left of SomeState");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.kw_note, tokens.items[0].type);
    try testing.expectEqual(TokenType.kw_left, tokens.items[1].type);
    try testing.expectEqual(TokenType.kw_of, tokens.items[2].type);
}

test "end keyword (used in multi-line note terminator)" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "end note");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.kw_end, tokens.items[0].type);
    try testing.expectEqualStrings("end", tokens.items[0].text);
    try testing.expectEqual(TokenType.kw_note, tokens.items[1].type);
}

test "comment %% to end of line" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "%% this is a comment\nA");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.comment, tokens.items[0].type);
    try testing.expect(std.mem.startsWith(u8, tokens.items[0].text, "%%"));
    // After comment there should be a newline and then identifier A
    try testing.expectEqual(TokenType.newline, tokens.items[1].type);
    try testing.expectEqual(TokenType.identifier, tokens.items[2].type);
    try testing.expectEqualStrings("A", tokens.items[2].text);
}

test "newlines tracked with line numbers" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "A\nB\nC");
    defer tokens.deinit();

    // Line numbers: A=1, newline=1, B=2, newline=2, C=3, eof=3
    try testing.expectEqual(@as(u32, 1), tokens.items[0].line); // A
    try testing.expectEqual(@as(u32, 2), tokens.items[2].line); // B
    try testing.expectEqual(@as(u32, 3), tokens.items[4].line); // C
}

test "carriage returns are skipped" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "A\r\nB");
    defer tokens.deinit();

    // A, newline, B, eof — \r is silently consumed
    try testing.expectEqual(TokenType.identifier, tokens.items[0].type);
    try testing.expectEqual(TokenType.newline, tokens.items[1].type);
    try testing.expectEqual(TokenType.identifier, tokens.items[2].type);
}

test "full minimal stateDiagram-v2 snippet" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Active
        \\    Active --> [*]
    ;
    var tokens = try tokenize(allocator, src);
    defer tokens.deinit();

    // First token: diagram header
    try testing.expectEqual(TokenType.kw_state_diagram_v2, tokens.items[0].type);

    // Find transition_op tokens
    var transition_count: usize = 0;
    for (tokens.items) |tok| {
        if (tok.type == .transition_op) transition_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), transition_count);
}

test "full composite state snippet" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state MyComp {
        \\        [*] --> Sub
        \\        Sub --> [*]
        \\        --
        \\        [*] --> Sub2
        \\    }
    ;
    var tokens = try tokenize(allocator, src);
    defer tokens.deinit();

    var open_count: usize = 0;
    var close_count: usize = 0;
    var region_count: usize = 0;

    for (tokens.items) |tok| {
        switch (tok.type) {
            .open_brace => open_count += 1,
            .close_brace => close_count += 1,
            .region_sep => region_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 1), open_count);
    try testing.expectEqual(@as(usize, 1), close_count);
    try testing.expectEqual(@as(usize, 1), region_count);
}

test "identifier with digits" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "state1 --> state2");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.identifier, tokens.items[0].type);
    try testing.expectEqualStrings("state1", tokens.items[0].text);
    try testing.expectEqual(TokenType.transition_op, tokens.items[1].type);
    try testing.expectEqual(TokenType.identifier, tokens.items[2].type);
    try testing.expectEqualStrings("state2", tokens.items[2].text);
}

test "identifier starting with underscore" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "_myState");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.identifier, tokens.items[0].type);
    try testing.expectEqualStrings("_myState", tokens.items[0].text);
}

test "quoted string literal" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "\"My State Label\"");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.string_literal, tokens.items[0].type);
    try testing.expectEqualStrings("\"My State Label\"", tokens.items[0].text);
}

test "colon token" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, ":");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.colon, tokens.items[0].type);
}

test "guard preserves internal whitespace" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "[x == 0 and y > 1]");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.guard_open, tokens.items[0].type);
    try testing.expectEqual(TokenType.guard_content, tokens.items[1].type);
    try testing.expectEqualStrings("x == 0 and y > 1", tokens.items[1].text);
    try testing.expectEqual(TokenType.guard_close, tokens.items[2].type);
}

test "multiple pseudo-states on same line" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "[*] --> [*]");
    defer tokens.deinit();

    try testing.expectEqual(TokenType.pseudo_start_end, tokens.items[0].type);
    try testing.expectEqual(TokenType.transition_op, tokens.items[1].type);
    try testing.expectEqual(TokenType.pseudo_start_end, tokens.items[2].type);
}

test "stereotype with join" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "state joinState <<join>>");
    defer tokens.deinit();

    var found_join = false;
    for (tokens.items) |tok| {
        if (tok.type == .identifier and std.mem.eql(u8, tok.text, "join")) {
            found_join = true;
        }
    }
    try testing.expect(found_join);
}

test "stereotype with choice" {
    const allocator = testing.allocator;
    var tokens = try tokenize(allocator, "state choiceState <<choice>>");
    defer tokens.deinit();

    var found_choice = false;
    for (tokens.items) |tok| {
        if (tok.type == .identifier and std.mem.eql(u8, tok.text, "choice")) {
            found_choice = true;
        }
    }
    try testing.expect(found_choice);
}

test "token line numbers increment across newlines" {
    const allocator = testing.allocator;
    const src = "A\n--\nB";
    var tokens = try tokenize(allocator, src);
    defer tokens.deinit();

    // A → line 1, newline → line 1, -- → line 2, newline → line 2, B → line 3
    var a_line: u32 = 0;
    var sep_line: u32 = 0;
    var b_line: u32 = 0;

    for (tokens.items) |tok| {
        if (tok.type == .identifier and std.mem.eql(u8, tok.text, "A")) a_line = tok.line;
        if (tok.type == .region_sep) sep_line = tok.line;
        if (tok.type == .identifier and std.mem.eql(u8, tok.text, "B")) b_line = tok.line;
    }

    try testing.expectEqual(@as(u32, 1), a_line);
    try testing.expectEqual(@as(u32, 2), sep_line);
    try testing.expectEqual(@as(u32, 3), b_line);
}
