/// Recursive-descent parser for stateDiagram-v2.
///
/// Consumes tokens produced by `state_lexer.tokenize()` (Sub-AC 5b) and builds
/// an Abstract Syntax Tree (AST) representing the full nested structure of the
/// input diagram.
///
/// Grammar production rules (each maps to a dedicated parsing function):
///
///   diagram          → header statement* EOF
///   header           → KW_STATE_DIAGRAM_V2 | KW_STATE_DIAGRAM
///   statement        → directive
///                    | region_separator
///                    | composite_state        ← recursive via parseStatements
///                    | state_type_decl
///                    | state_decl_with_label
///                    | simple_state
///                    | note
///                    | transition
///                    | NEWLINE | COMMENT
///   directive        → KW_DIRECTION IDENTIFIER
///   region_separator → REGION_SEP
///   composite_state  → KW_STATE id_spec OPEN_BRACE statement* CLOSE_BRACE
///   id_spec          → STRING_LITERAL KW_AS IDENTIFIER | IDENTIFIER
///   state_type_decl  → KW_STATE IDENTIFIER STEREO_OPEN ("fork"|"join"|"choice") STEREO_CLOSE
///   simple_state     → KW_STATE id_spec
///   note             → KW_NOTE (KW_RIGHT|KW_LEFT) KW_OF state_ref note_body
///   note_body        → COLON label_tokens NEWLINE
///                    | NEWLINE body_line* KW_END KW_NOTE
///   transition       → state_ref TRANSITION_OP state_ref (COLON label_tokens)?
///   state_ref        → IDENTIFIER | PSEUDO_START_END | PSEUDO_HISTORY | PSEUDO_DEEP_HISTORY
///   label_tokens     → (IDENTIFIER | STRING_LITERAL | COLON | ...)* until NEWLINE

const std = @import("std");
const Allocator = std.mem.Allocator;

// Sub-AC 5b: the stateDiagram-v2 lexer that produces the tokens we consume.
const sl = @import("state_lexer.zig");
const Token = sl.Token;
const TokenType = sl.TokenType;

const sm = @import("../models/state_model.zig");
const StateModel = sm.StateModel;
const StateType = sm.StateType;
const NotePosition = sm.NotePosition;

// =============================================================================
// AST Node Types
// =============================================================================

/// Position of a note annotation relative to the referenced state.
pub const AstNotePosition = enum { left, right };

/// Stereotype kind from `state ID <<fork|join|choice|entryPoint|exitPoint>>`.
pub const AstStateKind = enum { fork, join, choice, entry_point, exit_point };

/// Direction from `direction LR|RL|TB|BT`.
pub const AstDirection = enum { lr, rl, tb, bt };

/// A state reference in a transition or note (`state_ref` in the grammar).
pub const StateRef = union(enum) {
    id: []const u8,
    pseudo_start_end,
    pseudo_history,
    pseudo_deep_history,

    pub fn text(self: StateRef) []const u8 {
        return switch (self) {
            .id => |s| s,
            .pseudo_start_end => "[*]",
            .pseudo_history => "[H]",
            .pseudo_deep_history => "[H*]",
        };
    }
};

/// AST node for a simple state: `state ID` or `state "Label" as ID`.
pub const AstSimpleState = struct {
    id: []const u8,
    /// Human-readable label from `state "Label" as ID` syntax.
    label: ?[]const u8 = null,
};

/// AST node for a state type annotation: `state ID <<fork|join|choice>>`.
pub const AstStateTypeDecl = struct {
    id: []const u8,
    kind: AstStateKind,
};

/// AST node for a transition: `state_ref --> state_ref (: label)?`
pub const AstTransition = struct {
    from: []const u8,
    to: []const u8,
    /// Transition label text (joined from multiple tokens).  Points into
    /// `DiagramAst.owned_strings` when non-null.
    label: ?[]const u8 = null,
};

/// AST node for a note annotation.
pub const AstNote = struct {
    state_id: []const u8,
    position: AstNotePosition,
    /// Note body text.  Always points into `DiagramAst.owned_strings`.
    text: []const u8,
};

/// A composite state with a recursively nested body.
/// Heap-allocated (via `allocator.create`) so that `AstNode` remains fixed-size.
pub const CompositeState = struct {
    id: []const u8,
    /// Optional label from `state "Label" as ID { ... }` syntax.
    label: ?[]const u8 = null,
    /// Body statements — may contain further `CompositeState` nodes.
    body: std.ArrayList(AstNode),

    pub fn deinit(self: *CompositeState, allocator: Allocator) void {
        for (self.body.items) |*node| node.deinit(allocator);
        self.body.deinit();
    }
};

/// A single node in the stateDiagram-v2 AST.
///
/// The `.composite_state` variant stores a heap-allocated pointer to keep
/// the union size bounded and allow arbitrarily deep nesting.
pub const AstNode = union(enum) {
    simple_state: AstSimpleState,
    composite_state: *CompositeState,
    state_type_decl: AstStateTypeDecl,
    transition: AstTransition,
    /// `--` orthogonal region separator inside a composite state body.
    region_separator,
    note: AstNote,
    direction: AstDirection,

    pub fn deinit(self: *AstNode, allocator: Allocator) void {
        switch (self.*) {
            .composite_state => |cs| {
                cs.deinit(allocator);
                allocator.destroy(cs);
            },
            else => {},
        }
    }
};

/// The top-level AST for an entire stateDiagram-v2 diagram.
///
/// `owned_strings` accumulates every heap-allocated text fragment (transition
/// labels, multi-line note bodies, etc.) produced during parsing so they are
/// freed together when `deinit()` is called.
pub const DiagramAst = struct {
    allocator: Allocator,
    statements: std.ArrayList(AstNode),
    /// All heap-allocated strings produced during parsing.
    owned_strings: std.ArrayList([]u8),

    pub fn init(allocator: Allocator) DiagramAst {
        return .{
            .allocator = allocator,
            .statements = std.ArrayList(AstNode).init(allocator),
            .owned_strings = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *DiagramAst) void {
        for (self.statements.items) |*node| node.deinit(self.allocator);
        self.statements.deinit();
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit();
    }
};

// =============================================================================
// Recursive Descent Parser
// =============================================================================

/// Recursive-descent parser over a slice of `state_lexer` tokens.
///
/// Owns a pointer into the `DiagramAst.owned_strings` list so that allocated
/// text fragments (labels, note bodies) are automatically freed when the AST
/// is deinited — even if parsing fails partway through.
const Parser = struct {
    allocator: Allocator,
    tokens: []const Token,
    pos: usize,
    /// Sink for all heap-allocated strings produced during parsing.
    owned_strings: *std.ArrayList([]u8),

    // ── Cursor helpers ────────────────────────────────────────────────────────

    fn peek(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return tok;
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.tokens[self.pos].type == .eof;
    }

    fn skipNewlines(self: *Parser) void {
        while (!self.isAtEnd()) {
            const t = self.tokens[self.pos].type;
            if (t != .newline and t != .comment) break;
            self.pos += 1;
        }
    }

    // ── String allocation helpers ─────────────────────────────────────────────

    /// Register `bytes` (already heap-allocated by the caller) in
    /// `owned_strings`.  On error the bytes are freed; on success they are
    /// owned by the AST and must **not** be freed by the caller.
    fn trackString(self: *Parser, bytes: []u8) ParseError![]const u8 {
        errdefer self.allocator.free(bytes);
        try self.owned_strings.append(bytes);
        return bytes;
    }

    /// Collect all remaining tokens on the current line (until `newline` or
    /// EOF) into a heap-allocated string, joining token texts with spaces.
    /// Returns a slice owned by the AST (via `owned_strings`).
    /// Returns null when the line is empty.
    fn collectLineText(self: *Parser) ParseError!?[]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        while (!self.isAtEnd() and self.tokens[self.pos].type != .newline) {
            const tok = self.tokens[self.pos];
            self.pos += 1;
            if (tok.type == .comment) continue;
            if (buf.items.len > 0) try buf.append(' ');
            try buf.appendSlice(tok.text);
        }

        if (buf.items.len == 0) {
            buf.deinit();
            return null;
        }
        const text = try buf.toOwnedSlice();
        return try self.trackString(text);
    }

    /// Collect multi-line note body tokens until `end note` (KW_END KW_NOTE).
    /// Lines are joined with '\n'; blank lines are skipped.
    /// The returned text is owned by the AST (via `owned_strings`).
    fn collectNoteBody(self: *Parser) ParseError![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        var at_line_start = true;
        var emitted_line = false;

        while (!self.isAtEnd()) {
            const tok = self.tokens[self.pos];

            // "end note" terminates the note block.
            if (tok.type == .kw_end) {
                var look = self.pos + 1;
                while (look < self.tokens.len and self.tokens[look].type == .newline) {
                    look += 1;
                }
                if (look < self.tokens.len and self.tokens[look].type == .kw_note) {
                    self.pos = look + 1; // consume past "end note"
                    break;
                }
            }

            if (tok.type == .newline) {
                at_line_start = true;
                self.pos += 1;
                continue;
            }
            if (tok.type == .comment) {
                self.pos += 1;
                continue;
            }

            // Regular content token.
            if (at_line_start) {
                if (emitted_line) try buf.append('\n');
                at_line_start = false;
                emitted_line = true;
                try buf.appendSlice(tok.text);
            } else {
                try buf.append(' ');
                try buf.appendSlice(tok.text);
            }
            self.pos += 1;
        }

        const text = try buf.toOwnedSlice();
        return try self.trackString(text);
    }

    // ── Entry point ───────────────────────────────────────────────────────────

    // Explicit error type is required for mutually-recursive functions so Zig
    // can resolve the error set without cycles.
    const ParseError = error{OutOfMemory};

    fn parseStatements(self: *Parser, out: *std.ArrayList(AstNode), inside_composite: bool) ParseError!void {
        while (!self.isAtEnd()) {
            if (inside_composite and self.tokens[self.pos].type == .close_brace) break;
            if (try self.parseStatement(&out.*)) {}
        }
    }

    // ── Statement dispatch ────────────────────────────────────────────────────

    /// Parse one statement.
    /// Production: statement → directive | region_separator | composite_state
    ///             | state_type_decl | state_decl_with_label | simple_state
    ///             | note | transition | NEWLINE | COMMENT
    fn parseStatement(self: *Parser, out: *std.ArrayList(AstNode)) ParseError!bool {
        const tok = self.peek();
        switch (tok.type) {
            .newline, .comment => {
                _ = self.advance();
                return true;
            },
            .kw_direction => {
                if (try self.parseDirection()) |node| try out.append(node);
                return true;
            },
            .region_sep => {
                _ = self.advance();
                try out.append(AstNode{ .region_separator = {} });
                return true;
            },
            .kw_state => {
                if (try self.parseStateStatement()) |node| try out.append(node);
                return true;
            },
            .kw_note => {
                if (try self.parseNote()) |node| try out.append(node);
                return true;
            },
            .identifier, .pseudo_start_end, .pseudo_history, .pseudo_deep_history => {
                if (try self.parseTransitionOrState()) |node| try out.append(node);
                return true;
            },
            .eof => return false,
            else => {
                _ = self.advance();
                return true;
            },
        }
    }

    // ── Grammar productions ───────────────────────────────────────────────────

    /// direction → KW_DIRECTION IDENTIFIER
    fn parseDirection(self: *Parser) ParseError!?AstNode {
        _ = self.advance(); // consume "direction"
        if (self.isAtEnd() or self.tokens[self.pos].type != .identifier) return null;
        const dir_tok = self.advance();
        const dir: AstDirection = blk: {
            if (std.mem.eql(u8, dir_tok.text, "LR") or std.mem.eql(u8, dir_tok.text, "lr")) break :blk .lr;
            if (std.mem.eql(u8, dir_tok.text, "RL") or std.mem.eql(u8, dir_tok.text, "rl")) break :blk .rl;
            if (std.mem.eql(u8, dir_tok.text, "TB") or std.mem.eql(u8, dir_tok.text, "tb") or
                std.mem.eql(u8, dir_tok.text, "TD") or std.mem.eql(u8, dir_tok.text, "td")) break :blk .tb;
            if (std.mem.eql(u8, dir_tok.text, "BT") or std.mem.eql(u8, dir_tok.text, "bt")) break :blk .bt;
            return null;
        };
        return AstNode{ .direction = dir };
    }

    /// True when the current token is a valid state_ref starter.
    fn isStateRefAt(self: *const Parser) bool {
        return switch (self.tokens[self.pos].type) {
            .identifier, .pseudo_start_end, .pseudo_history, .pseudo_deep_history => true,
            else => false,
        };
    }

    /// state_ref → IDENTIFIER | PSEUDO_START_END | PSEUDO_HISTORY | PSEUDO_DEEP_HISTORY
    /// Returns the canonical string form.
    fn parseStateRef(self: *Parser) ?[]const u8 {
        const tok = self.peek();
        return switch (tok.type) {
            .identifier => {
                _ = self.advance();
                return tok.text;
            },
            .pseudo_start_end => {
                _ = self.advance();
                return "[*]";
            },
            .pseudo_history => {
                _ = self.advance();
                return "[H]";
            },
            .pseudo_deep_history => {
                _ = self.advance();
                return "[H*]";
            },
            else => null,
        };
    }

    /// Dispatch for `state ...` statement variants:
    ///   state_type_decl      → KW_STATE IDENTIFIER STEREO_OPEN kind STEREO_CLOSE
    ///   composite_state      → KW_STATE id_spec OPEN_BRACE statement* CLOSE_BRACE
    ///   state_decl_with_label → KW_STATE STRING_LITERAL KW_AS IDENTIFIER ("{" ...)?
    ///   simple_state         → KW_STATE IDENTIFIER
    fn parseStateStatement(self: *Parser) ParseError!?AstNode {
        _ = self.advance(); // consume "state"

        // state "Description" as ID  (with optional "{")
        if (self.peek().type == .string_literal) {
            return try self.parseStateWithLabel();
        }

        // state IDENTIFIER ...
        if (!self.isStateRefAt()) {
            self.skipLine();
            return null;
        }
        const id_tok = self.advance();
        const id = id_tok.text;

        // state ID <<fork|join|choice|entryPoint|exitPoint>>
        if (self.peek().type == .stereo_open) {
            _ = self.advance(); // consume "<<"
            const kind_opt: ?AstStateKind = blk: {
                if (self.peek().type != .identifier) {
                    break :blk null;
                }
                const kind_text = self.advance().text;
                // Consume closing ">>"
                if (self.peek().type == .stereo_close) _ = self.advance();
                if (std.mem.eql(u8, kind_text, "fork")) break :blk .fork;
                if (std.mem.eql(u8, kind_text, "join")) break :blk .join;
                if (std.mem.eql(u8, kind_text, "choice")) break :blk .choice;
                // UML entry/exit point pseudo-states
                if (std.mem.eql(u8, kind_text, "entryPoint")) break :blk .entry_point;
                if (std.mem.eql(u8, kind_text, "exitPoint")) break :blk .exit_point;
                break :blk null;
            };
            if (kind_opt) |kind| {
                return AstNode{ .state_type_decl = .{ .id = id, .kind = kind } };
            }
            return AstNode{ .simple_state = .{ .id = id } };
        }

        // state ID {  (composite state — RECURSIVE)
        if (self.peek().type == .open_brace) {
            _ = self.advance(); // consume "{"
            return try self.parseCompositeBody(id, null);
        }

        // state ID  (simple declaration)
        return AstNode{ .simple_state = .{ .id = id } };
    }

    /// state "Description" as ID  (optionally followed by "{" body "}")
    fn parseStateWithLabel(self: *Parser) ParseError!?AstNode {
        const str_tok = self.advance(); // consume string_literal
        const desc: []const u8 = if (str_tok.text.len >= 2 and str_tok.text[0] == '"')
            str_tok.text[1 .. str_tok.text.len - 1]
        else
            str_tok.text;

        // Expect "as"
        if (self.peek().type != .kw_as) {
            return AstNode{ .simple_state = .{ .id = desc, .label = desc } };
        }
        _ = self.advance(); // consume "as"

        // Expect IDENTIFIER
        if (!self.isStateRefAt()) return null;
        const id = self.advance().text;

        // Optional "{" for a composite body
        if (self.peek().type == .open_brace) {
            _ = self.advance(); // consume "{"
            return try self.parseCompositeBody(id, desc);
        }

        return AstNode{ .simple_state = .{ .id = id, .label = desc } };
    }

    /// composite_state → (already consumed KW_STATE id_spec OPEN_BRACE)
    ///                    statement* CLOSE_BRACE
    ///
    /// *** This is the RECURSIVE step ***:
    ///   parseStatements → parseStatement → parseStateStatement → parseCompositeBody
    fn parseCompositeBody(self: *Parser, id: []const u8, label: ?[]const u8) ParseError!AstNode {
        const cs = try self.allocator.create(CompositeState);
        errdefer self.allocator.destroy(cs);

        cs.* = CompositeState{
            .id = id,
            .label = label,
            .body = std.ArrayList(AstNode).init(self.allocator),
        };
        errdefer cs.deinit(self.allocator);

        // Recurse: parse body statements until "}" or EOF.
        try self.parseStatements(&cs.body, true);

        // Consume closing "}"
        if (!self.isAtEnd() and self.tokens[self.pos].type == .close_brace) {
            _ = self.advance();
        }

        return AstNode{ .composite_state = cs };
    }

    /// note → KW_NOTE (KW_RIGHT|KW_LEFT) KW_OF state_ref note_body
    /// note_body → COLON label_tokens NEWLINE | NEWLINE ... KW_END KW_NOTE
    fn parseNote(self: *Parser) ParseError!?AstNode {
        _ = self.advance(); // consume "note"

        const pos_tok = self.peek();
        const position: AstNotePosition = switch (pos_tok.type) {
            .kw_right => blk: {
                _ = self.advance();
                break :blk .right;
            },
            .kw_left => blk: {
                _ = self.advance();
                break :blk .left;
            },
            else => return null,
        };

        // Expect "of"
        if (self.peek().type != .kw_of) return null;
        _ = self.advance();

        // State reference
        const state_id = self.parseStateRef() orelse return null;

        // Inline note: ": text tokens…"
        if (self.peek().type == .colon) {
            _ = self.advance(); // consume ":"
            const text: []const u8 = (try self.collectLineText()) orelse "";
            return AstNode{ .note = .{ .state_id = state_id, .position = position, .text = text } };
        }

        // Multi-line note: collect body until "end note"
        const text = try self.collectNoteBody();
        return AstNode{ .note = .{ .state_id = state_id, .position = position, .text = text } };
    }

    /// transition → state_ref TRANSITION_OP state_ref (COLON label_tokens)?
    /// Falls back to a simple_state node when no TRANSITION_OP follows.
    fn parseTransitionOrState(self: *Parser) ParseError!?AstNode {
        const from = self.parseStateRef() orelse return null;

        if (self.peek().type == .transition_op) {
            _ = self.advance(); // consume "-->"
            const to = self.parseStateRef() orelse return null;

            const label: ?[]const u8 = if (self.peek().type == .colon) blk: {
                _ = self.advance(); // consume ":"
                break :blk try self.collectLineText();
            } else null;

            return AstNode{ .transition = .{ .from = from, .to = to, .label = label } };
        }

        // No transition — treat as simple state reference
        return AstNode{ .simple_state = .{ .id = from } };
    }

    // ── Utility ───────────────────────────────────────────────────────────────

    fn skipLine(self: *Parser) void {
        while (!self.isAtEnd() and self.tokens[self.pos].type != .newline) {
            self.pos += 1;
        }
        if (!self.isAtEnd()) self.pos += 1;
    }
};

// =============================================================================
// Public parse entry point
// =============================================================================

/// Parse `tokens` (from `state_lexer.tokenize`) into a `DiagramAst`.
///
/// Ownership: caller must call `.deinit()` on the returned AST.
pub fn parse(allocator: Allocator, tokens: []const Token) !DiagramAst {
    var ast = DiagramAst.init(allocator);
    errdefer ast.deinit();

    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens,
        .pos = 0,
        .owned_strings = &ast.owned_strings,
    };

    // Skip header line (stateDiagram-v2 | stateDiagram)
    parser.skipNewlines();
    if (!parser.isAtEnd()) {
        const t = parser.peek().type;
        if (t == .kw_state_diagram_v2 or t == .kw_state_diagram) {
            _ = parser.advance();
            // Skip remaining tokens on the header line
            while (!parser.isAtEnd() and parser.tokens[parser.pos].type != .newline) {
                _ = parser.advance();
            }
        }
    }

    // Parse all top-level statements
    try parser.parseStatements(&ast.statements, false);
    return ast;
}

// =============================================================================
// AST → StateModel conversion
// =============================================================================

/// Tokenise `source`, parse into a `DiagramAst`, then convert to a `StateModel`.
///
/// This is a convenience wrapper for the full parsing pipeline:
///   tokenize → parse → astToModel
///
/// The caller owns the returned model and must call `.deinit()`.
pub fn parseToModel(allocator: Allocator, source: []const u8) !StateModel {
    var tokens = try sl.tokenize(allocator, source);
    defer tokens.deinit();

    var ast = try parse(allocator, tokens.items);
    defer ast.deinit();

    return try astToModel(allocator, &ast);
}

/// Convert a `DiagramAst` into a `StateModel`.
///
/// Caller owns the returned model and must call `.deinit()`.
pub fn astToModel(allocator: Allocator, ast: *const DiagramAst) anyerror!StateModel {
    var model = StateModel.init(allocator);
    errdefer model.deinit();

    // Context stacks for nesting: parent_id + region_index at each level.
    var parent_stack = std.ArrayList(?[]const u8).init(allocator);
    defer parent_stack.deinit();
    var region_index_stack = std.ArrayList(?usize).init(allocator);
    defer region_index_stack.deinit();

    // Top-level sentinel (null parent = root)
    try parent_stack.append(null);
    try region_index_stack.append(null);

    try convertStatements(allocator, &model, ast.statements.items, &parent_stack, &region_index_stack);

    // Mark [*] targets as end states
    for (model.transitions.items) |t| {
        if (std.mem.eql(u8, t.to, "[*]")) {
            if (model.findStateMut("[*]_end") == null) {
                var es = try model.ensureState("[*]_end");
                es.state_type = .end;
                es.label = "[*]";
            }
        }
    }

    try model.buildGraph();
    return model;
}

fn convertStatements(
    allocator: Allocator,
    model: *StateModel,
    stmts: []const AstNode,
    parent_stack: *std.ArrayList(?[]const u8),
    region_index_stack: *std.ArrayList(?usize),
) anyerror!void {
    for (stmts) |*node| {
        try convertNode(allocator, model, node, parent_stack, region_index_stack);
    }
}

fn convertNode(
    allocator: Allocator,
    model: *StateModel,
    node: *const AstNode,
    parent_stack: *std.ArrayList(?[]const u8),
    region_index_stack: *std.ArrayList(?usize),
) anyerror!void {
    switch (node.*) {
        .direction => |dir| {
            model.direction = switch (dir) {
                .lr => .lr,
                .rl => .rl,
                .tb => .td,
                .bt => .bt,
            };
        },

        .simple_state => |ss| {
            var state = try ensureStateInCtx(model, parent_stack, region_index_stack, ss.id);
            if (ss.label) |lbl| {
                // Labels from "state "Desc" as ID" come from token text (borrowed
                // from the source string) — the source outlives the model, so no
                // dupe is strictly required.  We dupe for safety so the model's
                // lifetime is independent of the source string.
                const owned_lbl = try model.dupeString(lbl);
                state.label = owned_lbl;
                state.description = owned_lbl;
            }
        },

        .state_type_decl => |d| {
            var state = try ensureStateInCtx(model, parent_stack, region_index_stack, d.id);
            state.state_type = switch (d.kind) {
                .fork => .fork,
                .join => .join,
                .choice => .choice,
                .entry_point => .entry_point,
                .exit_point => .exit_point,
            };
        },

        .transition => |tr| {
            _ = try ensureStateInCtx(model, parent_stack, region_index_stack, tr.from);
            _ = try ensureStateInCtx(model, parent_stack, region_index_stack, tr.to);
            // Dupe the label so the model owns it independently of the AST.
            // Collected label text lives in ast.owned_strings which is freed
            // when the AST is deinited — the model must hold its own copy.
            const owned_label: ?[]const u8 = if (tr.label) |lbl|
                try model.dupeString(lbl)
            else
                null;
            try addTransitionInCtx(model, parent_stack, region_index_stack, tr.from, tr.to, owned_label);
        },

        .region_separator => {
            try handleRegionSeparator(model, parent_stack, region_index_stack);
        },

        .note => |n| {
            const pos: NotePosition = if (n.position == .left) .left else .right;
            // Dupe note text into the model so it survives ast.deinit().
            const owned_text = try model.dupeString(n.text);
            try model.addNote(n.state_id, pos, owned_text);
        },

        // ── Composite state: RECURSIVE descent through body ───────────────────
        .composite_state => |cs| {
            var state = try ensureStateInCtx(model, parent_stack, region_index_stack, cs.id);
            state.state_type = .composite;
            if (cs.label) |lbl| {
                // Dupe label so the model owns it independently.
                const owned_lbl = try model.dupeString(lbl);
                state.label = owned_lbl;
                state.description = owned_lbl;
            }

            try parent_stack.append(cs.id);
            try region_index_stack.append(null);

            // Recurse into the composite body
            try convertStatements(allocator, model, cs.body.items, parent_stack, region_index_stack);

            _ = parent_stack.pop();
            _ = region_index_stack.pop();
        },
    }
}

// ── Context helpers ───────────────────────────────────────────────────────────

fn ensureStateInCtx(
    model: *StateModel,
    parent_stack: *const std.ArrayList(?[]const u8),
    region_index_stack: *const std.ArrayList(?usize),
    id: []const u8,
) !*sm.State {
    const depth = parent_stack.items.len;
    if (depth > 0) {
        const parent_id = parent_stack.items[depth - 1];
        if (parent_id) |pid| {
            if (model.findStateRecursive(pid)) |parent| {
                const region_idx = region_index_stack.items[depth - 1];
                if (region_idx) |ridx| {
                    if (ridx < parent.regions.items.len) {
                        return parent.regions.items[ridx].ensureState(model.allocator, id, parent.depth);
                    }
                }
                // No region — add as direct child
                for (parent.children.items) |*child| {
                    if (std.mem.eql(u8, child.id, id)) return child;
                }
                const stype = classifyId(id);
                try parent.children.append(.{
                    .id = id,
                    .label = id,
                    .state_type = stype,
                    .depth = parent.depth + 1,
                    .children = std.ArrayList(sm.State).init(model.allocator),
                    .child_transitions = std.ArrayList(sm.Transition).init(model.allocator),
                    .regions = std.ArrayList(sm.Region).init(model.allocator),
                });
                return &parent.children.items[parent.children.items.len - 1];
            }
        }
    }
    return model.ensureState(id);
}

fn addTransitionInCtx(
    model: *StateModel,
    parent_stack: *const std.ArrayList(?[]const u8),
    region_index_stack: *const std.ArrayList(?usize),
    from: []const u8,
    to: []const u8,
    label: ?[]const u8,
) !void {
    // Dupe the label into model.owned_strings so the model owns the string
    // independently of the AST. The AST's owned_strings are freed when the
    // AST is deinitialized (before the caller uses the model), which would
    // leave a dangling pointer if we stored the AST slice directly.
    const owned_label: ?[]const u8 = if (label) |lbl| blk: {
        const duped = try model.allocator.dupe(u8, lbl);
        errdefer model.allocator.free(duped);
        try model.owned_strings.append(duped);
        break :blk duped;
    } else null;

    const depth = parent_stack.items.len;
    if (depth > 0) {
        const parent_id = parent_stack.items[depth - 1];
        if (parent_id) |pid| {
            if (model.findStateRecursive(pid)) |parent| {
                const region_idx = region_index_stack.items[depth - 1];
                if (region_idx) |ridx| {
                    if (ridx < parent.regions.items.len) {
                        try parent.regions.items[ridx].transitions.append(.{ .from = from, .to = to, .label = owned_label });
                        return;
                    }
                }
                try StateModel.addChildTransition(parent, from, to, owned_label);
                return;
            }
        }
    }
    try model.transitions.append(.{ .from = from, .to = to, .label = owned_label });
}

fn handleRegionSeparator(
    model: *StateModel,
    parent_stack: *const std.ArrayList(?[]const u8),
    region_index_stack: *std.ArrayList(?usize),
) !void {
    const depth = parent_stack.items.len;
    if (depth == 0) return;
    const parent_id = parent_stack.items[depth - 1] orelse return;
    const parent = model.findStateRecursive(parent_id) orelse return;
    const current = region_index_stack.items[depth - 1];

    if (current == null) {
        // First "--": migrate existing children/transitions into region 0.
        var r0 = try model.addRegion(parent);
        for (parent.children.items) |child| try r0.states.append(child);
        parent.children.clearRetainingCapacity();
        for (parent.child_transitions.items) |t| try r0.transitions.append(t);
        parent.child_transitions.clearRetainingCapacity();
        _ = try model.addRegion(parent); // region 1
        region_index_stack.items[depth - 1] = 1;
    } else {
        _ = try model.addRegion(parent);
        region_index_stack.items[depth - 1] = parent.regions.items.len - 1;
    }
}

fn classifyId(id: []const u8) StateType {
    if (std.mem.eql(u8, id, "[*]")) return .start;
    if (std.mem.eql(u8, id, "[H]")) return .history;
    if (std.mem.eql(u8, id, "[H*]")) return .deep_history;
    return .normal;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// ── parse() AST tests ─────────────────────────────────────────────────────────

test "rd: empty source → empty AST" {
    const allocator = testing.allocator;
    var toks = try sl.tokenize(allocator, "");
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 0), ast.statements.items.len);
}

test "rd: header only → empty statement list" {
    const allocator = testing.allocator;
    var toks = try sl.tokenize(allocator, "stateDiagram-v2\n");
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 0), ast.statements.items.len);
}

test "rd: simple transition A --> B" {
    const allocator = testing.allocator;
    var toks = try sl.tokenize(allocator, "stateDiagram-v2\n    A --> B\n");
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 1), ast.statements.items.len);
    const tr = ast.statements.items[0].transition;
    try testing.expectEqualStrings("A", tr.from);
    try testing.expectEqualStrings("B", tr.to);
    try testing.expectEqual(@as(?[]const u8, null), tr.label);
}

test "rd: transition with label" {
    const allocator = testing.allocator;
    var toks = try sl.tokenize(allocator, "stateDiagram-v2\n    A --> B : go now\n");
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    const tr = ast.statements.items[0].transition;
    try testing.expectEqualStrings("go now", tr.label.?);
}

test "rd: pseudo-state transitions" {
    const allocator = testing.allocator;
    const src = "stateDiagram-v2\n    [*] --> Idle\n    Idle --> [*]\n";
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 2), ast.statements.items.len);
    try testing.expectEqualStrings("[*]", ast.statements.items[0].transition.from);
    try testing.expectEqualStrings("[*]", ast.statements.items[1].transition.to);
}

test "rd: direction directive" {
    const allocator = testing.allocator;
    var toks = try sl.tokenize(allocator, "stateDiagram-v2\n    direction LR\n");
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 1), ast.statements.items.len);
    try testing.expectEqual(AstDirection.lr, ast.statements.items[0].direction);
}

test "rd: state type declarations (fork, join, choice)" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state fork_s <<fork>>
        \\    state join_s <<join>>
        \\    state choice_s <<choice>>
    ;
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 3), ast.statements.items.len);
    try testing.expectEqual(AstStateKind.fork, ast.statements.items[0].state_type_decl.kind);
    try testing.expectEqual(AstStateKind.join, ast.statements.items[1].state_type_decl.kind);
    try testing.expectEqual(AstStateKind.choice, ast.statements.items[2].state_type_decl.kind);
    try testing.expectEqualStrings("fork_s", ast.statements.items[0].state_type_decl.id);
}

test "rd: one-level composite state" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Outer {
        \\        A --> B
        \\    }
    ;
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 1), ast.statements.items.len);
    const cs = ast.statements.items[0].composite_state;
    try testing.expectEqualStrings("Outer", cs.id);
    try testing.expectEqual(@as(usize, 1), cs.body.items.len);
    try testing.expectEqualStrings("A", cs.body.items[0].transition.from);
}

test "rd: nested composite states (recursive descent)" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Outer {
        \\        A --> B
        \\        state Inner {
        \\            C --> D
        \\        }
        \\    }
    ;
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 1), ast.statements.items.len);
    const outer = ast.statements.items[0].composite_state;
    try testing.expectEqualStrings("Outer", outer.id);
    // Body: transition(A→B) + composite_state(Inner)
    try testing.expectEqual(@as(usize, 2), outer.body.items.len);

    const inner_node = outer.body.items[1];
    const inner = inner_node.composite_state;
    try testing.expectEqualStrings("Inner", inner.id);
    try testing.expectEqual(@as(usize, 1), inner.body.items.len);
    try testing.expectEqualStrings("C", inner.body.items[0].transition.from);
    try testing.expectEqualStrings("D", inner.body.items[0].transition.to);
}

test "rd: three-level nested composite (deep recursion)" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state L1 {
        \\        state L2 {
        \\            state L3 {
        \\                X --> Y
        \\            }
        \\        }
        \\    }
    ;
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    const l1 = ast.statements.items[0].composite_state;
    try testing.expectEqualStrings("L1", l1.id);
    const l2 = l1.body.items[0].composite_state;
    try testing.expectEqualStrings("L2", l2.id);
    const l3 = l2.body.items[0].composite_state;
    try testing.expectEqualStrings("L3", l3.id);
    try testing.expectEqual(@as(usize, 1), l3.body.items.len);
    try testing.expectEqualStrings("X", l3.body.items[0].transition.from);
}

test "rd: region separator in composite body" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Comp {
        \\        A --> B
        \\        --
        \\        C --> D
        \\    }
    ;
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    const comp = ast.statements.items[0].composite_state;
    // Body: transition(A→B), region_separator, transition(C→D)
    try testing.expectEqual(@as(usize, 3), comp.body.items.len);
    try testing.expectEqual(std.meta.Tag(AstNode).transition, std.meta.activeTag(comp.body.items[0]));
    try testing.expectEqual(std.meta.Tag(AstNode).region_separator, std.meta.activeTag(comp.body.items[1]));
    try testing.expectEqual(std.meta.Tag(AstNode).transition, std.meta.activeTag(comp.body.items[2]));
}

test "rd: inline note right" {
    const allocator = testing.allocator;
    const src = "stateDiagram-v2\n    note right of Active : This is active\n";
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    const note = ast.statements.items[0].note;
    try testing.expectEqualStrings("Active", note.state_id);
    try testing.expectEqual(AstNotePosition.right, note.position);
    try testing.expectEqualStrings("This is active", note.text);
}

test "rd: multiline note" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    note right of Active
        \\        Line one
        \\        Line two
        \\    end note
    ;
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    const note = ast.statements.items[0].note;
    try testing.expectEqualStrings("Active", note.state_id);
    try testing.expectEqualStrings("Line one\nLine two", note.text);
}

test "rd: state with label" {
    const allocator = testing.allocator;
    const src = "stateDiagram-v2\n    state \"My Label\" as MyState\n";
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    const ss = ast.statements.items[0].simple_state;
    try testing.expectEqualStrings("MyState", ss.id);
    try testing.expectEqualStrings("My Label", ss.label.?);
}

test "rd: state with label and composite body" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state "Processing Phase" as Processing {
        \\        [*] --> Validate
        \\    }
    ;
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    const cs = ast.statements.items[0].composite_state;
    try testing.expectEqualStrings("Processing", cs.id);
    try testing.expectEqualStrings("Processing Phase", cs.label.?);
    try testing.expectEqual(@as(usize, 1), cs.body.items.len);
}

test "rd: comments are skipped" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    %% this comment should be skipped
        \\    A --> B
    ;
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 1), ast.statements.items.len);
    try testing.expectEqualStrings("A", ast.statements.items[0].transition.from);
}

// ── parseToModel integration tests ───────────────────────────────────────────

test "parseToModel: basic transitions" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Active : start
        \\    Active --> [*]
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 3), model.transitions.items.len);
    try testing.expect(model.findStateMut("[*]") != null);
    try testing.expect(model.findStateMut("Idle") != null);
    try testing.expect(model.findStateMut("Active") != null);
}

test "parseToModel: transition label" {
    const allocator = testing.allocator;
    var model = try parseToModel(allocator, "stateDiagram-v2\n    A --> B : go\n");
    defer model.deinit();

    try testing.expectEqualStrings("go", model.transitions.items[0].label.?);
}

test "parseToModel: fork and join stereotypes" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state fork_s <<fork>>
        \\    state join_s <<join>>
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const fork = model.findStateMut("fork_s") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.fork, fork.state_type);
    const join = model.findStateMut("join_s") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.join, join.state_type);
}

test "parseToModel: nested composite (recursive)" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Outer {
        \\        A --> B
        \\        state Inner {
        \\            C --> D
        \\        }
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const outer = model.findStateMut("Outer") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.composite, outer.state_type);
    try testing.expect(outer.children.items.len >= 2);

    var found_inner = false;
    for (outer.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "Inner")) {
            found_inner = true;
            try testing.expectEqual(StateType.composite, child.state_type);
            try testing.expect(child.children.items.len >= 2);
        }
    }
    try testing.expect(found_inner);
}

test "parseToModel: direction LR" {
    const allocator = testing.allocator;
    const graph_mod = @import("../models/graph.zig");
    var model = try parseToModel(allocator, "stateDiagram-v2\n    direction LR\n    [*] --> A\n");
    defer model.deinit();
    try testing.expectEqual(graph_mod.Direction.lr, model.direction);
}

test "parseToModel: inline note" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    [*] --> Active
        \\    note right of Active : This is active
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("Active", model.notes.items[0].state_id);
    try testing.expectEqualStrings("This is active", model.notes.items[0].text);
}

test "parseToModel: multiline note" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    [*] --> S
        \\    note right of S
        \\        Line one
        \\        Line two
        \\    end note
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.notes.items.len);
    try testing.expectEqualStrings("Line one\nLine two", model.notes.items[0].text);
}

test "parseToModel: two concurrent regions" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Active {
        \\        [*] --> Processing
        \\        Processing --> Done
        \\        --
        \\        [*] --> Monitoring
        \\        Monitoring --> Alert
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const active = model.findStateMut("Active") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.composite, active.state_type);
    try testing.expect(active.hasRegions());
    try testing.expectEqual(@as(usize, 2), active.regionCount());
}

test "parseToModel: three concurrent regions" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Parallel {
        \\        A --> B
        \\        --
        \\        C --> D
        \\        --
        \\        E --> F
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const par = model.findStateMut("Parallel") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), par.regionCount());
}

test "parseToModel: start and end pseudo-states" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    [*] --> Active
        \\    Active --> [*]
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const start = model.findStateMut("[*]") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.start, start.state_type);
    const end = model.findStateMut("[*]_end") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.end, end.state_type);
}

test "parseToModel: choice pseudostate" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state is_ready <<choice>>
        \\    [*] --> is_ready
        \\    is_ready --> Yes : ready
        \\    is_ready --> No : not ready
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const choice = model.findStateMut("is_ready") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.choice, choice.state_type);
    try testing.expectEqual(@as(usize, 3), model.transitions.items.len);
}

test "parseToModel: state with label" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state "Waiting for input" as Wait
        \\    Wait --> Done
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const wait = model.findStateMut("Wait") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Waiting for input", wait.label);
}

test "parseToModel: self-transition" {
    const allocator = testing.allocator;
    var model = try parseToModel(allocator, "stateDiagram-v2\n    Idle --> Idle : keepalive\n");
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.transitions.items.len);
    try testing.expectEqualStrings("Idle", model.transitions.items[0].from);
    try testing.expectEqualStrings("Idle", model.transitions.items[0].to);
}

test "parseToModel: history pseudo-state [H]" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Outer {
        \\        [*] --> [H]
        \\        [H] --> Inner
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const outer = model.findStateMut("Outer") orelse return error.TestUnexpectedResult;
    var found = false;
    for (outer.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "[H]")) {
            try testing.expectEqual(StateType.history, child.state_type);
            found = true;
        }
    }
    try testing.expect(found);
}

test "parseToModel: deep history pseudo-state [H*]" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Outer {
        \\        [*] --> [H*]
        \\        [H*] --> Deep
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const outer = model.findStateMut("Outer") orelse return error.TestUnexpectedResult;
    var found = false;
    for (outer.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "[H*]")) {
            try testing.expectEqual(StateType.deep_history, child.state_type);
            found = true;
        }
    }
    try testing.expect(found);
}

// ── Nesting depth metadata tests ─────────────────────────────────────────────

test "parseToModel: top-level states have depth 0" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Active
        \\    Active --> [*]
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    // All top-level states must have depth = 0
    const idle = model.findStateMut("Idle") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), idle.depth);

    const active = model.findStateMut("Active") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), active.depth);
}

test "parseToModel: direct children of composite have depth 1" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Outer {
        \\        A --> B
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const outer = model.findStateMut("Outer") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), outer.depth);

    // A and B are direct children of Outer, so depth = 1
    for (outer.children.items) |*child| {
        try testing.expectEqual(@as(u32, 1), child.depth);
    }
}

test "parseToModel: grandchildren of composite have depth 2" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state L1 {
        \\        state L2 {
        \\            X --> Y
        \\        }
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const l1 = model.findStateMut("L1") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), l1.depth);

    // L2 is a direct child of L1 → depth 1
    var found_l2 = false;
    for (l1.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "L2")) {
            try testing.expectEqual(@as(u32, 1), child.depth);
            found_l2 = true;
            // X and Y are children of L2 → depth 2
            for (child.children.items) |*grandchild| {
                try testing.expectEqual(@as(u32, 2), grandchild.depth);
            }
        }
    }
    try testing.expect(found_l2);
}

test "parseToModel: states in concurrent regions have correct depth" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Active {
        \\        [*] --> Processing
        \\        --
        \\        [*] --> Monitoring
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const active = model.findStateMut("Active") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), active.depth);
    try testing.expect(active.hasRegions());

    // States inside concurrent regions of Active should have depth 1
    for (active.regions.items) |*region| {
        for (region.states.items) |*child| {
            try testing.expectEqual(@as(u32, 1), child.depth);
        }
    }
}

test "parseToModel: model maxDepth reflects nesting" {
    const allocator = testing.allocator;

    // Flat diagram: maxDepth = 1
    {
        var model = try parseToModel(allocator, "stateDiagram-v2\n    A --> B\n");
        defer model.deinit();
        try testing.expectEqual(@as(usize, 1), model.maxDepth());
    }

    // One level of nesting: maxDepth = 2
    {
        const src =
            \\stateDiagram-v2
            \\    state Outer {
            \\        A --> B
            \\    }
        ;
        var model = try parseToModel(allocator, src);
        defer model.deinit();
        try testing.expectEqual(@as(usize, 2), model.maxDepth());
    }

    // Two levels of nesting: maxDepth = 3
    {
        const src =
            \\stateDiagram-v2
            \\    state L1 {
            \\        state L2 {
            \\            X --> Y
            \\        }
            \\    }
        ;
        var model = try parseToModel(allocator, src);
        defer model.deinit();
        try testing.expectEqual(@as(usize, 3), model.maxDepth());
    }
}

// ── Entry/exit point tests ────────────────────────────────────────────────────

test "rd: entryPoint stereotype parses to AstStateKind.entry_point" {
    const allocator = testing.allocator;
    const src = "stateDiagram-v2\n    state ep <<entryPoint>>\n";
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 1), ast.statements.items.len);
    const decl = ast.statements.items[0].state_type_decl;
    try testing.expectEqualStrings("ep", decl.id);
    try testing.expectEqual(AstStateKind.entry_point, decl.kind);
}

test "rd: exitPoint stereotype parses to AstStateKind.exit_point" {
    const allocator = testing.allocator;
    const src = "stateDiagram-v2\n    state xp <<exitPoint>>\n";
    var toks = try sl.tokenize(allocator, src);
    defer toks.deinit();
    var ast = try parse(allocator, toks.items);
    defer ast.deinit();

    try testing.expectEqual(@as(usize, 1), ast.statements.items.len);
    const decl = ast.statements.items[0].state_type_decl;
    try testing.expectEqualStrings("xp", decl.id);
    try testing.expectEqual(AstStateKind.exit_point, decl.kind);
}

test "parseToModel: entryPoint stereotype sets StateType.entry_point" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state Composite {
        \\        state ep <<entryPoint>>
        \\        ep --> Active
        \\        Active --> xp
        \\        state xp <<exitPoint>>
        \\    }
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const comp = model.findStateMut("Composite") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.composite, comp.state_type);

    var found_ep = false;
    var found_xp = false;
    for (comp.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "ep")) {
            try testing.expectEqual(StateType.entry_point, child.state_type);
            found_ep = true;
        }
        if (std.mem.eql(u8, child.id, "xp")) {
            try testing.expectEqual(StateType.exit_point, child.state_type);
            found_xp = true;
        }
    }
    try testing.expect(found_ep);
    try testing.expect(found_xp);
}

test "parseToModel: entry/exit point transitions are wired into graph" {
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state CS {
        \\        state entry <<entryPoint>>
        \\        state exit_p <<exitPoint>>
        \\        entry --> Running
        \\        Running --> exit_p
        \\    }
        \\    [*] --> CS
        \\    CS --> [*]
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    // Verify that entry/exit point states were created with correct types
    const cs = model.findStateMut("CS") orelse return error.TestUnexpectedResult;
    var found_entry = false;
    var found_exit = false;
    for (cs.children.items) |*child| {
        if (std.mem.eql(u8, child.id, "entry")) {
            try testing.expectEqual(StateType.entry_point, child.state_type);
            found_entry = true;
        }
        if (std.mem.eql(u8, child.id, "exit_p")) {
            try testing.expectEqual(StateType.exit_point, child.state_type);
            found_exit = true;
        }
    }
    try testing.expect(found_entry);
    try testing.expect(found_exit);

    // Verify graph has both states registered
    try testing.expect(model.graph.nodes.contains("entry"));
    try testing.expect(model.graph.nodes.contains("exit_p"));
}

test "parseToModel: top-level entry/exit points" {
    // Entry/exit points declared at top level (outside any composite)
    const allocator = testing.allocator;
    const src =
        \\stateDiagram-v2
        \\    state ep <<entryPoint>>
        \\    state xp <<exitPoint>>
        \\    [*] --> ep
        \\    xp --> [*]
    ;
    var model = try parseToModel(allocator, src);
    defer model.deinit();

    const ep = model.findStateMut("ep") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.entry_point, ep.state_type);

    const xp = model.findStateMut("xp") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(StateType.exit_point, xp.state_type);
}
