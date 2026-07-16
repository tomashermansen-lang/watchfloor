#!/bin/bash
# test_grinder_mechanical.sh — Bash integration tests for grinder-mechanical.sh
#
# Tests: C1-C8 (resolve_test_command, run_tests_for_project,
# resolve_mechanical_tools, build_mechanical_prompt, run_mechanical_tools,
# rerun_scanner, execute_mechanical_batch, process_batch enrichment)
#
# Usage: bash tests/test_grinder_mechanical.sh
# Exits with the number of failures (0 = all pass).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_DIR/tests/fixtures/grinder-mechanical"
GRINDER="$REPO_DIR/adapters/claude-code/claude/tools/grinder.sh"
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
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

# --- Shared helpers ---

TEST_DIR="${TMPDIR:-/tmp}/test-grinder-mechanical-$$"
mkdir -p "$TEST_DIR"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

setup_test_dir() {
    local dir
    dir=$(mktemp -d "$TEST_DIR/tmp.XXXXXX")
    echo "$dir"
}

setup_git_repo() {
    local dir
    dir=$(setup_test_dir)
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial commit"
    echo "$dir"
}

# Source mechanical lib in isolation (need grinder-discover.sh too)
source_mechanical_lib() {
    local project_dir="${1:-.}"
    # Set required globals
    export TOOLS_DIR="$REPO_DIR/adapters/claude-code/claude/tools"
    export LIB_DIR="$TOOLS_DIR/lib"
    export SCHEMA_DIR="$REPO_DIR/schema"
    export PROJECT_DIR="$project_dir"
    export GRINDER_DIR="${2:-$project_dir/docs/grinder}"

    # Source dependencies
    source "$LIB_DIR/grinder-discover.sh"
    source "$LIB_DIR/grinder-mechanical.sh"
}

echo "Running grinder-mechanical.sh integration tests..."
echo ""

# =============================================================================
# Group 1: Test Command Resolution (C1)
# =============================================================================

# M1-01: Python project with pyproject.toml + uv
test_m1_01() {
    local dir
    dir=$(setup_test_dir)
    cp -r "$FIXTURES/fixture-python/"* "$dir/"

    # Mock uv
    mkdir -p "$dir/bin"
    printf '#!/bin/bash\nexit 0\n' > "$dir/bin/uv"
    chmod +x "$dir/bin/uv"

    local output
    output=$(
        PATH="$dir/bin:$PATH" \
        GRINDER_TEST_CMD_RESOLVED="" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            resolve_test_command
        ' 2>/dev/null
    )
    [[ "$output" == *"uv run python3 -m pytest tests/ -q"* ]] || return 1
    return 0
}
check "M1-01: Python project with pyproject.toml + uv" test_m1_01

# M1-02: Bash project with test/*.sh files
test_m1_02() {
    local dir
    dir=$(setup_test_dir)
    cp -r "$FIXTURES/fixture-bash/"* "$dir/"

    local output
    output=$(
        GRINDER_TEST_CMD_RESOLVED="" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            resolve_test_command
        ' 2>/dev/null
    )
    [[ "$output" == *"test_basic.sh"* ]] || return 1
    return 0
}
check "M1-02: Bash project with test/*.sh files" test_m1_02

# M1-03: No test suite available
test_m1_03() {
    local dir
    dir=$(setup_test_dir)
    cp -r "$FIXTURES/fixture-no-tests/"* "$dir/"

    local combined
    combined=$(
        GRINDER_TEST_CMD_RESOLVED="" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            resolve_test_command
        ' 2>&1
    )
    local stdout
    stdout=$(echo "$combined" | grep -v "mechanical:" || true)
    [[ -z "$stdout" || "$stdout" =~ ^[[:space:]]*$ ]] || return 1
    echo "$combined" | grep -q "no test command resolved" || return 1
    return 0
}
check "M1-03: No test suite available" test_m1_03

# M1-04: Caching — second call returns cached value
test_m1_04() {
    local output
    output=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="/nonexistent"
            GRINDER_TEST_CMD_RESOLVED=true
            GRINDER_TEST_CMD="cached-cmd"
            resolve_test_command
        ' 2>/dev/null
    )
    [[ "$output" == "cached-cmd" ]] || return 1
    return 0
}
check "M1-04: Caching — second call returns cached value" test_m1_04

# M1-05: package.json + vitest detection
test_m1_05() {
    local dir
    dir=$(setup_test_dir)
    echo '{"name":"test"}' > "$dir/package.json"
    mkdir -p "$dir/node_modules/.bin"
    printf '#!/bin/bash\nexit 0\n' > "$dir/node_modules/.bin/vitest"
    chmod +x "$dir/node_modules/.bin/vitest"

    local output
    output=$(
        GRINDER_TEST_CMD_RESOLVED="" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            resolve_test_command
        ' 2>/dev/null
    )
    [[ "$output" == *"npx vitest run"* ]] || return 1
    return 0
}
check "M1-05: package.json + vitest detection" test_m1_05

# M1-06: package.json + jest detection (vitest absent)
test_m1_06() {
    local dir
    dir=$(setup_test_dir)
    echo '{"name":"test"}' > "$dir/package.json"
    mkdir -p "$dir/node_modules/.bin"
    printf '#!/bin/bash\nexit 0\n' > "$dir/node_modules/.bin/jest"
    chmod +x "$dir/node_modules/.bin/jest"

    local output
    output=$(
        GRINDER_TEST_CMD_RESOLVED="" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            resolve_test_command
        ' 2>/dev/null
    )
    [[ "$output" == *"npx jest"* ]] || return 1
    return 0
}
check "M1-06: package.json + jest detection (vitest absent)" test_m1_06

# =============================================================================
# Group 2: Test Execution Wrapper (C2)
# =============================================================================

# M2-01: Passing tests return exit 0
test_m2_01() {
    local dir
    dir=$(setup_test_dir)
    printf '#!/bin/bash\nexit 0\n' > "$dir/pass.sh"
    chmod +x "$dir/pass.sh"

    local rc=0
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="'"$dir"'"
        GRINDER_TEST_CMD="bash '"$dir/pass.sh"'"
        run_tests_for_project
    ' 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] || return 1
    return 0
}
check "M2-01: Passing tests return exit 0" test_m2_01

# M2-02: Failing tests return exit 1
test_m2_02() {
    local dir
    dir=$(setup_test_dir)
    printf '#!/bin/bash\nexit 1\n' > "$dir/fail.sh"
    chmod +x "$dir/fail.sh"

    local rc=0
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="'"$dir"'"
        GRINDER_TEST_CMD="bash '"$dir/fail.sh"'"
        run_tests_for_project
    ' 2>/dev/null || rc=$?
    [[ $rc -ne 0 ]] || return 1
    return 0
}
check "M2-02: Failing tests return exit 1" test_m2_02

# M2-03: Timeout after 300s (simulated via exit 124)
test_m2_03() {
    local dir
    dir=$(setup_test_dir)

    # Mock timeout that always returns 124
    mkdir -p "$dir/bin"
    printf '#!/bin/bash\nexit 124\n' > "$dir/bin/timeout"
    chmod +x "$dir/bin/timeout"

    local combined
    local rc=0
    combined=$(
        PATH="$dir/bin:$PATH" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            GRINDER_TEST_CMD="sleep 600"
            run_tests_for_project
        ' 2>&1
    ) || rc=$?
    [[ $rc -ne 0 ]] || return 1
    echo "$combined" | grep -q "timed out after 300s" || return 1
    return 0
}
check "M2-03: Timeout after 300s (EC-3.1)" test_m2_03

# M2-04: Empty test command returns 0
test_m2_04() {
    local rc=0
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="/tmp"
        GRINDER_TEST_CMD=""
        run_tests_for_project
    ' 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] || return 1
    return 0
}
check "M2-04: Empty test command returns 0" test_m2_04

# M2-05: Missing test runner binary (EC-3.2)
test_m2_05() {
    local combined
    local rc=0
    combined=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="/tmp"
            GRINDER_TEST_CMD="nonexistent-test-binary-xyz"
            run_tests_for_project
        ' 2>&1
    ) || rc=$?
    [[ $rc -eq 0 ]] || return 1
    echo "$combined" | grep -q "test runner binary missing" || return 1
    return 0
}
check "M2-05: Missing test runner binary (EC-3.2)" test_m2_05

# M2-06: No timeout binary available
test_m2_06() {
    local dir
    dir=$(setup_test_dir)
    printf '#!/bin/bash\nexit 0\n' > "$dir/pass.sh"
    chmod +x "$dir/pass.sh"

    # Create a restricted PATH without timeout or gtimeout
    local python3_path
    python3_path=$(command -v python3)
    local python3_dir
    python3_dir=$(dirname "$python3_path")

    local combined
    local rc=0
    combined=$(
        PATH="$python3_dir:/usr/bin:/bin" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            GRINDER_TEST_CMD="bash '"$dir/pass.sh"'"
            run_tests_for_project
        ' 2>&1
    ) || rc=$?
    [[ $rc -eq 0 ]] || return 1
    echo "$combined" | grep -q "no timeout command available" || return 1
    return 0
}
check "M2-06: No timeout binary — runs without timeout" test_m2_06

# =============================================================================
# Group 3: Tool Dispatch (C3)
# =============================================================================

# M3-01: Mechanical pass resolves shellcheck from plan
test_m3_01() {
    local dir
    dir=$(setup_test_dir)
    mkdir -p "$dir/docs/grinder"
    # Create plan with shellcheck scanner
    cat > "$dir/docs/grinder/grinder-plan.yaml" << 'YAML'
passes:
- id: pass-mechanical
  kind: mechanical
  batches:
  - id: batch-001
    files: [scripts/deploy.sh]
    estimated_turns: 3
    status: pending
YAML

    # Mock shellcheck in PATH
    mkdir -p "$dir/bin"
    printf '#!/bin/bash\nexit 0\n' > "$dir/bin/shellcheck"
    chmod +x "$dir/bin/shellcheck"

    local output
    output=$(
        PATH="$dir/bin:$PATH" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            GRINDER_DIR="'"$dir/docs/grinder"'"
            resolve_mechanical_tools "pass-mechanical"
        ' 2>/dev/null
    )
    [[ "$output" == *"shellcheck"* ]] || return 1
    return 0
}
check "M3-01: Mechanical pass resolves shellcheck from plan" test_m3_01

# M3-02: Mechanical pass resolves ruff from plan
test_m3_02() {
    local dir
    dir=$(setup_test_dir)
    mkdir -p "$dir/docs/grinder"
    cat > "$dir/docs/grinder/grinder-plan.yaml" << 'YAML'
passes:
- id: pass-mechanical
  kind: mechanical
  batches:
  - id: batch-001
    files: [src/app.py]
    estimated_turns: 3
    status: pending
YAML

    # Mock ruff
    mkdir -p "$dir/bin"
    printf '#!/bin/bash\nexit 0\n' > "$dir/bin/ruff"
    chmod +x "$dir/bin/ruff"

    local output
    output=$(
        PATH="$dir/bin:$PATH" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            GRINDER_DIR="'"$dir/docs/grinder"'"
            resolve_mechanical_tools "pass-mechanical"
        ' 2>/dev/null
    )
    [[ "$output" == *"ruff"* ]] || return 1
    return 0
}
check "M3-02: Mechanical pass resolves ruff from plan" test_m3_02

# M3-03: Unavailable scanner is omitted with warning
test_m3_03() {
    local dir
    dir=$(setup_test_dir)
    mkdir -p "$dir/docs/grinder"
    cat > "$dir/docs/grinder/grinder-plan.yaml" << 'YAML'
passes:
- id: pass-mechanical
  kind: mechanical
  batches:
  - id: batch-001
    files: [src/app.js]
    estimated_turns: 3
    status: pending
YAML

    # Ensure eslint is NOT in PATH (but keep python3 available)
    local python3_path
    python3_path=$(command -v python3)
    local python3_dir
    python3_dir=$(dirname "$python3_path")

    local combined
    combined=$(
        PATH="$python3_dir:/usr/bin:/bin" \
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            GRINDER_DIR="'"$dir/docs/grinder"'"
            resolve_mechanical_tools "pass-mechanical"
        ' 2>&1
    )
    # Output should NOT contain eslint (it's unavailable)
    local stdout_only
    stdout_only=$(echo "$combined" | grep -v "mechanical:" || true)
    [[ "$stdout_only" != *"eslint"* ]] || return 1
    # Stderr should have warning
    echo "$combined" | grep -q "not available" || return 1
    return 0
}
check "M3-03: Unavailable scanner omitted with warning" test_m3_03

# =============================================================================
# Group 4: Prompt Template Builder (C4)
# =============================================================================

# M4-01: Auto-fix tool prompt contains constraints
test_m4_01() {
    local dir
    dir=$(setup_test_dir)

    local output
    output=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            build_mechanical_prompt "ruff" "src/app.py"
        ' 2>/dev/null
    )
    [[ "$output" == *"deterministic auto-fixes"* ]] || { echo "missing objective"; return 1; }
    [[ "$output" == *"noqa"* ]] || { echo "missing noqa constraint"; return 1; }
    [[ "$output" == *"Do not modify files outside"* ]] || { echo "missing scope constraint"; return 1; }
    return 0
}
check "M4-01: Auto-fix tool prompt contains constraints" test_m4_01

# M4-02: Shellcheck propose-only prompt embeds findings JSON
test_m4_02() {
    local dir
    dir=$(setup_test_dir)
    mkdir -p "$dir/docs/grinder/scanner-output"
    cp "$FIXTURES/shellcheck-findings.json" "$dir/docs/grinder/scanner-output/shellcheck.json"

    local output
    output=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            GRINDER_DIR="'"$dir/docs/grinder"'"

            # Override discover_run_scanner to return fixture JSON
            discover_run_scanner() { cat "'"$FIXTURES/shellcheck-findings.json"'"; }
            build_mechanical_prompt "shellcheck" "scripts/deploy.sh"
        ' 2>/dev/null
    )
    [[ "$output" == *"shellcheck findings must be fixed"* ]] || { echo "missing header"; return 1; }
    [[ "$output" == *"2086"* ]] || { echo "missing finding code"; return 1; }
    return 0
}
check "M4-02: Shellcheck propose-only prompt embeds findings JSON" test_m4_02

# M4-03: Invalid shellcheck JSON is handled gracefully
test_m4_03() {
    local dir
    dir=$(setup_test_dir)

    local combined
    combined=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"
            GRINDER_DIR="'"$dir"'"

            # Override to return invalid JSON
            discover_run_scanner() { echo "NOT VALID JSON {{"; }
            build_mechanical_prompt "shellcheck" "scripts/deploy.sh"
        ' 2>&1
    )
    echo "$combined" | grep -q "not valid JSON" || return 1
    # Still contains base constraints
    echo "$combined" | grep -q "deterministic" || return 1
    return 0
}
check "M4-03: Invalid shellcheck JSON handled gracefully" test_m4_03

# M4-04: Ruff prompt includes verify/cleanup instruction
test_m4_04() {
    local output
    output=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="/tmp"
            build_mechanical_prompt "ruff" "src/app.py"
        ' 2>/dev/null
    )
    [[ "$output" == *"erify"* || "$output" == *"verify"* ]] || return 1
    return 0
}
check "M4-04: Ruff prompt includes verify instruction" test_m4_04

# =============================================================================
# Group 5: Direct Auto-Fix Execution (C5)
# =============================================================================

# M5-01: Ruff --fix and ruff format are called on batch files
test_m5_01() {
    local dir
    dir=$(setup_test_dir)
    mkdir -p "$dir/src"
    echo "import os " > "$dir/src/app.py"
    echo "x = 1 " > "$dir/src/mock file.py"

    # Mock ruff
    mkdir -p "$dir/bin"
    cp "$FIXTURES/mock-ruff.sh" "$dir/bin/ruff"
    chmod +x "$dir/bin/ruff"

    local log_file="$dir/ruff-log.txt"
    PATH="$dir/bin:$PATH" MOCK_RUFF_LOG="$log_file" \
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="'"$dir"'"
        run_mechanical_tools "ruff" "'"$dir/src/app.py"'" "'"$dir/src/mock file.py"'"
    ' 2>/dev/null

    grep -q "check --fix" "$log_file" || { echo "missing check --fix"; return 1; }
    grep -q "format" "$log_file" || { echo "missing format"; return 1; }
    return 0
}
check "M5-01: Ruff --fix and ruff format called on batch files" test_m5_01

# M5-02: Shellcheck is skipped (propose-only)
test_m5_02() {
    local dir
    dir=$(setup_test_dir)
    mkdir -p "$dir/bin"
    local log_file="$dir/shellcheck-log.txt"
    printf '#!/bin/bash\necho "shellcheck called" >> %s\n' "$log_file" > "$dir/bin/shellcheck"
    chmod +x "$dir/bin/shellcheck"

    PATH="$dir/bin:$PATH" \
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="'"$dir"'"
        run_mechanical_tools "shellcheck" "scripts/deploy.sh"
    ' 2>/dev/null

    [[ ! -f "$log_file" ]] || return 1
    return 0
}
check "M5-02: Shellcheck skipped in run_mechanical_tools (propose-only)" test_m5_02

# =============================================================================
# Group 6: Post-Fix Scanner Re-Run (C6)
# =============================================================================

# M6-01: Findings decreased — returns 0
test_m6_01() {
    local rc=0
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="/tmp"

        # Mock discover_run_scanner to return 5 findings
        discover_run_scanner() {
            echo "[{},{},{},{},{}]"
        }
        # Mock normalise-findings.py via TOOLS_DIR
        rerun_scanner "shellcheck" 10 "batch-001" "file1.sh"
    ' 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] || return 1
    return 0
}
check "M6-01: Findings decreased — returns 0" test_m6_01

# M6-02: Findings increased >10% and >1 — returns 1 (revert)
test_m6_02() {
    local rc=0
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="/tmp"

        # Mock: 5 findings post-fix (was 3 → +66%, delta=2 > 1)
        discover_run_scanner() {
            echo "[{},{},{},{},{}]"
        }
        rerun_scanner "shellcheck" 3 "batch-001" "file1.sh"
    ' 2>/dev/null || rc=$?
    [[ $rc -ne 0 ]] || return 1
    return 0
}
check "M6-02: Findings increased >10% and >1 — returns 1" test_m6_02

# M6-03: Findings increased by exactly 1 — returns 0 (tolerance)
test_m6_03() {
    local combined
    local rc=0
    combined=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="/tmp"

            # Mock: 11 findings post-fix (was 10 → +10%, exactly 1 more)
            discover_run_scanner() {
                printf "%s" "["; for i in $(seq 1 11); do printf "{}"; [[ $i -lt 11 ]] && printf ","; done; printf "]"
            }
            rerun_scanner "shellcheck" 10 "batch-001" "file1.sh"
        ' 2>&1
    ) || rc=$?
    [[ $rc -eq 0 ]] || return 1
    echo "$combined" | grep -q "within tolerance" || return 1
    return 0
}
check "M6-03: Findings increased by exactly 1 — tolerance" test_m6_03

# M6-04: Zero-base findings increase — returns 1
test_m6_04() {
    local rc=0
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="/tmp"

        # Mock: 1 finding post-fix (was 0 → zero-base regression)
        discover_run_scanner() {
            echo "[{}]"
        }
        rerun_scanner "shellcheck" 0 "batch-001" "file1.sh"
    ' 2>/dev/null || rc=$?
    [[ $rc -ne 0 ]] || return 1
    return 0
}
check "M6-04: Zero-base findings increase — returns 1" test_m6_04

# M6-05: Findings unchanged — returns 0
test_m6_05() {
    local rc=0
    bash -c '
        source "'"$LIB_DIR/grinder-discover.sh"'"
        source "'"$LIB_DIR/grinder-mechanical.sh"'"
        PROJECT_DIR="/tmp"

        discover_run_scanner() {
            echo "[{},{},{},{},{}]"
        }
        rerun_scanner "shellcheck" 5 "batch-001" "file1.sh"
    ' 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] || return 1
    return 0
}
check "M6-05: Findings unchanged — returns 0" test_m6_05

# =============================================================================
# Group 7: Full Batch Lifecycle (C7)
# =============================================================================

# Helper: setup a full mechanical batch test environment
setup_mechanical_repo() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir/scanner-output"

    mkdir -p "$dir/src"
    echo "import os " > "$dir/src/app.py"
    git -C "$dir" add src/
    git -C "$dir" commit -q -m "add source"

    local sha
    sha=$(git -C "$dir" rev-parse HEAD)

    sed "s/REPLACE_SHA/$sha/" "$FIXTURES/grinder-plan-mechanical.yaml" > "$gdir/grinder-plan.yaml"
    echo '[{"code":"E501","file":"src/app.py"},{"code":"E302","file":"src/app.py"}]' > "$gdir/scanner-output/ruff.json"
    touch "$gdir/stream.ndjson"

    mkdir -p "$dir/mock-bin"
    cp "$FIXTURES/mock-claude.sh" "$dir/mock-bin/claude"
    cp "$FIXTURES/mock-ruff.sh" "$dir/mock-bin/ruff"
    chmod +x "$dir/mock-bin/claude" "$dir/mock-bin/ruff"

    echo "$dir"
}

# Helper: run execute_mechanical_batch in isolated bash -c with common setup
# Usage: run_mechanical_batch <dir> <gdir> <env_vars> <overrides> <batch_json>
# Returns: output in $MECH_OUTPUT, exit code in $MECH_RC
run_mechanical_batch() {
    local dir="$1" gdir="$2" env_script="$3" override_script="$4" batch_json="${5:-[\"src/app.py\"]}"

    MECH_RC=0
    MECH_OUTPUT=$(
        cd "$dir"
        BATCH_FILES_JSON="$batch_json" \
        bash -c "
            $env_script
            export TOOLS_DIR=\"$TOOLS_DIR\"
            export LIB_DIR=\"$LIB_DIR\"
            export SCHEMA_DIR=\"$REPO_DIR/schema\"
            export PROJECT_DIR=\"$dir\"
            export GRINDER_DIR=\"$gdir\"
            export STREAM_FILE=\"$gdir/stream.ndjson\"
            export AUTOPILOT_SID=\"test\"
            export DASHBOARD_DATA=\"/dev/null\"
            export ALLOWED_TOOLS=\"Read,Edit,Write,Bash\"
            source \"\$LIB_DIR/claude-session-lib.sh\"
            source \"\$LIB_DIR/grinder-discover.sh\"
            source \"\$LIB_DIR/grinder-mechanical.sh\"
            $override_script
            execute_mechanical_batch \"batch-001\" \"mechanical\" \
                \"\$BATCH_FILES_JSON\" \"5\"
        " 2>&1
    ) || MECH_RC=$?
}

# M7-01: Successful batch — commit with correct message (AS-2)
test_m7_01() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_RUFF_EXIT=0; export MOCK_CLAUDE_FILES=\"$dir/src/app.py\"; export GRINDER_TEST_CMD=true; export GRINDER_TEST_CMD_RESOLVED=true" \
        'run_phase() { for f in $MOCK_CLAUDE_FILES; do [[ -f "$f" ]] && sed -i.bak "s/[[:space:]]*$//" "$f" && rm -f "${f}.bak"; done; return 0; }; discover_run_scanner() { echo "[{}]"; }'

    [[ $MECH_RC -eq 0 ]] || { echo "  exit code: $MECH_RC, output: $MECH_OUTPUT"; return 1; }

    local last_msg
    last_msg=$(git -C "$dir" log -1 --pretty=%s 2>/dev/null)
    [[ "$last_msg" == *"pass-1-autofix"* ]] || { echo "  bad commit msg: $last_msg"; return 1; }
    [[ "$last_msg" == *"ruff"* ]] || { echo "  missing tool name: $last_msg"; return 1; }
    [[ "$last_msg" == *"batch-001"* ]] || { echo "  missing batch id: $last_msg"; return 1; }
    return 0
}
check "M7-01: Successful batch — correct commit message (AS-2)" test_m7_01

# M7-02: Test regression triggers revert (AS-1)
test_m7_02() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_RUFF_EXIT=0; export MOCK_CLAUDE_FILES=\"$dir/src/app.py\"" \
        'TEST_CALL_COUNT=0; GRINDER_TEST_CMD_RESOLVED=true; GRINDER_TEST_CMD=x;
        run_tests_for_project() { TEST_CALL_COUNT=$((TEST_CALL_COUNT + 1)); [[ $TEST_CALL_COUNT -le 1 ]]; };
        run_phase() { for f in $MOCK_CLAUDE_FILES; do [[ -f "$f" ]] && sed -i.bak "s/[[:space:]]*$//" "$f" && rm -f "${f}.bak"; done; return 0; };
        discover_run_scanner() { echo "[{}]"; }'

    [[ $MECH_RC -ne 0 ]] || { echo "  should have failed"; return 1; }
    echo "$MECH_OUTPUT" | grep -q "test regression" || { echo "  missing regression msg"; return 1; }

    local diff_out
    diff_out=$(git -C "$dir" diff --name-only 2>/dev/null)
    [[ -z "$diff_out" ]] || { echo "  files not reverted: $diff_out"; return 1; }
    return 0
}
check "M7-02: Test regression triggers revert (AS-1)" test_m7_02

# M7-03: Pre-commit hook failure triggers revert (AS-3)
test_m7_03() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    mkdir -p "$dir/.git/hooks"
    cp "$FIXTURES/mock-commit-hook-fail.sh" "$dir/.git/hooks/pre-commit"
    chmod +x "$dir/.git/hooks/pre-commit"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_RUFF_EXIT=0; export MOCK_CLAUDE_FILES=\"$dir/src/app.py\"; export GRINDER_TEST_CMD=true; export GRINDER_TEST_CMD_RESOLVED=true" \
        'run_phase() { for f in $MOCK_CLAUDE_FILES; do [[ -f "$f" ]] && sed -i.bak "s/[[:space:]]*$//" "$f" && rm -f "${f}.bak"; done; return 0; }; discover_run_scanner() { echo "[{}]"; }'

    [[ $MECH_RC -ne 0 ]] || { echo "  should have failed"; return 1; }
    echo "$MECH_OUTPUT" | grep -q "pre-commit hook failure" || { echo "  missing hook msg"; return 1; }
    echo "$MECH_OUTPUT" | grep -q "\-\-no-verify" && { echo "  used --no-verify!"; return 1; }
    return 0
}
check "M7-03: Pre-commit hook failure triggers revert (AS-3)" test_m7_03

# M7-04: Dotfiles shellcheck propose-only flow (AS-4)
test_m7_04() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    # Add a bash fixture file
    mkdir -p "$dir/scripts"
    echo 'echo $unquoted_var' > "$dir/scripts/deploy.sh"
    git -C "$dir" add scripts/
    git -C "$dir" commit -q -m "add bash script"

    # Update plan SHA and replace batch to target .sh files
    local sha
    sha=$(git -C "$dir" rev-parse HEAD)
    cat > "$gdir/grinder-plan.yaml" << YAML
created_at: '2026-04-17T10:00:00+00:00'
estimated_batches: 1
estimated_hours: 0.5
git_sha_at_start: $sha
project: test-project
staleness_commit_threshold: 10
passes:
- batches:
  - estimated_turns: 3
    files:
    - scripts/deploy.sh
    id: batch-001
    status: pending
  id: pass-mechanical
  kind: mechanical
YAML

    # Set up scanner output with findings for pre_findings > 0
    mkdir -p "$gdir/scanner-output"
    cp "$FIXTURES/shellcheck-findings.json" "$gdir/scanner-output/shellcheck.json"

    # Mock shellcheck to return fixture findings
    mkdir -p "$dir/mock-bin"
    cp "$FIXTURES/mock-shellcheck.sh" "$dir/mock-bin/shellcheck"
    chmod +x "$dir/mock-bin/shellcheck"

    # Configure mock shellcheck to return fixture findings
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-findings.json"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_SHELLCHECK_OUTPUT=\"$FIXTURES/shellcheck-findings.json\"; export GRINDER_TEST_CMD=true; export GRINDER_TEST_CMD_RESOLVED=true" \
        'run_phase() { sed -i.bak "s/\$unquoted_var/\"$unquoted_var\"/" "'"$dir/scripts/deploy.sh"'"; rm -f "'"$dir/scripts/deploy.sh.bak"'"; return 0; }; discover_run_scanner() { cat "'"$FIXTURES/shellcheck-findings.json"'"; }' \
        '["scripts/deploy.sh"]'

    [[ $MECH_RC -eq 0 ]] || { echo "  exit code: $MECH_RC, output: $MECH_OUTPUT"; return 1; }

    # Verify that the batch completed (commit or no-change is fine)
    # The key thing: shellcheck is propose-only, so run_mechanical_tools should NOT call it
    # We already tested this in M5-02, but here we verify the full lifecycle works
    return 0
}
check "M7-04: Dotfiles shellcheck propose-only flow (AS-4)" test_m7_04

# M7-05: Pre-batch tests already failing — skip verification (AS-6)
test_m7_05() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_RUFF_EXIT=0; export MOCK_CLAUDE_FILES=\"$dir/src/app.py\"; export GRINDER_TEST_CMD=false; export GRINDER_TEST_CMD_RESOLVED=true" \
        'run_phase() { for f in $MOCK_CLAUDE_FILES; do [[ -f "$f" ]] && sed -i.bak "s/[[:space:]]*$//" "$f" && rm -f "${f}.bak"; done; return 0; }; discover_run_scanner() { echo "[{}]"; }'

    echo "$MECH_OUTPUT" | grep -q "pre-batch tests already failing" || { echo "  missing skip msg"; return 1; }
    [[ $MECH_RC -eq 0 ]] || { echo "  should succeed with pre-failing tests"; return 1; }
    return 0
}
check "M7-05: Pre-batch tests already failing — skip verification (AS-6)" test_m7_05

# M7-06: No test suite — skip verification (AS-7)
test_m7_06() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_RUFF_EXIT=0; export MOCK_CLAUDE_FILES=\"$dir/src/app.py\"; export GRINDER_TEST_CMD=; export GRINDER_TEST_CMD_RESOLVED=true" \
        'run_phase() { for f in $MOCK_CLAUDE_FILES; do [[ -f "$f" ]] && sed -i.bak "s/[[:space:]]*$//" "$f" && rm -f "${f}.bak"; done; return 0; }; discover_run_scanner() { echo "[{}]"; }'

    [[ $MECH_RC -eq 0 ]] || { echo "  should succeed"; return 1; }
    return 0
}
check "M7-06: No test suite — skip verification (AS-7)" test_m7_06

# M7-07: Scanner re-run finds increased findings — revert (AS-8)
test_m7_07() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_RUFF_EXIT=0; export MOCK_CLAUDE_FILES=\"$dir/src/app.py\"; export GRINDER_TEST_CMD=true; export GRINDER_TEST_CMD_RESOLVED=true" \
        'run_phase() { for f in $MOCK_CLAUDE_FILES; do [[ -f "$f" ]] && sed -i.bak "s/[[:space:]]*$//" "$f" && rm -f "${f}.bak"; done; return 0; }; discover_run_scanner() { echo "[{},{},{},{},{}]"; }'

    [[ $MECH_RC -ne 0 ]] || return 1
    return 0
}
check "M7-07: Scanner re-run increased findings — revert (AS-8)" test_m7_07

# M7-08: No files changed after fix — skip commit (EC-6.2)
test_m7_08() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    # Zero out scanner output so pre_findings=0
    echo '[]' > "$gdir/scanner-output/ruff.json"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export GRINDER_TEST_CMD=true; export GRINDER_TEST_CMD_RESOLVED=true" \
        'run_phase() { return 0; }; discover_run_scanner() { echo "[]"; }'

    [[ $MECH_RC -eq 0 ]] || { echo "  should succeed"; return 1; }
    echo "$MECH_OUTPUT" | grep -q "files_fixed=0" || { echo "  missing files_fixed=0"; return 1; }

    local commit_count
    commit_count=$(git -C "$dir" rev-list --count HEAD)
    [[ "$commit_count" -le 2 ]] || { echo "  unexpected commit created"; return 1; }
    return 0
}
check "M7-08: No files changed — skip commit (EC-6.2)" test_m7_08

# M7-09: New files created by session are cleaned on revert (EC-4.1)
test_m7_09() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_RUFF_EXIT=0" \
        "TEST_CALL_COUNT=0; GRINDER_TEST_CMD_RESOLVED=true; GRINDER_TEST_CMD=x;
        run_tests_for_project() { TEST_CALL_COUNT=\$((TEST_CALL_COUNT + 1)); [[ \$TEST_CALL_COUNT -le 1 ]]; };
        run_phase() { sed -i.bak 's/[[:space:]]*$//' \"$dir/src/app.py\"; rm -f \"$dir/src/app.py.bak\"; echo 'new file' > \"$dir/src/new_generated.py\"; return 0; };
        discover_run_scanner() { echo '[{}]'; }"

    [[ $MECH_RC -ne 0 ]] || { echo "  should have failed"; return 1; }
    [[ ! -f "$dir/src/new_generated.py" ]] || { echo "  new file not cleaned"; return 1; }
    echo "$MECH_OUTPUT" | grep -q "cleaned.*new file" || { echo "  missing clean msg"; return 1; }
    return 0
}
check "M7-09: New files cleaned on revert (EC-4.1)" test_m7_09

# M7-10: Shellcheck no issues in batch — skip session (EC-7.1)
test_m7_10() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    # Add a bash file and update plan to target .sh files
    mkdir -p "$dir/scripts"
    echo '#!/bin/bash' > "$dir/scripts/deploy.sh"
    echo 'echo "clean"' >> "$dir/scripts/deploy.sh"
    git -C "$dir" add scripts/
    git -C "$dir" commit -q -m "add clean bash script"

    local sha
    sha=$(git -C "$dir" rev-parse HEAD)
    cat > "$gdir/grinder-plan.yaml" << YAML
created_at: '2026-04-17T10:00:00+00:00'
estimated_batches: 1
estimated_hours: 0.5
git_sha_at_start: $sha
project: test-project
staleness_commit_threshold: 10
passes:
- batches:
  - estimated_turns: 3
    files:
    - scripts/deploy.sh
    id: batch-001
    status: pending
  id: pass-mechanical
  kind: mechanical
YAML

    # Zero out scanner output so pre_findings=0
    mkdir -p "$gdir/scanner-output"
    echo '[]' > "$gdir/scanner-output/shellcheck.json"

    # Mock shellcheck that returns no findings
    mkdir -p "$dir/mock-bin"
    cp "$FIXTURES/mock-shellcheck.sh" "$dir/mock-bin/shellcheck"
    chmod +x "$dir/mock-bin/shellcheck"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export GRINDER_TEST_CMD=true; export GRINDER_TEST_CMD_RESOLVED=true" \
        'run_phase() { echo "SESSION_CALLED" >&2; return 0; }; discover_run_scanner() { echo "[]"; }' \
        '["scripts/deploy.sh"]'

    [[ $MECH_RC -eq 0 ]] || { echo "  should succeed, got rc=$MECH_RC"; return 1; }
    echo "$MECH_OUTPUT" | grep -q "findings_before=0" || { echo "  missing findings_before=0"; return 1; }
    # Session should NOT be called when no findings (EC-7.1 early return)
    echo "$MECH_OUTPUT" | grep -q "SESSION_CALLED" && { echo "  session called with 0 findings"; return 1; }
    return 0
}
check "M7-10: Shellcheck no issues — skip session (EC-7.1)" test_m7_10

# M7-11: File paths with spaces handled throughout lifecycle
test_m7_11() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    mkdir -p "$dir/src"
    echo "x = 1 " > "$dir/src/mock file.py"
    git -C "$dir" add "src/mock file.py"
    git -C "$dir" commit -q -m "add spaced file"

    local sha
    sha=$(git -C "$dir" rev-parse HEAD)
    python3 -c "
import sys
p = sys.argv[1]
t = open(p).read().replace('REPLACE_SHA', sys.argv[2])
# Also update existing SHA
import re
t = re.sub(r'git_sha_at_start: [a-f0-9]+', 'git_sha_at_start: ' + sys.argv[2], t)
open(p, 'w').write(t)
" "$gdir/grinder-plan.yaml" "$sha"

    run_mechanical_batch "$dir" "$gdir" \
        "export PATH=\"$dir/mock-bin:\$PATH\"; export MOCK_RUFF_EXIT=0; export GRINDER_TEST_CMD=true; export GRINDER_TEST_CMD_RESOLVED=true" \
        "run_phase() { sed -i.bak 's/[[:space:]]*$//' \"$dir/src/mock file.py\"; rm -f \"$dir/src/mock file.py.bak\"; return 0; }; discover_run_scanner() { echo '[{}]'; }" \
        '["src/mock file.py"]'

    [[ $MECH_RC -eq 0 ]] || { echo "  exit code: $MECH_RC"; return 1; }

    local committed_files
    committed_files=$(git -C "$dir" diff --name-only HEAD~1 HEAD 2>/dev/null)
    [[ "$committed_files" == *"mock file.py"* ]] || { echo "  spaced file not in commit"; return 1; }
    return 0
}
check "M7-11: File paths with spaces handled throughout lifecycle" test_m7_11

# M7-12: EXTRA_SYSTEM_PROMPT heredoc quoting
test_m7_12() {
    local dir
    dir=$(setup_test_dir)

    local output
    output=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            PROJECT_DIR="'"$dir"'"

            # Override to return JSON with shell metacharacters
            discover_run_scanner() {
                echo "[{\"message\": \"fix \$HOME and \`whoami\` issues\"}]"
            }
            build_mechanical_prompt "shellcheck" "scripts/deploy.sh"
        ' 2>/dev/null
    )
    # Verify literal $HOME (not expanded)
    [[ "$output" == *'$HOME'* ]] || { echo "dollar expanded"; return 1; }
    [[ "$output" == *'`whoami`'* ]] || { echo "backtick expanded"; return 1; }
    return 0
}
check "M7-12: EXTRA_SYSTEM_PROMPT preserves shell metacharacters" test_m7_12

# =============================================================================
# Group 8: Helper Functions (P2-2)
# =============================================================================

# M8-01: _unique_batch_dirs deduplicates directory names
test_m8_01() {
    local output
    output=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            _unique_batch_dirs "src/a.py" "src/b.py" "lib/c.py" "src/d.py" "lib/e.py"
        ' 2>/dev/null
    )
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    [[ "$count" -eq 2 ]] || { echo "expected 2 dirs, got $count: $output"; return 1; }
    echo "$output" | grep -q "^src$" || { echo "missing src"; return 1; }
    echo "$output" | grep -q "^lib$" || { echo "missing lib"; return 1; }
    return 0
}
check "M8-01: _unique_batch_dirs deduplicates directory names" test_m8_01

# M8-02: _unique_batch_dirs handles single file
test_m8_02() {
    local output
    output=$(
        bash -c '
            source "'"$LIB_DIR/grinder-discover.sh"'"
            source "'"$LIB_DIR/grinder-mechanical.sh"'"
            _unique_batch_dirs "scripts/deploy.sh"
        ' 2>/dev/null
    )
    [[ "$output" == "scripts" ]] || { echo "expected 'scripts', got '$output'"; return 1; }
    return 0
}
check "M8-02: _unique_batch_dirs handles single file" test_m8_02

# M8-03: Path traversal guard rejects ../ in file paths
test_m8_03() {
    local dir
    dir=$(setup_mechanical_repo)
    local gdir="$dir/docs/grinder"

    local rc=0
    local output
    output=$(
        cd "$dir"
        bash -c "
            export TOOLS_DIR=\"$TOOLS_DIR\"
            export LIB_DIR=\"$LIB_DIR\"
            export SCHEMA_DIR=\"$REPO_DIR/schema\"
            export PROJECT_DIR=\"$dir\"
            export GRINDER_DIR=\"$gdir\"
            export STREAM_FILE=\"$gdir/stream.ndjson\"
            export AUTOPILOT_SID=\"test\"
            export DASHBOARD_DATA=\"/dev/null\"
            export ALLOWED_TOOLS=\"Read,Edit,Write,Bash\"
            export GRINDER_TEST_CMD=true
            export GRINDER_TEST_CMD_RESOLVED=true
            source \"\$LIB_DIR/claude-session-lib.sh\"
            source \"\$LIB_DIR/grinder-discover.sh\"
            source \"\$LIB_DIR/grinder-mechanical.sh\"
            execute_mechanical_batch \"batch-001\" \"mechanical\" \
                '[\"../../../etc/passwd\"]' \"5\"
        " 2>&1
    ) || rc=$?
    [[ $rc -ne 0 ]] || { echo "  should have rejected path traversal"; return 1; }
    echo "$output" | grep -q "path traversal" || { echo "  missing path traversal message"; return 1; }
    return 0
}
check "M8-03: Path traversal guard rejects ../ in file paths" test_m8_03

# M8-04: process_batch mechanical enrichment — key=value lines parsed
test_m8_04() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"

    local sha
    sha=$(git -C "$dir" rev-parse HEAD)
    cat > "$gdir/grinder-plan.yaml" << YAML
created_at: '2026-04-17T10:00:00+00:00'
estimated_batches: 1
estimated_hours: 0.5
git_sha_at_start: $sha
project: test-project
staleness_commit_threshold: 10
passes:
- batches:
  - estimated_turns: 3
    files:
    - file.txt
    id: batch-001
    status: pending
  id: pass-mechanical
  kind: mechanical
YAML

    touch "$gdir/events.ndjson"
    echo '{"current_pass":"pass-mechanical","current_batch":"","status":"running","batches_completed":0,"batches_failed":0,"batches_deferred":0,"batches_pending":1}' > "$gdir/state.json"

    local test_script="$dir/run_test.sh"
    cat > "$test_script" << 'INNEREOF'
#!/bin/bash
set -euo pipefail
source "$LIB_DIR/claude-session-lib.sh"
source "$LIB_DIR/grinder-discover.sh"
source "$LIB_DIR/grinder-mechanical.sh"

# Save globals before eval (grinder.sh top-level resets PROJECT_DIR/GRINDER_DIR)
_saved_project_dir="$PROJECT_DIR"
_saved_grinder_dir="$GRINDER_DIR"

# Source grinder.sh functions by stripping the final main "$@" call
eval "$(sed '/^main "\$@"/d' "$TOOLS_DIR/grinder.sh")"

# Restore globals overwritten by eval
PROJECT_DIR="$_saved_project_dir"
GRINDER_DIR="$_saved_grinder_dir"
cd "$PROJECT_DIR"

# Override execute_batch to emit enrichment data on stdout
execute_batch() {
    echo "findings_before=10"
    echo "findings_after=3"
    echo "files_fixed=2"
    return 0
}

process_batch '{"id":"batch-001","status":"pending","files":["file.txt"],"estimated_turns":3}' "mechanical"
INNEREOF
    chmod +x "$test_script"

    local rc=0
    TOOLS_DIR="$REPO_DIR/adapters/claude-code/claude/tools" \
    LIB_DIR="$REPO_DIR/adapters/claude-code/claude/tools/lib" \
    SCHEMA_DIR="$REPO_DIR/schema" \
    PROJECT_DIR="$dir" \
    GRINDER_DIR="$gdir" \
    STREAM_FILE="$gdir/stream.ndjson" \
    AUTOPILOT_SID="test" \
    DASHBOARD_DATA="/dev/null" \
    ALLOWED_TOOLS="Read,Edit,Write,Bash" \
    bash "$test_script" 2>/dev/null || rc=$?

    [[ $rc -eq 0 ]] || { echo "  process_batch failed with rc=$rc"; return 1; }

    # Verify enrichment data made it into events.ndjson
    grep -q "findings_before" "$gdir/events.ndjson" || { echo "  missing findings_before in events"; return 1; }
    grep -q "findings_after" "$gdir/events.ndjson" || { echo "  missing findings_after in events"; return 1; }
    grep -q "files_fixed" "$gdir/events.ndjson" || { echo "  missing files_fixed in events"; return 1; }
    return 0
}
check "M8-04: process_batch mechanical enrichment — key=value lines parsed" test_m8_04

# =============================================================================
# Group 9: process_batch reverted flag (P2-1)
# =============================================================================

# M9-01: Non-mechanical failed batch does NOT include reverted=true
test_m9_01() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"

    # Create a minimal plan with a non-mechanical pass
    local sha
    sha=$(git -C "$dir" rev-parse HEAD)
    cat > "$gdir/grinder-plan.yaml" << YAML
created_at: '2026-04-17T10:00:00+00:00'
estimated_batches: 1
estimated_hours: 0.5
git_sha_at_start: $sha
project: test-project
staleness_commit_threshold: 10
passes:
- batches:
  - estimated_turns: 3
    files:
    - file.txt
    id: batch-001
    status: pending
  id: pass-llm
  kind: llm
YAML

    # Create events.ndjson and state.json
    touch "$gdir/events.ndjson"
    echo '{"current_pass":"pass-llm","current_batch":"","status":"running"}' > "$gdir/state.json"

    # Write a test script that sources grinder.sh functions without calling main
    local test_script="$dir/run_test.sh"
    cat > "$test_script" << 'INNEREOF'
#!/bin/bash
set -euo pipefail
source "$LIB_DIR/claude-session-lib.sh"
source "$LIB_DIR/grinder-discover.sh"
source "$LIB_DIR/grinder-mechanical.sh"

# Source grinder.sh functions by stripping the final main "$@" call
eval "$(sed '/^main "\$@"/d' "$TOOLS_DIR/grinder.sh")"

# Override execute_batch to fail
execute_batch() { echo "simulated failure" >&2; return 1; }

process_batch '{"id":"batch-001","status":"pending","files":["file.txt"],"estimated_turns":3}' "llm"
INNEREOF
    chmod +x "$test_script"

    local rc=0
    TOOLS_DIR="$REPO_DIR/adapters/claude-code/claude/tools" \
    LIB_DIR="$REPO_DIR/adapters/claude-code/claude/tools/lib" \
    SCHEMA_DIR="$REPO_DIR/schema" \
    PROJECT_DIR="$dir" \
    GRINDER_DIR="$gdir" \
    STREAM_FILE="$gdir/stream.ndjson" \
    AUTOPILOT_SID="test" \
    DASHBOARD_DATA="/dev/null" \
    ALLOWED_TOOLS="Read,Edit,Write,Bash" \
    bash "$test_script" 2>/dev/null || rc=$?

    # Check events.ndjson for reverted field
    if grep -q '"reverted":true' "$gdir/events.ndjson" 2>/dev/null; then
        echo "  non-mechanical batch should NOT have reverted=true"
        return 1
    fi
    return 0
}
check "M9-01: Non-mechanical failed batch does NOT include reverted=true" test_m9_01

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $failed
