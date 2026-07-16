#!/bin/bash
# test-eager-exit.sh — TDD for the end-turn-armed no-output watchdog.
#
# Verifies the eager-exit upgrade to spawn_result_watchdog in
# adapters/claude-code/claude/tools/lib/claude-session-lib.sh:
#
#   * The watchdog arms on the agent's `result` event and treats stream
#     mtime advance as legitimate post-result activity (REQ-1, REQ-2).
#   * SIGTERM fires after EAGER_EXIT_IDLE_S of mtime silence; SIGKILL
#     escalates after EAGER_EXIT_GRACE_S (REQ-3, REQ-4).
#   * One structured `{"type":"orchestrator","msg":"Eager-exit fired …"}`
#     NDJSON line lands in $STREAM_FILE BEFORE SIGTERM (REQ-5).
#   * EAGER_EXIT_DISABLE=1 / EAGER_EXIT_IDLE_S=0 short-circuit arming;
#     the absolute-timeout branch (PHASE_TIMEOUT) is preserved (REQ-9).
#   * Helper validators default invalid env values and warn once per
#     process per variable (REQ-6 edge case).
#   * _classify_phase_exit reclassifies 143/137/124 against the result
#     event (REQ-12).
#
# Wall-clock budget: < 60 s. Uses small EAGER_EXIT_IDLE_S=2 and
# EAGER_EXIT_GRACE_S=1 to keep timing assertions tight.
#
# Usage: bash tests/test-eager-exit.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"
RUN_ALL="$REPO_DIR/dashboard/tests/run-all.sh"

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

TEST_DIR="${TMPDIR:-/tmp}/test-eager-exit-$$"

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
}

teardown() {
    pkill -P $$ 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap teardown EXIT

# Write a single fake-claude shim to $TEST_DIR/fake.py. Behaviour is
# parameterised entirely by env vars so the same shim covers every
# integration case below.
#
#   FAKE_PID_FILE                  — path to write os.getpid() to.
#   FAKE_NDJSON                    — phase NDJSON path the fake appends to.
#   FAKE_TERM_LOG (optional)       — append "TERM\n" on SIGTERM (counts kills).
#   FAKE_IGNORE_SIGTERM (0|1)      — when 1, install SIG_IGN; do not exit on TERM.
#   FAKE_PRE_RESULT_SLEEP (s)      — delay between pid-file write and result line.
#   FAKE_POST_RESULT_SLEEP (s)     — sleep after final NDJSON write.
#   FAKE_POST_RESULT_WRITES        — semicolon-list "delay|json_line" pairs appended after result.
#   FAKE_FORK_GRANDCHILD_SLEEP (s) — when > 0, fork a grandchild that sleeps.
#   FAKE_GRANDCHILD_PID_FILE       — path to write the grandchild's PID to.
write_fake() {
    cat > "$TEST_DIR/fake.py" <<'PY'
import os, signal, sys, time

pid_file = os.environ["FAKE_PID_FILE"]
ndjson = os.environ["FAKE_NDJSON"]
term_log = os.environ.get("FAKE_TERM_LOG", "")
ignore_sigterm = os.environ.get("FAKE_IGNORE_SIGTERM", "0") == "1"
pre_result_sleep = float(os.environ.get("FAKE_PRE_RESULT_SLEEP", "0"))
post_result_sleep = float(os.environ.get("FAKE_POST_RESULT_SLEEP", "0"))
post_result_writes = os.environ.get("FAKE_POST_RESULT_WRITES", "")
fork_grandchild_sleep = float(os.environ.get("FAKE_FORK_GRANDCHILD_SLEEP", "0"))
gc_pid_file = os.environ.get("FAKE_GRANDCHILD_PID_FILE", "")

try:
    os.setsid()
except OSError:
    pass

if ignore_sigterm:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
elif term_log:
    def on_term(signum, frame):
        with open(term_log, "a") as f:
            f.write("TERM\n")
            f.flush()
        sys.exit(143)
    signal.signal(signal.SIGTERM, on_term)

with open(pid_file, "w") as f:
    f.write(str(os.getpid()))
    f.flush()

if fork_grandchild_sleep > 0:
    pid = os.fork()
    if pid == 0:
        time.sleep(fork_grandchild_sleep)
        sys.exit(0)
    if gc_pid_file:
        with open(gc_pid_file, "w") as f:
            f.write(str(pid))
            f.flush()

if pre_result_sleep > 0:
    time.sleep(pre_result_sleep)

with open(ndjson, "a") as f:
    f.write('{"type":"assistant"}\n')
    f.write('{"type":"result","subtype":"success"}\n')
    f.flush()

if post_result_writes:
    for spec in post_result_writes.split(";"):
        delay_str, msg = spec.split("|", 1)
        time.sleep(float(delay_str))
        with open(ndjson, "a") as f:
            f.write(msg + "\n")
            f.flush()

if post_result_sleep > 0:
    time.sleep(post_result_sleep)

sys.exit(0)
PY
}

wait_for_file() {
    local path="$1" max_iters="${2:-50}" _i
    for _i in $(seq 1 "$max_iters"); do
        [[ -s "$path" ]] && return 0
        sleep 0.1
    done
    return 1
}

# Spawn the watchdog under a fresh shell so its `( ... ) &` subshell is
# orphaned cleanly when the caller exits — matches the production call
# pattern in run_phase. Echoes the watchdog PID.
spawn_watchdog_under() {
    local ndjson="$1" pid_file="$2" stream_file="$3"
    local idle="${EAGER_EXIT_IDLE_S:-2}"
    local grace="${EAGER_EXIT_GRACE_S:-1}"
    local disable="${EAGER_EXIT_DISABLE:-}"
    local phase_timeout="${PHASE_TIMEOUT:-1800}"
    bash -c "
        export STREAM_FILE='$stream_file'
        export EAGER_EXIT_IDLE_S='$idle'
        export EAGER_EXIT_GRACE_S='$grace'
        export EAGER_EXIT_DISABLE='$disable'
        export PHASE_TIMEOUT='$phase_timeout'
        source '$LIB'
        spawn_result_watchdog '$ndjson' '$pid_file'
    "
}

echo "Running eager-exit watchdog tests..."
echo ""

# =============================================================================
# (a) Natural exit, no-op (REQ-7, AC-2)
# =============================================================================
test_a_natural_exit_no_op() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    local term_log="$TEST_DIR/term.log"
    : > "$ndjson"; : > "$stream_file"; : > "$term_log"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_SLEEP=0.5 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    wait "$fake_pid" 2>/dev/null
    local fake_exit=$?
    [[ $fake_exit -eq 0 ]] || { echo "  fake exited non-zero: $fake_exit"; return 1; }

    sleep 3  # let watchdog observe kill -0 fail and exit cleanly

    local term_count
    term_count=$(grep -c TERM "$term_log" || true)
    [[ "$term_count" -eq 0 ]] || { echo "  unexpected SIGTERM observations: $term_count"; return 1; }

    local orch_count
    orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 0 ]] || { echo "  orchestrator events on natural exit: $orch_count"; return 1; }
    return 0
}
check "(a) natural exit — no signal, no orchestrator event" test_a_natural_exit_no_op

# =============================================================================
# (b) Stalled-after-result, watchdog fires (REQ-1, REQ-3, REQ-4, REQ-5,
#     REQ-11 PG, REQ-13 timing, R6 Continue?)
# =============================================================================
test_b_stalled_after_result_fires() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    local term_log="$TEST_DIR/term.log"
    local gc_pid_file="$TEST_DIR/grandchild.pid"
    : > "$ndjson"; : > "$stream_file"; : > "$term_log"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_SLEEP=30 \
    FAKE_FORK_GRANDCHILD_SLEEP=120 \
    FAKE_GRANDCHILD_PID_FILE="$gc_pid_file" \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }
    wait_for_file "$gc_pid_file" || { echo "  grandchild PID never recorded"; kill -- -"$fake_pid" 2>/dev/null; return 1; }
    local gc_pid; gc_pid=$(cat "$gc_pid_file")

    local t0; t0=$(date +%s)
    EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    # Wait up to 8 s for the leader to die; that bounds T_idle (2) +
    # T_grace (1) + slack (5) per REQ-13.
    local elapsed=0
    while kill -0 "$fake_pid" 2>/dev/null && [[ $elapsed -lt 8 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$fake_pid" 2>/dev/null; then
        echo "  fake leader still alive after $elapsed s"
        kill -KILL -- "-$fake_pid" 2>/dev/null
        return 1
    fi

    local t1; t1=$(date +%s)
    local total=$((t1 - t0))
    [[ $total -le 8 ]] || { echo "  REQ-13: total wall-clock $total s > 8 s"; return 1; }

    # Grandchild must be reaped via PG kill (REQ-11).
    sleep 1
    if kill -0 "$gc_pid" 2>/dev/null; then
        echo "  grandchild $gc_pid survived PG kill"
        kill -KILL "$gc_pid" 2>/dev/null
        return 1
    fi

    local term_count; term_count=$(grep -c TERM "$term_log" || true)
    [[ "$term_count" -ge 1 ]] || { echo "  no SIGTERM observed in term log"; return 1; }

    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 1 ]] || { echo "  orchestrator events: $orch_count (want 1)"; return 1; }

    grep -Eq '"type":"orchestrator","msg":"Eager-exit fired after T_idle=2s, T_grace=1s","ts":"[^"]+Z"' "$stream_file" || {
        echo "  orchestrator line did not match REQ-5 schema: $(grep 'orchestrator' "$stream_file")"
        return 1
    }

    # R6: eager-exit fire must NOT introduce a Continue? checkpoint string.
    local cont_count; cont_count=$(grep -c 'Continue?' "$stream_file" || true)
    [[ "$cont_count" -eq 0 ]] || { echo "  unexpected Continue? in stream: $cont_count"; return 1; }
    return 0
}
check "(b) stalled-after-result — SIGTERM/SIGKILL + 1 orchestrator + PG reap" test_b_stalled_after_result_fires

# =============================================================================
# (c) Mtime advance resets the inactivity timer (REQ-2, AC-2)
# =============================================================================
test_c_mtime_advance_resets() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    local term_log="$TEST_DIR/term.log"
    : > "$ndjson"; : > "$stream_file"; : > "$term_log"

    # T_idle=2; fake writes a dummy NDJSON line at 0.8 s post-result, then
    # exits. The watchdog must reset and never fire. Margin: probe loop
    # samples mtime at most every 1 s; a 0.8 s write delay guarantees the
    # advance lands before the 2 s idle expires even under CI load (≥ 1 s
    # of slack between the mtime advance and the t_idle threshold).
    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_WRITES='0.8|{"type":"system","subtype":"task_updated"}' \
    FAKE_POST_RESULT_SLEEP=0.3 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    wait "$fake_pid" 2>/dev/null
    local fake_exit=$?
    [[ $fake_exit -eq 0 ]] || { echo "  fake exited non-zero: $fake_exit (mtime reset failed)"; return 1; }

    sleep 3

    local term_count; term_count=$(grep -c TERM "$term_log" || true)
    [[ "$term_count" -eq 0 ]] || { echo "  unexpected SIGTERM observations: $term_count"; return 1; }
    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 0 ]] || { echo "  orchestrator events with mtime reset: $orch_count"; return 1; }
    return 0
}
check "(c) mtime advance — watchdog resets, never fires" test_c_mtime_advance_resets

# =============================================================================
# (d) SIGTERM ignored → SIGKILL escalation (REQ-4, AC-1)
# =============================================================================
test_d_sigterm_grace_then_sigkill() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    : > "$ndjson"; : > "$stream_file"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_IGNORE_SIGTERM=1 \
    FAKE_POST_RESULT_SLEEP=30 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    # Allow up to 8 s: T_idle (2) + T_grace (1) + slack (5).
    local elapsed=0
    while kill -0 "$fake_pid" 2>/dev/null && [[ $elapsed -lt 8 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$fake_pid" 2>/dev/null; then
        echo "  SIGTERM-ignoring fake still alive after $elapsed s — SIGKILL escalation failed"
        kill -KILL -- "-$fake_pid" 2>/dev/null
        return 1
    fi

    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 1 ]] || { echo "  orchestrator events: $orch_count (want 1)"; return 1; }
    return 0
}
check "(d) SIGTERM ignored — SIGKILL escalation kills PG" test_d_sigterm_grace_then_sigkill

# =============================================================================
# (e) EAGER_EXIT_DISABLE=1 kill switch (REQ-9, AC-3)
# =============================================================================
test_e_disable_kill_switch() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    local term_log="$TEST_DIR/term.log"
    : > "$ndjson"; : > "$stream_file"; : > "$term_log"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_SLEEP=8 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    # Both DISABLE=1 AND IDLE_S=120 set — disable wins (edge-case row 34).
    EAGER_EXIT_DISABLE=1 EAGER_EXIT_IDLE_S=120 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    sleep 6  # well past hypothetical T_idle=2 + T_grace=1 = 3 s
    if ! kill -0 "$fake_pid" 2>/dev/null; then
        echo "  fake died at +6 s with DISABLE=1 — kill switch leaked"
        return 1
    fi

    local term_count; term_count=$(grep -c TERM "$term_log" || true)
    [[ "$term_count" -eq 0 ]] || { echo "  SIGTERM with DISABLE=1: $term_count"; return 1; }
    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 0 ]] || { echo "  orchestrator events with DISABLE=1: $orch_count"; return 1; }

    kill -KILL -- "-$fake_pid" 2>/dev/null
    wait "$fake_pid" 2>/dev/null || true
    return 0
}
check "(e) EAGER_EXIT_DISABLE=1 — watchdog never fires" test_e_disable_kill_switch

# =============================================================================
# (e′) EAGER_EXIT_IDLE_S=0 secondary kill switch (REQ-9)
# =============================================================================
test_eprime_idle_s_zero_kill_switch() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    local term_log="$TEST_DIR/term.log"
    : > "$ndjson"; : > "$stream_file"; : > "$term_log"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_SLEEP=8 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    EAGER_EXIT_DISABLE='' EAGER_EXIT_IDLE_S=0 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    sleep 6
    if ! kill -0 "$fake_pid" 2>/dev/null; then
        echo "  fake died at +6 s with IDLE_S=0 — kill switch leaked"
        return 1
    fi

    local term_count; term_count=$(grep -c TERM "$term_log" || true)
    [[ "$term_count" -eq 0 ]] || { echo "  SIGTERM with IDLE_S=0: $term_count"; return 1; }
    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 0 ]] || { echo "  orchestrator events with IDLE_S=0: $orch_count"; return 1; }

    kill -KILL -- "-$fake_pid" 2>/dev/null
    wait "$fake_pid" 2>/dev/null || true
    return 0
}
check "(e′) EAGER_EXIT_IDLE_S=0 — secondary kill switch" test_eprime_idle_s_zero_kill_switch

# =============================================================================
# (f) Resume-loop coverage (REQ-10, AC-5)
# =============================================================================
test_f_resume_loop_coverage() {
    setup
    write_fake
    # Use per-resume mktemp paths to mirror the resume-loop call site at
    # claude-session-lib.sh:1258.
    local ndjson="$TEST_DIR/resume.ndjson"
    local pid_file="$TEST_DIR/resume.pid"
    local stream_file="$TEST_DIR/resume-stream.ndjson"
    local term_log="$TEST_DIR/resume-term.log"
    : > "$ndjson"; : > "$stream_file"; : > "$term_log"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_SLEEP=30 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote resume pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    local elapsed=0
    while kill -0 "$fake_pid" 2>/dev/null && [[ $elapsed -lt 8 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$fake_pid" 2>/dev/null; then
        echo "  resume fake still alive after $elapsed s"
        kill -KILL -- "-$fake_pid" 2>/dev/null
        return 1
    fi

    local term_count; term_count=$(grep -c TERM "$term_log" || true)
    [[ "$term_count" -ge 1 ]] || { echo "  resume SIGTERM not observed"; return 1; }
    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 1 ]] || { echo "  resume orchestrator events: $orch_count"; return 1; }
    return 0
}
check "(f) resume-loop watchdog — eager-exit semantics apply" test_f_resume_loop_coverage

# =============================================================================
# (g) Empty / late-write phase NDJSON does not crash the watchdog
# =============================================================================
test_g_empty_phase_ndjson_no_crash() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    local watch_stderr="$TEST_DIR/watch.stderr"
    : > "$ndjson"; : > "$stream_file"; : > "$watch_stderr"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_PRE_RESULT_SLEEP=2 \
    FAKE_POST_RESULT_SLEEP=0.3 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    # Capture stderr from the watchdog launcher to detect stat warnings.
    EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 PHASE_TIMEOUT=20 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" 2>"$watch_stderr" >/dev/null

    wait "$fake_pid" 2>/dev/null
    local fake_exit=$?
    [[ $fake_exit -eq 0 ]] || { echo "  fake exited non-zero: $fake_exit"; return 1; }

    sleep 3
    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 0 ]] || { echo "  unexpected orchestrator events: $orch_count"; return 1; }

    if grep -E 'stat:' "$watch_stderr" >/dev/null 2>&1; then
        echo "  watchdog emitted stat error: $(cat "$watch_stderr")"
        return 1
    fi
    return 0
}
check "(g) empty / late-write NDJSON — watchdog arms cleanly" test_g_empty_phase_ndjson_no_crash

# =============================================================================
# (h) Unwritable $STREAM_FILE does not abort the kill (REQ-5 failure mode 2)
# =============================================================================
test_h_unwritable_stream_file_no_abort() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local term_log="$TEST_DIR/term.log"
    : > "$ndjson"; : > "$term_log"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_SLEEP=30 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    # /dev/null/nope is a path that always fails to open for append (ENOTDIR).
    EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "/dev/null/nope" >/dev/null

    local elapsed=0
    while kill -0 "$fake_pid" 2>/dev/null && [[ $elapsed -lt 8 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$fake_pid" 2>/dev/null; then
        echo "  fake still alive after $elapsed s with unwritable stream"
        kill -KILL -- "-$fake_pid" 2>/dev/null
        return 1
    fi

    local term_count; term_count=$(grep -c TERM "$term_log" || true)
    [[ "$term_count" -ge 1 ]] || { echo "  SIGTERM not sent when STREAM_FILE unwritable"; return 1; }
    return 0
}
check "(h) unwritable STREAM_FILE — SIGTERM still fires" test_h_unwritable_stream_file_no_abort

# =============================================================================
# (i) Leader exits between mtime tick and SIGTERM — no signal, no event
# =============================================================================
test_i_leader_exit_race_no_signal() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    local term_log="$TEST_DIR/term.log"
    : > "$ndjson"; : > "$stream_file"; : > "$term_log"

    # Fake exits cleanly at result + 1.5 s (well within T_idle=2).
    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_SLEEP=1.5 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    wait "$fake_pid" 2>/dev/null
    [[ $? -eq 0 ]] || { echo "  fake exited non-zero"; return 1; }

    sleep 3

    local term_count; term_count=$(grep -c TERM "$term_log" || true)
    [[ "$term_count" -eq 0 ]] || { echo "  spurious SIGTERM after race exit: $term_count"; return 1; }
    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 0 ]] || { echo "  spurious orchestrator event: $orch_count"; return 1; }
    return 0
}
check "(i) leader-exit race — kill -0 early-out, no signal" test_i_leader_exit_race_no_signal

# =============================================================================
# (j) _validate_eager_exit_int unit test (REQ-6 edge cases)
# =============================================================================
test_j_validate_eager_exit_int_defaults() {
    set +e
    # shellcheck disable=SC1090
    source "$LIB" >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 0 ]] || { echo "  failed to source lib: rc=$rc"; return 1; }

    type -t _validate_eager_exit_int >/dev/null || { echo "  _validate_eager_exit_int not defined"; return 1; }

    local out
    # 1. unset → default
    unset CHECK_VAR_A
    out=$(_validate_eager_exit_int CHECK_VAR_A 60 2>/dev/null)
    [[ "$out" == "60" ]] || { echo "  unset → '$out' (want 60)"; return 1; }

    # 2. empty → default
    out=$(CHECK_VAR_A="" _validate_eager_exit_int CHECK_VAR_A 60 2>/dev/null)
    [[ "$out" == "60" ]] || { echo "  empty → '$out' (want 60)"; return 1; }

    # 3. valid integer → pass-through
    out=$(CHECK_VAR_A=2 _validate_eager_exit_int CHECK_VAR_A 60 2>/dev/null)
    [[ "$out" == "2" ]] || { echo "  '2' → '$out'"; return 1; }

    # 4. zero → pass-through (zero is valid; the kill-switch is in the caller)
    out=$(CHECK_VAR_A=0 _validate_eager_exit_int CHECK_VAR_A 60 2>/dev/null)
    [[ "$out" == "0" ]] || { echo "  '0' → '$out'"; return 1; }

    # 5. negative → default + WARNING
    local err1
    err1=$(CHECK_VAR_A=-5 _validate_eager_exit_int CHECK_VAR_A 60 2>&1 >/dev/null)
    [[ "$err1" == *WARNING* ]] || { echo "  negative emitted no WARNING (got: $err1)"; return 1; }

    # 6. non-numeric → default + WARNING
    local err2
    err2=$(CHECK_VAR_B=abc _validate_eager_exit_int CHECK_VAR_B 60 2>&1 >/dev/null)
    [[ "$err2" == *WARNING* ]] || { echo "  non-numeric emitted no WARNING (got: $err2)"; return 1; }

    # 7. one-shot guard: two invalid calls in same shell → single WARNING
    local combined warning_count
    combined=$( {
        CHECK_VAR_C=-5 _validate_eager_exit_int CHECK_VAR_C 60 >/dev/null
        CHECK_VAR_C=-7 _validate_eager_exit_int CHECK_VAR_C 60 >/dev/null
        CHECK_VAR_C=abc _validate_eager_exit_int CHECK_VAR_C 60 >/dev/null
    } 2>&1 )
    warning_count=$(echo "$combined" | grep -c WARNING || true)
    [[ "$warning_count" -eq 1 ]] || { echo "  one-shot guard: got $warning_count WARNINGs (want 1)"; return 1; }

    return 0
}
check "(j) _validate_eager_exit_int — defaults + one-shot WARNING" test_j_validate_eager_exit_int_defaults

# =============================================================================
# (k) _classify_phase_exit reclassification (REQ-12)
# =============================================================================
test_k_classify_phase_exit_reclass() {
    setup
    set +e
    # shellcheck disable=SC1090
    source "$LIB" >/dev/null 2>&1
    set -e

    local with_result="$TEST_DIR/with_result.ndjson"
    local without_result="$TEST_DIR/without_result.ndjson"
    printf '{"type":"assistant"}\n{"type":"result","subtype":"success"}\n' > "$with_result"
    printf '{"type":"assistant"}\n' > "$without_result"

    local out
    out=$(_classify_phase_exit 143 "$with_result")
    [[ "$out" == "0" ]] || { echo "  143 + result → '$out' (want 0)"; return 1; }

    out=$(_classify_phase_exit 137 "$with_result")
    [[ "$out" == "0" ]] || { echo "  137 + result → '$out' (want 0)"; return 1; }

    out=$(_classify_phase_exit 124 "$without_result")
    [[ "$out" == "124" ]] || { echo "  124 + no-result → '$out' (want 124)"; return 1; }

    out=$(_classify_phase_exit 1 "$with_result")
    [[ "$out" == "1" ]] || { echo "  1 + result → '$out' (want 1; non-timeout pass-through)"; return 1; }
    return 0
}
check "(k) _classify_phase_exit — 143/137 reclassified, 124 preserved" test_k_classify_phase_exit_reclass

# =============================================================================
# (l) EAGER_EXIT_DISABLE only the literal "1" disables (REQ-9 / REQ-6)
# =============================================================================
test_l_disable_only_literal_one() {
    setup
    write_fake
    local ndjson="$TEST_DIR/phase.ndjson"
    local pid_file="$TEST_DIR/claude.pid"
    local stream_file="$TEST_DIR/stream.ndjson"
    local term_log="$TEST_DIR/term.log"
    : > "$ndjson"; : > "$stream_file"; : > "$term_log"

    FAKE_PID_FILE="$pid_file" \
    FAKE_NDJSON="$ndjson" \
    FAKE_TERM_LOG="$term_log" \
    FAKE_POST_RESULT_SLEEP=30 \
    python3 "$TEST_DIR/fake.py" &
    local fake_pid=$!

    wait_for_file "$pid_file" || { echo "  fake never wrote pid_file"; kill "$fake_pid" 2>/dev/null; return 1; }

    # "true" is shell-truthy but NOT the literal string "1" — must NOT disable.
    EAGER_EXIT_DISABLE=true EAGER_EXIT_IDLE_S=2 EAGER_EXIT_GRACE_S=1 \
        spawn_watchdog_under "$ndjson" "$pid_file" "$stream_file" >/dev/null

    local elapsed=0
    while kill -0 "$fake_pid" 2>/dev/null && [[ $elapsed -lt 8 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$fake_pid" 2>/dev/null; then
        echo "  fake survived with DISABLE=true — gate accepted non-literal-1 truthy value"
        kill -KILL -- "-$fake_pid" 2>/dev/null
        return 1
    fi

    local orch_count; orch_count=$(grep -c 'Eager-exit fired' "$stream_file" || true)
    [[ "$orch_count" -eq 1 ]] || { echo "  orchestrator events with DISABLE=true: $orch_count (want 1)"; return 1; }
    return 0
}
check "(l) EAGER_EXIT_DISABLE=true does NOT disable — only literal '1'" test_l_disable_only_literal_one

# =============================================================================
# (m) Static: orchestrator emit precedes SIGTERM in source (REQ-5 ordering)
# =============================================================================
test_m_emit_before_kill_in_source() {
    local body
    body=$(awk '/^spawn_result_watchdog\(\) \{/,/^\}/' "$LIB")
    [[ -n "$body" ]] || { echo "  could not extract spawn_result_watchdog body"; return 1; }

    local emit_line term_line
    emit_line=$(echo "$body" | grep -n '_emit_orchestrator_kill_event' | head -1 | cut -d: -f1)
    term_line=$(echo "$body" | grep -n 'kill -TERM' | head -1 | cut -d: -f1)

    [[ -n "$emit_line" ]] || { echo "  _emit_orchestrator_kill_event call missing from spawn_result_watchdog"; return 1; }
    [[ -n "$term_line" ]] || { echo "  kill -TERM missing from spawn_result_watchdog"; return 1; }
    [[ "$emit_line" -lt "$term_line" ]] || { echo "  emit at line $emit_line, kill -TERM at line $term_line — emit must precede"; return 1; }
    return 0
}
check "(m) static: orchestrator emit precedes kill -TERM in source" test_m_emit_before_kill_in_source

# =============================================================================
# (n) Static: Strategy B — superseded knob removed from production source
# =============================================================================
# Scope is intentionally narrow: the two files whose contents define the
# operator-facing contract. This test file legitimately mentions the old
# knob name as an assertion target, so it is excluded from the sweep.
test_n_no_legacy_knob_references() {
    local legacy='RESULT_GRACE_S'
    local files=(
        "$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"
        "$REPO_DIR/tests/test_run_phase_watchdog.sh"
    )
    local f hits
    for f in "${files[@]}"; do
        hits=$(grep -n "$legacy" "$f" 2>/dev/null || true)
        if [[ -n "$hits" ]]; then
            echo "  $legacy still referenced in $f:"
            echo "$hits"
            return 1
        fi
    done
    return 0
}
check "(n) Strategy B: legacy knob removed from production source" test_n_no_legacy_knob_references

# =============================================================================
# (o) Static: dashboard/tests/run-all.sh registers both watchdog suites
# =============================================================================
test_o_run_all_registers_both_suites() {
    grep -F 'tests/test_run_phase_watchdog.sh' "$RUN_ALL" >/dev/null || { echo "  run-all.sh missing test_run_phase_watchdog.sh registration"; return 1; }
    grep -F 'tests/test-eager-exit.sh' "$RUN_ALL" >/dev/null || { echo "  run-all.sh missing test-eager-exit.sh registration"; return 1; }
    return 0
}
check "(o) run-all.sh registers both watchdog suites" test_o_run_all_registers_both_suites

# =============================================================================
# (p) Static: autopilot.sh declares the three eager-exit env vars near
#     PHASE_TIMEOUT (REQ-6 discoverability — TESTPLAN row 10)
# =============================================================================
test_p_autopilot_declares_env_vars() {
    local autopilot="$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh"
    bash -n "$autopilot" || { echo "  autopilot.sh failed bash -n syntax check"; return 1; }
    local idle_line grace_line disable_line phase_team_line
    idle_line=$(grep -n 'EAGER_EXIT_IDLE_S' "$autopilot" | head -1 | cut -d: -f1 || true)
    grace_line=$(grep -n 'EAGER_EXIT_GRACE_S' "$autopilot" | head -1 | cut -d: -f1 || true)
    disable_line=$(grep -n 'EAGER_EXIT_DISABLE' "$autopilot" | head -1 | cut -d: -f1 || true)
    phase_team_line=$(grep -n 'PHASE_TIMEOUT_TEAM' "$autopilot" | head -1 | cut -d: -f1 || true)
    [[ -n "$idle_line" && -n "$grace_line" && -n "$disable_line" ]] || { echo "  one or more EAGER_EXIT_* vars missing from autopilot.sh"; return 1; }
    [[ -n "$phase_team_line" ]] || { echo "  PHASE_TIMEOUT_TEAM not found in autopilot.sh"; return 1; }
    # All three must sit within ±15 lines of PHASE_TIMEOUT_TEAM (REQ-6 "near").
    local delta
    for line in "$idle_line" "$grace_line" "$disable_line"; do
        delta=$(( line - phase_team_line ))
        delta=${delta#-}
        [[ "$delta" -le 15 ]] || { echo "  EAGER_EXIT_* declared $delta lines from PHASE_TIMEOUT_TEAM (>15)"; return 1; }
    done
    return 0
}
check "(p) autopilot.sh declares EAGER_EXIT_* near PHASE_TIMEOUT" test_p_autopilot_declares_env_vars

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
