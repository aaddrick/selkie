# Welcome to Selkie

Selkie is a **Zig-based** markdown viewer with *native* rendering.

## Inline Formatting

This paragraph has **bold text**, *italic text*, ***bold and italic text***, ~~strikethrough text~~, and `inline code` all in one place.

Here is a [link](https://example.com) and some more `code snippets` with **bold** and *italic* nearby.

## Lists

### Unordered Lists

- First item
- Second item
  - Nested item A
  - Nested item B
    - Deeply nested item
    - Another deep item
  - Back to second level
- Third item

### Ordered Lists

1. First step
2. Second step
3. Third step

### Mixed Nesting

- Bullet item
  1. Ordered sub-item one
  2. Ordered sub-item two
- Another bullet
  - Sub-bullet
    - Deep sub-bullet

## Block Elements

> This is a blockquote. It should have a colored left border
> and indented content.

> Nested blockquotes:
> > This is a nested blockquote inside another blockquote.

---

## Code Example

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello, Selkie!\n", .{});
}
```

### Heading Levels

# Heading 1
## Heading 2
### Heading 3
#### Heading 4
##### Heading 5
###### Heading 6

---

That's all for now. Press **T** to toggle dark mode!
