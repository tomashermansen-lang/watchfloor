#!/usr/bin/env bash
set -euo pipefail

# ── start-validate.sh ──
# Validates context before starting a new feature.
# Checks: is main project (not worktree), no existing feature worktree/branch.
#
# Usage:
#   start-validate.sh <feature-name>
#
# Output: JSON to stdout. All diagnostics to stderr.
# Exit: Always 0. Errors reported via ok:false in JSON.

# ── Error trap: ensure valid JSON on crash ──
_bail() {
  jq -n --arg error "$1" '{"ok":false,"error":$error}' 2>/dev/null \
    || printf '{"ok":false,"error":"internal error"}\n'
  exit 0
}
trap '_bail "unexpected error at line $LINENO"' ERR

# ── Dependency checks ──
command -v jq >/dev/null 2>&1 || { _bail "jq not found — install with: brew install jq"; }
command -v git >/dev/null 2>&1 || { _bail "git not available"; }

# ── Verify we're in a git repo ──
git rev-parse --git-dir >/dev/null 2>&1 || { _bail "not a git repository"; }

# ── Validate argument ──
FEATURE="${1:-}"
if [ -z "$FEATURE" ]; then
  _bail "feature name required — usage: start-validate.sh <feature-name>"
fi

# ── Check 1: Is this the main project (not a worktree)? ──
is_main_project=true
wt_porcelain=$(git worktree list --porcelain 2>/dev/null || true)
main_worktree=$(echo "$wt_porcelain" | head -1 | sed 's/^worktree //')
current_dir=$(pwd -P)
if [ "$current_dir" != "$main_worktree" ]; then
  is_main_project=false
fi

# ── Check 2: Current branch (informational) ──
current_branch=$(git branch --show-current 2>/dev/null || true)

# ── Check 3: Does a feature branch already exist? ──
existing_branch=false
branch_output=$(git branch --list "feature/$FEATURE" 2>/dev/null || true)
if [ -n "$branch_output" ]; then
  existing_branch=true
fi

# ── Check 4: Does a worktree for this feature already exist? ──
existing_worktree=""
# Parse worktree list for branch refs/heads/feature/<feature>
while IFS= read -r line; do
  if [[ "$line" == "worktree "* ]]; then
    current_wt_path="${line#worktree }"
  fi
  if [[ "$line" == "branch refs/heads/feature/$FEATURE" ]]; then
    existing_worktree="$current_wt_path"
    break
  fi
done <<< "$wt_porcelain"

# ── Compute feature_exists ──
feature_exists=false
if [ "$existing_branch" = "true" ] || [ -n "$existing_worktree" ]; then
  feature_exists=true
fi

# ── Compute ok ──
ok=true
error=""
if [ "$is_main_project" = "false" ]; then
  ok=false
  error="not in main project — /start must run from the main project, not a worktree"
elif [ "$feature_exists" = "true" ]; then
  ok=false
  if [ -n "$existing_worktree" ]; then
    error="feature '$FEATURE' already has a worktree at $existing_worktree"
  else
    error="branch feature/$FEATURE already exists"
  fi
fi

# ── Output JSON ──
jq -n \
  --argjson ok "$ok" \
  --argjson is_main_project "$is_main_project" \
  --argjson feature_exists "$feature_exists" \
  --arg existing_worktree "$existing_worktree" \
  --argjson existing_branch "$existing_branch" \
  --arg current_branch "$current_branch" \
  --arg error "$error" \
  '{ok:$ok, is_main_project:$is_main_project, feature_exists:$feature_exists, existing_worktree:(if $existing_worktree == "" then null else $existing_worktree end), existing_branch:$existing_branch, current_branch:$current_branch} + (if $error != "" then {error:$error} else {} end)'

exit 0
