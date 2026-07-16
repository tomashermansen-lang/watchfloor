#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
TOTAL=0

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

# Helper to extract a field from JSON result
json_field() {
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1',{}).get('$2',''))"
}

json_has_key() {
  python3 -c "import sys,json; d=json.load(sys.stdin); print('$1' in d)"
}

# Run stuck detection via Python — writes temp file to avoid quoting issues
TMPFILE="$PROJECT_DIR/.test-tmp-stuck"
mkdir -p "$TMPFILE"
trap 'rm -rf "$TMPFILE"' EXIT

run_detect() {
  local events_file="$1"
  local sids_json="$2"
  python3 << PYEOF
import sys, json
sys.path.insert(0, '$PROJECT_DIR')
from server.stuck_detection import detect_stuck_sessions
with open('$events_file') as f:
    events = json.load(f)
sids = json.loads('$sids_json')
result = detect_stuck_sessions(events, sids)
print(json.dumps(result))
PYEOF
}

echo "=== Stuck Detection Tests ==="

# ── SD-1: Attractor loop — 3 consecutive identical tool+file ──
test_sd1() {
  echo "  SD-1: Attractor loop — 3 consecutive identical"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"src/auth.ts","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"src/auth.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"src/auth.ts","ts":"2026-01-01T00:00:03Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"src/auth.ts","ts":"2026-01-01T00:00:04Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"src/auth.ts","ts":"2026-01-01T00:00:05Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-1 reason" "attractor_loop" "$(echo "$result" | json_field s1 reason)"
  assert_eq "SD-1 tool" "Read" "$(echo "$result" | json_field s1 tool)"
  assert_eq "SD-1 file" "src/auth.ts" "$(echo "$result" | json_field s1 file)"
}

# ── SD-2: Attractor loop — 5 consecutive (exceeds threshold) ──
test_sd2() {
  echo "  SD-2: Attractor loop — 5 consecutive"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PreToolUse","type":"Edit","fp":"main.py","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Edit","fp":"main.py","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PreToolUse","type":"Edit","fp":"main.py","ts":"2026-01-01T00:00:03Z"},
  {"sid":"s1","event":"PreToolUse","type":"Edit","fp":"main.py","ts":"2026-01-01T00:00:04Z"},
  {"sid":"s1","event":"PreToolUse","type":"Edit","fp":"main.py","ts":"2026-01-01T00:00:05Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-2 reason" "attractor_loop" "$(echo "$result" | json_field s1 reason)"
}

# ── SD-3: Not stuck — 3 identical then different (E4) ──
test_sd3() {
  echo "  SD-3: Not stuck — pattern broken by different call"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:03Z"},
  {"sid":"s1","event":"PreToolUse","type":"Write","fp":"b.ts","ts":"2026-01-01T00:00:04Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-3 no stuck" "{}" "$result"
}

# ── SD-4: Not stuck — same tool, different files (E5) ──
test_sd4() {
  echo "  SD-4: Not stuck — same tool, different files"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"b.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"c.ts","ts":"2026-01-01T00:00:03Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-4 no stuck" "{}" "$result"
}

# ── SD-5: Not stuck — insufficient data (E6) ──
test_sd5() {
  echo "  SD-5: Not stuck — insufficient data"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"SessionStart","ts":"2026-01-01T00:00:01Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-5 no stuck" "{}" "$result"
}

# ── SD-6: Permission oscillation — 3 of 6 events ──
test_sd6() {
  echo "  SD-6: Permission oscillation — 3 of 6"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PermissionRequest","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PermissionRequest","ts":"2026-01-01T00:00:03Z"},
  {"sid":"s1","event":"PreToolUse","type":"Write","fp":"b.ts","ts":"2026-01-01T00:00:04Z"},
  {"sid":"s1","event":"PermissionRequest","ts":"2026-01-01T00:00:05Z"},
  {"sid":"s1","event":"PreToolUse","type":"Edit","fp":"c.ts","ts":"2026-01-01T00:00:06Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-6 reason" "permission_oscillation" "$(echo "$result" | json_field s1 reason)"
}

# ── SD-7: Permission oscillation — different tools (E7) ──
test_sd7() {
  echo "  SD-7: Permission oscillation — different tools still flagged"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PermissionRequest","type":"Bash","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PermissionRequest","type":"Edit","ts":"2026-01-01T00:00:03Z"},
  {"sid":"s1","event":"PreToolUse","type":"Write","fp":"b.ts","ts":"2026-01-01T00:00:04Z"},
  {"sid":"s1","event":"PermissionRequest","type":"Write","ts":"2026-01-01T00:00:05Z"},
  {"sid":"s1","event":"PreToolUse","type":"Edit","fp":"c.ts","ts":"2026-01-01T00:00:06Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-7 reason" "permission_oscillation" "$(echo "$result" | json_field s1 reason)"
}

# ── SD-8: Permission oscillation — below threshold ──
test_sd8() {
  echo "  SD-8: Permission oscillation — below threshold"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PermissionRequest","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PreToolUse","type":"Write","fp":"b.ts","ts":"2026-01-01T00:00:03Z"},
  {"sid":"s1","event":"PreToolUse","type":"Edit","fp":"c.ts","ts":"2026-01-01T00:00:04Z"},
  {"sid":"s1","event":"PermissionRequest","ts":"2026-01-01T00:00:05Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"d.ts","ts":"2026-01-01T00:00:06Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-8 no stuck" "{}" "$result"
}

# ── SD-9: Bounded scan — only last 50 events (R2d) ──
test_sd9() {
  echo "  SD-9: Bounded scan — old attractor outside window"
  # Build 60 events: first 3 are identical (attractor), remaining 57 are varied
  python3 << PYEOF > "$TMPFILE/events.json"
import json
events = []
# Old attractor pattern (will be outside the 50-event window)
for i in range(3):
    events.append({"sid":"s1","event":"PreToolUse","type":"Read","fp":"old.ts","ts":f"2026-01-01T00:00:{i:02d}Z"})
# 57 varied events
for i in range(57):
    events.append({"sid":"s1","event":"PreToolUse","type":"Read","fp":f"file{i}.ts","ts":f"2026-01-01T00:01:{i:02d}Z"})
print(json.dumps(events))
PYEOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-9 no stuck" "{}" "$result"
}

# ── SD-10: Multiple sessions — one stuck, one healthy ──
test_sd10() {
  echo "  SD-10: Multiple sessions — one stuck, one healthy"
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:03Z"},
  {"sid":"s2","event":"PreToolUse","type":"Read","fp":"x.ts","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s2","event":"PreToolUse","type":"Write","fp":"y.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s2","event":"PreToolUse","type":"Edit","fp":"z.ts","ts":"2026-01-01T00:00:03Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1","s2"]')
  assert_eq "SD-10 s1 stuck" "attractor_loop" "$(echo "$result" | json_field s1 reason)"
  assert_eq "SD-10 s2 healthy" "False" "$(echo "$result" | json_has_key s2)"
}

# ── SD-11: Both patterns present — attractor wins (first detector) ──
test_sd11() {
  echo "  SD-11: Both patterns — attractor wins (first detector in registry)"
  # 3 PreToolUse with same tool+file (attractor) interleaved with 3 PermissionRequest (oscillation)
  # Attractor detector filters to PreToolUse only, sees 3 consecutive identical → attractor wins
  cat > "$TMPFILE/events.json" << 'EOF'
[
  {"sid":"s1","event":"PermissionRequest","ts":"2026-01-01T00:00:01Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:02Z"},
  {"sid":"s1","event":"PermissionRequest","ts":"2026-01-01T00:00:03Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:04Z"},
  {"sid":"s1","event":"PermissionRequest","ts":"2026-01-01T00:00:05Z"},
  {"sid":"s1","event":"PreToolUse","type":"Read","fp":"a.ts","ts":"2026-01-01T00:00:06Z"}
]
EOF
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-11 reason" "attractor_loop" "$(echo "$result" | json_field s1 reason)"
}

# ── SD-12: Empty events list ──
test_sd12() {
  echo "  SD-12: Empty events list"
  echo "[]" > "$TMPFILE/events.json"
  local result
  result=$(run_detect "$TMPFILE/events.json" '["s1"]')
  assert_eq "SD-12 empty" "{}" "$result"
}

# Run all tests
test_sd1
test_sd2
test_sd3
test_sd4
test_sd5
test_sd6
test_sd7
test_sd8
test_sd9
test_sd10
test_sd11
test_sd12

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="
[ "$FAIL" -eq 0 ]
