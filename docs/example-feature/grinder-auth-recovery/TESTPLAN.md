<!-- phase: testplan | date: 2026-05-09 | branch: feature/grinder-auth-recovery -->

# Test Plan — grinder-auth-recovery

## Summary

Every requirement in `REQUIREMENTS.md` (R1.1–R6.3) and every component in
`PLAN.md` (C1–C8) is mapped to at least one verifiable scenario below.
Tests follow the existing repo conventions inventoried by `test-explorer`:

- **Bash test harness**: `set -euo pipefail`, named `test_tNN` functions
  invoked via the standard `check "name" test_fn` wrapper, ✓/✗ coloured
  output, `passed`/`failed` counters, exit non-zero on any failure
  (template: `tests/test_classify_phase_exit.sh:24–50`).
- **Library testing**: source `claude-session-lib.sh` inside `bash -c
  "source '$LIB'; ..."` subshells; stub `log()` and `fail_pipeline()`
  before sourcing for tests that exercise `run_phase` / `run_gated_phase`
  without a live grinder (template: `test_classify_phase_exit.sh:64–71`,
  `test_claude_session_lib.sh`).
- **PATH-shim mocks**: `claude` is mocked via a tiny bash script in
  `$TMPDIR/mock-bin/` placed first on `PATH`; the shim emits the chosen
  fixture NDJSON when invoked as `claude -p ...` (template:
  `tests/fixtures/grinder-mechanical/mock-claude.sh`).
- **Fixture isolation**: per-test `TEST_DIR=${TMPDIR}/...$$` plus `trap
  teardown EXIT` cleans up; `$STREAM_FILE`, `$AUTOPILOT_SID`,
  `$DASHBOARD_DATA`, etc. all point inside `$TEST_DIR`.

Two test files ship with this feature, plus three fixture NDJSONs:

| File | Purpose |
|---|---|
| `tests/test_grinder_auth_recovery.sh` | New — primary driver for C1, C3, C4, C5, C6, C7, C8 (R1, R2, R3, R4, R6) |
| `tests/test_classify_phase_exit.sh` | Existing — extended with negative-coverage row to prove the auth classifier does not collide with the timeout reclassifier |
| `tests/fixtures/grinder-auth-recovery/auth_failed_not_logged_in.ndjson` | New — shape (a) from R3.1 |
| `tests/fixtures/grinder-auth-recovery/auth_failed_top_level_error.ndjson` | New — shape (b) from R3.1 |
| `tests/fixtures/grinder-auth-recovery/non_auth_failure.ndjson` | New — R3.5 negative case (validation-failed, not auth) |

The new test is registered in `dashboard/tests/run-all.sh` next to
`test_run_phase_watchdog.sh` (line 56) so CI picks it up automatically
(R4.6 satisfied + integration with the suite).

`run-all.sh` is the only CI runner; there is no `Makefile` or pytest
discovery in this repo. Registration there is therefore mandatory, not
nice-to-have.

## Scope and Conventions

- **Test types:** `unit` (sourced helper, single function), `integration`
  (sourced lib + stubbed callers), `subprocess` (full bash subprocess
  against `grinder.sh` or `claude-session-lib.sh`), `static` (grep/awk
  assertion against source files), `manual` (operator-driven, recorded
  in the manual test log only).
- **No real `claude` invocation.** Every scenario uses a PATH-shim or
  a fixture NDJSON. R4.5 forbids it; R5.1's manual end-to-end is the
  only exception and is explicitly out-of-scope for the autopilot
  pipeline (it runs in the parent plan's `sonarqube-and-verification`
  phase).
- **Bash 3.2 compatibility.** No associative arrays in any new test
  code.
- **Runtime budget.** The full new test must finish in ≤ 30s on the
  operator's machine (R4.4); each scenario is ≤ 5s in practice.

## C1 — `auth_preflight_probe` scenarios

| # | Scenario | Req | Type | Fixture / Mock notes |
|---|---|---|---|---|
| C1.1 | Probe success path returns 0 silently (no stdout/stderr beyond what `cmd_run` already emits) | R1.4, R6.1 | integration | PATH-shim `claude` emits a non-auth-failed result event (`{"type":"result","subtype":"success","is_error":false,...}`); assert `$?==0`, captured stderr empty, captured stdout empty (probe is silent on success) |
| C1.2 | Probe success path completes within 1s wall-clock | R1.2 | integration | Same shim as C1.1; wrap invocation in `time` (or `EPOCHREALTIME` arithmetic); assert duration < 1.0s. Soft target — see RK-3; hard ceiling is C1.7 |
| C1.3 | `GRINDER_SKIP_AUTH_PREFLIGHT=1` short-circuits, writes WARNING, returns 0 without invoking `claude` | R1.7, EC-D, EC-L | integration | No shim on PATH (or shim that exits 99 if invoked); export var; assert `$?==0`, stderr contains exact line `WARNING: auth preflight skipped via GRINDER_SKIP_AUTH_PREFLIGHT`, shim invocation counter file is absent |
| C1.4 | `claude` binary absent from PATH → exit 2, stderr `claude binary not found on PATH` | R1.6, EC-B | integration | Set `PATH=/nonexistent`; assert `$?==2`, stderr contains exact line |
| C1.5 | Probe sees `result/is_error/Not logged in` shape → exit 2, stderr `claude auth required — run claude login and retry` | R1.5, R6.2 | integration | Shim emits fixture `auth_failed_not_logged_in.ndjson`; assert `$?==2`, stderr line exact match |
| C1.6 | Probe sees top-level `error:"authentication_failed"` shape → exit 2, same operator message | R1.5, R6.2 | integration | Shim emits fixture `auth_failed_top_level_error.ndjson`; assert `$?==2`, stderr line exact match |
| C1.7 | Probe times out at `AUTH_PROBE_TIMEOUT_S=5` → exit 2, stderr `claude auth probe timed out after 5s` | R1.3, R1.6, EC-C | integration | Shim sleeps 30s; override `AUTH_PROBE_TIMEOUT_S=2` to keep test fast; assert exit 2 and stderr line (with the overridden timeout reflected in the message) |
| C1.8 | Probe with non-zero rc but non-auth output → exit 2, stderr `claude auth probe failed (exit <rc>)` | R1.5 (defensive), C1 spec | integration | Shim exits 1, emits a non-auth result event; assert exit 2 + correct rc-bearing stderr line |
| C1.9 | Probe writes nothing under `$HOME` beyond what `claude` itself already creates | R6.3 | integration | Snapshot `find $HOME -newer <baseline>` before/after; assert no new files in `$HOME` excluding `$TMPDIR` and `docs/grinder/` |
| C1.10 | Probe runs with the eight-var proxy env strip (so the probe is exercised under the same env as `run_phase`, R2 symmetry) | R2.1, C1 spec | static | `grep -c '\-u no_proxy\|-u NO_PROXY' adapters/claude-code/claude/tools/grinder.sh` ≥ 1 in `auth_preflight_probe` body |
| C1.11 | Probe is exposed as a function (defined) | C1 contract | unit | `bash -c "source '$GRINDER'; type -t auth_preflight_probe"` returns `function` |

## C2 — `cmd_run` / `cmd_resume` probe-insertion scenarios

| # | Scenario | Req | Type | Fixture / Mock notes |
|---|---|---|---|---|
| C2.1 | `grinder.sh run` invokes the probe before `acquire_grinder_lock` (probe runs after pause/validate/staleness/state checks) | R1.1 | subprocess | PATH-shim `claude` emits auth-failed; run `bash grinder.sh run --project-dir <fixture>`; assert `$?==2`, stderr contains the auth-required line, AND the lock file `<grinder-dir>/.lock` is absent (because the probe halts before `acquire_grinder_lock`) |
| C2.2 | `grinder.sh resume` invokes the probe at re-entry (EC-G) | R1.1 (extended), EC-G | subprocess | Same as C2.1 but with `resume` subcommand; same assertions |
| C2.3 | `grinder.sh discover` does NOT invoke the probe | R1.8 | subprocess | Shim records invocations to a counter file; run `discover`; assert counter file absent |
| C2.4 | `grinder.sh pause` does NOT invoke the probe | R1.8 | subprocess | Same harness; run `pause` |
| C2.5 | `grinder.sh status` does NOT invoke the probe | R1.8 | subprocess | Same harness; run `status` |
| C2.6 | `grinder.sh ack-review` does NOT invoke the probe | R1.8 | subprocess | Same harness; run `ack-review` against a fixture review state |
| C2.7 | Probe ordering: pause-check is honoured BEFORE the probe (PAUSE sentinel still wins) | R1.1, EC-A | subprocess | `touch <grinder-dir>/PAUSE`; run `grinder.sh run`; assert exit 0 (pause path), shim invocation counter absent (probe never runs because `cmd_run` returns at the pause check) |
| C2.8 | Probe ordering: invalid plan halts BEFORE the probe (no shim invocation on plan-validation failure) | R1.1 ordering | subprocess | Use `tests/fixtures/grinder-orchestrator/invalid-plan.yaml`; run `grinder.sh run`; assert non-zero exit (validation), shim counter absent |

## C3 — `_auth_failed_classify` scenarios

| # | Scenario | Req | Type | Fixture / Mock notes |
|---|---|---|---|---|
| C3.1 | Function is defined | C3 contract | unit | `bash -c "source '$LIB'; type -t _auth_failed_classify"` returns `function` |
| C3.2 | Returns `not_logged_in` for shape (a): `subtype:"success"` + `is_error:true` + `result` containing literal `Not logged in` | R3.1 | unit | Pass `auth_failed_not_logged_in.ndjson` path; capture stdout; assert exact `not_logged_in` |
| C3.3 | Returns `authentication_failed` for shape (b): top-level `error:"authentication_failed"` | R3.1 | unit | Pass `auth_failed_top_level_error.ndjson`; assert exact `authentication_failed` |
| C3.4 | Returns empty string for non-matching result events (e.g., `is_error:true` + `result:"validation failed"`) | R3.5, EC-F | unit | Pass `non_auth_failure.ndjson`; assert stdout empty |
| C3.5 | Returns empty for events whose `type` is not `result` (assistant, user, system, tool_use) | R3.1 (predicate scope) | unit | Hand-rolled fixture stream containing only `{"type":"assistant",...}` and `{"type":"user",...}` events with `error:"authentication_failed"` payloads embedded; assert stdout empty (predicate must gate on `type=="result"`) |
| C3.6 | First-match-wins when both shapes appear in the same stream | R3.2, EC-E | unit | Hand-rolled fixture with shape (a) on line 1, shape (b) on line 3; assert stdout = `not_logged_in` (the first match), not duplicated, not `authentication_failed` |
| C3.7 | Malformed JSON line is skipped without raising | R3.6, EC-F | unit | Hand-rolled fixture: line 1 = `{"type":"resu` (truncated), line 2 = valid auth-failed shape; assert stdout = expected reason, no python traceback in stderr |
| C3.8 | Missing input file does not crash | R3.6 (defensive) | unit | Pass a path that does not exist; assert exit 0 OR clean empty stdout, no traceback |
| C3.9 | Empty file returns empty | R3.6 | unit | `: > $TMPDIR/empty.ndjson`; pass path; assert empty stdout |
| C3.10 | Predicate does not fire on assessor-output JSON (defence: assessor output has no `type:"result"` field, see RK-5) | RK-5 | unit | Synthetic assessor JSON object literally containing `error:"authentication_failed"` but no `type` field, written one-per-line; assert stdout empty |
| C3.11 | Result event with `subtype:"success"` + `is_error:false` (real success) does NOT match shape (a) | R3.1 (negative — `is_error` gate) | unit | Fixture line: `{"type":"result","subtype":"success","is_error":false,"result":"Not logged in fyi"}`; assert empty stdout (the `is_error:true` clause must gate the literal-substring match) |

## C4 — `_emit_auth_failed_event` scenarios

| # | Scenario | Req | Type | Fixture / Mock notes |
|---|---|---|---|---|
| C4.1 | Function is defined | C4 contract | unit | `type -t` returns `function` |
| C4.2 | Appends exactly one NDJSON line to `$STREAM_FILE` | R3.2 | unit | Set `STREAM_FILE=$TMPDIR/stream.ndjson`; call `_emit_auth_failed_event "phase-x" "sid-y" "not_logged_in"`; assert `wc -l < $STREAM_FILE` == 1 |
| C4.3 | Emitted line is valid JSON with the exact wire format | R3.2 | unit | `python3 -c "import json,sys;e=json.loads(open(sys.argv[1]).read().strip());assert e['type']=='auth_failed' and e['phase']=='phase-x' and e['session_id']=='sid-y' and e['reason']=='not_logged_in' and 'ts' in e"` |
| C4.4 | `ts` field is UTC ISO-8601 (`YYYY-MM-DDTHH:MM:SSZ`) | R3.2 | unit | Regex assertion on the `ts` value: `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$` |
| C4.5 | Append failure (unwritable `$STREAM_FILE`) does not abort the caller | C4 spec, parity with `_emit_orchestrator_kill_event` | unit | `STREAM_FILE=/dev/full` (or `chmod 000` a tmp file); call function; assert exit 0, no aborted shell |
| C4.6 | Multiple back-to-back calls produce N distinct lines (positive control for C4.2) | R3.2 (idempotency invariant comes from the caller) | unit | Call 3× with different reasons; assert 3 lines, each parses as JSON, distinct timestamps OR same-second timestamps allowed |
| C4.7 | Empty `session_id` is accepted (informational field) | C5 contract (sid extraction may fail) | unit | Call with `""` for sid; assert valid JSON line with empty `session_id` field |

## C5 — `run_phase` post-stream auth hook scenarios

| # | Scenario | Req | Type | Fixture / Mock notes |
|---|---|---|---|---|
| C5.1 | Hook is NOT invoked when `exit_code == 0` (success-path optimisation) | R3.5, perf | integration | Mock claude shim emits a clean success result event; spy on `_auth_failed_classify` (replace with a counter shim); assert counter file shows 0 invocations |
| C5.2 | Hook IS invoked when `exit_code != 0` and classifier matches → emits one auth_failed event in `$STREAM_FILE`, returns `$AUTH_FAILED_EXIT_CODE` (=42) | R3.1, R3.2, R3.3 | integration | Source lib, stub `log`/`fail_pipeline`/`dashboard_event`, set `STREAM_FILE`, write fixture `auth_failed_not_logged_in.ndjson` to a temp `phase_ndjson` path, then drive run_phase via a minimal harness or call the post-stream block directly via a test-only entry point; assert exit code = 42 and exactly 1 `"type":"auth_failed"` line in stream |
| C5.3 | Hook returns sentinel for shape (b) too (parity with shape (a)) | R3.1, R3.3 | integration | Same as C5.2 with `auth_failed_top_level_error.ndjson`; assert reason = `authentication_failed` in the emitted event |
| C5.4 | Hook does NOT fire when `exit_code != 0` AND classifier returns empty (non-auth failure path) | R3.5, EC-F | integration | Same harness with `non_auth_failure.ndjson`; assert exit code = original non-zero (NOT 42), zero `auth_failed` events in stream |
| C5.5 | Hook is positioned AFTER `_classify_phase_exit` reclassification (so a 124+result event masked to 0 does NOT trigger an auth scan) | RK-4, C5 spec | integration | Provide `phase_ndjson` containing both a result event AND an auth-failed shape; set raw `exit_code=124`; after `_classify_phase_exit` it becomes 0; assert auth hook does NOT fire (because the gate is `exit_code != 0` post-reclassification) |
| C5.6 | Hook is positioned BEFORE `phase_ndjson` cleanup at line 1351 (so the classifier can still read it) | RK-4 | static | `awk` over the modified `run_phase` body: line number of `_auth_failed_classify` invocation < line number of `rm -f "$phase_ndjson"` |
| C5.7 | session_id passed to `_emit_auth_failed_event` matches the value extracted by the existing session-id parser | C5 spec | integration | Fixture includes a session-init event with `session_id:"abc-123"`; assert emitted event contains `"session_id":"abc-123"` |
| C5.8 | Resume loop is NOT entered when the auth hook fires (early `return $AUTH_FAILED_EXIT_CODE` skips the resume path) | C5 spec, R3.4 (no commit) | integration | Spy on resume-loop entry by inserting a marker file write at the resume-loop top; auth-failed run; assert marker file absent |
| C5.9 | The auth hook's returned sentinel matches the named constant (no magic number) | RK-2, project convention | static | `grep -n '\b42\b' adapters/claude-code/claude/tools/lib/claude-session-lib.sh` shows ONLY the `AUTH_FAILED_EXIT_CODE` declaration line; the C5/C6 sites reference `$AUTH_FAILED_EXIT_CODE` |

## C6 — `run_gated_phase` short-circuit scenarios

| # | Scenario | Req | Type | Fixture / Mock notes |
|---|---|---|---|---|
| C6.1 | First-attempt sentinel exit halts retry loop (zero second attempt) | R3.3, R4.3, AC-3 | integration | Stub `run_phase` to return `$AUTH_FAILED_EXIT_CODE`; harness invokes `run_gated_phase` with `max_attempts=2`; spy on `run_phase` invocations via a counter file; assert counter == 1, NOT 2 |
| C6.2 | Operator-visible halt message logged exactly once | R3.4, R6.1 | integration | Stub `log()` to append to a file; assert file contains exactly one line matching `grinder halted: claude authentication lost mid-run — run claude login and re-run grinder.sh run` |
| C6.3 | `track_phase` is invoked with status `"auth_failed"` (NOT `"completed"`, NOT `"failed"`) | R3.4, EC-J | integration | Stub `track_phase` to record args; assert single invocation with second arg = `auth_failed` |
| C6.4 | `track_deviation` is NOT invoked (gated by existing `status == "completed"` check at lib:1242) | R3.4, EC-J | integration | Spy on `track_deviation` via a counter file; assert counter absent |
| C6.5 | `commit_phase` is NOT invoked | R3.4 | integration | Spy on `commit_phase`; assert counter absent |
| C6.6 | `fail_pipeline` is invoked exactly once | R3.4 | integration | Stub `fail_pipeline` to write a marker and `return 1` (so the test process survives the assertions); assert marker present, exactly one invocation |
| C6.7 | Non-auth `run_phase` failure (exit code 1) STILL runs the existing 2-attempt retry (negative parity check) | R3.5, AC-3 | integration | Stub `run_phase` to return 1 always; assert counter == 2 (the existing retry path is unchanged) |
| C6.8 | Non-auth `run_phase` failure (exit code 124, real timeout) STILL runs the existing retry | R3.5 | integration | Stub returns 124; assert counter == 2 |
| C6.9 | Sentinel mismatch (e.g., 41) is treated as a regular failure (boundary case) | R3.3, RK-2 | integration | Stub returns 41; assert counter == 2 (only `$AUTH_FAILED_EXIT_CODE` short-circuits) |
| C6.10 | When `AUTH_FAILED_EXIT_CODE` is overridden via env (e.g., `42 → 50`), C6 still short-circuits on the new value | RK-2, OCP | integration | Export `AUTH_FAILED_EXIT_CODE=50`; stub returns 50; assert counter == 1, halt message logged |

## C7 — `run_phase` env-strip extension scenarios

| # | Scenario | Req | Type | Fixture / Mock notes |
|---|---|---|---|---|
| C7.1 | Initial `run_phase` claude -p invocation strips all 8 proxy vars | R2.1, AC-2 | static | `awk` extracts the `env -u ... claude -p` block at line ~1307; assert all 8 vars present (`ALL_PROXY HTTPS_PROXY HTTP_PROXY NO_PROXY all_proxy https_proxy http_proxy no_proxy`) |
| C7.2 | Resume-path claude -p invocation strips all 8 proxy vars | R2.3, RK-6 | static | Same `awk` against the resume call site (line ~1397); assert all 8 vars present |
| C7.3 | Strip uses `env -u` flags only (no shell-level `unset`) | R2.2 | static | `grep -B2 -A20 'claude -p' claude-session-lib.sh` shows `env -u`, NOT `unset` |
| C7.4 | Parent-shell proxy env survives the strip (the strip is local to the subprocess) | R2.2 | integration | Set `HTTPS_PROXY=mock` in the test harness; invoke a stub run_phase; after invocation assert `[[ "$HTTPS_PROXY" == "mock" ]]` (parent unaffected) |
| C7.5 | Strip on the assessor wire (line 699) is unchanged (regression check — copy target is the source of truth) | R2.1 (parity) | static | `grep -c '\-u no_proxy' claude-session-lib.sh` returns ≥ 3 (assessor + run_phase initial + run_phase resume); the assessor line is the copy target so its presence is the parity baseline |

## C8 — Test infrastructure / Integration scenarios

| # | Scenario | Req | Type | Fixture / Mock notes |
|---|---|---|---|---|
| C8.1 | `tests/test_grinder_auth_recovery.sh` exists, is executable, and follows the standard test-file convention | R4.1 | static | `[[ -x tests/test_grinder_auth_recovery.sh ]]`, file starts with `#!/bin/bash` shebang, has the standard 6-line header (purpose, usage, exit semantics) |
| C8.2 | Test is registered in `dashboard/tests/run-all.sh` so CI invokes it | R4.6, project convention | static | `grep -c 'test_grinder_auth_recovery.sh' dashboard/tests/run-all.sh` == 1 |
| C8.3 | All three fixtures are valid NDJSON (one JSON object per line) | R4.6 | unit | `python3 -c "import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]"` over each fixture file; exit 0 |
| C8.4 | Fixtures live under `tests/fixtures/grinder-auth-recovery/` (folder convention) | R4.6 | static | `[[ -d tests/fixtures/grinder-auth-recovery ]]`; expected files present |
| C8.5 | Test cleans up `$TMPDIR` on EXIT, INT, TERM | R4.5 | unit | Run test; `kill -INT` mid-run; assert `$TEST_DIR` removed afterwards |
| C8.6 | Test does not invoke real `claude` (no real `claude` binary on PATH inside the test) | R4.5 | static + runtime | `grep -c "command -v claude" tests/test_grinder_auth_recovery.sh` does NOT show calls outside the shim setup; runtime: shim is exclusively on PATH during invocations |
| C8.7 | Test does not write outside `tests/` and `$TMPDIR` | R4.5 | runtime | Snapshot `find / -newer <baseline>` excluding `$TMPDIR`/`tests/`; assert empty (best-effort, scoped to `$HOME` and the repo) |
| C8.8 | Test asserts `git status --porcelain` is unchanged at start vs. end (defence-in-depth) | R4.5 | unit | Built into the test's own teardown; proves the shim and fixtures do not leak into the working tree |
| C8.9 | Test runtime ≤ 30s on the operator's machine | R4.4 | runtime | Wrap test in `time`; assert real time < 30s (in practice ≤ 5s) |
| C8.10 | Test exit code is non-zero on any scenario failure (standard `passed`/`failed` counter idiom) | R4.3, project convention | runtime | Force one assertion to fail; assert outer `$?` non-zero |
| C8.11 | All three R4.3 assertions are exercised end-to-end on each of the two auth-failed shapes (positive parity check) | R4.3, AC-4 | integration | Two scenarios (one per shape) each assert: (1) exactly one `"type":"auth_failed"` event in `$STREAM_FILE`, (2) zero `attempt 2/$max_attempts` log lines, (3) overall non-zero exit |

## Cross-Cutting Scenarios

| # | Scenario | Req | Type | Notes |
|---|---|---|---|---|
| X.1 | Single discoverable signal: structured `auth_failed` NDJSON event is the only operator-facing record (no silent retry, no half-baked commit, no swallowed error) | R6.1 | integration | Combination of C5.2, C6.5, C6.6 — the `commit_phase` counter is absent AND the stream has exactly one event AND the halt message is in the log file. Asserted as a final "post-state coherence" check at the end of the integration test |
| X.2 | Every error path writes a single-line stderr message naming the next operator action | R6.2 | integration | Audit: enumerate every `exit 2` / `fail_pipeline` callsite in C1–C6; assert each is preceded by exactly one stderr line with an actionable verb (`run claude login`, `claude binary not found`, `run claude login and re-run grinder.sh run`) |
| X.3 | No new files in operator's `$HOME` beyond what `claude` itself creates | R6.3 | runtime | Already C1.9; cross-listed because R6.3 is a system-wide invariant, not a probe-only one |
| X.4 | Bash 3.2 compatibility: no associative arrays in any new shell code | parent plan constraint | static | `grep -E 'declare -A\|local -A' adapters/claude-code/claude/tools/grinder.sh adapters/claude-code/claude/tools/lib/claude-session-lib.sh tests/test_grinder_auth_recovery.sh` returns no NEW hits relative to baseline |
| X.5 | Constants/named values, not magic numbers | parent plan constraint, RK-2 | static | The numeric literal `42` appears in the lib only inside the `: "${AUTH_FAILED_EXIT_CODE:=42}"` declaration; `5` for the timeout appears only inside the `AUTH_PROBE_TIMEOUT_S=5` declaration |
| X.6 | CLAUDE.md update ships with the code: `adapters/claude-code/claude/CLAUDE.md` documents the preflight + the `GRINDER_SKIP_AUTH_PREFLIGHT` knob | docs constraint | static | `grep -c 'GRINDER_SKIP_AUTH_PREFLIGHT\|auth preflight' adapters/claude-code/claude/CLAUDE.md` ≥ 1 after `/implement` |
| X.7 | Header tables updated: `claude-session-lib.sh` and `grinder.sh` headers list the new tunables | docs constraint | static | `grep -c 'AUTH_FAILED_EXIT_CODE\|AUTH_PROBE_TIMEOUT_S' <head -50 of each file>` ≥ 1 |

## Manual Test Scenarios (operator-driven, recorded in MANUAL_TEST_LOG.md)

These scenarios are NOT run by the autopilot pipeline. They are recorded
here for the parent plan's `sonarqube-and-verification` phase (AC-5,
R5.1, R5.2) and for `/manualtest` to invoke during full-pipeline runs.
The corresponding `task.manualtest_scenarios` entries on the host plan
are the authoritative copy; this list is the testplan-side mirror.

| # | Scenario | Req | Steps |
|---|---|---|---|
| M.1 | E2E grinder run on dotfiles with valid auth completes without any `auth_failed` events | R5.1, R5.2, AC-5 | (a) Ensure `claude` is logged in. (b) Run `bash adapters/claude-code/claude/tools/grinder.sh run --project-dir <dotfiles>`; complete a `pass-mechanical`. (c) Assert `grep -c '"auth_failed"\|"authentication_failed"' docs/grinder/grinder-stream.ndjson` == 0 |
| M.2 | Preflight halt: simulate logged-out state | R1.5, AC-1 | (a) Pre-test: arrange `claude` to be unauthenticated (operator chooses how — usually a temporary token swap). (b) Run `grinder.sh run`. (c) Assert exit 2, stderr line `claude auth required — run claude login and retry`, no lock acquired (`<grinder-dir>/.lock` absent), no batch spawned (`docs/grinder/grinder-stream.ndjson` has no new pass entries) |
| M.3 | Mid-run auth loss + recovery via resume | EC-A, EC-G | (a) Start a long-running grinder. (b) Force-expire auth mid-run (token rotation). (c) Observe halt with the operator-facing message. (d) `claude login` to recover. (e) `grinder.sh resume`. (f) Assert resume completes the remaining batches with zero further `auth_failed` events |
| M.4 | `claude` binary genuinely missing | R1.6, EC-B | (a) `PATH=/usr/bin bash -c 'grinder.sh run --project-dir <dotfiles>'` (PATH excludes `claude`). (b) Assert exit 2, stderr `claude binary not found on PATH` |
| M.5 | Slow network triggers the 5s timeout | R1.3, EC-C | (a) Constrain network (Network Link Conditioner: 100ms latency, 1% loss). (b) Run `grinder.sh run`. (c) On a sufficiently slow link, assert the timeout message; on a fast link, this scenario is informational-only (records the wall-clock latency for RK-3) |
| M.6 | `GRINDER_SKIP_AUTH_PREFLIGHT=1` actually disables the probe in operator-context (so operators can opt out for offline runs) | R1.7, EC-L | (a) `GRINDER_SKIP_AUTH_PREFLIGHT=1 grinder.sh run` with no network. (b) Assert WARNING line in stderr, batches proceed (subject to other failures). The expectation is that this knob is loud — the WARNING must be visible |

## Coverage Map (Requirement → Scenario)

Every requirement in REQUIREMENTS.md (R1.1–R6.3) maps to at least one
scenario above. Every scenario references at least one requirement.

| Requirement | Scenarios |
|---|---|
| R1.1 | C2.1, C2.2, C2.7, C2.8 |
| R1.2 | C1.2 |
| R1.3 | C1.7, M.5 |
| R1.4 | C1.1 |
| R1.5 | C1.5, C1.6, C1.8, M.2 |
| R1.6 | C1.4, C1.7, M.4 |
| R1.7 | C1.3, M.6 |
| R1.8 | C2.3, C2.4, C2.5, C2.6 |
| R2.1 | C7.1, C7.5 |
| R2.2 | C7.3, C7.4 |
| R2.3 | C7.2 |
| R3.1 | C3.2, C3.3, C3.5, C3.11 |
| R3.2 | C3.6, C4.2, C4.3, C5.2 |
| R3.3 | C5.2, C5.3, C6.1, C6.10 |
| R3.4 | C6.2, C6.3, C6.4, C6.5, C6.6 |
| R3.5 | C3.4, C5.1, C5.4, C6.7, C6.8 |
| R3.6 | C3.7, C3.8, C3.9 |
| R4.1 | C8.1 |
| R4.2 | C8.3, C8.4 |
| R4.3 | C8.10, C8.11 |
| R4.4 | C8.9 |
| R4.5 | C8.5, C8.6, C8.7, C8.8 |
| R4.6 | C8.2, C8.4 |
| R5.1 | M.1 |
| R5.2 | M.1 |
| R6.1 | C1.1, X.1 |
| R6.2 | C1.5, C1.6, X.2 |
| R6.3 | C1.9, X.3 |

| Acceptance scenario | Scenarios |
|---|---|
| AC-1 | C2.1, M.2 |
| AC-2 | C7.1, C7.2, C7.5 |
| AC-3 | C5.2, C5.3, C5.4, C6.1, C6.7 |
| AC-4 | C8.11 |
| AC-5 | M.1 |

| Edge case | Scenarios |
|---|---|
| EC-A | M.3 |
| EC-B | C1.4, M.4 |
| EC-C | C1.7, M.5 |
| EC-D | C1.3 |
| EC-E | C3.6 |
| EC-F | C3.4, C3.7, C5.4 |
| EC-G | C2.2, M.3 |
| EC-H | C2.7, C2.8 |
| EC-I | (out-of-scope; lock acquisition is not in the probe path; covered by existing `test_grinder_orchestrator.sh::T*` lock tests) |
| EC-J | C6.3, C6.4 |
| EC-K | C6.10 |
| EC-L | C1.3, M.6 |

| Risk | Scenarios |
|---|---|
| RK-1 | C2.1, C2.2 (both `run` and `resume` paths exercised — the dual coverage IS the disposition. If /review prefers the narrow R1.8 read, only C2.2 fails and it converts to a static check that the resume path explicitly does NOT call the probe) |
| RK-2 | C5.9, C6.10, X.5 |
| RK-3 | C1.2 (soft target), C1.7 (hard ceiling), M.5 (real-network reality check) |
| RK-4 | C5.5, C5.6 |
| RK-5 | C3.10 |
| RK-6 | C7.2 |
| RK-7 | C6.3 (covers the `track_phase` status-string contract; `print_run_summary` rendering is unmodified per RK-7 disposition and not tested) |

## Out-of-Scope (explicitly NOT tested here)

- **Live `claude` end-to-end on the operator's machine.** Covered by
  M.1 in the parent plan's `sonarqube-and-verification` phase, not
  this task's autopilot pipeline.
- **`print_run_summary` rendering of `auth_failed` status.** RK-7
  documents that `print_run_summary` prints the status literal
  without colour-mapping for unknown values (matching the existing
  posture for non-`completed`/non-`failed` rows). The operator-facing
  signal per R6.1 is the stderr halt message + structured NDJSON
  event; the summary table's literal rendering is sufficient and
  no modification to `print_run_summary` is required.
- **Future deviation-flagged retry path.** EC-K's promise (any future
  caller wrapping `run_phase` checks the sentinel) is structurally
  enforced by the named constant, not by an integration test that
  doesn't yet have a second consumer to exercise. The static-grep
  check X.5 is the maximal coverage available today.
- **Probe behaviour against a real Anthropic API timeout.** The unit
  test forces a synthetic 5s+ delay via the shim; real-network
  variability is M.5 (manual, informational).

## Test Execution Commands

```bash
# Primary new test
bash tests/test_grinder_auth_recovery.sh

# Existing tests with this feature's regression coverage
bash tests/test_classify_phase_exit.sh         # ensure auth hook does not collide
bash tests/test_run_phase_watchdog.sh          # ensure watchdog reclassification still works
bash tests/test_grinder_orchestrator.sh        # ensure cmd_run/cmd_resume ordering preserved

# Static checks (one-off; can be wrapped in tests later)
grep -c '\-u no_proxy' adapters/claude-code/claude/tools/lib/claude-session-lib.sh   # expect ≥ 3
grep -c 'AUTH_FAILED_EXIT_CODE\b' adapters/claude-code/claude/tools/lib/claude-session-lib.sh  # expect ≥ 3 (decl + C5 + C6)
grep -c '\b42\b' adapters/claude-code/claude/tools/lib/claude-session-lib.sh         # expect 1 (decl only)

# Full CI suite (registers the new test automatically)
bash dashboard/tests/run-all.sh
```

## Status (post-/implement, 2026-05-09)

| Suite | Result |
|---|---|
| `tests/test_grinder_auth_recovery.sh` | **54 passed, 0 failed** |
| `tests/test_grinder_orchestrator.sh` | 32 passed, 0 failed (T05 stale assertion repaired in same branch — pre-existing CLAUDE.md → pipeline.yaml drift; T28 now sets `GRINDER_SKIP_AUTH_PREFLIGHT=1` because its 30 s sleep mock would block the new probe) |
| `tests/test_classify_phase_exit.sh` | 11 passed, 0 failed (no new collisions with the auth hook) |
| `tests/test_run_phase_watchdog.sh` | 6 passed, 0 failed |
| `tests/test_claude_session_lib.sh` | 24 passed, 0 failed |
| `shellcheck -S warning` over modified shell files | clean |

Manual scenarios M.1–M.6 are deferred to the parent plan's
`sonarqube-and-verification` phase per the design and are NOT run by the
autopilot pipeline (R5.1, AC-5).
