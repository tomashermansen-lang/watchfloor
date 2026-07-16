#!/bin/bash
# smoke.sh — Minimal smoke test for the dotfiles repo.
#
# Mirrors the smoke_test commands declared in CLAUDE.md's pipeline manifest.
# Used by autopilot's postmerge_check and as a manual sanity check.
#
# Usage: bash tests/smoke.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

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

echo "Running dotfiles smoke tests..."
echo ""

check "validate-plan.py exits 0 on zero-tech-debt-pipeline" \
    python3 ~/.claude/tools/validate-plan.py \
    docs/DONE_Plan_zero-tech-debt-pipeline/execution-plan.yaml

check "autopilot.sh prints usage on missing args" \
    bash -c "bash adapters/claude-code/claude/tools/autopilot.sh 2>&1 | grep -qi usage"

check "scripts/worktree.sh prints usage" \
    bash -c "bash scripts/worktree.sh 2>&1 | grep -q Usage"

check "shellcheck available on PATH" \
    command -v shellcheck

check "jq available on PATH" \
    command -v jq

check "Python imports yaml" \
    python3 -c "import yaml"

check "Python imports jsonschema (needed for Phase 1 schema-validators)" \
    python3 -c "import jsonschema"

check "pytest passes" python3 -m pytest tests/ -x -q

check "test_claude_session_lib passes" \
    bash tests/test_claude_session_lib.sh

check "test_run_phase_watchdog passes" \
    bash tests/test_run_phase_watchdog.sh

check "test_classify_phase_exit passes" \
    bash tests/test_classify_phase_exit.sh

check "test_finalize_plan passes" \
    bash tests/test_finalize_plan.sh

check "test_worktree_provision passes" \
    bash tests/test_worktree_provision.sh

check "test_resolve_plan_yaml_for_task passes" \
    bash tests/test_resolve_plan_yaml_for_task.sh

check "test_deviation_wire passes" \
    bash tests/test_deviation_wire.sh

check "test_tdd_gate passes" \
    bash tests/test_tdd_gate.sh

check "test_phase_selector passes" \
    bash tests/test_phase_selector.sh

check "test_sonar_preflight passes" \
    bash tests/test_sonar_preflight.sh

check "test_commit_finalize_untracked_stash passes" \
    bash tests/test_commit_finalize_untracked_stash.sh

check "grinder-check.sh exits 0 on dotfiles" \
    bash -c "GRINDER_CHECK_PROJECTS='dotfiles|$REPO_DIR' bash adapters/claude-code/claude/tools/grinder-check.sh"

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
