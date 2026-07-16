#!/bin/bash
# test_worktree_provision.sh — verify scripts/worktree.sh new provisions a
# usable Python venv + node_modules so autopilot phases find their tools.
#
# Background: gitignored deps don't carry across git worktrees. Without
# explicit provisioning, every fresh worktree is toolless and autopilot
# phases either skip (mypy/ruff/pytest-cov) or hang trying to install on
# the fly. uv with a relocatable venv + the global cache makes per-worktree
# provisioning cheap (~1s, ~0 disk via hardlinks).
#
# Tests use WORKTREE_SKIP_PROVISION=1 for the "no-op" case and the real
# provisioning path for the happy case. Each test creates and removes its
# own worktree so the suite is hermetic.

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
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

# Generate a unique feature name per test so a leaked worktree from a previous
# crashed run can't collide with this run's.
gen_name() {
    echo "test-worktree-prov-$$-$1-$RANDOM"
}

cleanup_feature() {
    local feature="$1"
    local wt="$REPO_DIR/../dotfiles-$feature"
    if [[ -d "$wt" ]]; then
        bash "$REPO_DIR/scripts/worktree.sh" rm "$feature" >/dev/null 2>&1 || {
            git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
            git -C "$REPO_DIR" branch -D "feature/$feature" >/dev/null 2>&1 || true
            rm -rf "$wt" 2>/dev/null || true
        }
    fi
}

echo "Running worktree provisioning tests..."
echo ""

# =============================================================================
# T01: WORKTREE_SKIP_PROVISION=1 short-circuits provisioning
# =============================================================================
test_t01() {
    local feature
    feature=$(gen_name "skip")
    local wt="$REPO_DIR/../dotfiles-$feature"
    # shellcheck disable=SC2064  # early expansion intentional: $feature is local
    trap "cleanup_feature '$feature'" RETURN

    # shellcheck disable=SC2034  # WORKTREE_SKIP_PROVISION read by worktree.sh
    WORKTREE_SKIP_PROVISION=1 bash "$REPO_DIR/scripts/worktree.sh" new "$feature" >/dev/null 2>&1 \
        || { echo "  worktree creation failed"; return 1; }

    # When provisioning is skipped, the worktree should NOT have a populated
    # .venv (uv would have created bin/mypy etc.) — empty or absent is fine.
    if [[ -x "$wt/.venv/bin/mypy" ]]; then
        echo "  SKIP=1 still installed mypy — provisioning didn't short-circuit"
        return 1
    fi
    return 0
}
check "T01: WORKTREE_SKIP_PROVISION=1 short-circuits provisioning" test_t01

# =============================================================================
# T02: default new run installs Python dev tools (mypy, ruff, pytest-cov, coverage)
# =============================================================================
test_t02() {
    if ! command -v uv >/dev/null 2>&1; then
        echo "  uv not on PATH — cannot exercise this test (skipping)"
        return 0  # treat as pass (env-gated, not a regression)
    fi
    local feature
    feature=$(gen_name "py")
    local wt="$REPO_DIR/../dotfiles-$feature"
    # shellcheck disable=SC2064  # early expansion intentional: $feature is local
    trap "cleanup_feature '$feature'" RETURN

    bash "$REPO_DIR/scripts/worktree.sh" new "$feature" >/dev/null 2>&1 \
        || { echo "  worktree creation failed"; return 1; }

    for tool in mypy ruff pytest coverage; do
        if [[ ! -x "$wt/.venv/bin/$tool" ]]; then
            echo "  Missing tool in fresh worktree's venv: $tool"
            return 1
        fi
    done
    return 0
}
check "T02: provisioning installs mypy + ruff + pytest + coverage in venv" test_t02

# =============================================================================
# T03: venv is relocatable (uv venv --relocatable)
# =============================================================================
test_t03() {
    if ! command -v uv >/dev/null 2>&1; then
        echo "  uv not on PATH — skipping"
        return 0
    fi
    local feature
    feature=$(gen_name "reloc")
    local wt="$REPO_DIR/../dotfiles-$feature"
    # shellcheck disable=SC2064  # early expansion intentional: $feature is local
    trap "cleanup_feature '$feature'" RETURN

    bash "$REPO_DIR/scripts/worktree.sh" new "$feature" >/dev/null 2>&1 \
        || { echo "  worktree creation failed"; return 1; }

    grep -q '^relocatable = true' "$wt/.venv/pyvenv.cfg" \
        || { echo "  relocatable flag not set in pyvenv.cfg"; return 1; }
    return 0
}
check "T03: provisioned venv is relocatable" test_t03

# =============================================================================
# T04: pipeline.yaml declares mypy + ruff in toolchain.python
# =============================================================================
test_t04() {
    grep -qE '^  python:.*mypy' "$REPO_DIR/pipeline.yaml" \
        || { echo "  toolchain.python missing mypy"; return 1; }
    grep -qE '^  python:.*ruff' "$REPO_DIR/pipeline.yaml" \
        || { echo "  toolchain.python missing ruff"; return 1; }
    return 0
}
check "T04: pipeline.yaml toolchain.python declares mypy + ruff" test_t04

# =============================================================================
# T05: validate-manifest.py accepts the new toolchain.python entry
# =============================================================================
test_t05() {
    cd "$REPO_DIR"
    .venv/bin/python adapters/claude-code/claude/tools/validate-manifest.py pipeline.yaml >/dev/null 2>&1 \
        || { echo "  validate-manifest.py rejected new toolchain shape"; return 1; }
    return 0
}
check "T05: validate-manifest accepts toolchain.python" test_t05

# =============================================================================
# T06: pnpm provisioning installs dashboard/app/node_modules with the .pnpm
# store-layout (proves the store-backed install path, not the npm fallback).
# =============================================================================
test_t06() {
    if ! command -v pnpm >/dev/null 2>&1; then
        echo "  pnpm not on PATH — skipping"
        return 0
    fi
    if [[ ! -f "$REPO_DIR/dashboard/app/pnpm-lock.yaml" ]]; then
        echo "  no pnpm-lock.yaml in main — skipping"
        return 0
    fi
    local feature
    feature=$(gen_name "node")
    local wt="$REPO_DIR/../dotfiles-$feature"
    # shellcheck disable=SC2064  # early expansion intentional: $feature is local
    trap "cleanup_feature '$feature'" RETURN

    bash "$REPO_DIR/scripts/worktree.sh" new "$feature" >/dev/null 2>&1 \
        || { echo "  worktree creation failed"; return 1; }

    if [[ ! -d "$wt/dashboard/app/node_modules" ]]; then
        echo "  pnpm did not create node_modules"
        return 1
    fi
    # node_modules/.pnpm is the canonical pnpm store-layout marker; if it's
    # absent, the worktree.sh fallback ran npm ci instead.
    if [[ ! -d "$wt/dashboard/app/node_modules/.pnpm" ]]; then
        echo "  pnpm store layout missing (no node_modules/.pnpm)"
        return 1
    fi
    return 0
}
check "T06: pnpm provisioning populates dashboard/app/node_modules" test_t06

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
