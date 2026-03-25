#!/bin/bash
# PreToolUse hook: TDD gate — blocks src/ writes when no test was modified first.
# Returns exit 2 to deny the tool call with feedback to Claude.
# Zero token cost — pure shell, no LLM invocation.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.file // ""')

# Only gate implementation files in src/
case "$FILE_PATH" in
    */src/*) ;;
    *) exit 0 ;;
esac

# Allow if any test file has uncommitted changes (staged or unstaged)
if git status --porcelain -- tests/ 2>/dev/null | grep -q .; then
    exit 0
fi

# Allow if on a feature/hotfix branch and tests were committed in this branch
BRANCH=$(git branch --show-current 2>/dev/null)
case "$BRANCH" in
    feature/*|hotfix/*)
        if git diff --name-only main...HEAD -- tests/ 2>/dev/null | grep -q .; then
            exit 0
        fi
        ;;
esac

echo "TDD: modify a test file in tests/ before writing to src/. Test-first!" >&2
exit 2
