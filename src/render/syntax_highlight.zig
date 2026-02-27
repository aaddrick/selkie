const std = @import("std");

pub const TokenKind = enum {
    keyword,
    string,
    comment,
    number,
    type_name,
    function,
    operator,
    punctuation,
    text,
};

pub const Token = struct {
    start: usize,
    end: usize,
    kind: TokenKind,
};

const LangDef = struct {
    keywords: []const []const u8,
    types: []const []const u8,
    builtins: []const []const u8,
    line_comment: ?[]const u8,
    block_comment_start: ?[]const u8,
    block_comment_end: ?[]const u8,
    string_chars: []const u8, // quote chars that delimit strings
    has_single_quote_strings: bool,
    has_backtick_strings: bool,
};

// --- Language definitions ---

const zig_keywords = [_][]const u8{
    "const",     "var",       "fn",        "pub",       "return",   "if",
    "else",      "while",     "for",       "switch",    "break",    "continue",
    "defer",     "errdefer",  "try",       "catch",     "orelse",   "and",
    "or",        "not",       "struct",    "enum",      "union",    "error",
    "test",      "comptime",  "inline",    "export",    "extern",   "align",
    "volatile",  "allowzero", "threadlocal", "linksection", "unreachable",
    "undefined", "null",      "true",      "false",     "async",    "await",
    "suspend",   "resume",    "nosuspend", "anytype",   "opaque",   "usingnamespace",
};
const zig_types = [_][]const u8{
    "u8",    "u16",   "u32",    "u64",   "u128",  "usize",
    "i8",    "i16",   "i32",    "i64",   "i128",  "isize",
    "f16",   "f32",   "f64",    "f128",  "bool",  "void",
    "type",  "noreturn", "anyerror", "anyframe", "comptime_int", "comptime_float",
};
const zig_builtins = [_][]const u8{
    "@import", "@as",       "@intCast", "@floatCast", "@ptrCast",  "@alignCast",
    "@min",    "@max",      "@memcpy",  "@memset",    "@intFromFloat",
    "@floatFromInt", "@intFromEnum", "@enumFromInt", "@bitCast", "@truncate",
    "@TypeOf", "@typeInfo", "@field",   "@This",      "@Vector",
};
const zig_def = LangDef{
    .keywords = &zig_keywords,
    .types = &zig_types,
    .builtins = &zig_builtins,
    .line_comment = "//",
    .block_comment_start = null,
    .block_comment_end = null,
    .string_chars = "\"",
    .has_single_quote_strings = true, // char literals
    .has_backtick_strings = false,
};

const python_keywords = [_][]const u8{
    "def",     "class",  "return",  "if",      "elif",    "else",
    "for",     "while",  "break",   "continue", "pass",    "import",
    "from",    "as",     "try",     "except",  "finally", "raise",
    "with",    "yield",  "lambda",  "and",     "or",      "not",
    "in",      "is",     "global",  "nonlocal", "assert",  "del",
    "True",    "False",  "None",    "async",   "await",
};
const python_types = [_][]const u8{
    "int", "float", "str", "bool", "list", "dict", "tuple", "set", "bytes", "object", "type",
};
const python_def = LangDef{
    .keywords = &python_keywords,
    .types = &python_types,
    .builtins = &[_][]const u8{},
    .line_comment = "#",
    .block_comment_start = null,
    .block_comment_end = null,
    .string_chars = "\"'",
    .has_single_quote_strings = true,
    .has_backtick_strings = false,
};

const js_keywords = [_][]const u8{
    "function", "const",  "let",     "var",     "return",  "if",
    "else",     "for",    "while",   "do",      "switch",  "case",
    "break",    "continue", "new",   "delete",  "typeof",  "instanceof",
    "in",       "of",     "class",   "extends", "super",   "this",
    "import",   "export", "default", "from",    "async",   "await",
    "try",      "catch",  "finally", "throw",   "yield",   "true",
    "false",    "null",   "undefined", "void",  "with",
};
const js_types = [_][]const u8{
    "Array",   "Object",  "String",  "Number",  "Boolean", "Function",
    "Promise", "Map",     "Set",     "Date",    "RegExp",  "Error",
    "Symbol",  "BigInt",  "WeakMap", "WeakSet",
};
const js_def = LangDef{
    .keywords = &js_keywords,
    .types = &js_types,
    .builtins = &[_][]const u8{},
    .line_comment = "//",
    .block_comment_start = "/*",
    .block_comment_end = "*/",
    .string_chars = "\"'",
    .has_single_quote_strings = true,
    .has_backtick_strings = true,
};

const ts_keywords = [_][]const u8{
    "function", "const",    "let",       "var",       "return",  "if",
    "else",     "for",      "while",     "do",        "switch",  "case",
    "break",    "continue", "new",       "delete",    "typeof",  "instanceof",
    "in",       "of",       "class",     "extends",   "super",   "this",
    "import",   "export",   "default",   "from",      "async",   "await",
    "try",      "catch",    "finally",   "throw",     "yield",   "true",
    "false",    "null",     "undefined", "void",      "with",
    "interface", "type",    "enum",      "namespace", "declare", "implements",
    "abstract", "readonly", "as",        "is",        "keyof",   "infer",
};
const ts_types = [_][]const u8{
    "string",  "number",  "boolean", "any",     "unknown", "never",
    "void",    "object",  "Array",   "Promise", "Record",  "Partial",
    "Required", "Readonly", "Pick",  "Omit",    "Exclude", "Extract",
};
const ts_def = LangDef{
    .keywords = &ts_keywords,
    .types = &ts_types,
    .builtins = &[_][]const u8{},
    .line_comment = "//",
    .block_comment_start = "/*",
    .block_comment_end = "*/",
    .string_chars = "\"'",
    .has_single_quote_strings = true,
    .has_backtick_strings = true,
};

const c_keywords = [_][]const u8{
    "auto",     "break",   "case",     "const",    "continue", "default",
    "do",       "else",    "enum",     "extern",   "for",      "goto",
    "if",       "inline",  "register", "restrict", "return",   "sizeof",
    "static",   "struct",  "switch",   "typedef",  "union",    "volatile",
    "while",    "NULL",    "true",     "false",
};
const c_types = [_][]const u8{
    "void",    "char",    "short",   "int",     "long",    "float",
    "double",  "signed",  "unsigned", "size_t",  "ssize_t", "int8_t",
    "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
    "uint64_t", "bool",   "FILE",    "ptrdiff_t",
};
const c_def = LangDef{
    .keywords = &c_keywords,
    .types = &c_types,
    .builtins = &[_][]const u8{},
    .line_comment = "//",
    .block_comment_start = "/*",
    .block_comment_end = "*/",
    .string_chars = "\"",
    .has_single_quote_strings = true, // char literals
    .has_backtick_strings = false,
};

const rust_keywords = [_][]const u8{
    "fn",      "let",     "mut",     "const",   "pub",     "return",
    "if",      "else",    "match",   "for",     "while",   "loop",
    "break",   "continue", "struct", "enum",    "impl",    "trait",
    "type",    "use",     "mod",     "crate",   "self",    "super",
    "as",      "in",      "ref",     "move",    "async",   "await",
    "where",   "unsafe",  "extern",  "dyn",     "true",    "false",
    "Some",    "None",    "Ok",      "Err",
};
const rust_types = [_][]const u8{
    "u8",     "u16",    "u32",    "u64",    "u128",   "usize",
    "i8",     "i16",    "i32",    "i64",    "i128",   "isize",
    "f32",    "f64",    "bool",   "char",   "str",    "String",
    "Vec",    "Option", "Result", "Box",    "Rc",     "Arc",
    "HashMap", "HashSet", "Self",
};
const rust_def = LangDef{
    .keywords = &rust_keywords,
    .types = &rust_types,
    .builtins = &[_][]const u8{},
    .line_comment = "//",
    .block_comment_start = "/*",
    .block_comment_end = "*/",
    .string_chars = "\"",
    .has_single_quote_strings = true, // char literals
    .has_backtick_strings = false,
};

const go_keywords = [_][]const u8{
    "func",      "var",     "const",   "type",    "return",  "if",
    "else",      "for",     "range",   "switch",  "case",    "break",
    "continue",  "default", "package", "import",  "struct",  "interface",
    "map",       "chan",     "go",      "defer",   "select",  "fallthrough",
    "goto",      "true",    "false",   "nil",
};
const go_types = [_][]const u8{
    "int",    "int8",   "int16",  "int32",   "int64",
    "uint",   "uint8",  "uint16", "uint32",  "uint64",
    "float32", "float64", "complex64", "complex128",
    "bool",   "string", "byte",   "rune",    "error",
    "uintptr", "any",
};
const go_def = LangDef{
    .keywords = &go_keywords,
    .types = &go_types,
    .builtins = &[_][]const u8{},
    .line_comment = "//",
    .block_comment_start = "/*",
    .block_comment_end = "*/",
    .string_chars = "\"",
    .has_single_quote_strings = false,
    .has_backtick_strings = true,
};

const java_keywords = [_][]const u8{
    "abstract",  "assert",     "break",     "case",      "catch",    "class",
    "const",     "continue",   "default",   "do",        "else",     "enum",
    "extends",   "final",      "finally",   "for",       "goto",     "if",
    "implements", "import",    "instanceof", "interface", "native",   "new",
    "package",   "private",   "protected",  "public",    "return",   "static",
    "strictfp",  "super",     "switch",     "synchronized", "this",  "throw",
    "throws",    "transient", "try",        "void",      "volatile", "while",
    "true",      "false",     "null",
};
const java_types = [_][]const u8{
    "byte",    "short",   "int",     "long",    "float",   "double",
    "boolean", "char",    "String",  "Object",  "Integer", "Long",
    "Double",  "Float",   "Boolean", "List",    "Map",     "Set",
    "ArrayList", "HashMap",
};
const java_def = LangDef{
    .keywords = &java_keywords,
    .types = &java_types,
    .builtins = &[_][]const u8{},
    .line_comment = "//",
    .block_comment_start = "/*",
    .block_comment_end = "*/",
    .string_chars = "\"",
    .has_single_quote_strings = true, // char literals
    .has_backtick_strings = false,
};

const shell_keywords = [_][]const u8{
    "if",     "then",   "else",   "elif",   "fi",     "for",
    "while",  "do",     "done",   "case",   "esac",   "in",
    "function", "return", "local", "export", "source", "exit",
    "echo",   "read",   "set",    "unset",  "shift",  "trap",
    "eval",   "exec",   "true",   "false",
};
const shell_def = LangDef{
    .keywords = &shell_keywords,
    .types = &[_][]const u8{},
    .builtins = &[_][]const u8{},
    .line_comment = "#",
    .block_comment_start = null,
    .block_comment_end = null,
    .string_chars = "\"'",
    .has_single_quote_strings = true,
    .has_backtick_strings = true,
};

const json_keywords = [_][]const u8{ "true", "false", "null" };
const json_def = LangDef{
    .keywords = &json_keywords,
    .types = &[_][]const u8{},
    .builtins = &[_][]const u8{},
    .line_comment = null,
    .block_comment_start = null,
    .block_comment_end = null,
    .string_chars = "\"",
    .has_single_quote_strings = false,
    .has_backtick_strings = false,
};

const toml_keywords = [_][]const u8{ "true", "false" };
const toml_def = LangDef{
    .keywords = &toml_keywords,
    .types = &[_][]const u8{},
    .builtins = &[_][]const u8{},
    .line_comment = "#",
    .block_comment_start = null,
    .block_comment_end = null,
    .string_chars = "\"'",
    .has_single_quote_strings = true,
    .has_backtick_strings = false,
};

const yaml_keywords = [_][]const u8{ "true", "false", "null", "yes", "no", "on", "off" };
const yaml_def = LangDef{
    .keywords = &yaml_keywords,
    .types = &[_][]const u8{},
    .builtins = &[_][]const u8{},
    .line_comment = "#",
    .block_comment_start = null,
    .block_comment_end = null,
    .string_chars = "\"'",
    .has_single_quote_strings = true,
    .has_backtick_strings = false,
};

const html_keywords = [_][]const u8{
    "html",  "head",   "body",   "div",    "span",   "p",
    "a",     "img",    "ul",     "ol",     "li",     "table",
    "tr",    "td",     "th",     "form",   "input",  "button",
    "script", "style", "link",   "meta",   "title",  "h1",
    "h2",    "h3",     "h4",     "h5",     "h6",     "section",
    "nav",   "header", "footer", "main",   "article", "aside",
};
const html_def = LangDef{
    .keywords = &html_keywords,
    .types = &[_][]const u8{},
    .builtins = &[_][]const u8{},
    .line_comment = null,
    .block_comment_start = "<!--",
    .block_comment_end = "-->",
    .string_chars = "\"'",
    .has_single_quote_strings = true,
    .has_backtick_strings = false,
};

const css_keywords = [_][]const u8{
    "color",      "background", "border",    "margin",   "padding",   "display",
    "position",   "width",      "height",    "font",     "text",      "flex",
    "grid",       "align",      "justify",   "overflow", "transform", "transition",
    "animation",  "opacity",    "z-index",   "important", "none",     "auto",
    "inherit",    "initial",    "unset",
};
const css_def = LangDef{
    .keywords = &css_keywords,
    .types = &[_][]const u8{},
    .builtins = &[_][]const u8{},
    .line_comment = null,
    .block_comment_start = "/*",
    .block_comment_end = "*/",
    .string_chars = "\"'",
    .has_single_quote_strings = true,
    .has_backtick_strings = false,
};

const sql_keywords = [_][]const u8{
    "SELECT",  "FROM",    "WHERE",   "INSERT",  "INTO",    "UPDATE",
    "DELETE",  "CREATE",  "DROP",    "ALTER",   "TABLE",   "INDEX",
    "JOIN",    "LEFT",    "RIGHT",   "INNER",   "OUTER",   "ON",
    "AND",     "OR",      "NOT",     "IN",      "IS",      "NULL",
    "AS",      "ORDER",   "BY",      "GROUP",   "HAVING",  "LIMIT",
    "OFFSET",  "UNION",   "ALL",     "DISTINCT", "SET",    "VALUES",
    "BEGIN",   "COMMIT",  "ROLLBACK", "TRANSACTION", "PRIMARY", "KEY",
    "FOREIGN", "REFERENCES", "CASCADE", "DEFAULT", "CONSTRAINT",
    // lowercase variants
    "select",  "from",    "where",   "insert",  "into",    "update",
    "delete",  "create",  "drop",    "alter",   "table",   "index",
    "join",    "left",    "right",   "inner",   "outer",   "on",
    "and",     "or",      "not",     "in",      "is",      "null",
    "as",      "order",   "by",      "group",   "having",  "limit",
    "offset",  "union",   "all",     "distinct", "set",    "values",
    "begin",   "commit",  "rollback", "transaction", "primary", "key",
    "foreign", "references", "cascade", "default", "constraint",
};
const sql_types = [_][]const u8{
    "INT",      "INTEGER",  "BIGINT",   "SMALLINT", "TINYINT",
    "VARCHAR",  "CHAR",     "TEXT",     "BOOLEAN",  "BOOL",
    "FLOAT",    "DOUBLE",   "DECIMAL",  "NUMERIC",  "DATE",
    "TIMESTAMP", "DATETIME", "SERIAL",  "UUID",
};
const sql_def = LangDef{
    .keywords = &sql_keywords,
    .types = &sql_types,
    .builtins = &[_][]const u8{},
    .line_comment = "--",
    .block_comment_start = "/*",
    .block_comment_end = "*/",
    .string_chars = "'",
    .has_single_quote_strings = true,
    .has_backtick_strings = false,
};

/// Look up a language definition from a fence_info string.
/// Returns null for unrecognized languages.
pub fn getLangDef(fence_info: []const u8) ?*const LangDef {
    // Trim whitespace and take first word
    var lang = fence_info;
    if (std.mem.indexOfScalar(u8, lang, ' ')) |idx| {
        lang = lang[0..idx];
    }
    // Convert to lowercase comparison
    if (eqlIgnoreCase(lang, "zig")) return &zig_def;
    if (eqlIgnoreCase(lang, "python") or eqlIgnoreCase(lang, "py")) return &python_def;
    if (eqlIgnoreCase(lang, "javascript") or eqlIgnoreCase(lang, "js")) return &js_def;
    if (eqlIgnoreCase(lang, "typescript") or eqlIgnoreCase(lang, "ts")) return &ts_def;
    if (eqlIgnoreCase(lang, "c") or eqlIgnoreCase(lang, "cpp") or eqlIgnoreCase(lang, "c++") or eqlIgnoreCase(lang, "h")) return &c_def;
    if (eqlIgnoreCase(lang, "rust") or eqlIgnoreCase(lang, "rs")) return &rust_def;
    if (eqlIgnoreCase(lang, "go") or eqlIgnoreCase(lang, "golang")) return &go_def;
    if (eqlIgnoreCase(lang, "java")) return &java_def;
    if (eqlIgnoreCase(lang, "bash") or eqlIgnoreCase(lang, "sh") or eqlIgnoreCase(lang, "shell") or eqlIgnoreCase(lang, "zsh")) return &shell_def;
    if (eqlIgnoreCase(lang, "json") or eqlIgnoreCase(lang, "jsonc")) return &json_def;
    if (eqlIgnoreCase(lang, "toml")) return &toml_def;
    if (eqlIgnoreCase(lang, "yaml") or eqlIgnoreCase(lang, "yml")) return &yaml_def;
    if (eqlIgnoreCase(lang, "html") or eqlIgnoreCase(lang, "htm") or eqlIgnoreCase(lang, "xml")) return &html_def;
    if (eqlIgnoreCase(lang, "css") or eqlIgnoreCase(lang, "scss") or eqlIgnoreCase(lang, "less")) return &css_def;
    if (eqlIgnoreCase(lang, "sql")) return &sql_def;
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Tokenize source code using a language definition.
/// Returns a list of tokens. Caller owns the returned slice.
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8, lang_def: *const LangDef) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    while (i < source.len) {
        const ch = source[i];

        // Skip newlines and whitespace as plain text
        if (ch == '\n' or ch == '\r' or ch == ' ' or ch == '\t') {
            const start = i;
            while (i < source.len and (source[i] == '\n' or source[i] == '\r' or source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
            try tokens.append(.{ .start = start, .end = i, .kind = .text });
            continue;
        }

        // Block comments
        if (lang_def.block_comment_start) |bcs| {
            if (i + bcs.len <= source.len and std.mem.eql(u8, source[i..][0..bcs.len], bcs)) {
                const start = i;
                i += bcs.len;
                const bce = lang_def.block_comment_end.?;
                while (i + bce.len <= source.len) {
                    if (std.mem.eql(u8, source[i..][0..bce.len], bce)) {
                        i += bce.len;
                        break;
                    }
                    i += 1;
                } else {
                    i = source.len;
                }
                try tokens.append(.{ .start = start, .end = i, .kind = .comment });
                continue;
            }
        }

        // Line comments
        if (lang_def.line_comment) |lc| {
            if (i + lc.len <= source.len and std.mem.eql(u8, source[i..][0..lc.len], lc)) {
                const start = i;
                while (i < source.len and source[i] != '\n') : (i += 1) {}
                try tokens.append(.{ .start = start, .end = i, .kind = .comment });
                continue;
            }
        }

        // Strings: double quotes
        if (ch == '"' and std.mem.indexOfScalar(u8, lang_def.string_chars, '"') != null) {
            const start = i;
            i += 1;
            while (i < source.len and source[i] != '"' and source[i] != '\n') {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if (i < source.len and source[i] == '"') i += 1;
            try tokens.append(.{ .start = start, .end = i, .kind = .string });
            continue;
        }

        // Strings: single quotes
        if (ch == '\'' and lang_def.has_single_quote_strings) {
            const start = i;
            i += 1;
            while (i < source.len and source[i] != '\'' and source[i] != '\n') {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if (i < source.len and source[i] == '\'') i += 1;
            try tokens.append(.{ .start = start, .end = i, .kind = .string });
            continue;
        }

        // Strings: backtick
        if (ch == '`' and lang_def.has_backtick_strings) {
            const start = i;
            i += 1;
            while (i < source.len and source[i] != '`') {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if (i < source.len and source[i] == '`') i += 1;
            try tokens.append(.{ .start = start, .end = i, .kind = .string });
            continue;
        }

        // Numbers
        if (std.ascii.isDigit(ch) or (ch == '.' and i + 1 < source.len and std.ascii.isDigit(source[i + 1]))) {
            const start = i;
            // Hex: 0x...
            if (ch == '0' and i + 1 < source.len and (source[i + 1] == 'x' or source[i + 1] == 'X')) {
                i += 2;
                while (i < source.len and (std.ascii.isHex(source[i]) or source[i] == '_')) : (i += 1) {}
            }
            // Binary: 0b...
            else if (ch == '0' and i + 1 < source.len and (source[i + 1] == 'b' or source[i + 1] == 'B')) {
                i += 2;
                while (i < source.len and (source[i] == '0' or source[i] == '1' or source[i] == '_')) : (i += 1) {}
            }
            // Octal: 0o...
            else if (ch == '0' and i + 1 < source.len and (source[i + 1] == 'o' or source[i + 1] == 'O')) {
                i += 2;
                while (i < source.len and (source[i] >= '0' and source[i] <= '7' or source[i] == '_')) : (i += 1) {}
            } else {
                // Decimal (with optional dot and exponent)
                while (i < source.len and (std.ascii.isDigit(source[i]) or source[i] == '_')) : (i += 1) {}
                if (i < source.len and source[i] == '.') {
                    i += 1;
                    while (i < source.len and (std.ascii.isDigit(source[i]) or source[i] == '_')) : (i += 1) {}
                }
                if (i < source.len and (source[i] == 'e' or source[i] == 'E')) {
                    i += 1;
                    if (i < source.len and (source[i] == '+' or source[i] == '-')) i += 1;
                    while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) {}
                }
            }
            try tokens.append(.{ .start = start, .end = i, .kind = .number });
            continue;
        }

        // Zig builtins: @word
        if (ch == '@' and lang_def.builtins.len > 0) {
            const start = i;
            i += 1;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) : (i += 1) {}
            const word = source[start..i];
            var is_builtin = false;
            for (lang_def.builtins) |b| {
                if (std.mem.eql(u8, word, b)) {
                    is_builtin = true;
                    break;
                }
            }
            try tokens.append(.{ .start = start, .end = i, .kind = if (is_builtin) .function else .text });
            continue;
        }

        // Identifiers and keywords
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = i;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) : (i += 1) {}
            const word = source[start..i];

            var kind: TokenKind = .text;
            for (lang_def.keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    kind = .keyword;
                    break;
                }
            }
            if (kind == .text) {
                for (lang_def.types) |t| {
                    if (std.mem.eql(u8, word, t)) {
                        kind = .type_name;
                        break;
                    }
                }
            }
            // Heuristic: if followed by '(' it's likely a function call
            if (kind == .text and i < source.len and source[i] == '(') {
                kind = .function;
            }

            try tokens.append(.{ .start = start, .end = i, .kind = kind });
            continue;
        }

        // Operators
        if (isOperator(ch)) {
            try tokens.append(.{ .start = i, .end = i + 1, .kind = .operator });
            i += 1;
            continue;
        }

        // Punctuation
        if (isPunctuation(ch)) {
            try tokens.append(.{ .start = i, .end = i + 1, .kind = .punctuation });
            i += 1;
            continue;
        }

        // Anything else is plain text
        try tokens.append(.{ .start = i, .end = i + 1, .kind = .text });
        i += 1;
    }

    return tokens.toOwnedSlice();
}

fn isOperator(ch: u8) bool {
    return switch (ch) {
        '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~' => true,
        else => false,
    };
}

fn isPunctuation(ch: u8) bool {
    return switch (ch) {
        '(', ')', '{', '}', '[', ']', ';', ':', ',', '.' => true,
        else => false,
    };
}
