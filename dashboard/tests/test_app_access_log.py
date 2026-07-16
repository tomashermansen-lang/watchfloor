"""Tests for AccessLogMiddleware + JSON formatter (ALM-01..ALM-08)."""

from __future__ import annotations

import json
import logging
from collections.abc import Iterator

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.responses import Response

from dashboard.server.app import (
    AccessLogMiddleware,
    _JsonAccessFormatter,
    app,
)

# ---------------------------------------------------------------------------
# Capture handler — records every emit on the dashboard.access logger.
# ---------------------------------------------------------------------------


class _CapturingHandler(logging.Handler):
    """Stores formatted records and the raw record objects."""

    def __init__(self) -> None:
        super().__init__()
        self.records: list[logging.LogRecord] = []
        self.lines: list[str] = []
        self.setFormatter(_JsonAccessFormatter())

    def emit(self, record: logging.LogRecord) -> None:  # noqa: D401
        self.records.append(record)
        self.lines.append(self.format(record))


@pytest.fixture()
def capture() -> Iterator[_CapturingHandler]:
    handler = _CapturingHandler()
    logger = logging.getLogger("dashboard.access")
    logger.addHandler(handler)
    try:
        yield handler
    finally:
        logger.removeHandler(handler)


@pytest.fixture()
def main_client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


# ---------------------------------------------------------------------------
# ALM-01..ALM-03 — happy path / 404 path on the real app
# ---------------------------------------------------------------------------


def test_alm01_one_record_per_request_with_expected_keys(capture, main_client):
    """ALM-01 (R5): one access record per request; JSON keys exact."""
    capture.records.clear()
    capture.lines.clear()
    main_client.get("/health")
    assert len(capture.records) == 1, (
        f"R5: exactly one access record expected, got {len(capture.records)}"
    )
    payload = json.loads(capture.lines[0])
    assert set(payload.keys()) == {"method", "path", "status", "duration_ms"}, (
        f"R5: log keys must be exactly {{method,path,status,duration_ms}}, got {payload.keys()}"
    )


def test_alm02_record_field_values_for_health(capture, main_client):
    """ALM-02 (R5): GET /health record values."""
    capture.records.clear()
    capture.lines.clear()
    main_client.get("/health")
    payload = json.loads(capture.lines[0])
    assert payload["method"] == "GET"
    assert payload["path"] == "/health"
    assert payload["status"] == 200
    assert isinstance(payload["duration_ms"], int)
    assert payload["duration_ms"] >= 0


def test_alm03_404_route(capture, main_client):
    """ALM-03 (R5, AS-4): unported /api/* → status 404 in log; one line.

    Uses /api/nope to hit the explicit /api/{rest:path} 404 catch-all
    (app.py:_compose_routes). A bare /nope would be absorbed by the SPA
    static mount and return 200 with index.html — that path tests SPA
    fallback, not the 404 log path.
    """
    capture.records.clear()
    capture.lines.clear()
    main_client.get("/api/nope")
    assert len(capture.records) == 1
    payload = json.loads(capture.lines[0])
    assert payload["status"] == 404
    assert payload["path"] == "/api/nope"
    assert payload["duration_ms"] >= 0


# ---------------------------------------------------------------------------
# ALM-04..ALM-06 — edge-case routes via a separate test app
# ---------------------------------------------------------------------------


def _build_test_app() -> FastAPI:
    """A minimal app that wires AccessLogMiddleware + extra error routes."""
    test_app = FastAPI()
    test_app.add_middleware(AccessLogMiddleware)

    @test_app.get("/empty")
    async def empty() -> Response:
        return Response(status_code=204)

    @test_app.get("/crash")
    async def crash() -> Response:  # pragma: no cover — body never returns
        raise RuntimeError("boom")

    return test_app


@pytest.fixture()
def test_app_client() -> Iterator[TestClient]:
    test_app = _build_test_app()
    with TestClient(test_app, raise_server_exceptions=False) as client:
        yield client


def test_alm04_non_ascii_path_lossless(capture, main_client):
    """ALM-04 (R5, EC-5.1): non-ASCII path round-trips through JSON losslessly."""
    capture.records.clear()
    capture.lines.clear()
    main_client.get("/health/ünicode")
    assert capture.lines, "R5: at least one access record expected"
    payload = json.loads(capture.lines[0])
    assert "ünicode" in payload["path"], (
        f"EC-5.1: path must round-trip losslessly, got {payload['path']!r}"
    )


def test_alm05_204_no_body_still_emits(capture, test_app_client):
    """ALM-05 (R5, EC-5.2): empty 204 response still emits an access log line."""
    capture.records.clear()
    capture.lines.clear()
    response = test_app_client.get("/empty")
    assert response.status_code == 204
    assert len(capture.records) == 1
    payload = json.loads(capture.lines[0])
    assert payload["status"] == 204


def test_alm06_handler_exception_logs_500(capture, test_app_client):
    """ALM-06 (R5, EC-5.3): handler RuntimeError → status=500 logged + propagates."""
    capture.records.clear()
    capture.lines.clear()
    response = test_app_client.get("/crash")
    # raise_server_exceptions=False → TestClient surfaces 500 instead of raising.
    assert response.status_code == 500
    assert len(capture.records) == 1
    payload = json.loads(capture.lines[0])
    assert payload["status"] == 500
    assert payload["path"] == "/crash"
    assert payload["duration_ms"] >= 0


# ---------------------------------------------------------------------------
# ALM-07..ALM-08 — formatter unit tests
# ---------------------------------------------------------------------------


def test_alm07_formatter_returns_single_json_object():
    """ALM-07 (R5): _JsonAccessFormatter.format() returns a single JSON object."""
    formatter = _JsonAccessFormatter()
    record = logging.LogRecord(
        name="dashboard.access",
        level=logging.INFO,
        pathname=__file__,
        lineno=0,
        msg="",
        args=(),
        exc_info=None,
    )
    record.method = "GET"
    record.path = "/x"
    record.status = 200
    record.duration_ms = 0
    line = formatter.format(record)
    payload = json.loads(line)
    assert payload == {"method": "GET", "path": "/x", "status": 200, "duration_ms": 0}
    assert "\n" not in line, "R5: formatter must not embed newlines mid-string"


def test_alm08_sub_millisecond_rounds_to_zero(monkeypatch, capture, main_client):
    """ALM-08 (R5): sub-ms responses produce duration_ms == 0 (not None, not negative)."""
    capture.records.clear()
    capture.lines.clear()
    # Force perf_counter to return identical values → elapsed == 0.
    monkeypatch.setattr("dashboard.server.app.time.perf_counter", lambda: 1.0)
    main_client.get("/health")
    payload = json.loads(capture.lines[0])
    assert payload["duration_ms"] == 0
