#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PASS=0
FAIL=0
TOTAL=0

PORT=8799
BASE_URL="http://127.0.0.1:$PORT"

SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  [ -n "${SERVER_PID:-}" ] && port_reaper "$PORT" || true
  rm -rf "$PROJECT_ROOT/docs/INPROGRESS_Feature_stream-test"
}
trap cleanup EXIT

# ─── Assertions ──────────────────────────────────────────────────────

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    output: $(echo "$haystack" | head -3)"
  fi
}

assert_http_status() {
  local label="$1" expected="$2" url="$3"
  TOTAL=$((TOTAL + 1))
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  if [ "$expected" = "$status" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected HTTP: $expected"
    echo "    actual HTTP:   $status"
  fi
}

# ─── Setup ───────────────────────────────────────────────────────────

setup_test_fixtures() {
  local feature_dir="$PROJECT_ROOT/docs/INPROGRESS_Feature_stream-test"
  mkdir -p "$feature_dir"

  # Create an NDJSON stream file with various event types
  cat > "$feature_dir/autopilot-stream.ndjson" <<'EOF'
{"type":"system","message":"init"}
{"type":"phase","phase":"Business Analysis","status":"running","ts":"2026-03-21T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Analyzing requirements..."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"total 42\ndrwxr-xr-x  5 user  staff  160 Mar 21 10:00 ."}]}}
{"type":"rate_limit_event","retry_after":5}
{"type":"phase","phase":"Business Analysis","status":"completed","duration_s":222,"ts":"2026-03-21T10:03:42Z"}
{"type":"result","subtype":"success","total_cost_usd":0.74,"duration_ms":221000,"num_turns":17}
EOF
}

start_server() {
  port_preflight "$PORT"
  # Post fastapi-cutover (T0.3): boot uvicorn against the FastAPI app and
  # poll /health.
  local repo_root
  repo_root="$(cd "$PROJECT_ROOT/.." && pwd)"
  local py="python3"
  if [ -x "$repo_root/.venv/bin/python" ]; then
    py="$repo_root/.venv/bin/python"
  fi
  PYTHONPATH="$repo_root" "$py" -m uvicorn dashboard.server.app:app \
    --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
  SERVER_PID=$!
  local tries=0
  while ! curl -sf "$BASE_URL/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
      echo "  FAIL: Server did not start"
      exit 1
    fi
    sleep 0.2
  done
}

# ─── Test Cases: /api/autopilot/stream ───────────────────────────────

test_stream_missing_task() {
  assert_http_status "stream: missing task → 400" "400" "$BASE_URL/api/autopilot/stream"
}

test_stream_invalid_task() {
  assert_http_status "stream: invalid task (traversal) → 400" "400" "$BASE_URL/api/autopilot/stream?task=../../etc/passwd"
}

test_stream_nonexistent_task() {
  assert_http_status "stream: nonexistent task → 404" "404" "$BASE_URL/api/autopilot/stream?task=nonexistent-xyz"
}

test_stream_from_offset_zero() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=0")
  assert_contains "stream offset=0: has events key" '"events"' "$out"
  assert_contains "stream offset=0: has offset key" '"offset"' "$out"
}

test_stream_filters_system_events() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=0")
  # Should NOT contain system events
  local has_system
  has_system=$(echo "$out" | python3 -c "
import sys, json
data = json.load(sys.stdin)
types = [e['type'] for e in data['events']]
print('yes' if 'system' in types else 'no')
" 2>/dev/null || echo "error")
  assert_exit "stream: filters system events" "no" "$has_system"
}

test_stream_filters_rate_limit_events() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=0")
  local has_rate_limit
  has_rate_limit=$(echo "$out" | python3 -c "
import sys, json
data = json.load(sys.stdin)
types = [e['type'] for e in data['events']]
print('yes' if 'rate_limit_event' in types else 'no')
" 2>/dev/null || echo "error")
  assert_exit "stream: filters rate_limit_event" "no" "$has_rate_limit"
}

test_stream_contains_phase_events() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=0")
  assert_contains "stream: has phase event" '"phase"' "$out"
  assert_contains "stream: has Business Analysis" "Business Analysis" "$out"
}

test_stream_contains_assistant_events() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=0")
  assert_contains "stream: has assistant event" '"assistant"' "$out"
  assert_contains "stream: has text content" "Analyzing requirements" "$out"
}

test_stream_contains_result_events() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=0")
  assert_contains "stream: has result event" '"result"' "$out"
  assert_contains "stream: has cost" "0.74" "$out"
}

test_stream_offset_tracks_bytes() {
  local out offset1 out2 count2
  out=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=0")
  offset1=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['offset'])" 2>/dev/null)
  # Second request with new offset should return empty events (no new data)
  out2=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=$offset1")
  count2=$(echo "$out2" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['events']))" 2>/dev/null)
  assert_exit "stream: second poll returns 0 events" "0" "$count2"
}

test_stream_negative_offset() {
  assert_http_status "stream: negative offset → 400" "400" "$BASE_URL/api/autopilot/stream?task=stream-test&offset=-1"
}

test_stream_non_integer_offset() {
  assert_http_status "stream: non-integer offset → 400" "400" "$BASE_URL/api/autopilot/stream?task=stream-test&offset=abc"
}

test_stream_event_count() {
  local out count
  out=$(curl -s "$BASE_URL/api/autopilot/stream?task=stream-test&offset=0")
  count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['events']))" 2>/dev/null)
  # 8 lines total, minus 2 filtered (system + rate_limit_event) = 6
  assert_exit "stream: returns 6 filtered events" "6" "$count"
}

# ─── Test Cases: /api/autopilot/activity ──────────────────────────────

test_activity_missing_task() {
  assert_http_status "activity: missing task → 400" "400" "$BASE_URL/api/autopilot/activity"
}

test_activity_invalid_task() {
  assert_http_status "activity: invalid task (traversal) → 400" "400" "$BASE_URL/api/autopilot/activity?task=../../etc/passwd"
}

test_activity_returns_json() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/activity?task=stream-test")
  assert_contains "activity: has task key" '"task"' "$out"
  assert_contains "activity: has events key" '"events"' "$out"
}

# ─── Run all tests ───────────────────────────────────────────────────

echo "=== API Autopilot Stream Endpoint Tests ==="

setup_test_fixtures
start_server

test_stream_missing_task
test_stream_invalid_task
test_stream_nonexistent_task
test_stream_from_offset_zero
test_stream_filters_system_events
test_stream_filters_rate_limit_events
test_stream_contains_phase_events
test_stream_contains_assistant_events
test_stream_contains_result_events
test_stream_offset_tracks_bytes
test_stream_negative_offset
test_stream_non_integer_offset
test_stream_event_count
test_activity_missing_task
test_activity_invalid_task
test_activity_returns_json

echo ""
echo "---"
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$((PASS + FAIL))"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo "All stream endpoint tests passed."
exit 0
