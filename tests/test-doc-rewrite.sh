#!/usr/bin/env bash
# test-doc-rewrite.sh — Phase 2 gate negative-grep predicate as a unit test.
# Verifies REQ-1 (commands/), REQ-12 gate.checklist[1] (full grep scope),
# and REQ-14 (hook-path template preserved verbatim).
#
# Usage: bash tests/test-doc-rewrite.sh
set -uo pipefail

REPO_DIR_REAL="$(cd "$(dirname "$0")/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"; shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"; passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"; failed=$((failed + 1))
    fi
}

# ---------------------------------------------------------------------------
# T-DR-1: adapters/claude-code/claude/commands/ contains zero
#         claude-agent-dashboard matches (REQ-1, REQ-10, REQ-11).
# ---------------------------------------------------------------------------
test_commands_clean() {
    ! grep -rq 'claude-agent-dashboard' \
        "$REPO_DIR_REAL/adapters/claude-code/claude/commands/"
}
check "T-DR-1 adapters/claude-code/claude/commands/ contains no 'claude-agent-dashboard' literal" \
    test_commands_clean

# ---------------------------------------------------------------------------
# T-DR-2: full Phase 2 gate grep scope is clean (REQ-1, REQ-12 gate.checklist[1]).
#         The host-plan grep scope: adapters/claude-code/, start-system.sh,
#         tests/fixtures/, pipeline.yaml. settings.json is excluded per REQ-14.
# ---------------------------------------------------------------------------
test_gate_scope_clean() {
    local hits
    # Exclude REQ-14 hook-path template (settings.json) and Python bytecode
    # caches (gitignored, transient). REQUIREMENTS § REQ-1 EC1 scopes the
    # gate to text source files; .pyc binaries are out of scope.
    hits=$(grep -rn 'claude-agent-dashboard' \
        --binary-files=without-match \
        --exclude-dir=__pycache__ \
        --exclude='*.pyc' \
        "$REPO_DIR_REAL/adapters/claude-code/" \
        "$REPO_DIR_REAL/start-system.sh" \
        "$REPO_DIR_REAL/tests/fixtures/" \
        "$REPO_DIR_REAL/pipeline.yaml" 2>/dev/null \
        | grep -v 'adapters/claude-code/claude/settings.json' \
        | wc -l | tr -d ' ')
    [[ "$hits" -eq 0 ]]
}
check "T-DR-2 Phase 2 gate negative-grep scope is clean (excluding settings.json template per REQ-14)" \
    test_gate_scope_clean

# ---------------------------------------------------------------------------
# T-DR-3: REQ-14 — hook-path template in adapters/claude-code/claude/settings.json
#         retains its 12 legacy hook-path entries (operator reinstall rewrites them).
# ---------------------------------------------------------------------------
test_settings_template_unchanged() {
    local count
    count=$(grep -c '~/Projekter/claude-agent-dashboard/hooks/report-status.sh' \
        "$REPO_DIR_REAL/adapters/claude-code/claude/settings.json") || count=0
    [[ "$count" -eq 12 ]]
}
check "T-DR-3 settings.json hook-path template preserves 12 legacy hook references (REQ-14)" \
    test_settings_template_unchanged

# ---------------------------------------------------------------------------
echo
if [[ $failed -eq 0 ]]; then
    echo -e "${GREEN}All $passed tests passed.${NC}"
    exit 0
fi
echo -e "${RED}$failed of $((passed + failed)) tests failed.${NC}"
exit 1
