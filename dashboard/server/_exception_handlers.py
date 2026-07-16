"""Stdlib-equivalent HTML 4xx/5xx exception handlers (R10, OQ#1, OQ#5).

Reproduces the body bytes and Content-Type that
``http.server.BaseHTTPRequestHandler.send_error`` emits, so the FastAPI
port stays byte-equivalent with the captured baseline fixtures.

The template is read from the running interpreter's stdlib at request
time (``BaseHTTPRequestHandler.error_message_format``), not snapshotted
at import — so a future Python release that changes the template is
caught by the byte-equivalence harness on first run rather than masked
by a frozen copy in source.
"""

from __future__ import annotations

import html
from http.server import BaseHTTPRequestHandler
from typing import Final

from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.requests import Request
from starlette.responses import Response

# "text/html;charset=utf-8" — note the absence of a space between ';' and
# 'charset' (contrast with JSON's "application/json; charset=utf-8" which
# DOES have a space). Load-bearing for byte-level parity with stdlib.
_HTML_CONTENT_TYPE: Final[str] = BaseHTTPRequestHandler.error_content_type

# Fallback (shortmsg, longmsg) when the status code is not in
# ``BaseHTTPRequestHandler.responses`` — mirrors the stdlib ``send_error``
# defensive default (EC-10.5).
_FALLBACK_RESPONSE: Final[tuple[str, str]] = ("???", "???")


def _resolve_status_phrases(status_code: int) -> tuple[str, str]:
    """Return ``(shortmsg, longmsg)`` for ``status_code`` or the fallback."""
    return BaseHTTPRequestHandler.responses.get(status_code, _FALLBACK_RESPONSE)


def _render_html_body(status_code: int, message: str) -> bytes:
    """Render ``error_message_format`` for ``status_code`` / ``message``.

    Reads ``error_message_format`` from the running interpreter so a future
    Python release that updates the template propagates to the FastAPI
    handler automatically (Risk-A mitigation). HTML-escapes the message via
    ``html.escape(quote=False)`` mirroring stdlib ``send_error`` (EC-10.4).
    """
    shortmsg, longmsg = _resolve_status_phrases(status_code)
    safe_message = html.escape(message, quote=False) if message else shortmsg
    body = BaseHTTPRequestHandler.error_message_format % {
        "code": status_code,
        "message": safe_message,
        "explain": longmsg,
    }
    return body.encode("utf-8")


async def html_4xx_handler(_request: Request, exc: Exception) -> Response:
    """R10: render Starlette ``HTTPException`` as stdlib HTML body bytes.

    Registered on ``StarletteHTTPException`` (which ``fastapi.HTTPException``
    subclasses) so every 4xx raised in the FastAPI app emits the byte-
    equivalent stdlib template instead of FastAPI's default JSON ``{"detail":
    ...}`` body.
    """
    if not isinstance(exc, StarletteHTTPException):
        raise exc
    detail_str = exc.detail if isinstance(exc.detail, str) and exc.detail else ""
    return Response(
        content=_render_html_body(exc.status_code, detail_str),
        status_code=exc.status_code,
        media_type=_HTML_CONTENT_TYPE,
    )


async def html_500_handler(_request: Request, _exc: Exception) -> Response:
    """OQ#5: render unhandled exceptions as stdlib HTML 500.

    Stdlib ``BaseHTTPRequestHandler`` converts every unhandled exception to
    HTML 500 via its ``handle_one_request`` exception path; without this
    handler, FastAPI would emit ``{"detail":"Internal Server Error"}`` JSON
    — visually inconsistent with every other 4xx in the app.
    """
    return Response(
        content=_render_html_body(500, "Internal Server Error"),
        status_code=500,
        media_type=_HTML_CONTENT_TYPE,
    )
