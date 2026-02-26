# Welcome to Selkie

Selkie is a **Zig-based** markdown viewer with *native* rendering.

## Features

- GFM markdown support
- Native Mermaid chart rendering
- Customizable **themes**

### Getting Started

This is a paragraph with `inline code` and a [link](https://example.com).

Here is some more text to test word wrapping. This paragraph should be long enough to wrap to the next line when rendered in the viewer window with the default content width settings applied.

---

> This is a blockquote. It should have a colored left border
> and indented content.

## Code Example

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello, Selkie!\n", .{});
}
```

### Another Section

1. First item
2. Second item
3. Third item

That's all for now. Press **T** to toggle dark mode!
