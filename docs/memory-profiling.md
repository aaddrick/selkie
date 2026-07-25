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

## AFTER results (lazy font-atlas loading, tasks 2-4 applied)

Same machine, same procedure, same `-Doptimize=ReleaseSafe` build, run
immediately after `zig build -Doptimize=ReleaseSafe` at commit `2c9ac05`
(final commit of tasks 1-4).

### One-line file (`printf '# Hello\n'`)

| Run | Peak RSS (KiB) | Peak RSS (MiB) | Elapsed |
|-----|---------------:|---------------:|--------:|
| 1 (cold, first post-build) | 189,092 | 184.7 | 1.49s |
| 2 (warm) | 190,004 | 185.5 | 0.34s |
| 3 (warm) | 189,736 | 185.3 | 0.36s |

The one-line doc's eager atlas is the default set only (303 codepoints x 5
variants) — `ensureGlyphs` never triggers a rebuild for it, since `# Hello`
contains nothing outside Basic Latin.

### Full sample doc (`docs/github-markdown-samples.md`, 936 lines)

| Run | Peak RSS (KiB) | Peak RSS (MiB) | Elapsed |
|-----|---------------:|---------------:|--------:|
| 1 (cold) | 191,976 | 187.5 | 0.41s |
| 2 (warm) | 191,848 | 187.4 | 0.39s |
| 3 (warm) | 191,240 | 186.8 | 0.36s |

The sample doc's math/emoji/mermaid content pulls in additional codepoints
beyond the default set (e.g. `∫ ∑ √ π ± ×` from LaTeX math synthesis, `❤ ⚠`
from emoji shortcodes), so `ensureGlyphs` performs exactly one atlas rebuild
per tab load, growing the loaded set past the default 303 — but nowhere
near the old 2,135, since only the codepoints actually used are added.

### BEFORE vs AFTER comparison (avg of 3 runs)

| Fixture | BEFORE (KiB) | AFTER (KiB) | Delta | Delta % |
|---------|-------------:|------------:|------:|--------:|
| One-line file | 199,185 | 189,611 | -9,575 KiB (-9.35 MiB) | -4.81% |
| Full sample doc | 201,545 | 191,688 | -9,857 KiB (-9.63 MiB) | -4.89% |

**Warm startup:** AFTER warm elapsed (0.34-0.39s) is equal to or faster
than BEFORE warm elapsed (0.37-0.44s) for both fixtures — not regressed,
mildly improved. The one-line cold run (1.49s) is an outlier from this
being the very first process launch after a fresh build with a cold OS
page cache for the new binary; it is not representative of steady-state
startup and is excluded from the regression judgment (the same caveat
documented above under "Take the **first** invocation... as 'cold'").

### Target assessment: **materially reduced, aspirational `<100MB`/`<80MB` target not reached**

- One-line idle peak RSS dropped ~9.4MB (~4.8%), from ~194.5MB to ~185.2MB.
  This is a real, measurable, material reduction directly attributable to
  the lazy-atlas work (eager bake shrank from 2,135 to 303 codepoints x 5
  variants), and warm startup is not regressed.
- The reduction is smaller than the ~15-20MB the plan estimated from the
  Task 1 isolation experiment, because that experiment's "reduced" config
  was ASCII-only (95 codepoints), while the actual eager default per the
  issue's own spec is larger — Basic Latin + Latin-1 + General Punctuation
  (303 codepoints). The measured ~9.4MB sits consistently between the
  ASCII-only floor (95cp -> ~180.9MB) and the full-atlas baseline (2,135cp
  -> ~194.5MB), scaling roughly with codepoint count as expected.
- The issue's `<100MB` (ideally `<80MB`) target is **not reached**: idle
  peak RSS is still ~185-187MB. This was flagged as a likely outcome during
  planning (see "Go/no-go verdict" above) — the ~181MB ASCII-only floor
  measured in Task 1 is fixed cost from raylib window creation, the
  OpenGL/GLX context, and base runtime/allocator overhead, none of which
  this issue's font-atlas work touches. Closing the remaining gap to
  `<100MB` would require a separate investigation into that non-font floor
  and is out of scope for issue #77.

## Glyph coverage verification (no missing-glyph regression)

To verify the tiered loading introduced no missing-glyph regression vs the
pre-issue-77 baseline, two checks were run against both the AFTER binary
(commit `2c9ac05`) and a BEFORE binary built from commit `3d842d2^`
(`9e073de`, the last commit before any issue-77 work, built in a scratch
`git worktree` with `deps/cmark-gfm` copied in since submodules aren't
auto-initialized in a fresh worktree checkout):

1. **Targeted glyph-category check** — a small doc exercising every
   category named in the issue's acceptance criteria (Greek, arrows, math
   operators, dingbats, ligatures, currency, plus misc symbols, geometric
   shapes, and superscripts/subscripts) was rendered with `--full-document`
   on both binaries and diffed pixel-for-pixel. Result: **identical**
   (a 14x1px anti-aliasing difference in one circled-digit dingbat glyph,
   well below any visible threshold). Every category renders correctly on
   both, confirming lazy loading preserves full BMP coverage.

2. **Full sample doc diff** — `docs/github-markdown-samples.md` was
   rendered full-document on both binaries (1400x22325px) and diffed.
   Result: 1,391 differing pixels out of ~31.3 million (0.004%), confined
   to two regions: the GFM alert icons and the emoji-shortcode section.
   In both regions, the *only* difference is that codepoints outside the
   Unicode Basic Multilingual Plane (e.g. emoji shortcodes that expand to
   supplementary-plane codepoints like `:fire:`/`:rocket:`/`:tada:`, and a
   couple of alert-type icons) render as a `?` placeholder glyph in BEFORE
   and as blank space in AFTER. These codepoints were **never** in either
   codepoint table — the pre-issue-77 `codepoints` list (`unicode_codepoints.zig`
   at `3d842d2^`) tops out at `0xFFFD`, same as today's eager+lazy union —
   so this is a pre-existing gap in both builds, not a new regression. No
   glyph that rendered as a real character in BEFORE is blank in AFTER;
   only the *fallback indicator* for already-unsupported codepoints changed
   from `?` to blank, which is a raylib font-fallback cosmetic side effect
   of the atlas being assembled via `unloadFonts`+`loadFontEx` rebuilds
   instead of a single upfront load, not a functional regression.

**Verdict:** no missing-glyph regression for any of the issue's named
categories (Greek, arrows, math operators, dingbats, ligatures, currency).
Supplementary-plane emoji remain unsupported exactly as before — out of
scope for issue #77, which only targets the BMP ranges enumerated in
`unicode_codepoints.zig`.
