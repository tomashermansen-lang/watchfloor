#!/usr/bin/env bash
# CSRF enforcement tests (non-loopback) via Starlette TestClient.
#
# Why this exists: the curl-based CSRF cases in test-security.sh POST from
# loopback (127.0.0.1), but csrf.py short-circuits loopback clients
# (controls-07 #8, documented threat-model rationale) — so they can NOT exercise
# enforcement (they get 404, not 403). TestClient presents host "testclient"
# (non-loopback), which hits the full enforcement path — the way csrf.py itself
# names as the correct test vector. No git fixture, no bound port: runs anywhere
# (incl. the sandbox), so this is the suite that actually guards CSRF.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PY="python3"
[ -x "$REPO_ROOT/.venv/bin/python" ] && PY="$REPO_ROOT/.venv/bin/python"

echo "CSRF enforcement (non-loopback / TestClient)"
echo "============================================"

PYTHONPATH="$REPO_ROOT" "$PY" - <<'PY'
import sys
from starlette.testclient import TestClient
from dashboard.server.app import app

ORIGIN = {"Origin": "http://127.0.0.1:8787"}  # passes the loopback-permissive origin allowlist
fails = 0


def check(desc, ok):
    global fails
    print(f"  {'PASS' if ok else 'FAIL'}: {desc}")
    if not ok:
        fails += 1


def post(token_cookie=None, token_header=None):
    c = TestClient(app)  # fresh client → no cookie-jar leakage between cases
    if token_cookie is not None:
        c.cookies.set("csrf_token", token_cookie)
    headers = dict(ORIGIN)
    if token_header is not None:
        headers["X-CSRF-Token"] = token_header
    return c.post("/api/csrf-test", headers=headers)


# Unsafe method, non-loopback, no token → rejected 403 {"error":"csrf"}.
r = post()
check("missing token → 403", r.status_code == 403)
check('missing token → {"error":"csrf"} body', r.text == '{"error":"csrf"}')

# Header present, cookie absent → 403.
r = post(token_header="AAA")
check("header without cookie → 403", r.status_code == 403)

# Cookie present, header absent → 403.
r = post(token_cookie="AAA")
check("cookie without header → 403", r.status_code == 403)

# Mismatched cookie vs header → 403.
r = post(token_cookie="AAA", token_header="BBB")
check("mismatched token → 403", r.status_code == 403)

# EC-3: empty cookie + empty header must NOT bypass (compare_digest('','') guard).
r = post(token_cookie="", token_header="")
check("empty token pair → 403 (no compare_digest bypass)", r.status_code == 403)

# Valid double-submit (matching cookie+header) passes CSRF → reaches routing
# (404 for the non-existent probe path), i.e. NOT a 403 csrf rejection.
r = post(token_cookie="AAA", token_header="AAA")
check("matching token → not csrf-rejected", r.status_code != 403)

sys.exit(1 if fails else 0)
PY
rc=$?
echo ""
if [ "$rc" -eq 0 ]; then
  echo "All CSRF enforcement checks passed."
else
  echo "CSRF enforcement checks FAILED."
fi
exit "$rc"
