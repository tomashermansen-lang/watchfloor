#!/bin/bash
# Log permission requests to track repeated approvals.
# Triggered by PermissionRequest hook — costs zero API calls.
# Logs to .claude/logs/permissions.jsonl (gitignored).

INPUT=$(cat)

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
mkdir -p "$LOG_DIR"

jq -n \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg tool "$TOOL_NAME" \
  --argjson input "$TOOL_INPUT" \
  '{timestamp: $ts, session_id: $sid, tool: $tool, input: $input}' \
  >> "$LOG_DIR/permissions.jsonl"

exit 0
