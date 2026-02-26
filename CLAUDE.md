# Selkie — Claude Code Project Guide

## Project Overview

Selkie is a Zig-based GUI markdown viewer with GFM support, native Mermaid chart rendering, and theming.

**Tech Stack:**
- Zig 0.14.1 (stable)
- raylib-zig v5.5 (OpenGL-based GUI rendering)
- cmark-gfm (vendored C library for GFM markdown parsing)
- Native Zig Mermaid renderer

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

## Build & Run

```bash
zig build              # Build
zig build run -- file.md   # Run with a markdown file
zig build test         # Run tests
```

## Architecture

```
file.md → cmark-gfm parser → Zig AST
  → mermaid detector (code blocks → diagram models)
  → document_layout (AST + theme → positioned LayoutTree)
  → renderer (LayoutTree → raylib draw calls @ 60fps)
  → viewport (culling, scrolling, input)
```

## Key Directories
- `src/parser/` — cmark-gfm integration, AST types
- `src/mermaid/` — Mermaid parsers, models, layout algorithms, renderers
- `src/layout/` — Document layout engine (AST → positioned elements)
- `src/render/` — raylib drawing code
- `src/viewport/` — Scrolling, input, visible region management
- `src/theme/` — Theme definitions and JSON loader
- `deps/cmark-gfm/` — Vendored cmark-gfm C source
- `assets/` — Fonts and theme JSON files
