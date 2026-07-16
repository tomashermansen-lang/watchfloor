#!/bin/bash
# test_plan_ownership_hook.sh
#
# Plan-ownership Track 2 — verify the PreToolUse hook blocks unauthorized
# plan writes under autopilot, allows them in interactive sessions, and
# honors PLAN_WRITE_INTENT carve-outs for legitimate orchestrator helpers.
#
# Replays the 7d434e3 incident as input to assert: under autopilot context,
# every Edit on a sibling task's `what` field is denied.
#
# Usage: bash tests/test_plan_ownership_hook.sh

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${REPO_ROOT}/adapters/claude-code/claude/hooks/plan-ownership-guard.sh"
OWNERSHIP="${REPO_ROOT}/core/schema/plan-field-ownership.yaml"

WORKDIR="${TMPDIR:-/tmp}/plan-ownership-hook-test-$$"
trap 'rm -rf "$WORKDIR"' EXIT

setup_fixture() {
    mkdir -p "$WORKDIR"
    cat > "$WORKDIR/execution-plan.yaml" <<'YAML'
schema_version: "2.0.0"
name: test-plan
vision: "vision"
users: ["op"]
success_criteria:
  - id: SC1
    description: "criterion one"
    measurable_via: test
scope:
  in_scope: []
  out_of_scope: []
tech_stack: [bash]
existing_infrastructure_to_reuse: []
test_targets:
  - id: t
    path: .
    description: "tests"
setup:
  prerequisites: []
kill_criteria: []
design_notes: []
risks: []
phases:
  - id: P1
    name: "p1"
    overview_summary: "x"
    sequencing_rationale: "y"
    tasks:
      - id: task-current
        name: "Current"
        task_type: development
        status: wip
        what: "current task does the current thing"
        why: "because current"
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
      - id: task-done
        name: "Done predecessor"
        task_type: development
        status: done
        what: "done task does the done thing"
        why: "because done"
        where: {modify: []}
        acceptance: ["worked"]
        prompt: "did it"
        depends: []
        codebase_snapshot:
          commit_ref: abc123
          interfaces_introduced:
            - name: do_thing
              defined_in: file.py
              signature: "do_thing() -> None"
YAML
}

# Helpers ----------------------------------------------------------------

# Invoke the hook with a synthesized Claude-Code PreToolUse JSON payload.
# Pipes a fully-formed JSON via Python through the hook. Echoes hook stdout;
# stderr is dropped unless captured by the caller via 2>&1.
invoke_hook() {
    local tool_name="$1" file_path="$2" old_string="$3" new_string="$4"
    # Use environment-passed args to avoid quoting hell with apostrophes/braces.
    TOOL_NAME="$tool_name" FILE_PATH="$file_path" \
    OLD_STRING="$old_string" NEW_STRING="$new_string" \
    python3 -c '
import json, os, sys
payload = {
    "tool_name": os.environ["TOOL_NAME"],
    "tool_input": {
        "file_path": os.environ["FILE_PATH"],
        "old_string": os.environ["OLD_STRING"],
        "new_string": os.environ["NEW_STRING"],
    },
}
sys.stdout.write(json.dumps(payload))
' | bash "$HOOK"
}

# Tests ------------------------------------------------------------------

test_hook_exists() {
    if [[ -f "$HOOK" ]]; then
        printf "${GREEN}PASS${NC}: plan-ownership-guard.sh exists\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: plan-ownership-guard.sh not found at $HOOK\n"
        failed=$((failed + 1))
    fi
}

test_interactive_allows_anything() {
    # No AUTOPILOT_CURRENT_PHASE set → interactive → allow
    unset AUTOPILOT_CURRENT_PHASE CHAIN_CURRENT_TASK_ID
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "sibling task does the sibling thing" \
        "sibling task does something new" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: interactive session — write allowed (rc=0)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: interactive session denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
}

test_static_analysis_denies_sibling_what_edit() {
    # The 7d434e3 incident: /static-analysis under autopilot edits a sibling's what.
    # Realistic Edit calls include the YAML key + the sibling task's id in context.
    export AUTOPILOT_CURRENT_PHASE=static-analysis
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      - id: task-sibling
        name: \"Sibling\"
        task_type: development
        status: pending
        what: \"sibling task does the sibling thing\"" \
        "      - id: task-sibling
        name: \"Sibling\"
        task_type: development
        status: pending
        what: \"rewritten sibling content\"" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]] && echo "$out" | grep -q '"permissionDecision".*"deny"'; then
        printf "${GREEN}PASS${NC}: /static-analysis sibling-what edit denied\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /static-analysis sibling-what edit not denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_static_analysis_allows_own_artifact_ref() {
    # /static-analysis IS allowed to set its own static_analysis_path
    export AUTOPILOT_CURRENT_PHASE=static-analysis
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      depends: []" \
        "      depends: []
      artifact_refs:
        static_analysis_path: docs/INPROGRESS_Feature_task-current/STATIC_ANALYSIS.md" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: /static-analysis own static_analysis_path edit allowed\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /static-analysis own static_analysis_path edit denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_start_allows_status_flip() {
    export AUTOPILOT_CURRENT_PHASE=start
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "        status: wip" \
        "        status: wip
        last_updated: '2026-05-25T12:00:00Z'" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: /start status edit allowed\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /start status edit denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_done_allows_codebase_snapshot_on_current() {
    export AUTOPILOT_CURRENT_PHASE=done
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "        status: wip" \
        "        status: done
        codebase_snapshot:
          commit_ref: deadbeef" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: /done codebase_snapshot on current task allowed\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /done codebase_snapshot on current task denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_done_denies_sibling_task_edit() {
    # /done is normally allowed to write codebase_snapshot — but ONLY on the
    # current task. An attempt to rewrite a sibling task's codebase_snapshot
    # must be denied via the cross-task check.
    # (WORM-on-done check is in Track 4 — separate test there.)
    export AUTOPILOT_CURRENT_PHASE=done
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      - id: task-done
        name: \"Done predecessor\"
        codebase_snapshot:
          commit_ref: abc123
          interfaces_introduced:
            - name: do_thing
              defined_in: file.py
              signature: \"do_thing() -> None\"" \
        "      - id: task-done
        name: \"Done predecessor\"
        codebase_snapshot:
          commit_ref: abc123
          interfaces_introduced:
            - name: do_thing
              defined_in: file.py
              signature: \"do_thing() -> bool\"" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]] && echo "$out" | grep -q '"permissionDecision".*"deny"'; then
        printf "${GREEN}PASS${NC}: /done sibling-task edit denied (cross-task)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /done sibling-task edit not denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_plan_project_allows_anything() {
    export AUTOPILOT_CURRENT_PHASE=plan-project
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "sibling task does the sibling thing" \
        "rewritten by /plan-project --update" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: /plan-project sibling-what edit allowed (full authority)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /plan-project sibling-what edit denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_phase_results_intent_allows_deviation_tracker_writes() {
    # deviation-tracker.py is called from the Shared Closing Step of every
    # plan-aware phase. The orchestrator sets PLAN_WRITE_INTENT=phase_results
    # for the duration of the subprocess.
    export AUTOPILOT_CURRENT_PHASE=qa
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    export PLAN_WRITE_INTENT=phase_results
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      depends: []" \
        "      depends: []
      phase_results:
        - phase: qa
          conformance: aligned" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: PLAN_WRITE_INTENT=phase_results allows /qa's phase_results write\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: PLAN_WRITE_INTENT=phase_results blocked (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID PLAN_WRITE_INTENT
}

test_wrong_intent_does_not_open_door() {
    # PLAN_WRITE_INTENT=phase_results does NOT authorize a sibling-what rewrite.
    # Realistic Edit context includes the sibling task's id + the `what:` key.
    export AUTOPILOT_CURRENT_PHASE=qa
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    export PLAN_WRITE_INTENT=phase_results
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      - id: task-sibling
        name: \"Sibling\"
        what: \"sibling task does the sibling thing\"" \
        "      - id: task-sibling
        name: \"Sibling\"
        what: \"rewritten\"" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]] && echo "$out" | grep -q '"permissionDecision".*"deny"'; then
        printf "${GREEN}PASS${NC}: PLAN_WRITE_INTENT=phase_results does not open door to sibling-what rewrite\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: PLAN_WRITE_INTENT=phase_results wrongly permitted sibling-what (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID PLAN_WRITE_INTENT
}

test_read_under_autopilot_denied_for_phase_agent() {
    # Track 1 hard enforcement: /static-analysis reading the plan directly
    # is denied; the agent must use task-view.py.
    export AUTOPILOT_CURRENT_PHASE=static-analysis
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    unset PLAN_WRITE_INTENT
    local payload out rc
    payload=$(python3 -c 'import json, sys; sys.stdout.write(json.dumps({
        "tool_name": "Read",
        "tool_input": {"file_path": "'"$WORKDIR"'/execution-plan.yaml"}
    }))')
    out=$(echo "$payload" | bash "$HOOK" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]] && echo "$out" | grep -q '"permissionDecision".*"deny"' \
        && echo "$out" | grep -q "task-view.py"; then
        printf "${GREEN}PASS${NC}: Read of plan denied for /static-analysis with task-view.py redirect\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: Read of plan was not denied for /static-analysis (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_read_under_autopilot_allowed_for_plan_project() {
    # /plan-project is a whole-plan reader — allowed
    export AUTOPILOT_CURRENT_PHASE=plan-project
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    unset PLAN_WRITE_INTENT
    local payload out rc
    payload=$(python3 -c 'import json, sys; sys.stdout.write(json.dumps({
        "tool_name": "Read",
        "tool_input": {"file_path": "'"$WORKDIR"'/execution-plan.yaml"}
    }))')
    out=$(echo "$payload" | bash "$HOOK" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: Read of plan allowed for /plan-project (whole-plan reader)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: Read of plan was denied for /plan-project (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_read_in_interactive_session_allowed() {
    # No AUTOPILOT_CURRENT_PHASE = operator-in-loop = allow
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID PLAN_WRITE_INTENT
    local payload out rc
    payload=$(python3 -c 'import json, sys; sys.stdout.write(json.dumps({
        "tool_name": "Read",
        "tool_input": {"file_path": "'"$WORKDIR"'/execution-plan.yaml"}
    }))')
    out=$(echo "$payload" | bash "$HOOK" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: Read of plan allowed in interactive session\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: Read of plan was denied in interactive session (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
}

test_hook_silent_on_non_plan_file() {
    # Edits to OTHER files must pass through unaffected
    export AUTOPILOT_CURRENT_PHASE=static-analysis
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/source.py" "old code" "new code" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: hook is silent on non-plan file paths\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: hook interfered with non-plan file edit (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_warn_mode_emits_warning_but_allows() {
    # When PLAN_OWNERSHIP_GUARD_MODE=warn, denies become warnings (exit 0 + stderr)
    export AUTOPILOT_CURRENT_PHASE=static-analysis
    export AUTOPILOT_CURRENT_TASK_ID=task-current
    export PLAN_OWNERSHIP_GUARD_MODE=warn
    unset PLAN_WRITE_INTENT
    local stdout stderr rc
    local tmp_err="$WORKDIR/stderr.$$"
    stdout=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      - id: task-sibling
        what: \"sibling task does the sibling thing\"" \
        "      - id: task-sibling
        what: \"rewritten\"" 2>"$tmp_err")
    rc=$?
    stderr=$(cat "$tmp_err" 2>/dev/null || true)
    rm -f "$tmp_err"
    if [[ $rc -eq 0 ]] && echo "$stderr" | grep -qE "(WARN|warning|would_deny)"; then
        printf "${GREEN}PASS${NC}: warn mode emits warning + allows (rc=0)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: warn mode did not emit warning or did not allow (rc=%s, stderr=%s)\n" "$rc" "$stderr"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID PLAN_OWNERSHIP_GUARD_MODE
}

# Run -------------------------------------------------------------------

echo "Testing plan-ownership-guard.sh hook (plan-ownership Track 2)..."
echo "Target: $HOOK"
echo "Matrix: $OWNERSHIP"
echo

setup_fixture
test_hook_exists
test_interactive_allows_anything
test_static_analysis_denies_sibling_what_edit
test_static_analysis_allows_own_artifact_ref
test_start_allows_status_flip
test_done_allows_codebase_snapshot_on_current
test_done_denies_sibling_task_edit
test_plan_project_allows_anything
test_phase_results_intent_allows_deviation_tracker_writes
test_wrong_intent_does_not_open_door
test_read_under_autopilot_denied_for_phase_agent
test_read_under_autopilot_allowed_for_plan_project
test_read_in_interactive_session_allowed
test_hook_silent_on_non_plan_file
test_warn_mode_emits_warning_but_allows

echo
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]] || exit 1
