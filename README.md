<p align="center">
  <img src="assets/images/selkie_banner_readme.png" alt="Selkie — From raw markdown to elegant forms" width="600">
</p>

# Selkie

A Zig-based markdown viewer with GFM support, native Mermaid chart rendering, and theming.

## Features

- **GFM Markdown** — Full GitHub Flavored Markdown support (tables, task lists, strikethrough, autolinks)
- **Mermaid Charts** — Native rendering of Mermaid diagram syntax
- **Theming** — Customizable themes for the viewer

## Building

```bash
zig build                                # Debug build
zig build -Doptimize=ReleaseSafe         # Optimized + stripped binary
```

## Usage

```bash
zig build run -- <file.md>
```
