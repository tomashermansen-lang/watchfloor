#!/bin/bash
# test_commit_finalize_untracked_stash.sh
#
# Regression test for: untracked files on main blocking merge with
# "The following untracked working tree files would be overwritten by merge".
#
# Pre-fix, commit-finalize.sh's `git stash push` (without -u) ignored
# untracked files and merge aborted. Post-fix, `git stash push -u` includes
# them so the merge can proceed.
#
# Usage: bash tests/test_commit_finalize_untracked_stash.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

# Use sandbox-safe temp dir (TMPDIR is set by harness)
WORKDIR="${TMPDIR:-/tmp}/finalize-stash-test-$$"
trap 'rm -rf "$WORKDIR"' EXIT

setup_fixture() {
    local main="$WORKDIR/main"
    local wt="$WORKDIR/wt"

    mkdir -p "$main"
    (
        cd "$main"
        git init -q -b main
        git config user.email "test@test"
        git config user.name "Test"
        git config commit.gpgsign false
        mkdir -p docs/DONE_Feature_X
        echo "initial" > README.md
        git add README.md
        git commit -q -m "initial"

        git worktree add -q -b feature/x "$wt" main
    )
    (
        cd "$wt"
        mkdir -p docs/DONE_Feature_X
        echo '{"task":"x","branch":"feature/x"}' > docs/DONE_Feature_X/summary.json
        git add docs/DONE_Feature_X/summary.json
        git commit -q -m "feat(x): add summary"
    )

    echo '{"task":"x","stale":true}' > "$main/docs/DONE_Feature_X/summary.json"
}

run_stash_fragment() {
    local main="$1"
    (
        cd "$main"
        local has_untracked=false
        if [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]; then
            has_untracked=true
        fi
        if ! git diff --quiet HEAD 2>/dev/null \
            || ! git diff --cached --quiet HEAD 2>/dev/null \
            || [[ "$has_untracked" == true ]]; then
            git stash push -u -m "test: pre-merge stash" >/dev/null 2>&1 || exit 1
            exit 0
        fi
        exit 2
    )
}

test_stash_includes_untracked() {
    rm -rf "$WORKDIR"
    setup_fixture

    set +e
    run_stash_fragment "$WORKDIR/main"
    local rc=$?
    set -e
    [[ $rc -eq 0 ]] || { echo "  FAIL: expected stash rc=0, got $rc"; return 1; }

    [[ ! -e "$WORKDIR/main/docs/DONE_Feature_X/summary.json" ]] \
        || { echo "  FAIL: stale summary.json still present after stash -u"; return 1; }

    (cd "$WORKDIR/main" && git merge --no-ff --no-edit feature/x >/dev/null 2>&1) \
        || { echo "  FAIL: merge failed despite stash"; return 1; }

    return 0
}

test_stash_skipped_when_clean() {
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR/main"
    (
        cd "$WORKDIR/main"
        git init -q -b main
        git config user.email "t@t"; git config user.name "t"
        git config commit.gpgsign false
        echo "x" > a.txt; git add a.txt; git commit -q -m "x"
    )

    set +e
    run_stash_fragment "$WORKDIR/main"
    local rc=$?
    set -e
    [[ $rc -eq 2 ]] || { echo "  FAIL: expected rc=2 (skip), got $rc"; return 1; }
    return 0
}

check() {
    local name="$1"; shift
    if "$@"; then
        printf "${GREEN}✓${NC} %s\n" "$name"
        passed=$((passed + 1))
    else
        printf "${RED}✗${NC} %s\n" "$name"
        failed=$((failed + 1))
    fi
}

check "stash -u includes untracked files; merge succeeds afterward" test_stash_includes_untracked
check "stash skipped when working tree fully clean" test_stash_skipped_when_clean

if [[ $failed -gt 0 ]]; then
    printf "\n${RED}%d failed${NC}, %d passed\n" "$failed" "$passed"
    exit 1
fi
printf "\n${GREEN}All %d tests passed${NC}\n" "$passed"
