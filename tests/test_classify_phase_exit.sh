#!/bin/bash
# test_classify_phase_exit.sh — TDD for the wrapper-timeout exit-code classifier.
#
# Background: when the agent emits its final {"type":"result"} event but the
# claude process hangs (upstream issue anthropics/claude-code#25629 — JVM/python
# grandchildren inherit claude's stdout fd), one of two timers fires at
# PHASE_TIMEOUT seconds:
#
#   - the watchdog SIGTERM   → pipeline exits 143
#   - gtimeout PHASE_TIMEOUT → pipeline exits 124
#   - escalated SIGKILL      → pipeline exits 137
#
# All three are wrapper-level timeouts. If the agent's result event reached
# phase_ndjson, the phase is functionally complete — the kill merely cleaned
# up dead-but-still-running grandchildren. The classifier MUST return 0 so
# run_gated_phase does NOT redundantly re-invoke the agent (observed waste:
# ~$0.61 + 160s per chain run — see CONTINUATION_chain-pipeline-friction.md
# section A).
#
# Before this fix, run_phase only converted exit_code 143 → 0. Static-analysis
# is the worst offender because sonar-scanner spawns a JVM that holds the
# stdout fd longer than the watchdog's grace period, so gtimeout often wins
# the race → exit_code=124 → the result-event branch was skipped → run_gated_phase
# retried.
#
# Usage: bash tests/test_classify_phase_exit.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

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

TEST_DIR="${TMPDIR:-/tmp}/test-classify-phase-exit-$$"

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}
trap teardown EXIT

# Run the classifier in a subshell so each test gets a clean library load.
classify() {
    local input_exit=$1 ndjson=$2
    bash -c "
        source '$LIB'
        _classify_phase_exit '$input_exit' '$ndjson'
    "
}

echo "Running _classify_phase_exit tests..."
echo ""

# =============================================================================
# T01: function is defined
# =============================================================================
test_t01() {
    local result
    result=$(bash -c "source '$LIB'; type -t _classify_phase_exit" 2>&1) || {
        echo "  source failed: $result"
        return 1
    }
    [[ "$result" == "function" ]] || {
        echo "  _classify_phase_exit not a function: $result"
        return 1
    }
}
check "T01: _classify_phase_exit is defined" test_t01

# =============================================================================
# T02: clean success — exit_code 0 passes through unchanged
# =============================================================================
test_t02() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    : > "$ndjson"
    local out
    out=$(classify 0 "$ndjson")
    [[ "$out" == "0" ]] || { echo "  expected 0 got $out"; return 1; }
}
check "T02: exit_code=0 passes through (clean success)" test_t02

# =============================================================================
# T03: real error (exit_code 1) passes through unchanged
# =============================================================================
test_t03() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    printf '{"type":"result","subtype":"error_max_turns"}\n' > "$ndjson"
    local out
    out=$(classify 1 "$ndjson")
    [[ "$out" == "1" ]] || { echo "  expected 1 got $out (must NOT mask real failures)"; return 1; }
}
check "T03: exit_code=1 passes through (real failure not masked)" test_t03

# =============================================================================
# T04: SIGTERM (143) + result event present → 0 (watchdog killed AFTER agent finished)
# =============================================================================
test_t04() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    printf '{"type":"assistant"}\n{"type":"result","subtype":"success"}\n' > "$ndjson"
    local out
    out=$(classify 143 "$ndjson")
    [[ "$out" == "0" ]] || { echo "  expected 0 got $out (watchdog cleanup of finished agent)"; return 1; }
}
check "T04: 143 + result event → 0 (watchdog SIGTERM after success)" test_t04

# =============================================================================
# T05: SIGTERM (143) + no result event → 124 (real watchdog absolute timeout)
# =============================================================================
test_t05() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    : > "$ndjson"
    local out
    out=$(classify 143 "$ndjson")
    [[ "$out" == "124" ]] || { echo "  expected 124 got $out (real timeout, surface as gtimeout-style)"; return 1; }
}
check "T05: 143 + no result → 124 (real watchdog absolute timeout)" test_t05

# =============================================================================
# T06: gtimeout (124) + result event present → 0 ← THE BUG FIX
# =============================================================================
# This is the case observed in DONE_Feature_plans-filter-ui (2026-05-06):
# agent finished at T=768s, sonar-scanner JVM child held stdout fd, gtimeout
# fired at 1800s with exit_code=124. The result event was in phase_ndjson.
# Before the fix, run_phase returned 1 → run_gated_phase retried wastefully.
test_t06() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    printf '{"type":"assistant"}\n{"type":"result","subtype":"success","num_turns":63}\n' > "$ndjson"
    local out
    out=$(classify 124 "$ndjson")
    [[ "$out" == "0" ]] || { echo "  expected 0 got $out (gtimeout cleanup of finished agent — was the bug)"; return 1; }
}
check "T06: 124 + result event → 0 (gtimeout cleanup of finished agent — BUG FIX)" test_t06

# =============================================================================
# T07: gtimeout (124) + no result event → 124 (real timeout, agent never finished)
# =============================================================================
test_t07() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    printf '{"type":"assistant"}\n' > "$ndjson"  # tool calls but no final result
    local out
    out=$(classify 124 "$ndjson")
    [[ "$out" == "124" ]] || { echo "  expected 124 got $out (real timeout preserved)"; return 1; }
}
check "T07: 124 + no result → 124 (real timeout, no false success)" test_t07

# =============================================================================
# T08: SIGKILL (137) + result event present → 0 (gtimeout escalated SIGKILL after grace)
# =============================================================================
test_t08() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    printf '{"type":"result","subtype":"success"}\n' > "$ndjson"
    local out
    out=$(classify 137 "$ndjson")
    [[ "$out" == "0" ]] || { echo "  expected 0 got $out (SIGKILL cleanup of finished agent)"; return 1; }
}
check "T08: 137 + result event → 0 (SIGKILL cleanup of finished agent)" test_t08

# =============================================================================
# T09: SIGKILL (137) + no result event → 124 (real timeout escalated to SIGKILL)
# =============================================================================
test_t09() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    : > "$ndjson"
    local out
    out=$(classify 137 "$ndjson")
    [[ "$out" == "124" ]] || { echo "  expected 124 got $out (real timeout)"; return 1; }
}
check "T09: 137 + no result → 124 (real timeout, no false success)" test_t09

# =============================================================================
# T10: missing phase_ndjson file → behaves as no result event
# =============================================================================
test_t10() {
    setup
    local ndjson="$TEST_DIR/never-created.ndjson"
    local out
    out=$(classify 124 "$ndjson")
    [[ "$out" == "124" ]] || { echo "  expected 124 got $out (missing file → real timeout)"; return 1; }
}
check "T10: missing ndjson file → 124 (does not crash, treats as no result)" test_t10

# =============================================================================
# T11: arbitrary non-zero exit (e.g., claude crash 2) passes through unchanged
# =============================================================================
test_t11() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    printf '{"type":"result","subtype":"success"}\n' > "$ndjson"
    local out
    out=$(classify 2 "$ndjson")
    [[ "$out" == "2" ]] || { echo "  expected 2 got $out (only timeout-shaped codes get reclassified)"; return 1; }
}
check "T11: exit=2 passes through even with result event (only 124/143/137 reclassify)" test_t11

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
