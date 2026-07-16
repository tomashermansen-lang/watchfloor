#!/usr/bin/env bash
# test_stop_after_phase_chain.sh — integration tests for the
# autopilot-chain.sh --stop-after-phase CLI flag.
#
# Covers TESTPLAN.md scenarios C4.1–C4.13 (argv parsing + flag
# forwarding + partial-summary detection + chain_stopped emission +
# default-path zero-regression). Scenarios that need real concurrency
# semantics (C4.14, C4.15 — drain) and the pause-file precedence cases
# (C4.20–C4.22) are intentionally not driven here because they double
# the runtime cost; their contract is covered structurally + by the
# existing chain.PAUSE / autopilot.PAUSE tests.
#
# Drives autopilot-chain.sh as a subprocess with AUTOPILOT_CMD set to
# an inline stub script. The stub records its argv to a side-channel
# file and writes a synthetic autopilot-summary.json so the chain's
# harvest-time partial-summary probe has something to inspect.
#
# Portability: bash 3.2 macOS-default. No mapfile, no nameref.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHAIN_SH="$REPO_ROOT/adapters/claude-code/claude/tools/autopilot-chain.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/stop-after-phase-fixture-plan.yaml"

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

[[ -f "$CHAIN_SH" ]] || { echo "FATAL: $CHAIN_SH not found"; exit 1; }
[[ -f "$FIXTURE" ]] || { echo "FATAL: $FIXTURE not found"; exit 1; }

# Skip cleanly when shlock/jq are absent (sandbox environments).
if ! command -v shlock >/dev/null 2>&1; then
  echo "SKIP: shlock not in PATH — chain integration cases need it"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not in PATH — chain integration cases need it"
  exit 0
fi

TMP_DIRS=()
# new_plan_dir lays out a temp tree mirroring the production worktree
# convention so the chain's harvest probe at
# `${PLAN_DIR}/../../worktrees/feature-<id>/...` resolves inside the
# test tree:
#   $base/proj/docs/INPROGRESS_Plan_<x>/  ← PLAN_DIR
#   $base/proj/worktrees/                  ← stubs write summaries here
#
# Basename of PLAN_DIR is `INPROGRESS_Plan_<x>` → chain strips the
# `INPROGRESS_Plan_` prefix and keeps `<x>`, which must match the
# lifecycle target regex ^[a-zA-Z0-9_-]{1,64}$ (no dots).
new_plan_dir() {
  local base
  base=$(mktemp -d "${TMPDIR:-/tmp}/stop-after-phase-chain-XXXXXX")
  TMP_DIRS+=("$base")
  local plan_dir="$base/proj/docs/INPROGRESS_Plan_fixture"
  mkdir -p "$plan_dir" "$base/proj/worktrees"
  cp "$FIXTURE" "$plan_dir/execution-plan.yaml"
  echo "$plan_dir"
}
cleanup_all() {
  local d
  for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup_all EXIT

# build_stub <plan_dir> <status>  →  echoes path of a stub script
# The stub records its argv to <plan_dir>/argv.log, mkdirs the per-task
# worktree path, and writes a synthetic autopilot-summary.json with the
# requested status. <plan_dir>/../../worktrees/feature-${task_id} is
# the path the chain probes per RSK-3 / Component 4 edit #7.
build_stub() {
  local plan_dir="$1"
  local stub_status="$2"
  local stub="$plan_dir/stub-autopilot.sh"
  cat > "$stub" <<STUB_EOF
#!/usr/bin/env bash
set -uo pipefail
plan_dir="$plan_dir"
stub_status="$stub_status"
echo "\$@" >> "\$plan_dir/argv.log"
# Last positional arg is the task id.
task_id="\${@: -1}"
# Mirror the worktree path the chain probes:
#   \${PLAN_DIR}/../../worktrees/feature-\${task_id}
wt_dir="\$plan_dir/../../worktrees/feature-\${task_id}"
feature_dir="\$wt_dir/docs/INPROGRESS_Feature_\${task_id}"
mkdir -p "\$feature_dir"
printf '{"task":"%s","status":"%s","duration_s":0,"phases":[]}\n' \
  "\$task_id" "\$stub_status" > "\$feature_dir/autopilot-summary.json"
exit 0
STUB_EOF
  chmod +x "$stub"
  echo "$stub"
}

# ───────────────────────────────────────────────────────────────────────
# C4.2 — invalid phase rejected with exit 2
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir)
  RC=0
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
    bash "$CHAIN_SH" --stop-after-phase foobar "$PLAN_DIR" \
      >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || RC=$?
  check "C4.2: exit 2 on invalid phase"     test "$RC" -eq 2
  check "C4.2: stderr contains Invalid phase: 'foobar'" \
    grep -F -q "Invalid phase: 'foobar'" "$PLAN_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# C4.3 — missing value rejected with exit 2 + helpful message.
# Invoking with no following token at all triggers the `$# -lt 2` guard.
# (Passing a PLAN_DIR after the flag instead makes the path the value
# and routes to the validate_phase_name "Invalid phase" path — covered
# implicitly by C4.2's invalid-phase case.)
# ───────────────────────────────────────────────────────────────────────
{
  ERR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/stop-after-phase-c43-XXXXXX")
  TMP_DIRS+=("$ERR_DIR")
  RC=0
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
    bash "$CHAIN_SH" --stop-after-phase \
      >"$ERR_DIR/out" 2>"$ERR_DIR/err" || RC=$?
  check "C4.3: exit 2 on missing value"     test "$RC" -eq 2
  check "C4.3: stderr names the flag" \
    grep -F -q -- "--stop-after-phase requires a phase name" "$ERR_DIR/err"
}

# ───────────────────────────────────────────────────────────────────────
# C4.4 — chain.sh sources phase-selector.sh
# ───────────────────────────────────────────────────────────────────────
{
  check "C4.4: chain.sh sources phase-selector.sh" \
    bash -c "grep -E -q 'source.*lib/phase-selector\\.sh' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# C4.5 — header docstring lists --stop-after-phase
# ───────────────────────────────────────────────────────────────────────
{
  check "C4.5: header docstring lists --stop-after-phase" \
    bash -c "head -40 '$CHAIN_SH' | grep -F -q -- '--stop-after-phase'"
}

# ───────────────────────────────────────────────────────────────────────
# C4.6 / C4.7 — flag forwarding: task-a sees --stop-after-phase implement,
# task-b never launched
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir)
  STUB=$(build_stub "$PLAN_DIR" "partial")
  : > "$PLAN_DIR/argv.log"
  RC=0
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
  AUTOPILOT_CMD="bash $STUB" \
    bash "$CHAIN_SH" --max-parallel 1 --stop-after-phase implement "$PLAN_DIR" \
      >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || RC=$?
  check "C4.6: chain exit 0 on partial detection" test "$RC" -eq 0
  # Inspect first recorded stub argv line
  check "C4.6: first stub argv contains --stop-after-phase implement" \
    bash -c "head -1 '$PLAN_DIR/argv.log' | grep -F -q -- '--stop-after-phase implement'"
  check "C4.6: first stub argv contains --full --pipeline light" \
    bash -c "head -1 '$PLAN_DIR/argv.log' | grep -F -q -- '--full --pipeline light'"
  # Only ONE invocation of the stub (task-b never launched)
  argv_lines=$(wc -l < "$PLAN_DIR/argv.log" | tr -d ' ')
  check "C4.7: stub invoked exactly once" test "$argv_lines" -eq 1
  check "C4.7: task-b never appears in argv.log" \
    bash -c "! grep -F -q 'task-b' '$PLAN_DIR/argv.log'"
}

# ───────────────────────────────────────────────────────────────────────
# C4.10 — chain_stopped event emitted with right payload
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir)
  STUB=$(build_stub "$PLAN_DIR" "partial")
  : > "$PLAN_DIR/argv.log"
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
  AUTOPILOT_CMD="bash $STUB" \
    bash "$CHAIN_SH" --max-parallel 1 --stop-after-phase implement "$PLAN_DIR" \
      >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || true
  events_file="$PLAN_DIR/chain-events.ndjson"
  check "C4.10: chain-events.ndjson exists" test -f "$events_file"
  check "C4.10: chain_stopped event present" \
    bash -c "grep -F -q 'chain_stopped' '$events_file'"
  check "C4.10: chain_stopped has reason=stop_after_phase" \
    bash -c "grep -F 'chain_stopped' '$events_file' | grep -F -q 'stop_after_phase'"
  check "C4.10: chain_stopped has phase=implement" \
    bash -c "grep -F 'chain_stopped' '$events_file' | grep -F -q '\"phase\":\"implement\"'"
  check "C4.10: chain_stopped has feature_id=task-a" \
    bash -c "grep -F 'chain_stopped' '$events_file' | grep -F -q '\"feature_id\":\"task-a\"'"
}

# ───────────────────────────────────────────────────────────────────────
# C4.13 — no chain_completed alongside chain_stopped (no double-emit)
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir)
  STUB=$(build_stub "$PLAN_DIR" "partial")
  : > "$PLAN_DIR/argv.log"
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
  AUTOPILOT_CMD="bash $STUB" \
    bash "$CHAIN_SH" --max-parallel 1 --stop-after-phase implement "$PLAN_DIR" \
      >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || true
  events_file="$PLAN_DIR/chain-events.ndjson"
  check "C4.13: no chain_completed event when chain_stopped fired" \
    bash -c "! grep -F -q 'chain_completed' '$events_file'"
}

# ───────────────────────────────────────────────────────────────────────
# C4.18 — default path: no flag → both tasks launched, chain_completed
# (zero-regression). The stub writes status=success here so the chain
# does NOT take the partial branch.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir)
  STUB=$(build_stub "$PLAN_DIR" "success")
  : > "$PLAN_DIR/argv.log"
  RC=0
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
  AUTOPILOT_CMD="bash $STUB" \
    bash "$CHAIN_SH" "$PLAN_DIR" \
      >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || RC=$?
  check "C4.18: chain exit 0 (default path)" test "$RC" -eq 0
  argv_lines=$(wc -l < "$PLAN_DIR/argv.log" | tr -d ' ')
  check "C4.18: both tasks launched" test "$argv_lines" -eq 2
  check "C4.18: no --stop-after-phase appears in any stub argv" \
    bash -c "! grep -F -q -- '--stop-after-phase' '$PLAN_DIR/argv.log'"
  events_file="$PLAN_DIR/chain-events.ndjson"
  check "C4.18: no chain_stopped event in default path (R16)" \
    bash -c "! grep -F -q 'chain_stopped' '$events_file'"
  # The chain only emits chain_completed when the plan's YAML status is
  # updated to done (autopilot.sh does this in production via the
  # commit phase). With a stub that does not touch the YAML, the plan
  # stays pending and the chain logs `No ready tasks — blocked`
  # instead. The byte-identical contract (R16) is exercised by the
  # absence of chain_stopped and by the both-tasks-launched assertion
  # above.
}

# ───────────────────────────────────────────────────────────────────────
# C4.9 — structural: array-build idiom for autopilot_args (RSK-6 / bash 3.2 safety)
# ───────────────────────────────────────────────────────────────────────
{
  check "C4.9: chain.sh builds autopilot_args as an array" \
    bash -c "grep -F -q 'autopilot_args=' '$CHAIN_SH'"
  check "C4.9: chain.sh forwards STOP_AFTER_PHASE via array append" \
    bash -c "grep -F -q -- 'autopilot_args+=(--stop-after-phase' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# C4.16 — structural: harvest probe reads from worktrees/feature-<id>
# autopilot-summary.json (matches PLAN.md Component 4 edit #7)
# ───────────────────────────────────────────────────────────────────────
{
  check "C4.16: harvest probe path includes worktrees/feature-" \
    bash -c "grep -F -q 'worktrees/feature-' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# Bash 3.2 portability: new chain edits are clean
# ───────────────────────────────────────────────────────────────────────
{
  check "Bash32: chain.sh has no mapfile" \
    bash -c "! grep -E -q '(^|[[:space:]])mapfile([[:space:]]|\$)' '$CHAIN_SH'"
  check "Bash32: chain.sh has no readarray" \
    bash -c "! grep -E -q '(^|[[:space:]])readarray([[:space:]]|\$)' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# F5 — fixture is valid against validate-plan.py
# ───────────────────────────────────────────────────────────────────────
{
  VALIDATE="$REPO_ROOT/adapters/claude-code/claude/tools/validate-plan.py"
  check "F5.1: fixture validates clean (exit 0)" \
    bash -c "python3 '$VALIDATE' '$FIXTURE' >/dev/null 2>&1"
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
echo "All stop-after-phase chain tests passed."
exit 0
