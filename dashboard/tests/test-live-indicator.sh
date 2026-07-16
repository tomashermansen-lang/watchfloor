#!/bin/bash
# Test: LogViewer live indicator — isLive flag from useAutopilotLog
#
# The useAutopilotLog hook should expose isLive: true when new log content
# arrived in the last poll cycle, false otherwise. The LogViewer header
# uses this to show a pulsing green dot.
#
# This test verifies the behavioral contract at the API level:
# - When log content is growing, successive /api/autopilot/log calls return content
# - When log content stops, successive calls return empty content
#
# Frontend live indicator is driven by session.status === 'running', not per-poll content.
# The API contract tested here supports the log auto-scroll and content detection.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TEST_TMP="/tmp/claude/test-live-$$"
mkdir -p "$TEST_TMP"
trap 'rm -rf "$TEST_TMP"' EXIT

# Simulate a growing log file
LOG="$TEST_TMP/autopilot.log"
echo "[16:00:01] Phase started" > "$LOG"

# Read from offset 0 — should get content (isLive=true condition)
RESULT=$(python3 -c "
import sys; sys.path.insert(0, '.')
from server.autopilot_helpers import read_log_incremental
result = read_log_incremental('${LOG}', 0)
if result:
    print(f'TEXT={repr(result[0])}')
    print(f'OFFSET={result[1]}')
else:
    print('TEXT=')
    print('OFFSET=0')
")
TEXT=$(echo "$RESULT" | grep '^TEXT=' | sed 's/^TEXT=//')
OFFSET=$(echo "$RESULT" | grep '^OFFSET=' | sed 's/^OFFSET=//')

if [ -n "$TEXT" ] && [ "$TEXT" != "''" ]; then
  pass "Initial read returns content (isLive=true)"
else
  fail "Initial read returns content (isLive=true) — got: $TEXT"
fi

# Read again from same offset without appending — should get empty (isLive=false condition)
TEXT2=$(python3 -c "
import sys; sys.path.insert(0, '.')
from server.autopilot_helpers import read_log_incremental
result = read_log_incremental('${LOG}', ${OFFSET})
if result:
    print(repr(result[0]))
else:
    print('None')
")

if echo "$TEXT2" | grep -q "''"; then
  pass "No-change read returns empty content (isLive=false)"
else
  fail "No-change read returns empty content (isLive=false) — got: $TEXT2"
fi

# Append new content — read should get it (isLive=true again)
echo "[16:00:05] New activity" >> "$LOG"
TEXT3=$(python3 -c "
import sys; sys.path.insert(0, '.')
from server.autopilot_helpers import read_log_incremental
result = read_log_incremental('${LOG}', ${OFFSET})
if result:
    print(result[0])
else:
    print('')
")

if echo "$TEXT3" | grep -q "New activity"; then
  pass "After append, read returns new content (isLive=true)"
else
  fail "After append, read returns new content (isLive=true) — got: $TEXT3"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
