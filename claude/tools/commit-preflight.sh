#!/usr/bin/env bash
set -euo pipefail

# ── commit-preflight.sh ──
# Gathers pre-commit context in a single execution.
# Standard mode: test results + git status + diff + recent commits
# Flow mode (--flow): adds branch, worktree, QA report, uncommitted checks
#
# Usage:
#   commit-preflight.sh [--flow] [--test-cmd CMD]
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

# ── Parse arguments ──
FLOW=false
TEST_CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow) FLOW=true; shift ;;
    --test-cmd) TEST_CMD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── Auto-detect test command if not provided ──
if [ -z "$TEST_CMD" ]; then
  if [ -x "./scripts/run_tests.sh" ]; then
    TEST_CMD="./scripts/run_tests.sh"
  fi
fi

# ── Run tests ──
tests_passed="null"
test_output=""
if [ -n "$TEST_CMD" ]; then
  test_raw=""
  test_exit=0
  test_raw=$(eval "$TEST_CMD" 2>&1) || test_exit=$?
  if [ "$test_exit" -eq 0 ]; then
    tests_passed="true"
  else
    tests_passed="false"
  fi
  # Truncate to last 30 lines, strip control chars
  test_output=$(echo "$test_raw" | tail -30 | tr -d '\000-\010\013\014\016-\037\177')
fi

# ── Gather git context ──
status=$(git status --short 2>/dev/null || true)
diff_stat=$(git diff --stat 2>/dev/null || true)
recent_commits=$(git log --oneline -5 2>/dev/null || true)

# ── Standard mode output ──
if [ "$FLOW" = "false" ]; then
  ok="true"
  error=""
  if [ "$tests_passed" = "false" ]; then
    ok="false"
    error="tests failed"
  elif [ "$tests_passed" = "null" ]; then
    ok="false"
    error="no test runner found (use --test-cmd or create ./scripts/run_tests.sh)"
  fi

  jq -n \
    --argjson ok "$ok" \
    --argjson tests_passed "$tests_passed" \
    --arg test_output "$test_output" \
    --arg status "$status" \
    --arg diff_stat "$diff_stat" \
    --arg recent_commits "$recent_commits" \
    --arg error "$error" \
    '{ok:$ok, tests_passed:$tests_passed, test_output:$test_output, status:$status, diff_stat:$diff_stat, recent_commits:$recent_commits} + (if $error != "" then {error:$error} else {} end)'
  exit 0
fi

# ── Flow mode: additional context ──
branch=$(git branch --show-current 2>/dev/null || true)
if [ -z "$branch" ]; then
  branch_json="null"
else
  branch_json="\"$branch\""
fi

# Determine if we're in a worktree (not the main worktree)
is_worktree=false
main_worktree=""
wt_porcelain=$(git worktree list --porcelain 2>/dev/null || true)
# First worktree listed is always the main one
main_worktree=$(echo "$wt_porcelain" | head -1 | sed 's/^worktree //')
current_dir=$(pwd -P)
if [ "$current_dir" != "$main_worktree" ]; then
  is_worktree=true
fi

# Check for QA report
has_qa_report=false
# Extract feature name from branch (feature/foo → foo)
if [ -n "$branch" ]; then
  feature_name="${branch##*/}"
  # Check docs/*<feature>*/QA_REPORT.md or TEAM_QA.md
  if compgen -G "docs/*${feature_name}*/QA_REPORT.md" >/dev/null 2>&1 || \
     compgen -G "docs/*${feature_name}*/TEAM_QA.md" >/dev/null 2>&1; then
    has_qa_report=true
  fi
fi

uncommitted="$status"

# Determine ok status for flow mode
ok="true"
error=""
if [ "$is_worktree" = "false" ]; then
  ok="false"
  error="not in a worktree — /commit flow must run from a feature worktree"
elif [ -z "$branch" ]; then
  ok="false"
  error="detached HEAD — cannot determine branch"
elif [ "$tests_passed" = "false" ]; then
  ok="false"
  error="tests failed"
elif [ "$tests_passed" = "null" ]; then
  ok="false"
  error="no test runner found (use --test-cmd or create ./scripts/run_tests.sh)"
fi

jq -n \
  --argjson ok "$ok" \
  --argjson tests_passed "$tests_passed" \
  --arg test_output "$test_output" \
  --argjson is_worktree "$is_worktree" \
  --arg main_worktree "$main_worktree" \
  --argjson has_qa_report "$has_qa_report" \
  --arg uncommitted "$uncommitted" \
  --arg error "$error" \
  --arg branch_str "${branch:-}" \
  '{ok:$ok, tests_passed:$tests_passed, test_output:$test_output, branch:(if $branch_str == "" then null else $branch_str end), is_worktree:$is_worktree, main_worktree:$main_worktree, has_qa_report:$has_qa_report, uncommitted:$uncommitted} + (if $error != "" then {error:$error} else {} end)'

exit 0
