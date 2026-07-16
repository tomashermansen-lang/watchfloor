#!/bin/bash
# Test: buildLaunchCommand always includes --full flag
# Verifies the focusUri.ts utility generates correct autopilot commands.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# Check that focusUri.ts includes --full in the command
if grep -q '\-\-full' app/src/utils/focusUri.ts; then
  pass "focusUri.ts includes --full flag"
else
  fail "focusUri.ts missing --full flag"
fi

# Check that default command includes --full
if grep -q 'autopilot.sh --full' app/src/utils/focusUri.ts; then
  pass "Default command uses --full"
else
  fail "Default command missing --full"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
