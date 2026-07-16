#!/usr/bin/env bash
# test_consumer_legacy_handling.sh — C.T4
#
# Greps the seven consumer files for either:
#   - `LegacyPlanError` (Python consumers — import or except clause), OR
#   - `dump --` subprocess pattern (Bash consumers delegating to plan_yaml_deferred), OR
#   - `plan_yaml_deferred` import/reference (Python consumers using the module directly)
#
# Fails if any consumer omits all three patterns (TC-CLH01).
#
# Usage: bash tests/test_consumer_legacy_handling.sh
# Exits 0 on all pass, 1 on any failure.

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

# ---------------------------------------------------------------------------
# Helper: return 0 if a file contains a legacy-handling marker.
# ---------------------------------------------------------------------------
_has_legacy_handler() {
    local file="$1"
    # Python consumers: import or catch LegacyPlanError
    if grep -q "LegacyPlanError" "$file" 2>/dev/null; then
        return 0
    fi
    # Bash consumers: subprocess delegation via `dump --` OR via filter-deferred.py
    # (get-findings.sh delegates deferred routing to filter-deferred.py, which
    # itself handles 2.0 plan routing — that counts as a legacy handler).
    if grep -q "dump --" "$file" 2>/dev/null; then
        return 0
    fi
    if grep -q "filter-deferred" "$file" 2>/dev/null; then
        return 0
    fi
    # Python consumers that import plan_yaml_deferred (covers emit-baseline.py
    # which does detect_plan_version routing without catching LegacyPlanError
    # at the call site — the version check itself IS the legacy guard).
    if grep -q "plan_yaml_deferred" "$file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# TC-CLH01: all seven consumers have a legacy-handling marker.
# ---------------------------------------------------------------------------
CONSUMERS=(
    "claude/tools/lib/filter-deferred.py"
    "claude/tools/lib/finalise-deferred.py"
    "claude/tools/lib/ratchet-autolog.py"
    "claude/tools/lib/emit-baseline.py"
    "claude/tools/get-findings.sh"
    "claude/tools/commit-preflight.sh"
    "claude/tools/grinder-audit.py"
)

all_ok=true
for rel in "${CONSUMERS[@]}"; do
    file="$REPO_DIR/$rel"
    check "TC-CLH01: $rel has legacy handler" _has_legacy_handler "$file"
    if ! _has_legacy_handler "$file" 2>/dev/null; then
        all_ok=false
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
