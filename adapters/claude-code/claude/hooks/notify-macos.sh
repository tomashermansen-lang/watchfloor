#!/bin/bash
# notify-macos.sh — macOS notification hook for Claude Code
#
# Fires on the Notification hook event (permission_prompt, idle_prompt, etc.)
# Shows a macOS notification identifying WHICH worktree needs attention,
# with a click action that brings the correct VS Code window to the front.
#
# Install:  Add to .claude/settings.json under hooks.Notification (see below)
# Requires: jq (brew install jq), terminal-notifier (brew install terminal-notifier)
#           Falls back to osascript if terminal-notifier is not installed.
#
# Settings snippet:
#   "Notification": [
#     {
#       "hooks": [
#         {
#           "type": "command",
#           "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/notify-macos.sh"
#         }
#       ]
#     }
#   ]

set -euo pipefail

# ── 1. Read stdin JSON ────────────────────────────────────────────────────────
INPUT=$(cat)

# ── 2. Extract fields from the Notification hook stdin schema ─────────────────
# Common fields (all hooks): session_id, transcript_path, cwd, hook_event_name
# Notification-specific fields: message, title, notification_type
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
HOOK_MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude needs your attention"')
HOOK_TITLE=$(echo "$INPUT" | jq -r '.title // "Claude Code"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# ── 3. Derive the worktree name ───────────────────────────────────────────────
# $CLAUDE_PROJECT_DIR is set as an environment variable by Claude Code.
# It points to the project root for the current session's worktree.
# Fallback to cwd from stdin if $CLAUDE_PROJECT_DIR is unset.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"

# The worktree name is the basename of the project dir.
# For /Users/tomas/oih-capacity → "oih-capacity"
# For /Users/tomas/OIH          → "OIH" (main worktree)
WORKTREE_NAME=$(basename "$PROJECT_DIR")

# Try to get the current git branch for even more context
BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "")
if [[ -n "$BRANCH" ]]; then
    CONTEXT_LABEL="[$WORKTREE_NAME] $BRANCH"
else
    CONTEXT_LABEL="[$WORKTREE_NAME]"
fi

# ── 4. Build human-readable notification texts ────────────────────────────────
case "$NOTIFICATION_TYPE" in
    permission_prompt)
        TITLE="Claude: Permission needed"
        MESSAGE="$CONTEXT_LABEL — $HOOK_MESSAGE"
        SOUND="Glass"
        ;;
    idle_prompt)
        TITLE="Claude: Waiting for input"
        MESSAGE="$CONTEXT_LABEL — Ready for your next prompt"
        SOUND="Ping"
        ;;
    auth_success)
        TITLE="Claude: Authenticated"
        MESSAGE="$CONTEXT_LABEL — Auth complete"
        SOUND="Pop"
        ;;
    elicitation_dialog)
        TITLE="Claude: Input required"
        MESSAGE="$CONTEXT_LABEL — $HOOK_MESSAGE"
        SOUND="Glass"
        ;;
    *)
        TITLE="Claude Code"
        MESSAGE="$CONTEXT_LABEL — $HOOK_MESSAGE"
        SOUND="Ping"
        ;;
esac

# ── 5. Build VS Code open action ──────────────────────────────────────────────
# Strategy A (preferred): vscode://file/PATH URI via `open -u`
# VS Code registers the "vscode" URL scheme (verified in Info.plist).
# Opening vscode://file/<path> reuses an existing window that has <path> open,
# rather than spawning a new window — matching the built-in file:// behavior.
#
# Strategy B (fallback): AppleScript activate — brings VS Code to front
# without opening a specific folder. Useful if the URI doesn't work.
#
# URL-encode the path (spaces → %20, etc.)
# Pure bash percent-encoding for path components
url_encode_path() {
    local string="$1"
    local encoded=""
    local length="${#string}"
    for (( i = 0; i < length; i++ )); do
        local char="${string:$i:1}"
        case "$char" in
            [a-zA-Z0-9.~_/-]) encoded+="$char" ;;
            ' ') encoded+="%20" ;;
            *)   encoded+=$(printf '%%%02X' "'$char") ;;
        esac
    done
    echo "$encoded"
}

ENCODED_PATH=$(url_encode_path "$PROJECT_DIR")
VSCODE_URI="vscode://file/${ENCODED_PATH}"

# ── 6. Send the notification ───────────────────────────────────────────────────
if command -v terminal-notifier &>/dev/null; then
    # terminal-notifier: supports -open URL for click action.
    # The -open flag accepts any URL scheme, including vscode://
    # -group prevents duplicate notifications for the same worktree.
    terminal-notifier \
        -title "$TITLE" \
        -message "$MESSAGE" \
        -sound "$SOUND" \
        -open "$VSCODE_URI" \
        -group "claude-code-$WORKTREE_NAME" \
        -appIcon "" \
        2>/dev/null || true
else
    # Fallback: osascript (built-in, no click action support in standard API)
    # Notifications sent via osascript have no click-to-open callback.
    # The notification does bring Script Editor to front on click, which is
    # unhelpful — so we separate the notification from the VS Code focus.

    # Escape special chars for AppleScript string literals
    SAFE_TITLE="${TITLE//\\/\\\\}"
    SAFE_TITLE="${SAFE_TITLE//\"/\\\"}"
    SAFE_MSG="${MESSAGE//\\/\\\\}"
    SAFE_MSG="${SAFE_MSG//\"/\\\"}"

    osascript -e "display notification \"$SAFE_MSG\" with title \"$SAFE_TITLE\" sound name \"$SOUND\"" \
        2>/dev/null || true

    # For permission_prompt specifically, also force-open the right VS Code window
    # immediately (without waiting for a click) since the user needs to act fast.
    if [[ "$NOTIFICATION_TYPE" == "permission_prompt" ]]; then
        open -u "$VSCODE_URI" 2>/dev/null || \
        osascript -e 'tell application "Visual Studio Code" to activate' 2>/dev/null || true
    fi
fi

# ── 7. Always exit 0 ──────────────────────────────────────────────────────────
# Notification hooks cannot block or modify notifications.
# Non-zero exit shows stderr to user only, does not affect Claude.
exit 0
