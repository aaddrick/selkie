const std = @import("std");
const Allocator = std.mem.Allocator;

/// GFM-aware markdown syntax highlighter for the editor buffer.
/// Tokenizes raw markdown text into styled spans for rendering.
/// Operates on single lines with optional multi-line state (for fenced code blocks).
pub const MdHighlighter = struct {
    /// Multi-line state carried between lines.
    pub const LineState = enum {
        normal,
        fenced_code,
    };

    /// Token kinds for GFM markdown elements.
    pub const TokenKind = enum {
        text,
        heading_marker, // # symbols
        heading_text, // heading content
        bold, // **text** or __text__
        italic, // *text* or _text_
        bold_italic, // ***text***
        code_span, // `inline code`
        link_text, // [text]
        link_url, // (url)
        image_marker, // ![
        list_marker, // -, *, +, 1.
        blockquote_marker, // >
        fence, // ``` or ~~~
        code_line, // line inside fenced code block
        table_pipe, // |
        table_align, // :--- etc. in separator rows
        horizontal_rule, // ---, ***, ___
        strikethrough, // ~~text~~
        task_marker, // [ ] or [x]
        html_tag, // <tag> or </tag>
        escape, // \char
        autolink, // <https://...> or bare URLs
        footnote_ref, // [^label]
        footnote_def, // [^label]:
        alert_marker, // [!NOTE], [!WARNING], etc. inside blockquotes
        emoji, // :shortcode:
    };

    pub const Token = struct {
        start: usize,
        end: usize,
        kind: TokenKind,
    };

    /// Tokenize a single line of markdown with awareness of multi-line state.
    /// Returns tokens and the state to pass to the next line.
    /// Caller owns the returned slice and must free it with the same allocator.
    pub fn tokenizeLine(
        allocator: Allocator,
        line: []const u8,
        state_in: LineState,
    ) !struct { tokens: []Token, state_out: LineState } {
        var tokens = std.ArrayList(Token).init(allocator);
        errdefer tokens.deinit();

        // Inside a fenced code block
        if (state_in == .fenced_code) {
            if (isFenceLine(line)) {
                try tokens.append(.{ .start = 0, .end = line.len, .kind = .fence });
                return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
            }
            if (line.len > 0) {
                try tokens.append(.{ .start = 0, .end = line.len, .kind = .code_line });
            }
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .fenced_code };
        }

        // Opening fence
        if (isFenceLine(line)) {
            try tokens.append(.{ .start = 0, .end = line.len, .kind = .fence });
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .fenced_code };
        }

        const trimmed = std.mem.trimLeft(u8, line, " ");
        const leading_spaces = line.len - trimmed.len;

        // Horizontal rule: ---, ***, ___  (3+ of same char, optional spaces)
        if (isHorizontalRule(trimmed)) {
            try tokens.append(.{ .start = 0, .end = line.len, .kind = .horizontal_rule });
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
        }

        // Heading: # ... ######
        if (isHeadingLine(trimmed)) {
            const hash_start = leading_spaces;
            var hash_end = hash_start;
            while (hash_end < line.len and line[hash_end] == '#') : (hash_end += 1) {}
            // Include the space after # markers
            var content_start = hash_end;
            if (content_start < line.len and line[content_start] == ' ') content_start += 1;

            try tokens.append(.{ .start = hash_start, .end = content_start, .kind = .heading_marker });
            if (content_start < line.len) {
                // Tokenize inline elements within the heading text
                try tokenizeInline(&tokens, line, content_start, line.len, .heading_text);
            }
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
        }

        // Blockquote: > ...
        if (trimmed.len > 0 and trimmed[0] == '>') {
            const marker_end = leading_spaces + 1;
            var content_start = marker_end;
            if (content_start < line.len and line[content_start] == ' ') content_start += 1;

            try tokens.append(.{ .start = leading_spaces, .end = content_start, .kind = .blockquote_marker });
            if (content_start < line.len) {
                // Check for GFM alert syntax: > [!NOTE], > [!WARNING], etc.
                const rest = line[content_start..];
                if (isAlertMarker(rest)) |alert_end_offset| {
                    try tokens.append(.{ .start = content_start, .end = content_start + alert_end_offset, .kind = .alert_marker });
                    const after_alert = content_start + alert_end_offset;
                    if (after_alert < line.len) {
                        try tokenizeInline(&tokens, line, after_alert, line.len, .text);
                    }
                } else {
                    try tokenizeInline(&tokens, line, content_start, line.len, .text);
                }
            }
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
        }

        // Footnote definition: [^label]: ...
        if (isFootnoteDefinition(trimmed)) |def_end_offset| {
            const def_end = leading_spaces + def_end_offset;
            try tokens.append(.{ .start = leading_spaces, .end = def_end, .kind = .footnote_def });
            if (def_end < line.len) {
                try tokenizeInline(&tokens, line, def_end, line.len, .text);
            }
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
        }

        // Table separator row: | --- | :---: | ---: |
        if (isTableSeparatorRow(trimmed)) {
            try tokens.append(.{ .start = 0, .end = line.len, .kind = .table_align });
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
        }

        // Table row: | ... | ... |
        if (isTableRow(trimmed)) {
            try tokenizeTableRow(&tokens, line);
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
        }

        // List items: -, *, +, or 1. 2. etc.
        if (getListMarkerEnd(trimmed)) |marker_len| {
            const marker_end = leading_spaces + marker_len;
            try tokens.append(.{ .start = leading_spaces, .end = marker_end, .kind = .list_marker });

            // Check for task list marker: [ ] or [x] or [X]
            const after_marker = line[marker_end..];
            if (after_marker.len >= 3 and after_marker[0] == '[' and
                (after_marker[1] == ' ' or after_marker[1] == 'x' or after_marker[1] == 'X') and
                after_marker[2] == ']')
            {
                try tokens.append(.{ .start = marker_end, .end = marker_end + 3, .kind = .task_marker });
                const text_start = marker_end + 3;
                if (text_start < line.len) {
                    try tokenizeInline(&tokens, line, text_start, line.len, .text);
                }
            } else if (marker_end < line.len) {
                try tokenizeInline(&tokens, line, marker_end, line.len, .text);
            }
            return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
        }

        // Normal paragraph text — tokenize inline elements
        try tokenizeInline(&tokens, line, 0, line.len, .text);
        return .{ .tokens = try tokens.toOwnedSlice(), .state_out = .normal };
    }

    /// Tokenize inline markdown elements (bold, italic, code, links, etc.)
    fn tokenizeInline(
        tokens: *std.ArrayList(Token),
        line: []const u8,
        start: usize,
        end: usize,
        default_kind: TokenKind,
    ) !void {
        var i = start;
        var text_start = start;

        while (i < end) {
            const ch = line[i];

            // Escape sequence
            if (ch == '\\' and i + 1 < end) {
                // Flush preceding text
                if (i > text_start) {
                    try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                }
                try tokens.append(.{ .start = i, .end = i + 2, .kind = .escape });
                i += 2;
                text_start = i;
                continue;
            }

            // Inline code: `...`
            if (ch == '`') {
                if (i > text_start) {
                    try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                }
                const code_end = findClosingBacktick(line, i, end);
                try tokens.append(.{ .start = i, .end = code_end, .kind = .code_span });
                i = code_end;
                text_start = i;
                continue;
            }

            // Strikethrough: ~~...~~
            if (ch == '~' and i + 1 < end and line[i + 1] == '~') {
                if (findClosingDouble(line, i, end, '~')) |close| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = close, .kind = .strikethrough });
                    i = close;
                    text_start = i;
                    continue;
                }
            }

            // Bold+italic: *** or ___
            if ((ch == '*' or ch == '_') and i + 2 < end and line[i + 1] == ch and line[i + 2] == ch) {
                if (findClosingTriple(line, i, end, ch)) |close| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = close, .kind = .bold_italic });
                    i = close;
                    text_start = i;
                    continue;
                }
            }

            // Bold: ** or __
            if ((ch == '*' or ch == '_') and i + 1 < end and line[i + 1] == ch) {
                if (findClosingDouble(line, i, end, ch)) |close| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = close, .kind = .bold });
                    i = close;
                    text_start = i;
                    continue;
                }
            }

            // Italic: * or _ (single, not followed by space for _)
            if (ch == '*' or (ch == '_' and !isSurroundedByAlnum(line, i))) {
                if (findClosingSingle(line, i, end, ch)) |close| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = close, .kind = .italic });
                    i = close;
                    text_start = i;
                    continue;
                }
            }

            // Image: ![alt](url)
            if (ch == '!' and i + 1 < end and line[i + 1] == '[') {
                if (findLinkEnd(line, i + 1, end)) |link_end| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = i + 2, .kind = .image_marker });
                    // Find ] to split text/url
                    if (std.mem.indexOfScalarPos(u8, line, i + 2, ']')) |bracket_end| {
                        try tokens.append(.{ .start = i + 2, .end = bracket_end, .kind = .link_text });
                        try tokens.append(.{ .start = bracket_end, .end = link_end, .kind = .link_url });
                    }
                    i = link_end;
                    text_start = i;
                    continue;
                }
            }

            // Footnote reference: [^label]
            if (ch == '[' and i + 1 < end and line[i + 1] == '^') {
                if (findFootnoteRefEnd(line, i, end)) |ref_end| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = ref_end, .kind = .footnote_ref });
                    i = ref_end;
                    text_start = i;
                    continue;
                }
            }

            // Link: [text](url)
            if (ch == '[') {
                if (findLinkEnd(line, i, end)) |link_end| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    if (std.mem.indexOfScalarPos(u8, line, i + 1, ']')) |bracket_end| {
                        try tokens.append(.{ .start = i, .end = bracket_end + 1, .kind = .link_text });
                        try tokens.append(.{ .start = bracket_end + 1, .end = link_end, .kind = .link_url });
                    }
                    i = link_end;
                    text_start = i;
                    continue;
                }
            }

            // Autolink: <https://...> or <http://...> or <mailto:...>
            if (ch == '<' and i + 1 < end) {
                if (findAutolink(line, i, end)) |autolink_end| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = autolink_end, .kind = .autolink });
                    i = autolink_end;
                    text_start = i;
                    continue;
                }
            }

            // HTML tag: <...>
            if (ch == '<' and i + 1 < end and (std.ascii.isAlphabetic(line[i + 1]) or line[i + 1] == '/')) {
                if (std.mem.indexOfScalarPos(u8, line, i + 1, '>')) |tag_end| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = tag_end + 1, .kind = .html_tag });
                    i = tag_end + 1;
                    text_start = i;
                    continue;
                }
            }

            // Emoji shortcode: :name:
            if (ch == ':' and i + 1 < end and isEmojiNameChar(line[i + 1])) {
                if (findEmojiEnd(line, i, end)) |emoji_end| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = emoji_end, .kind = .emoji });
                    i = emoji_end;
                    text_start = i;
                    continue;
                }
            }

            // Bare autolink: https:// or http:// URLs in plain text
            if (ch == 'h') {
                if (matchesBareUrl(line, i, end)) |url_end| {
                    if (i > text_start) {
                        try tokens.append(.{ .start = text_start, .end = i, .kind = default_kind });
                    }
                    try tokens.append(.{ .start = i, .end = url_end, .kind = .autolink });
                    i = url_end;
                    text_start = i;
                    continue;
                }
            }

            i += 1;
        }

        // Flush remaining text
        if (text_start < end) {
            try tokens.append(.{ .start = text_start, .end = end, .kind = default_kind });
        }
    }

    fn tokenizeTableRow(tokens: *std.ArrayList(Token), line: []const u8) !void {
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '|') {
                try tokens.append(.{ .start = i, .end = i + 1, .kind = .table_pipe });
                i += 1;
            } else {
                // Find next pipe or end
                const cell_start = i;
                while (i < line.len and line[i] != '|') : (i += 1) {}
                if (i > cell_start) {
                    try tokenizeInline(tokens, line, cell_start, i, .text);
                }
            }
        }
    }

    // --- Helper functions ---

    fn isFenceLine(line: []const u8) bool {
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len < 3) return false;
        const fence_char = trimmed[0];
        if (fence_char != '`' and fence_char != '~') return false;
        var count: usize = 0;
        for (trimmed) |c| {
            if (c == fence_char) {
                count += 1;
            } else break;
        }
        return count >= 3;
    }

    fn isHeadingLine(trimmed: []const u8) bool {
        if (trimmed.len == 0 or trimmed[0] != '#') return false;
        var level: usize = 0;
        while (level < trimmed.len and trimmed[level] == '#') : (level += 1) {}
        if (level > 6) return false;
        // Must be followed by space or end of line
        return level == trimmed.len or trimmed[level] == ' ';
    }

    fn isHorizontalRule(trimmed: []const u8) bool {
        if (trimmed.len < 3) return false;
        const ch = trimmed[0];
        if (ch != '-' and ch != '*' and ch != '_') return false;
        var count: usize = 0;
        for (trimmed) |c| {
            if (c == ch) {
                count += 1;
            } else if (c != ' ') {
                return false;
            }
        }
        return count >= 3;
    }

    fn isTableSeparatorRow(trimmed: []const u8) bool {
        if (trimmed.len < 3) return false;
        // Must contain at least one | and consist of |, -, :, and spaces
        var has_pipe = false;
        var has_dash = false;
        for (trimmed) |c| {
            switch (c) {
                '|' => has_pipe = true,
                '-' => has_dash = true,
                ':', ' ' => {},
                else => return false,
            }
        }
        return has_pipe and has_dash;
    }

    fn isTableRow(trimmed: []const u8) bool {
        if (trimmed.len == 0) return false;
        // A table row starts or ends with |
        return trimmed[0] == '|' or trimmed[trimmed.len - 1] == '|';
    }

    fn getListMarkerEnd(trimmed: []const u8) ?usize {
        if (trimmed.len == 0) return null;

        // Unordered: -, *, + followed by space
        if ((trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and
            trimmed.len > 1 and trimmed[1] == ' ')
        {
            return 2; // marker + space
        }

        // Ordered: digits followed by . or ) then space
        var i: usize = 0;
        while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) : (i += 1) {}
        if (i > 0 and i < trimmed.len and (trimmed[i] == '.' or trimmed[i] == ')')) {
            if (i + 1 < trimmed.len and trimmed[i + 1] == ' ') {
                return i + 2;
            }
        }

        return null;
    }

    fn findClosingBacktick(line: []const u8, start: usize, end: usize) usize {
        // Count opening backticks
        var open_count: usize = 0;
        var i = start;
        while (i < end and line[i] == '`') : (i += 1) {
            open_count += 1;
        }
        if (open_count == 0) return start + 1;

        // Find matching number of backticks
        while (i + open_count <= end) {
            if (line[i] == '`') {
                var close_count: usize = 0;
                while (i < end and line[i] == '`') : (i += 1) {
                    close_count += 1;
                }
                if (close_count == open_count) return i;
                // Not matching count, continue
                continue;
            }
            i += 1;
        }
        // No closing found, treat just the opening backticks as code_span
        return start + open_count;
    }

    fn findClosingDouble(line: []const u8, start: usize, end: usize, ch: u8) ?usize {
        // Start after the opening **
        var i = start + 2;
        while (i + 1 < end) {
            if (line[i] == ch and line[i + 1] == ch) {
                return i + 2;
            }
            i += 1;
        }
        return null;
    }

    fn findClosingTriple(line: []const u8, start: usize, end: usize, ch: u8) ?usize {
        var i = start + 3;
        while (i + 2 < end) {
            if (line[i] == ch and line[i + 1] == ch and line[i + 2] == ch) {
                return i + 3;
            }
            i += 1;
        }
        return null;
    }

    fn findClosingSingle(line: []const u8, start: usize, end: usize, ch: u8) ?usize {
        var i = start + 1;
        // Must have content between markers
        if (i >= end or line[i] == ' ') return null;
        while (i < end) {
            if (line[i] == ch) {
                return i + 1;
            }
            if (line[i] == '\\' and i + 1 < end) {
                i += 2;
                continue;
            }
            i += 1;
        }
        return null;
    }

    fn isSurroundedByAlnum(line: []const u8, pos: usize) bool {
        // _ should not be emphasis when surrounded by alnum
        if (pos > 0 and std.ascii.isAlphanumeric(line[pos - 1])) return true;
        if (pos + 1 < line.len and std.ascii.isAlphanumeric(line[pos + 1])) return true;
        return false;
    }

    fn findLinkEnd(line: []const u8, start: usize, end: usize) ?usize {
        // Find matching ]
        var i = start + 1;
        var depth: usize = 1;
        while (i < end) {
            if (line[i] == '[') depth += 1;
            if (line[i] == ']') {
                depth -= 1;
                if (depth == 0) break;
            }
            i += 1;
        }
        if (depth != 0) return null;
        // i is at ], check for (url)
        if (i + 1 < end and line[i + 1] == '(') {
            var j = i + 2;
            var paren_depth: usize = 1;
            while (j < end) {
                if (line[j] == '(') paren_depth += 1;
                if (line[j] == ')') {
                    paren_depth -= 1;
                    if (paren_depth == 0) return j + 1;
                }
                j += 1;
            }
        }
        return null;
    }

    /// Check if text starts with a GFM alert marker: [!NOTE], [!TIP], [!IMPORTANT], [!WARNING], [!CAUTION]
    fn isAlertMarker(text: []const u8) ?usize {
        if (text.len < 6 or text[0] != '[' or text[1] != '!') return null;
        // Find closing ]
        var i: usize = 2;
        while (i < text.len and i < 20) : (i += 1) {
            if (text[i] == ']') {
                const label = text[2..i];
                if (isAlertLabel(label)) {
                    return i + 1;
                }
                return null;
            }
            // Alert labels are uppercase letters only
            if (!std.ascii.isAlphabetic(text[i])) return null;
        }
        return null;
    }

    fn isAlertLabel(label: []const u8) bool {
        const alert_labels = [_][]const u8{ "NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION" };
        for (alert_labels) |valid| {
            if (std.ascii.eqlIgnoreCase(label, valid)) return true;
        }
        return false;
    }

    /// Check if trimmed text starts with a footnote definition: [^label]:
    fn isFootnoteDefinition(trimmed: []const u8) ?usize {
        if (trimmed.len < 5 or trimmed[0] != '[' or trimmed[1] != '^') return null;
        var i: usize = 2;
        // Label must have at least one character
        if (i >= trimmed.len or !isFootnoteLabelChar(trimmed[i])) return null;
        while (i < trimmed.len and isFootnoteLabelChar(trimmed[i])) : (i += 1) {}
        if (i >= trimmed.len or trimmed[i] != ']') return null;
        i += 1;
        if (i >= trimmed.len or trimmed[i] != ':') return null;
        i += 1;
        // Include the trailing space if present
        if (i < trimmed.len and trimmed[i] == ' ') i += 1;
        return i;
    }

    fn isFootnoteLabelChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
    }

    /// Find footnote reference: [^label]
    fn findFootnoteRefEnd(line: []const u8, start: usize, end: usize) ?usize {
        if (start + 3 >= end) return null;
        if (line[start] != '[' or line[start + 1] != '^') return null;
        var i = start + 2;
        if (i >= end or !isFootnoteLabelChar(line[i])) return null;
        while (i < end and isFootnoteLabelChar(line[i])) : (i += 1) {}
        if (i >= end or line[i] != ']') return null;
        // Make sure it's not a footnote definition (not followed by ':')
        if (i + 1 < end and line[i + 1] == ':') return null;
        return i + 1;
    }

    /// Find autolink in angle brackets: <https://...> <http://...> <mailto:...>
    fn findAutolink(line: []const u8, start: usize, end: usize) ?usize {
        if (start + 1 >= end) return null;
        const after_bracket = line[start + 1 .. end];
        const is_url = std.mem.startsWith(u8, after_bracket, "https://") or
            std.mem.startsWith(u8, after_bracket, "http://") or
            std.mem.startsWith(u8, after_bracket, "mailto:");
        if (!is_url) return null;
        // Find closing >
        if (std.mem.indexOfScalarPos(u8, line, start + 1, '>')) |close| {
            // Autolinks cannot contain spaces
            const content = line[start + 1 .. close];
            if (std.mem.indexOfScalar(u8, content, ' ') != null) return null;
            return close + 1;
        }
        return null;
    }

    fn isEmojiNameChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '+' or ch == '-';
    }

    /// Find emoji shortcode: :name: (at least 2 chars between colons)
    fn findEmojiEnd(line: []const u8, start: usize, end: usize) ?usize {
        var i = start + 1;
        const name_start = i;
        while (i < end and isEmojiNameChar(line[i])) : (i += 1) {}
        if (i >= end or line[i] != ':') return null;
        // Name must be at least 2 characters
        if (i - name_start < 2) return null;
        return i + 1;
    }

    /// Match a bare URL starting with http:// or https://
    fn matchesBareUrl(line: []const u8, start: usize, end: usize) ?usize {
        const remaining = line[start..end];
        const prefix_len: usize = if (std.mem.startsWith(u8, remaining, "https://"))
            8
        else if (std.mem.startsWith(u8, remaining, "http://"))
            7
        else
            return null;

        // Must have at least one char after the prefix
        if (start + prefix_len >= end) return null;

        // Scan until we hit whitespace or end of line
        var i = start + prefix_len;
        while (i < end and !std.ascii.isWhitespace(line[i])) : (i += 1) {}

        // Strip trailing punctuation that's unlikely to be part of URL
        while (i > start + prefix_len) {
            const prev = line[i - 1];
            if (prev == '.' or prev == ',' or prev == ';' or prev == ':' or
                prev == '!' or prev == '?' or prev == ')' or prev == '\'' or prev == '"')
            {
                i -= 1;
            } else break;
        }

        if (i <= start + prefix_len) return null;
        return i;
    }
};

const testing = std.testing;

test "MdHighlighter heading" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator, "## Hello World", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 2);
    try testing.expectEqual(MdHighlighter.TokenKind.heading_marker, result.tokens[0].kind);
    try testing.expectEqual(MdHighlighter.TokenKind.heading_text, result.tokens[1].kind);
    try testing.expectEqual(MdHighlighter.LineState.normal, result.state_out);
}

test "MdHighlighter fenced code block" {
    // Opening fence
    const r1 = try MdHighlighter.tokenizeLine(testing.allocator,"```python", .normal);
    defer testing.allocator.free(r1.tokens);
    try testing.expectEqual(MdHighlighter.LineState.fenced_code, r1.state_out);
    try testing.expectEqual(MdHighlighter.TokenKind.fence, r1.tokens[0].kind);

    // Code line inside
    const r2 = try MdHighlighter.tokenizeLine(testing.allocator,"print('hello')", .fenced_code);
    defer testing.allocator.free(r2.tokens);
    try testing.expectEqual(MdHighlighter.LineState.fenced_code, r2.state_out);
    try testing.expectEqual(MdHighlighter.TokenKind.code_line, r2.tokens[0].kind);

    // Closing fence
    const r3 = try MdHighlighter.tokenizeLine(testing.allocator,"```", .fenced_code);
    defer testing.allocator.free(r3.tokens);
    try testing.expectEqual(MdHighlighter.LineState.normal, r3.state_out);
    try testing.expectEqual(MdHighlighter.TokenKind.fence, r3.tokens[0].kind);
}

test "MdHighlighter bold text" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"hello **world** end", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 3);
    // Should have: text, bold, text
    var has_bold = false;
    for (result.tokens) |tok| {
        if (tok.kind == .bold) has_bold = true;
    }
    try testing.expect(has_bold);
}

test "MdHighlighter italic text" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"hello *world* end", .normal);
    defer testing.allocator.free(result.tokens);

    var has_italic = false;
    for (result.tokens) |tok| {
        if (tok.kind == .italic) has_italic = true;
    }
    try testing.expect(has_italic);
}

test "MdHighlighter inline code" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"use `code` here", .normal);
    defer testing.allocator.free(result.tokens);

    var has_code = false;
    for (result.tokens) |tok| {
        if (tok.kind == .code_span) has_code = true;
    }
    try testing.expect(has_code);
}

test "MdHighlighter link" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"[click](https://example.com)", .normal);
    defer testing.allocator.free(result.tokens);

    var has_link_text = false;
    var has_link_url = false;
    for (result.tokens) |tok| {
        if (tok.kind == .link_text) has_link_text = true;
        if (tok.kind == .link_url) has_link_url = true;
    }
    try testing.expect(has_link_text);
    try testing.expect(has_link_url);
}

test "MdHighlighter unordered list" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"- item one", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 1);
    try testing.expectEqual(MdHighlighter.TokenKind.list_marker, result.tokens[0].kind);
}

test "MdHighlighter ordered list" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"1. first item", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 1);
    try testing.expectEqual(MdHighlighter.TokenKind.list_marker, result.tokens[0].kind);
}

test "MdHighlighter table row" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"| Col1 | Col2 |", .normal);
    defer testing.allocator.free(result.tokens);

    var pipe_count: usize = 0;
    for (result.tokens) |tok| {
        if (tok.kind == .table_pipe) pipe_count += 1;
    }
    try testing.expect(pipe_count >= 2);
}

test "MdHighlighter table separator" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"| --- | :---: |", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 1);
    try testing.expectEqual(MdHighlighter.TokenKind.table_align, result.tokens[0].kind);
}

test "MdHighlighter blockquote" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"> quoted text", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 1);
    try testing.expectEqual(MdHighlighter.TokenKind.blockquote_marker, result.tokens[0].kind);
}

test "MdHighlighter horizontal rule" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"---", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 1);
    try testing.expectEqual(MdHighlighter.TokenKind.horizontal_rule, result.tokens[0].kind);
}

test "MdHighlighter strikethrough" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"~~deleted~~", .normal);
    defer testing.allocator.free(result.tokens);

    var has_strike = false;
    for (result.tokens) |tok| {
        if (tok.kind == .strikethrough) has_strike = true;
    }
    try testing.expect(has_strike);
}

test "MdHighlighter task list" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"- [x] done", .normal);
    defer testing.allocator.free(result.tokens);

    var has_task = false;
    for (result.tokens) |tok| {
        if (tok.kind == .task_marker) has_task = true;
    }
    try testing.expect(has_task);
}

test "MdHighlighter image" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"![alt](img.png)", .normal);
    defer testing.allocator.free(result.tokens);

    var has_image = false;
    for (result.tokens) |tok| {
        if (tok.kind == .image_marker) has_image = true;
    }
    try testing.expect(has_image);
}

test "MdHighlighter escape sequence" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"\\*not italic\\*", .normal);
    defer testing.allocator.free(result.tokens);

    var has_escape = false;
    for (result.tokens) |tok| {
        if (tok.kind == .escape) has_escape = true;
    }
    try testing.expect(has_escape);
}

test "MdHighlighter empty line" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"", .normal);
    defer testing.allocator.free(result.tokens);
    try testing.expectEqual(@as(usize, 0), result.tokens.len);
}

test "MdHighlighter plain text" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"just some text", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 1);
    try testing.expectEqual(MdHighlighter.TokenKind.text, result.tokens[0].kind);
}

test "MdHighlighter bold_italic" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"***bold italic***", .normal);
    defer testing.allocator.free(result.tokens);

    var has_bold_italic = false;
    for (result.tokens) |tok| {
        if (tok.kind == .bold_italic) has_bold_italic = true;
    }
    try testing.expect(has_bold_italic);
}

test "MdHighlighter html tag" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"<div>content</div>", .normal);
    defer testing.allocator.free(result.tokens);

    var has_html = false;
    for (result.tokens) |tok| {
        if (tok.kind == .html_tag) has_html = true;
    }
    try testing.expect(has_html);
}

test "MdHighlighter heading with inline formatting" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"## Hello **bold** world", .normal);
    defer testing.allocator.free(result.tokens);

    // Should have heading_marker, then heading_text and bold tokens
    try testing.expectEqual(MdHighlighter.TokenKind.heading_marker, result.tokens[0].kind);
    var has_bold = false;
    for (result.tokens) |tok| {
        if (tok.kind == .bold) has_bold = true;
    }
    try testing.expect(has_bold);
}

test "MdHighlighter - dash list not confused with hr" {
    const h = MdHighlighter.init(testing.allocator);
    // "- item" is a list, not an HR
    const result = try h.tokenizeLine("- item", .normal);
    defer testing.allocator.free(result.tokens);
    try testing.expectEqual(MdHighlighter.TokenKind.list_marker, result.tokens[0].kind);
}

test "MdHighlighter autolink in angle brackets" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"visit <https://example.com> now", .normal);
    defer testing.allocator.free(result.tokens);

    var has_autolink = false;
    for (result.tokens) |tok| {
        if (tok.kind == .autolink) has_autolink = true;
    }
    try testing.expect(has_autolink);
}

test "MdHighlighter bare URL autolink" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"visit https://example.com now", .normal);
    defer testing.allocator.free(result.tokens);

    var has_autolink = false;
    for (result.tokens) |tok| {
        if (tok.kind == .autolink) {
            has_autolink = true;
            const url = "visit https://example.com now"[tok.start..tok.end];
            try testing.expectEqualStrings("https://example.com", url);
        }
    }
    try testing.expect(has_autolink);
}

test "MdHighlighter footnote reference" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"text[^1] more", .normal);
    defer testing.allocator.free(result.tokens);

    var has_footnote_ref = false;
    for (result.tokens) |tok| {
        if (tok.kind == .footnote_ref) has_footnote_ref = true;
    }
    try testing.expect(has_footnote_ref);
}

test "MdHighlighter footnote definition" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"[^1]: This is the footnote", .normal);
    defer testing.allocator.free(result.tokens);

    try testing.expect(result.tokens.len >= 1);
    try testing.expectEqual(MdHighlighter.TokenKind.footnote_def, result.tokens[0].kind);
}

test "MdHighlighter alert marker" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"> [!NOTE]", .normal);
    defer testing.allocator.free(result.tokens);

    var has_alert = false;
    for (result.tokens) |tok| {
        if (tok.kind == .alert_marker) has_alert = true;
    }
    try testing.expect(has_alert);
}

test "MdHighlighter alert warning" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"> [!WARNING]", .normal);
    defer testing.allocator.free(result.tokens);

    var has_blockquote = false;
    var has_alert = false;
    for (result.tokens) |tok| {
        if (tok.kind == .blockquote_marker) has_blockquote = true;
        if (tok.kind == .alert_marker) has_alert = true;
    }
    try testing.expect(has_blockquote);
    try testing.expect(has_alert);
}

test "MdHighlighter emoji shortcode" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"hello :smile: world", .normal);
    defer testing.allocator.free(result.tokens);

    var has_emoji = false;
    for (result.tokens) |tok| {
        if (tok.kind == .emoji) has_emoji = true;
    }
    try testing.expect(has_emoji);
}

test "MdHighlighter emoji with plus and dash" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,":+1: and :thumbs-up:", .normal);
    defer testing.allocator.free(result.tokens);

    var emoji_count: usize = 0;
    for (result.tokens) |tok| {
        if (tok.kind == .emoji) emoji_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), emoji_count);
}

test "MdHighlighter single colon not emoji" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"time: 3:00", .normal);
    defer testing.allocator.free(result.tokens);

    var has_emoji = false;
    for (result.tokens) |tok| {
        if (tok.kind == .emoji) has_emoji = true;
    }
    try testing.expect(!has_emoji);
}

test "MdHighlighter footnote ref not confused with definition" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"See [^foo] for details", .normal);
    defer testing.allocator.free(result.tokens);

    var has_ref = false;
    var has_def = false;
    for (result.tokens) |tok| {
        if (tok.kind == .footnote_ref) has_ref = true;
        if (tok.kind == .footnote_def) has_def = true;
    }
    try testing.expect(has_ref);
    try testing.expect(!has_def);
}

test "MdHighlighter mailto autolink" {
    const result = try MdHighlighter.tokenizeLine(testing.allocator,"<mailto:user@example.com>", .normal);
    defer testing.allocator.free(result.tokens);

    var has_autolink = false;
    for (result.tokens) |tok| {
        if (tok.kind == .autolink) has_autolink = true;
    }
    try testing.expect(has_autolink);
}
