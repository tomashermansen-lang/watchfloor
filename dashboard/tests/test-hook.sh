#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/report-status.sh"
PASS=0
FAIL=0
TOTAL=0

# Create isolated temp directory under $HOME (hook validates cwd is under $HOME)
TMPDIR_BASE="$(cd "$SCRIPT_DIR/.." && pwd)/.test-tmp"
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup() {
  TEST_DATA_DIR="$TMPDIR_BASE/data-$$-$RANDOM"
  mkdir -p "$TEST_DATA_DIR"
  TEST_JSONL="$TEST_DATA_DIR/sessions.jsonl"
  # Create a valid cwd directory under $HOME (hook validates this)
  TEST_CWD="$TMPDIR_BASE/worktree-$$-$RANDOM"
  mkdir -p "$TEST_CWD"
  # Initialize a git repo so git branch works
  git -C "$TEST_CWD" init -q 2>/dev/null
  git -C "$TEST_CWD" checkout -b "feature/test-branch" 2>/dev/null
}

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

assert_file_exists() {
  local label="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — file not found: $path"
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — file should not exist: $path"
  fi
}

assert_line_count() {
  local label="$1" expected="$2" file="$3"
  local actual=0
  if [ -f "$file" ]; then
    actual=$(wc -l < "$file" | tr -d ' ')
  fi
  assert_eq "$label" "$expected" "$actual"
}

assert_valid_json() {
  local label="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$file" ] && jq -e . "$file" > /dev/null 2>&1; then
    # Each line should be valid JSON
    local bad_lines
    bad_lines=$(while IFS= read -r line; do
      echo "$line" | jq -e . > /dev/null 2>&1 || echo "bad"
    done < "$file" | wc -l | tr -d ' ')
    if [ "$bad_lines" = "0" ]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $label — $bad_lines lines are not valid JSON"
    fi
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — file missing or not valid JSON"
  fi
}

run_hook() {
  local input="$1"
  echo "$input" | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null
}

# ── Test: Valid Notification event ──

test_notification_event() {
  setup
  local input='{"session_id":"sess-abc123","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow write to src/db/schema.py"}'

  run_hook "$input"

  assert_file_exists "Notification: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local sid event type msg branch
    sid=$(jq -r '.sid' "$TEST_JSONL")
    event=$(jq -r '.event' "$TEST_JSONL")
    type=$(jq -r '.type' "$TEST_JSONL")
    msg=$(jq -r '.msg' "$TEST_JSONL")
    branch=$(jq -r '.branch' "$TEST_JSONL")

    assert_eq "Notification: sid" "sess-abc123" "$sid"
    assert_eq "Notification: event" "Notification" "$event"
    assert_eq "Notification: type" "permission_prompt" "$type"
    assert_eq "Notification: msg" "Allow write to src/db/schema.py" "$msg"
    assert_eq "Notification: branch" "feature/test-branch" "$branch"

    # Verify timestamp format (ISO 8601 UTC)
    local ts
    ts=$(jq -r '.ts' "$TEST_JSONL")
    TOTAL=$((TOTAL + 1))
    if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: Notification: timestamp format — got: $ts"
    fi

    # Verify cwd field
    local cwd
    cwd=$(jq -r '.cwd' "$TEST_JSONL")
    assert_eq "Notification: cwd" "$TEST_CWD" "$cwd"
  fi
}

# ── Test: Valid Stop event ──

test_stop_event() {
  setup
  local input='{"session_id":"sess-stop1","cwd":"'"$TEST_CWD"'","hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"All tasks completed successfully"}'

  run_hook "$input"

  assert_file_exists "Stop: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local sid event msg
    sid=$(jq -r '.sid' "$TEST_JSONL")
    event=$(jq -r '.event' "$TEST_JSONL")
    msg=$(jq -r '.msg' "$TEST_JSONL")

    assert_eq "Stop: sid" "sess-stop1" "$sid"
    assert_eq "Stop: event" "Stop" "$event"
    assert_eq "Stop: msg" "All tasks completed successfully" "$msg"
  fi
}

# ── Test: Valid TaskCompleted event ──

test_task_completed_event() {
  setup
  local input='{"session_id":"sess-task1","cwd":"'"$TEST_CWD"'","hook_event_name":"TaskCompleted","task_id":"task-42","task_subject":"Implement auth module","task_description":"Added JWT authentication"}'

  run_hook "$input"

  assert_file_exists "TaskCompleted: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local sid event msg tsub
    sid=$(jq -r '.sid' "$TEST_JSONL")
    event=$(jq -r '.event' "$TEST_JSONL")
    msg=$(jq -r '.msg' "$TEST_JSONL")
    tsub=$(jq -r '.tsub' "$TEST_JSONL")

    assert_eq "TaskCompleted: sid" "sess-task1" "$sid"
    assert_eq "TaskCompleted: event" "TaskCompleted" "$event"
    # msg is now empty for TaskCompleted (H10: tsub carries the content)
    assert_eq "TaskCompleted: msg empty" "" "$msg"
    assert_eq "TaskCompleted: tsub" "Implement auth module" "$tsub"
  fi
}

# ── Test: Valid SubagentStop event ──

test_subagent_stop_event() {
  setup
  local input='{"session_id":"sess-sub1","cwd":"'"$TEST_CWD"'","hook_event_name":"SubagentStop","agent_id":"agent-7","agent_type":"Explore","last_assistant_message":"Found 3 relevant files"}'

  run_hook "$input"

  assert_file_exists "SubagentStop: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local sid event msg
    sid=$(jq -r '.sid' "$TEST_JSONL")
    event=$(jq -r '.event' "$TEST_JSONL")
    msg=$(jq -r '.msg' "$TEST_JSONL")

    assert_eq "SubagentStop: sid" "sess-sub1" "$sid"
    assert_eq "SubagentStop: event" "SubagentStop" "$event"
    assert_eq "SubagentStop: msg" "Found 3 relevant files" "$msg"
  fi
}

# ── Test: Empty stdin ──

test_empty_stdin() {
  setup
  echo "" | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null

  assert_file_not_exists "Empty stdin: no JSONL written" "$TEST_JSONL"
}

# ── Test: Malformed JSON stdin ──

test_malformed_json() {
  setup
  echo "this is not json{{{" | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null

  assert_file_not_exists "Malformed JSON: no JSONL written" "$TEST_JSONL"
}

# ── Test: Missing session_id ──

test_missing_session_id() {
  setup
  local input='{"cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Missing session_id: no JSONL written" "$TEST_JSONL"
}

# ── Test: Invalid cwd (nonexistent directory) ──

test_invalid_cwd() {
  setup
  local input='{"session_id":"sess-bad-cwd","cwd":"/nonexistent/path/to/nowhere","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Invalid cwd: no JSONL written" "$TEST_JSONL"
}

# ── Test: Message truncation at 200 chars ──

test_message_truncation() {
  setup
  # Create a message longer than 200 chars
  local long_msg
  long_msg=$(printf 'A%.0s' $(seq 1 300))
  local input='{"session_id":"sess-trunc","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"'"$long_msg"'"}'

  run_hook "$input"

  assert_file_exists "Truncation: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local msg_len
    msg_len=$(jq -r '.msg | length' "$TEST_JSONL")
    TOTAL=$((TOTAL + 1))
    if [ "$msg_len" -le 200 ]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: Truncation: message length $msg_len > 200"
    fi
  fi
}

# ── Test: JSONL rotation at 1MB ──

test_jsonl_rotation() {
  setup
  # Create a file just over 1MB
  dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\0' 'x' > "$TEST_JSONL"

  local input='{"session_id":"sess-rotate","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"trigger rotation"}'

  run_hook "$input"

  # Old file should have been rotated to .1
  assert_file_exists "Rotation: backup file created" "$TEST_JSONL.1"

  # New JSONL should contain just the new entry
  if [ -f "$TEST_JSONL" ]; then
    assert_line_count "Rotation: new file has 1 line" "1" "$TEST_JSONL"
  fi
}

# ── Test: Hook exits 0 on all errors ──

test_exit_code_always_zero() {
  setup
  local ret

  # Empty stdin
  ret=0
  echo "" | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null || ret=$?
  assert_eq "Exit code: empty stdin" "0" "$ret"

  # Malformed JSON
  ret=0
  echo "not json" | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null || ret=$?
  assert_eq "Exit code: malformed JSON" "0" "$ret"

  # Invalid session_id
  ret=0
  echo '{"session_id":"$(rm -rf /)","cwd":"/tmp","hook_event_name":"Stop"}' | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null || ret=$?
  assert_eq "Exit code: invalid session_id" "0" "$ret"
}

# ── Test: Notification without notification_type uses empty type ──

test_notification_no_type() {
  setup
  local input='{"session_id":"sess-notype","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"idle notification"}'

  run_hook "$input"

  assert_file_exists "No type: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local type
    type=$(jq -r '.type' "$TEST_JSONL")
    assert_eq "No type: type is empty or null" "true" "$([ "$type" = "" ] || [ "$type" = "null" ] && echo true || echo false)"
  fi
}

# ── Run all tests ──

echo "Hook functional tests"
echo "====================="

test_notification_event
test_stop_event
test_task_completed_event
test_subagent_stop_event
test_empty_stdin
test_malformed_json
test_missing_session_id
test_invalid_cwd
test_message_truncation
test_jsonl_rotation
test_exit_code_always_zero
test_notification_no_type

echo ""
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
