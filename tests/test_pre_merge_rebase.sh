#!/bin/bash
# test_pre_merge_rebase.sh — TDD tests for
# adapters/claude-code/claude/tools/lib/pre-merge-rebase.sh
#
# The function `pre_merge_rebase <workdir> <target>` rebases the current
# branch in <workdir> onto <target>. Used by commit-finalize.sh to
# prevent YAML conflicts when sibling tasks land status/phase_results
# updates between worktree creation and finalize.
#
# Test cases:
#   T01 — already-up-to-date branch returns 0, no-op
#   T02 — clean fast-forward-possible branch rebases successfully (exit 0)
#   T03 — branch with conflicting region against target returns non-zero
#         AND restores branch state via rebase --abort (no half-rebased mess)
#   T04 — branches with disjoint edits to the same file merge cleanly via rebase
#         (this is the parallel-task YAML scenario this lib was built for)
#
# Isolation safeguards (CRITICAL — a prior version of this test silently
# polluted the parent dotfiles repo on every run because mktemp returned an
# unwritable path and `cd ""` left git operating in the ambient repo):
#   * Every git command runs via `git -C "$TEST_DIR"` — never `cd $TEST_DIR`
#     followed by a bare `git`. Empty $TEST_DIR fails the -C arg loudly.
#   * `setup_repo` asserts $TEST_DIR exists and contains a freshly-created
#     .git/ after `git init`; aborts the test run on any divergence.
#   * `GIT_CEILING_DIRECTORIES` is set to the test root so git cannot walk
#     up to the ambient dotfiles repo even if a future bug breaks the -C
#     invocation discipline.
#
# Usage: bash tests/test_pre_merge_rebase.sh
# Exits 0 on pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/pre-merge-rebase.sh"

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

[[ -f "$LIB" ]] || { echo "FATAL: $LIB not found"; exit 1; }

TEST_ROOT="${TMPDIR:-/tmp}"
# Defence-in-depth: prevent any git command in this script (or sourced libs)
# from walking up to the ambient dotfiles repo if a -C path is dropped.
export GIT_CEILING_DIRECTORIES="$TEST_ROOT"

TEST_DIR=""
setup_repo() {
    TEST_DIR=$(mktemp -d -p "$TEST_ROOT" test-pre-merge-rebase-XXXXXX) || {
        echo "FATAL: mktemp failed under $TEST_ROOT" >&2
        return 1
    }
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] || {
        echo "FATAL: TEST_DIR not a directory: '$TEST_DIR'" >&2
        return 1
    }
    git -C "$TEST_DIR" init -q -b main || return 1
    [[ -d "$TEST_DIR/.git" ]] || {
        echo "FATAL: .git not created under $TEST_DIR (would have polluted ambient repo)" >&2
        return 1
    }
    git -C "$TEST_DIR" config user.email "test@test"
    git -C "$TEST_DIR" config user.name "test"
    echo "line1" > "$TEST_DIR/file.txt"
    git -C "$TEST_DIR" add file.txt
    git -C "$TEST_DIR" commit -qm "initial"
}
teardown_repo() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; }
trap teardown_repo EXIT

# ── T01: already-up-to-date branch → exit 0, no-op ──
test_t01_up_to_date() {
    setup_repo || return 1
    git -C "$TEST_DIR" checkout -qb feature
    (
        source "$LIB"
        pre_merge_rebase "$TEST_DIR" "main" >/dev/null 2>&1
    )
}
check "T01: pre_merge_rebase → 0 when branch already at target" test_t01_up_to_date

# ── T02: clean rebase (feature behind main, no conflicts) → exit 0 ──
test_t02_clean_rebase() {
    setup_repo || return 1
    git -C "$TEST_DIR" checkout -qb feature
    echo "feature-edit" >> "$TEST_DIR/file.txt"
    git -C "$TEST_DIR" commit -qam "feature-commit"
    # main moves ahead with a different file
    git -C "$TEST_DIR" checkout -q main
    echo "main-only" > "$TEST_DIR/other.txt"
    git -C "$TEST_DIR" add other.txt
    git -C "$TEST_DIR" commit -qm "main-commit"
    git -C "$TEST_DIR" checkout -q feature
    (
        source "$LIB"
        pre_merge_rebase "$TEST_DIR" "main" >/dev/null 2>&1
    ) && \
        [[ -f "$TEST_DIR/other.txt" ]] && \
        grep -q "feature-edit" "$TEST_DIR/file.txt"
}
check "T02: pre_merge_rebase → 0 when no conflicts; main's commit is reachable" test_t02_clean_rebase

# ── T03: real conflict → non-zero exit AND rebase aborted (no half-state) ──
test_t03_conflict_aborts() {
    setup_repo || return 1
    git -C "$TEST_DIR" checkout -qb feature
    echo "feature-line" > "$TEST_DIR/file.txt"
    git -C "$TEST_DIR" commit -qam "feature-edit"
    git -C "$TEST_DIR" checkout -q main
    echo "main-line" > "$TEST_DIR/file.txt"
    git -C "$TEST_DIR" commit -qam "main-edit"
    git -C "$TEST_DIR" checkout -q feature
    (
        source "$LIB"
        ! pre_merge_rebase "$TEST_DIR" "main" >/dev/null 2>&1
    ) && \
        ! [[ -d "$TEST_DIR/.git/rebase-merge" ]] && \
        ! [[ -d "$TEST_DIR/.git/rebase-apply" ]] && \
        ! grep -q '^<<<<<<<' "$TEST_DIR/file.txt"
}
check "T03: pre_merge_rebase → non-zero on conflict; rebase aborted; no conflict markers" test_t03_conflict_aborts

# ── T04: parallel-task scenario — disjoint regions in same file rebase cleanly ──
test_t04_disjoint_regions() {
    setup_repo || return 1
    cat > "$TEST_DIR/file.txt" <<'EOF'
top: original-top
mid: stable-middle
bot: original-bot
EOF
    git -C "$TEST_DIR" add file.txt
    git -C "$TEST_DIR" commit -qam "seed disjoint regions"
    # main edits top (simulates sibling task that landed first)
    git -C "$TEST_DIR" checkout -q main
    sed -i.bak 's/top: original-top/top: main-changed-top/' "$TEST_DIR/file.txt"
    rm -f "$TEST_DIR/file.txt.bak"
    git -C "$TEST_DIR" commit -qam "main-edit-top"
    # feature edits bot (simulates this task, started before main moved)
    git -C "$TEST_DIR" checkout -qb feature "HEAD~1"
    sed -i.bak 's/bot: original-bot/bot: feature-changed-bot/' "$TEST_DIR/file.txt"
    rm -f "$TEST_DIR/file.txt.bak"
    git -C "$TEST_DIR" commit -qam "feature-edit-bot"
    (
        source "$LIB"
        pre_merge_rebase "$TEST_DIR" "main" >/dev/null 2>&1
    ) && \
        grep -q "main-changed-top" "$TEST_DIR/file.txt" && \
        grep -q "feature-changed-bot" "$TEST_DIR/file.txt" && \
        ! grep -q '^<<<<<<<' "$TEST_DIR/file.txt"
}
check "T04: pre_merge_rebase merges disjoint regions of the same file (the parallel-task YAML case)" test_t04_disjoint_regions

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
