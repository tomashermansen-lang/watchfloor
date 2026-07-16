#!/usr/bin/env bash
# autopilot-stub.sh — offline stub fixture for the autopilot.PAUSE
# integration test. Mimics the phase-loop shape of the real autopilot.sh
# using three named phases (stub-phase-1, stub-phase-2, stub-phase-3).
#
# This fixture SOURCES the real lib/autopilot-pause.sh — do NOT redefine
# check_pause_file or _stale_pause_cleanup here. The test exercises the
# literal production helper (closes RSK-4 in PLAN.md).
#
# Environment inputs:
#   WORKDIR              required — directory where autopilot.PAUSE
#                        is created and observed.
#   STUB_PAUSE_BEFORE    optional — phase name BEFORE which the fixture
#                        creates ${WORKDIR}/autopilot.PAUSE (used by
#                        test cases that need a pause injected between
#                        phases without an external timer).
#
# Outputs:
#   stdout — one "ran:<phase>" line per phase block that runs.
#   stderr — log() stub writes here; dashboard_event() stub writes to
#            the file pointed to by $DASHBOARD_EVENT_LOG (default /dev/null).
#
# The fixture never invokes claude -p, git, tmux, gtimeout, or the real
# dashboard_event. R10 forbids those.

set -euo pipefail

: "${WORKDIR:?WORKDIR is required}"
STUB_PAUSE_BEFORE="${STUB_PAUSE_BEFORE:-}"
DASHBOARD_EVENT_LOG="${DASHBOARD_EVENT_LOG:-/dev/null}"

# Stub log() — writes to stderr so the test can grep it.
log() { printf '%s\n' "$*" >&2; }

# Stub dashboard_event() — no-op append to a capture file.
dashboard_event() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$DASHBOARD_EVENT_LOG"; }

# Source the real lib so the test exercises the literal production
# helper (RSK-4 closure). Resolve path from this fixture's location:
# dashboard/tests/fixtures/autopilot-stub.sh  →  repo root  →  lib.
FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$FIXTURE_DIR/../../.." && pwd)"
# shellcheck source=../../../adapters/claude-code/claude/tools/lib/autopilot-pause.sh
source "$REPO_ROOT/adapters/claude-code/claude/tools/lib/autopilot-pause.sh"

_maybe_inject_pause_before() {
  local next_phase="$1"
  if [[ "$STUB_PAUSE_BEFORE" == "$next_phase" ]]; then
    touch "${WORKDIR}/autopilot.PAUSE"
  fi
}

# Block 1 — stub-phase-1
check_pause_file "stub-phase-1"
echo "ran:stub-phase-1"
_maybe_inject_pause_before "stub-phase-2"

# Block 2 — stub-phase-2
check_pause_file "stub-phase-2"
echo "ran:stub-phase-2"
_maybe_inject_pause_before "stub-phase-3"

# Block 3 — stub-phase-3
check_pause_file "stub-phase-3"
echo "ran:stub-phase-3"

exit 0
