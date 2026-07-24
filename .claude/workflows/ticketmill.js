export const meta = {
  name: 'ticketmill',
  description: 'Batch-process GitHub issues end-to-end: preflight-heal from GitHub state, then per issue implement (research -> evaluate <-> contrarian -> plan <-> contrarian -> tasks with review/quality loops) -> test loop -> docblocks -> PR -> spec+code review loop -> tech docs -> squash-merge + follow-ups. Stack-agnostic: driven by the target repo\'s .claude/ticketmill.json profile and its own agents.',
  whenToUse: 'When asked to batch-implement GitHub issues autonomously (the engine behind the ticketmill plugin\'s mill skill). Required args: {branch}. Provide issues:[...] OR labels:[...]. Requires a .claude/ticketmill.json profile in the target repo (run mill-init first). Optional: concurrency (1-5), limit, state, no_assignee, dry_run, run_label, batch_branch.',
  phases: [
    { title: 'Select', detail: 'load profile + resolve roles + resolve issue list + preflight probe (skip merged/closed, route open PRs to review, heal partial runs) + distill prior-run learnings', model: 'haiku' },
    { title: 'Report', detail: 'summary written to the profile logs dir + retrospective learnings appended' },
  ],
}

// =============================================================================
// ticketmill — stack-agnostic batch issue processing engine.
//
// Ported from flyspacea's batch-issues.js (itself a workflow port of
// batch-orchestrator.sh + implement-issue-orchestrator.sh). The process
// machinery — contamination guards, settled-decision ledger, handoff notes,
// claims, circuit breakers, degrade windows, preflight healing — encodes
// multiple runs of retrospective learnings and is preserved intact. What
// changed is everything project-shaped: agents, test commands, doc
// conventions, and browser verification now come from the TARGET REPO via
// its .claude/ticketmill.json profile and its .claude/agents/ directory.
//
// USAGE
//   Workflow({ scriptPath: '<repo>/.claude/workflows/ticketmill.js',
//              args: { branch: 'dev', issues: [701, 702] } })
//   Workflow({ scriptPath: ..., args: { branch: 'dev', labels: ['frontend'],
//              no_assignee: true, limit: 10 } })
//   Safe preview (probe only, no changes):
//   Workflow({ scriptPath: ..., args: { branch: 'dev', issues: [701], dry_run: true } })
//
// PROFILE (.claude/ticketmill.json in the target repo — written by mill-init)
//   The profile is REQUIRED. A missing profile halts the run: the engine never
//   guesses a toolchain, because a wrong guess silently skips verification and
//   silently-skipped verification ships broken code (the original engine's v4
//   retro paid for that lesson; see TEST LOOP below).
//   {
//     "repo": "owner/name",              // optional; discovered from gh if omitted
//     "test_command": "php artisan test",// REQUIRED KEY. null = "this project has
//                                        // no test gate" — an explicit human
//                                        // decision recorded by mill-init, and
//                                        // surfaced in the batch PR body.
//     "test_globs": ["**/*.php", "tests/**"], // changed files that count as testable
//     "install_commands": ["composer install --no-interaction"],
//     "env_files": [".env"],             // copied root -> worktree at setup
//     "simplify_globs": ["**/*.php"],    // files worth a simplify pass; null = always run
//     "serialize_globs": ["**/config/*.php"], // OPTIONAL (issue #1, lane scheduling):
//                                        // any two issues whose predicted_files both
//                                        // hit one of these patterns are a TRUSTED
//                                        // edge for computeLanes() — they always run
//                                        // in the same serial lane instead of racing,
//                                        // never dissolved by the collapse guard.
//                                        // Use it for hot/shared files (a central
//                                        // router, a schema, a magnet config) that
//                                        // predicted_files' own path-overlap
//                                        // heuristic can't be trusted to catch on its
//                                        // own. Unset/[] = only depends_on and actual
//                                        // predicted-file overlap drive lanes.
//     "docblock_globs": ["app/**/*.php"],// files needing docblocks; null = skip stage
//     "docs_dir": "docs",                // tech-docs stage target; null = skip stage
//     "release": null,                   // OPTIONAL, default null (stage skipped
//                                        // entirely, no agent call): batch-level
//                                        // CHANGELOG + version-file bump, owned by the
//                                        // Report phase, run ONCE per batch immediately
//                                        // before the batch PR agent — so the bump
//                                        // lands inside the human-reviewed TARGET->BASE
//                                        // diff by construction. Per-issue stages must
//                                        // NOT bump versions themselves.
//                                        // { "version_files": [".claude-plugin/plugin.json"],
//                                        //   "changelog": "CHANGELOG.md",  // default shown
//                                        //   "bump": null }               // "major"|"minor"|"patch" override;
//                                        //                                // unset = derive from shipped
//                                        //                                // commit types (any "feat" -> minor,
//                                        //                                // else patch) — see deriveReleaseVersion().
//                                        // version_files: JSON file(s) with a top-level "version"
//                                        // string key, bumped in place. Name the CANONICAL file only —
//                                        // never a path also listed in lockstep_installed_paths; that
//                                        // file's own mirroring tooling keeps it in sync, a second bump
//                                        // commit would just fight it. marketplace.json carries no
//                                        // version field of its own — never add one here or anywhere else.
//                                        // The next version is always computed from origin/BASE's
//                                        // version_files[0] (never TARGET), so a resumed/healing pass
//                                        // regenerates the identical version + CHANGELOG section in place
//                                        // instead of double-bumping. CAVEAT: two batch PRs open
//                                        // concurrently against the same BASE both compute BASE+bump to
//                                        // the same next version and collide on version_files/changelog at
//                                        // the second human merge — a git conflict at the human merge gate
//                                        // (pre-existing under manual bumps, not made worse), not silent
//                                        // corruption. The generated CHANGELOG entry is an explicit draft;
//                                        // the human reviewer refines wording inside the batch PR.
//     "consolidation": true,             // OPTIONAL, default true: Select-phase gate
//                                        // that groups issues cheaper to resolve as
//                                        // one unit. false disables the gate entirely
//                                        // (no gate agent call); see
//                                        // consolidationEnabled().
//     "logs_dir": "logs/ticketmill",
//     "claim_label": "ticketmill",
//     "verify_notes": ["tests need the pgvector container: podman start ncl_test"],
//     "engine_owned_globs": [],          // extends the built-in engine-owned set
//                                        // (.claude/ticketmill.json, .claude/agents/**,
//                                        // .claude/workflows/ticketmill.js,
//                                        // .claude/scripts/ticketmill/**) — read-only
//                                        // during a run; see ENGINE_OWNED_GLOBS.
//     "lockstep_installed_paths": [],    // engine-owned paths that are a deliberate
//                                        // installed copy of a source-of-truth file
//                                        // elsewhere in THIS repo, kept in lockstep by
//                                        // its own tooling — exempted from the
//                                        // post-implement hard-revert gate; see
//                                        // isHardRevertPath. This repo sets
//                                        // [".claude/workflows/ticketmill.js"].
//     "warn_base_branches": [],          // OPTIONAL (issue #36), default []: base
//                                        // branch names that trigger a Select-phase
//                                        // WARNING when a batch's target branch looks
//                                        // like a CI/CD deploy-trigger branch (PRs
//                                        // normally target the working branch, not a
//                                        // branch that auto-deploys on push). Unset/[]
//                                        // = no warning; the engine bakes in no
//                                        // project-shaped branch names of its own.
//     "contrarian_max_iterations": 3,    // OPTIONAL, default 3: caps the approach/plan
//                                        // (and consolidation) contrarian challenge
//                                        // gates' iterations before proceeding with
//                                        // unresolved caveats (recorded in the batch
//                                        // PR's Verification Gaps). Must be an integer
//                                        // >= 1 if set. 'trivial'-complexity issues get
//                                        // min(2, this value) per gate regardless.
//     "browser": null,                   // OPT-IN browser verification:
//     // { "serve_command": "php artisan serve --port={port}", "build_command": null,
//     //   "ui_globs": ["resources/views/**"], "port_base": 8100, "notes": "...",
//     //   "port_span": 900, "lock_path": "/tmp/ticketmill-browser-lock",
//     //   "stale_seconds": 1800, "poll_seconds": 15,
//     //   "artifact_dir": "/tmp/ticketmill-issue-{issue}" }
//     // All five of port_span/lock_path/stale_seconds/poll_seconds/artifact_dir are
//     // optional and default to the values shown above; artifact_dir substitutes
//     // {issue} if present (like serve_command's {port}), else appends -<issue>.
//     "models": { "plan": { "model": "opus", "effort": "high" } }, // OPTIONAL per-stage
//                                        // model/effort overrides, keyed by stage name.
//                                        // Valid keys (25): probe, setup, research,
//                                        // evaluate, consolidation, contrarian, plan,
//                                        // implement, taskReview, simplify, qReview,
//                                        // fix, testRun, testValidate, browser,
//                                        // docblock, pr, specReview, codeReview,
//                                        // techDocs, merge, release, report, retro,
//                                        // learnings.
//                                        // The `M` map below is the source of truth
//                                        // for these keys and their defaults.
//     "roles": {
//       "implementers": ["laravel-backend-developer", "frontend-developer"],
//       "default_implementer": "laravel-backend-developer",
//       "task_reviewer": "spec-reviewer", "spec_reviewer": "spec-reviewer",
//       "code_reviewer": "code-reviewer", "contrarian": "contrarian",
//       "test_validator": "php-test-validator", "simplifier": null,
//       "docblock_writer": null, "doc_writer": null
//     }
//   }
//
// AGENT MODEL (single mechanism, on purpose)
//   Roles are filled by the target repo's own agents (.claude/agents/<name>.md),
//   referenced by name in profile.roles. A stage prompt instructs its subagent to
//   READ the agent file first and adopt the persona — the engine never passes
//   agentType, so behavior does not depend on what the session's agent registry
//   happened to load at startup (newly generated agents work immediately, and a
//   run behaves the same before and after a session restart). Roles left null or
//   pointing at a missing file fall back to a built-in role charter, loudly.
//
// BATCH BRANCH MODEL
//   args.branch (BASE) is only ever the target of ONE human-reviewed PR. At startup
//   the run creates TARGET = Batch_<start timestamp> from origin/BASE (timestamp via
//   a `date` probe — Date.now() is unavailable here). All worktrees branch from
//   TARGET, all diffs/reviews compare against TARGET, and per-issue PRs squash-merge
//   into TARGET. The run ends by opening a PR TARGET -> BASE with "Closes #N" for
//   every completed issue — NEVER auto-merged; issues stay open until a human merges
//   that PR (per-issue merges into a non-default branch don't fire "Closes #"). To
//   heal/resume a batch, re-run with args.batch_branch: 'Batch_<ts>'.
//
// CROSS-RUN ISSUE CLAIMS (multi-machine coordination)
//   At Select time — BEFORE the concurrency queue drains — the run claims every
//   selected issue: a claim label + a "## Ticketmill Claimed" comment carrying
//   batch branch, run tag, host, and a started epoch. A second run started
//   elsewhere claims at ITS Select phase, finds a fresh foreign claim (< 12h),
//   and skips the issue; a post-then-verify race check (earlier epoch wins)
//   settles simultaneous starts. Claims from the SAME batch branch are recognized
//   as our own (resume). One-way compatibility: fresh claims left by the older
//   batch-issues engine ("## Batch Processing Claimed" / batch-in-flight label)
//   are honored as foreign claims too. Releases: per-issue at merge and on halt
//   notes, plus a Report-phase sweep; a dead run's claims expire via the 12h
//   staleness window. Claims are advisory — a died claim agent fails open.
//
// BROWSER VERIFICATION (opt-in, serial)
//   Only when profile.browser is configured. UI-testable changes (diff touches
//   profile.browser.ui_globs) get a live-browser pass twice: after the test loop
//   ('implement') and after PR reviews approve ('pre-merge'). The browser MCP is
//   ONE shared instance, so all browser stages across concurrent pipelines run
//   through a chained mutex; probes and fix stages run outside the lock. Each
//   pass boots profile.browser.serve_command (with {port} substituted per issue).
//   Two-layer locking: the JS mutex only orders stages THIS SCRIPT schedules, so
//   a host-global mkdir lock (default /tmp/ticketmill-browser-lock, owner file,
//   default 30-min stale-steal, default 15s poll — all overridable via
//   profile.browser.lock_path/stale_seconds/poll_seconds) additionally guards the
//   browser itself; ad-hoc agent use goes through the same lock.
//
// RESTARTABLE (two independent paths)
//   1. Same session, exact resume: Workflow({ scriptPath, resumeFromRunId: 'wf_...' })
//   2. Any session: re-run with the SAME args (+ batch_branch). The Select-phase
//      preflight reads GitHub/git state and routes each issue: merged/closed ->
//      skip; open PR -> review+merge only; partial branch/worktree -> implement
//      continues (setup is idempotent; every implement prompt checks existing
//      commits first).
//
// SELF-HEALING
//   - Every stage retries once with an attempt-stamped prompt (distinct journal key).
//   - Schema-forced structured output (the harness retries schema mismatches).
//   - Quality-loop stage errors degrade the task and continue (halt only when >= 3
//     of the last 5 tasks degraded).
//   - Test-loop stage errors halt the issue loudly (silent degradation would ship
//     broken code when CI does not run the suite).
//   - Circuit breakers: >= 3 issues failed, or >= 3 consecutive agent deaths
//     (the usage-limit signature) -> stop launching, report a resume plan.
//   - Failures post an issue comment with the halt stage + resume instructions.
//
// CROSS-PIPELINE CONTAMINATION GUARDS
//   - Scope guard: every stage prompt pins gh comment/edit targets to its own issue
//     and requires an "<!-- ticketmill <repo>#<issue> -->" marker on every comment.
//   - Contrarian gates mechanically delete trail comments whose marker names a
//     different issue (misfiled by a concurrent pipeline).
//   - Decision-chain records are issue-stamped; decisionChain() drops mis-stamped
//     records. sanitizeTasks() drops stub task descriptions (< 12 chars) so a
//     placeholder plan fails and retries instead of dispatching an empty task.
//
// LOOP-STEP VISIBILITY: every review/fix loop iteration posts its own issue/PR
// comment — the trail shows each round, not just "Task N Implemented".
//
// CONTEXT THREADING (how earlier agents inform later ones, 3-4 stages downstream)
//   - Decision chain: distilled per-stage summaries injected into judgment stages.
//   - Settled ledger: decisions adjudicated at contrarian gates travel forward with
//     a "re-open only with new evidence" contract.
//   - Handoff notes: work stages return notes_for_downstream (env quirks, anchoring
//     gotchas); a bounded ledger is injected into later implement/fix/test prompts.
//   - Learnings digest: one Select-phase agent distills process-retrospective.md
//     once; category sections are injected per stage.
//   - Issue trail: contrarian gates read the full GitHub comment trail — the
//     uncompressed record — before challenging.
//
// MODEL POLICY (override per stage via profile.models)
//   haiku/low  : mechanical gh/git probes, setup script, running the test suite,
//                batch-branch creation, UI-file probes
//   sonnet     : research, implementation, fixes, simplify, per-task reviews,
//                test validation, browser verification, docs, PR/merge mechanics,
//                reporting
//   opus       : judgment gates — evaluate, plan, contrarian challenges (high
//                effort), and the final pre-merge code review (high effort)
// =============================================================================

// ----- args -----
// Self-heal stringified args: some invocation paths deliver args as a JSON string.
let A = args
if (typeof A === 'string') {
  try { A = JSON.parse(A) } catch (e) { throw new Error('args arrived as a non-JSON string: ' + A.slice(0, 200)) }
}
A = A || {}
const BASE = A.branch
if (!BASE) throw new Error('args.branch is required (base branch for PRs, e.g. "dev" or "main")')
let TARGET = A.batch_branch ? String(A.batch_branch).trim() : null
let ROOT = A.root || null       // absolute repo root; discovered by the bootstrap probe if not provided
let REPO = A.repo || null       // owner/name slug; profile or bootstrap probe if not provided
let WORKTREES = null            // ROOT + '/.worktrees' once ROOT is known
const RUN_TAG = A.run_label || A.date || 'run'
const CONCURRENCY = Math.max(1, Math.min(5, Number(A.concurrency) || 2))
const DRY_RUN = !!A.dry_run

// ----- caps -----
let MAX_CONTRARIAN_ITERATIONS = 3 // overridable via profile.contrarian_max_iterations (see __seed / Select)
const MAX_TASK_REVIEW_ATTEMPTS = 3
const MAX_QUALITY_ITERATIONS = 5
const MAX_TEST_ITERATIONS = 10
const MAX_BROWSER_ITERATIONS = 3
const CLAIM_TITLE = '## Ticketmill Claimed'
const LEGACY_CLAIM_TITLE = '## Batch Processing Claimed' // batch-issues engine — honored one-way
const CLAIM_STALE_SECONDS = 12 * 3600
const MAX_PR_REVIEW_ITERATIONS = 3
const MAX_BATCH_FAILURES = 3
const QUALITY_DEGRADE_WINDOW = 5
const MAX_QUALITY_DEGRADES_IN_WINDOW = 3
const MAX_CONSECUTIVE_AGENT_DEATHS = 3
const STAGE_TRIES = 2
// lane scheduling (issue #1): bounds a lane's merged predicted_files list (the
// union of every member unit's own, already-capped-at-20 predicted_files) so a
// lane spanning many units can't grow that list unboundedly — it's a DRY_RUN/
// human-readability aid, not a correctness input, so a hard cap is safe.
const MAX_LANE_PREDICTED_FILES = 60
// lane scheduling (issue #1): bounds how many completed units' predicted-vs-
// actual data the Report-phase retrospective agent is handed (each entry is a
// small {issue, pr, predicted_files} tuple) — a human-readability/prompt-size
// cap on the accuracy sample, not a correctness input.
const MAX_LANE_ACCURACY_SAMPLES = 40

// ----- model policy (profile.models may override any stage key) -----
const M = {
  probe:        { model: 'haiku', effort: 'low' },
  setup:        { model: 'haiku', effort: 'low' },
  research:     { model: 'sonnet' },
  evaluate:     { model: 'opus' },
  consolidation: { model: 'opus', effort: 'high' }, // proposeConsolidation's propose/revise calls (Select-phase gate)
  contrarian:   { model: 'opus', effort: 'high' },
  plan:         { model: 'opus', effort: 'high' },
  implement:    { model: 'sonnet' },
  taskReview:   { model: 'sonnet' },
  simplify:     { model: 'sonnet' },
  qReview:      { model: 'sonnet' },
  fix:          { model: 'sonnet' },
  testRun:      { model: 'haiku', effort: 'low' },
  testValidate: { model: 'sonnet' },
  browser:      { model: 'sonnet' },
  docblock:     { model: 'sonnet', effort: 'low' },
  pr:           { model: 'sonnet', effort: 'low' },
  specReview:   { model: 'sonnet' },
  codeReview:   { model: 'opus', effort: 'high' },
  techDocs:     { model: 'sonnet' },
  merge:        { model: 'sonnet' },
  release:      { model: 'sonnet' }, // Report-phase batch release stage (gated on profile.release)
  report:       { model: 'sonnet', effort: 'low' },
  retro:        { model: 'sonnet' },
  learnings:    { model: 'sonnet', effort: 'low' },
}

// ----- built-in role charters (fallback when a role has no project agent) -----
const CHARTERS = {
  implementer: 'You are a careful senior software engineer. Follow the conventions you observe in the codebase and its CLAUDE.md; prefer small, focused commits; never weaken tests or delete assertions to make failures disappear; verify your change compiles/runs before committing.',
  task_reviewer: 'You are a pragmatic reviewer verifying that an implementation achieves its task goal. Judge goal achievement against the task description and the actual diff — not style preferences. Fail only for concrete, demonstrable gaps.',
  spec_reviewer: 'You are a specification reviewer. Verify the PR achieves the ISSUE requirements — goal achievement, not code quality. Flag scope creep (unrelated features) for removal. Check acceptance criteria against the actual diff and pre-existing code before flagging anything missing.',
  code_reviewer: 'You are a rigorous code reviewer. Check correctness, security, error handling, and consistency with the codebase\'s own conventions (read neighboring code first). Findings must be concrete and actionable; do not block on style nits.',
  contrarian: 'You are a devil\'s-advocate analyst. Apply the Tenth Man Rule: assume the consensus is wrong and investigate that world. Steel-man first, then assumption audit, pre-mortem, inversion, second-order effects. Verify before asserting; calibrate severity honestly.',
  test_validator: 'You are a test-quality auditor. Audit tests for cheating: TODO/incomplete tests, hollow assertions (assertTrue(true)-style), missing edge cases, mock abuse, tests that pass without exercising the change. Judge coverage against the changed code only.',
  simplifier: 'You simplify and refine code for clarity, consistency, and maintainability while preserving ALL functionality. Match the codebase\'s idiom; never change behavior; commit only when a change is a strict improvement.',
  docblock_writer: 'You write clear, comprehensive documentation blocks for the changed code in the codebase\'s established doc-comment style. Explain purpose, parameters, returns, and context for a new developer. Do not change code behavior.',
  doc_writer: 'You write technical design documentation in GitHub Markdown (with Mermaid where a diagram clarifies). Document architecture, data flow, and contracts — not line-by-line code narration.',
}

// PROFILE, ROLES, IMPLEMENTERS, AGENT_INFO are populated at Select.
let PROFILE = null
let ROLES = {}
let IMPLEMENTERS = []           // implementer agent names (may be empty)
let DEFAULT_IMPLEMENTER = null  // name or null -> charter fallback
let AGENT_INFO = {}             // name -> { exists: bool, description: string }
let TEST_CMD
let LOGS = null                 // ROOT + '/' + profile.logs_dir
let CLAIM_LABEL = 'ticketmill'
let BROWSER = null              // profile.browser or null
let RELEASE = null              // profile.release or null (normalized: version_files
                                 // as strings, changelog defaulted to 'CHANGELOG.md')
let VERIFY_SKIPS = []           // human-visible verification gaps -> batch PR body
// ENGINE_OWNED / LOCKSTEP_INSTALLED_PATHS (issue #3): populated at Select from
// ENGINE_OWNED_GLOBS (~line 1244, declared after this point — assigned via
// mergeEngineOwnedGlobs, not referenced eagerly here) merged with
// PROFILE.engine_owned_globs, and PROFILE.lockstep_installed_paths respectively.
let ENGINE_OWNED = []
let LOCKSTEP_INSTALLED_PATHS = []

function stageOpts(key) {
  const base = M[key] || { model: 'sonnet' }
  const o = PROFILE && PROFILE.models && PROFILE.models[key] ? PROFILE.models[key] : null
  if (!o) return base
  const merged = Object.assign({}, base)
  if (o.model) merged.model = o.model
  if (o.effort) merged.effort = o.effort
  return merged
}

// roleBlock: the single agent mechanism. If the role maps to an existing project
// agent file, the stage subagent is instructed to READ it and adopt the persona
// (full file, from the target repo — not a truncated inline copy). Otherwise the
// built-in charter is inlined. Never agentType: behavior must not depend on what
// the session's agent registry loaded at startup.
function personaFor(agentName, charterKey) {
  const info = agentName ? AGENT_INFO[agentName] : null
  if (info && info.exists) {
    return '## Role\nFIRST read ' + ROOT + '/.claude/agents/' + agentName + '.md and fully adopt that persona for this stage: its scope, conventions, anti-patterns, and coordination rules override generic behavior. (Read the file before doing anything else.)'
  }
  if (agentName) log('role fallback: agent "' + agentName + '" not found in ' + (ROOT || '<root>') + '/.claude/agents — using built-in ' + charterKey + ' charter')
  return '## Role\n' + (CHARTERS[charterKey] || CHARTERS.implementer)
}
function roleBlock(roleKey) { return personaFor(ROLES[roleKey], roleKey) }
function implementerBlock(name) {
  const n = IMPLEMENTERS.indexOf(name) !== -1 ? name : DEFAULT_IMPLEMENTER
  return personaFor(n, 'implementer')
}
function pickFixAgent(recommended, fallback) {
  if (recommended && IMPLEMENTERS.indexOf(recommended) !== -1) return recommended
  return fallback || DEFAULT_IMPLEMENTER
}

// ----- schemas -----
const BOOT_SCHEMA = {
  type: 'object', required: ['root', 'repo'],
  properties: { root: { type: 'string' }, repo: { type: 'string' } },
}
const PROFILE_SCHEMA = {
  type: 'object', required: ['found'],
  // found/raw describe the probe's own response shape (does the profile file
  // exist, and its raw text). engine_owned_globs/lockstep_installed_paths
  // document — for readers of this schema — the two optional array fields
  // issue #3 added to the parsed .claude/ticketmill.json profile itself (read
  // via PROFILE.engine_owned_globs / PROFILE.lockstep_installed_paths at
  // Select, see mergeEngineOwnedGlobs); they are not part of the probe
  // response and additionalProperties is unset, so listing them here is
  // documentation only, not enforcement.
  properties: {
    found: { type: 'boolean' }, raw: { type: 'string' },
    engine_owned_globs: { type: 'array', items: { type: 'string' } },
    lockstep_installed_paths: { type: 'array', items: { type: 'string' } },
  },
}
const AGENTS_SCHEMA = {
  type: 'object', required: ['agents'],
  properties: { agents: { type: 'array', items: { type: 'object', required: ['name', 'exists'], properties: { name: { type: 'string' }, exists: { type: 'boolean' }, description: { type: 'string' } } } } },
}
const SELECT_SCHEMA = {
  type: 'object', required: ['issues'],
  properties: { issues: { type: 'array', items: { type: 'object', required: ['number'], properties: { number: { type: 'integer' }, title: { type: 'string' } } } } },
}
const PREFLIGHT_SCHEMA = {
  type: 'object', required: ['issue', 'resume_point', 'reason'],
  properties: {
    issue: { type: 'integer' }, title: { type: 'string' },
    // body (issue #3): the issue's full body text, added so the Select-phase
    // JS pass can compute engineOwnedIntentional (engineOwnedHit over
    // title+body) without a second probe round-trip.
    body: { type: 'string' },
    issue_state: { enum: ['open', 'closed', 'unknown'] },
    pr_number: { type: ['integer', 'null'] },
    pr_state: { enum: ['open', 'merged', 'closed', 'none'] },
    // pr_base (issue #30): base branch of the SAME related PR pr_state/pr_number
    // describe — null if no related PR. Lets the JS skip-return below string-match
    // it against TARGET (the batch branch), so "merged into ANY branch" (e.g. a
    // concurrent run's own batch branch) is never confused with "merged into THIS
    // run's batch branch". See merged_into_target at the resume_point==='skip' return.
    pr_base: { type: ['string', 'null'] },
    branch: { type: ['string', 'null'] }, worktree_exists: { type: 'boolean' },
    commits_ahead: { type: ['integer', 'null'] },
    resume_point: { enum: ['skip', 'process_pr', 'implement'] },
    reason: { type: 'string' },
    // root_dirty_engine_paths (issue #3): engine-owned paths (per the
    // literalized pathspec interpolated into the probe prompt) that `git -C
    // ROOT status --porcelain` reports dirty right now — the regime (a)
    // root-dirty read applyEngineOwnedRootDirtySkip() acts on. [] when clean.
    root_dirty_engine_paths: { type: 'array', items: { type: 'string' } },
    // OPTIONAL lane-scheduling prediction (issue #1): real repo-relative paths
    // resolved against origin/TARGET (never guessed), and in-batch issue refs
    // parsed from body text. Both fail open to [] — see the probe prompt below
    // and deriveUnits() for how they're threaded onto the unit shape.
    predicted_files: { type: 'array', items: { type: 'string' } },
    depends_on: { type: 'array', items: { type: 'integer' } },
  },
}
const SETUP_SCHEMA = {
  type: 'object', required: ['status'],
  properties: { status: { enum: ['success', 'error'] }, worktree: { type: 'string' }, branch: { type: 'string' }, error: { type: ['string', 'null'] } },
}
const BATCH_BRANCH_SCHEMA = {
  type: 'object', required: ['status'],
  properties: { status: { enum: ['success', 'error'] }, branch: { type: 'string' }, error: { type: ['string', 'null'] } },
}
const TARGET_FETCH_SCHEMA = {
  type: 'object', required: ['status'],
  properties: { status: { enum: ['success', 'error'] }, error: { type: ['string', 'null'] } },
}
const UI_PROBE_SCHEMA = {
  type: 'object', required: ['ui_files'],
  properties: { ui_files: { type: 'array', items: { type: 'string' } } },
}
// DIFF_PROBE_SCHEMA: the post-implement engine-owned gate's own read-only
// diff probe (runEngineOwnedGate) — same shape as UI_PROBE_SCHEMA's ui_files
// idea, generalized to "every changed file" since the JS side (not the
// agent) does the ENGINE_OWNED filtering.
const DIFF_PROBE_SCHEMA = {
  type: 'object', required: ['changed_files'],
  properties: {
    changed_files: { type: 'array', items: { type: 'string' } },
    // added_files: optional — files newly created on this branch (absent from
    // origin/TARGET at baseline). Only runEngineOwnedGate's probe populates this
    // (a second `--diff-filter=A` command); other DIFF_PROBE_SCHEMA callers omit
    // it and get today's behavior unchanged (see the revert-stage partition).
    added_files: { type: 'array', items: { type: 'string' } },
  },
}
const CLAIM_SCHEMA = {
  type: 'object', required: ['issue', 'claimed'],
  properties: { issue: { type: 'integer' }, claimed: { type: 'boolean' }, reason: { type: 'string' } },
}
const BROWSER_SCHEMA = {
  type: 'object', required: ['result', 'summary'],
  properties: {
    result: { enum: ['passed', 'failed', 'skipped'] },
    scenarios: { type: 'array', items: { type: 'string' } },
    failures: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    notes_for_downstream: { type: 'array', items: { type: 'string' } },
  },
}
const RESEARCH_SCHEMA = {
  type: 'object', required: ['status'],
  properties: {
    status: { enum: ['success', 'error'] },
    context: { type: 'object', properties: {
      issue_title: { type: 'string' }, issue_body: { type: 'string' },
      related_files: { type: 'array', items: { type: 'string' } },
      dependencies: { type: 'array', items: { type: 'string' } },
      prior_work: { type: 'string' },
    } },
    error: { type: ['string', 'null'] },
  },
}
const EVALUATE_SCHEMA = {
  type: 'object', required: ['status', 'summary'],
  properties: {
    status: { enum: ['success', 'error'] }, approach: { type: 'string' }, rationale: { type: 'string' },
    complexity: { enum: ['trivial', 'standard', 'complex'] },
    risks: { type: 'array', items: { type: 'string' } },
    alternatives_rejected: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' }, error: { type: ['string', 'null'] },
  },
}
const CHALLENGE_SCHEMA = {
  // Only verdict+summary are hard-required: opus challengers demonstrably drop the
  // findings array under long output, and control flow stays correct without it
  // (missing findings => 0 critical/major).
  type: 'object', required: ['verdict', 'summary'],
  properties: {
    verdict: { enum: ['sound_with_caveats', 'needs_rework', 'investigate_first'] },
    strengths: { type: 'string' },
    findings: { type: 'array', items: { type: 'object', required: ['severity', 'summary', 'recommendation'], properties: {
      severity: { enum: ['critical', 'major', 'minor'] }, summary: { type: 'string' },
      assumption_challenged: { type: 'string' }, failure_scenario: { type: 'string' },
      impact: { type: 'string' }, recommendation: { type: 'string' },
    } } },
    caveats: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
}
const PLAN_SCHEMA = {
  type: 'object', required: ['status', 'summary', 'tasks'],
  properties: {
    status: { enum: ['success', 'error'] }, plan_path: { type: 'string' },
    tasks: { type: 'array', items: { type: 'object', required: ['id', 'description', 'agent'], properties: {
      id: { type: 'integer' }, description: { type: 'string' }, agent: { type: 'string' },
      // origin_issue: only meaningful for a consolidated group unit — the member
      // issue number whose requirement drives this task. Optional/absent for a
      // singleton run; the plan-task sanitizer defaults it to ctx.issue either way.
      origin_issue: { type: ['integer', 'null'] },
    } } },
    summary: { type: 'string' }, task_list_markdown: { type: 'string' }, error: { type: ['string', 'null'] },
  },
}
const IMPL_SCHEMA = {
  type: 'object', required: ['status', 'summary'],
  properties: {
    status: { enum: ['success', 'error'] }, commit: { type: ['string', 'null'] },
    files_changed: { type: 'array', items: { type: 'string' } }, summary: { type: 'string' }, error: { type: ['string', 'null'] },
    notes_for_downstream: { type: 'array', items: { type: 'string' } },
  },
}
const TASK_REVIEW_SCHEMA = {
  type: 'object', required: ['result', 'suggested_improvements'],
  properties: { result: { enum: ['passed', 'failed'] }, suggested_improvements: { enum: ['yes', 'no'] }, comments: { type: 'string' } },
}
const REVIEW_SCHEMA = {
  type: 'object', required: ['result', 'summary'],
  properties: {
    result: { enum: ['approved', 'changes_requested'] }, comments: { type: 'string' },
    issues: { type: 'array', items: {} }, recommended_fix_agent: { type: ['string', 'null'] }, summary: { type: 'string' },
  },
}
const FIX_SCHEMA = {
  type: 'object', required: ['status', 'summary'],
  properties: {
    status: { enum: ['success', 'error'] }, commit: { type: ['string', 'null'] },
    files_changed: { type: 'array', items: { type: 'string' } },
    fixes_applied: { type: 'array', items: { type: 'string' } }, summary: { type: 'string' }, error: { type: ['string', 'null'] },
    notes_for_downstream: { type: 'array', items: { type: 'string' } },
  },
}
const TEST_SCHEMA = {
  type: 'object', required: ['result', 'summary'],
  properties: {
    result: { enum: ['passed', 'failed'] }, total_tests: { type: 'integer' }, passed_tests: { type: 'integer' },
    failed_tests: { type: 'integer' },
    failures: { type: 'array', items: { type: 'object', properties: { test: { type: 'string' }, message: { type: 'string' } } } },
    summary: { type: 'string' },
    notes_for_downstream: { type: 'array', items: { type: 'string' } },
  },
}
const TECH_DOCS_SCHEMA = {
  type: 'object', required: ['status', 'docs_needed', 'summary'],
  properties: {
    status: { enum: ['success', 'skipped', 'error'] }, docs_needed: { type: 'boolean' },
    actions: { type: 'array', items: { type: 'object', properties: { action: { enum: ['created', 'updated'] }, file: { type: 'string' }, description: { type: 'string' } } } },
    commit: { type: ['string', 'null'] }, summary: { type: 'string' }, error: { type: ['string', 'null'] },
  },
}
const PR_SCHEMA = {
  type: 'object', required: ['status'],
  properties: { status: { enum: ['success', 'error'] }, pr_number: { type: ['integer', 'null'] }, pr_url: { type: 'string' }, error: { type: ['string', 'null'] } },
}
// ----- Report-phase release stage schemas (gated on profile.release) -----
const RELEASE_PROBE_SCHEMA = {
  type: 'object', required: ['base_version', 'commit_types'],
  properties: {
    base_version: { type: ['string', 'null'] },
    commit_types: { type: 'array', items: { type: 'string' } },
  },
}
const RELEASE_SCHEMA = {
  type: 'object', required: ['status'],
  properties: {
    status: { enum: ['success', 'error'] },
    version: { type: ['string', 'null'] },
    commit: { type: ['string', 'null'] },
    pushed: { type: ['boolean', 'null'] },
    summary: { type: 'string' },
    error: { type: ['string', 'null'] },
  },
}
const MERGE_SCHEMA = {
  type: 'object', required: ['status'],
  properties: {
    status: { enum: ['merged', 'blocked', 'error'] },
    follow_up_issues: { type: 'array', items: { type: 'integer' } },
    error: { type: ['string', 'null'] },
  },
}
// ----- merge auto-resolve schemas (see runMergeAutoResolve) -----
const MERGE_PREFLIGHT_SCHEMA = {
  type: 'object', required: ['mergeable'],
  properties: {
    state: { type: 'string' },
    mergeable: { enum: ['MERGEABLE', 'CONFLICTING', 'UNKNOWN'] },
    mergeStateStatus: { type: 'string' },
  },
}
const MERGE_REBASE_SCHEMA = {
  type: 'object', required: ['status'],
  properties: {
    status: { enum: ['clean', 'conflicts', 'error'] },
    conflicted_files: { type: 'array', items: { type: 'string' } },
    error: { type: ['string', 'null'] },
  },
}
const MERGE_RESOLVE_SCHEMA = {
  type: 'object', required: ['status', 'summary'],
  properties: {
    status: { enum: ['resolved', 'aborted'] },
    commit: { type: ['string', 'null'] },
    files_changed: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    notes_for_downstream: { type: 'array', items: { type: 'string' } },
  },
}
const MERGE_GUARD_SCHEMA = {
  type: 'object', required: ['moved'],
  properties: { moved: { type: 'boolean' }, detail: { type: 'string' } },
}
const MERGE_PUSH_SCHEMA = {
  type: 'object', required: ['status'],
  properties: { status: { enum: ['success', 'error'] }, error: { type: ['string', 'null'] } },
}
const NOTE_SCHEMA = { type: 'object', required: ['posted'], properties: { posted: { type: 'boolean' } } }
const REPORT_SCHEMA = {
  type: 'object', required: ['report_path', 'markdown_summary'],
  properties: { report_path: { type: 'string' }, markdown_summary: { type: 'string' } },
}
const RETRO_SCHEMA = {
  type: 'object', required: ['summary'],
  properties: {
    learnings_added: { type: 'integer' }, learnings_deprecated: { type: 'integer' }, summary: { type: 'string' },
    // lane_prediction_accuracy (issue #1, lane scheduling): one plain-text line
    // summarizing predicted vs. actual changed files across this run's completed,
    // predicted units — e.g. "7/9 actual changed files were predicted (78%
    // coverage) across 4 completed issues with predictions". Optional/absent
    // when this run had nothing to measure (no completed unit had predictions).
    lane_prediction_accuracy: { type: 'string' },
  },
}
const LEARNINGS_SCHEMA = {
  type: 'object', required: ['found'],
  properties: {
    found: { type: 'boolean' },
    agent_selection: { type: 'string' }, quality_loop: { type: 'string' }, test_loop: { type: 'string' },
    performance: { type: 'string' }, error_patterns: { type: 'string' }, workflow: { type: 'string' },
  },
}
// CONSOLIDATION_SCHEMA: the opus-tier Select-phase gate that proposes grouping
// selected issues into ONE worktree/branch/research/plan/PR unit. Conservative bar —
// grouping is the exception, so groups[] is expected to be empty on most runs. Each
// group names an explicit reason (subsystem + shared acceptance surface, OR an
// explicit dependency) so shared files alone never qualify; the prompt that drives
// this schema (added when the gate itself is wired in) enforces that at least one of
// shared_surface/dependency is populated. ungrouped[] carries every candidate issue
// the gate declined to group, so the caller can assert groups+ungrouped covers every
// candidate.
const CONSOLIDATION_SCHEMA = {
  type: 'object', required: ['groups', 'ungrouped'],
  properties: {
    groups: { type: 'array', items: { type: 'object', required: ['primary', 'members', 'subsystem', 'rationale'], properties: {
      primary: { type: 'integer' },              // issue number carrying the comment trail
      members: { type: 'array', items: { type: 'integer' } }, // every issue in the group, primary included
      subsystem: { type: 'string' },
      shared_surface: { type: 'string' },        // the shared acceptance surface, if that's the reason
      dependency: { type: 'string' },            // the explicit dependency, if that's the reason instead
      rationale: { type: 'string' },
    } } },
    ungrouped: { type: 'array', items: { type: 'integer' } },
  },
}
// CONSOLIDATION_MARKER_PROBE_SCHEMA: the read-only probe proposeConsolidation()
// uses to fetch each candidate's existing consolidation-marker comment (if any),
// feeding healGroups() so a prior decision is recognized before the opus gate runs.
const CONSOLIDATION_MARKER_PROBE_SCHEMA = {
  type: 'object', required: ['markers'],
  properties: {
    markers: { type: 'array', items: { type: 'object', required: ['issue', 'body'], properties: {
      issue: { type: 'integer' }, body: { type: 'string' },
    } } },
  },
}

// =============================================================================
// CONSOLIDATION (unit-of-work) FOUNDATIONS
//
// A "unit" is either a singleton (today's per-issue path, verbatim) or a group
// (a primary issue + members[] processed as one worktree/branch/research/plan/PR).
// With zero groups every unit is a singleton, so a no-overlap run behaves
// byte-for-byte like today — that's the acceptance bar this whole abstraction is
// built to preserve.
//
// Judgment (the opus gate + capped contrarian challenge that PROPOSES groups) is not
// implemented here — this section only holds the pure, harness-testable plumbing it
// will be built on: the schema above, the comment markers that let a resumed run
// recognize a prior consolidation, and the reducers that turn "what the markers say"
// plus "what's live right now" into the units runPool() actually processes.
//
// STABLE GROUP ID: a group's PHYSICAL identity (worktree issue-N, branch issue-N-*,
// PR head — see scripts/setup-worktree.sh and the process_pr path) is bound to a
// group id that is chosen once and never changes. The group's LOGICAL primary (the
// issue carrying the comment trail) can move on re-anchor (e.g. the original primary
// got skip-flipped by a resume), but the group id does not — mixing the two up is
// exactly the contradiction the approach-gate contrarian caught. By convention the
// group id is the lowest issue number that has EVER been a member (see
// stableGroupId()); it is also the key healGroups()/reconcileGroups() index by.
// =============================================================================

// Comment titles (first line) that gate consolidation markers apart from ordinary
// trail comments. Every marker comment still ends with the canonical scope-guard
// line "<!-- ticketmill <repo>#<issue> -->" (see scopeGuard()) — these titles add a
// second, group-specific line of machine-parseable content ABOVE that line; they
// never replace or reshape the canonical marker itself.
const CONSOLIDATION_MEMBER_TITLE = '## Consolidated'       // posted on an absorbed member's own issue
const CONSOLIDATION_GROUP_TITLE = '## Consolidation Group' // posted on the group's primary issue

// fmtIssues: render a list of issue numbers as "#1, #2, #3" — the shared rendering
// used by every consolidation marker/prompt that lists member issues below.
function fmtIssues(nums) {
  return (nums || []).map(function (n) { return '#' + n }).join(', ')
}

// buildConsolidatedMemberComment: the comment left on an absorbed member's issue.
// Names the CURRENT primary for humans reading the trail, and the STABLE groupId
// (never the primary, which can move — see reconcileGroups) for the machine heal
// pass to key off of.
function buildConsolidatedMemberComment(repo, memberIssue, primaryIssue, groupId, rationale) {
  return [
    CONSOLIDATION_MEMBER_TITLE,
    'Consolidated into #' + primaryIssue + ' (group ' + groupId + ') — implemented as one unit.',
    rationale ? 'Rationale: ' + rationale : '',
    '<!-- ticketmill ' + repo + '#' + memberIssue + ' -->',
  ].filter(Boolean).join('\n')
}

// oneLine: collapse embedded newlines to spaces — parseConsolidationGroupComment's
// per-field regexes are line-anchored (^field:\s*(.*)$), so a value written with a
// literal newline would silently truncate to its first line on read-back. Every
// free-text field written into a group marker comment must be passed through this
// first.
function oneLine(s) {
  return String(s || '').replace(/\r?\n+/g, ' ').trim()
}

// buildConsolidationGroupComment: the comment left on the group's primary issue,
// enumerating every live member so a resumed run's heal pass can reconstruct the
// whole group even if it never fetches each member's own marker comment.
function buildConsolidationGroupComment(repo, primaryIssue, groupId, members, subsystem, rationale) {
  return [
    CONSOLIDATION_GROUP_TITLE,
    'group: ' + groupId,
    'members: ' + fmtIssues(members),
    'subsystem: ' + oneLine(subsystem),
    rationale ? 'rationale: ' + oneLine(rationale) : '',
    '<!-- ticketmill ' + repo + '#' + primaryIssue + ' -->',
  ].filter(Boolean).join('\n')
}

// parseConsolidatedMemberComment: null unless body is a member marker (title-gated,
// so an unrelated comment that merely mentions "consolidated" is never misread).
// Returns { primary, groupId }.
function parseConsolidatedMemberComment(body) {
  if (!body || String(body).split('\n')[0].trim() !== CONSOLIDATION_MEMBER_TITLE) return null
  const m = /Consolidated into #(\d+) \(group (\S+)\)/.exec(body)
  if (!m) return null
  return { primary: Number(m[1]), groupId: Number(m[2]) }
}

// parseConsolidationGroupComment: null unless body is a group marker (title-gated).
// Returns { groupId, members: [issueNumbers], subsystem, rationale }.
function parseConsolidationGroupComment(body) {
  if (!body || String(body).split('\n')[0].trim() !== CONSOLIDATION_GROUP_TITLE) return null
  const g = /^group:\s*(\S+)\s*$/m.exec(body)
  const mem = /^members:\s*(.+)$/m.exec(body)
  if (!g || !mem) return null
  const members = mem[1].split(',')
    .map(function (s) { return Number(s.trim().replace(/^#/, '')) })
    .filter(function (n) { return n > 0 })
  if (!members.length) return null
  const sub = /^subsystem:\s*(.*)$/m.exec(body)
  const rat = /^rationale:\s*(.*)$/m.exec(body)
  return { groupId: Number(g[1]), members: members, subsystem: sub ? sub[1].trim() : '', rationale: rat ? rat[1].trim() : '' }
}

// stableGroupId: a group's immutable physical-identity anchor (see comment block
// above) — the lowest issue number ever proposed as a member. Chosen once, at first
// proposal; re-anchoring the logical primary (reconcileGroups) never changes it.
function stableGroupId(memberIssueNumbers) {
  return Math.min.apply(null, memberIssueNumbers)
}

// pickPrimary: choose a group's primary — the proposed primary if it's still a
// live member, otherwise the stable (lowest-numbered) member, so a primary that
// dropped out of the group (excluded by reconcileGroups, or trimmed by a
// contrarian revision) always re-anchors onto a member that's actually still
// there. Shared by reconcileGroups(), proposeConsolidation()'s proposal
// filtering, and challengeConsolidationGroup()'s revision-acceptance path — all
// three re-derive a primary the same way. `members` may be empty only at the
// proposal-filtering call site (before its own >= 2 filter runs); that case
// falls back to proposedPrimary itself, since stableGroupId([]) is undefined.
function pickPrimary(members, proposedPrimary) {
  if (members.indexOf(proposedPrimary) !== -1) return proposedPrimary
  return members.length ? stableGroupId(members) : proposedPrimary
}

// memberIssues: ctx.members is an array of preflight-shaped refs (deriveUnits());
// most call sites (research/plan/PR-body/merge prompts, result objects) only need
// the bare issue numbers. Shared here so every one of those call sites derives the
// list the same way. For a singleton, ctx.members === [self], so this is always
// [ctx.issue] — the no-group case never sees anything new here.
function memberIssues(ctx) {
  return (ctx.members || []).map(function (m) { return m.issue })
}

// batchClosesIssues (issue #30): the deduped issue numbers whose work is actually
// IN the batch branch — used to derive the batch PR's "Closes #N" lines and the
// gate/title/groups that must agree with them by construction (see the batch-PR
// block below). A result counts as shipped when:
//   - status==='completed' (this pass did the work), OR
//   - status==='skipped' AND merged_into_target===true (a PRIOR pass's per-issue
//     PR already merged into THIS run's TARGET — see the resume_point==='skip'
//     return in processIssue() above, which computes merged_into_target from the
//     structured pr_state/pr_base preflight fields, never from reason text).
// Everything else (failed/not_started/dissolved, or a skip whose PR merged into a
// DIFFERENT branch) contributes nothing. flatMaps over r.members (falling back to
// [r.issue] for a non-grouped result) so a shipped group closes every member, not
// just its primary — mirrors the inline flatMap the batch-PR prompt used to do
// itself. Pure and placed above the TICKETMILL-TEST-HARNESS-SPLIT marker so
// tests/harness.js can drive it directly.
function batchClosesIssues(results) {
  const out = []
  const seen = {}
  for (const r of results || []) {
    if (!r) continue
    const shipped = r.status === 'completed' || (r.status === 'skipped' && r.merged_into_target === true)
    if (!shipped) continue
    const members = (r.members && r.members.length) ? r.members : [r.issue]
    for (const n of members) {
      if (!seen[n]) { seen[n] = true; out.push(n) }
    }
  }
  return out
}

// resolveIssueNumbers (issue #33): normalizes args.issues into deduped positive
// integers in first-seen order. Without this, a repeated issue number (typo or a
// stale resume command passing issues:[701,701]) survives the old inline
// map(Number).filter(n>0) untouched and produces two preflights/claims/processIssue
// units racing on the same worktree/branch for the same issue. Only the explicit
// A.issues path needs this: the A.labels path lists issues via `gh issue list`,
// which cannot return the same number twice. Pure and placed above the
// TICKETMILL-TEST-HARNESS-SPLIT marker so tests/harness.js can drive it directly.
function resolveIssueNumbers(raw) {
  return [...new Set((Array.isArray(raw) ? raw : []).map(Number).filter(function (n) { return n > 0 }))]
}

// worktreeAnchor: the issue number passed to setup-worktree.sh as the physical
// worktree/branch anchor. A group's worktree/branch/PR identity is bound to its
// STABLE groupId (the lowest issue number ever proposed as a member — see
// stableGroupId()), never to the mutable logical primary (ctx.issue), because
// reconcileGroups() can re-anchor the primary onto a different live member across
// a resumed run — using ctx.issue there would spawn a second, orphaned worktree.
// groupId is itself always a real member issue number, so `gh issue view` against
// it (setup-worktree.sh's title-slug lookup) resolves exactly like any other issue.
// For a singleton, ctx.groupId is always null, so this is always ctx.issue.
function worktreeAnchor(ctx) {
  return ctx.groupId != null ? ctx.groupId : ctx.issue
}

// toGroupEntry: build one out.set() value in the shape healGroups()/reconcileGroups()
// share (groupId, primary, members, subsystem, rationale, +extra) — shared by
// proposeConsolidation()'s DRY_RUN-preview and post-challenge acceptance paths so
// the two nearly-identical object literals can't drift out of sync.
function toGroupEntry(g, extra) {
  return Object.assign({
    groupId: stableGroupId(g.members), primary: g.primary, members: g.members.slice(),
    subsystem: g.subsystem || '', rationale: g.rationale || '',
  }, extra)
}

// consolidationEnabled: profile.consolidation defaults to true (the gate runs for any
// run with >1 'implement' candidate); an explicit false disables the gate entirely —
// free, with no gate agent call at all. A single-issue run skips it for free too,
// since the gate only ever has one candidate to look at.
function consolidationEnabled(profile) {
  return !!profile && profile.consolidation !== false
}

// healGroups: reconstruct prior consolidation decisions from GitHub comment markers
// so a resumed run recognizes an existing group instead of reprocessing its members
// individually. Keyed by the STABLE groupId (never the mutable primary) so a
// re-anchor from a prior run is picked up as the same group, not treated as new.
//   preflights: this run's live preflight probes — used only to know which issue
//               numbers are in play right now; healGroups never mutates them.
//   markers: [{ issue, body }] — the single most relevant consolidation-marker
//            comment found on each candidate issue, if any (produced by the
//            Select-phase marker-fetch pass this reducer is pure of). Both a group's
//            own marker and its members' markers may appear; either alone is enough
//            to reconstruct the group (the member markers act as a fallback in case
//            the primary's own comment was never fetched or was deleted).
// Returns Map<groupId, { groupId, primary, members: [issueNumbers], subsystem, rationale }>.
function healGroups(preflights, markers) {
  const known = {}
  for (const p of preflights || []) known[p.issue] = true
  const groups = new Map()
  const memberOnly = []
  for (const rec of markers || []) {
    if (!rec || !known[rec.issue]) continue
    const g = parseConsolidationGroupComment(rec.body)
    if (g) {
      groups.set(g.groupId, { groupId: g.groupId, primary: rec.issue, members: g.members.slice(), subsystem: g.subsystem, rationale: g.rationale })
      continue
    }
    const m = parseConsolidatedMemberComment(rec.body)
    if (m) memberOnly.push({ issue: rec.issue, primary: m.primary, groupId: m.groupId })
  }
  // Fallback: reconstruct (or extend) a group from member-side markers alone, for
  // when the primary's own group-marker comment wasn't fetched or never landed.
  for (const m of memberOnly) {
    let g = groups.get(m.groupId)
    if (!g) { g = { groupId: m.groupId, primary: m.primary, members: [], subsystem: '', rationale: '' }; groups.set(m.groupId, g) }
    if (g.members.indexOf(m.issue) === -1) g.members.push(m.issue)
    if (g.members.indexOf(g.primary) === -1) g.members.push(g.primary)
  }
  return groups
}

// reconcileGroups: make LIVE claimed preflights authoritative over group membership.
// A member whose live preflight resume_point is 'skip' (already merged, closed,
// claimed by another concurrent run, ...) is excluded — it takes its own ordinary
// path (a skip singleton) instead of blocking or corrupting the group. A member
// resolved to 'implement' OR 'process_pr' stays live and IN the group: 'process_pr'
// is exactly the state every member lands in when a PRIOR run created the group's
// shared PR (one "Closes #N" per member) but crashed/failed before merging it — on
// resume, the preflight probe matches that SAME PR for every member, so the whole
// group must keep routing together as one unit (worktreeAnchor's stable groupId,
// one reviewAndMerge call on the shared PR) instead of splintering into N
// independent process_pr singletons that would each attempt to review/merge it.
// If the excluded member was the group's primary, the group re-anchors onto
// another live member (lowest issue number, for determinism) — groupId, and
// therefore the group's worktree/branch/PR identity, never moves. A group left
// with fewer than 2 live members dissolves entirely (returns no entry): its one
// remaining member, if any, falls through to deriveUnits as an ordinary
// singleton, same as if it had never been grouped.
function reconcileGroups(map, livePreflights) {
  const resumeByIssue = {}
  for (const p of livePreflights || []) resumeByIssue[p.issue] = p.resume_point
  const out = new Map()
  map.forEach(function (g, groupId) {
    const live = g.members.filter(function (n) { return resumeByIssue[n] === 'implement' || resumeByIssue[n] === 'process_pr' })
    if (live.length < 2) return // dissolved
    out.set(groupId, { groupId: groupId, primary: pickPrimary(live, g.primary), members: live, subsystem: g.subsystem, rationale: g.rationale })
  })
  return out
}

// unionField: dedupe the union of an array-valued field across a group's live
// member refs, in first-seen order. Shared by deriveUnits() below for both
// predicted_files and depends_on so a group unit sees everything its members
// individually predicted, not just the primary's own slice.
function unionField(memberRefs, field) {
  const seen = {}
  const out = []
  for (const m of memberRefs) {
    const arr = m && Array.isArray(m[field]) ? m[field] : []
    for (const v of arr) {
      const key = String(v)
      if (!seen[key]) { seen[key] = true; out.push(v) }
    }
  }
  return out
}

// deriveUnits: the final translation from "reconciled groups" + "live preflights" to
// the array runPool() actually iterates. Every reconciled group becomes ONE unit
// (a live-preflight-shaped object for the primary, with members: the live preflight
// refs of every group member, groupId, subsystem, rationale attached); every other
// live preflight becomes an ordinary singleton unit (members: [self], groupId: null)
// — the exact shape processIssue()'s ctx init below defaults to, so a no-group run
// produces units identical to today's preflights array.
// engineOwnedIntentional (issue #3) is OR-folded across a group's live memberRefs
// (.some), not just inherited from the primary — Object.assign({}, primaryRef, ...)
// below would otherwise silently carry ONLY the primary's own flag, and pickPrimary
// picks a primary for group-identity reasons entirely orthogonal to intent (lowest
// issue number / proposed primary), so a deliberate-engine member that isn't the
// primary would be invisible to any consumer reading it off the unit. A singleton
// unit needs no such fold: Object.assign({}, p, {...}) below already spreads p's
// OWN engineOwnedIntentional through untouched.
//
// predicted_files/depends_on (issue #1, lane scheduling): every preflight carries
// these two OPTIONAL arrays (normalized to [] by the probe's .then() above). A
// singleton unit carries its own straight through the Object.assign spread below
// (p.predicted_files/p.depends_on are already on p) — no extra work needed. A
// group unit's predicted_files is the union over every live member (unionField
// above); its depends_on is that same union MINUS any ref onto a fellow member of
// THIS group — that dependency is already satisfied by the merge (both issues land
// in the same unit), so keeping it would dangle a lane edge onto an issue number
// that no longer exists as its own unit once grouped.
function deriveUnits(reconciledMap, livePreflights) {
  const byIssue = {}
  for (const p of livePreflights || []) byIssue[p.issue] = p
  const consumed = {}
  const units = []
  reconciledMap.forEach(function (g) {
    const memberRefs = g.members.map(function (n) { return byIssue[n] }).filter(Boolean)
    if (memberRefs.length < 2) return // a member vanished from livePreflights entirely; treat as dissolved
    const primaryRef = byIssue[g.primary] || memberRefs[0]
    memberRefs.forEach(function (m) { consumed[m.issue] = true })
    const engineOwnedIntentional = memberRefs.some(function (m) { return m.engineOwnedIntentional })
    const memberIssueSet = {}
    memberRefs.forEach(function (m) { memberIssueSet[m.issue] = true })
    const predictedFiles = unionField(memberRefs, 'predicted_files')
    const dependsOn = unionField(memberRefs, 'depends_on').filter(function (n) { return !memberIssueSet[n] })
    units.push(Object.assign({}, primaryRef, { members: memberRefs, groupId: g.groupId, subsystem: g.subsystem, rationale: g.rationale, engineOwnedIntentional: engineOwnedIntentional, predicted_files: predictedFiles, depends_on: dependsOn }))
  })
  for (const p of (livePreflights || [])) {
    if (consumed[p.issue]) continue
    units.push(Object.assign({}, p, { members: [p], groupId: null }))
  }
  return units
}

// laneKey/sortLanesByLowestIndex: small shared helpers for the lane-scheduling
// reducers below (issue #1) and their DRY_RUN preview mirror further down. A
// lane's canonical identity for membership comparison is its sorted unit-index
// list joined into a string; its canonical display order is by lowest member
// index, ascending.
function laneKey(unitIndices) {
  return unitIndices.slice().sort(function (a, b) { return a - b }).join(',')
}
function sortLanesByLowestIndex(lanes) {
  lanes.sort(function (a, b) { return Math.min.apply(null, a.unitIndices) - Math.min.apply(null, b.unitIndices) })
  return lanes
}

// laneMemberIssues: flatten-and-dedup the member issue numbers across every unit
// in a lane, using memberIssues() so a lane's reported issue list matches the
// semantics every other member-issue call site already uses (a consolidated
// group unit contributes ALL its members, not just its primary issue). Extracted
// as a named helper — rather than inlined at its one call site (the DRY_RUN
// lanesPreviewOut composition, further down) — specifically so it sits before
// the TICKETMILL-TEST-HARNESS-SPLIT marker and is directly unit-testable; the
// lanesPreviewOut block itself lives after the split and is unreachable by
// tests/harness.js.
function laneMemberIssues(units, unitIndices) {
  return unitIndices.reduce(function (acc, i) {
    memberIssues(units[i]).forEach(function (n) { if (acc.indexOf(n) === -1) acc.push(n) })
    return acc
  }, [])
}

// computeLanes: pure reducer (issue #1, lane scheduling) that groups deriveUnits()'s
// output into lanes — sets of unit INDICES that must run serially (one worker
// draining the lane in order) instead of racing. Reuses globToRe/matchesGlobs
// (defined below; hoisted, so fine to call from here) for glob matching. Returns
// an array of { unitIndices: [index,...], predicted_files: [path,...] }, one per
// connected component, sorted by each lane's lowest unit index for determinism;
// a unit connected to nothing is its own lane of size 1 — with no overlap
// anywhere, this returns units.length singleton lanes, degenerating byte-for-byte
// to today's every-unit-races-every-unit pool.
//
// Union-find over unit indices with two edge tiers:
//   - TRUSTED (always unite, never dissolved): a serialize_globs pattern matched
//     by >=1 predicted_files path of each unit (same pattern), or a depends_on
//     reference from one unit onto another (resolved via each unit's own issue
//     plus every member's issue, so a grouped unit's members all resolve to it).
//   - HEURISTIC (unite unless suppressed by the collapse guard below): a shared
//     normalized predicted_files path between two units, or — only when no path
//     is shared — a shared basename (weaker, e.g. same filename in different
//     directories).
//
// Cohesion-aware collapse guard (NOT size-keyed — a lane's fate never depends on
// how many units or edges it has, only on overlap structure): every heuristic
// edge is graded by what the SPECIFIC PAIR it connects directly co-predicts —
// STRONG (that pair alone shares >=2 distinct paths/basenames — e.g. an
// implementation file plus its test) is self-sufficient and always survives.
// WEAK (that pair shares exactly one) only survives as part of a WEAK-EDGE-ONLY
// chain whose edges collectively touch >=2 DISTINCT keys, counted strictly from
// the weak edges' own shared keys — never inherited from a neighboring strong
// cluster's unrelated paths. That scoping is what stops a single popular path
// (a magnet) from dragging a unit that touches only it into a lane that is
// cohesive for entirely unrelated reasons: a unit sharing only a magnet path
// with one member of a genuine 2-path cluster must not serialize with the whole
// cluster just because that cluster happens to pass the >=2 bar on its own.
// A weak chain that never reaches 2 distinct keys is a single-path promiscuous
// connector — the shape a magnet file produces (many otherwise unrelated units
// all touching one popular path) — and dissolves back to trusted-only, i.e.
// those units race instead of serializing. Trusted edges are never touched by
// this guard.
//
// DF (document-frequency) signal: advisory/metric-only, logged when a predicted
// path is matched by more than half the batch (min 3 units) — surfaced for human
// visibility but NEVER used to drop an intersection key or suppress an edge; that
// job belongs solely to the collapse guard above. serialize_globs paths are never
// counted toward DF (they're a deliberate trusted signal, not a magnet).
//
// opts.trustedOnly (issue #1, lane scheduling — used by the real-run collapse
// guard right before runPool() drains, workflows below the harness split): skips
// the DF log and the whole heuristic-edge/collapse-guard section, unioning ONLY
// serialize_globs + depends_on. Lets the drive code ask "which of the lanes I
// already computed would exist on trusted edges ALONE?" without re-deriving that
// graph by hand — a lane whose membership is identical trustedOnly is provably
// never touched by a heuristic edge and must never be dissolved.
function computeLanes(units, serializeGlobs, opts) {
  const trustedOnly = !!(opts && opts.trustedOnly)
  const n = (units || []).length
  function find(p, x) { while (p[x] !== x) { p[x] = p[p[x]]; x = p[x] } return x }
  function union(p, a, b) { const ra = find(p, a); const rb = find(p, b); if (ra !== rb) p[ra] = rb }

  function normalizePath(f) { return String(f).trim().replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/{2,}/g, '/') }
  function basenameOf(f) { const parts = normalizePath(f).split('/'); return parts[parts.length - 1] }

  const predictedSets = units.map(function (u) {
    const s = {}
    for (const f of (Array.isArray(u && u.predicted_files) ? u.predicted_files : [])) s[normalizePath(f)] = true
    return s
  })
  const basenameSets = units.map(function (u) {
    const s = {}
    for (const f of (Array.isArray(u && u.predicted_files) ? u.predicted_files : [])) s[basenameOf(f)] = true
    return s
  })
  // every issue number that resolves to this unit index — its own, plus every
  // live member's (a group unit's members all point back to the one group unit).
  const issueToIndex = {}
  units.forEach(function (u, idx) {
    if (u && u.issue != null) issueToIndex[u.issue] = idx
    for (const m of (Array.isArray(u && u.members) ? u.members : [])) {
      if (m && m.issue != null) issueToIndex[m.issue] = idx
    }
  })

  const parent = []
  for (let i = 0; i < n; i++) parent[i] = i

  // ---- trusted: serialize_globs (unite every unit whose predicted_files hits
  // the same pattern) ----
  const globs = Array.isArray(serializeGlobs) ? serializeGlobs.filter(function (g) { return typeof g === 'string' && g.length > 0 }) : []
  for (const g of globs) {
    let first = -1
    for (let i = 0; i < n; i++) {
      const hit = Object.keys(predictedSets[i]).some(function (p) { return matchesGlobs(p, [g]) })
      if (!hit) continue
      if (first === -1) first = i
      else union(parent, first, i)
    }
  }

  // ---- trusted: depends_on ----
  for (let i = 0; i < n; i++) {
    for (const dep of (Array.isArray(units[i].depends_on) ? units[i].depends_on : [])) {
      const j = issueToIndex[dep]
      if (j != null && j !== i) union(parent, i, j)
    }
  }

  // ---- DF signal + heuristic edges + collapse guard: entirely skipped in
  // trustedOnly mode — the caller wants ONLY the serialize_globs/depends_on
  // union above, with no heuristic edge (and therefore no DF log / dissolve log
  // noise) considered at all. ----
  if (!trustedOnly) {
    // ---- DF signal: advisory/metric-only, logged, never used to drop keys ----
    const isSerializeGlobPath = function (p) { return globs.some(function (g) { return matchesGlobs(p, [g]) }) }
    const dfCount = {}
    for (let i = 0; i < n; i++) {
      for (const p of Object.keys(predictedSets[i])) {
        if (isSerializeGlobPath(p)) continue // serialize_globs never counted
        dfCount[p] = (dfCount[p] || 0) + 1
      }
    }
    const magnets = Object.keys(dfCount).filter(function (p) { return dfCount[p] >= 3 && dfCount[p] > n / 2 })
    if (magnets.length) {
      log('computeLanes: DF magnet signal (advisory only — intersection keys NOT dropped): ' +
        magnets.map(function (p) { return p + ' (' + dfCount[p] + '/' + n + ')' }).join(', '))
    }

    // ---- heuristic candidate edges: full-path intersection, else basename ----
    const heuristicEdges = []
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        let shared = Object.keys(predictedSets[i]).filter(function (p) { return predictedSets[j][p] })
        if (!shared.length) shared = Object.keys(basenameSets[i]).filter(function (b) { return basenameSets[j][b] })
        if (shared.length) heuristicEdges.push({ i: i, j: j, shared: shared })
      }
    }

    // ---- cohesion-aware collapse guard: strong edges are self-sufficient; weak
    // edges only survive as a weak-only chain that reaches 2 distinct keys on its
    // own (see docstring above) ----
    const strongEdges = heuristicEdges.filter(function (e) { return e.shared.length >= 2 })
    const weakEdges = heuristicEdges.filter(function (e) { return e.shared.length === 1 })

    for (const e of strongEdges) union(parent, e.i, e.j)

    const weakParent = []
    for (let i = 0; i < n; i++) weakParent[i] = i
    for (const e of weakEdges) union(weakParent, e.i, e.j)

    const weakKeysByRoot = {} // weak-only root -> set of distinct shared keys among its weak edges
    for (const e of weakEdges) {
      const r = find(weakParent, e.i)
      if (!weakKeysByRoot[r]) weakKeysByRoot[r] = {}
      weakKeysByRoot[r][e.shared[0]] = true
    }

    for (const e of weakEdges) {
      const r = find(weakParent, e.i)
      if (Object.keys(weakKeysByRoot[r]).length >= 2) union(parent, e.i, e.j) // exempt: weak chain reaches 2 distinct keys on its own
      // else: single-path promiscuous connector — left dissolved, those units race
    }

    const dissolvedRoots = Object.keys(weakKeysByRoot).filter(function (r) { return Object.keys(weakKeysByRoot[r]).length < 2 })
    if (dissolvedRoots.length) {
      log('computeLanes: collapse guard dissolved ' + dissolvedRoots.length +
        ' heuristic lane(s) — single-path promiscuous connector(s) with < 2 co-predicted paths; racing instead of serializing')
    }
  }

  // ---- materialize final lanes, bounding predicted-set growth per lane ----
  const groupsByRoot = {}
  for (let i = 0; i < n; i++) {
    const r = find(parent, i)
    if (!groupsByRoot[r]) groupsByRoot[r] = []
    groupsByRoot[r].push(i)
  }
  const lanes = Object.keys(groupsByRoot).map(function (r) {
    const unitIndices = groupsByRoot[r]
    const predicted = []
    const seen = {}
    for (const idx of unitIndices) {
      if (predicted.length >= MAX_LANE_PREDICTED_FILES) break
      for (const p of Object.keys(predictedSets[idx])) {
        if (seen[p]) continue
        if (predicted.length >= MAX_LANE_PREDICTED_FILES) break
        seen[p] = true
        predicted.push(p)
      }
    }
    return { unitIndices: unitIndices, predicted_files: predicted }
  })
  return sortLanesByLowestIndex(lanes)
}

// applyRealRunCollapseGuard: pure reducer (issue #1, lane scheduling) — a final,
// run-time safety net called immediately before runPool()'s real drain (dry-run
// separately previews lanes read-only, before claims settle — see the DRY_RUN
// block). computeLanes() already guards its OWN edges locally/per-chain (see its
// module comment) — this is coarser and whole-batch scoped, for a shape its local
// view can't see: a long chain of pairwise-weak edges, each sharing a DIFFERENT
// path with its neighbor, can reach computeLanes()'s own ">=2 distinct keys" bar
// in aggregate without the lane, taken as a whole, actually cohering around
// anything. Only recomputes anything when collapse_ratio (effective lane
// concurrency over what a flat pool would've given) < 0.5 AND there was enough
// work to want that concurrency in the first place (unitCount >= concurrency) —
// with too little work, `lanes` passes through completely untouched.
//
// Mirrors computeLanes()'s discriminator one level up (whole lanes, not edges): a
// lane whose membership is IDENTICAL to recomputing computeLanes() with heuristic
// edges disabled (serialize_globs + depends_on only, via { trustedOnly: true }) is
// TRUSTED and is always kept, no matter its size. Any other multi-unit lane is
// HEURISTIC; it survives only if its units, taken as a whole, actually co-predict
// >= 2 distinct paths (a genuinely cohesive cluster) — otherwise it's a
// single-path magnet connector computeLanes()'s local/chained view let slip
// through in aggregate, and is dissolved back into one singleton lane per unit
// (those units then race instead of serializing).
//
// Returns { lanes, dissolvedCount, collapseRatio } so the caller can log/branch
// without duplicating the ratio math; `lanes` is the SAME array reference when
// dissolvedCount is 0 (no-op fast path).
function applyRealRunCollapseGuard(units, lanes, concurrency, serializeGlobs) {
  const n = (units || []).length
  const flatConcurrency = Math.min(concurrency, n)
  const effectiveConcurrency = Math.min(concurrency, (lanes || []).length)
  const collapseRatio = flatConcurrency ? effectiveConcurrency / flatConcurrency : 1
  if (n < concurrency || collapseRatio >= 0.5) return { lanes: lanes, dissolvedCount: 0, collapseRatio: collapseRatio }

  const trustedLanes = computeLanes(units, serializeGlobs, { trustedOnly: true })
  const trustedKeys = {}
  trustedLanes.forEach(function (l) {
    trustedKeys[laneKey(l.unitIndices)] = true
  })
  let dissolvedCount = 0
  const nextLanes = []
  lanes.forEach(function (lane) {
    if (lane.unitIndices.length < 2) { nextLanes.push(lane); return } // already a singleton
    if (trustedKeys[laneKey(lane.unitIndices)]) { nextLanes.push(lane); return } // trusted — always kept
    // heuristic lane: whole-lane cohesion — a path present in >= 2 of the lane's
    // OWN units, counted fresh here (not inherited from computeLanes()'s
    // per-chain scoping, which is exactly the gap this guard exists to catch).
    const pathCounts = {}
    lane.unitIndices.forEach(function (i) {
      const seen = {}
      for (const p of (Array.isArray(units[i].predicted_files) ? units[i].predicted_files : [])) {
        const norm = String(p).trim().replace(/\\/g, '/').replace(/^\.\//, '')
        if (seen[norm]) continue
        seen[norm] = true
        pathCounts[norm] = (pathCounts[norm] || 0) + 1
      }
    })
    const sharedPaths = Object.keys(pathCounts).filter(function (p) { return pathCounts[p] >= 2 }).length
    if (sharedPaths >= 2) { nextLanes.push(lane); return } // cohesive cluster — exempt
    dissolvedCount++
    lane.unitIndices.forEach(function (i) {
      nextLanes.push({ unitIndices: [i], predicted_files: (units[i].predicted_files || []).slice() })
    })
  })
  if (!dissolvedCount) return { lanes: lanes, dissolvedCount: 0, collapseRatio: collapseRatio }
  return { lanes: sortLanesByLowestIndex(nextLanes), dissolvedCount: dissolvedCount, collapseRatio: collapseRatio }
}

// ----- batch state -----
const STOP = { tripped: false, reason: '' }
const BATCH = { failures: 0, consecutiveDeaths: 0 }
// STAGE_TOKENS: region-boundary token buckets for Select-phase orchestration
// spend that has no per-issue ctx to attribute to (see aggregateTokens' byStage
// param above). Populated by addStage() (below, near spentTokens()) bracketing
// four run-body regions — never inside runPool(), the only concurrent region,
// so every addStage() delta is exact regardless of CONCURRENCY. Plain literal,
// sandbox-safe (mirrors STOP/BATCH here, not a class).
const STAGE_TOKENS = { preflight: 0, select: 0 }
let LEARN = null // category digests distilled from process-retrospective.md (Select phase)

function tripStop(reason) {
  if (!STOP.tripped) { STOP.tripped = true; STOP.reason = reason; log('STOP: ' + reason) }
}

// isBudgetExhaustedError: only a real budget/token-exhaustion signature is
// fatal for the whole run (tripStop), not a per-attempt death — shared by
// stage() and consolidationAgent() so the two call sites can't drift on what
// counts as one. Requires a budget/token/ceiling NOUN to co-occur with an
// exhaust/exceed/deplete/ran-out/overrun-shaped/limit-reached VERB; either
// alone is not enough, so a target repo's own domain error that merely names
// "budget" (no exhaustion verb) or merely exceeds something unrelated (no
// budget noun) is left to the ordinary per-attempt retry + recordAgentDeath()
// path instead of halting the whole run. The "over" family is deliberately
// anchored to overrun-shaped phrasing (overrun/overage/went over/ran over/
// over budget/over the limit) rather than the bare word "over", which shows
// up in ordinary prose ("budget review is over") without meaning exhaustion.
function isBudgetExhaustedError(msg) {
  const hasBudgetNoun = /\b(?:budget|token|ceiling)\b/i.test(msg)
  const hasExhaustionVerb = /\b(?:exhaust(?:ed|ion|s)?|exceed(?:ed|s|ing)?|deplete(?:d|s)?|ran\s+out|over[\s-]?(?:run|age)\b|went\s+over|ran\s+over|over\s+budget|over\s+the\s+limit|limit[\s-]?reached)\b/i.test(msg)
  if (!hasBudgetNoun || !hasExhaustionVerb) return false
  tripStop('token budget exhausted (' + msg + ')')
  return true
}

// recordAgentDeath: shared BATCH.consecutiveDeaths bookkeeping for stage() and
// consolidationAgent() — trips STOP after MAX_CONSECUTIVE_AGENT_DEATHS in a row,
// on the theory that repeated deaths mean a usage limit or API outage rather
// than a one-off flake.
function recordAgentDeath() {
  BATCH.consecutiveDeaths++
  if (BATCH.consecutiveDeaths >= MAX_CONSECUTIVE_AGENT_DEATHS) {
    tripStop(MAX_CONSECUTIVE_AGENT_DEATHS + ' consecutive agent deaths — likely usage limit or API outage. Resume later with the same args (preflight will skip finished work) or resumeFromRunId.')
  }
}

// True only for values safe to do arithmetic on (excludes NaN/Infinity/non-numbers).
function isFiniteNumber(v) {
  return typeof v === 'number' && isFinite(v)
}

// Guarded wrapper over the runtime's budget.spent() (cumulative output tokens
// for the whole run, monotonic). Never throws; returns a finite Number or null
// when the runtime hook is unavailable or reports something non-numeric, so
// callers can render "not tracked" instead of a false zero.
function spentTokens() {
  try {
    if (typeof budget === 'undefined' || !budget || typeof budget.spent !== 'function') return null
    const v = budget.spent()
    return isFiniteNumber(v) ? v : null
  } catch (e) {
    return null
  }
}

// addStage: DRY region-boundary bracketing helper for STAGE_TOKENS (above).
// Callers sample `before = spentTokens()` immediately before a sequential
// run-body region, then call addStage(bucket, before) immediately after —
// this reads `after = spentTokens()` and accumulates a guarded
// Math.max(0, after - before) into STAGE_TOKENS[bucket]. Isolated in its own
// try/catch, mirroring stage()'s finally block below, so a tracking failure
// (e.g. budget.spent() misbehaving) can never affect run-body control flow.
// Exact regardless of CONCURRENCY as long as the bracketed region itself never
// overlaps runPool() (the only concurrent region) — every call site below is
// sequential, strictly before runPool() drains.
function addStage(bucket, before) {
  try {
    const after = spentTokens()
    if (isFiniteNumber(before) && isFiniteNumber(after)) {
      STAGE_TOKENS[bucket] += Math.max(0, after - before)
    }
  } catch (e) {
    // never let tracking failures affect run-body control flow
  }
}

// stage(): one agent call with retry, journal-unique prompts, death accounting.
// Returns the validated object, or null after STAGE_TRIES attempts.
// Every prompt carries a scope guard: at concurrency N, agents from different
// per-issue pipelines run side by side; the guard pins gh targets to this ctx's
// issue and stamps every posted comment with a machine-checkable marker that
// the contrarian gates use to detect and delete misfiled comments.
//
// A consolidation GROUP unit's stages legitimately need to post to / edit every
// member issue (postNote's per-member halt note, the merge stage's per-member
// claim release, ...) — a single-issue guard would flatly forbid that ("NEVER
// post to them") and contradict every group-aware prompt built above. So the
// guard widens its in-scope set to every ctx.members issue for a group unit,
// while keeping the singleton branch byte-for-byte identical to before.
function scopeGuard(ctx) {
  const isGroup = ctx.members && ctx.members.length > 1
  const memberNums = isGroup ? memberIssues(ctx) : [ctx.issue]
  const lines = isGroup
    ? [
        '## Scope guard (ticketmill)',
        'You are working EXCLUSIVELY on consolidation group ' + ctx.groupId + ' of ' + REPO + (ctx.pr ? ' (PR #' + ctx.pr + ')' : '') +
        ', covering member issues: ' + fmtIssues(memberNums) + '.',
        'Every gh issue comment / gh pr comment / gh issue edit command MUST target one of these member issues (' +
        fmtIssues(memberNums) + ')' + (ctx.pr ? ' or PR #' + ctx.pr : '') + ' exactly — re-read the number in the command line before running it.',
        'Other issue/PR numbers appearing in context, handoff notes, or learnings belong to concurrent pipelines;',
        'NEVER post to them.',
        'End every comment you post on a member issue with THAT issue\'s own marker line: <!-- ticketmill ' + REPO + '#<that member\'s number> -->.',
      ]
    : [
        '## Scope guard (ticketmill)',
        'You are working EXCLUSIVELY on issue #' + ctx.issue + ' of ' + REPO + (ctx.pr ? ' (PR #' + ctx.pr + ')' : '') + '.',
        'Every gh issue comment / gh pr comment / gh issue edit command MUST target issue #' + ctx.issue +
        (ctx.pr ? ' or PR #' + ctx.pr : '') + ' exactly — re-read the number in the command line before running it.',
        'Other issue/PR numbers appearing in context, handoff notes, or learnings belong to concurrent pipelines;',
        'NEVER post to them.',
        'End every comment body you post with this exact marker line: <!-- ticketmill ' + REPO + '#' + ctx.issue + ' -->',
      ]
  if (BROWSER) {
    lines.push('The shared verification browser is lock-guarded (' + bwLock() + '): only use it if your prompt includes the')
    lines.push('"live browser feedback" protocol block — without that block, do NOT open the browser.')
  }
  // Engine-owned advisory clause (issue #3): a deterministic post-implement
  // gate (runEngineOwnedGate, before the test loop) is the real backstop —
  // this is only defense-in-depth, so it is unconditional (prepended to
  // EVERY stage prompt, not gated on isGroup/BROWSER) and stays generic
  // rather than naming ctx.engineOwnedIntentional: an agent mid-stage has no
  // reliable way to know which regime it is in, so the instruction must hold
  // for both — never touch these paths without being told to.
  if (ENGINE_OWNED.length) {
    lines.push('Engine-owned paths (' + ENGINE_OWNED.join(', ') + ') are OUT OF SCOPE unless this issue explicitly targets one of')
    lines.push('them: do not stage, commit, or restore them from git history for any other reason (including "reconciling" a')
    lines.push('diff or an apparently stale file) — leave them exactly as you found them and surface the discrepancy as a')
    lines.push('deferred note instead.')
  }
  return lines.join('\n')
}
async function stage(ctx, key, prompt, opts, schema, tries) {
  const n = tries || STAGE_TRIES
  const guarded = scopeGuard(ctx) + '\n\n' + prompt
  const tokensBefore = spentTokens()
  try {
    for (let attempt = 1; attempt <= n; attempt++) {
      if (STOP.tripped) return null
      const p = attempt === 1 ? guarded : guarded +
        '\n\n(RETRY attempt ' + attempt + ': a previous attempt failed or died mid-flight. ' +
        'Re-check current state before acting — work may be partially done. Make every action idempotent.)'
      let r = null
      try {
        r = await agent(p, Object.assign({ label: ctx.issue + ':' + key, phase: 'Issue #' + ctx.issue, schema: schema }, opts))
      } catch (e) {
        const msg = String((e && e.message) || e)
        if (isBudgetExhaustedError(msg)) return null
        log('#' + ctx.issue + ' ' + key + ' attempt ' + attempt + ' threw: ' + msg)
      }
      if (r) { BATCH.consecutiveDeaths = 0; return r }
      log('#' + ctx.issue + ' ' + key + ' attempt ' + attempt + ' returned null' + (attempt < n ? ' — retrying' : ''))
    }
    recordAgentDeath()
    return null
  } finally {
    // Token attribution is instrumentation only — isolated in its own try/catch so
    // a tracking failure (e.g. budget.spent() misbehaving) can never alter the
    // STOP/retry/return control flow above. Sampled around the whole retry loop
    // (not per-attempt) so retries and STOP/budget-exhaust early returns all
    // accumulate into one delta; opts.model is stable across attempts.
    try {
      const tokensAfter = spentTokens()
      if (isFiniteNumber(tokensBefore) && isFiniteNumber(tokensAfter) && ctx && ctx.tokens) {
        const delta = Math.max(0, tokensAfter - tokensBefore)
        ctx.tokens.total += delta
        const model = opts && opts.model
        if (model) ctx.tokens.byModel[model] = (ctx.tokens.byModel[model] || 0) + delta
        ctx.tokens.tracked = true
      }
    } catch (e) {
      // never let tracking failures affect stage() control flow
    }
  }
}

// ----- decision chain -----
// Records are stamped with their issue number ({issue, entry}); decisionChain()
// drops any record whose stamp doesn't match the ctx it renders for, making
// cross-pipeline contamination a mechanical rejection instead of a judgment call.
function pushDecision(ctx, title, body) {
  const b = String(body || '').slice(0, 1500)
  ctx.decisions.push({ issue: ctx.issue, entry: '### [#' + ctx.issue + '] ' + title + '\n' + b })
}
function decisionChain(ctx) {
  const d = []
  for (const r of ctx.decisions) {
    if (r && r.issue === ctx.issue && r.entry) { d.push(r.entry); continue }
    log('#' + ctx.issue + ' decision-chain: DROPPED foreign/unstamped record: ' + String((r && r.entry) || r).slice(0, 100))
  }
  if (!d.length) return '(none yet)'
  // keep the foundation (research/evaluate/plan) plus the most recent entries, bounded
  let picked = d
  if (d.length > 12) picked = d.slice(0, 4).concat(['…(' + (d.length - 10) + ' earlier entries elided)…']).concat(d.slice(-6))
  let out = picked.join('\n\n')
  if (out.length > 14000) out = out.slice(0, 14000) + '\n…(truncated)'
  return out
}

// ----- learnings injection (cross-RUN context: retro file -> stage prompts) -----
function learn(cat) {
  if (!LEARN) return ''
  const t = LEARN[cat]
  return t ? '## Prior-run learnings — ' + cat + '\n' + String(t).slice(0, 900) : ''
}

// ----- settled-decisions ledger -----
// Decisions adjudicated at a contrarian gate travel to later gates with a "new
// evidence required to re-open" contract — otherwise fresh contrarians see only
// digests, nothing marks a trade-off as adjudicated, and gates oscillate.
function settleDecision(ctx, topic, gate, decision, why, rejected) {
  ctx.settled.push({
    topic: topic, gate: gate,
    decision: String(decision || '').slice(0, 400),
    why: String(why || '').slice(0, 300),
    rejected: (rejected || []).slice(0, 4).map(function (r) { return String(r).slice(0, 160) }),
  })
}
function settledBlock(ctx) {
  if (!ctx.settled.length) return ''
  return [
    '## Adjudicated decisions (settled at earlier gates; later entries supersede on conflict)',
    ctx.settled.slice(-6).map(function (s) {
      return '- [' + s.gate + '] ' + s.topic + ': ' + s.decision +
        (s.why ? '\n  Why: ' + s.why : '') +
        (s.rejected.length ? '\n  Rejected alternatives: ' + s.rejected.join('; ') : '')
    }).join('\n'),
    'Re-open a settled decision ONLY with concrete evidence not considered at adjudication, and cite that',
    'evidence explicitly. Re-litigating a settled decision without new evidence is itself a process failure.',
  ].join('\n')
}

// ----- handoff notes (agent -> future-agent context, 3-4 stages downstream) -----
const HANDOFF_ASK = 'If you discovered environment quirks, workarounds, or gotchas that later agents will need ' +
  '(test/env setup, shifted line numbers after deletes, tooling oddities), also return notes_for_downstream ' +
  '(1-3 short strings); otherwise return it empty.'

// ----- commit SHA integrity (retro found agents twice typing a fabricated/shortened SHA into a posted comment instead of reading the real one, requiring a fixup edit) -----
const COMMIT_SHA_ASK = 'Get the exact commit SHA by running: git -C <worktree> log -1 --format=%H — it prints the ' +
  'full 40-character SHA. Paste that literal command output verbatim in the comment. Never type, shorten, guess, ' +
  'or recall a SHA from memory.'
function collectNotes(ctx, from, r) {
  const arr = (r && r.notes_for_downstream) || []
  for (const n of arr) {
    const s = String(n || '').trim()
    if (s) ctx.notes.push('[' + from + '] ' + s.slice(0, 300))
  }
  if (ctx.notes.length > 12) ctx.notes = ctx.notes.slice(-12)
}
function notesBlock(ctx) {
  if (!ctx.notes.length) return ''
  return '## Handoff notes from earlier agents in this run\n' + ctx.notes.map(function (n) { return '- ' + n }).join('\n')
}
function verifyNotesBlock() {
  const vn = (PROFILE.verify_notes || [])
  if (!vn.length) return ''
  return '## Project verification notes (from the ticketmill profile)\n' + vn.map(function (n) { return '- ' + n }).join('\n')
}

// Compact intent context for fix stages — they otherwise see only reviewer comments
// or failure lists and optimize for "make the complaint go away" over the issue goal.
function fixContext(ctx, taskDesc) {
  return [
    '## Context',
    'Issue #' + ctx.issue + ': ' + (ctx.title || ''),
    ctx.approach ? 'Approach: ' + String(ctx.approach).slice(0, 300) : '',
    taskDesc ? 'Task: ' + String(taskDesc).slice(0, 300) : '',
    notesBlock(ctx),
  ].filter(Boolean).join('\n')
}

// Gate-by-gate decision titles (with a verdict snippet) — cheap narrative for the
// report + retro, which otherwise reconstruct iteration behavior from git archaeology.
function timeline(ctx) {
  return (ctx.decisions || []).map(function (d) {
    const lines = String((d && d.entry) || d).split('\n')
    const title = lines[0].replace(/^#+\s*/, '').replace(/^\[#\d+\]\s*/, '')
    const body = (lines[1] || '').replace(/\*\*/g, '').slice(0, 120)
    return body ? title + ' — ' + body : title
  })
}

// Display labels for aggregateTokens' 4th (byStage) param's known keys — the
// STAGE_TOKENS region-boundary buckets (preflight/select-phase orchestration
// spend, sampled outside the per-issue pool — see STAGE_TOKENS). An unknown
// key still renders (key + ' (orchestration)'), so a future bucket doesn't
// silently vanish from the table just because this map wasn't updated.
const STAGE_LABELS = { preflight: 'preflight (orchestration)', select: 'select-phase (orchestration)' }

// Pure aggregation of per-issue/per-stage token deltas into per-issue,
// per-model, and per-stage subtotals, plus a finished markdown "## Token
// Usage" section — all math done here in JS, never delegated to an LLM.
// Takes no globals; harness-testable in isolation.
//   results      - the run's per-issue result array. Entries lacking a `.tokens`
//                  field entirely (skipped/not_started — never got a ctx) or
//                  carrying `.tokens.tracked === false` (ctx existed but no stage
//                  ever sampled a usable budget.spent() pair) both render
//                  "not tracked", never a false zero.
//   spent        - the guarded, run-wide budget.spent() total (Number or null).
//   concurrency  - CONCURRENCY. Only per-issue rows are affected by it:
//     === 1: per-issue stage deltas cannot overlap, so they're an exact
//       partition of that portion of the run (reconciles: true, given spent
//       and some tracked data).
//     > 1: multiple issues' stages run side by side against ONE shared
//       monotonic counter — agent() returns schema content only, never a
//       per-call usage figure, so there is no way to split budget.spent()'s
//       movement between concurrent callers. Overlapping stages each see (and
//       get attributed) the same movement, so per-issue deltas over-count and
//       the whole breakdown is labelled approximate (reconciles: false).
//   byStage      - optional (normalizes to {}, so existing 3-arg callers are
//                  unaffected): a flat { preflight, select, ... } map of
//                  region-bracketed orchestration spend sampled OUTSIDE the
//                  concurrent per-issue pool (see STAGE_TOKENS), so it's exact
//                  regardless of `concurrency`. Every nonzero bucket folds
//                  into sumDeltas exactly once and renders as its own labeled
//                  row (STAGE_LABELS) — never absorbed silently into the
//                  remainder below, and never double-counted by it. A run
//                  where every per-issue result is untracked but the stage
//                  buckets are populated (e.g. a resumed run) still counts as
//                  "tracked" and still renders a breakdown, via anyStage.
// remainder (whatever budget.spent() counted that no per-issue row or stage
// bucket attributed — max(0, spent - sumDeltas)) is computed and rendered as
// its own "orchestration/unattributed" row whenever `spent` is available,
// regardless of concurrency/reconciles — including the approximate
// concurrency>1 case, so that spend is never left implicit — since the stage
// buckets are already folded into sumDeltas, it is never double-counted.
function aggregateTokens(results, spent, concurrency, byStage) {
  const list = results || []
  const stages = byStage || {}
  const byIssue = []
  const byModel = {}
  let sumDeltas = 0
  let anyTracked = false

  for (const r of list) {
    const t = r && r.tokens
    if (t && t.tracked) {
      anyTracked = true
      const total = t.total || 0
      sumDeltas += total
      byIssue.push({ issue: r.issue, total: total, by_model: Object.assign({}, t.byModel || {}), tracked: true })
      const models = t.byModel || {}
      for (const m in models) {
        if (Object.prototype.hasOwnProperty.call(models, m)) byModel[m] = (byModel[m] || 0) + models[m]
      }
    } else {
      byIssue.push({ issue: r && r.issue, total: null, by_model: {}, tracked: false })
    }
  }

  // Stage buckets fold into sumDeltas exactly once (below) so the remainder
  // row never double-counts them; zero-valued buckets are kept in by_stage
  // (the returned JSON) but omitted from the rendered table rows.
  const byStageOut = {}
  const stageRows = []
  for (const key in stages) {
    if (!Object.prototype.hasOwnProperty.call(stages, key)) continue
    const v = stages[key] || 0
    byStageOut[key] = v
    if (v) {
      sumDeltas += v
      stageRows.push({ label: STAGE_LABELS[key] || (key + ' (orchestration)'), total: v })
    }
  }
  const anyStage = stageRows.length > 0

  const hasSpent = isFiniteNumber(spent)
  // run_total must agree with the markdown's "Run total" line, which only ever
  // renders the guarded budget.spent() figure or "not tracked" — never a
  // sumDeltas fallback (see CHANGELOG for the Quality Review finding this fixes).
  const runTotal = hasSpent ? spent : null
  const trackedAny = anyTracked || anyStage
  const tracked = trackedAny || hasSpent
  const reconciles = concurrency === 1 && hasSpent && trackedAny
  const remainder = hasSpent ? Math.max(0, spent - sumDeltas) : null
  const models = Object.keys(byModel).sort()

  const lines = []
  lines.push('## Token Usage')
  lines.push('')
  lines.push(hasSpent
    ? 'Run total (output tokens, via budget.spent()): **' + spent + '**'
    : 'Run total: not tracked (budget.spent() unavailable this run)')
  lines.push('')

  if (!tracked) {
    lines.push('Per-issue / per-model breakdown: not tracked (no stage in this run reported a usable token delta).')
  } else {
    if (!trackedAny) {
      // hasSpent is true here (tracked === trackedAny || hasSpent, trackedAny is
      // false) but no per-issue row or stage bucket attributed any of it — the
      // degenerate case this fix closes. Still render the table (all rows "not
      // tracked") so the remainder row below carries the full run total instead
      // of it vanishing into a "not tracked" line that contradicts "Run total: N".
      lines.push('_no per-issue or stage data attributed any spend this run — the "orchestration/unattributed" row ' +
        'below carries the full run total instead of leaving it implicit._')
    } else if (concurrency > 1) {
      lines.push('_approximate - overlapping concurrent stages over-count and do NOT reconcile to the run total._')
      lines.push('(A single shared monotonic counter cannot be split per concurrent call — agent() returns schema ' +
        'content only, no per-call usage — so simultaneous issues each see the same counter movement. The stage ' +
        'rows below are exact even so — they are sampled outside the concurrent per-issue pool — only the ' +
        'per-issue rows above them over-count.)')
    } else if (reconciles) {
      lines.push('_Reconciles exactly to the run total above — the "orchestration/unattributed" row below absorbs ' +
        'whatever budget.spent() counted that no stage attributed._')
    } else {
      lines.push('_approximate — the run total above (budget.spent()) is unavailable this run, so this breakdown ' +
        'cannot be checked against it._')
    }
    lines.push('')
    const header = ['Issue'].concat(models).concat(['Subtotal'])
    lines.push('| ' + header.join(' | ') + ' |')
    lines.push('|' + header.map(function () { return ' --- ' }).join('|') + '|')
    for (const row of byIssue) {
      const cells = ['#' + row.issue].concat(models.map(function (m) {
        return row.tracked ? String(row.by_model[m] || 0) : 'not tracked'
      }))
      cells.push(row.tracked ? String(row.total) : 'not tracked')
      lines.push('| ' + cells.join(' | ') + ' |')
    }
    for (const sr of stageRows) {
      const cells = [sr.label].concat(models.map(function () { return '' })).concat([String(sr.total)])
      lines.push('| ' + cells.join(' | ') + ' |')
    }
    if (hasSpent) {
      const remCells = ['orchestration/unattributed'].concat(models.map(function () { return '' })).concat([String(remainder)])
      lines.push('| ' + remCells.join(' | ') + ' |')
    }
    const totalCells = ['**Total**'].concat(models.map(function (m) { return '**' + byModel[m] + '**' }))
    totalCells.push('**' + (hasSpent ? spent : sumDeltas) + '**')
    lines.push('| ' + totalCells.join(' | ') + ' |')
  }

  return {
    run_total: runTotal,
    by_issue: byIssue,
    by_model: byModel,
    by_stage: byStageOut,
    remainder: remainder,
    tracked: tracked,
    reconciles: reconciles,
    markdown: lines.join('\n'),
  }
}

// aggregateMergeAutoResolve: JS-computed run-level rollup of runMergeAutoResolve
// activity (see that function) — no LLM math, injected verbatim below, same
// pattern as aggregateTokens above. Reads ctx.metrics.merge_auto_resolved /
// merge_thrash off EVERY result (fail() carries ctx.metrics through too, so a
// thrash-escalated needs_human result is counted here even though it never
// reached 'completed'). resolved_count only ever reflects issues that actually
// MERGED after auto-resolve (see runMergeAutoResolve's own doc comment on why
// the metric bumps post-merge, not post-rebase) — thrash_count is a distinct,
// non-overlapping bucket: an issue that thrashed escalated to needs_human and
// therefore never also incremented merge_auto_resolved.
function aggregateMergeAutoResolve(results) {
  const list = results || []
  const resolvedIssues = []
  const thrashIssues = []
  for (const r of list) {
    const m = r && r.metrics
    if (m && m.merge_auto_resolved) resolvedIssues.push(r.issue)
    if (m && m.merge_thrash) thrashIssues.push(r.issue)
  }
  const lines = []
  lines.push('## Merge Auto-Resolution')
  lines.push('')
  if (!resolvedIssues.length && !thrashIssues.length) {
    lines.push('No CONFLICTING PRs this run — nothing to auto-resolve.')
  } else {
    lines.push(resolvedIssues.length
      ? resolvedIssues.length + ' issue(s) auto-resolved: CONFLICTING after review, rebased onto the batch branch, ' +
        're-tested green, force-pushed, then merged — ' + fmtIssues(resolvedIssues) + '.'
      : '0 issue(s) auto-resolved this run.')
    if (thrashIssues.length) {
      lines.push('')
      lines.push(thrashIssues.length + ' issue(s) hit the thrash guard (batch branch moved again while the mandatory ' +
        're-test ran) and escalated to needs_human instead of a silent re-rebase — ' + fmtIssues(thrashIssues) + '.')
    }
  }
  return {
    resolved_count: resolvedIssues.length,
    resolved_issues: resolvedIssues,
    thrash_count: thrashIssues.length,
    thrash_issues: thrashIssues,
    markdown: lines.join('\n'),
  }
}

// Best-effort halt note on the issue so humans can triage from GitHub alone. For a
// consolidation group (ctx.members.length > 1), the SAME halt fires the same note
// on EVERY member issue — not just the primary — naming the group so a human
// reading any one member's trail knows the whole unit halted together, and
// releases every member's claim so a resumed run can re-pick up the group. The
// singleton branch below is byte-for-byte the original single-issue prompt.
async function postNote(ctx, stageKey, status, error) {
  if (STOP.tripped) return
  const isGroup = ctx.members && ctx.members.length > 1
  const memberNums = isGroup ? memberIssues(ctx) : [ctx.issue]
  const groupLine = isGroup
    ? 'This issue is part of consolidation group ' + ctx.groupId + ' (primary #' + ctx.issue + '; members: ' + fmtIssues(memberNums) + ') — the whole group halted together.'
    : ''
  const lines = [
    isGroup
      ? 'Post a GitHub comment on EACH of these member issues in ' + REPO + ' (use gh issue comment for every one): ' + fmtIssues(memberNums) + '.'
      : 'Post a GitHub comment on issue #' + ctx.issue + ' in ' + REPO + ' (use gh issue comment).',
    'Title line: "## Automated Processing Halted"',
    'Body: state that the ticketmill workflow halted at stage "' + stageKey + '" with status "' + status + '".',
  ]
  if (isGroup) lines.push(groupLine)
  lines.push(
    'Error: ' + String(error || 'unknown').slice(0, 800),
    'Include: "Resume: re-run the ticketmill workflow with the same args — completed stages are detected from GitHub/git state and skipped."',
    'Also release the claim so another run can pick this ' + (isGroup ? 'group' : 'issue') + ' up' + (isGroup ? ' — do this for EVERY member issue listed above' : '') + ':',
    isGroup
      ? memberNums.map(function (n) { return 'gh issue edit ' + n + ' --repo ' + REPO + ' --remove-label ' + CLAIM_LABEL + ' 2>/dev/null || true' }).join('\n')
      : 'gh issue edit ' + ctx.issue + ' --repo ' + REPO + ' --remove-label ' + CLAIM_LABEL + ' 2>/dev/null || true',
    'Return posted=true/false.',
  )
  const noted = await stage(ctx, 'halt-note-' + stageKey, lines.join('\n'), stageOpts('probe'), NOTE_SCHEMA, 1)
  if (!noted || !noted.posted) log('#' + ctx.issue + ' halt note (' + stageKey + ') did not post — status is recorded in the run results only')
}

// fail(): called exactly once per unit — every call site is a `return fail(...)`,
// so this fires (and increments BATCH.failures) exactly ONCE per unit regardless
// of how many members it covers. A failed GROUP is still one breaker increment,
// not one per member; postNote() above is what fans the halt note out per member.
async function fail(ctx, status, stageKey, error) {
  log('#' + ctx.issue + ' -> ' + status + ' at ' + stageKey + ': ' + String(error || '').slice(0, 200))
  await postNote(ctx, stageKey, status, error)
  BATCH.failures++
  if (BATCH.failures >= MAX_BATCH_FAILURES) tripStop('circuit breaker: ' + BATCH.failures + ' issues failed')
  return { issue: ctx.issue, title: ctx.title, status: status, stage: stageKey, pr: ctx.pr || null, error: String(error || ''), follow_ups: [], metrics: ctx.metrics || null, tokens: ctx.tokens || null, timeline: timeline(ctx), handoff_notes: (ctx.notes || []).slice(), members: memberIssues(ctx) }
}

// =============================================================================
// QUALITY LOOP (simplify -> review -> fix, with degrade accounting)
// Returns 'approved' | 'degraded' | 'halted'
// =============================================================================
// Glob matching for profile globs (test_globs, simplify_globs, ui_globs).
// Supports ** (any path), * (any chars within a segment). Anchored to the
// repo-relative path.
function globToRe(g) {
  let s = String(g).replace(/[.+^${}()|[\]\\]/g, '\\$&')
  s = s.replace(/\*\*\//g, '<GLOBSTAR_SLASH>')
  s = s.replace(/\*\*/g, '<GLOBSTAR>')
  s = s.replace(/\*/g, '[^/]*')
  s = s.replace(/<GLOBSTAR_SLASH>/g, '(?:.*/)?')
  s = s.replace(/<GLOBSTAR>/g, '.*')
  return new RegExp('^' + s + '$')
}
function matchesGlobs(file, globs) {
  if (!Array.isArray(globs)) return true // null/absent = match everything
  for (const g of globs) { if (globToRe(g).test(String(file))) return true }
  return false
}

// =============================================================================
// ENGINE-OWNED PATHS (issue #3): the ticketmill profile, agent roster, and the
// engine's own installed copy are read-only artifacts of THIS run's tooling —
// not the target repo's application code. A worktree's committed state of
// these paths can be stale relative to the root working tree driving the run
// (nonconvexlabs-com #77): an implementer that "reconciles" a stale diff here
// silently clobbers newer state that exists only uncommitted at ROOT.
// ENGINE_OWNED_GLOBS is the default set; a profile may extend it via
// PROFILE.engine_owned_globs (mergeEngineOwnedGlobs). Some engine-owned paths
// are legitimately installed/lockstepped alongside a source-of-truth copy
// elsewhere in the repo (this repo's own .claude/workflows/ticketmill.js,
// kept byte-identical to workflows/ticketmill.js by scripts/lint-engine.js) —
// PROFILE.lockstep_installed_paths (default []) names those so a hard-revert
// gate can exempt them (isHardRevertPath).
// =============================================================================
const ENGINE_OWNED_GLOBS = [
  '.claude/ticketmill.json',
  '.claude/agents/**',
  '.claude/workflows/ticketmill.js',
  '.claude/scripts/ticketmill/**',
]

// mergeEngineOwnedGlobs: the module default plus an optional profile
// extension (PROFILE.engine_owned_globs). Pure so tests can exercise it
// without seeding module state.
function mergeEngineOwnedGlobs(profile) {
  const extra = profile && Array.isArray(profile.engine_owned_globs) ? profile.engine_owned_globs.map(String) : []
  return ENGINE_OWNED_GLOBS.concat(extra)
}

// literalizeGlob: strips a trailing run of '*' characters (covers '/**',
// '/*', and a bare trailing '*' uniformly) down to the fixed prefix before
// it, e.g. '.claude/agents/**' -> '.claude/agents/'. An exact-file glob with
// no trailing star (e.g. '.claude/ticketmill.json') is returned unchanged.
// Shared by engineOwnedHit's prose substring match and
// buildEngineOwnedPathspec's git pathspec.
function literalizeGlob(g) {
  return String(g).replace(/\*+$/, '')
}

// engineOwnedHit: case-sensitive substring scan of free text (an issue title
// + body) for any literalized engine-owned prefix. Returns the literalized
// prefix that hit (a truthy string a caller can name in a reason/log line),
// or null when nothing matched. Deliberately dumb — substring, not path
// parsing — because the callers need a cheap, deterministic proxy for "does
// this issue's prose plainly target an engine-owned path", not a parser.
function engineOwnedHit(text, globs) {
  const s = String(text || '')
  const list = Array.isArray(globs) ? globs : []
  for (const g of list) {
    const prefix = literalizeGlob(g)
    if (prefix && s.indexOf(prefix) !== -1) return prefix
  }
  return null
}

// buildEngineOwnedPathspec: the same literalization as engineOwnedHit,
// applied to build a `git ... -- <pathspec>` argument list. Trailing '*'
// characters are already stripped, so every entry is a plain literal path
// git can match directly — a directory prefix (e.g. '.claude/agents/')
// matches everything under it, an exact file path matches only itself; no
// pathspec magic (':(literal)' etc) is needed since no glob metacharacters
// remain. Deduplicates in case a profile's engine_owned_globs re-lists a
// default entry.
function buildEngineOwnedPathspec(globs) {
  const list = Array.isArray(globs) ? globs : []
  const out = []
  for (const g of list) {
    const p = literalizeGlob(g)
    if (p && out.indexOf(p) === -1) out.push(p)
  }
  return out
}

// isHardRevertPath: file-level predicate for the post-implement hard-revert
// gate — true when `file` falls under the engine-owned set AND is NOT one of
// the profile's lockstep-installed exceptions. Built on matchesGlobs (full
// glob matching, file-match time) rather than a glob-STRING set difference:
// a glob-string diff can't express "this lockstep file sits nested under
// that engine-owned directory glob" (e.g. '.claude/agents/pinned.md' vs
// '.claude/agents/**') — matching at the file level gets nesting right
// without special-casing it.
function isHardRevertPath(file, engineGlobs, lockstepPaths) {
  return matchesGlobs(file, engineGlobs) && !matchesGlobs(file, lockstepPaths)
}

// attachEngineOwnedIntentional: per-preflight regime classifier (issue #3) —
// does THIS issue's own title+body plainly target an engine-owned path
// (engineOwnedHit)? Computed once, right after the preflight probe returns,
// from title+body ALONE (never from root_dirty_engine_paths or resume_point)
// so it stays a pure "did the prose name the set" signal that deriveUnits can
// later OR-fold across every live member of a consolidation group, regardless
// of which member ends up as the group's primary ref. Pure and side-effect-free:
// returns a NEW array (does not mutate `preflights`) so a probe-died fallback
// entry (no live body) flows through identically to every other preflight —
// engineOwnedHit('' , globs) is always null, so it lands false, never throws.
function attachEngineOwnedIntentional(preflights, globs) {
  return (preflights || []).map(function (p) {
    return Object.assign({}, p, { engineOwnedIntentional: !!engineOwnedHit((p.title || '') + '\n' + (p.body || ''), globs) })
  })
}

// applyEngineOwnedRootDirtySkip: regime (a) of the three-regime model (issue
// #3, ENGINE_OWNED_GLOBS module comment) — an issue whose OWN prose plainly
// targets an engine-owned path (engineOwnedIntentional), probed while the
// ROOT working tree is ALREADY dirty under that same set, is routed to
// select-skip instead of being implemented mid-run: the state actually
// driving this run lives only uncommitted at ROOT, so any worktree checkout
// this run builds is stale relative to it (the #77 hazard) — implementing
// from it risks silently reconciling/clobbering the newer uncommitted state.
// Regime (b) (prose targets the set, root clean — deliberate engine work,
// e.g. issue #3 itself) and regime (c) (root dirty for unrelated reasons, or
// prose doesn't target the set) are both left untouched here; only the (a)
// intersection flips resume_point.
// Pure: returns { preflights: <NEW array>, flagged: [issueNumbers] } rather
// than mutating in place, so the Select-phase caller can both use the updated
// preflights AND log the root-dirty condition exactly once (not once per
// flagged issue) — see the caller for that single log line.
function applyEngineOwnedRootDirtySkip(preflights) {
  const flagged = []
  const out = (preflights || []).map(function (p) {
    const dirty = Array.isArray(p.root_dirty_engine_paths) ? p.root_dirty_engine_paths : []
    if (!p.engineOwnedIntentional || !dirty.length) return p
    flagged.push(p.issue)
    return Object.assign({}, p, {
      resume_point: 'skip',
      reason: 'engine-owned path targeted by this issue, and the root working tree is already dirty under it (' + dirty.join(', ') + ') — run this issue solo outside a batch, or after the run completes',
    })
  })
  return { preflights: out, flagged: flagged }
}

async function runQualityLoop(ctx, prefix, taskDesc, filesChanged) {
  const simplifyGlobs = PROFILE.simplify_globs || null
  const inScope = function (f) { return matchesGlobs(f, simplifyGlobs) }
  // human-readable scope for the loop-step issue comments ("task 3", "PR-fix round 2")
  const stepLabel = prefix.replace(/^task-/, 'task ').replace(/^pr-fix-i/, 'PR-fix round ')
  // Skip simplify when the triggering change verifiably touched no in-scope files
  // (retro: the simplifier is near-zero value outside its language and can trip
  // schema-retry halts). Fail OPEN: an unknown/empty file list still runs simplify;
  // an in-loop fix that later touches in-scope files re-enables it.
  let runSimplify = !Array.isArray(filesChanged) || filesChanged.length === 0 || filesChanged.some(inScope)
  let approved = false
  let degraded = false
  for (let iter = 1; !approved && !degraded && iter <= MAX_QUALITY_ITERATIONS; iter++) {
    if (STOP.tripped) return 'halted'
    ctx.metrics.quality_iters++

    if (runSimplify) {
      const simp = await stage(ctx, 'simplify-' + prefix + '-i' + iter, [
        roleBlock('simplifier'),
        '',
        'Simplify the modified files in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + '.',
        simplifyGlobs ? 'Only files matching these patterns are in scope for simplification: ' + simplifyGlobs.join(', ') : '',
        '',
        taskDesc ? 'Task context: ' + String(taskDesc).slice(0, 300) : '',
        notesBlock(ctx),
        'IMPORTANT SCOPE CONSTRAINT: this is for issue #' + ctx.issue + '. Only simplify code directly related to',
        'the issue. Do NOT apply general modernization to files that were only incidentally touched.',
        'If no in-scope files were modified for this issue, make no changes and report "Nothing to simplify".',
        'Simplify for clarity and consistency WITHOUT changing behavior. Commit if you changed anything.',
        'If you changed anything, post an issue comment "## Simplify Pass (' + stepLabel + ', iteration ' + iter + ')" with',
        'the commit SHA and 2-4 lines on what was simplified (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ');',
        'skip the comment entirely if you made no changes.',
        COMMIT_SHA_ASK,
        HANDOFF_ASK,
        'Return status, commit, files_changed, summary.',
      ].join('\n'), stageOpts('simplify'), IMPL_SCHEMA)
      if (!simp || simp.status === 'error') { degraded = true; log('#' + ctx.issue + ' quality ' + prefix + ' i' + iter + ': simplify degraded'); break }
      collectNotes(ctx, 'simplify', simp)
    } else if (iter === 1) {
      log('#' + ctx.issue + ' quality ' + prefix + ': simplify skipped (no in-scope files in change)')
    }

    const rev = await stage(ctx, 'quality-review-' + prefix + '-i' + iter, [
      roleBlock('code_reviewer'),
      '',
      'Review the code changes for scope "' + prefix + '" of issue #' + ctx.issue + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + '.',
      '',
      '## Decision chain (context from prior stages)',
      decisionChain(ctx),
      settledBlock(ctx),
      '',
      'This is a task-level quality check inside the implementation workflow, NOT a full PR review.',
      'Check: code patterns and standards, consistency with codebase conventions, potential bugs, security concerns.',
      'Diff to review: git -C ' + ctx.worktree + ' diff ' + TARGET + '...HEAD',
      IMPLEMENTERS.length ? 'If changes are requested, set recommended_fix_agent to one of: ' + IMPLEMENTERS.join(', ') + '.' : '',
      bwFeedback(ctx),
      'Post an issue comment "## Quality Review (' + stepLabel + ', iteration ' + iter + ')" with your verdict',
      '(approved / changes requested) and key findings in 3-6 lines (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
      'Return result (approved|changes_requested), comments, issues, recommended_fix_agent, summary.',
    ].join('\n'), stageOpts('qReview'), REVIEW_SCHEMA)
    if (!rev) { degraded = true; log('#' + ctx.issue + ' quality ' + prefix + ' i' + iter + ': review degraded'); break }

    if (rev.result === 'approved') { approved = true; break }

    const fixAgent = pickFixAgent(rev.recommended_fix_agent, null)
    const fix = await stage(ctx, 'quality-fix-' + prefix + '-i' + iter, [
      implementerBlock(fixAgent),
      '',
      'Address code review feedback in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + ' (issue #' + ctx.issue + '):',
      '',
      String(rev.comments || rev.summary || 'No comments'),
      '',
      fixContext(ctx, taskDesc),
      '',
      'After committing, post an issue comment "## Quality Fix (' + stepLabel + ', iteration ' + iter + ')" with the',
      'commit SHA and the fixes applied in 2-4 lines (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
      COMMIT_SHA_ASK,
      bwFeedback(ctx),
      HANDOFF_ASK,
      'Fix the issues and commit. Return status, commit, files_changed, fixes_applied, summary.',
    ].join('\n'), stageOpts('fix'), FIX_SCHEMA)
    if (!fix || fix.status === 'error') { degraded = true; log('#' + ctx.issue + ' quality ' + prefix + ' i' + iter + ': fix degraded'); break }
    collectNotes(ctx, 'quality-fix', fix)
    if (!runSimplify && (fix.files_changed || []).some(inScope)) runSimplify = true
  }

  // rolling degrade window across this issue's tasks
  ctx.degrades.push(degraded)
  if (degraded) ctx.metrics.quality_degrades++
  const window = ctx.degrades.slice(-QUALITY_DEGRADE_WINDOW)
  const count = window.filter(Boolean).length
  if (count >= MAX_QUALITY_DEGRADES_IN_WINDOW) {
    log('#' + ctx.issue + ' quality degrade rate exceeded (' + count + '/' + window.length + ') — halting issue')
    return 'halted'
  }
  return approved ? 'approved' : 'degraded'
}

// =============================================================================
// BROWSER VERIFICATION (opt-in via profile.browser; serial across ALL pipelines)
// The verification browser is one shared instance on this host — concurrent
// agents hijack each other's tabs mid-flow. Every browser stage acquires this
// chained mutex; probes and fixes stay outside the lock so browser time is
// held only while the browser is actually in use.
// =============================================================================
let BW_QUEUE = Promise.resolve()
function withBrowser(fn) {
  const run = BW_QUEUE.then(function () { return fn() })
  BW_QUEUE = run.then(function () {}, function () {}) // keep the chain alive past failures
  return run
}
function bwPort(issue) { return ((BROWSER && BROWSER.port_base) || 8100) + (issue % ((BROWSER && BROWSER.port_span) || 900)) }
function serveCmd(issue) {
  return String((BROWSER && BROWSER.serve_command) || '').replace(/\{port\}/g, String(bwPort(issue)))
}
function bwArtifactDir(issue) {
  const tmpl = (BROWSER && BROWSER.artifact_dir) || '/tmp/ticketmill-issue-{issue}'
  return /\{issue\}/.test(tmpl) ? tmpl.replace(/\{issue\}/g, String(issue)) : tmpl + '-' + issue
}

// Host-global browser lock. The JS mutex above only serializes stages THIS SCRIPT
// schedules — but any agent can load a browser MCP via ToolSearch, so ad-hoc
// browser use (implement/fix/review agents wanting live feedback) needs a lock
// that works from inside any agent's shell. flock can't span separate Bash tool
// calls (each call is its own process), so the lock is an atomic mkdir directory
// with an owner file and a 30-minute stale-steal (both configurable via
// profile.browser). Scheduled verification stages acquire the SAME lock, so
// ad-hoc use and the verification pipeline stay mutually serial.
function bwLock() { return (BROWSER && BROWSER.lock_path) || '/tmp/ticketmill-browser-lock' }
function bwAcquire(who) {
  const lock = bwLock()
  const staleSeconds = parseInt((BROWSER && BROWSER.stale_seconds), 10) || 1800
  const pollSeconds = parseInt((BROWSER && BROWSER.poll_seconds), 10) || 15
  return [
    'Acquire the global browser lock (bounded wait; NEVER touch the browser without it):',
    '  until mkdir ' + lock + ' 2>/dev/null; do',
    '    s=$(cat ' + lock + '/started 2>/dev/null || echo 0); now=$(date +%s)',
    '    if [ $((now - s)) -gt ' + staleSeconds + ' ]; then rm -rf ' + lock + '; fi   # steal stale locks (dead holder)',
    '    sleep ' + pollSeconds,
    '  done',
    '  echo ' + who + ' > ' + lock + '/owner; date +%s > ' + lock + '/started',
    '(Bound the wait to ~15 minutes of looping. If holding the lock across a long step — a build, a fix —',
    'release it first and re-acquire after; re-touch ' + lock + '/started if a browser session runs long.)',
  ].join('\n')
}
function bwRelease(who) {
  const lock = bwLock()
  return 'Release the lock ONLY if you own it: grep -qx "' + who + '" ' + lock + '/owner 2>/dev/null && rm -rf ' + lock
}
// Optional live-feedback offer for implement/fix/review prompts. Empty when the
// profile has no browser config — the offer must not exist for non-UI projects.
function bwFeedback(ctx) {
  if (!BROWSER) return ''
  const who = 'issue-' + ctx.issue
  return [
    '## Optional: live browser feedback (shared browser — serial, lock required)',
    'If (and ONLY if) this is UI work where static inspection is insufficient, you may verify your work in the',
    'shared browser. It is ONE global instance; using it without the lock corrupts another agent\'s session.',
    bwAcquire(who),
    'Then: serve from your worktree (cd ' + ctx.worktree + ' && ' + serveCmd(ctx.issue) + ', backgrounded), load browser tools via',
    'ToolSearch ("playwright browser"), and look at what you need. Keep it SHORT — the whole batch queues on this lock.',
    BROWSER.notes ? 'Project notes: ' + BROWSER.notes : '',
    'When done (ALWAYS, even on failure): kill your server, close the browser, then',
    bwRelease(who),
    'If you cannot acquire the lock within ~15 minutes, proceed without browser feedback — it is optional here.',
  ].filter(Boolean).join('\n')
}

// runBrowserCheck: gate UI-testable changes through a live browser pass.
// where: 'implement' (after the test loop) | 'pre-merge' (after PR reviews).
// Returns { ok: true, skipped? } | { ok: false, error }
async function runBrowserCheck(ctx, where) {
  if (!BROWSER) return { ok: true, skipped: true }
  const uiGlobs = BROWSER.ui_globs || []
  if (!uiGlobs.length) { log('#' + ctx.issue + ' browser(' + where + '): profile.browser has no ui_globs — skipping (recorded)'); VERIFY_SKIPS.push('#' + ctx.issue + ': browser verification skipped — profile.browser.ui_globs is empty'); return { ok: true, skipped: true } }
  // Cheap unlocked probe: any UI surface in this diff at all? Default retries (a
  // 1-try probe that died would collapse to [] and SILENTLY skip verification —
  // fail-open). If it still dies, fail CLOSED: run verification and let the
  // verifier determine the UI scope itself.
  const probe = await stage(ctx, 'ui-probe-' + where, [
    'READ-ONLY probe: list UI-relevant files changed for issue #' + ctx.issue + '. Run exactly:',
    'git -C ' + ctx.worktree + ' diff origin/' + TARGET + '...HEAD --name-only',
    'Then keep ONLY lines matching any of these glob patterns: ' + uiGlobs.join(', '),
    'Return ui_files (the matching lines as an array; empty array if none).',
  ].join('\n'), stageOpts('probe'), UI_PROBE_SCHEMA)
  const uiFiles = probe ? (probe.ui_files || []).filter(function (f) { return matchesGlobs(f, uiGlobs) }) : null
  if (uiFiles && !uiFiles.length) { log('#' + ctx.issue + ' browser(' + where + '): skipped — no UI files in diff'); return { ok: true, skipped: true } }
  if (!uiFiles) log('#' + ctx.issue + ' browser(' + where + '): UI probe died — failing CLOSED, verifier determines UI scope itself')

  const port = bwPort(ctx.issue)
  for (let iter = 1; iter <= MAX_BROWSER_ITERATIONS; iter++) {
    if (STOP.tripped) return { ok: false, error: 'stopped: ' + STOP.reason }
    ctx.metrics.browser_iters++
    const bw = await withBrowser(async function () {
      const r = await stage(ctx, 'browser-' + where + '-i' + iter, [
        'Browser verification (' + where + ') for issue #' + ctx.issue + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + '.',
        '',
        'You hold the EXCLUSIVE browser lock — no other agent is using the browser right now. In exchange:',
        'do all non-browser prep FIRST, keep browser time tight, and when finished close the browser',
        'and kill any server you started, so the next lock holder starts clean.',
        '',
        uiFiles
          ? 'UI files changed by this issue:\n' + uiFiles.slice(0, 30).map(function (f) { return '- ' + f }).join('\n')
          : 'The UI-file probe was unavailable — determine the changed UI surface yourself:\n' +
            'git -C ' + ctx.worktree + ' diff origin/' + TARGET + '...HEAD --name-only (match against: ' + uiGlobs.join(', ') + ')\n' +
            'If that returns NOTHING, do not boot anything — return result=skipped with summary "no UI files in diff".',
        '',
        ctx.approach ? 'Change intent: ' + String(ctx.approach).slice(0, 300) : '',
        notesBlock(ctx), '',
        'Steps:',
        '0. ' + bwAcquire('issue-' + ctx.issue + '-verify') + '\n   (Scheduled verification is also serialized script-side, but ad-hoc',
        '   agents use this same lock for feedback — you still must hold it.)',
        '1. Load browser tools via ToolSearch (query "playwright browser").',
        '2. Prep the app in the worktree:' + (BROWSER.build_command ? ' build assets if needed (cd ' + ctx.worktree + ' && ' + BROWSER.build_command + ');' : '') + ' then boot the app on a per-issue port:',
        '   cd ' + ctx.worktree + ' && ' + serveCmd(ctx.issue) + ' (background it; verify it responds with curl before browsing).',
        '3. In the browser, exercise the SPECIFIC UI behaviors this issue changes — the affected flow end-to-end,',
        '   not a generic smoke test. Follow the target project\'s CLAUDE.md guidance for selectors/login/theme quirks.',
        BROWSER.notes ? '   Project notes: ' + BROWSER.notes : '',
        '4. Artifact discipline: save any screenshots/traces/scratch files ONLY under ' + bwArtifactDir(ctx.issue),
        '   — never inside the worktree (they would pollute commits and the PR diff).',
        '5. result=passed only if every exercised behavior works; failed with concrete failures (what you did,',
        '   what you saw, what was expected) otherwise; skipped ONLY if nothing here is actually verifiable in a',
        '   browser — explain why in summary.',
        '6. Cleanup: kill the server you started, close the browser.',
        'Post an issue comment "## Browser Verification (' + where + ', iteration ' + iter + ')" listing the scenarios',
        'exercised and the result (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
        HANDOFF_ASK,
        'Return result (passed|failed|skipped), scenarios, failures, summary.',
      ].join('\n'), stageOpts('browser'), BROWSER_SCHEMA)
      // Deterministic cleanup UNDER the lock — runs even when the verifier died
      // mid-flight, so the next lock holder inherits a closed browser and a free
      // port instead of hijackable tabs and an orphaned server. Non-fatal.
      const clean = await stage(ctx, 'browser-cleanup-' + where + '-i' + iter, [
        'Cleanup after a browser verification pass (idempotent; repo-safe — touch NO files in ' + ctx.worktree + '):',
        '1. Kill any server listening on port ' + port + ': fuser -k ' + port + '/tcp 2>/dev/null || true',
        '2. Load the browser MCP tools via ToolSearch and close the browser (ignore errors if nothing is open).',
        '3. rm -rf ' + bwArtifactDir(ctx.issue) + ' || true',
        '4. ' + bwRelease('issue-' + ctx.issue + '-verify'),
        '   (owner-guarded on purpose: if the verifier died BEFORE acquiring, the lock belongs to someone else — leave it)',
        'Return posted=true when done.',
      ].join('\n'), stageOpts('probe'), NOTE_SCHEMA, 1)
      if (!clean) log('#' + ctx.issue + ' browser(' + where + ') i' + iter + ': cleanup agent died — next lock holder may inherit browser/port state')
      return r
    })
    if (!bw) return { ok: false, error: 'browser verifier died (' + where + ', iteration ' + iter + ')' }
    collectNotes(ctx, 'browser', bw)
    if (bw.result !== 'failed') {
      pushDecision(ctx, 'Browser Verification (' + where + ')', '**Result:** ' + bw.result + ' (iteration ' + iter + ')\n' + (bw.summary || ''))
      return { ok: true }
    }
    if (iter === MAX_BROWSER_ITERATIONS) break
    // fix OUTSIDE the lock — the browser is free while code is being repaired
    const fix = await stage(ctx, 'browser-fix-' + where + '-i' + iter, [
      implementerBlock(null),
      '',
      'Fix UI defects found by browser verification for issue #' + ctx.issue + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + ':',
      '',
      'Failures observed in the browser:',
      (bw.failures || []).map(function (f) { return '- ' + f }).join('\n') || (bw.summary || ''),
      '',
      fixContext(ctx, null),
      'Fix the real defect — do NOT hide the symptom (e.g. removing the interaction that fails).',
      'After committing, post an issue comment "## Browser Fix (' + where + ', iteration ' + iter + ')" with the commit',
      'SHA and what was fixed (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
      COMMIT_SHA_ASK,
      HANDOFF_ASK,
      'Commit' + (where === 'pre-merge' ? ' and push: git -C ' + ctx.worktree + ' push origin ' + ctx.branch : '') + '. Return status, commit, files_changed, fixes_applied, summary.',
    ].join('\n'), stageOpts('fix'), FIX_SCHEMA)
    if (!fix || fix.status === 'error') return { ok: false, error: 'browser-fix stage failed (' + where + ')' }
    collectNotes(ctx, 'browser-fix', fix)
  }
  return { ok: false, error: 'browser verification still failing after ' + MAX_BROWSER_ITERATIONS + ' iterations (' + where + ')' }
}

// =============================================================================
// ENGINE-OWNED GATE (issue #3, regimes b/c) — the deterministic post-implement
// backstop. scopeGuard()'s engine-owned clause (above) is advisory layer 1; this
// is layer 2. Modeled on runBrowserCheck immediately above: a READ-ONLY probe
// runs `git diff --name-only` against the batch baseline and returns every
// changed file; JS (never the agent) filters that list via matchesGlobs against
// ENGINE_OWNED, then routes on ctx.engineOwnedIntentional — computed once at
// Select from THIS issue's own prose (engineOwnedHit) and OR-folded across a
// consolidation group's live members (deriveUnits) — per the three-regime model
// documented above ENGINE_OWNED_GLOBS:
//   (b) intentional: this issue's own prose plainly targets the engine-owned
//       set, so an engine-owned diff is expected, deliberate work (e.g. issue
//       #3 itself). Leave the implementation exactly as committed — no revert.
//   (c) NOT intentional, but engine-owned paths showed up in the diff anyway:
//       the incidental/paraphrased silent-restore vector nonconvexlabs-com #77
//       actually was. A single-purpose stage hard-reverts ONLY the paths where
//       isHardRevertPath(f, ENGINE_OWNED, LOCKSTEP_INSTALLED_PATHS) is true —
//       lockstep-installed paths (e.g. this repo's own
//       .claude/workflows/ticketmill.js) are deliberately exempted so a
//       source-of-truth edit's installed lockstep copy is never clobbered by
//       this gate; any resulting divergence is left for the test loop's own
//       lint-engine byte-compare to catch in-band — see isHardRevertPath's doc
//       comment — to the batch baseline (origin/TARGET), commits, and pushes.
// Placed BEFORE runTestLoop() in implementIssue() (not near runBrowserCheck,
// which runs AFTER the test loop) so a revert this gate makes is re-validated
// by the SAME run's test suite / lint-engine byte-compare, in-band, rather
// than landing unverified.
// Never halts the run on its own: a dead probe or a failed/dead revert stage
// degrades to a recorded deferred follow-up (mirrors the anti-pattern rule —
// a skipped verification must be recorded, never silently swallowed) so a
// plumbing hiccup in this gate never blocks an otherwise-green issue.
// Returns { ok: true } always.
// =============================================================================
async function runEngineOwnedGate(ctx) {
  if (!ENGINE_OWNED.length) return { ok: true }
  const probe = await stage(ctx, 'engine-owned-probe', [
    'READ-ONLY probe for issue #' + ctx.issue + ': list every file this issue\'s implementation changed. Run exactly:',
    'git -C ' + ctx.worktree + ' diff origin/' + TARGET + '...HEAD --name-only',
    'Return changed_files (the output lines as an array; empty array if none).',
    '',
    'Also run this second command to find files newly created on this branch (absent from the batch baseline):',
    'git -C ' + ctx.worktree + ' diff origin/' + TARGET + '...HEAD --diff-filter=A --name-only',
    'Return added_files (the output lines as an array; empty array if none).',
  ].join('\n'), stageOpts('probe'), DIFF_PROBE_SCHEMA)
  if (!probe) {
    log('#' + ctx.issue + ' engine-owned gate: diff probe died — degrading (recorded), not blocking the issue')
    ctx.deferred.push('Engine-owned guardrail: the post-implement diff probe died, so this pass could not check for incidental changes to ' + ENGINE_OWNED.join(', ') + ' — verify manually before merge.')
    return { ok: true }
  }
  const engineFiles = (probe.changed_files || []).filter(function (f) { return matchesGlobs(f, ENGINE_OWNED) })
  if (!engineFiles.length) return { ok: true }

  if (ctx.engineOwnedIntentional) {
    log('#' + ctx.issue + ' engine-owned gate: regime (b) deliberate engine work — leaving ' + engineFiles.length + ' engine-owned file(s) in place: ' + engineFiles.join(', '))
    return { ok: true }
  }

  const revertFiles = engineFiles.filter(function (f) { return isHardRevertPath(f, ENGINE_OWNED, LOCKSTEP_INSTALLED_PATHS) })
  const exemptFiles = engineFiles.filter(function (f) { return !isHardRevertPath(f, ENGINE_OWNED, LOCKSTEP_INSTALLED_PATHS) })
  if (exemptFiles.length) {
    log('#' + ctx.issue + ' engine-owned gate: ' + exemptFiles.length + ' lockstep-installed path(s) left in place (regime (c) exemption): ' + exemptFiles.join(', '))
    ctx.deferred.push('Engine-owned guardrail: incidental change(s) to lockstep-installed path(s) — ' + exemptFiles.join(', ') + ' — were NOT reverted (lockstep exemption); verify the lockstep pair stayed in sync (lint-engine) before merge.')
  }
  if (!revertFiles.length) return { ok: true }

  // Partition revertFiles: createdFiles are absent from origin/TARGET (git
  // checkout errors 'pathspec did not match any file(s)' on these — they must
  // be git rm'd instead); existingFiles are the rest, handled via checkout as
  // before. added_files is optional (older/degraded probe responses omit it),
  // in which case createdFiles is empty and behavior is unchanged from before
  // this partition existed — checkout attempts the created path too, fails,
  // and the stage degrades to a recorded ctx.deferred follow-up as it always did.
  const addedFiles = probe.added_files || []
  const createdFiles = revertFiles.filter(function (f) { return addedFiles.indexOf(f) !== -1 })
  const existingFiles = revertFiles.filter(function (f) { return addedFiles.indexOf(f) === -1 })

  log('#' + ctx.issue + ' engine-owned gate: regime (c) incidental change — hard-reverting ' + revertFiles.join(', ') + ' to origin/' + TARGET)
  const revertSteps = []
  let stepNum = 1
  if (existingFiles.length) {
    revertSteps.push(
      stepNum++ + '. git -C ' + ctx.worktree + ' checkout origin/' + TARGET + ' -- ' + existingFiles.map(function (f) { return '"' + f + '"' }).join(' ')
    )
  }
  if (createdFiles.length) {
    revertSteps.push(
      stepNum++ + '. git -C ' + ctx.worktree + ' rm ' + createdFiles.map(function (f) { return '"' + f + '"' }).join(' ')
    )
  }
  revertSteps.push(
    stepNum++ + '. Confirm the revert is exact: git -C ' + ctx.worktree + ' diff origin/' + TARGET + ' -- ' + revertFiles.map(function (f) { return '"' + f + '"' }).join(' ') + ' (must be empty)',
    stepNum++ + '. git -C ' + ctx.worktree + ' commit -m "revert(engine): drop incidental engine-owned change(s) (#' + ctx.issue + ')"',
    stepNum++ + '. git -C ' + ctx.worktree + ' push origin ' + ctx.branch
  )
  const revert = await stage(ctx, 'engine-owned-revert', [
    'The scope guard\'s OUT-OF-SCOPE clause above (engine-owned paths — do not stage, commit, or restore them) does NOT',
    'apply to this stage: this stage IS the deterministic guardrail acting on your behalf. Carry out the steps below.',
    '',
    'Regime (c) engine-owned guardrail for issue #' + ctx.issue + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + ':',
    'This issue\'s implementation incidentally changed engine-owned path(s) that this issue does NOT target (its title/body',
    'never names them) — these are read-only tooling artifacts of the run itself (the ticketmill profile, agent roster, or',
    'engine copy), not this issue\'s application code.',
    '',
    'Hard-revert EXACTLY these paths to the batch baseline, and touch NOTHING else:',
    revertFiles.map(function (f) { return '- ' + f }).join('\n'),
    (createdFiles.length
      ? '\nOf these, the following were newly created on this branch (absent from origin/' + TARGET + ') — git rm them' +
        ' rather than checking them out:\n' + createdFiles.map(function (f) { return '- ' + f }).join('\n')
      : ''),
    '',
    revertSteps.join('\n'),
    '',
    'Restore existing paths ONLY via checkout from origin/' + TARGET + ' — never from git log/reflog/history on this branch, and',
    'never by re-authoring the file yourself. Stage and commit nothing outside the listed paths.',
    'Return status, commit, files_changed, summary.',
  ].join('\n'), stageOpts('fix'), FIX_SCHEMA, 1)
  if (!revert || revert.status === 'error') {
    log('#' + ctx.issue + ' engine-owned gate: revert stage failed/died — degrading (recorded), not blocking the issue')
    ctx.deferred.push('Engine-owned guardrail: automatic revert of incidental engine-owned change(s) to ' + revertFiles.join(', ') + ' FAILED — a human must verify/revert these paths manually before merge.')
    return { ok: true }
  }
  pushDecision(ctx, 'Engine-Owned Guardrail', 'Reverted incidental engine-owned change(s) to the batch baseline (origin/' + TARGET + '): ' + revertFiles.join(', ') + '. Commit: ' + (revert.commit || 'n/a') + '.')
  ctx.deferred.push('Engine-owned guardrail: incidental change(s) to ' + revertFiles.join(', ') + ' were reverted to the batch baseline — if this was actually intentional engine work, redo it as its own dedicated issue that names the path(s) so it is recognized as deliberate.')
  return { ok: true }
}

// =============================================================================
// TEST LOOP (run -> fix -> validate -> fix; errors HALT)
// forced: when true, always runs the full suite — skips the "no testable code
// changed" shortcut below entirely. Used by runMergeAutoResolve, where the
// safety property being verified is "does the EXACT state about to be
// force-pushed pass tests", not "did this rebase touch test-glob files" (a
// rebase can pull in upstream commits whose diff against TARGET looks
// unchanged from this issue's own files while the tree that would be pushed
// has still moved).
// Returns { ok: true } | { ok: false, error }
// A null TEST_CMD is an EXPLICIT profile decision (mill-init records it after
// human confirmation) — the loop is skipped but the skip is surfaced in the
// batch PR body via VERIFY_SKIPS, never buried in logs.
// =============================================================================
async function runTestLoop(ctx, forced) {
  if (TEST_CMD === null) {
    log('#' + ctx.issue + ' test loop: profile declares test_command: null (no test gate) — recorded for the batch PR body')
    VERIFY_SKIPS.push('#' + ctx.issue + ': test loop skipped — profile declares "test_command": null (explicit no-test decision)')
    pushDecision(ctx, 'Test Loop', 'SKIPPED — profile declares no test gate (test_command: null)')
    return { ok: true }
  }
  const testGlobs = PROFILE.test_globs || null
  for (let iter = 1; iter <= MAX_TEST_ITERATIONS; iter++) {
    if (STOP.tripped) return { ok: false, error: 'stopped: ' + STOP.reason }
    ctx.metrics.test_iters = iter

    const t = await stage(ctx, 'test-run-i' + iter, [
      forced
        ? 'This is a MANDATORY re-run (auto-resolve safety gate after a rebase) — run the full suite below' +
          ' regardless of which files the diff touches; do NOT skip it for "no testable code changed".'
        : [
            'First check whether testable code changed: git -C ' + ctx.worktree + ' diff origin/' + TARGET + '...HEAD --name-only',
            testGlobs
              ? 'If NO changed file matches any of these patterns (' + testGlobs.join(', ') + '), do NOT run the suite — return'
              : 'If the diff is empty, do NOT run the suite — return',
            'result=passed with summary "no testable code changed — suite skipped" (and post the Test Run comment saying exactly that).',
          ].join('\n'),
      'Otherwise run the project test suite in worktree ' + ctx.worktree + ':',
      '  cd ' + ctx.worktree + ' && ' + TEST_CMD + ' 2>&1 | tail -30',
      '(Full output exceeds context — the tail carries the summary. If the suite fails to BOOT — missing env,',
      'credentials, services — that is an environment problem, not a code problem: check the project verification',
      'notes below and the env files (' + (PROFILE.env_files || []).join(', ') + ' should exist in the worktree, copied from ' + ROOT + '), fix the',
      'environment, then retry once.)',
      verifyNotesBlock(),
      learn('test_loop'),
      notesBlock(ctx),
      'Post an issue comment "## Test Run (iteration ' + iter + ')" with the result and counts',
      '(gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
      HANDOFF_ASK,
      'Report pass/fail and counts. Return result (passed|failed), total_tests, passed_tests, failed_tests, failures, summary.',
    ].join('\n'), stageOpts('testRun'), TEST_SCHEMA)
    // INTENTIONAL HALT: when CI does not run the suite, this loop is the only
    // gate — a silent skip here ships broken code.
    if (!t) return { ok: false, error: 'test runner died — halting (tests are the only gate when CI does not run them)' }
    collectNotes(ctx, 'test-run', t)

    if (t.result === 'failed') {
      const fix = await stage(ctx, 'test-fix-i' + iter, [
        implementerBlock(null),
        '',
        'Fix test failures in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + ' (issue #' + ctx.issue + '):',
        '',
        'Failures:',
        JSON.stringify(t.failures || [], null, 2).slice(0, 6000),
        '',
        fixContext(ctx, null),
        verifyNotesBlock(),
        learn('test_loop'),
        'Fix the real defect — do NOT delete or weaken assertions just to make the failure disappear.',
        'After committing, post an issue comment "## Test Fix (iteration ' + iter + ')" with the commit SHA and which',
        'failures were addressed (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
        COMMIT_SHA_ASK,
        HANDOFF_ASK,
        'Fix the issues and commit. Return status, commit, files_changed, fixes_applied, summary.',
      ].join('\n'), stageOpts('fix'), FIX_SCHEMA)
      if (!fix || fix.status === 'error') return { ok: false, error: 'test-fix stage failed — halting test loop' }
      collectNotes(ctx, 'test-fix', fix)
      continue
    }

    // tests passed -> validate test quality (scoped to the issue)
    const v = await stage(ctx, 'test-validate-i' + iter, [
      roleBlock('test_validator'),
      '',
      'Validate test comprehensiveness and integrity for issue #' + ctx.issue + ' in worktree ' + ctx.worktree + '.',
      '',
      ctx.approach ? 'Change intent: ' + String(ctx.approach).slice(0, 300) : '',
      notesBlock(ctx),
      'SCOPE: only tests related to this issue. Modified files:',
      '  git -C ' + ctx.worktree + ' diff ' + TARGET + '...HEAD --name-only',
      'IMPORTANT CONSTRAINTS:',
      testGlobs
        ? '- If NO modified file matches the testable patterns (' + testGlobs.join(', ') + '), return result=approved immediately.'
        : '- If no modified file contains testable logic (pure config/docs/assets), return result=approved immediately.',
      '- Only validate tests covering the modified code. Do NOT request tests for unrelated code, config, or assets.',
      'Audit for: TODO/incomplete tests, hollow assertions, missing edge cases, mock abuse.',
      'Post an issue comment "## Test Validation (iteration ' + iter + ')" with your verdict in 2-4 lines',
      '(gh issue comment ' + ctx.issue + ' --repo ' + REPO + '); if approved because nothing testable changed, say so.',
      'Return result (approved|changes_requested), comments, issues, summary.',
    ].join('\n'), stageOpts('testValidate'), REVIEW_SCHEMA)
    if (!v) return { ok: false, error: 'test validator died — halting test loop' }

    if (v.result === 'approved') return { ok: true }

    const qfix = await stage(ctx, 'test-quality-fix-i' + iter, [
      implementerBlock(null),
      '',
      'Address test quality issues in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + ' (issue #' + ctx.issue + '):',
      '',
      String(v.comments || v.summary || 'Fix test quality issues'),
      '',
      fixContext(ctx, null),
      'After committing, post an issue comment "## Test Quality Fix (iteration ' + iter + ')" with the commit SHA and',
      'what was added/strengthened (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
      COMMIT_SHA_ASK,
      HANDOFF_ASK,
      'Add missing assertions, remove TODOs, add edge-case tests, etc. Commit. Return status, commit, files_changed, fixes_applied, summary.',
    ].join('\n'), stageOpts('fix'), FIX_SCHEMA)
    if (!qfix || qfix.status === 'error') return { ok: false, error: 'test-quality-fix stage failed — halting test loop' }
    collectNotes(ctx, 'test-quality-fix', qfix)
  }
  return { ok: false, error: 'test loop exceeded ' + MAX_TEST_ITERATIONS + ' iterations' }
}

// mergeSettlePoll: verbatim bash a merge-preflight probe runs to query PR
// mergeability. GitHub recomputes mergeable=UNKNOWN asynchronously — most
// notably right after a force-push — so a probe that reads state exactly once
// during that window can misread a perfectly fine PR as unresolvable. Bounded
// backoff: up to 6 polls, 5s apart (~30s cap); every poll is echoed, so the
// LAST line printed is always the freshest read, whatever it settled to.
// Persistent UNKNOWN after the cap is a valid outcome this loop hands back
// as-is — the caller decides what to do with it. Shared between
// runMergeAutoResolve's own probe and the merge stage's own preflight.
function mergeSettlePoll(ctx) {
  return [
    'for i in $(seq 1 6); do',
    '  out=$(gh pr view ' + ctx.pr + ' --repo ' + REPO + ' --json state,mergeable,mergeStateStatus)',
    '  echo "$out"',
    '  echo "$out" | grep -q \'"mergeable":"UNKNOWN"\' || break',
    '  sleep 5',
    'done',
  ].join('\n')
}

// =============================================================================
// MERGE AUTO-RESOLVE (mechanical CONFLICTING recovery, modeled on
// runBrowserCheck: an internal probe decides whether to act at all, then a
// bounded sequence of mechanical git stages plus one judgment stage do the
// work.) Inserted into reviewAndMerge immediately before the merge stage, so a
// PR that preflights CONFLICTING gets one mechanical recovery attempt before
// falling back to today's immediate needs_human escalation.
//
// Flow: settle-poll probe -> only on CONFLICTING: fetch+rebase onto TARGET's
// current tip in the still-live worktree -> on rebase conflicts, a
// conflict-resolver stage (implementer persona, judgment call) prefers keeping
// BOTH sides of a hunk, aborts on anything semantic -> mandatory GREEN test
// loop on the rebased state, FORCED (the safety property here is the test
// suite re-verifying the EXACT state about to be force-pushed, not the
// resolver's judgment — it must not skip just because the rebase itself
// touched no test-glob files) -> a cheap guard that TARGET hasn't moved again
// while tests were running (if it has, escalate rather than silently
// re-rebasing and force-pushing content tests never verified — see the guard
// below) -> force-push with lease.
//
// Gated on a real test_command: with test_command:null there is no suite to
// re-verify against — the stated safety property does not exist — so this
// whole flow is skipped and a CONFLICTING PR falls straight through to the
// merge stage's own preflight (today's behavior, unchanged: the fallback, not
// the default).
//
// Returns { ok: true, resolved: boolean } | { ok: false, error }
//   resolved: true only when this flow actually rebased the branch onto a
//   newer TARGET tip and force-pushed it — including a CLEAN rebase with no
//   conflicts (e.g. already-upstream sibling commits), since the merged diff
//   still differs from the reviewed head either way. The caller bumps
//   ctx.metrics.merge_auto_resolved itself, and only once the merge stage that
//   follows actually reports merged=true — a resolved-but-still-blocked PR
//   (re-conflicted again, or another preflight reason) must not inflate the
//   metric.
// =============================================================================
async function runMergeAutoResolve(ctx) {
  if (TEST_CMD === null) return { ok: true, resolved: false }
  if (STOP.tripped) return { ok: false, error: 'stopped: ' + STOP.reason }

  const probe = await stage(ctx, 'merge-preflight-probe', [
    'READ-ONLY preflight probe for PR #' + ctx.pr + ' (' + REPO + '). Run exactly:',
    mergeSettlePoll(ctx),
    'Parse the LAST JSON object printed (the freshest poll). Return its state, mergeable, and mergeStateStatus',
    'fields verbatim.',
  ].join('\n'), stageOpts('probe'), MERGE_PREFLIGHT_SCHEMA)
  if (!probe) return { ok: false, error: 'merge-preflight probe died' }
  // Only CONFLICTING is this flow's business. MERGEABLE needs no help; a
  // persistent UNKNOWN is for the merge stage's own settle-tolerant preflight
  // to decide (it runs the identical poll again right before merging).
  if (probe.mergeable !== 'CONFLICTING') return { ok: true, resolved: false }

  log('#' + ctx.issue + ' merge-auto-resolve: PR #' + ctx.pr + ' is CONFLICTING — attempting mechanical rebase before escalating')

  // ---- fetch + rebase onto the current TARGET tip ----
  const rebase = await stage(ctx, 'merge-rebase', [
    'In worktree ' + ctx.worktree + ' (branch ' + ctx.branch + '), rebase onto the current tip of ' + TARGET + '.',
    'Idempotency FIRST: git -C ' + ctx.worktree + ' status',
    'If .git/rebase-merge or .git/rebase-apply already exists in the worktree, a PRIOR attempt left a rebase in',
    'progress — do NOT run git rebase again; inspect the current conflict state (git -C ' + ctx.worktree +
    ' diff --name-only --diff-filter=U) and report status=conflicts against what is ALREADY in progress.',
    'Otherwise:',
    '  git -C ' + ctx.worktree + ' fetch origin ' + TARGET,
    '  git -C ' + ctx.worktree + ' rebase origin/' + TARGET,
    'If it completes with no conflicts (e.g. the conflicting commits are already upstream from a sibling issue,',
    'or the hunks simply do not overlap), return status=clean.',
    'If it stops on conflicts, do NOT resolve them yourself — return status=conflicts and conflicted_files',
    '(git -C ' + ctx.worktree + ' diff --name-only --diff-filter=U); a resolver stage handles them next.',
    'If it fails for any OTHER reason, run git -C ' + ctx.worktree + ' rebase --abort and return status=error',
    'with the reason.',
    'Return status (clean|conflicts|error), conflicted_files, error.',
  ].join('\n'), stageOpts('probe'), MERGE_REBASE_SCHEMA)
  if (!rebase) return { ok: false, error: 'merge-rebase stage died — worktree left as-is for human inspection' }
  if (rebase.status === 'error') return { ok: false, error: 'rebase onto ' + TARGET + ' failed: ' + (rebase.error || 'unknown reason') }

  if (rebase.status === 'conflicts') {
    const resolve = await stage(ctx, 'merge-conflict-resolve', [
      implementerBlock(null),
      '',
      'Resolve rebase conflicts for issue #' + ctx.issue + ' in worktree ' + ctx.worktree + ' (branch ' + ctx.branch +
      '), mid-rebase onto ' + TARGET + '.',
      '',
      'Idempotency FIRST: git -C ' + ctx.worktree + ' status — a prior attempt may already have resolved some',
      'hunks, or already aborted; act on the ACTUAL current state, do not assume a fresh conflict.',
      '',
      'Conflicted files: ' + ((rebase.conflicted_files || []).join(', ') || '(re-derive from git status)'),
      ctx.approach ? 'This issue\'s change intent: ' + String(ctx.approach).slice(0, 300) : '',
      notesBlock(ctx),
      '',
      'PREFER KEEPING BOTH SIDES of every hunk (e.g. two non-overlapping additions in the same file/region) over',
      'discarding either — the other side is almost always an unrelated sibling issue\'s change that already',
      'landed on ' + TARGET + '. Only collapse to one side when the hunks are genuinely the same edit twice.',
      '',
      'If ANY hunk requires judging which side is semantically correct — not just mechanically combinable — do',
      'NOT guess: git -C ' + ctx.worktree + ' rebase --abort and return status=aborted with the reason in summary.',
      '',
      'Otherwise resolve every hunk, git -C ' + ctx.worktree + ' add -A, git -C ' + ctx.worktree +
      ' rebase --continue, repeating for any further stops, until the rebase completes. Return status=resolved.',
      HANDOFF_ASK,
      'Return status (resolved|aborted), commit, files_changed, summary.',
    ].join('\n'), stageOpts('fix'), MERGE_RESOLVE_SCHEMA)
    if (!resolve) return { ok: false, error: 'conflict-resolver stage died — worktree left mid-rebase for human inspection' }
    collectNotes(ctx, 'merge-conflict-resolve', resolve)
    if (resolve.status === 'aborted') return { ok: false, error: 'conflict resolver declined a semantic conflict (rebase aborted): ' + (resolve.summary || 'no reason given') }
  }

  // ---- mandatory green tests on the EXACT rebased state (forced: must not skip) ----
  const t = await runTestLoop(ctx, true)
  if (!t.ok) return { ok: false, error: 'mandatory post-rebase test loop failed: ' + t.error }

  // ---- thrash guard: TARGET must not have moved again while tests were running.
  // A second move means the state that just went green is already stale.
  // Escalating here (rather than silently re-rebasing and force-pushing
  // UNTESTED content) is a deliberate contrarian-adjudicated choice: an earlier
  // draft of this flow re-rebased and pushed at this point instead, which would
  // have force-pushed a diff runTestLoop never actually verified. ----
  const guard = await stage(ctx, 'merge-preflight-guard', [
    'In worktree ' + ctx.worktree + ', verify ' + TARGET + ' has not moved since the rebase above:',
    '  git -C ' + ctx.worktree + ' fetch origin ' + TARGET,
    '  git -C ' + ctx.worktree + ' merge-base --is-ancestor origin/' + TARGET + ' HEAD',
    'That command exits 0 if origin/' + TARGET + ' IS an ancestor of HEAD (TARGET has not moved past what tests',
    'just verified — safe to push) and non-zero if it moved further (the just-tested state is now stale).',
    'Return moved (boolean: true if the command exited non-zero / TARGET moved further, false otherwise).',
  ].join('\n'), stageOpts('probe'), MERGE_GUARD_SCHEMA)
  if (!guard) return { ok: false, error: 'pre-force-push guard stage died' }
  if (guard.moved) {
    ctx.metrics.merge_thrash = (ctx.metrics.merge_thrash || 0) + 1
    return { ok: false, error: TARGET + ' moved again while the mandatory test loop was running — escalating rather than force-pushing a state tests never verified (thrash guard tripped)' }
  }

  // ---- force-push the tested, rebased branch ----
  const push = await stage(ctx, 'merge-force-push', [
    'In worktree ' + ctx.worktree + ' (branch ' + ctx.branch + '), push the rebased branch:',
    'Idempotency FIRST: git -C ' + ctx.worktree + ' status — if it already shows nothing to push against origin/' +
    ctx.branch + ', a prior attempt may have already pushed; that is fine, treat as success.',
    'Otherwise: git -C ' + ctx.worktree + ' push --force-with-lease origin ' + ctx.branch,
    'If the push is rejected (stale lease — someone else pushed to this branch concurrently), return status=error',
    'with the reason — do NOT retry with a plain --force.',
    'Return status (success|error), error.',
  ].join('\n'), stageOpts('probe'), MERGE_PUSH_SCHEMA)
  if (!push || push.status === 'error') return { ok: false, error: 'force-push of the rebased, tested branch failed: ' + (push && push.error || 'push stage died') }

  log('#' + ctx.issue + ' merge-auto-resolve: PR #' + ctx.pr + ' rebased onto ' + TARGET + ', tests green, force-pushed')
  return { ok: true, resolved: true }
}

// sanitizeTasks: normalize a plan agent's raw task list and drop stub tasks.
// Top-level (not closed over ctx) so tests can exercise the stub guard directly;
// still closes over IMPLEMENTERS, DEFAULT_IMPLEMENTER, and log from module scope.
function sanitizeTasks(ctx, raw) {
  // origin_issue must name an actual member of THIS unit — a hallucinated or
  // stale issue number falls back to the primary (ctx.issue), same as a
  // singleton always does (its only valid origin is ctx.issue itself).
  const validOrigins = memberIssues(ctx)
  return (raw || []).map(function (t, i) {
    const origin = (typeof t.origin_issue === 'number' && validOrigins.indexOf(t.origin_issue) !== -1) ? t.origin_issue : ctx.issue
    return {
      id: typeof t.id === 'number' ? t.id : i + 1,
      description: String(t.description || '').trim(),
      agent: IMPLEMENTERS.indexOf(t.agent) !== -1 ? t.agent : DEFAULT_IMPLEMENTER,
      origin_issue: origin,
    }
  }).filter(function (t) {
    // Stub guard: a real task description is a sentence, not a token. Dropping
    // stubs makes a stubbed plan fail the !tasks.length check and retry instead
    // of dispatching an empty task.
    if (t.description.length >= 12) return true
    if (t.description.length > 0) log('#' + ctx.issue + ' plan: DROPPED stub task ' + t.id + ' ("' + t.description + '")')
    return false
  })
}

// =============================================================================
// PROPOSECONSOLIDATION (Select-phase judgment gate; ABOVE the harness split like
// implementIssue/reviewAndMerge, so tests/harness.js can drive it with a scripted
// agent()). Takes EVERY live preflight, any resume_point — not just 'implement' —
// because the HEAL phase below must recognize a group whose members have since
// flipped to 'process_pr' (the shared PR already exists; a prior run crashed
// after creating it) or 'skip' (one member resolved independently); filtering the
// candidate set to 'implement' up front would hide those markers from healGroups()
// entirely. Only the PROPOSE phase (brand-new opus-gate groupings) is restricted
// to 'implement' candidates — see its own filter below. Proposes grouping
// candidate issues into ONE worktree/branch/research/plan/PR unit when — and only
// when — they share the same subsystem AND acceptance surface, or one explicitly
// depends on another. Grouping is the EXCEPTION: the conservative-bar prompt below
// treats "shared files touched" as a hint, never a reason, and an empty run
// (0 or 1 candidates) short-circuits for free with no agent call at all.
//
// TWO-PHASE, LIKE THE APPROACH/PLAN GATES IN implementIssue() — WITH ONE
// DELIBERATE ASYMMETRY:
//   1. HEAL: fold in any group a PRIOR run already proposed and recorded via
//      comment markers (buildConsolidationGroupComment/buildConsolidatedMemberComment,
//      see the CONSOLIDATION FOUNDATIONS block above) — a resumed run recognizes an
//      existing decision instead of re-litigating it. This runs even when
//      PROFILE.consolidation === false: turning the gate off mid-run must not
//      un-heal a group a PRIOR run already committed to.
//   2. PROPOSE + CHALLENGE: only the residual, unmarked candidates go in front of
//      the opus gate; each proposed group then runs a CAPPED contrarian challenge
//      (reusing CHALLENGE_SCHEMA and the 'contrarian' role, exactly like the
//      approach/plan gates). THE ASYMMETRY: where those gates proceed-with-caveats
//      at the cap, a contested consolidation group instead DISSOLVES back into
//      independent issues. Grouping entangles multiple issues' worktree/branch/PR
//      into one unit — an unresolved "maybe these shouldn't be one unit" is not a
//      caveat implementation can absorb the way "maybe this approach has a risk"
//      is, and the safe fallback (process each issue independently) is always
//      available — so the gate takes it instead of forcing a doubtful merge
//      through. The same reasoning is why a DEAD challenger also dissolves rather
//      than proceeding unchallenged (implementIssue's gates fail open there
//      because the issue MUST be implemented regardless; this gate is a pure
//      optimization it is always safe to skip).
//
// DRY_RUN: the marker heal and the opus PROPOSAL are read-only (gh issue view /
// --json reads only — no writes) and run exactly the same under DRY_RUN as for
// real. The CONTRARIAN CHALLENGE is skipped ENTIRELY under DRY_RUN (it posts
// trail comments) — a dry run previews the raw, PRE-CHALLENGE proposal instead
// (each such entry carries dry_run_preview: true so a caller never mistakes an
// unchallenged preview group for a finalized one).
//
// MARKERS: posting the group/member consolidation-marker comments themselves is
// deliberately NOT this function's job. Real membership is only settled after
// claims (a member can be excluded by reconcileGroups() if its claim races or its
// resume_point flips) — see reconcileGroups()/deriveUnits() above. Posting markers
// here, before claims, could stamp a marker naming a member that never actually
// joins the live unit; the post-claim materialization step (Select-phase wiring)
// owns marker posting instead.
//
// RETURN: Map<groupId, {groupId, primary, members: [issueNumbers], subsystem,
// rationale, dry_run_preview?}> — the SAME shape healGroups()/reconcileGroups()
// return, so a caller can hand it straight to reconcileGroups(map, livePreflights)
// after claims. Only ACCEPTED groups (healed, or opus-proposed + contrarian-
// accepted) appear; dissolved/never-grouped candidates are simply absent — callers
// fall them through to deriveUnits()'s ordinary singleton path, exactly like an
// issue that was never a consolidation candidate at all.
// =============================================================================

// consolidationScopeGuard: scopeGuard(ctx) is single-issue by design (see its own
// comment) — a consolidation judgment call spans MULTIPLE issues in one prompt, so
// it needs its own guard pinning gh reads/writes to the exact candidate set
// instead of pretending there is one ctx.issue.
function consolidationScopeGuard(issueNumbers) {
  return [
    '## Scope guard (ticketmill consolidation gate)',
    'You are evaluating ONLY these candidate issues of ' + REPO + ': ' + fmtIssues(issueNumbers) + '.',
    'Any gh issue view/comment/edit command MUST target one of exactly these numbers — re-read the number before',
    'running it. Other issue/PR numbers appearing anywhere in context belong to concurrent pipelines; NEVER act on them.',
    'If you post a comment, end it with the marker line "<!-- ticketmill ' + REPO + '#<issue> -->", naming the',
    'SPECIFIC issue you posted to (never a different number).',
  ].join('\n')
}

// consolidationAgent: the same safety net stage() gives single-issue calls
// (STOP.tripped short-circuit, budget/ceiling errors converted to tripStop()
// instead of propagating, BATCH.consecutiveDeaths accounted on every death),
// but for the multi-issue consolidation gate — which has no single ctx to hang
// off of, so it guards on the candidate issueNumbers list via
// consolidationScopeGuard() instead of scopeGuard(ctx). No retries (matches
// this gate's pre-hardening call shape: a death here dissolves/falls through
// to the ordinary per-issue path rather than being worth a retry budget).
// Token attribution is INTENTIONALLY deferred here: stage()'s ctx.tokens sampling
// (spentTokens() before/after, attributed to one issue's metrics) has no home at
// this gate — there is no per-issue ctx, and a group spans several issues before
// any of them has one. Consolidation-gate/challenge spend is real run spend (it
// still counts against the shared budget), just not broken out per issue in the
// batch PR's token totals; revisit if that visibility gap ever needs closing.
async function consolidationAgent(issueNumbers, label, promptText, opts, schema) {
  if (STOP.tripped) return null
  const guarded = consolidationScopeGuard(issueNumbers) + '\n\n' + promptText
  let r = null
  try {
    r = await agent(guarded, Object.assign({ label: label, phase: 'Select', schema: schema }, opts))
  } catch (e) {
    const msg = String((e && e.message) || e)
    if (isBudgetExhaustedError(msg)) return null
    log('consolidation ' + label + ' threw: ' + msg)
  }
  if (r) { BATCH.consecutiveDeaths = 0; return r }
  recordAgentDeath()
  return null
}

// fetchConsolidationMarkers: READ-ONLY (safe under DRY_RUN) — collects each
// candidate's most recent consolidation-marker comment, if any, for healGroups().
async function fetchConsolidationMarkers(issueNumbers) {
  if (!issueNumbers.length) return []
  const r = await consolidationAgent(issueNumbers, 'consolidation:marker-probe', [
    'READ-ONLY: for each issue above, check whether it carries a prior ticketmill consolidation-marker comment —',
    'one whose FIRST line is EXACTLY "' + CONSOLIDATION_MEMBER_TITLE + '" or "' + CONSOLIDATION_GROUP_TITLE + '".',
    'gh issue view <n> --repo ' + REPO + ' --json comments',
    'Return markers: [{issue, body}] — ONLY for issues carrying such a comment (its exact full body; if more than',
    'one exists on an issue, the MOST RECENT). Omit issues with none entirely.',
  ].join('\n'), stageOpts('probe'), CONSOLIDATION_MARKER_PROBE_SCHEMA)
  return (r && r.markers) || []
}

// challengeConsolidationGroup: the capped contrarian loop for ONE proposed group.
// Returns the (possibly revised) accepted group, or null if it DISSOLVED (cap
// reached without acceptance, or a dead challenger/reviser — see the module
// comment above for why this gate fails conservatively, not open).
async function challengeConsolidationGroup(group, settledCarrier) {
  let current = group
  for (let iter = 1; iter <= MAX_CONTRARIAN_ITERATIONS; iter++) {
    const groupId = stableGroupId(current.members)
    const ch = await consolidationAgent(current.members, 'consolidation:challenge-g' + groupId + '-i' + iter, [
      roleBlock('contrarian'),
      '',
      'Stress-test a PROPOSED ISSUE CONSOLIDATION for ' + REPO + ' (challenge iteration ' + iter + ').',
      'Proposed group: primary #' + current.primary + ', members ' + fmtIssues(current.members) + '.',
      'Subsystem: ' + (current.subsystem || '(none given)'),
      current.shared_surface ? 'Shared acceptance surface: ' + current.shared_surface : '',
      current.dependency ? 'Dependency: ' + current.dependency : '',
      'Rationale: ' + (current.rationale || '(none given)'),
      '',
      settledBlock(settledCarrier),
      '',
      'Read every member issue (gh issue view <n> --repo ' + REPO + ' --json title,body,comments) before judging.',
      'Apply the CONSERVATIVE bar: grouping is the EXCEPTION. A finding is MAJOR OR WORSE if the group fails the',
      'bar — same subsystem AND a genuinely shared acceptance surface (the SAME tests/endpoints/UI verify every',
      'member), OR an explicit dependency — or if "files happen to overlap" is the ONLY justification offered.',
      'Verify claims against the actual issue text; do not accept the proposal\'s framing uncritically.',
      'ACCEPTANCE: verdict "sound_with_caveats" means ZERO unresolved critical/major findings.',
      iter > 1 ? 'This is iteration ' + iter + ': the group was revised per your prior findings — check whether they are addressed.' : '',
      'Post an issue comment on #' + current.primary + ' titled "## Contrarian: Consolidation Challenge (Group ' + groupId + ', Iteration ' + iter + ')" with your verdict and findings.',
      'STRUCTURED OUTPUT CONTRACT: verdict must be EXACTLY one of sound_with_caveats | needs_rework | investigate_first.',
      'Every concern goes in the findings ARRAY (severity, summary, recommendation), never only in prose.',
    ].filter(Boolean).join('\n'), stageOpts('contrarian'), CHALLENGE_SCHEMA)

    if (!ch) {
      log('consolidation group ' + groupId + ' DISSOLVED — challenge agent died (fails conservatively, not open)')
      return null
    }
    const criticalMajor = (ch.findings || []).filter(function (f) { return f.severity === 'critical' || f.severity === 'major' }).length
    if (ch.verdict === 'sound_with_caveats' && criticalMajor === 0) {
      settleDecision(settledCarrier, 'consolidation group ' + groupId, 'consolidation challenge i' + iter,
        'group primary #' + current.primary + ' <- members ' + current.members.join(','), current.rationale, [])
      return current
    }
    log('consolidation group ' + groupId + ' challenge i' + iter + ': ' + ch.verdict + ', ' + criticalMajor + ' critical/major')
    if (iter === MAX_CONTRARIAN_ITERATIONS) {
      log('consolidation group ' + groupId + ' DISSOLVED — contrarian cap (' + MAX_CONTRARIAN_ITERATIONS + ') reached without acceptance: ' + (ch.summary || ''))
      await consolidationAgent(current.members, 'consolidation:dissolve-note-g' + groupId, [
        'Post a GitHub comment on issue #' + current.primary + ' in ' + REPO + ' (gh issue comment).',
        'Title line: "## Consolidation Dissolved After Contrarian Cap"',
        'Body: a proposed consolidation of ' + fmtIssues(current.members) +
          ' did not survive ' + MAX_CONTRARIAN_ITERATIONS + ' contrarian challenge iterations; each issue will be',
        'processed independently instead. Last challenge summary: ' + String(ch.summary || '').slice(0, 900),
        'Return posted=true/false.',
      ].join('\n'), stageOpts('probe'), NOTE_SCHEMA)
      return null
    }
    // Revise: give the opus gate one more look at just THIS group, with the
    // challenge findings in hand. Reuses CONSOLIDATION_SCHEMA (a single-group
    // response is just groups: [one] — or groups: [] if it now concludes the
    // members should not be grouped at all, which dissolves immediately rather
    // than spending remaining iterations defending an unsupported grouping).
    const re = await consolidationAgent(current.members, 'consolidation:revise-g' + groupId + '-i' + iter, [
      'Revise a proposed issue consolidation for ' + REPO + ' based on contrarian feedback (verdict: ' + ch.verdict + ').',
      'Current group: primary #' + current.primary + ', members ' + fmtIssues(current.members) + '.',
      'Findings to address:',
      (ch.findings || []).map(function (f) { return '- [' + f.severity + '] ' + f.summary + ' -> ' + (f.recommendation || '') }).join('\n'),
      'A challenger finding is a HYPOTHESIS, not a directive — verify each against the actual issues first. If, after',
      'verifying, these issues genuinely should NOT be grouped, return groups: [] and list every member issue in',
      'ungrouped instead (this ends the review — do not keep defending a grouping the evidence does not support).',
      'Otherwise return EXACTLY ONE revised group (same schema as the original gate) addressing the CONFIRMED concerns.',
      'Only consider these candidates — never introduce an issue number outside this exact set: ' + fmtIssues(current.members) + '.',
    ].join('\n'), stageOpts('consolidation'), CONSOLIDATION_SCHEMA)

    if (!re || !Array.isArray(re.groups) || !re.groups.length) {
      log('consolidation group ' + groupId + ' DISSOLVED — revision concluded no grouping (or agent died)')
      return null
    }
    const rg = re.groups[0]
    const revisedMembers = (rg.members || []).filter(function (n) { return current.members.indexOf(n) !== -1 })
    if (revisedMembers.length < 2) {
      log('consolidation group ' + groupId + ' DISSOLVED — revision shrank below a group')
      return null
    }
    current = { primary: pickPrimary(revisedMembers, rg.primary), members: revisedMembers, subsystem: rg.subsystem || current.subsystem, shared_surface: rg.shared_surface, dependency: rg.dependency, rationale: rg.rationale || current.rationale }
  }
  return null // defensive; every loop iteration above returns before falling off the end
}

// proposeConsolidation: the Select-phase entry point (see the module comment
// above for the full design). `candidates` are preflight-shaped objects
// ({issue, title, resume_point, ...}) — the caller passes EVERY live preflight
// (all resume_points), not just 'implement' ones, so HEAL below can recognize a
// group whose members have since flipped to 'process_pr' or 'skip'.
async function proposeConsolidation(candidates) {
  const list = (candidates || []).filter(function (c) { return c && c.issue })
  if (list.length <= 1) return new Map() // free-skip: nothing to group, no agent call at all

  // ---- HEAL (always runs — even with PROFILE.consolidation === false; turning the
  // gate off mid-run must not un-heal a group a PRIOR run already committed to.
  // Runs over EVERY candidate regardless of resume_point: a group whose members
  // now all resolve to 'process_pr' — the prior run created the shared PR but
  // failed/crashed before merging it — must still be recognized here, or
  // reconcileGroups()/deriveUnits() would never see it and each member would
  // splinter into its own independent process_pr singleton, all targeting the
  // SAME PR.) ----
  const markers = await fetchConsolidationMarkers(list.map(function (c) { return c.issue }))
  const healed = healGroups(list, markers)
  const healedIssues = {}
  healed.forEach(function (g) { for (const n of g.members) healedIssues[n] = true })
  // ---- PROPOSE eligibility: only FRESH 'implement' candidates can enter a brand-new
  // opus-gate grouping — an issue already resolved to 'process_pr' or 'skip' has no
  // grouping decision left to make; if it belongs to a group, HEAL above already
  // found it via markers. ----
  const residual = list.filter(function (c) { return !healedIssues[c.issue] && c.resume_point === 'implement' })
  const out = new Map(healed)

  if (!consolidationEnabled(PROFILE) || residual.length <= 1) return out

  // ---- PROPOSE (opus gate, READ-ONLY, conservative bar) ----
  const menu = residual.map(function (c) { return '- #' + c.issue + ': ' + (c.title || '(no title)') }).join('\n')
  const proposal = await consolidationAgent(residual.map(function (c) { return c.issue }), 'consolidation:propose', [
    'READ-ONLY consolidation gate for a ticketmill batch run on ' + REPO + '. Decide whether any of these candidate',
    'issues are cheaper to resolve as ONE worktree/branch/research/plan/PR unit instead of independently:',
    menu,
    '',
    'Grouping is the EXCEPTION, not the rule — most runs should return an EMPTY groups array. Group two or more',
    'issues ONLY when BOTH (a) they touch the SAME subsystem, AND (b) they share the SAME acceptance surface (the',
    'same tests/endpoints/UI would verify all of them) — OR one issue has an EXPLICIT DEPENDENCY on another',
    '(cannot be implemented or verified without it). Shared files touched is a HINT, never a REASON on its own —',
    'many unrelated issues happen to touch the same file.',
    'Read each issue first: gh issue view <n> --repo ' + REPO + ' --json title,body,comments',
    'For each group: primary (the LOWEST issue number in the group — it will carry the comment trail), members',
    '(every issue number in the group, primary included), subsystem, shared_surface OR dependency (populate',
    'whichever reason applies — at least one is REQUIRED for any group; a group with neither is invalid),',
    'rationale (1-3 concrete sentences).',
    'Every candidate issue number listed above MUST appear in EXACTLY ONE of: some group\'s members, or ungrouped.',
    'Return groups (possibly empty — that is the expected common case) and ungrouped.',
  ].join('\n'), stageOpts('consolidation'), CONSOLIDATION_SCHEMA)

  if (!proposal || !Array.isArray(proposal.groups) || !proposal.groups.length) return out // agent died, or found nothing to propose

  const rawGroups = proposal.groups
    .map(function (g) {
      const members = (g.members || []).filter(function (n) { return residual.some(function (c) { return c.issue === n }) })
      return Object.assign({}, g, { members: members, primary: pickPrimary(members, g.primary) })
    })
    .filter(function (g) { return g.members.length >= 2 })

  if (!rawGroups.length) return out

  // ---- DEDUPE (mechanical invariant enforced in code, not just the prompt above):
  // CONSOLIDATION_SCHEMA does not forbid the same issue number appearing in two
  // groups[] entries, and only the prompt instructs the opus gate to keep every
  // candidate in exactly one bucket. If it ever violates that, two Map entries would
  // claim the same issue and downstream deriveUnits() would enter it into two
  // units/branches/PRs at once. First-seen wins: a later group that shares ANY member
  // with an earlier-claimed group is dropped whole (not trimmed — trimming could
  // silently orphan its primary or shrink it below a group without another look).
  const claimedIssues = {}
  const dedupedGroups = []
  for (const g of rawGroups) {
    if (g.members.some(function (n) { return claimedIssues[n] })) {
      log('consolidation: dropping proposed group ' + fmtIssues(g.members) + ' — overlaps an already-claimed issue')
      continue
    }
    g.members.forEach(function (n) { claimedIssues[n] = true })
    dedupedGroups.push(g)
  }
  if (!dedupedGroups.length) return out

  if (DRY_RUN) {
    // DRY_RUN previews the RAW, PRE-CHALLENGE proposal — the contrarian challenge
    // posts trail comments, so it never runs under DRY_RUN (see module comment).
    for (const g of dedupedGroups) out.set(stableGroupId(g.members), toGroupEntry(g, { dry_run_preview: true }))
    return out
  }

  // ---- CHALLENGE (capped; cap DISSOLVES — see module comment for the asymmetry) ----
  const consSettled = { settled: [] } // local carrier — reuses settleDecision()/settledBlock(); no per-issue ctx exists at this gate
  for (const g of dedupedGroups) {
    const accepted = await challengeConsolidationGroup(g, consSettled)
    if (!accepted) continue // dissolved — members fall through to the caller's ordinary singleton path
    out.set(stableGroupId(accepted.members), toGroupEntry(accepted))
  }
  return out
}

// postConsolidationMarkers: post the group-membership marker on a materialized
// group's PRIMARY (buildConsolidationGroupComment) and the absorbed-member marker
// on every OTHER live member (buildConsolidatedMemberComment). Deliberately called
// only AFTER Select-phase materialization (deriveUnits over the reconciled map +
// live post-claim preflights) — see proposeConsolidation()'s module comment: real
// membership is only settled post-claim, so posting any earlier could name a
// member that never actually joins the live unit. Idempotent across resumes: each
// post is instructed to first check for an existing marker (same pattern as
// implementIssue()'s setup stage, "SKIP the comment if one with that exact title
// already exists") so a resumed run's re-heal of an already-marked group never
// double-posts. `units` is the array runPool() is about to process; singletons
// (groupId null, or fewer than 2 live members) are silently skipped.
async function postConsolidationMarkers(units) {
  const groups = (units || []).filter(function (u) { return u && u.groupId != null && Array.isArray(u.members) && u.members.length >= 2 })
  for (const u of groups) {
    const memberIssueNums = u.members.map(function (m) { return m.issue })
    const groupBody = buildConsolidationGroupComment(REPO, u.issue, u.groupId, memberIssueNums, u.subsystem, u.rationale)
    await consolidationAgent(memberIssueNums, 'consolidation:mark-primary-g' + u.groupId, [
      'Post the consolidation GROUP marker comment on issue #' + u.issue + ' of ' + REPO + '.',
      'FIRST check whether it already exists: gh issue view ' + u.issue + ' --repo ' + REPO + ' --json comments',
      '— SKIP posting if any comment\'s first line is exactly "' + CONSOLIDATION_GROUP_TITLE + '" and it contains',
      '"group: ' + u.groupId + '" (resumed run; already posted).',
      'Otherwise post EXACTLY this body verbatim, unchanged (gh issue comment ' + u.issue + ' --repo ' + REPO + ' --body):',
      '"""',
      groupBody,
      '"""',
      'Return posted (true if you posted it now, false if it already existed).',
    ].join('\n'), stageOpts('probe'), NOTE_SCHEMA)

    for (const m of u.members) {
      if (m.issue === u.issue) continue // the primary carries the group marker, not a member marker
      const memberBody = buildConsolidatedMemberComment(REPO, m.issue, u.issue, u.groupId, u.rationale)
      await consolidationAgent([m.issue], 'consolidation:mark-member-' + m.issue, [
        'Post the consolidation MEMBER marker comment on issue #' + m.issue + ' of ' + REPO + '.',
        'FIRST check whether it already exists: gh issue view ' + m.issue + ' --repo ' + REPO + ' --json comments',
        '— SKIP posting if any comment\'s first line is exactly "' + CONSOLIDATION_MEMBER_TITLE + '" (resumed run;',
        'already posted).',
        'Otherwise post EXACTLY this body verbatim, unchanged (gh issue comment ' + m.issue + ' --repo ' + REPO + ' --body):',
        '"""',
        memberBody,
        '"""',
        'Return posted (true if you posted it now, false if it already existed).',
      ].join('\n'), stageOpts('probe'), NOTE_SCHEMA)
    }
  }
}

// =============================================================================
// IMPLEMENT (setup -> research -> evaluate<->contrarian -> plan<->contrarian ->
// tasks with review/quality loops -> test loop -> browser -> docblocks -> PR)
// Returns null on success (ctx.pr set), or a failure result object.
// =============================================================================
async function implementIssue(ctx) {
  // ---- SETUP (deterministic script; idempotent) ----
  const setupScript = ROOT + '/.claude/scripts/ticketmill/setup-worktree.sh'
  const envFiles = PROFILE.env_files || []
  const installCmds = PROFILE.install_commands || []
  // A group's worktree/branch/PR identity is bound to its stable groupId, never
  // the mutable logical primary (ctx.issue) — see worktreeAnchor()'s comment.
  // For a singleton, anchor === ctx.issue, so this is a no-op.
  const anchor = worktreeAnchor(ctx)
  const setup = await stage(ctx, 'setup', [
    'Set up the git worktree for issue #' + ctx.issue + ' (ticketmill workflow).',
    '',
    '0. Fetch the batch integration branch first: git -C ' + ROOT + ' fetch origin ' + TARGET,
    '1. Run exactly, from ' + ROOT + ', and capture its single-line JSON output:',
    '   ' + setupScript + ' ' + anchor + ' ' + TARGET + ' ' + ROOT + ' ' + WORKTREES + ' ' + REPO,
    '   (Idempotent: reuses an existing worktree already on an issue-' + anchor + '-* branch.)',
    '2. If success, make the worktree bootable:',
    envFiles.length
      ? '   - Copy env files from the root checkout if missing in the worktree: ' + envFiles.map(function (f) { return 'cp -n ' + ROOT + '/' + f + ' <worktree>/' + f + ' 2>/dev/null || true' }).join('; ')
      : '   - (no env_files declared in the profile)',
    installCmds.length
      ? '   - Run the project install commands IN THE WORKTREE, and REPORT any that fail (do not swallow errors):\n' +
        installCmds.map(function (c) { return '     cd <worktree> && ' + c }).join('\n')
      : '   - (no install_commands declared in the profile)',
    '   - Discard dependency-install churn so it cannot leak into task commits: from the worktree,',
    '     git checkout -- . for lockfiles ONLY if install commands modified them (check git status first).',
    '3. Self-assign the issue (non-blocking): gh issue edit ' + ctx.issue + ' --repo ' + REPO + ' --add-assignee @me',
    '4. Post an issue comment "## Starting Automated Processing" naming the batch branch ' + TARGET + ' (integration',
    '   target; final human-reviewed PR goes ' + TARGET + ' -> ' + BASE + ') and the pipeline',
    '   (research, evaluate + contrarian, plan + contrarian, tasks with quality loops, tests, docs, PR, review, merge).',
    '   SKIP the comment if one with that exact title already exists (resumed run).',
    'Return status, worktree, branch (from the script JSON), or status=error with error.',
  ].join('\n'), stageOpts('setup'), SETUP_SCHEMA)
  if (!setup) return fail(ctx, 'halted', 'setup', 'setup agent died')
  if (setup.status !== 'success' || !setup.worktree) return fail(ctx, 'failed', 'setup', setup.error || 'setup script failed')
  ctx.worktree = setup.worktree
  ctx.branch = setup.branch

  // ---- RESEARCH ----
  // Group unit: read EVERY member's issue, not just the primary — and keep each
  // member's requirements attributed to its own issue number rather than blended
  // into one synthesized narrative, so a task can later be traced back to the
  // member issue that drove it (see the plan stage's origin_issue tagging below).
  const isGroupUnit = ctx.members.length > 1
  const researchIssueStep = isGroupUnit
    ? '1. This is a CONSOLIDATED GROUP unit — read EVERY member issue AND its comments, not just the primary:\n' +
      ctx.members.map(function (m) { return '   gh issue view ' + m.issue + ' --repo ' + REPO + ' --json title,body,comments' }).join('\n')
    : '1. Read the issue AND all comments: gh issue view ' + ctx.issue + ' --repo ' + REPO + ' --json title,body,comments'
  const researchLines = [
    'Research context for issue #' + ctx.issue + ' of ' + REPO + '. Read-only exploration in worktree ' + ctx.worktree + '.',
    '',
    researchIssueStep,
    '2. Check prior PRs referencing it: gh pr list --repo ' + REPO + ' --state all --search "' + ctx.issue + '" --json number,title,state,body',
    '3. If prior work exists (implementation comments, closed/rejected PRs, review feedback): summarize what was',
    '   attempted, the outcome, what to preserve vs change.',
    '4. Check for a partial prior run: git -C ' + ctx.worktree + ' log --oneline origin/' + TARGET + '..HEAD',
    '   List existing commits in prior_work — downstream stages MUST build on them, not redo them.',
    '5. Explore related files and code structure; identify dependencies and related components. Read the target',
    '   project\'s CLAUDE.md for conventions that constrain the solution.',
    'You may also use WebSearch/WebFetch (load via ToolSearch) for external references the issue depends on',
    '(regulations, vendor docs, upstream APIs) — cite fetched URLs in the context you return.',
    bwFeedback(ctx),
  ]
  if (isGroupUnit) {
    researchLines.push(
      'Return context.issue_body as PER-MEMBER sections tagged by issue number (e.g. "#' + ctx.members[0].issue +
      ': ...", "#' + ctx.members[1].issue + ': ..." for every member) — do NOT synthesize one blended narrative;',
      'downstream stages need to trace a requirement back to the member issue it came from.'
    )
  }
  researchLines.push('Return status, context {issue_title, issue_body (brief requirements), related_files, dependencies, prior_work}.')
  const research = await stage(ctx, 'research', researchLines.join('\n'), stageOpts('research'), RESEARCH_SCHEMA)
  if (!research) return fail(ctx, 'halted', 'research', 'research agent died')
  if (research.status === 'error') return fail(ctx, 'failed', 'research', research.error || 'research failed')
  const rc = research.context || {}
  pushDecision(ctx, 'Research', '**Issue:** ' + (rc.issue_title || ctx.title || '') + '\n**Requirements:** ' + (rc.issue_body || '') +
    '\n**Related files:** ' + (rc.related_files || []).join(', ') + '\n**Prior work:** ' + (rc.prior_work || 'none'))

  // ---- EVALUATE + CONTRARIAN CHALLENGE (approach) ----
  let evalR = await stage(ctx, 'evaluate', [
    'Evaluate the best implementation approach for issue #' + ctx.issue + '.',
    '',
    '## Decision chain', decisionChain(ctx), '',
    'Determine: (1) recommended approach — if prior work exists, how this builds on or diverges from it;',
    '(2) rationale; (3) risks; (4) alternatives considered; (5) if prior attempts failed, how this addresses that feedback.',
    'Also classify complexity: "trivial" (mechanical/text-only/config edits with no behavior risk),',
    '"standard" (typical feature or fix), "complex" (architecture, data integrity, security, or multi-system).',
    'Trivial issues get a lighter adversarial-review pipeline — classify honestly, not defensively.',
    'Post an issue comment "## Evaluation: Best Path" with the approach + rationale (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
    'Return status ("success", or "error" ONLY for genuinely blocking problems), approach, rationale, complexity,',
    'risks, alternatives_rejected (each rejected alternative with its one-line rejection reason), summary.',
  ].join('\n'), stageOpts('evaluate'), EVALUATE_SCHEMA)
  if (!evalR) return fail(ctx, 'halted', 'evaluate', 'evaluate agent died')
  if (evalR.status !== 'success') return fail(ctx, 'blocked', 'evaluate', evalR.error || 'evaluation found blocking issues — human review required')
  ctx.approach = evalR.approach || ''
  pushDecision(ctx, 'Evaluate', '**Approach:** ' + (evalR.approach || '') + '\n**Rationale:** ' + (evalR.rationale || '') + '\n' + (evalR.summary || ''))

  // Proportional adversarial depth: trivial issues get TWO challenge iterations per
  // gate — enough for one challenge + one revision + one re-check. Cap 1 would skip
  // the revision cycle entirely; the full cap on a docs-only issue burns opus time
  // re-litigating settled trade-offs.
  const complexity = evalR.complexity || 'standard'
  const challengeCap = contrarianCapFor(complexity)
  if (complexity === 'trivial') log('#' + ctx.issue + ' classified trivial — contrarian caps reduced to ' + challengeCap + ' iteration(s) per gate')

  const misfiledCheck = [
    'MISFILED-COMMENT CHECK: workflow comments end with a marker line "<!-- ticketmill <repo>#<issue> -->".',
    'While reading the trail, if any comment\'s marker names a DIFFERENT issue than #' + ctx.issue + ', it was misfiled',
    'here by a concurrent pipeline: delete it (find its id via gh api repos/' + REPO + '/issues/' + ctx.issue + '/comments,',
    'then gh api -X DELETE repos/' + REPO + '/issues/comments/<id>), note the deletion in your posted comment, and',
    'ignore its content entirely. Comments with a matching marker or no marker are legitimate — leave them alone.',
  ].join('\n')

  let approachCaveats = []
  for (let iter = 1; iter <= challengeCap; iter++) {
    ctx.metrics.approach_iters = iter
    const ch = await stage(ctx, 'challenge-approach-i' + iter, [
      roleBlock('contrarian'),
      '',
      'Stress-test the proposed implementation approach for issue #' + ctx.issue + ' (challenge iteration ' + iter + ').',
      '',
      '## Decision chain', decisionChain(ctx), '',
      'The evaluate stage proposed:',
      'Approach: ' + (evalR.approach || ''), 'Rationale: ' + (evalR.rationale || ''), '',
      'FIRST read the full pipeline trail — gh issue view ' + ctx.issue + ' --repo ' + REPO + ' --comments — it is the',
      'uncompressed record; the decision chain above is only a digest. Prior contrarian comments at ANY gate count',
      'as prior adjudication: do not re-raise findings resolved or rebutted there unless you cite NEW evidence.',
      misfiledCheck,
      learn('quality_loop'),
      learn('performance'),
      'Apply the Tenth Man Rule — assume the consensus approach may be wrong and investigate that world.',
      'Steel-man first, then assumption audit, pre-mortem, inversion, second-order effects.',
      'VERIFY before asserting: rate a finding critical/major ONLY after confirming the failure path actually',
      'executes (e.g. that a script is really invoked, a branch really exists) — cite the check you ran.',
      'BE RIGOROUS but CALIBRATED — severity must be earned: critical = data loss / security / broken deploy;',
      'major = wrong behavior, missing requirement, or an unworkable step; minor = everything else (style, hygiene,',
      'process). For trivial/mechanical changes, ZERO critical/major findings is an expected, acceptable outcome —',
      'do NOT inflate severity to justify rework. Judge against the ISSUE REQUIREMENTS; do not raise findings about',
      'process artifacts (plan files, comment formatting, branch hygiene) unless they break the deliverable.',
      'ACCEPTANCE: verdict "sound_with_caveats" means ZERO unresolved critical/major findings. If any remain you',
      'MUST use needs_rework or investigate_first. Minor findings alone are acceptable.',
      iter > 1 ? 'This is iteration ' + iter + ': the approach was revised per your prior findings — focus on whether revisions address them; do not re-raise resolved issues.' : '',
      'Working directory (read-only): ' + ctx.worktree,
      'Post an issue comment "## Contrarian: Approach Challenge (Iteration ' + iter + ')" with your verdict and findings.',
      'STRUCTURED OUTPUT CONTRACT: verdict must be EXACTLY one of sound_with_caveats | needs_rework | investigate_first.',
      'Every concern goes in the findings ARRAY (objects with severity, summary, recommendation — keep each field to',
      '2-3 sentences), never only in prose. Keep summary under 200 words so the output stays well-formed.',
    ].join('\n'), stageOpts('contrarian'), CHALLENGE_SCHEMA)
    if (!ch) { log('#' + ctx.issue + ' contrarian(approach) died — proceeding with unchallenged approach (logged)'); pushDecision(ctx, 'Contrarian: Approach', 'SKIPPED — contrarian agent unavailable'); break }

    approachCaveats = ch.caveats || []
    const criticalMajor = (ch.findings || []).filter(function (f) { return f.severity === 'critical' || f.severity === 'major' }).length
    if (ch.verdict === 'sound_with_caveats' && criticalMajor === 0) {
      pushDecision(ctx, 'Contrarian: Approach Challenge', '**Verdict:** sound_with_caveats (iteration ' + iter + ')\n' +
        (approachCaveats.length ? '**Caveats:**\n- ' + approachCaveats.join('\n- ') : 'No caveats'))
      settleDecision(ctx, 'implementation approach', 'approach challenge i' + iter,
        evalR.approach, evalR.rationale, evalR.alternatives_rejected)
      break
    }
    log('#' + ctx.issue + ' contrarian(approach) i' + iter + ': ' + ch.verdict + ', ' + criticalMajor + ' critical/major — re-evaluating')
    if (iter === challengeCap) {
      pushDecision(ctx, 'Contrarian: Approach Challenge', 'Iteration cap (' + challengeCap + ') reached — proceeding WITH UNRESOLVED CAVEATS:\n' + (ch.summary || ''))
      for (const f of (ch.findings || [])) {
        if (f.severity === 'critical' || f.severity === 'major') {
          ctx.unresolved.push('[approach gate, ' + f.severity + '] ' + f.summary + ' -> ' + (f.recommendation || ''))
        }
      }
      VERIFY_SKIPS.push('#' + ctx.issue + ': approach challenge capped at ' + challengeCap + ' iterations with unresolved caveats: ' + oneLine(ch.summary || '').slice(0, 200))
      const capNote = await stage(ctx, 'cap-note-approach', [
        'Post a GitHub comment on issue #' + ctx.issue + ' in ' + REPO + ' (gh issue comment).',
        'Title line: "## Proceeding After Contrarian Cap (Approach)"',
        'Body: the approach challenge hit its ' + challengeCap + '-iteration cap without full acceptance;',
        'implementation continues with these unresolved caveats carried into the decision chain:',
        String(ch.summary || '').slice(0, 900),
        'Return posted=true/false.',
      ].join('\n'), stageOpts('probe'), NOTE_SCHEMA, 1)
      if (!capNote || !capNote.posted) log('#' + ctx.issue + ' cap note (approach) did not post — caveats live in the decision chain only')
      break
    }
    const re = await stage(ctx, 're-evaluate-i' + iter, [
      'Revise the implementation approach for issue #' + ctx.issue + ' based on contrarian feedback (verdict: ' + ch.verdict + '):',
      '', String(ch.summary || ''), '',
      'Findings to address:',
      (ch.findings || []).map(function (f) { return '- [' + f.severity + '] ' + f.summary + ' -> ' + (f.recommendation || '') }).join('\n'),
      '',
      'Your prior approach: ' + (evalR.approach || ''),
      'A challenger finding is a HYPOTHESIS, not a directive: verify each against the actual tree/state first.',
      'Adopt it if confirmed; REBUT it with concrete evidence if wrong. Do not capitulate to an unverified claim —',
      'gates oscillate precisely when a wrong Major is adopted without verification.',
      'Revise to address the CONFIRMED concerns: mitigate risks, justify challenged assumptions, adopt alternatives, or accept risks with mitigation plans.',
      'Post an issue comment "## Revised Evaluation (after contrarian iteration ' + iter + ')".',
      'Return status, approach, rationale, risks, alternatives_rejected, summary.',
    ].join('\n'), stageOpts('evaluate'), EVALUATE_SCHEMA)
    if (!re || re.status !== 'success') { log('#' + ctx.issue + ' re-evaluate failed — proceeding with caveats'); break }
    evalR = re
    ctx.approach = re.approach || ctx.approach
    pushDecision(ctx, 'Revised Evaluation (i' + iter + ')', '**Approach:** ' + (re.approach || '') + '\n' + (re.summary || ''))
  }

  // ---- PLAN + CONTRARIAN CHALLENGE (plan) ----
  const agentMenu = IMPLEMENTERS.length
    ? IMPLEMENTERS.map(function (n) {
        const d = AGENT_INFO[n] && AGENT_INFO[n].description ? AGENT_INFO[n].description : '(no description)'
        return '- ' + n + ': ' + String(d).slice(0, 240)
      }).join('\n')
    : '- implementer: built-in generalist software engineer charter (this project declared no implementer agents)'
  // Group unit: each task must be tagged with origin_issue — the member issue
  // whose requirement drives it — so downstream (task-implement prompts) can
  // reference the issue a task actually originated from instead of always the
  // primary. Singleton: identical to the original single-line instruction.
  // (isGroupUnit is declared once above, in the RESEARCH section — reused here.)
  const taskBreakdownLine = isGroupUnit
    ? 'Break the work into ordered tasks with agent assignments. Each task: {id, description, agent, origin_issue}\n' +
      '  — origin_issue is the member issue number (from the group members list above) whose requirement drives\n' +
      '  that task; use the primary #' + ctx.issue + ' only for cross-cutting work not specific to one member.'
    : 'Break the work into ordered tasks with agent assignments. Each task: {id, description, agent}.'
  const planPromptFor = function (revision) {
    const lines = [
      // Both variants anchor the worktree/branch explicitly — an unanchored
      // revision prompt once committed plan docs to the session's checked-out branch.
      revision ? 'Revise the implementation plan for issue #' + ctx.issue + ' (worktree ' + ctx.worktree + ', branch ' + ctx.branch + ') based on contrarian feedback below.' :
        'Create an implementation plan for issue #' + ctx.issue + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + '.',
      '',
      '## Decision chain', decisionChain(ctx),
      settledBlock(ctx), '',
      revision || '',
    ]
    if (isGroupUnit) lines.push('This is a CONSOLIDATED GROUP unit spanning member issues: ' + fmtIssues(memberIssues(ctx)) + '.')
    lines.push(
      taskBreakdownLine,
      'Available agents (from the target project\'s own roster):',
      agentMenu,
      IMPLEMENTERS.length ? 'Assign each task\'s "agent" to exactly one of those names.' : 'Set each task\'s "agent" to "implementer".',
      LEARN ? [learn('agent_selection'), learn('workflow')].filter(Boolean).join('\n')
        : 'Prior-run learnings: if ' + LOGS + '/process-retrospective.md exists, read its "## Active Learnings" section and apply it to agent selection and task decomposition.',
      'Account for existing commits on the branch (a resumed run) — do not plan tasks that redo committed work.',
      'For trivial/mechanical issues prefer 1-2 tasks, and fold acceptance verification (greps, diff checks) into',
      'the implementing task itself — do NOT create a separate verification-only task.',
      'Do NOT commit plan or verification-result documents to the repository — they land in the PR diff as noise.',
      'The issue comments are the plan of record; keep any scratch files untracked.',
      'Post TWO issue comments: first plan -> "## Implementation Plan" (summary + collapsible full plan) and',
      '"## Task List" (checkbox markdown); a revision -> "## Revised Implementation Plan (iteration N)" and',
      '"## Revised Task List (iteration N)" so the trail shows which is current.',
      'Return status, plan_path (empty string — plans are not files), tasks, summary, task_list_markdown.'
    )
    return lines.join('\n')
  }

  let planR = await stage(ctx, 'plan', planPromptFor(null), stageOpts('plan'), PLAN_SCHEMA)
  if (!planR) return fail(ctx, 'halted', 'plan', 'plan agent died')
  if (planR.status !== 'success') return fail(ctx, 'failed', 'plan', planR.error || 'planning failed')

  let tasks = sanitizeTasks(ctx, planR.tasks)
  if (!tasks.length) return fail(ctx, 'failed', 'plan', 'plan produced no tasks')
  pushDecision(ctx, 'Plan', (planR.summary || '') + '\n**Tasks:**\n' + tasks.map(function (t) { return '- ' + t.id + ' [' + (t.agent || 'implementer') + '] ' + t.description }).join('\n'))

  for (let iter = 1; iter <= challengeCap; iter++) {
    ctx.metrics.plan_iters = iter
    const ch = await stage(ctx, 'challenge-plan-i' + iter, [
      roleBlock('contrarian'),
      '',
      'Stress-test the implementation plan for issue #' + ctx.issue + ' (challenge iteration ' + iter + ').',
      '',
      '## Decision chain', decisionChain(ctx), '',
      'The plan proposes these tasks:',
      tasks.map(function (t) { return '- Task ' + t.id + ' [' + (t.agent || 'implementer') + ']: ' + t.description }).join('\n'),
      '',
      'Plan summary: ' + (planR.summary || ''),
      approachCaveats.length ? 'Caveats from the approach challenge this plan must address:\n- ' + approachCaveats.join('\n- ') : '',
      settledBlock(ctx),
      '',
      'FIRST read the full pipeline trail — gh issue view ' + ctx.issue + ' --repo ' + REPO + ' --comments — it is the',
      'uncompressed record; the decision chain above is only a digest. Prior contrarian comments at ANY gate count',
      'as prior adjudication: do not re-raise findings resolved or rebutted there unless you cite NEW evidence.',
      misfiledCheck,
      learn('quality_loop'),
      learn('performance'),
      'BE RIGOROUS but CALIBRATED. Focus on: task decomposition (too large/small/missing steps), ordering and',
      'dependencies, agent assignments, missing tasks, second-order effects, data-integrity risks, test-coverage gaps.',
      'Severity must be earned: critical = data loss/security/broken deploy; major = a task that produces wrong',
      'behavior or a missing requirement; minor = everything else. For trivial/mechanical plans, ZERO critical/major',
      'findings is an expected outcome — do NOT inflate severity. Judge the TASK SET against the issue requirements;',
      'do not block on process artifacts (plan-file wording, comment formatting, plan-vs-comment divergence).',
      'ACCEPTANCE: "sound_with_caveats" requires ZERO unresolved critical/major findings.',
      iter > 1 ? 'This is iteration ' + iter + ': the plan was revised per your prior findings — check whether they are addressed.' : '',
      'Working directory (read-only): ' + ctx.worktree,
      'Post an issue comment "## Contrarian: Plan Stress Test (Iteration ' + iter + ')".',
      'STRUCTURED OUTPUT CONTRACT: verdict must be EXACTLY one of sound_with_caveats | needs_rework | investigate_first.',
      'Every concern goes in the findings ARRAY (objects with severity, summary, recommendation — keep each field to',
      '2-3 sentences), never only in prose. Keep summary under 200 words so the output stays well-formed.',
    ].join('\n'), stageOpts('contrarian'), CHALLENGE_SCHEMA)
    if (!ch) { log('#' + ctx.issue + ' contrarian(plan) died — proceeding with unchallenged plan (logged)'); pushDecision(ctx, 'Contrarian: Plan', 'SKIPPED — contrarian agent unavailable'); break }

    const criticalMajor = (ch.findings || []).filter(function (f) { return f.severity === 'critical' || f.severity === 'major' }).length
    if (ch.verdict === 'sound_with_caveats' && criticalMajor === 0) {
      pushDecision(ctx, 'Contrarian: Plan Challenge', '**Verdict:** sound_with_caveats (iteration ' + iter + ')' +
        ((ch.caveats || []).length ? '\n**Caveats:**\n- ' + ch.caveats.join('\n- ') : ''))
      settleDecision(ctx, 'task plan (' + tasks.length + ' tasks)', 'plan challenge i' + iter, planR.summary,
        (ch.caveats || []).length ? 'accepted with caveats: ' + ch.caveats.join('; ') : 'accepted without caveats', [])
      break
    }
    if (iter === challengeCap) {
      pushDecision(ctx, 'Contrarian: Plan Challenge', 'Iteration cap (' + challengeCap + ') reached — proceeding WITH UNRESOLVED CAVEATS:\n' + (ch.summary || ''))
      for (const f of (ch.findings || [])) {
        if (f.severity === 'critical' || f.severity === 'major') {
          ctx.unresolved.push('[plan gate, ' + f.severity + '] ' + f.summary + ' -> ' + (f.recommendation || ''))
        }
      }
      VERIFY_SKIPS.push('#' + ctx.issue + ': plan challenge capped at ' + challengeCap + ' iterations with unresolved caveats: ' + oneLine(ch.summary || '').slice(0, 200))
      const capNote = await stage(ctx, 'cap-note-plan', [
        'Post a GitHub comment on issue #' + ctx.issue + ' in ' + REPO + ' (gh issue comment).',
        'Title line: "## Proceeding After Contrarian Cap (Plan)"',
        'Body: the plan challenge hit its ' + challengeCap + '-iteration cap without full acceptance;',
        'implementation proceeds with the current task set and these unresolved caveats in the decision chain:',
        String(ch.summary || '').slice(0, 900),
        'Return posted=true/false.',
      ].join('\n'), stageOpts('probe'), NOTE_SCHEMA, 1)
      if (!capNote || !capNote.posted) log('#' + ctx.issue + ' cap note (plan) did not post — caveats live in the decision chain only')
      break
    }
    const rp = await stage(ctx, 're-plan-i' + iter, planPromptFor(
      'Contrarian verdict on the current plan: ' + ch.verdict + '\n\n' + (ch.summary || '') + '\n\nFindings:\n' +
      (ch.findings || []).map(function (f) { return '- [' + f.severity + '] ' + f.summary + ' -> ' + (f.recommendation || '') }).join('\n') +
      '\n\nPrior tasks:\n' + tasks.map(function (t) { return '- ' + t.id + ' [' + (t.agent || 'implementer') + '] ' + t.description }).join('\n') +
      '\n\nA challenger finding is a HYPOTHESIS, not a directive: verify each against the actual tree/state, then' +
      ' adopt it or rebut it with concrete evidence. If your revision overturns a decision listed as adjudicated,' +
      ' cite the new evidence justifying the overturn in the summary.' +
      '\n\nRevise: add missing tasks, reorder for dependencies, reassign agents, split/merge tasks, address caveats concretely.'
    ), stageOpts('plan'), PLAN_SCHEMA)
    if (!rp || rp.status !== 'success') { log('#' + ctx.issue + ' re-plan failed — proceeding with current plan'); break }
    planR = rp
    const revised = sanitizeTasks(ctx, rp.tasks)
    if (revised.length) tasks = revised
    pushDecision(ctx, 'Revised Plan (i' + iter + ')', (rp.summary || '') + '\n**Tasks:**\n' + tasks.map(function (t) { return '- ' + t.id + ' [' + (t.agent || 'implementer') + '] ' + t.description }).join('\n'))
  }

  // ---- IMPLEMENT (sequential per-task: implement -> review -> fix loop -> quality loop) ----
  let tasksCompleted = 0
  const failedTasks = []
  for (let ti = 0; ti < tasks.length; ti++) {
    if (STOP.tripped) return fail(ctx, 'halted', 'implement', 'stopped: ' + STOP.reason)
    const task = tasks[ti]

    // Unresolved cap-out findings ride into the FIRST task structurally, not just
    // as a decision-chain digest.
    const unresolvedBlock = (ti === 0 && ctx.unresolved.length)
      ? '## Unresolved critical/major findings from capped contrarian gates\n' +
        ctx.unresolved.map(function (u) { return '- ' + u }).join('\n') +
        '\nResolve or explicitly verify each of these FIRST — they were never accepted, only carried past the iteration cap.'
      : ''
    // A group task's origin_issue names the member issue whose requirement drove
    // it (defaults to ctx.issue for a singleton, so the clause below never fires
    // there — the line stays byte-for-byte identical).
    const originNote = (task.origin_issue && task.origin_issue !== ctx.issue) ? ' (originating from member issue #' + task.origin_issue + ')' : ''
    const impl = await stage(ctx, 'task-' + task.id + '-implement', [
      implementerBlock(task.agent),
      '',
      'Implement task ' + task.id + ' for issue #' + ctx.issue + originNote + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + ':',
      '',
      task.description,
      '',
      '## Decision chain (context from prior stages)', decisionChain(ctx),
      unresolvedBlock,
      notesBlock(ctx), '',
      'FIRST check git -C ' + ctx.worktree + ' log --oneline origin/' + TARGET + '..HEAD — if a prior run already',
      'implemented part or all of this task, verify it works and build on it instead of redoing it.',
      'Commit with a descriptive conventional-commit message referencing issue #' + ctx.issue + '.',
      'After committing, post an issue comment (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ') titled',
      '"## Task ' + task.id + ' Implemented" with the commit SHA and a 2-3 line summary — this keeps the issue',
      'audit trail alive during the implementation phase.',
      COMMIT_SHA_ASK,
      bwFeedback(ctx),
      HANDOFF_ASK,
      'Return status, commit (SHA), files_changed, summary.',
    ].join('\n'), stageOpts('implement'), IMPL_SCHEMA)
    if (!impl) { failedTasks.push(task.id); log('#' + ctx.issue + ' task ' + task.id + ': implement died — task failed'); continue }
    if (impl.status !== 'success') { failedTasks.push(task.id); log('#' + ctx.issue + ' task ' + task.id + ': implement error — task failed'); continue }
    collectNotes(ctx, 'task-' + task.id, impl)

    let approved = false
    let lastComments = ''
    for (let attempt = 1; attempt <= MAX_TASK_REVIEW_ATTEMPTS; attempt++) {
      ctx.metrics.task_review_attempts++
      const rv = await stage(ctx, 'task-' + task.id + '-review-a' + attempt, [
        roleBlock('task_reviewer'),
        '',
        'Review the implementation of task ' + task.id + ' for issue #' + ctx.issue + ' (commit ' + (impl.commit || 'HEAD') + ') in worktree ' + ctx.worktree + '.',
        '',
        'Task description: ' + task.description, '',
        '## Decision chain', decisionChain(ctx), '',
        'Did the implementation achieve the task goal? Inspect the actual diff: git -C ' + ctx.worktree + ' diff origin/' + TARGET + '...HEAD',
        'Set suggested_improvements=yes ONLY for concrete, actionable follow-up work (a specific change someone',
        'could implement) — never for confirmations, verification results, or praise.',
        'Post an issue comment "## Task ' + task.id + ' Review (attempt ' + attempt + ')" with the result (passed/failed)',
        'and key comments in 2-5 lines (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
        'Return result (passed|failed), suggested_improvements (yes|no), comments.',
      ].join('\n'), stageOpts('taskReview'), TASK_REVIEW_SCHEMA)
      if (!rv) {
        // reviewer unavailable: keep the work, defer judgment to the PR-level reviews
        log('#' + ctx.issue + ' task ' + task.id + ': reviewer died — accepting provisionally (PR reviews still gate merge)')
        ctx.deferred.push('Task ' + task.id + ': task-review skipped (reviewer unavailable) — extra scrutiny needed at PR review')
        approved = true
        break
      }
      lastComments = rv.comments || ''
      if (rv.result === 'passed') {
        approved = true
        if (rv.suggested_improvements === 'yes' && lastComments) {
          ctx.deferred.push('Task ' + task.id + ' (' + task.description.slice(0, 80) + '): ' + lastComments.slice(0, 500))
        }
        break
      }
      if (attempt === MAX_TASK_REVIEW_ATTEMPTS) break
      const fx = await stage(ctx, 'task-' + task.id + '-fix-a' + attempt, [
        implementerBlock(task.agent),
        '',
        'Fix issues in task ' + task.id + ' for issue #' + ctx.issue + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + ':',
        '',
        'Review feedback:', lastComments || 'No comments', '',
        fixContext(ctx, task.description),
        'After committing, post an issue comment "## Task ' + task.id + ' Review Fix (attempt ' + attempt + ')" with the',
        'commit SHA and what was addressed in 2-4 lines (gh issue comment ' + ctx.issue + ' --repo ' + REPO + ').',
        COMMIT_SHA_ASK,
        bwFeedback(ctx),
        HANDOFF_ASK,
        'Address the issues and commit. Return status, commit, files_changed, fixes_applied, summary.',
      ].join('\n'), stageOpts('fix'), FIX_SCHEMA)
      if (!fx || fx.status === 'error') break
      collectNotes(ctx, 'task-' + task.id + '-fix', fx)
    }

    if (!approved) {
      failedTasks.push(task.id)
      pushDecision(ctx, 'Task ' + task.id + ' FAILED', 'Cap-exited after ' + MAX_TASK_REVIEW_ATTEMPTS + ' review attempts. Last feedback: ' + lastComments.slice(0, 400))
      await postNote(ctx, 'task-' + task.id, 'task-failed', 'Task failed review after ' + MAX_TASK_REVIEW_ATTEMPTS + ' attempts: ' + task.description.slice(0, 200))
      continue
    }

    tasksCompleted++
    pushDecision(ctx, 'Task ' + task.id + ' Complete', '**' + task.description.slice(0, 200) + '**\nCommit: ' + (impl.commit || 'n/a') + '\n' + (impl.summary || ''))

    const q = await runQualityLoop(ctx, 'task-' + task.id, task.description, impl.files_changed)
    if (q === 'halted') return fail(ctx, 'halted', 'quality-loop', STOP.tripped ? 'stopped: ' + STOP.reason
      : 'quality degrade rate exceeded (' + MAX_QUALITY_DEGRADES_IN_WINDOW + ' of last ' + QUALITY_DEGRADE_WINDOW + ' tasks) — systemic problem, human review required')
  }

  ctx.metrics.tasks_done = tasksCompleted
  ctx.metrics.tasks_failed = failedTasks.length
  if (tasksCompleted === 0) return fail(ctx, 'failed', 'implement', 'no tasks completed (' + failedTasks.length + ' failed)')
  if (failedTasks.length) ctx.deferred.push('Tasks that failed review and were NOT completed: ' + failedTasks.join(', '))

  // ---- ENGINE-OWNED GATE (issue #3) — BEFORE the test loop so a hard-revert
  // is re-validated by the same run's test suite / lint-engine in-band. ----
  await runEngineOwnedGate(ctx)

  // ---- TEST LOOP ----
  const tl = await runTestLoop(ctx)
  if (!tl.ok) return fail(ctx, STOP.tripped ? 'halted' : 'failed', 'test-loop', tl.error)

  // ---- BROWSER (implementation gate — serial across the batch; opt-in) ----
  const bwi = await runBrowserCheck(ctx, 'implement')
  if (!bwi.ok) return fail(ctx, STOP.tripped ? 'halted' : 'failed', 'browser', bwi.error)

  // ---- DOCBLOCKS (non-fatal; gated on profile.docblock_globs) ----
  if (PROFILE.docblock_globs && PROFILE.docblock_globs.length) {
    const docs = await stage(ctx, 'docblock', [
      roleBlock('docblock_writer'),
      '',
      'Write documentation blocks for the files modified for issue #' + ctx.issue + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + '.',
      'Modified files: git -C ' + ctx.worktree + ' diff origin/' + TARGET + '...HEAD --name-only',
      'Only files matching these patterns are in scope: ' + PROFILE.docblock_globs.join(', '),
      'If none, return status=success with summary "no files to document".',
      'Add comprehensive doc blocks in the project\'s established style and commit as: docs(issue-' + ctx.issue + '): add doc blocks',
      'Return status, commit, files_changed, summary.',
    ].join('\n'), stageOpts('docblock'), IMPL_SCHEMA)
    if (!docs || docs.status === 'error') log('#' + ctx.issue + ' docblock stage degraded (non-fatal) — continuing')
  }

  // ---- PR (with the fallback: probe gh if structured output lacks the number) ----
  // Group unit: the PR carries one "Closes #N" per member (not just the primary)
  // so the eventual batch PR's own Closes references stay meaningful per-issue.
  const closesInstruction = ctx.members.length > 1
    ? '   Body MUST include one "Closes #N" line for EACH member issue: ' +
      ctx.members.map(function (m) { return 'Closes #' + m.issue }).join(', ') +
      ' — plus an implementation summary, and key decisions from:'
    : '   Body MUST include "Closes #' + ctx.issue + '", an implementation summary, and key decisions from:'
  const pr = await stage(ctx, 'pr', [
    'Create or update the PR for issue #' + ctx.issue + ' from branch ' + ctx.branch + ' (worktree ' + ctx.worktree + ').',
    '',
    '1. Push: git -C ' + ctx.worktree + ' push -u origin ' + ctx.branch,
    '2. Existing PR? gh pr list --repo ' + REPO + ' --head ' + ctx.branch + ' --json number',
    '3. If none: gh pr create --repo ' + REPO + ' --base ' + TARGET + ' --head ' + ctx.branch,
    '   Title: conventional commit style referencing issue #' + ctx.issue + '.',
    closesInstruction,
    decisionChain(ctx),
    '   Body MUST also include this exact line verbatim (approximate — this issue\'s stages only, not the run',
    '   total; tokens only, no prices/currency): "Token usage (approximate, this issue only): ' +
      (ctx.tokens && ctx.tokens.tracked ? ctx.tokens.total + ' output tokens' : 'not tracked') + '"',
    '4. If one exists: ensure it is up to date and comment that a new revision was pushed.',
    'Return status, pr_number, pr_url.',
  ].join('\n'), stageOpts('pr'), PR_SCHEMA)
  let prNumber = pr && pr.pr_number
  if (!prNumber) {
    const probe = await stage(ctx, 'pr-probe', [
      'Find the open PR for head branch ' + ctx.branch + ' in ' + REPO + ':',
      'gh pr list --repo ' + REPO + ' --head ' + ctx.branch + ' --state open --json number,url',
      'Return status=success and pr_number (or status=error if none exists).',
    ].join('\n'), stageOpts('probe'), PR_SCHEMA, 1)
    prNumber = probe && probe.pr_number
  }
  if (!prNumber) return fail(ctx, 'failed', 'pr', 'no PR number from PR stage or gh probe')
  ctx.pr = prNumber
  log('#' + ctx.issue + ' -> PR #' + prNumber)
  return null // success — continue to review/merge
}

// =============================================================================
// REVIEW + MERGE (pr_review loop + tech_docs + complete + merge/follow-ups)
// =============================================================================
async function reviewAndMerge(ctx) {
  let approved = false
  for (let iter = 1; iter <= MAX_PR_REVIEW_ITERATIONS && !approved; iter++) {
    if (STOP.tripped) return fail(ctx, 'halted', 'pr-review', 'stopped: ' + STOP.reason)
    ctx.metrics.pr_review_iters = iter

    const reviews = await parallel([
      function () {
        return stage(ctx, 'spec-review-i' + iter, [
          roleBlock('spec_reviewer'),
          '',
          'Verify PR #' + ctx.pr + ' achieves the goals of issue #' + ctx.issue + ' (spec review iteration ' + iter + ').',
          '',
          '## Decision chain', decisionChain(ctx),
          settledBlock(ctx), '',
          'Check goal achievement, not code quality. Flag scope creep.',
          'IMPORTANT: before flagging any acceptance criterion as missing, check base branch ' + TARGET + ' — if the',
          'criterion is already satisfied by pre-existing code the PR preserves, mark it met, NOT missing.',
          'Read issue comments (gh issue view ' + ctx.issue + ' --json comments) and PR comments',
          '(gh pr view ' + ctx.pr + ' --json comments) for full context. On iteration 2+, stay consistent with your',
          'own prior spec reviews — do not reverse a prior scope approval without new information.',
          'Worktree: ' + ctx.worktree,
          'Post a PR comment "## Spec Review (Iteration ' + iter + ')" with the verdict.',
          'Return result (approved|changes_requested), comments, issues, recommended_fix_agent, summary.',
        ].join('\n'), stageOpts('specReview'), REVIEW_SCHEMA)
      },
      function () {
        return stage(ctx, 'code-review-i' + iter, [
          roleBlock('code_reviewer'),
          '',
          'Review code quality of PR #' + ctx.pr + ' against base ' + TARGET + ' for issue #' + ctx.issue + ' (code review iteration ' + iter + ').',
          '',
          '## Decision chain', decisionChain(ctx),
          settledBlock(ctx), '',
          'Check patterns, standards, security. This is the merge gate — be thorough.',
          'Read issue and PR comments for context. On iteration 2+, do not re-flag issues already addressed or accepted.',
          IMPLEMENTERS.length ? 'If changes are requested, set recommended_fix_agent to one of: ' + IMPLEMENTERS.join(', ') + '.' : '',
          bwFeedback(ctx),
          'Worktree: ' + ctx.worktree,
          'Post a PR comment "## Code Review (Iteration ' + iter + ')" with the verdict.',
          'Return result (approved|changes_requested), comments, issues, recommended_fix_agent, summary.',
        ].join('\n'), stageOpts('codeReview'), REVIEW_SCHEMA)
      },
    ])
    const spec = reviews[0]
    const code = reviews[1]
    if (!spec || !code) return fail(ctx, 'needs_human', 'pr-review', 'a PR reviewer died — PR #' + ctx.pr + ' left open for human review')

    if (spec.result === 'approved' && code.result === 'approved') { approved = true; break }
    if (iter === MAX_PR_REVIEW_ITERATIONS) break

    const fixAgent = pickFixAgent(code.recommended_fix_agent, null)
    const fix = await stage(ctx, 'pr-fix-i' + iter, [
      implementerBlock(fixAgent),
      '',
      'Address PR review feedback for PR #' + ctx.pr + ' in worktree ' + ctx.worktree + ' on branch ' + ctx.branch + ':',
      '',
      'Spec review:', String(spec.comments || spec.summary || 'approved'), '',
      'Code review:', String(code.comments || code.summary || 'approved'), '',
      fixContext(ctx, null),
      'After pushing, post a PR comment "## PR Review Fix (iteration ' + iter + ')" with the commit SHA and the fixes',
      'applied in 2-4 lines (gh pr comment ' + ctx.pr + ' --repo ' + REPO + ').',
      COMMIT_SHA_ASK,
      bwFeedback(ctx),
      HANDOFF_ASK,
      'Fix the issues, commit, and push: git -C ' + ctx.worktree + ' push origin ' + ctx.branch,
      'Return status, commit, files_changed, fixes_applied, summary.',
    ].join('\n'), stageOpts('fix'), FIX_SCHEMA)
    if (!fix || fix.status === 'error') return fail(ctx, 'needs_human', 'pr-fix', 'PR fix stage failed — PR #' + ctx.pr + ' left open for human review')
    pushDecision(ctx, 'PR Review Fix (i' + iter + ')', fix.summary || 'fixes applied')
    collectNotes(ctx, 'pr-fix', fix)

    const q = await runQualityLoop(ctx, 'pr-fix-i' + iter, 'post-review fixes for PR #' + ctx.pr, fix.files_changed)
    if (q === 'halted') return fail(ctx, 'halted', 'quality-loop', STOP.tripped ? 'stopped: ' + STOP.reason : 'quality degrade rate exceeded during PR fixes')
  }

  if (!approved) return fail(ctx, 'needs_human', 'pr-review', 'PR #' + ctx.pr + ' not approved after ' + MAX_PR_REVIEW_ITERATIONS + ' iterations — left open for human review')

  // ---- BROWSER (pre-merge gate — re-verifies after any PR-review fixes) ----
  const bwm = await runBrowserCheck(ctx, 'pre-merge')
  if (!bwm.ok) return fail(ctx, STOP.tripped ? 'halted' : 'needs_human', 'browser', bwm.error + ' — PR #' + ctx.pr + ' left open for human review')

  // ---- TECH DOCS (non-fatal; gated on profile.docs_dir) ----
  if (PROFILE.docs_dir) {
    const td = await stage(ctx, 'tech-docs', [
      roleBlock('doc_writer'),
      '',
      'Assess whether PR #' + ctx.pr + ' (issue #' + ctx.issue + ') needs new/updated technical documentation in ' + PROFILE.docs_dir + '/.',
      'Worktree ' + ctx.worktree + ' on branch ' + ctx.branch + '.',
      '',
      '1. Scope: git -C ' + ctx.worktree + ' diff origin/' + TARGET + '...HEAD --stat',
      '2. Existing docs: ls ' + ctx.worktree + '/' + PROFILE.docs_dir + '/',
      '3. Docs ARE needed for: new subsystem/service/integration, significant architecture or data-flow changes,',
      '   new API endpoints, complex features needing design explanation, infra/deployment changes.',
      '   NOT needed for: minor fixes, style-only, test-only, changes covered by existing docs.',
      '4. If needed: create/update docs (GitHub Markdown + Mermaid), follow the project\'s existing doc conventions,',
      '   commit as "docs(issue-' + ctx.issue + '): update technical documentation", push, and post a PR comment listing actions.',
      '5. If not needed: status=skipped with the reason in summary.',
      'Return status, docs_needed, actions, commit, summary.',
    ].join('\n'), stageOpts('techDocs'), TECH_DOCS_SCHEMA)
    if (!td || td.status === 'error') log('#' + ctx.issue + ' tech-docs degraded (non-fatal) — continuing to merge')
  }

  // ---- MERGE AUTO-RESOLVE (mechanical CONFLICTING recovery before the merge
  // stage's own preflight would otherwise escalate straight to needs_human) ----
  const mar = await runMergeAutoResolve(ctx)
  if (!mar.ok) return fail(ctx, STOP.tripped ? 'halted' : 'needs_human', 'merge-auto-resolve', mar.error + ' — PR #' + ctx.pr + ' left open for human review')

  // ---- MERGE (preflight, squash merge, complete comment, follow-ups, cleanup) ----
  const deferredBlock = ctx.deferred.length ? ctx.deferred.map(function (d) { return '- ' + d }).join('\n') : ''
  // Group unit: release the claim on EVERY member, not just the primary — every
  // member's claim label was taken at Select and must be freed the same way.
  const releaseClaimStep = ctx.members.length > 1
    ? '6. Release the claim on EVERY member issue:\n   ' +
      ctx.members.map(function (m) { return 'gh issue edit ' + m.issue + ' --repo ' + REPO + ' --remove-label ' + CLAIM_LABEL + ' 2>/dev/null || true' }).join('\n   ')
    : '6. Release the claim: gh issue edit ' + ctx.issue + ' --repo ' + REPO + ' --remove-label ' + CLAIM_LABEL + ' 2>/dev/null || true'
  // If auto-resolve force-pushed a rebased branch, the Implementation Complete
  // comment (posted only AFTER a confirmed merge below — see reordering) must say
  // so: the merged diff has diverged from what spec/code review actually looked at.
  const autoResolveNote = mar.resolved
    ? '   Also note explicitly: this PR was CONFLICTING after review; it was auto-rebased onto ' + TARGET +
      ' and force-pushed with tests re-verified green before this merge, so the merged diff differs from the' +
      ' head that spec/code review actually reviewed.'
    : ''
  const merge = await stage(ctx, 'merge', [
    'Finalize and merge PR #' + ctx.pr + ' for issue #' + ctx.issue + ' in ' + REPO + '. It passed spec and code review in this run.',
    '',
    '1. Preflight (settle-tolerant — GitHub can still report mergeable:UNKNOWN for a few seconds after the',
    '   auto-resolve force-push above; poll rather than reading once). Run exactly:',
    mergeSettlePoll(ctx),
    '   Parse the LAST JSON object printed (the freshest poll). If NOT open+mergeable (state!=OPEN, or',
    '   mergeable=CONFLICTING, or mergeable is still UNKNOWN after the poll): DO NOT merge and do NOT post the',
    '   Implementation Complete comment below; return status=blocked with the reason.',
    '2. Squash-merge: gh pr merge ' + ctx.pr + ' --repo ' + REPO + ' --squash --delete-branch',
    '3. Post a PR comment "## Implementation Complete" summarizing branch ' + ctx.branch + ', reviews passed,',
    '   and — if the deferred-suggestions block below is non-empty — a collapsible "Deferred Suggestions for Follow-up" section.',
    autoResolveNote,
    '4. Do NOT close issue #' + ctx.issue + ' manually. This PR merges into the batch branch ' + TARGET + ', not the',
    '   default branch, so "Closes #" will not fire — closure happens when a human merges the final batch PR',
    '   (' + TARGET + ' -> ' + BASE + '), whose body carries the Closes reference. Post a comment on issue #' + ctx.issue,
    '   noting it is implemented on ' + TARGET + ' awaiting the batch PR.',
    '5. Follow-ups: scan PR + issue comments for "follow-up", "out of scope but", "technical debt", "future improvement",',
    '   "consider adding", plus the deferred suggestions below. Create one GitHub issue per distinct actionable item',
    '   (reference PR #' + ctx.pr + ' and issue #' + ctx.issue + '; label bug/enhancement/tech-debt as appropriate).',
    '   First check for existing duplicates — do not re-file.',
    releaseClaimStep,
    '7. Cleanup (non-blocking): ' + (BROWSER ? 'fuser -k ' + bwPort(ctx.issue) + '/tcp 2>/dev/null || true;' : '') ,
    '   rm -rf ' + bwArtifactDir(ctx.issue) + ' || true;',
    '   git -C ' + ROOT + ' worktree remove ' + ctx.worktree + ' --force; git -C ' + ROOT + ' worktree prune',
    '',
    'Deferred suggestions collected during implementation:',
    deferredBlock || '(none)',
    '',
    'Return status (merged|blocked|error), follow_up_issues (created issue numbers), error.',
  ].join('\n'), stageOpts('merge'), MERGE_SCHEMA)
  if (!merge) return fail(ctx, 'needs_human', 'merge', 'merge agent died — PR #' + ctx.pr + ' is approved but unmerged')
  if (merge.status !== 'merged') return fail(ctx, 'needs_human', 'merge', merge.error || 'merge blocked (' + merge.status + ') — PR #' + ctx.pr + ' left open')

  // Bump the metric only now — after a CONFIRMED merge — so a PR that auto-resolve
  // fixed but that then failed this stage's own preflight for an unrelated reason
  // (still fails fail()/needs_human above) never inflates the count.
  if (mar.resolved) ctx.metrics.merge_auto_resolved = (ctx.metrics.merge_auto_resolved || 0) + 1

  log('#' + ctx.issue + ' merged PR #' + ctx.pr + (merge.follow_up_issues && merge.follow_up_issues.length ? ' (follow-ups: ' + merge.follow_up_issues.join(', ') + ')' : ''))
  return { issue: ctx.issue, title: ctx.title, status: 'completed', pr: ctx.pr, follow_ups: merge.follow_up_issues || [], stage: 'merge', error: null, metrics: ctx.metrics, tokens: ctx.tokens, timeline: timeline(ctx), handoff_notes: ctx.notes.slice(), members: memberIssues(ctx) }
}

// =============================================================================
// PER-ISSUE ROUTER
// =============================================================================
async function processIssue(pre) {
  const ctx = {
    issue: pre.issue, title: pre.title || '', worktree: '', branch: pre.branch || '',
    pr: pre.pr_number || null, decisions: [], degrades: [], deferred: [],
    settled: [],    // adjudicated decisions (contrarian gates) — later gates need new evidence to re-open
    notes: [],      // handoff notes: env quirks/gotchas agents pass to later stages
    unresolved: [], // critical/major findings carried past a contrarian iteration cap
    approach: '',   // evaluate's approach one-liner, threaded into fix/test prompts
    // Consolidation (unit-of-work): live preflight refs for every issue this unit
    // covers. deriveUnits() sets these on a group unit; anything else defaults to
    // a self-reference singleton, so ctx.members === [pre] and ctx.groupId === null
    // for every issue, matching the byte-for-byte no-group behavior the
    // unit-of-work abstraction must preserve.
    members: Array.isArray(pre.members) && pre.members.length ? pre.members : [pre],
    groupId: ('groupId' in pre && pre.groupId != null) ? pre.groupId : null, // stable consolidation-group id; null outside a group
    // engineOwnedIntentional (issue #3): deriveUnits() OR-folds this across a
    // group's live memberRefs (or spreads a singleton's own value through) —
    // see the comment above deriveUnits(). runEngineOwnedGate() reads it off
    // ctx (not pre) so every stage downstream of this init sees the same
    // threaded value.
    engineOwnedIntentional: !!pre.engineOwnedIntentional,
    metrics: { approach_iters: 0, plan_iters: 0, tasks_done: 0, tasks_failed: 0, task_review_attempts: 0, quality_iters: 0, quality_degrades: 0, test_iters: 0, browser_iters: 0, pr_review_iters: 0, merge_auto_resolved: 0, merge_thrash: 0 },
    tokens: { total: 0, byModel: {}, tracked: false }, // per-stage token deltas from spentTokens(); see stage()
  }
  if (pre.resume_point === 'skip') {
    log('#' + ctx.issue + ' skipped: ' + pre.reason)
    // merged_into_target (issue #30): true ONLY when the related PR pr_state
    // reported 'merged' AND its base branch (pr_base) is THIS run's batch branch
    // (TARGET) — a plain string match done here in JS, where TARGET is
    // authoritative, never left to agent judgment. A PR merged into a different
    // branch (e.g. a concurrent run's own batch branch, or straight into BASE)
    // must NOT count as "shipped into TARGET" — see batchClosesIssues() below,
    // which is the sole reader of this field.
    const merged_into_target = pre.pr_state === 'merged' && pre.pr_base === TARGET
    return { issue: ctx.issue, title: ctx.title, status: 'skipped', pr: ctx.pr, follow_ups: [], stage: 'preflight', error: null, reason: pre.reason, members: memberIssues(ctx), merged_into_target: merged_into_target }
  }
  if (pre.resume_point === 'process_pr') {
    log('#' + ctx.issue + ' healing: open PR #' + ctx.pr + ' found — jumping to review/merge')
    // idempotent setup so review-fix stages have a worktree. Anchor on the stable
    // groupId (see worktreeAnchor()) — reconcileGroups() admits members whose live
    // resume_point is 'implement' OR 'process_pr', so a healed-from-marker GROUP
    // unit can and does arrive here already mid-review (every member flipped to
    // 'process_pr' after a prior run created the shared PR but crashed/failed
    // before merging it). It must resolve the SAME worktree its implement phase
    // created, not a fresh one keyed off a re-anchored primary — hence the anchor.
    const anchor = worktreeAnchor(ctx)
    const envFiles = PROFILE.env_files || []
    const setup = await stage(ctx, 'setup-for-review', [
      'Ensure a worktree exists for issue #' + ctx.issue + ' (an open PR already exists; we only need the checkout for potential fixes).',
      'First: git -C ' + ROOT + ' fetch origin ' + TARGET,
      'Run from ' + ROOT + ': ' + ROOT + '/.claude/scripts/ticketmill/setup-worktree.sh ' + anchor + ' ' + TARGET + ' ' + ROOT + ' ' + WORKTREES + ' ' + REPO,
      'Then: git -C <worktree> pull origin <branch> (branch from the script JSON) so the checkout matches the PR head.',
      envFiles.length ? 'Copy env files if missing: ' + envFiles.map(function (f) { return 'cp -n ' + ROOT + '/' + f + ' <worktree>/' + f + ' 2>/dev/null || true' }).join('; ') : '',
      'Return status, worktree, branch.',
    ].join('\n'), stageOpts('setup'), SETUP_SCHEMA)
    if (!setup || setup.status !== 'success') return fail(ctx, 'halted', 'setup-for-review', (setup && setup.error) || 'setup died')
    ctx.worktree = setup.worktree
    ctx.branch = setup.branch
    pushDecision(ctx, 'Resumed Run', 'Preflight found open PR #' + ctx.pr + ' — implementation exists; this run reviews and merges it. ' + pre.reason)
    return reviewAndMerge(ctx)
  }
  const implFail = await implementIssue(ctx)
  if (implFail) return implFail
  return reviewAndMerge(ctx)
}

// Bounded worker pool (issue-level concurrency; agent-level pool is capped by the
// harness). Lane-aware work-stealing (issue #1, lane scheduling): `lanes` — the
// computeLanes() shape, [{unitIndices:[idx,...], ...}], omitted, or empty — groups
// `items` INDICES into sets that must run serially instead of racing. min(limit,
// lanes.length) workers each steal ONE WHOLE LANE at a time (a shared `nextLane`
// counter — the same "grab whatever's next" contract the old flat pool had over
// `items` directly) and drain every unit in that lane ONE AT A TIME, in
// depends_on order (laneDrainOrder() below), before stealing another lane.
//
// No lanes arg — or every lane a singleton, which is exactly what computeLanes()
// returns when nothing overlaps — degenerates BYTE-FOR-BYTE to the pre-lane pool:
// each lane is one item, so "steal a lane, drain it serially" IS "grab the next
// item", in the same original order, with workers = min(limit, items.length).
//
// results stays length === items.length, keyed by ORIGINAL item index regardless
// of lane membership or drain order — every caller downstream (counts, batch PR
// body, run report) already assumes that flat, index-stable shape.
//
// STOP is checked before EVERY unit, not once per lane: once tripped, every
// remaining unit in the lane a worker is currently draining gets a not_started
// result without calling fn — and so does every unit in every lane no worker has
// stolen yet, because a worker that finishes (or STOP-sweeps) its current lane
// immediately steals the next one and STOP-sweeps that too. Exactly one
// not_started per remaining unit, same shape the old flat pool produced per
// remaining item.
//
// A throw from fn() is caught PER UNIT inside drainUnit(), never left to bubble
// into Promise.all: it becomes a `failed` result for that one unit and the worker
// moves on (next unit in the lane, then next lane) exactly like a stage()-level
// failure would. So Promise.all over the worker promises never rejects because of
// unit-level work — a throw partway through one lane can never tear down another
// lane's in-flight or already-written results, and results.length always stays
// items.length no matter what any single fn() call does.
async function runPool(items, limit, fn, lanes) {
  const results = new Array(items.length)
  const laneList = (Array.isArray(lanes) && lanes.length)
    ? lanes
    : items.map(function (_, i) { return { unitIndices: [i] } })

  // laneDrainOrder: topological sort of one lane's unit indices by depends_on,
  // scoped to units actually IN this lane (a depends_on edge reaching outside the
  // lane would already have united that target into it — computeLanes()'s
  // depends_on union is trusted and never dissolved — so resolving only within the
  // lane here is a defensive no-op for any edge that somehow still points out).
  // Kahn's algorithm, always picking the SMALLEST-INDEX ready unit, so a lane with
  // no depends_on at all (the common case) drains in plain ascending
  // original-index order. Falls back to remaining ascending order on an
  // (unexpected) cycle rather than hanging — preflight's depends_on parsing
  // deterministically breaks 2-cycles, so this should never actually fire.
  function laneDrainOrder(unitIndices) {
    if (unitIndices.length <= 1) return unitIndices.slice()
    const issueToIdx = {}
    items.forEach(function (u, idx) {
      if (u && u.issue != null) issueToIdx[u.issue] = idx
      for (const m of (Array.isArray(u && u.members) ? u.members : [])) {
        if (m && m.issue != null) issueToIdx[m.issue] = idx
      }
    })
    const inLane = {}
    unitIndices.forEach(function (i) { inLane[i] = true })
    const indegree = {}
    const successors = {}
    unitIndices.forEach(function (i) { indegree[i] = 0; successors[i] = [] })
    unitIndices.forEach(function (i) {
      const deps = Array.isArray(items[i].depends_on) ? items[i].depends_on : []
      for (const dep of deps) {
        const j = issueToIdx[dep]
        if (j != null && j !== i && inLane[j]) { successors[j].push(i); indegree[i]++ }
      }
    })
    const ascending = unitIndices.slice().sort(function (a, b) { return a - b })
    const done = {}
    const order = []
    while (order.length < unitIndices.length) {
      let picked = -1
      for (const i of ascending) {
        if (done[i] || indegree[i] > 0) continue
        picked = i
        break
      }
      if (picked === -1) {
        for (const i of ascending) if (!done[i]) order.push(i) // cycle fallback
        break
      }
      order.push(picked)
      done[picked] = true
      for (const s of successors[picked]) indegree[s]--
    }
    return order
  }

  async function drainUnit(i) {
    if (STOP.tripped) {
      // items[i] is a unit (deriveUnits() shape) — .members is always present
      // (a self-reference singleton, or real group members), never ctx-shaped.
      results[i] = { issue: items[i].issue, title: items[i].title || '', status: 'not_started', pr: items[i].pr_number || null, follow_ups: [], stage: 'queue', error: 'not launched: ' + STOP.reason, members: (items[i].members || []).map(function (m) { return m.issue }) }
      return
    }
    try {
      results[i] = await fn(items[i])
    } catch (e) {
      // Isolate a throw to THIS unit only — never let it reject the worker
      // promise and tear down sibling lanes via Promise.all below.
      results[i] = { issue: items[i].issue, title: items[i].title || '', status: 'failed', pr: items[i].pr_number || null, follow_ups: [], stage: 'pool', error: 'runPool: ' + String((e && e.message) || e), members: (items[i].members || []).map(function (m) { return m.issue }) }
    }
  }

  let nextLane = 0
  async function worker() {
    for (;;) {
      const laneIdx = nextLane++
      if (laneIdx >= laneList.length) return
      const order = laneDrainOrder(laneList[laneIdx].unitIndices)
      for (const i of order) await drainUnit(i)
    }
  }
  const workers = []
  for (let w = 0; w < Math.min(limit, laneList.length); w++) workers.push(worker())
  await Promise.all(workers)
  return results
}

// shouldWarnBaseBranch (issue #36): true when `base` is a member of the
// profile's OPTIONAL warn_base_branches list — a CI/CD deploy-trigger branch
// name the target repo wants a Select-phase heads-up on (PRs normally target
// the working branch, not a branch that auto-deploys on push). Default []
// when the field is absent/non-array, same normalization idiom as
// LOCKSTEP_INSTALLED_PATHS/mergeEngineOwnedGlobs. Pure and placed above the
// TICKETMILL-TEST-HARNESS-SPLIT marker (unlike the `if (...) log(...)` call
// site below, which needs the real PROFILE/BASE populated at Select) so
// tests can exercise it without seeding module state.
function shouldWarnBaseBranch(profile, base) {
  const list = profile && Array.isArray(profile.warn_base_branches) ? profile.warn_base_branches.map(String) : []
  return list.indexOf(base) !== -1
}

// =============================================================================
// MAIN
// =============================================================================

// __seed: test-only hook (never called in production). tests/harness.js truncates
// this source at the marker below and evaluates everything above it in a fresh
// vm context; __seed lets that harness repopulate the Select-populated let
// bindings without re-running the bootstrap/profile-detection agent calls. Uses
// 'k' in o membership (not o[k] truthiness) so TEST_CMD: null is distinguishable
// from "key not provided" — a profile with no test command is a valid state.
function __seed(o) {
  o = o || {}
  if ('PROFILE' in o) PROFILE = o.PROFILE
  if ('TEST_CMD' in o) TEST_CMD = o.TEST_CMD
  if ('IMPLEMENTERS' in o) IMPLEMENTERS = o.IMPLEMENTERS
  if ('DEFAULT_IMPLEMENTER' in o) DEFAULT_IMPLEMENTER = o.DEFAULT_IMPLEMENTER
  if ('ROLES' in o) ROLES = o.ROLES
  if ('TARGET' in o) TARGET = o.TARGET
  if ('REPO' in o) REPO = o.REPO
  if ('ROOT' in o) ROOT = o.ROOT
  if ('ENGINE_OWNED' in o) ENGINE_OWNED = o.ENGINE_OWNED
  if ('LOCKSTEP_INSTALLED_PATHS' in o) LOCKSTEP_INSTALLED_PATHS = o.LOCKSTEP_INSTALLED_PATHS
  if ('MAX_CONTRARIAN_ITERATIONS' in o) MAX_CONTRARIAN_ITERATIONS = o.MAX_CONTRARIAN_ITERATIONS
}

// contrarianCapFor: proportional adversarial depth (see the comment at its call
// site) — trivial issues get at most 2 challenge iterations per gate even when a
// profile raises MAX_CONTRARIAN_ITERATIONS higher; a profile lowering the cap below
// 2 tightens trivial issues too. Pure and placed above the TICKETMILL-TEST-HARNESS-
// SPLIT marker so tests can exercise it without seeding module state.
function contrarianCapFor(complexity) {
  return complexity === 'trivial' ? Math.min(2, MAX_CONTRARIAN_ITERATIONS) : MAX_CONTRARIAN_ITERATIONS
}

// releaseEnabled: profile.release is OPTIONAL (default null/absent — the Report-
// phase release stage never runs, no agent call at all; see "release" in the
// profile comment block above). An explicit object naming at least one
// version_files entry opts in. Pure and placed above the TICKETMILL-TEST-HARNESS-
// SPLIT marker, like consolidationEnabled/shouldWarnBaseBranch, so tests can
// exercise the gating predicate without seeding module state.
function releaseEnabled(profile) {
  return !!(profile && profile.release && Array.isArray(profile.release.version_files) && profile.release.version_files.length)
}

// deriveReleaseVersion: the release stage's pure bump-derivation helper.
// BASE-anchored on purpose — `baseVersion` must come from origin/BASE's
// version_files[0] (read by a read-only probe agent), NEVER from TARGET, so a
// resumed/healing Report pass recomputes the exact same next version instead of
// double-bumping a version TARGET already carries from a prior pass. Bump choice:
// profile.release.bump ("major"|"minor"|"patch") overrides when set; otherwise any
// "feat" commit type shipped this batch bumps minor, everything else (fix, chore,
// docs, ...) bumps patch — a batch is exactly one bump regardless of how many
// distinct commit types it contains. Throws on a non-semver baseVersion (the call
// site treats that as a non-fatal, logged release-stage skip — see Report phase).
// Pure and placed above the TICKETMILL-TEST-HARNESS-SPLIT marker.
function deriveReleaseVersion(baseVersion, commitTypes, profile) {
  const override = profile && profile.release && profile.release.bump
  const bump = ['major', 'minor', 'patch'].indexOf(override) !== -1
    ? override
    : ((Array.isArray(commitTypes) ? commitTypes : []).indexOf('feat') !== -1 ? 'minor' : 'patch')
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(String(baseVersion || '').trim())
  if (!m) throw new Error('deriveReleaseVersion: base version is not a valid semver string: ' + JSON.stringify(baseVersion))
  let major = Number(m[1]); let minor = Number(m[2]); let patch = Number(m[3])
  if (bump === 'major') { major += 1; minor = 0; patch = 0 }
  else if (bump === 'minor') { minor += 1; patch = 0 }
  else { patch += 1 }
  return { version: major + '.' + minor + '.' + patch, bump: bump }
}

// releaseChangelogAnchor: the single, date-independent heading the release stage
// looks for (and regenerates in place) in the batch's CHANGELOG.md — anchored to
// the computed version and RUN_TAG, never to a wall-clock date. RUN_TAG is fixed
// once at run start (args.run_label/args.date, or 'run' — see its declaration
// above), so calling this with the SAME (version, runTag) pair on a Report pass
// that resumes after midnight yields the IDENTICAL string as the pass before
// midnight: the section is found and overwritten in place, never duplicated.
// Pure and placed above the TICKETMILL-TEST-HARNESS-SPLIT marker.
function releaseChangelogAnchor(version, runTag) {
  return '## [' + String(version) + '] - ' + String(runTag)
}

// ---- TICKETMILL-TEST-HARNESS-SPLIT: tests/harness.js truncates the source at this
// marker and evaluates only what precedes it; nothing from here down (including the
// top-level await below) runs under the test harness's vm context. Do not remove or
// reword this comment without updating tests/harness.js's split point in lockstep. ----

// ---- Select: bootstrap repo context (portable across users/machines) ----
phase('Select')
if (!ROOT || !REPO) {
  const boot = await agent([
    'Report this session\'s repository context (READ-ONLY, two commands):',
    '1. root: git rev-parse --show-toplevel',
    '2. repo slug: gh repo view --json nameWithOwner -q .nameWithOwner',
    '   (fallback: parse owner/name from: git remote get-url origin)',
    'Return root (absolute path) and repo (owner/name).',
  ].join('\n'), { label: 'bootstrap', phase: 'Select', schema: BOOT_SCHEMA, model: M.probe.model, effort: M.probe.effort })
  if (!boot || !boot.root || !boot.repo) throw new Error('bootstrap probe failed — pass args.root (absolute repo path) and args.repo (owner/name) explicitly')
  ROOT = ROOT || String(boot.root).trim().replace(/\/+$/, '')
  REPO = REPO || String(boot.repo).trim().replace(/\.git$/, '')
}
if (ROOT.charAt(0) !== '/') throw new Error('repo root must be an absolute path, got: ' + ROOT)
WORKTREES = ROOT + '/.worktrees'

// ---- Select: load the REQUIRED project profile ----
// The engine never guesses a toolchain. No profile -> halt with instructions.
const profR = await agent([
  'READ-ONLY: report the ticketmill profile of the target repo.',
  '1. If ' + ROOT + '/.claude/ticketmill.json exists: return found=true and raw = the file\'s exact contents.',
  '2. If it does not exist: return found=false.',
].join('\n'), { label: 'profile', phase: 'Select', schema: PROFILE_SCHEMA, model: M.probe.model, effort: M.probe.effort })
if (!profR) throw new Error('profile probe died — cannot proceed without ' + ROOT + '/.claude/ticketmill.json')
if (!profR.found) throw new Error('no ticketmill profile at ' + ROOT + '/.claude/ticketmill.json — run the mill-init skill first (/ticketmill:mill-init). The engine never guesses a toolchain: a wrong guess silently skips verification.')
try { PROFILE = JSON.parse(profR.raw) } catch (e) { throw new Error(ROOT + '/.claude/ticketmill.json is not valid JSON: ' + String((e && e.message) || e)) }
if (!PROFILE || typeof PROFILE !== 'object') throw new Error('ticketmill profile must be a JSON object')
if (!Object.prototype.hasOwnProperty.call(PROFILE, 'test_command')) {
  throw new Error('profile is missing the "test_command" key. It must be present: a command string, or null to record the EXPLICIT decision that this project has no test gate (mill-init writes this after confirmation).')
}
TEST_CMD = PROFILE.test_command === null ? null : String(PROFILE.test_command)
if (TEST_CMD !== null && !TEST_CMD.trim()) throw new Error('profile.test_command is an empty string — use a real command or an explicit null')
if (Object.prototype.hasOwnProperty.call(PROFILE, 'contrarian_max_iterations')) {
  const cmi = PROFILE.contrarian_max_iterations
  if (!Number.isInteger(cmi) || cmi < 1) throw new Error('profile.contrarian_max_iterations must be an integer >= 1, got: ' + JSON.stringify(cmi))
  MAX_CONTRARIAN_ITERATIONS = cmi
}
REPO = PROFILE.repo || REPO
LOGS = ROOT + '/' + String(PROFILE.logs_dir || 'logs/ticketmill').replace(/^\/+|\/+$/g, '')
CLAIM_LABEL = String(PROFILE.claim_label || 'ticketmill')
BROWSER = PROFILE.browser || null
if (BROWSER && !BROWSER.serve_command) throw new Error('profile.browser is set but has no serve_command — browser verification cannot boot the app')
RELEASE = PROFILE.release || null
if (RELEASE) {
  if (!Array.isArray(RELEASE.version_files) || !RELEASE.version_files.length) {
    throw new Error('profile.release is set but has no non-empty version_files array — the release stage needs at least one JSON file with a "version" key to bump')
  }
  RELEASE.version_files = RELEASE.version_files.map(String)
  if (RELEASE.bump != null && ['major', 'minor', 'patch'].indexOf(RELEASE.bump) === -1) {
    throw new Error('profile.release.bump must be "major"|"minor"|"patch" if set, got: ' + JSON.stringify(RELEASE.bump))
  }
  RELEASE.changelog = RELEASE.changelog ? String(RELEASE.changelog) : 'CHANGELOG.md'
}
ENGINE_OWNED = mergeEngineOwnedGlobs(PROFILE)
LOCKSTEP_INSTALLED_PATHS = Array.isArray(PROFILE.lockstep_installed_paths) ? PROFILE.lockstep_installed_paths.map(String) : []

// ---- Select: resolve roles against the target repo's agent roster ----
const R = PROFILE.roles || {}
IMPLEMENTERS = Array.isArray(R.implementers) ? R.implementers.map(String) : []
DEFAULT_IMPLEMENTER = R.default_implementer ? String(R.default_implementer) : (IMPLEMENTERS[0] || null)
if (DEFAULT_IMPLEMENTER && IMPLEMENTERS.indexOf(DEFAULT_IMPLEMENTER) === -1) IMPLEMENTERS.push(DEFAULT_IMPLEMENTER)
ROLES = {
  task_reviewer: R.task_reviewer || null, spec_reviewer: R.spec_reviewer || null,
  code_reviewer: R.code_reviewer || null, contrarian: R.contrarian || null,
  test_validator: R.test_validator || null, simplifier: R.simplifier || null,
  docblock_writer: R.docblock_writer || null, doc_writer: R.doc_writer || null,
}
const referencedAgents = []
for (const n of IMPLEMENTERS) { if (n && referencedAgents.indexOf(n) === -1) referencedAgents.push(n) }
for (const k in ROLES) { const n = ROLES[k]; if (n && referencedAgents.indexOf(n) === -1) referencedAgents.push(n) }
if (referencedAgents.length) {
  const disc = await agent([
    'READ-ONLY agent-roster check in ' + ROOT + '/.claude/agents/.',
    'For each of these agent names, check whether <name>.md exists there, and if so extract the "description:"',
    'value from its YAML frontmatter (first 400 chars of it):',
    referencedAgents.map(function (n) { return '- ' + n }).join('\n'),
    'Return agents: [{name, exists, description}] — one entry per name above, in order.',
  ].join('\n'), { label: 'agent-discovery', phase: 'Select', schema: AGENTS_SCHEMA, model: M.probe.model, effort: M.probe.effort })
  const found = (disc && disc.agents) || []
  for (const a of found) AGENT_INFO[a.name] = { exists: !!a.exists, description: a.description || '' }
  for (const n of referencedAgents) {
    if (!AGENT_INFO[n]) AGENT_INFO[n] = { exists: false, description: '' }
    if (!AGENT_INFO[n].exists) log('agent "' + n + '" referenced by the profile does not exist in .claude/agents — its role falls back to a built-in charter (run mill-init to regenerate)')
  }
  const missing = referencedAgents.filter(function (n) { return !AGENT_INFO[n].exists })
  if (missing.length) VERIFY_SKIPS.push('agents missing from .claude/agents (built-in charters used instead): ' + missing.join(', '))
} else {
  log('profile declares no agents — all roles use built-in charters (run mill-init to discover/generate project agents)')
}

// ---- Select: batch integration branch (TARGET = copy of BASE named Batch_<start>) ----
// Timestamp comes from a `date` probe (Date.now() is unavailable in workflow
// scripts), which also makes the name resume-stable: journal replay returns the
// cached branch. Dry runs never create the branch.
if (shouldWarnBaseBranch(PROFILE, BASE)) log('WARNING: base branch "' + BASE + '" looks like a CI/CD trigger branch. PRs normally target the working branch.')
if (!TARGET) {
  if (DRY_RUN) {
    TARGET = BASE // read-only probes only; noted in the dry-run output
  } else {
    const bb = await agent([
      'Create the batch integration branch for this ticketmill run (idempotent, from ' + ROOT + '):',
      '1. ts=$(date +%Y-%m-%d_%H%M%S) — the branch name is Batch_$ts',
      '2. git fetch origin ' + BASE,
      '3. git push origin origin/' + BASE + ':refs/heads/Batch_$ts',
      '4. git fetch origin Batch_$ts',
      'Return status=success and branch (the exact Batch_<ts> name), or status=error with error.',
    ].join('\n'), { label: 'batch-branch', phase: 'Select', schema: BATCH_BRANCH_SCHEMA, model: M.setup.model, effort: M.setup.effort })
    if (!bb || bb.status !== 'success' || !bb.branch) throw new Error('batch-branch creation failed: ' + String((bb && bb.error) || 'agent died') + ' — pass args.batch_branch to reuse an existing one')
    TARGET = String(bb.branch).trim()
  }
}
if (!/^[A-Za-z0-9._/-]+$/.test(TARGET)) throw new Error('unsafe batch branch name: ' + TARGET)
log('ticketmill: root=' + ROOT + ' repo=' + REPO + ' base=' + BASE + ' target=' + TARGET + ' concurrency=' + CONCURRENCY +
  ' tests=' + (TEST_CMD === null ? 'DISABLED (explicit)' : TEST_CMD) + ' browser=' + (BROWSER ? 'on' : 'off') + (DRY_RUN ? ' [DRY RUN]' : ''))

// ---- Select: resolve the issue list ----
let issueList = []
if (Array.isArray(A.issues) && A.issues.length) {
  issueList = resolveIssueNumbers(A.issues).map(function (n) { return { number: n, title: '' } })
} else if (Array.isArray(A.labels) && A.labels.length) {
  const labelFlags = A.labels.map(function (l) { return '--label "' + String(l).replace(/"/g, '') + '"' }).join(' ')
  const sel = await agent([
    'List GitHub issues to batch-process from ' + REPO + '.',
    'Run: gh issue list --repo ' + REPO + ' --state ' + (A.state || 'open') + ' --limit ' + (Number(A.limit) || 50) + ' ' + labelFlags + ' --json number,title,assignees',
    A.no_assignee ? 'Keep ONLY issues with zero assignees.' : '',
    'Sort ascending by number (oldest first). Return issues: [{number, title}].',
  ].join('\n'), { label: 'select-issues', phase: 'Select', schema: SELECT_SCHEMA, model: M.probe.model, effort: M.probe.effort })
  if (!sel) throw new Error('issue selection agent died — nothing to do')
  issueList = sel.issues || []
} else {
  throw new Error('provide args.issues (array of numbers) or args.labels (array of label names)')
}
issueList.sort(function (a, b) { return a.number - b.number })
if (!issueList.length) return { state: 'completed', results: [], note: 'no issues matched the selection criteria' }
log('Selected ' + issueList.length + ' issue(s): ' + issueList.map(function (i) { return '#' + i.number }).join(', '))

// ---- Select: distill prior-run learnings ONCE (fired here, awaited after preflight
// so it runs concurrently with the probes). Category sections are injected into
// stage prompts: plan gets agent_selection+workflow, contrarians get
// quality_loop+performance, test stages get test_loop.
// STAGE_TOKENS.preflight R1: brackets the whole region from just before
// learnPromise fires to just after it is awaited below — this deliberately
// spans (never sub-brackets) the fire-and-forget learnPromise itself, plus
// targetFetch and the preflight Promise.all in between, all of which run
// strictly sequentially before runPool() (see addStage()'s module comment).
const preflightR1Before = spentTokens()
const learnPromise = agent([
  'Read ' + LOGS + '/process-retrospective.md (READ-ONLY).',
  'If the file does not exist, return found=false with all categories as empty strings.',
  'Otherwise distill its "## Active Learnings" section into per-category digests:',
  'agent_selection, quality_loop, test_loop, performance, error_patterns, workflow.',
  'Each digest: ONLY the actionable "how to apply" guidance, compressed to <= 600 characters;',
  'empty string for categories with no entries. Do not editorialize or add advice not in the file.',
  'Return found=true and the six category strings.',
].join('\n'), { label: 'learnings-digest', phase: 'Select', schema: LEARNINGS_SCHEMA, model: M.learnings.model, effort: M.learnings.effort })
  .catch(function (e) { log('learnings digest failed (non-fatal): ' + String((e && e.message) || e).slice(0, 120)); return null })

// ---- Select: preflight probe (the GitHub-state healing layer) ----
// enginePathspec (issue #3): the literalized engine-owned pathspec, computed
// ONCE here (ENGINE_OWNED is already populated — profile is loaded) using the
// same literalization buildEngineOwnedPathspec shares with engineOwnedHit, and
// interpolated into every probe below so `git status --porcelain` gets plain
// literal paths, never the raw '**' globs it doesn't interpret.
const enginePathspec = buildEngineOwnedPathspec(ENGINE_OWNED)
// One shared fetch of origin/TARGET before the per-issue Promise.all below —
// each probe's predicted_files step reads this ref read-only. Fetching it once
// here (rather than once per issue inside the unbounded Promise.all) avoids N
// concurrent `git fetch` calls racing on the same ref's lock file in ROOT.
// Best-effort: on failure, probes still run and fall open to predicted_files=[]
// against whatever origin/TARGET already pointed at (batch-branch creation
// above already fetched it once too).
const targetFetch = await agent(
  ['Run: git -C ' + ROOT + ' fetch origin ' + TARGET + ' (read-only — updates the ref only, never checks anything out).',
    'Return status=success, or status=error with error if the fetch failed.'].join('\n'),
  { label: 'preflight-fetch', phase: 'Select', schema: TARGET_FETCH_SCHEMA, model: M.setup.model, effort: M.setup.effort })
if (!targetFetch || targetFetch.status !== 'success') log('preflight: git fetch origin ' + TARGET + ' failed (non-fatal) — predicted_files will fall open to [] wherever it depended on a fresher ref: ' + String((targetFetch && targetFetch.error) || 'agent died'))

// batchIssueNumbers: this run's whole candidate set, used below to scope
// depends_on parsing — a body reference to an issue outside the batch is
// dropped (there's no unit for computeLanes to point it at).
const batchIssueNumbers = issueList.map(function (it) { return it.number })
let preflights = (await Promise.all(issueList.map(function (it) {
  return agent([
    'Probe the current state of GitHub issue #' + it.number + ' in ' + REPO + ' (READ-ONLY: gh + git inspection, no changes).',
    '',
    '1. gh issue view ' + it.number + ' --repo ' + REPO + ' --json state,title,body',
    '2. Related PRs: gh pr list --repo ' + REPO + ' --state all --search "' + it.number + '" --json number,state,headRefName,baseRefName,mergedAt',
    '   A PR is related if its head branch starts with "issue-' + it.number + '-" or its body references #' + it.number + '.',
    '   Prefer: merged > open > closed-unmerged. Report its number, state, and base branch (baseRefName) as pr_base — null if no related PR.',
    '3. Local: does ' + WORKTREES + '/issue-' + it.number + ' exist, and on what branch? Commits ahead:',
    '   git -C ' + ROOT + ' rev-list --count origin/' + TARGET + '..<branch> 2>/dev/null (0/none if no branch).',
    '4. Engine-owned guardrail (issue #3): is the ROOT working tree dirty under any engine-owned path right now?',
    '   git -C ' + ROOT + ' status --porcelain -- ' + enginePathspec.join(' '),
    '   Return every dirty path under that pathspec as root_dirty_engine_paths (empty array if the pathspec is clean).',
    '',
    '5. predicted_files (best-effort lane-scheduling hint — fail open to [] on ANY doubt, never guess a path):',
    '   a. From the issue title + body, extract ONLY high-signal identifiers: backticked spans (`like this`),',
    '      quoted spans ("like this"), path-like strings (contain a / or a file extension such as .js/.md/.json/.sh),',
    '      and code-symbol tokens (PascalCase, camelCase, snake_case, or ALL_CAPS words of 3+ chars).',
    '      REJECT bare dictionary/English nouns used in ordinary prose (e.g. "engine", "button", "config" alone,',
    '      with no code formatting, path shape, or distinctive casing) — those are not identifiers.',
    '      If nothing clears this bar, predicted_files = [] and skip the rest of this step.',
    '   b. Resolve each surviving identifier against the REAL tree at origin/' + TARGET + ' (already fetched read-only',
    '      before this step; never the working directory, which may be on a different branch):',
    '      git -C ' + ROOT + ' grep -l -I -F -i -- "<identifier>" origin/' + TARGET + ' for a content match, and',
    '      git -C ' + ROOT + ' ls-tree -r --name-only origin/' + TARGET + ' filtered for a',
    '      case-insensitive substring match for a path/filename match. Keep ONLY the exact repo-relative paths those',
    '      commands actually return — never fabricate or normalize a path yourself.',
    '   c. Dedupe and cap at 20 paths. If every resolution comes back empty, or any command errors, predicted_files = [].',
    '6. depends_on (best-effort lane-scheduling hint — fail open to [] on ANY doubt):',
    '   a. Scan the issue body for "depends on #N", "depends-on #N", or "follow-up to #N" (case-insensitive). Collect each N.',
    '   b. Drop any N that is not one of this batch\'s issue numbers (' + batchIssueNumbers.join(', ') + '), and drop N == ' + it.number + '.',
    '   c. For each remaining N, check whether #N itself ALSO references "depends on #' + it.number + '" or',
    '      "follow-up to #' + it.number + '" in ITS OWN body (gh issue view N --repo ' + REPO + ' --json body, read-only).',
    '      If so this is a two-issue cycle: keep the edge ONLY on the lower-numbered issue of the pair and drop it from',
    '      the higher-numbered one (deterministic by issue number, so both probes agree without coordinating).',
    '   d. Return the surviving numbers as depends_on. Empty array if none, or on any doubt/error.',
    '',
    'Decide resume_point:',
    '- "skip": issue is closed OR a related PR is already merged',
    '- "process_pr": a related PR is OPEN (implementation exists; it needs review + merge)',
    '- "implement": otherwise (fresh, or partial branch/worktree — implementation will continue from existing commits)',
    'Return issue, title, body, issue_state, pr_number, pr_state, pr_base, branch, worktree_exists, commits_ahead, resume_point, reason (one line), root_dirty_engine_paths,',
    'predicted_files (array of real repo-relative paths, [] if none/uncertain), depends_on (array of in-batch issue numbers, [] if none/uncertain).',
  ].join('\n'), { label: it.number + ':preflight', phase: 'Select', schema: PREFLIGHT_SCHEMA, model: M.probe.model, effort: M.probe.effort })
    .then(function (r) {
      if (r) {
        if (!r.title && it.title) r.title = it.title
        // Normalize the two optional prediction fields to real arrays regardless
        // of what the agent omitted/returned — every downstream reader (deriveUnits,
        // eventually computeLanes) can then assume Array.isArray() without re-checking.
        r.predicted_files = Array.isArray(r.predicted_files) ? r.predicted_files : []
        r.depends_on = Array.isArray(r.depends_on) ? r.depends_on : []
        return r
      }
      // probe died -> assume full implement; the pipeline stages are individually idempotent
      return { issue: it.number, title: it.title || '', body: '', issue_state: 'unknown', pr_number: null, pr_state: 'none', pr_base: null, branch: null, worktree_exists: false, commits_ahead: null, resume_point: 'implement', reason: 'preflight probe died — defaulting to implement (stages self-heal)', root_dirty_engine_paths: [], predicted_files: [], depends_on: [] }
    })
}))).filter(Boolean)

// engineOwnedIntentional (issue #3): computed once per preflight, right after
// the probe returns, from THIS issue's own title+body — see the module
// comment above ENGINE_OWNED_GLOBS for the three-regime model this feeds, and
// deriveUnits()'s OR-fold for how it threads onto a consolidation-group unit.
preflights = attachEngineOwnedIntentional(preflights, ENGINE_OWNED)

for (const p of preflights) log('#' + p.issue + ' preflight: ' + p.resume_point + ' — ' + p.reason)

// ---- Select: engine-owned root-dirty skip — regime (a) of the three-regime
// model (ENGINE_OWNED_GLOBS module comment): this issue's own prose targets an
// engine-owned path AND the root working tree is already dirty under that set
// (the #77 hazard). Deterministic JS, run BEFORE the consolidation gate below
// so a flagged issue is neither offered to proposeConsolidation() (its residual
// filter only admits resume_point === 'implement') nor claimed (toClaim filters
// resume_point !== 'skip') — both existing gates, no new plumbing needed.
const engineSkip = applyEngineOwnedRootDirtySkip(preflights)
preflights = engineSkip.preflights
if (engineSkip.flagged.length) log('engine-owned guardrail: root working tree dirty under an engine-owned path targeted by issue(s) ' + engineSkip.flagged.join(', ') + ' — routed to select-skip (regime a)')

const learnR = await learnPromise
addStage('preflight', preflightR1Before) // STAGE_TOKENS.preflight R1 close — see the bracket comment above learnPromise
if (learnR && learnR.found) {
  LEARN = learnR
  log('prior-run learnings digested: ' + ['agent_selection', 'quality_loop', 'test_loop', 'performance', 'error_patterns', 'workflow']
    .filter(function (c) { return learnR[c] }).join(', '))
} else {
  log('no prior-run learnings digest — plan stage falls back to reading the retro file itself')
}

// ---- Select: consolidation gate (judgment call — see the PROPOSECONSOLIDATION
// module comment above the harness split for the full design). EVERY preflight is
// a candidate here, regardless of resume_point — NOT filtered to 'implement' —
// because proposeConsolidation()'s HEAL phase must see 'process_pr'/'skip' members
// too: a group whose members ALL flipped to 'process_pr' (a prior run created the
// shared PR but crashed/failed before merging it — spec review, code review, and
// merge all happen post-PR, in reviewAndMerge) still needs to be recognized as ONE
// group so its whole unit routes together through processIssue's process_pr branch
// (one setup + one reviewAndMerge on the shared PR), not as N independent
// process_pr singletons that would each attempt to review/merge the SAME PR.
// proposeConsolidation() itself restricts brand-new opus-gate proposals to
// 'implement' candidates only (see its own filter) — only the HEAL step is
// resume_point-agnostic. proposeConsolidation() free-skips internally with NO
// agent call at all when candidates.length <= 1, and skips the opus proposal (but
// still heals a group a PRIOR run already committed to, via comment markers) when
// PROFILE.consolidation is explicitly false — see its module comment on why the
// heal must survive a mid-run flag flip. It is read-only and side-effect-free
// under DRY_RUN: the marker-heal and opus proposal both run (gh reads only); the
// comment-posting contrarian challenge is skipped entirely.
const consolidationCandidates = preflights
// STAGE_TOKENS.select sub-bracket 1: the whole proposeConsolidation() call
// (internally sequential — propose/revise/challenge) has no per-issue ctx to
// attribute its spend to, hence the synthetic .select bucket (see the
// STAGE_TOKENS module comment). Runs under DRY_RUN too (read-only there), but
// aggregateTokens() never runs on a dry run, so the partial bucket never renders.
const selectBefore1 = spentTokens()
const consolidationMap = await proposeConsolidation(consolidationCandidates)
addStage('select', selectBefore1)

if (DRY_RUN) {
  // ---- lane-scheduling preview (issue #1) — read-only, mirrors the real-run
  // call sequence (reconcileGroups -> deriveUnits -> computeLanes ->
  // applyRealRunCollapseGuard, see that sequence below the harness split just
  // before runPool()) so the dry-run output has an actual unit source instead
  // of guessing lanes from predicted_files alone. DRY_RUN never runs the claim
  // loop (claims can flip a resume_point to 'skip' for a real run), so this
  // preview derives straight from `preflights` as probed — a real run's units
  // can still differ if a claim race flips something between now and then;
  // that's inherent to any preview and is exactly why it's still called a
  // preview, not a plan.
  const previewGroups = reconcileGroups(consolidationMap, preflights)
  const previewUnits = deriveUnits(previewGroups, preflights)
  const previewServeGlobs = PROFILE.serialize_globs || []
  const previewRawLanes = computeLanes(previewUnits, previewServeGlobs)
  const previewGuard = applyRealRunCollapseGuard(previewUnits, previewRawLanes, CONCURRENCY, previewServeGlobs)
  const previewLanes = previewGuard.lanes
  // Edge provenance per lane: a lane is 'trusted' when its exact membership
  // also comes out of computeLanes({trustedOnly:true}) — i.e. it would exist
  // on serialize_globs/depends_on alone, with no heuristic predicted-file
  // overlap needed. Any other multi-unit lane is 'heuristic'; a size-1 lane
  // (nothing united it with anything) is 'none'. Mirrors the same key-set
  // comparison applyRealRunCollapseGuard() uses internally.
  const previewTrustedLanes = computeLanes(previewUnits, previewServeGlobs, { trustedOnly: true })
  const previewTrustedKeys = {}
  previewTrustedLanes.forEach(function (l) {
    previewTrustedKeys[laneKey(l.unitIndices)] = true
  })
  const lanesPreviewOut = previewLanes.map(function (l) {
    return {
      issues: laneMemberIssues(previewUnits, l.unitIndices),
      predicted_files: l.predicted_files,
      provenance: l.unitIndices.length < 2 ? 'none' : (previewTrustedKeys[laneKey(l.unitIndices)] ? 'trusted' : 'heuristic'),
    }
  })
  const predictedUnitCount = previewUnits.filter(function (u) {
    return (u.predicted_files || []).length > 0 || (u.depends_on || []).length > 0
  }).length
  // DF-flagged paths: the same magnet threshold computeLanes() logs internally
  // (matched by more than half the batch, min 3 units) — computeLanes() only
  // logs this (advisory, never drops an intersection key), so it's recomputed
  // here, read-only, purely for dry-run visibility. serialize_globs paths are
  // excluded, same as computeLanes()'s own DF signal.
  const previewIsSerializeGlobPath = function (p) { return previewServeGlobs.some(function (g) { return matchesGlobs(p, [g]) }) }
  const previewDfCount = {}
  previewUnits.forEach(function (u) {
    for (const p of (Array.isArray(u.predicted_files) ? u.predicted_files : [])) {
      if (previewIsSerializeGlobPath(p)) continue
      previewDfCount[p] = (previewDfCount[p] || 0) + 1
    }
  })
  const dfFlaggedPaths = Object.keys(previewDfCount)
    .filter(function (p) { return previewDfCount[p] >= 3 && previewDfCount[p] > previewUnits.length / 2 })
    .map(function (p) { return { path: p, count: previewDfCount[p], batch_size: previewUnits.length } })
  // ref_possibly_stale: the shared preflight-fetch probe (Select phase, above)
  // is the only thing predicted_files is grounded against — if it failed,
  // every predicted_files entry (and therefore every heuristic lane here) may
  // be resolved against a stale origin/TARGET, not what a real run would fetch.
  const refPossiblyStale = !targetFetch || targetFetch.status !== 'success'

  return {
    state: 'dry_run', root: ROOT, repo: REPO, base_branch: BASE,
    profile: { test_command: TEST_CMD, browser: !!BROWSER, implementers: IMPLEMENTERS, roles: ROLES },
    agent_roster: AGENT_INFO,
    batch_branch_note: 'dry run probes against ' + TARGET + '; a real run creates Batch_<start-timestamp> from ' + BASE + ' (or pass args.batch_branch)',
    plan: preflights.map(function (p) { return { issue: p.issue, title: p.title, resume_point: p.resume_point, pr: p.pr_number, reason: p.reason } }),
    // Consolidation preview — a PRE-CHALLENGE veto point: dry_run runs only the
    // read-only marker-heal + opus proposal, never the comment-posting contrarian
    // challenge, so a human can veto a proposed grouping before it ever takes
    // effect for real (entries healed from a prior run's markers carry no
    // dry_run_preview flag; a fresh, unchallenged proposal does).
    consolidation_groups: Array.from(consolidationMap.values()).map(function (g) {
      return { group_id: g.groupId, primary: g.primary, members: g.members, subsystem: g.subsystem, rationale: g.rationale, dry_run_preview: !!g.dry_run_preview }
    }),
    // Lane-scheduling preview (issue #1) — see the block above for how each
    // field is derived. ref_possibly_stale flags the WHOLE preview (lanes and
    // df_flagged_paths both depend on predicted_files) rather than annotating
    // individual paths, since a stale fetch taints every prediction equally.
    lane_scheduling: {
      lanes: lanesPreviewOut,
      lane_count: previewLanes.length,
      max_lane_size: previewLanes.length ? Math.max.apply(null, previewLanes.map(function (l) { return l.unitIndices.length })) : 0,
      effective_concurrency: Math.min(CONCURRENCY, previewLanes.length),
      collapse_ratio: previewGuard.collapseRatio,
      prediction_coverage: previewUnits.length ? predictedUnitCount / previewUnits.length : 0,
      df_flagged_paths: dfFlaggedPaths,
      ref_possibly_stale: refPossiblyStale,
      ref_possibly_stale_note: refPossiblyStale
        ? 'preflight-fetch of origin/' + TARGET + ' failed — predicted_files (and every lane/DF signal above) may be grounded against a stale ref'
        : null,
    },
    note: 'No changes made. Re-run without dry_run to execute.',
  }
}

// ---- Select: claim every selected issue UP FRONT (cross-run coordination) ----
// Claims are advisory but early: they land before the concurrency queue drains, so
// queued-but-not-started issues are visibly taken. A claim agent that dies fails
// OPEN (proceed unclaimed, logged) — coordination must not block the work itself.
const toClaim = preflights.filter(function (p) { return p.resume_point !== 'skip' })
const HELD_CLAIMS = [] // issues this run successfully claimed — released at Report
if (toClaim.length) {
  // STAGE_TOKENS.preflight R2: brackets the claims Promise.all and its settle
  // loop below — real-run only (DRY_RUN already returned above), sequential,
  // strictly before runPool() — see the STAGE_TOKENS module comment.
  const preflightR2Before = spentTokens()
  const claims = await Promise.all(toClaim.map(function (p) {
    return agent([
      'Claim GitHub issue #' + p.issue + ' of ' + REPO + ' for this ticketmill run (batch branch: ' + TARGET + ', run tag: ' + RUN_TAG + ').',
      'Concurrent batch runs on other machines check these claims and skip claimed issues.',
      'LABEL SAFETY (non-negotiable): touch ONLY the "' + CLAIM_LABEL + '" label. Use exclusively',
      '`gh issue edit ... --add-label ' + CLAIM_LABEL + '` / `--remove-label ' + CLAIM_LABEL + '`. NEVER pass a full or',
      'comma-joined label list, NEVER use `gh api ... PUT .../labels` (that REPLACES the whole set), and NEVER add or',
      "remove any label other than \"" + CLAIM_LABEL + "\". The issue's existing labels MUST survive the claim untouched.",
      '',
      '1. Ensure the label exists (idempotent):',
      '   gh label create ' + CLAIM_LABEL + ' --repo ' + REPO + ' --color D93F0B --description "claimed by an active ticketmill run" 2>/dev/null || true',
      '2. Read state: gh issue view ' + p.issue + ' --repo ' + REPO + ' --json comments --jq \'[.comments[] | select((.body | startswith("' + CLAIM_TITLE + '")) or (.body | startswith("' + LEGACY_CLAIM_TITLE + '")))] | last | .body\'',
      '   A claim body has "batch: <branch>" and "started: <unix epoch>" lines. ("' + LEGACY_CLAIM_TITLE + '" claims',
      '   come from the older batch-issues engine — honor them exactly like foreign ticketmill claims.)',
      '3. Decide:',
      '   - Existing claim with batch != "' + TARGET + '" AND (now - started) < ' + CLAIM_STALE_SECONDS + 's: do NOT claim.',
      '     Return claimed=false, reason naming that batch and its age.',
      '   - Existing claim with batch == "' + TARGET + '" (this run, resumed): ensure the label is present',
      '     (gh issue edit ' + p.issue + ' --repo ' + REPO + ' --add-label ' + CLAIM_LABEL + '), post NO duplicate; return claimed=true.',
      '   - No claim, or only a stale one (>= ' + CLAIM_STALE_SECONDS + 's): claim it —',
      '     gh issue comment ' + p.issue + ' --repo ' + REPO + ' --body "$(printf \'%s\\n\' \'' + CLAIM_TITLE + '\' \'batch: ' + TARGET + '\' \'run: ' + RUN_TAG + '\' "host: $(hostname)" "started: $(date +%s)" \'Queued in an active ticketmill run — will be processed even if work has not visibly started (concurrency queue). Claims older than 12h are stale.\' \'<!-- ticketmill ' + REPO + '#' + p.issue + ' -->\')"',
      '     gh issue edit ' + p.issue + ' --repo ' + REPO + ' --add-label ' + CLAIM_LABEL,
      '4. RACE CHECK (two runs claiming simultaneously): re-read the claim comments. If a claim from a DIFFERENT',
      '   batch now exists with an EARLIER "started" epoch than yours (and is fresh), the other run wins: delete',
      '   YOUR claim comment (gh api -X DELETE repos/' + REPO + '/issues/comments/<your comment id>), leave the',
      '   label (the winner needs it), and return claimed=false with reason.',
      'Return issue=' + p.issue + ', claimed (boolean), reason (one line).',
    ].join('\n'), { label: p.issue + ':claim', phase: 'Select', schema: CLAIM_SCHEMA, model: M.probe.model, effort: M.probe.effort })
      .catch(function () { return null })
      .then(function (r) { return r || { issue: p.issue, claimed: true, reason: 'claim agent died — proceeding unclaimed (claims are advisory)' } })
  }))
  for (const c of claims) {
    if (c.claimed === false) {
      const p = preflights.find(function (x) { return x.issue === c.issue })
      if (p) { p.resume_point = 'skip'; p.reason = 'claimed by another in-flight batch run: ' + (c.reason || 'unknown') }
      log('#' + c.issue + ' SKIP — ' + (c.reason || 'claimed by another run'))
    } else {
      HELD_CLAIMS.push(c.issue)
      if (c.reason && /died/.test(c.reason)) log('#' + c.issue + ' claim: ' + c.reason)
    }
  }
  addStage('preflight', preflightR2Before) // STAGE_TOKENS.preflight R2 close — see the bracket comment above
  log('claims: ' + HELD_CLAIMS.length + '/' + toClaim.length + ' held by this run')
}

// ---- Select: materialize final consolidation units now that claims are settled —
// claims (and any claim-race resume_point flip just above, e.g. p.resume_point =
// 'skip') make membership authoritative over the pre-claim proposal.
// reconcileGroups() drops any member whose LIVE preflight resume_point is
// 'skip' (a skip-flipped member falls through deriveUnits() to an ordinary
// skip singleton, handled by processIssue()'s existing resume_point==='skip'
// return path) and keeps 'implement' or 'process_pr' members live; dissolves
// a group left with fewer than 2 live members; re-anchors
// the primary onto another live member (by stableGroupId, so the group's
// worktree/branch/PR identity never moves) when the proposed primary itself was
// excluded. deriveUnits() then translates the reconciled groups plus every other
// live preflight into the array runPool() below actually iterates — preflights
// itself stays untouched (still used by the claim loop above and the Report sweep
// below), so a no-group run's units are byte-for-byte identical to preflights.
const reconciledGroups = reconcileGroups(consolidationMap, preflights)
const units = deriveUnits(reconciledGroups, preflights)
const groupUnitCount = units.filter(function (u) { return u.groupId != null }).length
if (groupUnitCount) log('consolidation: ' + groupUnitCount + ' group unit(s) materialized out of ' + units.length + ' total')

// Post absorbed-member / primary group-membership markers ONLY now, post-
// materialization (see proposeConsolidation()'s module comment on why posting any
// earlier could name a member that never actually joins the live unit). DRY_RUN
// already returned above, so this line is only ever reached for a real run — the
// explicit guard documents that no marker is ever posted for a preview.
// STAGE_TOKENS.select sub-bracket 2: postConsolidationMarkers, real-run only
// (the guard above is already redundant with the DRY_RUN early-return, but
// kept explicit here too) — see the STAGE_TOKENS module comment.
if (!DRY_RUN) {
  const selectBefore2 = spentTokens()
  await postConsolidationMarkers(units)
  addStage('select', selectBefore2)
}

// ---- Process: lane scheduling (issue #1) — group `units` into lanes that must
// run serially (predicted-file overlap, a serialize_globs pattern hit, or a
// depends_on edge) instead of racing; computeLanes() itself already guards every
// heuristic edge (see its module comment: strong edges self-sufficient, weak
// edges only survive as part of a >=2-distinct-key weak-only chain, trusted edges
// never touched). serialize_globs is an OPTIONAL profile field, read the same way
// PROFILE.simplify_globs/test_globs are above — [] when unset, so a profile that
// never opts in still gets computeLanes()'s depends_on/heuristic unioning off
// predicted_files alone, on top of today's racing behavior for anything left over.
const serializeGlobs = PROFILE.serialize_globs || []
const rawLanes = computeLanes(units, serializeGlobs)
// applyRealRunCollapseGuard (pure reducer, above the harness split — see its
// module comment for the full "why") is the run-time-only safety net on top of
// computeLanes()'s own per-edge guard; a no-op (same array back, dissolvedCount
// 0) whenever collapse_ratio is healthy or the batch is too small to care.
const guard = applyRealRunCollapseGuard(units, rawLanes, CONCURRENCY, serializeGlobs)
const lanes = guard.lanes
if (guard.dissolvedCount) {
  log('runPool: real-run collapse guard dissolved ' + guard.dissolvedCount + ' heuristic lane(s) back to racing ' +
    '(collapse_ratio=' + guard.collapseRatio.toFixed(2) + ' < 0.5 with ' + units.length + ' units >= concurrency ' + CONCURRENCY + ')')
}
if (lanes.length < units.length) log('lane scheduling: ' + lanes.length + ' lane(s) for ' + units.length + ' unit(s) — effective concurrency ' + Math.min(CONCURRENCY, lanes.length) + '/' + CONCURRENCY)

// ---- Process: per-issue pipeline with issue-level concurrency + breakers ----
const results = await runPool(units, CONCURRENCY, processIssue, lanes)

const counts = {}
for (const r of results) counts[r.status] = (counts[r.status] || 0) + 1
const state = STOP.tripped ? 'circuit_breaker'
  : (results.some(function (r) { return r.status !== 'completed' && r.status !== 'skipped' }) ? 'completed_with_errors' : 'completed')
log('Batch done: ' + JSON.stringify(counts) + ' state=' + state + (STOP.tripped ? ' (' + STOP.reason + ')' : ''))

// ---- Consolidation groups this run actually materialized and processed (post-
// reconciliation, so this reflects live membership, not the pre-claim proposal) —
// one entry per group unit, reused below by BOTH the batch PR body and the run
// report so a reviewer sees primary/members/rationale explicitly, not just the
// primary issue's line. counts/state above already treat a group as ONE unit
// (runPool iterates `units`, one result per group, not per member) — nothing
// further to aggregate there.
const finalGroups = units.filter(function (u) { return u.groupId != null }).map(function (u) {
  return { group_id: u.groupId, primary: u.issue, members: memberIssues(u), subsystem: u.subsystem, rationale: u.rationale }
})

// ---- Release any claims this run still holds (circuit-breaker leftovers, misses) ----
// (toClaim/HELD_CLAIMS above and this sweep both operate on `preflights` — the raw
// per-issue array untouched by consolidation — so every group member was claimed
// individually and is released individually here; grouping never hides a member
// from claim coordination.)
phase('Report')
if (HELD_CLAIMS.length) {
  const swept = await agent([
    'Release ticketmill claims held by THIS run (batch branch ' + TARGET + ') on ' + REPO + '.',
    'For each of these issues: ' + HELD_CLAIMS.join(', '),
    '1. Check its newest "' + CLAIM_TITLE + '" comment. Only act if that claim\'s "batch:" line is exactly "' + TARGET + '"',
    '   — never strip another run\'s claim.',
    'LABEL SAFETY (non-negotiable): remove ONLY the "' + CLAIM_LABEL + '" label via `--remove-label ' + CLAIM_LABEL + '`.',
    'NEVER use `gh api ... PUT .../labels`, never pass a full label set, never remove any other label. All of the',
    "issue's other labels MUST remain intact.",
    '2. If it is ours: gh issue edit <n> --repo ' + REPO + ' --remove-label ' + CLAIM_LABEL + ' 2>/dev/null || true',
    '(Idempotent — most issues already had the label removed at their merge/halt step.)',
    'Return posted=true when done.',
  ].join('\n'), { label: 'claims-release', phase: 'Report', schema: NOTE_SCHEMA, model: M.probe.model, effort: M.probe.effort })
    .catch(function () { return null })
  if (!swept || !swept.posted) log('claims-release sweep incomplete — stale "' + CLAIM_LABEL + '" labels expire via the ' + Math.round(CLAIM_STALE_SECONDS / 3600) + 'h staleness window')
}

// ---- Token usage: JS-computed aggregation (no LLM math), injected verbatim below ----
const TOKEN_AGG = aggregateTokens(results, spentTokens(), CONCURRENCY, STAGE_TOKENS)

// ---- Merge auto-resolution: JS-computed run-level rollup, injected verbatim below ----
const MERGE_RESOLVE_AGG = aggregateMergeAutoResolve(results)

// ---- Batch PR: TARGET -> BASE, created for HUMAN review — never merged by the run ----
let batchPr = null
// shippedIssues (issue #30): the union, across THIS pass's completions and any
// prior pass's already-merged-into-TARGET skips, of every issue number whose
// work is actually in the batch branch — see batchClosesIssues() above
// memberIssues(). Driving the create/update gate, the title count, the
// Consolidated Groups section, AND the Closes lines all off this one set is what
// keeps them coherent by construction: a resumed/healing pass can no longer
// rebuild a body that drops a Closes line for a member merged in a prior pass.
const shippedIssues = batchClosesIssues(results)
// Groups this run actually shipped (a group unit's result carries the primary's
// issue number, materialized/reconciled BEFORE processIssue ran — see finalGroups
// above), reused for the explicit "## Consolidated Groups" section below.
const shippedGroups = finalGroups.filter(function (g) {
  return shippedIssues.indexOf(g.primary) !== -1
})
if (shippedIssues.length) {
  // ---- RELEASE (non-fatal; gated on profile.release) — batch-level CHANGELOG +
  // version bump, run ONCE per batch, BEFORE the batch-PR agent so the bump lands
  // inside the human-reviewed TARGET -> BASE diff by construction. See "release"
  // in the profile comment block above for the field shape and the concurrent-
  // batch-collision caveat. Runs as the doc_writer role in an EPHEMERAL worktree
  // (ROOT itself is never checked out/mutated; the engine's own installed copy at
  // .claude/workflows/ticketmill.js is never touched by this stage).
  if (releaseEnabled(PROFILE)) {
    const versionFile = RELEASE.version_files[0]
    const releaseProbe = await agent([
      'READ-ONLY release probe for batch ' + TARGET + ' -> ' + BASE + ' in ' + REPO + '. Make no changes.',
      '1. git fetch origin ' + BASE + ' ' + TARGET,
      '2. Read the version currently on origin/' + BASE + ': git show origin/' + BASE + ':' + versionFile,
      '   Extract the "version" field. If the file does not exist on origin/' + BASE + ' or has no such field,',
      '   return base_version=null.',
      '3. List distinct conventional-commit type prefixes shipped in this batch:',
      '   git log origin/' + BASE + '..origin/' + TARGET + ' --pretty=%s | grep -oE \'^[a-z]+\' | sort -u',
      '   (empty output is fine — return commit_types=[])',
      'Return base_version (string or null) and commit_types (array of distinct prefixes found, e.g. ["feat","fix"]).',
    ].join('\n'), { label: 'release-probe', phase: 'Report', schema: RELEASE_PROBE_SCHEMA, model: M.probe.model, effort: M.probe.effort })
      .catch(function (e) { log('release probe threw (non-fatal): ' + String((e && e.message) || e).slice(0, 120)); return null })
    if (!releaseProbe || !releaseProbe.base_version) {
      log('release stage skipped (non-fatal) — could not read a "version" field from origin/' + BASE + ':' + versionFile)
      VERIFY_SKIPS.push('release stage skipped — could not read the current version from origin/' + BASE + ':' + versionFile)
    } else {
      let derived = null
      try {
        derived = deriveReleaseVersion(releaseProbe.base_version, releaseProbe.commit_types, PROFILE)
      } catch (e) {
        log('release stage skipped (non-fatal): ' + String((e && e.message) || e).slice(0, 200))
        VERIFY_SKIPS.push('release stage skipped — ' + String((e && e.message) || e).slice(0, 200))
      }
      if (derived) {
        const anchor = releaseChangelogAnchor(derived.version, RUN_TAG)
        const entryLines = shippedIssues.map(function (n) {
          const r = results.filter(function (x) { return x.issue === n })[0]
          return '- ' + (r && r.title ? r.title : ('issue #' + n)) + ' (#' + n + ')'
        }).join('\n')
        const releaseWorktree = WORKTREES + '/release-' + TARGET
        let relWrite = null
        try {
          relWrite = await agent([
            roleBlock('doc_writer'),
            '',
            'Batch release bump for ' + TARGET + ' -> ' + BASE + ' in ' + REPO + '. Target version: ' + derived.version +
              ' (bump: ' + derived.bump + ', computed from origin/' + BASE + '\'s ' + versionFile + ' — NEVER from ' +
              TARGET + ', so a resumed pass recomputes this exact same version instead of double-bumping).',
            '',
            '1. Ephemeral checkout — ROOT itself (' + ROOT + ') is never touched:',
            '   git -C ' + ROOT + ' worktree add ' + releaseWorktree + ' origin/' + TARGET,
            '2. In ' + releaseWorktree + ', bump the "version" field to exactly "' + derived.version + '" in EACH of:',
            '   ' + RELEASE.version_files.join(', '),
            '3. Regenerate-in-place the ONE batch CHANGELOG section in ' + RELEASE.changelog + ':',
            '   - The section heading is EXACTLY: ' + JSON.stringify(anchor),
            '   - If a heading matching that EXACT text already exists (a prior pass of THIS batch already wrote a',
            '     draft section), REPLACE its body (everything up to the next "## " heading or EOF) with the list',
            '     below — do not create a second section for the same batch.',
            '   - If it does not exist yet, insert a new section with that exact heading (placed after the',
            '     top-level title, before the first existing "## " entry — newest first) containing exactly this list:',
            entryLines,
            '   This is an explicit DRAFT for the human reviewer to refine (wording/voice) inside the batch PR —',
            '   do not agonize over prose polish.',
            '4. git -C ' + releaseWorktree + ' add -A',
            '5. git -C ' + releaseWorktree + ' commit -m "chore(release): v' + derived.version + '"',
            '   (if there is nothing to commit — e.g. a resumed pass regenerated byte-identical content — treat that',
            '   as status=success with commit=null, not an error)',
            '6. Push (non-fatal — if this fails, log it and return pushed=false; do NOT throw or retry):',
            '   git -C ' + releaseWorktree + ' push origin HEAD:' + TARGET,
            '',
            'Return status (success|error), version, commit (exact SHA or null), pushed (boolean), summary, error.',
          ].join('\n'), { label: 'release', phase: 'Report', schema: RELEASE_SCHEMA, model: M.release.model, effort: M.release.effort })
            .catch(function (e) { log('release write agent threw (non-fatal): ' + String((e && e.message) || e).slice(0, 120)); return null })
        } finally {
          // Cleanup runs REGARDLESS of the write agent's outcome — an ephemeral
          // worktree must never linger. Idempotent (safe if worktree add itself
          // never happened or already failed).
          const relCleanup = await agent([
            'Cleanup the ephemeral release worktree (idempotent — safe if it is already gone):',
            'git -C ' + ROOT + ' worktree remove --force ' + releaseWorktree + ' 2>/dev/null || true',
            'git -C ' + ROOT + ' worktree prune',
            'rm -rf ' + releaseWorktree + ' || true',
            'Return posted=true when done.',
          ].join('\n'), { label: 'release-cleanup', phase: 'Report', schema: NOTE_SCHEMA, model: M.probe.model, effort: M.probe.effort })
            .catch(function () { return null })
          if (!relCleanup || !relCleanup.posted) log('release-cleanup incomplete — ' + releaseWorktree + ' may need manual `git worktree remove --force`')
        }
        if (!relWrite || relWrite.status !== 'success') {
          log('release stage degraded (non-fatal): ' + ((relWrite && relWrite.error) || 'agent died'))
          VERIFY_SKIPS.push('release stage did not complete — CHANGELOG/version bump for this batch may need a manual follow-up')
        } else if (relWrite.pushed === false) {
          log('release commit made but push to ' + TARGET + ' failed (non-fatal) — push manually before merging the batch PR')
          VERIFY_SKIPS.push('release commit (' + (relWrite.commit || 'unknown SHA') + ') did not push to ' + TARGET + ' — push manually before merging the batch PR')
        } else {
          log('release: bumped to v' + derived.version + ' (' + derived.bump + ') on ' + TARGET + (relWrite.commit ? ' — commit ' + relWrite.commit : ' (no-op, already up to date)'))
        }
      }
    }
  }

  const bp = await agent([
    'Create (or update) the batch integration PR for this run — DO NOT MERGE IT under any circumstances;',
    'a human reviews and merges this PR.',
    '',
    '1. Existing? gh pr list --repo ' + REPO + ' --head ' + TARGET + ' --base ' + BASE + ' --state open --json number',
    '2. If none: gh pr create --repo ' + REPO + ' --base ' + BASE + ' --head ' + TARGET,
    '   Title: "Batch ' + RUN_TAG + ': ' + shippedIssues.length + ' issue(s) (' + TARGET + ')"',
    '   Body must contain:',
    '   - one "Closes #<issue>" line per shipped issue — every issue completed this pass AND every',
    '     issue absorbed via consolidation AND every issue whose per-issue PR already merged into',
    '     ' + TARGET + ' in a PRIOR pass (a resumed/healing run must not drop those):',
    shippedIssues.map(function (n) { return '     Closes #' + n }).join('\n'),
    '   - a results table (Issue | Title | PR into batch | Status) built from:',
    JSON.stringify(results.map(function (r) { return { issue: r.issue, title: r.title, pr: r.pr, status: r.status } })).slice(0, 6000),
    shippedGroups.length
      ? '   - a "## Consolidated Groups" section the reviewer MUST see, listing EXACTLY these lines (one\n' +
        '     line per group: its primary issue, every absorbed member, and why they were grouped):\n' +
        shippedGroups.map(function (g) {
          return '     - primary #' + g.primary + ' — members: ' + g.members.map(function (n) { return '#' + n }).join(', ') + ' — ' + g.rationale
        }).join('\n')
      : '   - (no consolidation groups shipped this run — every issue merged as its own unit)',
    VERIFY_SKIPS.length
      ? '   - a "## Verification Gaps" section the reviewer MUST see, listing EXACTLY these lines:\n' + VERIFY_SKIPS.map(function (s) { return '     - ' + s }).join('\n')
      : '   - (all verification gates ran; no gaps section needed)',
    '   - a note that per-issue PRs were squash-merged into ' + TARGET + ' with full review trails on each issue.',
    '   - this "## Merge Auto-Resolution" section, injected VERBATIM (already computed in JS — do not recompute,',
    '     re-sum, or add commentary beyond copying it in):\n' + MERGE_RESOLVE_AGG.markdown,
    '   - this "## Token Usage" section, injected VERBATIM (already computed in JS — do not recompute, re-sum,',
    '     or add commentary beyond copying it in):\n' + TOKEN_AGG.markdown,
    '3. If one exists: update its body to the current results (gh pr edit) and comment that the run refreshed it.',
    'Return status, pr_number, pr_url.',
  ].join('\n'), { label: 'batch-pr', phase: 'Report', schema: PR_SCHEMA, model: M.pr.model, effort: M.pr.effort })
  batchPr = (bp && bp.pr_number) || null
  if (batchPr) log('batch PR: #' + batchPr + ' (' + TARGET + ' -> ' + BASE + ') — awaiting human review, NOT merged')
  else log('batch PR creation failed — create manually: gh pr create --repo ' + REPO + ' --base ' + BASE + ' --head ' + TARGET)
} else {
  log('no shipped issues — skipping batch PR (' + TARGET + ' has nothing to integrate)')
}

// ---- Report ----
const resultsJson = JSON.stringify({
  state: state, base_branch: BASE, batch_branch: TARGET, batch_pr: batchPr, stop: STOP, counts: counts,
  verification_gaps: VERIFY_SKIPS, tokens_spent: spentTokens(),
  tokens: { run_total: TOKEN_AGG.run_total, by_issue: TOKEN_AGG.by_issue, by_model: TOKEN_AGG.by_model, by_stage: TOKEN_AGG.by_stage, tracked: TOKEN_AGG.tracked, reconciles: TOKEN_AGG.reconciles },
  merge_auto_resolve: { resolved_count: MERGE_RESOLVE_AGG.resolved_count, resolved_issues: MERGE_RESOLVE_AGG.resolved_issues, thrash_count: MERGE_RESOLVE_AGG.thrash_count, thrash_issues: MERGE_RESOLVE_AGG.thrash_issues },
  consolidation_groups: finalGroups,
  results: results,
}, null, 2)
const report = await agent([
  'Write the ticketmill run report.',
  '',
  '1. mkdir -p ' + LOGS,
  '2. Write the JSON below verbatim to ' + LOGS + '/summary-' + RUN_TAG + '.json',
  '3. Write a human-readable markdown summary to ' + LOGS + '/summary-' + RUN_TAG + '.md with:',
  '   a results table (Issue | Title | Status | PR | Follow-ups | Error), a per-issue pipeline narrative built',
  '   from each result\'s "timeline" field (gates, verdicts, iterations), a "Consolidated Groups" section if',
  '   consolidation_groups is non-empty — one line per group naming its primary issue, every absorbed member,',
  '   and the rationale it was grouped for (a group is ONE unit: its members share one worktree/branch/PR/result,',
  '   so list them explicitly here rather than only showing the primary\'s row in the results table), a',
  '   "Verification Gaps" section if verification_gaps is non-empty, a failures section with halt stages, and —',
  '   if state is not "completed" — a "Resume" section: re-run ticketmill with the same args (preflight skips',
  '   finished work) or resume via resumeFromRunId. Include this "## Merge Auto-Resolution" section VERBATIM',
  '   (already computed in JS — do not recompute, re-sum, or add commentary beyond copying it in):',
  MERGE_RESOLVE_AGG.markdown,
  '   Include this "## Token Usage" section VERBATIM (already',
  '   computed in JS — do not recompute, re-sum, or add commentary beyond copying it in):',
  TOKEN_AGG.markdown,
  '4. Include the current timestamp from: date -Iseconds',
  RUN_TAG === 'run' ? '5. The tag "run" is a collision-prone default: substitute the current date (date +%F) for "run" in BOTH filenames so successive runs do not overwrite each other, and return the actual path.' : '',
  '',
  'Run data:', resultsJson.slice(0, 30000),
  '',
  'Return report_path and markdown_summary (the table portion, compact).',
].join('\n'), { label: 'report', phase: 'Report', schema: REPORT_SCHEMA, model: M.report.model, effort: M.report.effort })

// ---- Retrospective (the pipeline improves itself) ----
// lanePredictions (issue #1, lane scheduling): predicted-vs-actual accuracy
// input. `units`/`results` are index-aligned (runPool() preserves that — see
// its module comment), so this zip is safe. Scoped to units that both
// predicted something AND completed with a real PR to diff actual changed
// files against — nothing to measure otherwise. Actual changed files require
// git/gh access the engine JS sandbox doesn't have, so the retro agent (which
// already has that access for its other steps) resolves each PR's files
// itself rather than the engine guessing/faking it here.
const lanePredictions = units
  .map(function (u, i) { return { unit: u, result: results[i] } })
  .filter(function (x) {
    return x.result && x.result.status === 'completed' && x.result.pr &&
      Array.isArray(x.unit.predicted_files) && x.unit.predicted_files.length > 0
  })
  .map(function (x) { return { issue: x.unit.issue, pr: x.result.pr, predicted_files: x.unit.predicted_files } })
  .slice(0, MAX_LANE_ACCURACY_SAMPLES)
const retro = await agent([
  'Update the ticketmill process-retrospective memory from this batch run.',
  '',
  'Memory file: ' + LOGS + '/process-retrospective.md (seed with "## Active Learnings",',
  '"## Deprecated Learnings", "## Run History", "## Lane Prediction Accuracy" sections if missing).',
  '',
  'Run data:', resultsJson.slice(0, 20000),
  '',
  lanePredictions.length
    ? ['Lane-scheduling predicted-vs-actual data (issue #1) — one entry per completed unit that had a',
        'prediction, ' + REPO + ':', JSON.stringify(lanePredictions)].join('\n')
    : 'Lane-scheduling predicted-vs-actual data (issue #1): none this run (no completed unit had predicted_files).',
  '',
  'Instructions:',
  '1. Read the memory file and its existing learnings.',
  '2. From this run, extract durable learnings about: agent selection, quality-loop behavior, test-loop behavior,',
  '   error patterns, workflow friction. Only add learnings supported by evidence in the run data.',
  '   Each result carries structured evidence — use it instead of reconstructing from git archaeology:',
  '   "metrics" (iteration counts), "timeline" (gate-by-gate decisions with verdict snippets — spot decision',
  '   flips and cap-outs), and "handoff_notes" (env workarounds agents discovered — prime test_loop learnings).',
  '3. Update the file: add new learnings, deprecate contradicted ones, append one Run History row per issue.',
  '   Enforce caps: 20 active learnings, 10 deprecated, 20 history rows (drop oldest).',
  '4. Lane prediction accuracy (issue #1 — SKIP entirely, leave lane_prediction_accuracy empty and add no row,',
  '   if the predicted-vs-actual data above is "none this run"): for each entry, run',
  '   gh pr view <pr> --repo ' + REPO + ' --json files --jq \'.files[].path\' (read-only; the PR is already',
  '   merged, this just lists what it touched) to get that unit\'s actual changed files. Compare against its',
  '   predicted_files (repo-relative path match). Compute, across ALL entries combined: coverage = (actual files',
  '   that were predicted) / (total actual files), and precision = (predicted files that were actually changed) /',
  '   (total predicted files). Append ONE row to "## Lane Prediction Accuracy" (date, issue count, coverage %,',
  '   precision %, e.g. "2026-07-19 — 4 issues — coverage 78% (7/9) — precision 64% (7/11)"). Cap that section at',
  '   20 rows (drop oldest). Set lane_prediction_accuracy to that same line.',
  'Return learnings_added, learnings_deprecated, summary, lane_prediction_accuracy (omit/empty if step 4 was skipped).',
].join('\n'), { label: 'retrospective', phase: 'Report', schema: RETRO_SCHEMA, model: M.retro.model })
if (!retro) log('retrospective agent died (non-fatal)')
else if (retro.lane_prediction_accuracy) log('lane prediction accuracy: ' + retro.lane_prediction_accuracy)

return {
  state: state,
  root: ROOT,
  repo: REPO,
  base_branch: BASE,
  batch_branch: TARGET,
  batch_pr: batchPr,
  counts: counts,
  verification_gaps: VERIFY_SKIPS,
  merge_auto_resolved_count: MERGE_RESOLVE_AGG.resolved_count,
  merge_thrash_count: MERGE_RESOLVE_AGG.thrash_count,
  results: results,
  report: report ? report.report_path : null,
  summary_table: report ? report.markdown_summary : null,
  lane_prediction_accuracy: retro ? (retro.lane_prediction_accuracy || null) : null,
  stopped: STOP.tripped ? STOP.reason : null,
  resume_hint: state === 'completed' ? null :
    'Re-run ticketmill with the same args PLUS batch_branch: "' + TARGET + '" (so healing lands on the same integration branch) — the Select-phase preflight skips merged/closed issues, routes open PRs straight to review/merge, and continues partial branches. For exact journal replay use Workflow({scriptPath, resumeFromRunId}).',
}
