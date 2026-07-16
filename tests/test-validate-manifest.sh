#!/bin/bash
# test-validate-manifest.sh — TDD test suite for claude/tools/validate-manifest.py
#
# Uses the check() assertion pattern from tests/smoke.sh.
# Each test creates isolated fixture pipeline.yaml files, runs the validator,
# and asserts on exit code and output.
#
# Usage: bash tests/test-validate-manifest.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/adapters/claude-code/claude/tools/validate-manifest.py"

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

TEST_DIR="${TMPDIR:-/tmp}/test-validate-manifest-$$"

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}
trap teardown EXIT

# Helper: write a pipeline.yaml fixture file.
#
# Test fixtures historically used CLAUDE.md with an embedded `pipeline:`
# block — the format before the 2026-04-29 migration to standalone
# pipeline.yaml. Heredocs in this file still wrap content under
# `pipeline:` for readability; this helper strips the wrapper and
# de-indents so the resulting file matches the production manifest
# format that validate-manifest.py expects.
write_fixture() {
    local path="$1"
    local content="$2"
    mkdir -p "$(dirname "$path")"
    if [[ "$content" == "pipeline:"* ]]; then
        # Strip the `pipeline:` line and dedent 2 spaces from the rest.
        printf '%s\n' "$content" | sed -e '1d' -e 's/^  //' > "$path"
    else
        printf '%s\n' "$content" > "$path"
    fi
}

echo "Running validate-manifest tests..."
echo ""

# --- T1: integration: AS-1: All four valid manifests ---

test_t1() {
    setup

    # dotfiles-like
    write_fixture "$TEST_DIR/t1a/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck, jq, sonar-scanner]
  grinder:
    languages: [bash]
    findings:
      shellcheck:
        paths: [claude/tools/]
      fix_rules_allowlist: []
      never_touch_files: []
M
)"

    # OIH-like
    write_fixture "$TEST_DIR/t1b/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff, mypy]
    node: [eslint, tsc]
    infra: [sonar-scanner]
  grinder:
    languages: [python, typescript]
    coverage:
      python: "pytest --cov=src --cov-report=xml"
      typescript: "npx vitest run --coverage"
      target_project_wide: 0.85
      target_per_commit: 0.99
    findings:
      sonarqube:
        url: "http://localhost:9100"
        project_key: "OIH"
        min_severity: MAJOR
      ruff:
        enabled: true
      mypy:
        enabled: true
      eslint:
        enabled: true
      tsc:
        enabled: true
      fix_rules_allowlist: []
      never_touch_files: []
    dependencies:
      python: "pip-audit"
      typescript: "npm audit"
      severity_gate: HIGH
      exclude_deps: []
M
)"

    # Dashboard-like
    write_fixture "$TEST_DIR/t1c/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    node: [eslint, tsc]
    infra: [sonar-scanner]
  grinder:
    languages: [typescript]
    coverage:
      typescript: "npx vitest run --coverage"
      target_project_wide: 0.85
      target_per_commit: 0.99
    findings:
      sonarqube:
        url: "http://localhost:9100"
        project_key: "test-typescript-project"
        min_severity: MAJOR
      eslint:
        enabled: true
      tsc:
        enabled: true
      fix_rules_allowlist: []
      never_touch_files: []
    dependencies:
      typescript: "npm audit"
      severity_gate: HIGH
      exclude_deps: []
M
)"

    # RAG-like
    write_fixture "$TEST_DIR/t1d/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff, mypy]
    infra: [sonar-scanner]
  grinder:
    languages: [python]
    coverage:
      python: "pytest --cov=src --cov-report=xml"
      target_project_wide: 0.85
      target_per_commit: 0.99
    findings:
      sonarqube:
        url: "http://localhost:9100"
        project_key: "RAG-framework"
        min_severity: MAJOR
      ruff:
        enabled: true
      mypy:
        enabled: true
      fix_rules_allowlist: []
      never_touch_files: []
    dependencies:
      python: "pip-audit"
      severity_gate: HIGH
      exclude_deps: []
M
)"

    local exit_code
    for f in "$TEST_DIR"/t1{a,b,c,d}/pipeline.yaml; do
        python3 "$SCRIPT" "$f" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
        [[ $exit_code -eq 0 ]] || { echo "  Failed on $f (exit $exit_code)"; return 1; }
    done
    return 0
}
check "T1: integration: all four valid manifests exit 0" test_t1

# --- T2: semantic: AS-2: Undeclared tool rejected ---

test_t2() {
    setup
    write_fixture "$TEST_DIR/t2/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    findings:
      ruff:
        enabled: true
      bandit:
        enabled: true
      fix_rules_allowlist: []
      never_touch_files: []
M
)"

    local output exit_code
    output=$(python3 "$SCRIPT" "$TEST_DIR/t2/pipeline.yaml" 2>&1) && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    echo "$output" | grep -q "bandit" || { echo "  Expected 'bandit' in error output"; return 1; }
    return 0
}
check "T2: semantic: undeclared tool (bandit) rejected" test_t2

# --- T3: schema: AS-3: Missing languages ---

test_t3() {
    setup
    write_fixture "$TEST_DIR/t3/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck]
  grinder:
    findings:
      shellcheck:
        paths: [claude/tools/]
M
)"

    local output exit_code
    output=$(python3 "$SCRIPT" "$TEST_DIR/t3/pipeline.yaml" 2>&1) && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    echo "$output" | grep -qi "languages" || { echo "  Expected 'languages' in error"; return 1; }
    return 0
}
check "T3: schema: missing languages field rejected" test_t3

# --- T4: schema: AS-4: target > 1.0 ---

test_t4() {
    setup
    write_fixture "$TEST_DIR/t4/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    coverage:
      python: "pytest --cov"
      target_project_wide: 1.5
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t4/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    return 0
}
check "T4: schema: target_project_wide > 1.0 rejected" test_t4

# --- T5: schema: AS-5: target < 0.0 ---

test_t5() {
    setup
    write_fixture "$TEST_DIR/t5/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    coverage:
      python: "pytest --cov"
      target_project_wide: -0.1
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t5/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    return 0
}
check "T5: schema: target_project_wide < 0.0 rejected" test_t5

# --- T6: integration: AS-6: Dotfiles minimal block valid ---

test_t6() {
    # Uses the REAL dotfiles CLAUDE.md (after C3 grinder block is added)
    local real_claude="$REPO_DIR/pipeline.yaml"
    [[ -f "$real_claude" ]] || { echo "  claude/CLAUDE.md not found"; return 1; }

    local output exit_code
    output=$(python3 "$SCRIPT" "$real_claude" 2>&1) && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; echo "  Output: $output"; return 1; }
    return 0
}
check "T6: integration: dotfiles minimal grinder block valid" test_t6

# --- T7: schema: AS-7: Missing exclude_deps reason ---

test_t7() {
    setup
    write_fixture "$TEST_DIR/t7/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    dependencies:
      python: "pip-audit"
      exclude_deps:
        - name: some-pkg
M
)"

    local output exit_code
    output=$(python3 "$SCRIPT" "$TEST_DIR/t7/pipeline.yaml" 2>&1) && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    return 0
}
check "T7: schema: missing exclude_deps reason rejected" test_t7

# --- T8: schema: EC-1.1: Empty grinder block ---

test_t8() {
    setup
    write_fixture "$TEST_DIR/t8/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck]
  grinder: {}
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t8/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1 (languages required), got $exit_code"; return 1; }
    return 0
}
check "T8: schema: empty grinder block rejected (languages required)" test_t8

# --- T9: schema: EC-1.2: Unknown key accepted ---

test_t9() {
    setup
    write_fixture "$TEST_DIR/t9/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck]
  grinder:
    languages: [bash]
    extra_future_key: something
    findings:
      shellcheck:
        paths: [claude/tools/]
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t9/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0 (additionalProperties: true), got $exit_code"; return 1; }
    return 0
}
check "T9: schema: unknown top-level key accepted" test_t9

# --- T10: integration: EC-1.3: No grinder block ---

test_t10() {
    setup
    write_fixture "$TEST_DIR/t10/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck]
  contracts: []
M
)"

    local output exit_code
    output=$(python3 "$SCRIPT" "$TEST_DIR/t10/pipeline.yaml" 2>&1) && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0, got $exit_code"; return 1; }
    return 0
}
check "T10: integration: no grinder block exits 0" test_t10

# --- T11: semantic: EC-3.1: Coverage without commands ---

test_t11() {
    setup
    write_fixture "$TEST_DIR/t11/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    coverage:
      target_project_wide: 0.85
      target_per_commit: 0.99
M
)"

    local output exit_code
    output=$(python3 "$SCRIPT" "$TEST_DIR/t11/pipeline.yaml" 2>&1) && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1, got $exit_code"; return 1; }
    echo "$output" | grep -qi "coverage" || { echo "  Expected 'coverage' in error"; return 1; }
    return 0
}
check "T11: semantic: coverage block without language commands rejected" test_t11

# --- T12: schema: EC-3.2: target exactly 0.0 and 1.0 ---

test_t12() {
    setup
    write_fixture "$TEST_DIR/t12/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    coverage:
      python: "pytest --cov"
      target_project_wide: 0.0
      target_per_commit: 1.0
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t12/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0 (boundary values valid), got $exit_code"; return 1; }
    return 0
}
check "T12: schema: target exactly 0.0 and 1.0 accepted" test_t12

# --- T13: schema: EC-3.3: Integer target ---

test_t13() {
    setup
    write_fixture "$TEST_DIR/t13/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    coverage:
      python: "pytest --cov"
      target_project_wide: 1
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t13/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0 (integer 1 is valid number), got $exit_code"; return 1; }
    return 0
}
check "T13: schema: integer target (1) accepted as number" test_t13

# --- T14: schema: EC-5.1: Empty reason string ---

test_t14() {
    setup
    write_fixture "$TEST_DIR/t14/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    dependencies:
      python: "pip-audit"
      exclude_deps:
        - name: some-pkg
          reason: ""
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t14/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1 (empty reason), got $exit_code"; return 1; }
    return 0
}
check "T14: schema: empty reason string rejected" test_t14

# --- T15: schema: EC-5.2: Empty exclude_deps array ---

test_t15() {
    setup
    write_fixture "$TEST_DIR/t15/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff]
  grinder:
    languages: [python]
    dependencies:
      python: "pip-audit"
      exclude_deps: []
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t15/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0 (empty array valid), got $exit_code"; return 1; }
    return 0
}
check "T15: schema: empty exclude_deps array accepted" test_t15

# --- T16: semantic: EC-7.1: sonarqube → sonar-scanner mapping ---

test_t16() {
    setup
    write_fixture "$TEST_DIR/t16/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [sonar-scanner]
  grinder:
    languages: [bash]
    findings:
      sonarqube:
        url: "http://localhost:9100"
        project_key: "test"
        min_severity: MAJOR
      fix_rules_allowlist: []
      never_touch_files: []
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t16/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0 (sonarqube maps to sonar-scanner), got $exit_code"; return 1; }
    return 0
}
check "T16: semantic: sonarqube maps to sonar-scanner in toolchain" test_t16

# --- T17: semantic: EC-7.2: Tool in toolchain but not in grinder ---

test_t17() {
    setup
    write_fixture "$TEST_DIR/t17/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    python: [ruff, mypy, bandit]
    infra: [sonar-scanner]
  grinder:
    languages: [python]
    findings:
      ruff:
        enabled: true
      fix_rules_allowlist: []
      never_touch_files: []
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t17/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0 (extra tools in toolchain is fine), got $exit_code"; return 1; }
    return 0
}
check "T17: semantic: extra tools in toolchain (not in grinder) accepted" test_t17

# --- T18: semantic: EC-7.3: No executable toolchain categories ---

test_t18() {
    setup
    write_fixture "$TEST_DIR/t18/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    imports: [yaml, jsonschema]
    network: [pypi.org]
  grinder:
    languages: [python]
    findings:
      ruff:
        enabled: true
      fix_rules_allowlist: []
      never_touch_files: []
M
)"

    local output exit_code
    output=$(python3 "$SCRIPT" "$TEST_DIR/t18/pipeline.yaml" 2>&1) && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1 (no executable tools), got $exit_code"; return 1; }
    echo "$output" | grep -q "ruff" || { echo "  Expected 'ruff' in error"; return 1; }
    return 0
}
check "T18: semantic: grinder tools rejected when toolchain has no executable categories" test_t18

# --- T19: integration: EC-11.1: No pipeline block at all ---

test_t19() {
    setup
    write_fixture "$TEST_DIR/t19/pipeline.yaml" "$(cat <<'M'
# Just a normal CLAUDE.md

Some documentation without any pipeline block.
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t19/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0 (no pipeline block), got $exit_code"; return 1; }
    return 0
}
check "T19: integration: no pipeline block exits 0" test_t19

# --- T20: integration: EC-11.2: Malformed YAML ---

test_t20() {
    setup
    write_fixture "$TEST_DIR/t20/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck]
  grinder:
    languages: [bash
    findings:
      shellcheck
        paths: [bad
M
)"

    local exit_code
    python3 "$SCRIPT" "$TEST_DIR/t20/pipeline.yaml" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 1 ]] || { echo "  Expected exit 1 (malformed YAML), got $exit_code"; return 1; }
    return 0
}
check "T20: integration: malformed YAML rejected" test_t20

# --- T21: integration: project-dir argument resolves to pipeline.yaml ---
#
# Replaces the old "duplicate grinder blocks" test that became obsolete
# with the 2026-04-29 migration from regex-parsed CLAUDE.md to standalone
# pipeline.yaml. YAML parsers handle duplicate top-level keys natively
# (last-key-wins per yaml.safe_load), so the old "warn on duplicate"
# semantics no longer applies. Replaced with coverage of the
# project-directory argument shape that validate-manifest supports.

test_t21() {
    setup
    write_fixture "$TEST_DIR/t21/pipeline.yaml" "$(cat <<'M'
pipeline:
  toolchain:
    infra: [shellcheck]
  grinder:
    languages: [bash]
    findings:
      shellcheck:
        paths: [claude/tools/]
      fix_rules_allowlist: []
      never_touch_files: []
M
)"

    local exit_code
    # Pass the directory rather than the file; validator should resolve to pipeline.yaml.
    python3 "$SCRIPT" "$TEST_DIR/t21" > /dev/null 2>&1 && exit_code=0 || exit_code=$?
    [[ $exit_code -eq 0 ]] || { echo "  Expected exit 0 with directory arg, got $exit_code"; return 1; }
    return 0
}
check "T21: integration: project-dir arg resolves to pipeline.yaml" test_t21

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
