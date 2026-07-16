#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/report-status.sh"
PASS=0
FAIL=0
TOTAL=0

# Create isolated temp directory under $HOME
TMPDIR_BASE="$(cd "$SCRIPT_DIR/.." && pwd)/.test-tmp-concurrent"
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

TEST_DATA_DIR="$TMPDIR_BASE/data"
mkdir -p "$TEST_DATA_DIR"
TEST_JSONL="$TEST_DATA_DIR/sessions.jsonl"
TEST_CWD="$TMPDIR_BASE/worktree"
mkdir -p "$TEST_CWD"
git -C "$TEST_CWD" init -q 2>/dev/null
git -C "$TEST_CWD" checkout -b "feature/concurrent" 2>/dev/null

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

# ── Test: 5 parallel hook invocations ──

test_5_parallel() {
  rm -f "$TEST_JSONL"
  local n=5
  local pids=()

  for i in $(seq 1 $n); do
    echo '{"session_id":"sess-par-'"$i"'","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"parallel write '"$i"'"}' | \
      DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # All lines must be valid JSON
  local bad_lines=0
  if [ -f "$TEST_JSONL" ]; then
    while IFS= read -r line; do
      if ! echo "$line" | jq -e . >/dev/null 2>&1; then
        bad_lines=$((bad_lines + 1))
      fi
    done < "$TEST_JSONL"
  fi
  assert_eq "5-parallel: all lines valid JSON" "0" "$bad_lines"

  # Line count should match invocation count
  local line_count=0
  if [ -f "$TEST_JSONL" ]; then
    line_count=$(wc -l < "$TEST_JSONL" | tr -d ' ')
  fi
  assert_eq "5-parallel: line count" "$n" "$line_count"
}

# ── Test: 10 parallel invocations ──

test_10_parallel() {
  rm -f "$TEST_JSONL"
  local n=10
  local pids=()

  for i in $(seq 1 $n); do
    echo '{"session_id":"sess-par10-'"$i"'","cwd":"'"$TEST_CWD"'","hook_event_name":"Stop","last_assistant_message":"stop message '"$i"'"}' | \
      DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local bad_lines=0
  if [ -f "$TEST_JSONL" ]; then
    while IFS= read -r line; do
      if ! echo "$line" | jq -e . >/dev/null 2>&1; then
        bad_lines=$((bad_lines + 1))
      fi
    done < "$TEST_JSONL"
  fi
  assert_eq "10-parallel: all lines valid JSON" "0" "$bad_lines"

  local line_count=0
  if [ -f "$TEST_JSONL" ]; then
    line_count=$(wc -l < "$TEST_JSONL" | tr -d ' ')
  fi
  assert_eq "10-parallel: line count" "$n" "$line_count"
}

# ── Test: Concurrent write during rotation ──

test_concurrent_rotation() {
  rm -f "$TEST_JSONL" "$TEST_JSONL.1"
  # Create a file just over 1MB to trigger rotation
  dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\0' 'x' > "$TEST_JSONL"

  local n=5
  local pids=()

  for i in $(seq 1 $n); do
    echo '{"session_id":"sess-rot-'"$i"'","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"rotation test '"$i"'"}' | \
      DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # New JSONL should exist and contain only valid JSON lines
  TOTAL=$((TOTAL + 1))
  if [ -f "$TEST_JSONL" ]; then
    local bad_lines=0
    while IFS= read -r line; do
      if [ -n "$line" ] && ! echo "$line" | jq -e . >/dev/null 2>&1; then
        bad_lines=$((bad_lines + 1))
      fi
    done < "$TEST_JSONL"
    if [ "$bad_lines" -eq 0 ]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: Concurrent rotation: $bad_lines corrupted lines"
    fi
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Concurrent rotation: JSONL file missing"
  fi
}

# ── Test: Unique session IDs preserved ──

test_unique_sids() {
  rm -f "$TEST_JSONL"
  local n=5
  local pids=()

  for i in $(seq 1 $n); do
    echo '{"session_id":"sess-uniq-'"$i"'","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"unique test"}' | \
      DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # All session IDs should be unique
  if [ -f "$TEST_JSONL" ]; then
    local unique_sids
    unique_sids=$(jq -r '.sid' "$TEST_JSONL" | sort -u | wc -l | tr -d ' ')
    assert_eq "Unique SIDs: all distinct" "$n" "$unique_sids"
  else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: Unique SIDs: JSONL file missing"
  fi
}

# ── Run all tests ──

echo "Concurrent write tests"
echo "======================"

test_5_parallel
test_10_parallel
test_concurrent_rotation
test_unique_sids

echo ""
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
