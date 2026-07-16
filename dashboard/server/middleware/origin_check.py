"""Pure-ASGI Origin allowlist middleware (fastapi-origin-and-schemas).

Pure-ASGI because Starlette's `BaseHTTPMiddleware` does not see
websocket scopes; only raw ASGI can reject an upgrade before it
completes (R21). Audit-log writer here is a symmetric duplicate of
`csrf.py:_write_audit_entry`; extraction tracked as
RS-fastapi-origin-and-schemas-001 (SD-1).
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys
from collections.abc import Iterable
from datetime import UTC, datetime
from typing import Literal

from starlette.types import ASGIApp, Receive, Scope, Send

# R22: _AUDIT_PATH lives in csrf.py — both writers share one Path object.
from dashboard.server.middleware.csrf import _AUDIT_PATH

_ENV_VAR = "DASHBOARD_ALLOWED_ORIGINS"
# controls-06 #9 — when DASHBOARD_ALLOWED_ORIGINS is unset, any
# loopback origin (127.0.0.1 or localhost on any port, http or
# https) is accepted. The kernel-level sandbox restricts the
# server to a 127.0.0.1 bind (CLAUDE.md `## Security Rules`), so
# the only browser that can fetch the dashboard from the loopback
# interface is the operator's own browser on this machine.
# Hardcoding a finite list of ports (the cycle-5 default of
# `{127.0.0.1:8787, 127.0.0.1:5175}`) excluded `localhost:*` and
# the operator's other local projects (OIH 8100/5174, Eulex
# 8200/5173, etc.) for no security gain.
# When the operator sets the env var, the exact list replaces the
# loopback-permissive default — locking the dashboard to specific
# named origins when a tighter posture is preferred.
_DEFAULT_ORIGINS: frozenset[str] = frozenset()

# Matches `http(s)://127.0.0.1` and `http(s)://localhost`, with an
# optional `:PORT` (one to five decimal digits, no leading zero
# enforcement — the browser parses ports the same way). Trailing
# slash, path, query, fragment, userinfo all REJECTED so a crafted
# origin like `http://localhost:5175/../evil` cannot pass the
# loopback predicate.
_LOOPBACK_ORIGIN_RE: re.Pattern[str] = re.compile(
    r"^https?://(?:127\.0\.0\.1|localhost)(?::\d{1,5})?$"
)
_UNSAFE_METHODS: frozenset[str] = frozenset({"POST", "PUT", "PATCH", "DELETE"})
_REJECT_BODY: bytes = b'{"error":"origin"}'
_REJECT_HEADERS: list[tuple[bytes, bytes]] = [
    (b"content-type", b"application/json"),
]
_STARTUP_LOG_EVENT = "origin_allowlist_loaded"
_AUDIT_EVENT = "origin_violation"

_Reason = Literal["disallowed", "missing"]
_audit_logger = logging.getLogger("dashboard.access")


def _parse_allowlist(raw: str | None) -> frozenset[str]:
    if raw is None or raw.strip() == "":
        return _DEFAULT_ORIGINS
    # EC-2: case-sensitive byte equality; parse keeps raw bytes verbatim.
    return frozenset(item.strip() for item in raw.split(",") if item.strip())


def _is_loopback_origin(origin: str) -> bool:
    """Match an Origin string against the loopback interface predicate.

    True iff `origin` is exactly `http(s)://127.0.0.1[:PORT]` or
    `http(s)://localhost[:PORT]` with no path, query, or fragment.
    Used when no explicit allowlist is configured (controls-06 #9).
    """
    return _LOOPBACK_ORIGIN_RE.fullmatch(origin) is not None


def _extract_origin(headers: Iterable[tuple[bytes, bytes]]) -> str | None:
    # EC-4: first Origin header wins.
    for name, value in headers:
        if name == b"origin":
            return value.decode("latin-1")
    return None


def _remote_addr(scope: Scope) -> str:
    # R7: "unknown" is a diagnostic tripwire — proxy stripped client info.
    client = scope.get("client")
    if not client:
        return "unknown"
    try:
        return client[0] or "unknown"
    except (IndexError, TypeError):
        return "unknown"


def _classify(origin: str | None) -> _Reason | None:
    if not origin:
        return "missing"
    if origin in _ALLOWED_ORIGINS:
        return None
    # controls-06 #9 — loopback-permissive default: when the operator
    # has NOT set DASHBOARD_ALLOWED_ORIGINS, any loopback origin is
    # accepted regardless of port. Explicit allowlist takes
    # precedence (line above) so the operator can still lock down.
    if _ALLOW_LOOPBACK_DEFAULT and _is_loopback_origin(origin):
        return None
    return "disallowed"


def _write_origin_audit_entry(reason: _Reason, method: str, path: str, remote_addr: str) -> None:
    payload = {
        "ts": datetime.now(UTC).isoformat(),
        "event": _AUDIT_EVENT,
        "method": method,
        "path": path,
        "reason": reason,
        "remote_addr": remote_addr,
    }
    line = json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n"
    try:
        _AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
        # pre-open existence check is TOCTOU-safe under single-process
        # uvicorn (R15); switch to O_CREAT|O_EXCL if --workers is enabled.
        file_existed_before = _AUDIT_PATH.exists()
        with open(_AUDIT_PATH, "a", encoding="utf-8") as fh:
            fh.write(line)
        if not file_existed_before:
            os.chmod(_AUDIT_PATH, 0o600)
    except OSError as exc:
        # Log-and-continue: the 403 is already decided. Suppressing the
        # response on audit failure would turn a data-dir RO flip into a
        # DoS lever; audit is observability, not the auth boundary.
        _audit_logger.warning("origin_audit_write_failed: %s (%s)", _AUDIT_PATH, exc)


async def _send_403(scope_type: str, send: Send) -> None:
    # ASGI HTTP-rejection-on-WebSocket: uvicorn 0.46+ raises RuntimeError
    # if a websocket scope receives the bare `http.response.*` event
    # family. The websocket scope must use `websocket.http.response.*`
    # (ASGI spec §HTTP response, supported by uvicorn since 0.30). The
    # earlier "uvicorn closes the TCP connection" assumption no longer
    # holds — instead the client got no bytes because the asgi_send
    # call raised and the connection was torn down with no headers.
    if scope_type == "websocket":
        start_type = "websocket.http.response.start"
        body_type = "websocket.http.response.body"
    else:
        start_type = "http.response.start"
        body_type = "http.response.body"
    await send({"type": start_type, "status": 403, "headers": _REJECT_HEADERS})
    await send({"type": body_type, "body": _REJECT_BODY, "more_body": False})


class OriginMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self._app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        scope_type = scope["type"]
        if scope_type == "http":
            method = scope.get("method", "").upper()
            if method not in _UNSAFE_METHODS:
                await self._app(scope, receive, send)
                return
            audit_method = method
        elif scope_type == "websocket":
            audit_method = "WS"
        elif scope_type == "lifespan":
            await self._app(scope, receive, send)
            return
        else:
            # Unknown scope type — tripwire log, pass-through so a future
            # ASGI extension's startup-like events do not silently brick.
            _audit_logger.warning(
                "unknown_scope_type: %s",
                scope_type,
                extra={"event": "unknown_scope_type"},
            )
            await self._app(scope, receive, send)
            return

        reason = _classify(_extract_origin(scope.get("headers", ())))
        if reason is None:
            await self._app(scope, receive, send)
            return
        _write_origin_audit_entry(
            reason=reason,
            method=audit_method,
            path=scope.get("path", ""),
            remote_addr=_remote_addr(scope),
        )
        await _send_403(scope_type, send)


_env_raw = os.environ.get(_ENV_VAR)
_ALLOWED_ORIGINS: frozenset[str] = _parse_allowlist(_env_raw)
# controls-06 #9 — loopback-permissive default fires ONLY when the
# operator left the env var unset or empty. When the operator sets
# DASHBOARD_ALLOWED_ORIGINS the literal list is the WHOLE contract;
# loopback shortcuts would silently undo a tighter posture.
_ALLOW_LOOPBACK_DEFAULT: bool = _env_raw is None or _env_raw.strip() == ""

# AS-5: print to stderr (not _audit_logger.info) because dashboard.access
# logger handlers are not configured until app.py:_configure_logging
# runs AFTER this module's body. Logger-based emit would be a no-op.
_log_detail = (
    "loopback-permissive (no env override)"
    if _ALLOW_LOOPBACK_DEFAULT
    else f"explicit: {','.join(sorted(_ALLOWED_ORIGINS))}"
)
print(
    f"origin_allowlist_loaded: {_log_detail}",
    file=sys.stderr,
)
