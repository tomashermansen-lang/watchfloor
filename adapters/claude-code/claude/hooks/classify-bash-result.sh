#!/usr/bin/env bash
# PostToolUse hook for the Bash tool: classify the result by exit_code +
# stderr shape and emit a structured header back to the agent via the
# additionalContext channel.
#
# Background: canary A/B/C measured 24-38% of all Bash tool calls
# returning non-zero exits. Without a structured signal, the agent
# treated them all the same way (raw stderr → variation retries on
# errors that cannot be retried). This hook prepends an actionable
# class to every Bash result so the agent can short-circuit:
#
#   [exit_code=1 stderr_class=sandbox_denied]
#
# The agent-side rubric for what to do with each class lives in
# adapters/claude-code/claude/CLAUDE.md under "Bash error class rubric".
#
# Output protocol: JSON on stdout with hookSpecificOutput.additionalContext.
# Claude Code surfaces this string to the model on the next turn.
# Failure is non-blocking — exit 0 with no JSON keeps the existing
# transcript intact.

set -euo pipefail

CLASSIFIER="$HOME/.claude/tools/lib/bash-stderr-classify.sh"
# Source-of-truth fallback for editable installs that still point at the
# dotfiles repo. The deployed copy under ~/.claude/tools/lib/ is the
# canonical path after `sync.sh restore`.
[[ -f "$CLASSIFIER" ]] || CLASSIFIER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/lib/bash-stderr-classify.sh"
[[ -f "$CLASSIFIER" ]] || exit 0

INPUT=$(cat)

# Extract exit_code + stderr from the PostToolUse payload. Claude Code's
# Bash tool result schema exposes interrupted/output; we look for stderr
# under tool_response/result/output. Schema may evolve — be tolerant.
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    resp = data.get("tool_response") or data.get("result") or {}
    exit_code = resp.get("exit_code")
    if exit_code is None:
        exit_code = resp.get("returncode")
    if exit_code is None:
        exit_code = 1 if resp.get("is_error") else 0
    stderr = resp.get("stderr") or ""
    if not stderr:
        stderr = (resp.get("output") or "")[:4096]
    stderr = stderr.replace("\n", " ").replace("\r", " ")
    print(int(exit_code))
    print(stderr)
except Exception:
    print(0)
    print("")
' 2>/dev/null) || exit 0

EXIT_CODE=$(printf '%s' "$PARSED" | head -1)
STDERR=$(printf '%s' "$PARSED" | tail -n +2)

HEADER=$(bash "$CLASSIFIER" "$EXIT_CODE" <<<"$STDERR" 2>/dev/null || echo "")
[[ -z "$HEADER" ]] && exit 0

# Emit additionalContext for the agent. The hookSpecificOutput shape is
# Claude Code's documented PostToolUse extension point — the string is
# injected verbatim into the model's next-turn context.
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' \
  "$(printf '%s' "$HEADER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
exit 0
