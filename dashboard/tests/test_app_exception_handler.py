"""Tests for ``dashboard.server._exception_handlers`` (R10, OQ#1, OQ#5).

Loads the four committed Eval-4 fixtures from
``dashboard/tests/fixtures/error-templates/{400,403,404,500}.html`` and
asserts that ``html_4xx_handler`` produces those bytes for known-input
``HTTPException`` instances. Also verifies the XSS escape (T-EH-5),
unmapped-status fallback (T-EH-6), Content-Type byte parity (T-EH-7),
trailing newline (T-EH-8), unhandled-exception 500 path (T-EH-9),
passive-200 isolation (T-EH-10), empty-detail fallback (T-EH-11), and
template-re-read protection (T-EH-12 / Risk-A).
"""

from __future__ import annotations

import asyncio
from http.server import BaseHTTPRequestHandler
from pathlib import Path

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.requests import Request

from dashboard.server._exception_handlers import (
    _FALLBACK_RESPONSE,
    _HTML_CONTENT_TYPE,
    _render_html_body,
    html_4xx_handler,
    html_500_handler,
)

_FIXTURE_DIR = Path(__file__).parent / "fixtures" / "error-templates"


def _synthetic_request() -> Request:
    """Build a minimal Starlette ``Request`` for direct handler invocation."""
    scope = {
        "type": "http",
        "method": "GET",
        "path": "/test",
        "headers": [],
        "query_string": b"",
    }
    return Request(scope)


def _call(handler, exc: Exception):
    return asyncio.run(handler(_synthetic_request(), exc))


# ---------------------------------------------------------------------------
# T-EH-1 .. T-EH-4 — body bytes match committed fixtures
# ---------------------------------------------------------------------------


def test_t_eh_1_400_body_matches_fixture() -> None:
    """T-EH-1 (R10): HTTPException(400, 'Missing task parameter') → 400.html bytes."""
    expected = (_FIXTURE_DIR / "400.html").read_bytes()
    response = _call(html_4xx_handler, HTTPException(400, "Missing task parameter"))
    assert response.body == expected
    assert response.status_code == 400


def test_t_eh_2_403_body_matches_fixture() -> None:
    """T-EH-2 (R10, EC-10.1): HTTPException(403, 'Forbidden') → 403.html bytes."""
    expected = (_FIXTURE_DIR / "403.html").read_bytes()
    response = _call(html_4xx_handler, HTTPException(403, "Forbidden"))
    assert response.body == expected
    assert response.status_code == 403
    assert b"Request forbidden -- authorization will not help" in response.body


def test_t_eh_3_404_body_matches_fixture() -> None:
    """T-EH-3 (R10): HTTPException(404, 'Log file not found') → 404.html bytes."""
    expected = (_FIXTURE_DIR / "404.html").read_bytes()
    response = _call(html_4xx_handler, HTTPException(404, "Log file not found"))
    assert response.body == expected
    assert response.status_code == 404
    assert b"Nothing matches the given URI" in response.body


def test_t_eh_4_500_body_matches_fixture() -> None:
    """T-EH-4 (R10): HTTPException(500, 'Error reading artifact') → 500.html bytes."""
    expected = (_FIXTURE_DIR / "500.html").read_bytes()
    response = _call(html_4xx_handler, HTTPException(500, "Error reading artifact"))
    assert response.body == expected
    assert response.status_code == 500
    assert b"Server got itself in trouble" in response.body


# ---------------------------------------------------------------------------
# T-EH-5 — XSS escape (EC-10.4)
# ---------------------------------------------------------------------------


def test_t_eh_5_xss_message_is_html_escaped() -> None:
    """T-EH-5 (R10, EC-10.4): a ``<script>`` detail is HTML-escaped."""
    response = _call(html_4xx_handler, HTTPException(400, "<script>alert(1)</script>"))
    body = response.body
    assert b"&lt;script&gt;alert(1)&lt;/script&gt;" in body
    assert b"<script>" not in body
    assert b"</script>" not in body


# ---------------------------------------------------------------------------
# T-EH-6 — unmapped status falls back to ('???', '???') (EC-10.5)
# ---------------------------------------------------------------------------


def test_t_eh_6_unmapped_status_uses_fallback() -> None:
    """T-EH-6 (R10, EC-10.5): code 599 (no stdlib mapping) → '???' fallback.

    599 is chosen over 418 because Python 3.12+ MAPS 418 in
    ``BaseHTTPRequestHandler.responses`` and would not exercise the
    fallback branch (TESTPLAN.md § C2 documents the rationale).
    """
    assert 599 not in BaseHTTPRequestHandler.responses, (
        "T-EH-6 assumption broken: 599 became mapped"
    )
    response = _call(html_4xx_handler, HTTPException(599, "Custom code"))
    assert response.status_code == 599
    assert b"<p>Error code explanation: 599 - ???.</p>" in response.body
    assert _FALLBACK_RESPONSE == ("???", "???")


# ---------------------------------------------------------------------------
# T-EH-7 — Content-Type byte parity (no space between ; and charset)
# ---------------------------------------------------------------------------


def test_t_eh_7_content_type_has_no_space_before_charset() -> None:
    """T-EH-7 (R10): Content-Type is ``text/html;charset=utf-8`` (NO space)."""
    response = _call(html_4xx_handler, HTTPException(400, "x"))
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert _HTML_CONTENT_TYPE == "text/html;charset=utf-8"


# ---------------------------------------------------------------------------
# T-EH-8 — trailing newline preserved
# ---------------------------------------------------------------------------


def test_t_eh_8_body_ends_with_html_newline() -> None:
    """T-EH-8 (R10): every body ends with ``</html>\\n`` (single UTF-8 newline)."""
    response = _call(html_4xx_handler, HTTPException(400, "x"))
    assert response.body.endswith(b"</html>\n")


# ---------------------------------------------------------------------------
# T-EH-9 — html_500_handler renders bare exceptions
# ---------------------------------------------------------------------------


def test_t_eh_9_html_500_handler_renders_internal_server_error() -> None:
    """T-EH-9 (R10, OQ#5): bare RuntimeError → 500 with HTML body."""
    response = _call(html_500_handler, RuntimeError("boom"))
    assert response.status_code == 500
    assert b"<p>Message: Internal Server Error.</p>" in response.body
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert response.body.endswith(b"</html>\n")


# ---------------------------------------------------------------------------
# T-EH-10 — passive 200 paths are unaffected by the 4xx handler
# ---------------------------------------------------------------------------


def test_t_eh_10_200_route_unaffected_by_handler() -> None:
    """T-EH-10 (R10, EC-10.2): a 200 response retains its JSON Content-Type."""
    test_app = FastAPI()
    test_app.add_exception_handler(StarletteHTTPException, html_4xx_handler)
    test_app.add_exception_handler(Exception, html_500_handler)

    @test_app.get("/healthz")
    async def _healthz() -> dict[str, str]:
        return {"ok": "yes"}

    client = TestClient(test_app)
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.headers["content-type"] == "application/json"


# ---------------------------------------------------------------------------
# T-EH-11 — empty detail falls back to shortmsg
# ---------------------------------------------------------------------------


def test_t_eh_11_empty_detail_uses_shortmsg() -> None:
    """T-EH-11 (R10): HTTPException(400, '') → body uses 'Bad Request' shortmsg."""
    response = _call(html_4xx_handler, HTTPException(400, ""))
    assert b"<p>Message: Bad Request.</p>" in response.body


# ---------------------------------------------------------------------------
# T-EH-12 — template re-read at request time (Risk-A)
# ---------------------------------------------------------------------------


def test_t_eh_12_template_is_read_at_request_time(monkeypatch: pytest.MonkeyPatch) -> None:
    """T-EH-12 (R10, Risk-A): handler reads ``error_message_format`` per call.

    Monkeypatching ``BaseHTTPRequestHandler.error_message_format`` mid-test
    must change the rendered body — proving the template is NOT snapshotted
    at module-import time. Protects against a future Python upgrade silently
    drifting the template.
    """
    monkeypatch.setattr(BaseHTTPRequestHandler, "error_message_format", "STUB:%(code)d:%(message)s")
    body = _render_html_body(404, "msg")
    assert body == b"STUB:404:msg"


# ---------------------------------------------------------------------------
# Round-trip via _render_html_body for the four fixture cases — direct test
# of the template substitution before the handler wraps it in a Response.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("code", "message"),
    [
        (400, "Missing task parameter"),
        (403, "Forbidden"),
        (404, "Log file not found"),
        (500, "Error reading artifact"),
    ],
)
def test_render_html_body_matches_fixture(code: int, message: str) -> None:
    """``_render_html_body`` output equals the committed fixture bytes."""
    expected = (_FIXTURE_DIR / f"{code}.html").read_bytes()
    assert _render_html_body(code, message) == expected
