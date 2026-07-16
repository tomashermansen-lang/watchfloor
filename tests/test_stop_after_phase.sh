#!/usr/bin/env bash
# test_stop_after_phase.sh — integration + structural tests for the
# autopilot.sh --stop-after-phase CLI flag.
#
# Covers TESTPLAN.md scenarios I3.1–I3.12 (argv parsing / validation /
# composition), I3.22 (structural: every lifecycle_emit_phase_complete
# followed by should_stop_after_phase call), I3.10/I3.11 (no env-var
# fallback, header docstring), and integration AS1–AS5 / AS9–AS10 in
# the parse-and-validate paths.
#
# Tests that require driving a full pipeline (real run_phase invocation)
# are out of scope here — those are covered by the unit tests for
# stop_after_phase_exit in dashboard/tests/test-autopilot-pause.sh and
# by manual MT4 in TESTPLAN.md.
#
# Portability: bash 3.2 macOS-default.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTOPILOT_SH="$REPO_ROOT/adapters/claude-code/claude/tools/autopilot.sh"
CHAIN_SH="$REPO_ROOT/adapters/claude-code/claude/tools/autopilot-chain.sh"
LIB_SELECTOR="$REPO_ROOT/adapters/claude-code/claude/tools/lib/phase-selector.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

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
    printf '  FAIL: %s\n' "$name" >&2
  fi
}

[[ -f "$AUTOPILOT_SH" ]] || { echo "FATAL: $AUTOPILOT_SH not found"; exit 1; }
[[ -f "$LIB_SELECTOR" ]] || { echo "FATAL: $LIB_SELECTOR not found"; exit 1; }

TMP_DIRS=()
new_tmp() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/stop-after-phase.XXXXXX")
  TMP_DIRS+=("$d")
  echo "$d"
}
cleanup_all() {
  local d
  for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup_all EXIT

# ───────────────────────────────────────────────────────────────────────
# I3.2 — invalid phase name rejected with exit 2
# ───────────────────────────────────────────────────────────────────────
{
  TC_DIR=$(new_tmp)
  RC=0
  bash "$AUTOPILOT_SH" --stop-after-phase foobar nonsense-task >"$TC_DIR/out" 2>"$TC_DIR/err" || RC=$?
  check "I3.2: exit 2 on invalid phase"    test "$RC" -eq 2
  check "I3.2: stderr contains Invalid phase: 'foobar'" \
    grep -F -q "Invalid phase: 'foobar'" "$TC_DIR/err"
  check "I3.2: stderr lists valid phases" \
    grep -F -q "Valid phases: ba plan testplan review implement qa static-analysis commit" "$TC_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# I3.3 — empty-string phase rejected with exit 2
# ───────────────────────────────────────────────────────────────────────
{
  TC_DIR=$(new_tmp)
  RC=0
  bash "$AUTOPILOT_SH" --stop-after-phase "" nonsense-task >"$TC_DIR/out" 2>"$TC_DIR/err" || RC=$?
  check "I3.3: exit 2 on empty phase"      test "$RC" -eq 2
  check "I3.3: stderr contains Invalid phase: ''" \
    grep -F -q "Invalid phase: ''" "$TC_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# I3.4 — typo'd phase rejected with exit 2
# ───────────────────────────────────────────────────────────────────────
{
  TC_DIR=$(new_tmp)
  RC=0
  bash "$AUTOPILOT_SH" --stop-after-phase ba-typo nonsense-task >"$TC_DIR/out" 2>"$TC_DIR/err" || RC=$?
  check "I3.4: exit 2 on typo'd phase"     test "$RC" -eq 2
  check "I3.4: stderr contains Invalid phase: 'ba-typo'" \
    grep -F -q "Invalid phase: 'ba-typo'" "$TC_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# I3.6 — missing flag value rejected with exit 2 + helpful message
# ───────────────────────────────────────────────────────────────────────
{
  TC_DIR=$(new_tmp)
  RC=0
  bash "$AUTOPILOT_SH" --stop-after-phase >"$TC_DIR/out" 2>"$TC_DIR/err" || RC=$?
  check "I3.6: exit 2 on missing value"    test "$RC" -eq 2
  check "I3.6: stderr names the flag" \
    grep -F -q -- "--stop-after-phase requires a phase name" "$TC_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# I3.7 — next token is a flag-shaped value (EC8): downstream validation
# rejects it with exit 2 and Invalid phase '--pipeline'
# ───────────────────────────────────────────────────────────────────────
{
  TC_DIR=$(new_tmp)
  RC=0
  bash "$AUTOPILOT_SH" --stop-after-phase --pipeline light nonsense-task >"$TC_DIR/out" 2>"$TC_DIR/err" || RC=$?
  check "I3.7: exit 2 when value looks like a flag (EC8)" test "$RC" -eq 2
  check "I3.7: stderr names the flag-shaped value" \
    grep -F -q "Invalid phase: '--pipeline'" "$TC_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# I3.9 — reversed --from / --stop-after-phase rejected (AS10)
# ───────────────────────────────────────────────────────────────────────
{
  TC_DIR=$(new_tmp)
  RC=0
  bash "$AUTOPILOT_SH" --from qa --stop-after-phase plan nonsense-task >"$TC_DIR/out" 2>"$TC_DIR/err" || RC=$?
  check "I3.9: exit 2 when stop precedes from in PHASE_ORDER" test "$RC" -eq 2
  check "I3.9: stderr names the offending pair" \
    grep -F -q -- "--stop-after-phase plan precedes --from qa" "$TC_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# I3.10 — R22 no env-var fallback: STOP_AFTER_PHASE env does NOT activate
# the flag. Scan autopilot.sh + autopilot-chain.sh for any env-fallback.
# ───────────────────────────────────────────────────────────────────────
{
  check "I3.10: autopilot.sh has no STOP_AFTER_PHASE env-fallback expansion" \
    bash -c "! grep -E -q '\\\$\\{STOP_AFTER_PHASE_ENV' '$AUTOPILOT_SH'"
  check "I3.10: autopilot-chain.sh has no STOP_AFTER_PHASE env-fallback expansion" \
    bash -c "! grep -E -q '\\\$\\{STOP_AFTER_PHASE_ENV' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# I3.11 — R25 header docstring documents --stop-after-phase
# ───────────────────────────────────────────────────────────────────────
{
  check "I3.11: header documents --stop-after-phase" \
    bash -c "head -90 '$AUTOPILOT_SH' | grep -F -q -- '--stop-after-phase'"
  check "I3.11: header mentions phase-name placeholder syntax" \
    bash -c "head -90 '$AUTOPILOT_SH' | grep -F -q -- '<phase-name>'"
  check "I3.11: header references --from for cross-reference" \
    bash -c "head -90 '$AUTOPILOT_SH' | grep -F -q -- '--from'"
}

# ───────────────────────────────────────────────────────────────────────
# I3.22 — R3/R4 structural: every lifecycle_emit_phase_complete is
# followed (within a few lines) by a should_stop_after_phase ... call
# referencing the same phase. Closes RSK-1 — copy-paste drift if a
# future contributor refactors one phase block.
# ───────────────────────────────────────────────────────────────────────
{
  # Collect (phase, has_stop_check) for each lifecycle_emit_phase_complete
  TMPFILE=$(mktemp "${TMPDIR:-/tmp}/lec-pairs.XXXXXX")
  awk '
    /lifecycle_emit_phase_complete "\$STREAM_FILE" "\$TASK" "[^"]+"/ {
      # extract last quoted token
      n = split($0, parts, "\"")
      phase = parts[n-1]
      # scan next 4 lines for should_stop_after_phase "<phase>"
      found=0
      for (i=1; i<=4; i++) {
        if ((getline nxt) <= 0) break
        if (nxt ~ "should_stop_after_phase \"" phase "\"" && nxt ~ "stop_after_phase_exit \"" phase "\"") {
          found=1
          break
        }
      }
      print phase ":" found
    }
  ' "$AUTOPILOT_SH" > "$TMPFILE"

  EXPECTED_PHASES="ba plan testplan review implement qa static-analysis commit"
  for ph in $EXPECTED_PHASES; do
    line=$(grep -E "^${ph}:" "$TMPFILE" | head -1 || true)
    has_check() {
      [[ "$line" == "${ph}:1" ]]
    }
    check "I3.22: phase '${ph}' has should_stop_after_phase + stop_after_phase_exit after lifecycle_emit_phase_complete" has_check
  done
  rm -f "$TMPFILE"
}

# ───────────────────────────────────────────────────────────────────────
# Structural: autopilot.sh references the new lib helpers
# ───────────────────────────────────────────────────────────────────────
{
  check "S1: autopilot.sh references should_stop_after_phase" \
    bash -c "grep -F -q 'should_stop_after_phase' '$AUTOPILOT_SH'"
  check "S2: autopilot.sh references stop_after_phase_exit" \
    bash -c "grep -F -q 'stop_after_phase_exit' '$AUTOPILOT_SH'"
  check "S3: autopilot.sh defines STOP_AFTER_PHASE global initialiser" \
    bash -c "grep -E -q '^STOP_AFTER_PHASE=\"\"' '$AUTOPILOT_SH'"
  check "S4: autopilot.sh has a --stop-after-phase case branch" \
    bash -c "grep -F -q -- '--stop-after-phase)' '$AUTOPILOT_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# I3.12 — EC7 duplicate flag: last occurrence wins (validate_phase_name
# called against the second value). Reuse the invalid-phase path so the
# test does not need a worktree.
# ───────────────────────────────────────────────────────────────────────
{
  TC_DIR=$(new_tmp)
  RC=0
  bash "$AUTOPILOT_SH" --stop-after-phase ba --stop-after-phase foobar nonsense-task \
    >"$TC_DIR/out" 2>"$TC_DIR/err" || RC=$?
  check "I3.12: duplicate flag — second value wins (validated)" test "$RC" -eq 2
  check "I3.12: stderr names the SECOND value" \
    grep -F -q "Invalid phase: 'foobar'" "$TC_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# Bash 3.2 portability: new lib bodies stay clean
# ───────────────────────────────────────────────────────────────────────
{
  LIB_PAUSE="$REPO_ROOT/adapters/claude-code/claude/tools/lib/autopilot-pause.sh"
  for f in "$LIB_PAUSE" "$LIB_SELECTOR"; do
    check "Bash32: $(basename "$f") has no mapfile" \
      bash -c "! grep -E -q '(^|[[:space:]])mapfile([[:space:]]|\$)' '$f'"
    check "Bash32: $(basename "$f") has no readarray" \
      bash -c "! grep -E -q '(^|[[:space:]])readarray([[:space:]]|\$)' '$f'"
  done
}

# ───────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────
echo ""
echo "---"
printf "Checks: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" $((PASS + FAIL))
if [[ "$FAIL" -ne 0 ]]; then
  printf "Failed: %s\n" "${FAILED_NAMES[*]}"
  exit 1
fi
echo "All stop-after-phase tests passed."
exit 0
