<!-- phase: qa | date: 2026-05-14 | branch: feature/session-status-endpoint -->

# QA Report — `GET /api/{target_kind}/status`

## Verdict: PASSED (2 fixes applied)

## Summary

The feature ships one 9-LOC FastAPI handler at the end of
`dashboard/server/routes/api.py`, three new module-level imports
(`typing.Literal`, `dashboard.server.status_helper.derive_status`,
the `_TargetKind` alias), one new pytest module
`dashboard/tests/test_status_endpoint.py` (77 tests, all passing),
and one CLAUDE.md bullet under `## Dashboard Subtree → ### Layout`.
QA found one in-test scope-guard miscalibration (T8.3 allowed-set was
too narrow — three unavoidable test-suite wiring updates were not
listed) and one cross-document inconsistency between REQUIREMENTS.md
E13 / TESTPLAN.md T4.4 and the actual Starlette trailing-slash
behaviour (predicted 422/404, observed 307). Both were fixed in this
QA pass; the production handler itself required zero changes. All
acceptance criteria from the execution-plan task and from
REQUIREMENTS.md trace to passing tests.

## Test Results

### Feature pytest module

```
dashboard/tests/test_status_endpoint.py
============================== 77 passed in 0.71s ==============================
```

All 77 tests pass after two QA fix passes. Distribution:

- Group 1 (success path, AS1/AS5/AS8/AS9/AS12/AS13-pass/E1/E9): 18 tests
- Group 2 (helper-call contract, AS2/AS11): 7 tests
- Group 3 (4xx error paths, AS2/AS3/AS13-reject/AS14/E2/E3/E15): 12 tests
- Group 4 (method/URL surface, AS6/AS7/E13): 9 tests
- Group 5 (cross-validation drift detectors, AS10/AS15/Risk-5): 23 tests
- Group 6 (latency smoke, AS4): 2 tests
- Group 7 (CLAUDE.md doc, R-OUT-2): 1 test
- Group 8 (no-change guards, R2/R-OUT-1): 3 tests

### Canonical FastAPI test runner (`bash dashboard/tests/test-app.sh`)

```
388 passed in 3.40s
OK: dashboard/serve.py tombstone invariants (10 lines, contains 'tombstoned')
```

Includes the new 77-test module plus 311 pre-existing FastAPI tests.
No regressions. Tombstone invariant for `dashboard/serve.py` holds.

### Adjacent dashboard test modules (full pytest sweep)

```
.venv/bin/pytest dashboard/tests/ -q
1007 passed, 1 skipped in 20.52s
```

Every Python-side dashboard test passes. The 1 skipped test is
unrelated (`tests/test_status_helper.py` skips one test on systems
without `pytest-benchmark` installed).

### Bash-only test suites (`bash dashboard/tests/run-all.sh`)

```
Suites: 28 passed, 6 failed, 34 total
Failed: Hook functional tests | Concurrent write tests | Security tests
        | API plan endpoint tests | Plan detection tests | Hook expanded fields tests
```

⚠️ NOT-A-REGRESSION. The same six suites fail in this worktree
regardless of whether the branch's changes are present (verified by
`git stash` and re-run). They pass cleanly in the canonical
worktree at `~/Projekter/dotfiles` (34 of 34 passed — verified). Root
cause: this worktree lacks `.claude/settings.local.json` (which the
canonical worktree has at `.claude/settings.local.json`), so `git
init` calls inside `dashboard/.test-tmp/` are blocked by the macOS
sandbox attempting to copy template hooks into `.git/hooks/`. The
failure manifests as `git init -q` exiting 128 with "Operation not
permitted" on hook-template copy. Not introduced by this branch and
not addressable in scope (modifying `.claude/settings.local.json`
across worktrees is outside the feature's blast radius).

## Code Review Findings

Independent code-reviewer subagent pass. Verbatim findings below
with this QA's evaluation.

### B1 — `target_kind` rejection status code (REJECTED — invalid finding)

**Reviewer claim:** Tests assert 400 for bad `target_kind`;
REQUIREMENTS AS3 says 422.

**QA evaluation:** Reviewer missed the explicit reconciliation
chain in PLAN.md Risk-6 and TESTPLAN.md F1. REQUIREMENTS R-RECONCILE(2)
flagged this as an OPEN position; the architect closed it in
PLAN.md Risk-6 in favor of 400, justified by:

1. Production `dashboard/server/app.py:170-184` registers
   `_validation_error_to_400` against `RequestValidationError`,
   verified by reading the live file in this QA pass:
   ```
   async def _validation_error_to_400(...) -> JSONResponse:
       errors = [...]
       return JSONResponse(status_code=400, content=...)
   ```
2. The test app inlines a byte-equivalent copy at
   `test_status_endpoint.py:109-118` (intentional per Finding #7
   of the review phase to avoid private-symbol coupling).
3. Plan AC#2 explicitly says "400 with structured error body" —
   the implementation matches verbatim.

The body-shape assertion `body["detail"][0]["loc"]` and `["type"]`
are owned by Pydantic v2 and are stable across the pinned
`pydantic>=2,<3` range. Risk-2 mitigation in PLAN.md documents
this. No fix required.

### B2 — `route.dependant` introspection fragility (DOWNGRADED to NOTE)

**Reviewer claim:** T5.2's `route.dependant.query_params[0].field_info`
introspection is brittle to FastAPI internal changes.

**QA evaluation:** Partially valid concern, but mitigated:

- FastAPI is pinned at `fastapi>=0.110,<1` in `pyproject.toml`.
  `route.dependant` is part of the documented `APIRoute`
  attribute set since FastAPI 0.x and has not changed across the
  pinned range.
- The same contract has TWO additional behavioral tests
  (T3.6 empty id, T3.7 65-char id, T3.8 missing id) that hit the
  same accept-set boundary via real HTTP requests. If the
  introspection breaks on a FastAPI upgrade, the behavioral
  tests still catch any actual contract change.
- The introspection adds defense-in-depth: it catches the case
  where the `Query(min_length=1, max_length=64)` declaration is
  removed at the source but the helper's `_TARGET_PATTERN` no
  longer rejects empty/long ids — without the introspection, the
  behavioral tests would still pass.

Net assessment: the test is acceptable as-shipped. If FastAPI
internals change, the failure mode is loud (test fails on
collection, not silent), which is the desired signal. No fix
required.

### W1 — `target_id` vs `id` parameter naming (acknowledged, no action)

Reviewer self-retracted W1 in the same finding. The handler uses
`target_id` as the Python parameter name aliased to the URL
parameter `id` via `Query(alias="id", ...)` — this is the
explicit convention from PLAN.md Finding #8 of the review phase
(adopted to avoid shadowing Python's built-in `id()` function,
matching every sibling handler in `routes/api.py`). The test
`test_t2_2_helper_call_args_order` correctly validates positional
args via `mock.call_args[0] == ("autopilot", "feat-x")`. No fix
required.

### W2 — Trailing-slash edge case mismatch (FIXED in this QA pass)

**Reviewer claim:** Test asserts 307 redirect; REQUIREMENTS E13
says 422.

**QA evaluation:** Valid finding. The test asserts what Starlette
actually does (307 redirect to canonical no-trailing-slash form);
the BA's E13 prose was wrong. **Fixed:**

- `REQUIREMENTS.md:915-925` E13 rewritten to match observed
  behaviour (307 redirect via Starlette default) with a note
  explaining the BA-prose-vs-implementation correction trail.
- `TESTPLAN.md:122` T4.4 row updated to match.

Verification: `dashboard/tests/test_status_endpoint.py::test_t4_4_trailing_slash_redirects`
passes against the implementation; both docs now describe
behaviour that matches the test.

### N1, N2, N3 — Documentation-only notes (acknowledged, no action)

All three reviewer NOTEs (`_TargetKind` lift comment, source-text
scan in T5.3, session-scoped `large_stream` fixture) are correctly
implemented and explicitly justified in the documentation. No fix
required.

## Coverage Matrix

Every REQUIREMENTS.md ID has at least one passing test:

| Req | Tests | Status |
|---|---|---|
| R1 | T1.1, T5.4 | ✅ |
| R2 | T8.1, T8.3 | ✅ |
| R3 | T3.4, T3.5, T5.1, T5.5 | ✅ |
| R4 | T1.12, T1.13, T1.14, T3.1, T3.2, T3.3, T3.6, T3.7, T3.8 | ✅ |
| R5 | T2.1, T2.2, T2.3, T2.4, T2.5, T2.6, T2.7, T5.3 | ✅ |
| R6 | T1.1, T1.3, T1.4, T1.7, T1.8, T1.9, T1.10, T2.7 | ✅ |
| R7 | T3.1, T3.4 | ✅ |
| R8 | T2.4, T2.5, T2.6 | ✅ |
| R9 | T6.1, T6.2 | ✅ |
| R10 | T4.1, T4.2, T4.3, T4.5, T4.6 | ✅ |
| R11 | T1.4 | ✅ |
| R12 | T5.1 | ✅ |
| R13 | T1.6 | ✅ |
| R14 | T5.4, T5.1, T5.5 | ✅ |
| R15 | implementation-time wc-l, ≤35 production LOC verified | ✅ |
| R-OUT-1 | T8.2, T8.3 | ✅ |
| R-OUT-2 | T7.1 | ✅ |
| R-CON-1 | T2.1, T3.5, T3.6 | ✅ |
| R-CON-2 | T5.2 | ✅ |
| R-CON-3 | T2.7, T4.4 | ✅ |

Every acceptance scenario AS1-AS15 has at least one passing test
(see TESTPLAN.md § Acceptance-Scenario-to-Test Trace, all rows
mapped).

## Eval Traceability

Not applicable. The endpoint ships an HTTP surface over a
deterministic helper — no LLM-driven prompt is involved, no
judgement scoring is needed. REQUIREMENTS.md § Eval Cases
explicitly notes this and the execution-plan task does not
require eval cases.

## UX Compliance

Not applicable. The feature ships an HTTP-only backend endpoint;
no UI surface is added by this task. The Phase 3 Watchfloor UI
will consume this endpoint over HTTP in a separate task.

## Regressions

None. Verification:

- All 388 tests in `bash dashboard/tests/test-app.sh` pass.
- All 1007 Python tests in `pytest dashboard/tests/` pass.
- The bash-only suite failures (6 of 34) are pre-existing
  worktree-environment issues — not caused by this branch
  (verified by stashing all branch changes and re-running; same
  six suites still fail in this worktree).

## Architecture / CLAUDE.md Rules

- ✅ R5 — handler delegates ALL state derivation to
  `status_helper.derive_status`; no inline NDJSON parsing
  (verified by T5.3 source-scan + manual reading of the 9-LOC
  handler body).
- ✅ R-OUT-1 — `dashboard/server/status_helper.py` is unchanged
  (verified by T8.2 git diff + by running
  `git diff main...HEAD -- dashboard/server/status_helper.py`
  manually — zero output).
- ✅ R2 — `dashboard/server/app.py` is unchanged (verified by
  T8.1).
- ✅ Production-code surface restricted to the three
  documented files (CLAUDE.md, routes/api.py,
  test_status_endpoint.py) plus three unavoidable test-suite
  wiring updates (test-app.sh adds the new module to the smoke
  runner; test_routes_api.py and
  test_routes_api_artifacts_grinder.py both maintain hardcoded
  route-set assertions that must update when a new APIRouter
  path is registered).
- ✅ Localhost-only / read-only / no-shell-interpolation /
  no-eval (CLAUDE.md § Security Rules) — handler binds nothing,
  reads only via the helper, performs no shell calls, has no
  eval/innerHTML.

## Completeness / Cross-Document Consistency

REQUIREMENTS → DESIGN (n/a — backend-only) → PLAN → TESTPLAN →
implementation chain verified end-to-end:

- ✅ Every REQUIREMENTS R-id maps to a PLAN component.
- ✅ Every PLAN component (C1 handler, C2 test module, C3
  CLAUDE.md bullet) is implemented in code.
- ✅ Every TESTPLAN row maps to a `def test_*` in the new test
  module.
- ✅ No code in `routes/api.py` lacks a basis in REQUIREMENTS
  (the 9-LOC handler matches R1+R3+R4+R5+R6+R8 verbatim).
- ✅ No TODO, FIXME, stub, or "deferred" marker in the new
  code or tests (verified via `grep -n "TODO\|FIXME\|stub\|XXX\|deferred"`
  on the diff — zero matches).
- ✅ Two documented divergences from BA prose (R-RECONCILE(1)
  no-echo response shape; R-RECONCILE(2) 400 status) are
  explicitly closed in PLAN.md Risk-6 and verified in production
  app behaviour.

The two QA fixes in this pass tightened the spec-impl trace:

1. T8.3 allowed-set extended to include the three test-suite
   wiring files (test-app.sh, test_routes_api.py,
   test_routes_api_artifacts_grinder.py) that must change
   whenever a new APIRouter path lands. Comment in the source
   explicitly enumerates why each is in the allowed set.
2. REQUIREMENTS.md E13 + TESTPLAN.md T4.4 prose updated to
   match observed Starlette 307-redirect behaviour, replacing
   the BA's incorrect 422 prediction.

## Execution-Plan Drift

Plan task: `session-status-endpoint`
(`docs/INPROGRESS_Plan_poc-watchfloor-autopilot-control/execution-plan.yaml:2838-2896`).

| Plan AC | Implementation status |
|---|---|
| AC#1 — 200 round-trip with status fields within 200ms | ✅ T1.1 + T6.1 (200ms verified end-to-end on 40MB stream) |
| AC#2 — 400 on bad id OR bad target_kind before any file read | ✅ T3.1 (regex 400) + T3.4 (Pydantic 400) + T2.4/T2.5 (helper not called on rejection) |
| AC#3 — ≤200ms repeated polls on 40MB stream | ✅ T6.1 (100 polls, p100 ≤ 200ms, p50 ≤ 50ms) + T6.2 (incremental-append warm path ≤ 50ms) |
| AC#4 — idle for never-started target with all derived fields null | ✅ T1.5 + T1.6 |
| AC#5 — GET-only, no CSRF on GET, Origin allowlist still applies | ✅ T4.1 + T4.2 + T4.5 + T4.6 |

**Documented divergences from plan AC text** (closed during the
plan phase, not introduced at implementation):

- AC#1 lists `target_kind, target_id` as response fields. The
  implementation omits these per R-RECONCILE(1) / PLAN.md
  Risk-6: the helper's `SessionStatus` TypedDict is the
  contract; adding wrapper fields breaks the helper-as-source-of-truth
  pattern. The Watchfloor UI already knows `target_kind` and
  `id` from the URL it sent.
- AC#2 says "400" on both bad inputs. The implementation
  correctly returns 400 in both cases (matching production
  `_validation_error_to_400` rewrite). The original BA prose
  AS3 incorrectly predicted 422 — corrected by PLAN.md F1.

**No scope creep.** The implementation does not add features,
endpoints, or constants beyond what REQUIREMENTS / PLAN /
TESTPLAN specify. `git diff main...HEAD --name-only` outside the
docs tree lists the three production-code files plus three
unavoidable test-suite wiring files (route-count assertions,
test-runner registration). T8.3 enforces this.

**No interface contracts violated.** The predecessor task
`session-status-helper` ships `derive_status(target_kind,
target_id) -> SessionStatus` and `TARGET_KINDS` tuple. The
endpoint imports both verbatim, calls `derive_status` exactly
once per request (T2.1), passes args in the documented order
(T2.2 + T2.3), and pins the route's `_TargetKind` Literal to
match the helper's `TARGET_KINDS` (T5.1). No reimplementation,
no bypass, no helper-internal access.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| FastAPI internal API change breaks T5.2 introspection | LOW | FastAPI pinned `>=0.110,<1`; behavioural tests T3.6/T3.7/T3.8 redundantly cover the contract. Loud failure at test-collection time signals upgrade work. |
| Bash test-suite worktree env issue (6 of 34 suites fail in this worktree) | LOW | Pre-existing, environment-only, addressed once across worktrees in a separate task. The full-fidelity bash test sweep passes in the canonical worktree (`~/Projekter/dotfiles`). |
| Phase 2 control-endpoints task may need `_TargetKind` lifted to schemas.py | NONE | Anticipated by PLAN.md F3; the alias placement comment in `routes/api.py:137-139` documents the lift criteria. Phase 2 owns the lift if it needs the type from another module. |

## Files Touched

Production (3, plus three test-suite wiring deltas):

- `dashboard/server/routes/api.py` — `+9 LOC handler` + `+3 import lines` + `+1 alias line` (well under R15's ≤ 35 LOC budget)
- `dashboard/tests/test_status_endpoint.py` — new file, 845 LOC (over the R15 ≤ 350 LOC suggestion; the over-shoot reflects the parameterized-test groups Group 5 and Group 8 which the architect approved during the review phase as essential drift detectors)
- `CLAUDE.md` — `+5 LOC bullet` under `## Dashboard Subtree → ### Layout`
- `dashboard/tests/test-app.sh` — `+1 line` registering the new test module in the smoke runner
- `dashboard/tests/test_routes_api.py` — `+2 LOC` updating the route-set assertion to include the new path
- `dashboard/tests/test_routes_api_artifacts_grinder.py` — `+2 LOC` updating the route-count assertion (`22 → 23`)

Documentation (4 — all per-phase artifacts under
`docs/INPROGRESS_Feature_session-status-endpoint/`):

- `REQUIREMENTS.md` — BA phase + QA phase corrections to E13
- `PLAN.md` — architect phase
- `TESTPLAN.md` — testplan phase + QA phase corrections to T4.4
- `REVIEW.md` — review phase
- `QA_REPORT.md` — this file

## QA Fix Pass Log

**Pass 1:**
- Fix 1: `T8.3` allowed-set was too narrow — extended to include
  three unavoidable test-suite wiring deltas
  (`test-app.sh`, `test_routes_api.py`,
  `test_routes_api_artifacts_grinder.py`) that must change
  whenever a new APIRouter path is added. Edit at
  `dashboard/tests/test_status_endpoint.py:822-844`.
- Fix 2: `REQUIREMENTS.md E13` + `TESTPLAN.md T4.4` predicted
  trailing-slash → 422/404; observed Starlette behaviour is
  307 redirect to canonical no-trailing-slash form. Both docs
  rewritten to match observation; the test file was already
  correct.

**Pass 2:** Not needed — all 77 feature tests + 388 canonical
FastAPI tests + 1007 Python dashboard tests pass after Pass 1
fixes.
