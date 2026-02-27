# Testing Anti-Patterns

**Load this reference when:** writing or changing tests, creating test helpers, or tempted to add test-only methods to production code.

## Overview

Tests must verify real behavior, not test infrastructure behavior. Test helpers exist to simplify setup, not to become the thing being tested.

**Core principle:** Test what the code does, not what the test setup does.

**Following strict TDD prevents these anti-patterns.**

## The Iron Laws

```
1. NEVER test helper behavior instead of real behavior
2. NEVER add test-only methods to production structs
3. NEVER skip testing with the real allocator
```

## Anti-Pattern 1: Testing Setup Instead of Behavior

**The violation:**
```zig
// BAD: Testing that test setup works, not real behavior
test "parser initializes" {
    const allocator = std.testing.allocator;
    var parser = try MarkdownParser.init(allocator);
    defer parser.deinit();
    try std.testing.expect(parser.root != null);  // Just testing init works
}
```

**Why this is wrong:**
- You're verifying the setup, not the parsing behavior
- Test passes when init works but tells you nothing about parsing
- No insight into whether the parser handles real input correctly

**The fix:**
```zig
// GOOD: Test actual parsing behavior
test "parser handles empty input as empty document" {
    const allocator = std.testing.allocator;
    var parser = try MarkdownParser.init(allocator);
    defer parser.deinit();

    const doc = try parser.parse("");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.children.items.len);
}
```

### Gate Function

```
BEFORE writing any test assertion:
  Ask: "Am I testing real behavior or just setup/initialization?"

  IF testing setup:
    STOP - Add a meaningful behavior assertion instead

  Test what the code DOES, not that it EXISTS
```

## Anti-Pattern 2: Test-Only Methods in Production

**The violation:**
```zig
// BAD: reset() only used in tests
pub const LayoutTree = struct {
    nodes: std.ArrayList(LayoutNode),

    pub fn reset(self: *LayoutTree) void {  // Only tests call this!
        self.nodes.clearRetainingCapacity();
    }
};
```

**Why this is wrong:**
- Production struct polluted with test-only code
- Confuses API — users don't know which methods are "real"
- Dangerous if accidentally called in production path

**The fix:**
```zig
// GOOD: Test cleanup handled in test code
test "layout tree rebuilds on content change" {
    const allocator = std.testing.allocator;
    var tree = LayoutTree.init(allocator);
    defer tree.deinit();

    // First layout
    try tree.layoutDocument(doc1);
    try std.testing.expect(tree.nodes.items.len > 0);

    // Create fresh tree for second test — don't reuse
    var tree2 = LayoutTree.init(allocator);
    defer tree2.deinit();
    try tree2.layoutDocument(doc2);
}
```

### Gate Function

```
BEFORE adding any method to production struct:
  Ask: "Is this only used by tests?"

  IF yes:
    STOP - Don't add it
    Handle cleanup/setup in test code instead

  Ask: "Does this struct own this resource's lifecycle?"

  IF no:
    STOP - Wrong struct for this method
```

## Anti-Pattern 3: Skipping the Testing Allocator

**The violation:**
```zig
// BAD: Using page_allocator hides memory leaks
test "parse markdown document" {
    const allocator = std.heap.page_allocator;  // Won't detect leaks!
    const doc = try MarkdownParser.parse(allocator, content);
    // If we forget to free, test still passes
}
```

**Why this is wrong:**
- `std.testing.allocator` detects memory leaks automatically
- `page_allocator` silently ignores missing frees
- You lose Zig's best testing feature for memory safety

**The fix:**
```zig
// GOOD: testing.allocator catches leaks
test "parse markdown document" {
    const allocator = std.testing.allocator;  // Will fail if anything leaks
    const doc = try MarkdownParser.parse(allocator, content);
    defer doc.deinit();  // Must free or test fails

    try std.testing.expectEqual(@as(usize, 5), doc.children.items.len);
}
```

### Gate Function

```
BEFORE choosing an allocator in tests:
  ALWAYS use std.testing.allocator

  Exceptions (rare):
    - Testing allocator behavior itself
    - Benchmarks requiring specific allocator characteristics

  If you think you need page_allocator in a test:
    STOP - You probably have a leak you need to fix
```

## Anti-Pattern 4: Overly Broad Test Scope

**The violation:**
```zig
// BAD: Tests everything in one go — hard to diagnose failures
test "full rendering pipeline works" {
    const doc = try parser.parse(allocator, markdown_content);
    const layout = try document_layout.layout(allocator, doc, theme);
    const rendered = try renderer.render(layout, viewport);
    try std.testing.expect(rendered);
}
```

**Why this is wrong:**
- When this fails, which stage broke?
- Tests parser + layout + renderer in one assertion
- Can't isolate regressions

**The fix:**
```zig
// GOOD: Test each stage independently
test "parser produces correct AST for heading" {
    const doc = try parser.parse(allocator, "# Hello");
    try std.testing.expectEqual(ast.NodeType.heading, doc.children.items[0].node_type);
}

test "layout positions heading with theme font size" {
    const node = createHeadingNode("Hello");
    const layout_node = try document_layout.layoutNode(allocator, node, theme);
    try std.testing.expect(layout_node.rect.height > 0);
}
```

### Gate Function

```
BEFORE writing a test that touches multiple subsystems:
  Ask: "Can I test each stage independently?"

  IF yes:
    Write separate tests for each stage
    Integration test only for the glue between them

  IF no:
    Document WHY integration is necessary in the test name
```

## Anti-Pattern 5: Testing Without Cleanup

**The violation:**
```zig
// BAD: Leaks resources, breaks subsequent tests
test "load theme from file" {
    const theme = try theme_loader.loadFromFile(allocator, "assets/themes/light.json");
    try std.testing.expectEqualStrings("Selkie Light", theme.name);
    // Forgot defer theme.deinit() — leaked!
}
```

**Why this is wrong:**
- Memory leaks compound across tests
- `std.testing.allocator` will catch this, but only at test end
- Resource handles (file descriptors, etc.) may exhaust

**The fix:**
```zig
// GOOD: Always defer cleanup immediately after creation
test "load theme from file" {
    const theme = try theme_loader.loadFromFile(allocator, "assets/themes/light.json");
    defer theme.deinit();

    try std.testing.expectEqualStrings("Selkie Light", theme.name);
}
```

## Zig-Specific Testing Tips

### Use `errdefer` in production, `defer` in tests
- Production code: `errdefer` for cleanup on error paths
- Test code: `defer` immediately after every allocation

### Leverage comptime for test data
```zig
test "parse known diagram types" {
    const cases = .{
        .{ "graph LR", .flowchart },
        .{ "sequenceDiagram", .sequence },
        .{ "pie", .pie },
    };
    inline for (cases) |case| {
        const result = try detector.detect(allocator, case[0]);
        try std.testing.expectEqual(case[1], result.?);
    }
}
```

### Test error conditions explicitly
```zig
test "parser rejects invalid input" {
    const result = parser.parse(allocator, null);
    try std.testing.expectError(error.ParseFailed, result);
}
```

## Quick Reference

| Anti-Pattern | Fix |
|--------------|-----|
| Assert on setup/init | Test actual behavior output |
| Test-only methods in production | Handle in test code |
| Using page_allocator in tests | Always use testing.allocator |
| Overly broad test scope | Test each stage independently |
| Missing cleanup | Defer deinit immediately after creation |

## Red Flags

- Tests that only check `!= null` or `> 0`
- Methods on structs only called from test files
- `std.heap.page_allocator` in any test
- Single test covering parser → layout → render pipeline
- No `defer *.deinit()` after allocation in tests
- Test passes but `zig build test` shows leak warnings

## The Bottom Line

**Tests verify real behavior of real code.**

If TDD reveals you're testing infrastructure, you've gone wrong.

Fix: Test what the code does for real inputs and verify real outputs.
