#!/usr/bin/env bash
#
# test_specialist_validator_patterns.sh — exercise the §5T.2 specialist
# response validator's fuzzy regex patterns against synthetic specialist
# response fixtures.
#
# The §5T.2 validator (skills/plan-team-flow/SKILL.md) declares five
# fuzzy regex patterns. This script verifies each pattern matches the
# intended PASS fixtures and misses the intended FAIL fixtures. Component-
# level test only — does NOT exercise the full validator behavior
# (re-spawn, operator escalation, auto-fallback) which is integration-
# tested via the orchestrator at /plan-project run-time.
#
# Exit 0 on all expected match/no-match results. Exit 1 on any deviation.
#
# Usage:
#   bash tests/test_specialist_validator_patterns.sh

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/specialist-validator"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

# Patterns from skills/plan-team-flow/SKILL.md §5T.2 specialist response validator
ROLE_PATTERN='^##[[:space:]]+.*\bAnalysis\b'
TASKS_PATTERN='^###[[:space:]]+.*\b(Tasks?|Proposed)\b'
RISKS_PATTERN='^###[[:space:]]+.*\b(Risks?|Concerns?)\b'
SEQUENCING_PATTERN='^###[[:space:]]+.*\b(Sequencing|Ordering|Order)\b'
COUNCIL_PATTERN='^###[[:space:]]+.*\b(Council|Brief|Citations?)\b'

assert_match() {
  local fixture="$1"
  local pattern="$2"
  local label="$3"
  local expected="$4"  # "match" or "nomatch"
  local file="$FIXTURE_DIR/$fixture"
  TOTAL=$((TOTAL+1))

  if grep -E -q "$pattern" "$file"; then
    actual="match"
  else
    actual="nomatch"
  fi

  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS  [$fixture] $label expected=$expected actual=$actual"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "  FAIL  [$fixture] $label expected=$expected actual=$actual"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

echo "=== PASS fixtures: every required section header must match ==="
for fixture in PASS_canonical.md PASS_wording_variation.md; do
  assert_match "$fixture" "$ROLE_PATTERN" "role-analysis-header" "match"
  assert_match "$fixture" "$TASKS_PATTERN" "proposed-tasks-header" "match"
  assert_match "$fixture" "$RISKS_PATTERN" "risks-concerns-header" "match"
  assert_match "$fixture" "$SEQUENCING_PATTERN" "sequencing-header" "match"
  assert_match "$fixture" "$COUNCIL_PATTERN" "council-citations-header" "match"
done

echo ""
echo "=== FAIL fixtures: specifically-targeted section header must NOT match ==="
assert_match "FAIL_missing_role.md" "$ROLE_PATTERN" "missing-role-analysis" "nomatch"
assert_match "FAIL_missing_tasks.md" "$TASKS_PATTERN" "missing-proposed-tasks" "nomatch"
assert_match "FAIL_missing_risks.md" "$RISKS_PATTERN" "missing-risks-concerns" "nomatch"
assert_match "FAIL_missing_sequencing.md" "$SEQUENCING_PATTERN" "missing-sequencing" "nomatch"
assert_match "FAIL_missing_council.md" "$COUNCIL_PATTERN" "missing-council-citations" "nomatch"

echo ""
echo "=== Summary ==="
echo "Total assertions: $TOTAL"
echo "Passed:           $PASS_COUNT"
echo "Failed:           $FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo ""
  echo "FAIL: validator regex patterns do not match the §5T.2 spec."
  exit 1
fi

echo ""
echo "OK: all validator regex patterns behave as specified in"
echo "    skills/plan-team-flow/SKILL.md §5T.2"
exit 0
