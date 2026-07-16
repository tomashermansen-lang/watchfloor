#!/bin/bash
# test_commit_finalize_msg_scope.sh
#
# Plan-ownership Track 5 — verify that commit-finalize.sh's feature-branch
# finalization commit uses scope=`plan` not scope=`<task>`. The diff of this
# commit can include plan-edits (status flip, codebase_snapshot writes), so
# the scope should reflect that, not the task name. This silences false-
# positive Pattern A audit hits where `docs(<task>): mark as done` looked
# like a phase agent rewriting the plan.
#
# Usage: bash tests/test_commit_finalize_msg_scope.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FINALIZE_SH="${REPO_ROOT}/adapters/claude-code/claude/tools/commit-finalize.sh"

# Step 4 message: feature-branch finalization commit
test_step4_scope_is_plan() {
    if grep -qE 'git commit -m "docs\(\$\{TASK\}\): mark as done"' "$FINALIZE_SH"; then
        printf "${RED}FAIL${NC}: commit-finalize.sh Step 4 still uses scope=\${TASK} — should be scope=plan\n"
        failed=$((failed + 1))
        return
    fi
    if grep -qE 'git commit -m "docs\(plan\): mark \$\{TASK\} as done"' "$FINALIZE_SH"; then
        printf "${GREEN}PASS${NC}: commit-finalize.sh Step 4 uses scope=plan\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: commit-finalize.sh Step 4 commit message not found in expected new shape\n"
        failed=$((failed + 1))
    fi
}

# Step "post-merge" message: already correctly scoped — regression guard
test_post_merge_scope_is_plan() {
    if grep -qE 'git commit -m "docs\(plan\): mark \$\{TASK\} done \(post-merge\)"' "$FINALIZE_SH"; then
        printf "${GREEN}PASS${NC}: commit-finalize.sh post-merge commit uses scope=plan (regression guard)\n"
        passed=$((passed + 1))
    else
        printf "${RED}FAIL${NC}: commit-finalize.sh post-merge commit message not found in expected shape\n"
        failed=$((failed + 1))
    fi
}

echo "Testing commit-finalize.sh commit-message scopes (plan-ownership Track 5)..."
echo "Target: $FINALIZE_SH"
echo

test_step4_scope_is_plan
test_post_merge_scope_is_plan

echo
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]] || exit 1
