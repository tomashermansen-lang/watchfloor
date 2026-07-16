"""Guard: blocking read handlers must be sync ``def`` so Starlette dispatches
them in the AnyIO threadpool instead of on the event loop.

Rationale (dashboard-perf investigation, 2026-06-02): every handler in
``routes/api.py`` performs blocking I/O — file reads, ``git``/``tmux``
subprocess — with NO ``await`` in its body. Declared ``async def``, FastAPI
runs them directly on the single event-loop thread, so one slow artifact
read or a 2 s ``tmux has-session`` probe serializes *every* other request
AND stalls the terminal-stream WebSocket that shares the loop. FastAPI only
offloads NON-coroutine endpoints to the threadpool (Starlette dispatches via
``is_async_callable(endpoint)``), so these handlers must stay plain ``def``.

This is a structural guard: it fails the moment someone reintroduces
``async def`` on a blocking handler, reinstating the head-of-line blocking.
"""

from __future__ import annotations

import asyncio

from dashboard.server.routes.api import router

# Every path whose handler body does blocking I/O (file read or subprocess)
# and therefore must run in the threadpool. ``/api/csrf`` is intentionally
# excluded — it only reads ``request.state.csrf_token`` (no I/O), so its
# dispatch model is irrelevant to the perf contract.
_BLOCKING_PATHS: frozenset[str] = frozenset(
    {
        "/api/flow-status",
        "/api/worktrees",
        "/api/plan",
        "/api/plans",
        "/api/sessions",
        "/api/features",
        "/api/metrics",
        "/api/autopilots",
        "/api/autopilot/log",
        "/api/autopilot/stream",
        "/api/autopilot/summary",
        "/api/autopilot/artifacts",
        "/api/autopilot/artifact",
        "/api/autopilot/activity",
        "/api/plan/artifacts",
        "/api/plan/artifact",
        "/api/feature/artifacts",
        "/api/feature/artifact",
        "/api/grinder",
        "/api/grinder/stream",
        "/api/grinder/pause",
        "/api/{target_kind}/status",
    }
)


def _blocking_routes() -> list[tuple[str, object]]:
    """(path, endpoint) for every router route on a blocking path."""
    out: list[tuple[str, object]] = []
    for route in router.routes:
        path = getattr(route, "path", None)
        endpoint = getattr(route, "endpoint", None)
        if path in _BLOCKING_PATHS and endpoint is not None:
            out.append((path, endpoint))
    return out


def test_every_blocking_path_is_present() -> None:
    """Spec drift guard: if a blocking path is renamed/removed, this set must
    be updated deliberately rather than silently passing on zero routes."""
    seen = {path for path, _ in _blocking_routes()}
    missing = _BLOCKING_PATHS - seen
    assert not missing, f"blocking paths declared but not routed: {sorted(missing)}"


def test_blocking_read_handlers_are_threadpool_offloaded() -> None:
    """Blocking handlers must be sync ``def`` (not coroutines) so Starlette
    offloads them to the threadpool instead of blocking the event loop."""
    offenders = sorted(
        {
            path
            for path, endpoint in _blocking_routes()
            if asyncio.iscoroutinefunction(endpoint)
        }
    )
    assert not offenders, (
        "These handlers do blocking I/O but are `async def`, so they run on "
        "the event loop and serialize every request + the terminal WebSocket. "
        "Convert them to plain `def`: " + ", ".join(offenders)
    )
