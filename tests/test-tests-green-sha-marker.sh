#!/usr/bin/env bash
# test-tests-green-sha-marker.sh — TDD suite for the `.tests-green-sha`
# marker contract introduced by the workflow-optimization plan
# (Change 3: rename `.qa-passed-sha` → `.tests-green-sha`; written by
# /implement, /qa, and /static-analysis at the end of any green pass;
# read by commit-preflight.sh to skip the redundant full-suite rerun).
#
# Coverage:
#   T1   — commit-preflight.sh greps for the new marker name
#   T2   — when HEAD == marker_sha, preflight reports tests skipped
#   T3   — when diff since marker is docs/markdown only, tests skipped
#   T4   — when diff since marker is purely `fix(<scope>): resolve static
#          analysis findings` commits, tests skipped (NEW behavior — closes
#          the loop where /static-analysis commits move HEAD past the marker)
#   T5   — when diff since marker has unrelated code, tests run
#   T6   — when no marker exists, tests run (unchanged baseline)
#   T7   — COMMIT_PREFLIGHT_FORCE_TESTS=1 bypasses skip optimization
#   T8   — .gitignore tracks the new marker name (not the old one)
#   T9   — /qa command file writes the new marker name
#   T10  — /implement command file writes the marker at the end of Step 5
#   T11  — /static-analysis command file writes the marker after fix loop
#
# M-tests (meta):
#   M1   — test file is executable
#   M2   — at least 11 numbered tests defined (lower bound; prevents
#          accidental removal of coverage)
#
# Usage: bash tests/test-tests-green-sha-marker.sh
# Exits 0 on all-pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREFLIGHT="$REPO_DIR/adapters/claude-code/claude/tools/commit-preflight.sh"
QA_MD="$REPO_DIR/adapters/claude-code/claude/commands/qa.md"
IMPLEMENT_MD="$REPO_DIR/adapters/claude-code/claude/commands/implement.md"
STATIC_MD="$REPO_DIR/adapters/claude-code/claude/commands/static-analysis.md"
GITIGNORE="$REPO_DIR/.gitignore"

# Boundary-safe temp root: live under $TMPDIR or /tmp (sandbox writable).
TEST_DIR="${TMPDIR:-/tmp}/test-tests-green-sha-marker-$$"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

passed=0
failed=0
ran=0

setup() {
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

trap 'teardown' EXIT

pass() {
  passed=$((passed + 1))
  ran=$((ran + 1))
  echo -e "${GREEN}✓${NC} $1"
}

fail() {
  failed=$((failed + 1))
  ran=$((ran + 1))
  echo -e "${RED}✗${NC} $1"
  [[ -n "${2:-}" ]] && echo -e "    ${YELLOW}$2${NC}"
}

# Build a minimal git repo that looks like a feature worktree:
#   - main branch with one initial commit
#   - feature branch with N additional commits
#   - docs/INPROGRESS_Feature_test/ directory
# Optionally writes the marker file with the given SHA.
build_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test User"
    mkdir -p docs/INPROGRESS_Feature_test
    echo "initial" > README.md
    git add README.md
    git commit -q -m "init"
    git checkout -q -b feature/test
    # Add a test runner that exits 0 (so a non-skipped path would still succeed
    # — but our assertions look for the skip-reason text, not exit status).
    mkdir -p scripts
    cat > scripts/run_tests.sh <<'EOSH'
#!/usr/bin/env bash
echo "TESTS_RAN_MARKER"
exit 0
EOSH
    chmod +x scripts/run_tests.sh
    echo "code" > src.py
    git add scripts/run_tests.sh src.py
    git commit -q -m "feat: initial impl"
  )
}

run_preflight_in() {
  local repo="$1"
  local extra_env="${2:-}"
  (
    cd "$repo"
    if [[ -n "$extra_env" ]]; then
      env $extra_env bash "$PREFLIGHT" --test-cmd ./scripts/run_tests.sh 2>/dev/null
    else
      bash "$PREFLIGHT" --test-cmd ./scripts/run_tests.sh 2>/dev/null
    fi
  )
}

# ── T1: commit-preflight.sh greps for the new marker name ──
setup
if grep -q '\.tests-green-sha' "$PREFLIGHT"; then
  pass "T1: commit-preflight.sh references .tests-green-sha"
else
  fail "T1: commit-preflight.sh references .tests-green-sha" \
       "expected to find '.tests-green-sha' in $PREFLIGHT"
fi
if grep -q '\.qa-passed-sha' "$PREFLIGHT"; then
  fail "T1b: commit-preflight.sh no longer references .qa-passed-sha" \
       "old marker name still present in $PREFLIGHT"
else
  pass "T1b: commit-preflight.sh no longer references .qa-passed-sha"
fi

# ── T2: HEAD == marker_sha → tests skipped ──
setup
REPO="$TEST_DIR/repo-t2"
build_repo "$REPO"
(
  cd "$REPO"
  git rev-parse HEAD > docs/INPROGRESS_Feature_test/.tests-green-sha
)
out=$(run_preflight_in "$REPO")
if echo "$out" | grep -q '"tests_passed": *true'; then
  pass "T2a: tests_passed=true when HEAD == marker_sha"
else
  fail "T2a: tests_passed=true when HEAD == marker_sha" "got: $out"
fi
if echo "$out" | grep -qi 'tests skipped'; then
  pass "T2b: skip reason emitted when HEAD == marker_sha"
else
  fail "T2b: skip reason emitted when HEAD == marker_sha" "got: $out"
fi
# Test runner must NOT have been invoked
if echo "$out" | grep -q 'TESTS_RAN_MARKER'; then
  fail "T2c: test runner not invoked when skipping" "got: $out"
else
  pass "T2c: test runner not invoked when skipping"
fi

# ── T3: diff since marker is docs/markdown only → tests skipped ──
setup
REPO="$TEST_DIR/repo-t3"
build_repo "$REPO"
(
  cd "$REPO"
  git rev-parse HEAD > docs/INPROGRESS_Feature_test/.tests-green-sha
  # Add a doc-only commit AFTER the marker SHA
  echo "more docs" > docs/notes.md
  git add docs/notes.md
  git commit -q -m "docs(test): add notes"
)
out=$(run_preflight_in "$REPO")
if echo "$out" | grep -q '"tests_passed": *true' && echo "$out" | grep -qi 'docs.*markdown.*skipped'; then
  pass "T3: docs-only diff since marker → tests skipped"
else
  fail "T3: docs-only diff since marker → tests skipped" "got: $out"
fi

# ── T4: diff since marker is purely fix-static-analysis commits → tests skipped (NEW) ──
setup
REPO="$TEST_DIR/repo-t4"
build_repo "$REPO"
(
  cd "$REPO"
  git rev-parse HEAD > docs/INPROGRESS_Feature_test/.tests-green-sha
  # Two follow-up commits that match the static-analysis fix-loop pattern
  echo "code v2" > src.py
  git add src.py
  git commit -q -m "fix(test): resolve static analysis findings"
  echo "code v3" > src.py
  git add src.py
  git commit -q -m "fix(test): resolve static analysis findings"
)
out=$(run_preflight_in "$REPO")
if echo "$out" | grep -q '"tests_passed": *true' && echo "$out" | grep -qiE 'static.analysis.*skipped|skipped.*static.analysis'; then
  pass "T4: purely static-analysis fix commits → tests skipped"
else
  fail "T4: purely static-analysis fix commits → tests skipped" \
       "expected skip reason mentioning static-analysis. got: $out"
fi

# ── T5: unrelated code changes since marker → tests run ──
setup
REPO="$TEST_DIR/repo-t5"
build_repo "$REPO"
(
  cd "$REPO"
  git rev-parse HEAD > docs/INPROGRESS_Feature_test/.tests-green-sha
  # An unrelated feature commit (not a fix-static-analysis pattern)
  echo "new feature" > src.py
  git add src.py
  git commit -q -m "feat(test): add unrelated functionality"
)
out=$(run_preflight_in "$REPO")
if echo "$out" | grep -q 'TESTS_RAN_MARKER'; then
  pass "T5: unrelated code changes since marker → tests run"
else
  fail "T5: unrelated code changes since marker → tests run" \
       "expected runner to have executed. got: $out"
fi

# ── T6: no marker → tests run (baseline) ──
setup
REPO="$TEST_DIR/repo-t6"
build_repo "$REPO"
# Do NOT write any marker
out=$(run_preflight_in "$REPO")
if echo "$out" | grep -q 'TESTS_RAN_MARKER'; then
  pass "T6: no marker → tests run"
else
  fail "T6: no marker → tests run" "got: $out"
fi

# ── T7: COMMIT_PREFLIGHT_FORCE_TESTS=1 bypasses skip ──
setup
REPO="$TEST_DIR/repo-t7"
build_repo "$REPO"
(
  cd "$REPO"
  git rev-parse HEAD > docs/INPROGRESS_Feature_test/.tests-green-sha
)
out=$(run_preflight_in "$REPO" "COMMIT_PREFLIGHT_FORCE_TESTS=1")
if echo "$out" | grep -q 'TESTS_RAN_MARKER'; then
  pass "T7: COMMIT_PREFLIGHT_FORCE_TESTS=1 → tests run even with marker"
else
  fail "T7: COMMIT_PREFLIGHT_FORCE_TESTS=1 → tests run even with marker" "got: $out"
fi

# ── T8: .gitignore tracks new marker name (not old) ──
if grep -qE '\.tests-green-sha' "$GITIGNORE"; then
  pass "T8a: .gitignore tracks .tests-green-sha"
else
  fail "T8a: .gitignore tracks .tests-green-sha" \
       "expected '.tests-green-sha' in $GITIGNORE"
fi
if grep -qE '^docs/INPROGRESS_Feature_\*/\.qa-passed-sha$' "$GITIGNORE"; then
  fail "T8b: .gitignore no longer tracks .qa-passed-sha" \
       "old marker name still gitignored — should be removed or replaced"
else
  pass "T8b: .gitignore no longer tracks .qa-passed-sha"
fi

# ── T9: /qa command file writes the new marker name ──
if grep -q '\.tests-green-sha' "$QA_MD"; then
  pass "T9a: qa.md writes .tests-green-sha"
else
  fail "T9a: qa.md writes .tests-green-sha" \
       "expected '.tests-green-sha' write instruction in $QA_MD"
fi
if grep -q '\.qa-passed-sha' "$QA_MD"; then
  fail "T9b: qa.md no longer mentions .qa-passed-sha"
else
  pass "T9b: qa.md no longer mentions .qa-passed-sha"
fi

# ── T10: /implement command file writes the marker after Step 5 ──
if grep -q '\.tests-green-sha' "$IMPLEMENT_MD"; then
  pass "T10: implement.md writes .tests-green-sha"
else
  fail "T10: implement.md writes .tests-green-sha" \
       "expected '.tests-green-sha' write instruction in $IMPLEMENT_MD"
fi

# ── T11: /static-analysis command file writes the marker after fix loop ──
if grep -q '\.tests-green-sha' "$STATIC_MD"; then
  pass "T11: static-analysis.md writes .tests-green-sha"
else
  fail "T11: static-analysis.md writes .tests-green-sha" \
       "expected '.tests-green-sha' write instruction in $STATIC_MD"
fi

# ── M-tests ──
# M1: this file is executable
if [[ -x "$0" ]]; then
  pass "M1: test file is executable"
else
  fail "M1: test file is executable" "chmod +x $0"
fi

# M2: at least 11 numbered tests defined
test_count=$(grep -cE '^# ── T[0-9]+' "$0")
if [[ $test_count -ge 11 ]]; then
  pass "M2: ≥11 numbered tests defined ($test_count)"
else
  fail "M2: ≥11 numbered tests defined" "found $test_count"
fi

# ── Summary ──
echo
echo "─────────────────────────────────────────"
echo -e "Ran: $ran  ${GREEN}Passed: $passed${NC}  ${RED}Failed: $failed${NC}"
echo "─────────────────────────────────────────"

if [[ $failed -gt 0 ]]; then
  exit 1
fi
exit 0
