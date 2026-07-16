#!/bin/bash
# test_phase_selector.sh — TDD test suite for claude/tools/lib/phase-selector.sh
#
# Provides --from flag logic for autopilot.sh: decides which pipeline phases
# to run based on a starting phase name.
#
# Usage: bash tests/test_phase_selector.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/phase-selector.sh"

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

[[ -f "$LIB" ]] || { echo "FATAL: $LIB not found"; exit 1; }

# ── T01: PHASE_ORDER is defined and non-empty ────────────────
test_t01() {
    (
        source "$LIB"
        [[ ${#PHASE_ORDER[@]} -gt 0 ]]
    )
}
check "T01: PHASE_ORDER array is defined and non-empty" test_t01

# ── T02: PHASE_ORDER contains the canonical pipeline phases ──
test_t02() {
    (
        source "$LIB"
        local expected=(ba plan testplan review implement qa static-analysis commit)
        [[ "${PHASE_ORDER[*]}" == "${expected[*]}" ]]
    )
}
check "T02: PHASE_ORDER matches canonical phase list" test_t02

# ── T03: validate_phase_name accepts valid phase ──────────────
test_t03() {
    (
        source "$LIB"
        validate_phase_name "static-analysis" >/dev/null 2>&1
    )
}
check "T03: validate_phase_name accepts 'static-analysis'" test_t03

# ── T04: validate_phase_name rejects unknown phase ────────────
test_t04() {
    (
        source "$LIB"
        ! validate_phase_name "bogus-phase" >/dev/null 2>&1
    )
}
check "T04: validate_phase_name rejects 'bogus-phase'" test_t04

# ── T05: phase_enabled returns 0 for all phases when START_FROM empty ─
test_t05() {
    (
        source "$LIB"
        START_FROM=""
        phase_enabled "ba" && phase_enabled "commit"
    )
}
check "T05: phase_enabled always true when START_FROM empty" test_t05

# ── T06: phase_enabled skips phases before START_FROM ─────────
test_t06() {
    (
        source "$LIB"
        START_FROM="static-analysis"
        ! phase_enabled "ba" && \
        ! phase_enabled "plan" && \
        ! phase_enabled "review" && \
        ! phase_enabled "testplan" && \
        ! phase_enabled "implement"
    )
}
check "T06: phase_enabled false for phases before START_FROM" test_t06

# ── T07: phase_enabled allows START_FROM and later ────────────
test_t07() {
    (
        source "$LIB"
        START_FROM="static-analysis"
        phase_enabled "static-analysis" && \
        ! phase_enabled "qa" && \
        phase_enabled "commit"
    )
}
check "T07: phase_enabled true for START_FROM phase and later" test_t07

# ── T08: phase_enabled handles first phase (ba) correctly ─────
test_t08() {
    (
        source "$LIB"
        START_FROM="ba"
        phase_enabled "ba" && phase_enabled "commit"
    )
}
check "T08: START_FROM=ba runs everything" test_t08

# ── T09: phase_enabled handles last phase (commit) correctly ──
test_t09() {
    (
        source "$LIB"
        START_FROM="commit"
        ! phase_enabled "ba" && \
        ! phase_enabled "qa" && \
        phase_enabled "commit"
    )
}
check "T09: START_FROM=commit skips everything except commit" test_t09

# ── T10: phase_enabled with unknown phase_name returns false ──
test_t10() {
    (
        source "$LIB"
        START_FROM=""
        ! phase_enabled "nonexistent"
    )
}
check "T10: phase_enabled returns false for unknown phase_name" test_t10

# ── T11: skipped_phases lists phases before START_FROM ────────
test_t11() {
    (
        source "$LIB"
        START_FROM="static-analysis"
        local skipped
        skipped=$(skipped_phases)
        [[ "$skipped" == "ba plan testplan review implement qa" ]]
    )
}
check "T11: skipped_phases prints phases before START_FROM" test_t11

# ── T12: skipped_phases empty when START_FROM empty ───────────
test_t12() {
    (
        source "$LIB"
        START_FROM=""
        local skipped
        skipped=$(skipped_phases)
        [[ -z "$skipped" ]]
    )
}
check "T12: skipped_phases empty when no --from flag" test_t12

# ── T13: should_stop_after_phase returns 0 when STOP_AFTER_PHASE matches ──
test_t13() {
    (
        source "$LIB"
        STOP_AFTER_PHASE="ba"
        should_stop_after_phase "ba"
    )
}
check "T13: should_stop_after_phase true when STOP_AFTER_PHASE equals phase" test_t13

# ── T14: should_stop_after_phase returns 1 when phase doesn't match ────────
test_t14() {
    (
        source "$LIB"
        STOP_AFTER_PHASE="ba"
        ! should_stop_after_phase "plan"
    )
}
check "T14: should_stop_after_phase false for non-matching phase" test_t14

# ── T15: should_stop_after_phase returns 1 when STOP_AFTER_PHASE is empty ──
test_t15() {
    (
        source "$LIB"
        STOP_AFTER_PHASE=""
        ! should_stop_after_phase "ba"
    )
}
check "T15: should_stop_after_phase false when STOP_AFTER_PHASE empty" test_t15

# ── T16: should_stop_after_phase set -u safe (STOP_AFTER_PHASE unset) ──────
test_t16() {
    (
        set -u
        source "$LIB"
        unset STOP_AFTER_PHASE 2>/dev/null || true
        ! should_stop_after_phase "ba" 2>/dev/null
    )
}
check "T16: should_stop_after_phase set -u safe when var unset" test_t16

# ── T17: phase_index returns 0 for 'ba' ────────────────────────────────────
test_t17() {
    (
        source "$LIB"
        local idx
        idx=$(phase_index "ba")
        [[ "$idx" == "0" ]]
    )
}
check "T17: phase_index ba == 0" test_t17

# ── T18: phase_index returns 7 for 'commit' (last) ─────────────────────────
test_t18() {
    (
        source "$LIB"
        local idx
        idx=$(phase_index "commit")
        [[ "$idx" == "7" ]]
    )
}
check "T18: phase_index commit == 7" test_t18

# ── T19: phase_index returns 6 for 'static-analysis' ───────────────────────
test_t19() {
    (
        source "$LIB"
        local idx
        idx=$(phase_index "static-analysis")
        [[ "$idx" == "6" ]]
    )
}
check "T19: phase_index static-analysis == 6" test_t19

# ── T20: phase_index empty + exit 1 for unknown phase ──────────────────────
test_t20() {
    (
        source "$LIB"
        local idx rc
        idx=$(phase_index "foobar" 2>/dev/null) && rc=$? || rc=$?
        [[ "$rc" -ne 0 && -z "$idx" ]]
    )
}
check "T20: phase_index returns empty + non-zero for unknown phase" test_t20

# ── T21: phase_index for every PHASE_ORDER member matches array offset ────
test_t21() {
    (
        source "$LIB"
        local i p actual
        for i in "${!PHASE_ORDER[@]}"; do
            p="${PHASE_ORDER[$i]}"
            actual=$(phase_index "$p")
            [[ "$actual" == "$i" ]] || return 1
        done
    )
}
check "T21: phase_index round-trips every PHASE_ORDER member" test_t21

# ── T22: phase_index testplan == 2 (used by --from/--stop composition) ────
test_t22() {
    (
        source "$LIB"
        local idx
        idx=$(phase_index "testplan")
        [[ "$idx" == "2" ]]
    )
}
check "T22: phase_index testplan == 2" test_t22

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
