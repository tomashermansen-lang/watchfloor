#!/bin/bash
# PostToolUse hook: Log all Bash command invocations for security audit.
# Appends to .claude/logs/bash-audit.jsonl (gitignored).
# Zero token cost — pure shell, no LLM invocation.

INPUT=$(cat)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
mkdir -p "$LOG_DIR"

jq -n \
    --arg ts "$TIMESTAMP" \
    --arg sid "$SESSION_ID" \
    --arg cmd "$COMMAND" \
    '{timestamp: $ts, session_id: $sid, tool: "Bash", command: $cmd}' \
    >> "$LOG_DIR/bash-audit.jsonl"

exit 0
