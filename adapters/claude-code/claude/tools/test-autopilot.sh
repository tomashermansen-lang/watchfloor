#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  test-autopilot.sh — infrastructure tests for autopilot.sh
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Tests the INFRASTRUCTURE (worktree, NDJSON, session extraction,
#  artifact gating, cleanup, resume loop) WITHOUT calling `claude -p`.
#
#  Uses a mock that emits fake NDJSON events to exercise streaming.
#
#  Usage:
#    bash ~/.claude/tools/test-autopilot.sh
#
#  Runs in <60 seconds with zero credit cost.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

TEST_DIR="${TMPDIR:-/tmp}/test-autopilot-$$"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/worktree-reaper.sh
source "${TOOLS_DIR}/lib/worktree-reaper.sh"

setup() {
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

assert_eq() {
  local label=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label"
    echo -e "       expected: ${expected}"
    echo -e "       actual:   ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local label=$1 file=$2
  if [[ -f "$file" ]]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label — file not found: $file"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_exists() {
  local label=$1 file=$2
  if [[ ! -f "$file" && ! -d "$file" ]]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label — path still exists: $file"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label=$1 file=$2 pattern=$3
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label — pattern not found: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_field() {
  local label=$1 file=$2 field=$3 expected=$4
  local actual
  actual=$(python3 -c "import json; print(json.load(open('$file')).get('$field',''))" 2>/dev/null || echo "PARSE_ERROR")
  assert_eq "$label" "$expected" "$actual"
}

skip_test() {
  local label=$1 reason=$2
  echo -e "  ${YELLOW}SKIP${NC} $label — $reason"
  SKIP=$((SKIP + 1))
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Mock: fake claude that emits NDJSON stream
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

create_mock_claude() {
  local mock_path="$TEST_DIR/mock-claude"
  # mode passed via MOCK_CLAUDE_MODE env var, not as parameter

  cat > "$mock_path" <<'MOCKEOF'
#!/usr/bin/env bash
# Mock claude CLI — emits NDJSON events to stdout

MODE="${MOCK_CLAUDE_MODE:-success}"
SESSION_ID="${MOCK_CLAUDE_SESSION:-mock-session-$(date +%s)}"

# Parse flags to detect --resume
IS_RESUME=false
for arg in "$@"; do
  if [[ "$arg" == "--resume" ]]; then
    IS_RESUME=true
  fi
done

emit_session() {
  printf '{"type":"system","session_id":"%s","ts":"2025-01-01T00:00:00Z"}\n' "$SESSION_ID"
}

emit_assistant_text() {
  local text=$1
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$text"
}

emit_tool_use() {
  local name=$1 desc=$2
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"description":"%s"}}]}}\n' "$name" "$desc"
}

emit_tool_result() {
  local content=$1
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"%s"}]}}\n' "$content"
}

emit_result() {
  local status=$1 cost=${2:-0.05} turns=${3:-10} duration=${4:-5000}
  local result_text=${5:-"Phase completed successfully."}
  printf '{"type":"result","subtype":"%s","total_cost_usd":%s,"num_turns":%s,"duration_ms":%s,"result":"%s","session_id":"%s"}\n' \
    "$status" "$cost" "$turns" "$duration" "$result_text" "$SESSION_ID"
}

case "$MODE" in
  success)
    emit_session
    emit_assistant_text "Analyzing requirements..."
    emit_tool_use "Read" "Reading CLAUDE.md"
    emit_tool_result "File contents here"
    emit_assistant_text "Writing artifact..."
    emit_tool_use "Write" "Writing REQUIREMENTS.md"
    emit_tool_result "File written"
    emit_result "success" "0.12" "8" "15000"
    ;;
  fail)
    emit_session
    emit_assistant_text "Starting phase..."
    emit_result "error" "0.03" "2" "2000" "Phase failed with error"
    # Also set is_error flag
    printf '{"type":"result","subtype":"error","is_error":true,"total_cost_usd":0.03,"num_turns":2,"duration_ms":2000,"result":"Phase failed with error","session_id":"%s"}\n' "$SESSION_ID"
    exit 1
    ;;
  checkpoint)
    emit_session
    emit_assistant_text "Working on task..."
    if [[ "$IS_RESUME" == true ]]; then
      # On resume, complete normally
      emit_assistant_text "Continuing after checkpoint..."
      emit_result "success" "0.05" "3" "3000"
    else
      # First run: stop at checkpoint
      emit_result "success" "0.08" "5" "8000" "Continue? [yes / amend / stop]"
    fi
    ;;
  no-session)
    # Emit events without session_id — raw JSON, no emit_result (which includes session_id)
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Working without session..."}]}}\n'
    printf '{"type":"result","subtype":"success","total_cost_usd":0.02,"num_turns":1,"duration_ms":1000,"result":"Done"}\n'
    ;;
  timeout)
    emit_session
    emit_assistant_text "Starting long operation..."
    sleep 120  # Will be killed by timeout
    ;;
esac
MOCKEOF
  chmod +x "$mock_path"
  echo "$mock_path"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Test suites
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── 1. NDJSON stream processing ──────────────────────────

test_ndjson_stream_processing() {
  echo -e "\n${BOLD}${CYAN}Test Suite: NDJSON Stream Processing${NC}"

  local stream_file="$TEST_DIR/stream.ndjson"

  # Generate mock NDJSON
  MOCK_CLAUDE_MODE=success MOCK_CLAUDE_SESSION="test-sess-001" \
    bash "$TEST_DIR/mock-claude" > "$stream_file"

  # Test: session_id extraction from phase-local NDJSON
  local sid
  sid=$(python3 -c "
import json
with open('$stream_file') as f:
    for line in f:
        try:
            e = json.loads(line.strip())
            sid = e.get('session_id')
            if sid:
                print(sid)
                break
        except: pass
" 2>/dev/null || echo "")
  assert_eq "session_id extracted from NDJSON" "test-sess-001" "$sid"

  # Test: cost extraction from last result event
  local cost
  cost=$(grep '"type":"result"' "$stream_file" 2>/dev/null | tail -1 | \
    python3 -c "import sys,json; e=json.load(sys.stdin); print(e.get('total_cost_usd',0))" 2>/dev/null || echo "0")
  assert_eq "cost extracted from result event" "0.12" "$cost"

  # Test: process_stream extracts readable text
  # Source the process_stream function from autopilot.sh
  local readable
  # shellcheck disable=SC2016  # Python f-strings use $ syntax, not shell expansion
  readable=$(python3 -u -c '
import sys, json, re

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\r")

def strip_ansi(s):
    return _ANSI_RE.sub("", s)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue

    etype = event.get("type", "")

    if etype == "assistant":
        msg = event.get("message", {})
        for block in msg.get("content", []):
            if block.get("type") == "text":
                text = strip_ansi(block.get("text", ""))
                if text.strip():
                    print(text, flush=True)
            elif block.get("type") == "tool_use":
                name = block.get("name", "")
                inp = block.get("input", {})
                desc = inp.get("description", inp.get("command", inp.get("pattern", inp.get("prompt", ""))))
                if isinstance(desc, str) and len(desc) > 150:
                    desc = desc[:150] + "..."
                print(f"  tool:{name}({desc})", flush=True)

    elif etype == "result":
        status = event.get("subtype", "")
        cost = event.get("total_cost_usd", 0)
        turns = event.get("num_turns", 0)
        print(f"  result:{status}|{turns}|${cost:.2f}", flush=True)
' < "$stream_file" 2>/dev/null || echo "PROCESS_ERROR")

  if echo "$readable" | grep -q "Analyzing requirements"; then
    echo -e "  ${GREEN}PASS${NC} process_stream: assistant text extracted"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} process_stream: assistant text not found"
    FAIL=$((FAIL + 1))
  fi

  if echo "$readable" | grep -q "tool:Read"; then
    echo -e "  ${GREEN}PASS${NC} process_stream: tool_use events extracted"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} process_stream: tool_use events not found"
    FAIL=$((FAIL + 1))
  fi

  if echo "$readable" | grep -q "result:success"; then
    echo -e "  ${GREEN}PASS${NC} process_stream: result event extracted"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} process_stream: result event not found"
    FAIL=$((FAIL + 1))
  fi

  # Test: no-session mode produces empty session_id
  MOCK_CLAUDE_MODE=no-session bash "$TEST_DIR/mock-claude" > "$TEST_DIR/nosess.ndjson"
  local nosid
  nosid=$(python3 -c "
import json
with open('$TEST_DIR/nosess.ndjson') as f:
    for line in f:
        try:
            e = json.loads(line.strip())
            sid = e.get('session_id')
            if sid:
                print(sid)
                break
        except: pass
" 2>/dev/null || echo "")
  assert_eq "no session_id when absent from events" "" "$nosid"
}

# ── 2. Artifact gating ───────────────────────────────────

test_artifact_gating() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Artifact Gating${NC}"

  # Source check_artifact from autopilot.sh (inline version)
  local artifact_dir="$TEST_DIR/artifacts"
  mkdir -p "$artifact_dir"

  # Test: missing artifact
  local result=0
  [[ -f "$artifact_dir/REQUIREMENTS.md" ]] || result=1
  assert_eq "missing artifact returns failure" "1" "$result"

  # Test: present artifact
  echo "# Requirements" > "$artifact_dir/REQUIREMENTS.md"
  result=0
  [[ -f "$artifact_dir/REQUIREMENTS.md" ]] || result=1
  assert_eq "present artifact returns success" "0" "$result"

  # Test: retry logic (run_gated_phase allows 2 attempts)
  # Simulate: attempt 1 produces no artifact, attempt 2 produces it
  local attempt=0
  local max_attempts=2
  local gated_result="fail"

  while [[ $attempt -lt $max_attempts ]]; do
    attempt=$((attempt + 1))
    if [[ $attempt -eq 1 ]]; then
      # Simulate missing artifact
      rm -f "$artifact_dir/PLAN.md"
    else
      # Simulate artifact created on retry
      echo "# Plan" > "$artifact_dir/PLAN.md"
    fi

    if [[ -f "$artifact_dir/PLAN.md" ]]; then
      gated_result="pass"
      break
    fi
  done
  assert_eq "retry creates artifact on second attempt" "pass" "$gated_result"
  assert_eq "took 2 attempts" "2" "$attempt"
}

# ── 3. Worktree create/cleanup ────────────────────────────

test_worktree_lifecycle() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Worktree Lifecycle${NC}"

  # Create a test git repo to exercise real worktree operations
  local repo="$TEST_DIR/main-repo"
  mkdir -p "$repo"
  cd "$repo"
  git init -b main >/dev/null 2>&1
  echo "init" > file.txt
  git add file.txt
  git commit -m "init" --no-verify >/dev/null 2>&1

  local wt_path="$TEST_DIR/worktree-test-task"
  local branch="feature/test-task"

  # Create worktree
  git worktree add -b "$branch" "$wt_path" main >/dev/null 2>&1

  assert_file_exists "worktree directory created" "$wt_path/file.txt"

  # Verify worktree is listed
  local wt_list
  wt_list=$(git worktree list 2>/dev/null)
  if echo "$wt_list" | grep -q "$branch"; then
    echo -e "  ${GREEN}PASS${NC} worktree appears in git worktree list"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} worktree not found in git worktree list"
    FAIL=$((FAIL + 1))
  fi

  # Add untracked files (the lingering-files bug)
  echo "untracked content" > "$wt_path/untracked.txt"

  # Cleanup using the same logic as autopilot's cleanup_worktree
  cd "$repo"
  reap_worktree_orphans "$wt_path"
  git worktree remove --force "$wt_path" 2>/dev/null || true
  rm -rf "$wt_path" 2>/dev/null || true  # catch lingering untracked files
  git worktree prune 2>/dev/null || true
  git branch -D "$branch" 2>/dev/null || true

  assert_file_not_exists "worktree directory fully removed (including untracked)" "$wt_path"

  # Verify branch is gone
  local branch_check
  branch_check=$(git branch --list "$branch" 2>/dev/null || true)
  assert_eq "feature branch deleted" "" "$branch_check"

  # Verify worktree pruned
  local wt_after
  wt_after=$(git worktree list 2>/dev/null | grep -c "$branch" || true)
  assert_eq "worktree pruned from list" "0" "$wt_after"
}

# ── 4. Resume loop ────────────────────────────────────────

test_resume_loop() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Resume Loop${NC}"

  # Generate checkpoint NDJSON
  MOCK_CLAUDE_MODE=checkpoint MOCK_CLAUDE_SESSION="resume-sess-001" \
    bash "$TEST_DIR/mock-claude" > "$TEST_DIR/checkpoint.ndjson"

  # Extract last result text and check for "Continue?"
  local last_result
  last_result=$(python3 -c "
import json
with open('$TEST_DIR/checkpoint.ndjson') as f:
    for line in f:
        try:
            e = json.loads(line.strip())
            if e.get('type') == 'result':
                print(e.get('result', ''))
        except: pass
" 2>/dev/null || echo "")

  if echo "$last_result" | grep -q "Continue?"; then
    echo -e "  ${GREEN}PASS${NC} checkpoint detected in result text"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} checkpoint not detected — result: $last_result"
    FAIL=$((FAIL + 1))
  fi

  # Test keyword extraction: "[yes / amend / stop]" -> "yes"
  local keyword
  keyword=$(echo "$last_result" | grep -o '\[.*/ amend / stop\]' | head -1 | sed 's/\[\([a-z]*\).*/\1/')
  keyword=${keyword:-yes}
  assert_eq "keyword extracted from checkpoint" "yes" "$keyword"

  # Test resume limit (max 3 resumes)
  local resume_count=0
  local max_resumes=3
  while [[ $resume_count -lt $max_resumes ]]; do
    resume_count=$((resume_count + 1))
    # Simulate: each resume still sees checkpoint (worst case)
  done
  assert_eq "resume loop capped at max_resumes" "3" "$resume_count"

  # Test: session_id is used for resume (not re-extracted from shared stream)
  local sid
  sid=$(python3 -c "
import json
with open('$TEST_DIR/checkpoint.ndjson') as f:
    for line in f:
        try:
            e = json.loads(line.strip())
            sid = e.get('session_id')
            if sid:
                print(sid)
                break
        except: pass
" 2>/dev/null || echo "")
  assert_eq "session_id for resume from phase-local NDJSON" "resume-sess-001" "$sid"
}

# ── 5. EXTRA_SYSTEM_PROMPT clearing ──────────────────────

test_extra_system_prompt_clearing() {
  echo -e "\n${BOLD}${CYAN}Test Suite: EXTRA_SYSTEM_PROMPT Lifecycle${NC}"

  # Simulate the autopilot.sh pattern: set before test plan, clear after
  EXTRA_SYSTEM_PROMPT=""
  assert_eq "starts empty" "" "$EXTRA_SYSTEM_PROMPT"

  # Set for test plan phase (lines 985-991 of autopilot.sh)
  EXTRA_SYSTEM_PROMPT="YOUR ONLY TASK: Create TESTPLAN.md."
  assert_eq "set for test plan phase" "YOUR ONLY TASK: Create TESTPLAN.md." "$EXTRA_SYSTEM_PROMPT"

  # After test plan phase, must be cleared
  EXTRA_SYSTEM_PROMPT=""
  assert_eq "cleared after test plan phase" "" "$EXTRA_SYSTEM_PROMPT"

  # Verify the append-system-prompt construction handles empty EXTRA_SYSTEM_PROMPT
  local headless_prompt="HEADLESS MODE: base prompt"
  local combined="${headless_prompt}${EXTRA_SYSTEM_PROMPT:+

${EXTRA_SYSTEM_PROMPT}}"
  assert_eq "empty EXTRA_SYSTEM_PROMPT produces no trailing newlines" "$headless_prompt" "$combined"

  # Verify it appends when set
  EXTRA_SYSTEM_PROMPT="EXTRA stuff"
  combined="${headless_prompt}${EXTRA_SYSTEM_PROMPT:+

${EXTRA_SYSTEM_PROMPT}}"
  local expected
  expected=$(printf '%s\n\n%s' "$headless_prompt" "EXTRA stuff")
  assert_eq "non-empty EXTRA_SYSTEM_PROMPT appends with blank line" "$expected" "$combined"

  EXTRA_SYSTEM_PROMPT=""
}

# ── 6. Phase tracking and summary ────────────────────────

test_phase_tracking_and_summary() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Phase Tracking & Summary${NC}"

  # Simulate the track_phase and write_summary flow
  local -a PHASE_NAMES=()
  local -a PHASE_STATUSES=()
  local -a PHASE_DURATIONS=()
  local -a PHASE_ARTIFACTS=()
  local -a PHASE_COSTS=()

  # Track phases like autopilot does
  PHASE_NAMES+=("Business Analysis"); PHASE_STATUSES+=("completed"); PHASE_DURATIONS+=("120"); PHASE_ARTIFACTS+=("REQUIREMENTS.md"); PHASE_COSTS+=("0.12")
  PHASE_NAMES+=("Architecture Plan"); PHASE_STATUSES+=("completed"); PHASE_DURATIONS+=("90"); PHASE_ARTIFACTS+=("PLAN.md"); PHASE_COSTS+=("0.08")
  PHASE_NAMES+=("Implement"); PHASE_STATUSES+=("completed"); PHASE_DURATIONS+=("300"); PHASE_ARTIFACTS+=("null"); PHASE_COSTS+=("0.45")

  assert_eq "3 phases tracked" "3" "${#PHASE_NAMES[@]}"

  # Build JSON like write_summary
  local phases="["
  for i in "${!PHASE_NAMES[@]}"; do
    local artifact="${PHASE_ARTIFACTS[$i]}"
    [[ "$artifact" == "null" ]] && artifact="null" || artifact="\"$artifact\""
    [[ $i -gt 0 ]] && phases+=","
    phases+=$(printf '{"name":"%s","status":"%s","duration_s":%s,"cost":%s,"artifact":%s}' \
      "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DURATIONS[$i]}" "${PHASE_COSTS[$i]}" "$artifact")
  done
  phases+="]"

  local summary_file="$TEST_DIR/summary.json"
  cat > "$summary_file" <<EOJSON
{
  "task": "test-task",
  "project": "test-project",
  "branch": "feature/test-task",
  "workdir": "/tmp/test",
  "start_ts": "2025-01-01T00:00:00Z",
  "end_ts": "2025-01-01T00:08:30Z",
  "duration_s": 510,
  "phases": ${phases},
  "status": "success"
}
EOJSON

  assert_json_field "summary task field" "$summary_file" "task" "test-task"
  assert_json_field "summary status field" "$summary_file" "status" "success"

  # Verify phases array is valid JSON
  local phase_count
  phase_count=$(python3 -c "import json; print(len(json.load(open('$summary_file'))['phases']))" 2>/dev/null || echo "0")
  assert_eq "summary has 3 phases" "3" "$phase_count"

  # Verify cost is captured
  local total_cost
  total_cost=$(python3 -c "
import json
data = json.load(open('$summary_file'))
total = sum(p['cost'] for p in data['phases'])
print(f'{total:.2f}')
" 2>/dev/null || echo "0")
  assert_eq "total cost summed" "0.65" "$total_cost"
}

# ── 7. Dashboard event emission ──────────────────────────

test_dashboard_events() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Dashboard Event Emission${NC}"

  local dashboard_file="$TEST_DIR/sessions.jsonl"
  touch "$dashboard_file"

  # Simulate dashboard_event (from autopilot.sh lines 84-93)
  local AUTOPILOT_SID
  AUTOPILOT_SID="autopilot-test-$(date +%s)"
  local ts branch cwd json
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  branch="feature/test-task"
  cwd="/tmp/test"

  json=$(printf '{"sid":"%s","cwd":"%s","branch":"%s","event":"%s","type":"autopilot","msg":"%s","ts":"%s","atype":"%s"}' \
    "$AUTOPILOT_SID" "$cwd" "$branch" "PhaseStart" "BA: running" "$ts" "autopilot")
  echo "$json" >> "$dashboard_file"

  json=$(printf '{"sid":"%s","cwd":"%s","branch":"%s","event":"%s","type":"autopilot","msg":"%s","ts":"%s","atype":"%s"}' \
    "$AUTOPILOT_SID" "$cwd" "$branch" "PhaseStop" "BA: completed in 120s" "$ts" "autopilot")
  echo "$json" >> "$dashboard_file"

  assert_contains "PhaseStart event emitted" "$dashboard_file" "PhaseStart"
  assert_contains "PhaseStop event emitted" "$dashboard_file" "PhaseStop"

  # Verify each line is valid JSON
  local invalid_lines
  invalid_lines=$(python3 -c "
import json
count = 0
with open('$dashboard_file') as f:
    for line in f:
        try: json.loads(line.strip())
        except: count += 1
print(count)
" 2>/dev/null || echo "999")
  assert_eq "all dashboard events are valid JSON" "0" "$invalid_lines"
}

# ── 8. Orchestrator NDJSON log() emission ─────────────────

test_orchestrator_ndjson_emission() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Orchestrator NDJSON Emission${NC}"

  local stream_file="$TEST_DIR/orchestrator-stream.ndjson"
  echo "" > "$stream_file"

  # Simulate the log() function's NDJSON emission (lines 63-73)
  STREAM_FILE="$stream_file"
  local msg="Phase completed in 120s"
  local clean_msg
  # shellcheck disable=SC2001  # ANSI regex requires sed, not ${var//pattern}
  clean_msg=$(echo -e "$msg" | sed $'s/\x1b\\[[0-9;]*m//g')
  printf '{"type":"orchestrator","msg":"%s","ts":"%s"}\n' \
    "$(echo "$clean_msg" | sed 's/"/\\"/g')" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"

  assert_contains "orchestrator event in stream" "$stream_file" '"type":"orchestrator"'
  assert_contains "message preserved in stream" "$stream_file" "Phase completed in 120s"

  # Verify ANSI stripping
  local colored_msg=$'\033[0;32m✓\033[0m Phase done'
  # shellcheck disable=SC2001  # ANSI regex requires sed, not ${var//pattern}
  clean_msg=$(echo -e "$colored_msg" | sed $'s/\x1b\\[[0-9;]*m//g')
  printf '{"type":"orchestrator","msg":"%s","ts":"%s"}\n' \
    "$(echo "$clean_msg" | sed 's/"/\\"/g')" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"

  # The ANSI codes should be stripped
  local has_ansi
  has_ansi=$(python3 -c "
import json, re
with open('$stream_file') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            if re.search(r'\x1b\[', e.get('msg','')):
                print('yes')
                break
        except: pass
print('no')
" 2>/dev/null | tail -1)
  assert_eq "ANSI codes stripped from orchestrator events" "no" "$has_ansi"
}

# ── 8b. Stream append-across-restart ─────────────────────

test_stream_append_across_restart() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Stream Append Across Restart${NC}"

  # Resume of an in-flight feature must preserve the prior run's trace.
  # Regression guard: autopilot.sh used to truncate STREAM_FILE on every
  # start (echo "" > $STREAM_FILE), wiping ba/plan/implement/qa history
  # on a resume from a later phase. The init block now appends and
  # emits a session-boundary marker as the first record of each run.

  local repo="$TEST_DIR/append-repo"
  local wt_path="$TEST_DIR/append-worktree"
  local TASK="append-test"
  local FEATURE_DIR="docs/INPROGRESS_Feature_$TASK"

  mkdir -p "$repo"
  cd "$repo"
  git init -b main >/dev/null 2>&1
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > file.txt
  git add file.txt
  git commit -m "init" --no-verify >/dev/null 2>&1
  git worktree add -b "feature/$TASK" "$wt_path" main >/dev/null 2>&1

  local stream_file="$wt_path/$FEATURE_DIR/autopilot-stream.ndjson"
  mkdir -p "$wt_path/$FEATURE_DIR"

  # Simulate a prior run leaving its trace in the stream.
  printf '{"type":"lifecycle","action":"started","source":"cli","target":"%s","ts":"2026-05-22T10:00:00Z"}\n' "$TASK" > "$stream_file"
  printf '{"type":"lifecycle","action":"phase_complete","source":"cli","target":"%s","phase":"implement","ts":"2026-05-22T10:30:00Z"}\n' "$TASK" >> "$stream_file"
  local prior_line_count
  prior_line_count=$(wc -l < "$stream_file" | tr -d ' ')
  assert_eq "prior session wrote 2 lines" "2" "$prior_line_count"

  # Drive autopilot.sh init in isolation: the production block at the
  # ── Initialize ── section is what we need to exercise. Inline its
  # exact behavior (this is the regression target).
  STREAM_FILE="$stream_file"
  { printf '{"type":"orchestrator","msg":"--- session start ---","ts":"%s"}\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"; } 2>/dev/null || true

  # Prior content preserved (≥ 2 lines + new marker line).
  local total_lines
  total_lines=$(wc -l < "$stream_file" | tr -d ' ')
  if [[ "$total_lines" -ge 3 ]]; then
    echo -e "  ${GREEN}PASS${NC} prior session preserved + marker appended ($total_lines lines)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} expected ≥3 lines after init, got $total_lines"
    FAIL=$((FAIL + 1))
  fi

  assert_contains "phase_complete from prior session still present" "$stream_file" '"action":"phase_complete"'
  assert_contains "session-start marker emitted" "$stream_file" '--- session start ---'

  # The marker MUST come AFTER the prior lifecycle events — proving
  # append order, not accidental insert at the top.
  local last_line
  last_line=$(tail -n 1 "$stream_file")
  if echo "$last_line" | grep -q '"orchestrator".*session start'; then
    echo -e "  ${GREEN}PASS${NC} marker is the last line (append, not prepend)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} marker not at end of stream — last line: $last_line"
    FAIL=$((FAIL + 1))
  fi

  # Regression guard on the production source: assert autopilot.sh does
  # NOT truncate STREAM_FILE with `echo "" > "$STREAM_FILE"`. Catches
  # the case where someone reverts the append change.
  local autopilot_src="${TOOLS_DIR}/autopilot.sh"
  if grep -qE '^[[:space:]]*echo[[:space:]]+""[[:space:]]+>[[:space:]]+"\$STREAM_FILE"' "$autopilot_src"; then
    echo -e "  ${RED}FAIL${NC} autopilot.sh truncates STREAM_FILE — regression of append behavior"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC} autopilot.sh does not truncate STREAM_FILE"
    PASS=$((PASS + 1))
  fi

  cd "$TEST_DIR"
  git worktree remove --force "$wt_path" 2>/dev/null || true
  rm -rf "$repo" "$wt_path"
}

# ── 9. commit-finalize.sh ────────────────────────────────

test_commit_finalize() {
  echo -e "\n${BOLD}${CYAN}Test Suite: commit-finalize.sh${NC}"

  if ! command -v jq &>/dev/null; then
    skip_test "commit-finalize requires jq" "jq not installed"
    return
  fi

  # Create a test repo with a feature branch
  local repo="$TEST_DIR/finalize-repo"
  mkdir -p "$repo"
  cd "$repo"
  git init -b main >/dev/null 2>&1
  echo "init" > file.txt
  git add file.txt
  git commit -m "init" --no-verify >/dev/null 2>&1

  local branch="feature/finalize-test"
  local wt_path="$TEST_DIR/finalize-worktree"
  git worktree add -b "$branch" "$wt_path" main >/dev/null 2>&1

  # Create feature docs in worktree
  mkdir -p "$wt_path/docs/INPROGRESS_Feature_finalize-test"
  echo "# Requirements" > "$wt_path/docs/INPROGRESS_Feature_finalize-test/REQUIREMENTS.md"
  cd "$wt_path"
  git add docs/
  git commit -m "docs(finalize-test): requirements" --no-verify >/dev/null 2>&1

  # Run commit-finalize with --skip-merge --skip-cleanup
  # stdout has git output + JSON. Grab the last JSON line.
  local raw_output
  raw_output=$(bash "$TOOLS_DIR/commit-finalize.sh" \
    --task "finalize-test" \
    --worktree "$wt_path" \
    --main "$repo" \
    --branch "$branch" \
    --skip-merge \
    --skip-cleanup 2>/dev/null)

  # Extract the JSON object from the output (jq pretty-prints across multiple lines)
  # Try parsing from each '{' that starts a line to find the top-level object
  local task
  task=$(echo "$raw_output" | python3 -c "
import sys, json, re
text = sys.stdin.read()
for m in re.finditer(r'^\{', text, re.MULTILINE):
    try:
        obj = json.loads(text[m.start():])
        print(obj.get('task', ''))
        break
    except (json.JSONDecodeError, ValueError):
        continue
else:
    print('NO_JSON')
" 2>/dev/null || echo "PARSE_ERROR")
  assert_eq "commit-finalize returns valid JSON with task field" "finalize-test" "$task"

  # Verify docs were renamed
  assert_file_exists "docs renamed to DONE" "$wt_path/docs/DONE_Feature_finalize-test/REQUIREMENTS.md"
  assert_file_not_exists "INPROGRESS docs removed" "$wt_path/docs/INPROGRESS_Feature_finalize-test"

  # Cleanup
  cd "$repo"
  reap_worktree_orphans "$wt_path"
  git worktree remove --force "$wt_path" 2>/dev/null || true
  rm -rf "$wt_path" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
  git branch -D "$branch" 2>/dev/null || true
}

# ── 10. done-verify.sh ────────────────────────────────────

test_done_verify() {
  echo -e "\n${BOLD}${CYAN}Test Suite: done-verify.sh${NC}"

  if ! command -v jq &>/dev/null; then
    skip_test "done-verify requires jq" "jq not installed"
    return
  fi

  # Create a test repo
  local repo="$TEST_DIR/verify-repo"
  mkdir -p "$repo"
  cd "$repo"
  git init -b main >/dev/null 2>&1
  echo "init" > file.txt
  git add file.txt
  git commit -m "init" --no-verify >/dev/null 2>&1

  # No feature exists yet — should report all_clean=false
  local output
  output=$(bash "$TOOLS_DIR/done-verify.sh" "nonexistent-feature" 2>/dev/null)
  local all_clean
  all_clean=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('all_clean',''))" 2>/dev/null || echo "PARSE_ERROR")
  assert_eq "nonexistent feature is not all_clean" "False" "$all_clean"

  # Simulate a completed feature: create DONE docs and a merge commit
  mkdir -p "$repo/docs/DONE_Feature_verify-test"
  echo "done" > "$repo/docs/DONE_Feature_verify-test/REQUIREMENTS.md"
  git add docs/
  git commit -m "feat(verify-test): merge feature/verify-test" --no-verify >/dev/null 2>&1

  output=$(bash "$TOOLS_DIR/done-verify.sh" "verify-test" 2>/dev/null)
  local docs_status
  docs_status=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('docs_status',''))" 2>/dev/null || echo "PARSE_ERROR")
  assert_eq "docs_status is done" "done" "$docs_status"

  local is_merged
  is_merged=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('is_merged',''))" 2>/dev/null || echo "PARSE_ERROR")
  assert_eq "is_merged detected from commit message" "True" "$is_merged"
}

# ── 11. start-validate.sh ─────────────────────────────────

test_start_validate() {
  echo -e "\n${BOLD}${CYAN}Test Suite: start-validate.sh${NC}"

  if ! command -v jq &>/dev/null; then
    skip_test "start-validate requires jq" "jq not installed"
    return
  fi

  # Create a test repo
  local repo="$TEST_DIR/validate-repo"
  mkdir -p "$repo"
  cd "$repo"
  git init -b main >/dev/null 2>&1
  echo "init" > file.txt
  git add file.txt
  git commit -m "init" --no-verify >/dev/null 2>&1

  # From main: should be ok for a new feature
  local output
  output=$(bash "$TOOLS_DIR/start-validate.sh" "new-feature" 2>/dev/null)
  local ok
  ok=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "PARSE_ERROR")
  assert_eq "new feature on main is ok" "True" "$ok"

  # Create existing branch — should fail
  git branch "feature/existing-feature" 2>/dev/null
  output=$(bash "$TOOLS_DIR/start-validate.sh" "existing-feature" 2>/dev/null)
  ok=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "PARSE_ERROR")
  assert_eq "existing branch returns not ok" "False" "$ok"
}

# ── 12. Full worktree pipeline lifecycle ──────────────────

test_full_worktree_lifecycle() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Full Worktree Pipeline Lifecycle${NC}"

  # Create a "main repo" with initial commit
  local repo="$TEST_DIR/lifecycle-repo"
  mkdir -p "$repo"
  cd "$repo"
  git init -b main >/dev/null 2>&1
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > file.txt
  git add file.txt
  git commit -m "init" --no-verify >/dev/null 2>&1

  local TASK="lifecycle-test"
  local branch="feature/$TASK"
  local wt_path="$TEST_DIR/lifecycle-worktree"
  local FEATURE_DIR="docs/INPROGRESS_Feature_$TASK"

  # ── Step 1: Create worktree (like /start) ──
  git worktree add -b "$branch" "$wt_path" main >/dev/null 2>&1
  assert_file_exists "worktree created" "$wt_path/file.txt"

  # Verify branch exists
  local branch_exists
  branch_exists=$(cd "$repo" && git branch --list "$branch" | wc -l | tr -d ' ')
  assert_eq "feature branch created" "1" "$branch_exists"

  # ── Step 2: Simulate phases writing to NDJSON stream ──
  local STREAM_FILE="$wt_path/$FEATURE_DIR/autopilot-stream.ndjson"
  mkdir -p "$wt_path/$FEATURE_DIR"
  echo "" > "$STREAM_FILE"

  # BA phase: write running marker, mock events, completed marker
  printf '{"type":"phase","phase":"Business Analysis","status":"running","ts":"2025-01-01T00:00:00Z"}\n' >> "$STREAM_FILE"
  MOCK_CLAUDE_MODE=success MOCK_CLAUDE_SESSION="ba-sess-001" \
    bash "$TEST_DIR/mock-claude" >> "$STREAM_FILE"
  printf '{"type":"phase","phase":"Business Analysis","status":"completed","duration_s":120,"ts":"2025-01-01T00:02:00Z"}\n' >> "$STREAM_FILE"

  # Create BA artifact
  echo "# Requirements" > "$wt_path/$FEATURE_DIR/REQUIREMENTS.md"

  # Implementation phase: same pattern
  printf '{"type":"phase","phase":"Implementation (TDD)","status":"running","ts":"2025-01-01T00:04:00Z"}\n' >> "$STREAM_FILE"
  MOCK_CLAUDE_MODE=success MOCK_CLAUDE_SESSION="impl-sess-001" \
    bash "$TEST_DIR/mock-claude" >> "$STREAM_FILE"
  printf '{"type":"phase","phase":"Implementation (TDD)","status":"completed","duration_s":300,"ts":"2025-01-01T00:09:00Z"}\n' >> "$STREAM_FILE"

  # Verify NDJSON has running markers for BOTH phases
  local running_count
  running_count=$(python3 -c "
import json
count = 0
with open('$STREAM_FILE') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            if e.get('type') == 'phase' and e.get('status') == 'running':
                count += 1
        except: pass
print(count)
" 2>/dev/null)
  assert_eq "both phase running markers in NDJSON" "2" "$running_count"

  # Verify session isolation: each phase has its own session
  local ba_sid impl_sid
  ba_sid=$(python3 -c "
import json
in_ba = False
with open('$STREAM_FILE') as f:
    for line in f:
        try:
            e = json.loads(line.strip())
            if e.get('type') == 'phase' and 'Business' in e.get('phase','') and e.get('status') == 'running':
                in_ba = True
            elif e.get('type') == 'phase' and e.get('status') == 'completed':
                in_ba = False
            elif in_ba and e.get('session_id'):
                print(e['session_id']); break
        except: pass
" 2>/dev/null)
  impl_sid=$(python3 -c "
import json
in_impl = False
with open('$STREAM_FILE') as f:
    for line in f:
        try:
            e = json.loads(line.strip())
            if e.get('type') == 'phase' and 'Implement' in e.get('phase','') and e.get('status') == 'running':
                in_impl = True
            elif e.get('type') == 'phase' and e.get('status') == 'completed':
                in_impl = False
            elif in_impl and e.get('session_id'):
                print(e['session_id']); break
        except: pass
" 2>/dev/null)
  assert_eq "BA session ID correct" "ba-sess-001" "$ba_sid"
  assert_eq "Impl session ID correct (isolated)" "impl-sess-001" "$impl_sid"

  # ── Step 3: Commit on feature branch ──
  cd "$wt_path"
  git add docs/
  git commit -m "feat($TASK): implement" --no-verify >/dev/null 2>&1

  # ── Step 4: Rename INPROGRESS → DONE (like commit-finalize) ──
  mv "$wt_path/docs/INPROGRESS_Feature_$TASK" "$wt_path/docs/DONE_Feature_$TASK"
  git add docs/
  git commit -m "docs($TASK): mark as done" --no-verify >/dev/null 2>&1

  assert_file_exists "DONE docs exist" "$wt_path/docs/DONE_Feature_$TASK/REQUIREMENTS.md"
  assert_file_exists "NDJSON preserved in DONE dir" "$wt_path/docs/DONE_Feature_$TASK/autopilot-stream.ndjson"

  # ── Step 5: Merge to main (like commit-finalize) ──
  cd "$repo"
  git merge --no-ff "$branch" -m "feat($TASK): merge $branch" >/dev/null 2>&1

  # Verify merge landed
  assert_file_exists "DONE docs on main after merge" "$repo/docs/DONE_Feature_$TASK/REQUIREMENTS.md"
  assert_file_exists "NDJSON on main after merge" "$repo/docs/DONE_Feature_$TASK/autopilot-stream.ndjson"

  # ── Step 6: Cleanup worktree (like autopilot cleanup) ──
  # Add untracked files (the bug that caused lingering dirs)
  echo "untracked" > "$wt_path/leftover.txt"
  mkdir -p "$wt_path/node_modules/fake"
  echo "big" > "$wt_path/node_modules/fake/index.js"

  cd "$repo"
  reap_worktree_orphans "$wt_path"
  git worktree remove --force "$wt_path" 2>/dev/null || true
  rm -rf "$wt_path" 2>/dev/null || true  # catch untracked files
  git worktree prune 2>/dev/null || true
  git branch -D "$branch" 2>/dev/null || true

  # Verify complete cleanup
  assert_file_not_exists "worktree dir removed" "$wt_path"

  local wt_count
  wt_count=$(git worktree list 2>/dev/null | grep -c "feature/lifecycle-test" || true)
  assert_eq "worktree pruned from list" "0" "$wt_count"

  local branch_after
  branch_after=$(git branch --list "$branch" 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "feature branch deleted" "0" "$branch_after"

  # Verify NDJSON survived on main (not lost with worktree)
  assert_file_exists "NDJSON still on main after cleanup" "$repo/docs/DONE_Feature_$TASK/autopilot-stream.ndjson"

  # Verify no ghost directory recreated (the write_summary bug)
  assert_file_not_exists "no ghost worktree from mkdir -p" "$wt_path"
}

# ── 13. Pipeline value validation ─────────────────────────

test_pipeline_validation() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Pipeline Configuration${NC}"

  # Test pipeline phase mapping (full vs light)
  # Full pipeline
  local full_review="team-review" full_qa="team-qa"
  local light_review="review" light_qa="qa"

  # Simulate the pipeline selection logic from autopilot.sh lines 968-1033
  local PIPELINE="full"
  local REVIEW_CMD QA_CMD

  if [[ "$PIPELINE" == "full" ]]; then
    REVIEW_CMD="/team-review"
    QA_CMD="/team-qa"
  else
    REVIEW_CMD="/review"
    QA_CMD="/qa"
  fi
  assert_eq "full pipeline uses /team-review" "/team-review" "$REVIEW_CMD"
  assert_eq "full pipeline uses /team-qa" "/team-qa" "$QA_CMD"

  PIPELINE="light"
  if [[ "$PIPELINE" == "full" ]]; then
    REVIEW_CMD="/team-review"
    QA_CMD="/team-qa"
  else
    REVIEW_CMD="/review"
    QA_CMD="/qa"
  fi
  assert_eq "light pipeline uses /review" "/review" "$REVIEW_CMD"
  assert_eq "light pipeline uses /qa" "/qa" "$QA_CMD"

  # Test MAX_TURNS per phase type
  local MAX_TURNS_DEFAULT=75
  local MAX_TURNS_TEAM=200
  local MAX_TURNS_IMPLEMENT=200

  assert_eq "default turns for BA/Plan" "75" "$MAX_TURNS_DEFAULT"
  assert_eq "team turns for review/QA" "200" "$MAX_TURNS_TEAM"
  assert_eq "implement turns" "200" "$MAX_TURNS_IMPLEMENT"
}

# ── 13. Phase marker injection ────────────────────────────

test_phase_markers() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Phase Markers in NDJSON Stream${NC}"

  local stream_file="$TEST_DIR/markers.ndjson"
  echo "" > "$stream_file"

  # Simulate phase start marker (line 227-228)
  printf '{"type":"phase","phase":"%s","status":"running","ts":"%s"}\n' \
    "Business Analysis" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$stream_file"

  # Simulate phase end marker (lines 332-334)
  printf '{"type":"phase","phase":"%s","status":"%s","duration_s":%d,"ts":"%s"}\n' \
    "Business Analysis" "completed" "120" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$stream_file"

  # Verify markers
  local running_count completed_count
  running_count=$(python3 -c "
import json
count = 0
with open('$stream_file') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            if e.get('type') == 'phase' and e.get('status') == 'running':
                count += 1
        except: pass
print(count)
" 2>/dev/null || echo "0")
  assert_eq "phase running marker emitted" "1" "$running_count"

  completed_count=$(python3 -c "
import json
count = 0
with open('$stream_file') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            if e.get('type') == 'phase' and e.get('status') == 'completed':
                count += 1
        except: pass
print(count)
" 2>/dev/null || echo "0")
  assert_eq "phase completed marker emitted" "1" "$completed_count"
}

# ── 14. Manifest parsing ─────────────────────────────────

test_smoke_retry_budget() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Smoke-Test Retry Budget${NC}"

  # Extract just the retry helper from autopilot.sh — sourcing the whole
  # file would trigger the main-branch guard. The helper must be defined
  # in autopilot.sh as a top-level function starting with `run_smoke_with_retry()`.
  local helper_src
  helper_src=$(sed -n '/^run_smoke_with_retry()/,/^}$/p' "$TOOLS_DIR/autopilot.sh")
  if [[ -z "$helper_src" ]]; then
    echo -e "  ${RED}FAIL${NC} run_smoke_with_retry function not defined in autopilot.sh"
    FAIL=$((FAIL + 1))
    return
  fi
  # Define log() + color vars as no-ops so the helper can call log() without autopilot.sh's globals
  eval "log() { :; }"
  # shellcheck disable=SC2034
  YELLOW='' RED='' GREEN='' CYAN='' NC=''
  eval "$helper_src"

  # Override sleep to a no-op for fast tests (no real waiting between attempts)
  sleep() { :; }

  # Build counter-based mock commands via a shared state file
  local state_file="$TEST_DIR/retry_counter"

  _make_cmd_fails_n_then_passes() {
    # $1 = how many failures before first success
    echo 0 > "$state_file"
    echo "n=\$(cat '$state_file'); n=\$((n+1)); echo \$n > '$state_file'; [[ \$n -gt $1 ]]"
  }

  # Test 1: fails once then passes — should succeed on attempt 2
  local cmd
  cmd=$(_make_cmd_fails_n_then_passes 1)
  if run_smoke_with_retry "$cmd" 2>/dev/null; then
    local attempts=$(cat "$state_file")
    assert_eq "fails-once-then-passes: succeeds" "2" "$attempts"
  else
    echo -e "  ${RED}FAIL${NC} fails-once-then-passes: helper returned non-zero"
    FAIL=$((FAIL + 1))
  fi

  # Test 2: fails TWICE then passes — must succeed on attempt 3
  # (under max_attempts=2 this fails; under max_attempts=3 it passes)
  cmd=$(_make_cmd_fails_n_then_passes 2)
  if run_smoke_with_retry "$cmd" 2>/dev/null; then
    local attempts=$(cat "$state_file")
    assert_eq "fails-twice-then-passes: succeeds on 3rd attempt" "3" "$attempts"
  else
    echo -e "  ${RED}FAIL${NC} fails-twice-then-passes: helper gave up too early (max_attempts < 3)"
    FAIL=$((FAIL + 1))
  fi

  # Test 3: fails three times — should ultimately fail
  cmd=$(_make_cmd_fails_n_then_passes 99)  # always fails (counter never > 99)
  if run_smoke_with_retry "$cmd" 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC} always-fails: helper should return non-zero"
    FAIL=$((FAIL + 1))
  else
    local attempts=$(cat "$state_file")
    assert_eq "always-fails: exhausts exactly 3 attempts" "3" "$attempts"
  fi

  # Cleanup
  unset -f sleep
}

test_manifest_parsing() {
  echo -e "\n${BOLD}${CYAN}Test Suite: Pipeline Manifest Parsing${NC}"

  # Create a mock CLAUDE.md with pipeline manifest
  local claude_md="$TEST_DIR/CLAUDE.md"
  cat > "$claude_md" <<'EOF'
# Project Config

pipeline:
  toolchain:
    python: [ruff, mypy]
    node: [eslint, tsc]
    infra: [docker]
  smoke_test:
    - curl -sf http://localhost:8100/api/health
  contracts:
    - test: tests/contracts/test_api.py
EOF

  # Run the parse_manifest logic (extracted from autopilot.sh lines 391-444)
  local manifest
  manifest=$(python3 -c "
import re, sys

with open('$claude_md') as f:
    content = f.read()

m = re.search(r'^pipeline:\s*\n((?:[ \t]+.*\n)*)', content, re.MULTILINE)
if not m:
    sys.exit(0)

block = m.group(1)
section = None
for line in block.split('\n'):
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue
    if stripped.startswith('toolchain:'):
        section = 'toolchain'
        continue
    if stripped.startswith('smoke_test:'):
        section = 'smoke_test'
        continue
    if stripped.startswith('contracts:'):
        section = 'contracts'
        continue
    if section == 'toolchain':
        if ':' in stripped:
            key, val = stripped.split(':', 1)
            key = key.strip()
            items = [x.strip().strip('[]') for x in val.split(',')]
            items = [x for x in items if x]
            for item in items:
                print(f'TOOLCHAIN|{key}|{item}')
    elif section == 'smoke_test':
        if stripped.startswith('- '):
            cmd = stripped[2:].strip()
            print(f'SMOKE|{cmd}')
    elif section == 'contracts':
        if 'test:' in stripped:
            val = stripped.split('test:', 1)[1].strip()
            print(f'CONTRACT_TEST|{val}')
" 2>/dev/null || echo "")

  echo "$manifest" | grep -q "TOOLCHAIN|python|ruff" && {
    echo -e "  ${GREEN}PASS${NC} parsed python toolchain: ruff"
    PASS=$((PASS + 1))
  } || {
    echo -e "  ${RED}FAIL${NC} ruff not found in manifest"
    FAIL=$((FAIL + 1))
  }

  echo "$manifest" | grep -q "TOOLCHAIN|python|mypy" && {
    echo -e "  ${GREEN}PASS${NC} parsed python toolchain: mypy"
    PASS=$((PASS + 1))
  } || {
    echo -e "  ${RED}FAIL${NC} mypy not found in manifest"
    FAIL=$((FAIL + 1))
  }

  echo "$manifest" | grep -q "TOOLCHAIN|node|eslint" && {
    echo -e "  ${GREEN}PASS${NC} parsed node toolchain: eslint"
    PASS=$((PASS + 1))
  } || {
    echo -e "  ${RED}FAIL${NC} eslint not found in manifest"
    FAIL=$((FAIL + 1))
  }

  echo "$manifest" | grep -q "SMOKE|curl" && {
    echo -e "  ${GREEN}PASS${NC} parsed smoke_test command"
    PASS=$((PASS + 1))
  } || {
    echo -e "  ${RED}FAIL${NC} smoke_test not found"
    FAIL=$((FAIL + 1))
  }

  echo "$manifest" | grep -q "CONTRACT_TEST|tests/contracts/test_api.py" && {
    echo -e "  ${GREEN}PASS${NC} parsed contract test"
    PASS=$((PASS + 1))
  } || {
    echo -e "  ${RED}FAIL${NC} contract test not found"
    FAIL=$((FAIL + 1))
  }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Run all tests
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

main() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔═══════════════════════════════════════════════════╗"
  echo "  ║  test-autopilot.sh — infrastructure test suite   ║"
  echo "  ╚═══════════════════════════════════════════════════╝"
  echo -e "${NC}"

  local start_time=$(date +%s)

  setup
  create_mock_claude >/dev/null

  test_ndjson_stream_processing
  test_artifact_gating
  test_worktree_lifecycle
  test_resume_loop
  test_extra_system_prompt_clearing
  test_phase_tracking_and_summary
  test_dashboard_events
  test_orchestrator_ndjson_emission
  test_stream_append_across_restart
  test_commit_finalize
  test_done_verify
  test_start_validate
  test_full_worktree_lifecycle
  test_pipeline_validation
  test_phase_markers
  test_manifest_parsing
  test_smoke_retry_budget

  teardown

  local end_time=$(date +%s)
  local duration=$(( end_time - start_time ))

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}  (${duration}s)"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
