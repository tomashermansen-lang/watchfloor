#!/bin/bash
# test_task_view.sh
#
# Plan-ownership Track 1 — verify task-view.py produces a per-phase
# projection of execution-plan.yaml containing:
#   - only the consumption-table-allowed project/phase/task fields
#   - the current task's full block
#   - dependency task blocks (limited to artifact_refs per phase profile)
#   - NO sibling task blocks
#
# Usage: bash tests/test_task_view.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
failed=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_VIEW="${REPO_ROOT}/adapters/claude-code/claude/tools/task-view.py"
OWNERSHIP="${REPO_ROOT}/core/schema/plan-field-ownership.yaml"

WORKDIR="${TMPDIR:-/tmp}/task-view-test-$$"
trap 'rm -rf "$WORKDIR"' EXIT

setup_fixture() {
    mkdir -p "$WORKDIR"
    cat > "$WORKDIR/plan.yaml" <<'YAML'
schema_version: "2.0.0"
name: test-plan
vision: "the project vision"
users:
  - "operator"
success_criteria:
  - id: SC1
    description: "criterion one"
    measurable_via: test
scope:
  in_scope: ["X"]
  out_of_scope: ["Y"]
tech_stack:
  - bash
  - python3
existing_infrastructure_to_reuse: []
test_targets:
  - id: t
    path: .
    description: "tests"
setup:
  prerequisites: []
kill_criteria: []
design_notes:
  - id: DN1
    note: "be careful"
risks: []
phases:
  - id: P1
    name: "phase one"
    overview_summary: "phase one overview"
    sequencing_rationale: "P1 first because reasons"
    tasks:
      - id: task-alpha
        name: "Task Alpha"
        task_type: development
        status: done
        what: "alpha does the alpha thing"
        why: "because alpha"
        where:
          modify:
            - some/file.py
        acceptance:
          - "alpha works"
        prompt: "do alpha"
        depends: []
        artifact_refs:
          requirements_path: docs/INPROGRESS_Feature_alpha/REQUIREMENTS.md
          plan_path: docs/INPROGRESS_Feature_alpha/PLAN.md
        codebase_snapshot:
          commit_ref: abc123
          modules_changed:
            - path: some/file.py
              role: "core"
              lines: 50
          interfaces_introduced:
            - name: do_alpha
              defined_in: some/file.py
              signature: "do_alpha() -> None"
          tests_added: []
      - id: task-beta
        name: "Task Beta"
        task_type: development
        status: wip
        what: "beta does the beta thing"
        why: "because beta"
        where:
          modify:
            - some/other.py
        acceptance:
          - "beta works"
        prompt: "do beta"
        depends:
          - task-alpha
      - id: task-gamma
        name: "Task Gamma"
        task_type: development
        status: pending
        what: "gamma does the gamma thing"
        why: "because gamma"
        where:
          modify:
            - some/third.py
        acceptance:
          - "gamma works"
        prompt: "do gamma"
        depends: []
YAML
}

# ─── Test 1: tool exists and is executable ───────────────────────────────
test_tool_exists() {
    if [[ -f "$TASK_VIEW" ]] && [[ -x "$TASK_VIEW" || "$TASK_VIEW" == *.py ]]; then
        printf "${GREEN}PASS${NC}: task-view.py exists\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: task-view.py not found at $TASK_VIEW\n"
        failed=$((failed + 1))
    fi
}

# ─── Test 2: ownership matrix exists and is parseable ────────────────────
test_ownership_exists() {
    if [[ -f "$OWNERSHIP" ]]; then
        if python3 -c "import yaml; yaml.safe_load(open('$OWNERSHIP'))" 2>/dev/null; then
            printf "${GREEN}PASS${NC}: plan-field-ownership.yaml exists and is valid YAML\n"
            passed=$((passed + 1))
        else
            printf "${RED}FAIL${NC}: plan-field-ownership.yaml exists but is not valid YAML\n"
            failed=$((failed + 1))
        fi
    else
        printf "${RED}FAIL${NC}: plan-field-ownership.yaml not found at $OWNERSHIP\n"
        failed=$((failed + 1))
    fi
}

# ─── Test 3: slicer runs without error for ba phase on task-beta ─────────
test_runs_for_ba() {
    local out
    if ! out=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase ba 2>&1); then
        printf "${RED}FAIL${NC}: task-view.py exited non-zero for ba/task-beta\n"
        printf "  stderr: %s\n" "$out"
        failed=$((failed + 1))
        return
    fi
    printf "${GREEN}PASS${NC}: task-view.py exits 0 for ba/task-beta\n"
    passed=$((passed + 1))
}

# ─── Test 4: output contains the current task's what field ───────────────
test_includes_current_task() {
    local out
    out=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase ba 2>/dev/null)
    if echo "$out" | grep -q "beta does the beta thing"; then
        printf "${GREEN}PASS${NC}: output includes current task's what\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: output missing current task's what\n"
        failed=$((failed + 1))
    fi
}

# ─── Test 5: output does NOT contain sibling task content ────────────────
test_excludes_siblings() {
    local out
    out=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase ba 2>/dev/null)
    local fail=0
    if echo "$out" | grep -q "gamma does the gamma thing"; then
        printf "${RED}FAIL${NC}: output INCLUDES sibling task-gamma's what\n"
        fail=1
    fi
    if [[ $fail -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: output excludes sibling task-gamma\n"
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
}

# ─── Test 6: dep task included with limited fields ───────────────────────
test_includes_dep_artifact_refs() {
    local out
    out=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase ba 2>/dev/null)
    # ba's dep_artifact_refs is [requirements_path]; alpha's requirements_path should appear
    if echo "$out" | grep -q "REQUIREMENTS.md"; then
        printf "${GREEN}PASS${NC}: dep task's requirements_path appears for /ba\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: dep task's requirements_path missing for /ba\n"
        failed=$((failed + 1))
    fi
}

# ─── Test 7: static-analysis projection is narrow (no acceptance/prompt/why) ─
test_static_analysis_narrow() {
    local out
    out=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase static-analysis 2>/dev/null)
    local fail=0
    # SA must NOT see what/why/acceptance/prompt per consumption table
    if echo "$out" | grep -qE "^[[:space:]]*what:"; then
        printf "${RED}FAIL${NC}: static-analysis projection includes 'what' (should not)\n"
        fail=1
    fi
    if echo "$out" | grep -qE "^[[:space:]]*prompt:"; then
        printf "${RED}FAIL${NC}: static-analysis projection includes 'prompt' (should not)\n"
        fail=1
    fi
    # But it MUST include where (the only task-level field allowed)
    if ! echo "$out" | grep -qE "^[[:space:]]*where:"; then
        printf "${RED}FAIL${NC}: static-analysis projection missing 'where'\n"
        fail=1
    fi
    if [[ $fail -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: static-analysis projection is narrow (where only, no what/prompt)\n"
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
}

# ─── Test 8: implement projection includes /plan dep's plan_path ─────────
test_implement_dep_plan_path() {
    local out
    out=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase implement 2>/dev/null)
    # implement reads plan_path from deps; alpha's plan_path should appear
    if echo "$out" | grep -q "PLAN.md"; then
        printf "${GREEN}PASS${NC}: /implement projection includes dep's plan_path\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /implement projection missing dep's plan_path\n"
        failed=$((failed + 1))
    fi
}

# ─── Test 9: byte-stable output (deterministic) ──────────────────────────
test_deterministic_output() {
    local out1 out2
    out1=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase ba 2>/dev/null)
    out2=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase ba 2>/dev/null)
    if [[ "$out1" == "$out2" ]]; then
        printf "${GREEN}PASS${NC}: output is byte-stable across invocations\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: output differs between identical invocations\n"
        failed=$((failed + 1))
    fi
}

# ─── Test 10: unknown phase exits 2 ──────────────────────────────────────
test_unknown_phase_exits_2() {
    set +e
    python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase bogus-phase >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ $rc -eq 2 ]]; then
        printf "${GREEN}PASS${NC}: unknown phase exits 2\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: unknown phase exit was $rc (expected 2)\n"
        failed=$((failed + 1))
    fi
}

# ─── Test 11: unknown task exits 3 ───────────────────────────────────────
test_unknown_task_exits_3() {
    set +e
    python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task no-such-task --phase ba >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ $rc -eq 3 ]]; then
        printf "${GREEN}PASS${NC}: unknown task exits 3\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: unknown task exit was $rc (expected 3)\n"
        failed=$((failed + 1))
    fi
}

# ─── Test 12: plan-project, retro, done see entire plan ──────────────────
test_whole_plan_readers() {
    local fail=0
    for phase in plan-project retro done; do
        local out
        out=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase "$phase" 2>/dev/null)
        # whole-plan readers should see ALL three task whats
        local count
        count=$(echo "$out" | grep -cE "(alpha|beta|gamma) does the (alpha|beta|gamma) thing" || true)
        if [[ "$count" -lt 3 ]]; then
            printf "${RED}FAIL${NC}: phase=%s missed sibling tasks (count=%s)\n" "$phase" "$count"
            fail=1
        fi
    done
    if [[ $fail -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: plan-project, retro, done see entire plan\n"
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
}

# ─── Test 13: footer points to escape valve ──────────────────────────────
test_footer_lists_alternatives() {
    local out
    out=$(python3 "$TASK_VIEW" --plan "$WORKDIR/plan.yaml" --task task-beta --phase ba 2>/dev/null)
    # The footer should list sibling task IDs so the agent has an official escape
    if echo "$out" | grep -q "task-gamma"; then
        printf "${GREEN}PASS${NC}: footer mentions sibling task IDs for escape (task-gamma found)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: footer missing sibling task IDs for operator escape\n"
        failed=$((failed + 1))
    fi
}

# ─── Run ─────────────────────────────────────────────────────────────────
echo "Testing task-view.py + plan-field-ownership.yaml (plan-ownership Track 1)..."
echo "Target: $TASK_VIEW"
echo "Matrix: $OWNERSHIP"
echo

setup_fixture
test_tool_exists
test_ownership_exists
test_runs_for_ba
test_includes_current_task
test_excludes_siblings
test_includes_dep_artifact_refs
test_static_analysis_narrow
test_implement_dep_plan_path
test_deterministic_output
test_unknown_phase_exits_2
test_unknown_task_exits_3
test_whole_plan_readers
test_footer_lists_alternatives

echo
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]] || exit 1
