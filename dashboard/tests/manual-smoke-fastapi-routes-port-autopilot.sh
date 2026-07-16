#!/usr/bin/env bash
# Manual smoke recipe for T0.2.b fastapi-routes-port-autopilot (Eval-3, AS-3 + AS-4).
#
# Bundles the curl probes that exercise the 7 newly-ported autopilot endpoints
# AND the global HTML 4xx/5xx exception handler. NOT wired into run-all.sh per
# R13 — invoke from /manualtest or ad-hoc when investigating a stdlib HTML
# template / autopilot route drift. Predecessor companion script for the core
# port batch lives at manual-smoke-fastapi-routes-port-core.sh.
#
# Usage:
#   bash dashboard/tests/manual-smoke-fastapi-routes-port-autopilot.sh
#
# Launches uvicorn on 127.0.0.1:8798, polls /health, runs the probes, tears
# down. Exit 0 on full pass with "OK" on the last line; first failed probe
# exits non-zero with the probe label and observed status code.
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

echo "==> Launching uvicorn on 127.0.0.1:${PORT}"
PYTHONPATH="$REPO_ROOT" "$REPO_ROOT/.venv/bin/python" -m uvicorn \
  dashboard.server.app:app --host 127.0.0.1 --port "$PORT" \
  >/tmp/manual-smoke-autopilot-uvicorn.log 2>&1 &
UVICORN_PID=$!
trap 'kill "$UVICORN_PID" 2>/dev/null || true; wait "$UVICORN_PID" 2>/dev/null || true' EXIT

# Poll /health up to 10s
for _ in $(seq 1 50); do
  if curl -sf -o /dev/null "${BASE}/health"; then break; fi
  sleep 0.2
done
curl -sf -o /dev/null "${BASE}/health" || {
  echo "uvicorn failed to start"
  cat /tmp/manual-smoke-autopilot-uvicorn.log
  exit 1
}

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

run_body_grep() {
  local label="$1" url="$2" grep_for="$3"
  local body
  body=$(curl -sS "$url")
  if printf '%s' "$body" | grep -qF -- "$grep_for"; then
    echo "  PASS  ${label}: body contains '${grep_for}'"
  else
    echo "  FAIL  ${label}: body MISSING '${grep_for}'"
    printf '%s\n' "$body" | head -20
    return 1
  fi
}

run_method_status_check() {
  local label="$1" expected="$2" method="$3" url="$4"
  local actual
  actual=$(curl -sS -o /dev/null -w '%{http_code}' -X "$method" "$url")
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  ${label}: ${method} ${url} → ${actual}"
  else
    echo "  FAIL  ${label}: ${method} ${url} → ${actual} (expected ${expected})"
    return 1
  fi
}

echo "==> AS-3: /api/autopilots returns 200 with JSON list"
run_status_check "AS-3 autopilots-200"   "200" "${BASE}/api/autopilots"

echo "==> AS-3 / R10: 4xx body uses stdlib HTML template"
run_status_check "AS-3 log-404"          "404" "${BASE}/api/autopilot/log?task=zzznonexistent&offset=0"
run_body_grep   "AS-3 log-html-message"  "${BASE}/api/autopilot/log?task=zzznonexistent&offset=0" "<p>Message: Log file not found.</p>"
run_status_check "AS-3 stream-404"       "404" "${BASE}/api/autopilot/stream?task=zzznonexistent&offset=0"
run_body_grep   "AS-3 stream-html-message" "${BASE}/api/autopilot/stream?task=zzznonexistent&offset=0" "<p>Message: Stream file not found.</p>"
run_status_check "AS-3 summary-404"      "404" "${BASE}/api/autopilot/summary?task=zzznonexistent"
run_body_grep   "AS-3 summary-html-message" "${BASE}/api/autopilot/summary?task=zzznonexistent" "<p>Message: Summary not found.</p>"
run_status_check "AS-3 artifact-404"     "404" "${BASE}/api/autopilot/artifact?task=zzznonexistent&file=PLAN.md"
run_body_grep   "AS-3 artifact-html-message" "${BASE}/api/autopilot/artifact?task=zzznonexistent&file=PLAN.md" "<p>Message: Artifact not found.</p>"

echo "==> AS-4: input validation"
run_status_check "AS-4 log-missing-task"   "400" "${BASE}/api/autopilot/log"
run_body_grep   "AS-4 log-html-missing"    "${BASE}/api/autopilot/log" "<p>Message: Missing task parameter.</p>"
run_status_check "AS-4 log-bad-task"       "400" "${BASE}/api/autopilot/log?task=evil%2Fpath"
run_body_grep   "AS-4 log-html-invalid"    "${BASE}/api/autopilot/log?task=evil%2Fpath" "<p>Message: Invalid task parameter.</p>"
run_status_check "AS-4 log-bad-offset"     "400" "${BASE}/api/autopilot/log?task=ok&offset=notnum"
run_body_grep   "AS-4 log-html-offset"     "${BASE}/api/autopilot/log?task=ok&offset=notnum" "<p>Message: Invalid offset parameter.</p>"
run_status_check "AS-4 artifact-bad-file"  "400" "${BASE}/api/autopilot/artifact?task=ok&file=../../etc/passwd"
run_body_grep   "AS-4 artifact-html-file"  "${BASE}/api/autopilot/artifact?task=ok&file=../../etc/passwd" "<p>Message: Invalid file parameter.</p>"
run_status_check "AS-4 activity-bad-since" "400" "${BASE}/api/autopilot/activity?task=ok&since=not-a-date"
run_body_grep   "AS-4 activity-html-since" "${BASE}/api/autopilot/activity?task=ok&since=not-a-date" "<p>Message: Invalid since timestamp.</p>"

echo "==> OQ#3: POST/DELETE on unported /api/* return 404 deterministically"
run_method_status_check "OQ#3 POST"   "404" "POST"   "${BASE}/api/grinder/pause?project=zzz"
run_method_status_check "OQ#3 DELETE" "404" "DELETE" "${BASE}/api/grinder/pause?project=zzz"

echo "==> R12: /api/typo (unported GET) returns HTML 404"
run_status_check "R12 typo-404"      "404" "${BASE}/api/typo"
run_body_grep   "R12 typo-html"      "${BASE}/api/typo" "<p>Message: Not Found.</p>"

echo "OK"
