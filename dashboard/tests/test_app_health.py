"""Tests for HealthResponse + /health endpoint (HEP-* / HRM-* / APP-*)."""

from __future__ import annotations

import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from importlib.metadata import PackageNotFoundError

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import ValidationError

from dashboard.server.app import (
    HealthResponse,
    _resolve_version,
    app,
)

ISO_8601_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")


# ---------------------------------------------------------------------------
# APP-01..APP-04 — module bootstrap + version resolution
# ---------------------------------------------------------------------------


def test_app01_module_app_is_fastapi():
    """APP-01 (R3): `app` is a FastAPI instance."""
    assert isinstance(app, FastAPI), "R3: dashboard.server.app.app must be FastAPI"


def test_app02_app_title_and_version():
    """APP-02 (R3): app.title is the documented value; app.version is non-empty."""
    assert app.title == "Claude Agent Dashboard"
    assert isinstance(app.version, str)
    assert app.version, "app.version must be non-empty (or 'unknown' fallback)"


def test_app03_resolve_version_returns_str():
    """APP-03 (R4): _resolve_version() returns a non-empty string."""
    result = _resolve_version()
    assert isinstance(result, str) and result, (
        f"R4: _resolve_version() must return a non-empty str, got {result!r}"
    )


def test_app04_resolve_version_fallback_on_missing_metadata(monkeypatch):
    """APP-04 (R4, EC-4.1): fallback to literal 'unknown' on PackageNotFoundError."""

    def _raise(_name):  # noqa: ARG001 — signature must accept the name
        raise PackageNotFoundError("dashboard")

    monkeypatch.setattr("dashboard.server.app._pkg_version", _raise)
    assert _resolve_version() == "unknown"


# ---------------------------------------------------------------------------
# HRM-01..HRM-04 — HealthResponse pydantic contract
# ---------------------------------------------------------------------------


def test_hrm01_health_response_constructs():
    """HRM-01 (R4): HealthResponse(status='ok', version=..., ts=...) constructs."""
    instance = HealthResponse(status="ok", version="0.1.0", ts="2026-05-06T13:00:00+00:00")
    assert instance.status == "ok"
    assert instance.version == "0.1.0"
    assert instance.ts == "2026-05-06T13:00:00+00:00"


def test_hrm02_health_response_rejects_non_ok_status():
    """HRM-02 (R4): non-'ok' status MUST raise ValidationError (Literal['ok'])."""
    with pytest.raises(ValidationError):
        HealthResponse(status="degraded", version="x", ts="x")  # type: ignore[arg-type]


def test_hrm03_health_response_fields_exact():
    """HRM-03 (R4): model_fields keys are exactly {status, version, ts}."""
    keys = set(HealthResponse.model_fields.keys())
    assert keys == {"status", "version", "ts"}, (
        f"R4: HealthResponse fields must be exactly {{status, version, ts}}, got {keys}"
    )


def test_hrm04_health_response_dump_keys_only():
    """HRM-04 (R4): model_dump returns exactly the three declared keys."""
    instance = HealthResponse(status="ok", version="0.1.0", ts="x")
    dumped = instance.model_dump()
    assert set(dumped.keys()) == {"status", "version", "ts"}


# ---------------------------------------------------------------------------
# HEP-01..HEP-10 — /health TestClient assertions
# ---------------------------------------------------------------------------


@pytest.fixture()
def client() -> TestClient:
    return TestClient(app)


def test_hep01_get_health_status_200_and_body_keys(client):
    """HEP-01 (R3, R4): GET /health → 200 with body keys exactly {status,version,ts}."""
    response = client.get("/health")
    assert response.status_code == 200, "R3: /health must return 200"
    body = response.json()
    assert set(body.keys()) == {"status", "version", "ts"}, (
        f"R4: body keys must be exactly {{status,version,ts}} (no extras), got {body!r}"
    )


def test_hep02_status_literal_ok(client):
    """HEP-02 (R4): body.status == 'ok'."""
    body = client.get("/health").json()
    assert body["status"] == "ok"


def test_hep03_version_non_empty(client):
    """HEP-03 (R4): body.version is non-empty string (may be 'unknown' fallback)."""
    body = client.get("/health").json()
    assert isinstance(body["version"], str)
    assert body["version"], "R4: body.version must be non-empty"


def test_hep04_ts_iso8601_with_tzinfo(client):
    """HEP-04 (R4): body.ts matches ISO 8601 regex AND has tzinfo (kills RSK-PLAN-2)."""
    body = client.get("/health").json()
    assert ISO_8601_RE.match(body["ts"]), (
        f"R4: body.ts must match ISO 8601 with tz, got {body['ts']!r}"
    )
    parsed = datetime.fromisoformat(body["ts"])
    assert parsed.tzinfo is not None, "R4: body.ts MUST have tzinfo set (no naive timestamps)"


def _csrf_token(client: TestClient) -> str:
    # Acquire a CSRF cookie via the first GET so subsequent unsafe-method
    # requests reach their handler instead of being short-circuited by
    # CSRFMiddleware. TestClient's cookie jar auto-attaches the cookie on
    # follow-up requests; we only need to thread the value through the
    # X-CSRF-Token header.
    response = client.get("/health")
    assert response.status_code == 200, (
        f"CSRF preflight GET /health failed: status={response.status_code}; "
        "without this assert a downstream KeyError on cookies['csrf_token'] "
        "would mask the real cause."
    )
    return client.cookies["csrf_token"]


def test_hep05_post_health_405(client):
    """HEP-05 (R4, EC-4.4): POST /health → 405 Method Not Allowed."""
    token = _csrf_token(client)
    assert (
        client.post(
            "/health", headers={"X-CSRF-Token": token, "Origin": "http://127.0.0.1:8787"}
        ).status_code
        == 405
    )


def test_hep06_put_health_405(client):
    """HEP-06 (R4, EC-4.4): PUT /health → 405."""
    token = _csrf_token(client)
    assert (
        client.put(
            "/health", headers={"X-CSRF-Token": token, "Origin": "http://127.0.0.1:8787"}
        ).status_code
        == 405
    )


def test_hep07_delete_health_405(client):
    """HEP-07 (R4, EC-4.4): DELETE /health → 405."""
    token = _csrf_token(client)
    assert (
        client.delete(
            "/health", headers={"X-CSRF-Token": token, "Origin": "http://127.0.0.1:8787"}
        ).status_code
        == 405
    )


def test_hep08_pre_1970_timestamp(client, monkeypatch):
    """HEP-08 (R4, EC-4.2): pre-1970 system clock still produces ISO 8601 with tz."""

    class _FrozenDateTime(datetime):
        @classmethod
        def now(cls, tz=None):  # type: ignore[override]
            base = datetime(1969, 12, 31, 23, 59, 59, 123456, tzinfo=tz)
            return base

    monkeypatch.setattr("dashboard.server.app.datetime", _FrozenDateTime)
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert ISO_8601_RE.match(body["ts"]), body["ts"]
    parsed = datetime.fromisoformat(body["ts"])
    assert parsed.tzinfo is not None


def test_hep09_concurrent_burst_all_200(client):
    """HEP-09 (R4, EC-4.3): 32 concurrent /health calls all return 200."""
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(client.get, "/health") for _ in range(32)]
        results = [f.result() for f in as_completed(futures)]
    statuses = [r.status_code for r in results]
    assert all(s == 200 for s in statuses), (
        f"R4, EC-4.3: all 32 concurrent calls must return 200, got {set(statuses)}"
    )
    for r in results:
        body = r.json()
        assert set(body.keys()) == {"status", "version", "ts"}


def test_hep10_unknown_version_path(client, monkeypatch):
    """HEP-10 (R4): when _resolve_version → 'unknown', body.version is 'unknown' and 200."""
    monkeypatch.setattr("dashboard.server.app._resolve_version", lambda: "unknown")
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["version"] == "unknown"
