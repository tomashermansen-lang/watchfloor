<!-- phase: review | date: 2026-05-14 | branch: feature/session-status-endpoint -->

# Review Report: session-status-endpoint

## Verdict: APPROVED (2 passes, 10 fixes)

## Summary

The plan ships a single 33-LOC FastAPI handler in
`dashboard/server/routes/api.py` that thinly wraps
`status_helper.derive_status`, plus one new pytest module and a
one-line CLAUDE.md bullet. After two review passes, the plan
correctly reflects the production app's actual behaviour
(`_validation_error_to_400` returns 400, not 422), avoids private-
symbol coupling, uses domain-specific identifier naming consistent
with every sibling handler, and grounds its drift-detector tests in
behavioral assertions (not string-equality on regex constants that
the architect originally assumed matched but in fact do not). The
JSON byte-format discrepancy between human-readable body samples and
the actual `json.dumps()` default-separator output is documented in
PLAN.md F4 and TESTPLAN.md, with the recommended assertion pattern
(`response.content == json.dumps(expected).encode("utf-8")`) pinned
to the established convention in three sibling test files. The plan
is feasible against the existing architecture, SOLID-clean, and TDD-
ready.

## Findings Resolved

| # | Pass | Severity / Category | Description | Fix Applied |
|---|------|---------------------|-------------|-------------|
| 1 | 1 | WARNING / test-correctness | TESTPLAN.md T5.2 asserts `_RE_SAFE_ID == status_helper._TARGET_PATTERN.pattern` but the strings differ — `_RE_SAFE_ID = r"^[a-zA-Z0-9_-]+$"` (no length cap) vs `_TARGET_PATTERN = r"^[a-zA-Z0-9_-]{1,64}$"`. The drift detector would fail on first run and PLAN.md Risk-5 mitigation is unmitigated. T5.5 has the same defect against `FeatureId`. | Rewrote T5.2 and T5.5 as **behavioral** drift detectors — parameterized boundary inputs verify the ROUTE'S two-layer accept set (Query `min_length=1, max_length=64` + handler `_RE_SAFE_ID` chars) equals the helper's `_TARGET_PATTERN` accept set. Added PLAN.md F6 documenting the regex divergence. Updated Risk-5 mitigation language in PLAN.md to reference the new shape. |
| 2 | 1 | WARNING / spec-implementation gap | REQUIREMENTS.md R6 + AS1/AS5/AS8/AS9 and TESTPLAN.md T1.* show response bodies in compact JSON form (`{"status":"running",...}` no spaces) but `StdlibJSONResponse.render` uses `json.dumps(content).encode("utf-8")` with default separators `(', ', ': ')` — actual bytes have spaces. Tests written against the compact form would fail. | Added PLAN.md F4 byte-format note and a parallel "JSON body byte-format note" at the top of TESTPLAN.md, both pinning the actual spaced form and prescribing the recommended assertion pattern `response.content == json.dumps(expected_dict).encode("utf-8")` (matches the established pattern in `test_routes_api.py:156-158` / `test_routes_api_artifacts_grinder.py:124`). Body-sample text in individual rows stays in compact form for readability, but the byte assertion is unambiguously defined. |
| 3 | 1 | WARNING / test-correctness | TESTPLAN.md T8.3 says `git diff main...HEAD --name-only` must list EXACTLY 3 paths. The branch already has `docs/INPROGRESS_Feature_session-status-endpoint/{REQUIREMENTS,PLAN,TESTPLAN}.md` (committed as ba/plan/testplan artifacts) and the execution-plan.yaml mutation — `--name-only` returns 5+ paths today and 7+ after REVIEW.md and QA_REPORT.md land. The assertion would always fail. | Reworded T8.3 to use `git diff main...HEAD --name-only -- ':!docs/'` (pathspec excludes the docs tree). The assertion now correctly compares against the three production-code paths (CLAUDE.md, routes/api.py, test_status_endpoint.py) and explicitly enumerates the files this guard catches accidental edits to. |
| 4 | 1 | WARNING / deferred-keyword | TESTPLAN.md T6.3 was a `pytest.mark.skip(reason="documented expectation")` row — a skipped test is dead code, violates the "NO DEFERRING" rule. | Deleted T6.3 outright. Its negative-latency expectation is documented in PLAN.md Risk-3 mitigation prose if needed; nothing of value is lost. |
| 5 | 1 | WARNING / test-correctness | TESTPLAN.md T4.3 asserted "200 (or 405 — whichever FastAPI emits)" for HEAD requests — an indeterminate assertion is useless as a test. | Pinned T4.3 to FastAPI's actual auto-OPTIONS / auto-HEAD behaviour: OPTIONS returns 200 with `Allow` header listing GET; HEAD returns 200 with empty body (Starlette emits HEAD via GET with body stripped). The test now fails loudly if a future FastAPI release changes the behaviour. |
| 6 | 1 | WARNING / test-quality | TESTPLAN.md T5.4 specified `inspect.getmembers(routes_api)` diff against a baseline of allowed top-level names — fragile, breaks on any unrelated future addition. | Replaced T5.4 with a focused regression check: assert `len([r for r in router.routes if r.path == "/api/{target_kind}/status"]) == 1` and `methods == {"GET"}`. Pins exactly the fact R1 / R-OUT-1 care about. |
| 7 | 1 | SUGGESTION / encapsulation | TESTPLAN.md `client` fixture imported the module-private `_validation_error_to_400` from `dashboard.server.app`. Leading-underscore symbols crossing module boundaries are a code smell; R2 forbids editing app.py so promotion isn't an option. | Updated the TESTPLAN.md fixture description to inline the `RequestValidationError → 400` handler verbatim (~8 LOC) in the fixture. Removes the private-symbol import; trade-off is minor body-shape drift risk if app.py ever changes, but the contract is owned by the production callers (Watchfloor UI) and unlikely to move. |
| 8 | 1 | SUGGESTION / convention | PLAN.md C1 used the bare Python parameter name `id` (shadowing built-in `id()`). No other handler in `routes/api.py` uses `id` — every sibling uses domain-specific names (`task`, `cwd`, `feature`, `sid`, `project`). | Renamed the Python parameter to `target_id` and aliased to the URL parameter via `Query(..., alias="id", min_length=1, max_length=64)`. URL contract `?id=<id>` is preserved verbatim. Added a parameter-naming note under C1 explaining the convention. Propagated the rename through PLAN.md Summary, Data Flow, SOLID interfaces section, and the `_STATE_CACHE` side-effect note. |
| 9 | 1 | SUGGESTION / convention | PLAN.md C1 docstring template was `"""R1-R6: Pydantic-validated thin shim over status_helper.derive_status."""` — references requirement IDs in code, violating the global rule (don't reference current task or callers in code comments — IDs rot when REQUIREMENTS gets rewritten). | Dropped the `R1-R6:` prefix from the docstring template. The remaining text describes what the function does. |
| 10 | 1 | SUGGESTION / clarity | PLAN.md C1 surface shows `from typing import Literal` adjacent to the `from dashboard.server.status_helper ...` import — ambiguous whether `Literal` goes in the stdlib block (before sys.path bootstrap) or after. | Annotated the surface block with numbered comments explaining each import's correct placement: `typing.Literal` joins the stdlib block at lines 52-57 (no `noqa: E402`); `dashboard.server.status_helper` joins the dashboard.server.X block at lines 72-131 (with `noqa: E402` matching siblings); `_TargetKind` alias at line 133 adjacent to `router = APIRouter()`; handler at end of file after the grinder DELETE handler (line 594-614). |

## Findings Remaining

None. All findings resolved across two passes.

## Checklist

- [x] **Cross-document consistency: REQUIREMENTS → PLAN → TESTPLAN.**
  All 18 requirements (R1-R15 + R-OUT-1/2 + R-CON-1/2/3) trace to PLAN.md
  components and to at least one TESTPLAN.md row. All 15 acceptance
  scenarios trace to at least one row. All 17 edge cases either trace to
  a row or are explicitly marked "documented by design". The two
  divergences REQUIREMENTS.md R-RECONCILE flagged (response-field echoes,
  status code on bad `target_kind`) are closed by PLAN.md Risk-6.

- [x] **Feasibility against existing architecture.** Every claim in
  PLAN.md was verified against the live codebase:
  `_validation_error_to_400` exists and rewrites RequestValidationError
  → 400 (verified at `app.py:170-184`); `_RE_SAFE_ID` is already imported
  into `routes/api.py:73-90`; `StdlibJSONResponse.render` calls
  `json.dumps(content).encode("utf-8")` with default separators
  (`_responses.py:38-39`); `status_helper.TARGET_KINDS = ("autopilot",
  "chain")` (`status_helper.py:36`); `status_helper._TARGET_PATTERN`
  enforces `r"^[a-zA-Z0-9_-]{1,64}$"` (`status_helper.py:38`); routes/api.py
  is 615 lines with the grinder DELETE handler ending at line 614.
  Inserting the new handler at the end of the file is feasible.

- [x] **CLAUDE.md architecture rules.** The route uses the single helper
  call pattern (no inline NDJSON parsing — R5), respects the
  StdlibJSONResponse byte-equivalence contract (no FastAPI default
  JSONResponse), preserves the cache-control / content-type / field-order
  contracts the Phase 3 Watchfloor UI fixture diffs against. The bullet
  added to CLAUDE.md `## Dashboard Subtree` § Layout follows the
  established one-line-per-module pattern.

- [x] **SOLID compliance.** SRP, OCP, ISP, DIP all PASS per PLAN.md §
  SOLID Results, with each claim grounded in the actual code shape. LSP
  is N/A (no inheritance).

- [x] **Agentic navigability.** Handler naming
  (`api_session_status`) matches the `api_<resource>[_<action>]` pattern
  of every sibling. Test module naming (`test_status_endpoint.py`)
  mirrors `test_status_helper.py`. The `_TargetKind` alias signals
  module-private intent via leading underscore. CLAUDE.md update keeps
  the dashboard subtree's orientation index complete.

- [x] **TDD readiness + test plan covers requirements and components.**
  Every component (C1 handler, C2 test module, C3 CLAUDE.md bullet) and
  every requirement / acceptance scenario maps to at least one
  TESTPLAN.md row. The 40 MB latency smoke (T6.1/T6.2) is feasible via a
  session-scoped fixture. The drift detectors (T5.1, T5.2, T5.5) are now
  correctly grounded in behavioral equivalence, not string-equality on
  divergent regex constants. The cross-cutting concerns matrix at the
  end of TESTPLAN.md confirms what is and isn't tested at the route
  layer.
