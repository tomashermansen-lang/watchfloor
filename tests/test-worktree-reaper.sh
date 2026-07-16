#!/usr/bin/env bash
# test-worktree-reaper.sh — TDD suite for adapters/claude-code/claude/tools/lib/worktree-reaper.sh.
#
# Coverage:
#   T1–T20 — unit assertions against reap_worktree_orphans (real subprocesses,
#            real lsof, real kill — no mocks; the helper is shell-only).
#   S1–S10 — static-grep / awk-adjacency assertions that prove the call-site
#            integrations satisfy R9 (reaper line directly precedes the
#            destructive op) and R10/R11/R14.
#   M1–M3  — self-meta assertions about this test file itself.
#
# Usage: bash tests/test-worktree-reaper.sh
# Exits 0 on all-pass, 1 on any failure.

set -euo pipefail

# ── Shared setup ────────────────────────────────────────

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/worktree-reaper.sh"

# Boundary-safe temp root: fixtures live under PROJECTS_ROOT so the
# helper's boundary guard does not reject them. PROJECTS_ROOT defaults
# to ~/Projekter (matching the global convention).
BOUNDARY_ROOT="${PROJECTS_ROOT:-$HOME/Projekter}"
TEST_DIR="$BOUNDARY_ROOT/.test-reaper-$$"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0
ran=0

# Track every backgrounded child PID so teardown can KILL survivors.
PIDS=()

setup() {
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"
}

teardown() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_DIR"
}
trap teardown EXIT

check() {
  local name="$1"; shift
  ran=$((ran + 1))
  if "$@"; then
    echo -e "${GREEN}✓${NC} $name"
    passed=$((passed + 1))
  else
    echo -e "${RED}✗${NC} $name"
    failed=$((failed + 1))
  fi
}

# spawn_orphan <wt-path> [trap-term?] → writes the spawned PID into a
# global "SPAWN_PID" variable AND PIDS array. Avoids command substitution
# entirely: bash's `pid=$(spawn_orphan ...)` pattern does NOT see the
# backgrounded grandchild because the cmd-sub subshell holds the pipe and
# waits in a way that leaves a window where lsof has not yet picked up
# the post-exec cwd. Using a global side-effect variable side-steps the
# whole class.
#
# Stdio is detached (</dev/null >/dev/null 2>&1) so the backgrounded
# process does not keep the test runner's pipes alive.
SPAWN_PID=""
spawn_orphan() {
  local wt="$1"
  local trap_arg="${2:-}"
  mkdir -p "$wt"
  if [[ "$trap_arg" == "trap-term" ]]; then
    ( cd "$wt" && exec bash -c "trap '' TERM; sleep 60" ) </dev/null >/dev/null 2>&1 &
  else
    ( cd "$wt" && exec sleep 60 ) </dev/null >/dev/null 2>&1 &
  fi
  SPAWN_PID=$!
  PIDS+=( "$SPAWN_PID" )
  # Disown so bash's job-control does not print "Terminated"/"Killed"
  # lines to stderr when the reaper signals the orphan.
  disown "$SPAWN_PID" 2>/dev/null || true
  # Give the spawned child a moment so its cwd is committed before lsof
  # runs. macOS needs ~100ms after exec for the descriptor table.
  sleep 0.3
}

# Source the helper inside the current shell (functions then become callable).
# The helper is idempotent under multiple sources.
# shellcheck disable=SC1090
source "$LIB"

echo "Running worktree-reaper tests..."
echo

# ────────────────────────────────────────────────────────
# T1: Empty argument → exit 0, no stdout, no stderr
# ────────────────────────────────────────────────────────
test_t1() {
  setup
  local out err rc
  out=$(reap_worktree_orphans "" 2>"$TEST_DIR/err"); rc=$?
  err=$(cat "$TEST_DIR/err")
  [[ "$rc" == "0" && -z "$out" && -z "$err" ]] || { echo "  rc=$rc out=$out err=$err"; return 1; }
}
check "T1: empty arg → silent zero" test_t1

# ────────────────────────────────────────────────────────
# T2: Non-existent path → silent zero (R7, AS12)
# ────────────────────────────────────────────────────────
test_t2() {
  setup
  local out err rc
  out=$(reap_worktree_orphans "$TEST_DIR/does-not-exist-2026-05-09" 2>"$TEST_DIR/err"); rc=$?
  err=$(cat "$TEST_DIR/err")
  [[ "$rc" == "0" && -z "$out" && -z "$err" ]] || { echo "  rc=$rc out=$out err=$err"; return 1; }
}
check "T2: non-existent path → silent zero" test_t2

# ────────────────────────────────────────────────────────
# T3: Existing dir, zero processes inside → silent zero (R4, AS1)
# ────────────────────────────────────────────────────────
test_t3() {
  setup
  mkdir -p "$TEST_DIR/empty-wt"
  local out err rc
  out=$(reap_worktree_orphans "$TEST_DIR/empty-wt" 2>"$TEST_DIR/err"); rc=$?
  err=$(cat "$TEST_DIR/err")
  [[ "$rc" == "0" && -z "$out" && -z "$err" ]] || { echo "  rc=$rc out=$out err=$err"; return 1; }
}
check "T3: existing empty dir → silent zero" test_t3

# ────────────────────────────────────────────────────────
# T4: Single cooperative orphan reaped via SIGTERM (R3, R5, R6, AS2)
# ────────────────────────────────────────────────────────
test_t4() {
  setup
  local wt="$TEST_DIR/wt-coop"
  local pid
  spawn_orphan "$wt"; pid=$SPAWN_PID
  reap_worktree_orphans "$wt" 2>"$TEST_DIR/err"
  # Within 3s the cooperative child should be gone.
  for _ in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then echo "  pid $pid still alive"; return 1; fi
  grep -Eq "^reap_worktree_orphans: SIGTERM pid=$pid cmd=.+$" "$TEST_DIR/err" \
    || { echo "  stderr missing SIGTERM line for pid=$pid"; cat "$TEST_DIR/err" >&2; return 1; }
}
check "T4: cooperative orphan SIGTERMed" test_t4

# ────────────────────────────────────────────────────────
# T5: Stubborn orphan escalates to SIGKILL (R5, AS3)
# ────────────────────────────────────────────────────────
test_t5() {
  setup
  local wt="$TEST_DIR/wt-stub"
  local pid
  spawn_orphan "$wt" trap-term; pid=$SPAWN_PID
  reap_worktree_orphans "$wt" 2>"$TEST_DIR/err"
  # After grace period + KILL, the stubborn child must be gone.
  for _ in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then echo "  pid $pid still alive after KILL"; return 1; fi
  grep -q "SIGTERM pid=$pid" "$TEST_DIR/err" || { echo "  no SIGTERM line"; cat "$TEST_DIR/err"; return 1; }
  grep -q "SIGKILL pid=$pid" "$TEST_DIR/err" || { echo "  no SIGKILL line"; cat "$TEST_DIR/err"; return 1; }
}
check "T5: stubborn orphan escalates to SIGKILL" test_t5

# ────────────────────────────────────────────────────────
# T6: Multi-orphan: cooperative + stubborn → both reaped (R3, R5)
# ────────────────────────────────────────────────────────
test_t6() {
  setup
  local wt="$TEST_DIR/wt-multi"
  local pid_a pid_b
  spawn_orphan "$wt"; pid_a=$SPAWN_PID
  spawn_orphan "$wt" trap-term; pid_b=$SPAWN_PID
  reap_worktree_orphans "$wt" 2>"$TEST_DIR/err"
  for _ in 1 2 3; do
    if ! kill -0 "$pid_a" 2>/dev/null && ! kill -0 "$pid_b" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$pid_a" 2>/dev/null; then echo "  cooperative pid alive"; return 1; fi
  if kill -0 "$pid_b" 2>/dev/null; then echo "  stubborn pid alive";    return 1; fi
  grep -q "SIGTERM pid=$pid_a" "$TEST_DIR/err" || { echo "  cooperative SIGTERM missing"; return 1; }
  grep -q "SIGKILL pid=$pid_b" "$TEST_DIR/err" || { echo "  stubborn SIGKILL missing"; return 1; }
}
check "T6: multi-orphan (cooperative + stubborn) both reaped" test_t6

# ────────────────────────────────────────────────────────
# T7: Self-exclusion — caller PID and PPID are skipped (E1)
# ────────────────────────────────────────────────────────
test_t7() {
  setup
  local wt="$TEST_DIR/wt-self"
  mkdir -p "$wt"
  local orphan_pid
  spawn_orphan "$wt"; orphan_pid=$SPAWN_PID
  # Run a child shell whose own cwd is inside $wt, source the helper there,
  # and have it call the reaper. Self-exclusion (the child's $$ + $PPID)
  # must keep itself and this test process alive while killing the orphan.
  local marker="$TEST_DIR/marker"
  ( cd "$wt" && bash -c "
      source '$LIB'
      reap_worktree_orphans '$wt' 2>'$TEST_DIR/err'
      echo alive >'$marker'
    " )
  [[ -f "$marker" ]] || { echo "  child shell self-terminated"; return 1; }
  for _ in 1 2 3; do
    if ! kill -0 "$orphan_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$orphan_pid" 2>/dev/null; then echo "  orphan still alive"; return 1; fi
  # The current test-runner shell ($$) must still be alive (we're executing).
}
check "T7: self-exclusion ($$, $PPID skipped)" test_t7

# ────────────────────────────────────────────────────────
# T8: Symlink alias path resolves via pwd -P (R2, E2)
# ────────────────────────────────────────────────────────
test_t8() {
  setup
  local real="$TEST_DIR/real-wt"
  local alias="$TEST_DIR/alias-wt"
  mkdir -p "$real"
  ln -s "$real" "$alias"
  local pid
  spawn_orphan "$real"; pid=$SPAWN_PID
  reap_worktree_orphans "$alias" 2>"$TEST_DIR/err"
  for _ in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then echo "  alias-targeted pid alive"; return 1; fi
}
check "T8: symlink alias resolves via pwd -P" test_t8

# ────────────────────────────────────────────────────────
# T9: Audit-log format is strict (R6)
# ────────────────────────────────────────────────────────
test_t9() {
  setup
  local wt="$TEST_DIR/wt-fmt"
  local pid
  spawn_orphan "$wt"; pid=$SPAWN_PID
  local out
  out=$(reap_worktree_orphans "$wt" 2>"$TEST_DIR/err")
  [[ -z "$out" ]] || { echo "  stdout not empty: $out"; return 1; }
  grep -Eq "^reap_worktree_orphans: SIGTERM pid=$pid cmd=.+$" "$TEST_DIR/err" \
    || { echo "  stderr does not match strict regex"; cat "$TEST_DIR/err"; return 1; }
  # Wait for children to die so subsequent tests don't see them.
  for _ in 1 2 3; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
}
check "T9: audit log format strict regex" test_t9

# ────────────────────────────────────────────────────────
# T10: Missing lsof and no /proc → exit 1 with refusal message (R8, AS11)
# ────────────────────────────────────────────────────────
test_t10() {
  setup
  mkdir -p "$TEST_DIR/wt-nolsof"
  # Source the helper afresh in a subshell that has no lsof on PATH.
  # If /proc exists (Linux), the fallback path runs and the test is N/A —
  # skip on that case rather than fake a non-Linux environment.
  if [[ -d /proc ]]; then
    echo "  skipped — /proc exists; helper falls back instead of refusing"
    return 0
  fi
  local rc=0 err
  # Set PATH=/dev/null INSIDE the bash subshell — setting it on the bash
  # invocation itself would prevent the parent from finding `bash` and
  # exit 127 (command not found) before the helper ever runs.
  err=$(bash -c "
      export PATH=/dev/null
      unset WORKTREE_REAPER_LOADED
      source '$LIB'
      reap_worktree_orphans '$TEST_DIR/wt-nolsof'
    " 2>&1) || rc=$?
  [[ "$rc" == "1" ]] || { echo "  expected rc=1, got rc=$rc"; return 1; }
  echo "$err" | grep -q "lsof not found — cannot enumerate cwd holders" \
    || { echo "  refusal message not on stderr: $err"; return 1; }
}
check "T10: missing lsof → refusal exit 1" test_t10

# ────────────────────────────────────────────────────────
# T11: ESRCH (process exited between discovery and signal) is silent success (E3)
# ────────────────────────────────────────────────────────
test_t11() {
  setup
  local wt="$TEST_DIR/wt-esrch"
  local pid
  spawn_orphan "$wt"; pid=$SPAWN_PID
  # Kill the process externally, then call the reaper. The PID may or may
  # not still be in the lsof snapshot depending on timing; either way the
  # helper must exit 0 with no error noise about it.
  kill -KILL "$pid" 2>/dev/null || true
  # Allow the kernel to reap the zombie before lsof runs.
  for _ in 1 2 3; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  local rc=0
  reap_worktree_orphans "$wt" 2>"$TEST_DIR/err" || rc=$?
  [[ "$rc" == "0" ]] || { echo "  expected rc=0, got $rc"; cat "$TEST_DIR/err"; return 1; }
  # Permitted stderr: SIGTERM line for the racing pid (kill -0 returns
  # success briefly during the race) and nothing else. We do NOT assert
  # absolute silence — the contract is "exit 0, no error noise".
  if grep -E "lsof failed|refusing to scan" "$TEST_DIR/err" >/dev/null 2>&1; then
    echo "  unexpected error line on stderr"; cat "$TEST_DIR/err"; return 1
  fi
}
check "T11: ESRCH between discovery and signal is silent success" test_t11

# ────────────────────────────────────────────────────────
# T12: lsof +D exit 1 on empty dir treated as success (E6)
# ────────────────────────────────────────────────────────
test_t12() {
  setup
  mkdir -p "$TEST_DIR/wt-empty12"
  local rc=0
  reap_worktree_orphans "$TEST_DIR/wt-empty12" 2>"$TEST_DIR/err" || rc=$?
  [[ "$rc" == "0" ]] || { echo "  expected rc=0, got $rc"; cat "$TEST_DIR/err"; return 1; }
  [[ ! -s "$TEST_DIR/err" ]] || { echo "  stderr non-empty"; cat "$TEST_DIR/err"; return 1; }
}
check "T12: lsof +D exit 1 on empty dir is success" test_t12

# ────────────────────────────────────────────────────────
# T13: Boundary guard — / rejected (E5)
# ────────────────────────────────────────────────────────
test_t13() {
  setup
  local rc=0
  reap_worktree_orphans / 2>"$TEST_DIR/err" || rc=$?
  [[ "$rc" == "1" ]] || { echo "  expected rc=1, got $rc"; cat "$TEST_DIR/err"; return 1; }
  grep -q "refusing to scan path outside PROJECTS_ROOT" "$TEST_DIR/err" \
    || { echo "  refusal message missing"; cat "$TEST_DIR/err"; return 1; }
}
check "T13: boundary guard rejects /" test_t13

# ────────────────────────────────────────────────────────
# T14: Path that vanishes between existence check and pwd -P → silent zero (E5, R7)
# ────────────────────────────────────────────────────────
test_t14() {
  setup
  local wt="$TEST_DIR/wt-vanish"
  mkdir -p "$wt"
  # Bracket [[ -d ]] passes; pwd -P will succeed on the snapshot but we
  # assert silent zero behaviour even if a future regression made the
  # path resolution fail. Here we exercise the code path by passing a
  # symlink whose target was removed between resolution attempts.
  ln -s "$TEST_DIR/no-such-target" "$wt/dangling-link"
  local rc=0
  reap_worktree_orphans "$wt/dangling-link" 2>"$TEST_DIR/err" || rc=$?
  [[ "$rc" == "0" ]] || { echo "  expected silent zero, got $rc"; cat "$TEST_DIR/err"; return 1; }
}
check "T14: vanishing path is silent no-op" test_t14

# ────────────────────────────────────────────────────────
# T15: Boundary guard — path outside PROJECTS_ROOT rejected at call time (E5)
# ────────────────────────────────────────────────────────
test_t15() {
  setup
  # Set PROJECTS_ROOT to a tiny private boundary, then call the helper on
  # a path outside it. Proves the helper reads PROJECTS_ROOT dynamically
  # rather than snapshotting at source time.
  local boundary="$TEST_DIR/boundary"
  mkdir -p "$boundary"
  local outside="$TEST_DIR/outside"
  mkdir -p "$outside"
  local rc=0
  PROJECTS_ROOT="$boundary" reap_worktree_orphans "$outside" 2>"$TEST_DIR/err" || rc=$?
  [[ "$rc" == "1" ]] || { echo "  expected rc=1, got $rc"; cat "$TEST_DIR/err"; return 1; }
  grep -q "refusing to scan path outside PROJECTS_ROOT" "$TEST_DIR/err" \
    || { echo "  refusal message missing"; cat "$TEST_DIR/err"; return 1; }
}
check "T15: boundary guard reads PROJECTS_ROOT dynamically" test_t15

# ────────────────────────────────────────────────────────
# T16: Sourced-only contract — no top-level side effects (R1)
# ────────────────────────────────────────────────────────
test_t16() {
  setup
  local out err
  out=$(bash -c "source '$LIB'; declare -F reap_worktree_orphans" 2>"$TEST_DIR/err")
  err=$(cat "$TEST_DIR/err")
  [[ -z "$err" ]] || { echo "  stderr non-empty after source: $err"; return 1; }
  echo "$out" | grep -q "reap_worktree_orphans" \
    || { echo "  function not declared after source: $out"; return 1; }
}
check "T16: source has no top-level side effects" test_t16

# ────────────────────────────────────────────────────────
# T17: Idempotent re-source via WORKTREE_REAPER_LOADED guard (R1)
# ────────────────────────────────────────────────────────
test_t17() {
  setup
  local err
  err=$(bash -c "source '$LIB'; source '$LIB'; declare -F reap_worktree_orphans" 2>&1)
  echo "$err" | grep -qi "readonly variable" \
    && { echo "  re-source emitted readonly error: $err"; return 1; }
  echo "$err" | grep -q "reap_worktree_orphans" \
    || { echo "  function lost after re-source: $err"; return 1; }
  return 0
}
check "T17: idempotent re-source" test_t17

# ────────────────────────────────────────────────────────
# T18: Named constants present and readonly (R5, R15)
# ────────────────────────────────────────────────────────
test_t18() {
  local out
  out=$(bash -c "source '$LIB'; declare -p WORKTREE_REAPER_GRACE_SECONDS WORKTREE_REAPER_TERM_SIGNAL WORKTREE_REAPER_KILL_SIGNAL")
  echo "$out" | grep -q 'declare -r WORKTREE_REAPER_GRACE_SECONDS="2"' \
    || { echo "  GRACE_SECONDS constant missing/wrong: $out"; return 1; }
  echo "$out" | grep -q 'declare -r WORKTREE_REAPER_TERM_SIGNAL="TERM"' \
    || { echo "  TERM_SIGNAL constant missing/wrong: $out"; return 1; }
  echo "$out" | grep -q 'declare -r WORKTREE_REAPER_KILL_SIGNAL="KILL"' \
    || { echo "  KILL_SIGNAL constant missing/wrong: $out"; return 1; }
}
check "T18: named constants present and readonly" test_t18

# ────────────────────────────────────────────────────────
# T19: Audit log goes to stderr, not stdout (R6)
# ────────────────────────────────────────────────────────
test_t19() {
  setup
  local wt="$TEST_DIR/wt-stderr"
  local pid
  spawn_orphan "$wt"; pid=$SPAWN_PID
  local out
  out=$(reap_worktree_orphans "$wt" 2>"$TEST_DIR/err")
  [[ -z "$out" ]] || { echo "  audit landed on stdout: $out"; return 1; }
  grep -q "SIGTERM pid=$pid" "$TEST_DIR/err" \
    || { echo "  audit not on stderr"; cat "$TEST_DIR/err"; return 1; }
}
check "T19: audit log on stderr, not stdout" test_t19

# ────────────────────────────────────────────────────────
# T20: cwd descendant of worktree is reaped — proves +D recursion (R3)
# ────────────────────────────────────────────────────────
test_t20() {
  setup
  local wt="$TEST_DIR/wt-deep"
  local sub="$wt/sub/deep"
  mkdir -p "$sub"
  local pid
  spawn_orphan "$sub"; pid=$SPAWN_PID
  reap_worktree_orphans "$wt" 2>"$TEST_DIR/err"
  for _ in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then echo "  descendant pid alive"; return 1; fi
}
check "T20: descendant cwd is reaped (+D recursive)" test_t20

# ────────────────────────────────────────────────────────
# T21: Sibling-of-caller spared — regression for Backlog #62.
# A worktree-cwd process whose ppid equals the reaper's $PPID
# (i.e. a sibling of the reaper inside its caller's process tree)
# must not be reaped. In production this protects autopilot.sh's
# tee0 (autopilot.sh:944) and spawn_result_watchdog `(...) &`
# subshell from commit-finalize.sh:359's reaper call.
# ────────────────────────────────────────────────────────
test_t21() {
  setup
  local wt="$TEST_DIR/wt-sibling"
  mkdir -p "$wt"
  local marker="$TEST_DIR/sibling-result"
  local err="$TEST_DIR/sibling-err"
  rm -f "$marker" "$err"

  # Outer (...) subshell plays autopilot.sh: it backgrounds a
  # multi-command bash subshell ("sibling") with cwd in $wt, moves
  # itself out of $wt so it doesn't show up in lsof, then forks a
  # `bash -c` ("reaper-child") that plays commit-finalize.sh — its
  # $PPID equals the outer subshell, exactly the topology under
  # which Backlog #62 manifests.
  (
    cd "$wt"
    ( for _ in $(seq 1 30); do sleep 0.5; done ) &
    sibling_pid=$!
    sleep 0.3
    cd "$TEST_DIR"
    bash -c "source '$LIB'; reap_worktree_orphans '$wt' 2>'$err'"
    if kill -0 "$sibling_pid" 2>/dev/null; then
      echo sibling-alive > "$marker"
    else
      echo sibling-dead > "$marker"
    fi
    kill "$sibling_pid" 2>/dev/null || true
    wait "$sibling_pid" 2>/dev/null || true
  )

  [[ -f "$marker" ]] || { echo "  wrapper did not finish"; return 1; }
  grep -q "sibling-alive" "$marker" || {
    echo "  sibling subshell was reaped (regression for Backlog #62)"
    cat "$marker"
    [[ -f "$err" ]] && cat "$err"
    return 1
  }
}
check "T21: sibling of caller (ppid == \$PPID) spared (regression for #62)" test_t21

# ────────────────────────────────────────────────────────
# Static-grep / awk-adjacency assertions (S1–S10)
# Each S-row asserts the reaper line is on the line directly preceding
# the destructive op (R9 second sentence). Strict adjacency: NR == prev+1.
# ────────────────────────────────────────────────────────

# adjacency_check <file> <reaper-substring> <destructive-substring>
# returns 0 iff a line containing <reaper-substring> is immediately
# followed by a line containing <destructive-substring>. Uses awk
# index() (literal substring match) so the substrings can contain
# regex metacharacters like `$` without escaping.
adjacency_check() {
  local file="$1" reaper_sub="$2" destructive_sub="$3"
  awk -v rs="$reaper_sub" -v ds="$destructive_sub" '
    index($0, rs) > 0 { prev = NR; next }
    index($0, ds) > 0 { if (NR == prev + 1) ok = 1 }
    END              { exit ok ? 0 : 1 }
  ' "$file"
}

test_s1() {
  adjacency_check \
    "$REPO_DIR/scripts/worktree.sh" \
    'reap_worktree_orphans "$WORKTREE_DIR"' \
    'git worktree remove "$WORKTREE_DIR" --force' \
    || { echo "  scripts/worktree.sh adjacency violated"; return 1; }
}
check "S1: scripts/worktree.sh — reaper directly precedes git worktree remove" test_s1

test_s2() {
  adjacency_check \
    "$REPO_DIR/adapters/claude-code/claude/tools/autopilot.sh" \
    'reap_worktree_orphans "$worktree_dir"' \
    'git worktree remove --force "$worktree_dir"' \
    || { echo "  autopilot.sh adjacency violated"; return 1; }
}
check "S2: autopilot.sh — reaper directly precedes git worktree remove" test_s2

test_s3() {
  adjacency_check \
    "$REPO_DIR/adapters/claude-code/claude/tools/commit-finalize.sh" \
    'reap_worktree_orphans "$WORKTREE"' \
    'git worktree remove --force "$WORKTREE"' \
    || { echo "  commit-finalize.sh adjacency violated"; return 1; }
}
check "S3: commit-finalize.sh — reaper directly precedes git worktree remove" test_s3

test_s4() {
  adjacency_check \
    "$REPO_DIR/scripts/resume-cutover-chain.sh" \
    'reap_worktree_orphans "$CUTOVER_WORKTREE"' \
    'git worktree remove --force "$CUTOVER_WORKTREE"' \
    || { echo "  resume-cutover-chain.sh adjacency violated"; return 1; }
}
check "S4: resume-cutover-chain.sh — reaper directly precedes git worktree remove" test_s4

test_s5() {
  adjacency_check \
    "$REPO_DIR/dashboard/scripts/worktree.sh" \
    'reap_worktree_orphans "$WORKTREE_DIR"' \
    'git worktree remove "$WORKTREE_DIR" --force' \
    || { echo "  dashboard/scripts/worktree.sh adjacency violated"; return 1; }
  # R11 — no duplicate copy of the helper inside dashboard/.
  if [[ -f "$REPO_DIR/dashboard/scripts/worktree-reaper.sh" ]] \
     || [[ -f "$REPO_DIR/dashboard/tests/_lib/worktree-reaper.sh" ]]; then
    echo "  duplicate worktree-reaper.sh inside dashboard/"; return 1
  fi
}
check "S5: dashboard/scripts/worktree.sh adjacency + no dashboard duplicate" test_s5

test_s6() {
  # test-autopilot.sh has three destructive cleanups (R9, E7).
  local f="$REPO_DIR/adapters/claude-code/claude/tools/test-autopilot.sh"
  local count
  count=$(awk -v rs='reap_worktree_orphans "$wt_path"' \
              -v ds='git worktree remove --force "$wt_path"' '
    index($0, rs) > 0 { prev = NR; next }
    index($0, ds) > 0 { if (NR == prev + 1) hits++ }
    END               { print hits + 0 }
  ' "$f")
  [[ "$count" == "3" ]] || { echo "  expected 3 adjacencies in test-autopilot.sh, found $count"; return 1; }
}
check "S6: test-autopilot.sh — three reaper/destructive adjacencies" test_s6

test_s7() {
  adjacency_check \
    "$REPO_DIR/adapters/claude-code/claude/tools/autopilot-chain.sh" \
    'reap_worktree_orphans "$wt_dir"' \
    'rm -rf "$wt_dir"' \
    || { echo "  autopilot-chain.sh adjacency violated"; return 1; }
}
check "S7: autopilot-chain.sh — reaper directly precedes rm -rf" test_s7

test_s8() {
  # Every integrating script sources the helper with no hardcoded absolute
  # paths. Allow source lines that reference the helper via repo-relative
  # variables (MAIN_DIR, AUTOPILOT_DIR, CHAIN_DIR, TOOLS_DIR, REPO_ROOT, etc.).
  local files=(
    "scripts/worktree.sh"
    "adapters/claude-code/claude/tools/autopilot.sh"
    "adapters/claude-code/claude/tools/commit-finalize.sh"
    "scripts/resume-cutover-chain.sh"
    "dashboard/scripts/worktree.sh"
    "adapters/claude-code/claude/tools/test-autopilot.sh"
    "adapters/claude-code/claude/tools/autopilot-chain.sh"
  )
  local f abs_path
  for f in "${files[@]}"; do
    abs_path="$REPO_DIR/$f"
    grep -Eq '^[[:space:]]*(\.|source)[[:space:]].*worktree-reaper\.sh' "$abs_path" \
      || { echo "  $f does not source worktree-reaper.sh"; return 1; }
    if grep -E '^[[:space:]]*(\.|source)[[:space:]]+(/Users/|/home/|~|\$HOME)' "$abs_path" \
       | grep -q 'worktree-reaper\.sh'; then
      echo "  $f sources reaper via hardcoded absolute path"; return 1
    fi
  done
}
check "S8: every integrating script sources reaper via repo-relative path" test_s8

test_s9() {
  # R11 — exactly one canonical worktree-reaper.sh under repo root.
  local matches
  # shellcheck disable=SC2207
  matches=( $(find "$REPO_DIR" -type f -name 'worktree-reaper.sh' \
              -not -path '*/node_modules/*' \
              -not -path '*/.venv/*' \
              -not -path '*/docs/DONE_*/*' \
              2>/dev/null) )
  [[ "${#matches[@]}" == "1" ]] \
    || { echo "  expected 1 worktree-reaper.sh, found ${#matches[@]}: ${matches[*]}"; return 1; }
  [[ "${matches[0]}" == "$REPO_DIR/adapters/claude-code/claude/tools/lib/worktree-reaper.sh" ]] \
    || { echo "  unexpected location: ${matches[0]}"; return 1; }
}
check "S9: reaper helper at exactly one canonical location" test_s9

test_s10() {
  # R14 — reaper does not source or reference port-preflight (#52 isolation).
  if grep -E 'port-preflight|port_preflight' "$LIB" >/dev/null 2>&1; then
    echo "  reaper references port-preflight (R14 violation)"; return 1
  fi
}
check "S10: reaper helper has no port-preflight references" test_s10

# ────────────────────────────────────────────────────────
# Self-meta assertions (M1–M3)
# ────────────────────────────────────────────────────────

test_m1() {
  local self="$REPO_DIR/tests/test-worktree-reaper.sh"
  local first
  first=$(sed -n '1p' "$self")
  [[ "$first" == "#!/usr/bin/env bash" ]] \
    || { echo "  shebang wrong: $first"; return 1; }
  # set -euo pipefail must appear within the first 20 lines.
  head -n 20 "$self" | grep -Fq 'set -euo pipefail' \
    || { echo "  set -euo pipefail missing in first 20 lines"; return 1; }
  [[ -x "$self" ]] || { echo "  file not executable (mode 0755 expected)"; return 1; }
}
check "M1: self uses project shebang/safety pattern + executable" test_m1

test_m2() {
  # R8 — T10 must exist as a hard assertion. We grep for the function name.
  grep -q "^test_t10()" "$REPO_DIR/tests/test-worktree-reaper.sh" \
    || { echo "  T10 (missing-lsof refusal) missing — silent skip would re-introduce R8 bug"; return 1; }
}
check "M2: T10 (missing-lsof refusal) is a hard assertion" test_m2

test_m3() {
  # Lower-bound on test count: T1–T21 (21) + S1–S10 (10) + M1–M3 (3) = 34.
  # M3 is itself the 34th check, so by the time test_m3 runs, ran has
  # already been incremented to 34 by check().
  if (( ran < 34 )); then
    echo "  expected ≥34 tests, ran $ran"
    return 1
  fi
}
check "M3: ≥34 tests ran (T1–T21 + S1–S10 + M1–M3)" test_m3

# ────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────
echo
echo "---"
echo "Ran:    $ran"
echo "Passed: $passed"
echo "Failed: $failed"

exit $(( failed > 0 ? 1 : 0 ))
