#!/usr/bin/env bash
set -euo pipefail

# Test: Agent team command files — verify required sections, cross-gate
# awareness, flow-mode updates, and anti-sycophancy rules.

PASS=0
FAIL=0

# Commands are installed globally
TEAM_REVIEW="$HOME/.claude/commands/team-review.md"
TEAM_QA="$HOME/.claude/commands/team-qa.md"
REVIEW="$HOME/.claude/commands/review.md"
QA="$HOME/.claude/commands/qa.md"
PLAN_PROJECT="$HOME/.claude/commands/plan-project.md"

# Skills are deployed globally via sync.sh restore
FLOW_MODE="$HOME/.claude/skills/flow-mode/SKILL.md"

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

check_regex() {
  local desc="$1" file="$2" pattern="$3"
  if grep -Eq "$pattern" "$file"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Agent Team Command Tests ==="
echo ""

# --- T1: C1/C2 existence ---
echo "T1: Command files exist"
for f in "$TEAM_REVIEW" "$TEAM_QA"; do
  fname="$(basename "$f")"
  if [ -f "$f" ]; then
    echo "  PASS: $fname exists"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $fname missing"
    FAIL=$((FAIL + 1))
  fi
done

echo ""

# --- T2: C1 required sections ---
echo "T2: team-review.md required sections"
check "Frontmatter description" "$TEAM_REVIEW" "description:"
check "Argument hint" "$TEAM_REVIEW" "argument-hint:"
check "Feature Flag Guard" "$TEAM_REVIEW" "Feature Flag Guard"
check "Token Cost" "$TEAM_REVIEW" "Token Cost"
check "Team Spawning" "$TEAM_REVIEW" "Team Spawning"
check "Discussion Phase" "$TEAM_REVIEW" "Discussion"
check "Synthesis" "$TEAM_REVIEW" "Synthesis"
check "TEAM_REVIEW.md artifact" "$TEAM_REVIEW" "TEAM_REVIEW.md"
check "Checkpoint section" "$TEAM_REVIEW" "Checkpoint"
check "Graceful Degradation" "$TEAM_REVIEW" "Graceful Degradation"
check "Feature flag name" "$TEAM_REVIEW" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
check "BA Reviewer role" "$TEAM_REVIEW" "BA Reviewer"
check "UX Reviewer role" "$TEAM_REVIEW" "UX Reviewer"
check "Architect role" "$TEAM_REVIEW" "Architect"
check "Lead Dev role" "$TEAM_REVIEW" "Lead Dev"
check "Read-only tools" "$TEAM_REVIEW" "Read, Grep, Glob, Bash"
check "APPROVED verdict" "$TEAM_REVIEW" "APPROVED"
check "REJECTED verdict" "$TEAM_REVIEW" "REJECTED"

echo ""

# --- T3: C2 required sections ---
echo "T3: team-qa.md required sections"
check "Frontmatter description" "$TEAM_QA" "description:"
check "Argument hint" "$TEAM_QA" "argument-hint:"
check "Feature Flag Guard" "$TEAM_QA" "Feature Flag Guard"
check "Token Cost" "$TEAM_QA" "Token Cost"
check "Team Spawning" "$TEAM_QA" "Team Spawning"
check "Discussion Phase" "$TEAM_QA" "Discussion"
check "Synthesis" "$TEAM_QA" "Synthesis"
check "TEAM_QA.md artifact" "$TEAM_QA" "TEAM_QA.md"
check "Checkpoint section" "$TEAM_QA" "Checkpoint"
check "Graceful Degradation" "$TEAM_QA" "Graceful Degradation"
check "Feature flag name" "$TEAM_QA" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
check "Tester role" "$TEAM_QA" "Tester"
check "Security Reviewer role" "$TEAM_QA" "Security Reviewer"
check "Performance Reviewer role" "$TEAM_QA" "Performance Reviewer"
check "QA Lead role" "$TEAM_QA" "QA Lead"
check "Read-only tools" "$TEAM_QA" "Read, Grep, Glob, Bash"
check "PASSED verdict" "$TEAM_QA" "PASSED"
check "FAILED verdict" "$TEAM_QA" "FAILED"

echo ""

# --- T4: Anti-sycophancy in both team commands ---
echo "T4: Anti-sycophancy rules"
for f in "$TEAM_REVIEW" "$TEAM_QA"; do
  fname="$(basename "$f")"
  check "$fname: banned phrase 'Great point!'" "$f" "Great point!"
  check "$fname: banned phrase 'Good catch!'" "$f" "Good catch!"
done

echo ""

# --- T5: C4 — review.md cross-gate awareness ---
echo "T5: review.md Step 0.7 (cross-gate awareness)"
check "review.md references TEAM_REVIEW.md" "$REVIEW" "TEAM_REVIEW.md"
check "review.md has Step 0.7" "$REVIEW" "Step 0.7"
check "review.md checks REJECTED" "$REVIEW" "REJECTED"

echo ""

# --- T6: C5 — qa.md cross-gate awareness ---
echo "T6: qa.md Step 0.7 (cross-gate awareness)"
check "qa.md references TEAM_QA.md" "$QA" "TEAM_QA.md"
check "qa.md has Step 0.7" "$QA" "Step 0.7"
check "qa.md checks FAILED" "$QA" "FAILED"

echo ""

# --- T7: flow-mode/SKILL.md updates ---
echo "T7: flow-mode/SKILL.md team pipeline"
check "Team pipeline label" "$FLOW_MODE" "Team pipeline"
check "TEAM_REVIEW.md in phase detection" "$FLOW_MODE" "TEAM_REVIEW.md"
check "TEAM_QA.md in phase detection" "$FLOW_MODE" "TEAM_QA.md"
check "team-review phase commit" "$FLOW_MODE" "team review report"
check "team-qa phase commit" "$FLOW_MODE" "team QA report"

echo ""

# --- T8: plan-project.md team guidance ---
echo "T8: plan-project.md team gate guidance"
check "Team pipeline reference" "$PLAN_PROJECT" "team-review"
check "Team pipeline reference" "$PLAN_PROJECT" "team-qa"
check "Feature flag mention" "$PLAN_PROJECT" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
# 2026-06-02 drift fix: plan-project.md now describes gates as "optional,
# read-only" (was "advisory"). Same intent — gates don't block.
check "Advisory for phase gates" "$PLAN_PROJECT" "read-only"

echo ""

# --- T9: Shared boilerplate drift detection ---
echo "T9: Shared boilerplate consistency (C1 vs C2)"
for pattern in \
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" \
  "Feature Flag Guard" \
  "Token Cost" \
  "Read, Grep, Glob, Bash" \
  "Great point!" \
  "Good catch!" \
  "Graceful Degradation"; do
  IN_C1=$(grep -cF "$pattern" "$TEAM_REVIEW" 2>/dev/null || echo 0)
  IN_C2=$(grep -cF "$pattern" "$TEAM_QA" 2>/dev/null || echo 0)
  if [ "$IN_C1" -gt 0 ] && [ "$IN_C2" -gt 0 ]; then
    echo "  PASS: Both commands contain '$pattern'"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: Drift — '$pattern' missing in C1($IN_C1) or C2($IN_C2)"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
