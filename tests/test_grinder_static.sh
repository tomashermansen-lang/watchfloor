#!/bin/bash
# test_grinder_static.sh — Bash integration tests for grinder-static.sh
#
# Tests: ST-B01..ST-B29 from TESTPLAN.md
#
# Usage: bash tests/test_grinder_static.sh
# Exits with the number of failures (0 = all pass).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="$REPO_DIR/adapters/claude-code/claude/tools"
LIB_DIR="$TOOLS_DIR/lib"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

check_fail() {
    local name="$1"
    shift
    if ! "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name (expected failure)"
        failed=$((failed + 1))
    fi
}

# --- Setup ---

TEST_DIR="${TMPDIR:-/tmp}/test-grinder-static-$$"
mkdir -p "$TEST_DIR"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Source the library under test with stubs
SCHEMA_DIR="$REPO_DIR/schema"
PROJECT_DIR="$TEST_DIR/project"
GRINDER_DIR="$TEST_DIR/grinder"
mkdir -p "$PROJECT_DIR" "$GRINDER_DIR"

# Provide stubs for functions from grinder.sh
log() { echo -e "$1"; }

# Source the library
source "$LIB_DIR/grinder-static.sh"

echo "Testing grinder-static.sh helpers..."
echo ""

# ============================================================
# Allowlist Matching Tests (ST-B01 through ST-B03)
# ============================================================

echo "--- Allowlist Matching ---"

# ST-B01: rule matches
test_b01() {
    _STATIC_ALLOWLIST=$'B101\nS1481\nE0602'
    _static_match_allowlist "B101"
}
check "ST-B01: _static_match_allowlist — rule matches" test_b01

# ST-B02: rule does not match
test_b02() {
    _STATIC_ALLOWLIST=$'B101\nS1481'
    ! _static_match_allowlist "E0602"
}
check "ST-B02: _static_match_allowlist — rule does not match" test_b02

# ST-B03: empty allowlist
test_b03() {
    _STATIC_ALLOWLIST=""
    ! _static_match_allowlist "B101"
}
check "ST-B03: _static_match_allowlist — empty allowlist" test_b03

# ============================================================
# never_touch Matching Tests (ST-B04 through ST-B06)
# ============================================================

echo ""
echo "--- never_touch Matching ---"

# ST-B04: glob match
test_b04() {
    _STATIC_NEVER_TOUCH=$'tests/**\n**/conftest.py'
    _static_match_never_touch "tests/test_app.py"
}
check "ST-B04: _static_match_never_touch — glob match" test_b04

# ST-B05: no match
test_b05() {
    _STATIC_NEVER_TOUCH="tests/**"
    ! _static_match_never_touch "src/app.py"
}
check "ST-B05: _static_match_never_touch — no match" test_b05

# ST-B06: empty patterns
test_b06() {
    _STATIC_NEVER_TOUCH=""
    ! _static_match_never_touch "any/file.py"
}
check "ST-B06: _static_match_never_touch — empty patterns" test_b06

# ============================================================
# Diff Suppression Tests (ST-B07 through ST-B15)
# ============================================================

echo ""
echo "--- Diff Suppression Detection ---"

setup_git_for_suppression() {
    local dir
    dir=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial content" > file.py
    git add file.py
    git commit -q -m "initial"
    echo "$dir"
}

# ST-B07: clean diff
test_b07() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "clean code here" >> "$dir/file.py"
    cd "$dir" && git add file.py
    _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B07: _static_check_diff_suppressions — clean diff" test_b07

# ST-B08: # noqa detected
test_b08() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "x = 1  # noqa" >> "$dir/file.py"
    cd "$dir" && git add file.py
    ! _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B08: _static_check_diff_suppressions — # noqa detected" test_b08

# ST-B09: // eslint-disable detected
test_b09() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "// eslint-disable-next-line" >> "$dir/file.py"
    cd "$dir" && git add file.py
    ! _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B09: _static_check_diff_suppressions — // eslint-disable detected" test_b09

# ST-B10: # type: ignore detected
test_b10() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "x: int = 'a'  # type: ignore" >> "$dir/file.py"
    cd "$dir" && git add file.py
    ! _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B10: _static_check_diff_suppressions — # type: ignore detected" test_b10

# ST-B11: // @ts-ignore detected
test_b11() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "// @ts-ignore" >> "$dir/file.py"
    cd "$dir" && git add file.py
    ! _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B11: _static_check_diff_suppressions — // @ts-ignore detected" test_b11

# ST-B12: # pragma: no cover detected
test_b12() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "if True:  # pragma: no cover" >> "$dir/file.py"
    cd "$dir" && git add file.py
    ! _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B12: _static_check_diff_suppressions — # pragma: no cover detected" test_b12

# ST-B13: # shellcheck disable= detected
test_b13() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "# shellcheck disable=SC2034" >> "$dir/file.py"
    cd "$dir" && git add file.py
    ! _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B13: _static_check_diff_suppressions — # shellcheck disable= detected" test_b13

# ST-B14: // @ts-expect-error bare
test_b14() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "// @ts-expect-error" >> "$dir/file.py"
    cd "$dir" && git add file.py
    ! _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B14: _static_check_diff_suppressions — // @ts-expect-error bare" test_b14

# ST-B14b: /* istanbul ignore */ detected
test_b14b() {
    local dir
    dir=$(setup_git_for_suppression)
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    echo "/* istanbul ignore next */" >> "$dir/file.py"
    cd "$dir" && git add file.py
    ! _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B14b: _static_check_diff_suppressions — /* istanbul ignore */ detected" test_b14b

# ST-B15: pre-existing suppression not flagged
test_b15() {
    local dir
    dir=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    # File already has suppression
    printf 'line1\nline2\nline3\nline4\nx = 1  # noqa\nline6\nline7\nline8\nline9\nline10\n' > file.py
    git add file.py
    git commit -q -m "initial with noqa"
    # Modify a different line (no suppression)
    sed -i '' 's/line10/modified_line10/' file.py 2>/dev/null || sed -i 's/line10/modified_line10/' file.py
    git add file.py
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$dir"
    _static_check_diff_suppressions
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B15: _static_check_diff_suppressions — pre-existing suppression not flagged" test_b15

# ============================================================
# Append Proposal Tests (ST-B16 through ST-B18)
# ============================================================

echo ""
echo "--- Append Proposal ---"

# ST-B16: creates file when absent
test_b16() {
    local test_project
    test_project=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    mkdir -p "$test_project/docs/grinder"
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$test_project"
    local finding='{"tool":"bandit","rule":"B101","file":"src/app.py","line":42,"severity":"MEDIUM","message":"Use of assert"}'
    _static_append_proposal "$finding" "batch-001"
    # Check file exists and has header
    grep -q "# Grinder Proposals" "$test_project/docs/grinder/proposals.md"
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B16: _static_append_proposal — creates file when absent" test_b16

# ST-B17: appends to existing file
test_b17() {
    local test_project
    test_project=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    mkdir -p "$test_project/docs/grinder"
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$test_project"
    # Create existing file with one entry
    cat > "$test_project/docs/grinder/proposals.md" << 'EXISTING'
# Grinder Proposals

### OLD_RULE — old/file.py:1
- **Tool:** oldtool
- **Severity:** LOW
- **Message:** Old message
- **Batch:** batch-000
- **Date:** 2026-01-01T00:00:00Z
EXISTING
    local finding='{"tool":"bandit","rule":"B101","file":"src/app.py","line":42,"severity":"MEDIUM","message":"Use of assert"}'
    _static_append_proposal "$finding" "batch-001"
    # Check both entries exist
    local count
    count=$(grep -c "^### " "$test_project/docs/grinder/proposals.md")
    [[ "$count" -eq 2 ]]
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B17: _static_append_proposal — appends to existing file" test_b17

# ST-B18: entry format correct
test_b18() {
    local test_project
    test_project=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    mkdir -p "$test_project/docs/grinder"
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$test_project"
    local finding='{"tool":"bandit","rule":"B101","file":"src/app.py","line":42,"severity":"MEDIUM","message":"Use of assert"}'
    _static_append_proposal "$finding" "batch-001"
    local f="$test_project/docs/grinder/proposals.md"
    grep -qF "### B101 — src/app.py:42" "$f" && \
    grep -qF '**Tool:** bandit' "$f" && \
    grep -qF '**Severity:** MEDIUM' "$f" && \
    grep -qF '**Message:** Use of assert' "$f" && \
    grep -qF '**Batch:** batch-001' "$f" && \
    grep -qF '**Date:**' "$f"
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B18: _static_append_proposal — entry format correct" test_b18

# ============================================================
# Determine Primary Tool Tests (ST-B19 through ST-B20)
# ============================================================

echo ""
echo "--- Primary Tool ---"

# ST-B19: single scanner
test_b19() {
    local json='[{"tool":"bandit"},{"tool":"bandit"},{"tool":"bandit"}]'
    local result
    result=$(_static_determine_primary_tool "$json")
    [[ "$result" == "bandit" ]]
}
check "ST-B19: _static_determine_primary_tool — single scanner" test_b19

# ST-B20: multi scanner, majority wins
test_b20() {
    local json='[{"tool":"bandit"},{"tool":"bandit"},{"tool":"bandit"},{"tool":"mypy"}]'
    local result
    result=$(_static_determine_primary_tool "$json")
    [[ "$result" == "bandit" ]]
}
check "ST-B20: _static_determine_primary_tool — multi scanner, majority wins" test_b20

# ============================================================
# Build Prompt Tests (ST-B21 through ST-B24)
# ============================================================

echo ""
echo "--- Build Prompt ---"

# ST-B21: contains objective
test_b21() {
    local json='[{"tool":"bandit","rule":"B101","file":"src/a.py","line":1,"message":"test","severity":"warning"}]'
    local result
    result=$(_static_build_prompt "$json")
    echo "$result" | grep -q "Fix the following static-analysis findings"
}
check "ST-B21: _static_build_prompt — contains objective" test_b21

# ST-B22: contains suppression constraint
test_b22() {
    local json='[{"tool":"bandit","rule":"B101","file":"src/a.py","line":1,"message":"test","severity":"warning"}]'
    local result
    result=$(_static_build_prompt "$json")
    echo "$result" | grep -q "# noqa" && echo "$result" | grep -q "# type: ignore"
}
check "ST-B22: _static_build_prompt — contains suppression constraint" test_b22

# ST-B23: contains no-refactor constraint
test_b23() {
    local json='[{"tool":"bandit","rule":"B101","file":"src/a.py","line":1,"message":"test","severity":"warning"}]'
    local result
    result=$(_static_build_prompt "$json")
    echo "$result" | grep -q "Do not refactor surrounding code"
}
check "ST-B23: _static_build_prompt — contains no-refactor constraint" test_b23

# ST-B24: contains no-new-deps constraint
test_b24() {
    local json='[{"tool":"bandit","rule":"B101","file":"src/a.py","line":1,"message":"test","severity":"warning"}]'
    local result
    result=$(_static_build_prompt "$json")
    echo "$result" | grep -q "Do not add new dependencies"
}
check "ST-B24: _static_build_prompt — contains no-new-deps constraint" test_b24

# ============================================================
# Manifest Loading Tests (ST-B25)
# ============================================================

echo ""
echo "--- Manifest Loading ---"

# ST-B25: caches after first call
test_b25() {
    local test_project
    test_project=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    # Create a CLAUDE.md with grinder block
    cat > "$test_project/CLAUDE.md" << 'EOF'
# Test Project

pipeline:
  grinder:
    languages: [python]
    findings:
      shellcheck:
        paths: [src/]
      fix_rules_allowlist: [B101]
      never_touch_files: ["tests/**"]
EOF
    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$test_project"
    _STATIC_MANIFEST_LOADED=""
    _STATIC_ALLOWLIST=""
    _STATIC_NEVER_TOUCH=""
    _static_load_manifest
    local first_loaded="$_STATIC_MANIFEST_LOADED"
    local first_allowlist="$_STATIC_ALLOWLIST"
    # Call again — should use cache
    _static_load_manifest
    [[ "$first_loaded" == "true" ]] && [[ "$_STATIC_MANIFEST_LOADED" == "true" ]] && [[ "$_STATIC_ALLOWLIST" == "$first_allowlist" ]]
    local rc=$?
    PROJECT_DIR="$old_project_dir"
    return $rc
}
check "ST-B25: _static_load_manifest — caches after first call" test_b25

# ============================================================
# Execute Static Batch Tests (ST-B26, ST-B27)
# ============================================================

echo ""
echo "--- Execute Static Batch ---"

# ST-B26: all proposed, no claude session
test_b26() {
    local test_project
    test_project=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    cd "$test_project"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    mkdir -p src docs/grinder/scanner-output
    echo "x = 1" > src/app.py
    git add .
    git commit -q -m "initial"

    # Create CLAUDE.md with empty allowlist
    cat > "$test_project/CLAUDE.md" << 'EOF'
# Test

pipeline:
  grinder:
    languages: [python]
    findings:
      bandit:
        paths: [src/]
      fix_rules_allowlist: []
      never_touch_files: []
EOF

    # Create scanner output with findings
    cat > "$test_project/docs/grinder/scanner-output/bandit.json" << 'SCAN'
[{"id":"bandit:B101-app.py-aaaaaaaa","tool":"bandit","rule":"B101","file":"src/app.py","line":1,"severity":"warning","message":"Use of assert","content_hash":"aaaaaaaa"}]
SCAN

    local old_project_dir="$PROJECT_DIR"
    local old_grinder_dir="$GRINDER_DIR"
    PROJECT_DIR="$test_project"
    GRINDER_DIR="$test_project/docs/grinder"
    _STATIC_MANIFEST_LOADED=""

    # Stub run_phase to fail if called
    run_phase() { echo "ERROR: run_phase should not be called" >&2; return 1; }

    local output
    output=$(execute_static_batch "batch-001" "static_analysis" '["src/app.py"]' "5" 2>/dev/null)
    local rc=$?

    # Restore
    PROJECT_DIR="$old_project_dir"
    GRINDER_DIR="$old_grinder_dir"
    unset -f run_phase

    [[ $rc -eq 0 ]] && echo "$output" | grep -q "files_fixed=0"
}
check "ST-B26: execute_static_batch — all proposed, no claude session" test_b26

# ST-B27: all skipped (never_touch), no claude session
test_b27() {
    local test_project
    test_project=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    cd "$test_project"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    mkdir -p tests docs/grinder/scanner-output
    echo "x = 1" > tests/test_a.py
    git add .
    git commit -q -m "initial"

    cat > "$test_project/CLAUDE.md" << 'EOF'
# Test

pipeline:
  grinder:
    languages: [python]
    findings:
      bandit:
        paths: [tests/]
      fix_rules_allowlist: [B101]
      never_touch_files: ["tests/**"]
EOF

    cat > "$test_project/docs/grinder/scanner-output/bandit.json" << 'SCAN'
[{"id":"bandit:B101-test_a.py-aaaaaaaa","tool":"bandit","rule":"B101","file":"tests/test_a.py","line":1,"severity":"warning","message":"Use of assert","content_hash":"aaaaaaaa"}]
SCAN

    local old_project_dir="$PROJECT_DIR"
    local old_grinder_dir="$GRINDER_DIR"
    PROJECT_DIR="$test_project"
    GRINDER_DIR="$test_project/docs/grinder"
    _STATIC_MANIFEST_LOADED=""

    run_phase() { echo "ERROR: run_phase should not be called" >&2; return 1; }

    local output
    output=$(execute_static_batch "batch-002" "static_analysis" '["tests/test_a.py"]' "5" 2>/dev/null)
    local rc=$?

    PROJECT_DIR="$old_project_dir"
    GRINDER_DIR="$old_grinder_dir"
    unset -f run_phase

    [[ $rc -eq 0 ]] && echo "$output" | grep -q "files_skipped=1" && echo "$output" | grep -q "files_fixed=0"
}
check "ST-B27: execute_static_batch — all skipped (never_touch), no claude session" test_b27

# ============================================================
# Commit Proposals Tests (ST-B28, ST-B29)
# ============================================================

echo ""
echo "--- Commit Proposals ---"

# ST-B28: commits when proposals exist
test_b28() {
    local test_project
    test_project=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    cd "$test_project"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    mkdir -p docs/grinder
    echo "initial" > file.txt
    git add .
    git commit -q -m "initial"

    # Create proposals.md (simulating proposals were written)
    echo "# Grinder Proposals" > docs/grinder/proposals.md
    echo "" >> docs/grinder/proposals.md
    echo "### B101 — src/a.py:1" >> docs/grinder/proposals.md

    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$test_project"
    static_commit_proposals
    local rc=$?
    PROJECT_DIR="$old_project_dir"

    # Check commit exists
    cd "$test_project"
    git log --oneline -1 | grep -q "pass-3-static proposals"
}
check "ST-B28: static_commit_proposals — commits when proposals exist" test_b28

# ST-B29: no commit when no proposals
test_b29() {
    local test_project
    test_project=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    cd "$test_project"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    mkdir -p docs/grinder
    echo "initial" > file.txt
    git add .
    git commit -q -m "initial"

    local old_project_dir="$PROJECT_DIR"
    PROJECT_DIR="$test_project"
    local commit_before
    commit_before=$(cd "$test_project" && git rev-parse HEAD)
    static_commit_proposals
    local commit_after
    commit_after=$(cd "$test_project" && git rev-parse HEAD)
    PROJECT_DIR="$old_project_dir"

    [[ "$commit_before" == "$commit_after" ]]
}
check "ST-B29: static_commit_proposals — no commit when no proposals" test_b29

# ============================================================
# Summary
# ============================================================

echo ""
echo "========================"
echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
echo "========================"

exit $failed
