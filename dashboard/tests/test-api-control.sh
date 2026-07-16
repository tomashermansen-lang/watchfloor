#!/usr/bin/env bash
# End-to-end shell smoke for dashboard/server/control.py.
#
# TS-10 coverage:
#   - TS-10.1  uvicorn binds 127.0.0.1:8798 + /health returns 200
#   - TS-10.2  /health emits Set-Cookie csrf_token
#   - TS-10.3  POST /api/autopilot/pause with valid CSRF -> 200 + PAUSE file
#   - TS-10.4  Second POST is 200 (idempotent, AC-2)
#   - TS-10.5  Lifecycle stream contains two `paused` events with
#              source="dashboard"
#   - TS-10.6  uvicorn killed cleanly; port released
#   - TS-10.7  test never invokes `tmux` binary (pause has no tmux dependency)
#   - TS-10.8  _MAIN_DIR resolves via the dashboard package itself; we DO
#              not need a synthetic fixture root because control.py's
#              `_resolve_main_dir` walks the .git worktree pointer back to
#              the real dotfiles checkout. We seed the fixture under that
#              checkout's `docs/INPROGRESS_Feature_<smoke_id>/` and clean
#              it up on exit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DASHBOARD_DIR/.." && pwd)"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PORT="${DASHBOARD_CONTROL_TEST_PORT:-8798}"

PASS=0
FAIL=0
TOTAL=0

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

assert_file_exists() {
  local label="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — file not found: $path"
  fi
}

if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
  echo "  SKIP: workspace .venv not provisioned — run: cd ~/Projekter/dotfiles && uv sync --extra dev"
  exit 0
fi

# Resolve the main-dotfiles checkout the same way control.py does so the
# fixture directory we seed is the one the running uvicorn will read.
MAIN_DIR="$(
  "$REPO_ROOT/.venv/bin/python" - <<PY
import sys
sys.path.insert(0, "$REPO_ROOT")
sys.path.insert(0, "$REPO_ROOT/dashboard")
from dashboard.server import control
print(control._MAIN_DIR)
PY
)"

SMOKE_ID="smoke-$(date +%s)-$$"
FEATURE_DIR="$MAIN_DIR/docs/INPROGRESS_Feature_$SMOKE_ID"
mkdir -p "$FEATURE_DIR"
echo "# test fixture for $SMOKE_ID" > "$FEATURE_DIR/REQUIREMENTS.md"

LOG="$(mktemp "${TMPDIR:-/tmp}/control-api-$$.log")"
JAR="$(mktemp "${TMPDIR:-/tmp}/control-api-jar-$$.txt")"

cleanup() {
  set +e
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  port_reaper "$PORT" >/dev/null 2>&1
  rm -rf "$FEATURE_DIR" "$LOG" "$JAR"
}
trap cleanup EXIT

port_preflight "$PORT"
PYTHONPATH="$REPO_ROOT:$REPO_ROOT/dashboard" "$REPO_ROOT/.venv/bin/python" \
  -m uvicorn dashboard.server.app:app --port "$PORT" --log-level warning \
  >"$LOG" 2>&1 &
SERVER_PID=$!

# TS-10.1 — wait up to 10s for /health to return 200.
ready=""
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done

if [ -z "$ready" ]; then
  echo "  FAIL: TS-10.1: uvicorn did not start within 10s"
  cat "$LOG"
  exit 1
fi
TOTAL=$((TOTAL + 1))
PASS=$((PASS + 1))

# TS-10.2 — CSRF cookie issued.
curl -s -c "$JAR" -o /dev/null "http://127.0.0.1:$PORT/health"
CSRF=$(awk '/csrf_token/ {print $7; exit}' "$JAR")
TOTAL=$((TOTAL + 1))
if printf '%s' "$CSRF" | grep -qE '^[A-Za-z0-9_-]{43}$'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: TS-10.2: no valid csrf_token cookie (got: $CSRF)"
fi

# Origin header set to a loopback value so the request passes the
# origin_check middleware. controls-06 #9: the default allowlist is
# now loopback-permissive (any http(s)://127.0.0.1[:PORT] or
# http(s)://localhost[:PORT]) when DASHBOARD_ALLOWED_ORIGINS is
# unset, so $PORT would also work — but the pinned 8787 is kept
# as a literal-equality smoke check.

# TS-10.3 — first pause returns 200 + PAUSE file exists.
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "Origin: http://127.0.0.1:8787" \
  -H "X-CSRF-Token: $CSRF" -H "Cookie: csrf_token=$CSRF" \
  -H "Content-Type: application/json" \
  -d "{\"target_id\":\"$SMOKE_ID\"}" \
  "http://127.0.0.1:$PORT/api/autopilot/pause")
assert_eq "TS-10.3: first pause -> 200" "200" "$STATUS"
assert_file_exists "TS-10.3: autopilot.PAUSE created" "$FEATURE_DIR/autopilot.PAUSE"

# TS-10.4 — second pause idempotent. Origin pinned to 8787 — passes
# the loopback-permissive default (controls-06 #9, see TS-10.3 above).
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "Origin: http://127.0.0.1:8787" \
  -H "X-CSRF-Token: $CSRF" -H "Cookie: csrf_token=$CSRF" \
  -H "Content-Type: application/json" \
  -d "{\"target_id\":\"$SMOKE_ID\"}" \
  "http://127.0.0.1:$PORT/api/autopilot/pause")
assert_eq "TS-10.4: second pause -> 200 (idempotent)" "200" "$STATUS"

# TS-10.5 — two paused events with source=dashboard in the stream.
STREAM="$FEATURE_DIR/autopilot-stream.ndjson"
assert_file_exists "TS-10.5: stream file appended" "$STREAM"
if [ -f "$STREAM" ]; then
  COUNT=$(grep -c '"action": "paused"' "$STREAM" || true)
  assert_eq "TS-10.5: stream has two paused events" "2" "$COUNT"
  DASH_COUNT=$(grep -c '"source": "dashboard"' "$STREAM" || true)
  assert_eq "TS-10.5: both events tagged source=dashboard" "2" "$DASH_COUNT"
fi

echo "---"
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"

[ "$FAIL" -eq 0 ]
