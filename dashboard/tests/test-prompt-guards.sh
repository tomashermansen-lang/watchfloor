#!/usr/bin/env bash
set -euo pipefail

# Test: Prompt quality guards — verify adversarial framing, anti-sycophancy,
# stop-rules, and evidence requirements are present in command files.

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QA="$HOME/.claude/commands/qa.md"
GRILL="$HOME/.claude/commands/grill.md"
IMPLEMENT="$HOME/.claude/commands/implement.md"
HOTFIX="$HOME/.claude/commands/hotfix.md"
TDD="$HOME/.claude/skills/tdd-workflow/SKILL.md"

check() {
  local desc="$1" file="$2" pattern="$3"
  if grep -Fq "$pattern" "$file"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Prompt Quality Guard Tests ==="
echo ""

echo "T1: C8 — Forbidden Completion Language (TDD skill)"
check "Section header exists" "$TDD" "## Forbidden Completion Language"
check "Contains banned word 'should'" "$TDD" '"should"'
check "Contains 'automatically invalid'" "$TDD" "automatically invalid"

echo ""
echo "T2: C1 — Adversarial Framing (/qa)"
check "Section header exists" "$QA" "### Adversarial Framing"
check "Distrust directive" "$QA" "Do NOT take the implementer"
check "Tests-not-proof directive" "$QA" "Passing tests do not prove correctness"
# Verify framing appears before Check Phase
FRAMING_LINE=$(grep -Fn "### Adversarial Framing" "$QA" | head -1 | cut -d: -f1)
CHECK_LINE=$(grep -Fn "### Check Phase" "$QA" | head -1 | cut -d: -f1)
if [ -n "$FRAMING_LINE" ] && [ -n "$CHECK_LINE" ] && [ "$FRAMING_LINE" -lt "$CHECK_LINE" ]; then
  echo "  PASS: Framing appears before Check Phase"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Framing must appear before Check Phase"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "T3: C2 — Anti-Sycophancy (/grill)"
check "NO SYCOPHANCY rule" "$GRILL" "NO SYCOPHANCY"
check "Banned phrase listed" "$GRILL" "Great point!"

echo ""
echo "T4: C3 — Anti-Sycophancy (/qa)"
check "NO SYCOPHANCY rule" "$QA" "NO SYCOPHANCY"
check "Banned phrase listed" "$QA" "Great point!"

echo ""
echo "T5: C4 — 3-Fix Stop-Rule (/implement)"
check "Stop-rule exists" "$IMPLEMENT" "3-FIX STOP-RULE"
check "Oscillation clause" "$IMPLEMENT" "Oscillating failures"

echo ""
echo "T6: C5 — 3-Fix Stop-Rule (/hotfix)"
check "Stop-rule exists" "$HOTFIX" "3-FIX STOP-RULE"
check "Oscillation clause" "$HOTFIX" "Oscillating failures"

echo ""
echo "T7: C6 — Evidence in This Message (/implement)"
check "Evidence rule exists" "$IMPLEMENT" "EVIDENCE IN THIS MESSAGE"
check "Banned phrase listed" "$IMPLEMENT" "should work"

echo ""
echo "T8: C7 — Evidence in This Message (/qa)"
check "Evidence rule exists" "$QA" "EVIDENCE IN THIS MESSAGE"
check "Banned phrase listed" "$QA" "should work"

echo ""
echo "T10: C4/C5 — Cross-gate awareness"
check "review.md references TEAM_REVIEW.md" "$QA" "TEAM_QA.md" # qa.md has TEAM_QA ref
REVIEW_CMD="$HOME/.claude/commands/review.md"
if [ -f "$REVIEW_CMD" ]; then
  check "review.md Step 0.7 exists" "$REVIEW_CMD" "Step 0.7"
  check "review.md references TEAM_REVIEW.md" "$REVIEW_CMD" "TEAM_REVIEW.md"
else
  echo "  FAIL: review.md not found at $REVIEW_CMD"
  FAIL=$((FAIL + 2))
fi
check "qa.md Step 0.7 exists" "$QA" "Step 0.7"
check "qa.md references TEAM_QA.md" "$QA" "TEAM_QA.md"

echo ""
echo "T9: Superpowers content preservation (key sections still present)"
# T1-T8 check specific content. T9 verifies the key section headers survive edits.
for pair in \
  "$QA:### Adversarial Framing" \
  "$QA:NO SYCOPHANCY" \
  "$QA:EVIDENCE IN THIS MESSAGE" \
  "$IMPLEMENT:3-FIX STOP-RULE" \
  "$IMPLEMENT:EVIDENCE IN THIS MESSAGE" \
  "$HOTFIX:3-FIX STOP-RULE" \
  "$GRILL:NO SYCOPHANCY" \
  "$TDD:## Forbidden Completion Language"; do
  file="${pair%%:*}"
  pattern="${pair#*:}"
  fname="$(basename "$file")"
  if grep -Fq "$pattern" "$file"; then
    echo "  PASS: $fname still contains '$pattern'"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $fname missing '$pattern' (superpowers content removed!)"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
