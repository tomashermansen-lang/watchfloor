#!/bin/bash
# Mock shellcheck — emits fixture JSON to stdout.
set -euo pipefail

# If MOCK_SHELLCHECK_OUTPUT is set, use that file
if [[ -n "${MOCK_SHELLCHECK_OUTPUT:-}" && -f "$MOCK_SHELLCHECK_OUTPUT" ]]; then
    cat "$MOCK_SHELLCHECK_OUTPUT"
else
    echo '[]'
fi

exit "${MOCK_SHELLCHECK_EXIT:-0}"
