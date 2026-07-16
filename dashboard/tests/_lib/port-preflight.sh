# dashboard/tests/_lib/port-preflight.sh
#
# Sourced shell library exposing two functions:
#   port_preflight <port>  — fail loudly if a process holds <port>;
#                            silent on a free port.
#   port_reaper    <port>  — best-effort SIGKILL every process holding
#                            <port>; silent on a free port; loud if
#                            anything survives within the 2s timeout.
#
# Purpose: dashboard test fixtures spawn uvicorn / serve.py on hard-coded
# or random ports, then poll /health. If the bind silently loses to a
# stale listener the tests run against unrelated code (orphan-uvicorn
# anti-pattern, BACKLOG.md #52). Sourcing this helper and calling
# port_preflight before each spawn turns the silent failure into a fast,
# loud abort. port_reaper, called from the cleanup trap, kills any
# detached children that outlive the foreground SERVER_PID so the next
# test starts with a clean port.
#
# Exit-code matrix (both functions):
#   0  silent success — free port (preflight) / port now free (reaper)
#   1  port held (preflight) or surviving PID(s) after kill (reaper)
#   2  invalid port argument (missing / non-numeric / out of 1..65535)
#   3  lsof not found on PATH
#
# Stderr line shape on failure:
#   PREFLIGHT FAIL: invalid port <arg>
#   PREFLIGHT FAIL: lsof not found
#   PREFLIGHT FAIL: port <port> held by PID(s) <pids>
#   REAPER FAIL: invalid port <arg>
#   REAPER FAIL: lsof not found
#   REAPER FAIL: port <port> still held by PID(s) <pids>
#
# Usage:
#   source "$SCRIPT_DIR/_lib/port-preflight.sh"
#   port_preflight "$PORT"   # fails fast on held port; set -e aborts test
#   # ... spawn server ...
#   trap 'port_reaper "$PORT" || true' EXIT  # or appended to existing cleanup
#
# R1 contract: source pulls exactly `port_preflight` and `port_reaper`
# into the caller's scope. The validation, lsof-presence, and lsof-query
# logic is inlined into both functions so no `_port_preflight_*` private
# helpers leak into the consumer's namespace (verified by TC-A2).

# shellcheck shell=bash

port_preflight() {
  local arg="${1:-}"
  case "$arg" in
    "" | *[!0-9]*)
      printf 'PREFLIGHT FAIL: invalid port %s\n' "${1:-<missing>}" >&2
      return 2
      ;;
  esac
  if [ "$arg" -lt 1 ] || [ "$arg" -gt 65535 ]; then
    printf 'PREFLIGHT FAIL: invalid port %s\n' "$arg" >&2
    return 2
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    printf 'PREFLIGHT FAIL: lsof not found\n' >&2
    return 3
  fi
  local pids
  pids=$(lsof -nP -iTCP:"$arg" -sTCP:LISTEN -t 2>/dev/null || true)
  if [ -z "$pids" ]; then
    return 0
  fi
  local pids_inline
  pids_inline=$(printf '%s' "$pids" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  printf 'PREFLIGHT FAIL: port %s held by PID(s) %s\n' "$arg" "$pids_inline" >&2
  return 1
}

port_reaper() {
  local arg="${1:-}"
  case "$arg" in
    "" | *[!0-9]*)
      printf 'REAPER FAIL: invalid port %s\n' "${1:-<missing>}" >&2
      return 2
      ;;
  esac
  if [ "$arg" -lt 1 ] || [ "$arg" -gt 65535 ]; then
    printf 'REAPER FAIL: invalid port %s\n' "$arg" >&2
    return 2
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    printf 'REAPER FAIL: lsof not found\n' >&2
    return 3
  fi

  local pids
  pids=$(lsof -nP -iTCP:"$arg" -sTCP:LISTEN -t 2>/dev/null || true)
  if [ -z "$pids" ]; then
    return 0
  fi

  # Best-effort SIGKILL on every PID. Caller may not own the process —
  # ignore per-PID failures; the surviving-PID poll below catches anything
  # that lives.
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done <<<"$pids"

  # Poll up to 10×0.2s = 2s for the port to clear (R21).
  local _PORT_REAPER_INTERVAL=0.2
  local _PORT_REAPER_TRIES=10
  local i=0
  while [ "$i" -lt "$_PORT_REAPER_TRIES" ]; do
    pids=$(lsof -nP -iTCP:"$arg" -sTCP:LISTEN -t 2>/dev/null || true)
    if [ -z "$pids" ]; then
      return 0
    fi
    sleep "$_PORT_REAPER_INTERVAL"
    i=$((i + 1))
  done

  pids=$(lsof -nP -iTCP:"$arg" -sTCP:LISTEN -t 2>/dev/null || true)
  if [ -z "$pids" ]; then
    return 0
  fi
  local pids_inline
  pids_inline=$(printf '%s' "$pids" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  printf 'REAPER FAIL: port %s still held by PID(s) %s\n' "$arg" "$pids_inline" >&2
  return 1
}
