#!/bin/bash
# test_discovery_pass.sh — D2: Bash integration tests for cmd_discover()
#
# Tests entry-point validation, idempotency, scanner dispatch, output handling,
# commit artifacts, and edge cases.
#
# Usage: bash tests/test_discovery_pass.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GRINDER="$REPO_DIR/adapters/claude-code/claude/tools/grinder.sh"
FIXTURES="$REPO_DIR/tests/fixtures/discovery-pass"

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

TEST_DIR="${TMPDIR:-/tmp}/test-discovery-pass-$$"
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
mkdir -p "$TEST_DIR"

setup_git_repo() {
    local dir
    dir="$TEST_DIR/$(date +%s%N)"
    mkdir -p "$dir/docs/grinder"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial commit"
    echo "$dir"
}

setup_mock_tools() {
    # Creates mock binaries for scanner, normalise-findings.py, and grinder-discover.py
    local dir="$1"
    local mock_dir="$dir/mock-tools"
    local mock_lib="$mock_dir/lib"
    mkdir -p "$mock_dir" "$mock_lib"

    # Mock shellcheck
    cat > "$mock_dir/shellcheck" << 'MOCK_EOF'
#!/bin/bash
exit_code="${MOCK_SHELLCHECK_EXIT:-1}"
if [[ -n "${MOCK_SHELLCHECK_OUTPUT:-}" ]]; then
    cat "$MOCK_SHELLCHECK_OUTPUT"
else
    echo '[]'
fi
exit "$exit_code"
MOCK_EOF
    chmod +x "$mock_dir/shellcheck"

    # Mock normalise-findings.py (real tool path overridden via TOOLS_DIR)
    cat > "$mock_dir/normalise-findings.py" << 'MOCK_EOF'
#!/usr/bin/env python3
import sys
exit_code = int(__import__('os').environ.get('MOCK_NORMALISE_EXIT', '0'))
output_file = __import__('os').environ.get('MOCK_NORMALISE_OUTPUT', '')
if output_file:
    with open(output_file) as f:
        print(f.read(), end='')
else:
    # Read stdin and pass through (default: empty array)
    print('[]')
sys.exit(exit_code)
MOCK_EOF
    chmod +x "$mock_dir/normalise-findings.py"

    # Mock grinder-discover.py
    cat > "$mock_lib/grinder-discover.py" << 'MOCK_EOF'
#!/usr/bin/env python3
import argparse, json, sys, os, yaml
from datetime import datetime, timezone

exit_code = int(os.environ.get('MOCK_DISCOVER_EXIT', '0'))

parser = argparse.ArgumentParser()
parser.add_argument("--project-dir", required=True)
parser.add_argument("--grinder-dir", required=True)
parser.add_argument("--schema-dir", required=True)
parser.add_argument("--tools-dir", required=True)
parser.add_argument("--findings-json", required=True)
parser.add_argument("--project-name", required=True)
parser.add_argument("--git-sha", required=True)
parser.add_argument("--batch-size", type=int, default=5)
args = parser.parse_args()

if exit_code != 0:
    print("error: mock failure", file=sys.stderr)
    sys.exit(exit_code)

# Generate a minimal valid plan
findings = json.loads(open(args.findings_json).read())
plan = {
    "created_at": datetime.now(timezone.utc).isoformat(),
    "git_sha_at_start": args.git_sha,
    "estimated_batches": 1,
    "estimated_hours": 0.5,
    "staleness_commit_threshold": 1,
    "project": args.project_name,
    "passes": [{
        "id": "pass-mechanical",
        "kind": "mechanical",
        "batches": [{
            "id": "batch-001",
            "files": list({f["file"] for f in findings}),
            "estimated_turns": 3,
            "status": "pending"
        }]
    }]
}
with open(os.path.join(args.grinder_dir, "grinder-plan.yaml"), "w") as f:
    yaml.dump(plan, f, default_flow_style=False, sort_keys=False)
sys.exit(0)
MOCK_EOF
    chmod +x "$mock_lib/grinder-discover.py"

    # Copy real validate-manifest.py (needed for --parse-grinder)
    cp "$REPO_DIR/adapters/claude-code/claude/tools/validate-manifest.py" "$mock_dir/validate-manifest.py"

    # Symlink real shared libraries (needed by grinder.sh sourcing)
    ln -sf "$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh" "$mock_lib/claude-session-lib.sh"
    ln -sf "$REPO_DIR/adapters/claude-code/claude/tools/lib/merge-lock.sh" "$mock_lib/merge-lock.sh"
    ln -sf "$REPO_DIR/adapters/claude-code/claude/tools/lib/grinder-discover.sh" "$mock_lib/grinder-discover.sh"
    # __init__.py needed for Python imports from lib/
    touch "$mock_lib/__init__.py"

    echo "$mock_dir"
}

run_discover() {
    # Run grinder.sh discover with mock tools and correct env
    local project_dir="$1"
    shift
    local mock_dir="${MOCK_DIR:-}"

    local tools_dir="$REPO_DIR/adapters/claude-code/claude/tools"
    local lib_dir="$tools_dir/lib"
    if [[ -n "$mock_dir" ]]; then
        tools_dir="$mock_dir"
        lib_dir="$mock_dir/lib"
    fi

    PROJECTS_ROOT="$(dirname "$project_dir")" \
    TOOLS_DIR="$tools_dir" \
    LIB_DIR="$lib_dir" \
    SCHEMA_DIR="$REPO_DIR/schema" \
    PATH="${mock_dir:+$mock_dir:}$PATH" \
    bash "$GRINDER" discover --project-dir "$project_dir" "$@" 2>&1
}

echo "Running discovery-pass integration tests..."
echo ""

# =============================================================================
# D2-01: No CLAUDE.md → exit 1
# =============================================================================

test_d2_01() {
    local dir
    dir=$(setup_git_repo)
    local output
    output=$(run_discover "$dir") && return 1
    echo "$output" | grep -q "discover: no CLAUDE.md found in" || return 1
    return 0
}
check "D2-01: No CLAUDE.md → exit 1" test_d2_01

# =============================================================================
# D2-02: No grinder block → exit 1
# =============================================================================

test_d2_02() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/no-grinder-claude-md" "$dir/CLAUDE.md"
    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") && return 1
    echo "$output" | grep -q "discover: no pipeline.grinder block in CLAUDE.md" || return 1
    return 0
}
check "D2-02: No grinder block → exit 1" test_d2_02

# =============================================================================
# D2-03: Empty CLAUDE.md → exit 1
# =============================================================================

test_d2_03() {
    local dir
    dir=$(setup_git_repo)
    touch "$dir/CLAUDE.md"
    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") && return 1
    echo "$output" | grep -q "no pipeline.grinder block" || return 1
    return 0
}
check "D2-03: Empty CLAUDE.md → exit 1" test_d2_03

# =============================================================================
# D2-04: Idempotency — plan is current
# =============================================================================

test_d2_04() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    local sha
    sha=$(git -C "$dir" rev-parse HEAD)
    # Create existing plan with matching SHA
    mkdir -p "$dir/docs/grinder"
    cat > "$dir/docs/grinder/grinder-plan.yaml" << EOF
created_at: "2026-01-01T00:00:00Z"
git_sha_at_start: "$sha"
estimated_batches: 1
estimated_hours: 0.5
passes:
  - id: pass-1
    kind: mechanical
    batches:
      - id: batch-001
        files: [test.sh]
        estimated_turns: 3
        status: pending
EOF
    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir")
    local exit_code=$?
    [[ $exit_code -eq 0 ]] || return 1
    echo "$output" | grep -q "plan is current" || return 1
    return 0
}
check "D2-04: Idempotency — plan is current" test_d2_04

# =============================================================================
# D2-05: Stale plan → runs discovery
# =============================================================================

test_d2_05() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    # Create plan with non-matching SHA
    mkdir -p "$dir/docs/grinder"
    cat > "$dir/docs/grinder/grinder-plan.yaml" << EOF
created_at: "2026-01-01T00:00:00Z"
git_sha_at_start: "0000000000000000000000000000000000000000"
estimated_batches: 1
estimated_hours: 0.5
passes:
  - id: pass-1
    kind: mechanical
    batches:
      - id: batch-001
        files: [test.sh]
        estimated_turns: 3
        status: pending
EOF
    # Create shell files for shellcheck to find
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT
    # Should not say "plan is current"
    ! echo "$output" | grep -q "plan is current" || return 1
    return 0
}
check "D2-05: Stale plan → runs discovery" test_d2_05

# =============================================================================
# D2-06: Corrupt plan → treated as stale
# =============================================================================

test_d2_06() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/docs/grinder"
    echo "{{corrupt yaml{{{" > "$dir/docs/grinder/grinder-plan.yaml"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT
    # Should NOT say "plan is current"
    ! echo "$output" | grep -q "plan is current" || return 1
    return 0
}
check "D2-06: Corrupt plan → treated as stale" test_d2_06

# =============================================================================
# D2-07: Scanner not found → skip with warning
# =============================================================================

test_d2_07() {
    local dir
    dir=$(setup_git_repo)
    # Use a CLAUDE.md that references a non-existent scanner
    cat > "$dir/CLAUDE.md" << 'CLEOF'
# Test

pipeline:
  toolchain:
    infra: [bash]

  grinder:
    languages: [bash]
    findings:
      nonexistent_scanner_xyz:
        paths: [claude/tools/]
      fix_rules_allowlist: []
      never_touch_files: []
CLEOF
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    echo "$output" | grep -q "not found -- skipping" || return 1
    return 0
}
check "D2-07: Scanner not found → skip" test_d2_07

# =============================================================================
# D2-08: Scanner exits non-zero with output → accepted
# =============================================================================

test_d2_08() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT
    # Should NOT contain "failed with exit"
    if echo "$output" | grep -q "failed with exit"; then
        return 1
    fi
    return 0
}
check "D2-08: Scanner non-zero with output → accepted" test_d2_08

# =============================================================================
# D2-09: Scanner exits non-zero with no output → skipped
# =============================================================================

test_d2_09() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    # Create shellcheck that produces no output and fails
    cat > "$mock_dir/shellcheck" << 'EOF'
#!/bin/bash
exit 2
EOF
    chmod +x "$mock_dir/shellcheck"
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    echo "$output" | grep -q "failed with exit 2 and no output -- skipping" || return 1
    return 0
}
check "D2-09: Scanner non-zero no output → skipped" test_d2_09

# =============================================================================
# D2-10: Normaliser failure → skipped
# =============================================================================

test_d2_10() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_EXIT=1
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_EXIT
    echo "$output" | grep -q "normalise-findings.py failed for shellcheck -- skipping" || return 1
    return 0
}
check "D2-10: Normaliser failure → skipped" test_d2_10

# =============================================================================
# D2-11: Zero findings → nothing to grind
# =============================================================================

test_d2_11() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/empty-shellcheck.json"
    export MOCK_SHELLCHECK_EXIT=0
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir")
    local exit_code=$?
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT
    [[ $exit_code -eq 0 ]] || return 1
    echo "$output" | grep -q "discover: zero findings -- nothing to grind" || return 1
    return 0
}
check "D2-11: Zero findings → nothing to grind" test_d2_11

# =============================================================================
# D2-12: Raw scanner output stored in scanner-output/
# =============================================================================

test_d2_12() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"
    MOCK_DIR="$mock_dir" run_discover "$dir" >/dev/null 2>&1 || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT
    # Raw output must be stored
    [[ -f "$dir/docs/grinder/scanner-output/shellcheck.json" ]] || return 1
    # File must have content
    [[ -s "$dir/docs/grinder/scanner-output/shellcheck.json" ]] || return 1
    return 0
}
check "D2-12: Raw scanner output stored" test_d2_12

# =============================================================================
# D2-13: Re-run overwrites prior discovery artifacts
# =============================================================================

test_d2_13() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"

    # First run
    MOCK_DIR="$mock_dir" run_discover "$dir" >/dev/null 2>&1 || true
    local first_plan_mtime
    first_plan_mtime=$(stat -f "%m" "$dir/docs/grinder/grinder-plan.yaml" 2>/dev/null || stat -c "%Y" "$dir/docs/grinder/grinder-plan.yaml" 2>/dev/null)

    # Advance HEAD so idempotency guard doesn't skip
    echo "change" >> "$dir/file.txt"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "advance head"

    # Second run
    sleep 1  # ensure mtime differs
    MOCK_DIR="$mock_dir" run_discover "$dir" >/dev/null 2>&1 || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT

    local second_plan_mtime
    second_plan_mtime=$(stat -f "%m" "$dir/docs/grinder/grinder-plan.yaml" 2>/dev/null || stat -c "%Y" "$dir/docs/grinder/grinder-plan.yaml" 2>/dev/null)

    # Plan file must have been overwritten (different mtime)
    [[ "$first_plan_mtime" != "$second_plan_mtime" ]] || return 1
    return 0
}
check "D2-13: Re-run overwrites prior artifacts" test_d2_13

# =============================================================================
# D2-14: Commit message format
# =============================================================================

test_d2_14() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"
    MOCK_DIR="$mock_dir" run_discover "$dir" >/dev/null 2>&1 || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT

    # Check commit message format: "chore(grinder): discovery -- <basename> <sha7>"
    local commit_msg
    commit_msg=$(git -C "$dir" log --oneline -1)
    echo "$commit_msg" | grep -qE "chore\(grinder\): discovery --" || return 1
    return 0
}
check "D2-14: Commit message format" test_d2_14

# =============================================================================
# D2-15: Only grinder artifacts committed (not unrelated staged files)
# =============================================================================

test_d2_15() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    # Stage an unrelated file BEFORE running discover
    echo "unrelated content" > "$dir/unrelated.txt"
    git -C "$dir" add "$dir/unrelated.txt"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"
    MOCK_DIR="$mock_dir" run_discover "$dir" >/dev/null 2>&1 || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT

    # The discovery commit should NOT include unrelated.txt
    local committed_files
    committed_files=$(git -C "$dir" diff-tree --no-commit-id --name-only -r HEAD)
    if echo "$committed_files" | grep -q "unrelated.txt"; then
        return 1
    fi
    return 0
}
check "D2-15: Only grinder artifacts committed" test_d2_15

# =============================================================================
# D2-16: Summary output format
# =============================================================================

test_d2_16() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT

    # Summary must contain "batches, estimated" and "Run grinder.sh run to proceed"
    echo "$output" | grep -q "batches, estimated" || return 1
    echo "$output" | grep -q "Run grinder.sh run to proceed" || return 1
    return 0
}
check "D2-16: Summary output format" test_d2_16

# =============================================================================
# D2-19: Scanner paths not exist → skip with warning
# =============================================================================

test_d2_19() {
    local dir
    dir=$(setup_git_repo)
    cat > "$dir/CLAUDE.md" << 'CLEOF'
# Test

pipeline:
  toolchain:
    infra: [bash, shellcheck]

  grinder:
    languages: [bash]
    findings:
      shellcheck:
        paths: [nonexistent/path/]
      fix_rules_allowlist: []
      never_touch_files: []
CLEOF
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT

    # Should warn about non-existent path and skip (no files found)
    echo "$output" | grep -q "does not exist" || echo "$output" | grep -q "no files found" || return 1
    return 0
}
check "D2-19: Scanner paths not exist → skip" test_d2_19

# =============================================================================
# D2-20: never_touch_files patterns excluded
# =============================================================================

test_d2_20() {
    local dir
    dir=$(setup_git_repo)
    cat > "$dir/CLAUDE.md" << 'CLEOF'
# Test

pipeline:
  toolchain:
    infra: [bash, shellcheck]

  grinder:
    languages: [bash]
    findings:
      shellcheck:
        paths: [scripts/]
      fix_rules_allowlist: []
      never_touch_files: ["scripts/vendor*"]
CLEOF
    mkdir -p "$dir/scripts"
    echo '#!/bin/bash' > "$dir/scripts/main.sh"
    echo '#!/bin/bash' > "$dir/scripts/vendor-lib.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    # Use discover_collect_files directly to verify exclusion
    local output
    output=$(
      source "$REPO_DIR/adapters/claude-code/claude/tools/lib/grinder-discover.sh"
      export PROJECT_DIR="$dir"
      discover_collect_files "shellcheck" '["scripts/"]' '["scripts/vendor*"]'
    )
    # main.sh should be found
    echo "$output" | grep -q "main.sh" || return 1
    # vendor-lib.sh should be excluded
    if echo "$output" | grep -q "vendor-lib.sh"; then
        return 1
    fi
    return 0
}
check "D2-20: never_touch_files excluded" test_d2_20

# =============================================================================
# D2-17: scanner-output/ directory created
# =============================================================================

test_d2_17() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    # Intentionally do NOT create scanner-output/
    rm -rf "$dir/docs/grinder/scanner-output"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    export MOCK_SHELLCHECK_OUTPUT="$FIXTURES/shellcheck-output.json"
    export MOCK_SHELLCHECK_EXIT=1
    export MOCK_NORMALISE_OUTPUT="$FIXTURES/normalised-findings.json"
    MOCK_DIR="$mock_dir" run_discover "$dir" >/dev/null 2>&1 || true
    unset MOCK_SHELLCHECK_OUTPUT MOCK_SHELLCHECK_EXIT MOCK_NORMALISE_OUTPUT
    [[ -d "$dir/docs/grinder/scanner-output" ]] || return 1
    return 0
}
check "D2-17: scanner-output/ directory created" test_d2_17

# =============================================================================
# D2-18: All scanners skipped → zero findings
# =============================================================================

test_d2_18() {
    local dir
    dir=$(setup_git_repo)
    # Use a CLAUDE.md referencing only non-existent scanners
    cat > "$dir/CLAUDE.md" << 'CLEOF'
# Test

pipeline:
  toolchain:
    infra: [bash]

  grinder:
    languages: [bash]
    findings:
      nonexistent_scanner_abc:
        paths: [claude/tools/]
      nonexistent_scanner_def:
        paths: [claude/tools/]
      fix_rules_allowlist: []
      never_touch_files: []
CLEOF
    mkdir -p "$dir/claude/tools"
    echo '#!/bin/bash' > "$dir/claude/tools/test.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    local mock_dir
    mock_dir=$(setup_mock_tools "$dir")
    local output
    output=$(MOCK_DIR="$mock_dir" run_discover "$dir") || true
    echo "$output" | grep -q "nothing to grind" || return 1
    return 0
}
check "D2-18: All scanners skipped → nothing to grind" test_d2_18

# =============================================================================
# D2-21: Hidden dirs excluded from file collection
# =============================================================================

test_d2_21() {
    local dir
    dir=$(setup_git_repo)
    cp "$FIXTURES/minimal-claude-md" "$dir/CLAUDE.md"
    mkdir -p "$dir/claude/tools/.git"
    mkdir -p "$dir/claude/tools/node_modules"
    echo '#!/bin/bash' > "$dir/claude/tools/real.sh"
    echo '#!/bin/bash' > "$dir/claude/tools/.git/hidden.sh"
    echo '#!/bin/bash' > "$dir/claude/tools/node_modules/excluded.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "add files"

    # Use discover_collect_files directly via bash sourcing
    local output
    output=$(
      source "$REPO_DIR/adapters/claude-code/claude/tools/lib/grinder-discover.sh"
      export PROJECT_DIR="$dir"
      discover_collect_files "shellcheck" '["claude/tools/"]' '[]'
    )
    # real.sh should be found, hidden.sh and excluded.sh should not
    echo "$output" | grep -q "real.sh" || return 1
    if echo "$output" | grep -q ".git/hidden.sh"; then
        return 1
    fi
    if echo "$output" | grep -q "node_modules/excluded.sh"; then
        return 1
    fi
    return 0
}
check "D2-21: Hidden dirs excluded" test_d2_21

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
