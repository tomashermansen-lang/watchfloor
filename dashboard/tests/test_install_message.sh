#!/usr/bin/env bash
# test_install_message.sh — TDD harness for the C9 operator hand-off
# message in dashboard/install.sh. Covers TESTPLAN C9-01..C9-03.
#
# The script's printed "Done! To start the dashboard:" block is asserted
# at the source level so this test runs without invoking install.sh
# (which has side effects: cp hooks, edit settings.json).
#
# Usage: bash dashboard/tests/test_install_message.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$DASHBOARD_DIR/install.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"
    shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

# C9-01: install.sh hand-off message names `start-system dashboard`.
test_install_message_names_start_system_dashboard() {
    awk '/Done! To start the dashboard:/,/^Then open:/' "$INSTALL_SH" \
        | grep -qF 'start-system dashboard'
}

# C9-02: install.sh no longer mentions `python3 .*/serve.py`.
test_install_message_drops_serve_py_invocation() {
    grep -E 'python3.*serve\.py' "$INSTALL_SH" >/dev/null && return 1
    return 0
}

# C9-03: the open-in-browser hint at port 8787 is preserved.
test_install_message_keeps_localhost_8787_hint() {
    grep -qF 'http://127.0.0.1:8787' "$INSTALL_SH"
}

echo "=== dashboard/install.sh operator hand-off tests ==="
check "C9-01: install hint names 'start-system dashboard'" test_install_message_names_start_system_dashboard
check "C9-02: install hint drops 'python3 .../serve.py'" test_install_message_drops_serve_py_invocation
check "C9-03: install hint keeps http://127.0.0.1:8787" test_install_message_keeps_localhost_8787_hint

echo ""
echo "Passed: $passed"
echo "Failed: $failed"
[ "$failed" -eq 0 ]
