---
name: using-git-worktrees
description: Use when starting feature work that needs isolation from current workspace or before executing implementation plans - creates isolated git worktrees in .worktrees/
---

# Using Git Worktrees

## Overview

Git worktrees create isolated workspaces sharing the same repository, allowing work on multiple branches simultaneously without switching.

**Location:** Always use `.worktrees/` (per CLAUDE.md)

**Announce at start:** "I'm using the using-git-worktrees skill to set up an isolated workspace."

## Safety Verification

**Verify `.worktrees/` is ignored before creating worktree:**

```bash
git check-ignore -q .worktrees 2>/dev/null
```

**If NOT ignored:** Add to .gitignore and commit before proceeding.

**Why critical:** Prevents accidentally committing worktree contents to repository.

## Creation Steps

### 1. Create Worktree

```bash
git worktree add .worktrees/$BRANCH_NAME -b $BRANCH_NAME $BASE_BRANCH
cd .worktrees/$BRANCH_NAME
```

### 2. Run Project Setup

**Selkie (Zig project):**

Fresh worktrees have the full source but need to verify the build and dependencies:

```bash
# 1. Verify zig is available and correct version
zig version  # Should be 0.14.1

# 2. Build the project (fetches raylib-zig dependency, compiles cmark-gfm)
zig build

# 3. Verify tests pass
zig build test
```

**Why this order matters:**
- `zig build` fetches the raylib-zig dependency from the zon manifest
- cmark-gfm is vendored in `deps/` so it's always available
- Font/theme assets are tracked in git, so they exist in worktrees automatically

**Other projects:** Auto-detect from project files:
```bash
if [ -f build.zig ]; then zig build; fi
if [ -f package.json ]; then npm install; fi
if [ -f Cargo.toml ]; then cargo build; fi
if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
if [ -f go.mod ]; then go mod download; fi
```

### 3. Verify Baseline

Run tests to ensure worktree starts clean:
```bash
zig build test
```

**If tests fail:** Compare with main worktree to identify if failures are pre-existing. Check that `zig version` matches expected (0.14.1).

**If tests pass:** Report ready.

### 4. Report Location

```
Worktree ready at <full-path>
Branch: <branch-name>
Tests: All passed (or N pre-existing failures if any)
Ready to implement <feature-name>
```

## Quick Reference

| Situation | Action |
|-----------|--------|
| Creating worktree | `git worktree add .worktrees/$BRANCH -b $BRANCH $BASE` |
| `.worktrees/` not ignored | Add to .gitignore + commit first |
| Selkie project | `zig build && zig build test` |
| Other projects | Auto-detect from build.zig, package.json, Cargo.toml, etc. |
| Tests fail during baseline | Compare with main, verify zig version |

## Common Mistakes

### Skipping ignore verification

- **Problem:** Worktree contents get tracked, pollute git status
- **Fix:** Always use `git check-ignore` before creating worktree

### Skipping `zig build` before `zig build test`

- **Problem:** First build fetches dependencies; tests may fail without them
- **Fix:** Always run `zig build` first to ensure dependencies are fetched

### Wrong Zig version

- **Problem:** Selkie targets Zig 0.14.1; other versions may have breaking changes
- **Fix:** Verify `zig version` matches before building

### Hardcoding setup commands

- **Problem:** Breaks on projects using different tools
- **Fix:** Use documented sequence for Selkie, auto-detect for others

## Example Workflow

```
You: I'm using the using-git-worktrees skill to set up an isolated workspace.

[Verify ignored: git check-ignore .worktrees - confirmed]
[Create worktree: git worktree add .worktrees/issue-12 -b issue-12-file-watcher main]
[cd .worktrees/issue-12]
[zig version - 0.14.1 confirmed]
[zig build - success]
[zig build test - all tests passed]

Worktree ready at /home/user/source/selkie/.worktrees/issue-12
Branch: issue-12-file-watcher
Tests: All passed
Ready to implement file watcher feature
```

## Red Flags

**Never:**
- Create worktree without verifying `.worktrees/` is ignored
- Skip `zig build` in a fresh worktree
- Assume Zig version matches without checking

**Always:**
- Use `.worktrees/` directory
- Verify directory is ignored
- Run `zig build && zig build test` for baseline verification

## Integration

**Called by:**
- Implementation planning workflows — when design is approved
- Feature isolation — for independent feature work

**Pairs with:**
- Branch cleanup — after work is merged
- Phase-based development — per CLAUDE.md workflow
