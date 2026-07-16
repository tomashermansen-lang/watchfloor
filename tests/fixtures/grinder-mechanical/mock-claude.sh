#!/bin/bash
# Mock claude binary for grinder mechanical tests.
# - Captures EXTRA_SYSTEM_PROMPT to $MOCK_PROMPT_CAPTURE
# - Applies deterministic sed changes to batch files (removes trailing whitespace)
# - Streams JSON output matching run_phase caller protocol

set -euo pipefail

# Capture prompt for test assertions
if [[ -n "${MOCK_PROMPT_CAPTURE:-}" ]]; then
    echo "${EXTRA_SYSTEM_PROMPT:-}" > "$MOCK_PROMPT_CAPTURE"
fi

# If MOCK_CLAUDE_CREATE_FILE is set, create that file (for new-file-on-revert tests)
if [[ -n "${MOCK_CLAUDE_CREATE_FILE:-}" ]]; then
    echo "created by mock claude" > "$MOCK_CLAUDE_CREATE_FILE"
fi

# If MOCK_CLAUDE_NO_CHANGES is set, don't modify any files
if [[ "${MOCK_CLAUDE_NO_CHANGES:-}" == "true" ]]; then
    echo '{"type":"result","subtype":"success","session_id":"mock","num_turns":1,"duration_ms":100,"total_cost_usd":0}'
    exit 0
fi

# Apply deterministic changes: remove trailing whitespace from files in the prompt
# The prompt is passed as the argument after -p
prompt_text=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) shift; prompt_text="$1" ;;
        *) ;;
    esac
    shift
done

# If MOCK_CLAUDE_FAIL is set, exit with that code
if [[ -n "${MOCK_CLAUDE_FAIL:-}" ]]; then
    exit "$MOCK_CLAUDE_FAIL"
fi

# Apply changes to files listed in MOCK_CLAUDE_FILES (space-separated)
if [[ -n "${MOCK_CLAUDE_FILES:-}" ]]; then
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if [[ -f "$file" ]]; then
            # Remove trailing whitespace as a deterministic change
            sed -i.bak 's/[[:space:]]*$//' "$file"
            rm -f "${file}.bak"
        fi
    done <<< "${MOCK_CLAUDE_FILES}"
fi

echo '{"type":"result","subtype":"success","session_id":"mock","num_turns":1,"duration_ms":100,"total_cost_usd":0}'
exit 0
