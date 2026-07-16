#!/usr/bin/env bash
# Test: /api/plan/artifact and /api/plan/artifacts endpoints
#
# Tests the plan artifact API that serves markdown/yaml docs from
# execution plan projects — both task-level (REQUIREMENTS.md etc.)
# and plan-level (execution-plan.yaml, SETUP_PLAN.md etc.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PASS=0
FAIL=0
TOTAL=0

PORT=8801
BASE_URL="http://127.0.0.1:$PORT"

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-plan-artifact"
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
  # Create a fake project structure under TMPDIR_BASE
  local project="$TMPDIR_BASE/fake-project"
  mkdir -p "$project/docs/DONE_Feature_auth-module"
  mkdir -p "$project/docs/INPROGRESS_Feature_dark-mode"
  mkdir -p "$project/docs/INPROGRESS_Plan_v2"

  # Task-level artifacts for completed feature
  cat > "$project/docs/DONE_Feature_auth-module/REQUIREMENTS.md" <<'EOF'
# Auth Module Requirements

## R1: Login
The system SHALL allow users to log in.

| Field | Type | Required |
|-------|------|----------|
| email | string | yes |
| password | string | yes |
EOF

  cat > "$project/docs/DONE_Feature_auth-module/PLAN.md" <<'EOF'
# Auth Module Plan

## Components
1. LoginForm component
2. AuthContext provider
EOF

  cat > "$project/docs/DONE_Feature_auth-module/QA_REPORT.md" <<'EOF'
# QA Report
All tests passing.
EOF

  # Task-level artifacts for in-progress feature
  cat > "$project/docs/INPROGRESS_Feature_dark-mode/REQUIREMENTS.md" <<'EOF'
# Dark Mode Requirements
## R1: Toggle
EOF

  # Plan-level artifacts
  cat > "$project/docs/INPROGRESS_Plan_v2/execution-plan.yaml" <<'EOF'
name: Project V2
phases:
  - name: Core
    tasks:
      - id: auth-module
        name: Auth Module
        status: done
EOF

  cat > "$project/docs/INPROGRESS_Plan_v2/SETUP_PLAN.md" <<'EOF'
# Setup Plan
Install dependencies.
EOF

  cat > "$project/docs/INPROGRESS_Plan_v2/EXECUTION_GUIDE.md" <<'EOF'
# Execution Guide
Step-by-step instructions for the plan.
EOF

  cat > "$project/docs/INPROGRESS_Plan_v2/DEFERRED.md" <<'EOF'
# Deferred Items
Items deferred to future phases.
EOF
}

start_server() {
  # Post fastapi-cutover (T0.3): boot uvicorn against the FastAPI app and
  # poll /health.
  cd "$PROJECT_ROOT"
  port_preflight "$PORT"
  local repo_root
  repo_root="$(cd "$PROJECT_ROOT/.." && pwd)"
  local py="python3"
  if [ -x "$repo_root/.venv/bin/python" ]; then
    py="$repo_root/.venv/bin/python"
  fi
  PYTHONPATH="$repo_root" "$py" -m uvicorn dashboard.server.app:app \
    --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    if curl -sf "$BASE_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "FAIL: server did not start"
  exit 1
}

# ─── Tests ───────────────────────────────────────────────────────────

echo "=== Plan Artifact API Tests ==="
echo ""

setup_test_fixtures
start_server

PROJECT_PATH="$TMPDIR_BASE/fake-project"
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PROJECT_PATH', safe=''))")

# ── /api/plan/artifacts — list artifacts for a task ──

echo "  /api/plan/artifacts"

# List artifacts for completed task
RESULT=$(curl -s "$BASE_URL/api/plan/artifacts?cwd=$ENCODED_PATH&task=auth-module")
assert_contains "lists REQUIREMENTS.md for auth-module" "REQUIREMENTS.md" "$RESULT"
assert_contains "lists PLAN.md for auth-module" "PLAN.md" "$RESULT"
assert_contains "lists QA_REPORT.md for auth-module" "QA_REPORT.md" "$RESULT"

# List artifacts for in-progress task
RESULT=$(curl -s "$BASE_URL/api/plan/artifacts?cwd=$ENCODED_PATH&task=dark-mode")
assert_contains "lists REQUIREMENTS.md for dark-mode" "REQUIREMENTS.md" "$RESULT"

# Missing task param
assert_http_status "missing task param returns 400" "400" "$BASE_URL/api/plan/artifacts?cwd=$ENCODED_PATH"

# Non-existent task
RESULT=$(curl -s "$BASE_URL/api/plan/artifacts?cwd=$ENCODED_PATH&task=nonexistent")
assert_contains "non-existent task returns empty list" "[]" "$RESULT"

# ── /api/plan/artifact — get single artifact content ──

echo "  /api/plan/artifact"

# Valid artifact
RESULT=$(curl -s "$BASE_URL/api/plan/artifact?cwd=$ENCODED_PATH&task=auth-module&file=REQUIREMENTS.md")
assert_contains "returns REQUIREMENTS.md content" "Auth Module Requirements" "$RESULT"
assert_contains "returns table content" "email" "$RESULT"

# Plan-level artifact (no task param, use plan_dir)
PLAN_DIR="$PROJECT_PATH/docs/INPROGRESS_Plan_v2"
ENCODED_PLAN_DIR=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PLAN_DIR', safe=''))")
RESULT=$(curl -s "$BASE_URL/api/plan/artifact?plan_dir=$ENCODED_PLAN_DIR&file=execution-plan.yaml")
assert_contains "returns execution-plan.yaml content" "Project V2" "$RESULT"

RESULT=$(curl -s "$BASE_URL/api/plan/artifact?plan_dir=$ENCODED_PLAN_DIR&file=SETUP_PLAN.md")
assert_contains "returns SETUP_PLAN.md content" "Install dependencies" "$RESULT"

RESULT=$(curl -s "$BASE_URL/api/plan/artifact?plan_dir=$ENCODED_PLAN_DIR&file=EXECUTION_GUIDE.md")
assert_contains "returns EXECUTION_GUIDE.md content" "Step-by-step instructions" "$RESULT"

RESULT=$(curl -s "$BASE_URL/api/plan/artifact?plan_dir=$ENCODED_PLAN_DIR&file=DEFERRED.md")
assert_contains "returns DEFERRED.md content" "Deferred Items" "$RESULT"

# Missing file param
assert_http_status "missing file param returns 400" "400" "$BASE_URL/api/plan/artifact?cwd=$ENCODED_PATH&task=auth-module"

# Path traversal attempt
assert_http_status "path traversal returns 400" "400" "$BASE_URL/api/plan/artifact?cwd=$ENCODED_PATH&task=auth-module&file=../../etc/passwd"

# Disallowed file
assert_http_status "disallowed file returns 400" "400" "$BASE_URL/api/plan/artifact?cwd=$ENCODED_PATH&task=auth-module&file=secrets.env"

# Non-existent artifact
assert_http_status "non-existent artifact returns 404" "404" "$BASE_URL/api/plan/artifact?cwd=$ENCODED_PATH&task=auth-module&file=DESIGN.md"

# Invalid task name
assert_http_status "invalid task name returns 400" "400" "$BASE_URL/api/plan/artifact?cwd=$ENCODED_PATH&task=../evil&file=REQUIREMENTS.md"

echo ""
echo "Results: $PASS passed, $FAIL failed (out of $TOTAL)"
[ "$FAIL" -eq 0 ] || exit 1
