"""FastAPI app skeleton (T0.1 fastapi-app-skeleton).

Imported by uvicorn via ``dashboard.server.app:app``. Exposes a single
``GET /health`` endpoint and emits one line of JSON per request to the
``dashboard.access`` logger. The existing stdlib ``serve.py`` is unaffected
— see ``fastapi-cutover`` (T0.3) for the launcher swap.

Operator hand-shake (EC-5.4): set ``DASHBOARD_LOG_CONFIG_OPT_OUT=1`` to
skip the module-level ``dictConfig`` call so a uvicorn ``--log-config``
override wins. With the env var unset, this module installs JSON access
logging at import time.
"""

from __future__ import annotations

import json
import logging
import os
import time
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from importlib.metadata import PackageNotFoundError
from importlib.metadata import version as _pkg_version
from logging.config import dictConfig
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response
from starlette.types import Scope

from dashboard.server._exception_handlers import (
    html_4xx_handler,
    html_500_handler,
)
from dashboard.server.middleware.csrf import CSRFMiddleware
from dashboard.server.middleware.origin_check import OriginMiddleware
from dashboard.server.schemas import WriteRequest

# ---------------------------------------------------------------------------
# HealthResponse (R3, R4)
# ---------------------------------------------------------------------------


class HealthResponse(BaseModel):
    status: Literal["ok"]
    version: str
    ts: str


# ---------------------------------------------------------------------------
# JSON access log formatter (R5)
# ---------------------------------------------------------------------------


class _JsonAccessFormatter(logging.Formatter):
    """Renders an access record as one line of JSON.

    Reads four structured fields off the record (set via ``extra=`` in
    ``AccessLogMiddleware``): method, path, status, duration_ms.
    """

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "method": getattr(record, "method", None),
            "path": getattr(record, "path", None),
            "status": getattr(record, "status", None),
            "duration_ms": getattr(record, "duration_ms", None),
        }
        return json.dumps(payload, ensure_ascii=False)


_LOG_CONFIG: dict[str, object] = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {"json_access": {"()": _JsonAccessFormatter}},
    "handlers": {
        "access_stream": {
            "class": "logging.StreamHandler",
            "formatter": "json_access",
            "stream": "ext://sys.stderr",
        },
    },
    "loggers": {
        "dashboard.access": {
            "handlers": ["access_stream"],
            "level": "INFO",
            "propagate": False,
        },
        # Silence uvicorn's human-readable access line (R5 unwanted-behaviour).
        "uvicorn.access": {"level": "WARNING", "propagate": False},
    },
}


def _configure_logging() -> None:
    """Apply the dashboard JSON logging config unless explicitly opted-out.

    EC-5.4: ``DASHBOARD_LOG_CONFIG_OPT_OUT=1`` skips this so a uvicorn
    ``--log-config`` override survives module import.
    """
    if os.environ.get("DASHBOARD_LOG_CONFIG_OPT_OUT") == "1":
        return
    dictConfig(_LOG_CONFIG)


_configure_logging()
_access_logger = logging.getLogger("dashboard.access")


# ---------------------------------------------------------------------------
# AccessLogMiddleware (R5, EC-5.1, EC-5.2, EC-5.3)
# ---------------------------------------------------------------------------


class AccessLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        start = time.perf_counter()
        status = 500  # sentinel — overwritten on success
        try:
            response: Response = await call_next(request)
            status = response.status_code
            return response
        finally:
            duration_ms = max(0, round((time.perf_counter() - start) * 1000))
            _access_logger.info(
                "",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "status": status,
                    "duration_ms": duration_ms,
                },
            )


# ---------------------------------------------------------------------------
# /health endpoint (R3, R4)
# ---------------------------------------------------------------------------


def _resolve_version() -> str:
    """Return the installed `dashboard` package version, or 'unknown' (EC-4.1)."""
    try:
        return _pkg_version("dashboard")
    except PackageNotFoundError:
        return "unknown"


app = FastAPI(title="Claude Agent Dashboard", version=_resolve_version())


# AC2 (fastapi-origin-and-schemas): FastAPI returns 422 by default
# on body-validation failure; the plan AC pins this to 400. The body
# shape {"detail":[...]} mirrors FastAPI's default 422 envelope, so
# callers parsing the error list continue to work — only the status
# code changes.
async def _validation_error_to_400(request: Request, exc: RequestValidationError) -> JSONResponse:
    errors = [{k: v for k, v in e.items() if k not in {"input", "url"}} for e in exc.errors()]
    return JSONResponse(
        status_code=400,
        content=jsonable_encoder({"detail": errors}),
    )


# Starlette's add_exception_handler is typed as Callable[[Request, Exception], ...]
# but FastAPI dispatches by exception class via MRO — passing the
# RequestValidationError-specific handler is the documented FastAPI pattern.
app.add_exception_handler(RequestValidationError, _validation_error_to_400)  # type: ignore[arg-type]
# R10 (T0.2.b): register the global HTML 4xx/5xx exception handlers BEFORE
# `_compose_routes` so every HTTPException raised by a router or fallback
# emits stdlib-equivalent HTML body bytes instead of FastAPI's default JSON.
app.add_exception_handler(StarletteHTTPException, html_4xx_handler)
app.add_exception_handler(Exception, html_500_handler)
# Middleware registration order (Starlette's `add_middleware` inserts at
# `user_middleware[0]`, so the LAST-registered class is the OUTERMOST
# runtime middleware). Origin must be outermost so it rejects unsafe
# methods with `origin_violation` before CSRF would otherwise tag them
# `csrf_violation` (PLAN Risk-A).
#
# Final runtime chain: Origin → CSRF → AccessLog → routes
# `app.user_middleware` index order: [Origin, CSRF, AccessLog]
app.add_middleware(AccessLogMiddleware)
app.add_middleware(CSRFMiddleware)
app.add_middleware(OriginMiddleware)


@app.get("/health")
async def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        version=_resolve_version(),
        ts=datetime.now(UTC).isoformat(),
    )


# ---------------------------------------------------------------------------
# T0.2.a — fastapi-routes-port-core: include the 7 core API routes, install
# the explicit /api/{rest:path} 404 fallback for unported paths, and mount
# the SPA static fallback (DN-6 React Router compatibility) last.
# Registration order is load-bearing — see PLAN.md § C4 and Risk-A.
# ---------------------------------------------------------------------------

from dashboard.server.control import router as _control_router  # noqa: E402
from dashboard.server.routes.api import router as _api_router  # noqa: E402
from dashboard.server.terminal_ws import router as _terminal_ws_router  # noqa: E402


def _resolve_spa_root() -> Path:
    """Pick the SPA root directory at app-composition time.

    Mirrors stdlib ``serve.py:265`` — if the React build output exists, serve
    it; otherwise fall back to ``dashboard/`` so the operator gets a working
    server even without ``pnpm run build`` (PLAN OQ#4 Option a).
    """
    return _APP_DIST if _APP_DIST.is_dir() else _DASHBOARD_DIR


class _SPAStaticFiles(StaticFiles):
    """``StaticFiles`` variant that returns ``index.html`` for unmatched paths.

    Starlette's ``html=True`` only serves ``index.html`` for directory requests;
    it does not implement React Router fallback (a request for ``/watchfloor``
    must return the SPA HTML so the client-side router can route it). This
    subclass overrides ``get_response`` to look up ``index.html`` whenever the
    base lookup raises a 404 — but only when ``index.html`` actually exists, so
    the empty-SPA-root case still fails closed (EC-10.3, T10.8).
    """

    async def get_response(self, path: str, scope: Scope) -> Response:
        try:
            return await super().get_response(path, scope)
        except StarletteHTTPException as exc:
            if exc.status_code != 404:
                raise
            try:
                return await super().get_response("index.html", scope)
            except StarletteHTTPException:
                raise exc from None


def _compose_routes(target_app: FastAPI, spa_root: Path) -> None:
    """Wire the APIRouter, the /api/{rest:path} 404 fallback, and the SPA mount.

    Registration order is load-bearing (PLAN.md § C4 + Risk-A): the APIRouter
    runs first, the explicit ``/api/{rest:path}`` 404 catches unported API
    paths (R12), and the SPA mount handles non-API paths with React Router
    fallback (R10, DN-6).
    """
    target_app.include_router(_api_router)
    target_app.include_router(_control_router)
    target_app.include_router(_terminal_ws_router)

    _NOT_FOUND_RESPONSES: dict[int | str, dict[str, str]] = {404: {"description": "Not Found"}}

    @target_app.get(
        "/api/{rest:path}",
        include_in_schema=False,
        responses=_NOT_FOUND_RESPONSES,
    )
    async def _api_not_found_get(rest: str) -> None:
        """R12: unported GET /api/* paths return 404."""
        raise HTTPException(status_code=404)

    @target_app.post(
        "/api/{rest:path}",
        include_in_schema=False,
        responses=_NOT_FOUND_RESPONSES,
    )
    async def _api_not_found_post(rest: str) -> None:
        """R12 / OQ#3: unported POST /api/* paths return 404 deterministically."""
        raise HTTPException(status_code=404)

    @target_app.delete(
        "/api/{rest:path}",
        include_in_schema=False,
        responses=_NOT_FOUND_RESPONSES,
    )
    async def _api_not_found_delete(rest: str) -> None:
        """R12 / OQ#3: unported DELETE /api/* paths return 404 deterministically."""
        raise HTTPException(status_code=404)

    target_app.mount(
        "/",
        _SPAStaticFiles(directory=spa_root, html=True),
        name="spa",
    )


# R15 / AC2: sentinel endpoint must be registered BEFORE `_compose_routes`
# below because `_compose_routes` installs an `/api/{rest:path}` catch-all
# 404 handler that would otherwise match first and shadow this route.
@app.post(
    "/api/schema-test",
    responses={
        400: {
            "description": "Validation failed",
            "content": {
                "application/json": {
                    "example": {
                        "detail": [
                            {
                                "loc": ["body", "feature_id"],
                                "msg": "string does not match pattern",
                                "type": "value_error",
                            }
                        ]
                    }
                }
            },
        },
        403: {
            "description": "Origin or CSRF violation",
            "content": {
                "application/json": {
                    "examples": {
                        "origin": {"value": {"error": "origin"}},
                        "csrf": {"value": {"error": "csrf"}},
                    }
                }
            },
        },
    },
)
async def schema_test(body: WriteRequest) -> WriteRequest:
    # SD-2: permanent schema-contract observable. Side-effect-free echo —
    # no subprocess, no disk, no state mutation.
    return body


_DASHBOARD_DIR = Path(__file__).resolve().parents[1]
_APP_DIST = _DASHBOARD_DIR / "app" / "dist"
_SPA_ROOT = _resolve_spa_root()

_compose_routes(app, _SPA_ROOT)
