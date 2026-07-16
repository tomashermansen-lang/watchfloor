#!/bin/bash
set -euo pipefail
MAIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$MAIN_DIR/.." && pwd)"
# shellcheck source=../../adapters/claude-code/claude/tools/lib/worktree-reaper.sh
source "$REPO_ROOT/adapters/claude-code/claude/tools/lib/worktree-reaper.sh"
COMMAND="${1:-}"; FEATURE="${2:-}"
[[ -z "$COMMAND" || -z "$FEATURE" ]] && { echo "Usage: $0 {new|rm} <feature-name>"; exit 1; }
WORKTREE_DIR="$MAIN_DIR/../claude-agent-dashboard-$FEATURE"
BRANCH="feature/$FEATURE"
case "$COMMAND" in
  new)
    [[ -d "$WORKTREE_DIR" ]] && { echo "ERROR: Worktree exists at $WORKTREE_DIR" >&2; exit 1; }
    echo "==> Creating worktree at $WORKTREE_DIR on branch $BRANCH"
    git worktree add "$WORKTREE_DIR" -b "$BRANCH"
    [[ -d "$MAIN_DIR/app/node_modules" ]] && { echo "==> Installing app/node_modules"; (cd "$WORKTREE_DIR/app" && npm ci --silent); }
    echo "Done! Open $WORKTREE_DIR in VSCode." ;;
  rm)
    [[ ! -d "$WORKTREE_DIR" ]] && { echo "ERROR: No worktree at $WORKTREE_DIR" >&2; exit 1; }
    reap_worktree_orphans "$WORKTREE_DIR"
    git worktree remove "$WORKTREE_DIR" --force
    git rev-parse --verify "$BRANCH" &>/dev/null && git branch -d "$BRANCH" 2>/dev/null || true
    echo "Done." ;;
  *) echo "Usage: $0 {new|rm} <feature-name>"; exit 1 ;;
esac
