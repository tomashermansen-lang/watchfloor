#!/usr/bin/env bash
# bash-stderr-classify.sh — classify a Bash tool result by exit code +
# stderr text into one of seven actionable classes. Emits a single-line
# header `[exit_code=N stderr_class=X]` on stdout.
#
# Background: the canary A/B/C comparison (docs/A_B_test_canary-models/)
# showed 24-38% of all Bash tool calls returned non-zero exits, and the
# agent treated them all the same way (raw stderr in result content).
# Token waste plus parameter-mutation retry loops on errors that are not
# transient (sandbox-denied operations cannot be made to succeed by
# changing flags).
#
# This classifier is the deterministic half of the fix. It is sourced by
# the PostToolUse hook (`classify-bash-result.sh`) and is also callable
# directly for testing or ad-hoc use. The companion CLAUDE.md rubric
# tells the agent how to react to each class.
#
# Usage:
#   bash bash-stderr-classify.sh <exit_code> < <stderr_text>
#   classify_stderr <exit_code> <stderr_text>     # if sourced
#
# Classes (precedence order — first match wins):
#   ok                  exit == 0
#   sandbox_denied      "Operation not permitted" / pkill sandbox shapes
#                       / "sysmon request failed"
#   network_blocked     "Could not resolve host" / "tunnel error"
#   timeout             "timed out" / "killed by signal"
#   permission_denied   "Permission denied" / "EACCES"
#   not_found           "No such file or directory" / "command not found"
#   other               anything else
#
# Sandbox precedence: a pkill that hits the kernel sandbox often
# cascades into downstream "No such file" lines. The sandbox marker is
# the actionable signal — the agent should not retry — so it wins.
#
# Bash 3.2 portable.

set -euo pipefail

# classify_stderr emits the header to stdout. Pure function: no side
# effects, no file writes.
classify_stderr() {
  local exit_code="${1:?exit_code required}"
  local stderr_text="${2:-}"

  local class="other"
  if [[ "$exit_code" == "0" ]]; then
    class="ok"
  elif [[ "$stderr_text" =~ (Operation\ not\ permitted|pkill:\ Cannot\ get\ process\ list|sysmon\ request\ failed) ]]; then
    class="sandbox_denied"
  elif [[ "$stderr_text" =~ (Could\ not\ resolve\ host|tunnel\ error) ]]; then
    class="network_blocked"
  elif [[ "$exit_code" == "124" || "$exit_code" == "137" || "$exit_code" == "143" ]] \
       || [[ "$stderr_text" =~ (timed\ out|[Kk]illed\ by\ signal|^Killed$) ]]; then
    # 124 = gtimeout, 137 = SIGKILL, 143 = SIGTERM — well-known timeout
    # codes; classify by exit before text so bare "Killed" stderr is
    # recognised even without a signal suffix (BSD kill is terser than
    # GNU here).
    class="timeout"
  elif [[ "$stderr_text" =~ (Permission\ denied|EACCES) ]]; then
    class="permission_denied"
  elif [[ "$stderr_text" =~ (No\ such\ file\ or\ directory|command\ not\ found) ]]; then
    class="not_found"
  fi

  printf '[exit_code=%s stderr_class=%s]\n' "$exit_code" "$class"
}

# Direct invocation: read stderr text from stdin, emit header to stdout.
# Sourced consumers skip this branch (BASH_SOURCE != $0).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <exit_code> < <stderr_text>" >&2
    exit 2
  fi
  stderr_text=$(cat)
  classify_stderr "$1" "$stderr_text"
fi
