#\!/usr/bin/env bash
# test_resolve_plan_yaml_for_task.sh — TDD test for multi-plan YAML_FILE resolution
#
# Tests claude-session-lib.sh::resolve_plan_yaml_for_task — task-id-aware
# lookup that picks the INPROGRESS_Plan_* dir containing the requested task,
# falling back to first alphabetically when no plan matches.
#
# This fixes the multi-plan ambiguity at autopilot.sh:724 where
# `find ... | head -1` picked the alphabetically-first plan regardless of
# which plan owned the task being executed — silently breaking deviation
# tracking for any plan that wasn't first alphabetically.
#
# Usage: bash tests/test_resolve_plan_yaml_for_task.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"
    shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

TEST_DIR="${TMPDIR:-/tmp}/test-resolve-plan-yaml-$$"

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/docs"
}

teardown() {
    rm -rf "$TEST_DIR"
}
trap teardown EXIT

# Helper: create an INPROGRESS_Plan_<name> dir with an execution-plan.yaml
# containing one phase + N tasks.
make_plan() {
    local name=$1
    shift
    local plan_dir="$TEST_DIR/docs/INPROGRESS_Plan_${name}"
    mkdir -p "$plan_dir"
    {
        echo "schema_version: \"2.0.0\""
        echo "name: $name"
        echo "phases:"
        echo "  - id: phase-1"
        echo "    name: \"Phase 1\""
        echo "    tasks:"
        for tid in "$@"; do
            echo "      - id: ${tid}"
            echo "        name: \"task ${tid}\""
            echo "        status: pending"
        done
    } > "$plan_dir/execution-plan.yaml"
}

# Helper: invoke the function under test in a subshell and echo its output.
resolve() {
    local task_id=$1
    local main_dir=$2
    bash -c "
        source '$LIB'
        resolve_plan_yaml_for_task '$task_id' '$main_dir'
    " 2>&1
}

echo "Running resolve_plan_yaml_for_task tests..."
echo ""

# ─── TC-RPY01 ───
# Single INPROGRESS plan containing the task → resolves to it.
test_tc_rpy01() {
    setup
    make_plan "alpha" "task-foo" "task-bar"
    local got
    got=$(resolve "task-foo" "$TEST_DIR")
    [[ "$got" == "$TEST_DIR/docs/INPROGRESS_Plan_alpha/execution-plan.yaml" ]] || {
        echo "  expected: $TEST_DIR/docs/INPROGRESS_Plan_alpha/execution-plan.yaml"
        echo "  got:      $got"
        return 1
    }
    return 0
}
check "TC-RPY01: single plan with task → resolves to it" test_tc_rpy01

# ─── TC-RPY02 ───
# Three INPROGRESS plans alphabetically (alpha, beta, gamma); task lives ONLY
# in beta. Function must resolve to beta, NOT alpha (which would be the legacy
# `head -1` answer).
test_tc_rpy02() {
    setup
    make_plan "alpha" "alpha-task-a" "alpha-task-b"
    make_plan "beta" "watchfloor-task-x" "watchfloor-task-y"
    make_plan "gamma" "gamma-task-1"
    local got
    got=$(resolve "watchfloor-task-x" "$TEST_DIR")
    [[ "$got" == "$TEST_DIR/docs/INPROGRESS_Plan_beta/execution-plan.yaml" ]] || {
        echo "  expected: $TEST_DIR/docs/INPROGRESS_Plan_beta/execution-plan.yaml"
        echo "  got:      $got"
        return 1
    }
    return 0
}
check "TC-RPY02: task in non-first plan → resolves to that plan (NOT alphabetic-first)" test_tc_rpy02

# ─── TC-RPY03 ───
# Three INPROGRESS plans; task is in NONE of them → fallback to first
# alphabetically (preserves legacy behavior).
test_tc_rpy03() {
    setup
    make_plan "alpha" "alpha-task-a"
    make_plan "beta" "beta-task-b"
    make_plan "gamma" "gamma-task-c"
    local got
    got=$(resolve "nonexistent-task" "$TEST_DIR")
    [[ "$got" == "$TEST_DIR/docs/INPROGRESS_Plan_alpha/execution-plan.yaml" ]] || {
        echo "  expected fallback to alpha (alphabetic first)"
        echo "  got:      $got"
        return 1
    }
    return 0
}
check "TC-RPY03: task in no plan → fallback to alphabetic-first (legacy preserved)" test_tc_rpy03

# ─── TC-RPY04 ───
# docs/ does not exist → empty string output.
test_tc_rpy04() {
    setup
    rm -rf "$TEST_DIR/docs"
    local got
    got=$(resolve "anything" "$TEST_DIR")
    [[ -z "$got" ]] || {
        echo "  expected empty string"
        echo "  got:      '$got'"
        return 1
    }
    return 0
}
check "TC-RPY04: docs/ missing → empty string" test_tc_rpy04

# ─── TC-RPY05 ───
# TASK empty → fallback to first alphabetically (preserves legacy semantics
# for callers that haven't set TASK yet).
test_tc_rpy05() {
    setup
    make_plan "alpha" "alpha-task"
    make_plan "beta" "beta-task"
    local got
    got=$(resolve "" "$TEST_DIR")
    [[ "$got" == "$TEST_DIR/docs/INPROGRESS_Plan_alpha/execution-plan.yaml" ]] || {
        echo "  expected fallback to alpha"
        echo "  got:      $got"
        return 1
    }
    return 0
}
check "TC-RPY05: empty task-id → fallback to alphabetic-first" test_tc_rpy05

# ─── TC-RPY06 ───
# Three plans; task IS in alphabetic-first plan → resolves to it (no false
# skip past the right answer).
test_tc_rpy06() {
    setup
    make_plan "alpha" "alpha-task-1" "alpha-task-2"
    make_plan "beta" "beta-task"
    make_plan "gamma" "gamma-task"
    local got
    got=$(resolve "alpha-task-2" "$TEST_DIR")
    [[ "$got" == "$TEST_DIR/docs/INPROGRESS_Plan_alpha/execution-plan.yaml" ]] || {
        echo "  expected: $TEST_DIR/docs/INPROGRESS_Plan_alpha/execution-plan.yaml"
        echo "  got:      $got"
        return 1
    }
    return 0
}
check "TC-RPY06: task IS in alphabetic-first plan → resolves to it" test_tc_rpy06

# ─── TC-RPY07 ───
# Empty docs/ (no INPROGRESS_Plan_* dirs at all) → empty string output, no
# crash.
test_tc_rpy07() {
    setup
    # docs/ exists but has no plan dirs
    local got
    got=$(resolve "anything" "$TEST_DIR")
    [[ -z "$got" ]] || {
        echo "  expected empty string"
        echo "  got:      '$got'"
        return 1
    }
    return 0
}
check "TC-RPY07: docs/ exists but no plans → empty string" test_tc_rpy07

# ─── resolve_plan_yaml_worktree_aware tests ───
#
# Verifies the worktree-preferring wrapper used by autopilot.sh to keep
# main clean during chain runs (deviation tracker writes go to worktree
# plan, then ride into main via the eventual feature merge).

# Helper: invoke the worktree-aware wrapper.
resolve_wt() {
    local task_id=$1
    local workdir=$2
    local main_dir=$3
    bash -c "
        source '$LIB'
        resolve_plan_yaml_worktree_aware '$task_id' '$workdir' '$main_dir'
    " 2>&1
}

# Helper: same as setup() but creates two parallel directory trees (main
# checkout and feature worktree) sharing the same plan content. Tests can
# then mutate one tree to verify which one resolves.
setup_two_trees() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/main/docs" "$TEST_DIR/work/docs"
}

make_plan_in() {
    local tree=$1
    local name=$2
    shift 2
    local plan_dir="$TEST_DIR/$tree/docs/INPROGRESS_Plan_${name}"
    mkdir -p "$plan_dir"
    {
        echo "schema_version: \"2.0.0\""
        echo "name: $name"
        echo "phases:"
        echo "  - id: phase-1"
        echo "    name: \"Phase 1\""
        echo "    tasks:"
        for tid in "$@"; do
            echo "      - id: ${tid}"
            echo "        name: \"task ${tid}\""
            echo "        status: pending"
        done
    } > "$plan_dir/execution-plan.yaml"
}

# ─── TC-WT01 ───
# Worktree has the plan with the task → resolves to the WORKTREE's copy,
# not main's copy. This is the chain-mode default that keeps main clean.
test_tc_wt01() {
    setup_two_trees
    make_plan_in main alpha t1
    make_plan_in work alpha t1
    local got
    got=$(resolve_wt "t1" "$TEST_DIR/work" "$TEST_DIR/main")
    local expected="$TEST_DIR/work/docs/INPROGRESS_Plan_alpha/execution-plan.yaml"
    [[ "$got" == "$expected" ]] || {
        echo "  expected: '$expected'"
        echo "  got:      '$got'"
        return 1
    }
    return 0
}
check "TC-WT01: workdir has plan → resolves to worktree copy (keeps main clean)" test_tc_wt01

# ─── TC-WT02 ───
# Workdir is unset (empty) → falls back to MAIN_DIR. Standalone autopilot
# runs (no chain) take this path, preserving the legacy single-checkout
# behaviour.
test_tc_wt02() {
    setup_two_trees
    make_plan_in main beta t1
    local got
    got=$(resolve_wt "t1" "" "$TEST_DIR/main")
    local expected="$TEST_DIR/main/docs/INPROGRESS_Plan_beta/execution-plan.yaml"
    [[ "$got" == "$expected" ]] || {
        echo "  expected: '$expected'"
        echo "  got:      '$got'"
        return 1
    }
    return 0
}
check "TC-WT02: empty workdir → falls back to main" test_tc_wt02

# ─── TC-WT03 ───
# Workdir has no docs/ directory (e.g., worktree on a branch that hasn't
# checked out the plan dir) → falls back to main without crashing.
test_tc_wt03() {
    setup_two_trees
    rm -rf "$TEST_DIR/work/docs"  # no docs in workdir
    make_plan_in main gamma t1
    local got
    got=$(resolve_wt "t1" "$TEST_DIR/work" "$TEST_DIR/main")
    local expected="$TEST_DIR/main/docs/INPROGRESS_Plan_gamma/execution-plan.yaml"
    [[ "$got" == "$expected" ]] || {
        echo "  expected: '$expected'"
        echo "  got:      '$got'"
        return 1
    }
    return 0
}
check "TC-WT03: workdir has no docs/ → falls back to main" test_tc_wt03

# ─── TC-WT04 ───
# Workdir's plan does not contain the task (worktree branched off before
# the task was added) → falls back to main where the task lives. Edge
# case for tasks added to the plan after the worktree was created.
test_tc_wt04() {
    setup_two_trees
    # workdir has a plan but with a different task
    make_plan_in work delta other-task
    # main has the task we want
    make_plan_in main delta target-task
    local got
    got=$(resolve_wt "target-task" "$TEST_DIR/work" "$TEST_DIR/main")
    local expected="$TEST_DIR/main/docs/INPROGRESS_Plan_delta/execution-plan.yaml"
    [[ "$got" == "$expected" ]] || {
        echo "  expected: '$expected'"
        echo "  got:      '$got'"
        return 1
    }
    return 0
}
check "TC-WT04: workdir plan lacks task → falls back to main copy of plan" test_tc_wt04

# ─── Summary ───
echo ""
echo "─── Summary ───"
echo "passed: $passed"
echo "failed: $failed"
[[ $failed -eq 0 ]] || exit 1
exit 0
