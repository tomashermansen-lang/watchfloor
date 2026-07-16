#!/usr/bin/env bash
# run_integration_gate — the orchestrator's UNSANDBOXED gate that runs a
# project's integration_test commands (manifest INTEGRATION| records) after
# /static-analysis, for suites the agent sandbox can't run. Mode via
# INTEGRATION_GATE_MODE: warn (report, never fail) | deny (fail on red).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

PASS=0
FAIL=0
check() { if "$2"; then echo "  ok: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/intgate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Drive run_integration_gate with a stubbed parse_manifest (newline-joined
# INTEGRATION|cmd records) and a fast timeout so the test is quick.
run_gate() {
  local mode="$1" records="$2"
  bash -c "
    STREAM_FILE=/dev/null; AUTOPILOT_SID=t; DASHBOARD_DATA=/dev/null; TASK=t
    INTEGRATION_GATE_MODE='$mode'; INTEGRATION_GATE_TIMEOUT=30
    export STREAM_FILE AUTOPILOT_SID DASHBOARD_DATA TASK INTEGRATION_GATE_MODE INTEGRATION_GATE_TIMEOUT
    source '$LIB' 2>/dev/null
    log() { printf '%s\n' \"\$*\"; }
    parse_manifest() { printf '%s\n' '$records'; }
    run_integration_gate '$TMP'; echo \"rc=\$?\"
  " 2>&1
}

test_warn_passes_pipeline_on_failure() {
  local o; o=$(run_gate warn 'INTEGRATION|false')
  echo "$o" | grep -qx 'rc=0' || { echo "    warn mode must not fail the pipeline; got: $o"; return 1; }
}
check "warn mode: failing command does NOT fail the pipeline (rc=0)" test_warn_passes_pipeline_on_failure

test_warn_logs_would_deny() {
  local o; o=$(run_gate warn 'INTEGRATION|false')
  echo "$o" | grep -qi 'would_deny' || { echo "    warn mode should log would_deny; got: $o"; return 1; }
}
check "warn mode: logs WARN (would_deny) on failure" test_warn_logs_would_deny

test_deny_fails_pipeline_on_failure() {
  local o; o=$(run_gate deny 'INTEGRATION|false')
  echo "$o" | grep -qx 'rc=1' || { echo "    deny mode must fail the pipeline (rc=1); got: $o"; return 1; }
}
check "deny mode: failing command fails the pipeline (rc=1)" test_deny_fails_pipeline_on_failure

test_passing_command_succeeds() {
  local o; o=$(run_gate deny 'INTEGRATION|true')
  echo "$o" | grep -qx 'rc=0' || { echo "    passing command should rc=0 even in deny; got: $o"; return 1; }
}
check "passing command succeeds (rc=0) in deny mode" test_passing_command_succeeds

test_no_integration_records_is_noop() {
  local o; o=$(run_gate deny 'SMOKE|bash x.sh')
  echo "$o" | grep -qx 'rc=0' || { echo "    no INTEGRATION records should be a no-op; got: $o"; return 1; }
}
check "no INTEGRATION records → no-op (rc=0)" test_no_integration_records_is_noop

test_runs_all_records() {
  # A later failing record must still be evaluated (overall fails in deny).
  local o; o=$(run_gate deny "INTEGRATION|true
INTEGRATION|false")
  echo "$o" | grep -qx 'rc=1' || { echo "    should evaluate all records; got: $o"; return 1; }
}
check "deny mode: evaluates all records (later failure fails gate)" test_runs_all_records

# ── run_phase_integration_gate: the §5-triggered phase-boundary gate ──
# Wraps run_integration_gate with (a) the conditional trigger — skip entirely
# when the phase diff doesn't touch the manifest's trigger globs — and (b)
# INTEGRATION_REPORT.md capture on failure. Drives it with a stubbed
# parse_manifest, a globs/files pair, and a report path.
run_phase_gate() {
  local mode="$1" records="$2" globs="$3" files="$4" report="$5"
  bash -c "
    STREAM_FILE=/dev/null; AUTOPILOT_SID=t; DASHBOARD_DATA=/dev/null; TASK=t
    INTEGRATION_GATE_MODE='$mode'; INTEGRATION_GATE_TIMEOUT=30
    export STREAM_FILE AUTOPILOT_SID DASHBOARD_DATA TASK INTEGRATION_GATE_MODE INTEGRATION_GATE_TIMEOUT
    source '$LIB' 2>/dev/null
    log() { printf '%s\n' \"\$*\"; }
    parse_manifest() { printf '%s\n' '$records'; }
    run_phase_integration_gate '$TMP' \"\$1\" \"\$2\" '$report'; echo \"rc=\$?\"
  " _ "$globs" "$files"
}

test_phase_gate_skips_when_trigger_misses() {
  # deny mode + a command that WOULD fail: rc=0 proves the command never ran
  # (the trigger didn't fire), not that it ran and passed.
  local r="$TMP/rep-miss.md"; rm -f "$r"
  local o; o=$(run_phase_gate deny 'INTEGRATION|false' 'dashboard/**' 'tests/x.py' "$r")
  echo "$o" | grep -qx 'rc=0' || { echo "    a trigger miss must skip the run (rc=0); got: $o"; return 1; }
  [[ ! -f "$r" ]] || { echo "    a skipped gate must not write a report"; return 1; }
}
check "phase gate: trigger miss → skip, command not run (rc=0)" test_phase_gate_skips_when_trigger_misses

test_phase_gate_runs_when_trigger_hits() {
  local r="$TMP/rep-hit.md"; rm -f "$r"
  local o; o=$(run_phase_gate deny 'INTEGRATION|true' 'dashboard/**' 'dashboard/server/app.py' "$r")
  echo "$o" | grep -qx 'rc=0' || { echo "    trigger hit + passing command → rc=0; got: $o"; return 1; }
}
check "phase gate: trigger hit + pass → rc=0" test_phase_gate_runs_when_trigger_hits

test_phase_gate_warn_does_not_fail() {
  local r="$TMP/rep-warn.md"; rm -f "$r"
  local o; o=$(run_phase_gate warn 'INTEGRATION|false' 'dashboard/**' 'dashboard/x.py' "$r")
  echo "$o" | grep -qx 'rc=0' || { echo "    warn mode must not fail even when fired+failing; got: $o"; return 1; }
}
check "phase gate: fired + failing + warn → rc=0" test_phase_gate_warn_does_not_fail

test_phase_gate_deny_fails_on_failure() {
  local r="$TMP/rep-deny.md"; rm -f "$r"
  local o; o=$(run_phase_gate deny 'INTEGRATION|false' 'dashboard/**' 'dashboard/x.py' "$r")
  echo "$o" | grep -qx 'rc=1' || { echo "    deny mode must fail when fired+failing; got: $o"; return 1; }
}
check "phase gate: fired + failing + deny → rc=1" test_phase_gate_deny_fails_on_failure

test_phase_gate_writes_report_on_failure() {
  local r="$TMP/rep-fail.md"; rm -f "$r"
  run_phase_gate warn 'INTEGRATION|false' 'dashboard/**' 'dashboard/x.py' "$r" >/dev/null
  [[ -f "$r" ]] || { echo "    a fired+failing gate must write INTEGRATION_REPORT.md"; return 1; }
  grep -qi 'FAILED' "$r" || { echo "    the report must record the failing command; got: $(cat "$r")"; return 1; }
}
check "phase gate: failure writes INTEGRATION_REPORT.md" test_phase_gate_writes_report_on_failure

test_phase_gate_empty_globs_always_fires() {
  local r="$TMP/rep-empty.md"; rm -f "$r"
  local o; o=$(run_phase_gate deny 'INTEGRATION|false' '' 'anything.py' "$r")
  echo "$o" | grep -qx 'rc=1' || { echo "    empty globs → always fire (fail-open); got: $o"; return 1; }
}
check "phase gate: empty trigger globs → always fire" test_phase_gate_empty_globs_always_fires

# ── evaluate_phase_integration_checks: chain-facing gate evaluator ──
# Detects kind=integration checklist items, resolves trigger globs (gate's own,
# else manifest fallback), computes the phase diff (stubbed here), and runs the
# §5-triggered gate. Verdict on stdout: none | passed | failed. Drives it with
# stubbed parse_manifest + _phase_changed_files so no real git/suite runs.
run_phase_checks() {
  local mode="$1" records="$2" checklist="$3" files="$4"
  bash -c "
    INTEGRATION_GATE_MODE='$mode'; INTEGRATION_GATE_TIMEOUT=30
    export INTEGRATION_GATE_MODE INTEGRATION_GATE_TIMEOUT
    source '$LIB' 2>/dev/null
    log() { :; }
    parse_manifest() { printf '%s\n' '$records'; }
    _phase_changed_files() { printf '%s\n' '$files'; }
    evaluate_phase_integration_checks '$checklist' '$TMP' '$TMP' 'phaseX'
  "
}

SHELL_ITEM='[{"item":"x","check":{"kind":"shell","cmd":"true"}}]'
INTEG_ITEM='[{"item":"i","check":{"kind":"integration","trigger":["dashboard/**"]}}]'
INTEG_NOTRIG='[{"item":"i","check":{"kind":"integration","trigger":[]}}]'

test_checks_none_when_no_integration_item() {
  local o; o=$(run_phase_checks deny 'INTEGRATION|false' "$SHELL_ITEM" 'dashboard/x.py')
  [[ "$o" == "none" ]] || { echo "    a gate with no integration item → none; got: $o"; return 1; }
}
check "phase checks: no integration item → none" test_checks_none_when_no_integration_item

test_checks_passed_when_fires_and_passes() {
  local o; o=$(run_phase_checks deny 'INTEGRATION|true' "$INTEG_ITEM" 'dashboard/server/app.py')
  [[ "$o" == "passed" ]] || { echo "    fired + passing → passed; got: $o"; return 1; }
}
check "phase checks: trigger hit + pass → passed" test_checks_passed_when_fires_and_passes

test_checks_passed_when_trigger_misses() {
  # Trigger miss → gate not blocked (the integration check is satisfied by being
  # out of scope), even though the command WOULD fail in deny had it run.
  local o; o=$(run_phase_checks deny 'INTEGRATION|false' "$INTEG_ITEM" 'tests/unrelated.py')
  [[ "$o" == "passed" ]] || { echo "    trigger miss → passed (not blocked); got: $o"; return 1; }
}
check "phase checks: trigger miss → passed (skipped, not blocked)" test_checks_passed_when_trigger_misses

test_checks_failed_when_fires_and_fails_deny() {
  local o; o=$(run_phase_checks deny 'INTEGRATION|false' "$INTEG_ITEM" 'dashboard/x.py')
  [[ "$o" == "failed" ]] || { echo "    fired + failing + deny → failed; got: $o"; return 1; }
}
check "phase checks: trigger hit + fail + deny → failed" test_checks_failed_when_fires_and_fails_deny

test_checks_failopen_when_diff_unknown() {
  # Empty changed-files (can't determine the phase diff) → FIRE anyway
  # (over-approx is the safe error direction). Proven by deny+false → failed.
  local o; o=$(run_phase_checks deny 'INTEGRATION|false' "$INTEG_ITEM" '')
  [[ "$o" == "failed" ]] || { echo "    empty diff must fail-open (fire); got: $o"; return 1; }
}
check "phase checks: unknown diff → fail-open (fires)" test_checks_failopen_when_diff_unknown

test_checks_trigger_fallback_to_manifest() {
  # Gate declares no trigger → fall back to the manifest's INTEGRATION_TRIGGER.
  local o; o=$(run_phase_checks deny $'INTEGRATION|false\nINTEGRATION_TRIGGER|dashboard/**' "$INTEG_NOTRIG" 'dashboard/x.py')
  [[ "$o" == "failed" ]] || { echo "    manifest-trigger hit should fire; got: $o"; return 1; }
  local o2; o2=$(run_phase_checks deny $'INTEGRATION|false\nINTEGRATION_TRIGGER|dashboard/**' "$INTEG_NOTRIG" 'tests/x.py')
  [[ "$o2" == "passed" ]] || { echo "    manifest-trigger miss should skip; got: $o2"; return 1; }
}
check "phase checks: empty gate trigger → manifest trigger fallback" test_checks_trigger_fallback_to_manifest

# ── phase-integration-gate.sh entrypoint (the chain's subprocess seam) ──
ENTRY="$REPO_ROOT/adapters/claude-code/claude/tools/lib/phase-integration-gate.sh"

test_entrypoint_none_exit0() {
  local o rc
  o=$(printf '%s' "$SHELL_ITEM" | bash "$ENTRY" "$TMP" "$TMP" pX 2>/dev/null); rc=$?
  [[ "$o" == "none" && "$rc" -eq 0 ]] || { echo "    no-integration checklist → none/exit0; got: '$o' rc=$rc"; return 1; }
}
check "entrypoint: no integration item → none, exit 0" test_entrypoint_none_exit0

test_entrypoint_usage_exit2() {
  local rc; printf '' | bash "$ENTRY" onlyonearg >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 2 ]] || { echo "    wrong arg count → exit 2; got rc=$rc"; return 1; }
}
check "entrypoint: usage error → exit 2" test_entrypoint_usage_exit2

# ── Remediation loop (§4.4): orchestrator-driven fix→re-run→escalate ──
# Stub the gate run (an rc sequence: one rc per attempt) and the fixer spawn (a
# counter) so the loop is exercised with no real claude / suite. INTEGRATION_-
# REMEDIATION=1 opts the autonomous loop in (off by default, §6a Guard #4).
run_remediation() {
  local mode="$1" rem="$2" max_iter="$3" seq="$4"
  local chk
  chk=$(printf '[{"item":"i","check":{"kind":"integration","trigger":["dashboard/**"],"remediation":{"agent":"lead-developer","max_iterations":%s,"on_unfixable":"escalate"}}}]' "$max_iter")
  printf '0' > "$TMP/attempt"
  rm -f "$TMP/integration.ESCALATE_phaseR"
  bash -c "
    INTEGRATION_GATE_MODE='$mode'; INTEGRATION_REMEDIATION='$rem'
    export INTEGRATION_GATE_MODE INTEGRATION_REMEDIATION
    source '$LIB' 2>/dev/null
    log() { :; }
    parse_manifest() { :; }
    _phase_changed_files() { printf 'dashboard/x.py\n'; }
    run_phase_integration_gate() {
      local n; n=\$(cat '$TMP/attempt'); n=\$((n + 1)); printf '%s' \"\$n\" > '$TMP/attempt'
      local rc; rc=\$(printf '%s' '$seq' | cut -d' ' -f\"\$n\"); return \${rc:-0}
    }
    : > '$TMP/spawns'
    _integration_remediation_agent() { echo x >> '$TMP/spawns'; }
    v=\$(evaluate_phase_integration_checks \"\$1\" '$TMP' '$TMP' 'phaseR')
    echo \"verdict=\$v spawns=\$(wc -l < '$TMP/spawns' | tr -d ' ')\"
  " _ "$chk"
}

test_rem_passes_first_try_no_spawn() {
  local o; o=$(run_remediation deny 1 2 "0")
  [[ "$o" == "verdict=passed spawns=0" ]] || { echo "    pass-first-try → no fixer spawn; got: $o"; return 1; }
}
check "remediation: passes first run → no fixer spawned" test_rem_passes_first_try_no_spawn

test_rem_fixes_after_one_attempt() {
  local o; o=$(run_remediation deny 1 2 "1 0")
  [[ "$o" == "verdict=passed spawns=1" ]] || { echo "    fail→fix→green → 1 spawn, passed; got: $o"; return 1; }
}
check "remediation: red then fixed → passed after 1 fixer attempt" test_rem_fixes_after_one_attempt

test_rem_escalates_when_unfixable() {
  local o; o=$(run_remediation deny 1 3 "1 1 1")
  [[ "$o" == "verdict=failed spawns=2" ]] || { echo "    never-fixed → max_iter-1 spawns, failed; got: $o"; return 1; }
  [[ -f "$TMP/integration.ESCALATE_phaseR" ]] || { echo "    unfixable must drop an ESCALATE marker"; return 1; }
}
check "remediation: unfixable after max_iterations → escalate + marker" test_rem_escalates_when_unfixable

test_rem_disabled_escalates_without_spawn() {
  local o; o=$(run_remediation deny 0 3 "1 1 1")
  [[ "$o" == "verdict=failed spawns=0" ]] || { echo "    remediation off → escalate, no spawn; got: $o"; return 1; }
  [[ -f "$TMP/integration.ESCALATE_phaseR" ]] || { echo "    deny failure must still escalate when remediation off"; return 1; }
}
check "remediation: OFF by default → deny-fail escalates, no fixer" test_rem_disabled_escalates_without_spawn

test_rem_warn_never_remediates() {
  # WARN: run_phase returns 0 even on a failing command, so the loop never
  # engages — uses the REAL run_phase via stubbed parse_manifest (INTEGRATION|false).
  rm -f "$TMP/spawns2"
  local o
  o=$(bash -c "
    INTEGRATION_GATE_MODE='warn'; INTEGRATION_REMEDIATION='1'; INTEGRATION_GATE_TIMEOUT=30
    export INTEGRATION_GATE_MODE INTEGRATION_REMEDIATION INTEGRATION_GATE_TIMEOUT
    source '$LIB' 2>/dev/null
    log() { :; }
    parse_manifest() { printf 'INTEGRATION|false\n'; }
    _phase_changed_files() { printf 'dashboard/x.py\n'; }
    : > '$TMP/spawns2'
    _integration_remediation_agent() { echo x >> '$TMP/spawns2'; }
    v=\$(evaluate_phase_integration_checks '$INTEG_ITEM' '$TMP' '$TMP' 'pW')
    echo \"verdict=\$v spawns=\$(wc -l < '$TMP/spawns2' | tr -d ' ')\"
  ")
  [[ "$o" == "verdict=passed spawns=0" ]] || { echo "    warn must not remediate or block; got: $o"; return 1; }
}
check "remediation: WARN mode never spawns a fixer (detection-only)" test_rem_warn_never_remediates

# ── Guard #4 (partial): credential scrub for the unsandboxed run ──
# The gate runs fixer-modified code UNSANDBOXED (§6a). Full isolation is an
# ephemeral container; the interim control is stripping credential env vars so
# injected code can't read SSH keys / cloud creds / API tokens from its env.
scrub_args() {
  bash -c "
    source '$LIB' 2>/dev/null
    export $1
    _integration_credential_unset_args | tr '\n' ' '
  "
}

test_scrub_strips_credentials() {
  local o; o=$(scrub_args "MY_API_KEY=secret AWS_SECRET_ACCESS_KEY=x GH_TOKEN=y")
  echo "$o" | grep -q -- "-u MY_API_KEY" || { echo "    *_API_KEY must be scrubbed; got: $o"; return 1; }
  echo "$o" | grep -q -- "-u AWS_SECRET_ACCESS_KEY" || { echo "    AWS_* must be scrubbed; got: $o"; return 1; }
  echo "$o" | grep -q -- "-u GH_TOKEN" || { echo "    GH_TOKEN must be scrubbed; got: $o"; return 1; }
}
check "guard#4: credential env vars are scrubbed (-u)" test_scrub_strips_credentials

test_scrub_keeps_benign_vars() {
  local o; o=$(scrub_args "PATH=/usr/bin HOME=/home/x EDITOR=vim")
  echo "$o" | grep -q -- "-u PATH" && { echo "    PATH must NOT be scrubbed (suite needs it); got: $o"; return 1; }
  echo "$o" | grep -q -- "-u EDITOR" && { echo "    benign vars must survive; got: $o"; return 1; }
  return 0
}
check "guard#4: benign env vars (PATH/HOME/EDITOR) survive the scrub" test_scrub_keeps_benign_vars

echo ""
echo "test_integration_gate: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
