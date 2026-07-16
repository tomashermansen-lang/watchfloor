#!/usr/bin/env bash
# test-plan-review-no-tests.sh — mechanical text contract for the
# workflow-optimization plan Change 4: `/plan` and `/review` are doc
# phases. They must NOT run pytest/vitest or any test suite, nor
# linters/type checkers. Sporadic invocations observed in real
# autopilot streams (median 1-2 per phase across some features) are
# agent self-narration ("let me verify") and produce no signal that
# `/implement` doesn't already gate.
#
# Coverage:
#   T1   — plan.md Rules section forbids running tests
#   T2   — plan.md Rules section forbids running linters/type checkers
#   T3   — review.md Rules section forbids running tests
#   T4   — review.md Rules section forbids running linters/type checkers
#
# M-tests:
#   M1   — at least 4 numbered tests
#
# Usage: bash tests/test-plan-review-no-tests.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLAN_MD="$REPO_DIR/adapters/claude-code/claude/commands/plan.md"
REVIEW_MD="$REPO_DIR/adapters/claude-code/claude/commands/review.md"

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

# Extract Rules section
plan_rules=$(awk '/^## Rules/,EOF' "$PLAN_MD")
review_rules=$(awk '/^## Rules/,EOF' "$REVIEW_MD")

# ── T1: plan.md Rules forbids running tests ──
# Must contain explicit "do not run tests" / "no test suite" / "forbid"
# language. We require both:
#   (a) a forbidden / no-run / do-not verb
#   (b) "test" or "test suite" target
if echo "$plan_rules" | grep -qiE '(do not run|never run|forbid|no test suite|no.*pytest|no.*vitest).*test|test.*(do not run|never run|forbid)'; then
  pass "T1: plan.md Rules forbids running tests"
else
  fail "T1: plan.md Rules forbids running tests" \
       "expected 'do not run tests' / 'no test suite' language in $PLAN_MD Rules"
fi

# ── T2: plan.md Rules forbids running linters/type checkers ──
if echo "$plan_rules" | grep -qiE '(do not run|never run|forbid|no.*lint|no.*type.checker).*(lint|type.check|mypy|tsc|ruff|eslint)|lint.*(do not run|never run|forbid)'; then
  pass "T2: plan.md Rules forbids running linters/type checkers"
else
  fail "T2: plan.md Rules forbids running linters/type checkers" \
       "expected 'do not run lint/type-check' language in $PLAN_MD Rules"
fi

# ── T3: review.md Rules forbids running tests ──
if echo "$review_rules" | grep -qiE '(do not run|never run|forbid|no test suite|no.*pytest|no.*vitest).*test|test.*(do not run|never run|forbid)'; then
  pass "T3: review.md Rules forbids running tests"
else
  fail "T3: review.md Rules forbids running tests" \
       "expected 'do not run tests' / 'no test suite' language in $REVIEW_MD Rules"
fi

# ── T4: review.md Rules forbids running linters/type checkers ──
if echo "$review_rules" | grep -qiE '(do not run|never run|forbid|no.*lint|no.*type.checker).*(lint|type.check|mypy|tsc|ruff|eslint)|lint.*(do not run|never run|forbid)'; then
  pass "T4: review.md Rules forbids running linters/type checkers"
else
  fail "T4: review.md Rules forbids running linters/type checkers" \
       "expected 'do not run lint/type-check' language in $REVIEW_MD Rules"
fi

# ── M1: ≥4 numbered tests ──
test_count=$(grep -cE '^# ── T[0-9]+' "$0")
if [[ $test_count -ge 4 ]]; then
  pass "M1: ≥4 numbered tests defined ($test_count)"
else
  fail "M1: ≥4 numbered tests defined" "found $test_count"
fi

# ── Summary ──
echo
echo "─────────────────────────────────────────"
echo -e "Ran: $ran  ${GREEN}Passed: $passed${NC}  ${RED}Failed: $failed${NC}"
echo "─────────────────────────────────────────"

[[ $failed -gt 0 ]] && exit 1
exit 0
