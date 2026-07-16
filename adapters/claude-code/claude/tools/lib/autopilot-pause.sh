#!/usr/bin/env bash
# autopilot-pause.sh — between-phase pause control file primitive.
#
# Mirrors the chain.PAUSE pattern in autopilot-chain.sh:413,859,977.
# Two responsibilities live here:
#
#   check_pause_file <phase-name>   pause primitive invoked at the TOP of
#                                   every phase boundary in autopilot.sh.
#                                   When ${WORKDIR}/autopilot.PAUSE exists
#                                   as a regular file, log the pause
#                                   message via log(), emit a SessionEnd
#                                   "paused at <phase>" dashboard event,
#                                   and exit 0. Absent file → return 0
#                                   silently (no I/O, no observable
#                                   latency).
#
#   _stale_pause_cleanup            invoked once at session start (after
#                                   STREAM_FILE is initialised). When a
#                                   leftover autopilot.PAUSE regular file
#                                   exists in $WORKDIR, log a warning and
#                                   remove it so the first phase
#                                   boundary does not falsely fire.
#
# Both helpers reference log() and dashboard_event() by name — bash
# late-binding resolves them at call time, so tests can inject stubs.
# WORKDIR must be set before either helper is invoked.
#
# The pause file path is exactly ${WORKDIR}/autopilot.PAUSE. It is NOT
# configurable — the worktree-relative path is the public contract that
# the dashboard pause endpoint will bind against.

# Source the adjacent lifecycle emitter library so check_pause_file can
# append a `paused` lifecycle record to ${STREAM_FILE} before exit. The
# guard avoids double-sourcing when autopilot.sh has already pulled it in.
if ! declare -F lifecycle_emit_paused >/dev/null 2>&1; then
  # shellcheck source=lifecycle-emit.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lifecycle-emit.sh"
fi

# Source phase-selector.sh for phase_index used by stop_after_phase_exit's
# resume-hint computation. Guarded on phase_index so autopilot.sh's prior
# source is not re-run.
if ! declare -F phase_index >/dev/null 2>&1; then
  # shellcheck source=phase-selector.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/phase-selector.sh"
fi

check_pause_file() {
  local phase="$1"
  if [[ -f "${WORKDIR}/autopilot.PAUSE" ]]; then
    log "Paused at phase boundary ${phase}"
    dashboard_event "SessionEnd" "autopilot" "paused at ${phase}"
    # lifecycle paused emit — see adapters/claude-code/claude/tools/lib/lifecycle-emit.sh.
    # ${STREAM_FILE:-} / ${TASK:-} defaults keep set -u happy if sourced
    # before autopilot.sh has initialised those vars (E1).
    lifecycle_emit_paused "${STREAM_FILE:-}" "${TASK:-}" "$phase"
    exit 0
  fi
}

_stale_pause_cleanup() {
  if [[ -f "${WORKDIR}/autopilot.PAUSE" ]]; then
    log "${YELLOW:-}⚠${NC:-} Stale autopilot.PAUSE detected at session start — removing before pipeline starts"
    rm -f "${WORKDIR}/autopilot.PAUSE"
  fi
}

# stop_after_phase_exit <phase-name>
# Graceful exit-0 sequence for the --stop-after-phase CLI flag.
# Sibling of check_pause_file: same between-phase exit semantics, but
# triggered by an explicit flag rather than the autopilot.PAUSE sentinel.
# Sets PIPELINE_STATUS=partial, computes TOTAL_DURATION, writes the
# summary, emits one paused lifecycle record + one SessionEnd dashboard
# event, logs a banner with a --from <next-phase> resume hint, and
# exits 0. Worktree, branch, and feature dir are left untouched (R7).
stop_after_phase_exit() {
  local phase="$1"
  # PIPELINE_STATUS / TOTAL_END / TOTAL_DURATION are read by write_summary
  # (defined in autopilot.sh; late-binding pattern, mirrors
  # check_pause_file's use of log/dashboard_event).
  # shellcheck disable=SC2034
  PIPELINE_STATUS="partial"
  local _total_end
  _total_end=$(date +%s)
  # shellcheck disable=SC2034
  TOTAL_END="$_total_end"
  # shellcheck disable=SC2034
  TOTAL_DURATION=$(( _total_end - ${TOTAL_START:-_total_end} ))
  write_summary
  lifecycle_emit_paused "${STREAM_FILE:-}" "${TASK:-}" "$phase"
  dashboard_event "SessionEnd" "autopilot" "stopped after ${phase}"

  local _next_hint=""
  if declare -F phase_index >/dev/null 2>&1; then
    local _idx
    if _idx=$(phase_index "$phase" 2>/dev/null); then
      local _next_idx=$(( _idx + 1 ))
      if [[ -n "${PHASE_ORDER[$_next_idx]+x}" ]]; then
        _next_hint="${PHASE_ORDER[$_next_idx]}"
      fi
    fi
  fi

  log "${YELLOW:-}⏸${NC:-} STOPPED — halted after phase '${phase}'"
  if [[ -n "$_next_hint" ]]; then
    log "  Resume with: bash autopilot.sh --from ${_next_hint} ${TASK:-<task>}"
  else
    log "  Resume with: bash autopilot.sh --from <phase> ${TASK:-<task>}"
  fi
  exit 0
}
