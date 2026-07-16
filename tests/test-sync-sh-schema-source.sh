#!/usr/bin/env bash
# test-sync-sh-schema-source.sh — verifies sync.sh restore deploys
# core/schema/ to ~/.claude/schema/ post-T3 (REQ-4 acceptance).
#
# Test approach: clone the worktree into TMPDIR (clean tree satisfies
# do_restore's git-status guard), HOME=TMPDIR/fake-home, run
# `sync.sh restore --no-diff --yes`, then assert files match.
#
# Usage: bash tests/test-sync-sh-schema-source.sh
set -uo pipefail

REPO_DIR_REAL="$(cd "$(dirname "$0")/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"; shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"; passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"; failed=$((failed + 1))
    fi
}

TEST_BASE="${TMPDIR:-/tmp}/test-sync-schema-$$"
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir -p "$TEST_BASE"

# Clone the worktree into TMPDIR — yields a clean git tree, satisfying
# the do_restore guard ('refuses to deploy when git status --porcelain
# is non-empty'). --no-local copies the working files (including the
# untracked ones present in the worktree at the time of the test run).
CLONE_DIR="$TEST_BASE/clone"
HOME_DIR="$TEST_BASE/fake-home"
mkdir -p "$HOME_DIR/.claude"

git clone -q --no-local "$REPO_DIR_REAL" "$CLONE_DIR"
# Also copy untracked files (newly-written under T3 implementation,
# not yet committed) so the test reflects current branch state.
rsync -a --exclude='.git/' \
    --exclude='node_modules/' \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='.pytest_cache/' \
    "$REPO_DIR_REAL/adapters/" "$CLONE_DIR/adapters/"
rsync -a --exclude='.git/' "$REPO_DIR_REAL/core/" "$CLONE_DIR/core/"
(
    cd "$CLONE_DIR"
    git config user.email "test@example.com"
    git config user.name "Test"
    git add -A
    git commit -q -m "test-snapshot" || true
)

# ---------------------------------------------------------------------------
# T-SY-1: sync.sh restore populates ~/.claude/schema/ with execution-plan.schema.json
# ---------------------------------------------------------------------------
HOME="$HOME_DIR" bash "$CLONE_DIR/adapters/claude-code/sync.sh" restore --no-diff --yes >/dev/null 2>&1

check "T-SY-1 ~/.claude/schema/execution-plan.schema.json exists post-restore" \
    test -f "$HOME_DIR/.claude/schema/execution-plan.schema.json"

check "T-SY-1 deployed schema is byte-identical to core/schema/ source" \
    cmp -s "$HOME_DIR/.claude/schema/execution-plan.schema.json" \
           "$REPO_DIR_REAL/core/schema/execution-plan.schema.json"

# ---------------------------------------------------------------------------
# T-SY-2: every file in core/schema/ is deployed
# ---------------------------------------------------------------------------
check "T-SY-2 ~/.claude/schema/ contents match core/schema/ exactly" \
    diff -q -r "$HOME_DIR/.claude/schema/" "$REPO_DIR_REAL/core/schema/"

# ---------------------------------------------------------------------------
# T-SY-3: sync.sh diff exits 0 (no drift) after restore
# ---------------------------------------------------------------------------
test_diff_clean() {
    set +e
    HOME="$HOME_DIR" bash "$CLONE_DIR/adapters/claude-code/sync.sh" diff >/dev/null 2>&1
    local rc=$?
    set -e
    [[ $rc -eq 0 ]]
}
check "T-SY-3 sync.sh diff reports clean after restore" test_diff_clean

# ---------------------------------------------------------------------------
# T-SY-4: legacy mapping is gone — no MISSING source for claude/schema
# ---------------------------------------------------------------------------
test_no_legacy_missing() {
    local out
    out=$(HOME="$HOME_DIR" bash "$CLONE_DIR/adapters/claude-code/sync.sh" diff 2>&1)
    ! echo "$out" | grep -q "MISSING.*claude/schema$"
}
check "T-SY-4 no legacy 'MISSING claude/schema' line in sync.sh diff output" test_no_legacy_missing

# ---------------------------------------------------------------------------
echo
if [[ $failed -eq 0 ]]; then
    echo -e "${GREEN}All $passed tests passed.${NC}"
    exit 0
fi
echo -e "${RED}$failed of $((passed + failed)) tests failed.${NC}"
exit 1
