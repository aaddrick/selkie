# Selkie — Claude Code Project Guide

> **IMPORTANT:** Read [CONTRIBUTORS.md](CONTRIBUTORS.md) first to understand who built this project and how.

## Project Overview

Selkie is a Zig-based GUI markdown viewer with GFM support, native Mermaid chart rendering, and theming.

**Tech Stack:**
- Zig 0.14.1 (stable)
- raylib-zig v5.5 (OpenGL-based GUI rendering)
- cmark-gfm (vendored C library for GFM markdown parsing)
- Native Zig Mermaid renderer

## Build & Run

```bash
zig build                        # Debug build
zig build -Doptimize=ReleaseSafe # Release build
zig build run -- file.md         # Run with a markdown file
zig build test                   # Run tests
```

## Architecture

```
file.md → cmark-gfm parser → Zig AST
  → mermaid detector (code blocks → diagram models)
  → document_layout (AST + theme → positioned LayoutTree)
  → renderer (LayoutTree → raylib draw calls @ 60fps)
  → viewport (culling, scrolling, input)
```

## Key Files

| File | Role |
|------|------|
| `src/main.zig` | Entry point: CLI parsing, window init, resource setup with `defer`/`errdefer` chains |
| `src/app.zig` | App state: theme, tabs, viewport, UI orchestration |
| `src/tab.zig` | Per-file state: document, layout, scroll, editor |
| `src/parser/markdown_parser.zig` | cmark-gfm C FFI wrapper |
| `src/layout/document_layout.zig` | AST + theme → positioned LayoutTree |
| `src/render/renderer.zig` | Main drawing dispatcher (viewport-aware culling) |
| `src/theme/theme_loader.zig` | JSON theme parsing and color conversion |
| `src/theme/defaults.zig` | Built-in light/dark theme constants |
| `src/mermaid/detector.zig` | Identifies Mermaid code blocks in AST |
| `src/xdg.zig` | XDG Base Directory resolution with fallback chain |
| `src/asset_paths.zig` | Runtime font/theme discovery (install vs dev paths) |
| `build.zig` | Build system: cmark-gfm static lib, raylib linking, FHS install |
| `build.zig.zon` | Package manifest (version, dependencies) |

## Key Directories

| Directory | Purpose |
|-----------|---------|
| `src/parser/` | cmark-gfm integration, AST types |
| `src/mermaid/` | Mermaid parsers, models, layout algorithms, renderers |
| `src/mermaid/models/` | Data structures per diagram type (11 types) |
| `src/mermaid/parsers/` | Diagram syntax parsers |
| `src/mermaid/renderers/` | Diagram drawing code |
| `src/mermaid/layout/` | Diagram layout algorithms (dagre, linear, tree) |
| `src/layout/` | Document layout engine (AST → positioned elements) |
| `src/render/` | raylib drawing code |
| `src/viewport/` | Scrolling, input, visible region management |
| `src/theme/` | Theme definitions and JSON loader |
| `src/search/` | Document search functionality |
| `src/editor/` | In-app markdown editor state |
| `src/export/` | PDF export (writer, TTF parser, save dialog) |
| `src/command/` | Command palette state |
| `src/utils/` | Utilities (text, slices) |
| `deps/cmark-gfm/` | Vendored cmark-gfm C source |
| `assets/` | Fonts (Inter, JetBrains Mono) and theme JSON files |
| `data/` | Desktop entry, AppStream metainfo, man page, icons |
| `packaging/` | Build scripts for deb, rpm, AppImage; AUR PKGBUILD |
| `.github/workflows/` | CI/CD: test, build, release, cleanup |
| `docs/` | Install and build instructions |

## Project Patterns

### Memory Management
- Every struct storing dynamic data takes an `Allocator` and implements `deinit()`
- `deinit()` recursively frees child resources
- `defer deinit()` paired with every allocation in `main.zig`
- Optional fields guarded: `if (field) |f| f.deinit()`
- `GeneralPurposeAllocator` used — reports leaks on exit in debug builds

### Error Handling
- Error unions with `catch |err| switch` for granular handling
- Named error sets defined at module top (`ParseError`, `ThemeLoadError`, etc.)
- `try` for propagation, explicit `switch` when recovery logic varies
- `errdefer` paired immediately after fallible allocations for rollback

### Initialization
- `init()` functions are infallible — return struct by value
- Fallible setup (fonts, themes, files) called separately after `init()`
- Resource lifetimes = struct lifetimes

### Testing
- Tests live in `test { }` blocks within their implementation module
- Root `main.zig` imports all modules at comptime for test discovery
- `testing.allocator` from std used in tests (detects leaks)
- No separate test files — tests colocate with implementation

### Version Sync
Four files must stay in sync when version changes:
1. `build.zig` — `const version = "0.1.0"` (line 5, has sync comment)
2. `build.zig.zon` — `.version = "0.1.0"`
3. `data/selkie.1` — man page header
4. `data/io.github.aaddrick.selkie.metainfo.xml` — release element

### Ownership Documentation
- Comments above fields document ownership: "Owned", "Borrowed", "External"
- Pointer vs value indicates ownership intent
- `base_theme: *const Theme` points to defaults or owned `custom_theme`
- `active_theme: Theme` is a derived copy with zoom scaling applied

## Anti-Patterns to Avoid

- **Allocating in `init()`** — keep init infallible; separate setup functions for fallible ops
- **Missing `errdefer`** — always pair cleanup immediately after fallible allocation
- **Implicit ownership** — every pointer/slice must have ownership documented
- **Unguarded optional deinit** — always `if (field) |f| f.deinit()`, never assume non-null
- **Tests in separate files** — tests belong in `test { }` blocks in the implementation module
- **Unsynced version strings** — update all four version locations together
- **Mixing error styles** — use `try` + error union consistently, not ad-hoc checks
- **`set -e` in CI shell scripts** — handle errors explicitly; `set -e` is unpredictable with pipes/conditionals (use `set -euo pipefail` only in packaging scripts)
- **GPG without `--batch`** — CI has no TTY; always use `--batch --yes` flags
- **Missing `if-no-files-found: error`** — always set on `upload-artifact` steps

## Available Agents

| Agent | Purpose | When to Use |
|-------|---------|-------------|
| `zig-developer` | Senior Zig developer for Selkie | Implementing features, fixing bugs, refactoring, build system, C FFI, memory management |
| `zig-code-reviewer` | Opinionated Zig code reviewer | After implementation — catches anti-patterns, naming violations, safety issues |
| `zig-code-simplifier` | Simplifies and refines Zig code | After implementation or phase completion — improves clarity without changing behavior |
| `zig-test-validator` | Validates test comprehensiveness | After code review — audits for hollow assertions, TODO placeholders, missing leak detection |
| `technical-doc-writer` | Architecture documentation writer | Creating design docs, data flow docs in `docs/` with Mermaid diagrams |
| `aaddrick-voice` | Voice replication for writing | Generating text matching aaddrick's documented writing style |

## Available Skills

| Skill | Trigger | Purpose |
|-------|---------|---------|
| `/implement-issue` | After plan approval | Full pipeline: implement → simplify → review → validate → commit |
| `/test-driven-development` | Any feature/bugfix | Write tests first, then implementation |
| `/using-git-worktrees` | Branch isolation needed | Create isolated workspace in `.worktrees/` |
| `/improvement-loop` | After resolving issues | Improve pipeline files (agents, skills, hooks) |
| `/writing-agents` | Defining new agents | Create agent definitions with TDD |
| `/writing-skills` | Defining new skills | Create skill definitions with TDD |

## Issue Tracking

All work is tracked via GitHub Issues on the `aaddrick/selkie` repository.

### Structure
- **Epic (#1)** — Master tracker linking all phase issues. Its checklist tracks phase completion.
- **Phase issues (#2–#11)** — Each phase is a milestone with a detailed task checklist.
- Each phase issue contains checkboxes for individual files/features to implement.

### Phase Execution Workflow

**Starting a phase:**
1. Comment on the phase issue: `🚧 Starting work on this phase`
2. Work through tasks in the order listed in the issue checklist
3. Commit code after each logical unit of work (not every file, but each working increment)

**During a phase:**
4. After completing a group of related tasks, comment on the issue with what was done:
   `✅ Completed: <brief description>` (e.g., "Completed: build system — cmark-gfm compiles as static lib, raylib linked")
5. Check off completed items in the issue body checklist using `gh issue edit`
6. Comments should be made at **meaningful milestones** — not every file, but when:
   - A subsystem compiles/works for the first time
   - A group of related tasks is done (e.g., "all parser files created")
   - The build succeeds after a major integration step
   - A visual milestone is reached (e.g., "text renders in window")

**Blockers and design decisions:**
7. If a planned approach doesn't work, comment before changing course:
   `⚠️ Blocker: <what failed>. Switching to: <new approach>`
8. If a design decision deviates from the issue spec, comment explaining why:
   `⚠️ Design change: <what changed and why>`

**Completing a phase:**
9. Verify the phase milestone (described at bottom of each issue) is met
10. Comment: `🎉 Phase complete. Summary: <what was built, any deviations from plan>`
11. Close the phase issue
12. Check off the phase in Epic #1's checklist

### Recovery and Session Continuity

When resuming work after a context reset or new session:
1. Read `CLAUDE.md` (this file) for project conventions
2. Run `gh issue list --repo aaddrick/selkie --state open` to see current phase
3. Read the open phase issue to see which tasks are checked off vs remaining
4. Read recent comments on the issue for context on where work left off
5. Check `git log --oneline -10` to see recent commits
6. Resume from the first unchecked task in the issue
7. Comment on the issue: `🚧 Resuming work — picking up from: <first unchecked task>`

### Error Recovery

If `zig build` breaks during development:
1. Check the last known-good commit: `git log --oneline -5`
2. Identify what changed since then: `git diff HEAD~1`
3. Fix the issue rather than reverting (unless the approach is fundamentally wrong)
4. If reverting is necessary, comment on the issue explaining what was reverted and why

If a phase dependency turns out to be wrong (e.g., a library doesn't work as expected):
1. Comment on the phase issue documenting the problem
2. Research alternatives
3. Comment with the chosen alternative and reasoning before implementing
4. Update the issue description if the task list needs to change
