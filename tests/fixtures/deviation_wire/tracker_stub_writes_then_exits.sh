#!/usr/bin/env bash
# Recording-stub deviation-tracker. Drains stdin (so the wrapper's
# pipe doesn't block), appends one invocation line to a recording
# file, and exits 0. The recording file path is
# ${DEVIATION_RECORD_FILE:-${TMPDIR:-/tmp}/dt-invocations}.
RECORD="${DEVIATION_RECORD_FILE:-${TMPDIR:-/tmp}/dt-invocations}"
mkdir -p "$(dirname "$RECORD")" 2>/dev/null || true
# Capture stdin if requested
if [[ -n "${DEVIATION_STDIN_FILE:-}" ]]; then
  cat > "$DEVIATION_STDIN_FILE"
else
  cat > /dev/null
fi
echo "invoked: $*" >> "$RECORD"
exit 0
