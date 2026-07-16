#!/usr/bin/env bash
# test_deviation_producer.sh — bash integration tests for the
# assess_phase_deviation producer wire (T1..T9). Mirrors the structure
# of test_deviation_wire.sh and binds REQ-1..REQ-13 + EVAL-1..EVAL-11.
#
# Usage:
#   bash tests/test_deviation_producer.sh                     # full matrix
#   bash tests/test_deviation_producer.sh race_two_autopilots # single test
#
# Exits 0 on all pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"
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

TEST_DIR="${TMPDIR:-/tmp}/test-deviation-producer-$$"
ORIG_PATH="$PATH"

setup() {
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/recordings"
  PATH="$TEST_DIR/bin:$ORIG_PATH"
  export PATH
  unset DEVIATION_TRACKER_DISABLE
  unset DEVIATION_ASSESS_SOURCE_FAIL_SHOWN
  unset DEVIATION_ASSESSOR_TIMEOUT_FALLBACK_SHOWN
  unset DEVIATION_TRACKER_LOG_NOPLAN_SHOWN
  unset DEVIATION_TRACKER_LOG_DISABLED_SHOWN
  unset DEVIATION_TRACKER_TIMEOUT_FALLBACK_SHOWN
}

teardown() {
  rm -rf "$TEST_DIR"
  PATH="$ORIG_PATH"
}
trap teardown EXIT

# Build a per-test isolated AUTOPILOT_DIR/dir layout that mimics the real
# autopilot.sh tree but with stub trackers. Mirrors the wire test's
# prepare_isolated_autopilot helper plus stages a stub `claude` on PATH.
prepare_isolated_autopilot() {
  local stub="${1:-}"
  local autopilot_dir="$TEST_DIR/autopilot"
  mkdir -p "$autopilot_dir/lib" "$TEST_DIR/schema"
  cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/deviation-phase-slugs.sh" "$autopilot_dir/lib/"
  cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/claude-session-lib.sh" "$autopilot_dir/lib/"
  cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/deviation-assess.sh" "$autopilot_dir/lib/"
  cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/schema_paths.py" "$autopilot_dir/lib/"
  cp "$REPO_DIR/core/schema/execution-plan.schema.json" "$TEST_DIR/schema/"
  if [[ -n "$stub" && "$stub" != "none" ]]; then
    cp "$FIXTURES/$stub" "$autopilot_dir/deviation-tracker.py"
    chmod +x "$autopilot_dir/deviation-tracker.py"
  fi
  echo "$autopilot_dir"
}

# Stage a parameterised `claude` stub binary at $TEST_DIR/bin/claude. The
# fixture-id selects behaviour: see TESTPLAN.md § stage_claude_stub.
# Every invocation appends one line to $TEST_DIR/recordings/claude-invocations
# so tests can assert invocation counts regardless of fixture.
stage_claude_stub() {
  local fixture="$1"
  local recording_file="$TEST_DIR/recordings/claude-invocations"
  local stub="$TEST_DIR/bin/claude"
  cat >"$stub" <<STUB
#!/usr/bin/env bash
# Generated claude stub — fixture: $fixture
# Record one line per invocation. Strip newlines from \$* so the recording
# stays one-line-per-call regardless of multi-line prompt arguments.
flat=\$(printf '%s ' "\$@" | tr '\n' ' ')
echo "PWD=\$PWD ARGS=\$flat" >>"$recording_file"
case "$fixture" in
  aligned-passthrough|gate-logic-drift|recording)
    # W1: record any proxy env vars visible to this stub invocation so
    # T2 can assert the proxy-strip env -u ... was applied before calling us.
    env | grep -iE '^(ALL_|HTTPS?_|NO_)?proxy=' >>"$recording_file" || true
    # W2: record the prompt argument (\$2 when called as: claude -p "<prompt>")
    # so T2 can assert "heuristic_flags" and ratio names reach the assessor.
    echo "PROMPT_ARG=\$2" >>"$recording_file"
    ;;
esac
case "$fixture" in
  aligned-passthrough)
    cat <<'JSON'
{"phase":"implement","timestamp":"2026-05-03T12:00:00Z","conformance":"aligned","acceptance_status":"met","deviations":[]}
JSON
    exit 0
    ;;
  gate-logic-drift)
    cat <<'JSON'
{"phase":"implement","timestamp":"2026-05-03T12:00:00Z","conformance":"deviated","acceptance_status":"partial","deviations":[{"type":"gate_logic_drift","description":"Gate predicate inverted","reason":"The flagged phase commits a gate condition that returns the opposite verdict from what the spec requires.","impact":"modified","criteria_affected":["AC-1"],"confidence":0.85,"evidence":"adapters/claude-code/claude/tools/lib/deviation-assess.sh:42 inverts the comparison operator versus the spec quoted at line 88 of REQUIREMENTS.md"}]}
JSON
    exit 0
    ;;
  timeout)
    sleep 5
    exit 0
    ;;
  nonzero-exit)
    exit 1
    ;;
  nonzero-exit-with-stderr)
    echo "Error: --allowedTools value rejected (FAKEFLAG_FOR_TEST)" >&2
    echo "partial json fragment {" >&1
    exit 1
    ;;
  malformed-json)
    cat <<'JSON'
{"conformance":"invalid"}
JSON
    exit 0
    ;;
  recording)
    cat >/dev/null
    exit 0
    ;;
  *)
    echo "unknown fixture: $fixture" >&2
    exit 99
    ;;
esac
STUB
  chmod +x "$stub"
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

# Stage a fake git repo under $1 with one initial commit and a follow-up
# commit that adds five large files so the heuristic flags. Emits the
# initial commit SHA on stdout for use as PHASE_BASE_REF.
git_repo_at() {
  local repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email test@test
    git config user.name test
    echo "initial" > seed.txt
    git add seed.txt
    git commit -q -m "initial commit"
    local base
    base=$(git rev-parse HEAD)
    local i
    for i in 1 2 3 4 5; do
      python3 -c "print('\n'.join('line ' + str(n) for n in range(40)))" > "file_${i}.txt"
    done
    git add file_*.txt
    git commit -q -m "expand the codebase"
    echo "$base"
  )
}

# Write a minimal plan fixture with rigged where.modify and lines_estimate
# such that the heuristic flags loc and files when paired with git_repo_at.
write_flagged_plan() {
  local plan="$1"
  cat >"$plan" <<'YAML'
schema_version: "1.0.0"
name: Flagged-path test plan
phases:
  - id: phase-1
    name: Phase 1
    tasks:
      - id: task-1
        name: Task 1
        status: wip
        prompt: /start task-1
        acceptance:
          - "AC-1: thing"
          - "AC-2: thing"
          - "AC-3: thing"
        where:
          modify:
            - file_1.txt
        estimate:
          lines_estimate: 10
YAML
}

# =============================================================================
# T1: Aligned path emits minimal 5-key payload, no claude spawn (REQ-1, REQ-3,
#     REQ-4, REQ-5, REQ-8, REQ-9, REQ-11, AS-2, AC-2, EVAL-1).
# =============================================================================
test_aligned_path_emits_minimal_payload() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub recording
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      assess_phase_deviation ba
    " 2>&1) || { echo "  bash failed: $stderr"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  expected 1 phase_result, got $n"; return 1; }

  local entry
  entry=$(read_first_phase_result "$plan")
  python3 -c "
import json, re
e = json.loads(r'''$entry''')
assert e['phase'] == 'ba', f'wrong phase: {e[\"phase\"]}'
assert e['conformance'] == 'aligned', f'wrong conformance: {e[\"conformance\"]}'
assert e['acceptance_status'] == 'met', f'wrong status: {e[\"acceptance_status\"]}'
assert e['deviations'] == []
assert re.match(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$', e['timestamp']), f'bad ts: {e[\"timestamp\"]}'
assert set(e.keys()) == {'phase','timestamp','conformance','acceptance_status','deviations'}, f'extra keys: {sorted(e.keys())}'
" 2>&1 || { echo "  payload check failed"; return 1; }

  if [[ -f "$TEST_DIR/recordings/claude-invocations" ]]; then
    echo "  claude stub invoked on aligned path"
    return 1
  fi
  return 0
}

# =============================================================================
# T2: Flagged path spawns assessor, validates, pipes output verbatim
#     (REQ-1, REQ-4, REQ-6, REQ-9, AS-3, AC-3, EVAL-2 + EVAL-3).
# =============================================================================
_t2_run_one() {
  local fixture="$1"
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub "$fixture"
  local plan="$TEST_DIR/execution-plan.yaml"
  write_flagged_plan "$plan"
  local repo="$TEST_DIR/repo"
  local baseref
  baseref=$(git_repo_at "$repo")

  # W1: export the full 8-variable proxy family BEFORE assess_phase_deviation so
  # the stub can confirm they were stripped from the assessor's env.
  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" \
    HTTP_PROXY="http://test:1" HTTPS_PROXY="http://test:1" ALL_PROXY="http://test:1" \
    NO_PROXY="test" http_proxy="http://test:1" https_proxy="http://test:1" \
    all_proxy="http://test:1" no_proxy="test" \
    bash -c "
      export HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      workdir='$repo'
      PHASE_BASE_REF='$baseref'
      assess_phase_deviation implement
    " 2>&1) || { echo "  bash failed for $fixture: $stderr"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  [$fixture] expected 1 phase_result, got $n; stderr=$stderr"; return 1; }

  local entry
  entry=$(read_first_phase_result "$plan")
  case "$fixture" in
    aligned-passthrough)
      python3 -c "
import json
e = json.loads(r'''$entry''')
assert e['conformance'] == 'aligned', f'wrong conformance: {e[\"conformance\"]}'
assert e['deviations'] == [], f'expected empty deviations, got {e[\"deviations\"]}'
" 2>&1 || { echo "  [$fixture] payload check failed"; return 1; }
      ;;
    gate-logic-drift)
      python3 -c "
import json
e = json.loads(r'''$entry''')
assert e['conformance'] == 'deviated', f'wrong conformance: {e[\"conformance\"]}'
assert len(e['deviations']) == 1, f'expected 1 deviation'
d = e['deviations'][0]
assert d['type'] == 'gate_logic_drift', f'wrong type: {d[\"type\"]}'
assert d['confidence'] == 0.85, f'wrong confidence: {d.get(\"confidence\")}'
assert len(d['evidence']) >= 80
" 2>&1 || { echo "  [$fixture] payload check failed"; return 1; }
      ;;
  esac

  if [[ ! -f "$TEST_DIR/recordings/claude-invocations" ]]; then
    echo "  [$fixture] claude stub was NOT invoked on flagged path"
    return 1
  fi
  # Count invocations via PWD= lines (one per call); extra lines are W1/W2
  # proxy-env and prompt-content recordings appended by the stub.
  local inv_lines
  inv_lines=$(grep -c '^PWD=' "$TEST_DIR/recordings/claude-invocations" || true)
  [[ "$inv_lines" == "1" ]] || { echo "  [$fixture] expected 1 claude invocation, got $inv_lines"; return 1; }

  # W1: assert NO proxy vars leaked into the stub's environment. The stub
  # writes matching lines to the recording; a clean env produces zero matches.
  if grep -qiE '^(ALL_|HTTPS?_|NO_)?proxy=' "$TEST_DIR/recordings/claude-invocations" 2>/dev/null; then
    echo "  [$fixture] proxy var(s) leaked into assessor env"
    return 1
  fi

  # W2: assert the prompt argument captured by the stub contains
  # "heuristic_flags" and at least one ratio name. Both parameterisations
  # send a flagged verdict so heuristic_flags must be present.
  local rec_content
  rec_content=$(cat "$TEST_DIR/recordings/claude-invocations")
  echo "$rec_content" | grep -q '"heuristic_flags"' \
    || { echo "  [$fixture] heuristic_flags not found in recorded prompt"; return 1; }
  echo "$rec_content" | grep -qE '"(files|loc|ac_coverage)"' \
    || { echo "  [$fixture] no ratio name found in recorded prompt"; return 1; }

  return 0
}

test_flagged_path_aligned_passthrough() {
  _t2_run_one aligned-passthrough
}

test_flagged_path_gate_logic_drift() {
  _t2_run_one gate-logic-drift
}

# =============================================================================
# T3: Flagged path validates assessor output; malformed JSON → fallback
#     (REQ-6 step 4, REQ-7, AS-4 validation branch, AC-4, EVAL-6).
# =============================================================================
test_flagged_path_validates_assessor_output() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub malformed-json
  local plan="$TEST_DIR/execution-plan.yaml"
  write_flagged_plan "$plan"
  local repo="$TEST_DIR/repo"
  local baseref
  baseref=$(git_repo_at "$repo")

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      workdir='$repo'
      PHASE_BASE_REF='$baseref'
      assess_phase_deviation implement
    " 2>&1) || { echo "  bash failed: $stderr"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  expected 1 phase_result, got $n; stderr=$stderr"; return 1; }

  local entry
  entry=$(read_first_phase_result "$plan")
  python3 -c "
import json
e = json.loads(r'''$entry''')
assert e['conformance'] == 'deviated', f'wrong conformance: {e[\"conformance\"]}'
assert e['acceptance_status'] == 'partial'
assert len(e['deviations']) == 1
d = e['deviations'][0]
assert d['type'] == 'integration_gap'
assert d['confidence'] == 0.0
assert d['evidence'].startswith('assessor unavailable: '), f'evidence={d[\"evidence\"]!r}'
assert 'assessor stdout invalid' in d['evidence']
assert len(d['evidence']) >= 80
" 2>&1 || { echo "  payload check failed; entry=$entry"; return 1; }

  echo "$stderr" | grep -qE "WARNING: deviation-assessor failed for phase implement: assessor stdout invalid" \
    || { echo "  missing WARNING; stderr=$stderr"; return 1; }
  return 0
}

# =============================================================================
# T4: Assessor timeout engages fallback (REQ-6 step 2, REQ-7, AS-4 timeout
#     branch, AC-4, EVAL-4).
# =============================================================================
test_assessor_timeout_engages_fallback() {
  if ! command -v timeout &>/dev/null && ! command -v gtimeout &>/dev/null; then
    echo "  skipped: no timeout binary on PATH"
    return 0
  fi
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub timeout
  local plan="$TEST_DIR/execution-plan.yaml"
  write_flagged_plan "$plan"
  local repo="$TEST_DIR/repo"
  local baseref
  baseref=$(git_repo_at "$repo")

  local start_ts end_ts elapsed stderr
  start_ts=$(date +%s)
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_ASSESSOR_TIMEOUT_S=1 PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      workdir='$repo'
      PHASE_BASE_REF='$baseref'
      assess_phase_deviation implement
    " 2>&1) || { echo "  bash failed: $stderr"; return 1; }
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  [[ $elapsed -le 10 ]] || { echo "  too slow: ${elapsed}s"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  expected 1 phase_result, got $n"; return 1; }

  local entry
  entry=$(read_first_phase_result "$plan")
  python3 -c "
import json
e = json.loads(r'''$entry''')
assert e['conformance'] == 'deviated'
assert len(e['deviations']) == 1
d = e['deviations'][0]
assert d['type'] == 'integration_gap'
assert d['confidence'] == 0.0
assert d['evidence'].startswith('assessor unavailable: assessor exit 124'), f'evidence={d[\"evidence\"]!r}'
assert len(d['evidence']) >= 80
" 2>&1 || { echo "  payload check failed; entry=$entry"; return 1; }

  echo "$stderr" | grep -qE "WARNING: deviation-assessor failed for phase implement: assessor exit 124" \
    || { echo "  missing timeout WARNING; stderr=$stderr"; return 1; }
  return 0
}

# =============================================================================
# T5: Assessor non-zero exit engages fallback (REQ-6 step 5, REQ-7, AS-4
#     non-zero exit branch, AC-4, EVAL-5).
# =============================================================================
test_assessor_nonzero_exit_engages_fallback() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub nonzero-exit
  local plan="$TEST_DIR/execution-plan.yaml"
  write_flagged_plan "$plan"
  local repo="$TEST_DIR/repo"
  local baseref
  baseref=$(git_repo_at "$repo")

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      workdir='$repo'
      PHASE_BASE_REF='$baseref'
      assess_phase_deviation implement
    " 2>&1) || { echo "  bash failed: $stderr"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  expected 1 phase_result, got $n"; return 1; }

  local entry
  entry=$(read_first_phase_result "$plan")
  python3 -c "
import json
e = json.loads(r'''$entry''')
assert e['conformance'] == 'deviated'
assert len(e['deviations']) == 1
d = e['deviations'][0]
assert d['type'] == 'integration_gap'
assert d['confidence'] == 0.0
assert d['evidence'].startswith('assessor unavailable: assessor exit 1'), f'evidence={d[\"evidence\"]!r}'
assert len(d['evidence']) >= 80
" 2>&1 || { echo "  payload check failed; entry=$entry"; return 1; }

  echo "$stderr" | grep -qE "WARNING: deviation-assessor failed for phase implement: assessor exit 1" \
    || { echo "  missing nonzero-exit WARNING; stderr=$stderr"; return 1; }
  return 0
}

# =============================================================================
# T6: Cascade-prevention skip set + case-sensitivity (REQ-2, REQ-15, AS-5,
#     AC-5 part 1, EVAL-7, EVAL-8, EVAL-9).
# =============================================================================
test_cascade_prevention_skip_set() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  stage_claude_stub recording
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local record="$TEST_DIR/recordings/dt-invocations"

  # shellcheck disable=SC1010  # `done` is a literal slug here, not the loop terminator.
  for slug in retro plan-project done; do
    local stderr
    stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
      DEVIATION_RECORD_FILE="$record" PATH="$PATH" \
      bash -c "
        declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
        log() { :; }
        source '$LIB'
        unset DEVIATION_TRACKER_DISABLE
        assess_phase_deviation $slug
      " 2>&1) || { echo "  bash failed for $slug: $stderr"; return 1; }
    [[ -z "$stderr" ]] || { echo "  expected silent skip for $slug, got: $stderr"; return 1; }
  done

  [[ ! -f "$record" ]] || { echo "  tracker stub invoked on skip set"; return 1; }
  [[ ! -f "$TEST_DIR/recordings/claude-invocations" ]] || { echo "  claude stub invoked on skip set"; return 1; }
  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "0" ]] || { echo "  expected 0 phase_results, got $n"; return 1; }

  # Case-sensitivity: uppercase RETRO MUST NOT skip.
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      assess_phase_deviation RETRO
    " >/dev/null 2>&1 || { echo "  RETRO arm failed"; return 1; }
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  expected 1 phase_result for RETRO, got $n"; return 1; }
  local entry
  entry=$(read_first_phase_result "$plan")
  python3 -c "
import json
e = json.loads(r'''$entry''')
assert e['phase'] == 'RETRO', f'phase={e[\"phase\"]}'
assert e['conformance'] == 'aligned'
" 2>&1 || { echo "  RETRO entry check failed; entry=$entry"; return 1; }

  # W7: exclusivity matrix — non-skip slugs MUST reach the heuristic.
  # Future widening of the skip set would fail this arm. Binds REQ-2's
  # contract that ONLY {retro, plan-project, done} skip; everything else
  # produces an aligned phase_result on the cheap path.
  local slug
  for slug in ba qa implement architecture-plan security-review manualtest; do
    rm -f "$plan"
    cp "$FIXTURES/plan_simple.yaml" "$plan"
    rm -f "$TEST_DIR/recordings/claude-invocations"
    env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
      DEVIATION_RECORD_FILE="$record" PATH="$PATH" \
      bash -c "
        declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
        log() { :; }
        source '$LIB'
        assess_phase_deviation $slug
      " >/dev/null 2>&1 || { echo "  non-skip slug $slug failed to produce entry"; return 1; }
    local n_slug
    n_slug=$(count_phase_results "$plan")
    [[ "$n_slug" == "1" ]] || { echo "  expected 1 phase_result for non-skip slug '$slug', got $n_slug"; return 1; }
    local entry_slug
    entry_slug=$(read_first_phase_result "$plan")
    python3 -c "
import json
e = json.loads(r'''$entry_slug''')
assert e['phase'] == '$slug', f'phase={e[\"phase\"]}'
assert e['conformance'] == 'aligned', f'conformance={e[\"conformance\"]}'
" 2>&1 || { echo "  non-skip slug $slug entry check failed; entry=$entry_slug"; return 1; }
  done
  return 0
}

# =============================================================================
# T7: YAML_FILE unset short-circuits (REQ-1, REQ-9, AS-5, AC-5 part 2, EVAL-11).
# =============================================================================
test_yaml_file_unset_skip() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  stage_claude_stub recording
  local record="$TEST_DIR/recordings/dt-invocations"

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="" TASK="task-1" \
    DEVIATION_RECORD_FILE="$record" PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      assess_phase_deviation ba
    " 2>&1) || { echo "  bash failed: $stderr"; return 1; }

  [[ -z "$stderr" ]] || { echo "  expected silent skip, got: $stderr"; return 1; }
  [[ ! -f "$record" ]] || { echo "  tracker stub invoked despite empty YAML_FILE"; return 1; }
  [[ ! -f "$TEST_DIR/recordings/claude-invocations" ]] || { echo "  claude stub invoked"; return 1; }
  return 0
}

# =============================================================================
# T8: race_two_autopilots — two concurrent track_phase calls land both entries
#     (REQ-13 KC-B, AS-3 under concurrency, EVAL-10).
# =============================================================================
race_two_autopilots() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub recording
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_concurrent_a.yaml" "$plan"

  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" \
    PATH="$PATH" STREAM_FILE="$TEST_DIR/stream.ndjson" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      (TASK=task-a track_phase 'Business Analysis' 'completed' 10 null) &
      (TASK=task-b track_phase 'Business Analysis' 'completed' 10 null) &
      wait
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "2" ]] || { echo "  expected 2 phase_results (lock corruption?), got $n"; return 1; }

  python3 -c "
import yaml
with open('$plan') as f:
    yaml.safe_load(f)
" 2>&1 || { echo "  plan structurally invalid"; return 1; }

  python3 -c "
import yaml
with open('$plan') as f:
    data = yaml.safe_load(f)
expected = {'phase','timestamp','conformance','acceptance_status','deviations'}
for ph in data.get('phases', []):
    for t in ph.get('tasks', []):
        for pr in t.get('phase_results', []) or []:
            assert pr['phase'] == 'ba', f'wrong phase: {pr[\"phase\"]}'
            assert set(pr.keys()) == expected, f'wrong keys: {sorted(pr.keys())}'
" 2>&1 || { echo "  per-entry check failed"; return 1; }
  return 0
}

# =============================================================================
# T9: track_deviation delegates to assess_phase_deviation exactly once
#     with the resolved slug (REQ-10, AS-1, AC-1).
# =============================================================================
test_track_deviation_delegates_to_assess_phase_deviation() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "tracker_stub_writes_then_exits.sh")
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"

  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" REC_FILE="$TEST_DIR/recordings/assess-calls" LIB="$LIB" \
    bash -c "$(cat <<'BASH'
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      # shellcheck disable=SC1090  # source target is dynamic via LIB env var.
      source "$LIB"
      assess_phase_deviation() {
        echo "($1)" >> "$REC_FILE"
        return 0
      }
      track_deviation "Business Analysis"
BASH
    )" >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  local rec="$TEST_DIR/recordings/assess-calls"
  [[ -f "$rec" ]] || { echo "  recording file missing"; return 1; }
  local lines
  lines=$(wc -l <"$rec" | tr -d ' ')
  [[ "$lines" == "1" ]] || { echo "  expected 1 line, got $lines"; return 1; }
  local content
  content=$(cat "$rec")
  [[ "$content" == "(ba)" ]] || { echo "  expected '(ba)', got '$content'"; return 1; }
  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "0" ]] || { echo "  shim was bypassed; got $n entries"; return 1; }
  return 0
}

# =============================================================================
# T6c (W7): non-skip slugs reach heuristic — aligned phase_result written
#     (REQ-2, AS-5 exclusivity arm, AC-5 part 1 extension, EVAL-7).
# =============================================================================
test_nonskip_slugs_reach_heuristic() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub recording
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"

  local slug
  for slug in ba qa implement architecture-plan security-review manualtest; do
    # Reset plan entry count between calls by recopying the fixture.
    cp "$FIXTURES/plan_simple.yaml" "$plan"
    local stderr
    stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
      PATH="$PATH" \
      bash -c "
        declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
        log() { :; }
        source '$LIB'
        assess_phase_deviation $slug
      " 2>&1) || { echo "  bash failed for slug=$slug: $stderr"; return 1; }

    local n
    n=$(count_phase_results "$plan")
    [[ "$n" == "1" ]] || { echo "  [$slug] expected 1 phase_result, got $n"; return 1; }

    local entry
    entry=$(read_first_phase_result "$plan")
    python3 -c "
import json
e = json.loads(r'''$entry''')
assert e['phase'] == '$slug', f'wrong phase: {e[\"phase\"]}'
assert e['conformance'] == 'aligned', f'wrong conformance: {e[\"conformance\"]}'
assert e['acceptance_status'] == 'met'
assert e['deviations'] == []
" 2>&1 || { echo "  [$slug] entry check failed; entry=$entry"; return 1; }
  done
  return 0
}

# =============================================================================
# T10 (W6): recursion guard fires when DEVIATION_ASSESSOR_DEPTH >= 1
#     (W6 guard contract: zero claude spawns, fallback with "recursion guard").
# =============================================================================
test_recursion_guard_fires() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub recording
  local plan="$TEST_DIR/execution-plan.yaml"
  write_flagged_plan "$plan"
  local repo="$TEST_DIR/repo"
  local baseref
  baseref=$(git_repo_at "$repo")

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    DEVIATION_ASSESSOR_DEPTH=1 PATH="$PATH" \
    bash -c "
      export DEVIATION_ASSESSOR_DEPTH
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      workdir='$repo'
      PHASE_BASE_REF='$baseref'
      assess_phase_deviation implement
    " 2>&1) || { echo "  bash failed: $stderr"; return 1; }

  # Zero claude invocations — guard short-circuits before spawn.
  if [[ -f "$TEST_DIR/recordings/claude-invocations" ]]; then
    echo "  claude stub was invoked despite recursion guard (depth=1)"
    return 1
  fi

  # One phase_result must be written (fallback integration_gap).
  local n
  n=$(count_phase_results "$plan")
  [[ "$n" == "1" ]] || { echo "  expected 1 phase_result (fallback), got $n; stderr=$stderr"; return 1; }

  # Evidence must contain "recursion guard tripped".
  local entry
  entry=$(read_first_phase_result "$plan")
  python3 -c "
import json
e = json.loads(r'''$entry''')
assert e['conformance'] == 'deviated', f'conformance={e[\"conformance\"]}'
d = e['deviations'][0]
assert d['type'] == 'integration_gap', f'type={d[\"type\"]}'
assert 'recursion guard tripped' in d['evidence'], f'evidence={d[\"evidence\"]!r}'
" 2>&1 || { echo "  entry check failed; entry=$entry"; return 1; }

  # Stderr WARNING must mention recursion guard.
  echo "$stderr" | grep -q "recursion guard tripped" \
    || { echo "  missing recursion-guard WARNING; stderr=$stderr"; return 1; }

  return 0
}

# =============================================================================
# T11 (DEEP-1): recursion guard depth is FUNCTION-SCOPED. Two sequential
#     flagged dispatches in the same shell must both reach the assessor;
#     the increment must NOT persist into the parent shell across calls.
# =============================================================================
test_recursion_guard_function_scoped() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub aligned-passthrough
  local plan="$TEST_DIR/execution-plan.yaml"
  write_flagged_plan "$plan"
  local repo="$TEST_DIR/repo"
  local baseref
  baseref=$(git_repo_at "$repo")

  # Two sequential calls to assess_phase_deviation in the same shell — both
  # MUST reach claude (no recursion guard trip). Bug pattern (DEEP-1): if
  # DEVIATION_ASSESSOR_DEPTH is exported globally (not function-scoped),
  # the second call would silently fall back to integration_gap.
  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      workdir='$repo'
      PHASE_BASE_REF='$baseref'
      assess_phase_deviation implement
      assess_phase_deviation implement
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  # Both calls reached claude — recordings file has TWO lines (one per spawn).
  if [[ ! -f "$TEST_DIR/recordings/claude-invocations" ]]; then
    echo "  claude stub never invoked"
    return 1
  fi
  local invocation_lines
  invocation_lines=$(grep -c '^PWD=' "$TEST_DIR/recordings/claude-invocations" || echo 0)
  if [[ "$invocation_lines" != "2" ]]; then
    echo "  expected 2 claude invocations across sequential phases, got $invocation_lines"
    echo "  (DEEP-1 regression: parent shell DEVIATION_ASSESSOR_DEPTH persists, second flagged phase silently falls back)"
    return 1
  fi
  return 0
}

# =============================================================================
# T12 (DEEP-2): outer EXIT trap (e.g. autopilot's finalize_cleanup) MUST
#     survive an assess_phase_deviation call. The wire's per-invocation
#     tempdir trap intentionally OMITS EXIT to avoid clobbering caller-
#     installed EXIT handlers, since bash traps are process-scoped.
# =============================================================================
test_outer_exit_trap_survives() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub recording
  local plan="$TEST_DIR/execution-plan.yaml"
  cp "$FIXTURES/plan_simple.yaml" "$plan"
  local marker="$TEST_DIR/outer-exit-trap-fired"

  # Install an EXIT trap, then call assess_phase_deviation, then exit.
  # If the wire's internal trap clobbered the outer EXIT trap, the marker
  # file will not exist when the subshell exits.
  env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" MARKER="$marker" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      trap 'echo outer-exit > \"\$MARKER\"' EXIT
      source '$LIB'
      assess_phase_deviation ba
      assess_phase_deviation ba
    " >/dev/null 2>&1 || { echo "  bash failed"; return 1; }

  if [[ ! -f "$marker" ]]; then
    echo "  outer EXIT trap was clobbered by assess_phase_deviation"
    echo "  (DEEP-2 regression: wire's tempdir trap must NOT include EXIT)"
    return 1
  fi
  return 0
}

# =============================================================================
# T15: When the assessor exits non-zero with stderr (e.g. claude -p rejects
#      a flag combination), the fallback evidence captures the stderr head
#      and stdout head so the next operator can diagnose without re-running.
#      Closes the diagnostic gap that hid the real cause of the post-fix
#      `assessor exit 1` regression on the 2026-05-12 grinder runs — those
#      runs only recorded the exit code, not what claude actually said.
# =============================================================================
test_nonzero_exit_captures_stderr_in_evidence() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub nonzero-exit-with-stderr
  local plan="$TEST_DIR/execution-plan.yaml"
  write_flagged_plan "$plan"
  local repo="$TEST_DIR/repo"
  local baseref
  baseref=$(git_repo_at "$repo")

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      workdir='$repo'
      PHASE_BASE_REF='$baseref'
      assess_phase_deviation implement
    " 2>&1) || { echo "  bash failed: $stderr"; return 1; }

  # Read directly from the YAML rather than round-tripping through bash —
  # the evidence string contains embedded `"` which would have to be
  # double-escaped if passed via heredoc.
  PLAN_PATH="$plan" python3 -c "
import os, yaml
with open(os.environ['PLAN_PATH']) as f:
    data = yaml.safe_load(f) or {}
prs = data['phases'][0]['tasks'][0].get('phase_results') or []
assert len(prs) == 1, f'expected 1 phase_result, got {len(prs)}'
d = prs[0]['deviations'][0]
ev = d['evidence']
assert d['type'] == 'integration_gap', f'type: {d[\"type\"]}'
assert 'assessor exit 1' in ev, f'evidence missing exit code: {ev!r}'
assert 'FAKEFLAG_FOR_TEST' in ev, f'evidence missing stderr head: {ev!r}'
assert 'partial json fragment' in ev, f'evidence missing stdout head: {ev!r}'
" 2>&1 || { echo "  payload check failed"; return 1; }
  return 0
}

# =============================================================================
# T13: Flagged path invokes claude -p with --agent deviation-assessor and
#      mirrors the agent frontmatter via --max-turns 15 + --allowedTools so
#      the agent definition (model: sonnet, tools: Read,Bash,Grep) governs
#      the session directly. Closes the parent-Opus-agent layer that caused
#      both `assessor exit 124` and `assessor stdout invalid: Expecting
#      value: line 1 column 1 (char 0)` failures observed on the
#      grinder-full-stack 2026-05-09 / 2026-05-12 runs.
#
#      Also asserts the prompt argument is the input JSON itself (no
#      "Invoke the deviation-assessor agent" preamble) — when --agent
#      binds the session, the agent's system prompt already states the
#      contract.
# =============================================================================
test_flagged_path_invokes_with_agent_flag() {
  setup
  local apdir
  apdir=$(prepare_isolated_autopilot "")
  cp "$TRACKER" "$apdir/deviation-tracker.py"
  stage_claude_stub aligned-passthrough
  local plan="$TEST_DIR/execution-plan.yaml"
  write_flagged_plan "$plan"
  local repo="$TEST_DIR/repo"
  local baseref
  baseref=$(git_repo_at "$repo")

  local stderr
  stderr=$(env AUTOPILOT_DIR="$apdir" YAML_FILE="$plan" TASK="task-1" \
    PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      workdir='$repo'
      PHASE_BASE_REF='$baseref'
      assess_phase_deviation implement
    " 2>&1) || { echo "  bash failed: $stderr"; return 1; }

  local rec="$TEST_DIR/recordings/claude-invocations"
  [[ -f "$rec" ]] || { echo "  claude stub never invoked"; return 1; }

  # Argv assertions — single ARGS line per invocation; T2 already asserts
  # invocation count, so here we only check the flag content.
  local argv
  argv=$(grep '^PWD=' "$rec" | head -n 1)
  echo "$argv" | grep -q -- '--agent deviation-assessor' \
    || { echo "  missing --agent deviation-assessor in argv: $argv"; return 1; }
  echo "$argv" | grep -q -- '--max-turns 15' \
    || { echo "  missing --max-turns 15 in argv: $argv"; return 1; }
  echo "$argv" | grep -qE -- '--allowedTools (Read,Bash,Grep|"Read,Bash,Grep")' \
    || { echo "  missing --allowedTools Read,Bash,Grep in argv: $argv"; return 1; }

  # Prompt assertion — when --agent binds the session, the agent's system
  # prompt already declares the JSON contract; the user prompt must be the
  # input JSON, not a "Invoke the deviation-assessor agent" preamble that
  # the parent Opus default agent would have to interpret. The stub's
  # PROMPT_ARG=$2 recording assumes the old `claude -p "<prompt>"` shape;
  # with --agent + --max-turns + --allowedTools in front the prompt is no
  # longer $2, so we read from the full ARGS line instead.
  if echo "$argv" | grep -q 'Invoke the deviation-assessor agent'; then
    echo "  prompt still contains parent-agent preamble: $argv"
    return 1
  fi
  echo "$argv" | grep -q '"heuristic_flags"' \
    || { echo "  argv missing heuristic_flags JSON field: $argv"; return 1; }
  echo "$argv" | grep -q '"task"' \
    || { echo "  argv missing task JSON field: $argv"; return 1; }
  return 0
}

# =============================================================================
# T14: DEVIATION_ASSESSOR_TIMEOUT_S default is 180s (post-fix headroom for
#      sonnet warm-up + Read/Bash + JSON emit on the direct-agent path).
#      Pre-fix default was 60s, which the failure record on grinder-full-stack
#      shows is insufficient even for the happy path.
# =============================================================================
test_assessor_timeout_default_is_180s() {
  setup
  local resolved
  resolved=$(env -u DEVIATION_ASSESSOR_TIMEOUT_S PATH="$PATH" \
    bash -c "
      declare -a PHASE_NAMES=() PHASE_STATUSES=() PHASE_DURATIONS=() PHASE_ARTIFACTS=() PHASE_COSTS=()
      log() { :; }
      source '$LIB'
      _assessor_resolve_timeout
    ")
  [[ "$resolved" == "180" ]] || { echo "  expected default 180, got '$resolved'"; return 1; }
  return 0
}

# =============================================================================
# Test runner dispatch
# =============================================================================
run_all() {
  echo "Running deviation-producer wire tests..."
  echo ""
  check "T1: aligned path emits minimal 5-key payload (no claude spawn)" test_aligned_path_emits_minimal_payload
  check "T2.1: flagged path passes assessor stdout verbatim (aligned-passthrough)" test_flagged_path_aligned_passthrough
  check "T2.2: flagged path passes assessor stdout verbatim (gate-logic-drift)" test_flagged_path_gate_logic_drift
  check "T3: flagged path validates assessor output against schema" test_flagged_path_validates_assessor_output
  check "T4: assessor timeout engages fallback" test_assessor_timeout_engages_fallback
  check "T5: assessor non-zero exit engages fallback" test_assessor_nonzero_exit_engages_fallback
  check "T6: cascade-prevention skip set + case-sensitivity" test_cascade_prevention_skip_set
  check "T6c: non-skip slugs reach heuristic (aligned phase_result per slug)" test_nonskip_slugs_reach_heuristic
  check "T7: YAML_FILE unset short-circuits silently" test_yaml_file_unset_skip
  check "T8: race_two_autopilots — both entries land under fcntl.flock" race_two_autopilots
  check "T9: track_deviation delegates to assess_phase_deviation exactly once" test_track_deviation_delegates_to_assess_phase_deviation
  check "T10: recursion guard fires when DEVIATION_ASSESSOR_DEPTH >= 1" test_recursion_guard_fires
  check "T11: recursion guard depth is function-scoped (DEEP-1)" test_recursion_guard_function_scoped
  check "T12: outer EXIT trap survives assess_phase_deviation (DEEP-2)" test_outer_exit_trap_survives
  check "T13: flagged path invokes claude -p with --agent deviation-assessor + --max-turns 15 + --allowedTools" test_flagged_path_invokes_with_agent_flag
  check "T14: DEVIATION_ASSESSOR_TIMEOUT_S default is 180s (was 60s)" test_assessor_timeout_default_is_180s
  check "T15: nonzero exit captures stderr + stdout head into evidence" test_nonzero_exit_captures_stderr_in_evidence
}

if [[ $# -gt 0 ]]; then
  check "$1" "$1"
  echo ""
  echo "Results: ${passed} passed, ${failed} failed"
  [[ $failed -eq 0 ]] && exit 0 || exit 1
fi

run_all
echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
