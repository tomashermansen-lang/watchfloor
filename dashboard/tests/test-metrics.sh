#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
TOTAL=0

# Temp directory for test JSONL files
TMPDIR_BASE="$PROJECT_DIR/.test-tmp"
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

assert_gt() {
  local label="$1" val="$2" threshold="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$val" -gt "$threshold" ] 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — $val not > $threshold"
  fi
}

# Write a JSONL file with test events
write_test_jsonl() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  : > "$file"
  for line in "$@"; do
    echo "$line" >> "$file"
  done
}

# Run compute_metrics and return JSON
run_metrics() {
  local jsonl_path="$1"
  local sid="${2:-}"
  local since="${3:-}"
  local data_dir
  data_dir="$(dirname "$jsonl_path")"

  local py_script="
import os, json, sys
os.environ['DASHBOARD_DATA_DIR'] = '$data_dir'
sys.path.insert(0, '$PROJECT_DIR')
from server.metrics_helpers import compute_metrics
args = {}
"
  [ -n "$sid" ] && py_script="$py_script
args['sid'] = '$sid'"
  [ -n "$since" ] && py_script="$py_script
args['since'] = '$since'"
  py_script="$py_script
result = compute_metrics(**args)
print(json.dumps(result))
"
  python3 -c "$py_script" 2>&1
}

# ── B1: Reads ALL lines, not just latest per sid ──

test_b1_all_lines() {
  local dir="$TMPDIR_BASE/b1"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"cmd","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Edit","msg":"edit","ts":"2026-03-01T10:01:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Read","msg":"read","ts":"2026-03-01T10:02:00Z"}'

  local result
  result=$(run_metrics "$jsonl")
  local total
  total=$(echo "$result" | jq '.tool_usage.total')
  assert_eq "B1: reads all 3 events" "3" "$total"
}

# ── B2: sid filter ──

test_b2_sid_filter() {
  local dir="$TMPDIR_BASE/b2"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s2","cwd":"/Users/dev/proj","branch":"feat","event":"PreToolUse","type":"Edit","msg":"","ts":"2026-03-01T10:01:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Read","msg":"","ts":"2026-03-01T10:02:00Z"}'

  local result
  result=$(run_metrics "$jsonl" "s1")
  local total
  total=$(echo "$result" | jq '.tool_usage.total')
  assert_eq "B2: sid filter" "2" "$total"
}

# ── B2: since filter ──

test_b2_since_filter() {
  local dir="$TMPDIR_BASE/b2s"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Edit","msg":"","ts":"2026-03-01T11:00:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Read","msg":"","ts":"2026-03-01T12:00:00Z"}'

  local result
  result=$(run_metrics "$jsonl" "" "2026-03-01T10:30:00Z")
  local total
  total=$(echo "$result" | jq '.tool_usage.total')
  assert_eq "B2: since filter" "2" "$total"
}

# ── B3/EC-B1: Missing optional fields ──

test_b3_missing_fields() {
  local dir="$TMPDIR_BASE/b3"
  local jsonl="$dir/sessions.jsonl"
  # Old-format lines (no tuid, model, etc.)
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"cmd","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PostToolUse","type":"Bash","msg":"ok","ts":"2026-03-01T10:00:05Z"}'

  local result
  result=$(run_metrics "$jsonl")
  # Should still count tool usage from type field
  local total
  total=$(echo "$result" | jq '.tool_usage.total')
  assert_eq "B3: old-format tool count" "1" "$total"
  # Permission friction should work but report no tuid data
  local has_tuid
  has_tuid=$(echo "$result" | jq '.permission_friction.has_tuid_data')
  assert_eq "B3: no tuid data" "false" "$has_tuid"
}

# ── B5: Test/temp sessions excluded ──

test_b5_excludes() {
  local dir="$TMPDIR_BASE/b5"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/.test-tmp/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s2","cwd":"/Users/dev/real-proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:01:00Z"}'

  local result
  result=$(run_metrics "$jsonl")
  local total
  total=$(echo "$result" | jq '.tool_usage.total')
  assert_eq "B5: excludes test sessions" "1" "$total"
}

# ── EC-B4: Empty JSONL ──

test_ecb4_empty() {
  local dir="$TMPDIR_BASE/ecb4"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl"

  local result
  result=$(run_metrics "$jsonl")
  local total
  total=$(echo "$result" | jq '.tool_usage.total')
  assert_eq "EC-B4: empty JSONL" "0" "$total"
}

# ── M1: Tool counts and rate ──

test_m1_tool_usage() {
  local dir="$TMPDIR_BASE/m1"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:01:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:02:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Edit","msg":"","ts":"2026-03-01T10:03:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Edit","msg":"","ts":"2026-03-01T10:04:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Read","msg":"","ts":"2026-03-01T10:05:00Z"}'

  local result
  result=$(run_metrics "$jsonl")
  local bash_count edit_count most_used total rate
  bash_count=$(echo "$result" | jq '.tool_usage.by_tool.Bash')
  edit_count=$(echo "$result" | jq '.tool_usage.by_tool.Edit')
  most_used=$(echo "$result" | jq -r '.tool_usage.most_used')
  total=$(echo "$result" | jq '.tool_usage.total')
  rate=$(echo "$result" | jq '.tool_usage.by_session.s1.rate')

  assert_eq "M1: Bash count" "3" "$bash_count"
  assert_eq "M1: Edit count" "2" "$edit_count"
  assert_eq "M1: most used" "Bash" "$most_used"
  assert_eq "M1: total" "6" "$total"
  assert_eq "M1: rate (1.2 calls/min over 5 min)" "1.2" "$rate"
}

# ── M2: Error tracking ──

test_m2_error_tracking() {
  local dir="$TMPDIR_BASE/m2"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:01:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PostToolUseFailure","type":"Bash","msg":"","ts":"2026-03-01T10:01:30Z","err":"cmd failed","intr":"false"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PostToolUseFailure","type":"Write","msg":"","ts":"2026-03-01T10:02:00Z","err":"perm denied","intr":"true"}'

  local result
  result=$(run_metrics "$jsonl")
  local total_errors failures interrupts bash_errors rate
  total_errors=$(echo "$result" | jq '.error_tracking.total_errors')
  failures=$(echo "$result" | jq '.error_tracking.failures')
  interrupts=$(echo "$result" | jq '.error_tracking.interrupts')
  bash_errors=$(echo "$result" | jq '.error_tracking.by_tool.Bash')
  rate=$(echo "$result" | jq -r '.error_tracking.by_session.s1.rate')

  assert_eq "M2: total errors" "2" "$total_errors"
  assert_eq "M2: failures" "1" "$failures"
  assert_eq "M2: interrupts" "1" "$interrupts"
  assert_eq "M2: Bash errors" "1" "$bash_errors"
  assert_eq "M2: error rate (100%)" "100.0" "$rate"
}

# ── M3: Session lifecycle ──

test_m3_session_lifecycle() {
  local dir="$TMPDIR_BASE/m3"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SessionStart","type":"","msg":"","ts":"2026-03-01T10:00:00Z","model":"claude-opus-4-6","src":"startup"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:15:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SessionEnd","type":"","msg":"","ts":"2026-03-01T10:30:00Z","rsn":"clear"}' \
    '{"sid":"s2","cwd":"/Users/dev/proj","branch":"feat","event":"SessionStart","type":"","msg":"","ts":"2026-03-01T10:10:00Z","model":"claude-sonnet-4-6","src":"resume"}'

  local result
  result=$(run_metrics "$jsonl")
  local s1_dur opus_count sonnet_count startup_count resume_count clear_count
  s1_dur=$(echo "$result" | jq '.session_lifecycle.sessions[0].duration_s')
  opus_count=$(echo "$result" | jq '.session_lifecycle.model_distribution."claude-opus-4-6"')
  sonnet_count=$(echo "$result" | jq '.session_lifecycle.model_distribution."claude-sonnet-4-6"')
  startup_count=$(echo "$result" | jq '.session_lifecycle.source_distribution.startup')
  resume_count=$(echo "$result" | jq '.session_lifecycle.source_distribution.resume')
  clear_count=$(echo "$result" | jq '.session_lifecycle.end_reasons.clear')

  assert_eq "M3: s1 duration (30 min = 1800s)" "1800" "$s1_dur"
  assert_eq "M3: opus count" "1" "$opus_count"
  assert_eq "M3: sonnet count" "1" "$sonnet_count"
  assert_eq "M3: startup count" "1" "$startup_count"
  assert_eq "M3: resume count" "1" "$resume_count"
  assert_eq "M3: clear end reason" "1" "$clear_count"
}

# ── M4: Permission friction ──

test_m4_permission_friction() {
  local dir="$TMPDIR_BASE/m4"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:00Z","tuid":"t1"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PermissionRequest","type":"Bash","msg":"","ts":"2026-03-01T10:00:05Z","pmode":"default"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PostToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:02:00Z","tuid":"t1"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PermissionRequest","type":"Write","msg":"","ts":"2026-03-01T10:03:00Z","pmode":"plan"}'

  local result
  result=$(run_metrics "$jsonl")
  local total_prompts bash_prompts has_tuid default_mode blocked_dur
  total_prompts=$(echo "$result" | jq '.permission_friction.total_prompts')
  bash_prompts=$(echo "$result" | jq '.permission_friction.by_tool.Bash')
  has_tuid=$(echo "$result" | jq '.permission_friction.has_tuid_data')
  default_mode=$(echo "$result" | jq '.permission_friction.mode_distribution.default')
  blocked_dur=$(echo "$result" | jq '.permission_friction.blocked_durations[0].duration_s')

  assert_eq "M4: total prompts" "2" "$total_prompts"
  assert_eq "M4: Bash prompts" "1" "$bash_prompts"
  assert_eq "M4: has tuid data" "true" "$has_tuid"
  assert_eq "M4: default mode count" "1" "$default_mode"
  assert_eq "M4: blocked duration (120s)" "120" "$blocked_dur"
}

# ── M5: Subagent utilization ──

test_m5_subagent() {
  local dir="$TMPDIR_BASE/m5"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SubagentStart","type":"","msg":"","ts":"2026-03-01T10:00:00Z","atype":"Explore","aid":"a1"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SubagentStart","type":"","msg":"","ts":"2026-03-01T10:01:00Z","atype":"Plan","aid":"a2"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SubagentStop","type":"","msg":"","ts":"2026-03-01T10:02:00Z","atype":"Plan","aid":"a2"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SubagentStop","type":"","msg":"","ts":"2026-03-01T10:03:00Z","atype":"Explore","aid":"a1"}'

  local result
  result=$(run_metrics "$jsonl")
  local spawned explore_count peak
  spawned=$(echo "$result" | jq '.subagent_utilization.total_spawned')
  explore_count=$(echo "$result" | jq '.subagent_utilization.by_type.Explore')
  peak=$(echo "$result" | jq '.subagent_utilization.peak_concurrent')

  assert_eq "M5: total spawned" "2" "$spawned"
  assert_eq "M5: Explore count" "1" "$explore_count"
  assert_eq "M5: peak concurrent" "2" "$peak"
}

# ── EC-B2: SubagentStart with no matching Stop ──

test_ecb2_running_subagent() {
  local dir="$TMPDIR_BASE/ecb2"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SubagentStart","type":"","msg":"","ts":"2026-03-01T10:00:00Z","atype":"Explore","aid":"a1"}'

  local result
  result=$(run_metrics "$jsonl")
  local running_count running_aid
  running_count=$(echo "$result" | jq '.subagent_utilization.running | length')
  running_aid=$(echo "$result" | jq -r '.subagent_utilization.running[0].aid')
  assert_eq "EC-B2: running count" "1" "$running_count"
  assert_eq "EC-B2: running aid" "a1" "$running_aid"
}

# ── M6: File activity ──

test_m6_file_activity() {
  local dir="$TMPDIR_BASE/m6"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Edit","msg":"","ts":"2026-03-01T10:00:00Z","fp":"/src/auth.ts"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Read","msg":"","ts":"2026-03-01T10:01:00Z","fp":"/src/db.ts"}' \
    '{"sid":"s2","cwd":"/Users/dev/proj","branch":"feat","event":"PreToolUse","type":"Edit","msg":"","ts":"2026-03-01T10:02:00Z","fp":"/src/auth.ts"}'

  local result
  result=$(run_metrics "$jsonl")
  local total edited conflicts conflict_path has_fp
  total=$(echo "$result" | jq '.file_activity.summary.total')
  edited=$(echo "$result" | jq '.file_activity.summary.edited')
  conflicts=$(echo "$result" | jq '.file_activity.conflicts | length')
  conflict_path=$(echo "$result" | jq -r '.file_activity.conflicts[0].path')
  has_fp=$(echo "$result" | jq '.file_activity.has_fp_data')

  assert_eq "M6: total files" "2" "$total"
  assert_eq "M6: edited files" "1" "$edited"
  assert_eq "M6: 1 conflict" "1" "$conflicts"
  assert_eq "M6: conflict path" "/src/auth.ts" "$conflict_path"
  assert_eq "M6: has fp data" "true" "$has_fp"
}

# ── M6: No fp data ──

test_m6_no_fp() {
  local dir="$TMPDIR_BASE/m6nfp"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:00Z"}'

  local result
  result=$(run_metrics "$jsonl")
  local has_fp
  has_fp=$(echo "$result" | jq '.file_activity.has_fp_data')
  assert_eq "M6: no fp data" "false" "$has_fp"
}

# ── M7: Task completion ──

test_m7_tasks() {
  local dir="$TMPDIR_BASE/m7"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SessionStart","type":"","msg":"","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"TaskCompleted","type":"","msg":"","ts":"2026-03-01T10:30:00Z","tsub":"Fix auth bug","tid":"t1"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"TaskCompleted","type":"","msg":"","ts":"2026-03-01T11:00:00Z","tsub":"Add tests","tid":"t2"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"TaskCompleted","type":"","msg":"","ts":"2026-03-01T11:30:00Z","tsub":"Update docs","tid":"t3"}'

  local result
  result=$(run_metrics "$jsonl")
  local total first_subject rate
  total=$(echo "$result" | jq '.task_completion.total')
  first_subject=$(echo "$result" | jq -r '.task_completion.tasks[0].subject')
  rate=$(echo "$result" | jq '.task_completion.rates.s1')

  assert_eq "M7: total tasks" "3" "$total"
  assert_eq "M7: first subject" "Fix auth bug" "$first_subject"
  assert_eq "M7: rate (2.0 tasks/hr over 1.5hr)" "2.0" "$rate"
}

# ── M8: Activity timeline ──

test_m8_timeline() {
  local dir="$TMPDIR_BASE/m8"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SessionStart","type":"","msg":"","ts":"2026-03-01T10:00:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:30Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PostToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:35Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Edit","msg":"","ts":"2026-03-01T10:05:00Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"SessionEnd","type":"","msg":"","ts":"2026-03-01T10:10:00Z"}'

  local result
  result=$(run_metrics "$jsonl")
  local session_count event_count idle_gaps category
  session_count=$(echo "$result" | jq '.activity_timeline.sessions | length')
  event_count=$(echo "$result" | jq '.activity_timeline.sessions[0].events | length')
  idle_gaps=$(echo "$result" | jq '.activity_timeline.sessions[0].idle_gaps | length')
  category=$(echo "$result" | jq -r '.activity_timeline.sessions[0].events[0].category')

  assert_eq "M8: 1 session" "1" "$session_count"
  assert_eq "M8: 5 events" "5" "$event_count"
  # Gap between 10:00:35→10:05:00 (265s) and 10:05:00→10:10:00 (300s) both > 60s
  assert_eq "M8: 2 idle gaps" "2" "$idle_gaps"
  assert_eq "M8: first event category is session" "session" "$category"
}

# ── EC-B6: Multiple PermissionRequests between same pre/post ──

test_ecb6_multiple_permissions() {
  local dir="$TMPDIR_BASE/ecb6"
  local jsonl="$dir/sessions.jsonl"
  write_test_jsonl "$jsonl" \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PreToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:00:00Z","tuid":"t1"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PermissionRequest","type":"Bash","msg":"","ts":"2026-03-01T10:00:05Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PermissionRequest","type":"Bash","msg":"","ts":"2026-03-01T10:00:10Z"}' \
    '{"sid":"s1","cwd":"/Users/dev/proj","branch":"main","event":"PostToolUse","type":"Bash","msg":"","ts":"2026-03-01T10:01:00Z","tuid":"t1"}'

  local result
  result=$(run_metrics "$jsonl")
  local prompts durations_count
  prompts=$(echo "$result" | jq '.permission_friction.total_prompts')
  durations_count=$(echo "$result" | jq '.permission_friction.blocked_durations | length')
  assert_eq "EC-B6: 2 prompts" "2" "$prompts"
  assert_eq "EC-B6: 1 blocked duration" "1" "$durations_count"
}

# ── Run all tests ──

echo "Metrics helpers tests"
echo "====================="

test_b1_all_lines
test_b2_sid_filter
test_b2_since_filter
test_b3_missing_fields
test_b5_excludes
test_ecb4_empty
test_m1_tool_usage
test_m2_error_tracking
test_m3_session_lifecycle
test_m4_permission_friction
test_m5_subagent
test_ecb2_running_subagent
test_m6_file_activity
test_m6_no_fp
test_m7_tasks
test_m8_timeline
test_ecb6_multiple_permissions

echo ""
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
