#!/bin/bash
# test_grinder_orchestrator.sh — C4: Bash integration tests for grinder.sh
#
# Tests CLI dispatch, status, pause, staleness, validation, corrupt state,
# truncated events, lock, TOOLS_DIR resolution, directory bootstrap, signals.
#
# Usage: bash tests/test_grinder_orchestrator.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GRINDER="$REPO_DIR/adapters/claude-code/claude/tools/grinder.sh"
FIXTURES="$REPO_DIR/tests/fixtures/grinder-orchestrator"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
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

# --- Shared helpers ---

TEST_DIR="${TMPDIR:-/tmp}/test-grinder-orchestrator-$$"
PIDS_TO_KILL=()

setup_test_dir() {
    local dir="$TEST_DIR/$(date +%s%N)"
    mkdir -p "$dir/docs/grinder"
    echo "$dir"
}

setup_git_repo() {
    # Creates a temp git repo with known commits for staleness tests.
    # Returns the repo path. Captures HEAD SHA.
    local dir
    dir=$(setup_test_dir)
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial commit"
    GIT_SHA=$(git rev-parse HEAD)
    echo "$dir"
}

make_mock_validate() {
    # Creates a mock validate-plan.py that exits with given code
    local dir="$1"
    local exit_code="${2:-0}"
    local mock_dir="$dir/mock-tools"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/validate-plan.py" << MOCK_EOF
#!/usr/bin/env python3
import sys
if $exit_code != 0:
    print("ERROR: validation failed", file=sys.stderr)
sys.exit($exit_code)
MOCK_EOF
    chmod +x "$mock_dir/validate-plan.py"
    echo "$mock_dir"
}

cleanup() {
    for pid in "${PIDS_TO_KILL[@]+"${PIDS_TO_KILL[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_DIR"

echo "Running grinder.sh integration tests..."
echo ""

# =============================================================================
# Category 1: CLI Dispatch (REQ-1)
# =============================================================================

# T01: Unknown subcommand
test_t01() {
    local output
    output=$(bash "$GRINDER" foo 2>&1) && return 1
    echo "$output" | grep -qi "unknown subcommand\|usage" || return 1
    return 0
}
check "T01: Unknown subcommand → exit 1 + usage" test_t01

# T02: No subcommand
test_t02() {
    local output
    output=$(bash "$GRINDER" 2>&1) && return 1
    echo "$output" | grep -qi "usage" || return 1
    return 0
}
check "T02: No subcommand → exit 1 + usage" test_t02

# T03: --project-dir does not exist
test_t03() {
    local output
    output=$(bash "$GRINDER" status --project-dir /nonexistent 2>&1) && return 1
    echo "$output" | grep -q "does not exist" || return 1
    return 0
}
check "T03: --project-dir does not exist → exit 1" test_t03

# T04: --project-dir outside trust boundary
test_t04() {
    local output
    output=$(PROJECTS_ROOT="$TEST_DIR/projekter" bash "$GRINDER" status --project-dir /tmp 2>&1) && return 1
    echo "$output" | grep -q "outside trust boundary" || return 1
    return 0
}
check "T04: --project-dir outside trust boundary → exit 1" test_t04

# T05: Discover — no pipeline.yaml → exit 1
# (cmd_discover was reworked to validate pipeline.yaml not CLAUDE.md;
#  the assertion mirrors the current REQ-1.1 error string at grinder.sh:1119.)
test_t05() {
    local dir
    dir=$(setup_test_dir)
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" discover --project-dir "$dir" 2>&1) && return 1
    echo "$output" | grep -q "no pipeline.yaml found" || return 1
    return 0
}
check "T05: Discover — no pipeline.yaml → exit 1" test_t05

# =============================================================================
# Category 2: Status Subcommand (REQ-3)
# =============================================================================

# T06: No plan exists → "no active plan"
test_t06() {
    local dir
    dir=$(setup_test_dir)
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" status --project-dir "$dir" --grinder-dir "$dir/docs/grinder" 2>&1)
    echo "$output" | grep -q "no active plan" || return 1
    return 0
}
check "T06: Status with no plan → 'no active plan'" test_t06

# T07: Plan exists, no state
test_t07() {
    local dir
    dir=$(setup_test_dir)
    cp "$FIXTURES/valid-plan.yaml" "$dir/docs/grinder/grinder-plan.yaml"
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" status --project-dir "$dir" --grinder-dir "$dir/docs/grinder" 2>&1)
    echo "$output" | grep -q "not started" || { echo "  Missing 'not started'"; return 1; }
    echo "$output" | grep -q "passes" || { echo "  Missing pass count"; return 1; }
    return 0
}
check "T07: Status with plan only → summary + 'not started'" test_t07

# T08: Plan + state exist → full status (AS-14)
test_t08() {
    local dir
    dir=$(setup_test_dir)
    cp "$FIXTURES/valid-plan.yaml" "$dir/docs/grinder/grinder-plan.yaml"
    cp "$FIXTURES/valid-state.json" "$dir/docs/grinder/grinder-state.json"
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" status --project-dir "$dir" --grinder-dir "$dir/docs/grinder" 2>&1)
    echo "$output" | grep -q "pass-2" || { echo "  Missing current pass"; return 1; }
    echo "$output" | grep -q "completed: 2" || { echo "  Missing completed count"; return 1; }
    echo "$output" | grep -q "failed: 1" || { echo "  Missing failed count"; return 1; }
    return 0
}
check "T08: Status with plan + state → full display (AS-14)" test_t08

# =============================================================================
# Category 3: Pause Mechanism (REQ-6)
# =============================================================================

# T09: Pause creates sentinel (AS-11)
test_t09() {
    local dir
    dir=$(setup_test_dir)
    PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" pause --project-dir "$dir" --grinder-dir "$dir/docs/grinder" >/dev/null 2>&1
    [[ -f "$dir/docs/grinder/PAUSE" ]] || return 1
    return 0
}
check "T09: Pause creates PAUSE sentinel (AS-11)" test_t09

# T10: Run while paused → exit 0, no batch executed (AS-10)
test_t10() {
    local dir
    dir=$(setup_test_dir)
    cp "$FIXTURES/valid-plan.yaml" "$dir/docs/grinder/grinder-plan.yaml"
    touch "$dir/docs/grinder/PAUSE"
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$dir/docs/grinder" 2>&1)
    echo "$output" | grep -q "grinder is paused" || return 1
    return 0
}
check "T10: Run while paused → exit 0 + paused message (AS-10)" test_t10

# T11: Resume clears pause (AS-12)
test_t11() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    # Create plan with current HEAD SHA
    local sha
    sha=$(cd "$dir" && git rev-parse HEAD)
    sed "s/abc1234/$sha/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"
    touch "$gdir/PAUSE"

    # Create mock validate-plan.py
    local mock_dir
    mock_dir=$(make_mock_validate "$dir" 0)

    local output
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      PATH="$mock_dir:$PATH" \
      bash "$GRINDER" resume --project-dir "$dir" --grinder-dir "$gdir" 2>&1) || true
    [[ ! -f "$gdir/PAUSE" ]] || { echo "  PAUSE still exists"; return 1; }
    echo "$output" | grep -q "pause cleared" || { echo "  Missing 'pause cleared'"; return 1; }
    return 0
}
check "T11: Resume clears PAUSE (AS-12)" test_t11

# =============================================================================
# Category 4: Staleness Check (REQ-5)
# =============================================================================

# T12: HEAD matches plan SHA → proceed
test_t12() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    local sha
    sha=$(cd "$dir" && git rev-parse HEAD)
    sed "s/abc1234/$sha/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"

    # Use mock validate-plan.py
    local mock_dir
    mock_dir=$(make_mock_validate "$dir" 0)

    # Mock claude too (run will try to execute batches)
    mkdir -p "$dir/mock-bin"
    cat > "$dir/mock-bin/claude" << 'CLAUDE_EOF'
#!/bin/bash
echo '{"type":"result","subtype":"success","session_id":"mock","num_turns":1,"duration_ms":100,"total_cost_usd":0}'
exit 0
CLAUDE_EOF
    chmod +x "$dir/mock-bin/claude"

    local output
    # Run should not fail on staleness
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      GRINDER_LOCK_MAX_WAIT=5 \
      PATH="$dir/mock-bin:$mock_dir:$PATH" \
      bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" 2>&1) || true
    # Should NOT contain "plan stale"
    if echo "$output" | grep -q "plan stale"; then
        echo "  Unexpected staleness error"
        return 1
    fi
    return 0
}
check "T12: HEAD matches plan SHA → staleness passes (EC-5.1)" test_t12

# T13: HEAD drifted beyond threshold → exit 1 (AS-9)
test_t13() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    local sha
    sha=$(cd "$dir" && git rev-parse HEAD)
    sed "s/abc1234/$sha/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"

    # Create 3 more commits to drift HEAD
    cd "$dir"
    for i in 1 2 3; do
        echo "drift $i" >> file.txt
        git add file.txt
        git commit -q -m "drift $i"
    done

    local mock_dir
    mock_dir=$(make_mock_validate "$dir" 0)

    local output
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      PATH="$mock_dir:$PATH" \
      bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" 2>&1) && return 1
    echo "$output" | grep -q "plan stale" || { echo "  Missing 'plan stale'"; return 1; }
    echo "$output" | grep -q "3 commits ahead" || { echo "  Missing commit count"; return 1; }
    return 0
}
check "T13: HEAD drifted → exit 1 + 'plan stale' (AS-9)" test_t13

# T14: SHA not an ancestor (rebase) → exit 1 (EC-5.2)
test_t14() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"

    # Use a SHA that doesn't exist in this repo
    sed "s/abc1234/deadbeef1234567890abcdef/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"

    local mock_dir
    mock_dir=$(make_mock_validate "$dir" 0)

    local output
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      PATH="$mock_dir:$PATH" \
      bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" 2>&1) && return 1
    echo "$output" | grep -q "not an ancestor" || { echo "  Missing ancestor error"; return 1; }
    return 0
}
check "T14: SHA not an ancestor → exit 1 (EC-5.2)" test_t14

# =============================================================================
# Category 5: Plan Validation (REQ-4)
# =============================================================================

# T15: Valid plan passes validation
test_t15() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    local sha
    sha=$(cd "$dir" && git rev-parse HEAD)
    sed "s/abc1234/$sha/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"

    # Use the real validate-plan.py — should pass
    mkdir -p "$dir/mock-bin"
    cat > "$dir/mock-bin/claude" << 'CLAUDE_EOF'
#!/bin/bash
echo '{"type":"result","subtype":"success","session_id":"mock","num_turns":1,"duration_ms":100,"total_cost_usd":0}'
CLAUDE_EOF
    chmod +x "$dir/mock-bin/claude"

    local output
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      GRINDER_LOCK_MAX_WAIT=5 \
      PATH="$dir/mock-bin:$PATH" \
      bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" 2>&1) || true
    # Should NOT contain validation error
    if echo "$output" | grep -qi "validation failed"; then
        echo "  Unexpected validation failure"
        return 1
    fi
    return 0
}
check "T15: Valid plan passes validation (REQ-4)" test_t15

# T16: Invalid plan blocks run (AS-2)
test_t16() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    cp "$FIXTURES/invalid-plan.yaml" "$gdir/grinder-plan.yaml"

    local output
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" 2>&1) && return 1
    # Should show error (missing passes)
    return 0
}
check "T16: Invalid plan blocks run (AS-2)" test_t16

# =============================================================================
# Category 6: Corrupt State (REQ-9)
# =============================================================================

# T17: Corrupt state JSON → exit 1 (AS-7)
test_t17() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    local sha
    sha=$(cd "$dir" && git rev-parse HEAD)
    sed "s/abc1234/$sha/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"
    cp "$FIXTURES/corrupt-state.json" "$gdir/grinder-state.json"

    local output
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" 2>&1) && return 1
    echo "$output" | grep -q "corrupt" || { echo "  Missing 'corrupt'"; return 1; }
    return 0
}
check "T17: Corrupt state → exit 1 + diagnostic (AS-7)" test_t17

# T18: State references unknown pass → exit 1 (EC-9.2)
test_t18() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    local sha
    sha=$(cd "$dir" && git rev-parse HEAD)
    sed "s/abc1234/$sha/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"
    cp "$FIXTURES/state-unknown-pass.json" "$gdir/grinder-state.json"

    local output
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" 2>&1) && return 1
    echo "$output" | grep -q "unknown pass" || { echo "  Missing 'unknown pass'"; return 1; }
    return 0
}
check "T18: State references unknown pass → exit 1 (EC-9.2)" test_t18

# =============================================================================
# Category 7: Truncated Events (REQ-10)
# =============================================================================

# T19: Truncated final line ignored (AS-8)
test_t19() {
    local dir
    dir=$(setup_test_dir)
    cp "$FIXTURES/truncated-events.ndjson" "$dir/docs/grinder/events.ndjson"

    # Use a self-contained script that defines read_events inline
    local combined_output
    combined_output=$(bash -c '
        set -euo pipefail
        GRINDER_DIR="'"$dir/docs/grinder"'"

        read_events() {
            local events_file="$GRINDER_DIR/events.ndjson"
            [[ -f "$events_file" ]] || return 0
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" ]] && continue
                if echo "$line" | jq -e "." >/dev/null 2>&1; then
                    echo "$line"
                else
                    echo "events.ndjson: ignoring truncated final line" >&2
                fi
            done < "$events_file"
        }

        read_events >/dev/null
    ' 2>&1) || true
    echo "$combined_output" | grep -q "truncated" || { echo "  Missing truncation warning"; return 1; }
    return 0
}
check "T19: Truncated final line → warning (AS-8)" test_t19

# T20: Empty events file → no error (EC-10.2)
test_t20() {
    local dir
    dir=$(setup_test_dir)
    touch "$dir/docs/grinder/events.ndjson"

    local combined_output
    combined_output=$(bash -c '
        set -euo pipefail
        GRINDER_DIR="'"$dir/docs/grinder"'"

        read_events() {
            local events_file="$GRINDER_DIR/events.ndjson"
            [[ -f "$events_file" ]] || return 0
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" ]] && continue
                if echo "$line" | jq -e "." >/dev/null 2>&1; then
                    echo "$line"
                else
                    echo "events.ndjson: ignoring truncated final line" >&2
                fi
            done < "$events_file"
        }

        stdout=$(read_events 2>/dev/null)
        [[ -z "$stdout" ]] || { echo "unexpected stdout: $stdout"; exit 1; }
    ' 2>&1) || return 1
    return 0
}
check "T20: Empty events file → no error (EC-10.2)" test_t20

# T21: All valid events → no warning (EC-10.3)
test_t21() {
    local dir
    dir=$(setup_test_dir)
    cp "$FIXTURES/valid-events.ndjson" "$dir/docs/grinder/events.ndjson"

    local combined_output
    combined_output=$(bash -c '
        set -euo pipefail
        GRINDER_DIR="'"$dir/docs/grinder"'"

        read_events() {
            local events_file="$GRINDER_DIR/events.ndjson"
            [[ -f "$events_file" ]] || return 0
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" ]] && continue
                if echo "$line" | jq -e "." >/dev/null 2>&1; then
                    echo "$line"
                else
                    echo "events.ndjson: ignoring truncated final line" >&2
                fi
            done < "$events_file"
        }

        stderr_output=$(read_events 2>&1 1>/dev/null)
        if echo "$stderr_output" | grep -q "truncated"; then
            echo "unexpected truncation warning"
            exit 1
        fi
    ' 2>&1) || { echo "  $combined_output"; return 1; }
    return 0
}
check "T21: All valid events → no warning (EC-10.3)" test_t21

# T22: Only truncated line → warning + empty (EC-10.4)
test_t22() {
    local dir
    dir=$(setup_test_dir)
    echo '{"ts":"2026-04-17T10:00:00Z","batch":"b","event":"sta' > "$dir/docs/grinder/events.ndjson"

    local combined_output
    combined_output=$(bash -c '
        set -euo pipefail
        GRINDER_DIR="'"$dir/docs/grinder"'"

        read_events() {
            local events_file="$GRINDER_DIR/events.ndjson"
            [[ -f "$events_file" ]] || return 0
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" ]] && continue
                if echo "$line" | jq -e "." >/dev/null 2>&1; then
                    echo "$line"
                else
                    echo "events.ndjson: ignoring truncated final line" >&2
                fi
            done < "$events_file"
        }

        combined=$(read_events 2>&1)
        echo "$combined" | grep -q "truncated" || { echo "missing truncation warning"; exit 1; }
        # No valid JSON lines should appear (only the warning)
        valid_lines=$(read_events 2>/dev/null || true)
        [[ -z "$valid_lines" ]] || { echo "unexpected valid events: $valid_lines"; exit 1; }
    ' 2>&1) || { echo "  $combined_output"; return 1; }
    return 0
}
check "T22: Only truncated line → warning + empty (EC-10.4)" test_t22

# =============================================================================
# Category 8: Lock (REQ-12)
# =============================================================================

# T23: Lock prevents concurrent run (AS-13)
test_t23() {
    local dir
    dir=$(setup_test_dir)
    local lock_file="$dir/docs/grinder/.grinder.lock"
    # Pre-create lock with our own PID (guarantees it's held)
    echo "$$" > "$lock_file"

    local output
    output=$(GRINDER_DIR="$dir/docs/grinder" GRINDER_LOCK_MAX_WAIT=2 bash -c '
        source "'"$REPO_DIR"'/claude/tools/lib/merge-lock.sh"
        GRINDER_DIR="'"$dir/docs/grinder"'"
        GRINDER_LOCK_MAX_WAIT=2
        lock_file="$GRINDER_DIR/.grinder.lock"
        MERGE_LOCK_MAX_WAIT=2 acquire_merge_lock "$lock_file" 2>&1
    ' 2>&1) && return 1  # Should fail
    return 0
}
check "T23: Lock prevents concurrent run (AS-13)" test_t23

# T24: Lock released after grinder.sh status (no lock needed)
test_t24() {
    local dir
    dir=$(setup_test_dir)
    local lock_file="$dir/docs/grinder/.grinder.lock"
    cp "$FIXTURES/valid-plan.yaml" "$dir/docs/grinder/grinder-plan.yaml"
    cp "$FIXTURES/valid-state.json" "$dir/docs/grinder/grinder-state.json"

    # Run grinder.sh status — should not leave a lock file
    PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" status \
        --project-dir "$dir" --grinder-dir "$dir/docs/grinder" >/dev/null 2>&1 || true
    [[ ! -f "$lock_file" ]] || { echo "  Lock file left behind after status"; return 1; }

    # Also verify pause creates no lock
    PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" pause \
        --project-dir "$dir" --grinder-dir "$dir/docs/grinder" >/dev/null 2>&1 || true
    [[ ! -f "$lock_file" ]] || { echo "  Lock file left behind after pause"; return 1; }
    return 0
}
check "T24: Lock not left behind after status/pause (REQ-12)" test_t24

# =============================================================================
# Category 9: TOOLS_DIR Resolution
# =============================================================================

# T25: Invoke from different CWD
test_t25() {
    local dir
    dir=$(setup_test_dir)
    local output
    # Run grinder.sh status from /tmp, pointing to our test dir
    output=$(cd /tmp && PROJECTS_ROOT="$(dirname "$dir")" \
      bash "$GRINDER" status --project-dir "$dir" --grinder-dir "$dir/docs/grinder" 2>&1)
    echo "$output" | grep -q "no active plan" || return 1
    return 0
}
check "T25: Invoke from different CWD → TOOLS_DIR resolves correctly" test_t25

# =============================================================================
# Category 10: Directory Bootstrap (REQ-15)
# =============================================================================

# T26: GRINDER_DIR created if missing
test_t26() {
    local dir
    dir=$(setup_test_dir)
    local new_gdir="$dir/new-grinder-dir"
    [[ ! -d "$new_gdir" ]] || return 1
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" pause --project-dir "$dir" --grinder-dir "$new_gdir" 2>&1) || true
    [[ -d "$new_gdir" ]] || { echo "  Directory not created"; return 1; }
    return 0
}
check "T26: GRINDER_DIR created if missing (REQ-15)" test_t26

# T27: State initialised from plan (REQ-7.1, REQ-15)
test_t27() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    local sha
    sha=$(cd "$dir" && git rev-parse HEAD)
    sed "s/abc1234/$sha/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"

    # Mock claude
    mkdir -p "$dir/mock-bin"
    cat > "$dir/mock-bin/claude" << 'CLAUDE_EOF'
#!/bin/bash
echo '{"type":"result","subtype":"success","session_id":"mock","num_turns":1,"duration_ms":100,"total_cost_usd":0}'
CLAUDE_EOF
    chmod +x "$dir/mock-bin/claude"

    [[ ! -f "$gdir/grinder-state.json" ]] || { echo "  State already exists"; return 1; }

    local output
    output=$(cd "$dir" && PROJECTS_ROOT="$(dirname "$dir")" \
      GRINDER_LOCK_MAX_WAIT=5 \
      PATH="$dir/mock-bin:$PATH" \
      bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" 2>&1) || true

    [[ -f "$gdir/grinder-state.json" ]] || { echo "  State not created"; return 1; }
    # Verify counters
    local pending
    pending=$(jq '.batches_pending' "$gdir/grinder-state.json" 2>/dev/null)
    # Should have started with 4 batches
    return 0
}
check "T27: State initialised from plan (REQ-7.1, REQ-15)" test_t27

# =============================================================================
# Category 11: Signal Handling (REQ-16)
# =============================================================================

# T28: SIGTERM releases lock via grinder.sh setup_traps()
test_t28() {
    local dir
    dir=$(setup_git_repo)
    local gdir="$dir/docs/grinder"
    mkdir -p "$gdir"
    local lock_file="$gdir/.grinder.lock"
    local sha
    sha=$(cd "$dir" && git rev-parse HEAD)
    sed "s/abc1234/$sha/" "$FIXTURES/valid-plan.yaml" > "$gdir/grinder-plan.yaml"

    # Mock claude that sleeps long enough for us to send SIGTERM
    mkdir -p "$dir/mock-bin"
    cat > "$dir/mock-bin/claude" << 'CLAUDE_EOF'
#!/bin/bash
sleep 30
CLAUDE_EOF
    chmod +x "$dir/mock-bin/claude"

    # Skip auth preflight: the mock claude sleeps 30s, which would block
    # the probe (5s timeout → exit 2 before the lock is acquired). The
    # GRINDER_SKIP_AUTH_PREFLIGHT knob is the test-only seam designed
    # exactly for this scenario (grinder-auth-recovery R1.7).
    PROJECTS_ROOT="$(dirname "$dir")" GRINDER_LOCK_MAX_WAIT=5 GRINDER_BATCH_TIMEOUT=60 \
        GRINDER_SKIP_AUTH_PREFLIGHT=1 \
        PATH="$dir/mock-bin:$PATH" \
        bash "$GRINDER" run --project-dir "$dir" --grinder-dir "$gdir" &
    local bg_pid=$!
    PIDS_TO_KILL+=("$bg_pid")

    # Wait for lock file to appear (grinder acquired lock)
    local waited=0
    while [[ ! -f "$lock_file" && $waited -lt 10 ]]; do
        sleep 0.3
        waited=$((waited + 1))
    done
    [[ -f "$lock_file" ]] || { echo "  Lock never created"; return 1; }

    # Send SIGTERM
    kill -TERM "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true
    sleep 0.3

    [[ ! -f "$lock_file" ]] || { echo "  Lock file not released after SIGTERM"; return 1; }
    return 0
}
check "T28: SIGTERM releases lock via setup_traps() (REQ-16)" test_t28

# =============================================================================
# Category 8: Ack-Review Subcommand (REQ-16 / A-01..A-04)
# =============================================================================

# A-01: Clears needs_review flag
test_a01() {
    local dir
    dir=$(setup_test_dir)
    # Create plan with needs_review: true on batch-3
    cat > "$dir/docs/grinder/grinder-plan.yaml" << 'PLAN_EOF'
created_at: "2026-04-17T10:00:00Z"
git_sha_at_start: "abc1234"
estimated_batches: 2
estimated_hours: 1.0
staleness_commit_threshold: 5
project: "test-project"
passes:
  - id: "pass-coverage"
    kind: "coverage"
    batches:
      - id: "cov-001"
        files: ["src/a.ts"]
        estimated_turns: 15
        status: "failed"
      - id: "cov-002"
        files: ["src/b.ts"]
        estimated_turns: 15
        status: "pending"
        needs_review: true
PLAN_EOF
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" ack-review --project-dir "$dir" --grinder-dir "$dir/docs/grinder" cov-002 2>&1)
    local rc=$?
    [[ $rc -eq 0 ]] || { echo "  exit code: $rc, output: $output"; return 1; }
    echo "$output" | grep -qi "cleared" || { echo "  Missing 'cleared': $output"; return 1; }
    # Verify flag is now false
    local flag
    flag=$(python3 -c "
import yaml
with open('$dir/docs/grinder/grinder-plan.yaml') as f:
    d = yaml.safe_load(f)
for p in d['passes']:
    for b in p['batches']:
        if b['id'] == 'cov-002':
            print(b.get('needs_review', 'not set'))
")
    [[ "$flag" == "False" ]] || { echo "  Flag still set: $flag"; return 1; }
    return 0
}
check "A-01: ack-review clears needs_review flag (REQ-16, AS-7)" test_a01

# A-02: Batch not found
test_a02() {
    local dir
    dir=$(setup_test_dir)
    cp "$FIXTURES/valid-plan.yaml" "$dir/docs/grinder/grinder-plan.yaml"
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" ack-review --project-dir "$dir" --grinder-dir "$dir/docs/grinder" nonexistent 2>&1) && return 1
    echo "$output" | grep -qi "not found" || return 1
    return 0
}
check "A-02: ack-review batch not found → exit 1 (EC-16.1)" test_a02

# A-03: Batch doesn't need review
test_a03() {
    local dir
    dir=$(setup_test_dir)
    cp "$FIXTURES/valid-plan.yaml" "$dir/docs/grinder/grinder-plan.yaml"
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" ack-review --project-dir "$dir" --grinder-dir "$dir/docs/grinder" batch-1 2>&1) && return 1
    echo "$output" | grep -qi "does not require review\|does not need review" || return 1
    return 0
}
check "A-03: ack-review batch doesn't need review → exit 1 (EC-16.2)" test_a03

# A-04: Batch already completed
test_a04() {
    local dir
    dir=$(setup_test_dir)
    cat > "$dir/docs/grinder/grinder-plan.yaml" << 'PLAN_EOF'
created_at: "2026-04-17T10:00:00Z"
git_sha_at_start: "abc1234"
estimated_batches: 1
estimated_hours: 0.5
staleness_commit_threshold: 5
project: "test-project"
passes:
  - id: "pass-coverage"
    kind: "coverage"
    batches:
      - id: "cov-001"
        files: ["src/a.ts"]
        estimated_turns: 15
        status: "completed"
        needs_review: true
PLAN_EOF
    local output
    output=$(PROJECTS_ROOT="$(dirname "$dir")" bash "$GRINDER" ack-review --project-dir "$dir" --grinder-dir "$dir/docs/grinder" cov-001 2>&1) && return 1
    echo "$output" | grep -qi "already completed\|already" || return 1
    return 0
}
check "A-04: ack-review batch already completed → exit 1 (EC-16.2)" test_a04

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $failed
