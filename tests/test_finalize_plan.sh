#!/bin/bash
# test_finalize_plan.sh — TDD for finalize-plan.sh helper.
#
# Background: at the end of every plan, autopilot-chain.sh hits a phase gate
# blocked on `kind: human` items (manual smoke tests). Today's resolution
# (2026-05-06) was an ad-hoc Python snippet to flip gate.passed=true and a
# manual `git mv INPROGRESS_Plan_… DONE_Plan_…`. Operators didn't know they
# were supposed to do that — the chain's "Gate blocked" banner gave no
# recovery path. See CONTINUATION_chain-pipeline-friction.md section C.
#
# This helper provides two atomic operations the chain can point operators at:
#
#   finalize-plan.sh approve-gate <plan-yaml> <phase-id>
#       Flip the named phase's gate.passed from false to true and commit
#       (matches the same regex autopilot-chain.sh uses internally so it's a
#       drop-in operator-facing equivalent).
#
#   finalize-plan.sh mark-done <plan-dir>
#       Rename docs/INPROGRESS_Plan_<x> → docs/DONE_Plan_<x> via git mv and
#       commit. No-op if already DONE_Plan_*.
#
# Usage: bash tests/test_finalize_plan.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_DIR/adapters/claude-code/claude/tools/finalize-plan.sh"

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

TEST_DIR="${TMPDIR:-/tmp}/test-finalize-plan-$$"

setup_repo() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
}

teardown() {
    cd "$REPO_DIR"
    rm -rf "$TEST_DIR"
}
trap teardown EXIT

# Minimal plan fragment with one gate per phase. Two phases — one already
# passed (idempotency check) and one open.
write_plan() {
    local plan_dir=$1
    mkdir -p "$plan_dir"
    cat > "$plan_dir/execution-plan.yaml" <<'EOF'
schema_version: 2.0.0
project:
  id: test-plan
  name: Test plan
phases:
- id: backend
  name: 'Phase 1'
  gate:
    checklist:
    - item: backend tests pass
      check:
        kind: shell
        cmd: 'true'
    passed: true
- id: smoke
  name: 'Phase 2'
  gate:
    checklist:
    - item: Manual smoke test A
      check:
        kind: human
    passed: false
EOF
    git add "$plan_dir/execution-plan.yaml"
    git commit -q -m "test: scaffold plan"
}

echo "Running finalize-plan.sh tests..."
echo ""

# =============================================================================
# T01: helper script exists and prints usage with no args
# =============================================================================
test_t01() {
    [[ -x "$HELPER" ]] || { echo "  $HELPER missing or not executable"; return 1; }
    local out
    out=$(bash "$HELPER" 2>&1) && { echo "  expected non-zero exit on missing args"; return 1; }
    echo "$out" | grep -q "Usage:" || { echo "  no usage banner: $out"; return 1; }
    return 0
}
check "T01: helper exists and prints usage on missing args" test_t01

# =============================================================================
# T02: approve-gate flips passed:false → passed:true and commits
# =============================================================================
test_t02() {
    setup_repo
    local plan_dir="docs/INPROGRESS_Plan_test"
    write_plan "$plan_dir"
    local before_sha
    before_sha=$(git rev-parse HEAD)

    bash "$HELPER" approve-gate "$plan_dir/execution-plan.yaml" smoke >/dev/null 2>&1 \
        || { echo "  approve-gate exited non-zero"; return 1; }

    grep -q "passed: true" "$plan_dir/execution-plan.yaml" \
        || { echo "  passed: true not written"; return 1; }
    if grep -q "passed: false" "$plan_dir/execution-plan.yaml"; then
        echo "  passed: false still present after flip"
        return 1
    fi

    local after_sha
    after_sha=$(git rev-parse HEAD)
    [[ "$before_sha" != "$after_sha" ]] || { echo "  no commit was made"; return 1; }

    git log -1 --format=%s | grep -q "smoke passed" \
        || { echo "  commit message does not name the phase"; return 1; }
}
check "T02: approve-gate flips false→true and commits" test_t02

# =============================================================================
# T03: approve-gate is idempotent — already-true exits 0 with no commit
# =============================================================================
test_t03() {
    setup_repo
    local plan_dir="docs/INPROGRESS_Plan_test"
    write_plan "$plan_dir"
    local before_sha
    before_sha=$(git rev-parse HEAD)

    bash "$HELPER" approve-gate "$plan_dir/execution-plan.yaml" backend >/dev/null 2>&1 \
        || { echo "  idempotent path exited non-zero"; return 1; }

    local after_sha
    after_sha=$(git rev-parse HEAD)
    [[ "$before_sha" == "$after_sha" ]] || { echo "  unexpected commit on idempotent path"; return 1; }
}
check "T03: approve-gate idempotent on already-passed gate (no commit)" test_t03

# =============================================================================
# T04: approve-gate errors on unknown phase
# =============================================================================
test_t04() {
    setup_repo
    local plan_dir="docs/INPROGRESS_Plan_test"
    write_plan "$plan_dir"

    local out
    out=$(bash "$HELPER" approve-gate "$plan_dir/execution-plan.yaml" nonexistent 2>&1) \
        && { echo "  expected non-zero exit on unknown phase"; return 1; }
    echo "$out" | grep -q "nonexistent" \
        || { echo "  error message does not name the missing phase: $out"; return 1; }
}
check "T04: approve-gate fails loudly on unknown phase id" test_t04

# =============================================================================
# T05: mark-done renames INPROGRESS_Plan_* → DONE_Plan_* via git mv and commits
# =============================================================================
test_t05() {
    setup_repo
    local plan_dir="docs/INPROGRESS_Plan_test"
    write_plan "$plan_dir"

    bash "$HELPER" mark-done "$plan_dir" >/dev/null 2>&1 \
        || { echo "  mark-done exited non-zero"; return 1; }

    [[ -d "docs/DONE_Plan_test" ]] || { echo "  DONE_Plan_test/ not created"; return 1; }
    [[ ! -d "$plan_dir" ]] || { echo "  INPROGRESS_Plan_test/ still present"; return 1; }

    # Verify it was a git-tracked rename (not a manual rm/cp)
    git log -1 --name-status | grep -E "^R" | grep -q "DONE_Plan_test" \
        || { echo "  rename not tracked as git rename"; return 1; }
}
check "T05: mark-done renames INPROGRESS_→DONE_ via git mv" test_t05

# =============================================================================
# T06: mark-done refuses non-INPROGRESS_Plan_ paths
# =============================================================================
test_t06() {
    setup_repo
    mkdir -p docs/random-dir
    git add . 2>/dev/null
    git commit -q -m "test: random dir" --allow-empty

    local out
    out=$(bash "$HELPER" mark-done docs/random-dir 2>&1) \
        && { echo "  expected non-zero exit on non-INPROGRESS path"; return 1; }
    echo "$out" | grep -qiE "INPROGRESS_Plan_|expected" \
        || { echo "  error message uninformative: $out"; return 1; }
}
check "T06: mark-done refuses paths outside INPROGRESS_Plan_*" test_t06

# =============================================================================
# T07: mark-done idempotent on already-DONE_Plan_* (exit 0, no commit)
# =============================================================================
test_t07() {
    setup_repo
    local plan_dir="docs/DONE_Plan_test"
    write_plan "$plan_dir"
    local before_sha
    before_sha=$(git rev-parse HEAD)

    bash "$HELPER" mark-done "$plan_dir" >/dev/null 2>&1 \
        || { echo "  idempotent mark-done exited non-zero"; return 1; }

    local after_sha
    after_sha=$(git rev-parse HEAD)
    [[ "$before_sha" == "$after_sha" ]] || { echo "  unexpected commit on idempotent path"; return 1; }
    [[ -d "$plan_dir" ]] || { echo "  DONE_Plan_test disappeared"; return 1; }
}
check "T07: mark-done idempotent on already-DONE_Plan_*" test_t07

# =============================================================================
# T08: approve-gate refuses to act on missing yaml file
# =============================================================================
test_t08() {
    setup_repo
    local out
    out=$(bash "$HELPER" approve-gate /tmp/no-such-plan.yaml smoke 2>&1) \
        && { echo "  expected non-zero exit on missing yaml"; return 1; }
    echo "$out" | grep -qiE "not found|missing|exist" \
        || { echo "  error message uninformative: $out"; return 1; }
}
check "T08: approve-gate fails loudly on missing yaml file" test_t08

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
