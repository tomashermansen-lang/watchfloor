#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Agent Dashboard — Install (hooks + data directory only)
#
#  Commands, skills, tools, schema, and templates are owned
#  by the dotfiles repo and deployed via dotfiles/sync.sh.
#  This script only sets up dashboard-specific observability.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DASHBOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="$DASHBOARD_DIR/hooks/report-status.sh"
SETTINGS="$HOME/.claude/settings.json"
DATA_DIR="$DASHBOARD_DIR/data"
EVENTS=("Notification" "Stop" "TaskCompleted" "SubagentStop" "SubagentStart" "PreToolUse" "PostToolUse" "UserPromptSubmit" "SessionStart" "SessionEnd")

echo "Agent Dashboard — Install"
echo "========================="
echo ""

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed."
  echo "  brew install jq"
  exit 1
fi

# Verify hook script exists
if [ ! -f "$HOOK_PATH" ]; then
  echo "ERROR: Hook script not found at $HOOK_PATH"
  exit 1
fi

# Create data directory with restricted permissions
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
echo "[ok] Data directory: $DATA_DIR (mode 700)"

# Make hook executable
chmod +x "$HOOK_PATH"
echo "[ok] Hook script: $HOOK_PATH"

# Create settings.json if missing
mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
  echo "[ok] Created $SETTINGS"
fi

# Register hooks (idempotent)
HOOK_CMD="bash $HOOK_PATH"
REGISTERED=0
SKIPPED=0

for event in "${EVENTS[@]}"; do
  # Check if this hook command is already registered for this event
  existing=$(jq -r --arg event "$event" --arg cmd "$HOOK_CMD" '
    .hooks[$event] // [] | map(.hooks // [] | map(select(.command == $cmd))) | flatten | length
  ' "$SETTINGS" 2>/dev/null) || existing="0"

  if [ "$existing" != "0" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # PreToolUse/PostToolUse need matcher to specify which tools to listen to
  MATCHER=""
  case "$event" in
    PreToolUse|PostToolUse) MATCHER='*' ;;
  esac

  # All hooks are async (fire-and-forget) — we only observe, never control
  if [ -n "$MATCHER" ]; then
    jq --arg event "$event" --arg cmd "$HOOK_CMD" --arg matcher "$MATCHER" '
      .hooks[$event] = (.hooks[$event] // []) + [{
        "matcher": $matcher,
        "hooks": [{
          "type": "command",
          "command": $cmd,
          "async": true
        }]
      }]
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  else
    jq --arg event "$event" --arg cmd "$HOOK_CMD" '
      .hooks[$event] = (.hooks[$event] // []) + [{
        "hooks": [{
          "type": "command",
          "command": $cmd,
          "async": true
        }]
      }]
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi

  REGISTERED=$((REGISTERED + 1))
done

echo "[ok] Hooks: $REGISTERED registered, $SKIPPED already present"

# ── Verify CLI pipeline (optional) ──
# The dashboard works standalone, but features like autopilot monitoring
# benefit from the full CLI pipeline (commands, tools, schema).
MISSING=0
for check in "$HOME/.claude/commands/commit.md" "$HOME/.claude/tools/commit-preflight.sh" "$HOME/.claude/schema/execution-plan.schema.json"; do
  if [ ! -f "$check" ]; then
    MISSING=$((MISSING + 1))
  fi
done

if [ "$MISSING" -gt 0 ]; then
  echo ""
  echo "NOTE: CLI pipeline not detected ($MISSING items missing)."
  echo "  The dashboard works without it, but for full autopilot monitoring"
  echo "  install the pipeline: https://github.com/tomashermansen-lang/claude-code-pipeline"
fi

echo ""
echo "Done! To start the dashboard:"
echo "  start-system dashboard"
echo ""
echo "Then open: http://127.0.0.1:8787"
