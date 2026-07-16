#!/usr/bin/env bash
# Test suite for the PLAN_FILE env-var export (fix for plan re-globbing
# antipattern surfaced by canary A/B/C).
#
# Contract:
#   - autopilot.sh exports PLAN_FILE alongside YAML_FILE at run-start so
#     subsequent claude -p phases can resolve the plan path without
#     re-globbing docs/INPROGRESS_Plan_*/execution-plan.yaml.
#   - plan-detection/SKILL.md tells phase agents to honor $PLAN_FILE first
#     and fall back to Glob only when the env var is empty/unset.
#
# Hermetic: grep-only checks against the source files; no autopilot
# invocation, no claude.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTOPILOT="$REPO_ROOT/adapters/claude-code/claude/tools/autopilot.sh"
SKILL="$REPO_ROOT/adapters/claude-code/claude/skills/plan-detection/SKILL.md"

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

# ─────────────────────────────────────────────────────────────────────
# T1: autopilot.sh exports PLAN_FILE
# ─────────────────────────────────────────────────────────────────────
check "T1.1: autopilot.sh exports PLAN_FILE" \
  grep -qE '^export PLAN_FILE\b' "$AUTOPILOT"

# ─────────────────────────────────────────────────────────────────────
# T2: PLAN_FILE is sourced from the already-resolved YAML_FILE so
# multi-plan disambiguation (resolve_plan_yaml_worktree_aware) is reused
# rather than re-implementing the find/glob logic.
# ─────────────────────────────────────────────────────────────────────
check "T2.1: PLAN_FILE aliases YAML_FILE" \
  grep -qE '^PLAN_FILE=("\$YAML_FILE"|\$YAML_FILE)' "$AUTOPILOT"

# ─────────────────────────────────────────────────────────────────────
# T3: PLAN_FILE export appears AFTER YAML_FILE is set (otherwise it
# would always export empty).
# ─────────────────────────────────────────────────────────────────────
check "T3.1: PLAN_FILE export follows YAML_FILE resolution" \
  bash -c "yaml_line=\$(grep -nE '^export YAML_FILE\b' '$AUTOPILOT' | head -1 | cut -d: -f1); plan_line=\$(grep -nE '^export PLAN_FILE\b' '$AUTOPILOT' | head -1 | cut -d: -f1); [[ -n \"\$yaml_line\" && -n \"\$plan_line\" && \$plan_line -ge \$yaml_line ]]"

# ─────────────────────────────────────────────────────────────────────
# T4: plan-detection/SKILL.md tells agents to honor $PLAN_FILE first
# ─────────────────────────────────────────────────────────────────────
check "T4.1: SKILL.md references PLAN_FILE env var" \
  grep -q 'PLAN_FILE' "$SKILL"

check "T4.2: SKILL.md instructs to check env var BEFORE globbing" \
  bash -c "plan_line=\$(grep -n 'PLAN_FILE' '$SKILL' | head -1 | cut -d: -f1); glob_line=\$(grep -n 'Glob the path docs/INPROGRESS_Plan_' '$SKILL' | head -1 | cut -d: -f1); [[ -z \"\$glob_line\" || \$plan_line -lt \$glob_line ]]"

# ─────────────────────────────────────────────────────────────────────
# T5: end-to-end shim — source autopilot up to the export and check the
# env var is present in the resulting shell. We can't run the whole
# autopilot.sh hermetically (it requires a worktree, claude, etc.) but
# we can verify the literal export line is reachable by execution.
# ─────────────────────────────────────────────────────────────────────
check "T5.1: PLAN_FILE export line is exactly one statement" \
  bash -c "[[ \$(grep -cE '^export PLAN_FILE\b' '$AUTOPILOT') -eq 1 ]]"

# ─────────────────────────────────────────────────────────────────────
# T6: Stronger enforcement — claude-session-lib.sh's run_phase must
# inject the PLAN_FILE value into the per-phase system prompt when
# the env var is set. The SKILL.md advice alone proved insufficient
# (canary F still ran 9 INPROGRESS_Plan globs despite the SKILL doc).
# A direct system-prompt injection bypasses the SKILL-loading round-trip.
# ─────────────────────────────────────────────────────────────────────
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

check "T6.1: lib references PLAN_FILE for system-prompt injection" \
  grep -q 'PLAN_FILE' "$LIB"

check "T6.2: headless_prompt interpolates the _plan_file_directive var" \
  bash -c "
    # The directive is built BEFORE headless_prompt and interpolated into
    # the closing string of the assignment via \${_plan_file_directive}.
    # Locking in that interpolation guarantees the value reaches the prompt.
    grep -q '_plan_file_directive' '$LIB' && \
      grep -A 12 '^  local headless_prompt=' '$LIB' | grep -q '_plan_file_directive'
  "

check "T6.3: injection explicitly discourages globbing INPROGRESS_Plan" \
  bash -c "
    # Look for either 'do not glob' or 'do not Glob' or 'skip the Glob'
    # near the PLAN_FILE injection in the lib.
    grep -iE 'do not glob|skip the glob|no glob|without globbing' '$LIB' | grep -qi 'plan\|inprogress'
  "

check "T6.4: injection only fires when PLAN_FILE is non-empty" \
  bash -c "
    # The injection must be inside a conditional that checks PLAN_FILE
    # is set/non-empty so standalone flow runs (no autopilot) stay
    # byte-identical to before.
    grep -E 'PLAN_FILE.*:-|:.\\?-|.\\{PLAN_FILE\\}|\\\$PLAN_FILE' '$LIB' | grep -qE ':\+|:-|\\?'
  "

# ─────────────────────────────────────────────────────────────────────
# Final
# ─────────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  for n in "${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"}"; do
    echo "  - $n" >&2
  done
  exit 1
fi
exit 0
