/*
 * latex_render.c — Lightweight LaTeX math parser
 *
 * Converts LaTeX math strings into a flat node tree for rendering.
 * Designed to be vendored and compiled as a static library.
 */

#include "latex_render.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* ====================================================================
 * Symbol table: LaTeX command → UTF-8 string
 * Sorted alphabetically for binary search.
 * ==================================================================== */

typedef struct {
    const char *name;
    const char *utf8;
} SymbolEntry;

static const SymbolEntry symbol_table[] = {
    {"Alpha",        "\xce\x91"},       /* Α */
    {"Beta",         "\xce\x92"},       /* Β */
    {"Chi",          "\xce\xa7"},       /* Χ */
    {"Delta",        "\xce\x94"},       /* Δ */
    {"Epsilon",      "\xce\x95"},       /* Ε */
    {"Eta",          "\xce\x97"},       /* Η */
    {"Gamma",        "\xce\x93"},       /* Γ */
    {"Iota",         "\xce\x99"},       /* Ι */
    {"Kappa",        "\xce\x9a"},       /* Κ */
    {"Lambda",       "\xce\x9b"},       /* Λ */
    {"Mu",           "\xce\x9c"},       /* Μ */
    {"Nu",           "\xce\x9d"},       /* Ν */
    {"Omega",        "\xce\xa9"},       /* Ω */
    {"Omicron",      "\xce\x9f"},       /* Ο */
    {"Phi",          "\xce\xa6"},       /* Φ */
    {"Pi",           "\xce\xa0"},       /* Π */
    {"Psi",          "\xce\xa8"},       /* Ψ */
    {"Rho",          "\xce\xa1"},       /* Ρ */
    {"Sigma",        "\xce\xa3"},       /* Σ */
    {"Tau",          "\xce\xa4"},       /* Τ */
    {"Theta",        "\xce\x98"},       /* Θ */
    {"Upsilon",      "\xce\xa5"},       /* Υ */
    {"Xi",           "\xce\x9e"},       /* Ξ */
    {"Zeta",         "\xce\x96"},       /* Ζ */
    {"aleph",        "\xd7\x90"},       /* א */
    {"alpha",        "\xce\xb1"},       /* α */
    {"amalg",        "\xe2\xa8\xbf"},   /* ⨿ */
    {"angle",        "\xe2\x88\xa0"},   /* ∠ */
    {"approx",       "\xe2\x89\x88"},   /* ≈ */
    {"ast",          "\xe2\x88\x97"},   /* ∗ */
    {"beta",         "\xce\xb2"},       /* β */
    {"bot",          "\xe2\x8a\xa5"},   /* ⊥ */
    {"bullet",       "\xe2\x80\xa2"},   /* • */
    {"cap",          "\xe2\x88\xa9"},   /* ∩ */
    {"cdot",         "\xc2\xb7"},       /* · */
    {"cdots",        "\xe2\x8b\xaf"},   /* ⋯ */
    {"chi",          "\xcf\x87"},       /* χ */
    {"circ",         "\xe2\x88\x98"},   /* ∘ */
    {"cong",         "\xe2\x89\x85"},   /* ≅ */
    {"cup",          "\xe2\x88\xaa"},   /* ∪ */
    {"dagger",       "\xe2\x80\xa0"},   /* † */
    {"ddagger",      "\xe2\x80\xa1"},   /* ‡ */
    {"ddots",        "\xe2\x8b\xb1"},   /* ⋱ */
    {"delta",        "\xce\xb4"},       /* δ */
    {"div",          "\xc3\xb7"},       /* ÷ */
    {"downarrow",    "\xe2\x86\x93"},   /* ↓ */
    {"ell",          "\xe2\x84\x93"},   /* ℓ */
    {"emptyset",     "\xe2\x88\x85"},   /* ∅ */
    {"epsilon",      "\xce\xb5"},       /* ε */
    {"equiv",        "\xe2\x89\xa1"},   /* ≡ */
    {"eta",          "\xce\xb7"},       /* η */
    {"exists",       "\xe2\x88\x83"},   /* ∃ */
    {"forall",       "\xe2\x88\x80"},   /* ∀ */
    {"gamma",        "\xce\xb3"},       /* γ */
    {"ge",           "\xe2\x89\xa5"},   /* ≥ */
    {"geq",          "\xe2\x89\xa5"},   /* ≥ */
    {"gg",           "\xe2\x89\xab"},   /* ≫ */
    {"hbar",         "\xe2\x84\x8f"},   /* ℏ */
    {"iff",          "\xe2\x9f\xba"},   /* ⟺ */
    {"imath",        "\xf0\x9d\x91\x96"}, /* 𝑖 */
    {"implies",      "\xe2\x9f\xb9"},   /* ⟹ */
    {"in",           "\xe2\x88\x88"},   /* ∈ */
    {"infty",        "\xe2\x88\x9e"},   /* ∞ */
    {"int",          "\xe2\x88\xab"},   /* ∫ */
    {"iota",         "\xce\xb9"},       /* ι */
    {"jmath",        "\xf0\x9d\x91\x97"}, /* 𝑗 */
    {"kappa",        "\xce\xba"},       /* κ */
    {"lambda",       "\xce\xbb"},       /* λ */
    {"langle",       "\xe2\x9f\xa8"},   /* ⟨ */
    {"lceil",        "\xe2\x8c\x88"},   /* ⌈ */
    {"ldots",        "\xe2\x80\xa6"},   /* … */
    {"le",           "\xe2\x89\xa4"},   /* ≤ */
    {"leftarrow",    "\xe2\x86\x90"},   /* ← */
    {"leftrightarrow","\xe2\x86\x94"},  /* ↔ */
    {"leq",          "\xe2\x89\xa4"},   /* ≤ */
    {"lfloor",       "\xe2\x8c\x8a"},   /* ⌊ */
    {"ll",           "\xe2\x89\xaa"},   /* ≪ */
    {"mapsto",       "\xe2\x86\xa6"},   /* ↦ */
    {"mid",          "\xe2\x88\xa3"},   /* ∣ */
    {"mp",           "\xe2\x88\x93"},   /* ∓ */
    {"mu",           "\xce\xbc"},       /* μ */
    {"nabla",        "\xe2\x88\x87"},   /* ∇ */
    {"ne",           "\xe2\x89\xa0"},   /* ≠ */
    {"neg",          "\xc2\xac"},       /* ¬ */
    {"neq",          "\xe2\x89\xa0"},   /* ≠ */
    {"ni",           "\xe2\x88\x8b"},   /* ∋ */
    {"not",          "\xc2\xac"},       /* ¬ */
    {"notin",        "\xe2\x88\x89"},   /* ∉ */
    {"nu",           "\xce\xbd"},       /* ν */
    {"odot",         "\xe2\x8a\x99"},   /* ⊙ */
    {"omega",        "\xcf\x89"},       /* ω */
    {"omicron",      "\xce\xbf"},       /* ο */
    {"oplus",        "\xe2\x8a\x95"},   /* ⊕ */
    {"otimes",       "\xe2\x8a\x97"},   /* ⊗ */
    {"parallel",     "\xe2\x88\xa5"},   /* ∥ */
    {"partial",      "\xe2\x88\x82"},   /* ∂ */
    {"perp",         "\xe2\x8a\xa5"},   /* ⊥ */
    {"phi",          "\xcf\x86"},       /* φ */
    {"pi",           "\xcf\x80"},       /* π */
    {"pm",           "\xc2\xb1"},       /* ± */
    {"prec",         "\xe2\x89\xba"},   /* ≺ */
    {"prime",        "\xe2\x80\xb2"},   /* ′ */
    {"prod",         "\xe2\x88\x8f"},   /* ∏ */
    {"propto",       "\xe2\x88\x9d"},   /* ∝ */
    {"psi",          "\xcf\x88"},       /* ψ */
    {"rangle",       "\xe2\x9f\xa9"},   /* ⟩ */
    {"rceil",        "\xe2\x8c\x89"},   /* ⌉ */
    {"rfloor",       "\xe2\x8c\x8b"},   /* ⌋ */
    {"rho",          "\xcf\x81"},       /* ρ */
    {"rightarrow",   "\xe2\x86\x92"},   /* → */
    {"sigma",        "\xcf\x83"},       /* σ */
    {"sim",          "\xe2\x88\xbc"},   /* ∼ */
    {"simeq",        "\xe2\x89\x83"},   /* ≃ */
    {"sqrt",         "\xe2\x88\x9a"},   /* √ */
    {"star",         "\xe2\x8b\x86"},   /* ⋆ */
    {"subset",       "\xe2\x8a\x82"},   /* ⊂ */
    {"subseteq",     "\xe2\x8a\x86"},   /* ⊆ */
    {"succ",         "\xe2\x89\xbb"},   /* ≻ */
    {"sum",          "\xe2\x88\x91"},   /* ∑ */
    {"supset",       "\xe2\x8a\x83"},   /* ⊃ */
    {"supseteq",     "\xe2\x8a\x87"},   /* ⊇ */
    {"tau",          "\xcf\x84"},       /* τ */
    {"theta",        "\xce\xb8"},       /* θ */
    {"times",        "\xc3\x97"},       /* × */
    {"to",           "\xe2\x86\x92"},   /* → */
    {"top",          "\xe2\x8a\xa4"},   /* ⊤ */
    {"triangle",     "\xe2\x96\xb3"},   /* △ */
    {"uparrow",      "\xe2\x86\x91"},   /* ↑ */
    {"upsilon",      "\xcf\x85"},       /* υ */
    {"varepsilon",   "\xce\xb5"},       /* ε */
    {"varphi",       "\xcf\x95"},       /* ϕ */
    {"varpi",        "\xcf\x96"},       /* ϖ */
    {"varrho",       "\xcf\xb1"},       /* ϱ */
    {"varsigma",     "\xcf\x82"},       /* ς */
    {"vartheta",     "\xcf\x91"},       /* ϑ */
    {"vdash",        "\xe2\x8a\xa2"},   /* ⊢ */
    {"vdots",        "\xe2\x8b\xae"},   /* ⋮ */
    {"vee",          "\xe2\x88\xa8"},   /* ∨ */
    {"wedge",        "\xe2\x88\xa7"},   /* ∧ */
    {"wp",           "\xe2\x84\x98"},   /* ℘ */
    {"xi",           "\xce\xbe"},       /* ξ */
    {"zeta",         "\xce\xb6"},       /* ζ */
};

#define SYMBOL_TABLE_SIZE (sizeof(symbol_table) / sizeof(symbol_table[0]))

/* ====================================================================
 * Internal helpers
 * ==================================================================== */

/* Binary search the symbol table. Returns UTF-8 string or NULL. */
static const char *lookup_symbol(const char *name, int name_len) {
    int lo = 0, hi = (int)SYMBOL_TABLE_SIZE - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        int cmp = strncmp(name, symbol_table[mid].name, (size_t)name_len);
        if (cmp == 0) {
            /* Check for exact match (name might be a prefix) */
            if (symbol_table[mid].name[name_len] == '\0')
                return symbol_table[mid].utf8;
            /* Our name is shorter — it comes before */
            cmp = -1;
        }
        if (cmp < 0)
            hi = mid - 1;
        else
            lo = mid + 1;
    }
    return NULL;
}

/* Ensure capacity for at least one more node. Returns 0 on success, -1 on failure. */
static int ensure_node_capacity(LatexParseResult *r) {
    if (r->count < r->capacity) return 0;
    int new_cap = r->capacity * 2;
    if (new_cap < 32) new_cap = 32;
    LatexNode *new_nodes = (LatexNode *)realloc(r->nodes, (size_t)new_cap * sizeof(LatexNode));
    if (!new_nodes) return -1;
    r->nodes = new_nodes;
    r->capacity = new_cap;
    return 0;
}

/* Allocate a new node, return its index or -1 on failure. */
static int alloc_node(LatexParseResult *r, int type) {
    if (ensure_node_capacity(r) < 0) return -1;
    int idx = r->count++;
    r->nodes[idx].type = type;
    r->nodes[idx].text = NULL;
    r->nodes[idx].text_len = 0;
    r->nodes[idx].first_child = -1;
    r->nodes[idx].next_sibling = -1;
    return idx;
}

/* Copy text into the string pool, return pointer. */
static const char *pool_string(LatexParseResult *r, const char *src, int len) {
    if (r->pool_used + len + 1 > r->pool_capacity) {
        int new_cap = r->pool_capacity * 2;
        if (new_cap < r->pool_used + len + 1 + 256) {
            new_cap = r->pool_used + len + 1 + 256;
        }
        char *new_pool = (char *)realloc(r->string_pool, (size_t)new_cap);
        if (!new_pool) return NULL;
        /* Update all existing text pointers (they point into the old pool) */
        ptrdiff_t delta = new_pool - r->string_pool;
        if (delta != 0) {
            for (int i = 0; i < r->count; i++) {
                if (r->nodes[i].text)
                    r->nodes[i].text += delta;
            }
        }
        r->string_pool = new_pool;
        r->pool_capacity = new_cap;
    }
    char *dst = r->string_pool + r->pool_used;
    memcpy(dst, src, (size_t)len);
    dst[len] = '\0';
    r->pool_used += len + 1;
    return dst;
}

/* Add a text node as a child of parent. Returns node index or -1. */
static int add_text_child(LatexParseResult *r, int parent, const char *text, int text_len) {
    int idx = alloc_node(r, LATEX_NODE_TEXT);
    if (idx < 0) return -1;
    const char *pooled = pool_string(r, text, text_len);
    if (!pooled) return -1;
    r->nodes[idx].text = pooled;
    r->nodes[idx].text_len = text_len;

    /* Link as child of parent */
    if (r->nodes[parent].first_child < 0) {
        r->nodes[parent].first_child = idx;
    } else {
        /* Find last child */
        int c = r->nodes[parent].first_child;
        while (r->nodes[c].next_sibling >= 0) c = r->nodes[c].next_sibling;
        r->nodes[c].next_sibling = idx;
    }
    return idx;
}

/* Link node as last child of parent. */
static void link_child(LatexParseResult *r, int parent, int child) {
    if (child < 0 || parent < 0) return;
    if (r->nodes[parent].first_child < 0) {
        r->nodes[parent].first_child = child;
    } else {
        int c = r->nodes[parent].first_child;
        while (r->nodes[c].next_sibling >= 0) c = r->nodes[c].next_sibling;
        r->nodes[c].next_sibling = child;
    }
}

/* Forward declaration */
static int parse_expr(LatexParseResult *r, const char *input, int len, int *pos, int parent, int stop_at_brace);

/* Skip whitespace */
static void skip_ws(const char *input, int len, int *pos) {
    while (*pos < len && (input[*pos] == ' ' || input[*pos] == '\t' ||
                          input[*pos] == '\n' || input[*pos] == '\r'))
        (*pos)++;
}

/* Parse a braced group {…}, return the group node index */
static int parse_group(LatexParseResult *r, const char *input, int len, int *pos) {
    if (*pos >= len || input[*pos] != '{') return -1;
    (*pos)++; /* skip '{' */
    int grp = alloc_node(r, LATEX_NODE_GROUP);
    if (grp < 0) return -1;
    parse_expr(r, input, len, pos, grp, 1);
    if (*pos < len && input[*pos] == '}') (*pos)++; /* skip '}' */
    return grp;
}

/* Parse a single token (command, char, group) as a node, return its index */
static int parse_atom(LatexParseResult *r, const char *input, int len, int *pos, int parent);

/* Check if a character is an operator that should be rendered with spacing */
static int is_math_operator(char c) {
    return c == '+' || c == '-' || c == '=' || c == '<' || c == '>';
}

/* Parse \begin{array}...\end{array} or \begin{matrix}...\end{matrix} */
static int parse_environment(LatexParseResult *r, const char *input, int len, int *pos) {
    /* We're positioned right after \begin{ — find the environment name */
    int name_start = *pos;
    while (*pos < len && input[*pos] != '}') (*pos)++;
    /* int name_len = *pos - name_start; */
    if (*pos < len) (*pos)++; /* skip '}' */

    /* Check for column spec (e.g., {cc} for array) */
    int is_array = (strncmp(input + name_start, "array", 5) == 0);
    if (is_array) {
        /* Skip column spec like {cc} or {c|c} */
        skip_ws(input, len, pos);
        if (*pos < len && input[*pos] == '{') {
            while (*pos < len && input[*pos] != '}') (*pos)++;
            if (*pos < len) (*pos)++; /* skip '}' */
        }
    }

    int matrix = alloc_node(r, LATEX_NODE_MATRIX);
    if (matrix < 0) return -1;

    /* Parse rows separated by \\ and cells separated by & */
    int current_row = alloc_node(r, LATEX_NODE_MATRIX_ROW);
    if (current_row < 0) return matrix;
    link_child(r, matrix, current_row);

    int current_cell = alloc_node(r, LATEX_NODE_MATRIX_CELL);
    if (current_cell < 0) return matrix;
    link_child(r, current_row, current_cell);

    while (*pos < len) {
        skip_ws(input, len, pos);
        if (*pos >= len) break;

        /* Check for \end{…} */
        if (input[*pos] == '\\' && *pos + 4 <= len && strncmp(input + *pos, "\\end", 4) == 0) {
            *pos += 4;
            /* Skip {name} */
            skip_ws(input, len, pos);
            if (*pos < len && input[*pos] == '{') {
                while (*pos < len && input[*pos] != '}') (*pos)++;
                if (*pos < len) (*pos)++;
            }
            break;
        }

        /* Check for \\ (row separator) */
        if (input[*pos] == '\\' && *pos + 1 < len && input[*pos + 1] == '\\') {
            *pos += 2;
            current_row = alloc_node(r, LATEX_NODE_MATRIX_ROW);
            if (current_row < 0) return matrix;
            link_child(r, matrix, current_row);
            current_cell = alloc_node(r, LATEX_NODE_MATRIX_CELL);
            if (current_cell < 0) return matrix;
            link_child(r, current_row, current_cell);
            continue;
        }

        /* Check for & (column separator) */
        if (input[*pos] == '&') {
            (*pos)++;
            current_cell = alloc_node(r, LATEX_NODE_MATRIX_CELL);
            if (current_cell < 0) return matrix;
            link_child(r, current_row, current_cell);
            continue;
        }

        /* Parse normal content into current cell */
        parse_atom(r, input, len, pos, current_cell);
    }

    return matrix;
}

/* Parse a LaTeX command starting with \ */
static int parse_command(LatexParseResult *r, const char *input, int len, int *pos, int parent) {
    if (*pos >= len || input[*pos] != '\\') return -1;
    (*pos)++; /* skip '\\' */

    if (*pos >= len) return -1;

    /* Single-char commands */
    char ch = input[*pos];
    if (!isalpha((unsigned char)ch)) {
        (*pos)++;
        /* \\ is row break (handled elsewhere), \, \; \! are spaces */
        if (ch == ',' || ch == ';' || ch == '!' || ch == ':') {
            int sp = alloc_node(r, LATEX_NODE_SPACE);
            if (sp < 0) return -1;
            const char *sp_text = (ch == ',') ? "\xe2\x80\x89" : /* thin space */
                                  (ch == ';') ? "\xe2\x80\x83" : /* em space */
                                  (ch == ':') ? "\xe2\x80\x82" : /* en space */
                                  "";
            if (sp_text[0]) {
                int slen = (int)strlen(sp_text);
                const char *pooled = pool_string(r, sp_text, slen);
                if (pooled) {
                    r->nodes[sp].text = pooled;
                    r->nodes[sp].text_len = slen;
                }
            }
            link_child(r, parent, sp);
            return sp;
        }
        /* \{ \} \| etc — literal characters */
        if (ch == '{' || ch == '}' || ch == '|' || ch == '\\' || ch == '%' || ch == '&' || ch == '#') {
            char buf[2] = {ch, '\0'};
            add_text_child(r, parent, buf, 1);
            return parent;
        }
        return -1;
    }

    /* Multi-char command: scan name */
    int cmd_start = *pos;
    while (*pos < len && isalpha((unsigned char)input[*pos])) (*pos)++;
    int cmd_len = *pos - cmd_start;
    const char *cmd = input + cmd_start;

    /* Handle specific structural commands */

    /* \frac{num}{den} */
    if (cmd_len == 4 && strncmp(cmd, "frac", 4) == 0) {
        int frac = alloc_node(r, LATEX_NODE_FRACTION);
        if (frac < 0) return -1;
        skip_ws(input, len, pos);
        int num = parse_group(r, input, len, pos);
        if (num >= 0) link_child(r, frac, num);
        skip_ws(input, len, pos);
        int den = parse_group(r, input, len, pos);
        if (den >= 0) link_child(r, frac, den);
        link_child(r, parent, frac);
        return frac;
    }

    /* \sqrt{…} */
    if (cmd_len == 4 && strncmp(cmd, "sqrt", 4) == 0) {
        int sq = alloc_node(r, LATEX_NODE_SQRT);
        if (sq < 0) return -1;
        skip_ws(input, len, pos);
        int child = parse_group(r, input, len, pos);
        if (child >= 0) link_child(r, sq, child);
        link_child(r, parent, sq);
        return sq;
    }

    /* \left and \right — delimiter markers */
    if ((cmd_len == 4 && strncmp(cmd, "left", 4) == 0) ||
        (cmd_len == 5 && strncmp(cmd, "right", 5) == 0)) {
        skip_ws(input, len, pos);
        int delim = alloc_node(r, LATEX_NODE_DELIMITER);
        if (delim < 0) return -1;
        if (*pos < len) {
            char d = input[*pos];
            (*pos)++;
            /* Map delimiter to display character */
            const char *dstr;
            char dbuf[2] = {d, '\0'};
            if (d == '(') dstr = "(";
            else if (d == ')') dstr = ")";
            else if (d == '[') dstr = "[";
            else if (d == ']') dstr = "]";
            else if (d == '|') dstr = "|";
            else if (d == '.') dstr = ""; /* invisible delimiter */
            else if (d == '\\') {
                /* \left\{ or \left\| */
                if (*pos < len) {
                    char d2 = input[*pos];
                    (*pos)++;
                    dbuf[0] = d2;
                    dstr = dbuf;
                } else {
                    dstr = "\\";
                }
            } else {
                dstr = dbuf;
            }
            int dlen = (int)strlen(dstr);
            if (dlen > 0) {
                const char *pooled = pool_string(r, dstr, dlen);
                if (pooled) {
                    r->nodes[delim].text = pooled;
                    r->nodes[delim].text_len = dlen;
                }
            }
        }
        link_child(r, parent, delim);
        return delim;
    }

    /* \begin{…} */
    if (cmd_len == 5 && strncmp(cmd, "begin", 5) == 0) {
        skip_ws(input, len, pos);
        if (*pos < len && input[*pos] == '{') {
            (*pos)++; /* skip '{' */
            int env = parse_environment(r, input, len, pos);
            if (env >= 0) link_child(r, parent, env);
            return env;
        }
        return -1;
    }

    /* \end{…} — should not be reached directly, but consume it */
    if (cmd_len == 3 && strncmp(cmd, "end", 3) == 0) {
        skip_ws(input, len, pos);
        if (*pos < len && input[*pos] == '{') {
            while (*pos < len && input[*pos] != '}') (*pos)++;
            if (*pos < len) (*pos)++;
        }
        return -1;
    }

    /* \operatorname{…} — render as upright text */
    if (cmd_len == 12 && strncmp(cmd, "operatorname", 12) == 0) {
        int op = alloc_node(r, LATEX_NODE_OPERATORNAME);
        if (op < 0) return -1;
        skip_ws(input, len, pos);
        if (*pos < len && input[*pos] == '{') {
            (*pos)++;
            int name_start = *pos;
            while (*pos < len && input[*pos] != '}') (*pos)++;
            int name_len2 = *pos - name_start;
            if (*pos < len) (*pos)++;
            const char *pooled = pool_string(r, input + name_start, name_len2);
            if (pooled) {
                r->nodes[op].text = pooled;
                r->nodes[op].text_len = name_len2;
            }
        }
        link_child(r, parent, op);
        return op;
    }

    /* \text{…}, \textbf{…}, \mathrm{…}, etc. — render content as text */
    if ((cmd_len == 4 && strncmp(cmd, "text", 4) == 0) ||
        (cmd_len == 6 && strncmp(cmd, "textbf", 6) == 0) ||
        (cmd_len == 6 && strncmp(cmd, "textit", 6) == 0) ||
        (cmd_len == 5 && strncmp(cmd, "mathr", 5) == 0) ||
        (cmd_len == 6 && strncmp(cmd, "mathrm", 6) == 0) ||
        (cmd_len == 6 && strncmp(cmd, "mathbf", 6) == 0) ||
        (cmd_len == 6 && strncmp(cmd, "mathit", 6) == 0) ||
        (cmd_len == 6 && strncmp(cmd, "mathbb", 6) == 0) ||
        (cmd_len == 7 && strncmp(cmd, "mathcal", 7) == 0)) {
        skip_ws(input, len, pos);
        int grp = parse_group(r, input, len, pos);
        if (grp >= 0) link_child(r, parent, grp);
        return grp;
    }

    /* \hat, \bar, \dot, \tilde, \vec — accent marks */
    if ((cmd_len == 3 && strncmp(cmd, "hat", 3) == 0) ||
        (cmd_len == 3 && strncmp(cmd, "bar", 3) == 0) ||
        (cmd_len == 3 && strncmp(cmd, "dot", 3) == 0) ||
        (cmd_len == 5 && strncmp(cmd, "tilde", 5) == 0) ||
        (cmd_len == 3 && strncmp(cmd, "vec", 3) == 0)) {
        int acc = alloc_node(r, LATEX_NODE_ACCENT);
        if (acc < 0) return -1;
        /* Map accent type to combining character */
        const char *accent_char;
        if (strncmp(cmd, "hat", 3) == 0 && cmd_len == 3)
            accent_char = "\xcc\x82"; /* combining circumflex U+0302 */
        else if (strncmp(cmd, "bar", 3) == 0 && cmd_len == 3)
            accent_char = "\xcc\x84"; /* combining macron U+0304 */
        else if (strncmp(cmd, "dot", 3) == 0 && cmd_len == 3)
            accent_char = "\xcc\x87"; /* combining dot above U+0307 */
        else if (strncmp(cmd, "tilde", 5) == 0 && cmd_len == 5)
            accent_char = "\xcc\x83"; /* combining tilde U+0303 */
        else
            accent_char = "\xe2\x83\x97"; /* combining right arrow U+20D7 */
        int alen = (int)strlen(accent_char);
        const char *pooled = pool_string(r, accent_char, alen);
        if (pooled) {
            r->nodes[acc].text = pooled;
            r->nodes[acc].text_len = alen;
        }
        skip_ws(input, len, pos);
        int child = parse_group(r, input, len, pos);
        if (child < 0) {
            /* Single character without braces */
            if (*pos < len) {
                char buf[2] = {input[*pos], '\0'};
                (*pos)++;
                child = alloc_node(r, LATEX_NODE_GROUP);
                if (child >= 0) add_text_child(r, child, buf, 1);
            }
        }
        if (child >= 0) link_child(r, acc, child);
        link_child(r, parent, acc);
        return acc;
    }

    /* Spacing commands: \quad, \qquad */
    if ((cmd_len == 4 && strncmp(cmd, "quad", 4) == 0) ||
        (cmd_len == 5 && strncmp(cmd, "qquad", 5) == 0)) {
        int sp = alloc_node(r, LATEX_NODE_SPACE);
        if (sp < 0) return -1;
        const char *sp_text = (cmd_len == 4) ? "\xe2\x80\x83" : "\xe2\x80\x83\xe2\x80\x83";
        int slen = (int)strlen(sp_text);
        const char *pooled = pool_string(r, sp_text, slen);
        if (pooled) {
            r->nodes[sp].text = pooled;
            r->nodes[sp].text_len = slen;
        }
        link_child(r, parent, sp);
        return sp;
    }

    /* \times as special case (common but needs to be caught before symbol lookup
     * in case there's a collision, but it's in the table) */

    /* Look up in symbol table */
    const char *sym = lookup_symbol(cmd, cmd_len);
    if (sym) {
        int slen = (int)strlen(sym);
        add_text_child(r, parent, sym, slen);
        return parent;
    }

    /* Unknown command — render as text with backslash */
    /* Allocate enough for backslash + name */
    {
        int total = cmd_len + 1;
        char *buf = (char *)malloc((size_t)total + 1);
        if (buf) {
            buf[0] = '\\';
            memcpy(buf + 1, cmd, (size_t)cmd_len);
            buf[total] = '\0';
            add_text_child(r, parent, buf, total);
            free(buf);
        }
    }
    return parent;
}

/* Parse a single atom (character, command, group, or sub/superscript) */
static int parse_atom(LatexParseResult *r, const char *input, int len, int *pos, int parent) {
    /* Note: whitespace is handled by parse_expr (emits SPACE nodes).
     * Do NOT call skip_ws here — it would drop spaces. */
    if (*pos >= len) return -1;

    char ch = input[*pos];

    /* Braced group */
    if (ch == '{') {
        int grp = parse_group(r, input, len, pos);
        if (grp >= 0) link_child(r, parent, grp);
        return grp;
    }

    /* Command */
    if (ch == '\\') {
        return parse_command(r, input, len, pos, parent);
    }

    /* Superscript */
    if (ch == '^') {
        (*pos)++;
        int sup = alloc_node(r, LATEX_NODE_SUPERSCRIPT);
        if (sup < 0) return -1;
        skip_ws(input, len, pos);
        if (*pos < len && input[*pos] == '{') {
            int child = parse_group(r, input, len, pos);
            if (child >= 0) link_child(r, sup, child);
        } else if (*pos < len) {
            /* Single char superscript */
            if (input[*pos] == '\\') {
                parse_command(r, input, len, pos, sup);
            } else {
                char buf[2] = {input[*pos], '\0'};
                (*pos)++;
                add_text_child(r, sup, buf, 1);
            }
        }
        link_child(r, parent, sup);
        return sup;
    }

    /* Subscript */
    if (ch == '_') {
        (*pos)++;
        int sub = alloc_node(r, LATEX_NODE_SUBSCRIPT);
        if (sub < 0) return -1;
        skip_ws(input, len, pos);
        if (*pos < len && input[*pos] == '{') {
            int child = parse_group(r, input, len, pos);
            if (child >= 0) link_child(r, sub, child);
        } else if (*pos < len) {
            if (input[*pos] == '\\') {
                parse_command(r, input, len, pos, sub);
            } else {
                char buf[2] = {input[*pos], '\0'};
                (*pos)++;
                add_text_child(r, sub, buf, 1);
            }
        }
        link_child(r, parent, sub);
        return sub;
    }

    /* End-of-group markers — don't consume */
    if (ch == '}' || ch == '&') {
        return -1;
    }

    /* Regular character */
    (*pos)++;
    /* Accumulate consecutive plain chars */
    int start = *pos - 1;
    while (*pos < len) {
        char c = input[*pos];
        if (c == '\\' || c == '{' || c == '}' || c == '^' || c == '_' ||
            c == '&' || c == ' ' || c == '\t' || c == '\n' || c == '\r')
            break;
        (*pos)++;
    }
    int text_len2 = *pos - start;
    add_text_child(r, parent, input + start, text_len2);
    return parent;
}

/* Emit whitespace as a SPACE node instead of silently discarding it.
 * Collapses multiple whitespace chars into a single space. */
static void emit_ws_if_present(LatexParseResult *r, const char *input, int len, int *pos, int parent) {
    if (*pos < len && (input[*pos] == ' ' || input[*pos] == '\t' ||
                       input[*pos] == '\n' || input[*pos] == '\r')) {
        skip_ws(input, len, pos);
        int sp = alloc_node(r, LATEX_NODE_SPACE);
        if (sp >= 0) {
            const char *sp_text = " ";
            const char *pooled = pool_string(r, sp_text, 1);
            if (pooled) {
                r->nodes[sp].text = pooled;
                r->nodes[sp].text_len = 1;
            }
            link_child(r, parent, sp);
        }
    }
}

/* Parse a sequence of atoms into the parent node.
 * If stop_at_brace is true, stop at '}' (used for group parsing). */
static int parse_expr(LatexParseResult *r, const char *input, int len, int *pos, int parent, int stop_at_brace) {
    /* Skip leading whitespace silently */
    skip_ws(input, len, pos);
    while (*pos < len) {
        if (stop_at_brace && input[*pos] == '}') break;
        if (input[*pos] == '&') break; /* cell separator in matrix */

        /* Check for \\ (row separator) — stop parsing this group */
        if (input[*pos] == '\\' && *pos + 1 < len && input[*pos + 1] == '\\') break;
        /* Check for \end — stop parsing this group */
        if (input[*pos] == '\\' && *pos + 4 <= len && strncmp(input + *pos, "\\end", 4) == 0) break;

        int before = r->count;
        parse_atom(r, input, len, pos, parent);
        /* Prevent infinite loops: if no progress was made, skip the character */
        if (r->count == before && *pos < len) {
            (*pos)++;
        }

        /* Emit inter-token whitespace as SPACE nodes */
        emit_ws_if_present(r, input, len, pos, parent);
    }
    return parent;
}

/* ====================================================================
 * Public API
 * ==================================================================== */

LatexParseResult *latex_render_parse(const char *input, int length) {
    if (!input || length <= 0) {
        /* Return an empty result */
        LatexParseResult *r = (LatexParseResult *)calloc(1, sizeof(LatexParseResult));
        if (!r) return NULL;
        int root = alloc_node(r, LATEX_NODE_ROOT);
        (void)root;
        return r;
    }

    LatexParseResult *r = (LatexParseResult *)calloc(1, sizeof(LatexParseResult));
    if (!r) return NULL;

    int root = alloc_node(r, LATEX_NODE_ROOT);
    if (root < 0) {
        free(r);
        return NULL;
    }

    int pos = 0;
    parse_expr(r, input, length, &pos, root, 0);

    return r;
}

void latex_render_free(LatexParseResult *result) {
    if (!result) return;
    free(result->nodes);
    free(result->string_pool);
    free(result);
}
