#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVE="$PROJECT_ROOT/serve.py"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PASS=0
FAIL=0
TOTAL=0

# Use a unique port to avoid conflicts — pick a random high port
PORT=$((9800 + RANDOM % 100))
BASE_URL="http://127.0.0.1:$PORT"

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-api"
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

# ─── Setup: Create test project with execution plan ──────────────────

setup_test_project() {
  local project_dir="$TMPDIR_BASE/test-project"
  mkdir -p "$project_dir/docs"
  git -C "$project_dir" init -q 2>/dev/null
  git -C "$project_dir" checkout -b "main" 2>/dev/null

  # Create a valid execution plan JSON
  cat > "$project_dir/execution-plan.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test Project",
  "description": "A test project for API tests",
  "phases": [
    {
      "id": "setup",
      "name": "Phase 0: Setup",
      "tasks": [
        {"id": "task-a", "name": "Task A", "status": "done"},
        {"id": "task-b", "name": "Task B", "status": "wip"}
      ],
      "gate": {
        "name": "Setup Gate",
        "checklist": ["Tests pass"],
        "passed": false
      }
    }
  ]
}
EOF

  # Create sessions.jsonl for /api/sessions testing
  local data_dir="$PROJECT_ROOT/data"
  mkdir -p "$data_dir"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"sid\":\"sess-test1\",\"cwd\":\"$project_dir\",\"branch\":\"main\",\"event\":\"Notification\",\"type\":\"assistant\",\"msg\":\"Working on task\",\"ts\":\"$ts\"}" >> "$data_dir/sessions.jsonl"

  echo "$project_dir"
}

# ─── Start server ────────────────────────────────────────────────────

start_server() {
  port_preflight "$PORT"
  # Post fastapi-cutover (T0.3): boot uvicorn against the FastAPI app and
  # wait for /health to return 200 before running assertions.
  local repo_root
  repo_root="$(cd "$PROJECT_ROOT/.." && pwd)"
  local py="python3"
  if [ -x "$repo_root/.venv/bin/python" ]; then
    py="$repo_root/.venv/bin/python"
  fi
  PYTHONPATH="$repo_root" "$py" -m uvicorn dashboard.server.app:app \
    --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
  SERVER_PID=$!
  # Wait for /health 200 (max 10s).
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

test_api_plan_returns_json() {
  local project_dir="$1"
  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")
  assert_contains "/api/plan returns JSON with phases" '"phases"' "$out"
  assert_contains "/api/plan returns JSON with tasks" '"tasks"' "$out"
  assert_contains "/api/plan returns JSON with gate" '"gate"' "$out"
}

test_api_plan_with_json_file() {
  local project_dir="$1"
  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")
  local name
  name=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null || echo "")
  assert_exit "/api/plan reads JSON file" "Test Project" "$name"
}

test_api_plan_markdown_fallback() {
  local project_dir="$TMPDIR_BASE/md-project"
  mkdir -p "$project_dir"
  git -C "$project_dir" init -q 2>/dev/null
  git -C "$project_dir" checkout -b "main" 2>/dev/null

  cat > "$project_dir/EXECUTION_GUIDE.md" <<'EOF'
FASE 0: Setup
- Install tools
- Configure CI

GATE: Setup complete
- All checks pass
EOF

  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")
  assert_contains "/api/plan markdown fallback has phases" '"phases"' "$out"
  local phase_count
  phase_count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['phases']))" 2>/dev/null || echo "0")
  assert_exit "/api/plan markdown fallback has 1 phase" "1" "$phase_count"
}

test_api_plan_no_plan_404() {
  local project_dir="$TMPDIR_BASE/empty-project"
  mkdir -p "$project_dir"
  git -C "$project_dir" init -q 2>/dev/null
  assert_http_status "/api/plan no plan → 404" "404" "$BASE_URL/api/plan?cwd=$project_dir"
}

test_api_plan_status_merge_done() {
  local project_dir="$TMPDIR_BASE/merge-project"
  mkdir -p "$project_dir/docs/DONE_Feature_task-a"
  git -C "$project_dir" init -q 2>/dev/null
  git -C "$project_dir" checkout -b "main" 2>/dev/null

  cat > "$project_dir/execution-plan.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Merge Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [{"id": "task-a", "name": "Task A", "status": "pending"}]
  }]
}
EOF

  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")
  local status
  status=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
print(plan['phases'][0]['tasks'][0]['status'])
" 2>/dev/null || echo "unknown")
  assert_exit "status merge: DONE_Feature_ overrides to done" "done" "$status"
}

test_api_plan_status_merge_wip() {
  local project_dir="$TMPDIR_BASE/merge-wip-project"
  mkdir -p "$project_dir/docs/INPROGRESS_Feature_task-b"
  git -C "$project_dir" init -q 2>/dev/null
  git -C "$project_dir" checkout -b "main" 2>/dev/null

  cat > "$project_dir/execution-plan.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Merge WIP Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [{"id": "task-b", "name": "Task B", "status": "done"}]
  }]
}
EOF

  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")
  local status
  status=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
print(plan['phases'][0]['tasks'][0]['status'])
" 2>/dev/null || echo "unknown")
  assert_exit "status merge: INPROGRESS_Feature_ overrides to wip" "wip" "$status"
}

test_api_plans_returns_list() {
  local out
  out=$(curl -s "$BASE_URL/api/plans")
  assert_contains "/api/plans returns array" "[" "$out"
}

test_api_sessions_returns_states() {
  local out
  out=$(curl -s "$BASE_URL/api/sessions")
  assert_contains "/api/sessions returns array" "[" "$out"
}

test_api_plan_path_traversal() {
  assert_http_status "/api/plan path traversal blocked" "403" "$BASE_URL/api/plan?cwd=/../../../etc"
}

test_api_plan_missing_cwd() {
  assert_http_status "/api/plan missing cwd → 400" "400" "$BASE_URL/api/plan"
}

# ─── Gate enrichment tests ────────────────────────────────────────────

test_api_plan_enriched_gate() {
  local project_dir="$TMPDIR_BASE/enriched-gate-project"
  mkdir -p "$project_dir"
  git -C "$project_dir" init -q 2>/dev/null
  git -C "$project_dir" checkout -b "main" 2>/dev/null

  cat > "$project_dir/execution-plan.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Enriched Gate Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [{"id": "t1", "name": "Task 1", "status": "done"}],
    "gate": {
      "name": "Test Gate",
      "checklist": ["tests pass", "lint clean"],
      "passed": false
    }
  }]
}
EOF
  # Write chain-events.ndjson with evaluation results
  printf '{"type":"gate_evaluated","phase":"p1","items":[{"text":"tests pass","kind":"shell","result":"passed"},{"text":"lint clean","kind":"shell","result":"failed"}]}\n' \
    > "$project_dir/chain-events.ndjson"

  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")

  # Verify enrichedChecklist is present
  assert_contains "enriched gate has enrichedChecklist" '"enrichedChecklist"' "$out"

  # Verify first item has lastResult=passed
  local first_result
  first_result=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
print(plan['phases'][0]['gate']['enrichedChecklist'][0]['lastResult'])
" 2>/dev/null || echo "error")
  assert_exit "enriched gate: first item passed" "passed" "$first_result"

  # Verify second item has lastResult=failed
  local second_result
  second_result=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
print(plan['phases'][0]['gate']['enrichedChecklist'][1]['lastResult'])
" 2>/dev/null || echo "error")
  assert_exit "enriched gate: second item failed" "failed" "$second_result"
}

test_api_plan_no_chain_events_fallback() {
  local project_dir="$TMPDIR_BASE/no-chain-events"
  mkdir -p "$project_dir"
  git -C "$project_dir" init -q 2>/dev/null
  git -C "$project_dir" checkout -b "main" 2>/dev/null

  cat > "$project_dir/execution-plan.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "No Chain Events",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [{"id": "t1", "name": "Task 1", "status": "done"}],
    "gate": {
      "name": "Test Gate",
      "checklist": ["tests pass"],
      "passed": false
    }
  }]
}
EOF
  # No chain-events.ndjson

  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")
  assert_contains "no chain-events has enrichedChecklist" '"enrichedChecklist"' "$out"

  local result_val
  result_val=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
print(plan['phases'][0]['gate']['enrichedChecklist'][0]['lastResult'])
" 2>/dev/null || echo "error")
  assert_exit "no chain-events: lastResult is None" "None" "$result_val"
}

test_api_plan_enriched_kind_present() {
  local project_dir="$TMPDIR_BASE/enriched-kind"
  mkdir -p "$project_dir"
  git -C "$project_dir" init -q 2>/dev/null
  git -C "$project_dir" checkout -b "main" 2>/dev/null

  cat > "$project_dir/execution-plan.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Kind Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [{"id": "t1", "name": "Task 1", "status": "done"}],
    "gate": {
      "name": "Test Gate",
      "checklist": ["manual check"],
      "passed": false
    }
  }]
}
EOF

  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")
  local kind_val
  kind_val=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
print(plan['phases'][0]['gate']['enrichedChecklist'][0]['kind'])
" 2>/dev/null || echo "error")
  assert_exit "enriched gate: string item kind is human" "human" "$kind_val"
}

# ─── Schema 2.0 API tests ─────────────────────────────────────────────

FIXTURE_2_0="$PROJECT_ROOT/tests/fixtures/plan-2.0.0/full.yaml"

test_api_plan_2_0_returns_full_dict() {
  local project_dir="$TMPDIR_BASE/two-oh-project"
  mkdir -p "$project_dir/docs/INPROGRESS_Plan_two_oh"
  cp "$FIXTURE_2_0" "$project_dir/docs/INPROGRESS_Plan_two_oh/execution-plan.yaml"

  local out
  out=$(curl -s "$BASE_URL/api/plan?cwd=$project_dir")

  assert_contains "/api/plan 2.0 has schema_version 2.x" '"schema_version"' "$out"
  assert_contains "/api/plan 2.0 has vision" '"vision"' "$out"
  assert_contains "/api/plan 2.0 has success_criteria" '"success_criteria"' "$out"
  assert_contains "/api/plan 2.0 has tech_stack" '"tech_stack"' "$out"
  assert_contains "/api/plan 2.0 has test_targets" '"test_targets"' "$out"
  assert_contains "/api/plan 2.0 has deferred[]" '"deferred"' "$out"
  assert_contains "/api/plan 2.0 has artifact_refs on tasks" '"artifact_refs"' "$out"

  # All four deferred kinds present
  for kind in code_finding review_suggestion scope_decision future_enhancement; do
    assert_contains "/api/plan 2.0 deferred has kind $kind" "\"kind\": \"$kind\"" "$out"
  done
}

test_api_plans_returns_both_versions() {
  local project_dir="$TMPDIR_BASE/coexist-project"
  mkdir -p "$project_dir/docs/INPROGRESS_Plan_one_x"
  mkdir -p "$project_dir/docs/INPROGRESS_Plan_two_oh"
  cat > "$project_dir/docs/INPROGRESS_Plan_one_x/execution-plan.yaml" <<'EOF'
schema_version: 1.0.0
name: Legacy
phases:
  - id: p1
    name: Phase 1
    tasks: []
EOF
  cp "$FIXTURE_2_0" "$project_dir/docs/INPROGRESS_Plan_two_oh/execution-plan.yaml"

  # We register the project in sessions.jsonl so discover_all_plans_v2
  # picks it up.
  local data_dir="$PROJECT_ROOT/data"
  mkdir -p "$data_dir"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"sid\":\"sess-coexist\",\"cwd\":\"$project_dir\",\"branch\":\"main\",\"event\":\"Notification\",\"type\":\"assistant\",\"msg\":\"x\",\"ts\":\"$ts\"}" >> "$data_dir/sessions.jsonl"

  local out
  out=$(curl -s "$BASE_URL/api/plans")
  # Expect both 1.x and 2.x plans surfaced
  assert_contains "/api/plans surfaces a 2.x plan" "2.0.0" "$out"
}

setup_descended_artifact() {
  local root="$TMPDIR_BASE/descended-project"
  mkdir -p "$root/docs/INPROGRESS_Feature_demo"
  echo "# Demo plan body" > "$root/docs/INPROGRESS_Feature_demo/PLAN.md"
  cat > "$root/execution-plan.yaml" <<'EOF'
schema_version: 1.0.0
name: descended
phases: []
EOF
  echo "$root"
}

test_api_plan_artifact_descended_path_returns_200() {
  local root
  root=$(setup_descended_artifact)
  local url="$BASE_URL/api/plan/artifact?cwd=$root&task=t1&file=docs%2FINPROGRESS_Feature_demo%2FPLAN.md"
  assert_http_status "/api/plan/artifact descended path returns 200" "200" "$url"
  local body
  body=$(curl -s "$url")
  assert_contains "descended path body has plan content" "Demo plan body" "$body"
}

test_api_plan_artifact_descended_path_dotdot_rejects() {
  local root
  root=$(setup_descended_artifact)
  local url="$BASE_URL/api/plan/artifact?cwd=$root&task=t1&file=..%2F..%2Fetc%2Fpasswd"
  assert_http_status "/api/plan/artifact ../../etc/passwd rejects 400" "400" "$url"
}

test_api_plan_artifact_descended_path_outside_projects_root_rejects() {
  local url="$BASE_URL/api/plan/artifact?cwd=%2F&task=t1&file=docs%2Ffoo%2FPLAN.md"
  assert_http_status "/api/plan/artifact cwd=/ rejects 400" "400" "$url"
}

test_api_plan_artifact_basename_mode_unchanged() {
  local root
  root=$(setup_descended_artifact)
  local url="$BASE_URL/api/plan/artifact?plan_dir=$root&file=execution-plan.yaml"
  assert_http_status "/api/plan/artifact basename mode still 200" "200" "$url"
}

test_api_plan_artifact_descended_path_404_on_missing_file() {
  local root
  root=$(setup_descended_artifact)
  local url="$BASE_URL/api/plan/artifact?cwd=$root&task=t1&file=docs%2FINPROGRESS_Feature_demo%2FREQUIREMENTS.md"
  assert_http_status "/api/plan/artifact missing file → 404" "404" "$url"
}

# ─── Run all tests ───────────────────────────────────────────────────

echo "=== API Plan Endpoint Tests ==="

PROJECT_DIR=$(setup_test_project)
start_server

test_api_plan_returns_json "$PROJECT_DIR"
test_api_plan_with_json_file "$PROJECT_DIR"
test_api_plan_markdown_fallback
test_api_plan_no_plan_404
test_api_plan_status_merge_done
test_api_plan_status_merge_wip
test_api_plans_returns_list
test_api_sessions_returns_states
test_api_plan_path_traversal
test_api_plan_missing_cwd
test_api_plan_enriched_gate
test_api_plan_no_chain_events_fallback
test_api_plan_enriched_kind_present

# Schema 2.0 API tests
test_api_plan_2_0_returns_full_dict
test_api_plans_returns_both_versions
test_api_plan_artifact_descended_path_returns_200
test_api_plan_artifact_descended_path_dotdot_rejects
test_api_plan_artifact_descended_path_outside_projects_root_rejects
test_api_plan_artifact_basename_mode_unchanged
test_api_plan_artifact_descended_path_404_on_missing_file

echo ""
echo "---"
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$((PASS + FAIL))"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo "All API plan tests passed."
exit 0
