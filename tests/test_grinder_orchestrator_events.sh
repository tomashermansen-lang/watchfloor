#!/bin/bash
# test_grinder_orchestrator_events.sh — TDD for orchestrator boundary events.
#
# Closes the dashboard/orchestrator contract gap surfaced 2026-05-12:
# dashboard/server/grinder_helpers.py:_find_batch_bounds expects
# {"type":"orchestrator","msg":"batch <id> started|completed|failed"}
# events to slice the grinder-stream.ndjson into per-batch views, but
# grinder.sh's transition_batch_status only writes to events.ndjson —
# nothing of type=orchestrator ever lands in the stream. Result: the
# dashboard's BatchView filter returns 0 events for every batch, even
# while the stream has hundreds of claude tool-call events flowing.
#
# Fix: transition_batch_status emits a sister event to STREAM_FILE
# every time it transitions a batch. Event shape is exactly what the
# dashboard expects, validated by dashboard/tests/test_grinder_stream.py
# (TestFilterBatchEvents C2.1-C2.7).
#
# Usage: bash tests/test_grinder_orchestrator_events.sh
# Exits 0 on pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GRINDER="$REPO_DIR/adapters/claude-code/claude/tools/grinder.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"
    shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

[[ -f "$GRINDER" ]] || { echo "FATAL: $GRINDER not found"; exit 1; }

# Defense-in-depth: pin git ceiling so any subprocess git invocation
# can't walk up to the ambient dotfiles repo.
export GIT_CEILING_DIRECTORIES="${TMPDIR:-/tmp}"

setup_dir() {
    GRINDER_DIR=$(mktemp -d -p "${TMPDIR:-/tmp}" test-orch-events-XXXXXX) || return 1
    [[ -n "$GRINDER_DIR" && -d "$GRINDER_DIR" ]] || return 1
    export GRINDER_DIR
    export STREAM_FILE="$GRINDER_DIR/grinder-stream.ndjson"
    : > "$STREAM_FILE"
}
teardown() { [[ -n "${GRINDER_DIR:-}" && -d "$GRINDER_DIR" ]] && rm -rf "$GRINDER_DIR"; }
trap teardown EXIT

# Pluck the new helper out of grinder.sh by sourcing the function block.
# grinder.sh as a whole is not source-safe (it has top-level exec logic),
# so we extract just the function defs we need into a temp file.
_extract_function() {
    local name="$1"
    awk -v fn="$name" '
        $0 ~ "^"fn"\\(\\) \\{" {capture=1}
        capture {print}
        capture && /^}/ {capture=0}
    ' "$GRINDER"
}

# ── T01: _emit_orchestrator_event writes a valid event to STREAM_FILE ──
test_t01_emits_orchestrator_event() {
    setup_dir || return 1
    local fn_src
    fn_src=$(_extract_function "_emit_orchestrator_event")
    [[ -n "$fn_src" ]] || { echo "  _emit_orchestrator_event not defined in grinder.sh"; return 1; }
    eval "$fn_src"
    _emit_orchestrator_event "batch-001" "started" >/dev/null 2>&1
    [[ -s "$STREAM_FILE" ]] || { echo "  STREAM_FILE empty after emit"; return 1; }
    local line
    line=$(cat "$STREAM_FILE")
    # Must be valid JSON, type=orchestrator, msg contains "batch batch-001" and "started"
    python3 -c "
import json, sys
e = json.loads('''$line''')
assert e['type'] == 'orchestrator', f'wrong type: {e[\"type\"]}'
assert 'batch batch-001' in e['msg'], f'msg missing batch id: {e[\"msg\"]}'
assert 'started' in e['msg'].split(), f'msg missing start keyword: {e[\"msg\"]}'
assert e.get('batch') == 'batch-001', f'batch field wrong: {e.get(\"batch\")}'
assert 'ts' in e, 'ts field missing'
" 2>&1
}
check "T01: _emit_orchestrator_event writes shape consumed by dashboard _find_batch_bounds" test_t01_emits_orchestrator_event

# ── T02: emit_orchestrator_event handles 'completed' transition ──
test_t02_completed_event() {
    setup_dir || return 1
    local fn_src
    fn_src=$(_extract_function "_emit_orchestrator_event")
    eval "$fn_src"
    _emit_orchestrator_event "batch-007" "completed" >/dev/null 2>&1
    local line
    line=$(cat "$STREAM_FILE")
    python3 -c "
import json
e = json.loads('''$line''')
assert e['type'] == 'orchestrator'
assert 'batch batch-007' in e['msg']
assert 'completed' in e['msg'].split()
" 2>&1
}
check "T02: 'completed' transition emits matching orchestrator event" test_t02_completed_event

# ── T03: emit_orchestrator_event handles 'failed' transition ──
test_t03_failed_event() {
    setup_dir || return 1
    local fn_src
    fn_src=$(_extract_function "_emit_orchestrator_event")
    eval "$fn_src"
    _emit_orchestrator_event "batch-002" "failed" >/dev/null 2>&1
    local line
    line=$(cat "$STREAM_FILE")
    python3 -c "
import json
e = json.loads('''$line''')
assert e['type'] == 'orchestrator'
assert 'batch batch-002' in e['msg']
assert 'failed' in e['msg'].split()
" 2>&1
}
check "T03: 'failed' transition emits matching orchestrator event" test_t03_failed_event

# ── T04: STREAM_FILE unset → no-op (fail soft) ──
test_t04_no_stream_file_fail_soft() {
    setup_dir || return 1
    local fn_src
    fn_src=$(_extract_function "_emit_orchestrator_event")
    eval "$fn_src"
    unset STREAM_FILE
    local rc=0
    _emit_orchestrator_event "batch-001" "started" >/dev/null 2>&1 || rc=$?
    # Should not crash; return 0 (fail soft, matches log() pattern at grinder.sh:103)
    [[ "$rc" -eq 0 ]]
}
check "T04: STREAM_FILE unset → fail soft (no crash, no event)" test_t04_no_stream_file_fail_soft

# ── T05: events match dashboard's filter contract (cross-check) ──
# Build a fixture stream identical to what grinder would write, run
# dashboard's filter_batch_events against it, assert it returns the
# events between started+completed markers.
test_t05_dashboard_filter_picks_up_events() {
    setup_dir || return 1
    local fn_src
    fn_src=$(_extract_function "_emit_orchestrator_event")
    eval "$fn_src"
    _emit_orchestrator_event "batch-001" "started" >/dev/null 2>&1
    # Simulate a claude tool-call event between markers
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' >> "$STREAM_FILE"
    _emit_orchestrator_event "batch-001" "completed" >/dev/null 2>&1
    # Now run dashboard filter_batch_events
    python3 -c "
import json, sys
sys.path.insert(0, '$REPO_DIR/dashboard')
from server.grinder_helpers import filter_batch_events
events = []
for line in open('$STREAM_FILE'):
    events.append(json.loads(line.strip()))
result = filter_batch_events(events, 'batch-001')
assert len(result) == 3, f'expected 3 events (start + assistant + end), got {len(result)}: {result}'
assert result[0].get('type') == 'orchestrator'
assert result[-1].get('type') == 'orchestrator'
assert 'started' in result[0]['msg']
assert 'completed' in result[-1]['msg']
" 2>&1
}
check "T05: dashboard filter_batch_events accepts emitted events end-to-end" test_t05_dashboard_filter_picks_up_events

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
