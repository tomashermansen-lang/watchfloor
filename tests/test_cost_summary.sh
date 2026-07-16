#!/usr/bin/env bash
# Test suite for cost-summary.py — trustworthy cost accounting tool.
#
# Verifies the two correctness invariants:
#   1. Phantom result events (multiple result events sharing one session_id)
#      contribute MAX(total_cost_usd) per session, not sum.
#   2. Retry attempts (multiple sessions for one phase) sum each session's
#      MAX cost — failed-attempt cost is INCLUDED (you paid for it).
#
# Hermetic: synthesises tiny NDJSON streams inline. No real autopilot run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/adapters/claude-code/claude/tools/cost-summary.py"

PASS=0
FAIL=0
FAILED_NAMES=()
TMP_DIRS=()

new_tmp() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/costsum.XXXXXX")
  TMP_DIRS+=("$d")
  echo "$d"
}

cleanup_all() {
  local d
  for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup_all EXIT

check() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "  FAIL: $name" >&2
  fi
}

# Helper: write one NDJSON event to file.
emit() {
  local file="$1"; shift
  printf '%s\n' "$1" >> "$file"
}

# ═══════════════════════════════════════════════════════════════════════
# T1: missing stream → exit 2
# ═══════════════════════════════════════════════════════════════════════
T1=$(new_tmp)
python3 "$TOOL" "$T1/missing.ndjson" >"$T1/out" 2>"$T1/err" || ec=$?
check "T1.1: missing stream → exit 2" test "${ec:-0}" -eq 2

# ═══════════════════════════════════════════════════════════════════════
# T2: empty stream → total $0
# ═══════════════════════════════════════════════════════════════════════
T2=$(new_tmp)
: > "$T2/stream.ndjson"
out=$(python3 "$TOOL" --json "$T2/stream.ndjson")
check "T2.1: empty stream → total_cost_usd=0" \
  test "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_cost_usd"])')" = "0"

# ═══════════════════════════════════════════════════════════════════════
# T3: single phase, single session, single result event
# ═══════════════════════════════════════════════════════════════════════
T3=$(new_tmp)
emit "$T3/stream.ndjson" '{"type":"phase","phase":"BA","status":"running","ts":"2026-05-23T10:00:00Z"}'
emit "$T3/stream.ndjson" '{"type":"result","session_id":"sess-1","total_cost_usd":1.50,"duration_ms":300000,"num_turns":10,"ts":"2026-05-23T10:05:00Z"}'
out=$(python3 "$TOOL" --json "$T3/stream.ndjson")
total=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_cost_usd"])')
check "T3.1: single event → total=1.50" test "$total" = "1.5"
phases=$(echo "$out" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["phases"]))')
check "T3.2: single phase counted" test "$phases" = "1"

# ═══════════════════════════════════════════════════════════════════════
# T4: PHANTOM — single session, multiple result events → MAX, not SUM
# ═══════════════════════════════════════════════════════════════════════
T4=$(new_tmp)
emit "$T4/stream.ndjson" '{"type":"phase","phase":"Implement","status":"running","ts":"2026-05-23T10:00:00Z"}'
# First result event at $5.96
emit "$T4/stream.ndjson" '{"type":"result","session_id":"sess-impl","total_cost_usd":5.96,"duration_ms":2250000,"num_turns":135,"ts":"2026-05-23T10:37:00Z"}'
# Phantom second result event from SAME session at $6.00 (cumulative)
emit "$T4/stream.ndjson" '{"type":"result","session_id":"sess-impl","total_cost_usd":6.00,"duration_ms":2256000,"num_turns":136,"ts":"2026-05-23T10:37:30Z"}'
out=$(python3 "$TOOL" --json "$T4/stream.ndjson")
total=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_cost_usd"])')
check "T4.1: phantom → MAX=6.0 (not 11.96)" test "$total" = "6.0"
sessions=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["phases"][0]["session_count"])')
check "T4.2: still 1 session" test "$sessions" = "1"
events=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["phases"][0]["sessions"][0]["result_event_count"])')
check "T4.3: result_event_count=2 visible" test "$events" = "2"

# ═══════════════════════════════════════════════════════════════════════
# T5: RETRY — multiple sessions for one phase → SUM of per-session MAX
# ═══════════════════════════════════════════════════════════════════════
T5=$(new_tmp)
emit "$T5/stream.ndjson" '{"type":"phase","phase":"QA","status":"running","ts":"2026-05-23T11:00:00Z"}'
# Attempt 1 fails
emit "$T5/stream.ndjson" '{"type":"result","session_id":"sess-qa-1","total_cost_usd":3.35,"duration_ms":1330000,"num_turns":76,"is_error":true,"ts":"2026-05-23T11:22:00Z"}'
# Attempt 2 succeeds
emit "$T5/stream.ndjson" '{"type":"result","session_id":"sess-qa-2","total_cost_usd":2.50,"duration_ms":900000,"num_turns":60,"ts":"2026-05-23T11:37:00Z"}'
out=$(python3 "$TOOL" --json "$T5/stream.ndjson")
total=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_cost_usd"])')
check "T5.1: retry → SUM=5.85 (failed attempt counted)" test "$total" = "5.85"
retries=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["phases"][0]["retries"])')
check "T5.2: retries=1" test "$retries" = "1"
had_failure=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["phases"][0]["had_failure"])')
check "T5.3: had_failure=True" test "$had_failure" = "True"

# ═══════════════════════════════════════════════════════════════════════
# T6: multi-phase attribution
# ═══════════════════════════════════════════════════════════════════════
T6=$(new_tmp)
emit "$T6/stream.ndjson" '{"type":"phase","phase":"BA","status":"running","ts":"2026-05-23T09:00:00Z"}'
emit "$T6/stream.ndjson" '{"type":"result","session_id":"sess-ba","total_cost_usd":1.00,"duration_ms":300000,"num_turns":20,"ts":"2026-05-23T09:05:00Z"}'
emit "$T6/stream.ndjson" '{"type":"phase","phase":"Plan","status":"running","ts":"2026-05-23T09:06:00Z"}'
emit "$T6/stream.ndjson" '{"type":"result","session_id":"sess-plan","total_cost_usd":0.50,"duration_ms":180000,"num_turns":15,"ts":"2026-05-23T09:09:00Z"}'
emit "$T6/stream.ndjson" '{"type":"phase","phase":"Implement","status":"running","ts":"2026-05-23T09:10:00Z"}'
emit "$T6/stream.ndjson" '{"type":"result","session_id":"sess-impl","total_cost_usd":4.00,"duration_ms":1800000,"num_turns":80,"ts":"2026-05-23T09:40:00Z"}'
out=$(python3 "$TOOL" --json "$T6/stream.ndjson")
total=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_cost_usd"])')
check "T6.1: 3-phase total=5.5" test "$total" = "5.5"
ph_count=$(echo "$out" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["phases"]))')
check "T6.2: 3 phases" test "$ph_count" = "3"
# Verify implement got its cost
impl_cost=$(echo "$out" | python3 -c 'import sys,json
d = json.load(sys.stdin)
impl = next(p for p in d["phases"] if p["phase"] == "Implement")
print(impl["cost_usd"])')
check "T6.3: Implement phase cost == 4.00" test "$impl_cost" = "4.0"

# ═══════════════════════════════════════════════════════════════════════
# T7: COMBINED — retry + phantom in same stream
# ═══════════════════════════════════════════════════════════════════════
T7=$(new_tmp)
emit "$T7/stream.ndjson" '{"type":"phase","phase":"Implement","status":"running","ts":"2026-05-23T10:00:00Z"}'
# Session 1 = phantom (impl session that emitted 2 results)
emit "$T7/stream.ndjson" '{"type":"result","session_id":"impl-a","total_cost_usd":5.96,"duration_ms":2250000,"num_turns":135,"ts":"2026-05-23T10:37:00Z"}'
emit "$T7/stream.ndjson" '{"type":"result","session_id":"impl-a","total_cost_usd":6.00,"duration_ms":2256000,"num_turns":136,"ts":"2026-05-23T10:37:30Z"}'
# Phase boundary
emit "$T7/stream.ndjson" '{"type":"phase","phase":"QA","status":"running","ts":"2026-05-23T11:00:00Z"}'
# QA session 1 failed
emit "$T7/stream.ndjson" '{"type":"result","session_id":"qa-1","total_cost_usd":3.35,"duration_ms":1330000,"num_turns":76,"is_error":true,"ts":"2026-05-23T11:22:00Z"}'
# QA session 2 succeeded
emit "$T7/stream.ndjson" '{"type":"result","session_id":"qa-2","total_cost_usd":2.50,"duration_ms":900000,"num_turns":60,"ts":"2026-05-23T11:37:00Z"}'
out=$(python3 "$TOOL" --json "$T7/stream.ndjson")
total=$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_cost_usd"])')
check "T7.1: combined total = 6.00 + 3.35 + 2.50 = 11.85" test "$total" = "11.85"

# ═══════════════════════════════════════════════════════════════════════
# T8: text-format output renders without crash, contains TOTAL line
# ═══════════════════════════════════════════════════════════════════════
text_out=$(python3 "$TOOL" "$T7/stream.ndjson")
check "T8.1: text output contains TOTAL" grep -q "TOTAL" <<<"$text_out"
check "T8.2: text output mentions QA retry" grep -q "retr" <<<"$text_out"

# ═══════════════════════════════════════════════════════════════════════
# Final
# ═══════════════════════════════════════════════════════════════════════
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:" >&2
  for n in "${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"}"; do
    echo "  - $n" >&2
  done
  exit 1
fi
exit 0
