#!/usr/bin/env bash
# Test suite for assert_implement_committed_sources — the post-/implement
# guard that fails loud when the agent left source code uncommitted
# (canary D failure mode, 2026-05-24).
#
# Contract:
#   - Walks `git status --porcelain` in the worktree.
#   - Source files = anything NOT under docs/ AND NOT
#     autopilot-stdout.log or autopilot-summary.json (those belong to
#     the orchestrator).
#   - When any modified/untracked source file is found, the function
#     emits a loud error block listing every offender + returns
#     non-zero so the caller can fail_pipeline.
#   - When the worktree is clean (or only has doc/orchestrator
#     artefacts), returns 0 silently.
#
# Hermetic: builds synthetic git repos in $TMPDIR; never spawns claude
# or autopilot.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

PASS=0
FAIL=0
FAILED_NAMES=()
TMP_DIRS=()

cleanup_all() {
  local d
  for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup_all EXIT

new_repo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/asrtimp.XXXXXX")
  TMP_DIRS+=("$d")
  git -C "$d" init -q --template=''
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  : > "$d/initial"
  git -C "$d" add initial
  git -C "$d" commit -q -m initial
  echo "$d"
}

check() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "  FAIL: $name" >&2
  fi
}

# Helper: run the assertion in a subshell that sources the lib.
# Echoes stdout, returns the function's exit code.
call_assert() {
  local wt="$1"
  bash -c "
    set -uo pipefail
    source '$LIB' 2>/dev/null
    assert_implement_committed_sources '$wt'
  "
}

# ───── T1: function exists in the lib ─────
check "T1.1: assert_implement_committed_sources defined" \
  grep -qE '^assert_implement_committed_sources\(\)' "$LIB"

# ───── T2: clean worktree → exit 0, no output ─────
WT=$(new_repo)
out=$(call_assert "$WT" 2>&1)
ec=$?
check "T2.1: clean tree → exit 0" test "$ec" -eq 0
check "T2.2: clean tree → no stderr output" test -z "$out"

# ───── T3: only docs changes → exit 0 (orchestrator commit will pick up) ─────
WT=$(new_repo)
mkdir -p "$WT/docs/INPROGRESS_Feature_demo"
echo "PLAN content" > "$WT/docs/INPROGRESS_Feature_demo/PLAN.md"
echo "stdout log"   > "$WT/docs/INPROGRESS_Feature_demo/autopilot-stdout.log"
echo '{"x":1}'      > "$WT/docs/INPROGRESS_Feature_demo/autopilot-summary.json"
out=$(call_assert "$WT" 2>&1)
ec=$?
check "T3.1: only docs/INPROGRESS_Feature → exit 0" test "$ec" -eq 0

# ───── T4: untracked source file → exit non-zero + loud error ─────
WT=$(new_repo)
mkdir -p "$WT/adapters/claude-code/claude/tools"
echo "echo new code"   > "$WT/adapters/claude-code/claude/tools/autopilot.sh"
out=$(call_assert "$WT" 2>&1)
ec=$?
check "T4.1: untracked source file → exit non-zero" test "$ec" -ne 0
check "T4.2: error names the offender" grep -q "autopilot.sh" <<<"$out"
check "T4.3: error mentions 'uncommitted'" grep -qi "uncommitted\|not committed\|committing" <<<"$out"

# ───── T5: modified-but-not-committed source file → exit non-zero ─────
WT=$(new_repo)
mkdir -p "$WT/tests"
echo "first"  > "$WT/tests/test_foo.sh"
git -C "$WT" add tests/test_foo.sh
git -C "$WT" commit -q -m "feat: add test"
echo "modified" >> "$WT/tests/test_foo.sh"
out=$(call_assert "$WT" 2>&1)
ec=$?
check "T5.1: modified source file → exit non-zero" test "$ec" -ne 0
check "T5.2: error names the modified file" grep -q "test_foo.sh" <<<"$out"

# ───── T6: mix of docs + source — must still fail (source is what matters) ─────
WT=$(new_repo)
mkdir -p "$WT/docs/INPROGRESS_Feature_demo" "$WT/adapters/claude-code/claude/tools"
echo "REQ"            > "$WT/docs/INPROGRESS_Feature_demo/REQUIREMENTS.md"
echo "echo prod"      > "$WT/adapters/claude-code/claude/tools/autopilot.sh"
out=$(call_assert "$WT" 2>&1)
ec=$?
check "T6.1: docs + source mix → exit non-zero (source dominates)" \
  test "$ec" -ne 0
check "T6.2: error lists the source file, not the docs" \
  bash -c "grep -q 'autopilot.sh' <<<\"\$0\"" "$out"

# ───── T7: orchestrator artefacts (autopilot-stdout.log,
# autopilot-summary.json) are NEVER considered source even outside
# docs/ (they could end up in worktree root from an old run).
# ─────────────────────────────────────────────────────────────────────
WT=$(new_repo)
echo "stdout"     > "$WT/autopilot-stdout.log"
echo '{"x":1}'    > "$WT/autopilot-summary.json"
out=$(call_assert "$WT" 2>&1)
ec=$?
check "T7.1: orchestrator artefacts ignored even at worktree root" \
  test "$ec" -eq 0

# ───── T8: .planning/ markers are orchestrator state, must be ignored ─────
WT=$(new_repo)
mkdir -p "$WT/.planning"
echo '{"task":"x"}' > "$WT/.planning/active-x.json"
out=$(call_assert "$WT" 2>&1)
ec=$?
check "T8.1: .planning/ markers ignored" test "$ec" -eq 0

# ───── T9: tests/ directory IS source — tests are part of the feature ─────
WT=$(new_repo)
mkdir -p "$WT/tests"
echo "test code" > "$WT/tests/test_new_feature.sh"
out=$(call_assert "$WT" 2>&1)
ec=$?
check "T9.1: untracked test file → exit non-zero" test "$ec" -ne 0
check "T9.2: error names the test file" grep -q "test_new_feature.sh" <<<"$out"

# ───── Final ─────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  for n in "${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"}"; do
    echo "  - $n" >&2
  done
  exit 1
fi
exit 0
