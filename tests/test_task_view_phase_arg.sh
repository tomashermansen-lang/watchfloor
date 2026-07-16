#!/usr/bin/env bash
# Regression guard: the task-view.py --phase argument injected into a phase's
# system prompt MUST be a valid PHASE_ORDER token, not the mangled display name.
# The old derivation turned "Business Analysis" into "business-analysis" (which
# task-view.py rejects with `exit 2 unknown phase`), wasting one tool call per
# phase — caught 2026-06-02 in the sonnet canary stream.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

PASS=0
FAIL=0
check() { if "$2"; then echo "  ok: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi; }

# Valid task-view.py phases (slash-command / PHASE_ORDER tokens).
VALID="ba commit done hotfix implement manualtest plan plan-project qa retro review start static-analysis team-qa team-review testplan ux"

tv() { bash -c "source '$LIB' 2>/dev/null; task_view_phase_arg \"\$1\" \"\$2\"" _ "$1" "$2"; }

is_valid() { case " $VALID " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

test_ba_token() {
  local r; r=$(tv "ba" "Business Analysis")
  [[ "$r" == "ba" ]] || { echo "    got '$r', want 'ba'"; return 1; }
}
check "Business Analysis (token ba) -> ba" test_ba_token

test_implement_token() {
  local r; r=$(tv "implement" "Implementation (TDD)")
  [[ "$r" == "implement" ]] || { echo "    got '$r', want 'implement'"; return 1; }
}
check "Implementation (TDD) (token implement) -> implement" test_implement_token

test_testplan_token() {
  local r; r=$(tv "testplan" "Test Plan")
  [[ "$r" == "testplan" ]] || { echo "    got '$r', want 'testplan'"; return 1; }
}
check "Test Plan (token testplan) -> testplan" test_testplan_token

test_never_emits_invalid_for_known_phases() {
  # Every display name + canonical token must yield a VALID task-view phase.
  local cases=("ba|Business Analysis" "plan|Architecture Plan" "testplan|Test Plan" \
               "review|Review" "implement|Implementation (TDD)" "qa|QA" \
               "static-analysis|Static Analysis" "commit|Commit & Merge")
  local c tok name r
  for c in "${cases[@]}"; do
    tok="${c%%|*}"; name="${c#*|}"
    r=$(tv "$tok" "$name")
    is_valid "$r" || { echo "    '$name' (token $tok) -> '$r' is NOT a valid task-view phase"; return 1; }
  done
}
check "all known phases resolve to valid task-view tokens" test_never_emits_invalid_for_known_phases

test_no_token_falls_back_to_derivation() {
  # /done passes no token; derive from display name (done is itself valid).
  local r; r=$(tv "" "Done")
  [[ "$r" == "done" ]] || { echo "    got '$r', want 'done'"; return 1; }
}
check "empty token falls back to display-name derivation" test_no_token_falls_back_to_derivation

test_regression_not_business_analysis() {
  local r; r=$(tv "ba" "Business Analysis")
  [[ "$r" != "business-analysis" ]] || { echo "    regressed to the invalid 'business-analysis'"; return 1; }
}
check "does NOT regress to 'business-analysis'" test_regression_not_business_analysis

echo ""
echo "test_task_view_phase_arg: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
