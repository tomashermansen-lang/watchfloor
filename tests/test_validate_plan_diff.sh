#!/bin/bash
# test_validate_plan_diff.sh
#
# Plan-ownership Track 3 — pre-commit defense-in-depth.
#
# Verifies validate-plan-diff.py:
#   - exits 0 when the staged plan diff is within the allowlist for the
#     current phase
#   - exits non-zero when the staged diff would have allowed 7d434e3 to
#     reach the commit boundary
#   - emits a clear human-readable error message naming the unauthorized
#     fields and the recommended action (/plan-project --update)
#
# Usage: bash tests/test_validate_plan_diff.sh

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_ROOT}/adapters/claude-code/claude/tools/validate-plan-diff.py"

WORKDIR="${TMPDIR:-/tmp}/validate-plan-diff-test-$$"
trap 'rm -rf "$WORKDIR"' EXIT

setup_repo() {
    mkdir -p "$WORKDIR/repo/docs/INPROGRESS_Plan_test"
    cd "$WORKDIR/repo"
    git init -q -b main
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false

    cat > docs/INPROGRESS_Plan_test/execution-plan.yaml <<'YAML'
schema_version: "2.0.0"
name: test
vision: "v"
users: ["op"]
success_criteria: [{id: SC1, description: "x", measurable_via: test}]
scope: {in_scope: [], out_of_scope: []}
tech_stack: [bash]
existing_infrastructure_to_reuse: []
test_targets: [{id: t, path: ., description: ""}]
setup: {prerequisites: []}
kill_criteria: []
design_notes: []
risks: []
phases:
  - id: P1
    name: p1
    overview_summary: "x"
    sequencing_rationale: "y"
    tasks:
      - id: task-current
        name: "Current"
        task_type: development
        status: wip
        what: "current task"
        why: "why"
        where: {modify: []}
        acceptance: ["works"]
        prompt: "do it"
        depends: []
      - id: task-sibling
        name: "Sibling"
        task_type: development
        status: pending
        what: "sibling task does the sibling thing"
        why: "because sibling"
        where: {modify: []}
        acceptance: ["works"]
        prompt: "do it"
        depends: []
YAML
    git add . >/dev/null
    git commit -q -m "initial"
    cd - >/dev/null
}

# Helper: stage a YAML change and run the validator against it.
stage_and_validate() {
    local phase="$1" task="$2" sed_expr="$3"
    cd "$WORKDIR/repo"
    sed -i.bak "$sed_expr" docs/INPROGRESS_Plan_test/execution-plan.yaml
    rm -f docs/INPROGRESS_Plan_test/execution-plan.yaml.bak
    git add docs/INPROGRESS_Plan_test/execution-plan.yaml
    AUTOPILOT_CURRENT_PHASE="$phase" AUTOPILOT_CURRENT_TASK_ID="$task" \
        python3 "$VALIDATOR" 2>&1
    local rc=$?
    git restore --staged --worktree docs/INPROGRESS_Plan_test/execution-plan.yaml >/dev/null 2>&1
    cd - >/dev/null
    return $rc
}

# Tests ------------------------------------------------------------------

test_tool_exists() {
    if [[ -f "$VALIDATOR" ]]; then
        printf "${GREEN}PASS${NC}: validate-plan-diff.py exists\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: validate-plan-diff.py not found at $VALIDATOR\n"
        failed=$((failed + 1))
    fi
}

test_no_staged_plan_diff_allows() {
    cd "$WORKDIR/repo"
    AUTOPILOT_CURRENT_PHASE=static-analysis AUTOPILOT_CURRENT_TASK_ID=task-current \
        python3 "$VALIDATOR" >/dev/null 2>&1
    local rc=$?
    cd - >/dev/null
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: no staged plan diff → exit 0\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: no staged plan diff but exit %s\n" "$rc"
        failed=$((failed + 1))
    fi
}

test_sibling_what_rewrite_denied() {
    # 7d434e3 replay: /static-analysis rewriting sibling task what
    local out
    out=$(stage_and_validate static-analysis task-current \
        's|sibling task does the sibling thing|rewritten by /static-analysis|')
    local rc=$?
    if [[ $rc -ne 0 ]] && echo "$out" | grep -qE "(REJECTED|unauthorized|cannot|deny|denied|may write .* but the diff touches)"; then
        printf "${GREEN}PASS${NC}: sibling-what rewrite denied by validate-plan-diff\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: sibling-what rewrite was NOT denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
}

test_status_flip_by_start_allowed() {
    local out
    out=$(stage_and_validate start task-current 's|status: wip|status: wip\n        last_updated: "2026-05-25T12:00:00Z"|')
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: /start status edit allowed by validate-plan-diff\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /start status edit denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
}

test_plan_project_full_authority() {
    local out
    out=$(stage_and_validate plan-project task-current \
        's|sibling task does the sibling thing|rewritten by /plan-project|')
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: /plan-project sibling rewrite allowed (full authority)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /plan-project sibling rewrite denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
}

test_interactive_session_allows() {
    cd "$WORKDIR/repo"
    sed -i.bak 's|sibling task does the sibling thing|interactive rewrite|' docs/INPROGRESS_Plan_test/execution-plan.yaml
    rm -f docs/INPROGRESS_Plan_test/execution-plan.yaml.bak
    git add docs/INPROGRESS_Plan_test/execution-plan.yaml
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
    python3 "$VALIDATOR" >/dev/null 2>&1
    local rc=$?
    git restore --staged --worktree docs/INPROGRESS_Plan_test/execution-plan.yaml >/dev/null 2>&1
    cd - >/dev/null
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: interactive session allowed (no AUTOPILOT_CURRENT_PHASE)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: interactive session denied (rc=%s)\n" "$rc"
        failed=$((failed + 1))
    fi
}

test_error_message_recommends_plan_project_update() {
    local out
    out=$(stage_and_validate static-analysis task-current \
        's|sibling task does the sibling thing|rewritten|')
    if echo "$out" | grep -q "plan-project --update"; then
        printf "${GREEN}PASS${NC}: error message recommends /plan-project --update\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: error message missing /plan-project --update recommendation\n  out: %s\n" "$out"
        failed=$((failed + 1))
    fi
}

# Run -------------------------------------------------------------------

echo "Testing validate-plan-diff.py (plan-ownership Track 3)..."
echo "Target: $VALIDATOR"
echo

setup_repo
test_tool_exists
test_no_staged_plan_diff_allows
test_sibling_what_rewrite_denied
test_status_flip_by_start_allowed
test_plan_project_full_authority
test_interactive_session_allows
test_error_message_recommends_plan_project_update

echo
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]] || exit 1
