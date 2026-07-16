#!/usr/bin/env bash
# lifecycle-emit.sh — shared lifecycle NDJSON emitters for autopilot.sh,
# autopilot-chain.sh, and lib/autopilot-pause.sh.
#
# Each emit writes one NDJSON record to a stream file. The record shape
# is the contract pinned by the predecessor module
# dashboard/server/lifecycle_events.py (see LIFECYCLE_ACTIONS,
# LIFECYCLE_SOURCES, and _TARGET_PATTERN there). Drift between this
# file and that module is caught by the integration test
# dashboard/tests/test-lifecycle-bash-emitters.sh.
#
# Public functions:
#   lifecycle_emit_started        <stream_file> <target>
#   lifecycle_emit_phase_complete <stream_file> <target> <phase>
#   lifecycle_emit_paused         <stream_file> <target> <phase_at_pause>
#   _lifecycle_resolve_source     (echoes ${CONTROL_SOURCE:-cli})
#   _lifecycle_target_valid       <target>  (exit 0 = valid)
#
# Contract invariants:
#   - target MUST match ^[a-zA-Z0-9_-]{1,64}$ — emit is silently skipped
#     otherwise (chain.sh additionally sets LIFECYCLE_DISABLED=1 + WARNING).
#   - source defaults to "cli"; CONTROL_SOURCE=dashboard exports the
#     dashboard-launched value. Any other value is written verbatim and
#     rejected downstream by parse_event — visible failure beats silent
#     coercion.
#   - One emit ≡ one printf '%s\n' ... >> stream — single syscall, atomic
#     for sub-PIPE_BUF writes per POSIX.
#   - Fail-soft: a failed open on the stream file never aborts the
#     caller. set -e tolerance via { ... } 2>/dev/null || true.
#   - Bash 3.2 compatible: no mapfile, no ${var^^}, no nameref.

_lifecycle_resolve_source() {
  printf '%s' "${CONTROL_SOURCE:-cli}"
}

_lifecycle_target_valid() {
  local target="${1:-}"
  [[ "$target" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]
}

lifecycle_emit_started() {
  local stream_file="${1:-}" target="${2:-}"
  _lifecycle_target_valid "$target" || return 0
  local ts source_v
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  source_v=$(_lifecycle_resolve_source)
  { printf '{"ts":"%s","type":"lifecycle","action":"started","source":"%s","target":"%s"}\n' \
      "$ts" "$source_v" "$target" >> "$stream_file"; } 2>/dev/null || true
}

lifecycle_emit_phase_complete() {
  local stream_file="${1:-}" target="${2:-}" phase="${3:-}"
  _lifecycle_target_valid "$target" || return 0
  local ts source_v
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  source_v=$(_lifecycle_resolve_source)
  { printf '{"ts":"%s","type":"lifecycle","action":"phase_complete","source":"%s","target":"%s","phase":"%s"}\n' \
      "$ts" "$source_v" "$target" "$phase" >> "$stream_file"; } 2>/dev/null || true
}

lifecycle_emit_paused() {
  local stream_file="${1:-}" target="${2:-}" phase_at_pause="${3:-}"
  _lifecycle_target_valid "$target" || return 0
  local ts source_v
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  source_v=$(_lifecycle_resolve_source)
  { printf '{"ts":"%s","type":"lifecycle","action":"paused","source":"%s","target":"%s","phase_at_pause":"%s"}\n' \
      "$ts" "$source_v" "$target" "$phase_at_pause" >> "$stream_file"; } 2>/dev/null || true
}
