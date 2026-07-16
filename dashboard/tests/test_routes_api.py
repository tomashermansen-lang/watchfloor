"""Tests for the FastAPI APIRouter port (C3 — routes/api.py).

Covers REQUIREMENTS.md R1, R3-R9, R11. The 7 endpoints in this batch are the
core read surface (flow-status, worktrees, plan, plans, sessions, features,
metrics). All handlers must call the existing helpers without modification
(R11) and emit StdlibJSONResponse so byte-equivalence holds (R2).

Test rows trace to TESTPLAN.md § Coverage Map. Helper functions are
monkey-patched onto the routes.api module surface so each test exercises one
branch of the handler in isolation.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest
from fastapi import APIRouter
from fastapi.testclient import TestClient

# ---------------------------------------------------------------------------
# Test client fixture — wires the router into a fresh FastAPI app so the
# handlers can be exercised without pulling the SPA mount into scope.
# ---------------------------------------------------------------------------


@pytest.fixture()
def client() -> TestClient:
    from fastapi import FastAPI

    from dashboard.server.routes.api import router

    app = FastAPI()
    app.include_router(router)
    return TestClient(app)


@pytest.fixture()
def client_html() -> TestClient:
    """T0.2.b sibling fixture: same router as ``client``, plus the C2 HTML 4xx
    handler. Used by every autopilot test (T10-T16) where the body-byte
    assertion needs the handler in scope. Predecessor ``client`` fixture stays
    untouched so T3.2 / T4.2 / T5.2 / T5.7 / T9.2 / T9.5 keep their JSON-body
    assertions green (PLAN.md C6 § Fixture strategy / REVIEW.md Finding #2).
    """
    from fastapi import FastAPI
    from starlette.exceptions import HTTPException as StarletteHTTPException

    from dashboard.server._exception_handlers import (
        html_4xx_handler,
        html_500_handler,
    )
    from dashboard.server.routes.api import router

    app = FastAPI()
    app.add_exception_handler(StarletteHTTPException, html_4xx_handler)
    app.add_exception_handler(Exception, html_500_handler)
    app.include_router(router)
    return TestClient(app)


# ---------------------------------------------------------------------------
# T1.* — APIRouter scaffolding (R1)
# ---------------------------------------------------------------------------


def test_t1_1_router_imports_and_is_apirouter_instance() -> None:
    """T1.1 (R1): router is importable and is an APIRouter instance."""
    from dashboard.server.routes.api import router

    assert isinstance(router, APIRouter)


def test_t1_2_router_declares_core_autopilot_artifacts_grinder_paths() -> None:
    """T1.2 (R1): router.routes contains all expected paths across the batches.

    T0.2.a shipped 7 core endpoints; T0.2.b shipped 7 autopilot
    endpoints; T0.2.c closed the chain with 6 GET artifact + grinder
    paths plus POST and DELETE on ``/api/grinder/pause`` (one path,
    two methods → counted once in the path set).
    session-status-endpoint adds ``/api/{target_kind}/status``.
    controls-06 #11 adds ``/api/csrf`` (body-token endpoint).
    """
    from dashboard.server.routes.api import router

    paths = {getattr(route, "path", None) for route in router.routes}
    assert paths == {
        # core (T0.2.a)
        "/api/flow-status",
        "/api/worktrees",
        "/api/plan",
        "/api/plans",
        "/api/sessions",
        "/api/features",
        "/api/metrics",
        # autopilot (T0.2.b)
        "/api/autopilots",
        "/api/autopilot/log",
        "/api/autopilot/stream",
        "/api/autopilot/summary",
        "/api/autopilot/artifacts",
        "/api/autopilot/artifact",
        "/api/autopilot/activity",
        # artifacts + grinder (T0.2.c)
        "/api/plan/artifacts",
        "/api/plan/artifact",
        "/api/feature/artifacts",
        "/api/feature/artifact",
        "/api/grinder",
        "/api/grinder/stream",
        "/api/grinder/pause",
        # session-status-endpoint
        "/api/{target_kind}/status",
        # body-token CSRF (controls-06 #11)
        "/api/csrf",
    }


def test_t1_3_routes_init_is_empty_package_marker() -> None:
    """T1.3 (R1): routes/__init__.py is empty (no side-effecting imports)."""
    from dashboard.server import routes as routes_pkg

    init_file = Path(routes_pkg.__file__)
    assert init_file.stat().st_size == 0


def test_t1_4_no_dispatch_dict_in_routes_api() -> None:
    """T1.4 (R1, constraint #1): no module-level UPPER_CASE = {...} dispatch dict."""
    from dashboard.server.routes import api as routes_api

    source = Path(routes_api.__file__).read_text()
    assert re.search(r"^[A-Z_]+\s*=\s*\{", source, re.MULTILINE) is None, (
        "routes/api.py must not declare a dispatch dict — use APIRouter decorators"
    )


# ---------------------------------------------------------------------------
# T3.* — GET /api/flow-status (R3)
# ---------------------------------------------------------------------------


def test_t3_1_flow_status_with_cwd_calls_helper_and_returns_200(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T3.1 (R3): handler delegates to detect_flow_status and emits 200 JSON."""
    from dashboard.server.routes import api as routes_api

    captured: dict[str, str] = {}

    def fake(cwd: str) -> list[dict[str, str]]:
        captured["cwd"] = cwd
        return [{"feature": "x", "phase": "plan", "dir": "INPROGRESS_Feature_x"}]

    monkeypatch.setattr(routes_api, "detect_flow_status", fake)
    response = client.get("/api/flow-status?cwd=/tmp/foo")
    assert response.status_code == 200
    assert captured["cwd"] == "/tmp/foo"
    assert response.content == json.dumps(
        [{"feature": "x", "phase": "plan", "dir": "INPROGRESS_Feature_x"}]
    ).encode("utf-8")
    assert response.headers["content-type"] == "application/json; charset=utf-8"
    assert response.headers["cache-control"] == "no-store"


def test_t3_2_flow_status_missing_cwd_returns_400_with_stdlib_message(
    client: TestClient,
) -> None:
    """T3.2 (R3): GET /api/flow-status (no cwd) → 400 'Missing cwd parameter'."""
    response = client.get("/api/flow-status")
    assert response.status_code == 400
    assert response.json() == {"detail": "Missing cwd parameter"}


def test_t3_3_flow_status_empty_cwd_proceeds_not_400(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T3.3 (R3, Risk-F): ?cwd= (key with empty value) → 200, NOT 400.

    Stdlib parse_qs returns ``[""]`` for ``?cwd=``; FastAPI Query(None) returns
    ``""`` (not None). The handler MUST use ``if cwd is None`` so the empty
    string proceeds to the helper — matching stdlib byte parity.
    """
    from dashboard.server.routes import api as routes_api

    captured: dict[str, object] = {}

    def fake(cwd: str) -> list:
        captured["cwd"] = cwd
        return []

    monkeypatch.setattr(routes_api, "detect_flow_status", fake)
    response = client.get("/api/flow-status?cwd=")
    assert response.status_code == 200, (
        "?cwd= must NOT be 400 — stdlib short-circuits only when key is absent"
    )
    assert captured["cwd"] == ""
    assert response.content == b"[]"


# ---------------------------------------------------------------------------
# T4.* — GET /api/worktrees (R4)
# ---------------------------------------------------------------------------


def test_t4_1_worktrees_with_cwd_calls_helper_and_returns_200(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T4.1 (R4): handler delegates to get_all_worktrees and emits 200 JSON."""
    from dashboard.server.routes import api as routes_api

    captured: dict[str, str] = {}

    def fake(cwd: str) -> list[dict[str, str]]:
        captured["cwd"] = cwd
        return [{"path": "/x", "branch": "main"}]

    monkeypatch.setattr(routes_api, "get_all_worktrees", fake)
    response = client.get("/api/worktrees?cwd=/tmp/foo")
    assert response.status_code == 200
    assert captured["cwd"] == "/tmp/foo"
    assert response.content == json.dumps([{"path": "/x", "branch": "main"}]).encode("utf-8")


def test_t4_2_worktrees_missing_cwd_returns_400(client: TestClient) -> None:
    """T4.2 (R4): GET /api/worktrees (no cwd) → 400 'Missing cwd parameter'."""
    response = client.get("/api/worktrees")
    assert response.status_code == 400
    assert response.json() == {"detail": "Missing cwd parameter"}


# ---------------------------------------------------------------------------
# T5.* — GET /api/plan four-tier resolution (R5)
# ---------------------------------------------------------------------------


def test_t5_1_plan_missing_cwd_returns_400(client: TestClient) -> None:
    """T5.1 (R5): GET /api/plan (no cwd) → 400 'Missing cwd parameter'."""
    response = client.get("/api/plan")
    assert response.status_code == 400
    assert response.json() == {"detail": "Missing cwd parameter"}


def test_t5_2_plan_invalid_cwd_returns_403(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T5.2 (R5): _validate_cwd_param rejects → 403 Forbidden."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda cwd: None)
    response = client.get("/api/plan?cwd=/etc")
    assert response.status_code == 403
    assert response.json() == {"detail": "Forbidden"}


def test_t5_3_plan_tier1_load_execution_plan_at_validated(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T5.3 (R5): tier 1 hit — load_execution_plan(validated) returns the plan."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda cwd: cwd)
    monkeypatch.setattr(routes_api, "get_main_worktree", lambda v: v)

    plan_obj = {"id": "tier-1", "phases": []}
    monkeypatch.setattr(routes_api, "load_execution_plan", lambda root: (plan_obj, str(root)))
    monkeypatch.setattr(routes_api, "find_plans", lambda root: [])
    monkeypatch.setattr(routes_api, "merge_file_status", lambda plan, root: plan)
    monkeypatch.setattr(routes_api, "enrich_gates", lambda plan, plan_dir: plan)

    response = client.get("/api/plan?cwd=/tmp/x")
    assert response.status_code == 200
    assert response.json() == plan_obj


def test_t5_4_plan_tier2_find_plans_inprogress_wins(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T5.4 (R5, EC-5.3): tier 2 picks the inprogress plan over a done plan."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda cwd: cwd)
    monkeypatch.setattr(routes_api, "get_main_worktree", lambda v: v)
    monkeypatch.setattr(routes_api, "load_execution_plan", lambda root: None)

    in_progress = {"id": "in-progress"}
    done = {"id": "done"}

    def fake_find_plans(root: str) -> list[dict]:
        return [
            {"plan": done, "path": "/x/docs/DONE_Plan_x/execution-plan.yaml", "lifecycle": "done"},
            {
                "plan": in_progress,
                "path": "/x/docs/INPROGRESS_Plan_y/execution-plan.yaml",
                "lifecycle": "inprogress",
            },
        ]

    monkeypatch.setattr(routes_api, "find_plans", fake_find_plans)
    monkeypatch.setattr(routes_api, "merge_file_status", lambda plan, root: plan)
    monkeypatch.setattr(routes_api, "enrich_gates", lambda plan, plan_dir: plan)

    response = client.get("/api/plan?cwd=/tmp/x")
    assert response.status_code == 200
    assert response.json() == in_progress


def test_t5_5_plan_tier3_load_execution_plan_at_main_root(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T5.5 (R5): tier 3 — first two miss; load_execution_plan(main_root) hits."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda cwd: cwd)
    monkeypatch.setattr(routes_api, "get_main_worktree", lambda v: "/main/root")

    main_plan = {"id": "tier-3"}

    def fake_load(root: str) -> tuple[dict, str] | None:
        if root == "/main/root":
            return (main_plan, "/main/root")
        return None

    def fake_find(root: str) -> list:
        return []

    monkeypatch.setattr(routes_api, "load_execution_plan", fake_load)
    monkeypatch.setattr(routes_api, "find_plans", fake_find)
    monkeypatch.setattr(routes_api, "merge_file_status", lambda plan, root: plan)
    monkeypatch.setattr(routes_api, "enrich_gates", lambda plan, plan_dir: plan)

    response = client.get("/api/plan?cwd=/wt")
    assert response.status_code == 200
    assert response.json() == main_plan


def test_t5_6_plan_tier4_find_plans_at_main_root(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T5.6 (R5, EC-5.2): tier 4 — only find_plans(main_root) returns a plan."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda cwd: cwd)
    monkeypatch.setattr(routes_api, "get_main_worktree", lambda v: "/main/root")
    monkeypatch.setattr(routes_api, "load_execution_plan", lambda root: None)

    main_plan = {"id": "tier-4"}

    def fake_find(root: str) -> list:
        if root == "/main/root":
            return [
                {
                    "plan": main_plan,
                    "path": "/main/root/docs/INPROGRESS_Plan_y/execution-plan.yaml",
                    "lifecycle": "inprogress",
                }
            ]
        return []

    monkeypatch.setattr(routes_api, "find_plans", fake_find)
    monkeypatch.setattr(routes_api, "merge_file_status", lambda plan, root: plan)
    monkeypatch.setattr(routes_api, "enrich_gates", lambda plan, plan_dir: plan)

    response = client.get("/api/plan?cwd=/wt")
    assert response.status_code == 200
    assert response.json() == main_plan


def test_t5_7_plan_all_tiers_miss_returns_404(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T5.7 (R5, EC-5.1): all four tiers miss → 404 'No execution plan found'."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda cwd: cwd)
    monkeypatch.setattr(routes_api, "get_main_worktree", lambda v: v)
    monkeypatch.setattr(routes_api, "load_execution_plan", lambda root: None)
    monkeypatch.setattr(routes_api, "find_plans", lambda root: [])

    response = client.get("/api/plan?cwd=/tmp/empty")
    assert response.status_code == 404
    assert response.json() == {"detail": "No execution plan found"}


def test_t5_8_plan_calls_merge_file_status_and_enrich_gates(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T5.8 (R5): both merge_file_status and enrich_gates run before emit."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda cwd: cwd)
    monkeypatch.setattr(routes_api, "get_main_worktree", lambda v: v)
    plan_obj = {"id": "p"}
    monkeypatch.setattr(routes_api, "load_execution_plan", lambda root: (plan_obj, str(root)))
    monkeypatch.setattr(routes_api, "find_plans", lambda root: [])

    merge_calls: list[tuple] = []
    enrich_calls: list[tuple] = []

    def merge(plan: dict, root: str) -> dict:
        merge_calls.append((id(plan), root))
        return {**plan, "merged": True}

    def enrich(plan: dict, plan_dir: str) -> dict:
        enrich_calls.append((id(plan), plan_dir))
        return {**plan, "enriched": True}

    monkeypatch.setattr(routes_api, "merge_file_status", merge)
    monkeypatch.setattr(routes_api, "enrich_gates", enrich)

    response = client.get("/api/plan?cwd=/tmp/x")
    assert response.status_code == 200
    assert response.json() == {"id": "p", "merged": True, "enriched": True}
    assert len(merge_calls) == 1
    assert len(enrich_calls) == 1


def test_t5_9_plan_helper_exception_propagates_as_500(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T5.9 (R5, EC-5.4): malformed YAML — helper raises → 500 propagates."""
    from fastapi import FastAPI

    from dashboard.server.routes import api as routes_api
    from dashboard.server.routes.api import router

    app = FastAPI()
    app.include_router(router)
    raising_client = TestClient(app, raise_server_exceptions=False)

    monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda cwd: cwd)
    monkeypatch.setattr(routes_api, "get_main_worktree", lambda v: v)

    def boom(root: str) -> None:
        raise ValueError("malformed yaml")

    monkeypatch.setattr(routes_api, "load_execution_plan", boom)
    response = raising_client.get("/api/plan?cwd=/tmp/x")
    assert response.status_code == 500


# ---------------------------------------------------------------------------
# T6.* — GET /api/plans (R6)
# ---------------------------------------------------------------------------


def test_t6_1_plans_calls_discover_all_plans_v2_once(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T6.1 (R6): handler delegates to discover_all_plans_v2 and emits 200."""
    from dashboard.server.routes import api as routes_api

    calls: list[int] = []

    def fake() -> list[dict]:
        calls.append(1)
        return [{"id": "x"}]

    monkeypatch.setattr(routes_api, "discover_all_plans_v2", fake)
    response = client.get("/api/plans")
    assert response.status_code == 200
    assert response.content == b'[{"id": "x"}]'
    assert len(calls) == 1


# ---------------------------------------------------------------------------
# T7.* — GET /api/sessions (R7)
# ---------------------------------------------------------------------------


def test_t7_1_sessions_calls_get_session_states_once(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T7.1 (R7): handler delegates to get_session_states and emits 200."""
    from dashboard.server.routes import api as routes_api

    calls: list[int] = []

    def fake() -> list[dict]:
        calls.append(1)
        return [{"sid": "abc"}]

    monkeypatch.setattr(routes_api, "get_session_states", fake)
    response = client.get("/api/sessions")
    assert response.status_code == 200
    assert response.content == b'[{"sid": "abc"}]'
    assert len(calls) == 1


# ---------------------------------------------------------------------------
# T8.* — GET /api/features (R8)
# ---------------------------------------------------------------------------


def test_t8_1_features_calls_discover_features_once(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T8.1 (R8): handler delegates to discover_features and emits 200."""
    from dashboard.server.routes import api as routes_api

    calls: list[int] = []

    def fake() -> list[dict]:
        calls.append(1)
        return [{"feature": "demo"}]

    monkeypatch.setattr(routes_api, "discover_features", fake)
    response = client.get("/api/features")
    assert response.status_code == 200
    assert response.content == b'[{"feature": "demo"}]'
    assert len(calls) == 1


# ---------------------------------------------------------------------------
# T9.* — GET /api/metrics validation (R9)
# ---------------------------------------------------------------------------


def test_t9_1_metrics_no_query_calls_helper_with_none_none(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T9.1 (R9, EC-9.4): no params → compute_metrics(sid=None, since=None) → 200."""
    from dashboard.server.routes import api as routes_api

    captured: dict[str, object] = {}

    def fake(*, sid: str | None, since: str | None) -> dict:
        captured["sid"] = sid
        captured["since"] = since
        return {"metrics": "ok"}

    monkeypatch.setattr(routes_api, "compute_metrics", fake)
    response = client.get("/api/metrics")
    assert response.status_code == 200
    assert captured["sid"] is None
    assert captured["since"] is None


def test_t9_2_metrics_invalid_sid_returns_400(client: TestClient) -> None:
    """T9.2 (R9, EC-9.3): sid containing `/` fails _RE_SAFE_ID → 400."""
    response = client.get("/api/metrics?sid=evil%2Fpath")
    assert response.status_code == 400
    assert response.json() == {"detail": "Invalid sid"}


def test_t9_3_metrics_empty_sid_short_circuits_to_200(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T9.3 (R9, Risk-B): ?sid= (empty) → 200, NOT 400 (stdlib short-circuit parity)."""
    from dashboard.server.routes import api as routes_api

    captured: dict[str, object] = {}

    def fake(*, sid: str | None, since: str | None) -> dict:
        captured["sid"] = sid
        return {}

    monkeypatch.setattr(routes_api, "compute_metrics", fake)
    response = client.get("/api/metrics?sid=")
    assert response.status_code == 200, "empty sid must short-circuit, NOT 400"
    assert captured["sid"] == ""


def test_t9_4_metrics_valid_sid_calls_helper(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T9.4 (R9): valid sid passes regex → 200; helper called with the value."""
    from dashboard.server.routes import api as routes_api

    captured: dict[str, object] = {}

    def fake(*, sid: str | None, since: str | None) -> dict:
        captured["sid"] = sid
        return {}

    monkeypatch.setattr(routes_api, "compute_metrics", fake)
    response = client.get("/api/metrics?sid=valid_id-1")
    assert response.status_code == 200
    assert captured["sid"] == "valid_id-1"


def test_t9_5_metrics_invalid_since_returns_400(client: TestClient) -> None:
    """T9.5 (R9): since=not-a-date → 400 'Invalid since timestamp'."""
    response = client.get("/api/metrics?since=not-a-date")
    assert response.status_code == 400
    assert response.json() == {"detail": "Invalid since timestamp"}


def test_t9_6_metrics_since_with_trailing_z_accepted(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T9.6 (R9, EC-9.2): since=...Z → 200 (`.replace("Z","+00:00")` substitution)."""
    from dashboard.server.routes import api as routes_api

    captured: dict[str, object] = {}

    def fake(*, sid: str | None, since: str | None) -> dict:
        captured["since"] = since
        return {}

    monkeypatch.setattr(routes_api, "compute_metrics", fake)
    response = client.get("/api/metrics?since=2026-05-09T12:00:00Z")
    assert response.status_code == 200
    assert captured["since"] == "2026-05-09T12:00:00Z"


def test_t9_7_metrics_since_with_explicit_offset_accepted(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T9.7 (R9): since=2026-05-09T12:00:00+00:00 → 200."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "compute_metrics", lambda *, sid, since: {})
    response = client.get("/api/metrics?since=2026-05-09T12:00:00%2B00:00")
    assert response.status_code == 200


def test_t9_8_re_safe_id_is_same_constant_as_serve(
    client: TestClient,
) -> None:
    """T9.8 (R9, EC-11.3): _RE_SAFE_ID is SAME identity as the canonical source.

    Post fastapi-cutover (T0.3) the canonical source is
    ``dashboard.server._serve_legacy`` (the holding pen for the 17 symbols
    routes/api.py used to import from ``dashboard.serve``).
    """
    from dashboard.server import _serve_legacy
    from dashboard.server.routes import api as routes_api

    assert routes_api._RE_SAFE_ID is _serve_legacy._RE_SAFE_ID, (
        "no regex re-declaration — must reuse _serve_legacy._RE_SAFE_ID"
    )


# ---------------------------------------------------------------------------
# T11.* — Helpers imported, never modified (R11)
# ---------------------------------------------------------------------------


def test_t11_1_dashboard_serve_imports_without_side_effects() -> None:
    """T11.1 (R11, EC-11.1): post fastapi-cutover, ``import dashboard.serve``
    is a tombstone — it writes the cutover sentinel to stderr and exits 1.

    The R11 contract ("helpers imported, never modified") moved to
    ``dashboard.server._serve_legacy`` along with the 17 symbols
    routes/api.py consumes; ``test_serve_legacy_imports.py`` covers the
    no-side-effect import contract for that module.
    """
    repo_root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        [sys.executable, "-c", "import dashboard.serve"],
        capture_output=True,
        text=True,
        env={"PYTHONPATH": str(repo_root), "PATH": "/usr/bin:/bin"},
        timeout=10,
    )
    assert result.returncode == 1, (
        f"tombstone import must exit 1, got {result.returncode}: stderr={result.stderr!r}"
    )
    assert "tombstoned" in result.stderr
    assert "uvicorn dashboard.server.app:app" in result.stderr
    assert result.stdout == "", f"unexpected stdout: {result.stdout!r}"


def test_t11_2_re_safe_id_is_serve_identity() -> None:
    """T11.2 (R11, EC-11.3): identity, not just equality, with the canonical
    source (post-cutover: ``_serve_legacy._RE_SAFE_ID``).
    """
    from dashboard.server import _serve_legacy
    from dashboard.server.routes import api as routes_api

    assert routes_api._RE_SAFE_ID is _serve_legacy._RE_SAFE_ID


def test_t11_3_err_missing_cwd_equals_serve_constant() -> None:
    """T11.3 (R11): _ERR_MISSING_CWD equals the canonical source constant."""
    from dashboard.server import _serve_legacy
    from dashboard.server.routes import api as routes_api

    assert routes_api._ERR_MISSING_CWD == _serve_legacy._ERR_MISSING_CWD


def test_t11_4_detect_flow_status_is_serve_function() -> None:
    """T11.4 (R11): detect_flow_status reference is the same function object."""
    from dashboard.server import _serve_legacy
    from dashboard.server.routes import api as routes_api

    assert routes_api.detect_flow_status is _serve_legacy.detect_flow_status


def test_t11_5_helper_exception_propagates_as_500_no_swallow(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T11.5 (R11, EC-11.2): helper raising surfaces as 500, not 200/null."""
    from fastapi import FastAPI

    from dashboard.server.routes import api as routes_api
    from dashboard.server.routes.api import router

    app = FastAPI()
    app.include_router(router)
    raising_client = TestClient(app, raise_server_exceptions=False)

    def boom() -> None:
        raise RuntimeError("helper crash")

    monkeypatch.setattr(routes_api, "discover_all_plans_v2", boom)
    response = raising_client.get("/api/plans")
    assert response.status_code == 500


# ===========================================================================
# T0.2.b — autopilot family endpoints (T10.* through T18.*)
# All assertions in this section use the ``client_html`` fixture so the
# global ``html_4xx_handler`` is in scope and 4xx body bytes match the
# stdlib HTML template (R10).
# ===========================================================================


# ---------------------------------------------------------------------------
# T10.* — GET /api/autopilots (R2)
# ---------------------------------------------------------------------------


def test_t10_1_autopilots_returns_200_with_empty_list_bytes(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T10.1 (R2): GET /api/autopilots → 200, body ``b'[]'``, JSON headers."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "discover_autopilots", lambda: [])
    response = client_html.get("/api/autopilots")
    assert response.status_code == 200
    assert response.content == b"[]"
    assert response.headers["content-type"] == "application/json; charset=utf-8"
    assert response.headers["cache-control"] == "no-store"


def test_t10_2_autopilots_calls_discover_exactly_once(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T10.2 (R2, R11): discover_autopilots invoked exactly once, no args."""
    from dashboard.server.routes import api as routes_api

    captured = {"calls": 0}

    def fake() -> list:
        captured["calls"] += 1
        return []

    monkeypatch.setattr(routes_api, "discover_autopilots", fake)
    client_html.get("/api/autopilots")
    assert captured["calls"] == 1


def test_t10_3_autopilots_emits_non_empty_list_byte_equivalent(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T10.3 (R2): non-empty list serialized via stdlib json.dumps defaults."""
    from dashboard.server.routes import api as routes_api

    payload = [{"task": "a", "phase": "implement"}, {"task": "b", "phase": "qa"}]
    monkeypatch.setattr(routes_api, "discover_autopilots", lambda: payload)
    response = client_html.get("/api/autopilots")
    assert response.status_code == 200
    assert response.content == json.dumps(payload).encode("utf-8")


# ---------------------------------------------------------------------------
# T11.* — GET /api/autopilot/log (R3)
# ---------------------------------------------------------------------------


def test_t11_1_log_happy_path_returns_200_byte_equivalent(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T11.1 (R3): valid task + offset → 200; offset coerced to int."""
    from pathlib import Path as _Path

    from dashboard.server.routes import api as routes_api

    captured: dict[str, object] = {}

    def fake_resolve(task: str) -> _Path:
        captured["resolved_task"] = task
        return _Path("/dummy/log")

    def fake_read(path: _Path, offset: int, max_tail_bytes: int | None = None) -> tuple[str, int]:
        captured["offset"] = offset
        captured["offset_type"] = type(offset).__name__
        return ("hi", 7)

    monkeypatch.setattr(routes_api, "_resolve_log_path", fake_resolve)
    monkeypatch.setattr(routes_api, "read_log_incremental", fake_read)

    response = client_html.get("/api/autopilot/log?task=ok&offset=5")
    assert response.status_code == 200
    assert captured["offset"] == 5
    assert captured["offset_type"] == "int"
    assert response.content == json.dumps({"content": "hi", "offset": 7, "task": "ok"}).encode(
        "utf-8"
    )


def test_t11_2_log_missing_task_returns_400_html_body(
    client_html: TestClient,
) -> None:
    """T11.2 (R3, R10): no ``task`` → 400 HTML with stdlib message."""
    response = client_html.get("/api/autopilot/log")
    assert response.status_code == 400
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert b"<p>Message: Missing task parameter.</p>" in response.content
    assert b"<p>Error code: 400</p>" in response.content


def test_t11_3_log_invalid_task_with_slash_returns_400(
    client_html: TestClient,
) -> None:
    """T11.3 (R3, R9, R10): task containing ``/`` fails _RE_SAFE_ID → 400."""
    response = client_html.get("/api/autopilot/log?task=evil%2Fpath")
    assert response.status_code == 400
    assert b"<p>Message: Invalid task parameter.</p>" in response.content


def test_t11_4_log_invalid_offset_non_int_returns_400(
    client_html: TestClient,
) -> None:
    """T11.4 (R3, R10): offset=notnum → ValueError on int() → 400."""
    response = client_html.get("/api/autopilot/log?task=ok&offset=notnum")
    assert response.status_code == 400
    assert b"<p>Message: Invalid offset parameter.</p>" in response.content


def test_t11_5_log_invalid_offset_negative_returns_400(
    client_html: TestClient,
) -> None:
    """T11.5 (R3, R10): offset=-1 → 400 (negative integer)."""
    response = client_html.get("/api/autopilot/log?task=ok&offset=-1")
    assert response.status_code == 400
    assert b"<p>Message: Invalid offset parameter.</p>" in response.content


def test_t11_6_log_resolve_returns_none_yields_404(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T11.6 (R3, R10): _resolve_log_path → None → 404 'Log file not found'."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_resolve_log_path", lambda task: None)
    response = client_html.get("/api/autopilot/log?task=missing")
    assert response.status_code == 404
    assert b"<p>Message: Log file not found.</p>" in response.content


def test_t11_7_log_read_returns_none_yields_404(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T11.7 (R3, R10): read_log_incremental → None → 404 (same message)."""
    from pathlib import Path as _Path

    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_resolve_log_path", lambda task: _Path("/dummy"))
    monkeypatch.setattr(routes_api, "read_log_incremental", lambda p, o, max_tail_bytes=None: None)
    response = client_html.get("/api/autopilot/log?task=ok&offset=99999")
    assert response.status_code == 404
    assert b"<p>Message: Log file not found.</p>" in response.content


def test_t11_8_log_offset_default_is_zero(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T11.8 (R3): missing offset → default ``"0"`` → int 0; helper sees 0."""
    from pathlib import Path as _Path

    from dashboard.server.routes import api as routes_api

    captured: dict[str, int] = {}

    monkeypatch.setattr(routes_api, "_resolve_log_path", lambda task: _Path("/d"))

    def fake_read(p: _Path, o: int, max_tail_bytes: int | None = None) -> tuple[str, int]:
        captured["offset"] = o
        return ("", 0)

    monkeypatch.setattr(routes_api, "read_log_incremental", fake_read)
    response = client_html.get("/api/autopilot/log?task=ok")
    assert response.status_code == 200
    assert captured["offset"] == 0


def test_t11_9_log_empty_offset_returns_400(
    client_html: TestClient,
) -> None:
    """T11.9 (R3, R10, EC-3.2): offset= (empty) → int('') raises → 400."""
    response = client_html.get("/api/autopilot/log?task=ok&offset=")
    assert response.status_code == 400
    assert b"<p>Message: Invalid offset parameter.</p>" in response.content


def test_t11_10_log_empty_task_returns_invalid_not_missing(
    client_html: TestClient,
) -> None:
    """T11.10 (R3, R9, R10, OQ#4): task= (empty) → 'Invalid' not 'Missing'."""
    response = client_html.get("/api/autopilot/log?task=")
    assert response.status_code == 400
    assert b"<p>Message: Invalid task parameter.</p>" in response.content
    assert b"Missing task parameter" not in response.content


def test_t11_11_log_validation_order_task_first(
    client_html: TestClient,
) -> None:
    """T11.11 (R3, R10, EC-3.1): no task AND bad offset → 'Missing task' wins."""
    response = client_html.get("/api/autopilot/log?offset=notnum")
    assert response.status_code == 400
    assert b"<p>Message: Missing task parameter.</p>" in response.content
    assert b"Invalid offset parameter" not in response.content


# ---------------------------------------------------------------------------
# T12.* — GET /api/autopilot/stream (R4)
# ---------------------------------------------------------------------------


def test_t12_1_stream_happy_path_returns_200_byte_equivalent(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T12.1 (R4): valid task + offset → 200 with events list serialized."""
    from pathlib import Path as _Path

    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_resolve_stream_path", lambda task: _Path("/d"))
    monkeypatch.setattr(
        routes_api,
        "read_stream_incremental",
        lambda p, o, max_tail_bytes=None: ([{"event": "a"}], 12),
    )
    response = client_html.get("/api/autopilot/stream?task=ok&offset=10")
    assert response.status_code == 200
    assert response.content == json.dumps(
        {"events": [{"event": "a"}], "offset": 12, "task": "ok"}
    ).encode("utf-8")


def test_t12_2_stream_missing_task_returns_400(
    client_html: TestClient,
) -> None:
    """T12.2 (R4, R10): no task → 400 'Missing task parameter'."""
    response = client_html.get("/api/autopilot/stream")
    assert response.status_code == 400
    assert b"<p>Message: Missing task parameter.</p>" in response.content


def test_t12_3_stream_invalid_offset_returns_400(
    client_html: TestClient,
) -> None:
    """T12.3 (R4, R10): offset non-int → 400 'Invalid offset parameter'."""
    response = client_html.get("/api/autopilot/stream?task=ok&offset=xyz")
    assert response.status_code == 400
    assert b"<p>Message: Invalid offset parameter.</p>" in response.content


def test_t12_4_stream_resolve_none_returns_404_with_distinct_message(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T12.4 (R4, R10): _resolve_stream_path → None → 404 'Stream file not found'.

    Distinct from R3 'Log file not found' — proves the literal has not been
    copy-pasted across endpoints.
    """
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_resolve_stream_path", lambda task: None)
    response = client_html.get("/api/autopilot/stream?task=missing")
    assert response.status_code == 404
    assert b"<p>Message: Stream file not found.</p>" in response.content
    assert b"Log file not found" not in response.content


# ---------------------------------------------------------------------------
# T13.* — GET /api/autopilot/summary (R5)
# ---------------------------------------------------------------------------


def test_t13_1_summary_happy_path_returns_200(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T13.1 (R5): load_summary returns dict → 200 with serialized JSON."""
    from dashboard.server.routes import api as routes_api

    payload = {"task": "ok", "phases": []}
    monkeypatch.setattr(routes_api, "load_summary", lambda task: payload)
    response = client_html.get("/api/autopilot/summary?task=ok")
    assert response.status_code == 200
    assert response.content == json.dumps(payload).encode("utf-8")


def test_t13_2_summary_missing_task_returns_400(
    client_html: TestClient,
) -> None:
    """T13.2 (R5, R10): no task → 400 'Missing task parameter'."""
    response = client_html.get("/api/autopilot/summary")
    assert response.status_code == 400
    assert b"<p>Message: Missing task parameter.</p>" in response.content


def test_t13_3_summary_load_returns_none_yields_404(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T13.3 (R5, R10): load_summary → None → 404 'Summary not found'."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "load_summary", lambda task: None)
    response = client_html.get("/api/autopilot/summary?task=missing")
    assert response.status_code == 404
    assert b"<p>Message: Summary not found.</p>" in response.content


def test_t13_4_summary_invalid_task_with_special_chars_returns_400(
    client_html: TestClient,
) -> None:
    """T13.4 (R5, R9, R10): task containing ``&`` → 400 'Invalid task'."""
    response = client_html.get("/api/autopilot/summary?task=evil%26space")
    assert response.status_code == 400
    assert b"<p>Message: Invalid task parameter.</p>" in response.content


# ---------------------------------------------------------------------------
# T14.* — GET /api/autopilot/artifacts (R6)
# ---------------------------------------------------------------------------


def test_t14_1_artifacts_empty_list_returns_200(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T14.1 (R6): list_autopilot_artifacts → [] → 200 body ``b'[]'``."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "list_autopilot_artifacts", lambda task: [])
    response = client_html.get("/api/autopilot/artifacts?task=ok")
    assert response.status_code == 200
    assert response.content == b"[]"


def test_t14_2_artifacts_three_entry_list_byte_equivalent(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T14.2 (R6): non-empty list serialized stdlib-equivalent."""
    from dashboard.server.routes import api as routes_api

    payload = [{"file": "PLAN.md"}, {"file": "REVIEW.md"}, {"file": "QA_REPORT.md"}]
    monkeypatch.setattr(routes_api, "list_autopilot_artifacts", lambda task: payload)
    response = client_html.get("/api/autopilot/artifacts?task=ok")
    assert response.status_code == 200
    assert response.content == json.dumps(payload).encode("utf-8")


def test_t14_3_artifacts_missing_task_returns_400(
    client_html: TestClient,
) -> None:
    """T14.3 (R6, R10): no task → 400 'Missing task parameter'."""
    response = client_html.get("/api/autopilot/artifacts")
    assert response.status_code == 400
    assert b"<p>Message: Missing task parameter.</p>" in response.content


def test_t14_4_artifacts_invalid_task_with_slash_returns_400(
    client_html: TestClient,
) -> None:
    """T14.4 (R6, R9, R10): task with slash → 400 'Invalid task parameter'."""
    response = client_html.get("/api/autopilot/artifacts?task=evil%2Fpath")
    assert response.status_code == 400
    assert b"<p>Message: Invalid task parameter.</p>" in response.content


# ---------------------------------------------------------------------------
# T15.* — GET /api/autopilot/artifact (R7)
# ---------------------------------------------------------------------------


def test_t15_1_artifact_happy_path_reads_file_and_returns_200(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """T15.1 (R7): valid task + allow-listed file → 200 with content."""
    from dashboard.server.routes import api as routes_api

    real_file = tmp_path / "PLAN.md"
    real_file.write_text("PLAN body", encoding="utf-8")
    monkeypatch.setattr(routes_api, "_resolve_artifact_path", lambda t, f: str(real_file))

    response = client_html.get("/api/autopilot/artifact?task=ok&file=PLAN.md")
    assert response.status_code == 200
    assert response.content == json.dumps(
        {"task": "ok", "file": "PLAN.md", "content": "PLAN body"}
    ).encode("utf-8")


def test_t15_2_artifact_missing_file_returns_combined_message(
    client_html: TestClient,
) -> None:
    """T15.2 (R7, R10, EC-7): no file param → 400 combined message."""
    response = client_html.get("/api/autopilot/artifact?task=ok")
    assert response.status_code == 400
    assert b"<p>Message: Missing task or file parameter.</p>" in response.content
    assert b"Missing file parameter" not in response.content


def test_t15_3_artifact_missing_task_returns_combined_message(
    client_html: TestClient,
) -> None:
    """T15.3 (R7, R10): no task param → 400 combined message (symmetric)."""
    response = client_html.get("/api/autopilot/artifact?file=PLAN.md")
    assert response.status_code == 400
    assert b"<p>Message: Missing task or file parameter.</p>" in response.content


def test_t15_4_artifact_both_missing_returns_combined_message(
    client_html: TestClient,
) -> None:
    """T15.4 (R7, R10): both missing → 400 combined message."""
    response = client_html.get("/api/autopilot/artifact")
    assert response.status_code == 400
    assert b"<p>Message: Missing task or file parameter.</p>" in response.content


def test_t15_5_artifact_path_traversal_blocked_at_allow_list(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T15.5 (R7, R10, EC-7.1): ../.. file → 400, _resolve_artifact_path NEVER called."""
    from dashboard.server.routes import api as routes_api

    sentinel: dict[str, bool] = {"called": False}

    def asserting(_t: str, _f: str) -> None:
        sentinel["called"] = True
        return None

    monkeypatch.setattr(routes_api, "_resolve_artifact_path", asserting)
    response = client_html.get("/api/autopilot/artifact?task=ok&file=..%2F..%2Fetc%2Fpasswd")
    assert response.status_code == 400
    assert b"<p>Message: Invalid file parameter.</p>" in response.content
    assert sentinel["called"] is False, "resolver MUST NOT run for invalid file"


def test_t15_6_artifact_lowercase_filename_rejected_case_sensitive(
    client_html: TestClient,
) -> None:
    """T15.6 (R7, R10, EC-7.2): file=plan.md (lowercase) → 400; allow-list is case-sensitive."""
    response = client_html.get("/api/autopilot/artifact?task=ok&file=plan.md")
    assert response.status_code == 400
    assert b"<p>Message: Invalid file parameter.</p>" in response.content


def test_t15_7_artifact_validation_order_task_before_file(
    client_html: TestClient,
) -> None:
    """T15.7 (R7, R9, R10): bad task + good file → 'Invalid task' first."""
    response = client_html.get("/api/autopilot/artifact?task=evil%2Fpath&file=PLAN.md")
    assert response.status_code == 400
    assert b"<p>Message: Invalid task parameter.</p>" in response.content


def test_t15_8_artifact_resolve_none_yields_404(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T15.8 (R7, R10): _resolve_artifact_path → None → 404 'Artifact not found'."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_resolve_artifact_path", lambda t, f: None)
    response = client_html.get("/api/autopilot/artifact?task=missing&file=PLAN.md")
    assert response.status_code == 404
    assert b"<p>Message: Artifact not found.</p>" in response.content


def test_t15_9_artifact_oserror_on_read_yields_500(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T15.9 (R7, R10, EC-7.3): Path.read_text raises PermissionError → 500."""
    from pathlib import Path as _Path

    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "_resolve_artifact_path", lambda t, f: "/nope/PLAN.md")

    def boom(self: _Path, encoding: str = "utf-8") -> str:
        raise PermissionError("denied")

    monkeypatch.setattr(_Path, "read_text", boom)
    response = client_html.get("/api/autopilot/artifact?task=ok&file=PLAN.md")
    assert response.status_code == 500
    assert b"<p>Message: Error reading artifact.</p>" in response.content


def test_t15_10_allow_list_is_exact_ten_filenames() -> None:
    """T15.10 (R7, R9): _ALLOWED_ARTIFACT_FILES is exactly the 10 stdlib names."""
    from dashboard.server.routes.api import _ALLOWED_ARTIFACT_FILES

    assert _ALLOWED_ARTIFACT_FILES == frozenset(
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
    assert len(_ALLOWED_ARTIFACT_FILES) == 10


# ---------------------------------------------------------------------------
# T16.* — GET /api/autopilot/activity (R8)
# ---------------------------------------------------------------------------


def test_t16_1_activity_happy_path_no_since_returns_200(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T16.1 (R8): no since → helper sees None; body is byte-equivalent JSON."""
    from dashboard.server.routes import api as routes_api

    captured: dict[str, object] = {}

    def fake(task: str, since: str | None) -> list:
        captured["task"] = task
        captured["since"] = since
        return []

    monkeypatch.setattr(routes_api, "get_session_activity", fake)
    response = client_html.get("/api/autopilot/activity?task=ok")
    assert response.status_code == 200
    assert captured["since"] is None
    assert response.content == json.dumps({"task": "ok", "events": []}).encode("utf-8")


def test_t16_2_activity_missing_task_returns_400(
    client_html: TestClient,
) -> None:
    """T16.2 (R8, R10): no task → 400 'Missing task parameter'."""
    response = client_html.get("/api/autopilot/activity")
    assert response.status_code == 400
    assert b"<p>Message: Missing task parameter.</p>" in response.content


def test_t16_3_activity_invalid_since_returns_400(
    client_html: TestClient,
) -> None:
    """T16.3 (R8, R10): since=not-a-date → 400 'Invalid since timestamp'."""
    response = client_html.get("/api/autopilot/activity?task=ok&since=not-a-date")
    assert response.status_code == 400
    assert b"<p>Message: Invalid since timestamp.</p>" in response.content


def test_t16_4_activity_since_with_trailing_z_accepted(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T16.4 (R8, EC-8.1): ``since=...Z`` → 200 (Z→+00:00 substitution)."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "get_session_activity", lambda t, since: [])
    response = client_html.get("/api/autopilot/activity?task=ok&since=2026-05-09T12:00:00Z")
    assert response.status_code == 200


def test_t16_5_activity_since_with_space_separator_accepted(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T16.5 (R8, EC-8.2): ``2026-05-09 12:00:00`` accepted on Python 3.11+."""
    from dashboard.server.routes import api as routes_api

    monkeypatch.setattr(routes_api, "get_session_activity", lambda t, since: [])
    response = client_html.get("/api/autopilot/activity?task=ok&since=2026-05-09%2012:00:00")
    assert response.status_code == 200


def test_t16_6_activity_since_empty_returns_400(
    client_html: TestClient,
) -> None:
    """T16.6 (R8, R10, EC-8.3): ?since= → 400 (helper validates empty)."""
    response = client_html.get("/api/autopilot/activity?task=ok&since=")
    assert response.status_code == 400
    assert b"<p>Message: Invalid since timestamp.</p>" in response.content


def test_t16_7_activity_helper_sees_raw_since_string(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T16.7 (R8): helper receives the original raw string (NOT Z-replaced).

    The Z→+00:00 substitution is for ``fromisoformat`` only; the helper does
    its own parsing. Stdlib counterpart at ``serve.py:687`` passes the raw
    string — divergence here would silently change semantics.
    """
    from dashboard.server.routes import api as routes_api

    captured: dict[str, str] = {}

    def fake(task: str, since: str) -> list:
        captured["since"] = since
        return []

    monkeypatch.setattr(routes_api, "get_session_activity", fake)
    response = client_html.get("/api/autopilot/activity?task=ok&since=2026-05-09T12:00:00Z")
    assert response.status_code == 200
    assert captured["since"] == "2026-05-09T12:00:00Z"


# ---------------------------------------------------------------------------
# T17.* — _validate_iso_since helper (C4 — OQ#2 + R8)
# ---------------------------------------------------------------------------


def test_t17_1_validate_iso_since_none_is_silent() -> None:
    """T17.1 (R8, OQ#2): _validate_iso_since(None) returns silently."""
    from dashboard.server.routes.api import _validate_iso_since

    assert _validate_iso_since(None) is None


def test_t17_2_validate_iso_since_garbage_raises_400() -> None:
    """T17.2 (R8, R10, OQ#2): bad string raises HTTPException(400, message)."""
    from fastapi import HTTPException as _HTTPException

    from dashboard.server.routes.api import _validate_iso_since

    with pytest.raises(_HTTPException) as exc_info:
        _validate_iso_since("not-a-date")
    assert exc_info.value.status_code == 400
    assert exc_info.value.detail == "Invalid since timestamp"


def test_t17_3_validate_iso_since_with_trailing_z_accepted() -> None:
    """T17.3 (R8, OQ#2): trailing-Z timestamp accepted via .replace('Z', '+00:00')."""
    from dashboard.server.routes.api import _validate_iso_since

    assert _validate_iso_since("2026-05-09T12:00:00Z") is None


def test_t17_4_validate_iso_since_empty_string_raises() -> None:
    """T17.4 (R8, R10, OQ#2, EC-8.3): empty string → fromisoformat raises → 400."""
    from fastapi import HTTPException as _HTTPException

    from dashboard.server.routes.api import _validate_iso_since

    with pytest.raises(_HTTPException) as exc_info:
        _validate_iso_since("")
    assert exc_info.value.status_code == 400
    assert exc_info.value.detail == "Invalid since timestamp"


def test_t17_5_metrics_since_invalid_still_400_after_helper_extract(
    client: TestClient,
) -> None:
    """T17.5 (R15, Risk-F): /api/metrics?since=not-a-date → 400 'Invalid since timestamp'.

    Regression check: the C4 extraction must NOT change the predecessor T9.5
    behaviour for /api/metrics. JSON body shape preserved (uses ``client``
    fixture which has no HTML handler).
    """
    response = client.get("/api/metrics?since=not-a-date")
    assert response.status_code == 400
    assert response.json() == {"detail": "Invalid since timestamp"}


# ---------------------------------------------------------------------------
# T18.* — Helper-import shim (C5 — R9, R11)
# ---------------------------------------------------------------------------


def test_t18_1_seven_autopilot_handler_symbols_importable() -> None:
    """T18.1 (R11): all 7 new handler functions importable from routes.api."""
    from dashboard.server.routes.api import (  # noqa: F401
        api_autopilot_activity,
        api_autopilot_artifact,
        api_autopilot_artifacts,
        api_autopilot_log,
        api_autopilot_stream,
        api_autopilot_summary,
        api_autopilots,
    )


def test_t18_2_exception_handler_symbols_importable() -> None:
    """T18.2 (R10): C2 module exposes html_4xx_handler and html_500_handler."""
    from dashboard.server._exception_handlers import (  # noqa: F401
        html_4xx_handler,
        html_500_handler,
    )


def test_t18_3_error_constants_are_serve_identity() -> None:
    """T18.3 (R9, R11): _ERR_* in routes.api are SAME identity as the canonical
    source (post-cutover: ``_serve_legacy``).
    """
    from dashboard.server import _serve_legacy
    from dashboard.server.routes import api as routes_api

    assert routes_api._ERR_MISSING_TASK is _serve_legacy._ERR_MISSING_TASK
    assert routes_api._ERR_INVALID_TASK is _serve_legacy._ERR_INVALID_TASK
    assert routes_api._ERR_INVALID_OFFSET is _serve_legacy._ERR_INVALID_OFFSET
    assert routes_api._ERR_INVALID_FILE is _serve_legacy._ERR_INVALID_FILE
    assert routes_api._ERR_ARTIFACT_NOT_FOUND is _serve_legacy._ERR_ARTIFACT_NOT_FOUND
    # T0.2.c (R10): grinder/pause + grinder/stream constants
    assert routes_api._ERR_GRINDER_NOT_FOUND is _serve_legacy._ERR_GRINDER_NOT_FOUND
    assert routes_api._ERR_INVALID_PROJECT is _serve_legacy._ERR_INVALID_PROJECT


def test_t18_4_re_safe_id_identity_extended_to_autopilot() -> None:
    """T18.4 (R9): _RE_SAFE_ID identity holds (extends T9.8 / T11.2)."""
    from dashboard.server import _serve_legacy
    from dashboard.server.routes import api as routes_api

    assert routes_api._RE_SAFE_ID is _serve_legacy._RE_SAFE_ID


def test_re_safe_id_is_capped_at_64() -> None:
    """tmux-session-helper R4: regex cap landed on the consumer side.

    Lock in the 64-char upper bound so a future refactor that
    re-introduces the permissive ``^[a-zA-Z0-9_-]+$`` shape is caught
    immediately.
    """
    import re

    from dashboard.server.routes import api as routes_api

    assert re.match(routes_api._RE_SAFE_ID, "a" * 64)
    assert not re.match(routes_api._RE_SAFE_ID, "a" * 65)
    assert not re.match(routes_api._RE_SAFE_ID, "")


def test_t18_5_get_session_activity_signature() -> None:
    """T18.5 (R11): get_session_activity signature includes feature + since.

    Helper signature is ``(feature, since, limit)``; stdlib serve.py:686
    passes ``task`` positionally (it maps to ``feature``). The port mirrors
    that — ``get_session_activity(task, since=since)`` works because ``task``
    binds to the first positional ``feature`` parameter. The contract this
    test locks in: at minimum the helper must accept a positional first arg
    AND a ``since`` keyword.
    """
    import inspect

    from dashboard.server.session_helpers import get_session_activity

    sig = inspect.signature(get_session_activity)
    params = list(sig.parameters.keys())
    assert len(params) >= 1, "must have at least one positional parameter"
    assert "since" in params, "must accept a 'since' parameter"


def test_t18_6_discover_autopilots_called_per_request_no_local_cache(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T18.6 (R11, EC-11.1): port does NOT add a local cache; helper called each time.

    The helper itself has a 3-second TTL cache (autopilot_helpers.py) — the
    port must NOT add an extra layer that would shadow that contract.
    """
    from dashboard.server.routes import api as routes_api

    captured = {"calls": 0}

    def fake() -> list:
        captured["calls"] += 1
        return []

    monkeypatch.setattr(routes_api, "discover_autopilots", fake)
    client_html.get("/api/autopilots")
    client_html.get("/api/autopilots")
    assert captured["calls"] == 2, "port must not insert a local cache around discover_autopilots"
