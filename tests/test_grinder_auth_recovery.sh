#!/bin/bash
# test_grinder_auth_recovery.sh — TDD for the grinder auth-recovery feature.
#
# Covers C1 (auth_preflight_probe), C3 (_auth_failed_classify),
# C4 (_emit_auth_failed_event), C5 (run_phase post-stream auth hook helper),
# C6 (run_gated_phase short-circuit), and C7 (8-var env-strip parity).
#
# Usage: bash tests/test_grinder_auth_recovery.sh
# Exit 0 on success, non-zero on any assertion failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"
GRINDER="$REPO_DIR/adapters/claude-code/claude/tools/grinder.sh"
FIXTURES="$REPO_DIR/tests/fixtures/grinder-auth-recovery"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"; shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

TEST_DIR="${TMPDIR:-/tmp}/test-grinder-auth-recovery-$$"
GIT_STATE_BEFORE=""

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR" "$TEST_DIR/mock-bin"
}

teardown() {
    rm -rf "$TEST_DIR"
}
trap teardown EXIT INT TERM

GIT_STATE_BEFORE=$(cd "$REPO_DIR" && git status --porcelain 2>/dev/null | grep -v '^?? tests/fixtures/grinder-auth-recovery/' || true)

echo "Running grinder auth-recovery tests..."
echo ""

# Source the library inside a subshell, with stubs for the caller-provided
# functions, then call the requested helper. Stubs are defined AFTER `source`
# so they shadow any lib-provided defaults. Stdout is the helper's output;
# captured exit code is the helper's exit. Used by C3/C4/C5 unit tests.
call_lib() {
    bash -c "
        STREAM_FILE=\${STREAM_FILE:-${TEST_DIR}/stream.ndjson}
        AUTOPILOT_SID=\${AUTOPILOT_SID:-test-sid}
        DASHBOARD_DATA=\${DASHBOARD_DATA:-/dev/null}
        export STREAM_FILE AUTOPILOT_SID DASHBOARD_DATA
        source '$LIB'
        log() { :; }
        fail_pipeline() { return 1; }
        dashboard_event() { :; }
        track_phase() { :; }
        commit_phase() { :; }
        check_artifact() { return 0; }
        track_deviation() { :; }
        $*
    "
}

# =============================================================================
# C3 — _auth_failed_classify
# =============================================================================

test_c3_1_defined() {
    local out
    out=$(call_lib "type -t _auth_failed_classify")
    [[ "$out" == "function" ]] || { echo "  not a function: $out"; return 1; }
}
check "C3.1: _auth_failed_classify is defined" test_c3_1_defined

test_c3_2_not_logged_in() {
    local out
    out=$(call_lib "_auth_failed_classify '$FIXTURES/auth_failed_not_logged_in.ndjson'")
    [[ "$out" == "not_logged_in" ]] || { echo "  expected 'not_logged_in', got '$out'"; return 1; }
}
check "C3.2: shape (a) → 'not_logged_in'" test_c3_2_not_logged_in

test_c3_3_top_level_error() {
    local out
    out=$(call_lib "_auth_failed_classify '$FIXTURES/auth_failed_top_level_error.ndjson'")
    [[ "$out" == "authentication_failed" ]] || { echo "  expected 'authentication_failed', got '$out'"; return 1; }
}
check "C3.3: shape (b) → 'authentication_failed'" test_c3_3_top_level_error

test_c3_4_non_auth_returns_empty() {
    local out
    out=$(call_lib "_auth_failed_classify '$FIXTURES/non_auth_failure.ndjson'")
    [[ -z "$out" ]] || { echo "  expected empty, got '$out'"; return 1; }
}
check "C3.4: non-auth result event → empty (R3.5)" test_c3_4_non_auth_returns_empty

test_c3_5_only_type_result() {
    setup
    local f="$TEST_DIR/c3_5.ndjson"
    cat > "$f" <<EOF
{"type":"assistant","error":"authentication_failed"}
{"type":"user","result":"Not logged in","is_error":true,"subtype":"success"}
EOF
    local out
    out=$(call_lib "_auth_failed_classify '$f'")
    [[ -z "$out" ]] || { echo "  expected empty, got '$out'"; return 1; }
}
check "C3.5: predicate gates on type==result only" test_c3_5_only_type_result

test_c3_6_first_match_wins() {
    setup
    local f="$TEST_DIR/c3_6.ndjson"
    cat > "$f" <<EOF
{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}
{"type":"assistant"}
{"type":"result","error":"authentication_failed"}
EOF
    local out
    out=$(call_lib "_auth_failed_classify '$f'")
    [[ "$out" == "not_logged_in" ]] || { echo "  expected 'not_logged_in' (first match), got '$out'"; return 1; }
}
check "C3.6: first-match-wins (EC-E)" test_c3_6_first_match_wins

test_c3_7_malformed_json_skipped() {
    setup
    local f="$TEST_DIR/c3_7.ndjson"
    printf '{"type":"resu\n{"type":"result","error":"authentication_failed"}\n' > "$f"
    local out
    out=$(call_lib "_auth_failed_classify '$f'" 2>"$TEST_DIR/stderr")
    [[ "$out" == "authentication_failed" ]] || { echo "  expected match after skipping malformed; got '$out'"; return 1; }
    grep -q -i 'traceback' "$TEST_DIR/stderr" && { echo "  unexpected python traceback in stderr"; return 1; }
    return 0
}
check "C3.7: malformed JSON line skipped (R3.6)" test_c3_7_malformed_json_skipped

test_c3_8_missing_file() {
    local out rc=0
    out=$(call_lib "_auth_failed_classify '/nonexistent/path.ndjson'" 2>/dev/null) || rc=$?
    [[ -z "$out" ]] || { echo "  expected empty for missing file, got '$out'"; return 1; }
    return 0
}
check "C3.8: missing input file does not crash (defensive)" test_c3_8_missing_file

test_c3_9_empty_file() {
    setup
    : > "$TEST_DIR/empty.ndjson"
    local out
    out=$(call_lib "_auth_failed_classify '$TEST_DIR/empty.ndjson'")
    [[ -z "$out" ]] || { echo "  expected empty, got '$out'"; return 1; }
}
check "C3.9: empty file → empty" test_c3_9_empty_file

test_c3_10_assessor_payload_no_match() {
    setup
    local f="$TEST_DIR/c3_10.ndjson"
    # Synthetic assessor-shaped JSON: no `type:"result"` field at top level.
    printf '{"category":"integration_gap","error":"authentication_failed","confidence":0.9}\n' > "$f"
    local out
    out=$(call_lib "_auth_failed_classify '$f'")
    [[ -z "$out" ]] || { echo "  expected empty (no type==result), got '$out'"; return 1; }
}
check "C3.10: assessor payload (no type==result) → empty (RK-5)" test_c3_10_assessor_payload_no_match

test_c3_11_is_error_false() {
    setup
    local f="$TEST_DIR/c3_11.ndjson"
    printf '{"type":"result","subtype":"success","is_error":false,"result":"Not logged in fyi"}\n' > "$f"
    local out
    out=$(call_lib "_auth_failed_classify '$f'")
    [[ -z "$out" ]] || { echo "  expected empty (is_error false), got '$out'"; return 1; }
}
check "C3.11: is_error=false does NOT match shape (a) (negative gate)" test_c3_11_is_error_false

# =============================================================================
# C4 — _emit_auth_failed_event
# =============================================================================

test_c4_1_defined() {
    local out
    out=$(call_lib "type -t _emit_auth_failed_event")
    [[ "$out" == "function" ]] || { echo "  not a function: $out"; return 1; }
}
check "C4.1: _emit_auth_failed_event is defined" test_c4_1_defined

test_c4_2_appends_one_line() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson" call_lib "_emit_auth_failed_event 'phase-x' 'sid-y' 'not_logged_in'"
    local lines
    lines=$(wc -l < "$TEST_DIR/stream.ndjson" | tr -d ' ')
    [[ "$lines" == "1" ]] || { echo "  expected 1 line, got $lines"; return 1; }
}
check "C4.2: appends exactly one NDJSON line" test_c4_2_appends_one_line

test_c4_3_valid_wire_format() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson" call_lib "_emit_auth_failed_event 'phase-x' 'sid-y' 'not_logged_in'"
    python3 -c "
import json,sys
e = json.loads(open(sys.argv[1]).read().strip())
assert e['type'] == 'auth_failed', e
assert e['phase'] == 'phase-x', e
assert e['session_id'] == 'sid-y', e
assert e['reason'] == 'not_logged_in', e
assert 'ts' in e, e
" "$TEST_DIR/stream.ndjson"
}
check "C4.3: emitted line is valid JSON with exact wire format" test_c4_3_valid_wire_format

test_c4_4_iso_timestamp() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson" call_lib "_emit_auth_failed_event 'p' 's' 'r'"
    local ts
    ts=$(python3 -c "import json; print(json.loads(open('$TEST_DIR/stream.ndjson').read().strip())['ts'])")
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || { echo "  ts not UTC ISO: '$ts'"; return 1; }
}
check "C4.4: ts field is UTC ISO 8601" test_c4_4_iso_timestamp

test_c4_5_unwritable_no_abort() {
    setup
    chmod 000 "$TEST_DIR" 2>/dev/null || true
    STREAM_FILE="$TEST_DIR/cannot-write/stream.ndjson" call_lib "_emit_auth_failed_event 'p' 's' 'r'" \
        2>/dev/null
    local rc=$?
    chmod 755 "$TEST_DIR" 2>/dev/null || true
    [[ $rc -eq 0 ]] || { echo "  helper aborted on unwritable STREAM_FILE (rc=$rc)"; return 1; }
}
check "C4.5: append failure does not abort caller" test_c4_5_unwritable_no_abort

test_c4_6_back_to_back() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson" call_lib "
_emit_auth_failed_event 'p1' 's1' 'not_logged_in'
_emit_auth_failed_event 'p2' 's2' 'authentication_failed'
_emit_auth_failed_event 'p3' 's3' 'not_logged_in'
"
    local lines
    lines=$(wc -l < "$TEST_DIR/stream.ndjson" | tr -d ' ')
    [[ "$lines" == "3" ]] || { echo "  expected 3 lines, got $lines"; return 1; }
}
check "C4.6: 3 back-to-back calls produce 3 distinct lines" test_c4_6_back_to_back

test_c4_7_empty_session_id() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson" call_lib "_emit_auth_failed_event 'p' '' 'not_logged_in'"
    python3 -c "
import json,sys
e = json.loads(open(sys.argv[1]).read().strip())
assert e['session_id'] == '', e
" "$TEST_DIR/stream.ndjson"
}
check "C4.7: empty session_id accepted" test_c4_7_empty_session_id

# =============================================================================
# C5 — run_phase post-stream auth hook (via _run_phase_auth_check helper)
# =============================================================================

test_c5_helper_defined() {
    local out
    out=$(call_lib "type -t _run_phase_auth_check")
    [[ "$out" == "function" ]] || { echo "  not a function: $out"; return 1; }
}
check "C5.0: _run_phase_auth_check helper is defined" test_c5_helper_defined

test_c5_2_shape_a_returns_sentinel() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson"
    local out rc=0
    out=$(STREAM_FILE="$STREAM_FILE" call_lib "
_run_phase_auth_check 1 '$FIXTURES/auth_failed_not_logged_in.ndjson' 'pass-mechanical' 'sid-abc'
echo \"RC=\$?\"
") || rc=$?
    grep -q "^RC=42$" <<<"$out" || { echo "  expected RC=42 (sentinel), got: $out"; return 1; }
    grep -q '"type":"auth_failed"' "$STREAM_FILE" || { echo "  no auth_failed event in stream"; return 1; }
    grep -q '"reason":"not_logged_in"' "$STREAM_FILE" || { echo "  reason not 'not_logged_in'"; return 1; }
    local n
    n=$(grep -c '"type":"auth_failed"' "$STREAM_FILE")
    [[ "$n" == "1" ]] || { echo "  expected 1 auth_failed event, got $n"; return 1; }
}
check "C5.2: hook returns sentinel for shape (a) + emits one event" test_c5_2_shape_a_returns_sentinel

test_c5_3_shape_b_returns_sentinel() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson"
    local out
    out=$(STREAM_FILE="$STREAM_FILE" call_lib "
_run_phase_auth_check 1 '$FIXTURES/auth_failed_top_level_error.ndjson' 'pass-mechanical' 'sid-abc'
echo \"RC=\$?\"
")
    grep -q "^RC=42$" <<<"$out" || { echo "  expected RC=42, got: $out"; return 1; }
    grep -q '"reason":"authentication_failed"' "$STREAM_FILE" || { echo "  reason not 'authentication_failed'"; return 1; }
}
check "C5.3: hook returns sentinel for shape (b)" test_c5_3_shape_b_returns_sentinel

test_c5_1_no_op_on_zero_exit() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson"
    local out
    out=$(STREAM_FILE="$STREAM_FILE" call_lib "
_run_phase_auth_check 0 '$FIXTURES/auth_failed_not_logged_in.ndjson' 'pass' 'sid'
echo \"RC=\$?\"
")
    grep -q "^RC=0$" <<<"$out" || { echo "  expected RC=0 (no auth check), got: $out"; return 1; }
    [[ ! -s "$STREAM_FILE" ]] || { echo "  stream should be empty when exit_code=0"; return 1; }
}
check "C5.1: hook is a no-op when exit_code==0 (R3.5, perf)" test_c5_1_no_op_on_zero_exit

test_c5_4_non_auth_passthrough() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson"
    local out
    out=$(STREAM_FILE="$STREAM_FILE" call_lib "
_run_phase_auth_check 1 '$FIXTURES/non_auth_failure.ndjson' 'pass' 'sid'
echo \"RC=\$?\"
")
    grep -q "^RC=1$" <<<"$out" || { echo "  expected RC=1 (passthrough), got: $out"; return 1; }
    [[ ! -s "$STREAM_FILE" ]] || { echo "  stream should be empty for non-auth failure"; return 1; }
}
check "C5.4: non-auth failure passes through unchanged (R3.5)" test_c5_4_non_auth_passthrough

# C5.6: hook positioned BEFORE phase_ndjson cleanup (static check)
test_c5_6_positioning() {
    local hook_line rm_line
    hook_line=$(awk '/_run_phase_auth_check/ && !/^[[:space:]]*#/ {print NR; exit}' "$LIB")
    rm_line=$(awk '/^  rm -f "\$phase_ndjson" "\$pid_file"/ {print NR; exit}' "$LIB")
    [[ -n "$hook_line" && -n "$rm_line" ]] || { echo "  could not locate both lines (hook='$hook_line', rm='$rm_line')"; return 1; }
    [[ "$hook_line" -lt "$rm_line" ]] || { echo "  hook ($hook_line) must precede rm ($rm_line)"; return 1; }
}
check "C5.6: auth hook positioned before phase_ndjson cleanup" test_c5_6_positioning

test_c5_9_named_constant_only() {
    # Numeric literal 42 should appear ONLY in the AUTH_FAILED_EXIT_CODE
    # default declaration line (via the `: "${VAR:=42}"` idiom).
    local count
    count=$(grep -cE '\b42\b' "$LIB" || true)
    [[ "$count" -ge 1 ]] || { echo "  AUTH_FAILED_EXIT_CODE declaration missing"; return 1; }
    # Every '42' must be inside a comment OR inside the AUTH_FAILED_EXIT_CODE line.
    local stray
    stray=$(grep -nE '\b42\b' "$LIB" | grep -v 'AUTH_FAILED_EXIT_CODE' | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [[ -z "$stray" ]] || { echo "  stray magic number 42 outside AUTH_FAILED_EXIT_CODE: $stray"; return 1; }
}
check "C5.9: '42' appears only in AUTH_FAILED_EXIT_CODE declaration (no magic number)" test_c5_9_named_constant_only

# =============================================================================
# C6 — run_gated_phase short-circuit
# =============================================================================

# Stub run_phase via a counter file. Drive run_gated_phase through call_lib
# with stubs for log/fail_pipeline/track_phase/check_artifact/commit_phase
# so the harness observes side effects without touching the real grinder.

run_gated_with_stub() {
    local stub_rc="$1"
    local override_sentinel="${2:-}"
    setup
    local counter="$TEST_DIR/run_phase_calls"
    local logfile="$TEST_DIR/log.txt"
    local trackfile="$TEST_DIR/track.txt"
    local committed="$TEST_DIR/committed.txt"
    local failpipefile="$TEST_DIR/fail_pipe.txt"
    local trackdev="$TEST_DIR/track_dev.txt"
    : > "$counter"
    : > "$logfile"
    : > "$trackfile"
    : > "$committed"
    : > "$failpipefile"
    : > "$trackdev"
    bash -c "
        ${override_sentinel:+export AUTH_FAILED_EXIT_CODE=$override_sentinel}
        STREAM_FILE='$TEST_DIR/stream.ndjson'
        AUTOPILOT_SID=t
        DASHBOARD_DATA=/dev/null
        TASK=t
        export STREAM_FILE AUTOPILOT_SID DASHBOARD_DATA TASK
        source '$LIB'
        # Stubs AFTER source so they shadow lib-provided definitions.
        log() { echo \"\$1\" >> '$logfile'; }
        fail_pipeline() { echo \"\$1|\$2\" >> '$failpipefile'; return 1; }
        run_phase() { echo 1 >> '$counter'; return $stub_rc; }
        check_artifact() { return 0; }
        commit_phase() { echo 1 >> '$committed'; }
        track_phase() { echo \"\$2\" >> '$trackfile'; }
        track_deviation() { echo 1 >> '$trackdev'; }
        run_gated_phase 'cmd' 'pass-mechanical' '$TEST_DIR' '$TEST_DIR/artifact' 'commit-msg' 'artifact-id' || true
    " 2>/dev/null
    echo "$counter $logfile $trackfile $committed $failpipefile $trackdev"
}

test_c6_1_sentinel_halts_loop() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 42)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    local n
    n=$(wc -l < "$counter" | tr -d ' ')
    [[ "$n" == "1" ]] || { echo "  expected 1 run_phase invocation, got $n"; return 1; }
}
check "C6.1: sentinel exit halts retry loop (counter=1)" test_c6_1_sentinel_halts_loop

test_c6_2_halt_message() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 42)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    local n
    n=$(grep -c 'grinder halted: claude authentication lost mid-run' "$logfile" || true)
    [[ "$n" == "1" ]] || { echo "  expected 1 halt message, got $n; logfile content:"; cat "$logfile"; return 1; }
}
check "C6.2: operator halt message logged exactly once" test_c6_2_halt_message

test_c6_3_track_phase_status() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 42)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    grep -q '^auth_failed$' "$trackfile" || { echo "  track_phase status not 'auth_failed'; got:"; cat "$trackfile"; return 1; }
}
check "C6.3: track_phase invoked with status 'auth_failed'" test_c6_3_track_phase_status

test_c6_4_no_track_deviation() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 42)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    [[ ! -s "$trackdev" ]] || { echo "  track_deviation was invoked"; return 1; }
}
check "C6.4: track_deviation NOT invoked on auth_failed (EC-J)" test_c6_4_no_track_deviation

test_c6_5_no_commit() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 42)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    [[ ! -s "$committed" ]] || { echo "  commit_phase was invoked"; return 1; }
}
check "C6.5: commit_phase NOT invoked on auth_failed" test_c6_5_no_commit

test_c6_6_fail_pipeline_once() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 42)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    local n
    n=$(wc -l < "$failpipefile" | tr -d ' ')
    [[ "$n" == "1" ]] || { echo "  expected 1 fail_pipeline call, got $n"; return 1; }
}
check "C6.6: fail_pipeline invoked exactly once" test_c6_6_fail_pipeline_once

test_c6_7_non_auth_still_retries() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 1)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    local n
    n=$(wc -l < "$counter" | tr -d ' ')
    [[ "$n" == "2" ]] || { echo "  expected 2 invocations (retry preserved), got $n"; return 1; }
}
check "C6.7: non-auth exit code 1 preserves 2-attempt retry" test_c6_7_non_auth_still_retries

test_c6_8_124_still_retries() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 124)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    local n
    n=$(wc -l < "$counter" | tr -d ' ')
    [[ "$n" == "2" ]] || { echo "  expected 2 invocations, got $n"; return 1; }
}
check "C6.8: real timeout (124) still retries (regression check)" test_c6_8_124_still_retries

test_c6_9_41_not_sentinel() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 41)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    local n
    n=$(wc -l < "$counter" | tr -d ' ')
    [[ "$n" == "2" ]] || { echo "  expected 2 invocations (41 is NOT the sentinel), got $n"; return 1; }
}
check "C6.9: exit 41 is not the sentinel; retry preserved" test_c6_9_41_not_sentinel

test_c6_10_env_override() {
    local outs counter logfile trackfile committed failpipefile trackdev
    outs=$(run_gated_with_stub 50 50)
    read -r counter logfile trackfile committed failpipefile trackdev <<<"$outs"
    local n
    n=$(wc -l < "$counter" | tr -d ' ')
    [[ "$n" == "1" ]] || { echo "  env override AUTH_FAILED_EXIT_CODE=50 should short-circuit; got $n"; return 1; }
}
check "C6.10: AUTH_FAILED_EXIT_CODE override (=50) short-circuits" test_c6_10_env_override

# =============================================================================
# C7 — env-strip extension (static checks)
# =============================================================================

test_c7_1_initial_invocation_strips_8_vars() {
    # Extract the run_phase block around the initial `$timeout_cmd env`
    # spawn. The line was modified by local-llm-routing to expand the
    # LOCAL_LLM_ENV_VARS array immediately after `env`; the `-u <var>`
    # tokens now sit on the continuation line. Entry pattern is the
    # `$timeout_cmd env` literal; accumulate until `python3 -c`.
    awk '
        /\$timeout_cmd env / { in_block = 1 }
        in_block { buf = buf $0 "\n" }
        in_block && /python3 -c/ { print buf; exit }
    ' "$LIB" > "$TEST_DIR/c7_1.txt"
    local missing=""
    for v in ALL_PROXY HTTPS_PROXY HTTP_PROXY NO_PROXY all_proxy https_proxy http_proxy no_proxy; do
        grep -q -- "-u $v\b" "$TEST_DIR/c7_1.txt" || missing="$missing $v"
    done
    [[ -z "$missing" ]] || { echo "  missing env -u for vars:$missing"; return 1; }
}
check "C7.1: initial run_phase claude -p invocation strips all 8 proxy vars" test_c7_1_initial_invocation_strips_8_vars

test_c7_2_resume_invocation_strips_8_vars() {
    # Extract the resume block around CLAUDE_PID_FILE="$resume_pid_file".
    awk '
        /CLAUDE_PID_FILE="\$resume_pid_file"/ { in_block = 1 }
        in_block { buf = buf $0 "\n" }
        in_block && /claude -p "\$keyword"/ { print buf; exit }
    ' "$LIB" > "$TEST_DIR/c7_2.txt"
    local missing=""
    for v in ALL_PROXY HTTPS_PROXY HTTP_PROXY NO_PROXY all_proxy https_proxy http_proxy no_proxy; do
        grep -q -- "-u $v\b" "$TEST_DIR/c7_2.txt" || missing="$missing $v"
    done
    [[ -z "$missing" ]] || { echo "  missing env -u for vars:$missing"; return 1; }
}
check "C7.2: resume run_phase claude -p invocation strips all 8 proxy vars (R2.3)" test_c7_2_resume_invocation_strips_8_vars

test_c7_3_no_unset() {
    # No `unset` of proxy vars near `claude -p` — only `env -u` is allowed.
    local hits
    hits=$(grep -nE 'unset[[:space:]]+(ALL_PROXY|HTTPS_PROXY|HTTP_PROXY|NO_PROXY|all_proxy|https_proxy|http_proxy|no_proxy)' "$LIB" || true)
    [[ -z "$hits" ]] || { echo "  unset of proxy vars found (R2.2 forbids):"; echo "$hits"; return 1; }
}
check "C7.3: no shell-level unset of proxy vars" test_c7_3_no_unset

test_c7_5_assessor_strip_unchanged() {
    # The assessor wire (line 699) and run_phase (initial + resume) collectively
    # strip all 8 vars; counting `-u no_proxy` (lowercase) as a representative
    # marker, expect ≥ 3 occurrences in the file.
    local count
    count=$(grep -c -- '-u no_proxy' "$LIB" || true)
    [[ "$count" -ge 3 ]] || { echo "  expected ≥3 '-u no_proxy' (assessor + initial + resume); got $count"; return 1; }
}
check "C7.5: 8-var strip parity across assessor + initial + resume invocations" test_c7_5_assessor_strip_unchanged

# =============================================================================
# C1 — auth_preflight_probe (in grinder.sh)
# =============================================================================

# Make grinder.sh sourceable: rely on the `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`
# guard added around `main "$@"`. If the guard is missing, sourcing trips
# `set -e`/main with no args; any C1 test below will fail loudly.
call_grinder() {
    bash -c "
        log() { :; }
        STREAM_FILE='$TEST_DIR/stream.ndjson'
        AUTOPILOT_SID=t
        DASHBOARD_DATA=/dev/null
        export STREAM_FILE AUTOPILOT_SID DASHBOARD_DATA
        source '$GRINDER' >/dev/null 2>&1
        $*
    "
}

test_c1_11_function_defined() {
    local out
    out=$(call_grinder "type -t auth_preflight_probe")
    [[ "$out" == "function" ]] || { echo "  not a function: '$out'"; return 1; }
}
check "C1.11: auth_preflight_probe is defined" test_c1_11_function_defined

# claude-free PATH that still has bash / mktemp / date / env: /usr/bin:/bin.
# Verified above (C1.4 test): claude is not in /usr/bin on the operator's machine.
NO_CLAUDE_PATH="/usr/bin:/bin"

test_c1_3_skip_env() {
    setup
    local out rc=0
    out=$(GRINDER_SKIP_AUTH_PREFLIGHT=1 PATH="$NO_CLAUDE_PATH" call_grinder "auth_preflight_probe" 2>&1) || rc=$?
    [[ $rc -eq 0 ]] || { echo "  expected rc=0, got $rc; output: $out"; return 1; }
    grep -q 'WARNING: auth preflight skipped via GRINDER_SKIP_AUTH_PREFLIGHT' <<<"$out" \
        || { echo "  WARNING line missing from stderr; got: $out"; return 1; }
}
check "C1.3: GRINDER_SKIP_AUTH_PREFLIGHT=1 short-circuits (R1.7)" test_c1_3_skip_env

test_c1_4_binary_missing() {
    setup
    local out rc=0
    out=$(PATH="$NO_CLAUDE_PATH" call_grinder "auth_preflight_probe" 2>&1) || rc=$?
    [[ $rc -eq 2 ]] || { echo "  expected exit 2, got $rc; output: $out"; return 1; }
    grep -q 'claude binary not found on PATH' <<<"$out" || { echo "  expected error message; got: $out"; return 1; }
}
check "C1.4: claude binary missing → exit 2 (R1.6, EC-B)" test_c1_4_binary_missing

# Build a PATH-shim claude that emits a fixture NDJSON.
# Inputs are validated to integer literals (exit_code, sleep_seconds)
# before heredoc substitution so a future caller cannot inject shell
# fragments via the mock-script body.
make_mock_claude() {
    local fixture="$1" exit_code="${2:-0}" sleep_seconds="${3:-0}"
    [[ "$exit_code" =~ ^[0-9]+$ ]] || { echo "make_mock_claude: exit_code must be integer, got '$exit_code'" >&2; return 2; }
    [[ "$sleep_seconds" =~ ^[0-9]+$ ]] || { echo "make_mock_claude: sleep_seconds must be integer, got '$sleep_seconds'" >&2; return 2; }
    cat > "$TEST_DIR/mock-bin/claude" <<EOF
#!/usr/bin/env bash
[[ $sleep_seconds -gt 0 ]] && sleep $sleep_seconds
cat "$fixture"
exit $exit_code
EOF
    chmod +x "$TEST_DIR/mock-bin/claude"
}

test_c1_5_not_logged_in() {
    setup
    make_mock_claude "$FIXTURES/auth_failed_not_logged_in.ndjson" 0
    local out rc=0
    out=$(PATH="$TEST_DIR/mock-bin:$PATH" call_grinder "auth_preflight_probe" 2>&1) || rc=$?
    [[ $rc -eq 2 ]] || { echo "  expected exit 2 (auth-failed shape (a)), got $rc; output: $out"; return 1; }
    grep -q 'claude auth required — run claude login and retry' <<<"$out" \
        || { echo "  expected operator message; got: $out"; return 1; }
}
check "C1.5: shape (a) probe → exit 2 + operator message (R1.5)" test_c1_5_not_logged_in

test_c1_6_top_level_error() {
    setup
    make_mock_claude "$FIXTURES/auth_failed_top_level_error.ndjson" 0
    local out rc=0
    out=$(PATH="$TEST_DIR/mock-bin:$PATH" call_grinder "auth_preflight_probe" 2>&1) || rc=$?
    [[ $rc -eq 2 ]] || { echo "  expected exit 2 (auth-failed shape (b)), got $rc; output: $out"; return 1; }
    grep -q 'claude auth required — run claude login and retry' <<<"$out" \
        || { echo "  expected operator message; got: $out"; return 1; }
}
check "C1.6: shape (b) probe → exit 2 + operator message (R1.5)" test_c1_6_top_level_error

test_c1_1_success_silent() {
    setup
    # Mock claude that emits a clean (non-auth-failed) result event and exits 0.
    cat > "$TEST_DIR/mock-bin/claude" <<EOF
#!/usr/bin/env bash
echo '{"type":"system","subtype":"init","session_id":"ok"}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"k","num_turns":1}'
exit 0
EOF
    chmod +x "$TEST_DIR/mock-bin/claude"
    local out rc=0
    out=$(PATH="$TEST_DIR/mock-bin:$PATH" call_grinder "auth_preflight_probe" 2>&1) || rc=$?
    [[ $rc -eq 0 ]] || { echo "  expected exit 0 on success path, got $rc; output: $out"; return 1; }
    [[ -z "$out" ]] || { echo "  expected silent success, got: $out"; return 1; }
}
check "C1.1: success path returns 0 silently (R1.4)" test_c1_1_success_silent

test_c1_7_timeout() {
    setup
    make_mock_claude "$FIXTURES/auth_failed_not_logged_in.ndjson" 0 30  # sleeps 30s
    local out rc=0
    # Override timeout to 1s so test stays fast.
    out=$(AUTH_PROBE_TIMEOUT_S=1 PATH="$TEST_DIR/mock-bin:$PATH" call_grinder "auth_preflight_probe" 2>&1) || rc=$?
    [[ $rc -eq 2 ]] || { echo "  expected exit 2 on timeout, got $rc; output: $out"; return 1; }
    grep -q 'claude auth probe timed out after 1s' <<<"$out" \
        || { echo "  expected timeout message; got: $out"; return 1; }
}
check "C1.7: probe timeout → exit 2 + timeout message (R1.3, R1.6, EC-C)" test_c1_7_timeout

test_c1_8_nonzero_no_auth() {
    setup
    # Shim exits 1 with a non-auth result event.
    cat > "$TEST_DIR/mock-bin/claude" <<EOF
#!/usr/bin/env bash
echo '{"type":"result","subtype":"success","is_error":true,"result":"some other error"}'
exit 1
EOF
    chmod +x "$TEST_DIR/mock-bin/claude"
    local out rc=0
    out=$(PATH="$TEST_DIR/mock-bin:$PATH" call_grinder "auth_preflight_probe" 2>&1) || rc=$?
    [[ $rc -eq 2 ]] || { echo "  expected exit 2 (defensive), got $rc; output: $out"; return 1; }
    grep -q 'claude auth probe failed' <<<"$out" \
        || { echo "  expected probe-failed message; got: $out"; return 1; }
}
check "C1.8: probe rc!=0 with no auth shape → exit 2 + probe-failed message" test_c1_8_nonzero_no_auth

# C1.10 — static check that the probe uses the eight-var strip.
test_c1_10_8var_strip() {
    awk '/^auth_preflight_probe\(\)/,/^}$/' "$GRINDER" > "$TEST_DIR/probe.txt"
    [[ -s "$TEST_DIR/probe.txt" ]] || { echo "  probe body not found"; return 1; }
    local missing=""
    for v in ALL_PROXY HTTPS_PROXY HTTP_PROXY NO_PROXY all_proxy https_proxy http_proxy no_proxy; do
        grep -q -- "-u $v\b" "$TEST_DIR/probe.txt" || missing="$missing $v"
    done
    [[ -z "$missing" ]] || { echo "  probe missing env -u for vars:$missing"; return 1; }
}
check "C1.10: probe uses the eight-var proxy strip (parity)" test_c1_10_8var_strip

# =============================================================================
# C8 — infrastructure scenarios
# =============================================================================

test_c8_1_executable() {
    [[ -x "$0" ]] || { echo "  test file not executable"; return 1; }
}
check "C8.1: test file is executable" test_c8_1_executable

test_c8_2_registered() {
    grep -q 'test_grinder_auth_recovery.sh' "$REPO_DIR/dashboard/tests/run-all.sh" \
        || { echo "  test not registered in dashboard/tests/run-all.sh"; return 1; }
}
check "C8.2: test registered in dashboard/tests/run-all.sh" test_c8_2_registered

test_c8_3_fixtures_valid_ndjson() {
    for f in "$FIXTURES"/*.ndjson; do
        python3 -c "import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]" "$f" \
            || { echo "  fixture invalid: $f"; return 1; }
    done
}
check "C8.3: all fixtures parse as NDJSON" test_c8_3_fixtures_valid_ndjson

test_c8_4_fixtures_present() {
    [[ -f "$FIXTURES/auth_failed_not_logged_in.ndjson" ]] || { echo "  missing fixture (a)"; return 1; }
    [[ -f "$FIXTURES/auth_failed_top_level_error.ndjson" ]] || { echo "  missing fixture (b)"; return 1; }
    [[ -f "$FIXTURES/non_auth_failure.ndjson" ]] || { echo "  missing negative fixture"; return 1; }
}
check "C8.4: fixtures present under tests/fixtures/grinder-auth-recovery/" test_c8_4_fixtures_present

test_c8_8_git_state_unchanged() {
    local current
    current=$(cd "$REPO_DIR" && git status --porcelain 2>/dev/null | grep -v '^?? tests/fixtures/grinder-auth-recovery/' || true)
    [[ "$current" == "$GIT_STATE_BEFORE" ]] || {
        echo "  git state changed during test run!"
        echo "  before: $GIT_STATE_BEFORE"
        echo "  after:  $current"
        return 1
    }
}
check "C8.8: git working tree unchanged at end of test" test_c8_8_git_state_unchanged

# =============================================================================
# Cross-cutting (X.4: bash 3.2 — no associative arrays in new code)
# =============================================================================

test_x4_no_associative_arrays() {
    # Restrict to NEW code (this test file + new shell additions in
    # grinder.sh and claude-session-lib.sh — feature additions only).
    # Use word-boundary patterns so the regex string in this very check
    # (with its quoted dashes) does not self-match.
    local hits=""
    hits=$(grep -nE '(declare|local)[[:space:]]+-A[[:space:]]' "$0" "$LIB" "$GRINDER" 2>/dev/null \
              | grep -v 'grep -nE' || true)
    [[ -z "$hits" ]] || { echo "  associative array usage found:"; echo "$hits"; return 1; }
}
check "X.4: bash 3.2 — no associative arrays in new test code" test_x4_no_associative_arrays

# X.6: CLAUDE.md documents the GRINDER_SKIP_AUTH_PREFLIGHT knob and probe.
test_x6_claude_md_documents_knob() {
    grep -q 'GRINDER_SKIP_AUTH_PREFLIGHT' "$REPO_DIR/adapters/claude-code/claude/CLAUDE.md" \
        || { echo "  CLAUDE.md missing GRINDER_SKIP_AUTH_PREFLIGHT documentation"; return 1; }
    grep -q 'auth preflight\|preflight probe\|claude auth required' "$REPO_DIR/adapters/claude-code/claude/CLAUDE.md" \
        || { echo "  CLAUDE.md missing auth preflight description"; return 1; }
}
check "X.6: CLAUDE.md documents preflight + GRINDER_SKIP_AUTH_PREFLIGHT" test_x6_claude_md_documents_knob

# X.7: header tables list the new tunables (lib + grinder.sh).
test_x7_header_tables_list_tunables() {
    head -100 "$LIB" | grep -q 'AUTH_FAILED_EXIT_CODE' \
        || { echo "  AUTH_FAILED_EXIT_CODE missing from claude-session-lib.sh header table"; return 1; }
    head -100 "$GRINDER" | grep -q 'AUTH_PROBE_TIMEOUT_S\|GRINDER_SKIP_AUTH_PREFLIGHT' \
        || { echo "  AUTH_PROBE tunables missing from grinder.sh header table"; return 1; }
}
check "X.7: lib + grinder.sh headers list new tunables" test_x7_header_tables_list_tunables

# X.8: AUTH_PROBE_TIMEOUT_S default must be >= 15s. Real claude startup
# (model state load, API auth handshake, first-token latency) measures
# 3-10s typical on a warm cache and 10-15s on a cold cache. The original
# 5s default tripped legitimate operator runs on 2026-05-12 ("claude auth
# probe timed out after 5s"), forcing AUTH_PROBE_TIMEOUT_S=30 overrides
# from the shell. 15s gives realistic headroom while still failing fast
# on a truly broken auth state.
test_x8_default_timeout_realistic() {
    local default_line
    default_line=$(grep -E '^AUTH_PROBE_TIMEOUT_S=' "$GRINDER" | head -1)
    [[ -n "$default_line" ]] || { echo "  AUTH_PROBE_TIMEOUT_S default not found in $GRINDER"; return 1; }
    # Extract the numeric default from the parameter expansion
    # `${AUTH_PROBE_TIMEOUT_S:-NN}` form.
    local default_value
    default_value=$(echo "$default_line" | grep -oE ':-[0-9]+' | grep -oE '[0-9]+')
    [[ -n "$default_value" ]] || { echo "  could not parse default value from: $default_line"; return 1; }
    [[ "$default_value" -ge 15 ]] || {
        echo "  default AUTH_PROBE_TIMEOUT_S is ${default_value}s; must be >= 15s for real claude startup latency"
        return 1
    }
}
check "X.8: AUTH_PROBE_TIMEOUT_S default >= 15s (real claude startup is 3-15s)" test_x8_default_timeout_realistic

# =============================================================================
# Additional coverage scenarios surfaced by /qa
# =============================================================================

# C1.9: probe writes nothing under $HOME beyond what claude itself creates.
test_c1_9_no_home_writes() {
    setup
    # Mock claude that emits a clean success result event.
    cat > "$TEST_DIR/mock-bin/claude" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"system","subtype":"init","session_id":"ok"}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"k"}'
exit 0
EOF
    chmod +x "$TEST_DIR/mock-bin/claude"
    local baseline_after baseline_before
    # Snapshot the user-visible top-level $HOME mtimes before / after
    # (excluding $TMPDIR and Library — the probe is allowed to touch
    #  those via mktemp / claude's own state).
    baseline_before=$(find "$HOME" -maxdepth 2 -mtime -1 \
        -not -path "$HOME/Library/*" -not -path "$HOME/.cache/*" \
        -not -path "$HOME/.npm/*" 2>/dev/null | sort | head -100)
    PATH="$TEST_DIR/mock-bin:$PATH" call_grinder "auth_preflight_probe" >/dev/null 2>&1 || true
    baseline_after=$(find "$HOME" -maxdepth 2 -mtime -1 \
        -not -path "$HOME/Library/*" -not -path "$HOME/.cache/*" \
        -not -path "$HOME/.npm/*" 2>/dev/null | sort | head -100)
    # Probe-related writes should land in $TMPDIR (mktemp), not $HOME.
    local diff
    diff=$(comm -13 <(echo "$baseline_before") <(echo "$baseline_after") | grep -v '^$' || true)
    # Only fail if NEW $HOME entries appear that aren't already pre-existing
    # claude config dirs (~/.claude, ~/.config/claude). Be conservative.
    local stray
    stray=$(echo "$diff" | grep -v '\.claude' | grep -v '\.config/claude' | grep -v '^$' || true)
    [[ -z "$stray" ]] || { echo "  probe wrote unexpected files under HOME: $stray"; return 1; }
}
check "C1.9: probe writes nothing under \$HOME (R6.3)" test_c1_9_no_home_writes

# C5.5: hook is skipped when _classify_phase_exit reclassifies 124+result → 0.
# Verified at the helper boundary: passing exit_code=0 must skip the scan
# even if phase_ndjson contains an auth-failed shape (e.g., a watchdog
# kill of an already-finished phase that emitted an auth shape would NOT
# count as auth-failed because the phase finished cleanly).
test_c5_5_post_reclassification_zero_skip() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson"
    local out
    out=$(STREAM_FILE="$STREAM_FILE" call_lib "
_run_phase_auth_check 0 '$FIXTURES/auth_failed_not_logged_in.ndjson' 'pass' 'sid'
echo \"RC=\$?\"
")
    grep -q "^RC=0$" <<<"$out" || { echo "  expected RC=0 (post-reclassification skip), got: $out"; return 1; }
    [[ ! -s "$STREAM_FILE" ]] || { echo "  no event should be emitted when post-reclassification exit_code is 0"; return 1; }
}
check "C5.5: hook skipped when post-reclassification exit_code==0 (RK-4)" test_c5_5_post_reclassification_zero_skip

# C5.7: session_id from the C5 caller is propagated verbatim into the emitted
# event (the helper does not lose / mutate the sid).
test_c5_7_session_id_propagation() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson"
    local sid='abc-123-xyz-from-fixture'
    STREAM_FILE="$STREAM_FILE" call_lib "
_run_phase_auth_check 1 '$FIXTURES/auth_failed_not_logged_in.ndjson' 'pass-mech' '$sid'
"
    grep -q "\"session_id\":\"$sid\"" "$STREAM_FILE" \
        || { echo "  session_id '$sid' not in emitted event:"; cat "$STREAM_FILE"; return 1; }
}
check "C5.7: session_id propagates from caller to emitted event" test_c5_7_session_id_propagation

# C5.8: when the auth hook fires, run_phase returns the sentinel BEFORE the
# resume loop entry. Static check on the run_phase body: the auth-hook
# `return "$AUTH_FAILED_EXIT_CODE"` must appear before the `# Resume loop`
# section header that gates the resume invocation.
test_c5_8_sentinel_returned_before_resume_loop() {
    local hook_return resume_loop
    hook_return=$(awk '/^[[:space:]]*return "\$AUTH_FAILED_EXIT_CODE"/ {print NR; exit}' "$LIB")
    resume_loop=$(awk '/^[[:space:]]*# Resume loop:/ {print NR; exit}' "$LIB")
    [[ -n "$hook_return" && -n "$resume_loop" ]] \
        || { echo "  could not locate hook return ($hook_return) or resume loop ($resume_loop)"; return 1; }
    [[ "$hook_return" -lt "$resume_loop" ]] \
        || { echo "  hook return ($hook_return) must precede resume loop ($resume_loop)"; return 1; }
}
check "C5.8: sentinel returned before resume loop entry" test_c5_8_sentinel_returned_before_resume_loop

# C7.4: parent-shell proxy env survives the strip (the strip is local to the
# claude -p subprocess via env -u). Quick check: `env -u HTTPS_PROXY bash -c`
# does NOT unset HTTPS_PROXY from the calling shell — the subshell sees it
# unset, the parent shell still has it.
test_c7_4_parent_shell_env_preserved() {
    HTTPS_PROXY="mock-parent-proxy" bash -c '
        sub=$(env -u HTTPS_PROXY bash -c "echo \${HTTPS_PROXY:-EMPTY}")
        [[ "$sub" == "EMPTY" ]] || { echo "  env -u did not strip in subshell: $sub"; exit 1; }
        [[ "$HTTPS_PROXY" == "mock-parent-proxy" ]] || { echo "  parent shell HTTPS_PROXY mutated: $HTTPS_PROXY"; exit 1; }
    '
}
check "C7.4: parent-shell proxy env preserved across env -u (R2.2)" test_c7_4_parent_shell_env_preserved

# C2 (cmd_run / cmd_resume integration): static checks that the probe is
# wired into both subcommands and NOT into discover / pause / status /
# ack-review. End-to-end subprocess scenarios live in
# tests/test_grinder_orchestrator.sh which sets GRINDER_SKIP_AUTH_PREFLIGHT=1
# precisely because the probe call now sits in cmd_run; that mutual
# observation is the integration evidence.
test_c2_probe_wired_into_run() {
    awk '/^cmd_run\(\) \{/, /^\}$/' "$GRINDER" | grep -q 'auth_preflight_probe' \
        || { echo "  auth_preflight_probe not called inside cmd_run"; return 1; }
}
check "C2.1: auth_preflight_probe is called inside cmd_run (R1.1)" test_c2_probe_wired_into_run

test_c2_probe_wired_into_resume() {
    awk '/^cmd_resume\(\) \{/, /^\}$/' "$GRINDER" | grep -q 'auth_preflight_probe' \
        || { echo "  auth_preflight_probe not called inside cmd_resume"; return 1; }
}
check "C2.2: auth_preflight_probe is called inside cmd_resume (EC-G)" test_c2_probe_wired_into_resume

test_c2_probe_not_in_other_subcmds() {
    # Each of these subcommand bodies must NOT call the probe.
    local sub
    for sub in cmd_discover cmd_pause cmd_status cmd_ack_review; do
        if awk -v fn="^${sub}\\\\(\\\\) \\\\{" '$0 ~ fn, /^\}$/' "$GRINDER" | grep -q 'auth_preflight_probe'; then
            echo "  $sub MUST NOT invoke auth_preflight_probe (R1.8)"
            return 1
        fi
    done
}
check "C2.3-6: discover/pause/status/ack-review do NOT call probe (R1.8)" test_c2_probe_not_in_other_subcmds

# C2.7: probe must run AFTER pause-check (so PAUSE sentinel still wins).
# Static evidence: in cmd_run, the line that returns on PAUSE precedes the
# auth_preflight_probe call.
test_c2_7_probe_after_pause_check() {
    local pause_line probe_line
    awk '/^cmd_run\(\) \{/, /^\}$/' "$GRINDER" > "$TEST_DIR/cmd_run.txt"
    pause_line=$(grep -nE 'PAUSE|paused' "$TEST_DIR/cmd_run.txt" | head -1 | cut -d: -f1)
    probe_line=$(grep -n 'auth_preflight_probe' "$TEST_DIR/cmd_run.txt" | head -1 | cut -d: -f1)
    [[ -n "$pause_line" && -n "$probe_line" ]] \
        || { echo "  could not locate pause-check ($pause_line) or probe ($probe_line)"; return 1; }
    [[ "$pause_line" -lt "$probe_line" ]] \
        || { echo "  pause-check ($pause_line) must precede probe ($probe_line)"; return 1; }
}
check "C2.7: probe runs after pause-check (PAUSE wins)" test_c2_7_probe_after_pause_check

# C2.8: probe must run BEFORE acquire_grinder_lock so a failed probe does not
# hold a lock the trap then has to release.
test_c2_8_probe_before_lock() {
    local lock_line probe_line
    awk '/^cmd_run\(\) \{/, /^\}$/' "$GRINDER" > "$TEST_DIR/cmd_run.txt"
    probe_line=$(grep -n 'auth_preflight_probe' "$TEST_DIR/cmd_run.txt" | head -1 | cut -d: -f1)
    lock_line=$(grep -n 'acquire_grinder_lock' "$TEST_DIR/cmd_run.txt" | head -1 | cut -d: -f1)
    [[ -n "$probe_line" && -n "$lock_line" ]] \
        || { echo "  could not locate probe ($probe_line) or lock ($lock_line)"; return 1; }
    [[ "$probe_line" -lt "$lock_line" ]] \
        || { echo "  probe ($probe_line) must precede acquire_grinder_lock ($lock_line)"; return 1; }
}
check "C2.8: probe runs before acquire_grinder_lock (no lock leak on failed probe)" test_c2_8_probe_before_lock

# C4.8 (regression for the JSON-injection fix): values with quotes /
# backslashes / control characters must not corrupt the wire format.
test_c4_8_json_injection_safe() {
    setup
    STREAM_FILE="$TEST_DIR/stream.ndjson" call_lib '
_emit_auth_failed_event "phase\"with\"quotes" "sid\\with\\bks" "rsn-ok"
'
    # The line must be valid JSON.
    python3 -c '
import json, sys
content = open(sys.argv[1]).read().strip()
e = json.loads(content)
assert e["type"] == "auth_failed", e
assert e["phase"] == "phase\"with\"quotes", e
assert e["session_id"] == "sid\\with\\bks", e
' "$TEST_DIR/stream.ndjson" \
        || { echo "  emitted line is not valid JSON or fields not preserved:"; cat "$TEST_DIR/stream.ndjson"; return 1; }
}
check "C4.8: _emit_auth_failed_event is safe against quote/backslash injection" test_c4_8_json_injection_safe

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
