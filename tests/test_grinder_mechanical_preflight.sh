#!/bin/bash
# test_grinder_mechanical_preflight.sh — TDD for the
# _mechanical_preflight_clean check.
#
# Closes the commit-scope bug observed 2026-05-12: when the operator has
# uncommitted edits in a file that happens to be in the next batch's
# batch_files, grinder's `git add -- <file>` stages the union of
# claude's intended fixes AND the operator's unrelated edits, then
# commits everything as "fix(grinder): pass-1-autofix / <tool> (batch
# batch-NNN)". The operator's work gets misattributed and the per-batch
# findings_after counter records measurement noise (the new lines in
# the operator's diff produce fresh scanner findings).
#
# The fix is operator-hygiene-enforced: before claude session spawns,
# preflight check rejects the batch if any batch_files have uncommitted
# changes (staged or unstaged). Operator must commit or stash first.
#
# Function under test: _mechanical_preflight_clean batch_files...
# Returns: 0 if all batch_files are clean (no diff vs HEAD)
#          1 if any file has uncommitted changes; stderr names the
#            dirty file(s) and instructs the operator to commit/stash
#
# Usage: bash tests/test_grinder_mechanical_preflight.sh
# Exits 0 on pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/grinder-mechanical.sh"

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

# Defense-in-depth — ambient repo isolation (same pattern as
# test_pre_merge_rebase.sh).
export GIT_CEILING_DIRECTORIES="${TMPDIR:-/tmp}"

setup_repo() {
    PROJECT_DIR=$(mktemp -d -p "${TMPDIR:-/tmp}" test-mech-preflight-XXXXXX) || return 1
    [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]] || return 1
    export PROJECT_DIR
    git -C "$PROJECT_DIR" init -q -b main
    git -C "$PROJECT_DIR" config user.email "test@test"
    git -C "$PROJECT_DIR" config user.name "test"
    # Seed two committed files
    echo "clean-content-1" > "$PROJECT_DIR/file1.py"
    echo "clean-content-2" > "$PROJECT_DIR/file2.py"
    git -C "$PROJECT_DIR" add file1.py file2.py
    git -C "$PROJECT_DIR" commit -qm "seed"
}
teardown() { [[ -n "${PROJECT_DIR:-}" && -d "$PROJECT_DIR" ]] && rm -rf "$PROJECT_DIR"; }
trap teardown EXIT

# Extract just the function from the lib (lib has top-level vars but
# no exec logic, so it's source-safe — but we still extract to keep
# the test fast).
_load_lib() {
    awk '
        $0 ~ "^_mechanical_preflight_clean\\(\\) \\{" {capture=1}
        capture {print}
        capture && /^}/ {capture=0}
    ' "$LIB"
}

# ── T01: all batch_files clean → returns 0, no output ──
test_t01_all_clean() {
    setup_repo || return 1
    local fn_src
    fn_src=$(_load_lib)
    [[ -n "$fn_src" ]] || { echo "  _mechanical_preflight_clean not defined"; return 1; }
    eval "$fn_src"
    (
        cd "$PROJECT_DIR"
        local rc=0
        _mechanical_preflight_clean "file1.py" "file2.py" 2>/dev/null || rc=$?
        [[ $rc -eq 0 ]]
    )
}
check "T01: clean batch_files → exit 0" test_t01_all_clean

# ── T02: one file has unstaged modification → returns 1 + stderr names it ──
test_t02_unstaged_modification() {
    setup_repo || return 1
    local fn_src
    fn_src=$(_load_lib)
    eval "$fn_src"
    echo "dirty-edit" >> "$PROJECT_DIR/file1.py"  # unstaged change
    (
        cd "$PROJECT_DIR"
        local rc=0
        local err
        err=$(_mechanical_preflight_clean "file1.py" "file2.py" 2>&1 >/dev/null) || rc=$?
        [[ $rc -ne 0 ]] && [[ "$err" == *"file1.py"* ]]
    )
}
check "T02: unstaged change → exit non-zero; stderr names dirty file" test_t02_unstaged_modification

# ── T03: one file has staged change → returns 1 + stderr names it ──
test_t03_staged_change() {
    setup_repo || return 1
    local fn_src
    fn_src=$(_load_lib)
    eval "$fn_src"
    echo "staged-edit" >> "$PROJECT_DIR/file2.py"
    git -C "$PROJECT_DIR" add file2.py
    (
        cd "$PROJECT_DIR"
        local rc=0
        local err
        err=$(_mechanical_preflight_clean "file1.py" "file2.py" 2>&1 >/dev/null) || rc=$?
        [[ $rc -ne 0 ]] && [[ "$err" == *"file2.py"* ]]
    )
}
check "T03: staged change → exit non-zero; stderr names dirty file" test_t03_staged_change

# ── T04: dirty file OUTSIDE batch_files → returns 0 (only batch matters) ──
test_t04_dirty_outside_batch_ok() {
    setup_repo || return 1
    local fn_src
    fn_src=$(_load_lib)
    eval "$fn_src"
    # Make file2.py dirty, but only pass file1.py to preflight
    echo "irrelevant-edit" >> "$PROJECT_DIR/file2.py"
    (
        cd "$PROJECT_DIR"
        local rc=0
        _mechanical_preflight_clean "file1.py" 2>/dev/null || rc=$?
        [[ $rc -eq 0 ]]
    )
}
check "T04: dirty file outside batch → exit 0 (only batch_files checked)" test_t04_dirty_outside_batch_ok

# ── T05: empty batch_files → returns 0 (nothing to check, no-op) ──
test_t05_empty_batch() {
    setup_repo || return 1
    local fn_src
    fn_src=$(_load_lib)
    eval "$fn_src"
    (
        cd "$PROJECT_DIR"
        local rc=0
        _mechanical_preflight_clean 2>/dev/null || rc=$?
        [[ $rc -eq 0 ]]
    )
}
check "T05: empty batch_files → exit 0 (no-op)" test_t05_empty_batch

# ── T06: stderr message guides operator (mentions commit/stash) ──
test_t06_actionable_message() {
    setup_repo || return 1
    local fn_src
    fn_src=$(_load_lib)
    eval "$fn_src"
    echo "dirty-edit" >> "$PROJECT_DIR/file1.py"
    (
        cd "$PROJECT_DIR"
        local err
        err=$(_mechanical_preflight_clean "file1.py" 2>&1 >/dev/null) || true
        # Message should name the file AND tell the operator what to do
        [[ "$err" == *"file1.py"* ]] && \
            { [[ "$err" == *"commit"* ]] || [[ "$err" == *"stash"* ]]; }
    )
}
check "T06: stderr is actionable (names file + commit/stash hint)" test_t06_actionable_message

# ── T07: multiple dirty files → all named in stderr ──
test_t07_multiple_dirty_files_all_named() {
    setup_repo || return 1
    local fn_src
    fn_src=$(_load_lib)
    eval "$fn_src"
    echo "x" >> "$PROJECT_DIR/file1.py"
    echo "y" >> "$PROJECT_DIR/file2.py"
    (
        cd "$PROJECT_DIR"
        local err
        err=$(_mechanical_preflight_clean "file1.py" "file2.py" 2>&1 >/dev/null) || true
        [[ "$err" == *"file1.py"* ]] && [[ "$err" == *"file2.py"* ]]
    )
}
check "T07: multiple dirty files → all named in single error report" test_t07_multiple_dirty_files_all_named

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
