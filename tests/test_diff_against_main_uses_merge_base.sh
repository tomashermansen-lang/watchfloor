#!/bin/bash
# test_diff_against_main_uses_merge_base.sh — regression guard for
# parallel-autopilot safety.
#
# Every reference to "files changed on this branch" in deployed agent
# prompts, rules, and skills MUST use the three-dot merge-base form
# (`git diff main...HEAD`), never the two-dot or shorthand form
# (`git diff main..HEAD` or `git diff main` without `..`/`...`).
#
# Why:
#   Under parallel autopilot, sibling tasks merge to main while this
#   task is still running. The two-dot form lists every file that
#   differs between branch tips — including the sibling task's files
#   that landed on main. The three-dot form pins comparison to the
#   merge-base (fork commit), so the diff returns only files THIS
#   branch changed.
#
#   Concrete blast radius (2026-05-12): grinder-scanner-enable QA
#   spent 76 turns and $6.09 trying to "fix" 12 files it never
#   touched, because a self-policing test used `main..HEAD`. See
#   commit 4cd1603 on feature/grinder-scanner-enable for the
#   in-worktree fix; this test prevents the pattern from reappearing
#   in any new prompt/rule/skill text shipped from this repo.
#
# Usage: bash tests/test_diff_against_main_uses_merge_base.sh
# Exits 0 on pass, 1 on any forbidden pattern found.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCAN_DIRS=(
    "$REPO_DIR/adapters/claude-code/claude/commands"
    "$REPO_DIR/adapters/claude-code/claude/rules"
    "$REPO_DIR/adapters/claude-code/claude/skills"
    "$REPO_DIR/adapters/claude-code/claude/agents"
)

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"
    shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

# Verbatim match for the bad shorthand "git diff main --..." or
# "git diff main HEAD ..." or "git diff main..HEAD" — anything other
# than three dots (or nothing-after-main inside backticks, allowed for
# narrative reference).
#
# Allowed three-dot form:
#   git diff main...HEAD
#   git diff main...HEAD --name-only
#   git diff --name-only main...HEAD
#
# Forbidden patterns:
#   git diff main --name-only         (shorthand, two-dot-equivalent)
#   git diff main..HEAD               (explicit two-dot)
#   git diff main HEAD                (positional, two-dot-equivalent)

# ── T01: no `git diff main --` shorthand anywhere in scanned dirs ──
test_no_bare_shorthand() {
    local hits
    hits=$(grep -rEn 'git diff[[:space:]]+main[[:space:]]+--' "${SCAN_DIRS[@]}" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        echo "  Forbidden 'git diff main --...' shorthand found:" >&2
        echo "$hits" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}
check "T01: no 'git diff main --<flag>' shorthand (use 'git diff main...HEAD --<flag>')" test_no_bare_shorthand

# ── T02: no explicit two-dot main..HEAD ──
test_no_two_dot_main_head() {
    local hits
    hits=$(grep -rEn 'git diff[^`]*main\.\.HEAD' "${SCAN_DIRS[@]}" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        echo "  Forbidden 'main..HEAD' (two-dot) found:" >&2
        echo "$hits" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}
check "T02: no 'git diff main..HEAD' (two-dot ranges break under parallel autopilot)" test_no_two_dot_main_head

# ── T03: no 'git diff main HEAD' positional form (no .. at all) ──
test_no_positional_main_head() {
    local hits
    hits=$(grep -rEn 'git diff[[:space:]]+main[[:space:]]+HEAD' "${SCAN_DIRS[@]}" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        echo "  Forbidden 'git diff main HEAD' positional form found:" >&2
        echo "$hits" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}
check "T03: no 'git diff main HEAD' positional form (use 'git diff main...HEAD')" test_no_positional_main_head

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
