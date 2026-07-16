#!/usr/bin/env bash
# Stop hook that forces a gated phase to produce its file artifact before the
# agent can end its turn. Deterministic backstop to the prompt contract for the
# "end-turn-without-artifact" failure (canary-models 2026-06-02).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/adapters/claude-code/claude/hooks/phase-artifact-stop-guard.sh"

PASS=0
FAIL=0
check() { if "$2"; then echo "  ok: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stopguard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"

# Run the hook: $1=PHASE_ARTIFACT_PATH (empty=unset-gate), $2=session_id, $3=max
run_hook() {
  local art="$1" sid="$2" maxf="${3:-3}"
  PHASE_ARTIFACT_PATH="$art" PHASE_ARTIFACT_STATE_DIR="$STATE" PHASE_ARTIFACT_MAX_FORCED="$maxf" \
    bash "$HOOK" <<<"{\"session_id\":\"$sid\",\"stop_hook_active\":false,\"hook_event_name\":\"Stop\"}"
}

test_noop_when_unset() {
  local o; o=$(run_hook "" s-unset)
  [[ -z "$o" ]] || { echo "    expected no output when PHASE_ARTIFACT_PATH unset; got: $o"; return 1; }
}
check "no-op when PHASE_ARTIFACT_PATH is unset (other sessions unaffected)" test_noop_when_unset

test_allows_when_artifact_exists() {
  local art="$TMP/exists.md"; echo x > "$art"
  local o; o=$(run_hook "$art" s-exists)
  [[ -z "$o" ]] || { echo "    expected no block when artifact exists; got: $o"; return 1; }
}
check "allows stop when artifact already exists" test_allows_when_artifact_exists

test_blocks_when_missing() {
  local art="$TMP/missing-req.md"
  local o; o=$(run_hook "$art" s-miss)
  echo "$o" | grep -q '"decision":[[:space:]]*"block"' || { echo "    expected block decision; got: $o"; return 1; }
}
check "blocks stop when artifact is missing" test_blocks_when_missing

test_block_reason_names_artifact() {
  local art="$TMP/named-req.md"
  local o; o=$(run_hook "$art" s-named)
  echo "$o" | grep -q "named-req.md" || { echo "    block reason omits the artifact path; got: $o"; return 1; }
}
check "block reason names the missing artifact" test_block_reason_names_artifact

test_block_output_is_valid_json() {
  local art="$TMP/json-req.md"
  run_hook "$art" s-json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["decision"]=="block"; assert d["reason"]' \
    || { echo "    block output is not valid JSON with decision+reason"; return 1; }
}
check "block output is valid JSON (decision=block + reason)" test_block_output_is_valid_json

test_caps_forced_continuations() {
  local art="$TMP/cap-req.md" sid=s-cap
  local b1 b2 b3
  b1=$(run_hook "$art" "$sid" 2); b2=$(run_hook "$art" "$sid" 2); b3=$(run_hook "$art" "$sid" 2)
  echo "$b1" | grep -q block || { echo "    call 1 should block"; return 1; }
  echo "$b2" | grep -q block || { echo "    call 2 should block"; return 1; }
  [[ -z "$b3" ]] || { echo "    call 3 should defer (no block) at max=2; got: $b3"; return 1; }
}
check "caps forced continuations (defers to retry past the cap)" test_caps_forced_continuations

test_failopen_empty_stdin() {
  # Empty stdin must not crash; with a missing artifact it still blocks.
  local art="$TMP/empty-stdin.md" o
  o=$(PHASE_ARTIFACT_PATH="$art" PHASE_ARTIFACT_STATE_DIR="$STATE" bash "$HOOK" </dev/null; echo "rc=$?")
  echo "$o" | grep -q 'rc=0' || { echo "    hook should exit 0 on empty stdin; got: $o"; return 1; }
}
check "fail-open on empty stdin (exit 0, no crash)" test_failopen_empty_stdin

echo ""
echo "test_phase_artifact_stop_guard: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
