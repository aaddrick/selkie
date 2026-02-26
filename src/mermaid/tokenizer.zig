const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenType = enum {
    keyword,
    identifier,
    string_literal,
    arrow,
    pipe,
    open_bracket,
    close_bracket,
    colon,
    semicolon,
    newline,
    number,
    comment,
    eof,
};

pub const BracketKind = enum {
    square, // [ ]
    round, // ( )
    curly, // { }
    double_round, // (( ))
    curly_square, // [{ }]
    slash, // [/ /]
    backslash, // [\ \]
};

pub const ArrowStyle = enum {
    solid, // -->
    dotted, // -.->
    thick, // ==>
};

pub const ArrowHeadType = enum {
    arrow, // >
    circle, // o
    cross, // x
    none, // --
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,
    arrow_style: ArrowStyle = .solid,
    arrow_head: ArrowHeadType = .arrow,
    bracket_kind: BracketKind = .square,
};

pub fn tokenize(allocator: Allocator, source: []const u8) !std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).init(allocator);
    var i: usize = 0;

    while (i < source.len) {
        const ch = source[i];

        // Skip spaces and tabs (but not newlines)
        if (ch == ' ' or ch == '\t') {
            i += 1;
            continue;
        }

        // Newline
        if (ch == '\n') {
            try tokens.append(.{ .type = .newline, .text = source[i .. i + 1] });
            i += 1;
            continue;
        }

        // Carriage return (skip, handle \r\n as single newline)
        if (ch == '\r') {
            i += 1;
            continue;
        }

        // Comments: %%
        if (ch == '%' and i + 1 < source.len and source[i + 1] == '%') {
            const start = i;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            try tokens.append(.{ .type = .comment, .text = source[start..i] });
            continue;
        }

        // Pipe
        if (ch == '|') {
            try tokens.append(.{ .type = .pipe, .text = source[i .. i + 1] });
            i += 1;
            continue;
        }

        // Semicolon
        if (ch == ';') {
            try tokens.append(.{ .type = .semicolon, .text = source[i .. i + 1] });
            i += 1;
            continue;
        }

        // Colon
        if (ch == ':') {
            try tokens.append(.{ .type = .colon, .text = source[i .. i + 1] });
            i += 1;
            continue;
        }

        // Quoted strings
        if (ch == '"') {
            const start = i;
            i += 1; // skip opening quote
            while (i < source.len and source[i] != '"') : (i += 1) {}
            if (i < source.len) i += 1; // skip closing quote
            try tokens.append(.{ .type = .string_literal, .text = source[start..i] });
            continue;
        }

        // Arrows and dashes: detect -->, -.-> , ==>, --x, --o, ---
        if (ch == '-' or ch == '=') {
            if (tryParseArrow(source, i)) |result| {
                try tokens.append(.{
                    .type = .arrow,
                    .text = source[i..result.end],
                    .arrow_style = result.style,
                    .arrow_head = result.head,
                });
                i = result.end;
                continue;
            }
        }

        // Brackets: [, ], (, ), {, }
        // Multi-char brackets: ((, )), [{, }], [/, /], [\, \]
        if (ch == '[') {
            if (i + 1 < source.len) {
                if (source[i + 1] == '(') {
                    // Could be [( but we treat [( as two tokens; use double_round for ((
                    try tokens.append(.{ .type = .open_bracket, .text = source[i .. i + 1], .bracket_kind = .square });
                    i += 1;
                    continue;
                }
                if (source[i + 1] == '{') {
                    try tokens.append(.{ .type = .open_bracket, .text = source[i .. i + 2], .bracket_kind = .curly_square });
                    i += 2;
                    continue;
                }
                if (source[i + 1] == '/') {
                    try tokens.append(.{ .type = .open_bracket, .text = source[i .. i + 2], .bracket_kind = .slash });
                    i += 2;
                    continue;
                }
                if (source[i + 1] == '\\') {
                    try tokens.append(.{ .type = .open_bracket, .text = source[i .. i + 2], .bracket_kind = .backslash });
                    i += 2;
                    continue;
                }
            }
            try tokens.append(.{ .type = .open_bracket, .text = source[i .. i + 1], .bracket_kind = .square });
            i += 1;
            continue;
        }

        if (ch == '(') {
            if (i + 1 < source.len and source[i + 1] == '(') {
                try tokens.append(.{ .type = .open_bracket, .text = source[i .. i + 2], .bracket_kind = .double_round });
                i += 2;
                continue;
            }
            try tokens.append(.{ .type = .open_bracket, .text = source[i .. i + 1], .bracket_kind = .round });
            i += 1;
            continue;
        }

        if (ch == '{') {
            try tokens.append(.{ .type = .open_bracket, .text = source[i .. i + 1], .bracket_kind = .curly });
            i += 1;
            continue;
        }

        // Closing brackets
        if (ch == ']') {
            try tokens.append(.{ .type = .close_bracket, .text = source[i .. i + 1], .bracket_kind = .square });
            i += 1;
            continue;
        }

        if (ch == ')') {
            if (i + 1 < source.len and source[i + 1] == ')') {
                try tokens.append(.{ .type = .close_bracket, .text = source[i .. i + 2], .bracket_kind = .double_round });
                i += 2;
                continue;
            }
            try tokens.append(.{ .type = .close_bracket, .text = source[i .. i + 1], .bracket_kind = .round });
            i += 1;
            continue;
        }

        if (ch == '}') {
            if (i + 1 < source.len and source[i + 1] == ']') {
                try tokens.append(.{ .type = .close_bracket, .text = source[i .. i + 2], .bracket_kind = .curly_square });
                i += 2;
                continue;
            }
            try tokens.append(.{ .type = .close_bracket, .text = source[i .. i + 1], .bracket_kind = .curly });
            i += 1;
            continue;
        }

        // Closing slash bracket
        if (ch == '/' and i + 1 < source.len and source[i + 1] == ']') {
            try tokens.append(.{ .type = .close_bracket, .text = source[i .. i + 2], .bracket_kind = .slash });
            i += 2;
            continue;
        }

        // Closing backslash bracket
        if (ch == '\\' and i + 1 < source.len and source[i + 1] == ']') {
            try tokens.append(.{ .type = .close_bracket, .text = source[i .. i + 2], .bracket_kind = .backslash });
            i += 2;
            continue;
        }

        // Numbers
        if (ch >= '0' and ch <= '9') {
            const start = i;
            while (i < source.len and source[i] >= '0' and source[i] <= '9') : (i += 1) {}
            try tokens.append(.{ .type = .number, .text = source[start..i] });
            continue;
        }

        // Identifiers and keywords
        if (isIdentChar(ch)) {
            const start = i;
            while (i < source.len and isIdentChar(source[i])) : (i += 1) {}
            const word = source[start..i];
            const tok_type: TokenType = if (isKeyword(word)) .keyword else .identifier;
            try tokens.append(.{ .type = tok_type, .text = word });
            continue;
        }

        // Skip unknown characters
        i += 1;
    }

    try tokens.append(.{ .type = .eof, .text = "" });
    return tokens;
}

const ArrowParseResult = struct {
    end: usize,
    style: ArrowStyle,
    head: ArrowHeadType,
};

fn tryParseArrow(source: []const u8, start: usize) ?ArrowParseResult {
    const i = start;
    const ch = source[i];

    // Thick arrow: ==>
    if (ch == '=' and i + 2 < source.len and source[i + 1] == '=' and source[i + 2] == '>') {
        return .{ .end = i + 3, .style = .thick, .head = .arrow };
    }

    // Dotted arrow: -.-> or -..->
    if (ch == '-' and i + 1 < source.len and source[i + 1] == '.') {
        var j = i + 1;
        while (j < source.len and source[j] == '.') : (j += 1) {}
        if (j < source.len and source[j] == '-') {
            j += 1;
            if (j < source.len and source[j] == '>') {
                return .{ .end = j + 1, .style = .dotted, .head = .arrow };
            }
        }
    }

    // Solid arrow: -->, --x, --o, ---
    if (ch == '-' and i + 1 < source.len and source[i + 1] == '-') {
        var j = i + 2;
        // Skip extra dashes
        while (j < source.len and source[j] == '-') : (j += 1) {}
        if (j > i + 2 and (j >= source.len or source[j] != '>' and source[j] != 'x' and source[j] != 'o')) {
            // Plain line segment: --- (no arrowhead)
            return .{ .end = j, .style = .solid, .head = .none };
        }
        if (j < source.len) {
            if (source[j] == '>') return .{ .end = j + 1, .style = .solid, .head = .arrow };
            if (source[j] == 'x') return .{ .end = j + 1, .style = .solid, .head = .cross };
            if (source[j] == 'o') return .{ .end = j + 1, .style = .solid, .head = .circle };
        }
        // Just -- with no head: treat as arrow with no head
        return .{ .end = j, .style = .solid, .head = .none };
    }

    return null;
}

fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_' or ch == '-';
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "graph",
        "flowchart",
        "subgraph",
        "end",
        "sequenceDiagram",
        "classDiagram",
        "stateDiagram",
        "erDiagram",
        "gantt",
        "pie",
        "gitgraph",
        "TD",
        "TB",
        "BT",
        "LR",
        "RL",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}
