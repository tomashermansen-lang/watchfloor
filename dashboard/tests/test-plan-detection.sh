#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PASS=0
FAIL=0
TOTAL=0

PORT=8798
BASE_URL="http://127.0.0.1:$PORT"

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-plan-detection"
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"

SERVER_PID=""

JSONL_EXISTED_BEFORE=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  [ -n "${SERVER_PID:-}" ] && port_reaper "$PORT" || true
  # Restore sessions.jsonl to pre-test state
  if [ "$JSONL_EXISTED_BEFORE" = "yes" ] && [ -f "$TMPDIR_BASE/sessions.jsonl.bak" ]; then
    cp "$TMPDIR_BASE/sessions.jsonl.bak" "$PROJECT_ROOT/data/sessions.jsonl"
  elif [ "$JSONL_EXISTED_BEFORE" = "no" ]; then
    rm -f "$PROJECT_ROOT/data/sessions.jsonl"
  fi
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

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

# ─── Setup: Create test project with plans in docs/ subdirs ───────────

setup_test_project() {
  local project_dir="$TMPDIR_BASE/test-project"
  mkdir -p "$project_dir/docs/INPROGRESS_Plan_my-feature"
  mkdir -p "$project_dir/docs/DONE_Plan_old-feature"
  git -C "$project_dir" init -q 2>/dev/null
  git -C "$project_dir" checkout -b "main" 2>/dev/null

  # INPROGRESS plan
  cat > "$project_dir/docs/INPROGRESS_Plan_my-feature/execution-plan.yaml" <<'EOF'
schema_version: "1.0.0"
name: "My Feature"
phases:
  - id: setup
    name: "Phase 0: Setup"
    tasks:
      - id: task-a
        name: Task A
        status: wip
      - id: task-b
        name: Task B
        status: pending
EOF

  # DONE plan
  cat > "$project_dir/docs/DONE_Plan_old-feature/execution-plan.yaml" <<'EOF'
schema_version: "1.0.0"
name: "Old Feature"
phases:
  - id: core
    name: "Phase 1: Core"
    tasks:
      - id: task-x
        name: Task X
        status: done
EOF

  # Backup sessions.jsonl before appending test data
  local data_dir="$PROJECT_ROOT/data"
  mkdir -p "$data_dir"
  if [ -f "$data_dir/sessions.jsonl" ]; then
    cp "$data_dir/sessions.jsonl" "$TMPDIR_BASE/sessions.jsonl.bak"
    JSONL_EXISTED_BEFORE="yes"
  else
    JSONL_EXISTED_BEFORE="no"
  fi

  # Create sessions.jsonl entry so discover_all_plans_v2 can find the project
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"sid\":\"sess-detect1\",\"cwd\":\"$project_dir\",\"branch\":\"main\",\"event\":\"Notification\",\"type\":\"assistant\",\"msg\":\"test\",\"ts\":\"$ts\"}" >> "$data_dir/sessions.jsonl"

  echo "$project_dir"
}

# ─── Start server ─────────────────────────────────────────────────────

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

# ─── Test Cases ───────────────────────────────────────────────────────

test_api_plans_includes_lifecycle() {
  local out
  out=$(curl -s "$BASE_URL/api/plans")
  assert_contains "/api/plans includes lifecycle field" '"lifecycle"' "$out"
}

test_api_plans_includes_inprogress_lifecycle() {
  local out
  out=$(curl -s "$BASE_URL/api/plans")
  assert_contains "/api/plans includes inprogress lifecycle" '"inprogress"' "$out"
}

test_api_plans_includes_done_lifecycle() {
  local out
  out=$(curl -s "$BASE_URL/api/plans")
  assert_contains "/api/plans includes done lifecycle" '"done"' "$out"
}

test_api_plans_includes_plan_dir() {
  local out
  out=$(curl -s "$BASE_URL/api/plans")
  assert_contains "/api/plans includes plan_dir field" '"plan_dir"' "$out"
}

test_existing_api_plans_fields_preserved() {
  local out
  out=$(curl -s "$BASE_URL/api/plans")
  assert_contains "/api/plans has project field" '"project"' "$out"
  assert_contains "/api/plans has path field" '"path"' "$out"
  assert_contains "/api/plans has phases field" '"phases"' "$out"
  assert_contains "/api/plans has progress field" '"progress"' "$out"
  assert_contains "/api/plans has has_plan field" '"has_plan"' "$out"
}

# ─── Run all tests ───────────────────────────────────────────────────

echo "=== Plan Detection Integration Tests ==="

setup_test_project >/dev/null
start_server

test_api_plans_includes_lifecycle
test_api_plans_includes_inprogress_lifecycle
test_api_plans_includes_done_lifecycle
test_api_plans_includes_plan_dir
test_existing_api_plans_fields_preserved

echo ""
echo "---"
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$((PASS + FAIL))"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo "All plan detection tests passed."
exit 0
