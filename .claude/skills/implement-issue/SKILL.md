---
name: implement-issue
description: Use when the user says "implement" after approving a plan, or asks to go from plan to commit. Orchestrates the full pipeline from approved plan through implementation, simplification, code review, test validation, and pushed commit. All feedback levels are addressed — nothing is deferred.
---

# Implement Issue

## Overview

Execute an approved implementation plan through a quality pipeline that produces a pushed commit. Every stage must complete before advancing. All feedback — critical, warning, and nit — is fixed in every pass.

**Core principle:** No feedback is deferred. Nits are not optional. The pipeline runs to completion or the commit does not happen.

## When to Use

- User approved a plan (from plan mode or conversation) and says "implement", "go", "do it"
- User asks to go from issue/plan to pushed commit
- User references this skill by name

**Not for:** Exploration, research, documentation-only tasks, single-line fixes

## Pipeline

```
Plan → Tasks → Implement → Build
  → Simplify → Review → Fix ALL → Build
  → Validate Tests → Fix ALL → Build
  → Re-validate → Commit → Push
```

**STRICT ORDERING:** Simplifier before reviewer. Reviewer before validator. Never parallel.

## Execution

### 1. Create Task List

Extract implementation steps from the approved plan. Use `TaskCreate` for each logical unit. Work through tasks in order, marking `in_progress` → `completed`.

### 2. Implement

Dispatch `zig-developer` subagent for implementation work, or implement directly if straightforward. After each major step:

```bash
zig build && zig build test
```

**If build fails:** Fix before continuing. Do not accumulate broken state.

### 3. Simplify

Run `zig-code-simplifier` over all changed files. This runs FIRST because the reviewer should see clean code.

```bash
zig build && zig build test  # after simplifier changes
```

### 4. Code Review

Run `zig-code-reviewer` over all changed files. **In series after simplifier — never parallel.**

### 5. Fix ALL Review Feedback

Fix every finding at every severity level:

| Severity | Action |
|----------|--------|
| CRITICAL | Fix immediately — blocks merge |
| WARNING | Fix immediately — do not defer |
| NIT | Fix immediately — do not defer |

**"Minor" is not "optional."** Nits become tech debt. Fix them now.

After fixing:
```bash
zig build && zig build test
```

If the reviewer verdict was `REQUEST_CHANGES`, re-run `zig-code-reviewer` to confirm all issues are resolved. Repeat until `APPROVE`.

### 6. Test Validation

Run `zig-test-validator` over all changed/new test files.

### 7. Fix ALL Validator Findings

Same rule: fix everything. Remove tautological tests. Add missing coverage. No hollow assertions.

```bash
zig build && zig build test
```

### 8. Re-validate

Re-run `zig-test-validator`. If it still reports issues, fix and re-run. **Loop until PASS.**

### 9. Commit and Push

Stage specific files (not `git add -A`). Commit message format:

```
<summary referencing issue number> (#N)

<body explaining what was built and any deviations>
```

Push to origin.

## Red Flags — STOP

- About to skip a nit? **Stop.** Fix it.
- About to run reviewer and simplifier in parallel? **Stop.** Series only.
- About to commit without re-running validator after fixes? **Stop.** Re-run.
- Build is broken and you want to keep going? **Stop.** Fix first.
- Reviewer said REQUEST_CHANGES and you want to commit? **Stop.** Re-run reviewer.
- Validator said FAIL and you want to commit? **Stop.** Re-run validator.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Skip nits — "minor, do later" | Nits are part of the pipeline. Fix now. |
| Simplifier + reviewer parallel | Reviewer must see simplified code. Series only. |
| Commit after fixing without re-validating | Always re-run the agent that found issues. |
| No build between stages | Build after every stage. Catch errors early. |
| `git add -A` | Stage specific files. Avoid committing secrets or artifacts. |
| Forget issue number in commit | Always reference the issue: `(#N)` |
