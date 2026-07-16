#!/bin/bash
# test_sonar_preflight.sh — TDD tests for claude/tools/lib/sonar-preflight.sh
# Usage: bash tests/test_sonar_preflight.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/sonar-preflight.sh"

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

TEST_DIR="${TMPDIR:-/tmp}/test-sonar-preflight-$$"
setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/main" "$TEST_DIR/worktree"
}
teardown() { rm -rf "$TEST_DIR"; }
trap teardown EXIT

# ── T01: sonar_required_for returns 0 when main has properties file ──
test_t01() {
    setup
    echo "sonar.projectKey=x" > "$TEST_DIR/main/sonar-project.properties"
    (
        source "$LIB"
        sonar_required_for "$TEST_DIR/main"
    )
}
check "T01: sonar_required_for → 0 when properties file exists" test_t01

# ── T02: sonar_required_for returns non-zero when no properties file ──
test_t02() {
    setup
    (
        source "$LIB"
        ! sonar_required_for "$TEST_DIR/main"
    )
}
check "T02: sonar_required_for → non-zero when no properties file" test_t02

# ── T03: sonar_copy_properties copies from main → worktree ──────────
test_t03() {
    setup
    echo "key=value" > "$TEST_DIR/main/sonar-project.properties"
    (
        source "$LIB"
        sonar_copy_properties "$TEST_DIR/main" "$TEST_DIR/worktree"
    )
    [[ -f "$TEST_DIR/worktree/sonar-project.properties" ]] && \
        [[ "$(cat "$TEST_DIR/worktree/sonar-project.properties")" == "key=value" ]]
}
check "T03: sonar_copy_properties copies main → worktree" test_t03

# ── T04: sonar_copy_properties is no-op when worktree already has file ──
test_t04() {
    setup
    echo "main=value" > "$TEST_DIR/main/sonar-project.properties"
    echo "worktree=existing" > "$TEST_DIR/worktree/sonar-project.properties"
    (
        source "$LIB"
        sonar_copy_properties "$TEST_DIR/main" "$TEST_DIR/worktree" || true
    )
    # Worktree file should be unchanged
    [[ "$(cat "$TEST_DIR/worktree/sonar-project.properties")" == "worktree=existing" ]]
}
check "T04: sonar_copy_properties preserves existing worktree file" test_t04

# ── T05: sonar_preflight returns 0 when project doesn't use Sonar ──
test_t05() {
    setup
    # No sonar-project.properties in main
    (
        source "$LIB"
        # Override potentially-slow functions to fail tests if reached
        sonar_reachable() { echo "should not be called" >&2; return 99; }
        sonar_preflight "$TEST_DIR/main" "$TEST_DIR/worktree" >/dev/null 2>&1
    )
}
check "T05: sonar_preflight → 0 when project has no properties file" test_t05

# ── T06: sonar_preflight returns 0 when Sonar already reachable ──
test_t06() {
    setup
    echo "x" > "$TEST_DIR/main/sonar-project.properties"
    (
        source "$LIB"
        sonar_reachable() { return 0; }  # mock as already up
        sonar_start() { echo "should not be called" >&2; return 99; }
        sonar_preflight "$TEST_DIR/main" "$TEST_DIR/worktree" >/dev/null 2>&1
    )
    # Should have copied properties to worktree
    [[ -f "$TEST_DIR/worktree/sonar-project.properties" ]]
}
check "T06: sonar_preflight → 0 when Sonar already up; copies properties" test_t06

# ── T07: sonar_preflight auto-starts then succeeds ──────────────────
test_t07() {
    setup
    echo "x" > "$TEST_DIR/main/sonar-project.properties"
    (
        source "$LIB"
        sonar_reachable() { return 1; }
        sonar_start() { return 0; }
        sonar_wait_ready() { return 0; }
        sonar_preflight "$TEST_DIR/main" "$TEST_DIR/worktree" >/dev/null 2>&1
    )
}
check "T07: sonar_preflight → 0 after successful auto-start" test_t07

# ── T08: sonar_preflight fails when Sonar won't start ───────────────
test_t08() {
    setup
    echo "x" > "$TEST_DIR/main/sonar-project.properties"
    (
        source "$LIB"
        sonar_reachable() { return 1; }
        sonar_start() { return 1; }  # docker-compose missing or failed
        ! sonar_preflight "$TEST_DIR/main" "$TEST_DIR/worktree" >/dev/null 2>&1
    )
}
check "T08: sonar_preflight → non-zero when start fails" test_t08

# ── T09: sonar_preflight fails when Sonar starts but never becomes ready ──
test_t09() {
    setup
    echo "x" > "$TEST_DIR/main/sonar-project.properties"
    (
        source "$LIB"
        sonar_reachable() { return 1; }
        sonar_start() { return 0; }
        sonar_wait_ready() { return 1; }  # timeout
        ! sonar_preflight "$TEST_DIR/main" "$TEST_DIR/worktree" >/dev/null 2>&1
    )
}
check "T09: sonar_preflight → non-zero when wait_ready times out" test_t09

# ── T10: SONAR_URL is configurable via environment ──────────────────
test_t10() {
    (
        SONAR_URL="http://custom:9999"
        source "$LIB"
        [[ "$SONAR_URL" == "http://custom:9999" ]]
    )
}
check "T10: SONAR_URL honors pre-set env var" test_t10

# ── T11: sonar_export_user_home redirects SONAR_USER_HOME to workdir ──
# Closes env-gap-sonar-userhome-sandbox-deny: macOS Seatbelt sandbox
# blocks writes to ~/.sonar/_tmp; redirect to a sandbox-writable path
# inside the worktree.
test_t11() {
    setup
    (
        unset SONAR_USER_HOME
        source "$LIB"
        sonar_export_user_home "$TEST_DIR/worktree"
        [[ -n "$SONAR_USER_HOME" ]] && \
            [[ "$SONAR_USER_HOME" == "$TEST_DIR/worktree/.sonar" ]] && \
            [[ -d "$SONAR_USER_HOME" ]]
    )
}
check "T11: sonar_export_user_home sets SONAR_USER_HOME to <workdir>/.sonar and mkdir -p" test_t11

# ── T12: sonar_export_user_home preserves operator-set SONAR_USER_HOME ──
# If the operator deliberately overrode SONAR_USER_HOME (e.g. for a CI
# cache mount), preflight must not clobber it.
test_t12() {
    setup
    (
        export SONAR_USER_HOME="$TEST_DIR/custom-sonar-cache"
        source "$LIB"
        sonar_export_user_home "$TEST_DIR/worktree"
        [[ "$SONAR_USER_HOME" == "$TEST_DIR/custom-sonar-cache" ]] && \
            [[ -d "$SONAR_USER_HOME" ]]
    )
}
check "T12: sonar_export_user_home preserves operator-set SONAR_USER_HOME" test_t12

# ── T13: sonar_preflight calls sonar_export_user_home when sonar reachable ──
test_t13() {
    setup
    echo "x" > "$TEST_DIR/main/sonar-project.properties"
    (
        unset SONAR_USER_HOME
        source "$LIB"
        sonar_reachable() { return 0; }
        sonar_preflight "$TEST_DIR/main" "$TEST_DIR/worktree" >/dev/null 2>&1
        [[ "$SONAR_USER_HOME" == "$TEST_DIR/worktree/.sonar" ]] && \
            [[ -d "$SONAR_USER_HOME" ]]
    )
}
check "T13: sonar_preflight exports SONAR_USER_HOME after reachable check" test_t13

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
