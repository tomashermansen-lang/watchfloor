<!-- phase: ba | date: 2026-05-09 | branch: feature/grinder-auth-recovery -->

# Requirements — grinder-auth-recovery

## Feature Summary

Close the silent-retry failure mode that produced reverted commits during the
2026-05-09 dotfiles grinder run (session 7ed5dd25: `cost=0`, `num_turns=1`,
`error=authentication_failed`). Three coupled fixes ship as one task because
each is partial in isolation:

1. **Preflight auth probe** at `grinder.sh run` startup that hard-stops the
   pipeline before any batch is spawned if `claude` cannot authenticate.
2. **NO_PROXY/no_proxy env-strip parity** in `run_phase` (currently strips
   six proxy variables; the assessor wire at `claude-session-lib.sh:699`
   already strips all eight — symmetric fix to close).
3. **Structured `auth_failed` classifier** inside `run_phase`'s result-event
   consumer that recognises authentication-loss shapes and exits the
   `run_gated_phase` retry loop early instead of silently re-spawning the
   batch and committing half-baked work.

A controlled fixture in `tests/test_grinder_auth_recovery.sh` injects a
synthetic `authentication_failed` result event so the classifier path is
verifiable without breaking the operator's real auth state. This task is
the prerequisite for SC-A in the parent `grinder-full-stack` plan and for
KC-A's kill-trigger guard (if the fixture cannot reproduce the failure
shape, the project pauses at Phase 1).

## Research Findings

### Failure shape observed (2026-05-09 dotfiles run)

Six of eight failed sessions on the 2026-05-09 grinder run committed
half-completed work that was reverted as untrustworthy. The canonical
session is `7ed5dd25`:

- Result event: `{"type":"result","subtype":"success","is_error":true,
  "result":"Not logged in","num_turns":1,"total_cost_usd":0,...}`
- Some sessions surfaced an alternate shape:
  `{"type":"result","error":"authentication_failed",...}`
- `run_gated_phase` saw a non-zero exit, triggered its 2-attempt retry,
  and the second attempt either inherited the same broken auth state
  (silently re-failing) or completed enough text-output to produce a
  partial-but-committable diff that the operator could not trust.

Two distinct upstream causes are hypothesised (DN-A): the `os.setsid()`
detachment in the python wrapper at `claude-session-lib.sh:1309`
interacting with macOS Keychain reads in the `claude` CLI, and the
asymmetric `NO_PROXY` strip leaking sandbox proxy state into the auth
HTTPS handshake. Both hypotheses are unconfirmable from the operator's
machine without instrumenting `claude` itself; the fix-by-construction
strategy closes both layers (probe + classifier) so a successful repro
is not required.

### Existing infrastructure to reuse

- `claude-session-lib.sh:699` — assessor subprocess invocation already
  strips all eight proxy variables (`ALL_PROXY HTTPS_PROXY HTTP_PROXY
  NO_PROXY all_proxy https_proxy http_proxy no_proxy`). The pattern is
  the literal copy target for the run_phase symmetry fix.
- `claude-session-lib.sh:1150` — `process_stream()` is the python3
  consumer that already parses each NDJSON result event. The classifier
  hook plugs into the `etype == "result"` branch (or a sibling helper
  invoked from it) where `is_error`/`result`/`error` fields are read.
- `claude-session-lib.sh:1447` — `run_gated_phase` is the retry loop
  with `max_attempts=2`. The classifier must surface auth_failed in a
  way that this loop can short-circuit (e.g., a sentinel exit code or
  a shared state file that the loop checks before incrementing
  `attempt`).
- `tests/test_grinder_orchestrator.sh` + `tests/fixtures/grinder-orchestrator/`
  — established pattern for orchestrator tests: subprocess invocation
  against a fixture NDJSON. The new test follows the same shape.
- `adapters/claude-code/claude/tools/grinder.sh:1322` — `cmd_run()` is
  the `grinder.sh run` entry point. The preflight probe runs after the
  pause check and before plan validation (or immediately at the top of
  `cmd_run`, before `acquire_grinder_lock` so a failed probe does not
  hold the lock).

### Constraints inherited from parent plan

- Bash 3.2 compatibility (no associative arrays in any new shell code).
- New tests live under `tests/` and use the project's existing
  fixture-NDJSON pattern; no live `claude` invocations.
- Preflight probe must exit within 1 second on the success path so it
  does not slow every `grinder.sh run` invocation.
- Constants and named values, not magic numbers (project convention).

## Requirements

Each requirement is testable. The five operator-locked acceptance
statements from the parent execution plan are reproduced verbatim under
**Acceptance Scenarios**; the requirements below decompose those into
component-level statements plus the operational scope (error handling,
timeouts, fail-closed behaviour) the acceptance statements imply.

### R1 — Preflight authentication probe at grinder.sh startup

**R1.1** When `grinder.sh run` is invoked and the `PAUSE` file is absent
and the plan is valid, the system shall execute an authentication probe
against the `claude` CLI before acquiring the grinder lock.

**R1.2** The preflight probe shall complete within 1 second on the
success path (probe-process wall-clock measured from invocation to
return).

**R1.3** The preflight probe shall be implemented as a cheap headless
`claude -p` invocation with a fixed deterministic prompt, a hard timeout
of 5 seconds, and stream-json output parsed for the same authentication
shapes the run-time classifier recognises (R3.1).

**R1.4** When the preflight probe succeeds, the system shall continue
with the existing `cmd_run` flow (lock acquisition, trap setup, batch
loop) without producing any operator-visible message beyond what
`grinder.sh run` already emits.

**R1.5** When the preflight probe fails by surfacing an authentication
shape, the system shall write the line `claude auth required — run
claude login and retry` to stderr and exit with exit code `2` before
acquiring the grinder lock and before spawning any batch subprocess.

**R1.6** When the preflight probe fails because the `claude` binary is
absent from `PATH` or the probe times out, the system shall write a
specific stderr message identifying the failure mode (`claude binary
not found on PATH` or `claude auth probe timed out after 5s`) and exit
with exit code `2`.

**R1.7** The preflight probe shall be skippable via the environment
variable `GRINDER_SKIP_AUTH_PREFLIGHT=1` so the test fixture can
exercise downstream paths without invoking `claude`. When skipped, the
system shall write `WARNING: auth preflight skipped via
GRINDER_SKIP_AUTH_PREFLIGHT` to stderr.

**R1.8** The preflight probe shall run on `grinder.sh run` only —
`grinder.sh discover`, `grinder.sh resume`, `grinder.sh pause`,
`grinder.sh status`, and `grinder.sh ack-review` shall not invoke the
probe. (Resume re-enters `cmd_run` after the pause check; the probe
runs once at that re-entry, satisfying the same auth-required gate.)

### R2 — NO_PROXY / no_proxy env-strip parity in run_phase

**R2.1** When `run_phase` invokes `claude -p` (`claude-session-lib.sh:1307`),
the system shall strip the eight-variable proxy family
`ALL_PROXY HTTPS_PROXY HTTP_PROXY NO_PROXY all_proxy https_proxy
http_proxy no_proxy`, matching verbatim the strip already deployed at
the assessor wire (`claude-session-lib.sh:699`).

**R2.2** The strip shall be implemented as `env -u` flags on the
existing invocation, so no shell-level unset is required and the
parent shell's proxy environment remains intact for non-claude
subprocesses.

**R2.3** The second `run_phase`-shaped `claude -p` invocation in the
same file (the dual-call path at `claude-session-lib.sh:1408`, if
present in the same `run_phase` body or a shared helper) shall receive
the same eight-variable strip; the requirement is "every direct
`claude -p` invocation in `run_phase`'s execution path uses the same
eight-variable env strip", not "exactly one line is changed".

### R3 — Structured auth_failed classifier in run_phase result handling

**R3.1** While `run_phase` is consuming a `type:"result"` NDJSON event,
if the event matches either authentication shape — (a) `subtype:"success"`
with `is_error:true` and `result` matching the literal substring
`Not logged in`, or (b) `error:"authentication_failed"` (top-level
`error` field equal to the literal string) — the system shall classify
the phase outcome as `auth_failed`.

**R3.2** When the classifier identifies an `auth_failed` outcome, the
system shall append exactly one structured NDJSON event to
`docs/grinder/grinder-stream.ndjson` with shape
`{"type":"auth_failed","phase":"<phase_name>","session_id":"<sid>",
"reason":"<not_logged_in|authentication_failed>","ts":"<utc-iso>"}` and
shall not duplicate that event on subsequent reads of the same result
line.

**R3.3** When the classifier identifies an `auth_failed` outcome, the
system shall cause `run_phase` to return a non-zero exit code that
`run_gated_phase` recognises as fatal-not-retryable, so the
`max_attempts=2` retry loop terminates after the first attempt instead
of re-spawning a second batch under the same broken auth state. The
exit-code convention shall be a fixed reserved value (e.g., `42`)
defined as a named constant in `claude-session-lib.sh` and consumed
explicitly by `run_gated_phase`.

**R3.4** When `run_gated_phase` receives the auth_failed sentinel exit
code, the system shall not invoke `commit_phase` for that phase, shall
not invoke `track_deviation`, shall log the operator-visible message
`grinder halted: claude authentication lost mid-run — run claude login
and re-run grinder.sh run`, and shall exit the `cmd_run` flow with a
non-zero exit code so the lock is released by the existing trap.

**R3.5** When the classifier observes a `type:"result"` event that is
NOT one of the two authentication shapes from R3.1, the system shall
not append an `auth_failed` event and shall not alter the existing
exit-code path; non-auth failures continue to flow through the
existing two-attempt retry loop unchanged.

**R3.6** The classifier shall handle malformed JSON lines gracefully:
a line that fails `json.loads` shall be skipped and shall not raise an
exception, matching the existing `process_stream` posture.

### R4 — Test fixture for the classifier and retry-loop short-circuit

**R4.1** The system shall ship `tests/test_grinder_auth_recovery.sh`
that invokes `grinder.sh run` (or a minimal subprocess that exercises
`run_phase` + `run_gated_phase` directly) with `GRINDER_SKIP_AUTH_PREFLIGHT=1`
set so the preflight probe is bypassed.

**R4.2** The fixture shall inject a synthetic `authentication_failed`
result event into the `STREAM_FILE` / `phase_ndjson` consumed by
`process_stream`, using one of the two shapes from R3.1.

**R4.3** When the test runs against the fixture, the assertions shall
verify:
- exactly one event with `"type":"auth_failed"` appears in
  `docs/grinder/grinder-stream.ndjson`,
- exactly zero retry attempts are observed (the
  `attempt 2/$max_attempts` log line from `run_gated_phase` does
  not appear),
- the overall exit code from `grinder.sh run` is non-zero.

**R4.4** The test shall complete within 30 seconds (matches the gate
checklist `expected_runtime_seconds: 30` for KC-A's kill-trigger).

**R4.5** The test shall be self-contained: it shall not depend on a
real `claude` binary, shall not write outside `tests/` and the
ephemeral `$TMPDIR` it creates, and shall clean up its temp directory
on exit (success or failure).

**R4.6** Test fixtures (synthetic NDJSON streams) shall live under
`tests/fixtures/grinder-auth-recovery/` to follow the existing
fixture-folder convention.

### R5 — End-to-end verification on dotfiles repo

**R5.1** When the operator runs `grinder.sh run` against the dotfiles
repo and `grinder.sh` completes a successful `pass-mechanical`, zero
events with `"type":"auth_failed"` and zero events with
`"error":"authentication_failed"` shall appear in
`docs/grinder/grinder-stream.ndjson`. (Verifiable via `grep '"auth_failed"\|"authentication_failed"' docs/grinder/grinder-stream.ndjson | wc -l` returning `0`.)

**R5.2** R5.1 holds end-to-end in the parent execution plan's
`sonarqube-and-verification` phase as the SC-A success criterion.

### R6 — Observability and operator UX

**R6.1** The structured `auth_failed` event from R3.2 shall be the
single discoverable signal for the operator. No silent retry, no
half-completed commit, no swallowed error.

**R6.2** When the preflight probe fails, the stderr message shall name
the actionable next step (`run claude login and retry`) so the
operator does not have to read code or stream history to recover.

**R6.3** No new files shall be created in the operator's `$HOME`
directory beyond what `claude` itself creates; the probe shall not
write log files outside `docs/grinder/` or `$TMPDIR`.

## Acceptance Scenarios

The five operator-locked acceptance criteria from the parent execution
plan (`docs/INPROGRESS_Plan_grinder-full-stack/execution-plan.yaml`,
task `grinder-auth-recovery`) are reproduced here verbatim and mapped
to the requirements above:

### AC-1 — Preflight probe hard-stops on auth failure

> When `grinder.sh run` starts, the system shall execute a preflight
> auth probe and abort with exit code 2 plus a `claude auth required —
> run claude login and retry` message on stderr if the probe fails,
> before spawning any batch.

**Covers:** R1.1, R1.2, R1.5
**Test path:** Subprocess invocation of `grinder.sh run` with a
mocked `claude` shim on `PATH` that emits the auth-failed result
event; assert exit code `2` and stderr line.

### AC-2 — Eight-variable proxy strip in run_phase

> When `run_phase` invokes `claude -p`, the system shall strip
> NO_PROXY and no_proxy alongside the existing six proxy variables,
> matching the eight-variable strip already deployed at line 699 of
> claude-session-lib.sh.

**Covers:** R2.1, R2.2, R2.3
**Test path:** `grep -c 'NO_PROXY\|no_proxy'` of the run_phase
invocation lines in `claude-session-lib.sh` returns the expected
count; static check sufficient because the change is a literal env-var
list extension.

### AC-3 — Result-event classifier exits retry loop

> While `run_phase` is consuming a phase result event, if the event
> contains subtype `success` with is_error true and result matching
> `Not logged in`, or error `authentication_failed`, then the system
> shall classify the phase as auth_failed, append a structured
> `auth_failed` event to grinder-stream.ndjson, and exit the
> run_gated_phase retry loop without retrying.

**Covers:** R3.1, R3.2, R3.3, R3.4, R3.5, R3.6, R6.1
**Test path:** `tests/test_grinder_auth_recovery.sh` (R4) is the
primary; covers both shapes via two fixture variants.

### AC-4 — Synthetic fixture verifies short-circuit

> If `tests/test_grinder_auth_recovery.sh` injects a synthetic
> authentication_failed result event into a fixture stream, then the
> test shall observe exactly one auth_failed structured event, zero
> retries, and an overall non-zero exit from grinder.sh.

**Covers:** R4.1, R4.2, R4.3, R4.4, R4.5, R4.6
**Test path:** the test itself; gate checklist runs it as
`bash tests/test_grinder_auth_recovery.sh`.

### AC-5 — Real-run produces zero auth_failed events on dotfiles

> When `grinder.sh run` completes a successful pass-mechanical against
> the dotfiles repo, zero authentication_failed events shall appear in
> the run's docs/grinder/grinder-stream.ndjson (verifiable via grep).

**Covers:** R5.1, R5.2
**Test path:** Manual end-to-end run in the
`sonarqube-and-verification` phase of the parent plan; not part of
this task's autopilot pipeline (this task ships the
infrastructure that makes AC-5 verifiable).

## Edge Cases

### EC-A — Auth lost mid-run (after preflight succeeded)

The preflight probe passed at `grinder.sh run` start, but the operator's
auth token expired between the probe and batch N. The classifier
(R3.1) is the second-line defence: when batch N's result event
surfaces `Not logged in`, R3.4 halts the run cleanly. AC-1 alone is
not sufficient; AC-3 closes this case.

### EC-B — `claude` binary absent or unexecutable

The probe's underlying `claude -p` invocation cannot start (`claude:
command not found` or non-executable). R1.6 mandates a specific
stderr message and exit code `2`, distinct from the auth-failed
message so the operator sees the right next action (install `claude`
vs `claude login`).

### EC-C — Probe network timeout (slow Wi-Fi or offline)

`claude -p` hangs while attempting to validate auth against the
Anthropic API. R1.3's 5-second hard timeout fires; R1.6 produces the
`claude auth probe timed out after 5s` stderr line and exit `2`. The
operator can opt-in via `GRINDER_SKIP_AUTH_PREFLIGHT=1` if they
deliberately want to run a grinder pass against a fixture with no
network — that scenario is the intended use of R1.7.

### EC-D — Fixture-injected auth_failed (test path)

`GRINDER_SKIP_AUTH_PREFLIGHT=1` is set so the probe is bypassed. The
classifier still fires (R3.1) when the synthetic event reaches
`process_stream`. AC-4 explicitly asserts no retry occurs and exactly
one structured event lands in the stream.

### EC-E — Both result shapes appear in same stream (defence in depth)

A pathological `claude` build emits both `is_error:true result:"Not
logged in"` and a separate `error:"authentication_failed"` event for
the same phase. R3.2's "exactly one structured event" wording is
preserved by deduplicating on `(phase, session_id)` — the second
matching event is observed but not re-emitted. The classifier exits
the retry loop on the first match; the second is informational only.

### EC-F — Malformed JSON line in result stream

The producer writes a partial JSON line (`{"type":"resu`) due to a
crash mid-write. R3.6 mandates `json.loads` failures are skipped, not
re-raised. The classifier moves to the next line; the existing
`process_stream` swallow-pattern is preserved bit-for-bit.

### EC-G — Resume after pause

The operator pauses grinder mid-phase, fixes auth, and runs
`grinder.sh resume`. `cmd_run` is re-entered (resume is a thin
wrapper over the same entry point); R1.1 fires the probe at that
re-entry. If auth is now valid, the run continues; if not, the same
`exit 2` path applies.

### EC-H — Plan staleness check vs preflight ordering

`cmd_run` currently runs (1) pause check, (2) plan validation, (3)
plan staleness, (4) state corruption, (5) lock acquisition. R1.1
inserts the probe between step (1) and step (5). The probe is placed
as late as possible (after staleness and state checks) so we do not
spawn `claude -p` when the plan is invalid — but before step (5) so a
failed probe does not hold a lock that the trap then has to release.
Concretely the probe runs immediately before `acquire_grinder_lock`.

### EC-I — Concurrent grinder runs

Lock acquisition (`acquire_grinder_lock`) prevents two grinder
processes from running simultaneously, so the probe never races
against a sibling probe. Probe placement before lock acquisition is
safe because the probe is read-only against the operator's `claude`
state.

### EC-J — `auth_failed` event during `track_deviation` post-success

The deviation tracker is invoked from `track_phase` only on
`completed` status (`claude-session-lib.sh:1242`). R3.4 mandates
`track_deviation` is not invoked on auth_failed, which is consistent
with the existing pattern; no special-case is required beyond
ensuring the auth_failed sentinel is not classified as `completed`.

### EC-K — Retry budget interaction with deviation-flagged phase

A future deviation-flagged retry (orthogonal feature, separate
trigger) must still respect R3.3's no-retry-on-auth-failure rule. The
sentinel exit code from R3.3 is the contract: any retry path in the
codebase that wraps `run_phase` must check for the sentinel and
short-circuit. Today only `run_gated_phase` retries — the requirement
is scoped to that consumer, but the named constant makes future
expansion safe.

### EC-L — Preflight bypass leaks into autopilot

`GRINDER_SKIP_AUTH_PREFLIGHT` is intended for tests. R1.7's stderr
WARNING ensures it is loud if accidentally set in autopilot. Autopilot
phase scripts do not export the variable; the test fixture sets it
explicitly per-invocation, not in `conftest.py` global setup.

## Open Questions

None for the operator. All five operator-locked acceptance criteria
from the parent plan are covered by R1–R5 plus operational
requirements (R1.3 timeout value, R1.7 skip env var, R3.3 sentinel
exit code, R3.4 operator message wording). Implementation choices
(exact probe prompt, sentinel exit code numeric value, deduplication
key) are within Architect's authority in `/plan` and do not require a
new BA decision.

## Eval Cases for `data/evals/`

(Eval directory is not part of this project's standard layout; the
parent plan does not reference `data/evals/`. The fixture-NDJSON test
under `tests/fixtures/grinder-auth-recovery/` is the closest
equivalent and is specified under R4.6.)

If a future plan adds a `data/evals/` slice for grinder, the two
synthetic-event fixtures from R4 are the seed cases:

1. **`auth_failed_not_logged_in.ndjson`** — result event with
   `subtype:"success"`, `is_error:true`, `result:"Not logged in"`.
   Expected classifier output: one `auth_failed` event with
   `reason:"not_logged_in"`, exit code = sentinel.
2. **`auth_failed_top_level_error.ndjson`** — result event with
   `error:"authentication_failed"`. Expected classifier output: one
   `auth_failed` event with `reason:"authentication_failed"`, exit
   code = sentinel.

## SOLID / Single-Module Trace

Each requirement traces to exactly one module:

| Requirement | Module | Function / Location |
|---|---|---|
| R1 (preflight) | `adapters/claude-code/claude/tools/grinder.sh` | `cmd_run` (immediately before `acquire_grinder_lock`) |
| R2 (env strip) | `adapters/claude-code/claude/tools/lib/claude-session-lib.sh` | `run_phase`, the `env -u` line at ~1307 (and the dual at 1408 if reachable) |
| R3 (classifier) | `adapters/claude-code/claude/tools/lib/claude-session-lib.sh` | `process_stream` (or a sibling helper invoked from `run_phase` after stream consumption) |
| R3.4 (loop short-circuit) | `adapters/claude-code/claude/tools/lib/claude-session-lib.sh` | `run_gated_phase` |
| R4 (test fixture) | `tests/test_grinder_auth_recovery.sh` + `tests/fixtures/grinder-auth-recovery/` | new files |
| R5 (e2e verification) | parent plan, phase `sonarqube-and-verification` | not modified by this task |

New requirements can be added (e.g., a third auth-failure shape if
upstream `claude` introduces one) by extending the classifier's
predicate list — single-point-of-change for the classifier (OCP).
