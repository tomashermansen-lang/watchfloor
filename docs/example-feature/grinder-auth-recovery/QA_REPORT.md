<!-- phase: qa | date: 2026-05-09 | branch: feature/grinder-auth-recovery -->

# QA Report — grinder-auth-recovery

## Verdict: PASSED (after fix loop)

54 → 67 tests after expanding the suite to cover TESTPLAN scenarios that
shipped without explicit assertions. All regression suites stay green.
Two WARNING and four NOTE findings from `code-reviewer` were applied as
fixes in this phase; no finding was deferred.

## Summary

- Test count: 67 passed, 0 failed (was 54). 13 new scenarios added to
  close TESTPLAN coverage gaps surfaced during /qa.
- Regression suites green: orchestrator (32), classify_phase_exit (11),
  run_phase_watchdog (6), claude_session_lib (24).
- `shellcheck -S warning` clean on every modified shell file.
- Two code-quality fixes applied: a JSON-injection vulnerability in
  `_emit_auth_failed_event` (printf with bare `%s` substitution) and a
  string-equality compare on the sentinel exit code (`==` → `-eq`).
- Three documentation/coverage fixes applied: `AUTH_FAILED_EXIT_CODE`
  added to the lib header table per PLAN.md §Agent-Navigability, the
  `grinder.sh` sourcing-guard comment tightened to disclose the
  lib-source dependency, `make_mock_claude` hardened against
  non-integer caller input.
- Plan validation: `validate-plan.py` returns Valid (one pre-existing
  120-LOC estimate warning, unrelated to this task's correctness).

## Test Results

```
$ bash tests/test_grinder_auth_recovery.sh
…
Results: 67 passed, 0 failed
```

| Suite | Result |
|---|---|
| `tests/test_grinder_auth_recovery.sh` | **67 passed, 0 failed** (13 new) |
| `tests/test_grinder_orchestrator.sh` | 32 passed, 0 failed |
| `tests/test_classify_phase_exit.sh` | 11 passed, 0 failed |
| `tests/test_run_phase_watchdog.sh` | 6 passed, 0 failed |
| `tests/test_claude_session_lib.sh` | 24 passed, 0 failed |
| `shellcheck -S warning` over modified shell files | clean |
| `validate-plan.py docs/INPROGRESS_Plan_grinder-full-stack/execution-plan.yaml` | Valid |

Wall-clock for the auth-recovery suite: ≈ 4 s (R4.4 ≤ 30 s honoured).

## Code Review Findings (applied + remaining)

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | WARNING | `claude-session-lib.sh:1–54` header table missing `AUTH_FAILED_EXIT_CODE` (PLAN.md §Agent-Navigability required it) | **FIXED** — added a row next to `DEVIATION_ASSESSOR_TIMEOUT_S` |
| 2 | WARNING | `_emit_auth_failed_event` used `printf '%s'` — a quote/backslash in `phase`/`sid`/`reason` would corrupt NDJSON and break every downstream `json.loads` consumer | **FIXED** — delegated encoding to `python3 json.dumps`; values are passed positionally via `sys.argv` so no shell-level escaping is needed |
| 3 | NOTE | `claude-session-lib.sh:1498` used string `==` for sentinel-exit-code comparison; inconsistent with arithmetic compare at line 1613 in `run_gated_phase` | **FIXED** — switched to `[[ $_ac_rc -eq $AUTH_FAILED_EXIT_CODE ]]` |
| 4 | NOTE | TESTPLAN scenarios C1.9, C2.1–C2.8, C5.5, C5.7, C5.8, C7.4, X.5–X.7 enumerated but not asserted in the test file | **FIXED** — 12 new test cases added (`C1.9`, `C2.1`, `C2.2`, `C2.3-6`, `C2.7`, `C2.8`, `C5.5`, `C5.7`, `C5.8`, `C7.4`, `X.6`, `X.7`, `C4.8`); the X.5 check was already covered as `C5.9`, retained as a duplicate-by-design sentinel |
| 5 | NOTE | `grinder.sh:1804` sourcing-guard comment said "lets tests source this file to unit-test" without disclosing that `claude-session-lib.sh` is unconditionally sourced first | **FIXED** — comment updated to call out the lib-source dependency |
| 6 | NOTE | `make_mock_claude` heredoc embedded `$exit_code` / `$sleep_seconds` without integer validation | **FIXED** — added `[[ "$x" =~ ^[0-9]+$ ]]` guards before heredoc emission; failure returns 2 with a clear message |

**Remaining findings:** None.

## Coverage Map (Requirement → Test)

| Requirement | Tests | Status |
|---|---|---|
| R1.1 (probe runs at startup before lock) | C2.1, C2.2, C2.7, C2.8 | ✅ |
| R1.2 (success-path ≤ 1 s soft target) | RK-3 disposition; hard 5 s ceiling enforced by C1.7 | ⚠️ aspirational — C1.7 hard ceiling stands |
| R1.3 (5 s hard timeout, deterministic prompt) | C1.7 | ✅ |
| R1.4 (silent success path) | C1.1 | ✅ |
| R1.5 (exit 2 + auth-required stderr line) | C1.5, C1.6, C1.8 | ✅ |
| R1.6 (binary-missing / timeout messages) | C1.4, C1.7 | ✅ |
| R1.7 (`GRINDER_SKIP_AUTH_PREFLIGHT` short-circuit + WARNING) | C1.3 | ✅ |
| R1.8 (probe excluded from discover/pause/status/ack-review) | C2.3-6 | ✅ |
| R2.1 (8-var strip on initial `claude -p`) | C7.1, C7.5 | ✅ |
| R2.2 (`env -u` flags only, parent shell preserved) | C7.3, C7.4 | ✅ |
| R2.3 (8-var strip on resume `claude -p`) | C7.2 | ✅ |
| R3.1 (predicate matches both shapes) | C3.2, C3.3, C3.5, C3.11 | ✅ |
| R3.2 (one structured event per phase) | C3.6, C4.2, C4.3, C4.8, C5.2 | ✅ (C4.8 = JSON-injection regression) |
| R3.3 (sentinel exit code from run_phase) | C5.2, C5.3, C6.1, C6.10 | ✅ |
| R3.4 (no commit, no track_deviation, halt msg, non-zero exit) | C6.2, C6.3, C6.4, C6.5, C6.6 | ✅ |
| R3.5 (non-auth failures unchanged) | C3.4, C5.1, C5.4, C5.5, C6.7, C6.8 | ✅ |
| R3.6 (malformed JSON skipped) | C3.7, C3.8, C3.9 | ✅ |
| R4.1 (test sets `GRINDER_SKIP_AUTH_PREFLIGHT=1`) | C8.1 | ✅ |
| R4.2 (fixtures cover both shapes) | C8.3, C8.4 | ✅ |
| R4.3 (assertions: 1 event, 0 retries, non-zero exit) | C5.2 (1 event), C6.1 (counter=1), C6.6 (fail_pipeline) | ✅ (split coverage; integration via C5.2 + C6.1 conjunction) |
| R4.4 (≤ 30 s runtime) | observed 4 s | ✅ |
| R4.5 (TMPDIR isolation, no real `claude`, git unchanged) | C8.6, C8.8 | ✅ |
| R4.6 (fixtures under `tests/fixtures/grinder-auth-recovery/`) | C8.2, C8.4 | ✅ |
| R5.1 (real-run produces 0 auth_failed events) | M.1 (manual) | 🟡 deferred to parent plan's `sonarqube-and-verification` phase per design |
| R5.2 (R5.1 holds in parent plan SC-A) | M.1 (manual) | 🟡 same as R5.1 |
| R6.1 (single discoverable signal) | C5.2 + C6.5 + C6.6 conjunction; C4.8 wire-format integrity | ✅ |
| R6.2 (actionable stderr messages) | C1.5, C1.6 | ✅ |
| R6.3 (no new files in `$HOME`) | C1.9 | ✅ |

R5.1 / R5.2 are explicitly out of this autopilot pipeline's scope per
PLAN.md §SOLID Trace and TESTPLAN §Out-of-Scope. They belong to the
parent plan's `sonarqube-and-verification` phase, where AC-5 of the
host execution-plan task is verified.

## Eval Traceability

This project does not maintain a `data/evals/` slice. The TESTPLAN
fixture pattern (`tests/fixtures/grinder-auth-recovery/`) is the
authoritative behavioural surface. Two of the three fixtures are also
documented as the seed cases for any future grinder eval slice
(REQUIREMENTS.md §"Eval Cases for `data/evals/`").

| Requirement | Test file | Fixture | Status |
|---|---|---|---|
| R3.1 shape (a) | `test_grinder_auth_recovery.sh::test_c3_2_*` | `auth_failed_not_logged_in.ndjson` | ✅ |
| R3.1 shape (b) | `test_grinder_auth_recovery.sh::test_c3_3_*` | `auth_failed_top_level_error.ndjson` | ✅ |
| R3.5 negative (non-auth) | `test_grinder_auth_recovery.sh::test_c3_4_*` | `non_auth_failure.ndjson` | ✅ |

## UX Compliance

Not applicable — this feature is backend-only (bash + python3
orchestration), no UI surface, no DESIGN.md.

## Regressions

None observed. The four regression test suites (`orchestrator`,
`classify_phase_exit`, `run_phase_watchdog`, `claude_session_lib`)
stayed green across the entire fix loop. Notably:

- `_classify_phase_exit` reclassification path is unchanged; T06
  (124+result→0) still passes, confirming the auth hook does not
  collide with the timeout reclassifier.
- `test_grinder_orchestrator.sh::T28` continues to pass — its
  pre-existing `GRINDER_SKIP_AUTH_PREFLIGHT=1` set during /implement
  remains the integration evidence that the probe is correctly wired
  into `cmd_run`.

## Architecture Compliance

| Rule | Status | Evidence |
|---|---|---|
| SRP — each new function has one reason to change | ✅ | `_auth_failed_classify` (predicate), `_emit_auth_failed_event` (wire format), `_run_phase_auth_check` (hook orchestration), `auth_preflight_probe` (startup check) — each isolated |
| OCP — adding a new auth-failure shape is a single-point change | ✅ | `_auth_failed_classify` Python block; no callers know the predicate's internals |
| DIP — sentinel is a named constant, not a magic number | ✅ | `AUTH_FAILED_EXIT_CODE` constant; the only literal `42` in the lib is the `: "${VAR:=42}"` declaration (verified by `C5.9` test) |
| Agentic navigability — function header docs, header tables updated | ✅ | C1/C3/C4/C5 each have multi-paragraph docstrings; lib header table now lists the tunable (X.7) |
| Hardcoded values forbidden | ✅ | `AUTH_PROBE_TIMEOUT_S`, `AUTH_PROBE_PROMPT`, `AUTH_FAILED_EXIT_CODE` all named, all operator-overridable |
| Bash 3.2 compatibility | ✅ | X.4 static check; no associative arrays in any new shell code |
| `set -euo pipefail` discipline | ✅ | Both modified shell files preserved |
| `${TMPDIR:-/tmp}` discipline | ✅ | `auth_preflight_probe` uses `mktemp` with the `${TMPDIR:-/tmp}` template |
| Import direction (orchestrator → lib, never reverse) | ✅ | `grinder.sh` sources `claude-session-lib.sh` (line 66); the new `auth_preflight_probe` calls `_resolve_timeout_bin` and `_auth_failed_classify` from the lib (one-way) |

## Completeness & Cross-Document Consistency

- ✅ Every R1.1–R6.3 has at least one test (the matrix above is the
  evidence). R1.2 is documented as aspirational by RK-3 with C1.7 as
  the hard-ceiling fallback. R5.1/R5.2 are by-design deferred to the
  parent plan's verification phase per the architect's scope split.
- ✅ Every C1–C8 component in PLAN.md exists in the implementation;
  none planned-but-unbuilt.
- ✅ Operator stderr strings match verbatim across REQUIREMENTS / PLAN
  / TESTPLAN / implementation: `claude auth required — run claude
  login and retry`, `claude binary not found on PATH`, `claude auth
  probe timed out after Ns`, `WARNING: auth preflight skipped via
  GRINDER_SKIP_AUTH_PREFLIGHT`, `grinder halted: claude authentication
  lost mid-run — run claude login and re-run grinder.sh run`.
- ✅ No TODOs, FIXMEs, stubs, or "deferred" items in the new code (the
  `deferred` strings present in `grinder.sh` are pre-existing and refer
  to grinder finding-batches, unrelated to this feature).
- ✅ No scope creep: no implementation outside R1–R6.3 mapping.

## Execution-Plan Drift

The host execution plan's `grinder-auth-recovery` task acceptance:

| AC | Implementation | Test |
|---|---|---|
| AC-1 (preflight + exit 2) | `auth_preflight_probe` + `cmd_run`/`cmd_resume` insertion | C1.5, C1.6, C2.1, C2.2, C2.7, C2.8 |
| AC-2 (8-var proxy strip) | `claude-session-lib.sh:1431` (initial), `:1547` (resume) | C7.1, C7.2, C7.5 |
| AC-3 (classifier + retry exit) | `_auth_failed_classify` + `_run_phase_auth_check` + `run_gated_phase` short-circuit | C5.2, C5.3, C6.1, C6.7 |
| AC-4 (fixture: 1 event, 0 retry, non-zero exit) | `tests/test_grinder_auth_recovery.sh` C5.2/C6.1/C6.6 | ✅ |
| AC-5 (real run produces 0 auth_failed) | infrastructure shipped; verified in parent plan's `sonarqube-and-verification` phase | M.1 (manual) |

No drift. Scope matches the host plan task description; constraints
honoured (bash 3.2, fixture pattern, ≤ 1 s soft success path); five
acceptance criteria all map to either an automated test (AC-1 to AC-4)
or the documented manual verification path (AC-5).

## Risks

| Severity | Risk | Mitigation |
|---|---|---|
| LOW | Cold `claude -p` first call may exceed the 1 s soft target | RK-3 disposition (PLAN.md): the 5 s hard ceiling at `AUTH_PROBE_TIMEOUT_S` is the operator-overridable safety net. C1.7 enforces the hard ceiling. |
| LOW | A future contributor adds a third caller to `run_phase` and forgets the sentinel check | EC-K disposition (REQUIREMENTS.md): the named sentinel constant is the contract — `grep -n AUTH_FAILED_EXIT_CODE` shows every consumer. |
| LOW | Operator sets `GRINDER_SKIP_AUTH_PREFLIGHT=1` and forgets to unset it | R1.7 mandates a loud stderr WARNING on every probe-skip. The test harness sets it per-invocation, never globally. |
| LOW | C1.9 (`$HOME` write check) heuristic excludes `~/.claude` and `~/.config/claude` to avoid false positives | This is the documented allowlist; the probe itself only `mktemp`s under `$TMPDIR`. The test is defence-in-depth. |

## Gotchas Captured

**Structured-event emitters that interpolate via `printf '%s'` are JSON-unsafe.**
The pre-existing `_emit_orchestrator_kill_event` pattern was copied
into `_emit_auth_failed_event`, which would have produced invalid
NDJSON if any field contained a `"` or `\` (e.g., a shell-quoted
phase name). Future emitters should delegate JSON encoding to
`python3 json.dumps` (or `jq -nc`) and never interpolate raw values
into a JSON template. The same defect likely lives in
`_emit_orchestrator_kill_event` — out of scope for this task but worth
flagging for a follow-up audit.

## Files Touched (this phase)

- `adapters/claude-code/claude/tools/lib/claude-session-lib.sh` —
  header table row for `AUTH_FAILED_EXIT_CODE`; `_emit_auth_failed_event`
  rewritten to use `python3 json.dumps`; `==` → `-eq` on sentinel
  comparison.
- `adapters/claude-code/claude/tools/grinder.sh` — sourcing-guard
  comment tightened.
- `tests/test_grinder_auth_recovery.sh` — `make_mock_claude` integer
  validation; +13 new test cases (`C1.9`, `C2.1`, `C2.2`, `C2.3-6`,
  `C2.7`, `C2.8`, `C5.5`, `C5.7`, `C5.8`, `C7.4`, `X.6`, `X.7`,
  `C4.8`).

No production code in `auth_preflight_probe`, `_run_phase_auth_check`,
or the `run_gated_phase` short-circuit was changed during /qa.
