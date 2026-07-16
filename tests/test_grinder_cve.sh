#!/bin/bash
# test_grinder_cve.sh — Bash integration tests for grinder-cve.sh
#
# Tests: CVE-H01..CVE-H07 from TESTPLAN.md
# Focuses on execute_cve_batch() flow: partition, review, metrics.
#
# Usage: bash tests/test_grinder_cve.sh
# Exits with the number of failures (0 = all pass).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="$REPO_DIR/adapters/claude-code/claude/tools"
LIB_DIR="$TOOLS_DIR/lib"

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

TEST_DIR="${TMPDIR:-/tmp}/test-grinder-cve-$$"
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

# Source CVE lib in isolation
source_cve_lib() {
    local project_dir="${1:-.}"
    export TOOLS_DIR="$REPO_DIR/adapters/claude-code/claude/tools"
    export LIB_DIR="$TOOLS_DIR/lib"
    export SCHEMA_DIR="$REPO_DIR/schema"
    export PROJECT_DIR="$project_dir"
    export GRINDER_DIR="${2:-$project_dir/docs/grinder}"

    # Source dependencies
    source "$LIB_DIR/grinder-discover.sh"
    source "$LIB_DIR/grinder-mechanical.sh"
    source "$LIB_DIR/grinder-cve.sh"

    # Reset cached state
    _CVE_MANIFEST_LOADED=""
    GRINDER_TEST_CMD_RESOLVED=""
}

echo "Running grinder-cve.sh integration tests..."
echo ""

# =============================================================================
# CVE-H01: cve_commit_review creates/commits cve-review.md
# =============================================================================

test_h01() {
    local dir
    dir=$(setup_git_repo)
    local grinder_dir="$dir/docs/grinder"
    mkdir -p "$grinder_dir"

    source_cve_lib "$dir" "$grinder_dir"

    # Create a cve-review.md with content
    printf '# CVE Review\n\n### CVE-2024-0001 — pkg (1.0.0)\n- **Severity:** CRITICAL\n' > "$grinder_dir/cve-review.md"

    # Run cve_commit_review
    cve_commit_review 2>/dev/null

    # Verify committed — use git log from the project dir
    cd "$dir"
    local log_out
    log_out=$(git log --oneline 2>/dev/null)
    echo "$log_out" | grep -q "cve-review" || return 1
    return 0
}
check "CVE-H01: cve_commit_review creates commit" test_h01

# =============================================================================
# CVE-H02: _cve_append_review appends entries (not overwrites)
# =============================================================================

test_h02() {
    local dir
    dir=$(setup_git_repo)
    local grinder_dir="$dir/docs/grinder"
    mkdir -p "$grinder_dir"

    source_cve_lib "$dir" "$grinder_dir"

    # Append first entry
    local finding1='{"rule":"CVE-2024-0001","file":"pkg1","severity":"CRITICAL","tool":"pip-audit","message":"vuln1","fix_version":"2.0.0"}'
    _cve_append_review "$finding1" "major bump required"

    # Append second entry
    local finding2='{"rule":"CVE-2024-0002","file":"pkg2","severity":"HIGH","tool":"npm-audit","message":"vuln2","fix_version":null}'
    _cve_append_review "$finding2" "no fix version available"

    # Verify both entries exist
    grep -q "CVE-2024-0001" "$grinder_dir/cve-review.md" || return 1
    grep -q "CVE-2024-0002" "$grinder_dir/cve-review.md" || return 1
    grep -q "major bump required" "$grinder_dir/cve-review.md" || return 1
    grep -q "no fix version available" "$grinder_dir/cve-review.md" || return 1
    return 0
}
check "CVE-H02: _cve_append_review appends (not overwrites)" test_h02

# =============================================================================
# CVE-H03: _cve_detect_ecosystem identifies scanners correctly
# =============================================================================

test_h03() {
    local dir
    dir=$(setup_test_dir)

    source_cve_lib "$dir"

    local result1
    result1=$(_cve_detect_ecosystem '{"tool":"pip-audit"}')
    [[ "$result1" == "python" ]] || return 1

    local result2
    result2=$(_cve_detect_ecosystem '{"tool":"npm-audit"}')
    [[ "$result2" == "node" ]] || return 1

    local result3
    result3=$(_cve_detect_ecosystem '{"tool":"unknown"}')
    [[ "$result3" == "unknown" ]] || return 1

    return 0
}
check "CVE-H03: _cve_detect_ecosystem identifies pip-audit/npm-audit" test_h03

# =============================================================================
# CVE-H04: execute_cve_batch with zero findings outputs correct metrics
# =============================================================================

test_h04() {
    local dir
    dir=$(setup_git_repo)
    local grinder_dir="$dir/docs/grinder"
    mkdir -p "$grinder_dir/scanner-output"

    # Write empty scanner output
    echo '[]' > "$grinder_dir/scanner-output/pip-audit.json"

    # Create minimal CLAUDE.md
    printf 'pipeline:\n  grinder:\n    languages: [python]\n' > "$dir/CLAUDE.md"

    source_cve_lib "$dir" "$grinder_dir"

    local output
    output=$(execute_cve_batch "b1" "cve" '["all"]' "3" 2>/dev/null)

    echo "$output" | grep -q "cves_found=0" || return 1
    echo "$output" | grep -q "cves_fixed=0" || return 1
    echo "$output" | grep -q "cves_deferred=0" || return 1
    echo "$output" | grep -q "deps_excluded=0" || return 1
    return 0
}
check "CVE-H04: zero vulnerabilities outputs correct metrics" test_h04

# =============================================================================
# CVE-H05: _cve_load_manifest loads defaults when no manifest
# =============================================================================

test_h05() {
    local dir
    dir=$(setup_test_dir)

    # No CLAUDE.md
    source_cve_lib "$dir"
    _cve_load_manifest 2>/dev/null

    [[ "$_CVE_SEVERITY_GATE" == "HIGH" ]] || return 1
    [[ "$_CVE_SUGGEST_GATE" == "MEDIUM" ]] || return 1
    [[ "$_CVE_EXCLUDE_DEPS_JSON" == "[]" ]] || return 1
    [[ "$_CVE_NEVER_AUTO_UPGRADE_JSON" == "[]" ]] || return 1
    return 0
}
check "CVE-H05: _cve_load_manifest defaults when no manifest" test_h05

# =============================================================================
# CVE-H06: execute_cve_batch with deferred findings creates cve-review.md
# =============================================================================

test_h06() {
    local dir
    dir=$(setup_git_repo)
    local grinder_dir="$dir/docs/grinder"
    mkdir -p "$grinder_dir/scanner-output"

    # Write scanner output with a finding that will be deferred (no fix version)
    cat > "$grinder_dir/scanner-output/pip-audit.json" << 'EOF'
[{"id":"pip-audit:CVE20240001-pkg-aaaaaaaa","tool":"pip-audit","rule":"CVE-2024-0001","file":"pkg","line":1,"severity":"CRITICAL","message":"pkg 1.0.0: vulnerability","content_hash":"aaaaaaaa","fix_version":null}]
EOF

    source_cve_lib "$dir" "$grinder_dir"

    local output
    output=$(execute_cve_batch "b1" "cve" '["all"]' "3" 2>/dev/null)

    # Should have deferred findings
    echo "$output" | grep -q "cves_deferred=1" || return 1
    echo "$output" | grep -q "cves_fixed=0" || return 1

    # cve-review.md should exist with the deferral
    [[ -f "$grinder_dir/cve-review.md" ]] || return 1
    grep -q "CVE-2024-0001" "$grinder_dir/cve-review.md" || return 1
    return 0
}
check "CVE-H06: deferred findings create cve-review.md entries" test_h06

# =============================================================================
# CVE-H07: execute_cve_batch with excluded deps logs and skips
# =============================================================================

test_h07() {
    local dir
    dir=$(setup_git_repo)
    local grinder_dir="$dir/docs/grinder"
    mkdir -p "$grinder_dir/scanner-output"

    # Write scanner output with a finding for an excluded package
    cat > "$grinder_dir/scanner-output/pip-audit.json" << 'EOF'
[{"id":"pip-audit:CVE20240001-excluded_pkg-aaaaaaaa","tool":"pip-audit","rule":"CVE-2024-0001","file":"excluded_pkg","line":1,"severity":"CRITICAL","message":"excluded_pkg 1.0.0: vulnerability","content_hash":"aaaaaaaa","fix_version":"1.0.1"}]
EOF

    # Set up exclude_deps manually (bypass manifest loading)
    source_cve_lib "$dir" "$grinder_dir"
    _CVE_MANIFEST_LOADED="true"
    _CVE_SEVERITY_GATE="HIGH"
    _CVE_SUGGEST_GATE="MEDIUM"
    _CVE_EXCLUDE_DEPS_JSON='[{"name":"excluded_pkg","reason":"pinned by upstream"}]'
    _CVE_NEVER_AUTO_UPGRADE_JSON="[]"

    local output stderr_file
    stderr_file=$(mktemp)
    output=$(execute_cve_batch "b1" "cve" '["all"]' "3" 2>"$stderr_file") || true

    echo "$output" | grep -q "deps_excluded=1" || { rm -f "$stderr_file"; return 1; }
    echo "$output" | grep -q "cves_fixed=0" || { rm -f "$stderr_file"; return 1; }
    grep -q "skipping excluded_pkg" "$stderr_file" || { rm -f "$stderr_file"; return 1; }
    rm -f "$stderr_file"

    # cve-review.md should NOT exist (excluded deps are fully suppressed)
    [[ ! -f "$grinder_dir/cve-review.md" ]] || { grep -q "excluded_pkg" "$grinder_dir/cve-review.md" && return 1 || true; }
    return 0
}
check "CVE-H07: excluded deps logged and skipped" test_h07

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "Results: $passed passed, $failed failed"
exit $failed
