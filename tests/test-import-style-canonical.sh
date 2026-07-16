#!/usr/bin/env bash
# test-import-style-canonical.sh — guardrail asserting every Python file
# under dashboard/ uses the canonical `from dashboard.server.X` /
# `import dashboard.server.X` style, never the legacy `from server.X`
# style.
#
# Why this guardrail:
#   - The legacy `from server.X` style required a sys.path bootstrap at
#     dashboard/server/routes/api.py:64-71 to resolve under uvicorn (which
#     only puts REPO_ROOT on PYTHONPATH), and a parallel pythonpath
#     workaround in pyproject.toml + an extra PYTHONPATH entry in
#     test_response_compat.py for the subprocess uvicorn it spawns.
#   - Refactor on 2026-05-23 standardised on the namespaced form and
#     dropped all three workarounds. This test locks the cleanup in —
#     any future drift back to `from server.X` would re-introduce the
#     bootstrap layer.
#   - Runs in <1s, pure grep, zero LLM cost.
#
# Coverage:
#   T1 — no `.py` file under dashboard/ contains `^from server\.`
#   T2 — no `.py` file under dashboard/ contains `^from server import`
#   T3 — no `.py` file under dashboard/ contains `^import server\.`
#   T4 — no `.py` file under dashboard/ contains `^import server$`
#   T5 — dashboard/server/routes/api.py does NOT contain `sys.path.insert.*DASHBOARD_DIR`
#        (the bootstrap is removed; re-introducing it would resurrect the asymmetry)
#   T6 — pyproject.toml `pythonpath` does NOT list `dashboard`
#   T7 — test_response_compat.py PYTHONPATH does NOT include `dashboard_dir`
#
# M-tests:
#   M1 — ≥7 numbered tests defined
#
# Usage: bash tests/test-import-style-canonical.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

passed=0
failed=0
ran=0

pass() { passed=$((passed+1)); ran=$((ran+1)); echo -e "${GREEN}✓${NC} $1"; }
fail() {
  failed=$((failed+1)); ran=$((ran+1))
  echo -e "${RED}✗${NC} $1"
  [[ -n "${2:-}" ]] && echo -e "    ${YELLOW}$2${NC}"
}

# Helper: grep recursively under dashboard/ for a pattern, listing offenders.
_offenders() {
  local pattern="$1"
  grep -rln --include='*.py' -E "$pattern" "$REPO_DIR/dashboard/" 2>/dev/null || true
}

# ── T1: no `from server.X` ──
offenders=$(_offenders '^from server\.')
if [[ -z "$offenders" ]]; then
  pass "T1: no '^from server.' under dashboard/"
else
  fail "T1: no '^from server.' under dashboard/" "offenders:\n$offenders"
fi

# ── T2: no `from server import` ──
offenders=$(_offenders '^from server import')
if [[ -z "$offenders" ]]; then
  pass "T2: no '^from server import' under dashboard/"
else
  fail "T2: no '^from server import' under dashboard/" "offenders:\n$offenders"
fi

# ── T3: no `import server.X` ──
offenders=$(_offenders '^import server\.')
if [[ -z "$offenders" ]]; then
  pass "T3: no '^import server.' under dashboard/"
else
  fail "T3: no '^import server.' under dashboard/" "offenders:\n$offenders"
fi

# ── T4: no bare `import server` ──
offenders=$(_offenders '^import server$')
if [[ -z "$offenders" ]]; then
  pass "T4: no '^import server$' under dashboard/"
else
  fail "T4: no '^import server$' under dashboard/" "offenders:\n$offenders"
fi

# ── T5: dashboard/server/routes/api.py has no DASHBOARD_DIR bootstrap ──
if grep -qE 'sys\.path\.insert.*_DASHBOARD_DIR|_DASHBOARD_DIR.*sys\.path' "$REPO_DIR/dashboard/server/routes/api.py" 2>/dev/null; then
  fail "T5: routes/api.py has no DASHBOARD_DIR sys.path bootstrap" \
       "the legacy bootstrap is re-introduced; remove it"
else
  pass "T5: routes/api.py has no DASHBOARD_DIR sys.path bootstrap"
fi

# ── T6: pyproject.toml pythonpath does NOT include 'dashboard' ──
if grep -E '^\s*pythonpath\s*=' "$REPO_DIR/pyproject.toml" | grep -qE '"dashboard"'; then
  fail "T6: pyproject.toml pythonpath does NOT include 'dashboard'" \
       "the legacy workaround entry is re-introduced; remove it"
else
  pass "T6: pyproject.toml pythonpath does NOT include 'dashboard'"
fi

# ── T7: test_response_compat.py PYTHONPATH does NOT include dashboard_dir ──
if grep -qE 'dashboard_dir.*PYTHONPATH|PYTHONPATH.*dashboard_dir' "$REPO_DIR/dashboard/tests/test_response_compat.py" 2>/dev/null; then
  fail "T7: test_response_compat.py subprocess PYTHONPATH excludes dashboard_dir" \
       "the legacy workaround is re-introduced; remove it"
else
  pass "T7: test_response_compat.py subprocess PYTHONPATH excludes dashboard_dir"
fi

# ── M1: ≥7 numbered tests ──
test_count=$(grep -cE '^# ── T[0-9]+' "$0")
if [[ $test_count -ge 7 ]]; then
  pass "M1: ≥7 numbered tests defined ($test_count)"
else
  fail "M1: ≥7 numbered tests defined" "found $test_count"
fi

# ── Summary ──
echo
echo "─────────────────────────────────────────"
echo -e "Ran: $ran  ${GREEN}Passed: $passed${NC}  ${RED}Failed: $failed${NC}"
echo "─────────────────────────────────────────"

[[ $failed -gt 0 ]] && exit 1
exit 0
