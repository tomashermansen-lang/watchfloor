#!/usr/bin/env bash
# test-lifecycle-bash-emitters.sh — cross-validation integration test
# for the bash-side lifecycle emitters (R1-R6, R10).
#
# Every NDJSON line produced by the production emit code paths in
#   adapters/claude-code/claude/tools/lib/lifecycle-emit.sh
#   adapters/claude-code/claude/tools/lib/autopilot-pause.sh (via autopilot-stub.sh)
#   dashboard/tests/fixtures/autopilot-chain-stub.sh (mirrors C4-C6 in autopilot-chain.sh)
# is piped through dashboard.server.lifecycle_events.parse_event. Any
# drift between the bash printf format strings and the Python validator
# fails this test (R10).
#
# Six scenarios SC1-SC6, one per R1/R2/R3/R4/R5/R6. Output convention
# mirrors test-autopilot-pause.sh: PASS/FAIL per check, final summary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/lifecycle-emit.sh"
AUTOPILOT_STUB="$SCRIPT_DIR/fixtures/autopilot-stub.sh"
CHAIN_STUB="$SCRIPT_DIR/fixtures/autopilot-chain-stub.sh"
PY="$REPO_ROOT/.venv/bin/python"

if [[ ! -x "$PY" ]]; then
  echo "ERROR: $PY not found — run 'uv sync --extra dev' from $REPO_ROOT" >&2
  exit 1
fi

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

assert_contains() {
  grep -F -q -- "$2" "$1"
}

assert_not_contains() {
  ! grep -F -q -- "$2" "$1"
}

# Validate every lifecycle line in $1 with parse_event. Optional $2..
# is the expected action; if provided, every line's action must match.
parse_lines() {
  local file="$1" expected_action="${2:-}"
  "$PY" - "$file" "$expected_action" <<'PY' >/dev/null 2>&1
import sys
sys.path.insert(0, "dashboard")
from server.lifecycle_events import parse_event
path, expected = sys.argv[1], sys.argv[2]
seen = 0
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line or "lifecycle" not in line:
            continue
        ev = parse_event(line)
        if expected and ev["action"] != expected:
            sys.exit(f"action mismatch: expected {expected}, got {ev['action']}")
        seen += 1
if seen == 0:
    sys.exit("no lifecycle lines parsed")
PY
}

# parse_one — extracts the first lifecycle line and asserts it matches
# expected action AND target. Returns 0 on success, 1 on mismatch.
parse_one() {
  local file="$1" expected_action="$2" expected_target="$3"
  "$PY" - "$file" "$expected_action" "$expected_target" <<'PY' >/dev/null 2>&1
import sys
sys.path.insert(0, "dashboard")
from server.lifecycle_events import parse_event
path, expected_action, expected_target = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line or "lifecycle" not in line:
            continue
        ev = parse_event(line)
        if ev["action"] != expected_action:
            sys.exit(f"action mismatch: {ev['action']!r} != {expected_action!r}")
        if ev["target"] != expected_target:
            sys.exit(f"target mismatch: {ev['target']!r} != {expected_target!r}")
        sys.exit(0)
sys.exit("no lifecycle line found")
PY
}

TMP_DIRS=()
TMP_BASE="${TMPDIR:-/tmp}"
new_tmp_dir() {
  local d
  d=$(mktemp -d "${TMP_BASE%/}/lifecycle-emit.XXXXXX")
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

# Disable history expansion so `!` in conditions doesn't trip up bash.
set +H || true

# ═══════════════════════════════════════════════════════════════════════
# SC1 — R1 — lifecycle_emit_started writes one line with action=started
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  STREAM="$TC/stream.ndjson"
  : > "$STREAM"
  (
    # Run in subshell so source doesn't pollute outer.
    set +H
    source "$LIB"
    unset CONTROL_SOURCE
    lifecycle_emit_started "$STREAM" "demo-feature"
  )
  check "SC1: one line emitted"                test "$(wc -l < "$STREAM")" -eq 1
  check "SC1: action=started"                  assert_contains "$STREAM" '"action":"started"'
  check "SC1: target=demo-feature"             assert_contains "$STREAM" '"target":"demo-feature"'
  check "SC1: source=cli (default)"            assert_contains "$STREAM" '"source":"cli"'
  check "SC1: parse_event accepts"             parse_one "$STREAM" "started" "demo-feature"
}

# ═══════════════════════════════════════════════════════════════════════
# SC1b — CONTROL_SOURCE=dashboard propagates (R7, AS10)
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  STREAM="$TC/stream.ndjson"
  : > "$STREAM"
  (
    set +H
    source "$LIB"
    CONTROL_SOURCE=dashboard lifecycle_emit_started "$STREAM" "demo-feature"
  )
  check "SC1b: source=dashboard"               assert_contains "$STREAM" '"source":"dashboard"'
  check "SC1b: not source=cli"                 assert_not_contains "$STREAM" '"source":"cli"'
  check "SC1b: parse_event accepts"            parse_one "$STREAM" "started" "demo-feature"
}

# ═══════════════════════════════════════════════════════════════════════
# SC1c — bogus CONTROL_SOURCE is written verbatim and rejected downstream
#         (R7, T-C0-07, X-06 — verifies "visible failure beats silent coercion")
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  STREAM="$TC/stream.ndjson"
  : > "$STREAM"
  (
    set +H
    source "$LIB"
    CONTROL_SOURCE=dashbord lifecycle_emit_started "$STREAM" "demo-feature"
  )
  check "SC1c: bogus source written verbatim"  assert_contains "$STREAM" '"source":"dashbord"'
  # parse_event must REJECT this line — the test passes when parse_one fails.
  if parse_one "$STREAM" "started" "demo-feature" 2>/dev/null; then
    PASS_=false
  else
    PASS_=true
  fi
  check "SC1c: parse_event rejects bogus source" test "$PASS_" = "true"
}

# ═══════════════════════════════════════════════════════════════════════
# SC2 — R2 — three phase_complete emits, one per phase
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  STREAM="$TC/stream.ndjson"
  : > "$STREAM"
  (
    set +H
    source "$LIB"
    for ph in ba plan testplan; do
      lifecycle_emit_phase_complete "$STREAM" "demo-feature" "$ph"
    done
  )
  check "SC2: three lines"                     test "$(wc -l < "$STREAM")" -eq 3
  check "SC2: phase=ba present"                assert_contains "$STREAM" '"phase":"ba"'
  check "SC2: phase=plan present"              assert_contains "$STREAM" '"phase":"plan"'
  check "SC2: phase=testplan present"          assert_contains "$STREAM" '"phase":"testplan"'
  check "SC2: no long display name"            assert_not_contains "$STREAM" '"phase":"Business Analysis"'
  check "SC2: parse_event accepts all"         parse_lines "$STREAM" "phase_complete"
}

# ═══════════════════════════════════════════════════════════════════════
# SC3 — R3 — paused emit via autopilot-stub.sh + check_pause_file
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  STREAM="$TC/stream.ndjson"
  : > "$STREAM"
  ERR="$TC/err"
  WORKDIR="$TC" STUB_PAUSE_BEFORE="stub-phase-2" \
    TASK="stub-feature" STREAM_FILE="$STREAM" \
    bash "$AUTOPILOT_STUB" >/dev/null 2>"$ERR" || true
  check "SC3: action=paused present"           assert_contains "$STREAM" '"action":"paused"'
  check "SC3: phase_at_pause=stub-phase-2"     assert_contains "$STREAM" '"phase_at_pause":"stub-phase-2"'
  check "SC3: target=stub-feature"             assert_contains "$STREAM" '"target":"stub-feature"'
  check "SC3: parse_event accepts"             parse_one "$STREAM" "paused" "stub-feature"
  check "SC3: existing log line preserved"     assert_contains "$ERR" "Paused at phase boundary stub-phase-2"
}

# ═══════════════════════════════════════════════════════════════════════
# SC3b — paused NOT emitted when PAUSE absent (T-C3-05)
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  STREAM="$TC/stream.ndjson"
  : > "$STREAM"
  WORKDIR="$TC" TASK="stub-feature" STREAM_FILE="$STREAM" \
    bash "$AUTOPILOT_STUB" >/dev/null 2>/dev/null
  check "SC3b: no lifecycle line when no PAUSE" assert_not_contains "$STREAM" '"action":"paused"'
}

# ═══════════════════════════════════════════════════════════════════════
# SC4 — R4 — chain `started` lifecycle emit + plan_id derivation
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  EVENTS="$TC/chain-events.ndjson"
  : > "$EVENTS"
  WORKDIR="$TC" PLAN_DIR_BASENAME="INPROGRESS_Plan_demo-plan" \
    EVENTS_FILE="$EVENTS" STUB_TRIGGER="started" \
    bash "$CHAIN_STUB" >/dev/null 2>/dev/null
  check "SC4: action=started present"          assert_contains "$EVENTS" '"action":"started"'
  check "SC4: target=demo-plan (stripped)"     assert_contains "$EVENTS" '"target":"demo-plan"'
  check "SC4: parse_event accepts"             parse_one "$EVENTS" "started" "demo-plan"
}

# ═══════════════════════════════════════════════════════════════════════
# SC4b — DONE_Plan_ prefix stripped (T-C4-03)
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  EVENTS="$TC/chain-events.ndjson"
  : > "$EVENTS"
  WORKDIR="$TC" PLAN_DIR_BASENAME="DONE_Plan_demo-plan" \
    EVENTS_FILE="$EVENTS" STUB_TRIGGER="started" \
    bash "$CHAIN_STUB" >/dev/null 2>/dev/null
  check "SC4b: target=demo-plan (DONE stripped)" assert_contains "$EVENTS" '"target":"demo-plan"'
}

# ═══════════════════════════════════════════════════════════════════════
# SC4c — AS9 negative path — invalid plan_id silences emits + WARNING
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  EVENTS="$TC/chain-events.ndjson"
  : > "$EVENTS"
  ERR="$TC/err"
  WORKDIR="$TC" PLAN_DIR_BASENAME="bad name" \
    EVENTS_FILE="$EVENTS" STUB_TRIGGER="started" \
    bash "$CHAIN_STUB" >/dev/null 2>"$ERR"
  check "SC4c: stderr contains WARNING"        assert_contains "$ERR" "WARNING: chain plan_id"
  check "SC4c: events file has no lifecycle"   assert_not_contains "$EVENTS" '"type":"lifecycle"'
}

# ═══════════════════════════════════════════════════════════════════════
# SC5 — R5 — chain phase_complete after gate_passed
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  EVENTS="$TC/chain-events.ndjson"
  : > "$EVENTS"
  WORKDIR="$TC" PLAN_DIR_BASENAME="INPROGRESS_Plan_demo-plan" \
    EVENTS_FILE="$EVENTS" STUB_TRIGGER="phase_complete" \
    STUB_PHASE_ID="backend-substrate" \
    bash "$CHAIN_STUB" >/dev/null 2>/dev/null
  check "SC5: gate_passed event present"       assert_contains "$EVENTS" '"event":"gate_passed"'
  check "SC5: lifecycle phase_complete"        assert_contains "$EVENTS" '"action":"phase_complete"'
  check "SC5: phase=backend-substrate"         assert_contains "$EVENTS" '"phase":"backend-substrate"'
  check "SC5: gate_passed before lifecycle"    test "$(grep -n 'gate_passed' "$EVENTS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'phase_complete' "$EVENTS" | head -1 | cut -d: -f1)"
  check "SC5: parse_event accepts lifecycle"   parse_one "$EVENTS" "phase_complete" "demo-plan"
}

# ═══════════════════════════════════════════════════════════════════════
# SC6 — R6 — chain paused with phase_at_pause from LAST_CHAIN_PHASE
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  EVENTS="$TC/chain-events.ndjson"
  : > "$EVENTS"
  WORKDIR="$TC" PLAN_DIR_BASENAME="INPROGRESS_Plan_demo-plan" \
    EVENTS_FILE="$EVENTS" STUB_TRIGGER="paused" \
    LAST_CHAIN_PHASE="backend-substrate" \
    bash "$CHAIN_STUB" >/dev/null 2>/dev/null
  check "SC6: chain_paused event present"      assert_contains "$EVENTS" '"event":"chain_paused"'
  check "SC6: lifecycle paused present"        assert_contains "$EVENTS" '"action":"paused"'
  check "SC6: phase_at_pause=backend-substrate" assert_contains "$EVENTS" '"phase_at_pause":"backend-substrate"'
  check "SC6: parse_event accepts lifecycle"   parse_one "$EVENTS" "paused" "demo-plan"
}

# ═══════════════════════════════════════════════════════════════════════
# SC6b — paused fallback to "unknown" when LAST_CHAIN_PHASE empty (T-C6-04)
# ═══════════════════════════════════════════════════════════════════════
{
  TC=$(new_tmp_dir)
  EVENTS="$TC/chain-events.ndjson"
  : > "$EVENTS"
  WORKDIR="$TC" PLAN_DIR_BASENAME="INPROGRESS_Plan_demo-plan" \
    EVENTS_FILE="$EVENTS" STUB_TRIGGER="paused" \
    LAST_CHAIN_PHASE="" STUB_PHASE_ID="" \
    bash "$CHAIN_STUB" >/dev/null 2>/dev/null
  check "SC6b: phase_at_pause=unknown"         assert_contains "$EVENTS" '"phase_at_pause":"unknown"'
}

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo "---"
printf 'Checks: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" $((PASS + FAIL))

if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[*]}" >&2
  exit 1
fi

echo "All lifecycle bash emitter tests passed."
exit 0
