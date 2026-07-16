"""Double-submit CSRF middleware (fastapi-csrf-middleware).

EC-13: the ``csrf_token`` cookie name is owned by this middleware; any
future cookie-emitting middleware must pick a distinct name. The
audit-log writer (``_write_audit_entry``) stays here until
``fastapi-origin-and-schemas`` adds a second writer.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

_COOKIE_NAME = "csrf_token"
_HEADER_NAME = "X-CSRF-Token"
_AUDIT_FILENAME = "audit.ndjson"
_REJECT_BODY: dict[str, str] = {"error": "csrf"}
_SAFE_METHODS: frozenset[str] = frozenset({"GET", "HEAD", "OPTIONS"})
_COOKIE_ISSUE_METHODS: frozenset[str] = frozenset({"GET"})
# controls-07 #8 — loopback hosts skip CSRF. Origin allowlist (cycle-9
# loopback-permissive) already blocks cross-site fetch; cookie-based
# double-submit adds zero security in the localhost-bound trust model
# and breaks on Safari's known WS-cookie bug. A future 0.0.0.0 bind or
# reverse-proxy deploy keeps full CSRF enforcement automatically.
_LOOPBACK_HOSTS: frozenset[str] = frozenset({"127.0.0.1", "::1"})

_Reason = Literal["missing_header", "missing_cookie", "mismatch"]


def _is_loopback_client(host: str | None) -> bool:
    """Return True iff `host` is an IPv4/IPv6 loopback literal.

    Exact match only — no DNS, no parsing tolerance. `localhost` is a
    name not an address; by the time the request reaches the middleware
    Starlette has resolved it to `127.0.0.1` (or `::1`) in scope.client.
    """
    return host in _LOOPBACK_HOSTS


def _resolve_audit_path() -> Path:
    # R8: honour DASHBOARD_DATA_DIR override; fall back to
    # <repo>/dashboard/data/audit.ndjson via parents[2].
    override = os.environ.get("DASHBOARD_DATA_DIR")
    if override:
        return Path(override) / _AUDIT_FILENAME
    return Path(__file__).resolve().parents[2] / "data" / _AUDIT_FILENAME


_AUDIT_PATH = _resolve_audit_path()
_audit_logger = logging.getLogger("dashboard.access")


def _generate_token() -> str:
    # EC-6: the literal 32 is pinned here. Shrinking the entropy budget
    # is caught by the T-5 grep regression test.
    return secrets.token_urlsafe(32)


def _classify(cookie: str, header: str) -> _Reason | None:
    if not cookie:
        return "missing_cookie"
    if not header:
        return "missing_header"
    # Non-ASCII bytes in either value raise TypeError; treat as mismatch (fail-closed).
    try:
        if not secrets.compare_digest(cookie, header):
            return "mismatch"
    except TypeError:
        return "mismatch"
    return None


def _remote_addr(request: Request) -> str:
    # R7: "unknown" is a diagnostic tripwire — proxy stripped client info.
    # Do NOT replace with None/"".
    client = getattr(request, "client", None)
    if client is None:
        _audit_logger.debug("csrf_request_client_none")
        return "unknown"
    host = getattr(client, "host", None)
    return host or "unknown"


# TODO(fastapi-origin-and-schemas): extract to _audit_log.py when second writer lands
def _write_audit_entry(reason: _Reason, method: str, path: str, remote_addr: str) -> None:
    payload = {
        "ts": datetime.now(UTC).isoformat(),
        "event": "csrf_violation",
        "method": method.upper(),
        "path": path,
        "reason": reason,
        "remote_addr": remote_addr,
    }
    line = json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n"
    try:
        _AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
        file_existed_before = _AUDIT_PATH.exists()
        with open(_AUDIT_PATH, "a", encoding="utf-8") as fh:
            fh.write(line)
        # pre-open existence check is TOCTOU-safe under single-process uvicorn
        # (R15); switch to O_CREAT|O_EXCL if --workers is enabled.
        if not file_existed_before:
            os.chmod(_AUDIT_PATH, 0o600)
    except OSError as exc:
        # Log-and-continue (not fail-shut): the security decision (403) is already
        # made; suppressing the response on audit failure would let a data-dir RO
        # flip become a DoS lever. Audit-log write is observability, not the auth
        # boundary. OSError covers PermissionError, ENOSPC (disk full),
        # IsADirectoryError, and FileNotFoundError races.
        _audit_logger.warning("csrf_audit_write_failed: %s (%s)", _AUDIT_PATH, exc)


class CSRFMiddleware(BaseHTTPMiddleware):
    # R3: HttpOnly is False because the frontend reads this cookie via
    # document.cookie to populate the X-CSRF-Token header for the
    # double-submit mechanism. Do NOT change this without also changing
    # the frontend hook (Phase 2: session-controls-state-machine).
    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        method = request.method.upper()
        if method in _SAFE_METHODS:
            # controls-06 #11 — compute the token BEFORE call_next so a
            # handler (notably the /api/csrf body-token endpoint) can
            # read the value from request.state. Without this, the
            # handler would have no way to surface the SAME token the
            # middleware is about to drop in Set-Cookie — a mismatch
            # would force the operator into a token-refresh dance.
            if method in _COOKIE_ISSUE_METHODS:
                existing = request.cookies.get(_COOKIE_NAME)
                token = existing if existing else _generate_token()
                request.state.csrf_token = token
                request.state.csrf_token_needs_set = existing is None
            response = await call_next(request)
            if (
                method in _COOKIE_ISSUE_METHODS
                and getattr(request.state, "csrf_token_needs_set", False)
            ):
                response.set_cookie(
                    key=_COOKIE_NAME,
                    value=request.state.csrf_token,
                    samesite="strict",
                    httponly=False,
                    path="/",
                    # Max-Age NOT set: browser-session cookie (R2)
                    # TRIP-WIRE: If the dashboard ever binds to 0.0.0.0 or sits behind a
                    # TLS proxy, set Secure=True and re-evaluate SameSite.
                    # Secure NOT set: localhost-only deployment (R2)
                )
            return response

        # Unsafe method path (R4)
        # controls-07 #8 — loopback short-circuit. See module-level
        # _LOOPBACK_HOSTS comment for the threat-model rationale. The
        # check fires BEFORE cookie/header parsing so a missing cookie
        # on the operator's first click is not punished. Non-loopback
        # clients (testclient in unit tests, 0.0.0.0 binds, reverse
        # proxies) still hit the full enforcement path below.
        if _is_loopback_client(_remote_addr(request)):
            return await call_next(request)
        # EC-3: the 'or ""' coercion is load-bearing. It maps both None and the
        # literal empty-string cookie to '', so the 'if not cookie' short-circuit
        # in _classify fires before compare_digest is reached. Without this,
        # compare_digest('', '') would return True and let an attacker bypass CSRF
        # with Cookie: csrf_token= + X-CSRF-Token:.
        cookie = request.cookies.get(_COOKIE_NAME) or ""
        header = request.headers.get(_HEADER_NAME) or ""
        reason = _classify(cookie, header)
        if reason is None:
            return await call_next(request)

        _write_audit_entry(
            reason=reason,
            method=method,
            path=request.url.path,
            remote_addr=_remote_addr(request),
        )
        return JSONResponse(status_code=403, content=_REJECT_BODY)
