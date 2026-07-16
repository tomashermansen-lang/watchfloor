#!/usr/bin/env bash
# Guards dashboard/tests/_lib/sandbox.sh — the detection that lets run-all.sh
# SKIP git-fixture integration suites when the Claude Code sandbox blocks
# `git init` (so the sandboxed autopilot agent doesn't wedge on exit-128), while
# they still run in the unsandboxed orchestrator integration gate.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/dashboard/tests/_lib/sandbox.sh"

PASS=0
FAIL=0
check() { if "$2"; then echo "  ok: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sbskip.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Mock `git` that simulates the sandbox blocking repo creation (exit 128).
mkdir -p "$TMP/bin-blocked"
cat > "$TMP/bin-blocked/git" <<'EOF'
#!/usr/bin/env bash
echo "error: could not write config file .git/config: Operation not permitted" >&2
exit 128
EOF
chmod +x "$TMP/bin-blocked/git"

# Mock `git` that simulates a working repo creation (writes .git/config).
mkdir -p "$TMP/bin-ok"
cat > "$TMP/bin-ok/git" <<'EOF'
#!/usr/bin/env bash
dir="."
while [ $# -gt 0 ]; do case "$1" in -C) dir="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$dir/.git" && printf '[core]\n' > "$dir/.git/config"
exit 0
EOF
chmod +x "$TMP/bin-ok/git"

probe_with() { PATH="$1:$PATH" bash -c "source '$LIB'; git_repo_supported && echo TRUE || echo FALSE"; }

test_blocked_git_detected_unsupported() {
  [[ "$(probe_with "$TMP/bin-blocked")" == "FALSE" ]] || { echo "    blocked git should report unsupported"; return 1; }
}
check "git_repo_supported: FALSE when git init is sandbox-blocked" test_blocked_git_detected_unsupported

test_working_git_detected_supported() {
  [[ "$(probe_with "$TMP/bin-ok")" == "TRUE" ]] || { echo "    working git should report supported"; return 1; }
}
check "git_repo_supported: TRUE when git init succeeds" test_working_git_detected_supported

# suite_should_skip rule table.
ssk() { bash -c "source '$LIB'; suite_should_skip \"\$1\" \"\$2\"" _ "$1" "$2"; }

test_git_suite_skipped_when_no_git() { [[ "$(ssk git false)" == "skip" ]] || { echo "    git suite + no git should skip"; return 1; }; }
check "suite_should_skip: git suite skipped when git unavailable" test_git_suite_skipped_when_no_git

test_git_suite_runs_when_git_ok() { [[ "$(ssk git true)" == "run" ]] || { echo "    git suite + git ok should run"; return 1; }; }
check "suite_should_skip: git suite runs when git available" test_git_suite_runs_when_git_ok

test_nongit_suite_always_runs_a() { [[ "$(ssk '' false)" == "run" ]] || { echo "    non-git suite should run even without git"; return 1; }; }
check "suite_should_skip: non-git suite runs without git" test_nongit_suite_always_runs_a

test_nongit_suite_always_runs_b() { [[ "$(ssk '' true)" == "run" ]] || { echo "    non-git suite should run with git"; return 1; }; }
check "suite_should_skip: non-git suite runs with git" test_nongit_suite_always_runs_b

test_broken_suite_always_skipped() {
  [[ "$(ssk broken true)" == "skip" && "$(ssk broken false)" == "skip" ]] \
    || { echo "    a 'broken' suite must always skip (known-hang quarantine)"; return 1; }
}
check "suite_should_skip: 'broken' suite is always skipped" test_broken_suite_always_skipped

# --- suite_is_integration: which suites belong to the orchestrator gate ---
# Integration suites are the sandbox-incompatible set: git-fixture ("git") and
# server-bound ("server"). Everything else is a unit suite that runs sandboxed
# in a feature phase. Single source of truth for `--only-integration` (real
# integration gates §4.4 / §9). A "broken" suite is quarantined, not integration.
sii() { bash -c "source '$LIB'; suite_is_integration \"\$1\"" _ "$1"; }

test_git_is_integration()    { [[ "$(sii git)" == "yes" ]]    || { echo "    git suite is integration"; return 1; }; }
check "suite_is_integration: git → yes" test_git_is_integration

test_server_is_integration() { [[ "$(sii server)" == "yes" ]] || { echo "    server suite is integration"; return 1; }; }
check "suite_is_integration: server → yes" test_server_is_integration

test_unit_not_integration()  { [[ "$(sii '')" == "no" ]]      || { echo "    unmarked suite is a unit suite"; return 1; }; }
check "suite_is_integration: unmarked → no" test_unit_not_integration

test_broken_not_integration() { [[ "$(sii broken)" == "no" ]] || { echo "    broken suite is quarantined, not integration"; return 1; }; }
check "suite_is_integration: broken → no" test_broken_not_integration

# --- suite_run_decision: the full run/skip rule given the gate mode ---
# Returns a token: run | skip:unit | skip:sandbox | skip:broken. run-all.sh maps
# the token to a human SKIP reason. Combines the sandbox rule (suite_should_skip)
# with the --only-integration filter so the decision lives in ONE place.
srd() { bash -c "source '$LIB'; suite_run_decision \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"; }

# Normal mode (only_integration=0) — behaviour unchanged from suite_should_skip.
test_srd_git_ok_normal()       { [[ "$(srd git true 0)" == "run" ]]          || { echo "    git+ok normal → run"; return 1; }; }
check "suite_run_decision: git suite runs (git ok, normal)" test_srd_git_ok_normal

test_srd_git_nogit_normal()    { [[ "$(srd git false 0)" == "skip:sandbox" ]] || { echo "    git+no-git → skip:sandbox"; return 1; }; }
check "suite_run_decision: git suite skips when no git (normal)" test_srd_git_nogit_normal

test_srd_unit_normal()         { [[ "$(srd '' true 0)" == "run" ]]            || { echo "    unit normal → run"; return 1; }; }
check "suite_run_decision: unit suite runs (normal)" test_srd_unit_normal

test_srd_broken_normal()       { [[ "$(srd broken true 0)" == "skip:broken" ]] || { echo "    broken normal → skip:broken"; return 1; }; }
check "suite_run_decision: broken suite skips (normal)" test_srd_broken_normal

# Only-integration mode (the gate) — unit suites are skipped, integration runs.
test_srd_unit_only_integ()     { [[ "$(srd '' true 1)" == "skip:unit" ]]      || { echo "    unit in only-integration → skip:unit"; return 1; }; }
check "suite_run_decision: unit suite skipped in --only-integration" test_srd_unit_only_integ

test_srd_git_only_integ()      { [[ "$(srd git true 1)" == "run" ]]           || { echo "    git in only-integration (git ok) → run"; return 1; }; }
check "suite_run_decision: git suite runs in --only-integration" test_srd_git_only_integ

test_srd_server_only_integ()   { [[ "$(srd server true 1)" == "run" ]]        || { echo "    server in only-integration → run"; return 1; }; }
check "suite_run_decision: server suite runs in --only-integration" test_srd_server_only_integ

test_srd_git_nogit_only_integ() { [[ "$(srd git false 1)" == "skip:sandbox" ]] || { echo "    integration suite needs git but none → skip:sandbox"; return 1; }; }
check "suite_run_decision: integration suite skips when its infra is unavailable" test_srd_git_nogit_only_integ

test_srd_broken_only_integ()   { [[ "$(srd broken true 1)" == "skip:broken" ]] || { echo "    broken in only-integration → skip:broken"; return 1; }; }
check "suite_run_decision: broken suite still skips in --only-integration" test_srd_broken_only_integ

# run-all.sh must accept the flag and route through suite_run_decision.
test_runall_accepts_only_integration_flag() {
  grep -q -- '--only-integration' "$REPO_ROOT/dashboard/tests/run-all.sh" \
    || { echo "    run-all.sh must parse --only-integration"; return 1; }
}
check "run-all.sh parses --only-integration" test_runall_accepts_only_integration_flag

test_runall_uses_decision_function() {
  grep -q 'suite_run_decision' "$REPO_ROOT/dashboard/tests/run-all.sh" \
    || { echo "    run_suite must route through suite_run_decision (single-source rule)"; return 1; }
}
check "run-all.sh run_suite uses suite_run_decision" test_runall_uses_decision_function

# run-all.sh honors RUNALL_ASSUME_NO_GIT — the git-fixture suites must report
# SKIP and the runner must still exit 0 (skips are not failures). We stub the
# heavy run by checking the marked-suite count is the SKIP count under no-git.
test_runall_marks_ten_git_suites() {
  local n; n=$(grep -cE 'run_suite .*"git"$' "$REPO_ROOT/dashboard/tests/run-all.sh")
  [[ "$n" == "10" ]] || { echo "    expected 10 git-marked suites, got $n"; return 1; }
}
check "run-all.sh marks exactly the 10 git-fixture suites" test_runall_marks_ten_git_suites

# The audited server-bound suites (spawn a real uvicorn / bind a real port and
# so can't be trusted in the agent sandbox) are marked "server" → they run at
# the integration gate, not as sandboxed unit suites (real integration gates,
# 3b-1 server audit). Conservative set: only suites proven to spawn a server.
test_runall_marks_five_server_suites() {
  local n; n=$(grep -cE 'run_suite .*"server"$' "$REPO_ROOT/dashboard/tests/run-all.sh")
  [[ "$n" == "5" ]] || { echo "    expected 5 server-marked suites, got $n"; return 1; }
}
check "run-all.sh marks exactly the 5 server-bound suites" test_runall_marks_five_server_suites

test_runall_server_suites_are_the_audited_ones() {
  local ra="$REPO_ROOT/dashboard/tests/run-all.sh" s
  for s in test-api-metrics.sh test-api-autopilot.sh test-features.sh \
           test-fastapi-integration.sh test-port-preflight.sh; do
    grep -qE "run_suite .*/$s\" \"server\"\$" "$ra" \
      || { echo "    $s must be marked server (audited: spawns a real server)"; return 1; }
  done
}
check "run-all.sh: the 5 server suites are the audited uvicorn/bind ones" test_runall_server_suites_are_the_audited_ones

# run_bounded: a hanging suite must be killed, not allowed to wedge the runner.
rb() { bash -c "source '$LIB'; run_bounded \"\$1\" \"\${@:2}\"; echo rc=\$?" _ "$@"; }

test_run_bounded_kills_hang() {
  local o; o=$(rb 1 sleep 8)
  echo "$o" | grep -q 'rc=124' || { echo "    expected rc=124 (timed out); got: $o"; return 1; }
}
check "run_bounded: kills a hanging command (rc=124)" test_run_bounded_kills_hang

test_run_bounded_passes_through_success() {
  local o; o=$(rb 5 true)
  echo "$o" | grep -q 'rc=0' || { echo "    expected rc=0 for fast success; got: $o"; return 1; }
}
check "run_bounded: passes through success (rc=0)" test_run_bounded_passes_through_success

test_run_bounded_passes_through_failure() {
  local o; o=$(rb 5 false)
  echo "$o" | grep -q 'rc=1' || { echo "    expected rc=1 for fast failure; got: $o"; return 1; }
}
check "run_bounded: passes through failure exit code" test_run_bounded_passes_through_failure

# run_bounded_retry: absorbs transient flakiness (random ports / slow boot) by
# retrying a failing suite; only fails if every attempt fails.
test_retry_passes_on_flaky_success() {
  local cnt="$TMP/cnt-$RANDOM" scr="$TMP/flaky-$RANDOM.sh"; printf '0' > "$cnt"
  # A script that fails the 1st run, succeeds the 2nd (simulates a port flake).
  cat > "$scr" <<EOF
#!/usr/bin/env bash
n=\$(cat '$cnt'); n=\$((n + 1)); printf '%s' "\$n" > '$cnt'
[ "\$n" -ge 2 ]
EOF
  local o; o=$(bash -c "source '$LIB'; run_bounded_retry 10 2 bash '$scr'; echo rc=\$?")
  echo "$o" | grep -q 'rc=0' || { echo "    flaky-then-pass should succeed via retry; got: $o"; return 1; }
}
check "run_bounded_retry: passes a flaky-then-success command" test_retry_passes_on_flaky_success

test_retry_fails_when_always_failing() {
  local o; o=$(bash -c "source '$LIB'; run_bounded_retry 10 2 false; echo rc=\$?")
  echo "$o" | grep -q 'rc=1' || { echo "    always-failing should fail after retries; got: $o"; return 1; }
}
check "run_bounded_retry: fails after exhausting retries" test_retry_fails_when_always_failing

test_retry_success_first_try() {
  local o; o=$(bash -c "source '$LIB'; run_bounded_retry 10 2 true; echo rc=\$?")
  echo "$o" | grep -q 'rc=0' || { echo "    immediate success should rc=0; got: $o"; return 1; }
}
check "run_bounded_retry: immediate success (rc=0)" test_retry_success_first_try

test_retry_does_not_retry_timeout() {
  # A timeout (hang) must NOT be retried — returns 124 fast, not 3x the wait.
  local start end o
  start=$(date +%s)
  o=$(bash -c "source '$LIB'; run_bounded_retry 1 3 sleep 8; echo rc=\$?")
  end=$(date +%s)
  echo "$o" | grep -q 'rc=124' || { echo "    timeout should surface rc=124; got: $o"; return 1; }
  [ $((end - start)) -lt 5 ] || { echo "    timeout was retried (took $((end - start))s, expected ~1s)"; return 1; }
}
check "run_bounded_retry: does NOT retry a timeout (fast 124)" test_retry_does_not_retry_timeout

echo ""
echo "test_runall_sandbox_skip: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
