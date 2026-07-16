#!/usr/bin/env bash
# Test suite for the Sonnet-effort=medium nudge.
#
# History:
#   2026-05-24 morning: nudge was ON by default on every Sonnet phase.
#   2026-05-24 afternoon: D vs F canary comparison found that the nudge
#   correlated with /implement commit failures (D never committed its
#   work; F with nudge OFF committed cleanly). Default INVERTED — nudge
#   is now OFF by default, opt-in via AUTOPILOT_SONNET_NUDGE_ENABLE="1".
#
# Contract (post-2026-05-24 afternoon):
#   - Default: CLAUDE_CODE_EFFORT_LEVEL is NOT set even on Sonnet routes
#     (no env var, no "Think briefly" prompt fragment).
#   - Opt-in: AUTOPILOT_SONNET_NUDGE_ENABLE="1" + Sonnet model = nudge
#     applied (env var + prompt fragment).
#   - Non-Sonnet (Opus, Haiku): nudge never applied regardless of env.
#
# Hermetic: grep + small bash invocations against the shared lib.

set -uo pipefail
# Note: `set -e` would abort on the first src_fn that returns 1 (the
# current get_model_for_phase signals "no match" via exit 1). Tests must
# handle non-zero returns inline via the `check` helper.

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

# ───── T1: is_sonnet_model helper exists ─────
check "T1.1: is_sonnet_model function defined in lib" \
  grep -qE '^is_sonnet_model\(\)' "$LIB"

# ───── T2: is_sonnet_model behaviour matrix (unchanged by inversion) ─────
out=$(bash -c "source '$LIB' 2>/dev/null; is_sonnet_model 'claude-sonnet-4-6' && echo yes || echo no")
check "T2.1: sonnet-4-6 → yes" grep -q yes <<<"$out"
out=$(bash -c "source '$LIB' 2>/dev/null; is_sonnet_model 'claude-opus-4-7' && echo yes || echo no")
check "T2.2: opus-4-7 → no" grep -q no <<<"$out"
out=$(bash -c "source '$LIB' 2>/dev/null; is_sonnet_model 'claude-haiku-4-5' && echo yes || echo no")
check "T2.3: haiku-4-5 → no" grep -q no <<<"$out"
out=$(bash -c "source '$LIB' 2>/dev/null; is_sonnet_model '' && echo yes || echo no")
check "T2.4: empty → no" grep -q no <<<"$out"

# ───── T3: spawn block still has the CLAUDE_CODE_EFFORT_LEVEL plumbing ─────
# (kept for opt-in path)
check "T3.1: spawn block references CLAUDE_CODE_EFFORT_LEVEL" \
  grep -q 'CLAUDE_CODE_EFFORT_LEVEL' "$LIB"
check "T3.2: spawn block sets it to medium when triggered" \
  grep -q 'CLAUDE_CODE_EFFORT_LEVEL=.*medium' "$LIB"
check "T3.3: effort-level is gated on the same nudge variable" \
  bash -c "
    grep -n 'CLAUDE_CODE_EFFORT_LEVEL' '$LIB' | grep -v '^[0-9]*:[[:space:]]*#' \
      | while IFS=: read -r ln line; do
        echo \"\$line\" | grep -q '_phase_sonnet_nudge:+' || exit 1
      done
  "

# ───── T4: opt-IN env var (AUTOPILOT_SONNET_NUDGE_ENABLE) is referenced ─────
check "T4.1: lib references AUTOPILOT_SONNET_NUDGE_ENABLE" \
  grep -q 'AUTOPILOT_SONNET_NUDGE_ENABLE' "$LIB"

check "T4.2: enable check sits in the same block as the nudge assignment" \
  bash -c "
    awk '
      /_phase_sonnet_nudge=\"\"/ {seen_init=1; next}
      seen_init && /AUTOPILOT_SONNET_NUDGE_ENABLE/ {seen_check=1; exit}
      END {exit seen_check ? 0 : 1}
    ' '$LIB'
  "

check "T4.3: only literal '1' enables the nudge" \
  grep -qE 'AUTOPILOT_SONNET_NUDGE_ENABLE.*"1"|"1".*AUTOPILOT_SONNET_NUDGE_ENABLE' "$LIB"

# ───── T5: prompt fragment still present (used on opt-in path) ─────
check "T5.1: 'Think briefly' nudge present somewhere in lib" \
  grep -qi 'Think briefly' "$LIB"
check "T5.2: nudge instructs the agent to not enumerate alternatives" \
  grep -qiE 'not enumerate alternatives|Do not enumerate' "$LIB"

# ───── T6: NO opt-OUT env var anymore — the old AUTOPILOT_SONNET_NUDGE_DISABLE
# semantics inverted into AUTOPILOT_SONNET_NUDGE_ENABLE. Operators who set
# the old DISABLE=1 will silently get the same off-by-default behaviour.
# Lock in the rename to prevent regressions.
# ─────────────────────────────────────────────────────────────────────────
check "T6.1: legacy AUTOPILOT_SONNET_NUDGE_DISABLE name is no longer referenced" \
  bash -c "! grep -qE '^[^#]*AUTOPILOT_SONNET_NUDGE_DISABLE' '$LIB'"

# ───── Final ─────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  for n in "${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"}"; do
    echo "  - $n" >&2
  done
  exit 1
fi
exit 0
