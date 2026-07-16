#!/usr/bin/env bash
# test-qa-phase-marker-skip.sh — mechanical text contract for the
# workflow-optimization plan Change 1: /qa and /team-qa skip their
# opening "Run all tests" / "Syntax/type check" steps when the
# `.tests-green-sha` marker proves /implement (or a previous green
# pass) just landed on this HEAD.
#
# Why mechanical: the .md files are agent instructions. Behavior is
# the agent obeying the text. The cheapest contract is: assert the
# text contains the expected gating language.
#
# Coverage:
#   T1   — qa.md Step 1 references `.tests-green-sha` (marker check exists)
#   T2   — qa.md Step 1 explicitly skips when marker matches HEAD
#   T3   — qa.md Step 1 falls back to running tests when marker absent/stale
#   T4   — qa.md Step 2 references `.tests-green-sha` (marker check covers lint/type)
#   T5   — qa.md Fix-and-Reverify still runs tests after every fix
#          (load-bearing — must NOT be removed)
#   T6   — team-qa.md Phase 2 §8.1 first check references `.tests-green-sha`
#   T7   — team-qa.md Phase 2 §8.1 syntax/type check references `.tests-green-sha`
#   T8   — team-qa.md Fix-and-Reverify still requires Fixer to run tests
#          after every change (load-bearing — must NOT be removed)
#
# M-tests:
#   M1   — at least 8 numbered tests
#
# Usage: bash tests/test-qa-phase-marker-skip.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QA_MD="$REPO_DIR/adapters/claude-code/claude/commands/qa.md"
TEAM_QA_MD="$REPO_DIR/adapters/claude-code/claude/commands/team-qa.md"

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

# Helper: extract the contents of /qa.md or /team-qa.md Step 1 / Phase 2
# §8.1 block. We don't need precise boundary parsing — we just need to
# assert the right keywords appear in the right phase entry block.

# ── T1: qa.md Step 1 references .tests-green-sha ──
# We look for ".tests-green-sha" appearing within the first ~30 lines of
# the "### Check Phase" section.
qa_check_phase=$(awk '/^### Check Phase/,/^### Fix-and-Reverify/' "$QA_MD")
if echo "$qa_check_phase" | grep -q '\.tests-green-sha'; then
  pass "T1: qa.md Check Phase references .tests-green-sha"
else
  fail "T1: qa.md Check Phase references .tests-green-sha" \
       "expected '.tests-green-sha' inside Check Phase block in $QA_MD"
fi

# ── T2: qa.md Step 1 skips opener when marker matches HEAD ──
if echo "$qa_check_phase" | grep -qiE 'skip|skipped' && \
   echo "$qa_check_phase" | grep -q 'rev-parse HEAD'; then
  pass "T2: qa.md Check Phase skips opener when marker matches HEAD"
else
  fail "T2: qa.md Check Phase skips opener when marker matches HEAD" \
       "expected both 'skip' and 'rev-parse HEAD' language in Check Phase"
fi

# ── T3: qa.md Step 1 falls back when marker absent/stale ──
# The phrase pattern: explicit "marker absent/stale/missing" or
# "absent/stale/missing marker" language — NOT just any "missing" word.
if echo "$qa_check_phase" \
     | grep -qiE 'marker[^.]*(absent|stale|missing)|(absent|stale|missing)[^.]*marker|absent[^.]*tests-green|stale[^.]*tests-green|tests-green[^.]*(absent|stale|missing)'; then
  pass "T3: qa.md Check Phase falls back when marker absent/stale"
else
  fail "T3: qa.md Check Phase falls back when marker absent/stale" \
       "expected explicit 'marker absent/stale/missing' fallback in Check Phase"
fi

# ── T4: qa.md Step 2 references the marker (lint/type covered) ──
# Step 2 used to be "Syntax/type check"; should be merged into the
# marker check, OR explicitly reference the marker as the proof.
# We look for ".tests-green-sha" appearing in the Check Phase (T1 already
# proved that). What we additionally want: language that the marker
# covers lint AND type-check, not just tests.
if echo "$qa_check_phase" | grep -qiE 'lint.*type|type.*lint|lint.*marker|marker.*lint'; then
  pass "T4: qa.md Check Phase confirms marker covers lint+type-check"
else
  fail "T4: qa.md Check Phase confirms marker covers lint+type-check" \
       "expected mention that marker covers lint + type-check"
fi

# ── T5: qa.md Fix-and-Reverify still runs tests after every fix ──
qa_fix_loop=$(awk '/^### Fix-and-Reverify/,/^### Report Phase/' "$QA_MD")
if echo "$qa_fix_loop" | grep -qiE 'rerun|re-run|run.*tests'; then
  pass "T5: qa.md Fix-and-Reverify still re-runs tests after every fix"
else
  fail "T5: qa.md Fix-and-Reverify still re-runs tests after every fix" \
       "expected test-rerun language in Fix-and-Reverify block (LOAD-BEARING)"
fi

# ── T6: team-qa.md Phase 2 §8.1 first check references marker ──
team_8_1=$(awk '/^### 8\.1: Deep QA Checks/,/^### 8\.2/' "$TEAM_QA_MD")
if echo "$team_8_1" | grep -q '\.tests-green-sha'; then
  pass "T6: team-qa.md §8.1 references .tests-green-sha"
else
  fail "T6: team-qa.md §8.1 references .tests-green-sha" \
       "expected '.tests-green-sha' inside §8.1 block in $TEAM_QA_MD"
fi

# ── T7: team-qa.md §8.1 syntax/type covered by marker ──
if echo "$team_8_1" | grep -qiE 'lint.*type|type.*lint|lint.*marker|marker.*lint'; then
  pass "T7: team-qa.md §8.1 confirms marker covers lint+type-check"
else
  fail "T7: team-qa.md §8.1 confirms marker covers lint+type-check" \
       "expected mention that marker covers lint + type-check"
fi

# ── T8: team-qa.md Fix-and-Reverify still requires tests after every fix ──
team_fix=$(awk '/^### 8\.2: Fix-and-Reverify Loop/,/^### 8\.3/' "$TEAM_QA_MD")
if echo "$team_fix" | grep -qiE 'rerun|re-run|run.*tests|tests after|tests obligation'; then
  pass "T8: team-qa.md §8.2 Fixer still runs tests after every change"
else
  fail "T8: team-qa.md §8.2 Fixer still runs tests after every change" \
       "expected Fixer test-rerun obligation in §8.2 (LOAD-BEARING)"
fi

# ── M1: ≥8 numbered tests ──
test_count=$(grep -cE '^# ── T[0-9]+' "$0")
if [[ $test_count -ge 8 ]]; then
  pass "M1: ≥8 numbered tests defined ($test_count)"
else
  fail "M1: ≥8 numbered tests defined" "found $test_count"
fi

# ── Summary ──
echo
echo "─────────────────────────────────────────"
echo -e "Ran: $ran  ${GREEN}Passed: $passed${NC}  ${RED}Failed: $failed${NC}"
echo "─────────────────────────────────────────"

[[ $failed -gt 0 ]] && exit 1
exit 0
