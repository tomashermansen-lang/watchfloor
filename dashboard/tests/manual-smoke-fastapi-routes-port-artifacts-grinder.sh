#!/usr/bin/env bash
# Manual smoke recipe for T0.2.c fastapi-routes-port-artifacts-grinder
# (Eval-3, AS-3 + AS-4). Bundles the curl probes that exercise the 8 newly-
# ported artifact + grinder endpoints AND the POST/DELETE method-routing
# distinction on /api/grinder/pause. NOT wired into run-all.sh per R12 —
# invoke from /manualtest or ad-hoc when investigating drift in the
# stdlib HTML template / artifact-grinder route family. Predecessor
# companion script for the autopilot port batch lives at
# manual-smoke-fastapi-routes-port-autopilot.sh.
#
# Usage:
#   bash dashboard/tests/manual-smoke-fastapi-routes-port-artifacts-grinder.sh
#
# Launches uvicorn on 127.0.0.1:8798, polls /health, runs the probes,
# tears down. Exit 0 on full pass with "All assertions passed." as the
# last line; first failed probe exits non-zero with the probe label and
# the observed HTTP status code.
#
# Convention: ALL response checks MUST go through assert_status. Bare
# curl calls without an assert_status wrapper are forbidden — the
# function captures status via %{http_code} and is the only abort
# gate. Set -uo pipefail (no -e) is intentional so assert_status'
# explicit `exit 1` is the single failure path; combining set -e with
# the helper would be redundant and harder to reason about.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DASHBOARD_DIR/.." && pwd)"
PORT="${PORT:-8798}"
BASE="http://127.0.0.1:${PORT}"

if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
  echo "  SKIP: workspace .venv not provisioned — run: cd $REPO_ROOT && uv sync --extra dev"
  exit 0
fi

echo "==> Launching uvicorn on 127.0.0.1:${PORT}"
PYTHONPATH="$REPO_ROOT" "$REPO_ROOT/.venv/bin/python" -m uvicorn \
  dashboard.server.app:app --host 127.0.0.1 --port "$PORT" \
  >/tmp/manual-smoke-artifacts-grinder-uvicorn.log 2>&1 &
UVICORN_PID=$!
trap 'kill "$UVICORN_PID" 2>/dev/null || true; wait "$UVICORN_PID" 2>/dev/null || true' EXIT

# Poll /health up to 10s
for _ in $(seq 1 50); do
  if curl -sf -o /dev/null "${BASE}/health"; then break; fi
  sleep 0.2
done
curl -sf -o /dev/null "${BASE}/health" || {
  echo "uvicorn failed to start"
  cat /tmp/manual-smoke-artifacts-grinder-uvicorn.log
  exit 1
}

assert_status() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  ${label} (got ${actual})"
  else
    echo "  FAIL  ${label} (expected ${expected}, got ${actual})"
    exit 1
  fi
}

curl_status() {
  curl -sS -o /dev/null -w '%{http_code}' "$@"
}

echo "==> AS-3: POST/DELETE /api/grinder/pause distinct routes (404 on unknown project)"
assert_status "AS-3 POST 404"   404 "$(curl_status -X POST   "${BASE}/api/grinder/pause?project=zzznonexistent")"
assert_status "AS-3 DELETE 404" 404 "$(curl_status -X DELETE "${BASE}/api/grinder/pause?project=zzznonexistent")"

echo "==> AS-4: input validation (400) for the 8 newly-ported endpoints"
assert_status "AS-4 plan/artifacts missing-task"     400 "$(curl_status "${BASE}/api/plan/artifacts?cwd=/tmp")"
assert_status "AS-4 plan/artifact missing-file"      400 "$(curl_status "${BASE}/api/plan/artifact")"
assert_status "AS-4 plan/artifact bad-file"          400 "$(curl_status "${BASE}/api/plan/artifact?file=NONEXISTENT.md")"
assert_status "AS-4 feature/artifacts missing-pair"  400 "$(curl_status "${BASE}/api/feature/artifacts")"
assert_status "AS-4 feature/artifact missing-trio"   400 "$(curl_status "${BASE}/api/feature/artifact")"
assert_status "AS-4 feature/artifact bad-feature"    400 "$(curl_status "${BASE}/api/feature/artifact?feature=evil%2F&project_root=/tmp&file=PLAN.md")"
assert_status "AS-4 grinder bad-project"             400 "$(curl_status "${BASE}/api/grinder?project=evil%2F")"
assert_status "AS-4 grinder/stream missing-project"  400 "$(curl_status "${BASE}/api/grinder/stream")"

echo "All assertions passed."
