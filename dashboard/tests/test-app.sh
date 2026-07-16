#!/usr/bin/env bash
# Wrapper: invoke pytest against the FastAPI app unit tests.
# Skips with a warning (exit 0) if the workspace .venv has not been provisioned yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DASHBOARD_DIR/.." && pwd)"

if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
  echo "  SKIP: workspace .venv not provisioned — run: cd ~/Projekter/dotfiles && uv sync --extra dev"
  exit 0
fi

cd "$DASHBOARD_DIR"
"$REPO_ROOT/.venv/bin/python" -m pytest \
  tests/test_app_health.py \
  tests/test_app_access_log.py \
  tests/test_app_logging_config.py \
  tests/test_responses.py \
  tests/test_routes_api.py \
  tests/test_routes_blocking_offload.py \
  tests/test_app_routing.py \
  tests/test_app_exception_handler.py \
  tests/test_routes_api_artifacts_grinder.py \
  tests/test_serve_legacy_imports.py \
  tests/test_origin_parse.py \
  tests/test_origin_audit.py \
  tests/test_schemas_writerequest.py \
  tests/test_status_endpoint.py \
  tests/test_pty_session.py \
  tests/test_terminal_ws.py \
  "$@"

# ─── Post fastapi-cutover (T0.3): tombstone size + token guard (C3-04, C3-05).
# Catches accidental regrowth of serve.py from a botched merge from main
# bringing back the 976-line stdlib body. Both checks run in O(ms).
SERVE_PY="$DASHBOARD_DIR/serve.py"
serve_lines=$(wc -l < "$SERVE_PY" | tr -d ' ')
if [ "$serve_lines" -gt 10 ]; then
  echo "  FAIL: dashboard/serve.py grew back to $serve_lines lines (tombstone budget ≤10)"
  exit 1
fi
if ! grep -qF tombstoned "$SERVE_PY"; then
  echo "  FAIL: dashboard/serve.py missing 'tombstoned' token — body was overwritten"
  exit 1
fi
if grep -qE '^from dashboard\.server' "$SERVE_PY"; then
  echo "  FAIL: dashboard/serve.py imports from dashboard.server.* (cycle risk)"
  exit 1
fi
echo "  OK: dashboard/serve.py tombstone invariants ($serve_lines lines, contains 'tombstoned')"
