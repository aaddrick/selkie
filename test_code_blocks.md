# Code Block Test

## Zig Code

```zig
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var list = std.ArrayList(u32).init(allocator);
    defer list.deinit();

    // Add some numbers
    try list.append(42);
    try list.append(100);

    const sum: u32 = 0;
    for (list.items) |item| {
        _ = item;
    }
    std.debug.print("Count: {d}\n", .{list.items.len});
}
```

## Python Code

```python
def fibonacci(n):
    """Calculate the nth Fibonacci number."""
    if n <= 1:
        return n
    a, b = 0, 1
    for _ in range(2, n + 1):
        a, b = b, a + b
    return b

# Print first 10 Fibonacci numbers
result = [fibonacci(i) for i in range(10)]
print(f"Fibonacci: {result}")
```

## JavaScript

```javascript
async function fetchData(url) {
    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(`HTTP error: ${response.status}`);
    }
    return response.json();
}

// Usage
const data = await fetchData("https://api.example.com/data");
console.log(data);
```

## Rust

```rust
fn main() {
    let numbers: Vec<i32> = (1..=10).collect();
    let sum: i32 = numbers.iter().sum();
    println!("Sum: {}", sum);

    // Pattern matching
    match sum {
        0 => println!("Zero"),
        1..=50 => println!("Small"),
        _ => println!("Large"),
    }
}
```

## JSON (no line comments)

```json
{
    "name": "selkie",
    "version": "0.1.0",
    "dependencies": {
        "raylib": "5.5",
        "cmark-gfm": true
    },
    "count": 42
}
```

## Shell

```bash
#!/bin/bash
# Deploy script
export ENV="production"

if [ -f ".env" ]; then
    source .env
    echo "Loaded environment"
fi

for file in *.md; do
    echo "Processing: $file"
done
```

## Plain code (no language)

```
This is a plain code block
with no syntax highlighting.
Just monospace text with line numbers.
```

## SQL

```sql
SELECT u.name, COUNT(o.id) AS order_count
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
WHERE u.created_at > '2024-01-01'
GROUP BY u.name
HAVING COUNT(o.id) > 5
ORDER BY order_count DESC
LIMIT 10;
```
