<!-- phase: testplan | date: 2026-05-14 | branch: feature/session-status-endpoint -->

# TESTPLAN — `GET /api/{target_kind}/status` endpoint

## Summary

One new pytest module, `dashboard/tests/test_status_endpoint.py`, exercises
the C1 handler end-to-end through `fastapi.testclient.TestClient`. Every
testable behaviour from REQUIREMENTS.md (R1–R15, R-OUT-1, R-OUT-2, R-CON-1,
R-CON-2, R-CON-3) and every acceptance scenario AS1–AS15 traces to exactly
one row below. Edge cases E1–E17 trace to rows in § Negative-Path Coverage
or are noted as "documented by design, not a runtime test". The 40 MB
warm-cache latency smoke (AS4 / plan AC#3) lives behind a session-scoped
fixture so a single 200 k-line stream is built once per suite run.

No test is written here — only scenarios. Implementation lands in
`/implement` Step 2 (TDD red→green→refactor) where each row below becomes
one or more `def test_*` functions.

### JSON body byte-format note (load-bearing for body-bytes assertions)

`StdlibJSONResponse.render` calls `json.dumps(content).encode("utf-8")`
with no `separators=` kwarg, so the response uses Python's default
separators `(', ', ': ')` — a comma-space pair AND a colon-space
pair. The serialized body for an idle target is therefore the byte
string

```
b'{"status": "idle", "phase_at_pause": null, "last_phase_complete": null, "started_at": null, "tmux_session": null}'
```

with spaces after every comma and after every colon. Body strings
shown inline in the rows below are rendered in compact form
(`{"status":"idle",...}`) for human readability; **the actual
implementation emits the spaced form** and every body-byte
assertion MUST be written against the spaced form. The recommended
shape is `response.content == json.dumps(expected_dict).encode("utf-8")`
(matches the established pattern in `test_routes_api.py:156-158`,
`test_routes_api.py:218-219`, and
`test_routes_api_artifacts_grinder.py:124`), which sidesteps the
discrepancy by letting Python re-serialize the expected dict.

## Fixtures

| Name | Scope | Source pattern | Purpose |
|---|---|---|---|
| `_reset_cache_autouse` | function (autouse) | mirrors `test_status_helper.py:35-39` | Calls `status_helper._reset_cache()` before+after every test. Prevents `_STATE_CACHE` from leaking across tests (Risk-1). |
| `patched_root` | function | mirrors `test_status_helper.py:42-45` | `monkeypatch.setattr(status_helper, "_PROJECTS_ROOT", tmp_path)`. Hermetic root for stream-discovery tests. |
| `client` | function | mirrors `test_routes_api.py:31-39` | Fresh `FastAPI()` + `include_router(router)` + a `RequestValidationError → 400` handler registered. The handler logic is **inlined verbatim** (~8 LOC) in the fixture rather than imported from `dashboard.server.app` — `_validation_error_to_400` has a leading underscore (module-private), and crossing module boundaries on a private symbol is a code smell (Finding #7 of the review phase). Inlining the 8 LOC duplicates the body shape `{"detail": [...]}` once and pins the test app's behaviour to a known shape independent of future `app.py` refactors. Used for Pydantic/Query 400 path assertions and the 200 success path. |
| `client_html` | function | mirrors `test_routes_api.py:42-63` | Same as `client` PLUS `html_4xx_handler` + `html_500_handler` registered. Used for stdlib-HTML 4xx body-bytes assertions on the handler-raised `HTTPException` (regex 400). |
| `make_stream` / `append_lifecycle` / `_stream_path` | helper functions | mirrors `test_status_helper.py:48-88` | Build NDJSON lifecycle stream files at the helper's resolved path. Reused verbatim — no behavioural divergence from helper-test patterns. |
| `large_stream` | session | NEW | Builds one 40 MB autopilot stream under `tmp_path_factory` once per session: ~200 000 non-lifecycle lines plus a final `started` lifecycle event. Returns `(projects_root, target_id)`. Used by TC-LATENCY only. |
| `mock_derive_status` | function | NEW (uses `monkeypatch.setattr`) | Patches `dashboard.server.routes.api.derive_status` (the in-module symbol — NOT `status_helper.derive_status`) to a `MagicMock` or a stub-returning-fixed-dict. Used by rows that assert call count, call args, or "helper not called". |

**Cache-reset rationale (Risk-1):** `derive_status` mutates a module-level
`_STATE_CACHE` dict keyed by `(target_kind, target_id)`. Without the autouse
reset, a "missing stream" test that runs after a "populated stream" test
would silently see the populated state. The reset hook makes test
ordering irrelevant.

**`large_stream` rationale (Risk-3):** Building a 40 MB NDJSON file at
~200 k lines takes ~2–3 s on the reference workstation. Session scope
amortizes this cost across the latency smoke's 100 iterations and any
other test reusing the fixture.

## Test Scenarios

Component column matches PLAN.md: `C1` = handler in `routes/api.py`,
`C2` = test module itself, `C3` = `CLAUDE.md` bullet.

### Group 1 — 200 success path (AS1, AS5, AS8, AS9, AS12, AS13-pass, E1, E9)

| # | Scenario | Req IDs | Component | Type | Fixtures / Mocks |
|---|---|---|---|---|---|
| T1.1 | `GET /api/autopilot/status?id=feat-x` against a stream with one `started` event returns 200 + body `{"status":"running","phase_at_pause":null,"last_phase_complete":null,"started_at":"<ts>","tmux_session":null}` byte-for-byte | R1, R5, R6, AS1 | C1 | integration | `client`, `patched_root`, `make_stream` + `append_lifecycle(action="started")` |
| T1.2 | Parameterized over each helper-reachable status value (`idle`, `running`, `paused`, `cancelled`), `GET /api/autopilot/status?id=feat-x` returns 200 with `body["status"]` equal to the parameter | R6, AS1 | C1 | integration | `client`, `patched_root`, parameterized lifecycle event sequences |
| T1.3 | `Content-Type: application/json; charset=utf-8` header is present on 200 responses (note: space before `charset`, matching `StdlibJSONResponse.media_type`) | R6 | C1 | integration | `client`, `patched_root`, `make_stream` |
| T1.4 | `Cache-Control: no-store` header is present on 200 responses | R6, R11 | C1 | integration | `client`, `patched_root`, `make_stream` |
| T1.5 | AS5: missing stream file → 200 with `{"status":"idle","phase_at_pause":null,"last_phase_complete":null,"started_at":null,"tmux_session":null}`. Four optional fields serialize as JSON literal `null`, not string `"null"`. | R6, AS5, E1 | C1 | integration | `client`, `patched_root` (no `make_stream` call) |
| T1.6 | AS5 corollary: idle response emits zero WARNING records from the `dashboard.server.status_helper` logger | R13, AS5 | C1 | integration | `client`, `patched_root`, `caplog` |
| T1.7 | AS12: `list(json.loads(response.content).keys()) == ["status", "phase_at_pause", "last_phase_complete", "started_at", "tmux_session"]` exactly. Field order is the contract. | R6, AS12 | C1 | integration | `client`, `patched_root`, `make_stream` |
| T1.8 | AS8: a stream with `started` → `phase_complete phase=ba` → `paused phase_at_pause=plan` returns body `{"status":"paused","phase_at_pause":"plan","last_phase_complete":"ba","started_at":"<started ts>","tmux_session":null}` | R6, AS8 | C1 | integration | `client`, `patched_root`, `make_stream` + 3 `append_lifecycle` calls |
| T1.9 | AS8 corollary: a stream ending with `cancelled` returns `{"status":"cancelled", …}` with `phase_at_pause=null` (helper R24 clears the pause field on transitions out of paused) | R6, AS8 | C1 | integration | `client`, `patched_root`, lifecycle sequence ending in `cancelled` |
| T1.10 | AS9: `GET /api/chain/status?id=<id>` with a `docs/INPROGRESS_Plan_<id>/chain-events.ndjson` file returns 200 with `status="running"` (the helper picks the chain file because `target_kind="chain"`) | R6, AS9, E12 | C1 | integration | `client`, `patched_root`, `make_stream(kind="chain", ...)` |
| T1.11 | AS9 isolation (TC-KIND-ISOLATION): same `id` returns idle for `target_kind="autopilot"` and `running` for `target_kind="chain"` when only the chain stream exists — proves the helper keys on `target_kind` end-to-end | R6, AS9 | C1 | integration | `client`, `patched_root`, `make_stream(kind="chain", ...)` only |
| T1.12 | AS13 (accept side): `id` of exactly 64 characters, all in regex set, returns 200 (helper returns idle, no stream for that id) | R4, AS13, E9 | C1 | integration | `client`, `patched_root`, no `make_stream` |
| T1.13 | E1: numeric-only `id` (`id=12345`) passes regex; 200 returned (idle). | R4, E1 | C1 | integration | `client`, `patched_root` |
| T1.14 | E9: leading/trailing `-` or `_` (`id=-feat-`, `id=_feat_`) pass regex; 200 returned. | R4, E9 | C1 | integration | `client`, `patched_root`, parameterized over both values |

### Group 2 — Helper-call contract (AS2, AS11)

| # | Scenario | Req IDs | Component | Type | Fixtures / Mocks |
|---|---|---|---|---|---|
| T2.1 | AS11: a valid request invokes `derive_status` exactly once. Patch `dashboard.server.routes.api.derive_status` (the in-module re-import) with a `MagicMock(return_value=IDLE_DEFAULT)`. Assert `mock.call_count == 1` and `mock.call_args == call("autopilot", "feat-x")` | R5, R-CON-1, AS11 | C1 | unit | `client`, `mock_derive_status` |
| T2.2 | AS11 arg-order: `target_kind` is the first positional, `id` (passed as `target_id`) is the second. Pin via `mock.call_args[0] == ("autopilot", "feat-x")`. | R5, AS11 | C1 | unit | `client`, `mock_derive_status` |
| T2.3 | T2.1 sibling for chain: `GET /api/chain/status?id=feat-x` → mock called with `("chain", "feat-x")` | R5, AS11 | C1 | unit | `client`, `mock_derive_status` |
| T2.4 | AS2 negative-side: regex-rejected request does NOT call the helper. Patch `derive_status` to raise `RuntimeError("must not be called")`; assert request still returns 400, no `RuntimeError` escapes. | R4, R5, R8, AS2 | C1 | unit | `client_html`, `mock_derive_status(side_effect=RuntimeError)` |
| T2.5 | T2.4 sibling for Pydantic-rejection: bad `target_kind` does NOT call helper. Same `RuntimeError` mock; assert 400 + `mock.call_count == 0`. | R3, R8, AS3 | C1 | unit | `client`, `mock_derive_status(side_effect=RuntimeError)` |
| T2.6 | T2.4 sibling for empty `id`: `id=` does NOT call helper. | R4, R8, AS14 | C1 | unit | `client`, `mock_derive_status(side_effect=RuntimeError)` |
| T2.7 | The route wraps the helper's return verbatim. Mock returns a fixed dict `{"status":"X", …}`; assert `json.loads(response.content) == fixed_dict`. Pins the "thin shim" contract (R5, R-CON-3) — no route-level reshaping. | R5, R6, R-CON-3 | C1 | unit | `client`, `mock_derive_status` |

### Group 3 — 400 / 4xx error paths (AS2, AS3, AS13-reject, AS14, E2, E3, E15)

| # | Scenario | Req IDs | Component | Type | Fixtures / Mocks |
|---|---|---|---|---|---|
| T3.1 | AS2: `GET /api/autopilot/status?id=bad%20id` returns 400 (regex rejection inside handler → `HTTPException(400, "Invalid id parameter")`). Body bytes match the stdlib HTML 4xx template: `b"<p>Message: Invalid id parameter</p>"` and `b"<p>Error code: 400</p>"` are substrings of `response.content`. Header `content-type: text/html;charset=utf-8` (no space before `charset` — see `_exception_handlers.py:27`). | R4, R6, R7, AS2 | C1 | integration | `client_html` |
| T3.2 | E2 (parameterized over `feat.x`, `feat/x`, `feat x`, `feat;rm`): regex rejection → 400 + same stdlib HTML body | R4, E2 | C1 | integration | `client_html`, parameterized |
| T3.3 | E15: `id=..` → regex fails → 400. Verify no filesystem access (mock `derive_status` to raise; expect no raise to escape). | R4, E15 | C1 | unit | `client_html`, `mock_derive_status(side_effect=RuntimeError)` |
| T3.4 | AS3: `GET /api/frobnicate/status?id=feat-x` returns 400 via `_validation_error_to_400`. Body parses as JSON; `body["detail"]` is a list; `body["detail"][0]["loc"]` includes the literal string `"target_kind"`; `body["detail"][0]["type"]` starts with `"literal_"` (covers Pydantic v2 `literal_error` naming variants — Risk-2 mitigation). | R3, R7, AS3 | C1 | integration | `client` |
| T3.5 | E3: `target_kind="AUTOPILOT"` (uppercase) → 400 via `_validation_error_to_400`. Same body shape as T3.4. | R3, E3 | C1 | integration | `client` |
| T3.6 | AS14: `GET /api/autopilot/status?id=` (empty query) returns 400 via `_validation_error_to_400` (Query `min_length=1` rejection). Body shape: `body["detail"][0]["loc"]` includes `"id"`; `body["detail"][0]["type"]` starts with `"string_"` or `"missing"`. | R4, AS14 | C1 | integration | `client` |
| T3.7 | AS13 (reject side): `id` of 65 characters (all in regex set) → 400 via `_validation_error_to_400` (Query `max_length=64` rejection — note this is the Query-layer rejection, NOT the handler's regex which has no length cap in `_RE_SAFE_ID`). Body shape: `body["detail"][0]["loc"]` includes `"id"`, `body["detail"][0]["type"]` starts with `"string_too_long"` or `"string_"`. | R4, AS13 | C1 | integration | `client` |
| T3.8 | Missing `id` parameter entirely (`GET /api/autopilot/status`) returns 400 via `_validation_error_to_400` (Query required-param rejection). | R4, AS14 | C1 | integration | `client` |

### Group 4 — Method / URL surface (AS6, AS7, E13)

| # | Scenario | Req IDs | Component | Type | Fixtures / Mocks |
|---|---|---|---|---|---|
| T4.1 | AS7: `POST /api/autopilot/status?id=feat-x` returns 405. Response headers include `Allow: GET` (FastAPI default). | R10, AS7 | C1 | integration | `client` |
| T4.2 | T4.1 parameterized over PUT, PATCH, DELETE → 405 each. | R10 | C1 | integration | `client`, parameterized |
| T4.3 | OPTIONS `/api/autopilot/status?id=feat-x` returns 200 with an `Allow` header listing `GET`. (FastAPI auto-generates an OPTIONS handler that returns the allowed-methods set for the path.) HEAD `/api/autopilot/status?id=feat-x` returns 200 with an empty body (FastAPI emits HEAD via the GET handler with the body stripped, per Starlette's routing). Both assertions are pinned — if a future FastAPI release changes the behaviour, this row fails loudly and the implementer revisits the contract. | R10 | C1 | integration | `client`, `patched_root`, `make_stream` |
| T4.4 | E13: `GET /api/autopilot/status/?id=feat-x` (trailing slash) returns 307 with `Location` pointing to the canonical no-trailing-slash form (Starlette default redirect; route body does not execute). Documented behaviour — no redirector added by this task. (Original BA prose predicted 422; corrected at QA after observed behaviour.) | R-CON-3, E13 | C1 | integration | `client` |
| T4.5 | AS6 / TC-NO-ORIGIN: `GET /api/autopilot/status?id=feat-x` with no `Origin` header returns 200 (Origin middleware is method-gated to unsafe methods + WS — verified upstream by middleware tests; this row is a pass-through smoke). Note: the `client` fixture composes a fresh app WITHOUT middleware, so this row also asserts that no route-level Origin check exists. | R10, AS6 | C1 | integration | `client`, `patched_root`, `make_stream` |
| T4.6 | AS6 / TC-DIS-ORIGIN: `GET /api/autopilot/status?id=feat-x` with `Origin: http://example.com` returns 200 in the SAME middleware-less test app. Pins the route-level behaviour: the handler does not inspect `Origin`. Production-side Origin enforcement is owned by `OriginMiddleware` and is method-gated (covered by `test_origin_check.py`); this row prevents a future regression where the handler grows its own Origin gate. | R10, AS6 | C1 | integration | `client`, `patched_root`, `make_stream` |

### Group 5 — Cross-validation / drift detection (AS10, AS15, Risk-5)

| # | Scenario | Req IDs | Component | Type | Fixtures / Mocks |
|---|---|---|---|---|---|
| T5.1 | TC-CROSS (AS10, R12): `typing.get_args(_TargetKind) == status_helper.TARGET_KINDS`. Pure import-time test — no client, no fixture. A future agent extending `TARGET_KINDS` (e.g., to add `grinder`) without updating the route's Literal fails this row before merge. | R3, R12, AS10 | C1, C2 | contract | (none — pure imports) |
| T5.2 | Behavioral drift detector (Risk-5): the **set** of `target_id` values accepted by the route (FastAPI `Query(min_length=1, max_length=64)` + handler `re.match(_RE_SAFE_ID, target_id)`) equals the set accepted by `status_helper._TARGET_PATTERN`. The regex *strings* are not equal (route's `_RE_SAFE_ID = r"^[a-zA-Z0-9_-]+$"` has no length cap; helper's `_TARGET_PATTERN.pattern = r"^[a-zA-Z0-9_-]{1,64}$"` does — see PLAN.md F6), so the test asserts behavioral equivalence via parameterized inputs: positive ids (length 1, length 64, all hyphens, all underscores, mixed alphanumerics, all digits) match BOTH `_TARGET_PATTERN` and the combined Query-bound + `_RE_SAFE_ID` predicate; negative ids (length 65, dot, slash, space, semicolon, empty string) are rejected by BOTH. Additionally introspect the route surface to assert `Query(min_length=1, max_length=64)` is declared (so a future drop of the length bound at the route layer is caught): locate the new route via `next(r for r in router.routes if getattr(r, "path", None) == "/api/{target_kind}/status")` and assert its dependant's query param for `target_id` declares both `min_length == 1` and `max_length == 64` (the exact accessor — `route.dependant.query_params[0].field_info` or equivalent — is determined at implementation time against the live FastAPI version). | R-CON-2, AS15 | C1, C2 | contract | (none — pure imports + parameterized inputs) |
| T5.3 | The route does NOT import `lifecycle_events.parse_event`, `read_stream_incremental`, `_resolve_stream_path`, or `_status_from_stream` (R5). Assert via `inspect.getsource(routes_api)` text scan for those identifiers (negative assertion — these names must not appear in the route file). | R5 | C1, C2 | contract | (none — pure source-text scan) |
| T5.4 | The new handler is registered exactly once on the router. Assert `len([r for r in router.routes if getattr(r, "path", None) == "/api/{target_kind}/status"]) == 1` and that its `methods` set equals `{"GET"}`. This is a focused regression check — it does NOT enumerate every other top-level symbol in `routes/api.py` (which would create coupling to unrelated future additions) but does pin the one fact R1 / R-OUT-1 care about: this task added one GET handler at the documented path. | R1, R-OUT-1 | C1, C2 | contract | (none — pure introspection) |
| T5.5 | TC-CROSS for the schema reuse path: the project-wide `FeatureId` regex (`dashboard.server.schemas.FeatureId.__metadata__[0].pattern`) and the route's `_RE_SAFE_ID` accept the **same set** of ids when constrained to length 1-64. Asserted via parameterized boundary inputs (the same positive/negative set used by T5.2). The regex *strings* are not equal — `FeatureId` is `r"^[a-zA-Z0-9_-]{1,64}$"`; `_RE_SAFE_ID` is `r"^[a-zA-Z0-9_-]+$"` — but the route layer applies a length cap via `Query(min_length=1, max_length=64)`, so the route's effective accepted set equals `FeatureId`'s. Catches the case where someone changes `FeatureId` (e.g., to add `.` to the character class) without realising the route doesn't use `FeatureId` directly. | R3, R-CON-1 | C1, C2 | contract | (none — pure imports + parameterized inputs) |

### Group 6 — Latency / performance (AS4, plan AC#3)

| # | Scenario | Req IDs | Component | Type | Fixtures / Mocks |
|---|---|---|---|---|---|
| T6.1 | AS4 / plan AC#3: build a 40 MB autopilot stream once (`large_stream` session fixture) with ~200 000 non-lifecycle JSON lines (skipped by the helper as non-lifecycle, per helper AS7) plus a final `started` lifecycle event. Issue one cold poll to warm the cache. Then issue 100 sequential `GET /api/autopilot/status?id=<id>` requests, measuring wall time via `time.perf_counter()` per request. Assert: (a) every response is HTTP 200 with `body["status"] == "running"`, (b) the maximum per-request wall time ≤ 200 ms, (c) the median per-request wall time ≤ 50 ms (catches a quiet regression that still passes the 200 ms cap but spends ~100 ms per call). | R9, AS4 | C1 | smoke (integration) | `client`, `patched_root`, `large_stream` |
| T6.2 | AS4 sibling — incremental-read warm path: after the cold warm-up, append ONE 256-byte `phase_complete` event to the 40 MB stream, then issue one poll. Wall time ≤ 50 ms (the helper reads only the appended bytes — see helper F1 incremental-read test). Asserts the cache-plus-append path scales with delta size, not file size. | R9, AS4 | C1 | smoke (integration) | `client`, `patched_root`, `large_stream` |

### Group 7 — CLAUDE.md and docs

| # | Scenario | Req IDs | Component | Type | Fixtures / Mocks |
|---|---|---|---|---|---|
| T7.1 | The CLAUDE.md `## Dashboard Subtree` → `### Layout` section contains a new bullet that references `dashboard/server/routes/api.py` and the GET status route. Assert via reading `CLAUDE.md` and grepping for the substring `routes/api.py` + `target_kind` (case-insensitive). Does NOT pin the exact text — wording is per R-OUT-2 illustrative. | R-OUT-2 | C3 | contract | (file read) |

### Group 8 — No-change guards (R2, R-OUT-1)

| # | Scenario | Req IDs | Component | Type | Fixtures / Mocks |
|---|---|---|---|---|---|
| T8.1 | R2: `git diff main...HEAD -- dashboard/server/app.py` produces zero lines (run via `subprocess.run(["git", "diff", "main...HEAD", "--", "dashboard/server/app.py"])` inside the test). Skipped automatically if `git` is not available or the test is run outside a git checkout. | R2 | C1 | contract | `subprocess` |
| T8.2 | R-OUT-1: `git diff main...HEAD -- dashboard/server/status_helper.py` produces zero lines. Same skip policy as T8.1. | R-OUT-1 | C1 | contract | `subprocess` |
| T8.3 | R-OUT-1 generalized (production code only): `git diff main...HEAD --name-only -- ':!docs/'` lists EXACTLY the three expected paths (`CLAUDE.md`, `dashboard/server/routes/api.py`, `dashboard/tests/test_status_endpoint.py`) — no more, no less. The pathspec `':!docs/'` excludes the per-phase documentation files under `docs/INPROGRESS_Feature_session-status-endpoint/` (REQUIREMENTS.md, PLAN.md, TESTPLAN.md, REVIEW.md, QA_REPORT.md, …) and the execution-plan mutation at `docs/INPROGRESS_Plan_*/execution-plan.yaml` — all committed as ordinary phase artifacts by predecessor phases. Without this exclusion, the assertion would compare against ~8 paths and fail. Skipped outside git. This row catches accidental edits to schemas.py, _serve_legacy.py, app.py, status_helper.py, every middleware file, every other route module, and every bash file under `adapters/claude-code/`. | R-OUT-1, PLAN § File-by-file | C1, C2, C3 | contract | `subprocess` |

## Negative-Path Coverage Map

| Edge case | Row(s) | Coverage type |
|---|---|---|
| E1 — numeric `id` | T1.13 | runtime |
| E2 — dot/slash/whitespace in `id` | T3.2 | runtime |
| E3 — uppercase `target_kind` | T3.5 | runtime |
| E4 — concurrent polls same target | (none) | documented in helper R23 / R-CON-2; single-worker uvicorn invariant. Not asserted at the endpoint level. |
| E5 — concurrent polls different targets | (none) | documented; per-target cache keys are independent. Not asserted at the endpoint level. |
| E6 — stream truncation mid-poll | (helper test) | covered by `test_status_helper.py` AS10 / R10. Endpoint is a pass-through; no separate runtime test. |
| E7 — OSError on stat race | (helper test) | covered by `test_status_helper.py` E7 / R14. Endpoint is a pass-through. |
| E8 — `_RE_SAFE_ID` removed from `_serve_legacy` | (import-time) | not a runtime test — fails at import (covered by T1.1 collection). |
| E9 — leading/trailing hyphens in `id` | T1.14 | runtime |
| E10 — helper-side enum extension widens status values | (intentionally open) | endpoint is transparent; documented by design. No row. |
| E11 — client ignores `Cache-Control: no-store` | (out of scope) | client-side behaviour. No row. |
| E12 — chain `id` collides with autopilot feature dir | T1.11 (kind isolation) | runtime |
| E13 — trailing slash | T4.4 | runtime |
| E14 — legacy query param (`task=…` instead of `id=…`) | T3.8 (missing `id` rejection) | runtime |
| E15 — path-traversal `id` (`..`) | T3.3 | runtime |
| E16 — helper returns unexpected status value | (intentionally open) | endpoint relays; documented. No row. |
| E17 — helper module not importable | (import-time) | covered by test-collection failure. No row. |

## Cross-Cutting Concerns

| Concern | Coverage |
|---|---|
| **CSRF** | Route is GET-only (T4.1–T4.3). CSRF middleware is method-gated to unsafe methods; no CSRF token needed. AS6 (T4.5) confirms no route-level CSRF check exists. |
| **Origin** | Same as CSRF — method-gated. T4.5 / T4.6 confirm GET passes through middleware-less test app unchanged, pinning the absence of a route-level Origin gate. |
| **Authentication** | Out of scope at the dashboard layer (binds to 127.0.0.1 per CLAUDE.md § Security Rules). No auth test. |
| **Logging** | T1.6 asserts no WARNING from the helper logger on the idle path. Per-request access logging is owned by `AccessLogMiddleware` (`app.py`) — covered by its own dedicated tests, not duplicated here (R13). |
| **Observability / tracing** | None added by this task. No OpenTelemetry / metric. Not in the test plan. |
| **Feature flags** | None. No config edit (PLAN § Config Changes). No row. |
| **Schema reuse / drift** | T5.1 (Literal ↔ TARGET_KINDS), T5.2 (regex parity), T5.5 (FeatureId ↔ _RE_SAFE_ID). Three contract rows form the drift-detector net. |
| **Byte-equivalent response shape** | T1.3 (Content-Type), T1.4 (Cache-Control), T1.7 (field order), T3.1 (HTML 4xx body bytes). The four-row set pins the bytes the Phase 3 Watchfloor UI fixture diffs against. |
| **LOC budget (R15)** | Not a runtime test. Verified at implementation time via `wc -l` on the two files (≤ 35 added in `routes/api.py`, ≤ 350 total in `test_status_endpoint.py`). |

## Manual Test Scenarios

The feature ships an HTTP endpoint only — no UI surface, no bash script,
no operator workflow. The acceptance criteria are fully covered by the
pytest module above. The following two manual smoke commands are listed
so the implementer can copy-paste-verify the route locally before opening
the `/qa` checkpoint; they are NOT pinned in CI.

| # | Command | Expected result |
|---|---|---|
| M1 | Start dashboard: `start-system dashboard`. In another shell: `curl -s -w '\nHTTP %{http_code}\n' 'http://127.0.0.1:8787/api/autopilot/status?id=nonexistent-feat-id'` | HTTP 200 with body `{"status":"idle","phase_at_pause":null,"last_phase_complete":null,"started_at":null,"tmux_session":null}` and headers `Content-Type: application/json; charset=utf-8`, `Cache-Control: no-store`. Visual confirmation of T1.5 + T1.3 + T1.4 against the live uvicorn instance. |
| M2 | `curl -s -w '\nHTTP %{http_code}\n' 'http://127.0.0.1:8787/api/autopilot/status?id=bad%20id'` | HTTP 400 with stdlib HTML body containing `<p>Message: Invalid id parameter</p>`. Visual confirmation of T3.1 against the live exception handler chain. |

These rows trace to the host execution-plan.yaml task's
`task.manualtest_scenarios` field — but since the route has no UI
component, the manual scenarios are minimal-by-design and do NOT
substitute for the pytest coverage above.

## Requirement-to-Test Trace Matrix

Every REQUIREMENTS.md ID has at least one test row.

| Requirement | Test rows |
|---|---|
| R1 | T1.1, T5.4 |
| R2 | T8.1, T8.3 |
| R3 | T3.4, T3.5, T5.1, T5.5 |
| R4 | T3.1, T3.2, T3.3, T3.6, T3.7, T3.8, T1.12, T1.13, T1.14 |
| R5 | T2.1–T2.7, T5.3 |
| R6 | T1.1, T1.3, T1.4, T1.7, T1.8, T1.9, T1.10, T2.7 |
| R7 | T3.1 (HTML 4xx body), T3.4 (`{"detail":[...]}` shape) |
| R8 | T2.4, T2.5, T2.6 (order: presence → regex → helper) |
| R9 | T6.1, T6.2 |
| R10 | T4.1, T4.2, T4.3, T4.5, T4.6 |
| R11 | T1.4 |
| R12 | T5.1 |
| R13 | T1.6 |
| R14 | T5.4 (no new top-level imports beyond declared set), T5.1 / T5.5 (`TARGET_KINDS` import sanity) |
| R15 | enforced at implementation, no runtime row |
| R-OUT-1 | T8.2, T8.3 |
| R-OUT-2 | T7.1 |
| R-CON-1 | T2.1, T3.5, T3.6 (one mechanism per parameter — Literal for kind, regex for id) |
| R-CON-2 | T5.2 (drift detector closes the gap that would expose this risk) |
| R-CON-3 | T2.7, T4.4 (no other path variants) |

## Acceptance-Scenario-to-Test Trace

| AS | Test rows |
|---|---|
| AS1 | T1.1, T1.2 |
| AS2 | T3.1, T2.4 |
| AS3 | T3.4, T2.5 |
| AS4 | T6.1, T6.2 |
| AS5 | T1.5, T1.6 |
| AS6 | T4.5, T4.6 |
| AS7 | T4.1, T4.2 |
| AS8 | T1.8, T1.9 |
| AS9 | T1.10, T1.11 |
| AS10 | T5.1 |
| AS11 | T2.1, T2.2, T2.3 |
| AS12 | T1.7 |
| AS13 | T1.12, T3.7 |
| AS14 | T3.6, T3.8, T2.6 |
| AS15 | T5.2 (drift detector — runtime test pinning the contract; the unreachable-by-design branch itself is not exercised at runtime per R-CON-2) |

## Out-of-Scope (explicit)

The following are **NOT** tested by this module:

- Helper-internal behaviour (NDJSON parsing, byte-offset cache mechanics,
  path resolution under `PROJECTS_ROOT`): covered by
  `dashboard/tests/test_status_helper.py`. Not duplicated here per R5.
- Middleware behaviour (`OriginMiddleware`, `CSRFMiddleware`,
  `AccessLogMiddleware`): covered by their own test modules. The route is
  GET-only and the test app does not register middleware; T4.5 / T4.6
  documents that the route does not add its own Origin check.
- FastAPI's `_validation_error_to_400` body format beyond the 400 status
  code + minimal `body["detail"][0]` shape assertions (Risk-2 mitigation).
- Frontend / Watchfloor UI consumption: the Phase 3 UI task ships its own
  byte-equivalent fixture diff against this endpoint's response.
- LOC budget enforcement (R15): verified manually at implementation time,
  not as a pytest row.

## Open Questions

**None.** All scenarios, fixtures, mocks, and trace rows are fully
specified. The plan-phase reviewer can accept or amend specific rows
without altering the overall coverage scope.
