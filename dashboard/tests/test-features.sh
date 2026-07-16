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

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-features"
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
  rm -rf "$PROJECT_ROOT/docs/INPROGRESS_Feature_test-feat"
  rm -rf "$PROJECT_ROOT/docs/INPROGRESS_Feature_test-empty"
}
trap cleanup EXIT

# ─── Assertions ──────────────────────────────────────────────────────

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
    echo "    output: $(echo "$haystack" | head -3)"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected NOT to contain: $needle"
  else
    PASS=$((PASS + 1))
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
  # Create a feature docs dir with some artifacts
  local feature_dir="$PROJECT_ROOT/docs/INPROGRESS_Feature_test-feat"
  mkdir -p "$feature_dir"
  echo "# Requirements" > "$feature_dir/REQUIREMENTS.md"
  echo "# Plan" > "$feature_dir/PLAN.md"

  # Create an empty feature docs dir (E1)
  mkdir -p "$PROJECT_ROOT/docs/INPROGRESS_Feature_test-empty"

  # Create sessions.jsonl with test events
  local data_dir="$TMPDIR_BASE/data"
  mkdir -p "$data_dir"
  # Use the actual project root in cwd so _guess_project_root resolves correctly
  cat > "$data_dir/sessions.jsonl" << JSONL
{"sid":"sess-1","event":"PreToolUse","type":"Read","fp":"src/main.ts","branch":"feature/test-feat","cwd":"$PROJECT_ROOT","ts":"2026-01-01T00:00:01Z"}
{"sid":"sess-1","event":"PreToolUse","type":"Write","fp":"src/main.ts","branch":"feature/test-feat","cwd":"$PROJECT_ROOT","ts":"2026-01-01T00:00:02Z"}
{"sid":"sess-2","event":"PreToolUse","type":"Read","fp":"a.ts","branch":"feature/other-feat","cwd":"$PROJECT_ROOT","ts":"2026-01-01T00:00:03Z"}
{"sid":"sess-3","event":"PreToolUse","type":"Read","fp":"b.ts","branch":"bugfix/not-a-feature","cwd":"$PROJECT_ROOT","ts":"2026-01-01T00:00:04Z"}
JSONL
  # Save original for restoring after stuck test
  cp "$data_dir/sessions.jsonl" "$data_dir/sessions.jsonl.bak"

  # Create stuck session events
  cat > "$data_dir/sessions-stuck.jsonl" << JSONL
{"sid":"stuck-1","event":"PreToolUse","type":"Read","fp":"src/auth.ts","branch":"feature/stuck-test","cwd":"$PROJECT_ROOT","ts":"2026-01-01T00:00:01Z"}
{"sid":"stuck-1","event":"PreToolUse","type":"Read","fp":"src/auth.ts","branch":"feature/stuck-test","cwd":"$PROJECT_ROOT","ts":"2026-01-01T00:00:02Z"}
{"sid":"stuck-1","event":"PreToolUse","type":"Read","fp":"src/auth.ts","branch":"feature/stuck-test","cwd":"$PROJECT_ROOT","ts":"2026-01-01T00:00:03Z"}
JSONL
}

PROJECTS_PARENT="$(dirname "$PROJECT_ROOT")"

start_server() {
  port_preflight "$PORT"
  # Post fastapi-cutover (T0.3): boot uvicorn against the FastAPI app and
  # poll /health. DASHBOARD_DATA_DIR / PROJECTS_ROOT env hand-off preserved.
  local repo_root
  repo_root="$(cd "$PROJECT_ROOT/.." && pwd)"
  local py="python3"
  if [ -x "$repo_root/.venv/bin/python" ]; then
    py="$repo_root/.venv/bin/python"
  fi
  DASHBOARD_DATA_DIR="$TMPDIR_BASE/data" PROJECTS_ROOT="$PROJECTS_PARENT" \
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

# ─── Tests: /api/features ───────────────────────────────────────────

test_features_returns_array() {
  echo "  API-1: /api/features returns JSON array"
  local out
  out=$(curl -s "$BASE_URL/api/features")
  assert_contains "features is array" "[" "$out"
}

test_features_has_required_fields() {
  echo "  API-2: Features include required fields"
  local out
  out=$(curl -s "$BASE_URL/api/features")
  # test-feat should be discovered from docs
  assert_contains "has name field" '"name"' "$out"
  assert_contains "has phase field" '"phase"' "$out"
  assert_contains "has status field" '"status"' "$out"
  assert_contains "has test-feat" "test-feat" "$out"
}

test_features_empty_state() {
  echo "  API-3: Empty docs folder shows up (E1)"
  local out
  out=$(curl -s "$BASE_URL/api/features")
  assert_contains "has test-empty" "test-empty" "$out"
}

# ─── Tests: /api/feature/artifacts ───────────────────────────────────

test_artifacts_list() {
  echo "  API-4: /api/feature/artifacts returns list"
  local out
  out=$(curl -s "$BASE_URL/api/feature/artifacts?feature=test-feat&project_root=$PROJECT_ROOT")
  assert_contains "has REQUIREMENTS.md" "REQUIREMENTS.md" "$out"
  assert_contains "has PLAN.md" "PLAN.md" "$out"
}

test_artifacts_missing_feature() {
  echo "  API-5: Missing feature param → 400"
  assert_http_status "missing feature" "400" "$BASE_URL/api/feature/artifacts"
}

test_artifacts_missing_root() {
  echo "  API-6: Missing project_root → 400"
  assert_http_status "missing root" "400" "$BASE_URL/api/feature/artifacts?feature=test"
}

test_artifacts_unknown_root() {
  echo "  API-7: Unknown project root → 403"
  assert_http_status "unknown root" "403" "$BASE_URL/api/feature/artifacts?feature=test&project_root=/etc"
}

test_artifacts_nonexistent_feature() {
  echo "  API-8: Nonexistent feature dir → empty array"
  local out
  out=$(curl -s "$BASE_URL/api/feature/artifacts?feature=nonexistent&project_root=$PROJECT_ROOT")
  assert_eq "empty array" "[]" "$out"
}

# ─── Tests: /api/feature/artifact ────────────────────────────────────

test_artifact_content() {
  echo "  API-9: Returns artifact content"
  local out
  out=$(curl -s "$BASE_URL/api/feature/artifact?feature=test-feat&project_root=$PROJECT_ROOT&file=REQUIREMENTS.md")
  assert_contains "has content" "Requirements" "$out"
  assert_contains "has file field" '"file"' "$out"
}

test_artifact_traversal_dotdot() {
  echo "  API-10: Path traversal with ../ → 400"
  assert_http_status "traversal .." "400" "$BASE_URL/api/feature/artifact?feature=test-feat&project_root=$PROJECT_ROOT&file=../../../etc/passwd"
}

test_artifact_traversal_slash() {
  echo "  API-11: Path traversal with / → 400"
  assert_http_status "traversal /" "400" "$BASE_URL/api/feature/artifact?feature=test-feat&project_root=$PROJECT_ROOT&file=/etc/passwd"
}

test_artifact_not_in_allowlist() {
  echo "  API-12: File not in allowlist → 400"
  assert_http_status "not allowed" "400" "$BASE_URL/api/feature/artifact?feature=test-feat&project_root=$PROJECT_ROOT&file=secrets.env"
}

test_artifact_not_found() {
  echo "  API-13: Allowed file but doesn't exist → 404"
  assert_http_status "not found" "404" "$BASE_URL/api/feature/artifact?feature=test-feat&project_root=$PROJECT_ROOT&file=DESIGN.md"
}

test_artifact_invalid_root() {
  echo "  API-14: Invalid project root → 403"
  assert_http_status "invalid root" "403" "$BASE_URL/api/feature/artifact?feature=foo&project_root=/etc&file=REQUIREMENTS.md"
}

# ─── Tests: Stuck detection via feature_helpers ──────────────────────

test_stuck_detection_integration() {
  echo "  FH-10: Stuck detection propagates to feature status"
  # Use the stuck-session JSONL data
  local result
  result=$(DASHBOARD_DATA_DIR="$TMPDIR_BASE/data" PROJECTS_ROOT="$PROJECTS_PARENT" python3 << PYEOF
import sys, os, json
sys.path.insert(0, '$PROJECT_ROOT')
os.environ['DASHBOARD_DATA_DIR'] = '$TMPDIR_BASE/data'
os.environ['PROJECTS_ROOT'] = '$PROJECTS_PARENT'
# Use stuck sessions data
stuck_jsonl = os.path.join('$TMPDIR_BASE/data', 'sessions-stuck.jsonl')
normal_jsonl = os.path.join('$TMPDIR_BASE/data', 'sessions.jsonl')
import shutil
shutil.copy2(stuck_jsonl, normal_jsonl)

from server import feature_helpers
feature_helpers._cache["ts"] = 0
features = feature_helpers.discover_features()
for f in features:
    if f["name"] == "stuck-test":
        print(json.dumps({"status": f["status"], "stuck_info": f.get("stuck_info")}))
        break
else:
    print(json.dumps({"status": "not_found"}))
PYEOF
)
  local status
  status=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
  assert_eq "FH-10 stuck status" "stuck" "$status"
}

test_non_feature_branches_excluded() {
  echo "  FH-7: Non-feature branches excluded (E2)"
  local out
  out=$(curl -s "$BASE_URL/api/features")
  assert_not_contains "no bugfix branch" "not-a-feature" "$out"
}

test_removed_worktree_excluded() {
  echo "  FH-11: Session-only features with missing worktree excluded"
  # Scenario: Feature was worked on in a worktree that has since been removed
  # (after /done). sessions.jsonl still has old events, but project_root no
  # longer exists on disk. The feature should NOT appear as active.
  local result
  result=$(DASHBOARD_DATA_DIR="$TMPDIR_BASE/data" PROJECTS_ROOT="$PROJECTS_PARENT" python3 << PYEOF
import sys, os, json
sys.path.insert(0, '$PROJECT_ROOT')
os.environ['DASHBOARD_DATA_DIR'] = '$TMPDIR_BASE/data'
os.environ['PROJECTS_ROOT'] = '$PROJECTS_PARENT'

# Write a sessions.jsonl where the cwd points to a now-removed worktree
missing_wt = os.path.join('$PROJECTS_PARENT', 'does-not-exist-worktree')
jsonl = os.path.join('$TMPDIR_BASE/data', 'sessions.jsonl')
with open(jsonl, 'w') as f:
    f.write(json.dumps({
        "sid": "autopilot-removed-feat-1",
        "event": "PreToolUse",
        "type": "Read",
        "branch": "feature/removed-feat",
        "cwd": missing_wt,
        "ts": "2026-04-18T10:00:00Z"
    }) + "\n")

from server import feature_helpers
feature_helpers._cache["ts"] = 0
features = feature_helpers.discover_features()
names = [f["name"] for f in features]
print(json.dumps({"names": names}))
PYEOF
)
  local has_removed
  has_removed=$(echo "$result" | python3 -c "import sys,json; print('removed-feat' in json.load(sys.stdin)['names'])")
  assert_eq "FH-11 removed worktree excluded" "False" "$has_removed"
}

# ─── Run ─────────────────────────────────────────────────────────────

echo "=== Feature API Tests ==="

setup_test_fixtures
start_server

# Stuck detection (runs before server tests, uses direct Python)
test_stuck_detection_integration
# Restore original sessions.jsonl after stuck test
cp "$TMPDIR_BASE/data/sessions.jsonl.bak" "$TMPDIR_BASE/data/sessions.jsonl"

# Removed-worktree exclusion (uses direct Python, mutates sessions.jsonl)
test_removed_worktree_excluded
# Restore original sessions.jsonl
cp "$TMPDIR_BASE/data/sessions.jsonl.bak" "$TMPDIR_BASE/data/sessions.jsonl"

# API endpoint tests
test_features_returns_array
test_features_has_required_fields
test_features_empty_state
test_non_feature_branches_excluded

test_artifacts_list
test_artifacts_missing_feature
test_artifacts_missing_root
test_artifacts_unknown_root
test_artifacts_nonexistent_feature

test_artifact_content
test_artifact_traversal_dotdot
test_artifact_traversal_slash
test_artifact_not_in_allowlist
test_artifact_not_found
test_artifact_invalid_root

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="
[ "$FAIL" -eq 0 ]
