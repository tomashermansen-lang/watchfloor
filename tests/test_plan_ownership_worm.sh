#!/bin/bash
# test_plan_ownership_worm.sh
#
# Plan-ownership Track 4 — WORM lock on codebase_snapshot and
# predecessor_context fields once a task transitions to status=done.
#
# Tests both layers:
#   - PreToolUse hook (plan-ownership-guard.sh + check helper):
#     even /done is denied from writing codebase_snapshot to a task
#     that's already in status=done in the on-disk plan.
#   - validate-plan-diff.py (pre-commit defense): same enforcement at
#     the commit boundary.
#
# Track 4 is the "frozen-evidence corruption" defense observed in
# commit 7d434e3 (13 reflowed signature: lines on 3 done predecessor
# tasks). Only /plan-project --update may rewrite these fields once
# the task is done.

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${REPO_ROOT}/adapters/claude-code/claude/hooks/plan-ownership-guard.sh"

WORKDIR="${TMPDIR:-/tmp}/plan-ownership-worm-test-$$"
trap 'rm -rf "$WORKDIR"' EXIT

setup_fixture() {
    mkdir -p "$WORKDIR"
    # A plan containing one already-done task with codebase_snapshot.
    cat > "$WORKDIR/execution-plan.yaml" <<'YAML'
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
      - id: done-task
        name: "Already done"
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
        predecessor_context:
          constraints:
            - "must be idempotent"
      - id: current-task
        name: "Currently active"
        task_type: development
        status: wip
        what: "current task"
        why: "why"
        where: {modify: []}
        acceptance: ["works"]
        prompt: "do"
        depends: ["done-task"]
YAML
}

# Helper: invoke the hook via JSON-on-stdin.
invoke_hook() {
    local tool_name="$1" file_path="$2" old_string="$3" new_string="$4"
    TOOL_NAME="$tool_name" FILE_PATH="$file_path" \
    OLD_STRING="$old_string" NEW_STRING="$new_string" \
    python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "tool_name": os.environ["TOOL_NAME"],
    "tool_input": {
        "file_path": os.environ["FILE_PATH"],
        "old_string": os.environ["OLD_STRING"],
        "new_string": os.environ["NEW_STRING"],
    },
}))' | bash "$HOOK"
}

# Tests ------------------------------------------------------------------

test_hook_denies_done_rewriting_done_predecessor_signature() {
    # /done attempts to rewrite a SIGNATURE inside a done predecessor's
    # codebase_snapshot. This is the 7d434e3 reflow class.
    # Pin deny mode: the plan-field WORM respects PLAN_OWNERSHIP_GUARD_MODE, and
    # the burn-in default may be `warn` in the operator's env (commit 67b9a03) —
    # this assertion is about the deny-mode behaviour, so set it explicitly.
    export PLAN_OWNERSHIP_GUARD_MODE=deny
    export AUTOPILOT_CURRENT_PHASE="done"
    export AUTOPILOT_CURRENT_TASK_ID=current-task
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      - id: done-task
        status: done
        codebase_snapshot:
          interfaces_introduced:
            - signature: \"do_thing() -> None\"" \
        "      - id: done-task
        status: done
        codebase_snapshot:
          interfaces_introduced:
            - signature: \"do_thing() -> bool\"" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]] && echo "$out" | grep -q '"permissionDecision".*"deny"'; then
        printf "${GREEN}PASS${NC}: /done WORM-denied from rewriting done predecessor's signature\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /done was NOT WORM-denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_hook_allows_done_on_current_task_codebase_snapshot() {
    # /done writing codebase_snapshot to the CURRENT (wip→done) task is
    # the legitimate path and must be allowed.
    export AUTOPILOT_CURRENT_PHASE="done"
    export AUTOPILOT_CURRENT_TASK_ID=current-task
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      - id: current-task
        status: wip" \
        "      - id: current-task
        status: done
        codebase_snapshot:
          commit_ref: deadbeef" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: /done allowed to write codebase_snapshot at wip→done transition\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /done denied at legitimate wip→done transition (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_hook_allows_plan_project_to_rewrite_done_snapshot() {
    # Escape hatch: /plan-project --update has full authority including
    # redesigning the lean-context schema on done tasks.
    export AUTOPILOT_CURRENT_PHASE=plan-project
    export AUTOPILOT_CURRENT_TASK_ID=current-task
    unset PLAN_WRITE_INTENT
    local out rc
    out=$(invoke_hook Edit "$WORKDIR/execution-plan.yaml" \
        "      - id: done-task
        codebase_snapshot:
          interfaces_introduced:
            - signature: \"do_thing() -> None\"" \
        "      - id: done-task
        codebase_snapshot:
          interfaces_introduced:
            - signature: \"do_thing() -> bool\"" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: /plan-project allowed to rewrite done codebase_snapshot (escape hatch)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: /plan-project denied the escape-hatch path (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset AUTOPILOT_CURRENT_PHASE AUTOPILOT_CURRENT_TASK_ID
}

test_validator_detects_frozen_evidence_drift() {
    # plan_validators.detect_frozen_evidence_drift: when run against a
    # plan whose done-task codebase_snapshot differs from the parent
    # commit's version, emit an error.
    # This is a unit test against the python function directly.
    PYTHONPATH="${REPO_ROOT}/adapters/claude-code/claude/tools" \
    python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/adapters/claude-code/claude/tools/lib')
import plan_validators

# Build a ValidationContext with a done task whose codebase_snapshot
# is present, then assert the validator surfaces it correctly. We're
# checking the function EXISTS and has the right signature; the deeper
# git-diff comparison is covered by integration in autopilot runs.
from pathlib import Path
ctx = plan_validators.ValidationContext(
    plan={
        'phases': [{
            'id': 'P1',
            'name': 'p1',
            'tasks': [{
                'id': 'done-task',
                'status': 'done',
                'codebase_snapshot': {'commit_ref': 'abc'},
            }]
        }]
    },
    plan_dir=Path('/tmp/nonexistent-test-dir'),
)
fn = getattr(plan_validators, 'detect_frozen_evidence_drift', None)
if fn is None:
    print('MISSING: detect_frozen_evidence_drift function not in plan_validators')
    sys.exit(1)
errors = fn(ctx)
# The function should at minimum return a list (empty is fine when no
# prior version exists to compare against).
if not isinstance(errors, list):
    print(f'WRONG TYPE: detect_frozen_evidence_drift returned {type(errors)}')
    sys.exit(1)
print('OK')
" 2>&1
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: plan_validators.detect_frozen_evidence_drift exists with correct shape\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: detect_frozen_evidence_drift missing or wrong shape (rc=%s)\n" "$rc"
        failed=$((failed + 1))
    fi
}

test_validator_registered_in_VALIDATORS_2_0() {
    PYTHONPATH="${REPO_ROOT}/adapters/claude-code/claude/tools" \
    python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/adapters/claude-code/claude/tools/lib')
import plan_validators
names = [getattr(fn, '__name__', str(fn)) for fn in plan_validators.VALIDATORS_2_0]
if 'detect_frozen_evidence_drift' not in names:
    print(f'NOT REGISTERED in VALIDATORS_2_0. Current: {names}')
    sys.exit(1)
print('OK')
" 2>&1
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "${GREEN}PASS${NC}: detect_frozen_evidence_drift registered in VALIDATORS_2_0\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: detect_frozen_evidence_drift NOT in VALIDATORS_2_0 dispatch (rc=%s)\n" "$rc"
        failed=$((failed + 1))
    fi
}

# Guard #2 — integration-gate test-immutability (real integration gates §6.2) -

# Invoke the hook with just a tool_name + file_path (oracle check needs no diff).
invoke_oracle() {
    TOOL_NAME="$1" FILE_PATH="$2" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "tool_name": os.environ["TOOL_NAME"],
    "tool_input": {"file_path": os.environ["FILE_PATH"], "content": "x"},
}))' | bash "$HOOK"
}

test_guard2_denies_fixer_editing_oracle() {
    # During remediation the fixer is WORM-denied Edit/Write to the oracle.
    export INTEGRATION_REMEDIATION_ACTIVE=1
    export INTEGRATION_ORACLE_GLOBS="dashboard/tests/**"$'\n'"tests/test_integration_gate.sh"
    unset AUTOPILOT_CURRENT_PHASE
    local out rc
    out=$(invoke_oracle Edit "$REPO_ROOT/dashboard/tests/test-security.sh" 2>&1); rc=$?
    if [[ $rc -ne 0 ]] && echo "$out" | grep -q '"permissionDecision".*"deny"'; then
        printf "${GREEN}PASS${NC}: Guard #2 WORM-denied fixer editing the integration oracle\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: oracle edit NOT denied (rc=%s, out=%s)\n" "$rc" "$out"
        failed=$((failed + 1))
    fi
    unset INTEGRATION_REMEDIATION_ACTIVE INTEGRATION_ORACLE_GLOBS
}

test_guard2_allows_fixer_editing_code() {
    # The fixer MAY edit the code under test (not the oracle).
    export INTEGRATION_REMEDIATION_ACTIVE=1
    export INTEGRATION_ORACLE_GLOBS="dashboard/tests/**"
    unset AUTOPILOT_CURRENT_PHASE
    local out
    out=$(invoke_oracle Edit "$REPO_ROOT/dashboard/server/app.py" 2>&1)
    if echo "$out" | grep -q '"permissionDecision".*"allow"'; then
        printf "${GREEN}PASS${NC}: Guard #2 allowed fixer editing code under test\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: code edit was not allowed (out=%s)\n" "$out"
        failed=$((failed + 1))
    fi
    unset INTEGRATION_REMEDIATION_ACTIVE INTEGRATION_ORACLE_GLOBS
}

test_guard2_inactive_outside_remediation() {
    # Without the remediation marker, the oracle WORM lock does not apply.
    unset INTEGRATION_REMEDIATION_ACTIVE INTEGRATION_ORACLE_GLOBS AUTOPILOT_CURRENT_PHASE
    local out
    out=$(invoke_oracle Edit "$REPO_ROOT/dashboard/tests/test-security.sh" 2>&1)
    if echo "$out" | grep -q '"permissionDecision".*"allow"'; then
        printf "${GREEN}PASS${NC}: oracle WORM inactive outside remediation\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: unexpected deny outside remediation (out=%s)\n" "$out"
        failed=$((failed + 1))
    fi
}

# Run -------------------------------------------------------------------

echo "Testing WORM enforcement for codebase_snapshot on done tasks (plan-ownership Track 4)..."
echo

setup_fixture
test_hook_denies_done_rewriting_done_predecessor_signature
test_hook_allows_done_on_current_task_codebase_snapshot
test_hook_allows_plan_project_to_rewrite_done_snapshot
test_validator_detects_frozen_evidence_drift
test_validator_registered_in_VALIDATORS_2_0
test_guard2_denies_fixer_editing_oracle
test_guard2_allows_fixer_editing_code
test_guard2_inactive_outside_remediation

echo
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]] || exit 1
