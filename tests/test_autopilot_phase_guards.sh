#!/usr/bin/env bash
# test_autopilot_phase_guards.sh — H.T1
#
# Tests the R43 protected-plan-dir guard logic against synthetic git diff output.
#
# The guard command (as documented in REQUIREMENTS.md R43) is:
#   git diff --name-only HEAD..feature/x | grep -E \
#     "docs/INPROGRESS_Plan_zero-tech-debt-pipeline/|docs/INPROGRESS_Plan_pipeline-optimization-v2/|docs/INPROGRESS_Plan_autopilot-hardening/"
#
# Exit semantics:
#   grep returns 0 (match found)    → protected dir touched → phase FAILS (bad)
#   grep returns 1 (no match)       → no protected dir touched → phase PASSES (good)
#
# TC-APG01: no protected dirs touched → grep exits 1 (pass path)
# TC-APG02: INPROGRESS_Plan_zero-tech-debt-pipeline/ touched → grep exits 0 (fail path)
# TC-APG03: INPROGRESS_Plan_pipeline-optimization-v2/ touched → grep exits 0
# TC-APG04: INPROGRESS_Plan_autopilot-hardening/ touched → grep exits 0
# TC-APG05: INPROGRESS_Plan_other-name/ touched → grep exits 1 (not protected)
#
# Usage: bash tests/test_autopilot_phase_guards.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

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

check_fail() {
    local name="$1"
    shift
    if ! "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name (expected failure but succeeded)"
        failed=$((failed + 1))
    fi
}

# ---------------------------------------------------------------------------
# The exact grep pattern from the R43 guard (extracted for unit testing).
# In production autopilot.sh this is piped from `git diff --name-only`.
# Here we echo synthetic diff output into the same grep command.
# ---------------------------------------------------------------------------
PROTECTED_GREP_PATTERN="docs/INPROGRESS_Plan_zero-tech-debt-pipeline/|docs/INPROGRESS_Plan_pipeline-optimization-v2/|docs/INPROGRESS_Plan_autopilot-hardening/"

_guard_matches() {
    # Takes newline-separated file list on stdin; exits 0 if any protected path found.
    grep -E "$PROTECTED_GREP_PATTERN"
}

# ---------------------------------------------------------------------------
# TC-APG01: no protected dirs touched → grep exits 1 (success: no match).
# ---------------------------------------------------------------------------
tc_apg01() {
    printf 'src/foo.py\nclaude/tools/bar.sh\n' | _guard_matches >/dev/null 2>&1
}
check_fail "TC-APG01: no protected paths → guard finds no match (phase passes)" tc_apg01

# ---------------------------------------------------------------------------
# TC-APG02: INPROGRESS_Plan_zero-tech-debt-pipeline/ modified → grep exits 0.
# ---------------------------------------------------------------------------
tc_apg02() {
    printf 'docs/INPROGRESS_Plan_zero-tech-debt-pipeline/execution-plan.yaml\n' \
        | _guard_matches >/dev/null 2>&1
}
check "TC-APG02: zero-tech-debt-pipeline dir touched → guard matches (phase fails)" tc_apg02

# ---------------------------------------------------------------------------
# TC-APG03: INPROGRESS_Plan_pipeline-optimization-v2/ modified → grep exits 0.
# ---------------------------------------------------------------------------
tc_apg03() {
    printf 'docs/INPROGRESS_Plan_pipeline-optimization-v2/execution-plan.yaml\n' \
        | _guard_matches >/dev/null 2>&1
}
check "TC-APG03: pipeline-optimization-v2 dir touched → guard matches (phase fails)" tc_apg03

# ---------------------------------------------------------------------------
# TC-APG04: INPROGRESS_Plan_autopilot-hardening/ modified → grep exits 0.
# ---------------------------------------------------------------------------
tc_apg04() {
    printf 'docs/INPROGRESS_Plan_autopilot-hardening/execution-plan.yaml\n' \
        | _guard_matches >/dev/null 2>&1
}
check "TC-APG04: autopilot-hardening dir touched → guard matches (phase fails)" tc_apg04

# ---------------------------------------------------------------------------
# TC-APG05: INPROGRESS_Plan_other-name/ modified → grep exits 1 (not protected).
# ---------------------------------------------------------------------------
tc_apg05() {
    printf 'docs/INPROGRESS_Plan_other-name/execution-plan.yaml\n' \
        | _guard_matches >/dev/null 2>&1
}
check_fail "TC-APG05: non-protected plan dir touched → guard finds no match (phase passes)" tc_apg05

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
