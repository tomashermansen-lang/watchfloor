#!/bin/bash
# test_grinder_archive_prior_cycle.sh — TDD for _archive_prior_cycle_logs.
#
# Closes the append-only-across-cycles bleed-through bug surfaced
# 2026-05-12: docs/grinder/events.ndjson and docs/grinder/grinder-stream.ndjson
# grow forever (events from every prior discover cycle remain in the
# file). Dashboard consumers — _extract_batch_timing in grinder_helpers.py
# and the GrinderEventsList renderer in the frontend — read these files
# verbatim and surface mixed-cycle data as if it belonged to the current
# run. _extract_batch_timing was fixed in commit fdfba4d to pick the
# newest event per batch_id; that fix mitigates the symptom but the root
# cause is the unbounded log files. _archive_prior_cycle_logs is the
# grinder-side fix: when discover starts a new cycle, archive the prior
# logs to *.<short-sha>.bak (preserving history) and truncate the live
# files so consumers see only current-cycle data.
#
# Usage: bash tests/test_grinder_archive_prior_cycle.sh
# Exits 0 on pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/grinder-discover.sh"

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

[[ -f "$LIB" ]] || { echo "FATAL: $LIB not found"; exit 1; }

# Defence-in-depth: prevent any git command from walking up to the
# ambient dotfiles repo.
export GIT_CEILING_DIRECTORIES="${TMPDIR:-/tmp}"

setup_grinder_dir() {
    GRINDER_DIR=$(mktemp -d -p "${TMPDIR:-/tmp}" test-grinder-archive-XXXXXX) || return 1
    [[ -n "$GRINDER_DIR" && -d "$GRINDER_DIR" ]] || return 1
    export GRINDER_DIR
}
teardown() { [[ -n "${GRINDER_DIR:-}" && -d "$GRINDER_DIR" ]] && rm -rf "$GRINDER_DIR"; }
trap teardown EXIT

# ── T01: empty grinder dir → no-op, no archives created ──
test_t01_empty_dir() {
    setup_grinder_dir || return 1
    (
        source "$LIB"
        _archive_prior_cycle_logs >/dev/null 2>&1
    )
    # Nothing should have been created
    local count
    count=$(find "$GRINDER_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" == "0" ]]
}
check "T01: empty grinder dir → no archives, no fresh files created" test_t01_empty_dir

# ── T02: prior events.ndjson + stream → archived with sha suffix ──
test_t02_archives_with_sha() {
    setup_grinder_dir || return 1
    echo '{"ts":"2026-04-22","msg":"old"}' > "$GRINDER_DIR/events.ndjson"
    echo '{"type":"log","msg":"old stream"}' > "$GRINDER_DIR/grinder-stream.ndjson"
    cat > "$GRINDER_DIR/grinder-state.json" <<'JSON'
{"git_sha_at_start": "abcdef1234567890fedcba", "current_pass": "pass-mechanical"}
JSON
    (
        source "$LIB"
        _archive_prior_cycle_logs >/dev/null 2>&1
    )
    # Archive files exist with prior short-sha (first 7 chars)
    [[ -f "$GRINDER_DIR/events.ndjson.abcdef1.bak" ]] && \
        [[ -f "$GRINDER_DIR/grinder-stream.ndjson.abcdef1.bak" ]] && \
        # Live files exist but are empty
        [[ -f "$GRINDER_DIR/events.ndjson" ]] && \
        [[ ! -s "$GRINDER_DIR/events.ndjson" ]] && \
        [[ -f "$GRINDER_DIR/grinder-stream.ndjson" ]] && \
        [[ ! -s "$GRINDER_DIR/grinder-stream.ndjson" ]]
}
check "T02: prior logs → archived as *.<short-sha>.bak; live files truncated" test_t02_archives_with_sha

# ── T03: archive preserves byte-equivalent content ──
test_t03_archive_preserves_content() {
    setup_grinder_dir || return 1
    local original_events='{"ts":"2026-04-22","msg":"line1"}
{"ts":"2026-04-22","msg":"line2"}'
    printf '%s\n' "$original_events" > "$GRINDER_DIR/events.ndjson"
    echo '{"git_sha_at_start": "abcdef1234"}' > "$GRINDER_DIR/grinder-state.json"
    (
        source "$LIB"
        _archive_prior_cycle_logs >/dev/null 2>&1
    )
    local archived_content
    archived_content=$(cat "$GRINDER_DIR/events.ndjson.abcdef1.bak" 2>/dev/null)
    [[ "$archived_content" == "$original_events" ]]
}
check "T03: archived .bak preserves byte-equivalent content of prior cycle" test_t03_archive_preserves_content

# ── T04: missing state.json → archive uses 'unknown' as sha tag ──
test_t04_missing_state_uses_unknown() {
    setup_grinder_dir || return 1
    echo '{"ts":"old"}' > "$GRINDER_DIR/events.ndjson"
    # No grinder-state.json
    (
        source "$LIB"
        _archive_prior_cycle_logs >/dev/null 2>&1
    )
    [[ -f "$GRINDER_DIR/events.ndjson.unknown.bak" ]] && \
        [[ ! -s "$GRINDER_DIR/events.ndjson" ]]
}
check "T04: missing state.json → archive tag is 'unknown'; archive still happens" test_t04_missing_state_uses_unknown

# ── T05: empty events.ndjson → no archive (avoid noise) ──
test_t05_empty_file_no_archive() {
    setup_grinder_dir || return 1
    : > "$GRINDER_DIR/events.ndjson"  # empty
    echo '{"git_sha_at_start": "abcdef1"}' > "$GRINDER_DIR/grinder-state.json"
    (
        source "$LIB"
        _archive_prior_cycle_logs >/dev/null 2>&1
    )
    # No .bak file should be created for an empty input
    ! ls "$GRINDER_DIR"/events.ndjson.*.bak >/dev/null 2>&1
}
check "T05: empty events.ndjson → no .bak created (skip-empty optimisation)" test_t05_empty_file_no_archive

# ── T06: only one file present → only that one archived ──
test_t06_partial_files() {
    setup_grinder_dir || return 1
    echo '{"ts":"old"}' > "$GRINDER_DIR/events.ndjson"
    # No grinder-stream.ndjson
    echo '{"git_sha_at_start": "abcdef1"}' > "$GRINDER_DIR/grinder-state.json"
    (
        source "$LIB"
        _archive_prior_cycle_logs >/dev/null 2>&1
    )
    [[ -f "$GRINDER_DIR/events.ndjson.abcdef1.bak" ]] && \
        ! ls "$GRINDER_DIR"/grinder-stream.ndjson.*.bak >/dev/null 2>&1
}
check "T06: only one ndjson present → only that one archived; missing one is no-op" test_t06_partial_files

echo ""
echo "Passed: $passed  Failed: $failed"
[ "$failed" -eq 0 ]
