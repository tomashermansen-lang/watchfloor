#!/usr/bin/env bash
# Phase integration-gate entrypoint (real integration gates §4.4).
#
# autopilot-chain.sh runs this as a SUBPROCESS at a phase boundary, rather than
# sourcing the gate machinery into its own long-lived process. Two reasons:
#   1. The gate runs agent-influenced code UNSANDBOXED (its purpose) — isolating
#      it in a throwaway process caps the blast radius (§6a Guard #4) and is the
#      seam the §4.5 "gate as mini-feature" (worktree/lifecycle) hooks into.
#   2. The chain process sits next to the documented bash-3.2 exit-hang; not
#      loading ~50 extra lib functions / FDs into it keeps that surface small.
#
# Usage:  printf '<checklist-json>' | phase-integration-gate.sh <repo_root> <report_dir> <phase_id>
# stdout: the verdict — exactly one of: none | passed | failed
# stderr: the streamed gate log (operator-facing)
# Exit:   0 = passed / skipped / none (gate does not block)
#         1 = failed (a command failed under INTEGRATION_GATE_MODE=deny)
#         2 = usage error
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-session-lib.sh
source "$DIR/claude-session-lib.sh" 2>/dev/null || { echo "failed"; exit 1; }

# The gate machinery logs via log(); route it to stderr so stdout carries only
# the verdict the chain parses.
log() { printf '%s\n' "$*" >&2; }

if [[ $# -ne 3 ]]; then
  echo "usage: phase-integration-gate.sh <repo_root> <report_dir> <phase_id>" >&2
  exit 2
fi

checklist="$(cat)"
verdict="$(evaluate_phase_integration_checks "$checklist" "$1" "$2" "$3")"
printf '%s\n' "$verdict"
[[ "$verdict" == "failed" ]] && exit 1
exit 0
