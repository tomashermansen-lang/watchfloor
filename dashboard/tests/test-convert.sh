#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
CONVERTER="$PROJECT_ROOT/tools/convert-guide.py"
VALIDATOR="$PROJECT_ROOT/tools/validate-plan.py"
PASS=0
FAIL=0
TOTAL=0

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-convert"
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected exit: $expected"
    echo "    actual exit:   $actual"
  fi
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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    output: $(echo "$haystack" | head -5)"
  fi
}

# Helper: convert markdown and capture output
run_converter() {
  python3 "$CONVERTER" "$1" 2>&1
}

# ─── Test Cases ───────────────────────────────────────────────────────

test_fase_headers_extracted() {
  local f="$TMPDIR_BASE/phases.md"
  cat > "$f" <<'EOF'
FASE 0: Setup
- Install dependencies
- Configure CI

FASE 1: Core Features
- Build API
- Add database

FASE 2: Polish
- Write docs
EOF
  local out
  out=$(run_converter "$f")
  local count
  count=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['phases']))")
  assert_eq "3 phases extracted" "3" "$count"
}

test_items_with_status() {
  local f="$TMPDIR_BASE/statuses.md"
  cat > "$f" <<'EOF'
FASE 0: Setup
- ✓ DONE Install tools
- WIP Configure env
- Add tests
EOF
  local out
  out=$(run_converter "$f")
  local statuses
  statuses=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
tasks = plan['phases'][0]['tasks']
print(' '.join(t['status'] for t in tasks))
")
  assert_eq "done wip pending statuses" "done wip pending" "$statuses"
}

test_gate_markers_extracted() {
  local f="$TMPDIR_BASE/gates.md"
  cat > "$f" <<'EOF'
FASE 0: Setup
- Install tools
GATE: All tests green
- CI passes
- Coverage > 80%
EOF
  local out
  out=$(run_converter "$f")
  local has_gate
  has_gate=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
gate = plan['phases'][0].get('gate')
print('yes' if gate else 'no')
")
  assert_eq "gate extracted" "yes" "$has_gate"
}

test_parallel_groups_detected() {
  local f="$TMPDIR_BASE/parallel.md"
  cat > "$f" <<'EOF'
FASE 1: Core
PARALLEL
- Feature A
- Feature B
- Feature C
SEKVENTIELT
- Feature D
EOF
  local out
  out=$(run_converter "$f")
  local groups
  groups=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
tasks = plan['phases'][0]['tasks']
pgroups = [t.get('parallel_group','') for t in tasks]
print(' '.join('p' if g else 's' for g in pgroups))
")
  assert_eq "parallel groups: p p p s" "p p p s" "$groups"
}

test_output_validates_against_schema() {
  local f="$TMPDIR_BASE/validate.md"
  cat > "$f" <<'EOF'
FASE 0: Setup
- Install tools
- Configure CI
GATE: Setup complete
- All checks pass
EOF
  local out
  out=$(run_converter "$f")
  local json_file="$TMPDIR_BASE/validate.json"
  echo "$out" > "$json_file"
  local exit_code=0
  python3 "$VALIDATOR" "$json_file" >/dev/null 2>&1 || exit_code=$?
  assert_exit "converter output validates" "0" "$exit_code"
}

test_empty_input_produces_valid_plan() {
  local f="$TMPDIR_BASE/empty.md"
  echo "" > "$f"
  local out
  out=$(run_converter "$f")
  local json_file="$TMPDIR_BASE/empty.json"
  echo "$out" > "$json_file"
  local exit_code=0
  python3 "$VALIDATOR" "$json_file" >/dev/null 2>&1 || exit_code=$?
  assert_exit "empty input validates" "0" "$exit_code"
  local phases
  phases=$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['phases']))")
  assert_eq "empty input has 0 phases" "0" "$phases"
}

test_prompts_extracted() {
  local f="$TMPDIR_BASE/prompts.md"
  cat > "$f" <<'EOF'
FASE 1: Features
>> /start feature-a
>> /ba flow feature-b
EOF
  local out
  out=$(run_converter "$f")
  local prompts
  prompts=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
tasks = plan['phases'][0]['tasks']
print(' '.join(t.get('prompt','none') for t in tasks))
")
  assert_contains "prompt contains /start" "/start feature-a" "$prompts"
}

test_status_markers_recognized() {
  local f="$TMPDIR_BASE/markers.md"
  cat > "$f" <<'EOF'
FASE 0: Test
- ✓ DONE task-one
- ✅ DONE task-two
- [x] task-three
- IN PROGRESS task-four
- task-five
EOF
  local out
  out=$(run_converter "$f")
  local statuses
  statuses=$(echo "$out" | python3 -c "
import sys, json
plan = json.load(sys.stdin)
tasks = plan['phases'][0]['tasks']
print(' '.join(t['status'] for t in tasks))
")
  assert_eq "all status markers" "done done done wip pending" "$statuses"
}

# ─── Run all tests ───────────────────────────────────────────────────

echo "=== Converter Tests ==="

test_fase_headers_extracted
test_items_with_status
test_gate_markers_extracted
test_parallel_groups_detected
test_output_validates_against_schema
test_empty_input_produces_valid_plan
test_prompts_extracted
test_status_markers_recognized

echo ""
echo "---"
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$((PASS + FAIL))"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo "All converter tests passed."
exit 0
