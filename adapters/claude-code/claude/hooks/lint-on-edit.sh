#!/usr/bin/env bash
# PostToolUse hook: run project linter on edited files.
# Deterministic quality gate — runs after every Edit/Write.
# Fails silently if no linter found (not all projects have one).
# Designed for speed: ruff ~50ms, eslint ~500ms.

set -euo pipefail

# Extract file path from tool input (JSON on stdin)
FILE_PATH=$(echo "$CLAUDE_TOOL_INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('file_path', ''))
except:
    pass
" 2>/dev/null)

[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

EXT="${FILE_PATH##*.}"

case "$EXT" in
    py)
        # Python: use ruff if available
        if command -v ruff &>/dev/null; then
            RESULT=$(ruff check "$FILE_PATH" 2>&1) || {
                echo "LINT: ruff found issues in $FILE_PATH"
                echo "$RESULT"
                exit 0  # Don't block — surface to Claude as feedback
            }
        fi
        ;;
    ts|tsx|js|jsx)
        # TypeScript/JavaScript: use eslint if config exists
        # Find project root by walking up to find eslint config
        DIR=$(dirname "$FILE_PATH")
        while [ "$DIR" != "/" ]; do
            if [ -f "$DIR/eslint.config.js" ] || [ -f "$DIR/.eslintrc.js" ] || [ -f "$DIR/.eslintrc.json" ]; then
                RESULT=$(cd "$DIR" && npx --no-install eslint "$FILE_PATH" 2>&1) || {
                    echo "LINT: eslint found issues in $FILE_PATH"
                    echo "$RESULT"
                    exit 0
                }
                break
            fi
            DIR=$(dirname "$DIR")
        done
        ;;
esac

exit 0
