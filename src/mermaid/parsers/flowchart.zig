const std = @import("std");
const Allocator = std.mem.Allocator;
const tokenizer = @import("../tokenizer.zig");
const Token = tokenizer.Token;
const TokenType = tokenizer.TokenType;
const BracketKind = tokenizer.BracketKind;
const graph_mod = @import("../models/graph.zig");
const NodeShape = graph_mod.NodeShape;
const EdgeStyle = graph_mod.EdgeStyle;
const ArrowHead = graph_mod.ArrowHead;
const Direction = graph_mod.Direction;
const fm = @import("../models/flowchart_model.zig");
const FlowchartModel = fm.FlowchartModel;
const Subgraph = fm.Subgraph;

pub fn parse(allocator: Allocator, tokens: std.ArrayList(Token)) !FlowchartModel {
    var parser = Parser{
        .allocator = allocator,
        .tokens = tokens.items,
        .pos = 0,
        .model = undefined,
    };

    // Expect 'graph' or 'flowchart' keyword
    parser.skipNewlines();
    const first = parser.peek();
    if (first.type != .keyword or
        (!std.mem.eql(u8, first.text, "graph") and !std.mem.eql(u8, first.text, "flowchart")))
    {
        // Not a valid flowchart, return empty model
        return FlowchartModel.init(allocator, .td);
    }
    parser.advance();

    // Parse direction
    const direction = parser.parseDirection();
    parser.model = FlowchartModel.init(allocator, direction);
    errdefer parser.model.deinit();

    parser.skipNewlines();

    // Parse body lines
    while (parser.pos < parser.tokens.len) {
        const tok = parser.peek();
        if (tok.type == .eof) break;
        if (tok.type == .newline or tok.type == .semicolon or tok.type == .comment) {
            parser.advance();
            continue;
        }
        try parser.parseLine();
    }

    return parser.model;
}

const Parser = struct {
    allocator: Allocator,
    tokens: []const Token,
    pos: usize,
    model: FlowchartModel,

    fn peek(self: *Parser) Token {
        if (self.pos >= self.tokens.len) return .{ .type = .eof, .text = "" };
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) self.pos += 1;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.pos < self.tokens.len) {
            const t = self.tokens[self.pos];
            if (t.type != .newline and t.type != .comment) break;
            self.pos += 1;
        }
    }

    fn parseDirection(self: *Parser) Direction {
        const tok = self.peek();
        if (tok.type == .keyword or tok.type == .identifier) {
            if (std.mem.eql(u8, tok.text, "TD") or std.mem.eql(u8, tok.text, "TB")) {
                self.advance();
                return .td;
            }
            if (std.mem.eql(u8, tok.text, "BT")) {
                self.advance();
                return .bt;
            }
            if (std.mem.eql(u8, tok.text, "LR")) {
                self.advance();
                return .lr;
            }
            if (std.mem.eql(u8, tok.text, "RL")) {
                self.advance();
                return .rl;
            }
        }
        return .td; // default
    }

    const ParseError = Allocator.Error;

    fn parseLine(self: *Parser) ParseError!void {
        const tok = self.peek();

        // subgraph
        if (tok.type == .keyword and std.mem.eql(u8, tok.text, "subgraph")) {
            try self.parseSubgraph();
            return;
        }

        // end keyword (close subgraph)
        if (tok.type == .keyword and std.mem.eql(u8, tok.text, "end")) {
            self.advance();
            return;
        }

        // Parse node/edge statement
        // Must start with an identifier
        if (tok.type == .identifier or tok.type == .keyword) {
            try self.parseStatement();
            return;
        }

        // Skip unknown token
        self.advance();
    }

    fn parseStatement(self: *Parser) ParseError!void {
        // Parse first node (possibly with shape declaration)
        const node_id = self.parseNodeRef();
        if (node_id == null) return;

        // After node ID, check for shape declaration
        try self.tryParseNodeShape(node_id.?);

        // Check for chained edges: A --> B --> C
        while (true) {
            const next = self.peek();
            if (next.type == .arrow) {
                const arrow_style: EdgeStyle = switch (next.arrow_style) {
                    .solid => .solid,
                    .dotted => .dotted,
                    .thick => .thick,
                };
                const arrow_head: ArrowHead = switch (next.arrow_head) {
                    .arrow => .arrow,
                    .circle => .circle,
                    .cross => .cross,
                    .none => .none,
                };
                self.advance();

                // Check for edge label: |label| or -- label -->
                var edge_label: ?[]const u8 = null;
                if (self.peek().type == .pipe) {
                    self.advance(); // skip |
                    edge_label = self.collectUntilPipe();
                    if (self.peek().type == .pipe) self.advance(); // skip closing |
                }

                // Parse target node
                const target_id = self.parseNodeRef();
                if (target_id == null) break;

                try self.tryParseNodeShape(target_id.?);

                // Ensure both nodes exist
                try self.ensureNode(node_id.?);
                try self.ensureNode(target_id.?);

                // Add edge
                var edge = try self.model.graph.addEdge(node_id.?, target_id.?);
                edge.style = arrow_style;
                edge.arrow_head = arrow_head;
                edge.label = edge_label;

                // Continue checking for chained edges from the target
                // We need to update "current" node for next chain iteration
                // But our edge already connects node_id -> target_id
                // For chaining A-->B-->C, we need B-->C as a separate edge
                // So we break here and the outer loop will get the next arrow
                // Actually, let's handle chaining properly by looping
                const chain_tok = self.peek();
                if (chain_tok.type == .arrow) {
                    // More edges chained from target_id
                    try self.parseChainedEdges(target_id.?);
                }
                break;
            } else {
                break;
            }
        }
    }

    fn parseChainedEdges(self: *Parser, from_id: []const u8) ParseError!void {
        var current = from_id;
        while (self.peek().type == .arrow) {
            const arr = self.peek();
            const arrow_style: EdgeStyle = switch (arr.arrow_style) {
                .solid => .solid,
                .dotted => .dotted,
                .thick => .thick,
            };
            const arrow_head: ArrowHead = switch (arr.arrow_head) {
                .arrow => .arrow,
                .circle => .circle,
                .cross => .cross,
                .none => .none,
            };
            self.advance();

            var edge_label: ?[]const u8 = null;
            if (self.peek().type == .pipe) {
                self.advance();
                edge_label = self.collectUntilPipe();
                if (self.peek().type == .pipe) self.advance();
            }

            const target_id = self.parseNodeRef();
            if (target_id == null) break;

            try self.tryParseNodeShape(target_id.?);
            try self.ensureNode(target_id.?);

            var edge = try self.model.graph.addEdge(current, target_id.?);
            edge.style = arrow_style;
            edge.arrow_head = arrow_head;
            edge.label = edge_label;

            current = target_id.?;
        }
    }

    fn parseNodeRef(self: *Parser) ?[]const u8 {
        const tok = self.peek();
        if (tok.type == .identifier or tok.type == .keyword or tok.type == .number) {
            self.advance();
            return tok.text;
        }
        return null;
    }

    fn tryParseNodeShape(self: *Parser, node_id: []const u8) ParseError!void {
        const tok = self.peek();
        if (tok.type != .open_bracket) return;

        const shape = bracketToShape(tok.bracket_kind);
        self.advance();

        // Collect label text until matching close bracket
        const label = self.collectLabel(tok.bracket_kind);

        // Skip close bracket
        const close = self.peek();
        if (close.type == .close_bracket) {
            self.advance();
        }

        // Update or create node with shape and label
        if (self.model.graph.nodes.getPtr(node_id)) |node| {
            node.shape = shape;
            if (label) |l| node.label = l;
        } else {
            try self.model.graph.addNode(node_id, label orelse node_id, shape);
        }
    }

    fn collectLabel(self: *Parser, _: BracketKind) ?[]const u8 {
        // Collect tokens until close bracket, building label from text
        const tok = self.peek();
        if (tok.type == .string_literal) {
            self.advance();
            // Strip quotes
            const text = tok.text;
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                return text[1 .. text.len - 1];
            }
            return text;
        }
        // Plain text label: collect identifier/keyword/number tokens
        if (tok.type == .identifier or tok.type == .keyword or tok.type == .number) {
            self.advance();
            return tok.text;
        }
        return null;
    }

    fn collectUntilPipe(self: *Parser) ?[]const u8 {
        // Collect text between pipe markers
        const tok = self.peek();
        if (tok.type == .identifier or tok.type == .keyword or tok.type == .string_literal or tok.type == .number) {
            self.advance();
            if (tok.type == .string_literal) {
                const text = tok.text;
                if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                    return text[1 .. text.len - 1];
                }
            }
            return tok.text;
        }
        return null;
    }

    fn ensureNode(self: *Parser, id: []const u8) ParseError!void {
        if (!self.model.graph.nodes.contains(id)) {
            try self.model.graph.addNode(id, id, .rectangle);
        }
    }

    fn parseSubgraph(self: *Parser) ParseError!void {
        self.advance(); // skip 'subgraph' keyword

        // Parse subgraph title/id
        const tok = self.peek();
        var sg_id: []const u8 = "subgraph";
        var sg_title: []const u8 = "subgraph";
        if (tok.type == .identifier or tok.type == .keyword) {
            sg_id = tok.text;
            sg_title = tok.text;
            self.advance();
        }

        var sg = Subgraph.init(self.allocator, sg_id, sg_title);

        self.skipNewlines();

        // Parse until 'end'
        while (self.pos < self.tokens.len) {
            const inner = self.peek();
            if (inner.type == .eof) break;
            if (inner.type == .keyword and std.mem.eql(u8, inner.text, "end")) {
                self.advance();
                break;
            }
            if (inner.type == .newline or inner.type == .semicolon or inner.type == .comment) {
                self.advance();
                continue;
            }

            // Track node IDs referenced in this subgraph
            if (inner.type == .identifier or inner.type == .keyword) {
                try sg.node_ids.append(inner.text);
            }

            try self.parseLine();
        }

        try self.model.subgraphs.append(sg);
    }

    fn bracketToShape(kind: BracketKind) NodeShape {
        return switch (kind) {
            .square => .rectangle,
            .round => .rounded,
            .curly => .diamond,
            .double_round => .double_circle,
            .curly_square => .subroutine,
            .slash => .parallelogram,
            .backslash => .trapezoid,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "flowchart parse basic nodes and edge" {
    const allocator = testing.allocator;
    var tokens = try tokenizer.tokenize(allocator, "graph TD\nA --> B");
    defer tokens.deinit();

    var model = try parse(allocator, tokens);
    defer model.deinit();

    try testing.expect(model.graph.nodes.contains("A"));
    try testing.expect(model.graph.nodes.contains("B"));
    try testing.expectEqual(@as(usize, 1), model.graph.edges.items.len);
    try testing.expectEqualStrings("A", model.graph.edges.items[0].from);
    try testing.expectEqualStrings("B", model.graph.edges.items[0].to);
}

test "flowchart parse direction LR" {
    const allocator = testing.allocator;
    var tokens = try tokenizer.tokenize(allocator, "graph LR\nA --> B");
    defer tokens.deinit();

    var model = try parse(allocator, tokens);
    defer model.deinit();

    try testing.expectEqual(Direction.lr, model.graph.direction);
}

test "flowchart parse node with label" {
    const allocator = testing.allocator;
    var tokens = try tokenizer.tokenize(allocator, "graph TD\nA[Hello]");
    defer tokens.deinit();

    var model = try parse(allocator, tokens);
    defer model.deinit();

    const node = model.graph.nodes.get("A") orelse unreachable;
    try testing.expectEqualStrings("Hello", node.label);
    try testing.expectEqual(NodeShape.rectangle, node.shape);
}

test "flowchart parse round brackets as rounded shape" {
    const allocator = testing.allocator;
    var tokens = try tokenizer.tokenize(allocator, "graph TD\nA(Rounded)");
    defer tokens.deinit();

    var model = try parse(allocator, tokens);
    defer model.deinit();

    const node = model.graph.nodes.get("A") orelse unreachable;
    try testing.expectEqual(NodeShape.rounded, node.shape);
}

test "flowchart parse empty input" {
    const allocator = testing.allocator;
    var tokens = try tokenizer.tokenize(allocator, "");
    defer tokens.deinit();

    var model = try parse(allocator, tokens);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 0), model.graph.edges.items.len);
}

test "flowchart parse subgraph" {
    const allocator = testing.allocator;
    var tokens = try tokenizer.tokenize(allocator, "graph TD\nsubgraph SG\nA --> B\nend");
    defer tokens.deinit();

    var model = try parse(allocator, tokens);
    defer model.deinit();

    try testing.expectEqual(@as(usize, 1), model.subgraphs.items.len);
    try testing.expectEqualStrings("SG", model.subgraphs.items[0].id);
}
