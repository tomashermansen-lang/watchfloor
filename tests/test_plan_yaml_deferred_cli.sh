#!/usr/bin/env bash
# test_plan_yaml_deferred_cli.sh — C.T2: CLI tests for plan_yaml_deferred dump subcommand.
#
# TC-PYD-CLI01: dump on a 2.0 plan dir emits JSON array
# TC-PYD-CLI02: dump on a dir with no plan emits []
# TC-PYD-CLI03: metacharacter in path is rejected (exit 2, stderr message) — SECURITY CRITICAL
# TC-PYD-CLI04: path outside PROJECTS_ROOT is rejected (exit 2, stderr message) — SECURITY CRITICAL
# TC-PYD-CLI05: dump on a direct .yaml file emits deferred[] entries
#
# Usage: bash tests/test_plan_yaml_deferred_cli.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYD_CLI="python3 -m claude.tools.lib.plan_yaml_deferred"
FIXTURE_MINIMAL="$REPO_DIR/tests/fixtures/plan-2.0.0/minimal.yaml"

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
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

check_output_contains() {
    local name="$1"
    local expected="$2"
    shift 2
    local output
    output="$("$@" 2>&1)" || true
    if echo "$output" | grep -qF "$expected"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name (expected: $expected, got: $output)"
        failed=$((failed + 1))
    fi
}

check_exit_code() {
    local name="$1"
    local expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [ "$actual_code" -eq "$expected_code" ]; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name (expected exit $expected_code, got $actual_code)"
        failed=$((failed + 1))
    fi
}

# Setup temp dirs
TEST_DIR="${TMPDIR:-/tmp}/pyd-cli-test-$$"
mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Create a 2.0 plan dir for testing
PLAN_DIR="$TEST_DIR/docs/INPROGRESS_Plan_test"
mkdir -p "$PLAN_DIR"
cp "$FIXTURE_MINIMAL" "$PLAN_DIR/execution-plan.yaml"

# TC-PYD-CLI01: dump on a 2.0 plan dir emits valid JSON array
echo "--- TC-PYD-CLI01: 2.0 plan dir → JSON array ---"
check "exit 0 for valid 2.0 plan dir" \
    bash -c "cd '$REPO_DIR' && $PYD_CLI dump -- '$PLAN_DIR'"

check "output is valid JSON" \
    bash -c "cd '$REPO_DIR' && $PYD_CLI dump -- '$PLAN_DIR' | python3 -c 'import json,sys; json.load(sys.stdin)'"

check "output is a JSON array" \
    bash -c "cd '$REPO_DIR' && $PYD_CLI dump -- '$PLAN_DIR' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)'"

# TC-PYD-CLI02: dump on a dir with no plan emits []
echo "--- TC-PYD-CLI02: empty dir → [] ---"
EMPTY_DIR="$TEST_DIR/empty"
mkdir -p "$EMPTY_DIR"
check "exit 0 for empty dir" \
    bash -c "cd '$REPO_DIR' && $PYD_CLI dump -- '$EMPTY_DIR'"

check "empty dir emits []" \
    bash -c "cd '$REPO_DIR' && output=\$($PYD_CLI dump -- '$EMPTY_DIR') && [ \"\$output\" = '[]' ]"

# TC-PYD-CLI03 (SECURITY CRITICAL): metacharacter path is rejected
echo "--- TC-PYD-CLI03: metacharacter rejection (security) ---"
META_ERR="$TEST_DIR/meta_err.txt"
META_EXIT=0
(cd "$REPO_DIR" && python3 -m claude.tools.lib.plan_yaml_deferred dump -- '$(echo PWNED)' 2>"$META_ERR") || META_EXIT=$?
if [ "$META_EXIT" -eq 2 ]; then
    echo -e "${GREEN}✓${NC} exit 2 for metachar path"
    passed=$((passed + 1))
else
    echo -e "${RED}✗${NC} exit 2 for metachar path (expected 2, got $META_EXIT)"
    failed=$((failed + 1))
fi

# Use a subshell to capture stderr for the metachar check
if grep -qiE "metachar|shell|security" "$META_ERR" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} stderr mentions metacharacters"
    passed=$((passed + 1))
else
    echo -e "${RED}✗${NC} stderr should mention metacharacters (got: $(cat "$META_ERR"))"
    failed=$((failed + 1))
fi

# TC-PYD-CLI04 (SECURITY CRITICAL): path outside trust boundary is rejected
echo "--- TC-PYD-CLI04: out-of-boundary path rejection (security) ---"
BOUNDARY_ERR="$TEST_DIR/boundary_err.txt"
exit_code=0
(cd "$REPO_DIR" && $PYD_CLI dump -- /etc 2>"$BOUNDARY_ERR") || exit_code=$?
if [ "$exit_code" -eq 2 ]; then
    echo -e "${GREEN}✓${NC} exit 2 for out-of-boundary path"
    passed=$((passed + 1))
else
    echo -e "${RED}✗${NC} expected exit 2 for /etc, got $exit_code"
    failed=$((failed + 1))
fi
if grep -qiE "boundary|trust|security" "$BOUNDARY_ERR" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} stderr mentions trust boundary"
    passed=$((passed + 1))
else
    echo -e "${RED}✗${NC} stderr should mention trust boundary (got: $(cat "$BOUNDARY_ERR"))"
    failed=$((failed + 1))
fi

# TC-PYD-CLI05: dump on a direct .yaml file emits deferred[] entries
echo "--- TC-PYD-CLI05: direct .yaml file ---"
DIRECT_PLAN="$PLAN_DIR/execution-plan.yaml"
check "exit 0 for direct yaml file" \
    bash -c "cd '$REPO_DIR' && $PYD_CLI dump -- '$DIRECT_PLAN'"

check "direct yaml emits JSON array" \
    bash -c "cd '$REPO_DIR' && $PYD_CLI dump -- '$DIRECT_PLAN' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)'"

echo ""
echo "Results: $passed passed, $failed failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
