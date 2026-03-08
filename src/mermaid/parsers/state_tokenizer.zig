/// stateDiagram-v2 tokenizer.
///
/// Converts raw stateDiagram-v2 source text into a flat list of typed tokens.
/// Each token tag corresponds to exactly one terminal symbol in the grammar
/// production rules used by the recursive-descent parser (state_rd_parser.zig).
///
/// Grammar terminals defined here:
///   header      → kw_stateDiagram_v2 | kw_stateDiagram
///   keyword     → kw_state | kw_note | kw_end | kw_direction | kw_as | kw_of
///                 | kw_right | kw_left
///   direction   → dir_lr | dir_rl | dir_tb | dir_bt
///   operator    → arrow | separator | lbrace | rbrace | colon
///   pseudo      → pseudo_start | pseudo_history | pseudo_deep_history
///   annotation  → angle_fork | angle_join | angle_choice
///   literal     → identifier | string_literal | label_text
///   other       → comment | newline | eof

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Token tags for stateDiagram-v2.
/// Each tag maps to a unique terminal in the grammar.
pub const TokenTag = enum {
    // ── Diagram header ────────────────────────────────────────────────────────
    /// "stateDiagram-v2"
    kw_stateDiagram_v2,
    /// "stateDiagram"
    kw_stateDiagram,

    // ── Statement keywords ────────────────────────────────────────────────────
    /// "state"
    kw_state,
    /// "note"
    kw_note,
    /// "end"  (used in "end note")
    kw_end,
    /// "direction"
    kw_direction,
    /// "as"
    kw_as,
    /// "of"
    kw_of,
    /// "right"
    kw_right,
    /// "left"
    kw_left,

    // ── Direction values ──────────────────────────────────────────────────────
    /// "LR" | "lr"
    dir_lr,
    /// "RL" | "rl"
    dir_rl,
    /// "TB" | "tb" | "TD" | "td"
    dir_tb,
    /// "BT" | "bt"
    dir_bt,

    // ── Operators and delimiters ──────────────────────────────────────────────
    /// "-->"  transition arrow
    arrow,
    /// "--"   orthogonal region separator (inside composite state bodies)
    separator,
    /// "{"    open composite state body
    lbrace,
    /// "}"    close composite state body
    rbrace,
    /// ":"    precedes a transition label or inline note text
    colon,

    // ── Pseudo-state identifiers ──────────────────────────────────────────────
    /// "[*]"   initial / terminal pseudo-state
    pseudo_start,
    /// "[H]"   shallow-history pseudo-state
    pseudo_history,
    /// "[H*]"  deep-history pseudo-state
    pseudo_deep_history,

    // ── State type annotations ────────────────────────────────────────────────
    /// "<<fork>>"
    angle_fork,
    /// "<<join>>"
    angle_join,
    /// "<<choice>>"
    angle_choice,

    // ── Literals ─────────────────────────────────────────────────────────────
    /// General identifier: letters, digits, underscores, and hyphens.
    /// Hyphens are included so state names like "my-state" and the
    /// "stateDiagram-v2" header keyword tokenize as single tokens.
    identifier,
    /// Quoted string:  "..."
    string_literal,
    /// Raw text following a ":" on the same source line (trimmed).
    /// Produced immediately after a `colon` token when non-whitespace
    /// content exists on the rest of the line.
    label_text,

    // ── Structural ────────────────────────────────────────────────────────────
    /// "%% ..." Mermaid line comment
    comment,
    /// Line-feed character
    newline,
    /// End of input sentinel
    eof,
};

/// A single token.  The `text` slice borrows from the original source string
/// and is valid as long as the source outlives the token list.
pub const Token = struct {
    tag: TokenTag,
    text: []const u8,
};

/// Tokenize `source` into a list of stateDiagram-v2 tokens.
///
/// Ownership: caller owns the returned `ArrayList` and must call `.deinit()`.
/// Token `.text` slices point into `source`; `source` must outlive the list.
pub fn tokenize(allocator: Allocator, source: []const u8) !std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    while (i < source.len) {
        const ch = source[i];

        // ── Horizontal whitespace ─────────────────────────────────────────────
        if (ch == ' ' or ch == '\t') {
            i += 1;
            continue;
        }

        // ── Carriage return (treat \r\n as single newline via the \n rule) ────
        if (ch == '\r') {
            i += 1;
            continue;
        }

        // ── Newline ───────────────────────────────────────────────────────────
        if (ch == '\n') {
            try tokens.append(.{ .tag = .newline, .text = source[i .. i + 1] });
            i += 1;
            continue;
        }

        // ── Comment: %% until end of line ────────────────────────────────────
        if (ch == '%' and i + 1 < source.len and source[i + 1] == '%') {
            const start = i;
            while (i < source.len and source[i] != '\n') i += 1;
            try tokens.append(.{ .tag = .comment, .text = source[start..i] });
            continue;
        }

        // ── Pseudo-state identifiers: [*], [H], [H*] ─────────────────────────
        // Longer patterns checked first (longest-match rule).
        if (ch == '[') {
            // [H*] must be checked before [H]
            if (i + 3 < source.len and source[i + 1] == 'H' and
                source[i + 2] == '*' and source[i + 3] == ']')
            {
                try tokens.append(.{ .tag = .pseudo_deep_history, .text = source[i .. i + 4] });
                i += 4;
                continue;
            }
            if (i + 2 < source.len and source[i + 1] == '*' and source[i + 2] == ']') {
                try tokens.append(.{ .tag = .pseudo_start, .text = source[i .. i + 3] });
                i += 3;
                continue;
            }
            if (i + 2 < source.len and source[i + 1] == 'H' and source[i + 2] == ']') {
                try tokens.append(.{ .tag = .pseudo_history, .text = source[i .. i + 3] });
                i += 3;
                continue;
            }
            // Unknown bracket — skip
            i += 1;
            continue;
        }

        // ── State type annotations: <<fork>>, <<join>>, <<choice>> ────────────
        if (ch == '<' and i + 1 < source.len and source[i + 1] == '<') {
            const rest = source[i..];
            if (std.mem.startsWith(u8, rest, "<<fork>>")) {
                try tokens.append(.{ .tag = .angle_fork, .text = source[i .. i + 8] });
                i += 8;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<<join>>")) {
                try tokens.append(.{ .tag = .angle_join, .text = source[i .. i + 8] });
                i += 8;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<<choice>>")) {
                try tokens.append(.{ .tag = .angle_choice, .text = source[i .. i + 10] });
                i += 10;
                continue;
            }
            // Unknown << — skip both chars
            i += 2;
            continue;
        }

        // ── Arrow --> or concurrency separator -- ─────────────────────────────
        if (ch == '-' and i + 1 < source.len and source[i + 1] == '-') {
            if (i + 2 < source.len and source[i + 2] == '>') {
                try tokens.append(.{ .tag = .arrow, .text = source[i .. i + 3] });
                i += 3;
                continue;
            }
            try tokens.append(.{ .tag = .separator, .text = source[i .. i + 2] });
            i += 2;
            continue;
        }

        // ── Braces ────────────────────────────────────────────────────────────
        if (ch == '{') {
            try tokens.append(.{ .tag = .lbrace, .text = source[i .. i + 1] });
            i += 1;
            continue;
        }
        if (ch == '}') {
            try tokens.append(.{ .tag = .rbrace, .text = source[i .. i + 1] });
            i += 1;
            continue;
        }

        // ── Colon: emit colon, then collect rest of line as label_text ────────
        if (ch == ':') {
            try tokens.append(.{ .tag = .colon, .text = source[i .. i + 1] });
            i += 1;
            // Skip leading whitespace on the same line
            while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
            const text_start = i;
            while (i < source.len and source[i] != '\n') i += 1;
            // Trim trailing whitespace
            var text_end = i;
            while (text_end > text_start and
                (source[text_end - 1] == ' ' or source[text_end - 1] == '\t' or
                source[text_end - 1] == '\r'))
            {
                text_end -= 1;
            }
            if (text_end > text_start) {
                try tokens.append(.{ .tag = .label_text, .text = source[text_start..text_end] });
            }
            continue;
        }

        // ── Quoted string literal ─────────────────────────────────────────────
        if (ch == '"') {
            const start = i;
            i += 1; // skip opening quote
            while (i < source.len and source[i] != '"' and source[i] != '\n') i += 1;
            if (i < source.len and source[i] == '"') i += 1; // skip closing quote
            try tokens.append(.{ .tag = .string_literal, .text = source[start..i] });
            continue;
        }

        // ── Identifier or keyword ─────────────────────────────────────────────
        if (isIdentStart(ch)) {
            const start = i;
            i += 1;
            while (i < source.len) {
                const c = source[i];
                // Stop before "--" so arrows are not consumed by the identifier rule.
                // e.g. "A--> B" must lex as identifier("A") + arrow("-->").
                if (c == '-' and i + 1 < source.len and source[i + 1] == '-') break;
                if (!isIdentContinue(c)) break;
                i += 1;
            }
            const word = source[start..i];
            try tokens.append(.{ .tag = classifyWord(word), .text = word });
            continue;
        }

        // ── Numeric literal (emit as identifier for label reconstruction) ──────
        // Digits can appear standalone in note content, state labels, etc.
        if (ch >= '0' and ch <= '9') {
            const start = i;
            while (i < source.len and source[i] >= '0' and source[i] <= '9') i += 1;
            try tokens.append(.{ .tag = .identifier, .text = source[start..i] });
            continue;
        }

        // ── Unknown character — skip ───────────────────────────────────────────
        i += 1;
    }

    try tokens.append(.{ .tag = .eof, .text = "" });
    return tokens;
}

// ── Character classification helpers ─────────────────────────────────────────

fn isIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        ch == '_';
}

/// Identifier continuation characters: letters, digits, underscores, hyphens.
/// Hyphens allow state names such as "my-state" and the "stateDiagram-v2"
/// header to be emitted as a single token.
fn isIdentContinue(ch: u8) bool {
    return isIdentStart(ch) or
        (ch >= '0' and ch <= '9') or
        ch == '-';
}

/// Map a raw word to its keyword tag, or `.identifier` if not a keyword.
fn classifyWord(word: []const u8) TokenTag {
    // Header keywords (checked first so they override bare "stateDiagram")
    if (std.mem.eql(u8, word, "stateDiagram-v2")) return .kw_stateDiagram_v2;
    if (std.mem.eql(u8, word, "stateDiagram")) return .kw_stateDiagram;
    // Statement keywords
    if (std.mem.eql(u8, word, "state")) return .kw_state;
    if (std.mem.eql(u8, word, "note")) return .kw_note;
    if (std.mem.eql(u8, word, "end")) return .kw_end;
    if (std.mem.eql(u8, word, "direction")) return .kw_direction;
    if (std.mem.eql(u8, word, "as")) return .kw_as;
    if (std.mem.eql(u8, word, "of")) return .kw_of;
    if (std.mem.eql(u8, word, "right")) return .kw_right;
    if (std.mem.eql(u8, word, "left")) return .kw_left;
    // Direction values
    if (std.mem.eql(u8, word, "LR") or std.mem.eql(u8, word, "lr")) return .dir_lr;
    if (std.mem.eql(u8, word, "RL") or std.mem.eql(u8, word, "rl")) return .dir_rl;
    if (std.mem.eql(u8, word, "TB") or std.mem.eql(u8, word, "tb") or
        std.mem.eql(u8, word, "TD") or std.mem.eql(u8, word, "td")) return .dir_tb;
    if (std.mem.eql(u8, word, "BT") or std.mem.eql(u8, word, "bt")) return .dir_bt;
    return .identifier;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "tokenize: empty input produces only eof" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "");
    defer toks.deinit();
    try testing.expectEqual(@as(usize, 1), toks.items.len);
    try testing.expectEqual(TokenTag.eof, toks.items[0].tag);
}

test "tokenize: stateDiagram-v2 header" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "stateDiagram-v2");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.kw_stateDiagram_v2, toks.items[0].tag);
    try testing.expectEqualStrings("stateDiagram-v2", toks.items[0].text);
}

test "tokenize: stateDiagram header (without v2)" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "stateDiagram");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.kw_stateDiagram, toks.items[0].tag);
}

test "tokenize: arrow -->" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "A --> B");
    defer toks.deinit();
    // identifier, arrow, identifier, eof
    try testing.expectEqual(TokenTag.identifier, toks.items[0].tag);
    try testing.expectEqual(TokenTag.arrow, toks.items[1].tag);
    try testing.expectEqualStrings("-->", toks.items[1].text);
    try testing.expectEqual(TokenTag.identifier, toks.items[2].tag);
}

test "tokenize: separator --" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "--");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.separator, toks.items[0].tag);
    try testing.expectEqualStrings("--", toks.items[0].text);
}

test "tokenize: pseudo-states" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "[*] [H] [H*]");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.pseudo_start, toks.items[0].tag);
    try testing.expectEqual(TokenTag.pseudo_history, toks.items[1].tag);
    try testing.expectEqual(TokenTag.pseudo_deep_history, toks.items[2].tag);
}

test "tokenize: angle annotations" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "<<fork>> <<join>> <<choice>>");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.angle_fork, toks.items[0].tag);
    try testing.expectEqual(TokenTag.angle_join, toks.items[1].tag);
    try testing.expectEqual(TokenTag.angle_choice, toks.items[2].tag);
}

test "tokenize: lbrace rbrace" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "{ }");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.lbrace, toks.items[0].tag);
    try testing.expectEqual(TokenTag.rbrace, toks.items[1].tag);
}

test "tokenize: colon produces label_text for rest of line" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "A --> B : transition label");
    defer toks.deinit();
    // identifier, arrow, identifier, colon, label_text, eof
    const colon_idx: usize = blk: {
        for (toks.items, 0..) |t, idx| {
            if (t.tag == .colon) break :blk idx;
        }
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(TokenTag.label_text, toks.items[colon_idx + 1].tag);
    try testing.expectEqualStrings("transition label", toks.items[colon_idx + 1].text);
}

test "tokenize: empty colon produces no label_text" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "A :");
    defer toks.deinit();
    // identifier, colon, eof  (no label_text because nothing follows)
    const last_non_eof = toks.items[toks.items.len - 2];
    try testing.expectEqual(TokenTag.colon, last_non_eof.tag);
}

test "tokenize: string literal" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "\"hello world\"");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.string_literal, toks.items[0].tag);
    try testing.expectEqualStrings("\"hello world\"", toks.items[0].text);
}

test "tokenize: comment skips to end of line" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "%% comment text\nA");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.comment, toks.items[0].tag);
    try testing.expectEqual(TokenTag.newline, toks.items[1].tag);
    try testing.expectEqual(TokenTag.identifier, toks.items[2].tag);
}

test "tokenize: direction keywords" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "direction LR");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.kw_direction, toks.items[0].tag);
    try testing.expectEqual(TokenTag.dir_lr, toks.items[1].tag);
}

test "tokenize: identifier with hyphen (e.g. state name)" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "my-state");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.identifier, toks.items[0].tag);
    try testing.expectEqualStrings("my-state", toks.items[0].text);
}

test "tokenize: identifier stops before -- (arrow scenario)" {
    const allocator = testing.allocator;
    // "A--> B" — hyphenated ident-start followed immediately by arrow
    var toks = try tokenize(allocator, "A--> B");
    defer toks.deinit();
    // Should produce: identifier("A"), arrow("-->"), identifier("B"), eof
    try testing.expectEqual(TokenTag.identifier, toks.items[0].tag);
    try testing.expectEqualStrings("A", toks.items[0].text);
    try testing.expectEqual(TokenTag.arrow, toks.items[1].tag);
    try testing.expectEqual(TokenTag.identifier, toks.items[2].tag);
}

test "tokenize: newline and carriage return" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "A\r\nB");
    defer toks.deinit();
    // identifier, newline, identifier, eof (\r is skipped)
    try testing.expectEqual(TokenTag.identifier, toks.items[0].tag);
    try testing.expectEqual(TokenTag.newline, toks.items[1].tag);
    try testing.expectEqual(TokenTag.identifier, toks.items[2].tag);
}

test "tokenize: keywords recognized case-sensitively" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "state note end direction as of right left");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.kw_state, toks.items[0].tag);
    try testing.expectEqual(TokenTag.kw_note, toks.items[1].tag);
    try testing.expectEqual(TokenTag.kw_end, toks.items[2].tag);
    try testing.expectEqual(TokenTag.kw_direction, toks.items[3].tag);
    try testing.expectEqual(TokenTag.kw_as, toks.items[4].tag);
    try testing.expectEqual(TokenTag.kw_of, toks.items[5].tag);
    try testing.expectEqual(TokenTag.kw_right, toks.items[6].tag);
    try testing.expectEqual(TokenTag.kw_left, toks.items[7].tag);
}

test "tokenize: all direction values" {
    const allocator = testing.allocator;
    var toks = try tokenize(allocator, "LR RL TB TD BT lr rl tb td bt");
    defer toks.deinit();
    try testing.expectEqual(TokenTag.dir_lr, toks.items[0].tag);
    try testing.expectEqual(TokenTag.dir_rl, toks.items[1].tag);
    try testing.expectEqual(TokenTag.dir_tb, toks.items[2].tag);
    try testing.expectEqual(TokenTag.dir_tb, toks.items[3].tag); // TD also maps to dir_tb
    try testing.expectEqual(TokenTag.dir_bt, toks.items[4].tag);
    try testing.expectEqual(TokenTag.dir_lr, toks.items[5].tag); // lowercase
    try testing.expectEqual(TokenTag.dir_rl, toks.items[6].tag);
    try testing.expectEqual(TokenTag.dir_tb, toks.items[7].tag);
    try testing.expectEqual(TokenTag.dir_tb, toks.items[8].tag);
    try testing.expectEqual(TokenTag.dir_bt, toks.items[9].tag);
}

test "tokenize: full simple diagram" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Active : start
        \\    Active --> [*]
    ;
    var toks = try tokenize(allocator, src);
    defer toks.deinit();

    // Must contain at least: header, newlines, pseudo_start, arrow, ident,
    // ident, arrow, ident, colon, label_text, ident, arrow, pseudo_start, eof
    var has_header = false;
    var has_arrow = false;
    var has_colon = false;
    var has_label = false;
    for (toks.items) |t| {
        if (t.tag == .kw_stateDiagram_v2) has_header = true;
        if (t.tag == .arrow) has_arrow = true;
        if (t.tag == .colon) has_colon = true;
        if (t.tag == .label_text) has_label = true;
    }
    try testing.expect(has_header);
    try testing.expect(has_arrow);
    try testing.expect(has_colon);
    try testing.expect(has_label);
}
