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
  TEST_CWD="$TMPDIR_BASE/worktree-$$-$RANDOM"
  mkdir -p "$TEST_CWD"
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

assert_field_absent() {
  local label="$1" field="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  local val
  val=$(jq -r ".$field // \"__ABSENT__\"" "$file")
  if [ "$val" = "__ABSENT__" ] || [ "$val" = "null" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — field $field should be absent, got: $val"
  fi
}

run_hook() {
  local input="$1"
  echo "$input" | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null
}

# ── H1: PostToolUseFailure event produces JSONL ──

test_h1_posttoolusefailure() {
  setup
  local input='{"session_id":"sess-h1","cwd":"'"$TEST_CWD"'","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"tuid-abc123","error":"Command not found: foobar","is_interrupt":false}'

  run_hook "$input"

  assert_file_exists "H1: JSONL created for PostToolUseFailure" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local event
    event=$(jq -r '.event' "$TEST_JSONL")
    assert_eq "H1: event" "PostToolUseFailure" "$event"
  fi
}

# ── H2: PreToolUse/PostToolUse/PostToolUseFailure include tuid ──

test_h2_tuid() {
  setup
  local input='{"session_id":"sess-h2","cwd":"'"$TEST_CWD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"tuid-xyz789"}'

  run_hook "$input"

  assert_file_exists "H2: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local tuid
    tuid=$(jq -r '.tuid' "$TEST_JSONL")
    assert_eq "H2: tuid on PreToolUse" "tuid-xyz789" "$tuid"
  fi
}

# ── H3: SessionStart includes model and src ──

test_h3_session_start_fields() {
  setup
  local input='{"session_id":"sess-h3","cwd":"'"$TEST_CWD"'","hook_event_name":"SessionStart","model":"claude-opus-4-6","source":"startup","permission_mode":"default"}'

  run_hook "$input"

  assert_file_exists "H3: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local model src
    model=$(jq -r '.model' "$TEST_JSONL")
    src=$(jq -r '.src' "$TEST_JSONL")
    assert_eq "H3: model" "claude-opus-4-6" "$model"
    assert_eq "H3: src" "startup" "$src"
  fi
}

# ── H4: SessionEnd includes rsn ──

test_h4_session_end_reason() {
  setup
  local input='{"session_id":"sess-h4","cwd":"'"$TEST_CWD"'","hook_event_name":"SessionEnd","reason":"clear"}'

  run_hook "$input"

  assert_file_exists "H4: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local rsn
    rsn=$(jq -r '.rsn' "$TEST_JSONL")
    assert_eq "H4: rsn" "clear" "$rsn"
  fi
}

# ── H5: SubagentStart/SubagentStop include atype and aid ──

test_h5_subagent_fields() {
  setup
  local input='{"session_id":"sess-h5","cwd":"'"$TEST_CWD"'","hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"agent-42"}'

  run_hook "$input"

  assert_file_exists "H5: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local atype aid
    atype=$(jq -r '.atype' "$TEST_JSONL")
    aid=$(jq -r '.aid' "$TEST_JSONL")
    assert_eq "H5: atype" "Explore" "$atype"
    assert_eq "H5: aid" "agent-42" "$aid"
  fi
}

# ── H6: PostToolUseFailure includes err and intr ──

test_h6_error_fields() {
  setup
  local input='{"session_id":"sess-h6","cwd":"'"$TEST_CWD"'","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"tuid-err1","error":"Command failed: exit 1","is_interrupt":false}'

  run_hook "$input"

  assert_file_exists "H6: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local err intr
    err=$(jq -r '.err' "$TEST_JSONL")
    intr=$(jq -r '.intr' "$TEST_JSONL")
    assert_eq "H6: err" "Command failed: exit 1" "$err"
    assert_eq "H6: intr" "false" "$intr"
  fi
}

# ── H7: PreToolUse with Read/Write/Edit includes fp ──

test_h7_file_path() {
  setup
  local input='{"session_id":"sess-h7","cwd":"'"$TEST_CWD"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_use_id":"tuid-fp1","tool_input":{"file_path":"'"$HOME"'/project/src/auth.ts","old_string":"foo","new_string":"bar"}}'

  run_hook "$input"

  assert_file_exists "H7: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local fp
    fp=$(jq -r '.fp' "$TEST_JSONL")
    assert_eq "H7: fp" "$HOME/project/src/auth.ts" "$fp"
  fi
}

# ── H7: fp with path traversal (..) rejected ──

test_h7_path_traversal_rejected() {
  setup
  local input='{"session_id":"sess-h7pt","cwd":"'"$TEST_CWD"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_use_id":"tuid-fp2","tool_input":{"file_path":"'"$HOME"'/../../etc/passwd","old_string":"a","new_string":"b"}}'

  run_hook "$input"

  assert_file_exists "H7-PT: JSONL created (event not dropped)" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    # fp should be absent since it has path traversal
    assert_field_absent "H7-PT: fp omitted for path traversal" "fp" "$TEST_JSONL"
  fi
}

# ── H8: TaskCompleted includes tsub and tid ──

test_h8_task_fields() {
  setup
  local input='{"session_id":"sess-h8","cwd":"'"$TEST_CWD"'","hook_event_name":"TaskCompleted","task_id":"task-99","task_subject":"Fix auth bug","task_description":"Fixed JWT validation"}'

  run_hook "$input"

  assert_file_exists "H8: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local tsub tid
    tsub=$(jq -r '.tsub' "$TEST_JSONL")
    tid=$(jq -r '.tid' "$TEST_JSONL")
    assert_eq "H8: tsub" "Fix auth bug" "$tsub"
    assert_eq "H8: tid" "task-99" "$tid"
  fi
}

# ── H9: SessionStart/PermissionRequest include pmode ──

test_h9_pmode() {
  setup
  local input='{"session_id":"sess-h9","cwd":"'"$TEST_CWD"'","hook_event_name":"PermissionRequest","tool_name":"Bash","permission_mode":"plan"}'

  run_hook "$input"

  assert_file_exists "H9: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local pmode
    pmode=$(jq -r '.pmode' "$TEST_JSONL")
    assert_eq "H9: pmode" "plan" "$pmode"
  fi
}

# ── H10/EC-H3: Line > 512 bytes triggers field dropping ──

test_h10_field_dropping() {
  setup
  # Create a long cwd path to push line over 512 bytes
  local long_dir="$TMPDIR_BASE/worktree-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$long_dir"
  git -C "$long_dir" init -q 2>/dev/null
  git -C "$long_dir" checkout -b "feature/very-long-branch-name-that-uses-many-chars" 2>/dev/null

  local long_err
  long_err=$(printf 'E%.0s' $(seq 1 100))
  local input='{"session_id":"sess-h10","cwd":"'"$long_dir"'","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"tuid-long-id-abcdef123456","error":"'"$long_err"'","is_interrupt":false}'

  run_hook "$input"

  assert_file_exists "H10: JSONL still written" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    # Line must be <= 512 bytes
    local line_size
    line_size=$(wc -c < "$TEST_JSONL" | tr -d ' ')
    TOTAL=$((TOTAL + 1))
    if [ "$line_size" -le 513 ]; then  # +1 for newline
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: H10: line size $line_size > 513 bytes (512 + newline)"
    fi
  fi
}

# ── H12: Invalid tuid (special chars) omitted ──

test_h12_invalid_tuid() {
  setup
  local input='{"session_id":"sess-h12","cwd":"'"$TEST_CWD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"tuid$(rm -rf /)"}'

  run_hook "$input"

  assert_file_exists "H12-tuid: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    assert_field_absent "H12-tuid: invalid tuid omitted" "tuid" "$TEST_JSONL"
  fi
}

# ── H12: Invalid model (special chars) omitted ──

test_h12_invalid_model() {
  setup
  local input='{"session_id":"sess-h12m","cwd":"'"$TEST_CWD"'","hook_event_name":"SessionStart","model":"bad;model","source":"startup"}'

  run_hook "$input"

  assert_file_exists "H12-model: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    assert_field_absent "H12-model: invalid model omitted" "model" "$TEST_JSONL"
  fi
}

# ── H12: Invalid pmode value omitted ──

test_h12_invalid_pmode() {
  setup
  local input='{"session_id":"sess-h12p","cwd":"'"$TEST_CWD"'","hook_event_name":"SessionStart","model":"claude-opus-4-6","source":"startup","permission_mode":"hacked"}'

  run_hook "$input"

  assert_file_exists "H12-pmode: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    assert_field_absent "H12-pmode: invalid pmode omitted" "pmode" "$TEST_JSONL"
  fi
}

# ── H13: Old-format input (no new fields) produces valid JSONL ──

test_h13_backward_compat() {
  setup
  local input='{"session_id":"sess-h13","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","notification_type":"agent","message":"working on task"}'

  run_hook "$input"

  assert_file_exists "H13: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local sid event
    sid=$(jq -r '.sid' "$TEST_JSONL")
    event=$(jq -r '.event' "$TEST_JSONL")
    assert_eq "H13: sid" "sess-h13" "$sid"
    assert_eq "H13: event" "Notification" "$event"
    # New fields should not appear (backward compat)
    assert_field_absent "H13: no tuid" "tuid" "$TEST_JSONL"
    assert_field_absent "H13: no model" "model" "$TEST_JSONL"
  fi
}

# ── EC-H1: Error > 100 chars truncated ──

test_ech1_error_truncation() {
  setup
  local long_error
  long_error=$(printf 'X%.0s' $(seq 1 200))
  local input='{"session_id":"sess-ech1","cwd":"'"$TEST_CWD"'","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"tuid-ech1","error":"'"$long_error"'","is_interrupt":true}'

  run_hook "$input"

  assert_file_exists "EC-H1: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local err_len
    err_len=$(jq -r '.err | length' "$TEST_JSONL")
    TOTAL=$((TOTAL + 1))
    if [ "$err_len" -le 100 ]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: EC-H1: error length $err_len > 100"
    fi
  fi
}

# ── EC-H2: File path > 120 chars truncated from left ──

test_ech2_fp_truncation() {
  setup
  local long_path="$HOME/very/deeply/nested/project/with/many/directory/levels/that/go/on/and/on/and/on/forever/components/features/auth/module.ts"
  local input='{"session_id":"sess-ech2","cwd":"'"$TEST_CWD"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"tuid-ech2","tool_input":{"file_path":"'"$long_path"'"}}'

  run_hook "$input"

  assert_file_exists "EC-H2: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local fp_len fp
    fp=$(jq -r '.fp' "$TEST_JSONL")
    fp_len=${#fp}
    TOTAL=$((TOTAL + 1))
    if [ "$fp_len" -le 120 ]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: EC-H2: fp length $fp_len > 120"
    fi
    # Must preserve filename
    TOTAL=$((TOTAL + 1))
    if [[ "$fp" == *"module.ts" ]]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: EC-H2: fp does not end with module.ts: $fp"
    fi
  fi
}

# ── EC-H4: Missing is_interrupt → no intr field ──

test_ech4_missing_is_interrupt() {
  setup
  local input='{"session_id":"sess-ech4","cwd":"'"$TEST_CWD"'","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"tuid-ech4","error":"something broke"}'

  run_hook "$input"

  assert_file_exists "EC-H4: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    assert_field_absent "EC-H4: intr absent when is_interrupt missing" "intr" "$TEST_JSONL"
  fi
}

# ── EC-H5: Missing model → no model field ──

test_ech5_missing_model() {
  setup
  local input='{"session_id":"sess-ech5","cwd":"'"$TEST_CWD"'","hook_event_name":"SessionStart","source":"startup"}'

  run_hook "$input"

  assert_file_exists "EC-H5: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    assert_field_absent "EC-H5: model absent" "model" "$TEST_JSONL"
    local src
    src=$(jq -r '.src' "$TEST_JSONL")
    assert_eq "EC-H5: src still present" "startup" "$src"
  fi
}

# ── EC-H6: Non-object tool_input → no fp field ──

test_ech6_non_object_tool_input() {
  setup
  local input='{"session_id":"sess-ech6","cwd":"'"$TEST_CWD"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"tuid-ech6","tool_input":"some string"}'

  run_hook "$input"

  assert_file_exists "EC-H6: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    assert_field_absent "EC-H6: fp absent for non-object tool_input" "fp" "$TEST_JSONL"
  fi
}

# ── H10: msg reduced for events with extra fields ──

test_h10_msg_truncation_tiers() {
  setup
  local long_msg
  long_msg=$(printf 'M%.0s' $(seq 1 250))
  local input='{"session_id":"sess-h10t","cwd":"'"$TEST_CWD"'","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"tuid-h10t","error":"short error","is_interrupt":false,"message":"'"$long_msg"'"}'

  run_hook "$input"

  assert_file_exists "H10-tier: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local msg_len
    msg_len=$(jq -r '.msg | length' "$TEST_JSONL")
    TOTAL=$((TOTAL + 1))
    # PostToolUseFailure should have msg truncated to 60, not 200
    if [ "$msg_len" -le 60 ]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: H10-tier: msg length $msg_len > 60 for PostToolUseFailure"
    fi
  fi
}

# ── H10: TaskCompleted msg set to empty ──

test_h10_task_msg_empty() {
  setup
  local input='{"session_id":"sess-h10tc","cwd":"'"$TEST_CWD"'","hook_event_name":"TaskCompleted","task_id":"task-1","task_subject":"Fix auth bug","message":"this should be dropped"}'

  run_hook "$input"

  assert_file_exists "H10-task: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local msg
    msg=$(jq -r '.msg' "$TEST_JSONL")
    assert_eq "H10-task: msg is empty for TaskCompleted" "" "$msg"
  fi
}

# ── EC-H7: Invalid tool_use_id → no tuid ──

test_ech7_invalid_tuid() {
  setup
  local input='{"session_id":"sess-ech7","cwd":"'"$TEST_CWD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"invalid id with spaces!"}'

  run_hook "$input"

  assert_file_exists "EC-H7: JSONL created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    assert_field_absent "EC-H7: invalid tuid omitted" "tuid" "$TEST_JSONL"
  fi
}

# ── Run all tests ──

echo "Hook expanded field tests"
echo "========================="

test_h1_posttoolusefailure
test_h2_tuid
test_h3_session_start_fields
test_h4_session_end_reason
test_h5_subagent_fields
test_h6_error_fields
test_h7_file_path
test_h7_path_traversal_rejected
test_h8_task_fields
test_h9_pmode
test_h10_field_dropping
test_h12_invalid_tuid
test_h12_invalid_model
test_h12_invalid_pmode
test_h13_backward_compat
test_ech1_error_truncation
test_ech2_fp_truncation
test_ech4_missing_is_interrupt
test_ech5_missing_model
test_ech6_non_object_tool_input
test_h10_msg_truncation_tiers
test_h10_task_msg_empty
test_ech7_invalid_tuid

echo ""
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
