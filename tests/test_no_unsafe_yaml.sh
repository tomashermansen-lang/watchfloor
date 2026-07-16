#!/usr/bin/env bash
# test_no_unsafe_yaml.sh — C.T3
#
# Greps claude/tools/lib/plan_*.py for yaml.load and unsafe_load.
# Any match means a plan_ module is using an unsafe YAML loader — exit 1.
#
# TC-YS01: no matches on the current repo → exit 0.
# TC-YS02: planted yaml.load( in a scratch file is caught → script fails.
#
# Usage: bash tests/test_no_unsafe_yaml.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$REPO_DIR/adapters/claude-code/claude/tools/lib"

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

check_fail() {
    local name="$1"
    shift
    if ! "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name (expected failure but succeeded)"
        failed=$((failed + 1))
    fi
}

# ---------------------------------------------------------------------------
# TC-YS01: plan_*.py files contain no yaml.load or unsafe_load calls.
# ---------------------------------------------------------------------------
tc_ys01() {
    # grep -l exits 0 if any match found (bad), 1 if no match (good).
    # We want no matches → grep must exit 1.
    if grep -rl --include="plan_*.py" -E "yaml\.load\b|unsafe_load" "$LIB_DIR" 2>/dev/null | grep -q .; then
        echo "Unsafe YAML loader found in plan_*.py:" >&2
        grep -rn --include="plan_*.py" -E "yaml\.load\b|unsafe_load" "$LIB_DIR" >&2
        return 1
    fi
    return 0
}
check "TC-YS01: plan_*.py files contain no yaml.load or unsafe_load" tc_ys01


# ---------------------------------------------------------------------------
# TC-YS02: planted yaml.load( in a scratch file is detected.
# ---------------------------------------------------------------------------
SCRATCH_DIR="${TMPDIR:-/tmp}/test-ys02-$$"
mkdir -p "$SCRATCH_DIR"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

# Write a fake plan_ file with an unsafe loader call.
python3 - "$SCRATCH_DIR/plan_unsafe_test.py" << 'PYEOF'
import sys
content = (
    "import yaml\n"
    "\n"
    "def parse(text):\n"
    "    return yaml.load(text, Loader=yaml.Loader)\n"
)
with open(sys.argv[1], "w") as f:
    f.write(content)
PYEOF

tc_ys02() {
    # The checker must detect yaml.load in the scratch file and exit non-zero.
    if grep -rl --include="plan_*.py" -E "yaml\.load\b|unsafe_load" "$SCRATCH_DIR" 2>/dev/null | grep -q .; then
        return 0   # match found → test correctly detects it
    fi
    return 1  # no match → checker failed to detect
}
check_fail "TC-YS02: planted yaml.load( in scratch file is detected (checker exits non-zero)" \
    bash -c '
        grep -rl --include="plan_*.py" -E "yaml\\.load\\b|unsafe_load" "'"$SCRATCH_DIR"'" 2>/dev/null | grep -q . && exit 1 || exit 0
    '


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
