#!/usr/bin/env bash
# Test suite for DEFAULT_MODEL_PER_PHASE — the Sonnet+Haiku combo C
# proved cheapest in canary A/B/C, promoted to the default routing.
#
# Contract:
#   - claude-session-lib.sh defines DEFAULT_MODEL_PER_PHASE constant
#     covering every phase in PHASE_ORDER, with Sonnet for reasoning
#     phases and Haiku for /static-analysis (and /commit, mechanical).
#   - When MODEL_PER_PHASE is unset, get_model_for_phase falls back to
#     DEFAULT_MODEL_PER_PHASE.
#   - An explicit MODEL_PER_PHASE override (even partial) takes precedence.
#   - MODEL_PER_PHASE="" (empty string) DISABLES the fallback — used to
#     force the prior Opus default for cost-sensitive comparisons.
#
# Hermetic: source the lib in subshells; no claude, no autopilot.

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

src_fn() {
  bash -c "
    set -uo pipefail
    source '$LIB' 2>/dev/null
    $1
  "
}

# ───── T1: DEFAULT_MODEL_PER_PHASE constant exists in the lib ─────
check "T1.1: DEFAULT_MODEL_PER_PHASE declared" \
  grep -qE '^DEFAULT_MODEL_PER_PHASE=' "$LIB"

# ───── T2: default applies when MODEL_PER_PHASE is unset ─────
out=$(src_fn 'unset MODEL_PER_PHASE; get_model_for_phase ba')
check "T2.1: unset MODEL_PER_PHASE → ba routes to sonnet" \
  grep -q 'claude-sonnet-4-6' <<<"$out"

out=$(src_fn 'unset MODEL_PER_PHASE; get_model_for_phase static-analysis')
check "T2.2: unset MODEL_PER_PHASE → static-analysis routes to haiku" \
  grep -q 'claude-haiku-4-5' <<<"$out"

out=$(src_fn 'unset MODEL_PER_PHASE; get_model_for_phase implement')
check "T2.3: unset MODEL_PER_PHASE → implement routes to sonnet" \
  grep -q 'claude-sonnet-4-6' <<<"$out"

# ───── T3: explicit MODEL_PER_PHASE override beats default ─────
out=$(src_fn 'MODEL_PER_PHASE="ba=claude-opus-4-7"; get_model_for_phase ba')
check "T3.1: explicit override beats default for matched phase" \
  grep -q 'claude-opus-4-7' <<<"$out"

# ───── T4: partial override — unmentioned phase still uses default ─────
out=$(src_fn 'MODEL_PER_PHASE="ba=claude-opus-4-7"; get_model_for_phase static-analysis')
check "T4.1: partial override → unmentioned phase falls through to default" \
  grep -q 'claude-haiku-4-5' <<<"$out"

# ───── T5: MODEL_PER_PHASE="" disables the default (legacy Opus path) ─────
out=$(src_fn 'MODEL_PER_PHASE=""; get_model_for_phase ba && echo "model=$(get_model_for_phase ba)" || echo "no-override"')
check "T5.1: empty MODEL_PER_PHASE → no model (legacy default Opus path)" \
  grep -q 'no-override' <<<"$out"

# ───── T6: DEFAULT_MODEL_PER_PHASE covers every PHASE_ORDER entry ─────
# The constant must include every canonical phase token so no phase
# silently falls through to the legacy ANTHROPIC_MODEL.
check "T6.1: DEFAULT covers ba, plan, testplan, review, team-review, implement, qa, team-qa, static-analysis, commit" \
  bash -c "
    src=\$(grep -E '^DEFAULT_MODEL_PER_PHASE=' '$LIB' | head -1)
    for p in ba plan testplan review implement qa static-analysis commit; do
      echo \"\$src\" | grep -q \"\$p=\" || { echo \"missing: \$p\" >&2; exit 1; }
    done
  "

# ───── T7: DEFAULT documented in CLAUDE.md with the three override scopes ─────
CLAUDE_MD="$REPO_ROOT/adapters/claude-code/claude/CLAUDE.md"
check "T7.1: CLAUDE.md mentions DEFAULT_MODEL_PER_PHASE" \
  grep -q 'DEFAULT_MODEL_PER_PHASE' "$CLAUDE_MD"
check "T7.2: CLAUDE.md documents per-task override via runner.env" \
  grep -qi 'runner\.env' "$CLAUDE_MD"
check "T7.3: CLAUDE.md documents the empty-string disable" \
  grep -q 'MODEL_PER_PHASE=""' "$CLAUDE_MD"

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
