#!/usr/bin/env bash
# autopilot-chain-stub.sh — offline stub fixture for the chain-side
# lifecycle emitters (R4, R5, R6). Mimics the slice of autopilot-chain.sh
# that derives PLAN_ID, validates it, and invokes the lifecycle helpers,
# without pulling in jq, shlock, claude-session-lib, or a real plan YAML.
#
# Environment inputs:
#   WORKDIR              required — directory the fixture writes into.
#   PLAN_DIR_BASENAME    required — e.g. "INPROGRESS_Plan_demo-plan",
#                        "DONE_Plan_demo-plan", or a deliberately-invalid
#                        value like "bad name" for the AS9 negative path.
#   EVENTS_FILE          required — path to the chain-events.ndjson file
#                        the fixture appends to.
#   STUB_TRIGGER         required — one of "started", "phase_complete",
#                        "paused" (selects the C4/C5/C6 code path).
#   STUB_PHASE_ID        optional — phase id passed to phase_complete
#                        and used as LAST_CHAIN_PHASE for paused.
#                        Defaults to "backend-substrate".
#   LAST_CHAIN_PHASE     optional — override the in-process phase tracker.
#                        Defaults to the value of STUB_PHASE_ID, or empty
#                        string when both are unset (so paused falls back
#                        to "unknown" per R6).
#   CONTROL_SOURCE       optional — passes through to the emitter's
#                        ${CONTROL_SOURCE:-cli} resolution.
#
# Outputs:
#   stdout/stderr — log lines plus any WARNING emitted by the invalid
#                   plan_id path (R8). Lifecycle records go to EVENTS_FILE.
#
# The fixture never invokes claude -p, git, jq, shlock, or tmux. R12
# requires that autopilot-stub.sh remain untouched beyond TASK and
# STREAM_FILE — this file holds the chain-side stub shape separately.

set -euo pipefail

: "${WORKDIR:?WORKDIR is required}"
: "${PLAN_DIR_BASENAME:?PLAN_DIR_BASENAME is required}"
: "${EVENTS_FILE:?EVENTS_FILE is required}"
: "${STUB_TRIGGER:?STUB_TRIGGER is required (started|phase_complete|paused)}"
STUB_PHASE_ID="${STUB_PHASE_ID:-backend-substrate}"
LAST_CHAIN_PHASE="${LAST_CHAIN_PHASE-$STUB_PHASE_ID}"

# Stub log() — chain.sh's log() writes to stderr.
log() { printf '%s\n' "$*" >&2; }

# Stub emit_event() — mirrors the existing chain.sh helper signature so
# the fixture can produce the companion `event=gate_passed` /
# `event=chain_paused` line that the lifecycle emit lands next to.
emit_event() {
  local event_file="$1"; shift
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local json="{\"ts\":\"$ts\""
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local val="${1#*=}"
    json+=",\"$key\":\"$val\""
    shift
  done
  json+="}"
  echo "$json" >> "$event_file"
}

# Resolve fixture's location → repo root → lib/lifecycle-emit.sh.
FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$FIXTURE_DIR/../../.." && pwd)"
# shellcheck source=../../../adapters/claude-code/claude/tools/lib/lifecycle-emit.sh
source "$REPO_ROOT/adapters/claude-code/claude/tools/lib/lifecycle-emit.sh"

# Derive plan_id from the fixture's PLAN_DIR_BASENAME — same logic as
# C4 in autopilot-chain.sh (strip the two known prefixes).
PLAN_ID="$PLAN_DIR_BASENAME"
PLAN_ID="${PLAN_ID#INPROGRESS_Plan_}"
PLAN_ID="${PLAN_ID#DONE_Plan_}"
LIFECYCLE_DISABLED=""
if ! _lifecycle_target_valid "$PLAN_ID"; then
  printf 'WARNING: chain plan_id %q fails target regex — lifecycle events disabled\n' "$PLAN_ID" >&2
  LIFECYCLE_DISABLED=1
fi

case "$STUB_TRIGGER" in
  started)
    if [[ -z "$LIFECYCLE_DISABLED" ]]; then
      lifecycle_emit_started "$EVENTS_FILE" "$PLAN_ID"
    fi
    ;;
  phase_complete)
    emit_event "$EVENTS_FILE" "event=gate_passed" "phase=$STUB_PHASE_ID"
    if [[ -z "$LIFECYCLE_DISABLED" ]]; then
      lifecycle_emit_phase_complete "$EVENTS_FILE" "$PLAN_ID" "$STUB_PHASE_ID"
    fi
    ;;
  paused)
    emit_event "$EVENTS_FILE" "event=chain_paused"
    if [[ -z "$LIFECYCLE_DISABLED" ]]; then
      lifecycle_emit_paused "$EVENTS_FILE" "$PLAN_ID" "${LAST_CHAIN_PHASE:-unknown}"
    fi
    ;;
  *)
    echo "Unknown STUB_TRIGGER: $STUB_TRIGGER (expected started|phase_complete|paused)" >&2
    exit 1
    ;;
esac

exit 0
