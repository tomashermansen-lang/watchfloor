#!/usr/bin/env bash
# End-to-end integration suite for the FastAPI app skeleton (T0.1).
# Covers INT-01..INT-06.
#
# Runs by default in run-all.sh — uvicorn IS the production runtime after
# fastapi-cutover (T0.3). Still SKIPs cleanly if the workspace .venv is
# missing (operator just hasn't run `uv sync --extra dev` yet).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DASHBOARD_DIR/.." && pwd)"
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PORT="${DASHBOARD_FASTAPI_TEST_PORT:-8798}"

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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    output (head): $(printf '%s' "$haystack" | head -3)"
  fi
}

if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
  echo "  SKIP: workspace .venv not provisioned — run: cd ~/Projekter/dotfiles && uv sync --extra dev"
  exit 0
fi

cd "$DASHBOARD_DIR"

# ─── INT-01: dependency import sanity ────────────────────────────────
set +e
"$REPO_ROOT/.venv/bin/python" -c "import fastapi, uvicorn, pydantic, httpx" >/dev/null 2>&1
exit_code=$?
set -e
assert_eq "INT-01: runtime + dev imports succeed" "0" "$exit_code"

# ─── INT-02: launch uvicorn, verify /health contract + bind addr ──────
LOG="$(mktemp "${TMPDIR:-/tmp}/fastapi-int.XXXXXX")"
trap 'set +e; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null; { [[ -n "${SERVER_PID:-}" ]] && port_reaper "$PORT"; } || true; rm -f "$LOG"' EXIT

port_preflight "$PORT"
PYTHONPATH="$REPO_ROOT" "$REPO_ROOT/.venv/bin/python" -m uvicorn dashboard.server.app:app \
  --port "$PORT" --log-level info >"$LOG" 2>&1 &
SERVER_PID=$!

# Wait for "Uvicorn running" message (max 10s).
for _ in $(seq 1 50); do
  if grep -q "Uvicorn running" "$LOG" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if ! grep -q "Uvicorn running" "$LOG"; then
  echo "  FAIL: INT-02: uvicorn did not start within 10s"
  echo "  --- LOG ---"
  cat "$LOG"
  exit 1
fi

set +e
HEALTH_BODY=$(curl -sf "http://127.0.0.1:$PORT/health")
HEALTH_EXIT=$?
set -e
assert_eq "INT-02: /health returns 200 OK" "0" "$HEALTH_EXIT"
assert_contains "INT-02: body contains 'status':'ok'" '"status":"ok"' "$HEALTH_BODY"
assert_contains "INT-02: body contains 'version'" '"version"' "$HEALTH_BODY"
assert_contains "INT-02: body contains 'ts'" '"ts"' "$HEALTH_BODY"

# Bind address: must be 127.0.0.1 (R6 / DN-7).
if command -v lsof >/dev/null 2>&1; then
  set +e
  BIND_INFO=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -1)
  set -e
  assert_contains "INT-02 (AS-9): bound to 127.0.0.1, NOT 0.0.0.0" "127.0.0.1:$PORT" "$BIND_INFO"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$BIND_INFO" | grep -qE '0\.0\.0\.0|\*:'; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: INT-02 (AS-9): bound to wildcard address"
    echo "    info: $BIND_INFO"
  else
    PASS=$((PASS + 1))
  fi
else
  echo "  SKIP: INT-02 bind-address check (lsof not in PATH)"
fi

# ─── INT-03: JSON access log shape on success path ───────────────────
set +e
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null
sleep 0.5
set -e
TAIL_LINE=$(tail -1 "$LOG")
assert_contains "INT-03 (R5, AS-3): access log line is JSON with method=GET" '"method": "GET"' "$TAIL_LINE"
assert_contains "INT-03: path=/health" '"path": "/health"' "$TAIL_LINE"
assert_contains "INT-03: status=200" '"status": 200' "$TAIL_LINE"
assert_contains "INT-03: duration_ms field present" '"duration_ms"' "$TAIL_LINE"

# ─── INT-04: unported /api/* path emits log line with status=404 ─────
# /api/nope hits the explicit /api/{rest:path} 404 catch-all
# (app.py:_compose_routes). A bare /nope is absorbed by the SPA static
# mount and returns 200 with index.html — that's SPA fallback behaviour,
# not the 404 path we want to verify here.
set +e
NOPE_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/nope" || true)
set -e
assert_eq "INT-04 (AS-4): GET /api/nope returns 404" "404" "$NOPE_CODE"
sleep 0.3
TAIL_LINE=$(tail -1 "$LOG")
assert_contains "INT-04: 404 access log line records path=/api/nope" '"path": "/api/nope"' "$TAIL_LINE"
assert_contains "INT-04: 404 access log line records status=404" '"status": 404' "$TAIL_LINE"

# ─── INT-05: opt-out env var lets uvicorn --log-config win (EC-5.4) ───
# Stop the existing server first.
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
[ -n "${SERVER_PID:-}" ] && port_reaper "$PORT" || true

INT05_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fastapi-int05.XXXXXX")"
CUSTOM_LOG_CFG="$INT05_DIR/log-config.json"
SENTINEL_LOG="$INT05_DIR/sentinel.log"
cat >"$CUSTOM_LOG_CFG" <<EOF
{
  "version": 1,
  "disable_existing_loggers": false,
  "formatters": {
    "sentinel": {"format": "CUSTOM-WINS-%(message)s"}
  },
  "handlers": {
    "sentinel_handler": {
      "class": "logging.FileHandler",
      "formatter": "sentinel",
      "filename": "$SENTINEL_LOG"
    }
  },
  "loggers": {
    "uvicorn.access": {"handlers": ["sentinel_handler"], "level": "INFO", "propagate": false}
  }
}
EOF

LOG2="$(mktemp "${TMPDIR:-/tmp}/fastapi-int2.XXXXXX")"
port_preflight "$PORT"
DASHBOARD_LOG_CONFIG_OPT_OUT=1 PYTHONPATH="$REPO_ROOT" \
  "$REPO_ROOT/.venv/bin/python" -m uvicorn dashboard.server.app:app \
  --port "$PORT" --log-config "$CUSTOM_LOG_CFG" >"$LOG2" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if grep -q "Uvicorn running" "$LOG2" 2>/dev/null; then break; fi
  sleep 0.2
done

set +e
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null
sleep 0.5
SENTINEL_CONTENT=$(cat "$SENTINEL_LOG" 2>/dev/null || true)
set -e

assert_contains "INT-05 (EC-5.4): custom --log-config wins (sentinel observed)" \
  "CUSTOM-WINS" "$SENTINEL_CONTENT"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
[ -n "${SERVER_PID:-}" ] && port_reaper "$PORT" || true
rm -rf "$INT05_DIR"
rm -f "$LOG2"

# ─── INT-06: regression — main test runner not implemented here ──────
# (run-all.sh aggregates the FastAPI suites; it will be validated holistically
# during /qa per AS-8.)

echo ""
printf "FastAPI integration: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
