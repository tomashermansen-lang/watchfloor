#!/bin/bash
# test_claude_session_lib.sh — TDD test suite for claude/tools/lib/claude-session-lib.sh
#
# Uses the check() assertion pattern from tests/smoke.sh.
# Each test sources the library in a controlled environment.
#
# Usage: bash tests/test_claude_session_lib.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"
FIXTURES="$REPO_DIR/tests/fixtures/claude-session-lib"

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

# --- Shared helpers ---

TEST_DIR="${TMPDIR:-/tmp}/test-claude-session-lib-$$"

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}
trap teardown EXIT

echo "Running claude-session-lib tests..."
echo ""

# =============================================================================
# T01: Source safety — no side effects (AS2, R2)
# =============================================================================
test_t01() {
    setup
    local before_files after_files
    before_files=$(ls -la "$TEST_DIR" | wc -l)

    # Source in a subshell with no globals set
    local result
    result=$(bash -c "
        source '$LIB'
        type -t dashboard_event
    " 2>&1) || { echo "  Source failed"; return 1; }

    after_files=$(ls -la "$TEST_DIR" | wc -l)
    [[ "$before_files" == "$after_files" ]] || { echo "  Files created in TEST_DIR"; return 1; }
    echo "$result" | grep -q "function" || { echo "  dashboard_event not defined as function"; return 1; }
    return 0
}
check "T01: Source safety — no side effects" test_t01

# =============================================================================
# T02: All 8 functions defined (R1)
# =============================================================================
test_t02() {
    local result
    result=$(bash -c "
        source '$LIB'
        for fn in dashboard_event process_stream run_phase run_gated_phase phase_header check_artifact commit_phase track_phase; do
            echo \"\$fn:\$(type -t \$fn)\"
        done
    " 2>&1) || { echo "  Source failed"; return 1; }

    for fn in dashboard_event process_stream run_phase run_gated_phase phase_header check_artifact commit_phase track_phase; do
        echo "$result" | grep -q "$fn:function" || { echo "  $fn not defined"; return 1; }
    done
    return 0
}
check "T02: All 8 functions defined" test_t02

# =============================================================================
# T03: Color constants — defaults applied (R6)
# =============================================================================
test_t03() {
    local result
    result=$(bash -c "
        source '$LIB'
        echo \"RED=\$RED\"
        echo \"GREEN=\$GREEN\"
        echo \"CYAN=\$CYAN\"
        echo \"YELLOW=\$YELLOW\"
        echo \"BOLD=\$BOLD\"
        echo \"NC=\$NC\"
    " 2>&1) || { echo "  Source failed"; return 1; }

    for var in RED GREEN CYAN YELLOW BOLD NC; do
        echo "$result" | grep "^${var}=" | grep -q "=" || { echo "  $var not set"; return 1; }
        local val
        val=$(echo "$result" | grep "^${var}=" | sed "s/^${var}=//")
        [[ -n "$val" ]] || { echo "  $var is empty"; return 1; }
    done
    return 0
}
check "T03: Color constants — defaults applied" test_t03

# =============================================================================
# T04: Color constants — caller preserved (E3, R6)
# =============================================================================
test_t04() {
    local result
    result=$(bash -c "
        RED='custom-red'
        source '$LIB'
        echo \"\$RED\"
    " 2>&1) || { echo "  Source failed"; return 1; }

    [[ "$result" == "custom-red" ]] || { echo "  RED was overwritten: got '$result'"; return 1; }
    return 0
}
check "T04: Color constants — caller preserved" test_t04

# =============================================================================
# T05: Header comment documents contract (R3)
# =============================================================================
test_t05() {
    grep -q 'AUTOPILOT_SID' "$LIB" || { echo "  AUTOPILOT_SID not documented"; return 1; }
    grep -q 'STREAM_FILE' "$LIB" || { echo "  STREAM_FILE not documented"; return 1; }
    grep -q 'DASHBOARD_DATA' "$LIB" || { echo "  DASHBOARD_DATA not documented"; return 1; }
    grep -q 'PHASE_TIMEOUT' "$LIB" || { echo "  PHASE_TIMEOUT not documented"; return 1; }
    grep -q 'log' "$LIB" || { echo "  log not documented"; return 1; }
    grep -q 'fail_pipeline' "$LIB" || { echo "  fail_pipeline not documented"; return 1; }
    return 0
}
check "T05: Header comment documents contract" test_t05

# =============================================================================
# T06: process_stream — fixture golden-file (AS3)
# =============================================================================
test_t06() {
    setup
    local output
    output=$(bash -c "
        source '$LIB'
        cat '$FIXTURES/stream-json-sample.ndjson' | process_stream
    " 2>&1) || true  # process_stream may exit 0 via || true

    echo "$output" > "$TEST_DIR/actual.txt"
    diff -u "$FIXTURES/stream-json-expected.txt" "$TEST_DIR/actual.txt" || { echo "  Output differs from golden file"; return 1; }
    return 0
}
check "T06: process_stream — fixture golden-file" test_t06

# =============================================================================
# T07: process_stream — malformed JSON skipped (E2)
# =============================================================================
test_t07() {
    setup
    local output exit_code
    output=$(bash -c "
        source '$LIB'
        cat '$FIXTURES/stream-json-malformed.ndjson' | process_stream
    " 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Non-zero exit: $exit_code"; return 1; }
    echo "$output" | grep -q "Valid line after malformed" || { echo "  Valid line not in output"; return 1; }
    return 0
}
check "T07: process_stream — malformed JSON skipped" test_t07

# =============================================================================
# T08: process_stream — empty input (—)
# =============================================================================
test_t08() {
    local output exit_code
    output=$(bash -c "
        source '$LIB'
        echo '' | process_stream
    " 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Non-zero exit: $exit_code"; return 1; }
    # Output should be empty (only whitespace at most)
    local trimmed
    trimmed=$(echo "$output" | tr -d '[:space:]')
    [[ -z "$trimmed" ]] || { echo "  Expected empty output, got: '$output'"; return 1; }
    return 0
}
check "T08: process_stream — empty input" test_t08

# =============================================================================
# T09: dashboard_event — JSON output (AS4)
# =============================================================================
test_t09() {
    setup
    local dashboard_file="$TEST_DIR/dashboard.jsonl"

    bash -c "
        source '$LIB'
        AUTOPILOT_SID='test-sid'
        DASHBOARD_DATA='$dashboard_file'
        dashboard_event 'TestEvent' 'TestPhase' 'test message'
    " 2>&1 || { echo "  dashboard_event failed"; return 1; }

    [[ -f "$dashboard_file" ]] || { echo "  Dashboard file not created"; return 1; }
    local line
    line=$(cat "$dashboard_file")

    # Verify JSON fields using python3
    python3 -c "
import json, sys
data = json.loads('''$line''')
for field in ['sid', 'event', 'type', 'msg', 'ts', 'atype']:
    assert field in data, f'Missing field: {field}'
assert data['sid'] == 'test-sid', f'Wrong sid: {data[\"sid\"]}'
assert data['event'] == 'TestEvent', f'Wrong event: {data[\"event\"]}'
" || { echo "  JSON validation failed"; return 1; }
    return 0
}
check "T09: dashboard_event — JSON output" test_t09

# =============================================================================
# T10: dashboard_event — missing DASHBOARD_DATA (silent failure)
# =============================================================================
test_t10() {
    local exit_code
    bash -c "
        source '$LIB'
        AUTOPILOT_SID='test-sid'
        DASHBOARD_DATA='/nonexistent/path/dashboard.jsonl'
        dashboard_event 'TestEvent' 'TestPhase' 'test message'
    " 2>&1 && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; return 1; }
    return 0
}
check "T10: dashboard_event — missing DASHBOARD_DATA (silent failure)" test_t10

# =============================================================================
# T11: phase_header — outputs banner (R1)
# =============================================================================
test_t11() {
    local output
    output=$(bash -c "
        source '$LIB'
        phase_header 'TestPhase'
    " 2>&1) || { echo "  phase_header failed"; return 1; }

    echo "$output" | grep -q "Phase: TestPhase" || { echo "  Banner missing 'Phase: TestPhase'"; return 1; }
    return 0
}
check "T11: phase_header — outputs banner" test_t11

# =============================================================================
# T12: phase_header — uses color constants (R1, R6)
# =============================================================================
test_t12() {
    local output
    output=$(bash -c "
        source '$LIB'
        phase_header 'TestPhase'
    " 2>&1) || { echo "  phase_header failed"; return 1; }

    # Check for ANSI escape sequences (ESC[) — use printf for portability (macOS grep lacks -P)
    echo "$output" | grep -q "$(printf '\033')\[" || { echo "  No ANSI escape sequences in output"; return 1; }
    return 0
}
check "T12: phase_header — uses color constants" test_t12

# =============================================================================
# T13: check_artifact — file exists (R1)
# =============================================================================
test_t13() {
    setup
    touch "$TEST_DIR/artifact.txt"

    local exit_code
    bash -c "
        source '$LIB'
        log() { true; }
        check_artifact '$TEST_DIR/artifact.txt' 'TestPhase'
    " 2>&1 && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; return 1; }
    return 0
}
check "T13: check_artifact — file exists" test_t13

# =============================================================================
# T14: check_artifact — file missing (R1)
# =============================================================================
test_t14() {
    local exit_code
    bash -c "
        source '$LIB'
        log() { true; }
        check_artifact '/nonexistent/file.txt' 'TestPhase'
    " 2>&1 && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    return 0
}
check "T14: check_artifact — file missing" test_t14

# =============================================================================
# T15: commit_phase — no changes to commit (R1)
# =============================================================================
test_t15() {
    setup
    local repo_dir="$TEST_DIR/repo"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    # Create initial commit
    echo "init" > README.md
    git add README.md
    git commit -q -m "init"
    local count_before
    count_before=$(git rev-list --count HEAD)

    bash -c "
        source '$LIB'
        commit_phase 'test' '$repo_dir' 'feat'
    " 2>&1 || true

    cd "$repo_dir"
    local count_after
    count_after=$(git rev-list --count HEAD)
    [[ "$count_before" == "$count_after" ]] || { echo "  Commit created when none expected"; return 1; }
    cd "$REPO_DIR"
    return 0
}
check "T15: commit_phase — no changes to commit" test_t15

# =============================================================================
# T16: commit_phase — commits feature dir changes (R1)
# =============================================================================
test_t16() {
    setup
    local repo_dir="$TEST_DIR/repo"
    mkdir -p "$repo_dir/docs/INPROGRESS_Feature_feat"
    cd "$repo_dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -q -m "init"

    echo "artifact" > "docs/INPROGRESS_Feature_feat/PLAN.md"
    git add "docs/INPROGRESS_Feature_feat/PLAN.md"

    bash -c "
        source '$LIB'
        log() { true; }
        commit_phase 'test phase' '$repo_dir' 'feat'
    " 2>&1 || true

    cd "$repo_dir"
    local last_msg
    last_msg=$(git log -1 --format=%s)
    echo "$last_msg" | grep -q "docs(feat): test phase" || { echo "  Wrong commit message: $last_msg"; return 1; }
    cd "$REPO_DIR"
    return 0
}
check "T16: commit_phase — commits feature dir changes" test_t16

# =============================================================================
# T17: track_phase — appends to arrays (R1, E4)
# =============================================================================
test_t17() {
    setup
    # Create a minimal STREAM_FILE with no result event
    echo '{"type":"orchestrator"}' > "$TEST_DIR/stream.ndjson"

    local result
    result=$(bash -c "
        source '$LIB'
        STREAM_FILE='$TEST_DIR/stream.ndjson'
        track_phase 'Test' 'done' '10' 'null'
        echo \"name=\${PHASE_NAMES[0]}\"
        echo \"status=\${PHASE_STATUSES[0]}\"
        echo \"duration=\${PHASE_DURATIONS[0]}\"
        echo \"artifact=\${PHASE_ARTIFACTS[0]}\"
    " 2>&1) || { echo "  track_phase failed"; return 1; }

    echo "$result" | grep -q "name=Test" || { echo "  PHASE_NAMES[0] wrong"; echo "$result"; return 1; }
    echo "$result" | grep -q "status=done" || { echo "  PHASE_STATUSES[0] wrong"; echo "$result"; return 1; }
    echo "$result" | grep -q "duration=10" || { echo "  PHASE_DURATIONS[0] wrong"; echo "$result"; return 1; }
    echo "$result" | grep -q "artifact=null" || { echo "  PHASE_ARTIFACTS[0] wrong"; echo "$result"; return 1; }
    return 0
}
check "T17: track_phase — appends to arrays" test_t17

# =============================================================================
# T18: track_phase — reads STREAM_FILE cost (R1)
# =============================================================================
test_t18() {
    setup
    echo '{"type":"result","total_cost_usd":1.23}' > "$TEST_DIR/stream.ndjson"

    local result
    result=$(bash -c "
        source '$LIB'
        STREAM_FILE='$TEST_DIR/stream.ndjson'
        track_phase 'Test' 'done' '10' 'null'
        echo \"cost=\${PHASE_COSTS[0]}\"
    " 2>&1) || { echo "  track_phase failed"; return 1; }

    echo "$result" | grep -q "cost=1.23" || { echo "  PHASE_COSTS[0] wrong"; echo "$result"; return 1; }
    return 0
}
check "T18: track_phase — reads STREAM_FILE cost" test_t18

# =============================================================================
# T19: track_phase — missing STREAM_FILE defaults to 0 (E1)
# =============================================================================
test_t19() {
    local result
    result=$(bash -c "
        source '$LIB'
        STREAM_FILE='/nonexistent/stream.ndjson'
        track_phase 'Test' 'done' '10' 'null'
        echo \"cost=\${PHASE_COSTS[0]}\"
    " 2>&1) || { echo "  track_phase failed"; return 1; }

    echo "$result" | grep -q "cost=0" || { echo "  PHASE_COSTS[0] should be 0"; echo "$result"; return 1; }
    return 0
}
check "T19: track_phase — missing STREAM_FILE defaults to 0" test_t19

# =============================================================================
# T20: autopilot.sh sources library (R5)
# =============================================================================
test_t20() {
    grep -q 'source.*claude-session-lib.sh' "$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh" || { echo "  Source line not found"; return 1; }
    return 0
}
check "T20: autopilot.sh sources library" test_t20

# =============================================================================
# T21: Functions removed from autopilot.sh (R5)
# =============================================================================
test_t21() {
    for fn in phase_header dashboard_event check_artifact run_gated_phase process_stream run_phase commit_phase track_phase; do
        # Check for function definition (not calls)
        if grep -qE "^${fn}\(\)|^function ${fn}" "$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh"; then
            echo "  $fn still defined inline in autopilot.sh"
            return 1
        fi
    done
    return 0
}
check "T21: Functions removed from autopilot.sh" test_t21

# =============================================================================
# T22: Color constants removed from autopilot.sh (R5)
# =============================================================================
test_t22() {
    # Check that RED=, GREEN=, etc. are not defined at the top of autopilot.sh
    # (they should come from the library now)
    # We check for bare definitions like RED='\033... not ${RED:= patterns
    if grep -qE "^RED=|^GREEN=|^CYAN=|^YELLOW=|^BOLD=|^NC=" "$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh"; then
        echo "  Color constants still defined in autopilot.sh"
        return 1
    fi
    return 0
}
check "T22: Color constants removed from autopilot.sh" test_t22

# =============================================================================
# T23: Source path uses BASH_SOURCE pattern (R5)
# =============================================================================
test_t23() {
    grep -q 'AUTOPILOT_DIR.*lib/claude-session-lib.sh' "$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh" || { echo "  Source path not using AUTOPILOT_DIR"; return 1; }
    return 0
}
check "T23: Source path uses AUTOPILOT_DIR pattern" test_t23

# =============================================================================
# T24: smoke.sh includes new test (C5)
# =============================================================================
test_t24() {
    grep -q 'test_claude_session_lib' "$REPO_DIR/tests/smoke.sh" || { echo "  test_claude_session_lib not in smoke.sh"; return 1; }
    return 0
}
check "T24: smoke.sh includes new test" test_t24

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
