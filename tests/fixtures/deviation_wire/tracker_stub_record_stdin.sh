#!/usr/bin/env bash
# Recording-stub deviation-tracker that captures stdin to
# ${DEVIATION_STDIN_FILE:-${TMPDIR:-/tmp}/dt-stdin.json}
# and exits 0.
STDIN_FILE="${DEVIATION_STDIN_FILE:-${TMPDIR:-/tmp}/dt-stdin.json}"
mkdir -p "$(dirname "$STDIN_FILE")" 2>/dev/null || true
cat > "$STDIN_FILE"
exit 0
