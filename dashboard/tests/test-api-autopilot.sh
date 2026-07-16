#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Resolver scans top-level projects under PROJECTS_ROOT (~/Projekter); dashboard
# is a subtree of the dotfiles monorepo, so the autopilot log fixture must
# live under the repo root, not under dashboard/.
REPO_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PASS=0
FAIL=0
TOTAL=0

PORT=8798
BASE_URL="http://127.0.0.1:$PORT"

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-autopilot"
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
  rm -rf "$REPO_ROOT/docs/INPROGRESS_Feature_test-task"
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
  # Create log inside the repo-root docs dir so the autopilot resolver
  # (which scans ~/Projekter/<project>/docs/...) discovers it as part of
  # the dotfiles project.
  local feature_dir="$REPO_ROOT/docs/INPROGRESS_Feature_test-task"
  mkdir -p "$feature_dir"
  cat > "$feature_dir/autopilot.log" <<'EOF'
╔══════════════════════════════════════════╗
║  AUTOPILOT                               ║
╠══════════════════════════════════════════╣
║  Task:     test-task                     ║
║  Project:  TestProject                   ║
║  Branch:   feature/test-task             ║
╚══════════════════════════════════════════╝

━━━ Phase: BA ━━━
Running /ba flow test-task...
✓ Requirements written
Phase completed in 60s
Total cost: $0.25

━━━ Phase: Plan ━━━
Running /plan flow test-task...
Phase completed in 90s

━━━ Phase: Implement ━━━
Running /implement flow test-task...

AUTOPILOT COMPLETE
EOF

  # Create a sample artifact
  cat > "$feature_dir/REQUIREMENTS.md" <<'ARTIFACTEOF'
# Test Requirements

## R1: Test requirement
The system MUST do something.
ARTIFACTEOF

  # Create summary in same feature dir
  cat > "$feature_dir/autopilot-summary.json" <<'EOF'
{
  "task": "test-task",
  "project": "TestProject",
  "branch": "feature/test-task",
  "workdir": "/tmp/test",
  "start_ts": "2026-03-21T10:00:00Z",
  "end_ts": "2026-03-21T10:05:00Z",
  "duration_s": 300,
  "phases": [
    {"name": "BA", "status": "completed", "duration_s": 60},
    {"name": "Plan", "status": "completed", "duration_s": 90}
  ],
  "status": "success"
}
EOF
}

start_server() {
  port_preflight "$PORT"
  # Post fastapi-cutover (T0.3): boot uvicorn against the FastAPI app and
  # poll /health.
  local py="python3"
  if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    py="$REPO_ROOT/.venv/bin/python"
  fi
  PYTHONPATH="$REPO_ROOT" "$py" -m uvicorn dashboard.server.app:app \
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

# ─── Test Cases: /api/autopilots ─────────────────────────────────────

test_autopilots_returns_array() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilots")
  assert_contains "/api/autopilots returns array" "[" "$out"
}

# ─── Test Cases: /api/autopilot/log ──────────────────────────────────

test_log_missing_task() {
  assert_http_status "log: missing task → 400" "400" "$BASE_URL/api/autopilot/log"
}

test_log_invalid_task() {
  assert_http_status "log: invalid task (traversal) → 400" "400" "$BASE_URL/api/autopilot/log?task=../../etc/passwd"
}

test_log_nonexistent_task() {
  assert_http_status "log: nonexistent task → 404" "404" "$BASE_URL/api/autopilot/log?task=nonexistent-xyz"
}

test_log_from_offset_zero() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/log?task=test-task&offset=0")
  assert_contains "log offset=0: has content" "content" "$out"
  assert_contains "log offset=0: has Phase" "Phase" "$out"
}

test_log_from_offset_n() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/log?task=test-task&offset=100")
  assert_contains "log offset=N: has content key" "content" "$out"
  # Should NOT contain the very first line (it's past offset 100)
  local content
  content=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][:20])" 2>/dev/null || echo "")
  # The header starts at offset 0, so offset 100 should skip it
  TOTAL=$((TOTAL + 1))
  if echo "$content" | grep -qvF "╔══"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: log offset=N should skip header"
  fi
}

test_log_negative_offset() {
  assert_http_status "log: negative offset → 400" "400" "$BASE_URL/api/autopilot/log?task=test-task&offset=-1"
}

test_log_non_integer_offset() {
  assert_http_status "log: non-integer offset → 400" "400" "$BASE_URL/api/autopilot/log?task=test-task&offset=abc"
}

test_log_offset_exceeds_file() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/log?task=test-task&offset=999999")
  local content
  content=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['content'])" 2>/dev/null || echo "FAIL")
  assert_exit "log: offset past EOF → empty content" "" "$content"
}

# ─── Test Cases: /api/autopilot/summary ──────────────────────────────

test_summary_not_found() {
  assert_http_status "summary: nonexistent → 404" "404" "$BASE_URL/api/autopilot/summary?task=nonexistent-xyz"
}

test_summary_returns_json() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/summary?task=test-task")
  assert_contains "summary: has task field" '"task"' "$out"
  assert_contains "summary: has status field" '"status"' "$out"
  local task
  task=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['task'])" 2>/dev/null || echo "")
  assert_exit "summary: task matches" "test-task" "$task"
}

# ─── Test Cases: Cross-cutting ───────────────────────────────────────

test_log_has_phases_with_artifacts() {
  # Via /api/autopilot/log offset=0, verify Phase markers are present
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/log?task=test-task&offset=0")
  assert_contains "log contains BA phase" "Phase: BA" "$out"
}

# ─── Test Cases: /api/autopilot/artifact ─────────────────────────────

test_artifact_missing_params() {
  assert_http_status "artifact: missing params → 400" "400" "$BASE_URL/api/autopilot/artifact"
}

test_artifact_invalid_task() {
  assert_http_status "artifact: invalid task → 400" "400" "$BASE_URL/api/autopilot/artifact?task=../../etc&file=REQUIREMENTS.md"
}

test_artifact_invalid_file() {
  assert_http_status "artifact: invalid file → 400" "400" "$BASE_URL/api/autopilot/artifact?task=test-task&file=../../etc/passwd"
}

test_artifact_not_found() {
  assert_http_status "artifact: nonexistent → 404" "404" "$BASE_URL/api/autopilot/artifact?task=nonexistent-xyz&file=REQUIREMENTS.md"
}

test_artifact_returns_content() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/artifact?task=test-task&file=REQUIREMENTS.md")
  assert_contains "artifact: has content" '"content"' "$out"
  assert_contains "artifact: has markdown" "Test Requirements" "$out"
}

test_artifacts_list() {
  local out status
  out=$(curl -s "$BASE_URL/api/autopilot/artifacts?task=test-task")
  status=$?
  assert_exit "artifacts list: curl succeeds" "0" "$status"
  assert_contains "artifacts list: has REQUIREMENTS.md" "REQUIREMENTS.md" "$out"
}

test_artifacts_list_missing_task() {
  assert_http_status "artifacts list: missing task returns 400" "400" "$BASE_URL/api/autopilot/artifacts"
}

# TDD anchor: launch command + pipeline tests in app/src/__tests__/focusUri.test.ts
# TDD anchor: StreamViewer filter + link interception in app/src/components/autopilot/StreamViewer.tsx
# TDD anchor: launch button clipboard-only (no vscode:// navigation)
# TDD anchor: ToolResultBlock handles undefined/non-string content gracefully
# TDD anchor: StreamViewer filter order and default state
# TDD anchor: StreamViewer visual redesign — same data, improved UI treatment
# TDD anchor: discover_autopilots prefers NDJSON stream phases over log phases
# TDD anchor: StreamViewer v2 visual polish — result summary as inline divider
# TDD anchor: Launch button uses same clipboard pattern as copy-prompt
# TDD anchor: Fix unicode escape in StreamViewer OrchestratorMessage
# TDD anchor: HeroStrip supports both EXECUTION_GUIDE.md and EXECUTION_PLAN.md

test_artifacts_list_nonexistent() {
  local out
  out=$(curl -s "$BASE_URL/api/autopilot/artifacts?task=nonexistent-xyz")
  assert_contains "artifacts list: nonexistent task returns empty" "[]" "$out"
}

# ─── Run all tests ───────────────────────────────────────────────────

echo "=== API Autopilot Endpoint Tests ==="

setup_test_fixtures
start_server

test_autopilots_returns_array
test_log_missing_task
test_log_invalid_task
test_log_nonexistent_task
test_log_from_offset_zero
test_log_from_offset_n
test_log_negative_offset
test_log_non_integer_offset
test_log_offset_exceeds_file
test_summary_not_found
test_summary_returns_json
test_log_has_phases_with_artifacts
test_artifact_missing_params
test_artifact_invalid_task
test_artifact_invalid_file
test_artifact_not_found
test_artifact_returns_content
test_artifacts_list
test_artifacts_list_missing_task
test_artifacts_list_nonexistent

echo ""
echo "---"
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$((PASS + FAIL))"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo "All API autopilot tests passed."
exit 0
