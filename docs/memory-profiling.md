# Memory Profiling Procedure (Issue #77)

This document is the reproducible `/usr/bin/time -v` procedure for measuring
Selkie's idle peak RSS and startup time, and the baseline (BEFORE) results
that gate the lazy font-atlas work tracked in issue #77.

Raw `/usr/bin/time -v` output is **not** committed — regenerate it locally
with the steps below. Only this procedure and its summarized results are
tracked.

## Why `--export-png`

Selkie has no daemon/idle mode to attach a profiler to at rest, so the
hidden-window `--export-png` path is used as the closest proxy for "idle
after opening a document": it drives the full startup sequence (window +
GL context init, `App.loadFonts()`, file load, parse, layout, one render
pass, PNG write, clean shutdown) without showing a GUI window, and it exits
deterministically so `/usr/bin/time -v` can capture peak RSS for the whole
process lifetime. This is the same code path documented in
`CLAUDE.md` under "PNG Export (screenshots)".

## Prerequisites

- A release build, since that's what ships (`packaging/arch/PKGBUILD` and
  `.github/workflows/build.yml` both build `-Doptimize=ReleaseSafe`):

  ```bash
  zig build -Doptimize=ReleaseSafe
  ```

  Note: this build currently prints `ld.lld: warning: ... is neither ET_REL
  nor LLVM bitcode` lines for raylib's dynamically-linked system libs
  (GLX/X11/EGL/wayland/etc.) and zig's build runner echoes them under an
  `error: warning(link): ...` banner. This is pre-existing linker noise, not
  a build failure — `zig build` still exits 0 and `zig-out/bin/selkie` is
  produced. Verify with `echo $?` if the banner is alarming.

- `/usr/bin/time -v` (GNU time; not the shell builtin `time`). Confirm it
  exists before relying on `-v`:

  ```bash
  /usr/bin/time -v true
  ```

- A live X11/Wayland display (`$DISPLAY` or `$WAYLAND_DISPLAY` set). Even
  though the export window is hidden, raylib still creates a real GL
  context, so this does not run under a display-less CI runner without a
  virtual display (Xvfb) — none was available in this environment, and none
  was needed since a real display was present.

## Test fixtures

**One-line file** — minimal document, generated inline (not committed as a
fixture):

```bash
printf '# Hello\n' > /tmp/one-line.md
```

**Full sample document** — the existing tracked fixture:

```
docs/github-markdown-samples.md   # 936 lines, full GFM surface incl. Mermaid
```

## Measurement command

Run from the repo root (or worktree root), quiet mode to suppress log noise,
hidden-window PNG export to a throwaway path:

```bash
BIN=./zig-out/bin/selkie

/usr/bin/time -v "$BIN" --export-png /tmp/out.png /tmp/one-line.md -q 2> /tmp/oneline_run.txt
grep -E "Maximum resident|Elapsed" /tmp/oneline_run.txt

/usr/bin/time -v "$BIN" --export-png /tmp/out.png docs/github-markdown-samples.md -q 2> /tmp/sample_run.txt
grep -E "Maximum resident|Elapsed" /tmp/sample_run.txt
```

Take the **first** invocation after a fresh build as "cold" (binary/font/theme
files not yet in the OS page cache from a prior run of this exact binary) and
at least two subsequent invocations as "warm" (page cache populated). This
environment has no root access to `echo 3 > /proc/sys/vm/drop_caches`
between runs, so "cold" here means "first run after (re)build," not
"cold OS page cache" in the strictest sense — note this caveat when
comparing across machines/CI.

`Maximum resident set size` from `/usr/bin/time -v` is `ru_maxrss`, reported
in KiB (1024-byte units) on Linux.

## BEFORE results (this commit, `-Doptimize=ReleaseSafe`)

Environment: Linux 7.0.5-200.nobara.fc43.x86_64, live X11 display, Zig
0.14.1.

### One-line file (`printf '# Hello\n'`)

| Run | Peak RSS (KiB) | Peak RSS (MiB) | Elapsed |
|-----|---------------:|---------------:|--------:|
| 1 (cold, first post-build) | 199,148 | 194.5 | 0.46s |
| 2 (warm) | 199,428 | 194.8 | 0.44s |
| 3 (warm) | 198,980 | 194.3 | 0.42s |

### Full sample doc (`docs/github-markdown-samples.md`, 936 lines)

| Run | Peak RSS (KiB) | Peak RSS (MiB) | Elapsed |
|-----|---------------:|---------------:|--------:|
| 1 (cold) | 201,240 | 196.5 | 0.41s |
| 2 (warm) | 201,524 | 196.8 | 0.40s |
| 3 (warm) | 201,872 | 197.1 | 0.37s |

**Observation:** peak RSS is ~199MB for a one-line file and ~201MB for the
936-line sample doc — a ~2MB delta for a ~100x increase in document size.
This confirms the issue's premise: idle peak RSS is dominated by a
document-size-independent fixed cost (window/GL context init + eager font
atlas bake), not by the document being viewed. This is the BEFORE baseline
against which the lazy-atlas work is compared.

## Atlas isolation experiment (confirms material share)

To directly attribute part of that fixed cost to the eager 32px/5-variant
glyph atlas (`src/unicode_codepoints.zig`, 2,135 codepoints x 5 font
variants = 10,675 baked glyph slots), `ranges` in
`src/unicode_codepoints.zig` was temporarily reduced to ASCII-only
(`0x0020`-`0x007E`, 95 codepoints) with all other ranges commented out,
rebuilt, measured against the one-line file, then reverted and rebuilt back
to the original (verified via `git status`/`git diff` showing no residual
changes, and a confirmation run matching the original baseline: 199,672
KiB).

| Config | Peak RSS (KiB, avg of 3) |
|--------|-------------------------:|
| Full atlas (2,135 cp x 5 variants) | 199,185 |
| ASCII-only atlas (95 cp x 5 variants) | 180,940 |

**Delta: ~18.2MB (~9-10% of the ~199MB baseline)** attributable purely to
expanding the eager codepoint set from 95 to 2,135 codepoints across 5 font
variants.

## Go/no-go verdict: **GO**

The atlas is a **material but not dominant** share of the ~200MB baseline:
- ~18MB of the ~199MB is directly attributable to the eager 2,135-codepoint
  x 5-variant atlas bake — large enough that lazy-loading it is worth
  building, and directly addressable by the planned `ensureGlyphs` work.
- The remaining ~181MB (ASCII-only floor) is fixed cost from raylib window
  creation, the OpenGL/GLX context, and base runtime/allocator overhead —
  **not addressable by font work**. This means the lazy-atlas change alone
  should shave a real ~15-20MB off idle RSS for small documents, but is
  very unlikely, by itself, to hit the issue's `<100MB` (or `<80MB`)
  stretch target — that floor sits at ~181MB regardless of font strategy.
- Per the adjudicated contrarian caveat ("measure atlas share first before
  building the machinery"), this is sufficient evidence to proceed with the
  lazy-loading implementation (tasks 2-5): the atlas is confirmed as a real,
  measurable, material contributor, not a rounding error. Downstream tasks
  should still record the AFTER numbers against this same procedure so the
  actual achieved reduction (not just the isolated delta) is documented,
  and the `<100MB` target should be understood as aspirational against a
  ~181MB non-font floor rather than a hard commitment this task alone can
  deliver.

## Reproducing AFTER measurement (for later tasks)

Once lazy loading lands, rerun the exact same commands in "Measurement
command" above against the same two fixtures on the same machine, and
append a comparison table (BEFORE vs AFTER, one-line file and full sample
doc, cold + warm) to this document or to the closing issue comment.
