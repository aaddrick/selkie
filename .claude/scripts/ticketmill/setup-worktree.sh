#!/usr/bin/env bash
# setup-worktree.sh — Deterministic worktree creation for the ticketmill engine.
#
# Usage: setup-worktree.sh <issue_number> <base_branch> <repo_root> <worktrees_dir> <repo_slug>
# Outputs JSON to stdout: {"status":"success","worktree":"...","branch":"..."}
# or {"status":"error","error":"..."}
#
# Branch naming: issue-<N>-<slug-from-issue-title>
# Worktree path: <worktrees_dir>/issue-<N>
#
# Idempotency: an existing worktree is reused when its branch matches the
# issue-<N>-* PREFIX — not the exact title-derived slug. Issue titles are
# editable mid-run; deriving the slug live and demanding an exact match would
# make a title edit destroy an in-flight worktree.
#
# This script does git mechanics ONLY. Dependency installs and env-file
# provisioning are driven by the profile (install_commands / env_files) in the
# engine's setup stage, so nothing language-specific lives here.

set -euo pipefail

if [[ $# -lt 5 ]]; then
    echo '{"status":"error","error":"usage: setup-worktree.sh <issue> <base_branch> <repo_root> <worktrees_dir> <repo_slug>"}'
    exit 1
fi

ISSUE_NUMBER="$1"
BASE_BRANCH="$2"
REPO_ROOT="$3"
WORKTREES_DIR="${4:-$REPO_ROOT/.worktrees}"
REPO="$5"

die() { echo "{\"status\":\"error\",\"error\":\"$*\"}" >&1; exit 1; }

worktree="${WORKTREES_DIR}/issue-${ISSUE_NUMBER}"

# --- Idempotency: reuse an existing worktree on any issue-<N>-* branch ---
if [[ -d "$worktree" ]]; then
    existing_branch=$(git -C "$worktree" branch --show-current 2>/dev/null || true)
    if [[ "$existing_branch" == issue-${ISSUE_NUMBER}-* ]]; then
        echo "{\"status\":\"success\",\"worktree\":\"$worktree\",\"branch\":\"$existing_branch\"}"
        exit 0
    fi
    # Wrong branch — remove stale worktree
    git -C "$REPO_ROOT" worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
fi

# --- Reuse an existing issue-<N>-* branch before deriving a fresh slug ---
branch=$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/issue-${ISSUE_NUMBER}-*" | head -1)

if [[ -z "$branch" ]]; then
    # --- Fetch issue title for the branch slug (first creation only) ---
    title=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title --jq '.title' 2>/dev/null) \
        || die "Could not fetch issue #$ISSUE_NUMBER from $REPO"

    slug=$(echo "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//' \
        | cut -c1-50)

    [[ -z "$slug" ]] && slug="untitled"

    branch="issue-${ISSUE_NUMBER}-${slug}"
fi

# --- Fetch latest base branch ---
git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH" --quiet \
    || die "Could not fetch origin/$BASE_BRANCH"

# --- Create branch if it doesn't exist ---
if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$REPO_ROOT" branch "$branch" "origin/$BASE_BRANCH" >/dev/null 2>&1 \
        || die "Could not create branch $branch"
fi

# --- Add worktree ---
mkdir -p "$WORKTREES_DIR"
git -C "$REPO_ROOT" worktree add "$worktree" "$branch" >/dev/null 2>&1 \
    || die "Could not add worktree at $worktree"

# --- Init submodules when the project uses them ---
if [[ -f "$worktree/.gitmodules" ]]; then
    git -C "$worktree" submodule update --init --recursive >/dev/null 2>&1 \
        || die "Worktree created but submodule init failed in $worktree"
fi

echo "{\"status\":\"success\",\"worktree\":\"$worktree\",\"branch\":\"$branch\"}"
