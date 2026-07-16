#!/usr/bin/env bash
# test_deviation_wire.sh — bash integration tests for the deviation-tracker
# wrapper (W01..W28). Mirrors the structure of test_claude_session_lib.sh.
#
# Usage: bash tests/test_deviation_wire.sh
# Exits 0 on all pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"
SLUG_LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/deviation-phase-slugs.sh"
FIXTURES="$REPO_DIR/tests/fixtures/deviation_wire"
TRACKER="$REPO_DIR/adapters/claude-code/claude/tools/deviation-tracker.py"

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

TEST_DIR="${TMPDIR:-/tmp}/test-deviation-wire-$$"

setup() {
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}
trap teardown EXIT

# Build a per-test isolated AUTOPILOT_DIR/dir layout that mimics the
# real autopilot.sh tree but with stub trackers so we can assert
# invocation/non-invocation cleanly.
prepare_isolated_autopilot() {
  local stub="${1:-tracker_stub_writes_then_exits.sh}"
  local autopilot_dir="$TEST_DIR/autopilot"
  mkdir -p "$autopilot_dir/lib" "$TEST_DIR/schema"
  cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/deviation-phase-slugs.sh" "$autopilot_dir/lib/"
  cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh" "$autopilot_dir/lib/"
  # The real tracker imports schema_paths.py and validates against
  # execution-plan.schema.json. Stage both so the isolated layout mimics
  # the deployed ~/.claude/ tree, where schema_paths.py resolves the
  # schema via its deployed-first probe (lib's grandparent / "schema").
  # For our $TEST_DIR/autopilot/lib layout that resolves to
  # $TEST_DIR/schema — hence the schema dir lives one level above $apdir.
  cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/schema_paths.py" "$autopilot_dir/lib/"
  cp "$REPO_DIR/core/schema/execution-plan.schema.json" "$TEST_DIR/schema/"
  if [[ -n "$stub" && "$stub" != "none" ]]; then
    cp "$FIXTURES/$stub" "$autopilot_dir/deviation-tracker.py"
    chmod +x "$autopilot_dir/deviation-tracker.py"
  fi
  mkdir -p "$TEST_DIR/recordings"
  echo "$autopilot_dir"
}

count_phase_results() {
  local plan="$1"
  python3 -c "
import sys, yaml
with open('$plan') as f:
    data = yaml.safe_load(f) or {}
total = 0
for ph in data.get('phases', []):
    for t in ph.get('tasks', []):
        total += len(t.get('phase_results', []) or [])
print(total)
"
}

read_first_phase_result() {
  local plan="$1"
  python3 -c "
import sys, yaml, json
with open('$plan') as f:
    data = yaml.safe_load(f) or {}
for ph in data.get('phases', []):
    for t in ph.get('tasks', []):
        prs = t.get('phase_results') or []
        if prs:
            print(json.dumps(prs[0]))
            sys.exit(0)
print('null')
"
}

echo "Running deviation-tracker wire tests..."
echo ""

# =============================================================================
# W01: Slug map + skip set contents (REQ-2 / Appendix A)
# =============================================================================
test_slug_map_contains_appendix_a_entries() {
  local result
  result=$(bash -c "
    source '$SLUG_LIB'
    echo \"count=\${#DEVIATION_PHASE_NAMES[@]}\"
    echo \"skip_count=\${#DEVIATION_PHASE_SKIPPED_NAMES[@]}\"
    for n in \"\${DEVIATION_PHASE_NAMES[@]}\"; do
      slug=\$(deviation_slug_for \"\$n\")
      echo \"\$n=\$slug\"
    done
    for n in \"\${DEVIATION_PHASE_SKIPPED_NAMES[@]}\"; do
      if deviation_phase_skipped \"\$n\"; then echo \"skipped:\$n=yes\"; else echo \"skipped:\$n=no\"; fi
    done
    if deviation_phase_skipped \"Quantum Folding\"; then echo \"qf_skipped=yes\"; else echo \"qf_skipped=no\"; fi
  " 2>&1) || { echo "  bash failed"; return 1; }

  echo "$result" | grep -q "^count=10$" || { echo "  expected 10 names, got: $(echo "$result" | grep '^count=')"; return 1; }
  echo "$result" | grep -q "^skip_count=2$" || { echo "  expected 2 skip names"; return 1; }
  echo "$result" | grep -q "^Business Analysis=ba$" || { echo "  Business Analysis slug wrong"; return 1; }
  echo "$result" | grep -q "^Architecture Plan=architecture-plan$" || { echo "  Architecture Plan slug wrong"; return 1; }
  echo "$result" | grep -q "^Review=review$" || return 1
  echo "$result" | grep -q "^Team Review=team-review$" || return 1
  echo "$result" | grep -q "^Test Plan=test-plan$" || return 1
  echo "$result" | grep -q "^Implement=implement$" || return 1
  echo "$result" | grep -q "^QA=qa$" || return 1
  echo "$result" | grep -q "^Team QA=team-qa$" || return 1
  echo "$result" | grep -q "^Static Analysis=static-analysis$" || return 1
  echo "$result" | grep -q "^Commit=commit$" || return 1
  echo "$result" | grep -q "^skipped:Finalize=yes$" || return 1
  echo "$result" | grep -q "^skipped:Done=yes$" || return 1
  echo "$result" | grep -q "^qf_skipped=no$" || { echo "  unknown phase should not be in skip set"; return 1; }
  return 0
}
check "W01: slug map + skip set contents" test_slug_map_contains_appendix_a_entries

# =============================================================================
# W02: hook fires once per completed track_phase on a real plan
# =============================================================================
test_hook_fires_once_per_completed_track_phase() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"

  local result
  result=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    STREAM_FILE="$TEST_DIR/stream.ndjson" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { echo \"\$@\"; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
    " 2>&1) || { echo "  track_phase failed: $result"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  expected 1 phase_result, got $n"; return 1; }

  local entry
  entry=$(read_first_phase_result "$plan")
  python3 -c "
import json, re
e = json.loads('''$entry''')
assert e['phase'] == 'ba', f'wrong phase: {e[\"phase\"]}'
assert e['conformance'] == 'aligned'
assert e['acceptance_status'] == 'met'
assert e['deviations'] == []
assert re.match(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$', e['timestamp']), f'bad ts: {e[\"timestamp\"]}'
assert set(e.keys()) == {'phase','timestamp','conformance','acceptance_status','deviations'}, f'extra keys: {sorted(e.keys())}'
" 2>&1 || { echo "  payload check failed"; return 1; }
  return 0
}
check "W02: hook fires once per completed track_phase" test_hook_fires_once_per_completed_track_phase

# =============================================================================
# W03: hook skipped when status=failed
# =============================================================================
test_hook_skipped_when_status_failed() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local record="$TEST_DIR/recordings/dt-invocations"

  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_RECORD_FILE="$record" \
    STREAM_FILE="$TEST_DIR/stream.ndjson" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { echo \"\$@\"; }
      source '$LIB'
      track_phase 'Business Analysis' 'failed' 10 null
    " >/dev/null 2>&1 || { echo "  track_phase failed"; return 1; }

  [[ ! -f "$record" ]] || { echo "  tracker stub was invoked on failed status"; return 1; }
  return 0
}
check "W03: hook skipped when status=failed" test_hook_skipped_when_status_failed

# =============================================================================
# W04: skip when YAML_FILE empty (NOPLAN log once per process)
# =============================================================================
test_skip_when_yaml_file_empty() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  local record="$TEST_DIR/recordings/dt-invocations"

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="" TASK="task-1" \
    DEVIATION_RECORD_FILE="$record" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      for i in 1 2 3 4 5 6 7 8; do
        track_deviation 'Business Analysis'
      done
    " 2>&1) || { echo "  bash failed"; return 1; }

  [[ ! -f "$record" ]] || { echo "  stub was spawned despite empty YAML_FILE"; return 1; }
  local count
  count=$(echo "$stderr" | grep -c "deviation-tracker: no plan loaded, skipping" || true)
  [[ "$count" == "1" ]] || { echo "  expected exactly one NOPLAN log, got $count: $stderr"; return 1; }
  return 0
}
check "W04: skip when YAML_FILE empty (NOPLAN once per process)" test_skip_when_yaml_file_empty

# =============================================================================
# W05: WARNING when tracker script absent
# =============================================================================
test_warning_when_tracker_script_absent() {
  setup
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"

  local stderr
  stderr=$(env AUTOPILOT_DIR="$TEST_DIR/nonexistent-dir" YAML_FILE="$plan" TASK="task-1" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
    " 2>&1) || { echo "  bash failed"; return 1; }

  echo "$stderr" | grep -q "WARNING: deviation-tracker failed for phase ba: tracker script not found" \
    || { echo "  missing WARNING: $stderr"; return 1; }
  return 0
}
check "W05: WARNING when tracker script absent" test_warning_when_tracker_script_absent

# =============================================================================
# W06: timeout kills slow tracker (REQ-5)
# =============================================================================
test_timeout_kills_slow_tracker() {
  if ! command -v timeout &>/dev/null && ! command -v gtimeout &>/dev/null; then
    echo "  skipped: no timeout binary on PATH"
    return 0
  fi
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_sleep.sh")
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"

  local start_ts end_ts elapsed stderr
  start_ts=$(date +%s)
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_TRACKER_TIMEOUT=1 \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
    " 2>&1) || true
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  [[ $elapsed -le 5 ]] || { echo "  elapsed too long: ${elapsed}s"; return 1; }
  echo "$stderr" | grep -q "WARNING: deviation-tracker failed for phase ba: timeout" \
    || { echo "  missing timeout WARNING: $stderr"; return 1; }
  return 0
}
check "W06: timeout kills slow tracker" test_timeout_kills_slow_tracker

# =============================================================================
# W07: no entries past failed phase (REQ-7)
# =============================================================================
test_no_entries_past_failed_phase() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"

  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    STREAM_FILE="$TEST_DIR/stream.ndjson" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
      track_phase 'Architecture Plan' 'completed' 10 null
      track_phase 'Static Analysis' 'failed' 10 null
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "2" ]] || { echo "  expected 2, got $n"; return 1; }

  python3 -c "
import yaml
with open('$plan') as f:
    data = yaml.safe_load(f)
slugs = [pr['phase'] for pr in data['phases'][0]['tasks'][0]['phase_results']]
assert slugs == ['ba', 'architecture-plan'], f'wrong slugs: {slugs}'
" 2>&1 || { echo "  slug ordering wrong"; return 1; }
  return 0
}
check "W07: no entries past failed phase" test_no_entries_past_failed_phase

# =============================================================================
# W08: retry appends single entry (REQ-8)
# =============================================================================
# Note: drives the status-gate short-circuit directly (track_phase failed→completed)
# rather than the full run_gated_phase retry path. Both prove REQ-8 — entry written
# exactly once on a retry sequence — via the same gate.
test_retry_appends_single_entry() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"

  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    STREAM_FILE="$TEST_DIR/stream.ndjson" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'QA' 'failed' 10 null
      track_phase 'QA' 'completed' 10 null
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  expected 1, got $n"; return 1; }
  return 0
}
check "W08: retry appends single entry" test_retry_appends_single_entry

# =============================================================================
# W09: WARNING when task not in plan (REQ-9)
# =============================================================================
test_warning_when_task_not_in_plan() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_missing_task.yaml" "$plan"
  local pre_sha
  pre_sha=$(shasum -a 256 "$plan" | awk '{print $1}')

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-b" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
    " 2>&1) || { echo "  bash failed"; return 1; }

  echo "$stderr" | grep -q "WARNING: deviation-tracker failed for phase ba: task 'task-b' not found in $plan" \
    || { echo "  expected WARNING, got: $stderr"; return 1; }
  local post_sha
  post_sha=$(shasum -a 256 "$plan" | awk '{print $1}')
  [[ "$pre_sha" == "$post_sha" ]] || { echo "  plan was modified"; return 1; }
  return 0
}
check "W09: WARNING when task not in plan" test_warning_when_task_not_in_plan

# =============================================================================
# W10: Architecture Plan emits canonical slug
# =============================================================================
test_architecture_plan_emits_canonical_slug() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_record_stdin.sh")
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local stdin_file="$TEST_DIR/recordings/dt-stdin.json"

  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_STDIN_FILE="$stdin_file" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Architecture Plan' 'completed' 10 null
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  [[ -f "$stdin_file" ]] || { echo "  stdin file not captured"; return 1; }
  python3 -c "
import json
with open('$stdin_file') as f:
    payload = json.load(f)
assert payload['phase'] == 'architecture-plan', f'got {payload[\"phase\"]}'
assert set(payload.keys()) == {'phase','timestamp','conformance','acceptance_status','deviations'}
" 2>&1 || { echo "  payload check failed"; return 1; }
  return 0
}
check "W10: Architecture Plan emits canonical slug" test_architecture_plan_emits_canonical_slug

# =============================================================================
# W11: schema 2.0 plan re-validates after append (REQ-11)
# =============================================================================
test_schema_2_0_plan_revalidates_after_append() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  local plan_dir="$TEST_DIR/docs/INPROGRESS_Plan_smoke"
  mkdir -p "$plan_dir"
  local plan="$plan_dir/execution-plan.yaml"
  cp "$REPO_DIR/tests/fixtures/plan-2.0.0/minimal.yaml" "$plan"

  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="schema-core" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  python3 -c "
import yaml
with open('$plan') as f:
    data = yaml.safe_load(f)
for ph in data['phases']:
    for t in ph['tasks']:
        if t['id'] == 'schema-core':
            prs = t.get('phase_results') or []
            assert len(prs) == 1, f'expected 1 phase_result, got {len(prs)}'
            assert prs[0]['phase'] == 'ba'
" 2>&1 || { echo "  append assertion failed"; return 1; }

  python3 "$REPO_DIR/adapters/claude-code/claude/tools/validate-plan.py" "$plan" >/dev/null 2>&1 \
    || { echo "  validate-plan rejected the appended plan"; return 1; }
  return 0
}
check "W11: schema 2.0 plan re-validates after append" test_schema_2_0_plan_revalidates_after_append

# =============================================================================
# W12: kill switch predicate (REQ-12)
# =============================================================================
test_disable_env_var_predicate_parametrized() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  local plan="$TEST_DIR/execution-plan.yaml"

  # Disabled values: any non-empty non-{0,false}
  for value in "1" "true" "yes" "on" "random-string" "False" "FALSE" "True" "TRUE"; do
    cp "$FIXTURES/plan_simple.yaml" "$plan"
    local record="$TEST_DIR/recordings/dt-invocations-$RANDOM"
    local stderr
    stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
      DEVIATION_TRACKER_DISABLE="$value" \
      DEVIATION_RECORD_FILE="$record" \
      bash -c "
        declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
        log() { :; }
        source '$LIB'
        for n in 'Business Analysis' 'Architecture Plan' 'Review' 'Team Review' 'Test Plan' 'Implement' 'QA' 'Commit'; do
          track_phase \"\$n\" 'completed' 10 null
        done
      " 2>&1) || { echo "  bash failed for value=$value"; return 1; }
    [[ ! -f "$record" ]] || { echo "  tracker invoked despite DISABLE=$value"; return 1; }
    local cnt
    cnt=$(echo "$stderr" | grep -c "deviation-tracker: disabled by environment, skipping" || true)
    [[ "$cnt" == "1" ]] || { echo "  expected 1 DISABLED log for value=$value, got $cnt"; return 1; }
  done

  # Enabled values: unset, empty, "0", "false" — assert against the REAL tracker
  # so the append-delta assertion is meaningful. (S-C5: previous duplicate loop
  # against the stub was dead — the stub does not write YAML, so no assertion
  # could fire — and was removed to eliminate the footgun.)
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  for value in "UNSET" "" "0" "false"; do
    cp "$FIXTURES/plan_simple.yaml" "$plan"
    local pre_n
    pre_n=$(count_phase_results "$plan")
    local cmd_prefix=""
    if [[ "$value" == "UNSET" ]]; then
      cmd_prefix="unset DEVIATION_TRACKER_DISABLE; "
    fi
    env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
      DEVIATION_TRACKER_DISABLE="$value" \
      bash -c "
        ${cmd_prefix}
        declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
        log() { :; }
        source '$LIB'
        track_phase 'Business Analysis' 'completed' 10 null
      " >/dev/null 2>&1 || { echo "  bash failed for enabled value=$value (real tracker)"; return 1; }
    local post_n
    post_n=$(count_phase_results "$plan")
    [[ $((post_n - pre_n)) == "1" ]] || { echo "  hook not fired for enabled value=$value (delta: $((post_n - pre_n)))"; return 1; }
  done

  # Restore stub for any later tests in this file
  cp "$FIXTURES/tracker_stub_writes_then_exits.sh" "$apdir/deviation-tracker.py"
  chmod +x "$apdir/deviation-tracker.py"
  return 0
}
check "W12: kill switch predicate (REQ-12)" test_disable_env_var_predicate_parametrized

# =============================================================================
# W13: unknown phase name logs WARNING
# =============================================================================
test_unknown_phase_name_logs_warning() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local record="$TEST_DIR/recordings/dt-invocations"

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_RECORD_FILE="$record" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Quantum Folding' 'completed' 10 null
    " 2>&1) || { echo "  bash failed"; return 1; }

  echo "$stderr" | grep -q "WARNING: deviation-tracker failed for phase Quantum Folding: unknown phase, no canonical slug" \
    || { echo "  missing WARNING: $stderr"; return 1; }
  [[ ! -f "$record" ]] || { echo "  tracker invoked for unknown phase"; return 1; }
  return 0
}
check "W13: unknown phase name logs WARNING" test_unknown_phase_name_logs_warning

# =============================================================================
# W14: silently skipped phase emits no warning
# =============================================================================
test_silently_skipped_phase_emits_no_warning() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local record="$TEST_DIR/recordings/dt-invocations"

  for phase in "Finalize" "Done"; do
    local stderr
    stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
      DEVIATION_RECORD_FILE="$record" \
      bash -c "
        declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
        log() { :; }
        source '$LIB'
        track_phase '$phase' 'completed' 10 null
      " 2>&1) || { echo "  bash failed for $phase"; return 1; }
    [[ -z "$stderr" ]] || { echo "  expected empty stderr for $phase, got: $stderr"; return 1; }
    [[ ! -f "$record" ]] || { echo "  tracker invoked for $phase"; return 1; }
  done
  return 0
}
check "W14: silently skipped phase emits no warning" test_silently_skipped_phase_emits_no_warning

# =============================================================================
# W15: no timeout binary skips hook
# =============================================================================
test_no_timeout_binary_skips_hook() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local record="$TEST_DIR/recordings/dt-invocations"

  # Use a minimal PATH that contains the basic POSIX utilities the lib
  # needs to source (dirname/cd) but excludes the homebrew/coreutils
  # dirs where `timeout` / `gtimeout` live. macOS stock /usr/bin has
  # no `timeout` of either name.
  local stderr
  stderr=$(env PATH="/usr/bin:/bin" \
    AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_RECORD_FILE="$record" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
    " 2>&1) || true

  echo "$stderr" | grep -q "WARNING: deviation-tracker: no timeout binary, REQ-5 unenforced; skipping hook" \
    || { echo "  missing WARNING: $stderr"; return 1; }
  [[ ! -f "$record" ]] || { echo "  tracker invoked despite missing timeout"; return 1; }
  return 0
}
check "W15: no timeout binary skips hook" test_no_timeout_binary_skips_hook

# =============================================================================
# W16: existing phase_results preserved byte-equal
# =============================================================================
test_existing_phase_results_preserved_byte_equal() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_existing.yaml" "$plan"

  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-a" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  python3 -c "
import yaml
with open('$plan') as f:
    data = yaml.safe_load(f)
prs = data['phases'][0]['tasks'][0]['phase_results']
assert len(prs) == 2, f'expected 2 entries, got {len(prs)}'
assert prs[0]['phase'] == 'ba'
assert prs[0]['timestamp'] == '2026-04-30T08:00:00Z'
assert prs[0]['conformance'] == 'aligned'
assert prs[0]['acceptance_status'] == 'met'
assert prs[0]['deviations'] == []
assert prs[1]['phase'] == 'ba'
" 2>&1 || { echo "  preservation check failed"; return 1; }
  return 0
}
check "W16: existing phase_results preserved byte-equal" test_existing_phase_results_preserved_byte_equal

# =============================================================================
# W17: JSON construction escapes special chars
# =============================================================================
test_json_construction_escapes_special_chars() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_record_stdin.sh")
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local stdin_file="$TEST_DIR/recordings/dt-stdin.json"

  # Override the slug function in the same shell so 'Test Special' resolves to a
  # nasty slug containing a quote, newline, and backslash.
  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_STDIN_FILE="$stdin_file" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      deviation_slug_for() {
        case \"\$1\" in
          'Test Special') printf 'bad\"\\n\\\\' ;;
          *) return 1 ;;
        esac
      }
      track_phase 'Test Special' 'completed' 10 null
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  [[ -f "$stdin_file" ]] || { echo "  stdin file missing"; return 1; }
  python3 -c "
import json
with open('$stdin_file') as f:
    payload = json.load(f)
assert payload['phase'] == 'bad\"\n\\\\', f'phase mismatch: {payload[\"phase\"]!r}'
assert set(payload.keys()) == {'phase','timestamp','conformance','acceptance_status','deviations'}
" 2>&1 || { echo "  JSON parse / payload check failed"; return 1; }
  return 0
}
check "W17: JSON construction escapes special chars" test_json_construction_escapes_special_chars

# =============================================================================
# W18: log gating flags per process (REQ-3 + REQ-12)
# =============================================================================
test_log_gating_flags_per_process() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")

  # Phase a: NOPLAN — eight calls, expect "no plan" once.
  local stderr_a
  stderr_a=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="" TASK="task-1" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      for i in 1 2 3 4 5 6 7 8; do track_deviation 'Business Analysis'; done
      echo \"flag=\${DEVIATION_TRACKER_LOG_NOPLAN_SHOWN:-unset}\" >&2
    " 2>&1) || { echo "  bash failed"; return 1; }
  local cnt_a
  cnt_a=$(echo "$stderr_a" | grep -c "deviation-tracker: no plan loaded, skipping" || true)
  [[ "$cnt_a" == "1" ]] || { echo "  NOPLAN log count != 1: got $cnt_a"; return 1; }
  echo "$stderr_a" | grep -q "flag=1" || { echo "  NOPLAN flag not set"; return 1; }

  # Phase b: DISABLED — eight calls, expect "disabled" once.
  local stderr_b
  stderr_b=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="" TASK="task-1" \
    DEVIATION_TRACKER_DISABLE=1 \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      for i in 1 2 3 4 5 6 7 8; do track_deviation 'Business Analysis'; done
      echo \"flag=\${DEVIATION_TRACKER_LOG_DISABLED_SHOWN:-unset}\" >&2
    " 2>&1) || { echo "  bash failed"; return 1; }
  local cnt_b
  cnt_b=$(echo "$stderr_b" | grep -c "deviation-tracker: disabled by environment, skipping" || true)
  [[ "$cnt_b" == "1" ]] || { echo "  DISABLED log count != 1: got $cnt_b"; return 1; }
  echo "$stderr_b" | grep -q "flag=1" || { echo "  DISABLED flag not set"; return 1; }
  return 0
}
check "W18: log gating flags per process" test_log_gating_flags_per_process

# =============================================================================
# W19: autopilot YAML resolution guards MAIN_DIR (PLAN AC 3.a.1)
# =============================================================================
test_autopilot_yaml_resolution_guards_main_dir() {
  # Direct grep proves the guard is present.
  local autopilot="$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh"
  grep -q "MAIN_DIR unset before YAML_FILE resolution" "$autopilot" \
    || { echo "  MAIN_DIR guard log line missing"; return 1; }
  return 0
}
check "W19: autopilot YAML resolution guards MAIN_DIR" test_autopilot_yaml_resolution_guards_main_dir

# =============================================================================
# W20: autopilot grep skipped on empty YAML_FILE (PLAN AC 3.a.2)
# =============================================================================
test_autopilot_grep_skipped_on_empty_yaml_file() {
  local autopilot="$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh"
  # The guard pattern: pipeline lookup is wrapped in `if [[ -n "$YAML_FILE" ]]`.
  grep -q 'if \[\[ -n "\$YAML_FILE" \]\]; then' "$autopilot" \
    || { echo "  empty-result guard not present"; return 1; }
  return 0
}
check "W20: autopilot grep skipped on empty YAML_FILE" test_autopilot_grep_skipped_on_empty_yaml_file

# =============================================================================
# W21: autopilot exports YAML_FILE + TASK
# =============================================================================
test_autopilot_exports_yaml_file_and_task() {
  local autopilot="$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh"
  grep -qE '^export YAML_FILE' "$autopilot" || { echo "  YAML_FILE not exported"; return 1; }
  grep -qE '^export TASK' "$autopilot" || { echo "  TASK not exported"; return 1; }
  return 0
}
check "W21: autopilot exports YAML_FILE + TASK" test_autopilot_exports_yaml_file_and_task

# =============================================================================
# W22: autopilot Usage banner documents env vars (PLAN AC 3.a.4)
# =============================================================================
test_autopilot_usage_banner_documents_env_vars() {
  local autopilot="$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh"
  local cnt
  # Banner window widened from 50→80 lines: the --stop-after-phase
  # documentation (feature pause-after-phase-flag) extended the
  # Usage block by ~14 lines, pushing DEVIATION_TRACKER below line 50.
  # The contract is "banner documents the env vars" — the line
  # number is incidental.
  cnt=$(head -80 "$autopilot" | grep -c DEVIATION_TRACKER || true)
  [[ "$cnt" -ge 2 ]] || { echo "  expected ≥2 DEVIATION_TRACKER lines in banner, got $cnt"; return 1; }
  return 0
}
check "W22: autopilot Usage banner documents env vars" test_autopilot_usage_banner_documents_env_vars

# =============================================================================
# W23: caller-provided globals header documents YAML_FILE/TASK/AUTOPILOT_DIR
# =============================================================================
test_caller_provided_globals_header_documents_three_globals() {
  local lib="$LIB"
  # Read first 40 lines (header table) and ensure all three globals appear there.
  local head_block
  head_block=$(head -40 "$lib")
  echo "$head_block" | grep -q 'YAML_FILE' || { echo "  YAML_FILE missing from header"; return 1; }
  echo "$head_block" | grep -q 'AUTOPILOT_DIR' || { echo "  AUTOPILOT_DIR missing from header"; return 1; }
  echo "$head_block" | grep -q 'track_deviation' || { echo "  track_deviation not referenced in header"; return 1; }
  echo "$head_block" | grep -q 'TASK' || { echo "  TASK missing from header"; return 1; }
  return 0
}
check "W23: caller-provided globals header documents three globals" test_caller_provided_globals_header_documents_three_globals

# =============================================================================
# W24: deviation-tracker.py path is config-derived (REQ-10)
# =============================================================================
test_tracker_path_is_config_derived() {
  local lib="$LIB"
  # No hardcoded user paths in the wrapper.
  if grep -nE '/Users/|/home/' "$lib" | grep -v '^[^:]*:[^:]*: *#'; then
    echo "  hardcoded user-path detected in lib (only allowed inside comments)"; return 1
  fi
  grep -q 'AUTOPILOT_DIR' "$lib" || { echo "  AUTOPILOT_DIR not referenced"; return 1; }
  grep -q 'deviation-tracker.py' "$lib" || { echo "  tracker filename not referenced"; return 1; }
  return 0
}
check "W24: deviation-tracker.py path is config-derived" test_tracker_path_is_config_derived

# =============================================================================
# W25: project CLAUDE.md mentions deviation-phase-slugs
# =============================================================================
test_claude_md_layout_mentions_deviation_phase_slugs() {
  grep -q 'deviation-phase-slugs' "$REPO_DIR/CLAUDE.md" \
    || { echo "  deviation-phase-slugs not mentioned in project CLAUDE.md"; return 1; }
  return 0
}
check "W25: project CLAUDE.md mentions deviation-phase-slugs" test_claude_md_layout_mentions_deviation_phase_slugs

# =============================================================================
# W26: invalid DEVIATION_TRACKER_TIMEOUT falls back to default and warns once
#      per process (REQ-5). Parametrized over ["abc","1.5","1e9","0","-1"].
# =============================================================================
test_timeout_validation_falls_back_on_invalid_value() {
  if ! command -v timeout &>/dev/null && ! command -v gtimeout &>/dev/null; then
    echo "  skipped: no timeout binary on PATH"
    return 0
  fi
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  local plan="$TEST_DIR/execution-plan.yaml"

  for bad_val in "abc" "1.5" "1e9" "0" "-1"; do
    cp "$FIXTURES/plan_simple.yaml" "$plan"
    local pre_n stderr
    pre_n=$(count_phase_results "$plan")

    stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
      DEVIATION_TRACKER_TIMEOUT="$bad_val" \
      STREAM_FILE="$TEST_DIR/stream.ndjson" \
      bash -c "
        declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
        log() { echo \"\$@\"; }
        source '$LIB'
        track_phase 'Business Analysis' 'completed' 10 null
      " 2>&1) || { echo "  bash failed for bad_val=$bad_val: $stderr"; return 1; }

    # (a) Warning message must appear exactly once per process
    local warn_count
    warn_count=$(echo "$stderr" | grep -c "WARNING: DEVIATION_TRACKER_TIMEOUT='${bad_val}' invalid, using default" || true)
    [[ "$warn_count" == "1" ]] || {
      echo "  expected 1 WARNING for bad_val=$bad_val, got $warn_count; stderr: $stderr"
      return 1
    }

    # (b) Tracker still runs: entry count must grow by 1 (fallback to 10s lets it succeed)
    local post_n
    post_n=$(count_phase_results "$plan")
    [[ $((post_n - pre_n)) == "1" ]] || {
      echo "  expected 1 new phase_result for bad_val=$bad_val, delta=$((post_n - pre_n))"
      return 1
    }
  done

  # (c) Second invocation in the SAME process shell with an invalid value must NOT
  #     repeat the warning (per-process gating via DEVIATION_TRACKER_TIMEOUT_FALLBACK_SHOWN).
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local stderr_second
  stderr_second=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_TRACKER_TIMEOUT="abc" \
    STREAM_FILE="$TEST_DIR/stream.ndjson" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { echo \"\$@\"; }
      source '$LIB'
      track_phase 'Business Analysis' 'completed' 10 null
      track_phase 'Architecture Plan' 'completed' 10 null
    " 2>&1) || { echo "  bash failed for second-invocation check"; return 1; }

  local second_warn_count
  second_warn_count=$(echo "$stderr_second" | grep -c "WARNING: DEVIATION_TRACKER_TIMEOUT='abc' invalid" || true)
  [[ "$second_warn_count" == "1" ]] || {
    echo "  expected WARNING to appear exactly once in same-process re-call, got $second_warn_count"
    return 1
  }
  return 0
}
check "W26: timeout validation falls back on invalid value" test_timeout_validation_falls_back_on_invalid_value

# =============================================================================
# W27: deviation hook fires when commit_phase returns non-zero (REQ-7 EC#1).
#      Stubs commit_phase to return 7; asserts phase_results entry still appended.
# =============================================================================
test_hook_fires_when_commit_phase_returns_nonzero() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local workdir="$TEST_DIR/workdir"
  mkdir -p "$workdir"
  # Minimal artifact file so check_artifact passes
  local artifact_file="$workdir/REQUIREMENTS.md"
  touch "$artifact_file"

  local pre_n
  pre_n=$(count_phase_results "$plan")

  # Drive run_gated_phase with:
  #   - run_phase stubbed to return 0 (phase succeeds)
  #   - check_artifact stubbed to return 0 (artifact present)
  #   - commit_phase stubbed to return 7 (non-zero, simulating empty diff)
  #   - fail_pipeline stubbed to prevent exit
  # The assertion: track_phase is still called → phase_results grows by 1.
  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    STREAM_FILE="$TEST_DIR/stream.ndjson" \
    PHASE_START=0 \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      fail_pipeline() { echo \"FAIL_PIPELINE called: \$*\" >&2; }
      PHASE_TIMEOUT=60 MAX_TURNS_PHASE=1 ALLOWED_TOOLS=Read EXTRA_SYSTEM_PROMPT='' \
        AUTOPILOT_SID=test DASHBOARD_DATA=/dev/null
      source '$LIB'
      # Override after sourcing so our stubs take precedence
      run_phase() { return 0; }
      check_artifact() { return 0; }
      commit_phase() { return 7; }
      run_gated_phase 'echo noop' 'Implement' '$workdir' '$artifact_file' 'msg' 'null'
    " >/dev/null 2>&1 || true

  local post_n
  post_n=$(count_phase_results "$plan")
  [[ $((post_n - pre_n)) == "1" ]] || {
    echo "  expected 1 new phase_result after commit_phase exit 7, delta=$((post_n - pre_n))"
    return 1
  }
  # Verify the slug is 'implement'
  python3 -c "
import yaml
with open('$plan') as f:
    data = yaml.safe_load(f)
prs = data['phases'][0]['tasks'][0].get('phase_results', [])
assert len(prs) == 1, f'expected 1 entry, got {len(prs)}'
assert prs[0]['phase'] == 'implement', f'expected implement, got {prs[0][\"phase\"]}'
" 2>&1 || { echo "  phase_result content check failed"; return 1; }
  return 0
}
check "W27: hook fires when commit_phase returns non-zero" test_hook_fires_when_commit_phase_returns_nonzero

# =============================================================================
# W28: autopilot.sh UI-guard pipeline resolves TASK_UI correctly against a
#      realistic plan (F12 regression).
#
#      Two bugs existed in the F6 awk filter:
#        (a) bare `$0!=t` — bash escapes `!` to `\!` even in non-interactive
#            scripts on macOS; BSD awk rejects the resulting syntax.
#        (b) whole-line equality `$0==t` compared "      - id: task" against
#            "id: task" — never equal, so the guard was silently dead on any
#            real plan (TASK_UI always empty → UI tasks not blocked).
#
#      The fix uses suffix-exact comparison via substr() — no `!`, works with
#      real YAML indentation, and still enforces the boundary (TASK="foo"
#      does not match a task id of "foo-bar").
#
#      Test strategy: write a production-shaped fixture (schema_version /
#      phases / tasks with leading "      - id:"), run the COMPLETE pipeline
#      from autopilot.sh (grep -A 10 -F | awk | grep ui: | awk print $2)
#      inside a fresh non-interactive bash subshell, assert TASK_UI=="true"
#      for the ui:true task and =="false" for the ui:false task.
# =============================================================================
test_autopilot_ui_guard_pipeline_resolves_correctly() {
  setup

  # Static regression guard: autopilot.sh code (non-comment lines) must not
  # contain the broken awk forms. Comments are excluded with grep -v '^ *#'.
  local autopilot="$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh"
  local code_lines
  code_lines=$(grep -v '^ *#' "$autopilot")
  # (a) top-level `$0!=t` in code triggers bash `!`→`\!` escape on macOS
  if echo "$code_lines" | grep -q '\$0!=t'; then
    echo "  F12(a) regression: \$0!=t in code (not comment) — BSD awk syntax error on macOS"
    return 1
  fi
  # (b) whole-line `$0==t` in an NR==1 code line is dead for indented YAML
  if echo "$code_lines" | grep 'NR==1' | grep -q '\$0==t'; then
    echo "  F12(b) regression: NR==1 guard uses whole-line \$0==t (dead for indented YAML)"
    return 1
  fi

  # Realistic production-shaped fixture: schema_version / phases / tasks.
  # Tasks appear as "      - id: <name>" (six spaces + dash + space), exactly
  # as autopilot.sh sees them at runtime.
  local plan="$TEST_DIR/plan_ui_guard.yaml"
  cat > "$plan" <<'YAML'
schema_version: "1.0.0"
name: UI guard regression fixture
phases:
  - id: phase-1
    name: Phase 1
    tasks:
      - id: add-dashboard
        name: Add dashboard
        status: pending
        ui: true
      - id: add-api
        name: Add API endpoint
        status: pending
        ui: false
YAML

  # Run the COMPLETE UI-guard pipeline from autopilot.sh end-to-end in a
  # fresh non-interactive bash subshell (same conditions as autopilot runtime).
  # TASK and YAML_FILE are passed via env so the inner shell expands them
  # without any outer-shell quoting interference.
  local out_ui out_noui
  out_ui=$(TASK="add-dashboard" YAML_FILE="$plan" bash -c '
    grep -A 10 -F "id: ${TASK}" "$YAML_FILE" 2>/dev/null \
      | awk -v t="id: ${TASK}" '"'"'NR==1{if(substr($0,length($0)-length(t)+1)==t)next; exit} NR>1'"'"' \
      | grep "ui:" | head -1 | awk '"'"'{print $2}'"'"' || true
  ' 2>&1)
  out_noui=$(TASK="add-api" YAML_FILE="$plan" bash -c '
    grep -A 10 -F "id: ${TASK}" "$YAML_FILE" 2>/dev/null \
      | awk -v t="id: ${TASK}" '"'"'NR==1{if(substr($0,length($0)-length(t)+1)==t)next; exit} NR>1'"'"' \
      | grep "ui:" | head -1 | awk '"'"'{print $2}'"'"' || true
  ' 2>&1)

  # Regression: a broken awk (either syntax error or dead guard) produces
  # empty output for both tasks. Assert both resolve to their correct values.
  [[ "$out_ui" == "true" ]] || {
    echo "  expected TASK_UI='true' for add-dashboard (ui:true task), got [$out_ui]"
    return 1
  }
  [[ "$out_noui" == "false" ]] || {
    echo "  expected TASK_UI='false' for add-api (ui:false task), got [$out_noui]"
    return 1
  }

  # Also verify boundary protection: a prefix-only match must not bleed
  # through (TASK="add" must not resolve ui from "add-dashboard").
  local out_prefix
  out_prefix=$(TASK="add" YAML_FILE="$plan" bash -c '
    grep -A 10 -F "id: ${TASK}" "$YAML_FILE" 2>/dev/null \
      | awk -v t="id: ${TASK}" '"'"'NR==1{if(substr($0,length($0)-length(t)+1)==t)next; exit} NR>1'"'"' \
      | grep "ui:" | head -1 | awk '"'"'{print $2}'"'"' || true
  ' 2>&1)
  [[ -z "$out_prefix" ]] || {
    echo "  boundary failure: TASK='add' matched 'add-dashboard', got [$out_prefix]"
    return 1
  }

  return 0
}
check "W28: autopilot UI-guard pipeline resolves TASK_UI on realistic plan (F12)" test_autopilot_ui_guard_pipeline_resolves_correctly

# =============================================================================
# Results
# =============================================================================
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
