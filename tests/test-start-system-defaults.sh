#!/usr/bin/env bash
# test-start-system-defaults.sh — verifies post-T3 dashboard defaults in
# start-system.sh, autopilot.sh, and grinder.sh point at the monorepo
# layout (REQ-2, REQ-5).
#
# Usage: bash tests/test-start-system-defaults.sh
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
# T-SS-1: start-system.sh default DASHBOARD_DIR points at monorepo dashboard
# ---------------------------------------------------------------------------
test_default_dashboard_dir() {
    grep -F 'DASHBOARD_DIR="${DASHBOARD_DIR:-$PROJECTS_ROOT/dotfiles/dashboard}"' \
        "$REPO_DIR_REAL/start-system.sh" >/dev/null
}
check "T-SS-1 start-system.sh default DASHBOARD_DIR resolves to <PROJECTS_ROOT>/dotfiles/dashboard" \
    test_default_dashboard_dir

# ---------------------------------------------------------------------------
# T-SS-2: start-system.sh contains zero claude-agent-dashboard matches
# ---------------------------------------------------------------------------
test_start_system_no_legacy() {
    ! grep -q 'claude-agent-dashboard' "$REPO_DIR_REAL/start-system.sh"
}
check "T-SS-2 start-system.sh contains no 'claude-agent-dashboard' literal" \
    test_start_system_no_legacy

# ---------------------------------------------------------------------------
# T-SS-3: explicit DASHBOARD_DIR override mechanism still in place
#         (the ${VAR:-default} pattern preserves the env-override contract)
# ---------------------------------------------------------------------------
test_override_pattern_preserved() {
    grep -F '${DASHBOARD_DIR:-' "$REPO_DIR_REAL/start-system.sh" >/dev/null
}
check "T-SS-3 start-system.sh preserves \${DASHBOARD_DIR:-...} override pattern" \
    test_override_pattern_preserved

# ---------------------------------------------------------------------------
# T-SS-4: autopilot.sh default DASHBOARD_DATA expansion contains
#         dotfiles/dashboard/data/sessions.jsonl and zero legacy refs
# ---------------------------------------------------------------------------
test_autopilot_default() {
    grep -F 'dotfiles/dashboard/data/sessions.jsonl' \
        "$REPO_DIR_REAL/adapters/claude-code/claude/tools/autopilot.sh" >/dev/null
}
check "T-SS-4 autopilot.sh references monorepo dashboard data path" test_autopilot_default

test_autopilot_no_legacy() {
    ! grep -q 'claude-agent-dashboard' \
        "$REPO_DIR_REAL/adapters/claude-code/claude/tools/autopilot.sh"
}
check "T-SS-4 autopilot.sh contains no 'claude-agent-dashboard' literal" \
    test_autopilot_no_legacy

# ---------------------------------------------------------------------------
# T-SS-5: grinder.sh run + resume paths reference monorepo data path twice
# ---------------------------------------------------------------------------
test_grinder_default() {
    local count
    count=$(grep -c 'dotfiles/dashboard/data/sessions.jsonl' \
        "$REPO_DIR_REAL/adapters/claude-code/claude/tools/grinder.sh") || count=0
    [[ "$count" -eq 2 ]]
}
check "T-SS-5 grinder.sh references monorepo dashboard data path on both run and resume paths" \
    test_grinder_default

test_grinder_no_legacy() {
    ! grep -q 'claude-agent-dashboard' \
        "$REPO_DIR_REAL/adapters/claude-code/claude/tools/grinder.sh"
}
check "T-SS-5 grinder.sh contains no 'claude-agent-dashboard' literal" \
    test_grinder_no_legacy

# ---------------------------------------------------------------------------
echo
if [[ $failed -eq 0 ]]; then
    echo -e "${GREEN}All $passed tests passed.${NC}"
    exit 0
fi
echo -e "${RED}$failed of $((passed + failed)) tests failed.${NC}"
exit 1
