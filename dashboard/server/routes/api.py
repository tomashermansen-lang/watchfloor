"""APIRouter port of the core, autopilot, artifact, and grinder endpoints.

Declares one ``APIRouter`` and 22 method-decorator combinations that mirror
the stdlib handlers in ``dashboard/serve.py`` byte-for-byte. T0.2.a shipped
the 7 core read endpoints (R1, R3-R9, R11); T0.2.b shipped the 7 autopilot
endpoints; T0.2.c closes the chain with the 6 GET artifact + grinder
endpoints plus POST and DELETE on ``/api/grinder/pause``.

Core (T0.2.a):

* ``GET /api/flow-status``  — ``serve.detect_flow_status``
* ``GET /api/worktrees``    — ``serve.get_all_worktrees``
* ``GET /api/plan``         — four-tier plan resolution
* ``GET /api/plans``        — ``plan_helpers.discover_all_plans_v2``
* ``GET /api/sessions``     — ``session_helpers.get_session_states``
* ``GET /api/features``     — ``feature_helpers.discover_features``
* ``GET /api/metrics``      — ``metrics_helpers.compute_metrics``

Autopilot (T0.2.b):

* ``GET /api/autopilots``        — ``autopilot_helpers.discover_autopilots``
* ``GET /api/autopilot/log``     — incremental log read
* ``GET /api/autopilot/stream``  — incremental NDJSON stream
* ``GET /api/autopilot/summary`` — parsed autopilot summary
* ``GET /api/autopilot/artifacts`` — list autopilot artifact docs
* ``GET /api/autopilot/artifact``  — read one allow-listed artifact
* ``GET /api/autopilot/activity``  — recent session events for a task

Artifacts + grinder (T0.2.c):

* ``GET /api/plan/artifacts``       — ``plan_helpers.list_task_artifacts``
* ``GET /api/plan/artifact``        — ``plan_helpers.get_plan_artifact``
* ``GET /api/feature/artifacts``    — inline ``FEATURE_ARTIFACT_ALLOWLIST`` scan
* ``GET /api/feature/artifact``     — traversal-checked file read
* ``GET /api/grinder``              — list / detail
* ``GET /api/grinder/stream``       — incremental grinder stream
* ``POST /api/grinder/pause``       — ``grinder_helpers.create_pause``
* ``DELETE /api/grinder/pause``     — ``grinder_helpers.remove_pause``

Each handler returns ``StdlibJSONResponse`` so the body bytes match
``serve.py:_send_json`` (default ``json.dumps`` separators, ``ensure_ascii=True``,
no trailing newline). Helpers are imported from existing modules without any
modification (R11). The constants ``_RE_SAFE_ID``, ``_ERR_MISSING_CWD``, and
the autopilot ``_ERR_*`` family are re-exported from ``dashboard.serve`` —
re-declaring them risks string drift (W11 / EC-11.3 / R9).

The HTML 4xx body bytes for every ``raise HTTPException`` here are formatted
by the global ``html_4xx_handler`` registered in ``dashboard.server.app``; this
module raises with the stdlib message and trusts the registry to render.
"""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Query, Request

# The sys.path bootstrap that used to live here (parents[2] → dashboard/)
# was removed 2026-05-23 when feature_helpers / plan_helpers / resume_helper /
# status_helper were refactored from `from server.X` to `from dashboard.server.X`
# — the bootstrap was only ever needed to make the legacy import style
# resolve under uvicorn. Now that every Python file uses the namespaced form,
# the dashboard repo-root is no longer needed on sys.path.

from dashboard.server._responses import StdlibJSONResponse
from dashboard.server._serve_legacy import (
    _ERR_ARTIFACT_NOT_FOUND,
    _ERR_GRINDER_NOT_FOUND,
    _ERR_INVALID_FILE,
    _ERR_INVALID_OFFSET,
    _ERR_INVALID_PROJECT,
    _ERR_INVALID_TASK,
    _ERR_MISSING_CWD,
    _ERR_MISSING_TASK,
    _RE_SAFE_ID,
    _resolve_project_root,
    _validate_artifact_filename,
    _validate_cwd_param,
    _validate_project_name,
    detect_flow_status,
    get_all_worktrees,
    get_main_worktree,
)
from dashboard.server._serve_legacy import logger as _serve_logger
from dashboard.server.autopilot_helpers import (
    _get_all_project_roots,
    _resolve_artifact_path,
    _resolve_log_path,
    _resolve_stream_path,
    discover_autopilots,
    list_autopilot_artifacts,
    load_summary,
    read_log_incremental,
    read_stream_incremental,
)
from dashboard.server.feature_helpers import (
    FEATURE_ARTIFACT_ALLOWLIST,
    discover_features,
)
from dashboard.server.grinder_helpers import (
    assemble_project_detail,
    create_pause,
    filter_batch_events,
    get_grinder_stream_path,
    list_grinder_projects,
    remove_pause,
)
from dashboard.server.metrics_helpers import compute_metrics
from dashboard.server.plan_helpers import (
    _ALL_ALLOWED_FILES,
    PLAN_ARTIFACT_ESCAPE_MARKER,
    PLAN_ARTIFACT_OUTSIDE_ROOT_MARKER,
    discover_all_plans_v2,
    enrich_gates,
    find_plans,
    get_plan_artifact,
    list_task_artifacts,
    load_execution_plan,
    merge_file_status,
)
from dashboard.server.session_helpers import (
    get_session_activity,
    get_session_states,
)
from dashboard.server.status_helper import (
    derive_status,
)

# Mirror of status_helper.TARGET_KINDS; if Phase 2 control-endpoints needs
# the alias from another module, lift it to dashboard.server.schemas then.
_TargetKind = Literal["autopilot", "chain"]

router = APIRouter()

# Allow-list of artifact filenames for /api/autopilot/artifact (R7, R9).
# Verbatim copy of ``dashboard/serve.py:567-571``; ``frozenset`` prevents
# accidental mutation at runtime and signals intent to the reader.
_ALLOWED_ARTIFACT_FILES: frozenset[str] = frozenset(
    {
        "REQUIREMENTS.md",
        "PLAN.md",
        "DESIGN.md",
        "REVIEW.md",
        "TEAM_REVIEW.md",
        "STATIC_ANALYSIS.md",
        "TEAM_QA.md",
        "QA_REPORT.md",
        "TESTPLAN.md",
        "MANUAL_TEST_LOG.md",
    }
)


def _validate_iso_since(since: str | None) -> None:
    """OQ#2: validate ISO-8601 ``since`` for /api/metrics + /api/autopilot/activity.

    No-ops on ``None``; raises ``HTTPException(400, 'Invalid since timestamp')``
    on parse failure. The ``Z`` → ``+00:00`` substitution mirrors stdlib
    ``serve.py:682`` so a trailing-Z timestamp is accepted by ``fromisoformat``.
    """
    if since is None:
        return
    try:
        datetime.fromisoformat(since.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid since timestamp") from exc


def _parse_tail(tail: str | None) -> int | None:
    """Parse the optional ``tail`` byte-budget query param for the stream/log
    endpoints (dashboard-perf 2026-06-02 #5).

    Lenient by design: a missing, non-numeric, zero, or negative value yields
    ``None`` (full read from the offset), so a malformed ``tail`` never turns
    into a 400 and never changes the existing validation order / error bytes of
    these handlers. Only a positive integer bounds the initial read.
    """
    if tail is None:
        return None
    try:
        value = int(tail)
    except (ValueError, TypeError):
        return None
    return value if value > 0 else None


@router.get("/api/flow-status")
def api_flow_status(cwd: str | None = Query(None)) -> StdlibJSONResponse:
    """R3: list flow phases for every feature under ``cwd``."""
    if cwd is None:
        raise HTTPException(status_code=400, detail=_ERR_MISSING_CWD)
    return StdlibJSONResponse(detect_flow_status(cwd))


@router.get("/api/csrf")
def api_csrf(request: Request) -> StdlibJSONResponse:
    """controls-06 #11 — body-token CSRF endpoint.

    Returns the same `csrf_token` value the CSRF middleware is about
    to drop in Set-Cookie. The cycle-5 double-submit pattern relied
    on `document.cookie` being readable from JS, which Vite-dev
    (`localhost:5175` proxying to FastAPI on `127.0.0.1:8787`) can
    silently break on browsers that treat the proxy hop as a
    SameSite-Strict boundary. With the token also surfaced in the
    response body, the frontend caches it in memory and uses it as
    the X-CSRF-Token header even when document.cookie comes up
    empty. The cookie is still issued (the middleware owns
    Set-Cookie), so the server-side double-submit compare still
    holds — this is purely a JS-visibility fallback.

    Safe to call any time; idempotent — returns the existing token
    when one is already in the cookie, or a freshly generated one
    when not. Tolerant of operators who refresh the page and lose
    the in-memory cache.
    """
    return StdlibJSONResponse({"token": request.state.csrf_token})


@router.get("/api/worktrees")
def api_worktrees(cwd: str | None = Query(None)) -> StdlibJSONResponse:
    """R4: list git worktrees rooted at ``cwd``."""
    if cwd is None:
        raise HTTPException(status_code=400, detail=_ERR_MISSING_CWD)
    return StdlibJSONResponse(get_all_worktrees(cwd))


@router.get("/api/plan")
def api_plan(cwd: str | None = Query(None)) -> StdlibJSONResponse:
    """R5: four-tier plan resolution mirroring ``serve.py:337-398``."""
    if cwd is None:
        raise HTTPException(status_code=400, detail=_ERR_MISSING_CWD)
    validated = _validate_cwd_param(cwd)
    if not validated:
        raise HTTPException(status_code=403, detail="Forbidden")
    main_root = get_main_worktree(validated) or validated

    result = load_execution_plan(validated)
    if not result:
        plans = find_plans(validated)
        if plans:
            target = next(
                (p for p in plans if p.get("lifecycle") == "inprogress"),
                plans[0],
            )
            result = (target["plan"], str(Path(target["path"]).parent))
    if not result:
        result = load_execution_plan(main_root)
    if not result:
        plans = find_plans(main_root)
        if plans:
            target = next(
                (p for p in plans if p.get("lifecycle") == "inprogress"),
                plans[0],
            )
            result = (target["plan"], str(Path(target["path"]).parent))
    if not result:
        raise HTTPException(status_code=404, detail="No execution plan found")

    plan, plan_dir = result
    plan = merge_file_status(plan, main_root)
    plan = enrich_gates(plan, plan_dir)
    return StdlibJSONResponse(plan)


@router.get("/api/plans")
def api_plans() -> StdlibJSONResponse:
    """R6: list all discovered execution plans across known projects."""
    return StdlibJSONResponse(discover_all_plans_v2())


@router.get("/api/sessions")
def api_sessions() -> StdlibJSONResponse:
    """R7: list current Claude Code session states."""
    return StdlibJSONResponse(get_session_states())


@router.get("/api/features")
def api_features() -> StdlibJSONResponse:
    """R8: list every in-progress feature visible to the dashboard."""
    return StdlibJSONResponse(discover_features())


@router.get("/api/metrics")
def api_metrics(
    sid: str | None = Query(None),
    since: str | None = Query(None),
) -> StdlibJSONResponse:
    """R9: aggregated metrics; validates sid and since per ``serve.py:415-433``."""
    if sid and not re.match(_RE_SAFE_ID, sid):
        raise HTTPException(status_code=400, detail="Invalid sid")
    # OQ#2 / Risk-F: shared helper with /api/autopilot/activity. The empty-
    # string short-circuit (``if since else None``) preserves predecessor
    # behaviour: stdlib ``serve.py:421`` uses ``if since:`` which treats ""
    # as "no since". /api/autopilot/activity calls the helper without this
    # short-circuit so empty raises 400 there (TESTPLAN T16.6).
    _validate_iso_since(since if since else None)
    return StdlibJSONResponse(compute_metrics(sid=sid, since=since))


# ---------------------------------------------------------------------------
# T0.2.b — autopilot family read endpoints (R1, R2-R8, R9, R11). Each handler
# mirrors its ``dashboard/serve.py:436-688`` stdlib counterpart byte-for-byte:
# same validation order, same hard-coded error messages, same helper calls.
# 4xx body bytes are formatted by ``html_4xx_handler`` registered in app.py.
# ---------------------------------------------------------------------------


@router.get("/api/autopilots")
def api_autopilots() -> StdlibJSONResponse:
    """R2: list discovered autopilot tasks (mirrors serve.py:436-440)."""
    return StdlibJSONResponse(discover_autopilots())


@router.get("/api/autopilot/log")
def api_autopilot_log(
    task: str | None = Query(None),
    offset: str = Query("0"),
    tail: str | None = Query(None),
) -> StdlibJSONResponse:
    """R3: incremental log read (mirrors serve.py:443-477)."""
    if task is None:
        raise HTTPException(status_code=400, detail=_ERR_MISSING_TASK)
    if not re.match(_RE_SAFE_ID, task):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_TASK)
    try:
        offset_int = int(offset)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=_ERR_INVALID_OFFSET) from exc
    if offset_int < 0:
        raise HTTPException(status_code=400, detail=_ERR_INVALID_OFFSET)
    log_path = _resolve_log_path(task)
    if not log_path:
        raise HTTPException(status_code=404, detail="Log file not found")
    result = read_log_incremental(log_path, offset_int, max_tail_bytes=_parse_tail(tail))
    if result is None:
        raise HTTPException(status_code=404, detail="Log file not found")
    content, new_offset = result
    return StdlibJSONResponse({"content": content, "offset": new_offset, "task": task})


@router.get("/api/autopilot/stream")
def api_autopilot_stream(
    task: str | None = Query(None),
    offset: str = Query("0"),
    tail: str | None = Query(None),
) -> StdlibJSONResponse:
    """R4: incremental NDJSON stream (mirrors serve.py:480-514)."""
    if task is None:
        raise HTTPException(status_code=400, detail=_ERR_MISSING_TASK)
    if not re.match(_RE_SAFE_ID, task):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_TASK)
    try:
        offset_int = int(offset)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=_ERR_INVALID_OFFSET) from exc
    if offset_int < 0:
        raise HTTPException(status_code=400, detail=_ERR_INVALID_OFFSET)
    stream_path = _resolve_stream_path(task)
    if not stream_path:
        raise HTTPException(status_code=404, detail="Stream file not found")
    result = read_stream_incremental(stream_path, offset_int, max_tail_bytes=_parse_tail(tail))
    if result is None:
        raise HTTPException(status_code=404, detail="Stream file not found")
    events, new_offset = result
    return StdlibJSONResponse({"events": events, "offset": new_offset, "task": task})


@router.get("/api/autopilot/summary")
def api_autopilot_summary(
    task: str | None = Query(None),
) -> StdlibJSONResponse:
    """R5: parsed autopilot summary (mirrors serve.py:517-534)."""
    if task is None:
        raise HTTPException(status_code=400, detail=_ERR_MISSING_TASK)
    if not re.match(_RE_SAFE_ID, task):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_TASK)
    summary = load_summary(task)
    if summary is None:
        raise HTTPException(status_code=404, detail="Summary not found")
    return StdlibJSONResponse(summary)


@router.get("/api/autopilot/artifacts")
def api_autopilot_artifacts(
    task: str | None = Query(None),
) -> StdlibJSONResponse:
    """R6: list autopilot artifact docs (mirrors serve.py:537-550)."""
    if task is None:
        raise HTTPException(status_code=400, detail=_ERR_MISSING_TASK)
    if not re.match(_RE_SAFE_ID, task):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_TASK)
    return StdlibJSONResponse(list_autopilot_artifacts(task))


@router.get("/api/autopilot/artifact")
def api_autopilot_artifact(
    task: str | None = Query(None),
    file: str | None = Query(None),
) -> StdlibJSONResponse:
    """R7: read a single allow-listed artifact (mirrors serve.py:553-587)."""
    if task is None or file is None:
        raise HTTPException(status_code=400, detail="Missing task or file parameter")
    if not re.match(_RE_SAFE_ID, task):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_TASK)
    if file not in _ALLOWED_ARTIFACT_FILES:
        raise HTTPException(status_code=400, detail=_ERR_INVALID_FILE)
    artifact_path = _resolve_artifact_path(task, file)
    if artifact_path is None:
        raise HTTPException(status_code=404, detail=_ERR_ARTIFACT_NOT_FOUND)
    try:
        content = Path(artifact_path).read_text(encoding="utf-8")
    except OSError as exc:
        raise HTTPException(status_code=500, detail="Error reading artifact") from exc
    return StdlibJSONResponse({"task": task, "file": file, "content": content})


@router.get("/api/autopilot/activity")
def api_autopilot_activity(
    task: str | None = Query(None),
    since: str | None = Query(None),
) -> StdlibJSONResponse:
    """R8: recent session events for an autopilot task (mirrors serve.py:668-688).

    The ``since`` value is forwarded to ``get_session_activity`` *as the raw
    string the client sent* (T16.7) — the ``Z`` → ``+00:00`` substitution in
    ``_validate_iso_since`` is for ``fromisoformat`` only; the helper does
    its own parsing and matches stdlib at ``serve.py:687``.
    """
    if task is None:
        raise HTTPException(status_code=400, detail=_ERR_MISSING_TASK)
    if not re.match(_RE_SAFE_ID, task):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_TASK)
    # T16.6 — empty string is validated (raises 400) rather than short-
    # circuited; the helper is called with the raw value.
    _validate_iso_since(since)
    events = get_session_activity(task, since=since)
    return StdlibJSONResponse({"task": task, "events": events})


# ---------------------------------------------------------------------------
# T0.2.c — artifact + grinder family endpoints (R1, R2-R11). Each handler
# mirrors its dashboard/serve.py:590-932 stdlib counterpart byte-for-byte:
# same validation order, same hard-coded error messages, same helper calls.
# 4xx/5xx body bytes are formatted by html_4xx_handler / html_500_handler
# already registered in app.py.
# ---------------------------------------------------------------------------


@router.get("/api/plan/artifacts")
def api_plan_artifacts(
    cwd: str | None = Query(None),
    task: str | None = Query(None),
) -> StdlibJSONResponse:
    """R2: list plan artifacts (mirrors serve.py:590-605)."""
    if cwd is None or task is None:
        raise HTTPException(status_code=400, detail="Missing cwd or task parameter")
    if not re.match(_RE_SAFE_ID, task):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_TASK)
    return StdlibJSONResponse(list_task_artifacts(cwd, task))


@router.get("/api/plan/artifact")
def api_plan_artifact(
    file: str | None = Query(None),
    task: str | None = Query(None),
    cwd: str | None = Query(None),
    plan_dir: str | None = Query(None),
) -> StdlibJSONResponse:
    """R3: read a single plan artifact (mirrors serve.py:626-665)."""
    if file is None:
        raise HTTPException(status_code=400, detail="Missing file parameter")
    if task and not re.match(_RE_SAFE_ID, task):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_TASK)
    descended = task is not None and cwd is not None and "/" in file
    if not _validate_artifact_filename(file, descended=descended, allowed=_ALL_ALLOWED_FILES):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_FILE)
    content = get_plan_artifact(cwd, plan_dir, task, file)
    if content == PLAN_ARTIFACT_ESCAPE_MARKER:
        raise HTTPException(status_code=400, detail="path escapes cwd")
    if content == PLAN_ARTIFACT_OUTSIDE_ROOT_MARKER:
        raise HTTPException(status_code=400, detail="cwd outside PROJECTS_ROOT")
    if content is None:
        raise HTTPException(status_code=404, detail=_ERR_ARTIFACT_NOT_FOUND)
    return StdlibJSONResponse({"file": file, "content": content})


@router.get("/api/feature/artifacts")
def api_feature_artifacts(
    feature: str | None = Query(None),
    project_root: str | None = Query(None),
) -> StdlibJSONResponse:
    """R4: list feature artifacts (mirrors serve.py:698-733).

    Inline iteration over ``FEATURE_ARTIFACT_ALLOWLIST`` is intentional:
    no helper exists for the directory scan, and R11 forbids extracting
    one in this batch. The same shape is inlined in stdlib serve.py:717-724.
    Tests cover this branch via mocked ``_validate_cwd_param`` /
    ``_get_all_project_roots`` plus tmp_path fixtures.
    """
    if feature is None or project_root is None:
        raise HTTPException(status_code=400, detail="Missing feature or project_root parameter")
    if not re.match(_RE_SAFE_ID, feature):
        raise HTTPException(status_code=400, detail="Invalid feature parameter")
    validated = _validate_cwd_param(project_root)
    if not validated:
        raise HTTPException(status_code=403, detail="Forbidden")
    if validated not in _get_all_project_roots():
        raise HTTPException(status_code=403, detail="Unknown project root")
    feature_dir = Path(validated) / "docs" / f"INPROGRESS_Feature_{feature}"
    if not feature_dir.is_dir():
        return StdlibJSONResponse([])
    artifacts = [
        {"name": filename, "file": filename}
        for filename in FEATURE_ARTIFACT_ALLOWLIST
        if (feature_dir / filename).is_file()
    ]
    return StdlibJSONResponse(artifacts)


@router.get("/api/feature/artifact")
def api_feature_artifact(
    feature: str | None = Query(None),
    project_root: str | None = Query(None),
    file: str | None = Query(None),
) -> StdlibJSONResponse:
    """R5: read a single feature artifact (mirrors serve.py:736-787)."""
    if feature is None or project_root is None or file is None:
        raise HTTPException(
            status_code=400,
            detail="Missing feature, project_root, or file parameter",
        )
    if not re.match(_RE_SAFE_ID, feature):
        raise HTTPException(status_code=400, detail="Invalid feature parameter")
    if ".." in file or "/" in file:
        raise HTTPException(status_code=400, detail=_ERR_INVALID_FILE)
    if file not in FEATURE_ARTIFACT_ALLOWLIST:
        raise HTTPException(status_code=400, detail=_ERR_INVALID_FILE)
    validated = _validate_cwd_param(project_root)
    if not validated:
        raise HTTPException(status_code=403, detail="Forbidden")
    if validated not in _get_all_project_roots():
        raise HTTPException(status_code=403, detail="Unknown project root")
    artifact_path = Path(validated) / "docs" / f"INPROGRESS_Feature_{feature}" / file
    resolved = artifact_path.resolve()
    if not str(resolved).startswith(str(Path(validated).resolve()) + "/"):
        raise HTTPException(status_code=403, detail="Path traversal detected")
    if not resolved.is_file():
        raise HTTPException(status_code=404, detail=_ERR_ARTIFACT_NOT_FOUND)
    try:
        content = resolved.read_text(encoding="utf-8")
    except OSError as exc:
        raise HTTPException(status_code=500, detail="Error reading artifact") from exc
    return StdlibJSONResponse({"feature": feature, "file": file, "content": content})


@router.get("/api/grinder")
def api_grinder(
    project: str | None = Query(None),
) -> StdlibJSONResponse:
    """R6: list grinder projects or detail (mirrors serve.py:808-832).

    ``?project=`` (empty value) is treated as absent — matches the stdlib
    handler that parsed the query via ``parse_qs(... keep_blank_values=False)``.
    Without this, FastAPI yields ``project == ""`` and the validator
    returns 400 for what stdlib used to answer 200 (T2.13 in
    test-api-grinder.sh — caught by the fastapi-cutover replay).
    """
    if not project:
        return StdlibJSONResponse(list_grinder_projects())
    if not _validate_project_name(project):
        raise HTTPException(status_code=400, detail="Invalid project parameter")
    root = _resolve_project_root(project)
    if not root:
        raise HTTPException(status_code=404, detail=_ERR_GRINDER_NOT_FOUND)
    return StdlibJSONResponse(assemble_project_detail(root))


@router.get("/api/grinder/stream")
def api_grinder_stream(
    project: str | None = Query(None),
    offset: str = Query("0"),
    batch: str | None = Query(None),
    tail: str | None = Query(None),
) -> StdlibJSONResponse:
    """R7: incremental grinder stream (mirrors serve.py:881-932).

    Validation order is load-bearing: project → resolve → offset →
    stream-path → read → batch. Reordering any step changes the fired
    error on compound-bad requests and breaks byte-equivalence (EC-7.3).
    """
    if project is None or not _validate_project_name(project):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_PROJECT)
    root = _resolve_project_root(project)
    if not root:
        raise HTTPException(status_code=404, detail=_ERR_GRINDER_NOT_FOUND)
    try:
        offset_int = int(offset)
        if offset_int < 0:
            raise ValueError("negative")
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=_ERR_INVALID_OFFSET) from exc
    stream_path = get_grinder_stream_path(root)
    if not stream_path:
        raise HTTPException(status_code=404, detail="No grinder stream file found")
    result = read_stream_incremental(stream_path, offset_int, max_tail_bytes=_parse_tail(tail))
    if result is None:
        raise HTTPException(status_code=500, detail="Error reading stream")
    events, new_offset = result
    if batch is not None:
        if not re.match(_RE_SAFE_ID, batch):
            raise HTTPException(status_code=400, detail="Invalid batch parameter")
        events = filter_batch_events(events, batch)
    return StdlibJSONResponse({"events": events, "offset": new_offset, "project": project})


@router.post("/api/grinder/pause")
def api_grinder_pause_post(
    project: str | None = Query(None),
) -> StdlibJSONResponse:
    """R8: create PAUSE marker (mirrors serve.py:835-855).

    The ``logger.warning`` call is a load-bearing side effect asserted
    by /qa via caplog (EC-8.2). Reuses ``dashboard.serve.logger`` so
    the log record's ``name`` field stays ``dashboard.serve``.
    """
    if project is None or not _validate_project_name(project):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_PROJECT)
    root = _resolve_project_root(project)
    if not root:
        raise HTTPException(status_code=404, detail=_ERR_GRINDER_NOT_FOUND)
    try:
        create_pause(root)
    except OSError as exc:
        _serve_logger.warning("Cannot create PAUSE file: %s", exc)
        raise HTTPException(status_code=500, detail="Cannot create PAUSE file") from exc
    return StdlibJSONResponse({"paused": True})


@router.delete("/api/grinder/pause")
def api_grinder_pause_delete(
    project: str | None = Query(None),
) -> StdlibJSONResponse:
    """R9: remove PAUSE marker (mirrors serve.py:858-878).

    Separate ``def`` from the POST handler — collapsing into one
    function with a method-switch is forbidden by AC-2 / plan
    constraint #2. Tests at ``test_routes_api_artifacts_grinder.py``
    ``TestPostDeleteRouting`` guard the distinction.
    """
    if project is None or not _validate_project_name(project):
        raise HTTPException(status_code=400, detail=_ERR_INVALID_PROJECT)
    root = _resolve_project_root(project)
    if not root:
        raise HTTPException(status_code=404, detail=_ERR_GRINDER_NOT_FOUND)
    try:
        remove_pause(root)
    except OSError as exc:
        _serve_logger.warning("Cannot remove PAUSE file: %s", exc)
        raise HTTPException(status_code=500, detail="Cannot remove PAUSE file") from exc
    return StdlibJSONResponse({"paused": False})


# ---------------------------------------------------------------------------
# session-status-endpoint — GET /api/{target_kind}/status (R1-R15)
# ---------------------------------------------------------------------------


@router.get(
    "/api/{target_kind}/status",
    responses={400: {"description": "Invalid id parameter"}},
)
def api_session_status(
    target_kind: _TargetKind,
    target_id: Annotated[
        str, Query(alias="id", min_length=1, max_length=64)
    ],
) -> StdlibJSONResponse:
    """Thin Pydantic-validated shim over status_helper.derive_status."""
    if not re.match(_RE_SAFE_ID, target_id):
        raise HTTPException(status_code=400, detail="Invalid id parameter")
    return StdlibJSONResponse(derive_status(target_kind, target_id))
