#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PASS=0
FAIL=0
TOTAL=0

# Use a unique port to avoid conflicts
PORT=8798
BASE_URL="http://127.0.0.1:$PORT"

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-api-metrics"
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"

SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  [ -n "${SERVER_PID:-}" ] && port_reaper "$PORT" || true
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

assert_eq() {
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

# ─── Setup: Create test JSONL data ──────────────────────────────────

setup_test_data() {
  local data_dir="$TMPDIR_BASE/data"
  mkdir -p "$data_dir"
  local jsonl="$data_dir/sessions.jsonl"

  cat > "$jsonl" <<'EOF'
{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SessionStart","type":"","msg":"","ts":"2026-03-01T10:00:00Z","model":"claude-opus-4-6","src":"startup","pmode":"default"}
{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"run tests","ts":"2026-03-01T10:01:00Z","tuid":"t1"}
{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PostToolUse","type":"Bash","msg":"ok","ts":"2026-03-01T10:01:30Z","tuid":"t1"}
{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Edit","msg":"","ts":"2026-03-01T10:02:00Z","tuid":"t2","fp":"/src/auth.ts"}
{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PostToolUse","type":"Edit","msg":"","ts":"2026-03-01T10:02:10Z","tuid":"t2"}
{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"TaskCompleted","type":"","msg":"","ts":"2026-03-01T10:05:00Z","tsub":"Fix auth bug","tid":"task-1"}
{"sid":"s2","cwd":"/Users/dev/proj","branch":"feat","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:03:00Z","tuid":"t3"}
{"sid":"s2","cwd":"/Users/dev/proj","branch":"feat","event":"PostToolUseFailure","type":"Bash","msg":"","ts":"2026-03-01T10:03:30Z","tuid":"t3","err":"exit 1","intr":"false"}
EOF

  echo "$data_dir"
}

# ─── Start server with test data ────────────────────────────────────

start_server() {
  local data_dir="$1"
  port_preflight "$PORT"
  # Post fastapi-cutover (T0.3): boot uvicorn against the FastAPI app and
  # poll /health. DASHBOARD_DATA_DIR env hand-off preserved.
  local repo_root
  repo_root="$(cd "$PROJECT_ROOT/.." && pwd)"
  local py="python3"
  if [ -x "$repo_root/.venv/bin/python" ]; then
    py="$repo_root/.venv/bin/python"
  fi
  DASHBOARD_DATA_DIR="$data_dir" PYTHONPATH="$repo_root" "$py" -m uvicorn \
    dashboard.server.app:app --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
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

# ─── Test Cases ─────────────────────────────────────────────────────

# A1: Returns JSON with all 8 metric blocks
test_a1_all_blocks() {
  local out
  out=$(curl -s "$BASE_URL/api/metrics")
  assert_contains "A1: tool_usage" '"tool_usage"' "$out"
  assert_contains "A1: error_tracking" '"error_tracking"' "$out"
  assert_contains "A1: session_lifecycle" '"session_lifecycle"' "$out"
  assert_contains "A1: permission_friction" '"permission_friction"' "$out"
  assert_contains "A1: subagent_utilization" '"subagent_utilization"' "$out"
  assert_contains "A1: file_activity" '"file_activity"' "$out"
  assert_contains "A1: task_completion" '"task_completion"' "$out"
  assert_contains "A1: activity_timeline" '"activity_timeline"' "$out"
}

# A2: sid parameter filters
test_a2_sid_filter() {
  local out
  out=$(curl -s "$BASE_URL/api/metrics?sid=s1")
  local total
  total=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['tool_usage']['total'])" 2>/dev/null || echo "0")
  assert_eq "A2: sid filter s1 tool count" "2" "$total"
}

# A2: since parameter filters
test_a2_since_filter() {
  local out
  out=$(curl -s "$BASE_URL/api/metrics?since=2026-03-01T10:02:00Z")
  local total
  total=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['tool_usage']['total'])" 2>/dev/null || echo "0")
  # Only events after 10:02:00Z: Edit at 10:02:00 excluded (<=), Bash at 10:03:00 included
  assert_eq "A2: since filter tool count" "1" "$total"
}

# A4: Invalid sid returns 400
test_a4_invalid_sid() {
  assert_http_status "A4: invalid sid returns 400" "400" "$BASE_URL/api/metrics?sid=\$(rm%20-rf%20/)"
}

# A4: Invalid since returns 400
test_a4_invalid_since() {
  assert_http_status "A4: invalid since returns 400" "400" "$BASE_URL/api/metrics?since=not-a-date"
}

# A1: No params returns all metrics
test_a1_no_params() {
  local out
  out=$(curl -s "$BASE_URL/api/metrics")
  local total
  total=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['tool_usage']['total'])" 2>/dev/null || echo "0")
  # s1: 2 PreToolUse + s2: 1 PreToolUse = 3 total
  assert_eq "A1: no params returns all metrics" "3" "$total"
}

# ─── Run all tests ──────────────────────────────────────────────────

echo "=== API Metrics Endpoint Tests ==="

DATA_DIR=$(setup_test_data)
start_server "$DATA_DIR"

test_a1_all_blocks
test_a2_sid_filter
test_a2_since_filter
test_a4_invalid_sid
test_a4_invalid_since
test_a1_no_params

echo ""
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo "All API metrics tests passed."
exit 0
