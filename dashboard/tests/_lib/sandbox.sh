#!/usr/bin/env bash
# Sandbox capability detection for the dashboard test runner.
#
# Several dashboard suites are git-fixture integration tests: they `git init`
# a temp project to mimic a monitored repo. The Claude Code Seatbelt sandbox
# (used by autopilot's `claude -p` phases) BLOCKS writes to `.git/config` and
# `.git/hooks`, so `git init` hard-fails (exit 128, "Operation not permitted")
# inside it. run-all.sh uses these helpers to SKIP those suites when git repo
# creation is unavailable — they run instead in the orchestrator integration
# gate (unsandboxed). This keeps the sandboxed agent from drowning in spurious
# failures while still guaranteeing the suites run where git works.
#
# Pure helpers, sourced by run-all.sh and unit-tested in isolation.

# git_repo_supported: return 0 (true) if a git repo can be created here, else 1.
# Probes with a throwaway repo and cleans it up. Never prints.
git_repo_supported() {
  local probe ok
  probe="$(mktemp -d "${TMPDIR:-/tmp}/gitprobe.XXXXXX" 2>/dev/null)" || probe=""
  if [ -z "$probe" ]; then
    probe="${TMPDIR:-/tmp}/.gitprobe-$$-${RANDOM:-0}"
    mkdir -p "$probe" 2>/dev/null || return 1
  fi
  if git -C "$probe" init -q >/dev/null 2>&1 && [ -f "$probe/.git/config" ]; then
    ok=0
  else
    ok=1
  fi
  rm -rf "$probe" 2>/dev/null || true
  return "$ok"
}

# run_bounded <timeout_secs> <cmd...>: run cmd with a HARD timeout (SIGTERM,
# then SIGKILL after a grace period) so a hanging suite can't wedge the runner —
# a dashboard suite was observed to hang and ignore SIGINT (canary-models
# 2026-06-02). Prefers `timeout`, falls back to `gtimeout`, then to no bound if
# neither exists. Returns the command's exit code (124 when the timeout fired).
run_bounded() {
  local secs="$1"; shift
  local bin=""
  if command -v timeout >/dev/null 2>&1; then
    bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    bin="gtimeout"
  fi
  if [ -n "$bin" ]; then
    "$bin" -k 10 "$secs" "$@"
  else
    "$@"
  fi
}

# run_bounded_retry <timeout_secs> <retries> <cmd...>: run cmd bounded; on a
# non-zero exit, retry up to <retries> more times. Returns 0 as soon as an
# attempt succeeds, else the last attempt's exit code. Absorbs the TRANSIENT
# flakiness in the integration suites (random ports can collide, uvicorn boot is
# a timed poll, concurrent-write tests race) so the gate only fails on a
# persistent failure — not a one-off. A brief backoff between attempts lets a
# colliding port free up.
run_bounded_retry() {
  local secs="$1" retries="$2"; shift 2
  local try=0 rc=0
  while :; do
    rc=0
    run_bounded "$secs" "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    # Do NOT retry a timeout (124 from timeout, 137 from SIGKILL): a hang won't
    # resolve by re-running and retrying would double the wait. Surface it now.
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      return "$rc"
    fi
    [ "$try" -ge "$retries" ] && return "$rc"
    try=$((try + 1))
    sleep 1
  done
}

# suite_should_skip <needs> <git_repo_ok>: echo "skip" or "run".
# A git-fixture suite ("git") is skipped only when git repo creation is
# unavailable ("false"). Everything else runs. Single source of the rule.
suite_should_skip() {
  local needs="$1" git_repo_ok="$2"
  # A known-broken suite (hangs / quarantined) is always skipped, regardless of
  # environment, until its underlying bug is fixed. Loud SKIP, not silent.
  if [ "$needs" = "broken" ]; then
    echo "skip"
  elif [ "$needs" = "git" ] && [ "$git_repo_ok" = "false" ]; then
    echo "skip"
  else
    echo "run"
  fi
}

# suite_is_integration <needs>: echo "yes" if the suite belongs to the
# orchestrator integration gate, else "no". The integration set is the
# sandbox-incompatible one: git-fixture suites ("git") and server-bound suites
# ("server"). These can't be trusted inside the agent sandbox and so run
# UNSANDBOXED at the phase gate (real integration gates §4.4). Everything else
# is a unit suite that runs sandboxed inside a feature phase. A "broken"
# (quarantined) suite is NOT integration — it is skipped everywhere until fixed.
# Single source of truth for the `--only-integration` selection (§9).
suite_is_integration() {
  case "$1" in
    git | server) echo "yes" ;;
    *) echo "no" ;;
  esac
}

# suite_run_decision <needs> <git_repo_ok> <only_integration>: echo one of
#   run | skip:unit | skip:sandbox | skip:broken
# The single place the run/skip rule lives. Composes the sandbox rule
# (suite_should_skip) with the gate's `--only-integration` filter:
#   - in only-integration mode the gate runs ONLY integration suites, so a unit
#     suite is skipped ("skip:unit") — it already ran sandboxed in a phase
#     (§4.4 "no redundant unit re-runs");
#   - otherwise the existing sandbox rule applies, and the skip reason is
#     refined to broken (quarantine) vs sandbox (git unavailable).
# run-all.sh maps the token to a human-readable SKIP message.
suite_run_decision() {
  local needs="$1" git_repo_ok="$2" only_integration="${3:-0}"
  # Sandbox / quarantine skips win first — a broken suite is skip:broken in
  # every mode, and a git suite with no git is skip:sandbox regardless of the
  # gate filter (it cannot run there either).
  if [ "$(suite_should_skip "$needs" "$git_repo_ok")" = "skip" ]; then
    if [ "$needs" = "broken" ]; then
      echo "skip:broken"
    else
      echo "skip:sandbox"
    fi
    return 0
  fi
  # The suite is runnable here; the gate then keeps only integration suites.
  if [ "$only_integration" = "1" ] && [ "$(suite_is_integration "$needs")" = "no" ]; then
    echo "skip:unit"
    return 0
  fi
  echo "run"
}
