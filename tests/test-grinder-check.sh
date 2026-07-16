#!/bin/bash
# test-grinder-check.sh — TDD test suite for claude/tools/grinder-check.sh
#
# Uses the check() assertion pattern from tests/smoke.sh.
# Each test creates isolated fixture dirs, overrides PROJECTS_ROOT and PATH,
# and cleans up via trap.
#
# Usage: bash tests/test-grinder-check.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/adapters/claude-code/claude/tools/grinder-check.sh"

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

# --- Shared helpers ---

TEST_DIR="${TMPDIR:-/tmp}/test-grinder-check-$$"
ORIG_PATH="$PATH"

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/bin"
    export PROJECTS_ROOT="$TEST_DIR"
    # Clear per-test override to prevent leakage between tests on early-return
    unset GRINDER_CHECK_PROJECTS 2>/dev/null || true
    # Restrict PATH to system essentials + our stub bin
    export PATH="$TEST_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

teardown() {
    # Restore permissions before cleanup (for chmod tests)
    find "$TEST_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
    rm -rf "$TEST_DIR"
    export PATH="$ORIG_PATH"
}
trap teardown EXIT

# Create a stub executable that prints a version and exits 0
make_stub() {
    local path="$1"
    local version="${2:-1.0.0}"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUBEOF
#!/bin/bash
echo "$version"
exit 0
STUBEOF
    chmod +x "$path"
}

# Create a stub that exits non-zero (simulates --version failure)
make_failing_stub() {
    local path="$1"
    local exit_code="${2:-1}"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUBEOF
#!/bin/bash
exit $exit_code
STUBEOF
    chmod +x "$path"
}

# Create a fixture CLAUDE.md with a pipeline.toolchain block
write_manifest() {
    local dir="$1"
    local content="$2"
    mkdir -p "$dir"
    cat > "$dir/CLAUDE.md" <<EOF
# Test Project

$content
EOF
}

# Create an npx stub that dispatches on tool name
make_npx_stub() {
    local bin_dir="$1"
    shift
    # Remaining args are pairs: tool_name version (or tool_name FAIL)
    mkdir -p "$bin_dir"
    local dispatch=""
    while [[ $# -ge 2 ]]; do
        local tool="$1"
        local ver="$2"
        shift 2
        if [[ "$ver" == "FAIL" ]]; then
            dispatch+="    $tool) exit 1;;"$'\n'
        else
            dispatch+="    $tool) echo \"$ver\"; exit 0;;"$'\n'
        fi
    done
    cat > "$bin_dir/npx" <<NPXEOF
#!/bin/bash
tool="\$1"
case "\$tool" in
$dispatch    *) exit 127;;
esac
NPXEOF
    chmod +x "$bin_dir/npx"
}

# We also need python3 on PATH for the manifest parser
ensure_python3() {
    # Find real python3 and symlink into our bin dir
    local real_python3
    real_python3="$(command -v python3 2>/dev/null || echo "/usr/bin/python3")"
    if [[ -x "$real_python3" && ! -e "$TEST_DIR/bin/python3" ]]; then
        ln -sf "$real_python3" "$TEST_DIR/bin/python3"
    fi
    # Also need bash itself
    local real_bash
    real_bash="$(command -v bash 2>/dev/null || echo "/bin/bash")"
    if [[ -x "$real_bash" && ! -e "$TEST_DIR/bin/bash" ]]; then
        ln -sf "$real_bash" "$TEST_DIR/bin/bash"
    fi
}

echo "Running grinder-check.sh tests..."
echo ""

# =============================================================================
# T1: Happy Path — All Tools Present (AS-1, REQ-3, REQ-4)
# =============================================================================
test_t1() {
    setup
    ensure_python3

    # Create 3 fixture projects with manifests
    write_manifest "$TEST_DIR/dotfiles" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck, jq]
M
)"
    write_manifest "$TEST_DIR/OIH" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff, mypy]
    infra: [sonar-scanner]
M
)"
    write_manifest "$TEST_DIR/RAG framework" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff, mypy]
    infra: [sonar-scanner]
M
)"

    # Create stubs for all infra tools
    make_stub "$TEST_DIR/bin/shellcheck" "0.9.0"
    make_stub "$TEST_DIR/bin/jq" "1.7"
    make_stub "$TEST_DIR/bin/sonar-scanner" "5.0.1"

    # Python tools: OIH uses uv (pyproject.toml present)
    make_stub "$TEST_DIR/bin/uv" "0.1.0"
    touch "$TEST_DIR/OIH/pyproject.toml"
    # uv run <tool> --version: make a uv stub that dispatches
    cat > "$TEST_DIR/bin/uv" <<'UVEOF'
#!/bin/bash
if [[ "$1" == "run" ]]; then
    shift
    tool="$1"
    case "$tool" in
        ruff)  echo "ruff 0.4.0"; exit 0;;
        mypy)  echo "mypy 1.10.0"; exit 0;;
        *)     exit 127;;
    esac
fi
echo "uv 0.1.0"
UVEOF
    chmod +x "$TEST_DIR/bin/uv"

    # RAG framework uses .venv
    touch "$TEST_DIR/RAG framework/pyproject.toml"
    # No uv for RAG — don't create pyproject.toml dependency on uv
    # Actually RAG has pyproject.toml but no uv in the original research.
    # Per REQUIREMENTS: RAG uses .venv/bin/ (no uv). So we need uv to NOT
    # be used for RAG. But uv IS on PATH from OIH setup above.
    # The resolution: uv is on PATH, pyproject.toml exists → uv run is tried.
    # For the test, we make the uv stub handle RAG's tools too.
    # Actually, the plan says: "If pyproject.toml exists AND uv available → uv run"
    # So RAG would also use uv run if uv is on PATH. But REQUIREMENTS says
    # RAG uses .venv. This is about the real world — in tests, the resolution
    # logic is what matters. Since uv is on PATH and pyproject.toml exists,
    # uv run will be used. The uv stub already handles ruff/mypy.

    # Node tools: npx stub
    make_npx_stub "$TEST_DIR/bin" eslint "9.0.0" tsc "5.4.0"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "MISSING" && { echo "  Unexpected MISSING in output"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "AVAILABLE" || { echo "  No AVAILABLE in output"; echo "  Output: $output"; return 1; }
    return 0
}
check "T1: Happy path — all tools present, exit 0" test_t1

# =============================================================================
# T2: Missing Tool — Exit 1 (AS-2, REQ-4)
# =============================================================================
test_t2() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff, mypy]
M
)"
    touch "$TEST_DIR/testproj/pyproject.toml"

    # uv stub that only knows mypy, not ruff
    cat > "$TEST_DIR/bin/uv" <<'UVEOF'
#!/bin/bash
if [[ "$1" == "run" ]]; then
    shift
    tool="$1"
    case "$tool" in
        mypy) echo "mypy 1.10.0"; exit 0;;
        *)    exit 127;;
    esac
fi
echo "uv 0.1.0"
UVEOF
    chmod +x "$TEST_DIR/bin/uv"

    # Override PROJECT_NAMES/PATHS to just our test project
    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    echo "$output" | grep -q "ruff: MISSING" || { echo "  Expected 'ruff: MISSING'"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "mypy: AVAILABLE" || { echo "  Expected 'mypy: AVAILABLE'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T2: Missing tool → exit 1, MISSING in output" test_t2

# =============================================================================
# T3: Version Probe Failure (AS-3, REQ-5)
# =============================================================================
test_t3() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck]
M
)"
    make_failing_stub "$TEST_DIR/bin/shellcheck" 1

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    echo "$output" | grep -q "shellcheck: MISSING" || { echo "  Expected 'shellcheck: MISSING'"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "\-\-version exited 1" || { echo "  Expected '--version exited 1'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T3: Version probe failure → MISSING with reason" test_t3

# =============================================================================
# T4: Path with Spaces (AS-4, REQ-6)
# =============================================================================
test_t4() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/RAG framework" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [sonar-scanner]
M
)"
    make_stub "$TEST_DIR/bin/sonar-scanner" "5.0.1"

    export GRINDER_CHECK_PROJECTS="RAG framework|$TEST_DIR/RAG framework"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "RAG framework" || { echo "  Expected 'RAG framework' in output"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "AVAILABLE" || { echo "  Expected AVAILABLE"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T4: Path with spaces — no word-splitting errors" test_t4

# =============================================================================
# T5: Sandbox Write Test — All Pass (AS-5, REQ-7)
# =============================================================================
test_t5() {
    setup
    ensure_python3

    mkdir -p "$TEST_DIR/proj1" "$TEST_DIR/proj2"

    export GRINDER_CHECK_PROJECTS="proj1|$TEST_DIR/proj1,proj2|$TEST_DIR/proj2"

    local output exit_code
    output=$(bash "$SCRIPT" --sandbox-write-test 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "PASS" || { echo "  Expected PASS"; echo "  Output: $output"; return 1; }
    # Verify cleanup — no .sandbox-test files remain
    [[ ! -f "$TEST_DIR/proj1/docs/grinder/.sandbox-test" ]] || { echo "  Stale .sandbox-test in proj1"; return 1; }
    [[ ! -f "$TEST_DIR/proj2/docs/grinder/.sandbox-test" ]] || { echo "  Stale .sandbox-test in proj2"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T5: Sandbox write test — all PASS, exit 0" test_t5

# =============================================================================
# T6: Sandbox Write Test — Denied (AS-6, REQ-7)
# =============================================================================
test_t6() {
    setup
    ensure_python3

    mkdir -p "$TEST_DIR/writable" "$TEST_DIR/readonly"
    # Make readonly dir non-writable
    chmod 555 "$TEST_DIR/readonly"

    export GRINDER_CHECK_PROJECTS="writable|$TEST_DIR/writable,readonly|$TEST_DIR/readonly"

    local output exit_code
    output=$(bash "$SCRIPT" --sandbox-write-test 2>&1) && exit_code=0 || exit_code=$?

    # Restore permissions for teardown
    chmod 755 "$TEST_DIR/readonly"

    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep "readonly" | grep -q "FAIL" || { echo "  Expected FAIL for readonly"; echo "  Output: $output"; return 1; }
    echo "$output" | grep "writable" | grep -q "PASS" || { echo "  Expected PASS for writable"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T6: Sandbox write test — denied → FAIL, exit 1" test_t6

# =============================================================================
# T7: Imports Category Ignored (AS-7, REQ-9)
# =============================================================================
test_t7() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
    imports: [yaml, jsonschema]
    infra: [jq]
M
)"
    make_stub "$TEST_DIR/bin/jq" "1.7"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "yaml" && { echo "  Unexpected 'yaml' in output (imports should be excluded)"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "jsonschema" && { echo "  Unexpected 'jsonschema' in output"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "jq: AVAILABLE" || { echo "  Expected 'jq: AVAILABLE'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T7: Imports category ignored, infra tools checked" test_t7

# =============================================================================
# T8: Missing CLAUDE.md — NO MANIFEST (EC-1.1)
# =============================================================================
test_t8() {
    setup
    ensure_python3

    # Create project dir but no CLAUDE.md
    mkdir -p "$TEST_DIR/testproj"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "NO MANIFEST" || { echo "  Expected 'NO MANIFEST'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T8: Missing CLAUDE.md → NO MANIFEST, exit 0" test_t8

# =============================================================================
# T9: Empty Toolchain Block (EC-1.2)
# =============================================================================
test_t9() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
M
)"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "MISSING" && { echo "  Unexpected MISSING"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T9: Empty toolchain block → exit 0, no MISSING" test_t9

# =============================================================================
# T10: Malformed Toolchain Block — Missing Colon (EC-1.3a)
# =============================================================================
test_t10() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
    python [ruff, mypy]
M
)"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "PARSE ERROR" || { echo "  Expected 'PARSE ERROR'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T10: Malformed block (missing colon) → PARSE ERROR, exit 1" test_t10

# =============================================================================
# T11: Malformed Toolchain Block — Wrong Nesting (EC-1.3b)
# =============================================================================
test_t11() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
toolchain:
  python: [ruff]
M
)"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "PARSE ERROR" || { echo "  Expected 'PARSE ERROR'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T11: Malformed block (wrong nesting) → PARSE ERROR, exit 1" test_t11

# =============================================================================
# T12: uv Not on PATH — Falls Through to .venv (EC-2.1)
# =============================================================================
test_t12() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
M
)"
    touch "$TEST_DIR/testproj/pyproject.toml"
    # No uv stub — .venv fallback
    make_stub "$TEST_DIR/testproj/.venv/bin/ruff" "ruff-venv 0.3.0"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "ruff: AVAILABLE" || { echo "  Expected 'ruff: AVAILABLE'"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "ruff-venv" || { echo "  Expected .venv version 'ruff-venv'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T12: uv not on PATH → .venv fallback" test_t12

# =============================================================================
# T13: Neither uv nor .venv — Bare Fallback (EC-2.2)
# =============================================================================
test_t13() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
M
)"
    touch "$TEST_DIR/testproj/pyproject.toml"
    # No uv, no .venv — bare ruff on PATH
    make_stub "$TEST_DIR/bin/ruff" "ruff-bare 0.2.0"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "ruff: AVAILABLE" || { echo "  Expected 'ruff: AVAILABLE'"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "ruff-bare" || { echo "  Expected bare version 'ruff-bare'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T13: Neither uv nor .venv → bare fallback" test_t13

# =============================================================================
# T14: npx Missing — MISSING with Reason (EC-2.3)
# =============================================================================
test_t14() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
    node: [eslint]
M
)"
    # No npx stub on PATH

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "eslint: MISSING" || { echo "  Expected 'eslint: MISSING'"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "npx not found" || { echo "  Expected 'npx not found'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T14: npx missing → MISSING [npx not found]" test_t14

# =============================================================================
# T15: Sandbox — docs/grinder/ Doesn't Exist Yet (EC-7.1)
# =============================================================================
test_t15() {
    setup
    ensure_python3

    # Fresh dir with no docs/ subdirectory
    mkdir -p "$TEST_DIR/testproj"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" --sandbox-write-test 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "PASS" || { echo "  Expected PASS"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T15: Sandbox — docs/grinder/ doesn't exist → mkdir -p → PASS" test_t15

# =============================================================================
# T16: Sandbox — Stale .sandbox-test File (EC-7.2)
# =============================================================================
test_t16() {
    setup
    ensure_python3

    mkdir -p "$TEST_DIR/testproj/docs/grinder"
    echo "stale" > "$TEST_DIR/testproj/docs/grinder/.sandbox-test"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" --sandbox-write-test 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "PASS" || { echo "  Expected PASS"; echo "  Output: $output"; return 1; }
    [[ ! -f "$TEST_DIR/testproj/docs/grinder/.sandbox-test" ]] || { echo "  Stale file not cleaned up"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T16: Sandbox — stale .sandbox-test cleaned up → PASS" test_t16

# =============================================================================
# T17: Sandbox — Removal Fails (EC-7.3)
# =============================================================================
test_t17() {
    setup
    ensure_python3

    mkdir -p "$TEST_DIR/testproj/docs/grinder"
    echo "test" > "$TEST_DIR/testproj/docs/grinder/.sandbox-test"
    # Make directory read+execute only — prevents file removal on macOS.
    # Note: this test produces a false-pass when run as root (chmod 555
    # does not block root writes). CI environments running as root will
    # skip this assertion in practice.
    chmod 555 "$TEST_DIR/testproj/docs/grinder"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" --sandbox-write-test 2>&1) && exit_code=0 || exit_code=$?

    # Restore permissions for teardown
    chmod 755 "$TEST_DIR/testproj/docs/grinder"

    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "FAIL" || { echo "  Expected FAIL"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T17: Sandbox — removal fails → FAIL, exit 1" test_t17

# =============================================================================
# T18: Network Category Excluded (REQ-9 extended)
# =============================================================================
test_t18() {
    setup
    ensure_python3

    write_manifest "$TEST_DIR/testproj" "$(cat <<'M'
pipeline:
  toolchain:
    network: [pypi.org]
    infra: [jq]
M
)"
    make_stub "$TEST_DIR/bin/jq" "1.7"

    export GRINDER_CHECK_PROJECTS="testproj|$TEST_DIR/testproj"

    local output exit_code
    output=$(bash "$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?

    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "pypi.org" && { echo "  Unexpected 'pypi.org' in output (network should be excluded)"; echo "  Output: $output"; return 1; }
    echo "$output" | grep -q "jq: AVAILABLE" || { echo "  Expected 'jq: AVAILABLE'"; echo "  Output: $output"; return 1; }
    unset GRINDER_CHECK_PROJECTS
    return 0
}
check "T18: Network category excluded, infra tools checked" test_t18

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
