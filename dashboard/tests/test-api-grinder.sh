#!/usr/bin/env bash
# Grinder API endpoint integration tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVE="$PROJECT_ROOT/serve.py"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PASS=0
FAIL=0
TOTAL=0

# Use a unique port to avoid conflicts
PORT=$((9800 + RANDOM % 100))
BASE_URL="http://127.0.0.1:$PORT"

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-grinder"
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
  local label="$1" expected="$2" method="$3" url="$4"
  TOTAL=$((TOTAL + 1))
  local status
  # Unsafe methods need Origin + double-submit CSRF after the
  # fastapi-origin-and-schemas + fastapi-csrf-middleware merges.
  # auth_curl handles both; GET stays bare to keep that path under test.
  case "$method" in
    POST|PUT|PATCH|DELETE)
      status=$(auth_curl -o /dev/null -w "%{http_code}" -X "$method" "$url" 2>/dev/null) ;;
    *)
      status=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$url" 2>/dev/null) ;;
  esac
  if [ "$expected" = "$status" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected HTTP: $expected"
    echo "    actual HTTP:   $status"
  fi
}

# ─── Origin + CSRF helper ─────────────────────────────────────────────
# Phase 0 backend-substrate registers OriginMiddleware (rejects unsafe
# methods without an allowlisted Origin) and CSRFMiddleware (rejects
# unsafe methods without matching cookie + X-CSRF-Token). Both run
# before any route handler, so /api/grinder/pause and friends are
# unreachable from a bare curl. prime_csrf does the GET that seeds the
# cookie; auth_curl wraps every unsafe-method curl with the headers
# the middlewares require. DASHBOARD_ALLOWED_ORIGINS is set at uvicorn
# launch so the test's randomized $BASE_URL is in the allowlist.
COOKIE_JAR="$TMPDIR_BASE/cookies.txt"
CSRF_TOKEN=""

prime_csrf() {
  curl -s -c "$COOKIE_JAR" "$BASE_URL/health" >/dev/null 2>&1
  CSRF_TOKEN=$(awk '/csrf_token/ {print $7; exit}' "$COOKIE_JAR" 2>/dev/null || true)
}

auth_curl() {
  curl -s -b "$COOKIE_JAR" \
       -H "Origin: $BASE_URL" \
       -H "X-CSRF-Token: $CSRF_TOKEN" \
       "$@"
}

# ─── Setup: Create test fixture projects ──────────────────────────────

setup_fixtures() {
  local fixtures_root="$TMPDIR_BASE/projects"
  mkdir -p "$fixtures_root"

  # Project 1: active grinder (OIH)
  local p1="$fixtures_root/OIH"
  mkdir -p "$p1/docs/grinder"
  git -C "$p1" init -q 2>/dev/null
  git -C "$p1" checkout -b "main" 2>/dev/null

  cat > "$p1/docs/grinder/grinder-plan.yaml" <<'PLANEOF'
passes:
  - id: pass-mechanical
    name: Mechanical
    batches:
      - id: batch-001
        status: completed
      - id: batch-002
        status: completed
  - id: pass-coverage
    name: Coverage
    batches:
      - id: batch-003
        status: completed
      - id: batch-004
        status: in_progress
  - id: pass-static
    name: Static Analysis
    batches:
      - id: batch-005
        status: pending
      - id: batch-006
        status: pending
  - id: pass-cve
    name: CVE
    batches: []
PLANEOF

  cat > "$p1/docs/grinder/grinder-state.json" <<'STATEEOF'
{
  "current_pass": "pass-coverage",
  "current_batch": "batch-004",
  "started_at": "2026-04-22T10:00:00Z",
  "paused": false
}
STATEEOF

  # Write grinder-stream.ndjson for stream endpoint tests
  cat > "$p1/docs/grinder/grinder-stream.ndjson" <<'STREAMEOF'
{"type":"orchestrator","msg":"batch b1 started"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on batch b1"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"orchestrator","msg":"batch b1 completed"}
{"type":"orchestrator","msg":"batch b2 started"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on batch b2"}]}}
{"type":"orchestrator","msg":"batch b2 completed"}
STREAMEOF

  # Write 10 events as NDJSON
  for i in $(seq 1 10); do
    local ts
    ts=$(printf "2026-04-22T10:%02d:00Z" "$i")
    if [ "$i" -le 3 ]; then
      echo "{\"ts\":\"$ts\",\"batch\":\"batch-001\",\"event\":\"completed\",\"files_fixed\":2}"
    elif [ "$i" -le 6 ]; then
      echo "{\"ts\":\"$ts\",\"batch\":\"batch-002\",\"event\":\"completed\",\"files_fixed\":1}"
    elif [ "$i" -le 8 ]; then
      echo "{\"ts\":\"$ts\",\"batch\":\"batch-003\",\"event\":\"completed\",\"files_fixed\":3}"
    elif [ "$i" -eq 9 ]; then
      echo "{\"ts\":\"$ts\",\"batch\":\"batch-004\",\"event\":\"started\",\"turns\":5}"
    else
      echo "INVALID JSON LINE {"
    fi
  done > "$p1/docs/grinder/events.ndjson"

  cat > "$p1/docs/grinder/deferred-findings.json" <<'DEFEOF'
[
  {"rule": "python:S3776", "count": 15, "example_file": "src/complex.py"},
  {"rule": "python:S1192", "count": 8, "example_file": "src/dup.py"},
  {"rule": "typescript:S6544", "count": 3, "example_file": "app/index.ts"}
]
DEFEOF

  # Project 2: completed grinder (dotfiles)
  local p2="$fixtures_root/dotfiles"
  mkdir -p "$p2/docs/grinder"
  git -C "$p2" init -q 2>/dev/null
  git -C "$p2" checkout -b "main" 2>/dev/null

  cat > "$p2/docs/grinder/grinder-plan.yaml" <<'PLANEOF2'
passes:
  - id: pass-mechanical
    name: Mechanical
    batches:
      - id: batch-a
        status: completed
PLANEOF2

  cat > "$p2/docs/grinder/grinder-state.json" <<'STATEEOF2'
{
  "current_pass": null,
  "current_batch": null,
  "paused": false
}
STATEEOF2

  echo '{"ts":"2026-04-21T12:00:00Z","batch":"batch-a","event":"completed","files_fixed":1}' > "$p2/docs/grinder/events.ndjson"
  echo '[]' > "$p2/docs/grinder/deferred-findings.json"

  # Project 3: no grinder directory (dashboard)
  local p3="$fixtures_root/dashboard"
  mkdir -p "$p3/docs"
  git -C "$p3" init -q 2>/dev/null
  git -C "$p3" checkout -b "main" 2>/dev/null

  # Project 4: grinder dir but missing all data files (partial)
  local p4="$fixtures_root/partial"
  mkdir -p "$p4/docs/grinder"
  git -C "$p4" init -q 2>/dev/null
  git -C "$p4" checkout -b "main" 2>/dev/null
  # Only grinder-plan.yaml — no state, events, deferrals
  cat > "$p4/docs/grinder/grinder-plan.yaml" <<'PLANEOF4'
passes:
  - id: pass-one
    name: First Pass
    batches:
      - id: batch-x
        status: pending
PLANEOF4

  # Project 5: empty stream file (for AS8 test)
  local p5="$fixtures_root/empty-stream"
  mkdir -p "$p5/docs/grinder"
  git -C "$p5" init -q 2>/dev/null
  git -C "$p5" checkout -b "main" 2>/dev/null
  cat > "$p5/docs/grinder/grinder-plan.yaml" <<'PLANEOF5'
passes:
  - id: pass-one
    name: First Pass
    batches: []
PLANEOF5
  touch "$p5/docs/grinder/grinder-stream.ndjson"

  echo "$fixtures_root"
}

# ─── Start server ────────────────────────────────────────────────────

start_server() {
  local fixtures_root="$1"
  port_preflight "$PORT"
  # Post fastapi-cutover (T0.3): boot uvicorn against the FastAPI app and
  # poll /health. PROJECTS_ROOT env hand-off preserved on the uvicorn
  # subprocess so /api/grinder helpers still resolve fixtures.
  local repo_root
  repo_root="$(cd "$PROJECT_ROOT/.." && pwd)"
  local py="python3"
  if [ -x "$repo_root/.venv/bin/python" ]; then
    py="$repo_root/.venv/bin/python"
  fi
  # DASHBOARD_ALLOWED_ORIGINS pinned to the test's randomized port so
  # OriginMiddleware permits same-origin curls. _DEFAULT_ORIGINS hardcodes
  # 8787/5175 which never match a $PORT picked from 9800-9899.
  PROJECTS_ROOT="$fixtures_root" PYTHONPATH="$repo_root" \
    DASHBOARD_ALLOWED_ORIGINS="$BASE_URL" \
    "$py" -m uvicorn \
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
  prime_csrf
}

# ─── Test Cases ───────────────────────────────────────────────────────

# T2.1 — GET /api/grinder: project list (AS1)
test_grinder_list() {
  local out
  out=$(curl -s "$BASE_URL/api/grinder")
  # Should have 4 projects (OIH, dotfiles, partial, empty-stream) — dashboard excluded
  local count
  count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  assert_exit "T2.1 project list has 4 entries" "4" "$count"
  assert_contains "T2.1 list contains OIH" '"OIH"' "$out"
  assert_contains "T2.1 list contains dotfiles" '"dotfiles"' "$out"
  assert_contains "T2.1 list contains partial" '"partial"' "$out"
}

# T2.2 — GET /api/grinder?project=OIH: detail (AS2)
test_grinder_detail() {
  local out
  out=$(curl -s "$BASE_URL/api/grinder?project=OIH")
  assert_contains "T2.2 detail has passes" '"passes"' "$out"
  assert_contains "T2.2 detail has current_batch" '"current_batch"' "$out"
  assert_contains "T2.2 detail has recent_events" '"recent_events"' "$out"
  assert_contains "T2.2 detail has top_deferrals" '"top_deferrals"' "$out"

  # Pass count
  local pass_count
  pass_count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['passes']))" 2>/dev/null || echo "0")
  assert_exit "T2.2 has 4 passes" "4" "$pass_count"

  # Current batch present
  local batch_id
  batch_id=$(echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['current_batch']['id'] if d['current_batch'] else 'null')" 2>/dev/null || echo "err")
  assert_exit "T2.2 current_batch is batch-004" "batch-004" "$batch_id"

  # Events: invalid lines skipped (T1.9), 9 valid out of 10 lines
  local event_count
  event_count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['recent_events']))" 2>/dev/null || echo "0")
  assert_exit "T2.2 recent_events has 9 valid events" "9" "$event_count"

  # Deferrals sorted by count desc
  local first_rule
  first_rule=$(echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin)['top_deferrals']; print(d[0]['rule'] if d else 'none')" 2>/dev/null || echo "err")
  assert_exit "T2.2 top deferral is python:S3776" "python:S3776" "$first_rule"

  # Pass status derivation (T1.14)
  local pass1_status pass2_status pass3_status pass4_status
  pass1_status=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['passes'][0]['status'])" 2>/dev/null || echo "err")
  pass2_status=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['passes'][1]['status'])" 2>/dev/null || echo "err")
  pass3_status=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['passes'][2]['status'])" 2>/dev/null || echo "err")
  pass4_status=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['passes'][3]['status'])" 2>/dev/null || echo "err")
  assert_exit "T1.14 pass-mechanical is completed" "completed" "$pass1_status"
  assert_exit "T1.14 pass-coverage is in_progress" "in_progress" "$pass2_status"
  assert_exit "T1.14 pass-static is pending" "pending" "$pass3_status"
  assert_exit "T1.16 pass-cve (zero batches) is pending" "pending" "$pass4_status"

  # Batch counts
  local p1_completed p1_total
  p1_completed=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['passes'][0]['batches_completed'])" 2>/dev/null || echo "0")
  p1_total=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['passes'][0]['batches_total'])" 2>/dev/null || echo "0")
  assert_exit "T1.14 pass-mechanical batches_completed" "2" "$p1_completed"
  assert_exit "T1.14 pass-mechanical batches_total" "2" "$p1_total"
}

# T2.3 — GET /api/grinder?project=dashboard: not found
test_grinder_not_found() {
  assert_http_status "T2.3 no grinder dir returns 404" "404" "GET" "$BASE_URL/api/grinder?project=dashboard"
}

# T2.4 — Path traversal (AS5)
test_grinder_path_traversal() {
  assert_http_status "T2.4 path traversal returns 400" "400" "GET" "$BASE_URL/api/grinder?project=../../etc"
}

# T2.5 — Unknown project root (AS6)
test_grinder_unknown_root() {
  assert_http_status "T2.5 unknown project returns 404" "404" "GET" "$BASE_URL/api/grinder?project=nonexistent"
}

# T2.6 — POST pause (AS3)
test_grinder_pause() {
  local out
  out=$(auth_curl -X POST "$BASE_URL/api/grinder/pause?project=OIH")
  assert_contains "T2.6 pause returns paused:true" '"paused": true' "$out"
  # Verify PAUSE file was created
  local fixtures_root="$1"
  if [ -f "$fixtures_root/OIH/docs/grinder/PAUSE" ]; then
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  else
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: T2.6 PAUSE file not created"
  fi
}

# T2.7 — DELETE resume (AS3)
test_grinder_resume() {
  local fixtures_root="$1"
  # Ensure PAUSE file exists first
  touch "$fixtures_root/OIH/docs/grinder/PAUSE"
  local out
  out=$(auth_curl -X DELETE "$BASE_URL/api/grinder/pause?project=OIH")
  assert_contains "T2.7 resume returns paused:false" '"paused": false' "$out"
  if [ ! -f "$fixtures_root/OIH/docs/grinder/PAUSE" ]; then
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  else
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: T2.7 PAUSE file not removed"
  fi
}

# T2.8 — POST pause missing project param
test_grinder_pause_missing_param() {
  assert_http_status "T2.8 POST pause missing project returns 400" "400" "POST" "$BASE_URL/api/grinder/pause"
}

# T2.9 — DELETE pause missing project param
test_grinder_resume_missing_param() {
  assert_http_status "T2.9 DELETE pause missing project returns 400" "400" "DELETE" "$BASE_URL/api/grinder/pause"
}

# T2.10 — Graceful degradation (AS4)
test_grinder_degradation() {
  local out
  out=$(curl -s "$BASE_URL/api/grinder?project=partial")
  assert_contains "T2.10 partial has passes" '"passes"' "$out"
  # current_batch should be null
  local batch
  batch=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['current_batch'])" 2>/dev/null || echo "err")
  assert_exit "T2.10 current_batch is null" "None" "$batch"
  # recent_events should be empty
  local ev_count
  ev_count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['recent_events']))" 2>/dev/null || echo "err")
  assert_exit "T2.10 recent_events is empty" "0" "$ev_count"
  # top_deferrals should be empty
  local def_count
  def_count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['top_deferrals']))" 2>/dev/null || echo "err")
  assert_exit "T2.10 top_deferrals is empty" "0" "$def_count"
  # All passes should be pending since no state
  local p_status
  p_status=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['passes'][0]['status'])" 2>/dev/null || echo "err")
  assert_exit "T2.10 pass is pending when no state" "pending" "$p_status"
}

# T2.12/T2.13 — validate_project_name
test_project_name_validation() {
  # Empty project= is treated as absent by parse_qs — returns project list (200)
  assert_http_status "T2.13 empty project returns list" "200" "GET" "$BASE_URL/api/grinder?project="
  assert_http_status "T2.13 project with spaces returns 400" "400" "GET" "$BASE_URL/api/grinder?project=foo%20bar"
  assert_http_status "T2.13 project with slashes returns 400" "400" "GET" "$BASE_URL/api/grinder?project=foo/bar"
}

# T1.24 — create_pause idempotent
test_grinder_pause_idempotent() {
  local fixtures_root="$1"
  # First pause
  auth_curl -X POST "$BASE_URL/api/grinder/pause?project=dotfiles" >/dev/null
  # Second pause — should not error
  local out
  out=$(auth_curl -X POST "$BASE_URL/api/grinder/pause?project=dotfiles")
  assert_contains "T1.24 idempotent pause returns true" '"paused": true' "$out"
  # Clean up
  rm -f "$fixtures_root/dotfiles/docs/grinder/PAUSE"
}

# T1.26 — remove_pause idempotent (no file)
test_grinder_resume_idempotent() {
  # Remove when no PAUSE file exists — should not error
  local out
  out=$(auth_curl -X DELETE "$BASE_URL/api/grinder/pause?project=dotfiles")
  assert_contains "T1.26 idempotent resume returns false" '"paused": false' "$out"
}

# ─── Stream endpoint tests (C3) ──────────────────────────────────────

# C3.1 — Valid stream request
test_grinder_stream_valid() {
  local out status
  status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/grinder/stream?project=OIH&offset=0" 2>/dev/null)
  assert_exit "C3.1 stream returns 200" "200" "$status"

  out=$(curl -s "$BASE_URL/api/grinder/stream?project=OIH&offset=0")
  assert_contains "C3.1 has events array" '"events"' "$out"
  assert_contains "C3.1 has offset" '"offset"' "$out"
  assert_contains "C3.1 has project" '"project"' "$out"

  local event_count
  event_count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['events']))" 2>/dev/null || echo "err")
  assert_exit "C3.1 has 7 events" "7" "$event_count"
}

# C3.2 — Missing project param
test_grinder_stream_missing_project() {
  assert_http_status "C3.2 missing project returns 400" "400" "GET" "$BASE_URL/api/grinder/stream"
}

# C3.3 — Invalid project name (path traversal)
test_grinder_stream_invalid_project() {
  assert_http_status "C3.3 path traversal returns 400" "400" "GET" "$BASE_URL/api/grinder/stream?project=../etc"
}

# C3.4 — Project without stream file
test_grinder_stream_no_file() {
  assert_http_status "C3.4 no stream file returns 404" "404" "GET" "$BASE_URL/api/grinder/stream?project=partial&offset=0"
}

# C3.5 — Non-existent project
test_grinder_stream_nonexistent() {
  assert_http_status "C3.5 nonexistent project returns 404" "404" "GET" "$BASE_URL/api/grinder/stream?project=nonexistent&offset=0"
}

# C3.6 — Negative offset
test_grinder_stream_negative_offset() {
  assert_http_status "C3.6 negative offset returns 400" "400" "GET" "$BASE_URL/api/grinder/stream?project=OIH&offset=-1"
}

# C3.7 — Non-numeric offset
test_grinder_stream_bad_offset() {
  assert_http_status "C3.7 non-numeric offset returns 400" "400" "GET" "$BASE_URL/api/grinder/stream?project=OIH&offset=abc"
}

# C3.8 — Batch filter
test_grinder_stream_batch_filter() {
  local out
  out=$(curl -s "$BASE_URL/api/grinder/stream?project=OIH&offset=0&batch=b1")
  local count
  count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['events']))" 2>/dev/null || echo "err")
  assert_exit "C3.8 batch b1 has 4 events" "4" "$count"
}

# C3.9 — Invalid batch ID
test_grinder_stream_invalid_batch() {
  assert_http_status "C3.9 invalid batch returns 400" "400" "GET" "$BASE_URL/api/grinder/stream?project=OIH&offset=0&batch=../../"
}

# C3.10 — Offset beyond file size
test_grinder_stream_offset_beyond() {
  local out
  out=$(curl -s "$BASE_URL/api/grinder/stream?project=OIH&offset=999999")
  local count
  count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['events']))" 2>/dev/null || echo "err")
  assert_exit "C3.10 offset beyond returns 0 events" "0" "$count"
}

# C3.11 — Empty stream file
test_grinder_stream_empty() {
  local out
  out=$(curl -s "$BASE_URL/api/grinder/stream?project=empty-stream&offset=0")
  local count
  count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['events']))" 2>/dev/null || echo "err")
  assert_exit "C3.11 empty stream returns 0 events" "0" "$count"
}

# C3.12 — Default offset (omitted)
test_grinder_stream_default_offset() {
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/grinder/stream?project=OIH" 2>/dev/null)
  assert_exit "C3.12 omitted offset returns 200" "200" "$status"
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "Grinder API endpoint tests"

FIXTURES_ROOT=$(setup_fixtures)
start_server "$FIXTURES_ROOT"

test_grinder_list
test_grinder_detail
test_grinder_not_found
test_grinder_path_traversal
test_grinder_unknown_root
test_grinder_pause "$FIXTURES_ROOT"
test_grinder_resume "$FIXTURES_ROOT"
test_grinder_pause_missing_param
test_grinder_resume_missing_param
test_grinder_degradation
test_project_name_validation
test_grinder_pause_idempotent "$FIXTURES_ROOT"
test_grinder_resume_idempotent

# Stream endpoint tests
test_grinder_stream_valid
test_grinder_stream_missing_project
test_grinder_stream_invalid_project
test_grinder_stream_no_file
test_grinder_stream_nonexistent
test_grinder_stream_negative_offset
test_grinder_stream_bad_offset
test_grinder_stream_batch_filter
test_grinder_stream_invalid_batch
test_grinder_stream_offset_beyond
test_grinder_stream_empty
test_grinder_stream_default_offset

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
