#!/bin/bash
# test_risk_summary.sh — tests for compute_risk_level and print_risk_summary
# in sync.sh. Verifies that aggregate classifications produce the expected
# risk level (NONE / LOW / MEDIUM / HIGH).
#
# Usage: bash tests/test_risk_summary.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$REPO_DIR/sync.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"; shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"; passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"; failed=$((failed + 1))
    fi
}

# Source only the function definitions from sync.sh by extracting them. We
# can't `source $SYNC` directly because the bottom case-statement runs and
# exits 1 with no command argument.
TMPDIR_TEST="${TMPDIR:-/tmp}/test-risk-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

EXTRACTED="$TMPDIR_TEST/risk-funcs.sh"
# Pull lines from "compute_risk_level()" through the end of "print_risk_summary"
# function (closing brace at column 0).
awk '
    /^compute_risk_level\(\)/      { capture=1 }
    capture                        { print }
    /^}$/ && capture && captured++ >= 1 && /^}$/ {
        if (captured >= 2) exit
    }
' "$SYNC" > "$EXTRACTED"
# Simpler: just extract from compute_risk_level to end-of-print_risk_summary
# using line numbers from grep
START=$(grep -n '^compute_risk_level()' "$SYNC" | head -1 | cut -d: -f1)
END=$(grep -n '^print_risk_summary()' "$SYNC" | head -1 | cut -d: -f1)
if [[ -z "$START" || -z "$END" ]]; then
    echo "Could not find functions in $SYNC" >&2
    exit 1
fi
# Find the closing brace of print_risk_summary — search forward from $END for
# a line that's just "}" at column 0, ending the function.
FUNC_END=$(awk -v s="$END" 'NR>=s && /^}$/ {print NR; exit}' "$SYNC")
# Extract the block + define color vars (used by print_risk_summary)
{
    cat <<'COLORS'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
COLORS
    sed -n "${START},${FUNC_END}p" "$SYNC"
} > "$EXTRACTED"

# shellcheck disable=SC1090
source "$EXTRACTED"

# ---------------------------------------------------------------------------
# Risk-level tests
# ---------------------------------------------------------------------------

check "T01 NONE: no changes" \
    test "$(compute_risk_level 'OK   claude/CLAUDE.md
OK   start-system.sh')" = NONE

check "T02 LOW: only HARDEN + NEUTRAL" \
    test "$(compute_risk_level '✓ HARDEN: tilføjet deny
✓ HARDEN: tilføjet hook
◦ NEUTRAL: refactor
CHANGED claude/foo')" = LOW

check "T03 MEDIUM: 1 DANGER, no critical paths" \
    test "$(compute_risk_level '✓ HARDEN: a
⚠ DANGER: noget mindre farligt')" = MEDIUM

check "T04 MEDIUM: 2 DANGER, no critical paths" \
    test "$(compute_risk_level '⚠ DANGER: a
⚠ DANGER: b
✓ HARDEN: c')" = MEDIUM

check "T05 HIGH: 3+ DANGER" \
    test "$(compute_risk_level '⚠ DANGER: a
⚠ DANGER: b
⚠ DANGER: c')" = HIGH

check "T06 HIGH: trust-chain CRITICAL banner" \
    test "$(compute_risk_level '✓ HARDEN: x
⚠⚠⚠ CRITICAL: trust-chain file modification detected')" = HIGH

check "T07 HIGH: sandbox.enabled true → false" \
    test "$(compute_risk_level '⚠ DANGER: sandbox.enabled true → false')" = HIGH

check "T08 HIGH: allowUnsandboxedCommands flipped on" \
    test "$(compute_risk_level '⚠ DANGER: sandbox.allowUnsandboxedCommands false → true')" = HIGH

check "T09 HIGH: PreToolUse hook removed" \
    test "$(compute_risk_level '⚠ DANGER: FJERNET PreToolUse-hook (matcher=Edit|Write): bash foo.sh')" = HIGH

check "T10 HIGH: defaultMode → bypassPermissions" \
    test "$(compute_risk_level '⚠ DANGER: permissions.defaultMode acceptEdits → bypassPermissions')" = HIGH

check "T11 HIGH: ~/.ssh denyRead removed" \
    test "$(compute_risk_level '⚠ DANGER: sandbox.denyRead: FJERNET ~/.ssh')" = HIGH

# ---------------------------------------------------------------------------
# Summary banner formatting tests
# ---------------------------------------------------------------------------

test_banner_counts() {
    local out
    out=$(print_risk_summary MEDIUM '⚠ DANGER: a
✓ HARDEN: b
✓ HARDEN: c')
    [[ "$out" == *'1 DANGER'* ]] && [[ "$out" == *'2 HARDEN'* ]]
}
check "T12 banner contains DANGER count" test_banner_counts

test_banner_critical_detail() {
    local out
    out=$(print_risk_summary HIGH '⚠⚠⚠ CRITICAL: trust-chain file modification detected')
    [[ "$out" == *'CRITICAL TRIGGERS'* ]] && [[ "$out" == *'trust-chain'* ]]
}
check "T13 banner contains HIGH critical-trigger detail" test_banner_critical_detail

test_banner_low() {
    local out
    out=$(print_risk_summary LOW '✓ HARDEN: a')
    [[ "$out" == *'kan godkendes uden'* ]]
}
check "T14 banner LOW shows 'kan godkendes uden'" test_banner_low

test_banner_high_guidance() {
    local out
    out=$(print_risk_summary HIGH '⚠ DANGER: a
⚠ DANGER: b
⚠ DANGER: c')
    [[ "$out" == *'læs HVER linje'* ]]
}
check "T15 banner HIGH shows 'læs HVER linje'" test_banner_high_guidance

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
[[ $failed -eq 0 ]] && exit 0 || exit 1
