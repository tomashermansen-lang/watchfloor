#!/bin/bash
# test_sonar_project_properties.sh — TDD test for sonar-project.properties.
#
# Asserts: every sonar.tests path is excluded from sonar.sources (either
# disjoint at the directory level, or covered by sonar.exclusions). Closes
# env-gap-sonar-sources-tests-overlap which surfaces as the
# "can't be indexed twice" sonar-scanner error.
#
# Usage: bash tests/test_sonar_project_properties.sh
# Exits 0 on pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROPS="$REPO_DIR/sonar-project.properties"

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

[[ -f "$PROPS" ]] || { echo "FATAL: $PROPS not found"; exit 1; }

# Parse a `key=val1,val2,...` line; emit comma-split values one per line.
_get_list() {
    local key="$1"
    grep -E "^${key}=" "$PROPS" | head -1 | sed "s/^${key}=//" | tr ',' '\n' | grep -v '^$'
}

# ── T01: every sonar.tests path is covered by sonar.exclusions OR disjoint from sonar.sources ──
test_no_double_index() {
    local sources tests exclusions
    sources=$(_get_list "sonar.sources")
    tests=$(_get_list "sonar.tests")
    exclusions=$(_get_list "sonar.exclusions")

    local violation=0
    while IFS= read -r test_path; do
        [[ -z "$test_path" ]] && continue
        while IFS= read -r src_path; do
            [[ -z "$src_path" ]] && continue
            # test_path is a subpath of src_path if it starts with "$src_path/"
            if [[ "$test_path/" == "$src_path/"* ]] || [[ "$test_path" == "$src_path/"* ]]; then
                # Subpath → MUST be covered by a sonar.exclusions glob.
                # Conservative check: the literal trailing folder name must
                # appear inside an exclusion glob.
                local trailing="${test_path##*/}"
                if ! echo "$exclusions" | grep -qE "(\*\*/|^)${trailing}(/\*\*|$)"; then
                    echo "  VIOLATION: sonar.tests path '$test_path' is inside sonar.sources path '$src_path' but not covered by sonar.exclusions" >&2
                    violation=1
                fi
            fi
        done <<< "$sources"
    done <<< "$tests"
    [[ $violation -eq 0 ]]
}
check "T01: sonar.tests paths do not double-index against sonar.sources" test_no_double_index

# ── T02: sonar.sources is non-empty ───────────────────────────────────
test_sources_nonempty() {
    [[ -n "$(_get_list sonar.sources)" ]]
}
check "T02: sonar.sources is declared" test_sources_nonempty

# ── T03: sonar.exclusions explicitly excludes __tests__ (regression guard) ──
# Closes env-gap-sonar-sources-tests-overlap: dashboard/app/src/__tests__
# is a literal subpath of dashboard/app/src.
test_excludes_tests_folder() {
    _get_list "sonar.exclusions" | grep -qE '\*\*/__tests__/\*\*'
}
check "T03: sonar.exclusions covers **/__tests__/** (regression guard)" test_excludes_tests_folder

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
