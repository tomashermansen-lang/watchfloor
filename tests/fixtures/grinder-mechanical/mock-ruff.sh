#!/bin/bash
# Mock ruff binary — logs invocations and optionally modifies files.
set -euo pipefail

LOG_FILE="${MOCK_RUFF_LOG:-/dev/null}"

# Log the full invocation
echo "ruff $*" >> "$LOG_FILE"

# If "check --fix" is in the args, remove trailing whitespace from target files
if [[ "$*" == *"check --fix"* ]] || [[ "$*" == *"format"* ]]; then
    for arg in "$@"; do
        [[ "$arg" == "check" || "$arg" == "--fix" || "$arg" == "format" || "$arg" == "--output-format" || "$arg" == "json" ]] && continue
        if [[ -f "$arg" ]]; then
            sed -i.bak 's/[[:space:]]*$//' "$arg"
            rm -f "${arg}.bak"
        fi
    done
fi

# ruff exits non-zero when findings exist
exit "${MOCK_RUFF_EXIT:-1}"
