#!/usr/bin/env bash
set -euo pipefail

# ── done-verify.sh ──
# Checks all cleanup criteria for a completed feature in a single execution.
# Verifies: worktree removed, branch deleted, merged to main, docs prefix.
#
# Usage:
#   done-verify.sh <feature-name>
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
  _bail "feature name required — usage: done-verify.sh <feature-name>"
fi

# ── Check 1: Worktree removed ──
# Use git worktree list to find any worktree on feature/<name> branch
worktree_removed=true
wt_porcelain=$(git worktree list --porcelain 2>/dev/null || true)
# Parse worktree list: look for a worktree with branch refs/heads/feature/<feature>
if echo "$wt_porcelain" | grep -q "branch refs/heads/feature/$FEATURE"; then
  worktree_removed=false
fi

# ── Check 2: Branch deleted ──
branch_deleted=true
branch_output=$(git branch --list "feature/$FEATURE" 2>/dev/null || true)
if [ -n "$branch_output" ]; then
  branch_deleted=false
fi

# ── Check 3: Merged to main ──
is_merged=false
merge_evidence=""
log_output=$(git log --oneline --all --grep="$FEATURE" 2>/dev/null | head -5 || true)
if [ -n "$log_output" ]; then
  is_merged=true
  merge_evidence=$(echo "$log_output" | tr -d '\000-\010\013\014\016-\037\177')
fi

# ── Check 4: Docs status ──
# Convention: docs/{STATUS}_{Type}_{name}/ where Type is Feature or Plan
docs_status="missing"
if [ -d "docs/DONE_Feature_$FEATURE" ] || [ -d "docs/DONE_Plan_$FEATURE" ]; then
  docs_status="done"
elif [ -d "docs/INPROGRESS_Feature_$FEATURE" ] || [ -d "docs/INPROGRESS_Plan_$FEATURE" ]; then
  docs_status="inprogress"
elif [ -d "docs/PENDING_Feature_$FEATURE" ] || [ -d "docs/PENDING_Plan_$FEATURE" ]; then
  docs_status="pending"
fi

# ── Compute all_clean ──
all_clean=false
if [ "$worktree_removed" = "true" ] && [ "$branch_deleted" = "true" ] && [ "$is_merged" = "true" ] && [ "$docs_status" = "done" ]; then
  all_clean=true
fi

# ── Output JSON ──
jq -n \
  --argjson ok "$all_clean" \
  --argjson all_clean "$all_clean" \
  --argjson worktree_removed "$worktree_removed" \
  --argjson branch_deleted "$branch_deleted" \
  --argjson is_merged "$is_merged" \
  --arg merge_evidence "$merge_evidence" \
  --arg docs_status "$docs_status" \
  '{ok:$ok, all_clean:$all_clean, worktree_removed:$worktree_removed, branch_deleted:$branch_deleted, is_merged:$is_merged, merge_evidence:$merge_evidence, docs_status:$docs_status}'

exit 0
