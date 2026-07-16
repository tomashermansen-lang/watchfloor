#!/bin/bash
# test_get_findings.sh — C7: Integration tests for get-findings.sh
#
# Tests the full pipeline: scanner → normaliser → filter.
# Uses mock scanner commands to avoid requiring real scanners.
#
# Usage: bash tests/test_get_findings.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GET_FINDINGS="$REPO_DIR/adapters/claude-code/claude/tools/get-findings.sh"

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

check_fail() {
    local name="$1"
    shift
    if ! "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name (expected failure but succeeded)"
        failed=$((failed + 1))
    fi
}

# --- Test setup ---

TEST_DIR="${TMPDIR:-/tmp}/test-get-findings-$$"
mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Create source files for content-hash (normaliser needs real files)
mkdir -p "$TEST_DIR/src"
cat > "$TEST_DIR/src/foo.py" << 'PYEOF'
import sys
import os
import json
# line 4
# line 5
# line 6
# line 7
# line 8
# line 9
x = "a" * 200  # line 10 — long line
PYEOF

mkdir -p "$TEST_DIR/scripts"
cat > "$TEST_DIR/scripts/run.sh" << 'SHEOF'
#!/bin/bash
set -e
# lines
# lines
# lines
# lines
# lines
# lines
# lines
# lines
# lines
# lines
# lines
# lines
# line 15
echo $unquoted
SHEOF

# Create ruff fixture matching our source files
RUFF_FIXTURE='[
  {"cell":null,"code":"E501","end_location":{"column":120,"row":10},"filename":"src/foo.py","fix":null,"location":{"column":1,"row":10},"message":"Line too long (120 > 88)","noqa_row":10,"url":""},
  {"cell":null,"code":"F401","end_location":{"column":10,"row":2},"filename":"src/foo.py","fix":null,"location":{"column":1,"row":2},"message":"`os` imported but unused","noqa_row":2,"url":""}
]'

# Create mock scanner scripts
cat > "$TEST_DIR/mock-ruff.sh" << MOCKEOF
#!/bin/bash
cat << 'JSONEOF'
$RUFF_FIXTURE
JSONEOF
MOCKEOF
chmod +x "$TEST_DIR/mock-ruff.sh"

# Mock scanner that exits non-zero but produces valid output (AS-4)
cat > "$TEST_DIR/mock-ruff-nonzero.sh" << MOCKEOF
#!/bin/bash
cat << 'JSONEOF'
$RUFF_FIXTURE
JSONEOF
exit 1
MOCKEOF
chmod +x "$TEST_DIR/mock-ruff-nonzero.sh"

# Mock scanner that produces empty JSON array
cat > "$TEST_DIR/mock-empty.sh" << 'MOCKEOF'
#!/bin/bash
echo '[]'
MOCKEOF
chmod +x "$TEST_DIR/mock-empty.sh"

# Create deferred-findings.json in the test project
mkdir -p "$TEST_DIR/docs/grinder"
echo '[]' > "$TEST_DIR/docs/grinder/deferred-findings.json"

# Deferred file matching one of the 2 ruff findings
# We need to know the finding_id format. Run normaliser first to get IDs.
NORMALISED=$(echo "$RUFF_FIXTURE" | python3 "$REPO_DIR/adapters/claude-code/claude/tools/normalise-findings.py" --tool ruff --project-root "$TEST_DIR")
# Extract finding IDs for deferred matching and assertion
FIRST_ID=$(echo "$NORMALISED" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
SECOND_ID=$(echo "$NORMALISED" | python3 -c "import sys,json; print(json.load(sys.stdin)[1]['id'])")

# Create deferred file matching the first finding
cat > "$TEST_DIR/deferred-1-match.json" << DEFEOF
[{"finding_id": "$FIRST_ID", "state": "WontFix", "reason": "test"}]
DEFEOF


# =========================================================================
# TC-GF01: Scanner exits non-zero with valid output (AS-4, REQ-5)
# =========================================================================
tc_gf01() {
    local stdout
    stdout=$(PROJECT_ROOT="$TEST_DIR" DEFERRED_FINDINGS_PATH="$TEST_DIR/docs/grinder/deferred-findings.json" \
        bash "$GET_FINDINGS" ruff bash "$TEST_DIR/mock-ruff-nonzero.sh" 2>/dev/null)
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    echo "$stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) > 0" || return 1
}
check "TC-GF01: scanner non-zero exit with valid output → exit 0" tc_gf01


# =========================================================================
# TC-GF02: Scanner command not found (EC-1.1)
# =========================================================================
tc_gf02() {
    PROJECT_ROOT="$TEST_DIR" \
        bash "$GET_FINDINGS" ruff nonexistent-binary-xyz-$$ 2>/dev/null
}
check_fail "TC-GF02: scanner command not found → exit 1" tc_gf02


# =========================================================================
# TC-GF03: Empty scanner output — zero findings (EC-1.2)
# =========================================================================
tc_gf03() {
    local stdout
    stdout=$(PROJECT_ROOT="$TEST_DIR" DEFERRED_FINDINGS_PATH="$TEST_DIR/docs/grinder/deferred-findings.json" \
        bash "$GET_FINDINGS" ruff bash "$TEST_DIR/mock-empty.sh" 2>/dev/null)
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    echo "$stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d == []" || return 1
}
check "TC-GF03: empty scanner output → [] exit 0" tc_gf03


# =========================================================================
# TC-GF04: Unknown tool name (EC-1.3)
# =========================================================================
tc_gf04() {
    local stderr
    stderr=$(PROJECT_ROOT="$TEST_DIR" \
        bash "$GET_FINDINGS" unknown-scanner-xyz bash "$TEST_DIR/mock-empty.sh" 2>&1 >/dev/null)
    local rc=$?
    [ "$rc" -ne 0 ] || return 1
    echo "$stderr" | grep -q "unknown tool" || return 1
}
check "TC-GF04: unknown tool name → exit 1 with normaliser error" tc_gf04


# =========================================================================
# TC-GF05: Project root resolution — env var (REQ-7)
# =========================================================================
tc_gf05() {
    local stdout
    stdout=$(PROJECT_ROOT="$TEST_DIR" DEFERRED_FINDINGS_PATH="$TEST_DIR/docs/grinder/deferred-findings.json" \
        bash "$GET_FINDINGS" ruff bash "$TEST_DIR/mock-ruff.sh" 2>/dev/null)
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    # Verify paths are relative (not absolute)
    echo "$stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); assert all(not f['file'].startswith('/') for f in d)" || return 1
    # Verify content_hash matches file content at PROJECT_ROOT (proves PROJECT_ROOT was used).
    # The normaliser hashes a 5-line window centered on the finding line.
    echo "$stdout" | python3 -c "
import sys, json, hashlib
d = json.load(sys.stdin)
# Find the E501 finding on line 10 of src/foo.py
e501 = [f for f in d if f['rule'] == 'E501']
assert len(e501) == 1, f'expected 1 E501 finding, got {len(e501)}'
# Compute the 5-line window hash the normaliser uses (center +/- 2 lines)
with open('$TEST_DIR/src/foo.py') as fh:
    content = fh.read()
lines = content.splitlines()
center = 10 - 1  # 0-indexed
start = max(0, center - 2)
end = min(len(lines), center + 3)
window = '\n'.join(lines[start:end])
expected = hashlib.sha256(window.encode('utf-8')).hexdigest()[:8]
actual = e501[0]['content_hash']
assert actual == expected, f'content_hash {actual} != expected {expected} — PROJECT_ROOT not used'
" || return 1
}
check "TC-GF05: PROJECT_ROOT env var used for normalisation" tc_gf05


# =========================================================================
# TC-GF06: Deferred path override via env var (REQ-8)
# =========================================================================
tc_gf06() {
    local stdout stderr
    # Use deferred file that matches one finding
    stderr=$(PROJECT_ROOT="$TEST_DIR" DEFERRED_FINDINGS_PATH="$TEST_DIR/deferred-1-match.json" \
        bash "$GET_FINDINGS" ruff bash "$TEST_DIR/mock-ruff.sh" 2>&1 >/dev/null)
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    echo "$stderr" | grep -q "1 deferred suppressed" || return 1
}
check "TC-GF06: DEFERRED_FINDINGS_PATH env var override" tc_gf06


# =========================================================================
# TC-GF07: Usage guard — too few args
# =========================================================================
tc_gf07_zero() {
    local stderr
    stderr=$(bash "$GET_FINDINGS" 2>&1 >/dev/null)
    local rc=$?
    [ "$rc" -eq 1 ] || return 1
    echo "$stderr" | grep -qi "usage" || return 1
}
check "TC-GF07a: zero args → usage error" tc_gf07_zero

tc_gf07_one() {
    local stderr
    stderr=$(bash "$GET_FINDINGS" ruff 2>&1 >/dev/null)
    local rc=$?
    [ "$rc" -eq 1 ] || return 1
    echo "$stderr" | grep -qi "usage" || return 1
}
check "TC-GF07b: one arg → usage error" tc_gf07_one


# =========================================================================
# TC-GF08: Normaliser resolved relative to script dir (REQ-13)
# =========================================================================
tc_gf08() {
    local stdout
    # Run from a different directory — should still find normaliser
    stdout=$(cd "$TEST_DIR" && PROJECT_ROOT="$TEST_DIR" DEFERRED_FINDINGS_PATH="$TEST_DIR/docs/grinder/deferred-findings.json" \
        bash "$GET_FINDINGS" ruff bash "$TEST_DIR/mock-ruff.sh" 2>/dev/null)
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    echo "$stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list)" || return 1
}
check "TC-GF08: normaliser resolved relative to SCRIPT_DIR" tc_gf08


# =========================================================================
# TC-GF09: End-to-end deferred filtering
# =========================================================================
tc_gf09() {
    local stdout stderr
    stdout=$(PROJECT_ROOT="$TEST_DIR" DEFERRED_FINDINGS_PATH="$TEST_DIR/deferred-1-match.json" \
        bash "$GET_FINDINGS" ruff bash "$TEST_DIR/mock-ruff.sh" 2>"$TEST_DIR/gf09-stderr.txt")
    local rc=$?
    stderr=$(cat "$TEST_DIR/gf09-stderr.txt")
    [ "$rc" -eq 0 ] || return 1
    # Should have 1 finding (2 total - 1 deferred)
    local count
    count=$(echo "$stdout" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    [ "$count" -eq 1 ] || return 1
    # Verify the remaining finding is the non-deferred one (SECOND_ID)
    local remaining_id
    remaining_id=$(echo "$stdout" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
    [ "$remaining_id" = "$SECOND_ID" ] || return 1
    echo "$stderr" | grep -q "1 deferred suppressed, 1 active findings" || return 1
}
check "TC-GF09: end-to-end deferred filtering" tc_gf09


# =========================================================================
# TC-GF10: Temp file cleanup on normal exit
# =========================================================================
tc_gf10() {
    local before after
    before=$(ls "${TMPDIR:-/tmp}"/get-findings-* 2>/dev/null | wc -l | tr -d ' ')
    before=${before:-0}
    PROJECT_ROOT="$TEST_DIR" DEFERRED_FINDINGS_PATH="$TEST_DIR/docs/grinder/deferred-findings.json" \
        bash "$GET_FINDINGS" ruff bash "$TEST_DIR/mock-ruff.sh" >/dev/null 2>&1
    after=$(ls "${TMPDIR:-/tmp}"/get-findings-* 2>/dev/null | wc -l | tr -d ' ')
    after=${after:-0}
    [ "$after" -le "$before" ] || return 1
}
check "TC-GF10: temp file cleanup on normal exit" tc_gf10


# =========================================================================
# TC-SC01: scanner-call-sites.md exists and is non-empty (REQ-9)
# =========================================================================
tc_sc01() {
    local doc="$REPO_DIR/docs/grinder/scanner-call-sites.md"
    [ -f "$doc" ] || return 1
    [ -s "$doc" ] || return 1
    grep -q "wrapped" "$doc" || return 1
    grep -q "not wrapped" "$doc" || return 1
    grep -q "grinder-internal" "$doc" || return 1
}
check "TC-SC01: scanner-call-sites.md exists with required sections" tc_sc01


# =========================================================================
# TC-IM01: implement.md references get-findings.sh for mypy (REQ-10)
# =========================================================================
tc_im01() {
    local count
    count=$(grep -c "get-findings.sh mypy" "$REPO_DIR/adapters/claude-code/claude/commands/implement.md" 2>/dev/null || true)
    [ "${count:-0}" -eq 1 ] || return 1
}
check "TC-IM01: implement.md has exactly 1 get-findings.sh mypy reference" tc_im01


# =========================================================================
# TC-IM02: implement.md references get-findings.sh for tsc (REQ-10)
# =========================================================================
tc_im02() {
    local count
    count=$(grep -c "get-findings.sh tsc" "$REPO_DIR/adapters/claude-code/claude/commands/implement.md" 2>/dev/null || true)
    [ "${count:-0}" -eq 1 ] || return 1
}
check "TC-IM02: implement.md has exactly 1 get-findings.sh tsc reference" tc_im02


# =========================================================================
# TC-IM03: implement.md auto-fix commands NOT wrapped (EC-10.1)
# =========================================================================
tc_im03() {
    # Lines with "ruff check --fix" or "ruff format" must not have get-findings.sh
    local wrapped_fixes
    wrapped_fixes=$(grep -E "(ruff check --fix|ruff format)" "$REPO_DIR/adapters/claude-code/claude/commands/implement.md" | grep -c "get-findings.sh" 2>/dev/null || true)
    [ "${wrapped_fixes:-0}" -eq 0 ] || return 1
}
check "TC-IM03: auto-fix commands NOT wrapped" tc_im03


# =========================================================================
# TC-SA01: static-analysis.md references get-findings.sh for mypy (REQ-11)
# =========================================================================
tc_sa01() {
    local count
    count=$(grep -c "get-findings.sh mypy" "$REPO_DIR/adapters/claude-code/claude/commands/static-analysis.md" 2>/dev/null || true)
    [ "${count:-0}" -eq 1 ] || return 1
}
check "TC-SA01: static-analysis.md has exactly 1 get-findings.sh mypy reference" tc_sa01


# =========================================================================
# TC-SA02: static-analysis.md SonarQube NOT wrapped (REQ-11.2)
# =========================================================================
tc_sa02() {
    local wrapped_sonar
    wrapped_sonar=$(grep "sonar-scanner" "$REPO_DIR/adapters/claude-code/claude/commands/static-analysis.md" | grep -c "get-findings.sh" 2>/dev/null || true)
    [ "${wrapped_sonar:-0}" -eq 0 ] || return 1
}
check "TC-SA02: sonar-scanner NOT wrapped" tc_sa02


# =========================================================================
# TC-CP01: commit-preflight.sh has no get-findings.sh references (REQ-12)
# =========================================================================
tc_cp01() {
    local count
    count=$(grep -c "get-findings.sh" "$REPO_DIR/adapters/claude-code/claude/tools/commit-preflight.sh" 2>/dev/null || true)
    [ "${count:-0}" -eq 0 ] || return 1
}
check "TC-CP01: commit-preflight.sh has zero get-findings.sh references" tc_cp01


# =========================================================================
# TC-CP02: commit-preflight.sh --test-cmd 'true' produces expected output
# =========================================================================
tc_cp02() {
    local stdout
    stdout=$(cd "$REPO_DIR" && bash "$REPO_DIR/adapters/claude-code/claude/tools/commit-preflight.sh" --test-cmd 'true' 2>/dev/null)
    local rc=$?
    [ "$rc" -eq 0 ] || return 1
    echo "$stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok') == True" || return 1
}
check "TC-CP02: commit-preflight.sh --test-cmd 'true' → JSON with ok:true" tc_cp02


# =========================================================================
# Summary
# =========================================================================
echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
