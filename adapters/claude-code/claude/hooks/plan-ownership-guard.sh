#!/bin/bash
# PreToolUse hook: plan-ownership write authority (plan-ownership Track 2).
#
# Fires on Edit / Write / NotebookEdit of any docs/**/execution-plan.yaml.
# Routes the JSON tool-input to the Python check helper, which:
#   - Allows silently if the target isn't a plan file
#   - Allows in interactive sessions (operator in the loop)
#   - Denies under autopilot when phase /static-analysis (or other phase
#     agents) attempt sibling-task or unauthorized-field writes
#   - Honors PLAN_WRITE_INTENT carve-outs for legitimate orchestrator
#     helpers (deviation-tracker.py, commit-finalize.sh, etc.)
#
# WHY: 7d434e3 was a Haiku /static-analysis agent silently rewriting 6
# sibling canary task descriptions while ostensibly fixing a validator
# warning. This hook makes that mechanically impossible under autopilot.
#
# Returns:
#   exit 0  permissionDecision=allow (on stdout as JSON)
#   exit 2  permissionDecision=deny  (on stdout as JSON) — Claude Code
#           contract: nonzero exit + JSON output blocks the tool call AND
#           feeds permissionDecisionReason back to the agent as stderr.
#
# Pure pass-through: the heavy lifting lives in
# adapters/claude-code/claude/tools/lib/plan-ownership-check.py.

set -uo pipefail

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_HOOK_DIR/../../../.." 2>/dev/null && pwd || echo "")"
_CHECK_PY="$_REPO_ROOT/adapters/claude-code/claude/tools/lib/plan-ownership-check.py"

# When deployed via sync.sh, the script lives in ~/.claude/hooks/ and the
# Python helper at ~/.claude/tools/lib/. Try both layouts.
if [[ ! -f "$_CHECK_PY" ]]; then
    _CHECK_PY="$HOME/.claude/tools/lib/plan-ownership-check.py"
fi

if [[ ! -f "$_CHECK_PY" ]]; then
    # Fail-open if helper missing — don't break the user's session.
    echo "[plan-ownership-guard] WARN: helper not found at $_CHECK_PY; allowing." >&2
    echo '{"permissionDecision":"allow"}'
    exit 0
fi

# Read stdin once; pass to Python.
INPUT=$(cat)

# Sandbox-safe temp dir (TMPDIR is set by the harness).
_TMP_OUT="${TMPDIR:-/tmp}/.plan-ownership-stdout.$$"
trap 'rm -f "$_TMP_OUT"' EXIT

# Run the checker. It writes a JSON decision to stdout and exits 0 on
# allow / 1 on deny / 2 on malformed input. We redirect stdout to a temp
# file so we can interleave stderr-to-stderr without mixing the channels.
_STDERR=$(echo "$INPUT" | python3 "$_CHECK_PY" 2>&1 >"$_TMP_OUT")
_RC=$?

# Surface the python stderr to our stderr (logs, hook diagnostics).
[[ -n "$_STDERR" ]] && echo "$_STDERR" >&2

# Emit the JSON decision to OUR stdout (where Claude Code reads it).
[[ -f "$_TMP_OUT" ]] && cat "$_TMP_OUT"

# Map python exit codes to hook exit codes per Claude Code PreToolUse contract:
#   - 0  → allow (do nothing — hook returns success)
#   - 1  → deny (hook returns 2; Claude Code interprets exit 2 as a denial)
#   - 2  → malformed input → fail-open with stderr noise
case "$_RC" in
    0) exit 0 ;;
    1) exit 2 ;;
    *) exit 0 ;;
esac
