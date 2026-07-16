#!/usr/bin/env bash
# Regression guard: run_gated_phase must ESCALATE with an action-forcing
# directive when a phase completes cleanly but its required artifact is
# missing — instead of re-issuing the byte-identical prompt.
#
# Why: in the canary-models A/B run (2026-06-02) Claude Opus 4.8 ran the /ba
# phase, explored the codebase for 27 turns, and ended its turn (stop_reason
# end_turn, no error) WITHOUT writing REQUIREMENTS.md. The original retry
# re-ran the identical command and failed identically. A pipeline whose
# correctness depends on the model voluntarily producing the deliverable is
# fragile across model versions (Opus 4.7 wrote it; 4.8 did not; a future
# Sonnet may regress). The fix injects a forcing directive into
# EXTRA_SYSTEM_PROMPT on the artifact-missing retry so the harness — not the
# model's goodwill — guarantees the deliverable is demanded.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

PASS=0
FAIL=0
check() {
  local desc="$1" fn="$2"
  if "$fn"; then echo "  ok: $desc"; PASS=$((PASS + 1));
  else echo "  FAIL: $desc"; FAIL=$((FAIL + 1)); fi
}

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gated_force.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

PROMPTS="$TEST_DIR/prompts.txt"

# Drive run_gated_phase with stubs. run_phase records (newline-collapsed) the
# EXTRA_SYSTEM_PROMPT it observed on each invocation; check_artifact always
# fails so both attempts run and we can inspect the retry's prompt.
run_missing_artifact() {
  : > "$PROMPTS"
  bash -c "
    STREAM_FILE='$TEST_DIR/stream.ndjson'
    AUTOPILOT_SID=t; DASHBOARD_DATA=/dev/null; TASK=t
    EXTRA_SYSTEM_PROMPT='ORIGINAL_CALLER_PROMPT'
    export STREAM_FILE AUTOPILOT_SID DASHBOARD_DATA TASK EXTRA_SYSTEM_PROMPT
    source '$LIB'
    log() { :; }
    fail_pipeline() { return 1; }
    run_phase() { printf 'CALL<<%s>>\n' \"\$(printf '%s' \"\${EXTRA_SYSTEM_PROMPT:-}\" | tr '\n' ' ')\"; return 0; } >> '$PROMPTS'
    check_artifact() { return 1; }
    commit_phase() { :; }
    track_phase() { :; }
    run_gated_phase 'cmd' 'Business Analysis' '$TEST_DIR' '$TEST_DIR/REQUIREMENTS.md' 'msg' 'art' || true
  " 2>/dev/null
}

line1() { sed -n '1p' "$PROMPTS"; }
line2() { sed -n '2p' "$PROMPTS"; }

test_two_attempts() {
  run_missing_artifact
  local n; n=$(grep -c '^CALL<<' "$PROMPTS")
  [[ "$n" == "2" ]] || { echo "    expected 2 run_phase calls, got $n"; return 1; }
}
check "two attempts run when artifact missing" test_two_attempts

# --- Attempt 1: PREVENTIVE deliverable contract (steers first-go success) ---

test_attempt1_has_contract() {
  line1 | grep -q 'DELIVERABLE CONTRACT' || { echo "    attempt 1 missing preventive contract; got: $(line1)"; return 1; }
}
check "attempt 1 carries the preventive deliverable contract" test_attempt1_has_contract

test_attempt1_names_artifact() {
  line1 | grep -q 'REQUIREMENTS.md' || { echo "    attempt 1 contract omits the artifact path; got: $(line1)"; return 1; }
}
check "attempt 1 contract names the required artifact" test_attempt1_names_artifact

test_attempt1_not_escalated() {
  ! line1 | grep -q 'FORCED COMPLETION' || { echo "    attempt 1 should NOT carry the escalated forcing directive"; return 1; }
}
check "attempt 1 is preventive, not the escalated retry" test_attempt1_not_escalated

test_attempt1_preserves_caller_prompt() {
  line1 | grep -q 'ORIGINAL_CALLER_PROMPT' || { echo "    attempt 1 clobbered the caller's EXTRA_SYSTEM_PROMPT"; return 1; }
}
check "attempt 1 appends to (not replaces) caller prompt" test_attempt1_preserves_caller_prompt

# --- Attempt 2: ESCALATED forcing directive (backstop for the rare miss) ---

test_attempt2_forces_action() {
  line2 | grep -q 'FORCED COMPLETION' || { echo "    attempt 2 missing escalated forcing language; got: $(line2)"; return 1; }
}
check "attempt 2 escalates to the forcing directive" test_attempt2_forces_action

test_attempt2_names_artifact() {
  line2 | grep -q 'REQUIREMENTS.md' || { echo "    attempt 2 directive omits the artifact path; got: $(line2)"; return 1; }
}
check "attempt 2 directive names the missing artifact" test_attempt2_names_artifact

test_attempt2_preserves_caller_prompt() {
  line2 | grep -q 'ORIGINAL_CALLER_PROMPT' || { echo "    attempt 2 clobbered the caller's EXTRA_SYSTEM_PROMPT"; return 1; }
}
check "attempt 2 appends to (not replaces) caller prompt" test_attempt2_preserves_caller_prompt

# --- Shared helper (build_deliverable_contract) used by gated phases AND /implement ---

helper_out() { bash -c "source '$LIB' 2>/dev/null; build_deliverable_contract '$1'"; }

test_helper_builds_contract() {
  local out; out=$(helper_out 'WIDGET.md is committed')
  echo "$out" | grep -q 'DELIVERABLE CONTRACT' \
    && echo "$out" | grep -q 'WIDGET.md is committed' \
    && echo "$out" | grep -q 'Do NOT end your turn' \
    || { echo "    helper output: $out"; return 1; }
}
check "build_deliverable_contract emits contract + the deliverable" test_helper_builds_contract

test_helper_is_preventive() {
  ! helper_out 'X' | grep -q 'FORCED COMPLETION' || { echo "    helper should carry no escalation language"; return 1; }
}
check "build_deliverable_contract is preventive (no escalation language)" test_helper_is_preventive

# --- /implement (run_phase path, contract-only) is wired to the helper ---

test_implement_wired_with_contract() {
  grep -q 'build_deliverable_contract "the implementation and its tests' \
    "$REPO_ROOT/adapters/claude-code/claude/tools/autopilot.sh" \
    || { echo "    /implement does not wire the preventive contract"; return 1; }
}
check "/implement wires the preventive deliverable contract" test_implement_wired_with_contract

echo ""
echo "test_gated_phase_artifact_forcing: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
