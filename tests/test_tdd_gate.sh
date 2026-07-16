#!/bin/bash
# test_tdd_gate.sh — TDD test suite for claude/hooks/tdd-gate.sh
#
# Usage: bash tests/test_tdd_gate.sh
# Exits 0 on all pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_DIR/adapters/claude-code/claude/hooks/tdd-gate.sh"

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

TEST_DIR="${TMPDIR:-/tmp}/test-tdd-gate-$$"

setup_repo() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR" || return 1
    git init -q -b main .
    # Existing surfaces
    mkdir -p app/src/__tests__ tests server
    echo "x" > app/src/foo.ts
    echo "y" > server/foo.py
    # Extended surfaces (2026-05-23): Python backend + orchestrators + tools.
    # These mirror the real dotfiles repo layout so T13–T17 exercise the
    # new path-coverage rules without needing fixtures of their own.
    mkdir -p dashboard/server/middleware dashboard/tools
    mkdir -p adapters/claude-code/claude/tools/lib
    echo "y" > dashboard/server/app.py
    echo "y" > dashboard/server/middleware/csrf.py
    echo "y" > dashboard/tools/validator.py
    echo "y" > adapters/claude-code/claude/tools/autopilot.py
    echo "y" > adapters/claude-code/claude/tools/lib/finalize_result.py
    git add .
    git -c user.email=t@t -c user.name=t commit -q -m init
}

teardown() {
    rm -rf "$TEST_DIR"
}
trap teardown EXIT

run_hook() {
    local file_path="$1"
    echo "{\"tool_input\":{\"file_path\":\"$file_path\"}}" | bash "$HOOK" 2>/dev/null
}

echo "Running tdd-gate tests..."
echo ""

# T01: Non-src/ paths pass through (no gate)
test_t01() {
    setup_repo
    run_hook "$TEST_DIR/server/foo.py"
}
check "T01: non-src/ path → exit 0 (pass-through)" test_t01

# T02: src/ on main with no tests → BLOCK
test_t02() {
    setup_repo
    local output
    output=$(run_hook "$TEST_DIR/app/src/foo.ts" 2>&1; echo "exit=$?")
    [[ "$output" == *"exit=2"* ]]
}
check "T02: main branch, no tests → exit 2 (block)" test_t02

# T03: Uncommitted test in tests/ → ALLOW
test_t03() {
    setup_repo
    echo "new" > "$TEST_DIR/tests/test_foo.py"
    run_hook "$TEST_DIR/app/src/foo.ts"
}
check "T03: uncommitted tests/ file → exit 0 (allow)" test_t03

# T04: Uncommitted test in __tests__/ → ALLOW
test_t04() {
    setup_repo
    echo "new" > "$TEST_DIR/app/src/__tests__/foo.test.ts"
    run_hook "$TEST_DIR/app/src/foo.ts"
}
check "T04: uncommitted __tests__/ file → exit 0 (allow)" test_t04

# T05: feature/* branch with tests/ committed vs main → ALLOW
test_t05() {
    setup_repo
    git checkout -q -b feature/x
    echo "new" > tests/test_foo.py
    git add tests/test_foo.py
    git -c user.email=t@t -c user.name=t commit -q -m "add test"
    run_hook "$TEST_DIR/app/src/foo.ts"
}
check "T05: feature branch with tests/ committed → exit 0 (allow)" test_t05

# T06: feature/* branch with __tests__/ committed vs main → ALLOW
test_t06() {
    setup_repo
    git checkout -q -b feature/y
    echo "new" > app/src/__tests__/foo.test.ts
    git add app/src/__tests__/foo.test.ts
    git -c user.email=t@t -c user.name=t commit -q -m "add frontend test"
    run_hook "$TEST_DIR/app/src/foo.ts"
}
check "T06: feature branch with __tests__/ committed → exit 0 (allow)" test_t06

# T07: feature/* branch with NO test changes → BLOCK
test_t07() {
    setup_repo
    git checkout -q -b feature/z
    local output
    output=$(run_hook "$TEST_DIR/app/src/foo.ts" 2>&1; echo "exit=$?")
    [[ "$output" == *"exit=2"* ]]
}
check "T07: feature branch with no test changes → exit 2 (block)" test_t07

# T08: Hook is cwd-independent — runs correctly when cwd != repo
test_t08() {
    setup_repo
    git checkout -q -b feature/cwd
    echo "new" > app/src/__tests__/foo.test.ts
    git add app/src/__tests__/foo.test.ts
    git -c user.email=t@t -c user.name=t commit -q -m "add test"
    cd "$REPO_DIR" || return 1  # change cwd AWAY from the test repo
    run_hook "$TEST_DIR/app/src/foo.ts"
}
check "T08: hook works when cwd != file's repo (worktree case)" test_t08

# T09: Non-git path → pass through (no repo to check)
test_t09() {
    local tmp="${TMPDIR:-/tmp}/not-a-repo-$$"
    mkdir -p "$tmp/src"
    local rc=0
    run_hook "$tmp/src/foo.ts" || rc=$?
    rm -rf "$tmp"
    [ "$rc" -eq 0 ]
}
check "T09: non-git path → exit 0 (pass-through)" test_t09

# T10: Writing TO a test file under src/__tests__/ on main → ALLOW.
# The test file IS the test-first step; the gate must not false-positive
# because its own path contains the substring "src/". Reported during
# controls-03 audit when SessionControls.test.tsx (in src/__tests__/)
# could not be edited via the Edit tool on main.
test_t10() {
    setup_repo
    run_hook "$TEST_DIR/app/src/__tests__/foo.test.ts"
}
check "T10: writing to src/__tests__/ test file on main → exit 0 (allow)" test_t10

# T11: Writing to a *.test.ts file that lives directly under src/ on main → ALLOW
# (handles colocated-tests project layouts, e.g. src/foo.test.ts next to src/foo.ts).
test_t11() {
    setup_repo
    run_hook "$TEST_DIR/app/src/foo.test.ts"
}
check "T11: writing to *.test.ts file under src/ on main → exit 0 (allow)" test_t11

# T12: Writing to a *_test.py file under src/ on main → ALLOW
# (Python pytest convention, in case a project chooses colocated layout).
test_t12() {
    setup_repo
    run_hook "$TEST_DIR/app/src/foo_test.py"
}
check "T12: writing to *_test.py file under src/ on main → exit 0 (allow)" test_t12

# ───────────────────────────────────────────────────────────────────
# Extended path coverage (added 2026-05-23):
# /src/ alone covers only the frontend; most of this repo's Python
# (dashboard/server/, adapters/claude-code/.../tools/, dashboard/tools/)
# was previously ungated. T13–T17 lock in the broader coverage.
# T18–T19 verify out-of-scope paths still pass through.
# ───────────────────────────────────────────────────────────────────

# T13: writing to dashboard/server/*.py on main with no tests → BLOCK
test_t13() {
    setup_repo
    local output
    output=$(run_hook "$TEST_DIR/dashboard/server/app.py" 2>&1; echo "exit=$?")
    [[ "$output" == *"exit=2"* ]]
}
check "T13: dashboard/server/*.py, main, no tests → exit 2 (block)" test_t13

# T14: writing to dashboard/server/<subdir>/*.py (e.g. middleware/) → BLOCK
# Proves the rule matches at arbitrary depth, not just one level deep.
test_t14() {
    setup_repo
    local output
    output=$(run_hook "$TEST_DIR/dashboard/server/middleware/csrf.py" 2>&1; echo "exit=$?")
    [[ "$output" == *"exit=2"* ]]
}
check "T14: dashboard/server/<subdir>/*.py → exit 2 (block at any depth)" test_t14

# T15: writing to adapters/claude-code/claude/tools/*.py on main → BLOCK
test_t15() {
    setup_repo
    local output
    output=$(run_hook "$TEST_DIR/adapters/claude-code/claude/tools/autopilot.py" 2>&1; echo "exit=$?")
    [[ "$output" == *"exit=2"* ]]
}
check "T15: claude/tools/*.py → exit 2 (block)" test_t15

# T16: writing to adapters/claude-code/claude/tools/lib/*.py → BLOCK
test_t16() {
    setup_repo
    local output
    output=$(run_hook "$TEST_DIR/adapters/claude-code/claude/tools/lib/finalize_result.py" 2>&1; echo "exit=$?")
    [[ "$output" == *"exit=2"* ]]
}
check "T16: claude/tools/lib/*.py → exit 2 (block at any depth)" test_t16

# T17: writing to dashboard/tools/*.py on main → BLOCK
test_t17() {
    setup_repo
    local output
    output=$(run_hook "$TEST_DIR/dashboard/tools/validator.py" 2>&1; echo "exit=$?")
    [[ "$output" == *"exit=2"* ]]
}
check "T17: dashboard/tools/*.py → exit 2 (block)" test_t17

# T18: Bash files are NOT gated — shellcheck is the bash quality gate
# (in /implement Step 5.2 and /static-analysis Step 2.4). The TDD hook
# only enforces unit-test discipline, which is not the convention for
# bash orchestrators in this repo.
test_t18() {
    setup_repo
    run_hook "$TEST_DIR/adapters/claude-code/claude/tools/autopilot.sh"
}
check "T18: bash .sh files → exit 0 (pass-through, shellcheck gates bash)" test_t18

# T19: Docs/config NOT gated. README, *.md, *.toml etc. are not source.
test_t19() {
    setup_repo
    run_hook "$TEST_DIR/dashboard/server/README.md"
}
check "T19: dashboard/server/*.md → exit 0 (pass-through, not source)" test_t19

# T20: feature/* branch with tests committed on branch + write to
# extended-coverage Python path → ALLOW (test-committed path applies
# universally, not just to /src/).
test_t20() {
    setup_repo
    git checkout -q -b feature/python-test
    echo "new" > tests/test_app.py
    git add tests/test_app.py
    git -c user.email=t@t -c user.name=t commit -q -m "add backend test"
    run_hook "$TEST_DIR/dashboard/server/app.py"
}
check "T20: feature branch, tests committed → exit 0 (allow extended-path write)" test_t20

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
