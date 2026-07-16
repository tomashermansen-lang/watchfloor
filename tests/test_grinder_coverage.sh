#!/bin/bash
# test_grinder_coverage.sh — Tests for grinder-coverage.sh helpers
#
# Tests: suppression rejection, mock depth validation, test file filtering,
#        revert mechanics, early exit check, needs_review threshold.
#
# Usage: bash tests/test_grinder_coverage.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
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

TEST_DIR="${TMPDIR:-/tmp}/test-grinder-coverage-$$"
mkdir -p "$TEST_DIR"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Source the library under test
# We need to set up the environment that grinder-coverage.sh expects
TOOLS_DIR="$REPO_DIR/adapters/claude-code/claude/tools"
LIB_DIR="$TOOLS_DIR/lib"
SCHEMA_DIR="$REPO_DIR/schema"
PROJECT_DIR="$TEST_DIR/project"
GRINDER_DIR="$TEST_DIR/grinder"
mkdir -p "$PROJECT_DIR" "$GRINDER_DIR"

# Source dependencies first (grinder-coverage.sh needs log() etc.)
# Provide stubs for functions from grinder.sh that coverage lib may reference
log() { echo -e "$1"; }
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Source the library
source "$LIB_DIR/grinder-coverage.sh"

echo "Testing grinder-coverage.sh helpers..."
echo ""

# ============================================================
# Suppression Rejection Tests (S-01 through S-11)
# ============================================================

echo "--- Suppression Rejection ---"

# S-01: Detects # pragma: no cover
test_s01() {
    local f="$TEST_DIR/test_s01.py"
    echo 'x = 1  # pragma: no cover' > "$f"
    ! _coverage_check_suppressions "$f"
}
check "S-01: detects # pragma: no cover" test_s01

# S-02: Detects # noqa
test_s02() {
    local f="$TEST_DIR/test_s02.py"
    echo 'x = 1  # noqa' > "$f"
    ! _coverage_check_suppressions "$f"
}
check "S-02: detects # noqa" test_s02

# S-03: Detects // istanbul ignore
test_s03() {
    local f="$TEST_DIR/test_s03.ts"
    echo '// istanbul ignore next' > "$f"
    ! _coverage_check_suppressions "$f"
}
check "S-03: detects // istanbul ignore" test_s03

# S-04: Detects # type: ignore
test_s04() {
    local f="$TEST_DIR/test_s04.py"
    echo 'x: int = "a"  # type: ignore' > "$f"
    ! _coverage_check_suppressions "$f"
}
check "S-04: detects # type: ignore" test_s04

# S-05: Detects /* istanbul ignore */
test_s05() {
    local f="$TEST_DIR/test_s05.ts"
    echo '/* istanbul ignore next */' > "$f"
    ! _coverage_check_suppressions "$f"
}
check "S-05: detects /* istanbul ignore */" test_s05

# S-06: Detects // @ts-ignore
test_s06() {
    local f="$TEST_DIR/test_s06.ts"
    echo '// @ts-ignore' > "$f"
    ! _coverage_check_suppressions "$f"
}
check "S-06: detects // @ts-ignore" test_s06

# S-07: Detects bare // @ts-expect-error
test_s07() {
    local f="$TEST_DIR/test_s07.ts"
    echo '// @ts-expect-error' > "$f"
    ! _coverage_check_suppressions "$f"
}
check "S-07: detects bare // @ts-expect-error" test_s07

# S-08: Allows // @ts-expect-error TS2345
test_s08() {
    local f="$TEST_DIR/test_s08.ts"
    echo '// @ts-expect-error TS2345' > "$f"
    _coverage_check_suppressions "$f"
}
check "S-08: allows // @ts-expect-error TS2345" test_s08

# S-09: Clean test file passes
test_s09() {
    local f="$TEST_DIR/test_s09.py"
    cat > "$f" << 'EOF'
def test_clean():
    assert 1 + 1 == 2
EOF
    _coverage_check_suppressions "$f"
}
check "S-09: clean test file passes" test_s09

# S-10: Suppression in string literal still rejects (EC-5.1)
test_s10() {
    local f="$TEST_DIR/test_s10.py"
    cat > "$f" << 'EOF'
def test_pragma():
    assert "# pragma: no cover" in code
EOF
    ! _coverage_check_suppressions "$f"
}
check "S-10: suppression in string literal still rejects" test_s10

# S-11: Multiple files — one bad fails all (EC-5.2)
test_s11() {
    local f1="$TEST_DIR/test_s11_clean.py"
    local f2="$TEST_DIR/test_s11_bad.py"
    echo 'assert True' > "$f1"
    echo '# noqa' > "$f2"
    ! _coverage_check_suppressions "$f1" "$f2"
}
check "S-11: multiple files — one bad fails all" test_s11

# ============================================================
# Mock Depth Tests (M-01 through M-07)
# ============================================================

echo ""
echo "--- Mock Depth ---"

# M-01: Zero mocks passes
test_m01() {
    local f="$TEST_DIR/test_m01.ts"
    cat > "$f" << 'EOF'
describe('feature', () => {
  it('works', () => {
    expect(1 + 1).toBe(2);
  });
});
EOF
    _coverage_check_mock_depth "$f"
}
check "M-01: zero mocks passes" test_m01

# M-02: Exactly 3 mocks passes
test_m02() {
    local f="$TEST_DIR/test_m02.ts"
    cat > "$f" << 'EOF'
describe('feature', () => {
  it('works', () => {
    vi.mock('a');
    vi.mock('b');
    vi.mock('c');
    expect(1).toBe(1);
  });
});
EOF
    _coverage_check_mock_depth "$f"
}
check "M-02: exactly 3 mocks passes" test_m02

# M-03: 4 mocks rejected
test_m03() {
    local f="$TEST_DIR/test_m03.ts"
    cat > "$f" << 'EOF'
describe('feature', () => {
  it('works', () => {
    vi.mock('a');
    vi.mock('b');
    vi.mock('c');
    vi.mock('d');
    expect(1).toBe(1);
  });
});
EOF
    ! _coverage_check_mock_depth "$f"
}
check "M-03: 4 mocks rejected" test_m03

# M-04: Python mock patterns counted
test_m04() {
    local f="$TEST_DIR/test_m04.py"
    cat > "$f" << 'EOF'
def test_auth():
    mock.patch('mod1')
    Mock()
    MagicMock()
    patch.object(cls, 'attr')
    assert True
EOF
    ! _coverage_check_mock_depth "$f"
}
check "M-04: Python mock patterns counted (4 = rejected)" test_m04

# M-05: TypeScript mock patterns counted
test_m05() {
    local f="$TEST_DIR/test_m05.ts"
    cat > "$f" << 'EOF'
describe('api', () => {
  it('calls service', () => {
    vi.mock('service');
    vi.fn();
    jest.mock('other');
    jest.fn();
    expect(true).toBe(true);
  });
});
EOF
    ! _coverage_check_mock_depth "$f"
}
check "M-05: TypeScript mock patterns counted (4 = rejected)" test_m05

# M-06: Mocks in beforeEach count toward block (EC-6.1)
test_m06() {
    local f="$TEST_DIR/test_m06.ts"
    cat > "$f" << 'EOF'
describe('feature', () => {
  beforeEach(() => {
    vi.mock('a');
    vi.mock('b');
  });
  it('test1', () => {
    vi.mock('c');
    vi.mock('d');
    expect(1).toBe(1);
  });
});
EOF
    ! _coverage_check_mock_depth "$f"
}
check "M-06: mocks in beforeEach count toward block" test_m06

# M-07: Separate describe blocks counted independently
test_m07() {
    local f="$TEST_DIR/test_m07.ts"
    cat > "$f" << 'EOF'
describe('block1', () => {
  it('test1', () => {
    vi.mock('a');
    vi.mock('b');
    expect(1).toBe(1);
  });
});
describe('block2', () => {
  it('test2', () => {
    vi.mock('c');
    vi.mock('d');
    expect(2).toBe(2);
  });
});
EOF
    _coverage_check_mock_depth "$f"
}
check "M-07: separate describe blocks counted independently" test_m07

# ============================================================
# Test File Filtering Tests (F-01 through F-06)
# ============================================================

echo ""
echo "--- Test File Filtering ---"

# F-01: test_*.py accepted
test_f01() {
    local result
    result=$(_coverage_filter_test_files "test_foo.py")
    [[ "$result" == *"test_foo.py"* ]]
}
check "F-01: test_*.py accepted" test_f01

# F-02: *_test.py accepted
test_f02() {
    local result
    result=$(_coverage_filter_test_files "foo_test.py")
    [[ "$result" == *"foo_test.py"* ]]
}
check "F-02: *_test.py accepted" test_f02

# F-03: *.test.ts accepted
test_f03() {
    local result
    result=$(_coverage_filter_test_files "foo.test.ts")
    [[ "$result" == *"foo.test.ts"* ]]
}
check "F-03: *.test.ts accepted" test_f03

# F-04: *.test.tsx accepted
test_f04() {
    local result
    result=$(_coverage_filter_test_files "foo.test.tsx")
    [[ "$result" == *"foo.test.tsx"* ]]
}
check "F-04: *.test.tsx accepted" test_f04

# F-05: *.spec.ts accepted
test_f05() {
    local result
    result=$(_coverage_filter_test_files "foo.spec.ts")
    [[ "$result" == *"foo.spec.ts"* ]]
}
check "F-05: *.spec.ts accepted" test_f05

# F-06: Non-test file rejected
test_f06() {
    local result
    result=$(_coverage_filter_test_files "foo.ts")
    [[ -z "$result" ]]
}
check "F-06: non-test file rejected" test_f06

# ============================================================
# Early Exit Tests (E-01 through E-03)
# ============================================================

echo ""
echo "--- Early Exit ---"

# E-01: Project-wide coverage meets target — skip pass
test_e01() {
    local result
    result=$(_should_early_exit_coverage 0.87 0.85)
    [[ "$result" == "true" ]]
}
check "E-01: coverage 87% >= target 85% → skip" test_e01

# E-02: Project-wide coverage below target — continue
test_e02() {
    local result
    result=$(_should_early_exit_coverage 0.72 0.85)
    [[ "$result" == "false" ]]
}
check "E-02: coverage 72% < target 85% → continue" test_e02

# E-02b: Exactly at target boundary — skip
test_e02b() {
    local result
    result=$(_should_early_exit_coverage 0.85 0.85)
    [[ "$result" == "true" ]]
}
check "E-02b: coverage 85% == target 85% → skip (boundary)" test_e02b

# E-03: Coverage tool not available (EC-3.1)
test_e03() {
    # _coverage_measure with a nonexistent command should fail
    local output
    output=$(_coverage_measure "nonexistent_coverage_tool_xyz" "auto" "$TEST_DIR" 2>&1) && return 1
    echo "$output" | grep -qi "coverage command failed\|not available\|error" || return 1
    return 0
}
check "E-03: coverage tool not available → error" test_e03

# ============================================================
# Revert Tests (R-01, R-02)
# ============================================================

echo ""
echo "--- Revert ---"

# R-01: Modified test file reverted via git checkout
test_r01() {
    local repo="$TEST_DIR/repo-r01"
    mkdir -p "$repo"
    cd "$repo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "original" > test_foo.py
    git add test_foo.py
    git commit -q -m "initial"

    # Record pre-untracked
    local pre_file="$TEST_DIR/pre-r01"
    git ls-files --others --exclude-standard > "$pre_file"

    # Modify tracked file
    echo "modified" > test_foo.py

    # Set PROJECT_DIR for the revert function
    PROJECT_DIR="$repo" _coverage_revert_batch "$pre_file"

    # Verify file reverted
    local content
    content=$(cat test_foo.py)
    [[ "$content" == "original" ]] || return 1
    rm -f "$pre_file"
    return 0
}
check "R-01: modified test file reverted via git checkout" test_r01

# R-02: New test file cleaned via git clean -f
test_r02() {
    local repo="$TEST_DIR/repo-r02"
    mkdir -p "$repo"
    cd "$repo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial"

    # Record pre-untracked (empty)
    local pre_file="$TEST_DIR/pre-r02"
    git ls-files --others --exclude-standard > "$pre_file"

    # Create new untracked file
    echo "new test" > test_new.py

    # Revert
    PROJECT_DIR="$repo" _coverage_revert_batch "$pre_file"

    # Verify new file removed
    [[ ! -f test_new.py ]] || return 1
    rm -f "$pre_file"
    return 0
}
check "R-02: new test file cleaned via git clean -f" test_r02

# ============================================================
# Path Traversal Tests (PT-01)
# ============================================================

echo ""
echo "--- Path Traversal ---"

# PT-01: Path traversal detected in batch files
test_pt01() {
    # The path traversal check is in execute_coverage_batch steps 2
    # Test the pattern match directly
    local f="../../../etc/passwd"
    [[ "$f" == *".."* ]]
}
check "PT-01: path traversal pattern detected" test_pt01

# ============================================================
# Prompt Builder Tests (PB-01)
# ============================================================

echo ""
echo "--- Prompt Builder ---"

# PB-01: Prompt contains required constraints
test_pb01() {
    local prompt
    prompt=$(_coverage_build_prompt '["src/foo.ts"]' '{"files":{"src/foo.ts":0.45}}')
    echo "$prompt" | grep -q "Write tests only" || return 1
    echo "$prompt" | grep -q "Do not modify source files" || return 1
    echo "$prompt" | grep -q "pragma: no cover" || return 1
    echo "$prompt" | grep -q "mock" || return 1
    echo "$prompt" | grep -q "src/foo.ts" || return 1
    echo "$prompt" | grep -q "0.45" || return 1
    return 0
}
check "PB-01: prompt contains constraints and file data" test_pb01

# ============================================================
# Needs Review Threshold Tests (N-01 through N-04)
# ============================================================

echo ""
echo "--- Needs Review Threshold ---"

# N-01: >50% failed triggers needs_review
test_n01() {
    local result
    result=$(_should_halt_coverage_pass 2 3)
    [[ "$result" == "true" ]]
}
check "N-01: 2/3 failed (67%) → halt" test_n01

# N-02: Exactly 50% does NOT trigger
test_n02() {
    local result
    result=$(_should_halt_coverage_pass 2 4)
    [[ "$result" == "false" ]]
}
check "N-02: 2/4 failed (50%) → continue" test_n02

# N-03: 1 of 1 batch failed (100%) triggers
test_n03() {
    local result
    result=$(_should_halt_coverage_pass 1 1)
    [[ "$result" == "true" ]]
}
check "N-03: 1/1 failed (100%) → halt" test_n03

# N-04: 0 of 3 failed does not trigger
test_n04() {
    local result
    result=$(_should_halt_coverage_pass 0 3)
    [[ "$result" == "false" ]]
}
check "N-04: 0/3 failed → continue" test_n04

# ============================================================
# Results
# ============================================================

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
