#!/usr/bin/env bash
# test-static-analysis-surgical.sh — mechanical text contract for the
# workflow-optimization plan Change 2: /static-analysis keeps its
# unique signals (coverage, mypy baseline regression, SonarQube) but
# scopes post-fix re-verification to the specific tool whose finding
# was fixed, on the changed file(s) only. Removes the contradiction
# between Step 2.3 (which calls mypy) and the Rules section (which
# previously claimed mypy never runs here).
#
# Coverage:
#   T1   — Step 2.3 still references mypy baseline regression (KEEP)
#   T2   — Step 2.1 still references pytest --cov (KEEP — coverage feeds SonarQube)
#   T3   — Step 3 still references sonar-scanner (KEEP)
#   T4   — Step 4.3 ("Re-Verify") tells the agent to re-run ONLY the
#          tool whose finding was just fixed, not the whole project
#   T5   — Step 4.3 explicitly mentions scoping to the changed file(s)
#   T6   — Rules section acknowledges the mypy-baseline carve-out
#   T7   — Rules section acknowledges the scoped post-fix re-run carve-out
#   T8   — Rules section still requires running tests after fix pass
#   T9   — Rules section still enforces the 3-pass hard cap
#   T10  — static-analysis-conventions.md "Interaction with..." section
#          documents the carve-outs (resolves contradiction)
#   T11  — static-analysis-conventions.md no longer claims linters/type
#          checkers "do NOT run again" unconditionally
#
# M-tests:
#   M1   — at least 11 numbered tests
#
# Usage: bash tests/test-static-analysis-surgical.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SA_MD="$REPO_DIR/adapters/claude-code/claude/commands/static-analysis.md"
SA_CONV="$REPO_DIR/adapters/claude-code/claude/rules/static-analysis-conventions.md"

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

# ── T1: Step 2.3 still runs mypy baseline regression ──
step_2_3=$(awk '/^### 2\.3: mypy Baseline Regression/,/^### 3:|^## Step 3/' "$SA_MD")
if echo "$step_2_3" | grep -q 'mypy' && echo "$step_2_3" | grep -qi 'baseline'; then
  pass "T1: Step 2.3 still runs mypy baseline regression"
else
  fail "T1: Step 2.3 still runs mypy baseline regression" \
       "expected 'mypy' + 'baseline' in Step 2.3 of $SA_MD"
fi

# ── T2: Step 2.1 still references pytest --cov ──
step_2_1=$(awk '/^### 2\.1: Python Coverage/,/^### 2\.2/' "$SA_MD")
if echo "$step_2_1" | grep -qE 'pytest.*--cov|coverage\.xml'; then
  pass "T2: Step 2.1 still references pytest --cov"
else
  fail "T2: Step 2.1 still references pytest --cov" \
       "expected coverage command in Step 2.1"
fi

# ── T3: Step 3 still references sonar-scanner ──
step_3=$(awk '/^## Step 3: SonarQube Scan/,/^## Step 4/' "$SA_MD")
if echo "$step_3" | grep -q 'sonar-scanner'; then
  pass "T3: Step 3 still references sonar-scanner"
else
  fail "T3: Step 3 still references sonar-scanner" "expected sonar-scanner in Step 3"
fi

# ── T4: Step 4.3 says re-run only the specific tool ──
step_4_3=$(awk '/^### 4\.3: Re-Verify/,/^### 4\.4/' "$SA_MD")
if echo "$step_4_3" | grep -qiE 'only the tool|only the specific|scoped to|specific.*tool.*finding|tool.*that flagged'; then
  pass "T4: Step 4.3 scopes re-verification to the specific tool"
else
  fail "T4: Step 4.3 scopes re-verification to the specific tool" \
       "expected scope-to-one-tool language in Step 4.3"
fi

# ── T5: Step 4.3 mentions scoping to changed file(s) ──
if echo "$step_4_3" | grep -qiE 'changed file|the file.*just edited|the file.*was edited|file.*you fixed'; then
  pass "T5: Step 4.3 mentions scoping to changed file(s)"
else
  fail "T5: Step 4.3 mentions scoping to changed file(s)" \
       "expected changed-file scoping in Step 4.3"
fi

# ── T6: Rules section acknowledges mypy-baseline carve-out ──
rules=$(awk '/^## Rules/,EOF' "$SA_MD")
if echo "$rules" | grep -qiE 'mypy.*baseline|baseline.*mypy|baseline regression.*runs|baseline regression.*carve.out|baseline regression.*exception'; then
  pass "T6: Rules section acknowledges mypy baseline carve-out"
else
  fail "T6: Rules section acknowledges mypy baseline carve-out" \
       "expected mypy-baseline carve-out language in Rules section"
fi

# ── T7: Rules section acknowledges scoped post-fix re-run carve-out ──
# Require explicit post-fix re-run language: "tool that flagged",
# "specific tool", "scoped re-run", or "carve-out". Generic "scope"
# words like "SCOPE TO BRANCH" do NOT count.
if echo "$rules" | grep -qiE 'tool that flagged|specific tool|scoped re-run|carve.out|re-run only|only the tool'; then
  pass "T7: Rules section acknowledges scoped post-fix carve-out"
else
  fail "T7: Rules section acknowledges scoped post-fix carve-out" \
       "expected explicit 'tool that flagged' / 'only the tool' / 'carve-out' language in Rules"
fi

# ── T8: Rules section still requires tests after fix pass ──
if echo "$rules" | grep -qiE 'RUN TESTS|run.*tests.*fix pass|after every fix pass'; then
  pass "T8: Rules section still requires running tests after fix pass"
else
  fail "T8: Rules section still requires running tests after fix pass" \
       "expected RUN TESTS or after-fix-pass language (LOAD-BEARING)"
fi

# ── T9: Rules section still has 3-pass hard cap ──
if echo "$rules" | grep -qiE '3-PASS HARD CAP|3-pass hard cap|3 fix passes|Maximum 3'; then
  pass "T9: Rules section still has 3-pass hard cap"
else
  fail "T9: Rules section still has 3-pass hard cap" \
       "expected 3-pass cap (LOAD-BEARING)"
fi

# ── T10: static-analysis-conventions.md documents carve-outs ──
conv_block=$(awk '/^## Interaction with Implementation and QA Phases/,EOF' "$SA_CONV")
if echo "$conv_block" | grep -qiE 'baseline regression|scoped|specific tool|carve.out|exception'; then
  pass "T10: static-analysis-conventions.md documents carve-outs"
else
  fail "T10: static-analysis-conventions.md documents carve-outs" \
       "expected carve-out documentation in Interaction section"
fi

# ── T11: static-analysis-conventions.md no longer unconditionally claims tools don't re-run ──
# The old text said: "They do NOT run again in /static-analysis." This is now
# false (mypy baseline; scoped re-run). Require that this exact unconditional
# sentence is gone — replaced by a conditional formulation.
if echo "$conv_block" | grep -qF 'They do NOT run again in `/static-analysis`'; then
  fail "T11: static-analysis-conventions.md no longer unconditionally claims tools don't re-run" \
       "the unconditional 'They do NOT run again' sentence is still present"
else
  pass "T11: static-analysis-conventions.md no longer unconditionally claims tools don't re-run"
fi

# ── T12: shellcheck safety-net step exists in /static-analysis ──
# QA's fix-loop can edit .sh files after /implement's marker landed. Without a
# final shellcheck-on-changed-files pass in /static-analysis, bash regressions
# QA introduced reach /commit unnoticed. Tokens-free unless something needs
# fixing; mirrors the mypy baseline regression carve-out (Step 2.3).
#
# Required: a Step 2.x block that names shellcheck AND scopes to
# `git diff main` changed .sh files (not the whole repo — that's the grinder's
# job per the scope-to-branch rule).
sa_md_body=$(cat "$SA_MD")
if echo "$sa_md_body" | grep -qiE 'shellcheck' \
   && echo "$sa_md_body" | grep -qiE 'git diff[^[:space:]]*main.*HEAD.*\.sh|changed.*\.sh|\.sh.*changed'; then
  pass "T12: shellcheck-on-changed-files safety net documented in static-analysis.md"
else
  fail "T12: shellcheck-on-changed-files safety net documented in static-analysis.md" \
       "expected a shellcheck step scoped to 'git diff main...HEAD' changed .sh files"
fi

# ── T13: shellcheck findings route to the fix loop (not a separate report) ──
# Findings from the new shellcheck pass must feed Step 4 (Fix Loop) like every
# other finding in this phase. Otherwise the safety net catches issues but
# leaves the operator to fix them manually — that's not the design.
if echo "$sa_md_body" | awk '/^### 2\.4|^### 2\.5/,/^## Step 3|^### 3/' | grep -qiE 'feed.*step 4|fix loop|Step 4 fix loop|route.*Step 4|treated like.*finding'; then
  pass "T13: shellcheck findings route to the Step 4 fix loop"
else
  fail "T13: shellcheck findings route to the Step 4 fix loop" \
       "expected the shellcheck step to explicitly route findings to Step 4 fix loop"
fi

# ── M1: ≥13 numbered tests ──
test_count=$(grep -cE '^# ── T[0-9]+' "$0")
if [[ $test_count -ge 13 ]]; then
  pass "M1: ≥13 numbered tests defined ($test_count)"
else
  fail "M1: ≥13 numbered tests defined" "found $test_count"
fi

# ── Summary ──
echo
echo "─────────────────────────────────────────"
echo -e "Ran: $ran  ${GREEN}Passed: $passed${NC}  ${RED}Failed: $failed${NC}"
echo "─────────────────────────────────────────"

[[ $failed -gt 0 ]] && exit 1
exit 0
