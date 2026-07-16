#!/bin/bash
# test_run_phase_watchdog.sh — TDD for the result-event watchdog in run_phase.
#
# Background: claude -p sometimes hangs after emitting its final
# {"type":"result","subtype":"success"} event. Subprocess grandchildren (e.g.,
# sonar-scanner JVM) inherit claude's stdout fd; the pipeline's reader never
# sees EOF; gtimeout fires at PHASE_TIMEOUT (1800s) wasting ~20-30 minutes per
# false hang. See anthropics/claude-code#25629.
#
# Workaround: spawn a sidecar that watches the phase NDJSON file for a result
# event, then group-kills the claude process (PID == PGID via setsid) after a
# short grace period.
#
# These tests verify the watchdog primitive (spawn_result_watchdog) in
# isolation. Integration with run_phase is not exercised here — that requires
# a real claude binary or a heavy mock.
#
# Usage: bash tests/test_run_phase_watchdog.sh

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

TEST_DIR="${TMPDIR:-/tmp}/test-run-phase-watchdog-$$"

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
}

teardown() {
    # Kill any leftover background processes from failed tests
    pkill -P $$ 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap teardown EXIT

echo "Running run_phase watchdog tests..."
echo ""

# =============================================================================
# T01: spawn_result_watchdog is defined and exported
# =============================================================================
test_t01() {
    local result
    result=$(bash -c "
        source '$LIB'
        type -t spawn_result_watchdog
    " 2>&1) || { echo "  Source failed"; return 1; }

    [[ "$result" == "function" ]] || { echo "  spawn_result_watchdog not a function: $result"; return 1; }
    return 0
}
check "T01: spawn_result_watchdog is defined" test_t01

# =============================================================================
# T02: setsid_exec helper is defined (Python wrapper for macOS)
# =============================================================================
test_t02() {
    grep -q "_setsid_exec_python\|os.setsid" "$LIB" || {
        echo "  No setsid wrapper in library"
        return 1
    }
    return 0
}
check "T02: setsid wrapper exists in library" test_t02

# =============================================================================
# T03: Watchdog fires on result event, kills the target PID's group
# =============================================================================
test_t03() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    : > "$ndjson"

    # Spawn a fake "claude" that:
    #  1. setsid (own process group)
    #  2. writes its PID to pid_file
    #  3. spawns a "child" (mimics sonar-scanner) that just sleeps
    #  4. emits a result event to ndjson
    #  5. sleeps 60s (the hang)
    python3 -c "
import os, sys, time
os.setsid()
with open('$pid_file','w') as f: f.write(str(os.getpid()))
# Fork a child that sleeps — mimics a JVM grandchild
if os.fork() == 0:
    time.sleep(120)
    sys.exit(0)
# Emit result event
with open('$ndjson','a') as f:
    f.write('{\"type\":\"assistant\"}\n')
    f.write('{\"type\":\"result\",\"subtype\":\"success\"}\n')
    f.flush()
# Hang
time.sleep(120)
" &
    local fake_pid=$!

    # Wait for pid_file
    local _i
    for _i in $(seq 1 50); do
        [[ -s "$pid_file" ]] && break
        sleep 0.1
    done
    [[ -s "$pid_file" ]] || { echo "  fake claude never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    # Spawn watchdog with short inactivity window
    local watch_pid
    watch_pid=$(bash -c "
        source '$LIB'
        EAGER_EXIT_IDLE_S=1
        spawn_result_watchdog '$ndjson' '$pid_file'
    ")
    [[ -n "$watch_pid" ]] || { echo "  spawn_result_watchdog returned empty"; kill "$fake_pid" 2>/dev/null; return 1; }

    # Wait up to 15 seconds for fake claude to die (group-killed by watchdog)
    local elapsed=0
    while kill -0 "$fake_pid" 2>/dev/null && [[ $elapsed -lt 15 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if kill -0 "$fake_pid" 2>/dev/null; then
        echo "  fake claude (pid $fake_pid) still alive after $elapsed seconds"
        kill -KILL -- "-$fake_pid" 2>/dev/null
        return 1
    fi

    # Cleanup
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
    return 0
}
check "T03: Watchdog group-kills target after result event + grace" test_t03

# =============================================================================
# T04: Watchdog respects EAGER_EXIT_IDLE_S — does NOT kill before window expires
# =============================================================================
test_t04() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    : > "$ndjson"

    # Fake claude that writes result, then exits cleanly within 1s
    python3 -c "
import os, time
os.setsid()
with open('$pid_file','w') as f: f.write(str(os.getpid()))
with open('$ndjson','a') as f:
    f.write('{\"type\":\"result\",\"subtype\":\"success\"}\n')
    f.flush()
time.sleep(1)  # exit cleanly
" &
    local fake_pid=$!

    # Spawn watchdog with idle window=10s (longer than fake's clean exit time)
    local watch_pid
    watch_pid=$(bash -c "
        source '$LIB'
        EAGER_EXIT_IDLE_S=10
        spawn_result_watchdog '$ndjson' '$pid_file'
    ")

    # Wait for fake claude to exit (should be ~1s, well under idle window)
    wait "$fake_pid" 2>/dev/null
    local exit_code=$?

    # Fake exited cleanly (exit 0). Watchdog should detect this and NOT fire SIGTERM.
    [[ $exit_code -eq 0 ]] || { echo "  fake claude exited non-zero: $exit_code"; return 1; }

    # Cleanup watchdog — give it a moment, then ensure it terminates
    sleep 12  # > idle window
    if kill -0 "$watch_pid" 2>/dev/null; then
        # Watchdog still alive — should have exited after seeing kill -0 fail
        kill "$watch_pid" 2>/dev/null
        wait "$watch_pid" 2>/dev/null || true
    fi
    return 0
}
check "T04: Watchdog skips kill if process already exited cleanly" test_t04

# =============================================================================
# T06: Absolute-timeout fallback — watchdog kills even without a result event
# =============================================================================
test_t06() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    : > "$ndjson"

    # Fake claude that NEVER emits a result event — just hangs.
    python3 -c "
import os, time
os.setsid()
with open('$pid_file','w') as f: f.write(str(os.getpid()))
# Hang without any output
time.sleep(120)
" &
    local fake_pid=$!

    # Wait for pid_file
    local _i
    for _i in $(seq 1 50); do
        [[ -s "$pid_file" ]] && break
        sleep 0.1
    done

    # Spawn watchdog with PHASE_TIMEOUT=3s — should fire absolute-timeout kill
    local watch_pid
    watch_pid=$(bash -c "
        source '$LIB'
        PHASE_TIMEOUT=3
        EAGER_EXIT_IDLE_S=99
        spawn_result_watchdog '$ndjson' '$pid_file'
    ")

    # Wait up to 15s for fake claude to die (should die at ~3s + 5s SIGKILL grace)
    local elapsed=0
    while kill -0 "$fake_pid" 2>/dev/null && [[ $elapsed -lt 15 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if kill -0 "$fake_pid" 2>/dev/null; then
        echo "  fake claude (pid $fake_pid) still alive after $elapsed seconds (PHASE_TIMEOUT=3)"
        kill -KILL -- "-$fake_pid" 2>/dev/null
        return 1
    fi

    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
    return 0
}
check "T06: Absolute-timeout fires watchdog kill without a result event" test_t06

# =============================================================================
# T05: Watchdog gives up if pid_file never appears
# =============================================================================
test_t05() {
    setup
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"  # never created
    : > "$ndjson"

    local watch_pid
    watch_pid=$(bash -c "
        source '$LIB'
        EAGER_EXIT_IDLE_S=1
        spawn_result_watchdog '$ndjson' '$pid_file'
    ")

    # Watchdog should exit on its own within ~15 seconds (pid file polling timeout)
    local elapsed=0
    while kill -0 "$watch_pid" 2>/dev/null && [[ $elapsed -lt 20 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if kill -0 "$watch_pid" 2>/dev/null; then
        echo "  watchdog still alive after $elapsed seconds (no pid_file)"
        kill "$watch_pid" 2>/dev/null
        return 1
    fi
    return 0
}
check "T05: Watchdog exits gracefully when pid_file never appears" test_t05

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
