#!/usr/bin/env bash
# Manual smoke recipe for T0.2.a fastapi-routes-port-core (Eval-3, MT-1..MT-9).
#
# Bundles the curl probes documented in TESTPLAN.md § Manual Test Scenarios
# into one regression oracle. NOT wired into run-all.sh per R13. Invoke from
# /manualtest or ad-hoc when investigating a SPA / API contract drift.
#
# Usage:
#   bash dashboard/tests/manual-smoke-fastapi-routes-port-core.sh
#
# The script launches uvicorn on 127.0.0.1:8798 against the worktree's app
# (default _SPA_ROOT, which falls back to dashboard/ when dist/ is absent),
# polls /health, runs the probes, and tears down. Exit 0 on full pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DASHBOARD_DIR/.." && pwd)"
PORT=8798
BASE="http://127.0.0.1:${PORT}"

if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
  echo "  SKIP: workspace .venv not provisioned — run: cd $REPO_ROOT && uv sync --extra dev"
  exit 0
fi

echo "==> MT-1: route enumeration"
PYTHONPATH="$REPO_ROOT" "$REPO_ROOT/.venv/bin/python" -c "
from dashboard.server.app import app
print(sorted({getattr(r,'path',str(r)) for r in app.routes}))
"

echo "==> Launching uvicorn on 127.0.0.1:${PORT}"
PYTHONPATH="$REPO_ROOT" "$REPO_ROOT/.venv/bin/python" -m uvicorn \
  dashboard.server.app:app --host 127.0.0.1 --port "$PORT" \
  >/tmp/manual-smoke-uvicorn.log 2>&1 &
UVICORN_PID=$!
trap 'kill "$UVICORN_PID" 2>/dev/null || true; wait "$UVICORN_PID" 2>/dev/null || true' EXIT

# Poll /health up to 10s
for _ in $(seq 1 50); do
  if curl -sf -o /dev/null "${BASE}/health"; then break; fi
  sleep 0.2
done
curl -sf -o /dev/null "${BASE}/health" || { echo "uvicorn failed to start"; cat /tmp/manual-smoke-uvicorn.log; exit 1; }

run_status_check() {
  local label="$1" expected="$2" url="$3"
  local actual
  actual=$(curl -sS -o /dev/null -w '%{http_code}' "$url")
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  ${label}: ${url} → ${actual}"
  else
    echo "  FAIL  ${label}: ${url} → ${actual} (expected ${expected})"
    return 1
  fi
}

echo "==> MT-3 / EC-10.1: unported /api/* returns JSON 404"
run_status_check "MT-3 unported"  "404" "${BASE}/api/autopilots"

echo "==> MT-3: in-batch /api/sessions returns 200"
run_status_check "MT-3 sessions" "200" "${BASE}/api/sessions"

echo "==> MT-4 / AS-4: /api/flow-status missing cwd → 400"
run_status_check "MT-4 missing"  "400" "${BASE}/api/flow-status"

echo "==> MT-4 (Risk-F): /api/flow-status?cwd= → 200 (empty cwd is NOT 400)"
run_status_check "MT-4 empty"    "200" "${BASE}/api/flow-status?cwd="

echo "==> MT-5 / AS-5: /api/plan?cwd=/etc → 403 (cwd outside HOME)"
run_status_check "MT-5 forbidden" "403" "${BASE}/api/plan?cwd=/etc"

echo "==> MT-6 / AS-6: /api/metrics?sid=evil%2Fpath → 400"
run_status_check "MT-6 bad sid"   "400" "${BASE}/api/metrics?sid=evil%2Fpath"

echo "==> MT-6: /api/metrics?since=not-a-date → 400"
run_status_check "MT-6 bad since" "400" "${BASE}/api/metrics?since=not-a-date"

echo "==> MT-6: /api/metrics → 200"
run_status_check "MT-6 metrics ok" "200" "${BASE}/api/metrics"

echo "==> MT-6 (Risk-B): /api/metrics?sid= → 200 (empty sid short-circuits)"
run_status_check "MT-6 empty sid" "200" "${BASE}/api/metrics?sid="

echo "==> ALL PROBES PASSED"
