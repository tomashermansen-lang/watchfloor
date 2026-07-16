<!-- phase: plan | date: 2026-05-14 | branch: feature/session-status-endpoint -->

# PLAN — `GET /api/{target_kind}/status` FastAPI endpoint over `status_helper.derive_status`

## Summary

Add one `async def api_session_status` handler to
`dashboard/server/routes/api.py`, decorated
`@router.get("/api/{target_kind}/status")`, that:

1. accepts `target_kind` as a path-parameter typed
   `Literal["autopilot", "chain"]` (Pydantic Literal coercion at the
   FastAPI request-validation layer);
2. accepts `id` as a query-parameter aliased to the Python
   parameter `target_id`
   (`fastapi.Query(..., alias="id", min_length=1, max_length=64)` —
   the `alias` mapping is required because bare `id` would shadow
   Python's built-in `id()`, breaking the codebase convention every
   sibling handler in `routes/api.py` follows);
3. inside the handler body, validates `target_id` against
   `_RE_SAFE_ID` (already imported from `_serve_legacy`);
4. calls `dashboard.server.status_helper.derive_status(target_kind,
   target_id)` exactly once;
5. returns the helper's `SessionStatus` dict wrapped in
   `StdlibJSONResponse`.

Add one new pytest module
`dashboard/tests/test_status_endpoint.py` covering the four plan
acceptance criteria (round-trip, 400 on bad input before any I/O,
warm-cache 200 ms latency on a 40 MB stream, idle envelope) plus the
cross-check tying the route's Literal to
`status_helper.TARGET_KINDS` (R12) and the response-shape contract
the Phase 2 control-endpoints + Phase 3 Watchfloor UI consume.

Add one bullet under `## Dashboard Subtree` → `### Layout` of
`CLAUDE.md` referencing the new route (R-OUT-2).

**No other files change.** `status_helper.py`, `app.py`,
`schemas.py`, `_serve_legacy.py`, `_responses.py`,
`_exception_handlers.py`, every middleware module, every other route
module, and every bash file under `adapters/claude-code/` are
untouched. `git diff main...HEAD --stat` after `/implement` lands
shall list exactly three paths:

```
CLAUDE.md
dashboard/server/routes/api.py
dashboard/tests/test_status_endpoint.py
```

## Research

REQUIREMENTS.md (R1-R15, R-OUT-1, R-OUT-2, R-CON-1, R-CON-2,
R-CON-3, AS1-AS15, E1-E17, R-RECONCILE) closes every degree of
freedom this task needs. The plan-phase findings below extend the
research with two facts the architect verified against the live
codebase that change the contract from REQUIREMENTS.md as written:

### F1 — `RequestValidationError` is globally rewritten to **400** (not 422)

`dashboard/server/app.py:170-184` registers
`_validation_error_to_400` against `RequestValidationError`:

```python
async def _validation_error_to_400(request: Request, exc: RequestValidationError) -> JSONResponse:
    errors = [
        {k: v for k, v in e.items() if k not in {"input", "url"}}
        for e in exc.errors()
    ]
    return JSONResponse(
        status_code=400,
        content=jsonable_encoder({"detail": errors}),
    )
```

Consequence:

- A request with `target_kind` outside `{autopilot, chain}` (Literal
  coercion failure) returns **HTTP 400** with body
  `{"detail":[{"type":"literal_error","loc":["path","target_kind"],"msg":"...","ctx":{...}}]}`,
  NOT 422 with `{"error":"invalid"}` as REQUIREMENTS.md AS3 / R-RECONCILE(2)
  states.
- A request with empty / missing `id` (Query `min_length=1`
  rejection) likewise returns **HTTP 400** via the same handler,
  NOT 422 as AS14 states.

This **resolves** R-RECONCILE(2): the actual behaviour matches plan
AC#2 ("400 with a structured error body before any file read")
verbatim. The architect adopts the actual app behaviour and updates
the test plan accordingly. AS3 and AS14 in TESTPLAN.md will assert
status_code 400 (not 422) against this handler.

### F2 — `_RE_SAFE_ID` is already imported into `routes/api.py`

`dashboard/server/routes/api.py:73-90` already imports `_RE_SAFE_ID`
from `_serve_legacy`. The new handler reuses the symbol verbatim;
no additional import line is needed for the regex.

### F3 — Sibling import shape for the helper

The existing `_serve_legacy` and `*_helpers.py` imports use the
`from dashboard.server.X import ...` form (lines 72-131 of
`routes/api.py`). The new helper import follows that exact shape:

```python
from dashboard.server.status_helper import TARGET_KINDS, derive_status  # noqa: E402
```

This deviates from REQUIREMENTS.md R14's suggested
`from server.status_helper import ...` form: REQUIREMENTS.md R14
proposed `from server.status_helper` because that mirrors how
`status_helper.py` itself imports `from server.lifecycle_events`.
But every other `routes/api.py` import goes through
`dashboard.server.X`, so the architect picks the in-module idiom
for one-file consistency. The `noqa: E402` suppresses ruff's
"import after `sys.path` mutation" warning, matching the existing
import block.

### F4 — `StdlibJSONResponse` JSON serialization preserves dict order AND uses default-separator spaces

`_responses.py:38-39`'s `render` calls `json.dumps(content)` with
default kwargs. Default kwargs preserve dict insertion order in
Python 3.7+. The helper's `SessionStatus` is a `TypedDict` whose
runtime form is a `dict` constructed via `SessionStatus(status=...,
phase_at_pause=..., last_phase_complete=..., started_at=...,
tmux_session=...)` — keys insert in that exact order. AS12's field-
order assertion is satisfied without route-level reordering.

**Byte format note (load-bearing for body-bytes assertions):**
`json.dumps()` with no `separators=` kwarg uses the defaults
`(', ', ': ')` — a comma-space pair AND a colon-space pair. So the
response body for an idle target is the byte string

```
b'{"status": "idle", "phase_at_pause": null, "last_phase_complete": null, "started_at": null, "tmux_session": null}'
```

with spaces after every comma and after every colon — NOT the
compact form `{"status":"idle",...}`. Every body-byte sample in
REQUIREMENTS.md R6 / AS1 / AS5 / AS8 / AS9 is rendered in compact
form for readability, but the implementation emits the spaced form
and tests MUST assert against the spaced form. The recommended test
shape is `response.content == json.dumps(expected_dict).encode("utf-8")`
(matches the established pattern in `test_routes_api.py:156-158`,
:218-219, and `test_routes_api_artifacts_grinder.py:124`), which
sidesteps the human-readability discrepancy by letting Python
re-serialize the expected dict.

### F6 — `_RE_SAFE_ID` is the bare character class (no length cap)

`dashboard/server/_serve_legacy.py:33` declares
`_RE_SAFE_ID = r"^[a-zA-Z0-9_-]+$"` — character class only, NO
`{1,64}` length bound. The `{1,64}` bound that REQUIREMENTS.md
implies (R4 line 307; R-OUT-2; AS13 line 793-801) lives in three
other places: (a) `dashboard.server.schemas.FeatureId` annotation
(`StringConstraints(pattern=r"^[a-zA-Z0-9_-]{1,64}$", min_length=1,
max_length=64)`), (b) `status_helper._TARGET_PATTERN` (compiled
regex `r"^[a-zA-Z0-9_-]{1,64}$"`), and (c) the new endpoint's
`Query(min_length=1, max_length=64)` declaration.

**Consequence:** the route's two-layer validation (Query bounds +
`_RE_SAFE_ID` chars) collectively matches the helper's single-layer
`_TARGET_PATTERN`, but the regex *strings* are not equal. The
drift-detector tests T5.2 / T5.5 cannot use a string-equality
assertion against `_RE_SAFE_ID`; TESTPLAN.md spells out the actual
behavioral assertions to use instead.

### F5 — Path-parameter Literal vs Annotated[str, ...]

REQUIREMENTS.md R3 picks `Literal["autopilot", "chain"]` directly.
The architect verified that FastAPI's path-parameter coercion for
`Literal` forwards the raw path segment to Pydantic, which validates
membership and emits `RequestValidationError` on mismatch.
`_validation_error_to_400` then converts to 400 (per F1). This is
the simplest declaration shape and matches the existing
`Annotated`-style pattern only by example (no path-param Literal
exists yet in `routes/api.py`).

## Components

### C1 — `api_session_status` handler in `dashboard/server/routes/api.py`

**File path**: `dashboard/server/routes/api.py` (modify)

**Responsibility (one sentence)**: Validate request shape via
Pydantic Literal + `Query(alias="id", min_length=1, max_length=64)` + a
`re.match(_RE_SAFE_ID, target_id)` guard, then call
`status_helper.derive_status(target_kind, target_id)` and wrap the
result in `StdlibJSONResponse`.

**Surface (added to the file)**:

```python
# 1. Stdlib import, joins the stdlib block at routes/api.py:52-57 (BEFORE
#    the sys.path bootstrap at lines 61-70 — no noqa needed):
from typing import Literal

# 2. First-party import, joins the dashboard.server.X block at lines
#    72-131 (AFTER the sys.path bootstrap — noqa: E402 matches the
#    existing siblings):
from dashboard.server.status_helper import TARGET_KINDS, derive_status  # noqa: E402

# 3. Module-level type alias (R3) — placed adjacent to ``router = APIRouter()``
#    at line 133:
_TargetKind = Literal["autopilot", "chain"]

# 4. Handler (placed at the END of the file, after the grinder DELETE
#    handler at line 594-614). The Python parameter is named
#    ``target_id`` (avoiding shadow of built-in ``id()``) and aliased
#    via ``Query(alias="id", ...)`` so the public URL contract
#    ``?id=<id>`` is preserved:
@router.get("/api/{target_kind}/status")
async def api_session_status(
    target_kind: _TargetKind,
    target_id: str = Query(..., alias="id", min_length=1, max_length=64),
) -> StdlibJSONResponse:
    """Thin Pydantic-validated shim over status_helper.derive_status."""
    if not re.match(_RE_SAFE_ID, target_id):
        raise HTTPException(status_code=400, detail="Invalid id parameter")
    return StdlibJSONResponse(derive_status(target_kind, target_id))
```

**Parameter-naming note (Finding #8 of the review phase):** every
existing sibling handler in `routes/api.py` uses domain-specific
names for the resource identifier (`task`, `cwd`, `feature`, `sid`,
`project`) — none uses bare `id`, which shadows Python's built-in
`id()` function. The handler above follows that convention by
declaring the Python parameter as `target_id` and using FastAPI's
`Query(alias="id", ...)` to map it to the public URL parameter
`id=<id>`. The URL contract specified by the execution-plan task
spec (`?id=<id>`) is unchanged; only the Python identifier differs.

**Dependencies (abstractions)**:

- `dashboard.server.status_helper.derive_status` (the only state
  derivation surface — R5 forbids any other reader).
- `dashboard.server.status_helper.TARGET_KINDS` (imported solely so
  TC-CROSS in the test module can compare against
  `typing.get_args(_TargetKind)` — R12).
- `dashboard.server._responses.StdlibJSONResponse` (already imported
  at `routes/api.py:72`).
- `dashboard.server._serve_legacy._RE_SAFE_ID` (already imported at
  `routes/api.py:82`).
- `fastapi.HTTPException`, `fastapi.Query` (already imported at
  `routes/api.py:59`).
- `re` (already imported at `routes/api.py:54`).
- `typing.Literal` (NEW import, single line).

**Dependents**: None at this layer. The Phase 2 `control-endpoints`
task and Phase 3 Watchfloor UI consume the route over HTTP, not via
Python import.

**Orchestration**: The handler is auto-registered when `app.py:219`
calls `from dashboard.server.routes.api import router as
_api_router` followed by `target_app.include_router(_api_router)`
(`app.py:263` per REQUIREMENTS R2). No `app.py` edit. No new
`include_router` call. No middleware change. No exception-handler
change.

**LOC budget**: ≤ 35 lines added to `routes/api.py` (3 import lines
+ 1 alias + 1 blank + decorator + 4-line signature + 3-line body +
docstring). REQUIREMENTS R15 ratifies ≤ 35.

### C2 — `dashboard/tests/test_status_endpoint.py`

**File path**: `dashboard/tests/test_status_endpoint.py` (create)

**Responsibility (one sentence)**: Exercise the handler end-to-end
through `fastapi.testclient.TestClient` against a fresh FastAPI app
that registers the C2 exception handlers + C1 router, asserting the
200 / 400 / 405 / response-shape / latency / cross-check
behaviours. Test scenarios are enumerated in TESTPLAN.md
(generated in Phase 3).

**Surface**: pytest module with one `client` fixture that mirrors
`test_routes_api.py:31-39`'s pattern — a fresh `FastAPI()` with
`router` included and the `_validation_error_to_400` +
`html_4xx_handler` exception handlers installed (so byte-equivalent
4xx body assertions work).

**Dependencies (abstractions)**:

- `fastapi.testclient.TestClient` — drives requests.
- `dashboard.server.routes.api.router` — handler under test.
- `dashboard.server.routes.api._TargetKind` — for TC-CROSS.
- `dashboard.server.routes.api.derive_status` — patched to a
  `MagicMock` for AS11 (call-count + args assertion) and to raise
  for AS2's "helper not called" assertion.
- `dashboard.server.status_helper` (the live module) — the latency
  smoke test calls the un-patched helper through the route.
- `dashboard.server.app._validation_error_to_400` — registered on
  the test app so the 400-on-Literal-mismatch path matches
  production.
- `dashboard.server._exception_handlers.html_4xx_handler` — same
  rationale.
- `tmp_path`, `monkeypatch` pytest fixtures.

**Dependents**: `dashboard/tests/run-all.sh` invokes the file via
the project pytest invocation; the gate
(`execution-plan.yaml:2932-2937`) selects
`test_paused_session_response_shape` from this module.

**Orchestration**:

- One module-level autouse fixture resets
  `status_helper._STATE_CACHE` per test (mirrors
  `test_status_helper.py:35-39`).
- One `client` fixture builds the FastAPI app per test (cheap;
  mirrors `test_routes_api.py:31-39`).
- One `client_html` fixture variant adds `html_4xx_handler` for the
  byte-equivalent 4xx assertions.
- One session-scoped `large_stream` fixture builds the 40 MB
  fixture once for AS4 (TESTPLAN R-TEST-G).

**LOC budget**: ≤ 350 lines (REQUIREMENTS R15). Twelve test
categories AS1-AS15 + TC-CROSS at ~25 LOC each including
fixture/setup gives ~330 expected.

### C3 — `CLAUDE.md` `## Dashboard Subtree` `### Layout` bullet

**File path**: `CLAUDE.md` (modify)

**Responsibility (one sentence)**: Add one bullet under the
existing `### Layout` section, immediately after the
`status_helper.py` bullet and before the `lifecycle-emit.sh`
bullet (the same spot REQUIREMENTS R-OUT-2 picked).

**Surface**:

```
- `dashboard/server/routes/api.py` registers GET
  `/api/{target_kind}/status` — Pydantic-validated thin shim over
  `status_helper.derive_status`. No state derivation in the route;
  helper is the single source of truth (R5 of
  REQUIREMENTS_session-status-endpoint).
```

**Dependencies / Dependents / Orchestration**: Documentation only.
No runtime effect. The bullet is searchable by future agents
orienting in `CLAUDE.md`.

**LOC budget**: ≤ 5 lines added.

## Data Flow

```
HTTP GET /api/<kind>/status?id=<id>
  │
  ▼
FastAPI router (path matching: /api/{target_kind}/status)
  │
  ▼
Pydantic Literal coercion of `target_kind` against {autopilot, chain}
  │ (failure → RequestValidationError → _validation_error_to_400 → HTTP 400 + {"detail":[...]} )
  ▼
FastAPI Query parsing of `id` (alias for handler param `target_id`,
  min_length=1, max_length=64)
  │ (failure → same RequestValidationError → HTTP 400 + {"detail":[...]} )
  ▼
api_session_status(target_kind, target_id) handler body
  │
  ├── re.match(_RE_SAFE_ID, target_id)
  │     │
  │     └── no-match → HTTPException(400, "Invalid id parameter")
  │                      → StarletteHTTPException → html_4xx_handler → stdlib HTML 4xx body
  │
  ▼
status_helper.derive_status(target_kind, target_id)
  │ (validates inputs again — should never fire because R3/R4 pre-rejected the same set)
  │ resolves stream path under PROJECTS_ROOT
  │ reads only newly-appended bytes (per-target byte-offset cache)
  │ returns SessionStatus TypedDict
  │
  ▼
StdlibJSONResponse(SessionStatus)
  │ json.dumps(dict) with default separators, ensure_ascii=True
  │ Content-Type: application/json; charset=utf-8
  │ Cache-Control: no-store
  │
  ▼
HTTP 200 + body bytes
```

**Per-request side effects**:
- Read-only on disk (helper opens stream, no writes).
- Mutates `status_helper._STATE_CACHE[(target_kind, target_id)]`
  in-process (single-thread safe — see R-CON-2).
- No cookie set, no `Set-Cookie` header, no extra response headers.
- One access-log entry via `dashboard.server.app.AccessLogMiddleware`
  (same as every other route).

**Cross-cutting middleware path** (per REQUIREMENTS R10 / AS6):
```
request → OriginMiddleware → CSRFMiddleware → AccessLogMiddleware → router → handler
```
For GET, `OriginMiddleware` and `CSRFMiddleware` are no-ops
(method-gated to unsafe methods). The handler always runs;
`AccessLogMiddleware` always logs.

## SOLID Results

### Single Responsibility — PASS

The handler does exactly four things in fixed order: (1) Pydantic
validates the request shape, (2) regex validates `id`, (3) helper
derives state, (4) response wraps. No business logic, no caching,
no error mapping beyond the one regex 400. State derivation is
fully delegated to the helper (REQUIREMENTS R5). Response
serialization is fully delegated to `StdlibJSONResponse`.

The test module's responsibility is bounded to "exercise this one
handler"; cross-cutting concerns (middleware, JSON byte format) are
exercised by their own dedicated test modules.

### Open / Closed — PASS

Adding a third `target_kind` (e.g., `grinder`) requires editing
`status_helper.TARGET_KINDS` AND this route's `_TargetKind` Literal
in lockstep. TC-CROSS (R12) is the lockstep enforcer — it fails the
build if one is updated without the other. The Literal is the only
extension seam this route exposes; everything else (response shape,
status code, error message) is fixed by the helper or by the global
exception handlers.

### Liskov — N/A (no inheritance in this module)

`StdlibJSONResponse` extends `starlette.responses.Response` — that
contract is owned by `_responses.py` and verified by
`test_response_compat.py`. This task does not subclass anything.

### Interface Segregation — PASS

The route depends on `derive_status` (one function) and
`TARGET_KINDS` (one tuple). It does NOT import the helper's
`_apply_line`, `_resolve_stream_path`, `_state_to_dict`, or
`_STATE_CACHE` — those are private. The minimal-surface dependency
keeps the route insulated from helper-internal refactors.

### Dependency Inversion — PASS

The route depends on the helper module's public surface (a stable
function signature defined by `SessionStatus`), not on stream-path
resolution, JSON parsing, or NDJSON layout. A future helper rewrite
that swaps NDJSON for a SQLite cache changes nothing in this
route. The route does NOT import `lifecycle_events.parse_event`
directly — that is a helper-internal abstraction (REQUIREMENTS R5).

## Agent Navigability

### Module / function names are self-describing — PASS

- `api_session_status` — `api_<resource>[_<action>]` matches every
  sibling handler (`api_flow_status`, `api_autopilots`,
  `api_autopilot_log`, …). A future agent grepping for `api_*` in
  `routes/api.py` discovers this handler immediately.
- `_TargetKind` — leading underscore signals "module-private";
  trailing `Kind` matches the helper's `TARGET_KINDS` vocabulary.
- The test module name `test_status_endpoint.py` mirrors the
  pattern set by `test_status_helper.py` (one helper module → one
  endpoint test module).

### Interfaces are explicit (Protocol/ABC, typed dataclasses) — PASS

- Handler signature is fully type-annotated: `target_kind:
  _TargetKind, target_id: str` (the `target_id` Python identifier is
  aliased to the URL parameter `id` via FastAPI's `Query(alias="id")`)
  and the return is `StdlibJSONResponse`. mypy validates.
- `_TargetKind` is a typed alias (Literal). `typing.get_args` works
  for TC-CROSS.
- The helper's `SessionStatus` TypedDict declares the response shape
  contract — no `dict[str, Any]` fall-through.

### Structured logging on error paths — PASS

- The handler does NOT log per-request. Per-request access logging
  is owned by `AccessLogMiddleware` (`app.py:_AccessLogMiddleware`).
- Helper-level WARNINGs (corrupt JSON line, OSError on stat) emit
  via the existing `dashboard.server.status_helper` logger.
- Unexpected exceptions (helper-raised `ValueError` despite R3/R4
  pre-rejection — R-CON-2 says this branch is unreachable) fall
  through to `html_500_handler` (already registered in `app.py`).
- 400 errors emit no log line at the route level. The
  AccessLogMiddleware records the 400 at the access-log layer with
  `status=400, duration_ms=…`.

### CLAUDE.md update — REQUIRED (C3 covers this)

The new route is a new public HTTP surface visible to UI and Phase
2 consumers. CLAUDE.md `## Dashboard Subtree` § Layout is the
agent-orientation index for `dashboard/server/`. Adding a one-line
bullet (C3) keeps the index complete. Wording matches the
predecessor `status_helper.py` bullet's style (one line, what the
module does + the contract reference).

## TDD Assessment

Every component can be tested in isolation.

- **C1 handler** is exercised through `fastapi.testclient.TestClient`
  against a freshly composed `FastAPI()` app (no SPA mount, no
  `app.py` import). The router is the unit under test. State is
  injected via `monkeypatch` against
  `status_helper._PROJECTS_ROOT` (mirrors `test_status_helper.py`'s
  `patched_root` fixture).

- **The regex 400 branch** is testable without any helper interaction
  by passing `id="bad id"` and asserting (a) status 400, (b) body
  matches the stdlib HTML 4xx template, (c) `derive_status` was not
  called (assert `MagicMock.call_count == 0`).

- **The Literal 400 branch** is testable by issuing GET
  `/api/frobnicate/status?id=feat-x` against the same client and
  asserting status 400 + body shape `{"detail": [...]}` (the
  `_validation_error_to_400` shape).

- **The helper success path** is testable in two modes:
  1. Unit (faster): patch `derive_status` on the route module to a
     stub returning a fixed dict; assert the route wraps it
     verbatim. This is AS11 + AS12.
  2. Integration: call the live helper through the route with a
     `tmp_path` stream fixture (AS1, AS5, AS8, AS9, AS13).

- **The 40MB latency smoke** is testable via a session-scoped
  fixture that builds the stream once, then a per-test 100-iter
  poll loop measured by `time.perf_counter()` (AS4).

- **TC-CROSS** (R12) is a pure import-time assertion — no client,
  no fixture: `assert typing.get_args(_TargetKind) ==
  status_helper.TARGET_KINDS`.

No abstraction is missing. The helper already exposes a pure-stdlib,
side-effect-free public surface (verified by predecessor task QA).
The route's only `re.match` is against a constant; the only
`HTTPException` is the regex 400. Every branch of the handler is
covered by the test plan that Phase 3 (`/plan --step testplan`)
will produce.

## Config Changes

**None.** The route reads no `config/settings.yaml` keys. The
helper reads `PROJECTS_ROOT` from the environment at import time
(`status_helper.py:39`); the route does not touch the env var
directly. No new env var, no new setting key, no new feature flag.

The `pipeline.yaml` stream-extension rules already cover
`autopilot-stream.ndjson` and `chain-events.ndjson` — no manifest
edit needed.

## Risks

### Risk-1 — Helper's `_STATE_CACHE` leaks across tests (HIGH likelihood, LOW impact)

The helper's per-process cache survives across pytest test cases by
default. Without the autouse `_reset_cache_autouse` fixture,
test ordering can mask bugs (a "missing stream" test that runs after
a "populated stream" test still sees the populated state).

**Mitigation**: Mirror `test_status_helper.py:35-39`'s autouse
fixture in `test_status_endpoint.py`. Hard-coded in the test plan;
verified by running each test in isolation via `pytest -k
<name>`.

### Risk-2 — `RequestValidationError` body format is opaque to the test plan (MEDIUM likelihood, LOW impact)

`_validation_error_to_400` produces
`{"detail":[{"type":"literal_error", "loc":["path","target_kind"],
"msg":"Input should be 'autopilot' or 'chain'", "ctx":{...}}]}`.
The exact `msg` string is owned by Pydantic and may shift between
minor Pydantic versions. Pinning the full body in tests would make
the test fragile across Pydantic upgrades.

**Mitigation**: TESTPLAN.md asserts only:
- status_code is 400
- body parses as JSON
- `body["detail"][0]["loc"]` includes `target_kind`
- `body["detail"][0]["type"]` starts with `"literal_"` (covers
  Pydantic v2 naming variants)
- the helper was NOT called (mocked `derive_status.call_count == 0`)

This pins the contract that matters (early rejection, error shape)
without coupling to a Pydantic-version-specific `msg`.

### Risk-3 — 40MB stream fixture is slow on cold cache (MEDIUM likelihood, MEDIUM impact)

Building a 40 MB NDJSON file with ~200k valid events takes seconds
on the dev workstation. Running it per-test would slow the suite
by ~10×.

**Mitigation**: Session-scoped pytest fixture builds the file once
per test session, in `tmp_path_factory`'s session dir. The
warm-cache loop (100 iterations) measures only the per-iter wall
time, not fixture build time. Cold-cache build cost is amortized
across all 100 iterations (and across any other test that reuses
the fixture).

### Risk-4 — Field-order test fragility (LOW likelihood, LOW impact)

AS12 asserts `list(json.loads(body).keys()) == ["status",
"phase_at_pause", "last_phase_complete", "started_at",
"tmux_session"]`. This depends on (a) Python dict insertion order
preservation (guaranteed since 3.7), (b) `TypedDict` constructor
preserving kwarg order (guaranteed by CPython since 3.7), and (c)
`StdlibJSONResponse.render` calling `json.dumps` with default
sort_keys=False (verified at `_responses.py:39`).

**Mitigation**: All three guarantees are stable Python contracts.
The test will fail loudly if any of them changes — which is the
desired signal because the Phase 3 Watchfloor UI byte-diffs
fixtures against ordered keys (per
`test_response_compat.py`'s established convention).

### Risk-5 — Helper raises `ValueError` despite pre-validation (LOW likelihood, MEDIUM impact)

R-CON-2 asserts the helper's input-validation set equals the
route's pre-rejection set. If a future helper change widens the
helper's rejected set (e.g., rejects single-char `id`) without the
route widening its `_RE_SAFE_ID`, the helper raises mid-handler.
The handler has no try/except — the exception propagates to
`html_500_handler` and the user sees a 500.

**Mitigation**: TC-CROSS already pins `target_kind`. For `id`,
the route's two-layer validation (FastAPI `Query(min_length=1,
max_length=64)` + handler `re.match(_RE_SAFE_ID, target_id)`)
collectively accepts the same set the helper's `_TARGET_PATTERN`
accepts — even though the regex *strings* differ (F6:
`_RE_SAFE_ID = r"^[a-zA-Z0-9_-]+$"` has no length cap;
`_TARGET_PATTERN = r"^[a-zA-Z0-9_-]{1,64}$"` does). A behavioral
drift detector therefore cannot use a string-equality assertion;
TESTPLAN.md T5.2 instead asserts that (a) the character class in
`_RE_SAFE_ID` matches the character class in `_TARGET_PATTERN.pattern`
via parameterized boundary inputs (length-1, length-64,
length-65, leading/trailing `-`/`_`, mixed alphanumerics, plus one
rejected character class member) and (b) `Query(max_length=64)` is
declared at the route surface (introspect via `router.routes[-1]`).
Together these prevent the 500-on-validation-mismatch surprise that
Risk-5 describes. Adding this set of assertions costs ~15 lines and
is in the LOC budget.

### Risk-6 — Two intentional divergences from REQUIREMENTS.md must be reconciled

REQUIREMENTS R-RECONCILE flagged two open positions:

1. **Response field echoes** (`target_kind`, `target_id`): the plan
   AC#1 lists them; REQUIREMENTS R6 omits them. The architect
   **adopts the omit position**: the helper's `SessionStatus` is
   the contract; adding wrapper fields breaks the helper-as-source-
   of-truth pattern (R-CON-3). The Watchfloor UI already knows
   `target_kind` and `id` — it sent them in the URL. Echoing wastes
   bytes.

2. **Status code on bad `target_kind`**: REQUIREMENTS R3 / AS3 say
   422; F1 establishes the actual behaviour is 400 due to the
   global `_validation_error_to_400` handler. The architect
   **adopts 400** because (a) it matches the production app
   behaviour without any code change, (b) it satisfies plan AC#2
   ("400 with structured error body") verbatim, (c) every other
   sibling endpoint that hits the same handler also returns 400.
   AS3 in TESTPLAN.md will assert 400.

Both reconciliations are **closed** by this plan. They are NOT
deferred. The implementation phase implements 400 + no-echo as
specified here.

### Risk-7 — `routes/api.py` LOC creep risks the file becoming a god-object (LOW likelihood, MEDIUM impact)

`routes/api.py` is already 616 lines with 22 handlers. Adding a
23rd handler is fine; the file is still navigable by section
comments (`# T0.2.b — autopilot family read endpoints`, etc.).

**Mitigation**: This task does NOT split the file. A future task
(tracked in the host plan's `deferred[]` if needed; not added by
this task) may extract `routes/api.py` into per-resource sub-modules
if 30+ handlers accumulate. For now, one handler per cohort plus
the existing section comments is sufficient.

## Open Questions

**None.** REQUIREMENTS R-RECONCILE positions are closed by Risk-6.
Component placement is fixed (one handler in `routes/api.py`, one
test module, one CLAUDE.md bullet). No new dependencies. No new
config. No middleware change. Auto-router-registration via the
existing `include_router` covers the wiring.

## CLAUDE.md / ARCHITECTURE.md update flag

**Yes — CLAUDE.md update required.** C3 captures the one-line bullet
under `## Dashboard Subtree` → `### Layout`. No `ARCHITECTURE.md`
exists in this repo (the equivalent role is split between
`CLAUDE.md` and per-file docstrings) so no other doc edit is
needed.

## File-by-file impact summary

| File | Verb | Lines added | Lines removed | Notes |
|---|---|---|---|---|
| `dashboard/server/routes/api.py` | modify | ~33 | 0 | C1 handler + alias + 2 imports |
| `dashboard/tests/test_status_endpoint.py` | create | ≤ 350 | 0 | C2 test module (TESTPLAN drives count) |
| `CLAUDE.md` | modify | ~5 | 0 | C3 bullet under § Layout |
| `dashboard/server/status_helper.py` | UNTOUCHED | 0 | 0 | R-OUT-1 — verified by `git diff` |
| `dashboard/server/app.py` | UNTOUCHED | 0 | 0 | R2 — verified by `git diff` |
| `dashboard/server/schemas.py` | UNTOUCHED | 0 | 0 | R3 — `_TargetKind` lives inline in `routes/api.py` |
| every other file | UNTOUCHED | 0 | 0 | REQUIREMENTS § Out-of-scope |

Total lines added: ~388 (well under the helper's predecessor task
budget of 218 + 530 = 748; this task's `lines_estimate: 95` in the
host plan applies to production code only — the test module is
out-of-budget per project convention since `lines_estimate` excludes
tests at the team-planning step).
