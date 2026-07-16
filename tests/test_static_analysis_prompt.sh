#!/bin/bash
# test_static_analysis_prompt.sh — regression guards on the /static-analysis
# slash command prompt (claude/commands/static-analysis.md).
#
# These tests pin the SonarQube polling/results contract so a future prompt
# rewrite cannot silently reintroduce a 403-prone endpoint or lose the
# project-scoped fallback. Closes env-gap-sonar-token-403-on-ce-activity.
#
# Usage: bash tests/test_static_analysis_prompt.sh
# Exits 0 on pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROMPT="$REPO_DIR/adapters/claude-code/claude/commands/static-analysis.md"

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

[[ -f "$PROMPT" ]] || { echo "FATAL: $PROMPT not found"; exit 1; }

# ── T01: /api/ce/activity is not used for the poll-until-done step ──
# Project-scoped SONAR_TOKEN returns 403 on /api/ce/activity (needs Browse
# on the global endpoint). The prompt must poll /api/qualitygates/project_status
# instead, which works with the project-scoped token.
test_no_ce_activity_poll() {
    ! grep -qE 'curl.*\/api\/ce\/activity' "$PROMPT"
}
check "T01: prompt does not invoke /api/ce/activity (403 with project-scoped token)" test_no_ce_activity_poll

# ── T02: poll loop targets /api/qualitygates/project_status ──
test_poll_uses_qualitygates() {
    grep -qE 'curl.*\/api\/qualitygates\/project_status' "$PROMPT"
}
check "T02: prompt polls /api/qualitygates/project_status" test_poll_uses_qualitygates

# ── T03: poll is bounded — finite max-wait documented ──
# A regression guard against unbounded polling. The original 2-minute cap
# should survive any prompt rewrite.
test_bounded_poll() {
    grep -qE '(max [0-9]+ (minute|second)|timeout|deadline)' "$PROMPT"
}
check "T03: poll has a documented bound (max-wait / timeout / deadline)" test_bounded_poll

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
