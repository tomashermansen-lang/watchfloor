<!-- phase: ba | date: 2026-05-14 | branch: feature/session-status-endpoint -->

# REQUIREMENTS — `GET /api/{target_kind}/status` FastAPI endpoint consuming `status_helper.derive_status`

## Feature Summary

Ship the HTTP surface for the lifecycle-derived session status feature.
A new `GET /api/{target_kind}/status?id=<target_id>` route lands in
`dashboard/server/routes/api.py` that:

- accepts `target_kind` as a **path parameter** restricted to the
  enum `{autopilot, chain}` (Pydantic Literal),
- accepts `id` as a **query parameter** validated against
  `^[a-zA-Z0-9_-]{1,64}$` (the project-wide `FeatureId` regex),
- delegates ALL state derivation to
  `dashboard.server.status_helper.derive_status(target_kind, target_id)`
  — the predecessor task (`session-status-helper`, merged
  2026-05-14, commit `9d872f1`) that already ships exhaustive unit
  tests for the underlying state machine,
- returns the helper's five-field `SessionStatus` dict as the
  response body using the existing `StdlibJSONResponse` class so
  body bytes stay byte-equivalent with the stdlib JSON conventions
  used by every other read route in this module,
- returns HTTP 400 with the byte-equivalent stdlib HTML error body
  before any I/O on malformed `id` or `target_kind`,
- delivers ≤200ms per-request latency under repeated polling
  against a 40MB autopilot stream — leaning on the helper's
  byte-offset incremental-read cache for the warm path.

Ship a new pytest module at `dashboard/tests/test_status_endpoint.py`
covering the four plan acceptance criteria
(`execution-plan.yaml:2870-2887`), the validation order
(`target_kind` Pydantic enum rejection → `id` regex rejection →
helper invocation → response), the response-shape contract that
Phase 2 control endpoints and Phase 3 Watchfloor UI consume, and
the 40MB warm-poll latency smoke test.

This task ships **NO changes** to the helper module
(`dashboard/server/status_helper.py` is frozen — see R-OUT-1), **NO
new helper modules**, **NO modifications** to existing routes /
schemas / middleware / app skeleton, and **NO bash changes**. The
only files touched by this task are:

1. `dashboard/server/routes/api.py` — one new `@router.get` handler
   plus, where needed for minimal request validation symmetry with
   other routes, a Pydantic enum import (existing
   `dashboard.server.schemas` already declares `FeatureId` — reused
   verbatim, no schema file edits).
2. `dashboard/tests/test_status_endpoint.py` — new test module.
3. `CLAUDE.md` (one-line bullet under
   `## Dashboard Subtree` § "FastAPI APIRouter modules") — the
   running file-by-file orientation note for future agents,
   matching the pattern set by predecessor `status_helper.py` and
   `resume_helper.py` entries already in CLAUDE.md.

## Research Findings

### Predecessor task: `session-status-helper` (DONE, merged 2026-05-14)

- Production module: `dashboard/server/status_helper.py` (218 LOC,
  per `git diff` against the pre-merge baseline).
- Public surface this task consumes:
  - `derive_status(target_kind: str, target_id: str) -> SessionStatus` —
    the single function the endpoint calls. Synchronous, pure-stdlib,
    side-effect-free except for the module-level
    `_STATE_CACHE` byte-offset cache. Raises `ValueError` on bad
    `target_kind` or `target_id` BEFORE any I/O
    (`status_helper.py:75-79`).
  - `SessionStatus` — a `TypedDict` with five fields in this exact
    order: `status`, `phase_at_pause`, `last_phase_complete`,
    `started_at`, `tmux_session` (`status_helper.py:42-47`).
  - `STATUS_VALUES = ("idle", "running", "paused", "cancelled",
    "completed", "failed")` — six-value enum (R7 of the helper's
    REQUIREMENTS.md). Today the helper reaches four
    (`idle | running | paused | cancelled`); `completed` and
    `failed` are reserved for forward-compat. The endpoint surfaces
    whatever value the helper returns without normalization.
  - `TARGET_KINDS = ("autopilot", "chain")` —
    `status_helper.py:36` — used to keep this task's Pydantic
    Literal in sync with the helper's accepted set. The
    endpoint's path-parameter Literal MUST be identical or the
    response shape can disagree across a future enum extension.
- Public **invariant** verified by the helper's QA report: no
  FastAPI / Pydantic / Starlette imports anywhere in the module
  (R1 of helper REQUIREMENTS, tested by `test_inv1`).
  Consequence: the helper is import-safe inside any FastAPI route
  module without leaking ASGI surface back into stdlib code.
- Public **observable behaviour** the endpoint relies on:
  - missing stream file → returns the idle default (status=idle,
    all other fields None) WITHOUT raising — covered by helper AS8.
  - corrupt stream lines → silently skipped, helper logs WARNING,
    no exception escapes — covered by helper AS7.
  - second poll on unchanged stream → O(1) stat-only fast path
    returns cached state — covered by helper AS10.

### Sibling reads in `dashboard/server/routes/api.py`

Every read endpoint in `routes/api.py` follows one fixed shape:

1. Path/query parameters declared as `fastapi.Query(...)` or
   path parameters in the decorator string.
2. Validation order: presence (`is None`) → regex
   (`re.match(_RE_SAFE_ID, ...)`) → enum membership where
   applicable → helper call.
3. 400 raised via `fastapi.HTTPException(status_code=400,
   detail=<verbatim string from `_serve_legacy`>)` — the global
   `html_4xx_handler` registered in `app.py` then formats the
   body bytes to match stdlib `BaseHTTPRequestHandler.send_error`.
4. Helper return value wrapped in
   `dashboard.server._responses.StdlibJSONResponse` so body bytes
   come from `json.dumps(content)` with default separators and
   `ensure_ascii=True`.
5. No try/except around the helper call — helper-raised
   `Exception` propagates to `html_500_handler` (also registered
   in `app.py`).

This task follows that shape verbatim — see R3 / R4 / R5 / R6.

### Path parameter shape decision (DN-implicit)

The task spec (`execution-plan.yaml:2847`) describes the route as
`GET /api/{target_kind}/status?id=<id>` — `target_kind` is a
**path** parameter, `id` is a **query** parameter. This matches
the route layout the Phase 2 control endpoints will adopt
(`control-endpoints` plan task lists POST
`/api/{target_kind}/start`, `/api/{target_kind}/pause`, etc.) so
the URL family stays uniform: one path segment names the kind,
one query string names the instance. The endpoint declared in
this task MUST use this exact path shape (R3) — diverging would
require Phase 2 to either re-template every control route or
abandon URL uniformity.

### Schema reuse

- `FeatureId` already exists at
  `dashboard/server/schemas.py:20-27` — the Pydantic `Annotated[str,
  StringConstraints(pattern=r"^[a-zA-Z0-9_-]{1,64}$",
  min_length=1, max_length=64)]` exactly matches the regex the
  helper enforces (`status_helper.py:38`). The endpoint MUST
  reuse this symbol — re-declaring it inline would create a
  third copy (helper, schemas.py, this route) that can drift.
  Reused via `from dashboard.server.schemas import FeatureId`.
- A `target_kind` Literal does NOT yet exist in
  `dashboard.server.schemas`. The endpoint declares a
  `TargetKind = Literal["autopilot", "chain"]` alias **inline at
  the top of `routes/api.py`** (NOT in `schemas.py`) because (a)
  the helper's `TARGET_KINDS` tuple is the source of truth, (b)
  no other module needs the type today, (c) adding it to
  `schemas.py` would mean editing a second file — R20 of the
  helper's REQUIREMENTS forbade that pattern for the helper and
  we mirror the discipline here. If Phase 2 also needs the type
  (it will, in `control-endpoints`), Phase 2 will lift the alias
  into `schemas.py`; this task does NOT pre-lift it.
- Verification: tests assert that the inline Literal's values
  equal `status_helper.TARGET_KINDS` exactly (R12 below).

### Response body shape

The helper returns a `TypedDict` with five fields. FastAPI's
default `JSONResponse` (and via subclass `StdlibJSONResponse`)
serializes a `TypedDict` as a JSON object identical to a `dict`.
Field order in the serialized output is dictated by Python dict
insertion order, which for `TypedDict(...)` is the order the
fields are declared in the class body:
`status, phase_at_pause, last_phase_complete, started_at,
tmux_session`. The response JSON MUST preserve that order —
the Phase 3 Watchfloor UI fixture diffs against ordered keys
(per the project's convention of byte-equivalent fixtures,
established in `test_response_compat.py`).

### CSRF / Origin / authentication boundary

- The endpoint is a **GET** — CSRF middleware
  (`dashboard.server.middleware.csrf.CSRFMiddleware`) only acts on
  unsafe methods (`POST/PUT/PATCH/DELETE`), per the existing
  `_UNSAFE_METHODS` set in `csrf.py`. No CSRF token required.
- The Origin allowlist middleware
  (`dashboard.server.middleware.origin_check.OriginMiddleware`)
  ALSO only acts on unsafe methods + WebSocket upgrades. GET
  requests pass through unconditionally. This matches the
  cross-cutting constraint
  `Read-only endpoint — no CSRF needed; Origin allowlist still
  applies` (`execution-plan.yaml:2891`) — "still applies"
  meaning the middleware is in the request pipeline, not that
  it gates the request. Tests confirm by issuing a GET with no
  Origin header and asserting 200 (R10 below).
- There is no authentication on the dashboard backend — it
  binds to `127.0.0.1` only (see CLAUDE.md § Security Rules).

### Performance budget

- Plan AC#3 (`execution-plan.yaml:2878-2881`): "latency shall
  remain under 200ms via the helper's incremental-read cache
  (smoke test asserts this against a 40MB stream fixture)".
- Decomposition of the budget:
  - cold-cache first poll on a 40MB stream: NOT in the budget —
    the helper's `_STATE_CACHE` is empty so it reads 40MB.
  - warm-cache subsequent poll, file unchanged: ≤200ms is
    extremely generous; the helper's R9 step 5 returns from the
    cache without opening the file. Expected wall time: <1ms.
  - warm-cache poll, file grew by ≤256 bytes (one appended
    event): the helper reads only the new bytes. Expected wall
    time: <5ms.
- The smoke test in R-TEST-G measures the warm-cache scenario;
  the cold-cache cost is amortized once at dashboard startup and
  not part of the per-poll budget.

### CLAUDE.md update precedent

The predecessor task `session-status-helper` added the bullet
`dashboard/server/status_helper.py — pure-stdlib lifecycle-state
helper. Public: derive_status(target_kind, target_id) -> SessionStatus.
...` under `### Layout` of `## Dashboard Subtree` (see CLAUDE.md
~line 145). This task adds a sibling entry for the route — see
R-OUT-2 / R-DOC-1 below for the exact text.

### Out-of-scope confirmations (negative scope)

Per the plan task spec (`execution-plan.yaml:2855-2863`) and the
ancestor predecessor task's R20 (frozen modules), this task does
NOT:

- modify `dashboard/server/status_helper.py`, `app.py`,
  `schemas.py`, `_serve_legacy.py`, `lifecycle_events.py`,
  `autopilot_helpers.py`, `chain_events.py`,
  `_responses.py`, `_exception_handlers.py`, any middleware module,
  or any other file under `dashboard/server/` except
  `routes/api.py`;
- modify any bash file under `adapters/claude-code/`;
- modify `dashboard/serve.py` (the legacy stdlib server) — that
  module is in tombstoning state per the predecessor's REVIEW.md;
- ship a chain-side or autopilot-side new helper — the helper
  layer is already complete.

## Requirements

All requirements use EARS notation. Each is testable and
self-contained.

### R1 — Endpoint location and decoration

The system shall declare exactly one new route handler inside the
existing module `dashboard/server/routes/api.py`. The handler
shall:

- be decorated with
  `@router.get("/api/{target_kind}/status")` (path parameter
  syntax), where `router` is the module-level `APIRouter`
  instance already declared at `routes/api.py:133`;
- be an `async def` function whose name shall be
  `api_session_status` (matches the
  `api_<resource>[_<action>]` naming of every sibling handler in
  this module: `api_flow_status`, `api_autopilots`,
  `api_autopilot_log`, etc.);
- accept the path parameter `target_kind` typed as the inline
  Pydantic Literal `Literal["autopilot", "chain"]` (R3);
- accept the query parameter `id` typed as
  `str = fastapi.Query(...)`  with `min_length=1` and
  `max_length=64` so FastAPI's automatic 422 response covers the
  totally-absent case before the handler body runs;
- return `StdlibJSONResponse` (the module-level alias already
  imported from `dashboard.server._responses`).

The system shall NOT add any new top-level decorators, exception
handlers, middleware, dependencies, or background tasks in this
task.

### R2 — Router registration is automatic

The system shall NOT modify `dashboard/server/app.py`. The
existing `target_app.include_router(_api_router)` call at
`app.py:263` already mounts `routes/api.py:router` into the
FastAPI app; the new handler is reachable as soon as
`routes/api.py` defines it. Verification:
`git diff main...HEAD --stat` lists `dashboard/server/app.py`
with zero added/deleted lines (or omits it entirely).

### R3 — `target_kind` path parameter is a strict 2-value Literal

The system shall declare a module-level type alias at the top of
`routes/api.py` (after the existing imports, before the
`router = APIRouter()` line, NOT inside the handler body):

```python
from typing import Literal

# Mirror of status_helper.TARGET_KINDS; lifted to schemas.py if
# Phase 2 control-endpoints needs it.
_TargetKind = Literal["autopilot", "chain"]
```

The handler signature shall annotate `target_kind` as
`_TargetKind`. FastAPI shall therefore return 422 (its default
RequestValidationError shape) for any other value, BEFORE the
handler body runs. The endpoint shall NOT additionally validate
`target_kind` inside the handler body — duplicate validation is
forbidden by R-CON-1.

Tests shall pin the alias's values against
`status_helper.TARGET_KINDS` so a future helper-side enum
extension forces this route to be updated rather than silently
drift (R12, TC-CROSS).

### R4 — `id` query parameter validation

The system shall validate `id` against
`^[a-zA-Z0-9_-]{1,64}$` BEFORE any I/O. Implementation choice:

- The handler shall `re.match(_RE_SAFE_ID, id)` (the constant
  already re-exported from `dashboard.server._serve_legacy`) and
  raise `fastapi.HTTPException(status_code=400, detail="Invalid
  id parameter")` if the regex does not match.
- The handler shall NOT separately check `id is None` — the
  `min_length=1` on the `Query(...)` declaration combined with
  the regex match already covers the empty case; FastAPI's 422
  covers totally-absent.

The error string `"Invalid id parameter"` is new (no
predecessor) and is captured in R6 (canonical error strings) so
later tests pin against it.

### R5 — Single helper call, no inline state derivation

The system shall invoke
`status_helper.derive_status(target_kind, id)` exactly once per
request, after R3 + R4 validation succeeds. The handler shall NOT:

- import `lifecycle_events.parse_event` directly;
- import or use `read_stream_incremental`,
  `_resolve_stream_path`, `_status_from_stream`, or any other
  legacy stream reader;
- inline-construct a path under `docs/INPROGRESS_*` or
  `docs/DONE_*`;
- read NDJSON, `json.loads` lines, or maintain its own offset
  cache.

This is the codified version of the plan constraint "All state
derivation goes through status_helper.derive_status — no inline
NDJSON parsing in the route module" (`execution-plan.yaml:2889`).

### R6 — Response body shape and content type

When R3 + R4 pass and the helper returns successfully, the
system shall:

- Return HTTP 200 with `Content-Type: application/json;
  charset=utf-8` (the `StdlibJSONResponse.media_type`).
- Set `Cache-Control: no-store` (inherited from
  `StdlibJSONResponse.__init__`).
- Render the response body as
  `json.dumps(<helper return value>)` byte-for-byte. The five
  fields shall appear in this exact order:

  ```json
  {"status":"...","phase_at_pause":...,"last_phase_complete":...,"started_at":...,"tmux_session":...}
  ```

  Each `null` value (when the helper returned `None`) shall
  serialize to the JSON literal `null`; each populated string
  shall serialize as a quoted string. `ensure_ascii=True`
  (default for `json.dumps`) shall not be overridden.

The endpoint shall NOT add wrapper fields (`{"data": …}`,
`{"result": …}`, etc.), shall NOT include `target_kind` /
`target_id` echo fields in the body, and shall NOT add a `ts` /
`generated_at` field. The five-field shape is contract; UI
consumers diff against it directly.

### R7 — 400 / 422 error body bytes via stdlib HTML handler

The system shall raise `fastapi.HTTPException` with
`status_code=400` and a verbatim `detail` string from this set:

- `"Invalid id parameter"` (when R4's regex fails).

The system shall NOT raise 400 for `target_kind` —
`target_kind` rejection is FastAPI's default 422 path
(R3). The 422 response body bytes are governed by FastAPI's own
`RequestValidationError` handler, NOT by `html_4xx_handler`;
the existing app at `app.py` already overrides this
(`app.py:160-200` block: see grep result for "AC2") with a JSON
error body of shape `{"error":"<reason>"}`. The endpoint
inherits that handler unchanged.

The 400 body bytes shall match the existing stdlib HTML 4xx
template registered in `app.py` — same byte-equivalent path
every other 4xx in `routes/api.py` uses today
(`html_4xx_handler` from `_exception_handlers.py`). No new
exception handlers are added by this task.

### R8 — Validation order is load-bearing

The system shall enforce the following ordering, asserted by
test TC-ORDER:

1. **Path parameter `target_kind`** is parsed by FastAPI's
   Literal coercion — bad value raises 422 BEFORE the handler
   body runs.
2. **Query parameter `id`** is parsed by FastAPI's `Query`
   declaration — missing parameter (empty string only counts
   as missing if `min_length=1` rejects it) raises 422 BEFORE
   the handler body runs.
3. **Inside the handler body**:
   a. `re.match(_RE_SAFE_ID, id)` — 400 on no match.
   b. `status_helper.derive_status(target_kind, id)` — the
      helper performs its own input validation but should never
      raise from the route because R3/R4 have already rejected
      the same inputs the helper would reject. If the helper
      somehow raises `ValueError`, that path falls through to
      `html_500_handler` (which is acceptable because R3/R4
      should make this branch unreachable).

This ordering is the same shape every sibling route follows
(see `routes/api.py:272-296` for `api_autopilot_log`'s
`presence → regex → I/O` ordering). Reordering changes which
4xx fires on compound-bad requests and breaks test fixtures.

### R9 — Performance: ≤200ms warm-cache latency on a 40MB stream

When the helper's `_STATE_CACHE` already contains a valid offset
+ derived state for `(target_kind, target_id)` AND the stream
file is at least 40 MB AND has not grown since the previous poll,
the system shall complete the request-response cycle in ≤200 ms
on the developer reference workstation (Apple Silicon, NVMe SSD,
macOS 24.6.0 — matching `pipeline.yaml`'s declared dev
environment). The smoke test in R-TEST-G measures this
end-to-end via FastAPI `TestClient` calling into the live router
(NOT a mocked helper), and shall pass on the same workstation
class.

This requirement is not a hard SLO at runtime — it is an
acceptance gate at test time. Production polling intervals
(currently 2 s in the Watchfloor UI per `app/` source) carry
headroom orders of magnitude beyond the budget.

### R10 — Read-only contract: GET only, no other methods, no body

The system shall accept ONLY the HTTP GET method. POST / PUT /
PATCH / DELETE / OPTIONS / HEAD on `/api/{target_kind}/status`
shall yield FastAPI's default 405 Method Not Allowed (no custom
405 handler added). The endpoint shall NOT consume a request
body (no Pydantic body model in the handler signature). The
endpoint shall NOT set any cookie, shall NOT set
`Access-Control-Allow-Origin` (CORS is handled centrally; this
route adds no CORS surface), and shall NOT set any header beyond
those `StdlibJSONResponse` declares (Content-Type,
Cache-Control).

The endpoint shall pass through the Origin middleware unchanged
— per the cross-cutting constraint, the Origin allowlist still
applies, but it is a no-op on GET requests. Tests confirm:
a GET with no Origin header succeeds (TC-NO-ORIGIN), a GET with
a disallowed Origin header still succeeds (TC-DIS-ORIGIN) since
Origin enforcement is method-gated. This documents (not
changes) existing middleware behaviour for future readers.

### R11 — Cache-Control header is `no-store`

The system shall set `Cache-Control: no-store` on every
response (200, 400, 422). The 200 case inherits this from
`StdlibJSONResponse.__init__`'s default header merge
(`_responses.py:33`). The 4xx case inherits whatever the global
`html_4xx_handler` sets — verification is part of TC-VALID-400
asserting `Cache-Control` equals `no-store` if the existing
handler emits it, otherwise the test asserts the header is
absent (whichever the handler currently does — the endpoint
adds no `Cache-Control` of its own to 4xx responses).

The rationale: this is a real-time poll endpoint; a proxy or
browser caching a 200 (idle) response would mask a session
transition. The Watchfloor UI polls at 2 s intervals and relies
on cache-bypass.

### R12 — Cross-validation: route Literal matches helper `TARGET_KINDS`

The system shall include one test (TC-CROSS) that asserts the
endpoint's `_TargetKind` Literal's `__args__` exactly equals
`status_helper.TARGET_KINDS`. Concretely:

```python
import typing
from dashboard.server.routes.api import _TargetKind
from server import status_helper

assert typing.get_args(_TargetKind) == status_helper.TARGET_KINDS
```

This pins the URL surface to the helper's truth so the next agent
who extends `TARGET_KINDS` (e.g., to include a third target_kind)
cannot do so without either updating this route or breaking the
test loud-and-early.

### R13 — Logging

The system shall NOT add a new `logging.getLogger(...)` call inside
the endpoint. Helper-level WARNINGs (corrupt JSON lines, OSError
on stream open) already emit via
`dashboard.server.status_helper`'s logger. Access-log entries are
produced by the existing
`dashboard.server.app:_AccessLogMiddleware`; no per-request log
line is required at the route level.

If the endpoint encounters an unexpected exception (e.g., the
helper raises despite R3/R4 pre-validation — should be
unreachable in practice), the global `html_500_handler` already
formats the body. No try/except wraps the helper call in the
handler.

### R14 — No new dependencies

The system shall NOT add any package to `pyproject.toml`. All
needed imports (`fastapi`, `pydantic`, `typing`, `re`) are
already available. `status_helper` is already importable from
`server.status_helper` (the package mapping at
`pyproject.toml:[tool.setuptools] package-dir`).

Import shape inside `routes/api.py`:

```python
# at the top of the existing import block, after the existing imports:
from server.status_helper import derive_status, TARGET_KINDS  # noqa: E402
```

Note `noqa: E402` matches the existing import-after-`sys.path`
pattern used by the other `from dashboard.server.*` imports in
the file (`routes/api.py:72-131`). `TARGET_KINDS` is imported
solely so TC-CROSS's runtime assertion can compare it to
`_TargetKind.__args__`; it is NOT used elsewhere in the route
body.

### R15 — LOC budget

The system shall fit the change budget specified by the plan
task (`execution-plan.yaml:2895`: `lines_estimate: 95`):

- The new handler block in `routes/api.py` (decorator + signature
  + body + the `_TargetKind` alias + the two new imports) shall
  add ≤ 35 lines to the file.
- The new test module
  `dashboard/tests/test_status_endpoint.py` shall be ≤ 350 lines
  (12 test categories TC-A through TC-CROSS, each averaging ~25
  lines inclusive of fixture setup).

If either file exceeds its budget at implementation time, the
architect shall flag the overrun as a deviation in the `plan`
phase rather than silently expand scope.

### R-OUT-1 — No modification of the helper module

The system shall NOT modify `dashboard/server/status_helper.py`.
The helper's six-value enum, three-target-kind whitelist (today
two-value `("autopilot", "chain")`), `derive_status` signature,
and `SessionStatus` shape are all frozen by this task. If the
endpoint needs a new helper field (it does not), this task
escalates rather than amends.

Verification:
`git diff main...HEAD -- dashboard/server/status_helper.py` shall
produce zero output.

### R-OUT-2 — CLAUDE.md `Dashboard Subtree` bullet added

The system shall add one bullet under
`## Dashboard Subtree` → `### Layout` of `CLAUDE.md`, immediately
after the existing `status_helper.py` bullet and before the
`lifecycle-emit.sh` bullet, with this exact text (one line, ~120
chars, wrapped per existing style):

```
- `dashboard/server/routes/api.py` registers GET
  `/api/{target_kind}/status` — a thin Pydantic-validated surface
  over `status_helper.derive_status`. No state derivation in the
  route; helper is the single source of truth (R5 of
  REQUIREMENTS_session-status-endpoint).
```

Wording is illustrative; the test does NOT pin the exact text,
only that one new bullet referencing the route appears in the
`Layout` section. The `/done` phase later moves the
INPROGRESS_Feature_session-status-endpoint folder to
DONE_Feature_session-status-endpoint per project convention.

### R-CON-1 — No duplicate validation

The system shall NOT validate `target_kind` inside the handler
body (Pydantic Literal already does so before entering the
handler). The system shall NOT validate `id` regex via Pydantic
`StringConstraints` AND a duplicate `re.match` — pick one
mechanism per parameter. R3 picks Literal for `target_kind` and
R4 picks `re.match` for `id` because the existing
`routes/api.py:280` pattern (`re.match(_RE_SAFE_ID, task)`) is
the established idiom for the regex-on-query-string case, and
introducing a Pydantic `StringConstraints`-based `id` here would
diverge from twenty-plus sibling endpoints.

### R-CON-2 — Async function, sync helper

The system shall declare the handler `async def`. The helper
(`status_helper.derive_status`) is synchronous and blocking on
file I/O. Because uvicorn's event loop with a single worker
serializes one request at a time per worker on blocking code,
and dashboard runs at one worker (per `start-system` launch
command), this does NOT introduce a contention bug. The helper's
worst-case (cold-cache 40MB read) takes ~50 ms on the reference
workstation, well inside the 200 ms budget at single-worker
serialization.

If a future operator scales the dashboard to multiple workers,
the helper's R23 (single-thread only) flags the seam — adding a
`threading.Lock` around the cache mutation will be the next
task, not this one.

### R-CON-3 — Stable URL surface

The system shall NOT add any other path under
`/api/{target_kind}/status*` (no `/full`, `/extended`, `/raw`,
`/debug` variants). The five-field response is the only contract
this endpoint exposes; UI consumers compose multiple fields, not
multiple routes.

## Acceptance Scenarios

### AS1 — 200 round-trip with each derivable status value (plan AC#1)

- **GIVEN** an autopilot target whose lifecycle stream contains
  a single `started` event (helper derives `status="running"`),
- **WHEN** the client issues
  `GET /api/autopilot/status?id=<id>`,
- **THEN** the response is HTTP 200 with body
  `{"status":"running","phase_at_pause":null,"last_phase_complete":null,"started_at":"<event ts>","tmux_session":null}`
  (exact byte-equivalent JSON),
- **AND** `Content-Type` is `application/json; charset=utf-8`,
- **AND** `Cache-Control` is `no-store`,
- **AND** the response round-trip completes within 200 ms.

The same scenario, parameterized over each of the four
helper-reachable status values
(`idle`, `running`, `paused`, `cancelled`), shall pass — see
TC-A.

### AS2 — 400 on `id` regex mismatch (plan AC#2 partial)

- **GIVEN** an arbitrary `target_kind` in `{autopilot, chain}`,
- **WHEN** the client issues
  `GET /api/autopilot/status?id=bad id with spaces`,
- **THEN** the response is HTTP 400,
- **AND** the response body equals the stdlib HTML 4xx body
  bytes that `html_4xx_handler` emits for `(400, "Invalid id
  parameter")`,
- **AND** the `status_helper.derive_status` function is NOT
  called for this request (verified by patching it to raise and
  asserting no exception escapes).

The byte-equivalent assertion is the same shape every other 4xx
test in `test_routes_api.py` uses (see `client_html` fixture and
the existing `assert response.content == ...` patterns).

### AS3 — 422 on `target_kind` not in enum (plan AC#2 partial)

- **GIVEN** an arbitrary valid `id`,
- **WHEN** the client issues
  `GET /api/frobnicate/status?id=feat-x`,
- **THEN** the response is HTTP 422 (FastAPI's
  RequestValidationError default — `app.py:160-200` overrides
  the body to `{"error":"invalid"}` per the existing
  RequestValidationError exception handler),
- **AND** `status_helper.derive_status` is NOT called.

The body shape is whatever the existing
`RequestValidationError` handler in `app.py` emits — this task
does not modify that handler. TC-INVALID-KIND asserts the
status code (422) and that the helper was not called; body
bytes are NOT pinned because they are external contract owned
by the predecessor task (`fastapi-app-skeleton`).

### AS4 — Warm-cache 200ms latency on a 40MB stream (plan AC#3)

- **GIVEN** a 40 MB autopilot stream fixture containing
  ~200 000 non-lifecycle event lines plus a final `started`
  lifecycle event (constructed once per test session, NOT per
  request — pytest session-scope fixture),
- **AND** the helper has been warmed by one cold-poll
  (`derive_status` called once to populate
  `_STATE_CACHE` with the full-file offset),
- **WHEN** the client issues `GET
  /api/autopilot/status?id=<id>` 100 times in sequence,
- **THEN** every response is HTTP 200 with
  `{"status":"running", …}`,
- **AND** the wall-clock time for any single request shall be
  ≤ 200 ms,
- **AND** the median across 100 requests shall be ≤ 50 ms
  (asserted to catch a quiet regression that still passes
  under 200 ms but spends 100+ ms per call).

### AS5 — Idle target returns idle envelope (plan AC#4)

- **GIVEN** an `id` for which no stream file exists in any
  project root (helper R8 returns the idle default),
- **WHEN** the client issues
  `GET /api/autopilot/status?id=<id>`,
- **THEN** the response is HTTP 200 with body
  `{"status":"idle","phase_at_pause":null,"last_phase_complete":null,"started_at":null,"tmux_session":null}`,
- **AND** the four optional fields all serialize as the JSON
  literal `null` (not the string `"null"`),
- **AND** no WARNING-level log record is emitted from the
  `dashboard.server.status_helper` logger (helper AS1 / AS8
  guarantee silence on missing stream).

### AS6 — Read-only route is unaffected by Origin allowlist on GET (plan AC#5)

- **GIVEN** the route is registered through `app.include_router`
  in `app.py` (R2 — no app changes by this task),
- **AND** the request method is GET,
- **WHEN** the client issues
  `GET /api/autopilot/status?id=<id>` with NO `Origin` header,
- **THEN** the response is HTTP 200 (not 403),
- **AND** the same call with an explicit
  `Origin: http://example.com` header (a disallowed origin)
  ALSO returns HTTP 200 (Origin enforcement is method-gated to
  unsafe methods only — verified once here so a future Origin
  middleware change that broadens enforcement to GET breaks this
  test).

### AS7 — POST yields 405 Method Not Allowed

- **GIVEN** the route registered as `@router.get("/api/{target_kind}/status")`,
- **WHEN** the client issues `POST /api/autopilot/status?id=<id>`,
- **THEN** the response is HTTP 405,
- **AND** `Allow: GET` is in the response headers (FastAPI default).

### AS8 — Helper's `cancelled` and `paused` results surface correctly

- **GIVEN** an autopilot stream whose most-recent valid
  lifecycle event is `paused` (with
  `phase_at_pause="plan"`) preceded by a `started` then a
  `phase_complete phase=ba` event,
- **WHEN** the client issues
  `GET /api/autopilot/status?id=<id>`,
- **THEN** the response body equals
  `{"status":"paused","phase_at_pause":"plan","last_phase_complete":"ba","started_at":"<started event ts>","tmux_session":null}`.
- **AND** an analogous scenario where the most-recent event is
  `cancelled` returns
  `{"status":"cancelled", …}` with `phase_at_pause` cleared per
  helper R24.

### AS9 — `target_kind="chain"` resolves `chain-events.ndjson`

- **GIVEN** a chain plan stream at
  `docs/INPROGRESS_Plan_<id>/chain-events.ndjson` containing one
  valid `started` lifecycle event,
- **WHEN** the client issues
  `GET /api/chain/status?id=<id>`,
- **THEN** the response is HTTP 200 with
  `{"status":"running", …}`,
- **AND** the helper's `_resolve_stream_path` chose the chain
  file (verified indirectly by the same `id` returning idle when
  `target_kind="autopilot"` — TC-KIND-ISOLATION).

### AS10 — `target_kind` Literal mirrors helper `TARGET_KINDS` (R12)

- **GIVEN** the imported `_TargetKind` Literal from
  `dashboard.server.routes.api` and the imported
  `TARGET_KINDS` tuple from `server.status_helper`,
- **WHEN** the test inspects `typing.get_args(_TargetKind)`,
- **THEN** it equals `status_helper.TARGET_KINDS` exactly
  (`("autopilot", "chain")` as of 2026-05-14),
- **AND** any future edit to one without the other fails this
  test before merge.

### AS11 — Helper is invoked exactly once per request

- **GIVEN** a patched
  `dashboard.server.routes.api.derive_status` that records the
  call count,
- **WHEN** the client issues one valid request,
- **THEN** the recorded call count is exactly 1,
- **AND** the recorded args are
  `(target_kind, id)` in that order.

This pins the contract that the route is a thin shim — a future
refactor that introduces caching, retry, or fallback logic at
the route level breaks this test.

### AS12 — Response field order matches `SessionStatus` declaration order

- **GIVEN** any valid request,
- **WHEN** the client receives the JSON body,
- **THEN** parsing the body via
  `json.loads(response.content)` yields a `dict` whose
  `list(d.keys())` is exactly
  `["status", "phase_at_pause", "last_phase_complete", "started_at", "tmux_session"]`.

### AS13 — `id` of length 64 accepted, length 65 rejected

- **GIVEN** `target_kind="autopilot"` and `id` of exactly 64
  characters all in the regex set,
- **WHEN** the client issues the request,
- **THEN** the response is HTTP 200 (helper returns idle, no
  stream for that id).
- **AND** the same request with a 65-character `id` returns
  HTTP 400 (`"Invalid id parameter"`) before any helper call.

### AS14 — Empty `id` rejected by FastAPI before helper call

- **GIVEN** `target_kind="autopilot"`,
- **WHEN** the client issues
  `GET /api/autopilot/status?id=`,
- **THEN** the response is HTTP 422 (`Query` min_length=1
  rejection from the existing
  `RequestValidationError` handler in `app.py`),
- **AND** `derive_status` is NOT called.

### AS15 — Helper-raised exception path is unreachable in practice

- **GIVEN** R3 and R4 reject every input the helper would
  reject (helper raises `ValueError` for the same conditions),
- **WHEN** any input reaches the helper after R3 + R4 pass,
- **THEN** the helper does NOT raise (definition: the helper's
  R3 / R4 validate the same set the endpoint already validated).

This is enforced by code review, not by a runtime test. The
endpoint adds no try/except — if a future helper change widens
its rejection set without the endpoint widening its own, the
500 path fires and is caught by the existing
`html_500_handler`. R-CON-2 captures this design intent.

## Edge Cases

### E1 — `id` is a numeric string

`id=12345` is allowed by the regex `^[a-zA-Z0-9_-]{1,64}$`.
The helper resolves the path
`docs/INPROGRESS_Feature_12345/autopilot-stream.ndjson`. If
absent, helper R8 returns idle. The endpoint returns 200.

### E2 — `id` containing dot, slash, or whitespace

`id=feat.x`, `id=feat/x`, `id=feat x` all fail the regex →
400. No helper invocation.

### E3 — `target_kind=AUTOPILOT` (uppercase)

The Literal `Literal["autopilot", "chain"]` is case-sensitive.
FastAPI's coercion rejects uppercase → 422. No helper
invocation.

### E4 — Concurrent polls for the same `(target_kind, id)`

Uvicorn at one worker serializes blocking work; two concurrent
GETs queue. The helper's R23 (single-thread only) is therefore
not violated. Both polls see consistent state. Production
configuration (one worker) makes this the only supported
deployment shape.

### E5 — Concurrent polls for different ids (different cache entries)

Each `(target_kind, id)` key has its own `_CachedState`. Polls
for different ids are independent. No lock needed.

### E6 — Stream truncated mid-poll (autopilot session restart)

Helper R10 (backward-jump reset) handles this case silently —
the endpoint sees a 200 response with a fresh state (running
for the new session). No special handling at the route.

### E7 — Helper raises `OSError` on `stat` race

Helper R14 returns the cached state on OSError without raising;
the endpoint returns 200 with the stale state. The Watchfloor
UI's poll interval (2 s) recovers on the next call.

### E8 — Disabled or removed `_RE_SAFE_ID` import

If a refactor in `_serve_legacy.py` removes `_RE_SAFE_ID` from
the re-export set, the existing `from dashboard.server._serve_legacy
import (_RE_SAFE_ID, ...)` block in `routes/api.py` breaks at
import time. The test suite fails fast on the import error —
no separate guard needed. This task does NOT add a
`try/except ImportError` around the import.

### E9 — `id` with leading/trailing hyphens or underscores

`id=-feat-`, `id=_feat_` both pass the regex
(`^[a-zA-Z0-9_-]{1,64}$` matches `-` and `_` anywhere). The
helper accepts them. The endpoint returns 200 (idle if no
stream).

### E10 — Response body is invalidated by helper-side enum extension

If a future task extends `STATUS_VALUES` to include
`"recovering"` (hypothetical), the endpoint relays whatever
string the helper returned. UI consumers either know about the
new value (preferred) or rely on exhaustive switching with a
default branch. The endpoint does NOT enumerate-check the
helper's output.

This is intentional: the endpoint is a transparent surface, not
a contract narrower than the helper's. TC-CROSS guards the
`target_kind` direction; the response-value direction is open
on purpose.

### E11 — Browser tab caches the response despite `Cache-Control: no-store`

A misbehaving client can ignore Cache-Control. The endpoint
emits the directive; client compliance is out of scope.

### E12 — `target_kind="chain"` + autopilot-shaped `id`

A `chain` request with an `id` that happens to match an
autopilot feature dir (e.g., both have a feature called
`feat-x`) returns the chain stream's state (or idle if no chain
plan dir for that id). The helper's path resolution is
kind-keyed — see helper R5. The endpoint relays.

### E13 — Trailing slash on URL

`GET /api/autopilot/status/?id=feat-x` — Starlette emits an
HTTP 307 redirect to the canonical no-trailing-slash form
(`Location: /api/autopilot/status?id=feat-x`). The route body
never executes — the framework rewrites the URL. We do not add
a custom handler; the default redirect is acceptable for both
operator and Phase 3 UI consumers. (The original BA prose for
this edge case predicted a 422; the implementation phase
confirmed the actual behaviour is 307 and the QA phase
corrected this entry to match — see `T4.4_trailing_slash_redirects`
in `dashboard/tests/test_status_endpoint.py`.)

### E14 — Pinned client passing legacy query param

If a Phase 3 UI bug passes `task=<id>` instead of `id=<id>`,
FastAPI returns 422 (missing required `id`). The endpoint
emits no friendlier error. The UI bug is the issue, not the
route.

### E15 — `id` value `..` (path traversal attempt)

`id=..` (length 2, all dots) fails the regex (`.` not in
`[a-zA-Z0-9_-]`) → 400. No file system access. No defense in
depth needed at the route — the regex IS the defense.

### E16 — Helper returns an unexpected status value (e.g., synthesized externally)

Per E10: the endpoint relays. The TypedDict declares the
six-value Literal; Python's runtime does NOT enforce
`TypedDict` values. If a future helper bug returns `"foobar"`,
the endpoint still emits it. The fix lives in the helper.

### E17 — Helper module not importable (broken install)

If `from server.status_helper import derive_status` fails at
import time (broken venv, missing module), the whole `routes/api.py`
fails to import → the FastAPI app fails to start → uvicorn
exits with a stack trace. This is the desired loud-failure
mode; no try/except around the import in the route module.

## Open Questions

None. The plan task spec, the predecessor helper's REQUIREMENTS
and QA report (helper's R2, R7, R8, R10, R14, R23, R24, R25),
the existing route conventions in `routes/api.py`, the existing
exception handlers in `_exception_handlers.py`, the existing
middleware contract (CSRF + Origin both method-gated to unsafe
methods + WS), and the existing `StdlibJSONResponse` and
`FeatureId` types together close every degree of freedom the
endpoint needs.

## Eval Cases for `data/evals/`

This task ships an HTTP surface over a deterministic helper. No
LLM-driven prompt is involved; no judgement scoring is needed.
The fifteen acceptance scenarios AS1 through AS15 plus the
seventeen edge cases E1 through E17 provide exhaustive
correctness coverage. No eval-case additions to `data/evals/`
are required.

## Mapping back to plan acceptance criteria

| Plan AC# (`execution-plan.yaml:2870-2887`) | This doc's coverage |
|---|---|
| AC#1 — 200 with `target_kind, target_id, status, phase_at_pause, last_phase_complete, started_at` within 200ms | AS1 (200 + body), AS4 (200ms), AS12 (field order). Plan AC#1 lists `target_kind, target_id` as response fields; this doc's R6 deliberately removes those echo fields per the helper's `SessionStatus` shape — the helper does NOT carry `target_kind` or `target_id` in its return. See R-RECONCILE below. |
| AC#2 — 400 on bad `id` OR bad `target_kind` before any file read | AS2 (400 on bad id), AS3 (422 on bad target_kind — different status code intentionally; see R-RECONCILE) |
| AC#3 — ≤200ms repeated polls against 40MB stream | AS4 |
| AC#4 — idle for never-started target has all derived fields null | AS5 |
| AC#5 — GET only, no CSRF, Origin still applies | AS6 (Origin), AS7 (405 on POST), R10 (read-only) |

### R-RECONCILE — Two intentional divergences from plan ACs

(1) **Response fields**: Plan AC#1 lists
`target_kind, target_id` as response fields. This doc's R6
omits them. Rationale:

- The helper's `SessionStatus` TypedDict declares exactly five
  fields; adding two more in the endpoint would require either
  (a) a route-level wrapper dict (forbidden by R-CON-3 and the
  "thin shim" intent of R5), or (b) a change to the helper
  (forbidden by R-OUT-1).
- The client already knows `target_kind` and `id` — it sent
  them in the URL. Echoing in the body adds bytes without
  adding info.
- Phase 3 UI consumers (Watchfloor) plan to map state on
  `(target_kind, id) → status` in their local store keyed by the
  URL parameters, so echo fields would be redundant.

Action: the implementation phase shall raise this divergence as
a `scope_decision` in the execution-plan's `deferred[]` array if
the plan-phase reviewer disagrees. The default position is "omit
echoes"; the alternative is "wrap the helper response in
`{target_kind, target_id, **session_status}`" at the route layer,
which is a 2-line change.

(2) **Status code on bad `target_kind`**: Plan AC#2 says "400";
this doc's R3 + AS3 produce 422 via FastAPI's Pydantic Literal
rejection path. Rationale:

- 422 is FastAPI's idiomatic "request shape invalid" code; the
  app's existing `RequestValidationError` handler emits
  `{"error":"invalid"}` for path-param coercion failures
  (`app.py:160-200`). Switching this single endpoint to 400 for
  one parameter while every sibling route uses 422 for the same
  class of failure introduces an inconsistency that surfaces in
  Phase 3 error-handling code as a special case.
- 400 vs 422 is a contract the UI must know. The Watchfloor UI's
  error handler already branches on 422 → "shape" vs 400 →
  "validation"; following the same split here keeps the UI's
  error mapping uniform.

Action: same as (1) — the implementation phase shall raise this
as a `scope_decision` in `deferred[]` if the plan-phase reviewer
prefers a route-level downgrade to 400. The default is "match
the existing 422 path".

These two reconciliations are NOT deferred work — they are
explicit positions taken in this REQUIREMENTS doc that the plan
phase can either accept or reject. The implementation phase
implements whichever the plan phase ratifies.
