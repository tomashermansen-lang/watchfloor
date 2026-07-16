#!/bin/bash
set -euo pipefail

# Test: Frontend build produces valid output
# Verifies that `npm run build` succeeds and produces expected dist artifacts.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/../app"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

echo "=== Frontend Build Tests ==="

# T1: tsc type-check succeeds
echo ""
echo "T1: TypeScript type-check"
if (cd "$APP_DIR" && npx tsc -b --noEmit 2>&1); then
  pass "tsc -b passes with no errors"
else
  fail "tsc -b has type errors"
fi

# T2: vite build produces dist/index.html
echo ""
echo "T2: Vite build output"
if (cd "$APP_DIR" && npm run build >/dev/null 2>&1) && [ -f "$APP_DIR/dist/index.html" ]; then
  pass "dist/index.html exists after build"
else
  fail "dist/index.html missing after build"
fi

# T3: dist JS bundle contains key components
echo ""
echo "T3: Key components in bundle"
if grep -rq "Live activity" "$APP_DIR/dist/" 2>/dev/null; then
  pass "ActivityStrip 'Live activity' text present in bundle"
else
  fail "ActivityStrip 'Live activity' text missing from bundle"
fi

# T4: Vitest suite passes (includes Pipeline gate popover tests)
echo ""
echo "T4: Vitest unit tests"
if (cd "$APP_DIR" && npx vitest run --reporter=dot 2>&1 | grep -qE "Test Files.*passed" && ! npx vitest run --reporter=dot 2>&1 | grep -qE "failed"); then
  pass "all vitest tests pass"
else
  fail "vitest has failing tests"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
