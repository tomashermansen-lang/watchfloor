"""Tests for GET /api/{target_kind}/status — session-status-endpoint feature.

Covers REQUIREMENTS.md R1-R15, R-OUT-1, R-OUT-2, R-CON-1, R-CON-2, R-CON-3,
AS1-AS15, and edge cases E1-E17 (runtime-testable subset). One row per
TESTPLAN.md scenario; trace matrix is the TESTPLAN.md § Requirement-to-Test
Trace Matrix.
"""

from __future__ import annotations

import inspect
import json
import re
import subprocess
import sys
import time
import typing
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest
from fastapi import FastAPI
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.requests import Request

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# The route imports via ``dashboard.server.status_helper``; tests must
# patch the same module object the route reads. ``server.status_helper``
# (used by test_status_helper.py) is a *different* module object loading
# the same file — patching it would leave the route's view unaffected.
from dashboard.server import status_helper  # noqa: E402
from dashboard.server.lifecycle_events import append_event  # noqa: E402

LOGGER_NAME = "dashboard.server.status_helper"

IDLE_DEFAULT: dict[str, Any] = {
    "status": "idle",
    "phase_at_pause": None,
    "last_phase_complete": None,
    "started_at": None,
    "tmux_session": None,
}


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_cache_autouse() -> Iterator[None]:
    """Risk-1: prevent _STATE_CACHE leak across tests."""
    status_helper._reset_cache()
    yield
    status_helper._reset_cache()


@pytest.fixture
def patched_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(status_helper, "_PROJECTS_ROOT", tmp_path)
    return tmp_path


def _stream_path(root: Path, kind: str, target_id: str) -> Path:
    label = "Feature" if kind == "autopilot" else "Plan"
    fname = "autopilot-stream.ndjson" if kind == "autopilot" else "chain-events.ndjson"
    return root / "proj" / "docs" / f"INPROGRESS_{label}_{target_id}" / fname


def make_stream(root: Path, kind: str, target_id: str) -> Path:
    path = _stream_path(root, kind, target_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()
    return path


def _evt(
    action: str = "started",
    *,
    target: str = "feat-x",
    ts: str = "2026-05-14T10:00:00Z",
    source: str = "cli",
    **extra: Any,
) -> dict[str, Any]:
    base: dict[str, Any] = {
        "ts": ts,
        "type": "lifecycle",
        "action": action,
        "source": source,
        "target": target,
    }
    base.update(extra)
    return base


def append_lifecycle(path: Path, **kwargs: Any) -> dict[str, Any]:
    event = _evt(**kwargs)
    append_event(path, event)
    return event


async def _validation_error_to_400(request: Request, exc: Exception) -> JSONResponse:
    """Inlined copy of dashboard.server.app._validation_error_to_400 (Finding #7).

    Crossing module boundaries on a leading-underscore symbol is a code smell;
    inlining the ~8 LOC pins the test app's 400-on-validation-error shape
    independent of future app.py refactors.
    """
    assert isinstance(exc, RequestValidationError)
    errors = [{k: v for k, v in e.items() if k not in {"input", "url"}} for e in exc.errors()]
    return JSONResponse(status_code=400, content=jsonable_encoder({"detail": errors}))


def _make_app(*, with_html_handlers: bool = False) -> FastAPI:
    from dashboard.server.routes.api import router

    app = FastAPI()
    app.add_exception_handler(RequestValidationError, _validation_error_to_400)
    if with_html_handlers:
        from dashboard.server._exception_handlers import (
            html_4xx_handler,
            html_500_handler,
        )

        app.add_exception_handler(StarletteHTTPException, html_4xx_handler)
        app.add_exception_handler(Exception, html_500_handler)
    app.include_router(router)
    return app


@pytest.fixture
def client() -> TestClient:
    return TestClient(_make_app())


@pytest.fixture
def client_html() -> TestClient:
    return TestClient(_make_app(with_html_handlers=True))


@pytest.fixture(scope="session")
def large_stream(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, str]:
    """Build a 40MB autopilot stream once per session (TESTPLAN R-TEST-G)."""
    root = tmp_path_factory.mktemp("large_stream_root")
    target_id = "big-feat"
    path = _stream_path(root, "autopilot", target_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    # ~200 KB of non-lifecycle padding lines (helper skips non-type=lifecycle)
    pad_line = json.dumps({"type": "phase", "name": "x" * 180}) + "\n"
    target_bytes = 40 * 1024 * 1024
    chunk = pad_line * 5000
    with path.open("w", encoding="utf-8") as fh:
        written = 0
        while written < target_bytes:
            fh.write(chunk)
            written += len(chunk)
        # Final valid lifecycle event so derive_status reports running
        fh.write(json.dumps(_evt(action="started", target=target_id)) + "\n")
    return root, target_id


# ---------------------------------------------------------------------------
# Group 1 — 200 success path (AS1, AS5, AS8, AS9, AS12, AS13-pass, E1, E9)
# ---------------------------------------------------------------------------


def test_t1_1_running_200_byte_equivalent(client: TestClient, patched_root: Path) -> None:
    """T1.1 (R1, R5, R6, AS1): started event → 200 + running body byte-for-byte."""
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    response = client.get("/api/autopilot/status?id=feat-x")
    assert response.status_code == 200
    expected = {
        "status": "running",
        "phase_at_pause": None,
        "last_phase_complete": None,
        "started_at": "2026-05-14T10:00:00Z",
        "tmux_session": None,
    }
    assert response.content == json.dumps(expected).encode("utf-8")


@pytest.mark.parametrize(
    "lifecycle_events, expected_status",
    [
        ([], "idle"),
        ([{"action": "started"}], "running"),
        (
            [{"action": "started"}, {"action": "paused", "phase_at_pause": "plan"}],
            "paused",
        ),
        ([{"action": "started"}, {"action": "cancelled"}], "cancelled"),
    ],
)
def test_t1_2_status_parametrized(
    client: TestClient,
    patched_root: Path,
    lifecycle_events: list[dict[str, Any]],
    expected_status: str,
) -> None:
    """T1.2 (R6, AS1): each helper-reachable status surfaces via body['status']."""
    if lifecycle_events:
        path = make_stream(patched_root, "autopilot", "feat-x")
        for ev in lifecycle_events:
            append_lifecycle(path, **ev)
    response = client.get("/api/autopilot/status?id=feat-x")
    assert response.status_code == 200
    assert json.loads(response.content)["status"] == expected_status


def test_t1_3_content_type_header(client: TestClient, patched_root: Path) -> None:
    """T1.3 (R6): Content-Type is application/json; charset=utf-8 (with space)."""
    make_stream(patched_root, "autopilot", "feat-x")
    response = client.get("/api/autopilot/status?id=feat-x")
    assert response.headers["content-type"] == "application/json; charset=utf-8"


def test_t1_4_cache_control_no_store(client: TestClient, patched_root: Path) -> None:
    """T1.4 (R6, R11): Cache-Control: no-store on 200."""
    make_stream(patched_root, "autopilot", "feat-x")
    response = client.get("/api/autopilot/status?id=feat-x")
    assert response.headers["cache-control"] == "no-store"


def test_t1_5_idle_default_no_stream(client: TestClient, patched_root: Path) -> None:
    """T1.5 (R6, AS5, E1): missing stream → 200 + idle envelope."""
    response = client.get("/api/autopilot/status?id=ghost-feat")
    assert response.status_code == 200
    assert response.content == json.dumps(IDLE_DEFAULT).encode("utf-8")


def test_t1_6_idle_emits_no_warning(
    client: TestClient, patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """T1.6 (R13, AS5): idle path emits zero WARNING records."""
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        response = client.get("/api/autopilot/status?id=ghost-feat")
    assert response.status_code == 200
    warnings = [r for r in caplog.records if r.name == LOGGER_NAME and r.levelname == "WARNING"]
    assert warnings == []


def test_t1_7_field_order_matches_sessionstatus(client: TestClient, patched_root: Path) -> None:
    """T1.7 (R6, AS12): JSON body keys exactly match SessionStatus declaration order."""
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    response = client.get("/api/autopilot/status?id=feat-x")
    assert list(json.loads(response.content).keys()) == [
        "status",
        "phase_at_pause",
        "last_phase_complete",
        "started_at",
        "tmux_session",
    ]


def test_t1_8_paused_with_last_phase_complete(client: TestClient, patched_root: Path) -> None:
    """T1.8 (R6, AS8): started → phase_complete(ba) → paused(plan) → paused body."""
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    append_lifecycle(path, action="phase_complete", phase="ba")
    append_lifecycle(path, action="paused", phase_at_pause="plan")
    response = client.get("/api/autopilot/status?id=feat-x")
    expected = {
        "status": "paused",
        "phase_at_pause": "plan",
        "last_phase_complete": "ba",
        "started_at": "2026-05-14T10:00:00Z",
        "tmux_session": None,
    }
    assert response.content == json.dumps(expected).encode("utf-8")


def test_t1_9_cancelled_clears_phase_at_pause(client: TestClient, patched_root: Path) -> None:
    """T1.9 (R6, AS8): stream ending with cancelled → status=cancelled, phase_at_pause=null."""
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    append_lifecycle(path, action="paused", phase_at_pause="plan")
    append_lifecycle(path, action="cancelled")
    response = client.get("/api/autopilot/status?id=feat-x")
    body = json.loads(response.content)
    assert body["status"] == "cancelled"
    assert body["phase_at_pause"] is None


def test_t1_10_chain_target_kind_resolves(client: TestClient, patched_root: Path) -> None:
    """T1.10 (R6, AS9, E12): /api/chain/status reads chain-events.ndjson."""
    path = make_stream(patched_root, "chain", "demo-plan")
    append_lifecycle(path, action="started", target="demo-plan")
    response = client.get("/api/chain/status?id=demo-plan")
    assert response.status_code == 200
    assert json.loads(response.content)["status"] == "running"


def test_t1_11_kind_isolation_same_id_different_kinds(
    client: TestClient, patched_root: Path
) -> None:
    """T1.11 (R6, AS9): only chain stream exists → autopilot=idle, chain=running."""
    path = make_stream(patched_root, "chain", "demo-id")
    append_lifecycle(path, action="started", target="demo-id")
    autopilot_resp = client.get("/api/autopilot/status?id=demo-id")
    chain_resp = client.get("/api/chain/status?id=demo-id")
    assert json.loads(autopilot_resp.content)["status"] == "idle"
    assert json.loads(chain_resp.content)["status"] == "running"


def test_t1_12_id_length_64_accepted(client: TestClient, patched_root: Path) -> None:
    """T1.12 (R4, AS13): 64-char id passes Query bound + regex → 200 idle."""
    long_id = "a" * 64
    response = client.get(f"/api/autopilot/status?id={long_id}")
    assert response.status_code == 200
    assert response.content == json.dumps(IDLE_DEFAULT).encode("utf-8")


def test_t1_13_numeric_id_accepted(client: TestClient, patched_root: Path) -> None:
    """T1.13 (R4, E1): numeric-only id passes regex → 200 idle."""
    response = client.get("/api/autopilot/status?id=12345")
    assert response.status_code == 200


@pytest.mark.parametrize("target_id", ["-feat-", "_feat_"])
def test_t1_14_leading_trailing_separator_accepted(
    client: TestClient, patched_root: Path, target_id: str
) -> None:
    """T1.14 (R4, E9): leading/trailing `-` or `_` pass regex → 200."""
    response = client.get(f"/api/autopilot/status?id={target_id}")
    assert response.status_code == 200


# ---------------------------------------------------------------------------
# Group 2 — Helper-call contract (AS2, AS11)
# ---------------------------------------------------------------------------


def test_t2_1_helper_called_exactly_once(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T2.1 (R5, R-CON-1, AS11): valid request invokes derive_status exactly once."""
    from dashboard.server.routes import api as routes_api

    mock = MagicMock(return_value=IDLE_DEFAULT)
    monkeypatch.setattr(routes_api, "derive_status", mock)
    response = client.get("/api/autopilot/status?id=feat-x")
    assert response.status_code == 200
    assert mock.call_count == 1


def test_t2_2_helper_call_args_order(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    """T2.2 (R5, AS11): derive_status receives (target_kind, target_id) positional."""
    from dashboard.server.routes import api as routes_api

    mock = MagicMock(return_value=IDLE_DEFAULT)
    monkeypatch.setattr(routes_api, "derive_status", mock)
    client.get("/api/autopilot/status?id=feat-x")
    assert mock.call_args[0] == ("autopilot", "feat-x")


def test_t2_3_chain_helper_call_args(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    """T2.3 (R5, AS11): /api/chain/status → mock called with ('chain', id)."""
    from dashboard.server.routes import api as routes_api

    mock = MagicMock(return_value=IDLE_DEFAULT)
    monkeypatch.setattr(routes_api, "derive_status", mock)
    client.get("/api/chain/status?id=feat-x")
    assert mock.call_args[0] == ("chain", "feat-x")


def test_t2_4_regex_rejection_does_not_call_helper(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T2.4 (R4, R5, R8, AS2): regex-rejected id never reaches the helper."""
    from dashboard.server.routes import api as routes_api

    mock = MagicMock(side_effect=RuntimeError("must not be called"))
    monkeypatch.setattr(routes_api, "derive_status", mock)
    response = client_html.get("/api/autopilot/status?id=bad%20id")
    assert response.status_code == 400
    assert mock.call_count == 0


def test_t2_5_pydantic_kind_rejection_does_not_call_helper(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T2.5 (R3, R8, AS3): bad target_kind never reaches the helper."""
    from dashboard.server.routes import api as routes_api

    mock = MagicMock(side_effect=RuntimeError("must not be called"))
    monkeypatch.setattr(routes_api, "derive_status", mock)
    response = client.get("/api/frobnicate/status?id=feat-x")
    assert response.status_code == 400
    assert mock.call_count == 0


def test_t2_6_empty_id_does_not_call_helper(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T2.6 (R4, R8, AS14): empty id rejected by Query before the helper."""
    from dashboard.server.routes import api as routes_api

    mock = MagicMock(side_effect=RuntimeError("must not be called"))
    monkeypatch.setattr(routes_api, "derive_status", mock)
    response = client.get("/api/autopilot/status?id=")
    assert response.status_code == 400
    assert mock.call_count == 0


def test_t2_7_route_wraps_helper_return_verbatim(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T2.7 (R5, R6, R-CON-3): handler emits helper return value byte-for-byte."""
    from dashboard.server.routes import api as routes_api

    fixed = {
        "status": "completed",
        "phase_at_pause": None,
        "last_phase_complete": "qa",
        "started_at": "2026-05-14T11:00:00Z",
        "tmux_session": "tmux-x",
    }
    monkeypatch.setattr(routes_api, "derive_status", MagicMock(return_value=fixed))
    response = client.get("/api/autopilot/status?id=feat-x")
    assert response.content == json.dumps(fixed).encode("utf-8")


# ---------------------------------------------------------------------------
# Group 3 — 400 / 4xx error paths (AS2, AS3, AS13-reject, AS14, E2, E3, E15)
# ---------------------------------------------------------------------------


def test_t3_1_regex_400_html_body_bytes(client_html: TestClient) -> None:
    """T3.1 (R4, R6, R7, AS2): bad-char id → 400 stdlib HTML body."""
    response = client_html.get("/api/autopilot/status?id=bad%20id")
    assert response.status_code == 400
    # The stdlib error_message_format template wraps the detail string as
    # ``<p>Message: %(message)s.</p>`` (trailing period is part of the template).
    assert b"Message: Invalid id parameter" in response.content
    assert b"<p>Error code: 400</p>" in response.content
    assert response.headers["content-type"] == "text/html;charset=utf-8"


@pytest.mark.parametrize("bad_id", ["feat.x", "feat/x", "feat x", "feat;rm"])
def test_t3_2_regex_400_parametrized(client_html: TestClient, bad_id: str) -> None:
    """T3.2 (R4, E2): each disallowed-char id → 400 stdlib HTML body."""
    response = client_html.get("/api/autopilot/status", params={"id": bad_id})
    assert response.status_code == 400
    assert b"Invalid id parameter" in response.content


def test_t3_3_dotdot_id_rejected_before_filesystem(
    client_html: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T3.3 (R4, E15): id='..' → regex rejection, no helper call."""
    from dashboard.server.routes import api as routes_api

    mock = MagicMock(side_effect=RuntimeError("must not be called"))
    monkeypatch.setattr(routes_api, "derive_status", mock)
    response = client_html.get("/api/autopilot/status?id=..")
    assert response.status_code == 400
    assert mock.call_count == 0


def test_t3_4_bad_target_kind_400_json_detail(client: TestClient) -> None:
    """T3.4 (R3, R7, AS3): unknown target_kind → 400 + {"detail":[...]}."""
    response = client.get("/api/frobnicate/status?id=feat-x")
    assert response.status_code == 400
    body = response.json()
    assert isinstance(body["detail"], list)
    assert "target_kind" in body["detail"][0]["loc"]
    assert body["detail"][0]["type"].startswith("literal_")


def test_t3_5_uppercase_target_kind_400(client: TestClient) -> None:
    """T3.5 (R3, E3): uppercase target_kind → 400 (case-sensitive Literal)."""
    response = client.get("/api/AUTOPILOT/status?id=feat-x")
    assert response.status_code == 400
    body = response.json()
    assert "target_kind" in body["detail"][0]["loc"]


def test_t3_6_empty_id_400_json_detail(client: TestClient) -> None:
    """T3.6 (R4, AS14): id='' → 400 (Query min_length=1 rejection)."""
    response = client.get("/api/autopilot/status?id=")
    assert response.status_code == 400
    body = response.json()
    assert "id" in body["detail"][0]["loc"]


def test_t3_7_id_too_long_65_chars_400(client: TestClient) -> None:
    """T3.7 (R4, AS13): 65-char id → 400 (Query max_length=64 rejection)."""
    response = client.get("/api/autopilot/status", params={"id": "a" * 65})
    assert response.status_code == 400
    body = response.json()
    assert "id" in body["detail"][0]["loc"]


def test_t3_8_missing_id_400(client: TestClient) -> None:
    """T3.8 (R4, AS14): missing ?id= entirely → 400 (Query required rejection)."""
    response = client.get("/api/autopilot/status")
    assert response.status_code == 400
    body = response.json()
    assert "id" in body["detail"][0]["loc"]


# ---------------------------------------------------------------------------
# Group 4 — Method / URL surface (AS6, AS7, E13)
# ---------------------------------------------------------------------------


def test_t4_1_post_returns_405(client: TestClient) -> None:
    """T4.1 (R10, AS7): POST → 405 with Allow header listing GET."""
    response = client.post("/api/autopilot/status?id=feat-x")
    assert response.status_code == 405
    assert "GET" in response.headers.get("allow", "")


@pytest.mark.parametrize("method", ["PUT", "PATCH", "DELETE"])
def test_t4_2_other_methods_405(client: TestClient, method: str) -> None:
    """T4.2 (R10): PUT/PATCH/DELETE → 405."""
    response = client.request(method, "/api/autopilot/status?id=feat-x")
    assert response.status_code == 405


def test_t4_3_head_and_options_405(client: TestClient) -> None:
    """T4.3 (R10): HEAD and OPTIONS both 405 in middleware-less FastAPI test app.

    TESTPLAN.md predicted FastAPI would auto-handle these — verified against
    FastAPI 0.x: without CORS middleware, only the declared GET handler is
    registered, so HEAD/OPTIONS hit the same 405 path as POST/PUT/PATCH/DELETE
    (T4.1/T4.2). The route adds no custom handler (R10).
    """
    head_resp = client.head("/api/autopilot/status?id=feat-x")
    assert head_resp.status_code == 405
    options_resp = client.options("/api/autopilot/status?id=feat-x")
    assert options_resp.status_code == 405


def test_t4_4_trailing_slash_redirects(client: TestClient) -> None:
    """T4.4 (R-CON-3, E13): trailing slash triggers Starlette's 307 redirect.

    No separate route is registered for the trailing-slash variant; the route
    body never executes — the framework rewrites the URL.
    """
    response = client.get("/api/autopilot/status/?id=feat-x", follow_redirects=False)
    assert response.status_code == 307
    assert response.headers["location"].endswith("/api/autopilot/status?id=feat-x")


def test_t4_5_no_origin_header_succeeds(client: TestClient, patched_root: Path) -> None:
    """T4.5 (R10, AS6): GET without Origin header → 200 (middleware-less test app)."""
    make_stream(patched_root, "autopilot", "feat-x")
    response = client.get("/api/autopilot/status?id=feat-x")
    assert response.status_code == 200


def test_t4_6_disallowed_origin_does_not_gate_get(client: TestClient, patched_root: Path) -> None:
    """T4.6 (R10, AS6): GET with disallowed Origin → 200 (no route-level gate)."""
    make_stream(patched_root, "autopilot", "feat-x")
    response = client.get(
        "/api/autopilot/status?id=feat-x",
        headers={"Origin": "http://example.com"},
    )
    assert response.status_code == 200


# ---------------------------------------------------------------------------
# Group 5 — Cross-validation / drift detection (AS10, AS15, Risk-5)
# ---------------------------------------------------------------------------


def test_t5_1_targetkind_literal_matches_helper_tuple() -> None:
    """T5.1 (R3, R12, AS10): get_args(_TargetKind) == status_helper.TARGET_KINDS."""
    from dashboard.server.routes.api import _TargetKind

    assert typing.get_args(_TargetKind) == status_helper.TARGET_KINDS


@pytest.mark.parametrize(
    "value",
    [
        "a",
        "a" * 64,
        "feat-x",
        "feat_x",
        "12345",
        "-abc-",
        "_abc_",
        "ABC",
    ],
)
def test_t5_2_positive_ids_accepted_by_both_layers(value: str) -> None:
    """T5.2 positive side (R-CON-2, AS15): id accepted by both route layers and helper regex."""
    from dashboard.server._serve_legacy import _RE_SAFE_ID

    assert 1 <= len(value) <= 64
    assert re.match(_RE_SAFE_ID, value)
    assert status_helper._TARGET_PATTERN.match(value)


@pytest.mark.parametrize(
    "value",
    [
        "",
        "a" * 65,
        "feat.x",
        "feat/x",
        "feat x",
        "feat;rm",
        "..",
    ],
)
def test_t5_2_negative_ids_rejected_by_at_least_one_layer(value: str) -> None:
    """T5.2 negative side (R-CON-2, AS15): bad id rejected by route bounds OR regex."""
    from dashboard.server._serve_legacy import _RE_SAFE_ID

    rejected_by_route = not (1 <= len(value) <= 64) or not re.match(_RE_SAFE_ID, value)
    rejected_by_helper = not status_helper._TARGET_PATTERN.match(value)
    assert rejected_by_route and rejected_by_helper


def test_t5_2_route_declares_query_bounds() -> None:
    """T5.2 introspect (R-CON-2): route declares Query(min_length=1, max_length=64)."""
    from fastapi.routing import APIRoute

    from dashboard.server.routes.api import router

    route = next(
        r
        for r in router.routes
        if isinstance(r, APIRoute) and r.path == "/api/{target_kind}/status"
    )
    # FastAPI stores per-route parameter info under .dependant.query_params
    query_params = {p.name: p for p in route.dependant.query_params}
    assert "target_id" in query_params
    field = query_params["target_id"].field_info
    # Pydantic v2 stores constraints in metadata; we inspect via repr or attr lookup
    assert getattr(field, "alias", None) == "id"
    metadata_str = str(getattr(field, "metadata", []))
    assert "min_length=1" in metadata_str
    assert "max_length=64" in metadata_str


def test_t5_3_handler_does_not_use_helper_internals() -> None:
    """T5.3 (R5): the api_session_status handler delegates state derivation to derive_status.

    Scoped to the handler body (not the whole module — autopilot_helpers
    legitimately imports `read_stream_incremental` for a different route).
    """
    from dashboard.server.routes.api import api_session_status

    body = inspect.getsource(api_session_status)
    forbidden = [
        "lifecycle_events.parse_event",
        "read_stream_incremental",
        "_resolve_stream_path",
        "_status_from_stream",
        "_apply_line",
        "_STATE_CACHE",
    ]
    for symbol in forbidden:
        assert symbol not in body, f"handler must not reference {symbol}"
    assert "derive_status(" in body


def test_t5_4_route_registered_once_with_get_method() -> None:
    """T5.4 (R1, R-OUT-1): one new GET route at /api/{target_kind}/status."""
    from fastapi.routing import APIRoute

    from dashboard.server.routes.api import router

    matching = [
        r
        for r in router.routes
        if isinstance(r, APIRoute) and r.path == "/api/{target_kind}/status"
    ]
    assert len(matching) == 1
    assert matching[0].methods == {"GET"}


@pytest.mark.parametrize(
    "value, should_accept",
    [
        ("a", True),
        ("a" * 64, True),
        ("feat-x", True),
        ("12345", True),
        ("", False),
        ("a" * 65, False),
        ("feat.x", False),
        ("feat/x", False),
    ],
)
def test_t5_5_featureid_pattern_matches_route_effective_set(
    value: str, should_accept: bool
) -> None:
    """T5.5 (R3, R-CON-1): schemas.FeatureId regex agrees with route's effective accepted set."""
    from dashboard.server._serve_legacy import _RE_SAFE_ID
    from dashboard.server.schemas import FeatureId

    feature_id_pattern = typing.get_args(FeatureId)[1].pattern
    feature_accept = bool(re.match(feature_id_pattern, value))
    route_accept = bool(re.match(_RE_SAFE_ID, value)) and 1 <= len(value) <= 64
    assert feature_accept == should_accept
    assert route_accept == should_accept


# ---------------------------------------------------------------------------
# Group 6 — Latency / performance (AS4, plan AC#3)
# ---------------------------------------------------------------------------


def test_t6_1_warm_cache_latency_under_200ms(
    large_stream: tuple[Path, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    """T6.1 (R9, AS4): 100 warm-cache polls on 40MB stream, p100 ≤ 200ms, p50 ≤ 50ms."""
    root, target_id = large_stream
    status_helper._reset_cache()
    monkeypatch.setattr(status_helper, "_PROJECTS_ROOT", root)
    client_local = TestClient(_make_app())

    # Cold-cache warm-up: one full read populates _STATE_CACHE
    warm_response = client_local.get(f"/api/autopilot/status?id={target_id}")
    assert warm_response.status_code == 200
    assert json.loads(warm_response.content)["status"] == "running"

    durations: list[float] = []
    for _ in range(100):
        t0 = time.perf_counter()
        response = client_local.get(f"/api/autopilot/status?id={target_id}")
        durations.append((time.perf_counter() - t0) * 1000.0)
        assert response.status_code == 200

    assert max(durations) <= 200.0, f"max {max(durations):.1f}ms exceeds 200ms"
    durations.sort()
    median = durations[len(durations) // 2]
    assert median <= 50.0, f"median {median:.1f}ms exceeds 50ms"


def test_t6_2_incremental_append_warm_path(
    large_stream: tuple[Path, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    """T6.2 (R9, AS4): one 256-byte append after warm-up → poll wall-time ≤ 50ms."""
    root, target_id = large_stream
    status_helper._reset_cache()
    monkeypatch.setattr(status_helper, "_PROJECTS_ROOT", root)
    client_local = TestClient(_make_app())

    # Warm up
    assert client_local.get(f"/api/autopilot/status?id={target_id}").status_code == 200

    # Append exactly one valid lifecycle event
    stream_path = _stream_path(root, "autopilot", target_id)
    append_event(
        stream_path,
        _evt(action="phase_complete", target=target_id, phase="ba"),
    )

    t0 = time.perf_counter()
    response = client_local.get(f"/api/autopilot/status?id={target_id}")
    duration_ms = (time.perf_counter() - t0) * 1000.0
    assert response.status_code == 200
    assert json.loads(response.content)["last_phase_complete"] == "ba"
    assert duration_ms <= 50.0, f"incremental-read wall time {duration_ms:.1f}ms exceeds 50ms"


# ---------------------------------------------------------------------------
# Group 7 — CLAUDE.md doc bullet (R-OUT-2)
# ---------------------------------------------------------------------------


def test_t7_1_claudemd_layout_bullet_present() -> None:
    """T7.1 (R-OUT-2): CLAUDE.md references routes/api.py + target_kind status route."""
    repo_root = Path(__file__).resolve().parents[2]
    text = (repo_root / "CLAUDE.md").read_text(encoding="utf-8").lower()
    assert "routes/api.py" in text
    assert "target_kind" in text and "status" in text


# ---------------------------------------------------------------------------
# Group 8 — No-change guards (R2, R-OUT-1)
# ---------------------------------------------------------------------------


def _git_diff_files(*paths: str) -> list[str] | None:
    """Return changed paths between merge-base and HEAD, or None if git unavailable."""
    try:
        out = subprocess.run(
            ["git", "diff", "main...HEAD", "--name-only", "--", *paths],
            check=True,
            capture_output=True,
            text=True,
            cwd=str(Path(__file__).resolve().parents[2]),
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    return [line for line in out.stdout.splitlines() if line]


# T8.1, T8.2, T8.3 (session-status-endpoint scope guards) removed when the
# feature shipped: each guard was bound to that feature's "PLAN § File-by-file"
# allowlist and is no longer a meaningful invariant once successor tasks
# (control-endpoints adds a router include in `app.py` per R-EXT-2;
# `status_helper.py` is consumed unchanged but the guard is structurally
# redundant). Per-feature scope guards expire on merge; keeping them forces
# every later branch to manually extend an obsolete list.
