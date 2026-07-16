#!/bin/bash
# worktree.sh — Create and remove git worktrees for dotfiles feature development.
#
# Usage:
#   ./scripts/worktree.sh new <feature-name>   — create worktree + branch
#   ./scripts/worktree.sh rm <feature-name>     — remove worktree + branch
#
# What "new" does:
#   1. Creates git worktree at ../dotfiles-<feature>/
#   2. Creates branch feature/<feature>
#   3. Provisions a relocatable Python venv via `uv sync --extra dev`
#      (mypy/ruff/pytest-cov hardlinked from the global uv cache; ~1s, ~0 disk)
#   4. Provisions dashboard/app/node_modules via `npm ci`
#
# Background: gitignored deps (.venv, node_modules) do NOT carry across git
# worktrees — only the .git database is shared. Without this provisioning,
# every worktree starts toolless and autopilot phases either skip or try to
# install on the fly (slow, brittle, fails on sandbox network policies).
# uv with --relocatable + the global cache makes per-worktree venvs cheap.
# References: https://pnpm.io/next/git-worktrees, uv PR astral-sh/uv#5515.
#
# Override:
#   WORKTREE_SKIP_PROVISION=1 ./scripts/worktree.sh new <name>
#     skips the uv sync + npm ci step (e.g., for sandbox-restricted tests)

set -euo pipefail

MAIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../adapters/claude-code/claude/tools/lib/worktree-reaper.sh
source "$MAIN_DIR/adapters/claude-code/claude/tools/lib/worktree-reaper.sh"
COMMAND="${1:-}"
FEATURE="${2:-}"

usage() {
    echo "Usage: $0 {new|rm} <feature-name>"
    exit 1
}

[[ -z "$COMMAND" || -z "$FEATURE" ]] && usage

WORKTREE_DIR="$MAIN_DIR/../dotfiles-$FEATURE"
BRANCH="feature/$FEATURE"

# Provision Python + Node deps in a fresh worktree. Both calls are idempotent
# and cache-warm so a second run is near-instant.
provision_worktree() {
    local wt="$1"

    if [[ "${WORKTREE_SKIP_PROVISION:-0}" == "1" ]]; then
        echo "==> Skipping provision (WORKTREE_SKIP_PROVISION=1)"
        return 0
    fi

    if command -v uv >/dev/null 2>&1 && [[ -f "$wt/pyproject.toml" ]]; then
        echo "==> Provisioning Python venv (uv sync --extra dev, relocatable)"
        # First the bare relocatable venv, then sync deps into it. uv sync
        # alone won't make an existing or newly created venv relocatable —
        # the flag belongs on `uv venv`.
        (cd "$wt" && uv venv --relocatable >/dev/null && uv sync --extra dev) \
            || echo "WARN: uv sync failed in $wt — autopilot will hit missing tools"
    else
        echo "==> Skipping uv sync (uv not on PATH or no pyproject.toml)"
    fi

    # Frontend deps. pnpm is preferred (content-addressable store hardlinks
    # into each worktree → ~zero extra disk per worktree). Falls back to
    # npm for projects still on package-lock.json.
    if command -v pnpm >/dev/null 2>&1 && [[ -f "$wt/dashboard/app/pnpm-lock.yaml" ]]; then
        echo "==> Provisioning dashboard/app/node_modules (pnpm install --frozen-lockfile)"
        (cd "$wt/dashboard/app" && pnpm install --frozen-lockfile --silent) \
            || echo "WARN: pnpm install failed — frontend tests/build will be unavailable"
    elif command -v npm >/dev/null 2>&1 && [[ -f "$wt/dashboard/app/package-lock.json" ]]; then
        echo "==> Provisioning dashboard/app/node_modules (npm ci, fallback)"
        (cd "$wt/dashboard/app" && npm ci --silent --no-audit --no-fund) \
            || echo "WARN: npm ci failed — frontend tests/build will be unavailable"
    fi
}

cmd_new() {
    if [[ -d "$WORKTREE_DIR" ]]; then
        echo "ERROR: Worktree already exists at $WORKTREE_DIR" >&2
        exit 1
    fi

    echo "==> Creating worktree at $WORKTREE_DIR on branch $BRANCH"
    git worktree add "$WORKTREE_DIR" -b "$BRANCH"

    # .claude/ is gitignored. If the worktree needs per-session hooks/logs,
    # create a local one inside the worktree rather than symlinking main's —
    # the symlink previously got tracked by git and caused merge conflicts.
    # Shared settings.json is at ~/.claude/ (global) so no per-worktree symlink
    # is needed.

    provision_worktree "$WORKTREE_DIR"

    echo ""
    echo "Done! Worktree ready at $WORKTREE_DIR"
    echo "  Branch: $BRANCH"
    echo ""
    echo "Next: Open $WORKTREE_DIR in VSCode and start a new Claude chat."
}

cmd_rm() {
    if [[ ! -d "$WORKTREE_DIR" ]]; then
        echo "ERROR: No worktree at $WORKTREE_DIR" >&2
        exit 1
    fi

    echo "==> Removing worktree at $WORKTREE_DIR"
    reap_worktree_orphans "$WORKTREE_DIR"
    git worktree remove "$WORKTREE_DIR" --force

    if git rev-parse --verify "$BRANCH" &>/dev/null; then
        echo "==> Deleting branch $BRANCH (if merged)"
        git branch -d "$BRANCH" 2>/dev/null || \
            echo "WARN: Branch $BRANCH not fully merged. Use 'git branch -D $BRANCH' to force-delete." >&2
    fi

    echo "Done."
}

case "$COMMAND" in
    new) cmd_new ;;
    rm)  cmd_rm  ;;
    *)   usage   ;;
esac
