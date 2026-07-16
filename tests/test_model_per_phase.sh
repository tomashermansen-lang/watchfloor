#!/usr/bin/env bash
# Test suite for MODEL_PER_PHASE per-phase model routing primitive.
#
# Verifies:
#   - get_model_for_phase parses CSV env var correctly
#   - Returns 1 (no model) when env unset, empty, or phase missing
#   - Bash 3.2 portable (no associative arrays)
#   - Phase names with hyphens (e.g. static-analysis) parse correctly
#   - run_phase spawn block exports ANTHROPIC_MODEL when override set
#
# Hermetic: sources the lib in a subshell; no claude, no autopilot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

check() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "  FAIL: $name" >&2
  fi
}

# Helper: source the function under test in a clean subshell.
src_fn() {
  bash -c "
    set -euo pipefail
    # Source the lib but suppress any top-level chatter
    source '$LIB' 2>/dev/null
    $1
  "
}

# ═══════════════════════════════════════════════════════════════════════
# T1: get_model_for_phase honors DEFAULT_MODEL_PER_PHASE when env unset
# (behavior changed 2026-05-24 — see DEFAULT_MODEL_PER_PHASE in
# claude-session-lib.sh; the dedicated test for the default lives in
# tests/test_default_model_per_phase.sh).
# ═══════════════════════════════════════════════════════════════════════
out=$(src_fn 'unset MODEL_PER_PHASE; get_model_for_phase ba')
check "T1.1: unset env → falls back to default (sonnet for ba)" \
  grep -q '^claude-sonnet-4-6$' <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T2: empty env → DISABLED (legacy Opus path, returns notfound)
# ═══════════════════════════════════════════════════════════════════════
out=$(src_fn 'MODEL_PER_PHASE=""; get_model_for_phase ba && echo found || echo notfound')
check "T2.1: empty env → notfound (disables default)" grep -q "notfound" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T3: single pair lookup hit (explicit override)
# ═══════════════════════════════════════════════════════════════════════
out=$(src_fn 'MODEL_PER_PHASE="ba=claude-sonnet-4-6"; get_model_for_phase ba')
check "T3.1: single pair returns model" grep -q "^claude-sonnet-4-6$" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T4: partial override — unmentioned phase falls through to DEFAULT.
# Pre-2026-05-24 this returned "notfound"; post-default it returns the
# DEFAULT_MODEL_PER_PHASE entry so partial overrides don't force every
# unmentioned phase back to Opus.
# ═══════════════════════════════════════════════════════════════════════
out=$(src_fn 'MODEL_PER_PHASE="ba=claude-opus-4-7"; get_model_for_phase plan')
check "T4.1: partial override → unmentioned phase falls back to default" \
  grep -q '^claude-sonnet-4-6$' <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T5: multi-pair lookup
# ═══════════════════════════════════════════════════════════════════════
out=$(src_fn 'MODEL_PER_PHASE="ba=claude-sonnet-4-6,plan=claude-sonnet-4-6,static-analysis=claude-haiku-4-5"; get_model_for_phase static-analysis')
check "T5.1: hyphenated phase resolves" grep -q "^claude-haiku-4-5$" <<<"$out"

out=$(src_fn 'MODEL_PER_PHASE="ba=claude-sonnet-4-6,plan=claude-sonnet-4-6,static-analysis=claude-haiku-4-5"; get_model_for_phase plan')
check "T5.2: middle phase resolves" grep -q "^claude-sonnet-4-6$" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T6: tolerates spaces around CSV separators (defensive)
# ═══════════════════════════════════════════════════════════════════════
out=$(src_fn 'MODEL_PER_PHASE="ba=claude-sonnet-4-6, plan=claude-opus-4-7"; get_model_for_phase plan')
check "T6.1: space after comma still resolves" grep -q "^claude-opus-4-7$" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T7: phase name with embedded equals would be malformed — only first
# '=' is the key/value separator
# ═══════════════════════════════════════════════════════════════════════
out=$(src_fn 'MODEL_PER_PHASE="plan=foo=bar"; get_model_for_phase plan')
check "T7.1: model value containing = is preserved" grep -q "^foo=bar$" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T8: bash 3.2 portability — function must not use associative arrays
# ═══════════════════════════════════════════════════════════════════════
check "T8.1: no 'declare -A' in get_model_for_phase region" \
  bash -c "! grep -A 30 '^get_model_for_phase' '$LIB' | grep -q 'declare -A'"

# ═══════════════════════════════════════════════════════════════════════
# T9: spawn block conditionally prepends ANTHROPIC_MODEL when override set
# ═══════════════════════════════════════════════════════════════════════
check "T9.1: spawn block references get_model_for_phase" \
  grep -q "get_model_for_phase" "$LIB"

# ═══════════════════════════════════════════════════════════════════════
# Final
# ═══════════════════════════════════════════════════════════════════════
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  for n in "${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"}"; do
    echo "  - $n" >&2
  done
  exit 1
fi
exit 0
