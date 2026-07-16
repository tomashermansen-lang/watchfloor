"""Unit tests for origin_check audit helpers + module constants (C1.F-4, C1.G-4, C1.J).

Filesystem-side-effect-free; covers _remote_addr, lifespan pass-through,
and constant pins for _AUDIT_EVENT / _REJECT_BODY.
"""

from __future__ import annotations

import asyncio

from dashboard.server.middleware.origin_check import (
    _AUDIT_EVENT,
    _REJECT_BODY,
    OriginMiddleware,
    _remote_addr,
)

# ── C1.F-4 — _remote_addr fallback ─────────────────────────────────────


def test_c1_f_4a_remote_addr_returns_client_host_when_present() -> None:
    assert _remote_addr({"client": ("1.2.3.4", 9999)}) == "1.2.3.4"


def test_c1_f_4b_remote_addr_returns_unknown_when_client_absent() -> None:
    assert _remote_addr({}) == "unknown"


def test_c1_f_4c_remote_addr_returns_unknown_when_client_is_none() -> None:
    assert _remote_addr({"client": None}) == "unknown"


# ── C1.J — module-level security constants ─────────────────────────────


def test_c1_j_1_audit_event_constant_pin() -> None:
    assert _AUDIT_EVENT == "origin_violation"


def test_c1_j_2_reject_body_constant_pin() -> None:
    assert _REJECT_BODY == b'{"error":"origin"}'


# ── C1.G-4 — lifespan pass-through ─────────────────────────────────────


def test_c1_g_4_lifespan_passthrough() -> None:
    calls: list[dict] = []

    async def recorder(scope, receive, send):  # noqa: ANN001
        calls.append({"scope": scope, "receive": receive, "send": send})

    middleware = OriginMiddleware(recorder)

    async def _noop(*args, **kwargs):  # noqa: ANN001, ANN003
        return None

    asyncio.run(
        middleware(
            {"type": "lifespan"},
            _noop,
            _noop,
        )
    )

    assert len(calls) == 1
    assert calls[0]["scope"] == {"type": "lifespan"}


# ── C1.G — unknown scope type passes through with WARNING ──────────────


def test_unknown_scope_type_passes_through() -> None:
    import logging

    calls: list[dict] = []
    records: list[logging.LogRecord] = []

    class _Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            records.append(record)

    handler = _Capture(level=logging.WARNING)
    logger = logging.getLogger("dashboard.access")
    logger.addHandler(handler)
    try:

        async def recorder(scope, receive, send):  # noqa: ANN001
            calls.append({"scope": scope})

        middleware = OriginMiddleware(recorder)

        async def _noop(*args, **kwargs):  # noqa: ANN001, ANN003
            return None

        asyncio.run(middleware({"type": "future_extension"}, _noop, _noop))
    finally:
        logger.removeHandler(handler)

    assert len(calls) == 1
    assert any("unknown_scope_type" in rec.getMessage() for rec in records)
