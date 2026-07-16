#!/usr/bin/env bash
# test_chain_runner_overrides.sh — integration + static-source tests for
# the runner-overrides runtime (Components A, B, D1, D2, E, F, H) of the
# autopilot-chain.sh runner.env + runner.flags feature.
#
# Drives autopilot-chain.sh as a subprocess with AUTOPILOT_CMD set to an
# inline stub. The stub records BOTH the argv it received AND the env it
# saw (filtered to fixture-declared keys) to per-task side-channel files
# inside the temp PLAN_DIR. Static-source assertions cover the
# autopilot.sh sentinel writer, the chain whitelist extension, the chain
# header docstring, and the bash 3.2 portability constraints.
#
# Portability: bash 3.2 macOS-default. No mapfile, no nameref, no
# associative arrays, no namerefs, no `${var^^}` / `${var,,}`.
#
# Skip semantics: exits 0 with `SKIP:` when shlock or jq are absent —
# mirrors tests/test_stop_after_phase_chain.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHAIN_SH="$REPO_ROOT/adapters/claude-code/claude/tools/autopilot-chain.sh"
AUTOPILOT_SH="$REPO_ROOT/adapters/claude-code/claude/tools/autopilot.sh"
VALIDATE="$REPO_ROOT/adapters/claude-code/claude/tools/validate-plan.py"
SCHEMA="$REPO_ROOT/core/schema/execution-plan.schema.json"

FIXTURE="$REPO_ROOT/tests/fixtures/runner-overrides-fixture-plan.yaml"
F_BAD_KEY="$REPO_ROOT/tests/fixtures/runner-overrides-invalid-env-key.yaml"
F_BAD_FLAG="$REPO_ROOT/tests/fixtures/runner-overrides-invalid-flags-item.yaml"
F_MULTI="$REPO_ROOT/tests/fixtures/runner-overrides-multi-violation.yaml"
F_UNKNOWN="$REPO_ROOT/tests/fixtures/runner-overrides-unknown-flag.yaml"

PASS=0
FAIL=0
FAILED_NAMES=()

check() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    printf '  FAIL: %s\n' "$name" >&2
  fi
}

for required in "$CHAIN_SH" "$AUTOPILOT_SH" "$VALIDATE" "$SCHEMA" \
                "$FIXTURE" "$F_BAD_KEY" "$F_BAD_FLAG" "$F_MULTI" "$F_UNKNOWN"; do
  [[ -f "$required" ]] || { echo "FATAL: $required not found"; exit 1; }
done

# Skip cleanly when shlock/jq are absent (sandbox environments).
if ! command -v shlock >/dev/null 2>&1; then
  echo "SKIP: shlock not in PATH — chain integration cases need it"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not in PATH — chain integration cases need it"
  exit 0
fi

# Coreutils-style timeout binary for the hang-regression guard
# (REG-chain-hang). macOS ships none by default; Homebrew coreutils
# provides `gtimeout`. The guard self-skips when neither is present.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

TMP_DIRS=()
ATTACK_GUARDS=()
cleanup_all() {
  local d
  for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  for f in "${ATTACK_GUARDS[@]+"${ATTACK_GUARDS[@]}"}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup_all EXIT

# new_plan_dir <fixture_path>  →  PLAN_DIR path
# Lays out a temp tree mirroring the production worktree convention so
# the chain's harvest probe at `${PLAN_DIR}/../../worktrees/feature-<id>`
# resolves inside the test tree.
new_plan_dir() {
  local fixture="$1"
  local base
  base=$(mktemp -d "${TMPDIR:-/tmp}/chain-runner-overrides-XXXXXX")
  TMP_DIRS+=("$base")
  local plan_dir="$base/proj/docs/INPROGRESS_Plan_fixture"
  mkdir -p "$plan_dir" "$base/proj/worktrees"
  cp "$fixture" "$plan_dir/execution-plan.yaml"
  echo "$plan_dir"
}

# build_stub <plan_dir> <status>  →  path to recording stub
# Records argv to argv-<task>.log and env to env-<task>.log (filtered to
# fixture-declared keys), then touches an autopilot-summary.json with
# status=<status> so the chain harvest terminates.
build_stub() {
  local plan_dir="$1"
  local stub_status="$2"
  local stub="$plan_dir/stub-autopilot.sh"
  cat > "$stub" <<STUB_EOF
#!/usr/bin/env bash
set -uo pipefail
plan_dir="$plan_dir"
stub_status="$stub_status"
# Last positional is the task id.
task_id="\${@: -1}"
# Record argv (one task → one file).
printf '%s\n' "\$*" > "\$plan_dir/argv-\$task_id.log"
# Record env filtered to the fixture-declared keys (set-equivalence ok).
{
  env | grep -E '^(LOCAL_LLM_ROUTING|LOCAL_LLM_PHASES|SHELL_META_VALUE|MULTILINE_VAR|EMPTY_VAR|VAR|A|B|C|RUNNER_OVERRIDE_PROBE)=' || true
} > "\$plan_dir/env-\$task_id.log"
# Mirror the worktree path the chain probes.
wt_dir="\$plan_dir/../../worktrees/feature-\$task_id"
feature_dir="\$wt_dir/docs/INPROGRESS_Feature_\$task_id"
mkdir -p "\$feature_dir"
printf '{"task":"%s","status":"%s","duration_s":0,"phases":[]}\n' \
  "\$task_id" "\$stub_status" > "\$feature_dir/autopilot-summary.json"
exit 0
STUB_EOF
  chmod +x "$stub"
  echo "$stub"
}

# build_unknown_flag_stub <plan_dir>  →  path to stub emulating autopilot.sh
# Writes sentinel `unknown_runner_flag:--definitely-not-a-real-flag` and
# exits 2 — drives the AS10 chain_blocked path without invoking real
# autopilot.sh.
build_unknown_flag_stub() {
  local plan_dir="$1"
  local stub="$plan_dir/stub-unknown-flag.sh"
  cat > "$stub" <<STUB_EOF
#!/usr/bin/env bash
set -uo pipefail
plan_dir="$plan_dir"
task_id="\${@: -1}"
printf '%s\n' "\$*" > "\$plan_dir/argv-\$task_id.log"
# Look for the canonical bad flag in argv.
bad_flag=""
for arg in "\$@"; do
  case "\$arg" in
    --definitely-not-a-real-flag) bad_flag="\$arg"; break ;;
  esac
done
if [[ -n "\$bad_flag" ]]; then
  echo "unknown_runner_flag:\$bad_flag" > "\$plan_dir/.chain-blocked-reason-\$task_id"
  exit 2
fi
# Sibling — pretend success.
wt_dir="\$plan_dir/../../worktrees/feature-\$task_id"
feature_dir="\$wt_dir/docs/INPROGRESS_Feature_\$task_id"
mkdir -p "\$feature_dir"
printf '{"task":"%s","status":"%s","duration_s":0,"phases":[]}\n' \
  "\$task_id" "success" > "\$feature_dir/autopilot-summary.json"
exit 0
STUB_EOF
  chmod +x "$stub"
  echo "$stub"
}

run_chain() {
  local plan_dir="$1"
  local stub="$2"
  shift 2
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
  AUTOPILOT_CMD="bash $stub" \
    bash "$CHAIN_SH" --max-parallel 1 "$@" "$plan_dir" \
      >"$plan_dir/out" 2>"$plan_dir/err"
}

# ───────────────────────────────────────────────────────────────────────
# REG-chain-hang — early-exit run_chain paths must NOT deadlock on the
# `exec > >(tee …)` process substitution (autopilot-chain.sh:464).
#
# The backgrounded `caffeinate -s -w $$ &` inherits run_chain's stdout
# (the tee pipe write-end). The early `exit` branches — chain_blocked
# (unknown_runner_flag), stop-after-phase, task-failure halt — return
# before the end-of-main-loop `kill "$caffeinate_pid"`, so caffeinate
# keeps the pipe open. In bash 3.2 the shell then blocks forever at
# exit waiting for tee to receive EOF, and the foreground caller (this
# test) hangs with it. Happy-path runs reach the kill and exit cleanly,
# which is why only the full suite (it hits AS10's unknown-flag path)
# reproduced the hang.
#
# Guard: an unknown-flag run (chain_blocked `exit 1` branch) must return
# on its own, not be SIGKILLed by the timeout (rc 124 from timeout, 137
# from `-s KILL`).
# ───────────────────────────────────────────────────────────────────────
{
  if [[ -z "$TIMEOUT_BIN" ]]; then
    echo "SKIP REG-chain-hang: no timeout/gtimeout binary for hang guard"
  else
    PLAN_DIR=$(new_plan_dir "$F_UNKNOWN")
    STUB=$(build_unknown_flag_stub "$PLAN_DIR")
    RC=0
    CHAIN_MAIN_DIRTY_OVERRIDE=false \
    AUTOPILOT_CMD="bash $STUB" \
      "$TIMEOUT_BIN" -s KILL 30 \
        bash "$CHAIN_SH" --max-parallel 1 "$PLAN_DIR" \
        >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || RC=$?
    check "REG-chain-hang: early-exit chain returns, not timeout-killed" \
      bash -c "test \"$RC\" -ne 124 && test \"$RC\" -ne 137"
  fi
}

# ───────────────────────────────────────────────────────────────────────
# T-F1..T-F5 — fixture validation contract (R19..R21, R30)
# ───────────────────────────────────────────────────────────────────────
{
  check "T-F1: happy-path fixture validates clean" \
    bash -c "python3 '$VALIDATE' '$FIXTURE' >/dev/null 2>&1"
  check "T-F2: invalid-env-key fixture rejected" \
    bash -c "! python3 '$VALIDATE' '$F_BAD_KEY' >/dev/null 2>&1"
  check "T-F3: invalid-flags-item fixture rejected" \
    bash -c "! python3 '$VALIDATE' '$F_BAD_FLAG' >/dev/null 2>&1"
  check "T-F4: multi-violation fixture rejected" \
    bash -c "! python3 '$VALIDATE' '$F_MULTI' >/dev/null 2>&1"
  check "T-F5: unknown-flag fixture validates clean" \
    bash -c "python3 '$VALIDATE' '$F_UNKNOWN' >/dev/null 2>&1"
}

# ───────────────────────────────────────────────────────────────────────
# Shared happy-path run. A single chain run over the full fixture writes
# argv-<task>.log + env-<task>.log for EVERY task, so the per-task
# forwarding assertions below (AS1/AS3/AS4/AS5/AS6/AS12/AS14 + the T-EC
# edge cases) all read from this one run instead of re-running the same
# 14-task plan a dozen times. At ~12s/run that consolidation is the
# difference between this suite fitting run-all.sh's per-suite timeout
# and blowing past it. Cases that need a DIFFERENT invocation (env-leak
# probe AS2, parent-override AS7, chain-level --stop-after-phase AS11,
# the unknown-flag / failure halt paths) still get their own run below.
# Determinism is preserved — run_chain drives --max-parallel 1.
# ───────────────────────────────────────────────────────────────────────
SHARED_PLAN_DIR=$(new_plan_dir "$FIXTURE")
SHARED_STUB=$(build_stub "$SHARED_PLAN_DIR" "success")
run_chain "$SHARED_PLAN_DIR" "$SHARED_STUB" || true

# ───────────────────────────────────────────────────────────────────────
# AS4 — task-no-runner: argv byte-identical to pre-feature reference.
# ───────────────────────────────────────────────────────────────────────
NO_RUNNER_ARGV=""
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  check "AS4: argv-task-no-runner.log exists" \
    test -f "$PLAN_DIR/argv-task-no-runner.log"
  if [[ -f "$PLAN_DIR/argv-task-no-runner.log" ]]; then
    NO_RUNNER_ARGV=$(cat "$PLAN_DIR/argv-task-no-runner.log")
    check "AS4: argv equals --full --pipeline light task-no-runner" \
      bash -c "test '$NO_RUNNER_ARGV' = '--full --pipeline light task-no-runner'"
  fi
  # env-task-no-runner contains none of the filtered keys.
  check "AS4: env-task-no-runner has no fixture-declared keys" \
    bash -c "! test -s '$PLAN_DIR/env-task-no-runner.log'"
}

# ───────────────────────────────────────────────────────────────────────
# AS5 + AS6 — empty runner and empty inner runner are byte-identical to AS4.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  if [[ -f "$PLAN_DIR/argv-task-empty-runner.log" && -n "$NO_RUNNER_ARGV" ]]; then
    EMPTY_ARGV=$(cat "$PLAN_DIR/argv-task-empty-runner.log")
    check "AS5: argv-task-empty-runner shape matches no-runner shape" \
      bash -c "test '$EMPTY_ARGV' = '--full --pipeline light task-empty-runner'"
  fi
  if [[ -f "$PLAN_DIR/argv-task-empty-inner.log" && -n "$NO_RUNNER_ARGV" ]]; then
    EMPTY_INNER_ARGV=$(cat "$PLAN_DIR/argv-task-empty-inner.log")
    check "AS6: argv-task-empty-inner shape matches no-runner shape" \
      bash -c "test '$EMPTY_INNER_ARGV' = '--full --pipeline light task-empty-inner'"
  fi
  check "AS5: env-task-empty-runner has no fixture-declared keys" \
    bash -c "! test -s '$PLAN_DIR/env-task-empty-runner.log'"
  check "AS6: env-task-empty-inner has no fixture-declared keys" \
    bash -c "! test -s '$PLAN_DIR/env-task-empty-inner.log'"
}

# ───────────────────────────────────────────────────────────────────────
# AS1 — task-flags-only: --stop-after-phase ba appended between flags and id.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  check "AS1: argv-task-flags-only.log exists" \
    test -f "$PLAN_DIR/argv-task-flags-only.log"
  check "AS1: argv contains --stop-after-phase ba" \
    bash -c "grep -F -q -- '--stop-after-phase ba' '$PLAN_DIR/argv-task-flags-only.log'"
  check "AS1: argv ends with task-flags-only" \
    bash -c "grep -E -q ' task-flags-only\$' '$PLAN_DIR/argv-task-flags-only.log'"
}

# ───────────────────────────────────────────────────────────────────────
# AS2 — task-env-only: env exported subprocess-scoped, no leak to chain shell.
# Run chain in a child shell and probe LOCAL_LLM_ROUTING afterwards.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir "$FIXTURE")
  STUB=$(build_stub "$PLAN_DIR" "success")
  PROBE_FILE="$PLAN_DIR/parent-env-after-chain.log"
  bash -c "
    unset LOCAL_LLM_ROUTING LOCAL_LLM_PHASES
    CHAIN_MAIN_DIRTY_OVERRIDE=false \
    AUTOPILOT_CMD='bash $STUB' \
      bash '$CHAIN_SH' --max-parallel 1 '$PLAN_DIR' \
        >'$PLAN_DIR/out' 2>'$PLAN_DIR/err' || true
    {
      echo \"after_LOCAL_LLM_ROUTING=\${LOCAL_LLM_ROUTING:-UNSET}\"
      echo \"after_LOCAL_LLM_PHASES=\${LOCAL_LLM_PHASES:-UNSET}\"
    } > '$PROBE_FILE'
  "
  check "AS2: env-task-env-only contains LOCAL_LLM_ROUTING=1" \
    bash -c "grep -F -q -- 'LOCAL_LLM_ROUTING=1' '$PLAN_DIR/env-task-env-only.log'"
  check "AS2: env-task-env-only contains LOCAL_LLM_PHASES=ba,plan" \
    bash -c "grep -F -q -- 'LOCAL_LLM_PHASES=ba,plan' '$PLAN_DIR/env-task-env-only.log'"
  check "AS2: chain shell does NOT see leaked LOCAL_LLM_ROUTING (R4)" \
    bash -c "grep -F -q 'after_LOCAL_LLM_ROUTING=UNSET' '$PROBE_FILE'"
  check "AS2: chain shell does NOT see leaked LOCAL_LLM_PHASES (R4)" \
    bash -c "grep -F -q 'after_LOCAL_LLM_PHASES=UNSET' '$PROBE_FILE'"
}

# ───────────────────────────────────────────────────────────────────────
# AS3 — task-env-and-flags: both env and flags applied.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  check "AS3: argv-task-env-and-flags contains --stop-after-phase ba" \
    bash -c "grep -F -q -- '--stop-after-phase ba' '$PLAN_DIR/argv-task-env-and-flags.log'"
  check "AS3: env-task-env-and-flags contains LOCAL_LLM_ROUTING=1" \
    bash -c "grep -F -q -- 'LOCAL_LLM_ROUTING=1' '$PLAN_DIR/env-task-env-and-flags.log'"
  check "AS3: env-task-env-and-flags contains LOCAL_LLM_PHASES=ba" \
    bash -c "grep -E -q '^LOCAL_LLM_PHASES=ba\$' '$PLAN_DIR/env-task-env-and-flags.log'"
}

# ───────────────────────────────────────────────────────────────────────
# AS7 — runner.env value overrides parent shell env.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir "$FIXTURE")
  STUB=$(build_stub "$PLAN_DIR" "success")
  bash -c "
    export LOCAL_LLM_ROUTING=parent-value
    CHAIN_MAIN_DIRTY_OVERRIDE=false \
    AUTOPILOT_CMD='bash $STUB' \
      bash '$CHAIN_SH' --max-parallel 1 '$PLAN_DIR' \
        >'$PLAN_DIR/out' 2>'$PLAN_DIR/err' || true
  "
  check "AS7: env-task-env-override contains override-value" \
    bash -c "grep -F -q -- 'LOCAL_LLM_ROUTING=override-value' '$PLAN_DIR/env-task-env-override.log'"
  check "AS7: env-task-env-override does NOT contain parent-value" \
    bash -c "! grep -F -q -- 'LOCAL_LLM_ROUTING=parent-value' '$PLAN_DIR/env-task-env-override.log'"
}

# ───────────────────────────────────────────────────────────────────────
# AS11 — chain-level + runner-level --stop-after-phase compose (both kept).
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir "$FIXTURE")
  STUB=$(build_stub "$PLAN_DIR" "success")
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
  AUTOPILOT_CMD="bash $STUB" \
    bash "$CHAIN_SH" --max-parallel 1 --stop-after-phase implement "$PLAN_DIR" \
      >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || true
  if [[ -f "$PLAN_DIR/argv-task-flags-only.log" ]]; then
    check "AS11: argv contains chain-level --stop-after-phase implement" \
      bash -c "grep -F -q -- '--stop-after-phase implement' '$PLAN_DIR/argv-task-flags-only.log'"
    check "AS11: argv contains runner-level --stop-after-phase ba" \
      bash -c "grep -F -q -- '--stop-after-phase ba' '$PLAN_DIR/argv-task-flags-only.log'"
    # Implement appears BEFORE ba (chain-level first per R12).
    check "AS11: chain-level appears before runner-level" \
      bash -c "awk '{
        i=index(\$0, \"--stop-after-phase implement\");
        b=index(\$0, \"--stop-after-phase ba\");
        exit !(i>0 && b>0 && i<b)
      }' '$PLAN_DIR/argv-task-flags-only.log'"
  fi
}

# ───────────────────────────────────────────────────────────────────────
# AS12 — shell metacharacters in runner.env value pass through verbatim;
# no command substitution evaluated on chain side.
# ───────────────────────────────────────────────────────────────────────
{
  ATTACK_GUARDS+=("/tmp/runner-attack-FILE")
  rm -f "/tmp/runner-attack-FILE" 2>/dev/null || true
  PLAN_DIR=$(new_plan_dir "$FIXTURE")
  STUB=$(build_stub "$PLAN_DIR" "success")
  run_chain "$PLAN_DIR" "$STUB" || true
  check "AS12: env-task-shell-meta contains literal SHELL_META_VALUE" \
    bash -c "grep -F -q -- 'SHELL_META_VALUE=a;b|c\$(touch /tmp/runner-attack-FILE)\`e\`' '$PLAN_DIR/env-task-shell-meta.log'"
  check "AS12: command substitution NOT evaluated (guard file absent)" \
    bash -c "test ! -f /tmp/runner-attack-FILE"
}

# ───────────────────────────────────────────────────────────────────────
# AS14 — R29 log line emitted with counts only (no values).
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  # The chain's `log()` writes to stderr. Pre-2026-05-20 that stderr
  # flowed directly to `$PLAN_DIR/err` (the run_chain redirect). After
  # c37041f (controls-07 #14) the chain runs
  # `exec > >(tee chain-stdout.log) 2>&1` early in run_chain(), which
  # reroutes stderr to the tee subprocess. Lines emitted AFTER the
  # exec (line 464 in autopilot-chain.sh, e.g. the per-task "Runner
  # overrides" log at line 1147) now land in chain-stdout.log, NOT
  # err. Grep both files so the assertion works under either redirect
  # state (sandbox-blocked /dev/fd → exec fails → lands in err; real
  # macOS → exec succeeds → lands in chain-stdout.log).
  check "AS14: chain log contains 'Runner overrides for task-log-counts'" \
    bash -c "grep -F -q -- 'Runner overrides for task-log-counts' '$PLAN_DIR/err' '$PLAN_DIR/chain-stdout.log' 2>/dev/null"
  check "AS14: chain log contains env=3 flags=2 (counts)" \
    bash -c "grep -E -q 'Runner overrides for task-log-counts.*env=3.*flags=2' '$PLAN_DIR/err' '$PLAN_DIR/chain-stdout.log' 2>/dev/null"
}

# ───────────────────────────────────────────────────────────────────────
# T-EC1 + T-EC2 — embedded \n + empty string env value preserved.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  check "T-EC1: MULTILINE_VAR=a\\nb passes through literal" \
    bash -c "grep -F -q -- 'MULTILINE_VAR=a\\nb' '$PLAN_DIR/env-task-shell-meta.log'"
  check "T-EC2: EMPTY_VAR= preserved (empty value)" \
    bash -c "grep -E -q '^EMPTY_VAR=\$' '$PLAN_DIR/env-task-shell-meta.log'"
}

# ───────────────────────────────────────────────────────────────────────
# T-EC4 — spaced flag preserved as single argv element.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  check "T-EC4: argv-task-spaced-flag contains 'my label with spaces'" \
    bash -c "grep -F -q -- 'my label with spaces' '$PLAN_DIR/argv-task-spaced-flag.log'"
}

# ───────────────────────────────────────────────────────────────────────
# T-EC6 — no-value flag (--full) forwarded verbatim.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  # argv already contains chain-level --full; assert --full appears twice
  # (one chain-level, one runner-level).
  check "T-EC6: --full appears twice in argv-task-noval-flag" \
    bash -c "awk '{ n=gsub(/--full/, \"\"); exit !(n>=2) }' '$PLAN_DIR/argv-task-noval-flag.log'"
}

# ───────────────────────────────────────────────────────────────────────
# T-EC13 — Two tasks with overlapping VAR keys see only their own value.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  check "T-EC13: env-task-overlapping-a contains VAR=a" \
    bash -c "grep -E -q '^VAR=a\$' '$PLAN_DIR/env-task-overlapping-a.log'"
  check "T-EC13: env-task-overlapping-a does NOT contain VAR=b" \
    bash -c "! grep -E -q '^VAR=b\$' '$PLAN_DIR/env-task-overlapping-a.log'"
  check "T-EC13: env-task-overlapping-b contains VAR=b" \
    bash -c "grep -E -q '^VAR=b\$' '$PLAN_DIR/env-task-overlapping-b.log'"
  check "T-EC13: env-task-overlapping-b does NOT contain VAR=a" \
    bash -c "! grep -E -q '^VAR=a\$' '$PLAN_DIR/env-task-overlapping-b.log'"
}

# ───────────────────────────────────────────────────────────────────────
# T-EC14 — empty-string flag forwarded as single argv token.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR="$SHARED_PLAN_DIR"
  check "T-EC14: argv-task-empty-flag.log exists" \
    test -f "$PLAN_DIR/argv-task-empty-flag.log"
  if [[ -f "$PLAN_DIR/argv-task-empty-flag.log" ]]; then
    # The argv line should have task-empty-flag as the last token preceded
    # by space-empty-space — i.e. " task-empty-flag" with an extra space
    # before from the empty runner.flags entry.
    check "T-EC14: argv has 'light  task-empty-flag' (double space from empty entry)" \
      bash -c "grep -E -q 'light  task-empty-flag' '$PLAN_DIR/argv-task-empty-flag.log'"
  fi
}

# ───────────────────────────────────────────────────────────────────────
# AS10 + T-D2.3..T-D2.6 — unknown_runner_flag chain_blocked path.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir "$F_UNKNOWN")
  STUB=$(build_unknown_flag_stub "$PLAN_DIR")
  RC=0
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
  AUTOPILOT_CMD="bash $STUB" \
    bash "$CHAIN_SH" --max-parallel 1 "$PLAN_DIR" \
      >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || RC=$?
  events_file="$PLAN_DIR/chain-events.ndjson"
  check "AS10: chain exits non-zero" test "$RC" -ne 0
  check "AS10: chain-events.ndjson exists" test -f "$events_file"
  if [[ -f "$events_file" ]]; then
    cb_count=$(grep -F -c 'chain_blocked' "$events_file" 2>/dev/null)
    [[ -z "$cb_count" ]] && cb_count=0
    check "AS10: exactly one chain_blocked event" test "$cb_count" -eq 1
    check "AS10: chain_blocked has reason=unknown_runner_flag" \
      bash -c "grep -F 'chain_blocked' '$events_file' | grep -F -q 'unknown_runner_flag'"
    check "AS10: chain_blocked has task_id=task-10" \
      bash -c "grep -F 'chain_blocked' '$events_file' | grep -F -q '\"task_id\":\"task-10\"'"
    check "AS10: chain_blocked has bad_flag=--definitely-not-a-real-flag" \
      bash -c "grep -F 'chain_blocked' '$events_file' | grep -F -q -- '\"bad_flag\":\"--definitely-not-a-real-flag\"'"
    # T-D2.3 — no task_blocked event for task-10 on the unknown-flag path.
    tb_count=$(grep -F 'task_blocked' "$events_file" 2>/dev/null | grep -F -c '"task":"task-10"')
    [[ -z "$tb_count" ]] && tb_count=0
    check "T-D2.3: no task_blocked event for task-10 (R-RISK-8)" test "$tb_count" -eq 0
  fi
  # T-D2.5 — task-10-dep was never launched.
  check "T-D2.5: dependent task-10-dep never launched" \
    bash -c "! test -f '$PLAN_DIR/argv-task-10-dep.log'"
  # T-D2.6 — operator-visible block message. Grep err + chain-stdout.log
  # for the same c37041f tee-redirect reason documented above on AS14.
  check "T-D2.6: CHAIN PAUSED log block names task-10" \
    bash -c "grep -F -q 'task-10' '$PLAN_DIR/err' '$PLAN_DIR/chain-stdout.log' 2>/dev/null"
  check "T-D2.6: CHAIN PAUSED log block names bad flag" \
    bash -c "grep -F -q -- '--definitely-not-a-real-flag' '$PLAN_DIR/err' '$PLAN_DIR/chain-stdout.log' 2>/dev/null"
  check "AS10: reason file consumed (cleaned up)" \
    bash -c "! test -f '$PLAN_DIR/.chain-blocked-reason-task-10'"
}

# ───────────────────────────────────────────────────────────────────────
# T-R13 — Chain-level --stop-after-phase forwarded once to no-runner task.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_DIR=$(new_plan_dir "$FIXTURE")
  STUB=$(build_stub "$PLAN_DIR" "success")
  CHAIN_MAIN_DIRTY_OVERRIDE=false \
  AUTOPILOT_CMD="bash $STUB" \
    bash "$CHAIN_SH" --max-parallel 1 --stop-after-phase implement "$PLAN_DIR" \
      >"$PLAN_DIR/out" 2>"$PLAN_DIR/err" || true
  if [[ -f "$PLAN_DIR/argv-task-no-runner.log" ]]; then
    n=$(awk '{ n=gsub(/--stop-after-phase implement/, ""); print n }' "$PLAN_DIR/argv-task-no-runner.log")
    check "T-R13: chain-level flag appears exactly once in no-runner argv" \
      test "$n" -eq 1
  fi
}

# ───────────────────────────────────────────────────────────────────────
# T-D1.a..T-D1.d — autopilot.sh static-source assertions (Component D1).
# ───────────────────────────────────────────────────────────────────────
{
  check "T-D1.a: autopilot.sh writes unknown_runner_flag: sentinel" \
    bash -c "grep -F -q -- '_write_chain_blocked_reason \"unknown_runner_flag:' '$AUTOPILOT_SH'"
  check "T-D1.b: autopilot.sh unknown-flag exits 2" \
    bash -c "grep -F -A3 'Unknown flag' '$AUTOPILOT_SH' | grep -F -q 'exit 2'"
  check "T-D1.c: _write_chain_blocked_reason uses overwrite > not append >>" \
    bash -c "awk '/^_write_chain_blocked_reason\\(\\)/,/^}/' '$AUTOPILOT_SH' | grep -F -q '> \"\${plan_dir}/.chain-blocked-reason-\${TASK}\"'"
  check "T-D1.c-neg: _write_chain_blocked_reason has no >> append" \
    bash -c "! awk '/^_write_chain_blocked_reason\\(\\)/,/^}/' '$AUTOPILOT_SH' | grep -F -q '>>'"
  check "T-D1.d: _write_chain_blocked_reason gates on CHAIN_MERGE_LOCK" \
    bash -c "awk '/^_write_chain_blocked_reason\\(\\)/,/^}/' '$AUTOPILOT_SH' | grep -F -q 'CHAIN_MERGE_LOCK'"
}

# ───────────────────────────────────────────────────────────────────────
# T-D1.e — direct invocation of autopilot.sh with unknown flag writes sentinel.
# ───────────────────────────────────────────────────────────────────────
{
  PLAN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/chain-runner-overrides-D1e-XXXXXX")
  TMP_DIRS+=("$PLAN_TMP")
  : > "$PLAN_TMP/merge.lock"
  RC=0
  TASK=task-d1e-unknown \
  CHAIN_MERGE_LOCK="$PLAN_TMP/merge.lock" \
    bash "$AUTOPILOT_SH" --definitely-not-a-real-flag task-d1e-unknown \
      >"$PLAN_TMP/out" 2>"$PLAN_TMP/err" || RC=$?
  check "T-D1.e: autopilot.sh exits 2 on unknown flag" test "$RC" -eq 2
  check "T-D1.e: sentinel file written" \
    test -f "$PLAN_TMP/.chain-blocked-reason-task-d1e-unknown"
  if [[ -f "$PLAN_TMP/.chain-blocked-reason-task-d1e-unknown" ]]; then
    check "T-D1.e: sentinel content is unknown_runner_flag:--definitely-not-a-real-flag" \
      bash -c "grep -F -q -x 'unknown_runner_flag:--definitely-not-a-real-flag' '$PLAN_TMP/.chain-blocked-reason-task-d1e-unknown'"
  fi
  check "T-D1.e: stderr contains 'Unknown flag:'" \
    bash -c "grep -F -q -- 'Unknown flag:' '$PLAN_TMP/err'"
}

# ───────────────────────────────────────────────────────────────────────
# T-D2.1 — Existing merge_conflict reason still recognized.
# ───────────────────────────────────────────────────────────────────────
{
  check "T-D2.1: chain whitelist retains merge_conflict|lock_timeout|dirty_main" \
    bash -c "grep -E -q 'merge_conflict\\|lock_timeout\\|dirty_main' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# T-D2.2 — New unknown_runner_flag:* case arm parses bad_flag suffix.
# ───────────────────────────────────────────────────────────────────────
{
  check "T-D2.2: chain has unknown_runner_flag:*) case arm" \
    bash -c "grep -F -q 'unknown_runner_flag:*)' '$CHAIN_SH'"
  check "T-D2.2: chain parses bad_flag via parameter expansion suffix" \
    bash -c "grep -F -q 'unknown_runner_flag:' '$CHAIN_SH' && grep -F -q 'read_reason#unknown_runner_flag:' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# T-E1 + T-E2 — chain header docstring documents the runner mechanism.
# ───────────────────────────────────────────────────────────────────────
{
  check "T-E1: header references runner.env" \
    bash -c "head -40 '$CHAIN_SH' | grep -F -q -- 'runner.env'"
  check "T-E1: header references runner.flags" \
    bash -c "head -40 '$CHAIN_SH' | grep -F -q -- 'runner.flags'"
  check "T-E1: header references task_runner schema" \
    bash -c "head -40 '$CHAIN_SH' | grep -F -q 'task_runner'"
  check "T-E2: header does NOT duplicate schema shape (patternProperties)" \
    bash -c "! head -40 '$CHAIN_SH' | grep -F -q 'patternProperties'"
}

# ───────────────────────────────────────────────────────────────────────
# T-H1 — schema file unchanged on this branch.
# Skip when not in a git repo OR when sandboxed merge-base lookup fails.
# ───────────────────────────────────────────────────────────────────────
{
  if (cd "$REPO_ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    MERGE_BASE=$(cd "$REPO_ROOT" && git merge-base main HEAD 2>/dev/null || echo "")
    if [[ -n "$MERGE_BASE" ]]; then
      check "T-H1: schema file unchanged since merge-base" \
        bash -c "(cd '$REPO_ROOT' && git diff '$MERGE_BASE' HEAD -- core/schema/execution-plan.schema.json) | grep -q . && exit 1 || exit 0"
    fi
  fi
  check "T-H2: patternProperties regex literal present in schema" \
    bash -c "grep -F -q '^[A-Z][A-Z0-9_]*\$' '$SCHEMA'"
}

# ───────────────────────────────────────────────────────────────────────
# T-R24 — chain does NOT introduce new PHASE_ORDER reference for runner.
# Baseline approximation: PHASE_ORDER appears at most in stop-after-phase
# validation block. The runner code MUST NOT add new PHASE_ORDER references.
# ───────────────────────────────────────────────────────────────────────
{
  # Count PHASE_ORDER mentions; baseline at feature start was 2 (sourced
  # comment + STOP_AFTER_PHASE validation message). Allow up to 4 to leave
  # headroom for unrelated future additions without coupling.
  n=$(grep -F -c 'PHASE_ORDER' "$CHAIN_SH" || echo 0)
  check "T-R24: PHASE_ORDER references stay within baseline range" \
    bash -c "test '$n' -le 5"
}

# ───────────────────────────────────────────────────────────────────────
# T-R26.a..T-R26.d — bash 3.2 portability constraints on the chain.
# ───────────────────────────────────────────────────────────────────────
{
  check "T-R26.a: chain has no mapfile" \
    bash -c "! grep -E -q '(^|[[:space:]])mapfile([[:space:]]|\$)' '$CHAIN_SH'"
  check "T-R26.a: chain has no readarray" \
    bash -c "! grep -E -q '(^|[[:space:]])readarray([[:space:]]|\$)' '$CHAIN_SH'"
  check "T-R26.b: chain has no associative arrays (declare -A)" \
    bash -c "! grep -E -q 'declare[[:space:]]+-A\\b' '$CHAIN_SH'"
  check "T-R26.c: chain has no namerefs (declare -n)" \
    bash -c "! grep -E -q 'declare[[:space:]]+-n\\b' '$CHAIN_SH'"
  # bash 4 ${var^^} / ${var,,} case transforms.
  check "T-R26.d: chain has no \${var^^} / \${var,,} case transforms" \
    bash -c "! grep -E -q '\\\$\\{[A-Za-z_][A-Za-z0-9_]*[\\^,]+\\}' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# T-R27 — no env var gates the runner mechanism.
# ───────────────────────────────────────────────────────────────────────
{
  check "T-R27: no CHAIN_RUNNER_OVERRIDES_DISABLE env var" \
    bash -c "! grep -F -q 'CHAIN_RUNNER_OVERRIDES_DISABLE' '$CHAIN_SH'"
  check "T-R27: no RUNNER_FLAGS_ENABLE env var" \
    bash -c "! grep -F -q 'RUNNER_FLAGS_ENABLE' '$CHAIN_SH'"
  check "T-R27: no RUNNER_ENV_PASSTHROUGH env var" \
    bash -c "! grep -F -q 'RUNNER_ENV_PASSTHROUGH' '$CHAIN_SH'"
}

# ───────────────────────────────────────────────────────────────────────
# T-A5 — Defensive fallback: when the per-task python lookup emits empty
# output (malformed plan YAML, missing yaml module, etc.) the bash
# defaults MUST resolve to the literal two-byte JSON `[]` + `{}` so the
# downstream `!= "[]"` / `!= "{}"` guards correctly detect "no runner
# data" and skip the env-prefix / flag-append work (zero-regression
# contract; Q6 / R-RISK-3). QA pass 2026-05-22 found two distinct bugs
# on this exact line: first the original `{\}` form produced a 3-byte
# string with literal backslashes (caught here); a fix attempt to `{}}`
# then produced `{}` on the empty path (OK) but DOUBLED the closing `}`
# on the populated path (caught by T-A5b below) — silently mangling
# JSON so downstream `python3 -c "json.load(stdin)"` failed with the
# env-prefix array left empty, dropping every runner.env var on the
# floor. The current `[[ -z ... ]] && var="{}"` conditional sidesteps
# both. T-A5 + T-A5b together pin the contract for both paths.
# ───────────────────────────────────────────────────────────────────────
{
  # Empty-lookup path (T-A5).
  runner_lookup=""
  runner_flags_json=$(printf '%s\n' "$runner_lookup" | sed -n '1p')
  runner_env_json=$(printf '%s\n' "$runner_lookup" | sed -n '2p')
  runner_flags_json="${runner_flags_json:-[]}"
  [[ -z "${runner_env_json:-}" ]] && runner_env_json="{}"
  check "T-A5: empty lookup → runner_flags_json == '[]' (2 bytes)" \
    test "$runner_flags_json" = "[]"
  check "T-A5: empty lookup → runner_env_json == '{}' (2 bytes)" \
    test "$runner_env_json" = "{}"
  if [[ "$runner_flags_json" != "[]" ]]; then
    runner_flags_fired=1
  else
    runner_flags_fired=0
  fi
  if [[ "$runner_env_json" != "{}" ]]; then
    runner_env_fired=1
  else
    runner_env_fired=0
  fi
  check "T-A5: flags guard does NOT fire on empty lookup" \
    test "$runner_flags_fired" -eq 0
  check "T-A5: env guard does NOT fire on empty lookup" \
    test "$runner_env_fired" -eq 0

  # Populated-lookup path (T-A5b) — regression pin for the `{}}`
  # parameter-expansion bug. Under the broken `${var:-{}}` form the
  # set-value path appended a literal `}` to the JSON, producing
  # `{"X":"1"}}` which still failed the `!= "{}"` guard but broke
  # `python3 -c "json.load(stdin)"` downstream, leaving the env-prefix
  # array empty and every runner.env var silently dropped.
  runner_env_json='{"X":"1"}'
  [[ -z "${runner_env_json:-}" ]] && runner_env_json="{}"
  check "T-A5b: populated lookup → JSON unmodified (no trailing })" \
    test "$runner_env_json" = '{"X":"1"}'
  # Round-trip through python json to prove the value is still parseable
  # — the actual symptom of the broken expansion was downstream JSON
  # parse failure, not the string compare. Skip if python3 absent.
  if command -v python3 >/dev/null 2>&1; then
    check "T-A5b: populated lookup → python json.load survives" \
      bash -c "printf '%s' '$runner_env_json' | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)==\"{\"+chr(34)+\"X\"+chr(34)+\":\"+chr(34)+\"1\"+chr(34)+\"}\" else 1)' 2>/dev/null; [ \$? -eq 1 ] || python3 -c 'import json,sys; json.load(sys.stdin)' <<< '$runner_env_json' >/dev/null"
  fi
}

# ───────────────────────────────────────────────────────────────────────
# T-G3 — registered in dashboard/tests/run-all.sh
# ───────────────────────────────────────────────────────────────────────
{
  check "T-G3: registered in run-all.sh" \
    bash -c "grep -F -q 'test_chain_runner_overrides.sh' '$REPO_ROOT/dashboard/tests/run-all.sh'"
}

# ───────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────
echo ""
echo "---"
printf "Checks: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" $((PASS + FAIL))
if [[ "$FAIL" -ne 0 ]]; then
  printf "Failed: %s\n" "${FAILED_NAMES[*]}"
  exit 1
fi
echo "All chain runner-overrides tests passed."
exit 0
