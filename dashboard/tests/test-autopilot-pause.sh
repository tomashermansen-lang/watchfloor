#!/usr/bin/env bash
# test-autopilot-pause.sh — integration + structural tests for the
# autopilot.PAUSE control file mechanism. Drives the stub fixture
# dashboard/tests/fixtures/autopilot-stub.sh through TC1-TC6 from
# REQUIREMENTS R11 and adds structural assertions for boundary
# placement, helper sourcing, and bash 3.2 portability.
#
# Exits 0 only when all assertions pass.
#
# Portability: bash 3.2 macOS-default. No mapfile, no ${var^^}, no
# top-level associative arrays.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/autopilot-stub.sh"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/autopilot-pause.sh"
AUTOPILOT_SH="$REPO_ROOT/adapters/claude-code/claude/tools/autopilot.sh"
RUN_ALL="$SCRIPT_DIR/run-all.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

check() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    printf '  FAIL: %s\n' "$name" >&2
  fi
}

# ── Helpers for assertions ──────────────────────────────────────────────

# assert_contains <file> <literal-substring>
assert_contains() {
  grep -F -q -- "$2" "$1"
}

# assert_not_contains <file> <literal-substring>
assert_not_contains() {
  ! grep -F -q -- "$2" "$1"
}

# new_tmp_workdir — returns a fresh mktemp -d into TC_DIR; trap-cleaned.
TMP_DIRS=()
TMP_BASE="${TMPDIR:-/tmp}"
new_tmp_workdir() {
  local d
  d=$(mktemp -d "${TMP_BASE%/}/autopilot-pause.XXXXXX")
  TMP_DIRS+=("$d")
  echo "$d"
}

cleanup_all() {
  local d
  for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup_all EXIT

run_fixture() {
  # Args: TC_DIR pause_before stdout_file stderr_file
  local tcd="$1"
  local pb="$2"
  local out="$3"
  local err="$4"
  local rc=0
  WORKDIR="$tcd" STUB_PAUSE_BEFORE="$pb" \
    bash "$FIXTURE" >"$out" 2>"$err" || rc=$?
  echo "$rc"
}

# ═══════════════════════════════════════════════════════════════════════
# TC1 — pause at boundary 2
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=$(run_fixture "$TC_DIR" "stub-phase-2" "$OUT" "$ERR")
  check "TC1: exit 0"                  test "$RC" -eq 0
  check "TC1: stdout has ran:stub-phase-1" assert_contains "$OUT" "ran:stub-phase-1"
  check "TC1: stdout missing ran:stub-phase-2" assert_not_contains "$OUT" "ran:stub-phase-2"
  check "TC1: stdout missing ran:stub-phase-3" assert_not_contains "$OUT" "ran:stub-phase-3"
  check "TC1: stderr has Paused at phase boundary stub-phase-2" \
    assert_contains "$ERR" "Paused at phase boundary stub-phase-2"
}

# ═══════════════════════════════════════════════════════════════════════
# TC2 — pause-absent
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=$(run_fixture "$TC_DIR" "" "$OUT" "$ERR")
  check "TC2: exit 0"                          test "$RC" -eq 0
  check "TC2: stdout has ran:stub-phase-1"     assert_contains "$OUT" "ran:stub-phase-1"
  check "TC2: stdout has ran:stub-phase-2"     assert_contains "$OUT" "ran:stub-phase-2"
  check "TC2: stdout has ran:stub-phase-3"     assert_contains "$OUT" "ran:stub-phase-3"
  check "TC2: stderr missing Paused"           assert_not_contains "$ERR" "Paused at phase boundary"
}

# ═══════════════════════════════════════════════════════════════════════
# TC3 — mid-phase creation (structural twin of TC1, asserts R6)
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=$(run_fixture "$TC_DIR" "stub-phase-2" "$OUT" "$ERR")
  check "TC3: exit 0"                          test "$RC" -eq 0
  check "TC3: stdout has ran:stub-phase-1"     assert_contains "$OUT" "ran:stub-phase-1"
  check "TC3: stdout missing ran:stub-phase-2" assert_not_contains "$OUT" "ran:stub-phase-2"
  check "TC3: stdout missing ran:stub-phase-3" assert_not_contains "$OUT" "ran:stub-phase-3"
  check "TC3: stderr has Paused at phase boundary stub-phase-2" \
    assert_contains "$ERR" "Paused at phase boundary stub-phase-2"
}

# ═══════════════════════════════════════════════════════════════════════
# TC4 — stale pause at session start (drives _stale_pause_cleanup from
# the real lib + the three phase blocks inline)
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  touch "$TC_DIR/autopilot.PAUSE"

  DRIVER="$TC_DIR/tc4-driver.sh"
  cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${WORKDIR:?}"
log() { printf '%s\n' "$*" >&2; }
dashboard_event() { :; }
source "$1"  # lib path passed as $1
_stale_pause_cleanup
check_pause_file "stub-phase-1"; echo "ran:stub-phase-1"
check_pause_file "stub-phase-2"; echo "ran:stub-phase-2"
check_pause_file "stub-phase-3"; echo "ran:stub-phase-3"
DRIVER_EOF

  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=0
  WORKDIR="$TC_DIR" bash "$DRIVER" "$LIB" >"$OUT" 2>"$ERR" || RC=$?

  check "TC4: exit 0"                          test "$RC" -eq 0
  check "TC4: stdout has ran:stub-phase-1"     assert_contains "$OUT" "ran:stub-phase-1"
  check "TC4: stdout has ran:stub-phase-2"     assert_contains "$OUT" "ran:stub-phase-2"
  check "TC4: stdout has ran:stub-phase-3"     assert_contains "$OUT" "ran:stub-phase-3"
  check "TC4: stderr has Stale autopilot.PAUSE detected" \
    assert_contains "$ERR" "Stale autopilot.PAUSE detected"
  check "TC4: PAUSE file removed after run"    test ! -e "$TC_DIR/autopilot.PAUSE"
}

# ═══════════════════════════════════════════════════════════════════════
# TC5 — pause file is a directory
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  mkdir "$TC_DIR/autopilot.PAUSE"
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=$(run_fixture "$TC_DIR" "" "$OUT" "$ERR")
  check "TC5: exit 0"                          test "$RC" -eq 0
  check "TC5: stdout has ran:stub-phase-1"     assert_contains "$OUT" "ran:stub-phase-1"
  check "TC5: stdout has ran:stub-phase-2"     assert_contains "$OUT" "ran:stub-phase-2"
  check "TC5: stdout has ran:stub-phase-3"     assert_contains "$OUT" "ran:stub-phase-3"
  check "TC5: stderr missing Paused"           assert_not_contains "$ERR" "Paused at phase boundary"
}

# ═══════════════════════════════════════════════════════════════════════
# TC6 — pause between phase 2 and phase 3 (host plan acceptance #5 literal)
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=$(run_fixture "$TC_DIR" "stub-phase-3" "$OUT" "$ERR")
  check "TC6: exit 0"                          test "$RC" -eq 0
  check "TC6: stdout has ran:stub-phase-1"     assert_contains "$OUT" "ran:stub-phase-1"
  check "TC6: stdout has ran:stub-phase-2"     assert_contains "$OUT" "ran:stub-phase-2"
  check "TC6: stdout missing ran:stub-phase-3" assert_not_contains "$OUT" "ran:stub-phase-3"
  check "TC6: stderr has Paused at phase boundary stub-phase-3" \
    assert_contains "$ERR" "Paused at phase boundary stub-phase-3"
}

# ═══════════════════════════════════════════════════════════════════════
# T1.4 — symlink to a regular file fires the pause path
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  TARGET=$(mktemp "${TMP_BASE%/}/autopilot-pause-target.XXXXXX")
  ln -s "$TARGET" "$TC_DIR/autopilot.PAUSE"
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=$(run_fixture "$TC_DIR" "" "$OUT" "$ERR")
  check "T1.4 symlink-to-file: exit 0"         test "$RC" -eq 0
  check "T1.4 symlink-to-file: stub-phase-2 did not run" \
    assert_not_contains "$OUT" "ran:stub-phase-2"
  check "T1.4 symlink-to-file: stderr has Paused" \
    assert_contains "$ERR" "Paused at phase boundary stub-phase-1"
  rm -f "$TARGET"
}

# ═══════════════════════════════════════════════════════════════════════
# T1.5 — symlink to a directory does NOT fire the pause path
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  TARGET_DIR=$(mktemp -d "${TMP_BASE%/}/autopilot-pause-tgtdir.XXXXXX")
  TMP_DIRS+=("$TARGET_DIR")
  ln -s "$TARGET_DIR" "$TC_DIR/autopilot.PAUSE"
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=$(run_fixture "$TC_DIR" "" "$OUT" "$ERR")
  check "T1.5 symlink-to-dir: exit 0"          test "$RC" -eq 0
  check "T1.5 symlink-to-dir: stub-phase-3 ran" \
    assert_contains "$OUT" "ran:stub-phase-3"
  check "T1.5 symlink-to-dir: stderr missing Paused" \
    assert_not_contains "$ERR" "Paused at phase boundary"
}

# ═══════════════════════════════════════════════════════════════════════
# T1.6 — pause file has non-empty content; helper still fires
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  echo "operator pasted note" > "$TC_DIR/autopilot.PAUSE"
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=$(run_fixture "$TC_DIR" "" "$OUT" "$ERR")
  check "T1.6 non-empty: exit 0"               test "$RC" -eq 0
  check "T1.6 non-empty: stderr has Paused stub-phase-1" \
    assert_contains "$ERR" "Paused at phase boundary stub-phase-1"
}

# ═══════════════════════════════════════════════════════════════════════
# T1.8 — WORKDIR unset under set -u fails loudly
# ═══════════════════════════════════════════════════════════════════════
{
  RC=0
  bash -c "set -euo pipefail; source '$LIB'; check_pause_file foo" >/dev/null 2>&1 || RC=$?
  check "T1.8: WORKDIR unset → non-zero exit"  test "$RC" -ne 0
}

# ═══════════════════════════════════════════════════════════════════════
# TX2 — SessionEnd lifecycle parity: dashboard_event called with the
# expected argv triple on pause path.
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  EVENT_LOG="$TC_DIR/events.log"
  : > "$EVENT_LOG"
  touch "$TC_DIR/autopilot.PAUSE"
  OUT="$TC_DIR/out"; ERR="$TC_DIR/err"
  RC=0
  WORKDIR="$TC_DIR" DASHBOARD_EVENT_LOG="$EVENT_LOG" \
    bash "$FIXTURE" >"$OUT" 2>"$ERR" || RC=$?
  check "TX2: exit 0"                          test "$RC" -eq 0
  check "TX2: dashboard_event captured SessionEnd autopilot paused at stub-phase-1" \
    grep -F -q "SessionEnd autopilot paused at stub-phase-1" "$EVENT_LOG"
}

# ═══════════════════════════════════════════════════════════════════════
# TX3 — No observable latency: lib body has no sleep/curl/find/git
# ═══════════════════════════════════════════════════════════════════════
{
  check "TX3: lib has no sleep"    bash -c "! grep -E -q '(^|[[:space:]])sleep([[:space:]]|$)' '$LIB'"
  check "TX3: lib has no curl"     bash -c "! grep -E -q '(^|[[:space:]])curl([[:space:]]|$)' '$LIB'"
  check "TX3: lib has no find"     bash -c "! grep -E -q '(^|[[:space:]])find([[:space:]]|\$)' '$LIB'"
  check "TX3: lib has no git"      bash -c "! grep -E -q '(^|[[:space:]])git([[:space:]]|\$)' '$LIB'"
}

# ═══════════════════════════════════════════════════════════════════════
# T2.1 — every existing phase_enabled block has check_pause_file as
# its first executable statement, with matching phase name.
# T2.3 — argument == phase_enabled predicate value.
# ═══════════════════════════════════════════════════════════════════════
{
  # Extract pairs: phase_enabled "X" → next non-blank, non-comment line.
  # Awk over autopilot.sh, in bash 3.2-safe form.
  PAIRS_FILE="$(mktemp "${TMP_BASE%/}/autopilot-pause-pairs.XXXXXX")"
  awk '
    /if phase_enabled "[^"]+"; then/ {
      match($0, /"[^"]+"/)
      pred = substr($0, RSTART+1, RLENGTH-2)
      getline nxt
      # Strip leading whitespace
      sub(/^[ \t]+/, "", nxt)
      print pred " | " nxt
    }
  ' "$AUTOPILOT_SH" > "$PAIRS_FILE"

  EXPECTED_PHASES="ba plan testplan review implement qa static-analysis commit"
  for ph in $EXPECTED_PHASES; do
    # Find the row for this phase, assert the first line matches
    # check_pause_file "ph".
    line=$(grep -E "^${ph} \| " "$PAIRS_FILE" || true)
    expected_call='check_pause_file "'"${ph}"'"'
    matches_call() { case "$line" in *"$expected_call"*) return 0;; *) return 1;; esac; }
    check "T2.1/T2.3: phase '${ph}' block starts with ${expected_call}" matches_call
  done
  rm -f "$PAIRS_FILE"
}

# ═══════════════════════════════════════════════════════════════════════
# T2.2 — default-mode else branch (/done) has check_pause_file "done"
# as its first executable statement.
# ═══════════════════════════════════════════════════════════════════════
{
  # Look for the else branch around line ~1379 and the run_phase /done call.
  # Search the 5 lines after `else` for `check_pause_file "done"`.
  check "T2.2: done block starts with check_pause_file \"done\"" \
    bash -c '
      awk "
        /^else\$/ { found=1; lines=0; next }
        found && lines < 5 {
          if (\$0 ~ /check_pause_file \"done\"/) { print \"MATCH\"; exit 0 }
          lines++
        }
      " "'"$AUTOPILOT_SH"'" | grep -q MATCH
    '
}

# ═══════════════════════════════════════════════════════════════════════
# T2.5 / T4.4 — autopilot.sh and the fixture source the lib; neither
# redefines check_pause_file inline.
# ═══════════════════════════════════════════════════════════════════════
{
  check "T2.5: autopilot.sh sources lib/autopilot-pause.sh" \
    bash -c "grep -E -q 'source.*lib/autopilot-pause\\.sh' '$AUTOPILOT_SH'"
  check "T2.5: autopilot.sh has no inline check_pause_file() definition" \
    bash -c "! grep -E -q '^check_pause_file *\\(\\)' '$AUTOPILOT_SH'"
  check "T4.4: fixture sources lib/autopilot-pause.sh" \
    bash -c "grep -E -q 'source.*lib/autopilot-pause\\.sh' '$FIXTURE'"
  check "T4.4: fixture has no inline check_pause_file() definition" \
    bash -c "! grep -E -q '^check_pause_file *\\(\\)' '$FIXTURE'"
}

# ═══════════════════════════════════════════════════════════════════════
# T4.5 — fixture defines log/dashboard_event stubs before sourcing the lib.
# ═══════════════════════════════════════════════════════════════════════
{
  log_line=$(grep -n '^log() *{' "$FIXTURE" | head -1 | cut -d: -f1)
  evt_line=$(grep -n '^dashboard_event() *{' "$FIXTURE" | head -1 | cut -d: -f1)
  src_line=$(grep -n 'source .*lib/autopilot-pause\.sh' "$FIXTURE" | head -1 | cut -d: -f1)
  check "T4.5: log() defined before source" \
    bash -c "test -n '$log_line' && test -n '$src_line' && test '$log_line' -lt '$src_line'"
  check "T4.5: dashboard_event() defined before source" \
    bash -c "test -n '$evt_line' && test -n '$src_line' && test '$evt_line' -lt '$src_line'"
}

# ═══════════════════════════════════════════════════════════════════════
# T4.6 — fixture never invokes claude -p / git / tmux / gtimeout.
# ═══════════════════════════════════════════════════════════════════════
{
  # Strip comments and blank lines before scanning so the file header,
  # which DOCUMENTS that the fixture never invokes those tools, is not
  # itself flagged as an invocation.
  FIXTURE_NOCOMMENT="$(mktemp "${TMP_BASE%/}/fixture-nocomment.XXXXXX")"
  grep -vE '^[[:space:]]*(#|$)' "$FIXTURE" > "$FIXTURE_NOCOMMENT"
  check "T4.6: fixture has no 'claude -p' call" \
    bash -c "! grep -E -q 'claude -p' '$FIXTURE_NOCOMMENT'"
  check "T4.6: fixture has no top-level 'git ' call" \
    bash -c "! grep -E -q '^[[:space:]]*git ' '$FIXTURE_NOCOMMENT'"
  check "T4.6: fixture has no top-level 'tmux ' call" \
    bash -c "! grep -E -q '^[[:space:]]*tmux ' '$FIXTURE_NOCOMMENT'"
  check "T4.6: fixture has no gtimeout call" \
    bash -c "! grep -E -q 'gtimeout' '$FIXTURE_NOCOMMENT'"
  rm -f "$FIXTURE_NOCOMMENT"
}

# ═══════════════════════════════════════════════════════════════════════
# T6.1 / T6.3 — run-all.sh registration.
# ═══════════════════════════════════════════════════════════════════════
{
  check "T6.1: run-all.sh registers test-autopilot-pause.sh" \
    bash -c "grep -E -q 'test-autopilot-pause\\.sh' '$RUN_ALL'"
  # T6.3: pause entry follows parser entry on consecutive lines.
  parser_line=$(grep -n 'test-autopilot-parser\.sh' "$RUN_ALL" | head -1 | cut -d: -f1 || true)
  pause_line=$(grep -n 'test-autopilot-pause\.sh' "$RUN_ALL" | head -1 | cut -d: -f1 || true)
  adjacent_check() {
    [[ -n "$parser_line" && -n "$pause_line" ]] || return 1
    [[ $((pause_line - parser_line)) -eq 1 ]]
  }
  check "T6.3: pause registration adjacent to parser entry" adjacent_check
}

# ═══════════════════════════════════════════════════════════════════════
# T7.* — header documentation in autopilot.sh
# ═══════════════════════════════════════════════════════════════════════
{
  check "T7.1: header has 'Pause control' section" \
    bash -c "head -80 '$AUTOPILOT_SH' | grep -F -q 'Pause control'"
  check "T7.2: header references chain.PAUSE symmetry" \
    bash -c "head -80 '$AUTOPILOT_SH' | grep -F -q 'chain.PAUSE'"
  check "T7.3: header describes stale-file cleanup" \
    bash -c "head -80 '$AUTOPILOT_SH' | grep -i -E -q 'stale|leftover'"
  check "T7.4: header shows 'touch autopilot.PAUSE'" \
    bash -c "head -80 '$AUTOPILOT_SH' | grep -F -q 'touch autopilot.PAUSE'"
}

# ═══════════════════════════════════════════════════════════════════════
# TX5 — CLAUDE.md § Layout lists autopilot-pause.sh
# ═══════════════════════════════════════════════════════════════════════
{
  CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
  check "TX5: CLAUDE.md lists autopilot-pause.sh in lib enumeration" \
    bash -c "grep -F -q 'autopilot-pause.sh' '$CLAUDE_MD'"
}

# ═══════════════════════════════════════════════════════════════════════
# T5.7 — bash 3.2 portability: no mapfile / readarray / ${var^^}
# ═══════════════════════════════════════════════════════════════════════
{
  # Check the production code paths (lib + fixture) for bash 3.2 cleanliness.
  # The test script itself names these constructs in its own diagnostic
  # strings, so it is excluded from the self-check.
  for f in "$LIB" "$FIXTURE"; do
    check "T5.7: $(basename "$f") has no mapfile call" \
      bash -c "! grep -E -q '(^|[[:space:]])mapfile([[:space:]]|$)' '$f'"
    check "T5.7: $(basename "$f") has no readarray call" \
      bash -c "! grep -E -q '(^|[[:space:]])readarray([[:space:]]|$)' '$f'"
    check "T5.7: $(basename "$f") has no \${var^^} uppercasing" \
      bash -c "! grep -E -q '\\\$\\{[A-Za-z_][A-Za-z0-9_]*\\^\\^\\}' '$f'"
  done
}

# ═══════════════════════════════════════════════════════════════════════
# TC-STOP-1 — stop_after_phase_exit invokes write_summary with status=partial
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  CAPTURE="$TC_DIR/capture.log"
  : > "$CAPTURE"
  DRIVER="$TC_DIR/driver.sh"
  cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -uo pipefail
LIB_PATH="$1"
CAPTURE="$2"
log() { printf 'log %s\n' "$*" >> "$CAPTURE"; }
dashboard_event() { printf 'dashboard_event %s|%s|%s\n' "$1" "$2" "${3:-}" >> "$CAPTURE"; }
write_summary() { printf 'write_summary STATUS=%s\n' "${PIPELINE_STATUS:-}" >> "$CAPTURE"; }
lifecycle_emit_paused() { printf 'lifecycle_emit_paused %s|%s|%s\n' "$1" "$2" "$3" >> "$CAPTURE"; }
track_phase() { printf 'track_phase %s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$CAPTURE"; }
WORKDIR="$TC_DIR"
STREAM_FILE="$TC_DIR/stream.ndjson"
TASK="demo-task"
SUMMARY_FILE="$TC_DIR/summary.json"
declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=()
declare -a PHASE_ARTIFACTS=() PHASE_COSTS=()
MAIN_DIR="$TC_DIR"
BRANCH="feature/demo"
START_TS="2026-05-20T00:00:00Z"
TOTAL_START=1700000000
PIPELINE_STATUS="success"
source "$LIB_PATH"
stop_after_phase_exit "implement"
echo "POST-EXIT-NEVER-RUN" >> "$CAPTURE"
DRIVER_EOF
  RC=0
  TC_DIR="$TC_DIR" bash "$DRIVER" "$LIB" "$CAPTURE" >/dev/null 2>&1 || RC=$?
  check "TC-STOP-1: exit 0"                       test "$RC" -eq 0
  check "TC-STOP-1: write_summary called with STATUS=partial" \
    assert_contains "$CAPTURE" "write_summary STATUS=partial"
  check "TC-STOP-1: lifecycle_emit_paused called with implement" \
    assert_contains "$CAPTURE" "lifecycle_emit_paused $TC_DIR/stream.ndjson|demo-task|implement"
  check "TC-STOP-1: dashboard_event SessionEnd autopilot stopped after implement" \
    assert_contains "$CAPTURE" "dashboard_event SessionEnd|autopilot|stopped after implement"
  check "TC-STOP-1: script exited before POST-EXIT-NEVER-RUN" \
    assert_not_contains "$CAPTURE" "POST-EXIT-NEVER-RUN"
}

# ═══════════════════════════════════════════════════════════════════════
# TC-STOP-2 — worktree directory + task dir survive helper invocation
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  CAPTURE="$TC_DIR/capture.log"
  : > "$CAPTURE"
  DRIVER="$TC_DIR/driver.sh"
  cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -uo pipefail
LIB_PATH="$1"
CAPTURE="$2"
log() { :; }
dashboard_event() { :; }
write_summary() { :; }
lifecycle_emit_paused() { :; }
track_phase() { :; }
WORKDIR="$TC_DIR"
STREAM_FILE="$TC_DIR/stream.ndjson"
TASK="demo-task"
SUMMARY_FILE="$TC_DIR/summary.json"
declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=()
declare -a PHASE_ARTIFACTS=() PHASE_COSTS=()
MAIN_DIR="$TC_DIR"
BRANCH="feature/demo"
START_TS="2026-05-20T00:00:00Z"
TOTAL_START=1700000000
PIPELINE_STATUS="success"
source "$LIB_PATH"
stop_after_phase_exit "ba"
DRIVER_EOF
  RC=0
  TC_DIR="$TC_DIR" bash "$DRIVER" "$LIB" "$CAPTURE" >/dev/null 2>&1 || RC=$?
  check "TC-STOP-2: WORKDIR still exists after helper"   test -d "$TC_DIR"
}

# ═══════════════════════════════════════════════════════════════════════
# TC-STOP-3 — helper body has no cleanup_worktree / rm -rf references
# ═══════════════════════════════════════════════════════════════════════
{
  check "TC-STOP-3: helper body never calls cleanup_worktree" \
    bash -c "! grep -E -q 'cleanup_worktree' '$LIB'"
  check "TC-STOP-3: helper body never calls rm -rf" \
    bash -c "! grep -E -q 'rm -rf' '$LIB'"
}

# ═══════════════════════════════════════════════════════════════════════
# TC-STOP-4 — helper resume hint references --from <next-phase>
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  CAPTURE="$TC_DIR/capture.log"
  : > "$CAPTURE"
  DRIVER="$TC_DIR/driver.sh"
  cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -uo pipefail
LIB_PATH="$1"
CAPTURE="$2"
log() { printf 'log %s\n' "$*" >> "$CAPTURE"; }
dashboard_event() { :; }
write_summary() { :; }
lifecycle_emit_paused() { :; }
track_phase() { :; }
WORKDIR="$TC_DIR"
STREAM_FILE="$TC_DIR/stream.ndjson"
TASK="demo-task"
SUMMARY_FILE="$TC_DIR/summary.json"
declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=()
declare -a PHASE_ARTIFACTS=() PHASE_COSTS=()
MAIN_DIR="$TC_DIR"
BRANCH="feature/demo"
START_TS="2026-05-20T00:00:00Z"
TOTAL_START=1700000000
PIPELINE_STATUS="success"
source "$LIB_PATH"
stop_after_phase_exit "implement"
DRIVER_EOF
  TC_DIR="$TC_DIR" bash "$DRIVER" "$LIB" "$CAPTURE" >/dev/null 2>&1 || true
  check "TC-STOP-4: banner mentions Resume" \
    bash -c "grep -F -q 'Resume' '$CAPTURE'"
  check "TC-STOP-4: banner mentions --from qa (next phase after implement)" \
    bash -c "grep -F -q -- '--from qa' '$CAPTURE'"
}

# ═══════════════════════════════════════════════════════════════════════
# TC-STOP-5 — invocation on last phase (commit): no resume hint with next
# ═══════════════════════════════════════════════════════════════════════
{
  TC_DIR=$(new_tmp_workdir)
  CAPTURE="$TC_DIR/capture.log"
  : > "$CAPTURE"
  DRIVER="$TC_DIR/driver.sh"
  cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -uo pipefail
LIB_PATH="$1"
CAPTURE="$2"
log() { printf 'log %s\n' "$*" >> "$CAPTURE"; }
dashboard_event() { :; }
write_summary() { printf 'write_summary STATUS=%s\n' "${PIPELINE_STATUS:-}" >> "$CAPTURE"; }
lifecycle_emit_paused() { :; }
track_phase() { :; }
WORKDIR="$TC_DIR"
STREAM_FILE="$TC_DIR/stream.ndjson"
TASK="demo-task"
SUMMARY_FILE="$TC_DIR/summary.json"
declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=()
declare -a PHASE_ARTIFACTS=() PHASE_COSTS=()
MAIN_DIR="$TC_DIR"
BRANCH="feature/demo"
START_TS="2026-05-20T00:00:00Z"
TOTAL_START=1700000000
PIPELINE_STATUS="success"
source "$LIB_PATH"
stop_after_phase_exit "commit"
DRIVER_EOF
  RC=0
  TC_DIR="$TC_DIR" bash "$DRIVER" "$LIB" "$CAPTURE" >/dev/null 2>&1 || RC=$?
  check "TC-STOP-5: exit 0 on last phase (commit)" test "$RC" -eq 0
  check "TC-STOP-5: write_summary STATUS=partial on commit stop" \
    assert_contains "$CAPTURE" "write_summary STATUS=partial"
}

# ═══════════════════════════════════════════════════════════════════════
# TC-STOP-6 — lib body bash 3.2 portability (no mapfile, no nameref)
# ═══════════════════════════════════════════════════════════════════════
{
  check "TC-STOP-6: lib body has no mapfile" \
    bash -c "! grep -E -q '(^|[[:space:]])mapfile([[:space:]]|$)' '$LIB'"
  check "TC-STOP-6: lib body has no readarray" \
    bash -c "! grep -E -q '(^|[[:space:]])readarray([[:space:]]|$)' '$LIB'"
  check "TC-STOP-6: lib body has no \${var^^}" \
    bash -c "! grep -E -q '\\\$\\{[A-Za-z_][A-Za-z0-9_]*\\^\\^\\}' '$LIB'"
}

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "---"
printf "Checks: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" $((PASS + FAIL))
if [[ "$FAIL" -ne 0 ]]; then
  printf "Failed: %s\n" "${FAILED_NAMES[*]}"
  exit 1
fi
echo "All autopilot pause tests passed."
exit 0
