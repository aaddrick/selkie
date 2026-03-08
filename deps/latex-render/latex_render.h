/*
 * latex_render.h — Lightweight LaTeX math parser for rendering
 *
 * Parses LaTeX math strings into a flat array of structured nodes suitable
 * for rendering via a 2D graphics library. Handles:
 *   - Greek letters (\alpha, \beta, …)
 *   - Math operators and symbols (\int, \sum, \pm, \infty, …)
 *   - Superscripts (^) and subscripts (_)
 *   - Fractions (\frac{num}{den})
 *   - Square roots (\sqrt{…})
 *   - Grouping with braces ({…})
 *   - Array/matrix environments (\begin{array}…\end{array})
 *   - Delimiters (\left, \right)
 *   - Spacing commands (\quad, \,, \;, etc.)
 *
 * The output is a flat array of LatexNode structs with child/sibling indices,
 * designed for efficient FFI consumption from Zig.
 */

#ifndef LATEX_RENDER_H
#define LATEX_RENDER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    LATEX_NODE_ROOT       = 0,   /* Top-level container */
    LATEX_NODE_TEXT       = 1,   /* Plain text/symbol (UTF-8 in `text`) */
    LATEX_NODE_FRACTION   = 2,   /* \frac — children[0]=numerator, children[1]=denominator */
    LATEX_NODE_SUPERSCRIPT= 3,   /* ^{…} — child is the superscript content */
    LATEX_NODE_SUBSCRIPT  = 4,   /* _{…} — child is the subscript content */
    LATEX_NODE_SQRT       = 5,   /* \sqrt{…} — child is the radicand */
    LATEX_NODE_GROUP      = 6,   /* {…} grouping, or implicit row */
    LATEX_NODE_SPACE      = 7,   /* spacing: text holds width hint as string */
    LATEX_NODE_DELIMITER  = 8,   /* \left( \right) etc. — text holds the delimiter char */
    LATEX_NODE_MATRIX     = 9,   /* \begin{array}…\end{array} — rows as children */
    LATEX_NODE_MATRIX_ROW = 10,  /* single row — cells as children */
    LATEX_NODE_MATRIX_CELL= 11,  /* single cell — content as children */
    LATEX_NODE_ACCENT     = 12,  /* \hat, \bar, etc. — text holds accent char, child is base */
    LATEX_NODE_OPERATORNAME = 13, /* \operatorname{…} — text holds the name */
} LatexNodeType;

typedef struct {
    int type;           /* LatexNodeType */
    const char *text;   /* UTF-8 string for TEXT/SPACE/DELIMITER/ACCENT nodes (borrowed from result pool) */
    int text_len;       /* Length of text in bytes */
    int first_child;    /* Index of first child node (-1 = none) */
    int next_sibling;   /* Index of next sibling node (-1 = none) */
} LatexNode;

typedef struct {
    LatexNode *nodes;   /* Array of nodes (owned) */
    int count;          /* Number of nodes */
    int capacity;       /* Allocated capacity */
    char *string_pool;  /* Pool for all text strings (owned) */
    int pool_used;      /* Bytes used in string pool */
    int pool_capacity;  /* Allocated pool capacity */
} LatexParseResult;

/* Parse a LaTeX math string. Returns NULL on allocation failure.
 * The caller must free the result with latex_render_free(). */
LatexParseResult *latex_render_parse(const char *input, int length);

/* Free all memory associated with a parse result. */
void latex_render_free(LatexParseResult *result);

#ifdef __cplusplus
}
#endif

#endif /* LATEX_RENDER_H */
