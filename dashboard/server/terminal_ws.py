"""Read-only WebSocket bridge to a shared ``PtySession`` per tmux session.

ONE FastAPI ``APIRouter`` registering ONE route:
``GET /ws/{target_kind}/terminal?id=<target_id>&csrf=<token>``.

Origin is gated by the outermost ``OriginMiddleware`` (HTTP 403 +
``{"error":"origin"}`` before the upgrade completes). CSRF is enforced
in-endpoint via a double-submit query-parameter vs cookie comparison
because Starlette's ``BaseHTTPMiddleware`` does not run on WebSocket
scope. ``target_kind`` is constrained by a Pydantic ``Literal``;
``target_id`` matches ``validation.SAFE_ID_REGEX`` (``^[a-zA-Z0-9_-]{1,64}$``).

Per-connection state — a 16 ms-OR-4 KB frame batcher feeding a
drop-oldest 64 KB outbound buffer (high watermark 65 536 / low watermark
32 768; one JSON-text ``buffer_overflow`` sentinel per saturated window)
— is isolated. Cross-connection state lives in ``_REGISTRY: dict[str,
_SessionEntry]`` keyed by ``tmux_session_name``: N browser tabs share
ONE ``RealPtySession`` (one ``tmux attach -r``), capped at 8 subscribers
per session (close 1013 over cap). Object-identity-safe eviction
defends against AC-L10 race.

Read-only enforcement (AC-T2 / RSK-4) is doubly enforced: (a) the
``_inbound_drain`` task body is a single ``await ws.receive()``
statement in a ``while True`` loop with no other statement; (b) the
``PtySession`` Protocol surface has NO ``write``/``send``/``feed``
method by construction — the bridge has no syntactic path to forward
bytes to a pty.

Close codes emitted by this module:

* ``1011`` (internal) — helper closed mid-stream
  (``REASON_HELPER_CLOSED``); corrupt lifecycle stream
  (``REASON_LIFECYCLE_MISSING``); deterministic-name lookup mismatch
  (``REASON_LOOKUP_INCONSISTENT``); ``RealPtySession`` bring-up failed
  (``REASON_PTY_BRINGUP``). Reconnect-vs-stop is discriminated on
  ``(close.code, close.reason)`` not on ``close.code`` alone.
* ``1013`` (try again later) — per-session 8-subscriber cap exceeded
  (``REASON_SUBSCRIBER_CAP``).
* ``4001`` (app-csrf) — CSRF query/cookie mismatch (``REASON_CSRF``).
* ``4400`` (app-bad-request) — ``id`` query fails ``SAFE_ID_REGEX``
  (``REASON_INVALID_ID``).
* ``4404`` (app-not-found) — ``status_helper.derive_status`` returns
  idle/cancelled/completed/failed (``REASON_NOT_FOUND``).

``target_kind`` Literal validation is performed by FastAPI's framework
layer BEFORE the route body runs. The framework rejection emits no
bridge audit row — the framework's access log is the only audit trail
for that path.

Imports the private ``middleware.csrf._AUDIT_PATH`` symbol. This is
intentional cross-module coupling so the bridge writes its audit rows
to the SAME ``audit.ndjson`` file as the HTTP CSRF middleware (single
security-event source). Extraction to a shared ``audit_log.py``
module is tracked as deferred follow-up
``RS-fastapi-origin-and-schemas-001``.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import time
from collections import deque
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Final, Literal

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from dashboard.server import tmux_session
from dashboard.server.middleware.csrf import _AUDIT_PATH, _is_loopback_client
from dashboard.server.pty_session import (
    PtySession,
    PtySessionClosedError,
    RealPtySession,
)
from dashboard.server.schemas import BufferOverflowSentinel
from dashboard.server.status_helper import SessionStatus, derive_status
from dashboard.server.validation import validate_safe_id

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Public close-reason constants (the wire contract).
# ---------------------------------------------------------------------------

REASON_CSRF: Final[str] = "csrf"
REASON_INVALID_ID: Final[str] = "invalid id"
REASON_NOT_FOUND: Final[str] = "session not running"
REASON_HELPER_CLOSED: Final[str] = "pty session closed"
REASON_LIFECYCLE_MISSING: Final[str] = "lifecycle missing tmux_session"
REASON_LOOKUP_INCONSISTENT: Final[str] = "tmux_session lookup inconsistency"
REASON_PTY_BRINGUP: Final[str] = "pty bring-up failed"
REASON_SUBSCRIBER_CAP: Final[str] = "subscriber cap reached"

# ---------------------------------------------------------------------------
# Module-level Final constants — see PLAN.md state table.
# ---------------------------------------------------------------------------

_MAX_SUBSCRIBERS_PER_SESSION: Final[int] = 8
_BUFFER_HIGH_WATERMARK: Final[int] = 65_536
_BUFFER_LOW_WATERMARK: Final[int] = 32_768
_BATCH_BYTES_THRESHOLD: Final[int] = 4096
_BATCH_TIME_THRESHOLD_S: Final[float] = 0.016
_DISCONNECT_TIMEOUT_S: Final[float] = 1.0
_CSRF_QUERY_MAX_LEN: Final[int] = 256
_QUEUE_DEPTH: Final[int] = 32

_CsrfReason = Literal["missing_cookie", "missing_query", "mismatch"]
_TargetKind = Literal["autopilot", "chain"]


# ---------------------------------------------------------------------------
# Module-level state.
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class _SessionEntry:
    """Per-tmux-name unit of mutation.

    Single source of truth for ``pty`` + ``subscriber_count``. Eliminates
    the dual-dict shape (separate _REGISTRY + _SUBSCRIBER_COUNT) so the
    helper and the count cannot diverge.
    """

    pty: PtySession
    subscriber_count: int = 0
    created_at_loop_time: float = 0.0


_REGISTRY: dict[str, _SessionEntry] = {}

# Test seam — assigned a lambda by tests that builds a FakePtySession.
# Production value is ``RealPtySession`` (one-arg signature).
_PTY_SESSION_FACTORY: Callable[[str], PtySession] = RealPtySession


@dataclass(slots=True)
class _ConnectionState:
    """Per-WebSocket per-connection state owned by ``_endpoint``.

    The ``queue`` carries inbound chunks from the pty subscriber callback
    to the send pump. The ``out_buffer`` is the post-batch outbound
    deque that the drop-oldest backpressure logic mutates.
    """

    queue: asyncio.Queue[bytes]
    out_buffer: deque[bytes] = field(default_factory=deque)
    out_bytes: int = 0
    overflow_suppressed: bool = False
    bytes_dropped_this_window: int = 0
    callback_drops: int = 0


# ---------------------------------------------------------------------------
# CSRF + audit helpers.
# ---------------------------------------------------------------------------


def _validate_csrf(ws_cookies: Mapping[str, str], csrf_query: str | None) -> _CsrfReason | None:
    """Return failure reason or ``None`` on success.

    Mirrors ``middleware.csrf._classify`` semantics (fail-closed on
    ``TypeError`` from ``compare_digest``).  R5 length cap kicks in
    before ``compare_digest`` to prevent CPU inflation from pathological
    inputs.
    """
    cookie = ws_cookies.get("csrf_token") or ""
    query = csrf_query or ""
    if not cookie:
        return "missing_cookie"
    if not query:
        return "missing_query"
    if len(query) > _CSRF_QUERY_MAX_LEN:
        return "mismatch"
    try:
        if not secrets.compare_digest(cookie, query):
            return "mismatch"
    except TypeError:
        return "mismatch"
    return None


def _remote_addr(ws: WebSocket) -> str:
    client = getattr(ws, "client", None)
    if client is None:
        return "unknown"
    host = getattr(client, "host", None)
    return host or "unknown"


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _safe_log_id(s: str) -> str:
    return s[:64].encode("unicode_escape").decode("ascii")[:128]


def _write_audit_row(payload: dict[str, str]) -> None:
    """Append one JSON line to ``_AUDIT_PATH``.

    Log-and-continue on ``OSError`` (mirrors
    ``csrf._write_audit_entry``).  Audit-log write is observability,
    not the security boundary — the reject already happened.
    """
    line = json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n"
    try:
        _AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
        existed = _AUDIT_PATH.exists()
        with open(_AUDIT_PATH, "a", encoding="utf-8") as fh:
            fh.write(line)
        if not existed:
            os.chmod(_AUDIT_PATH, 0o600)
    except OSError as exc:
        logger.warning("ws_audit_write_failed: %s (%s)", _AUDIT_PATH, exc)


def _audit_csrf_violation(ws: WebSocket, *, target_kind: str, reason: _CsrfReason) -> None:
    _write_audit_row(
        {
            "ts": _now_iso(),
            "event": "csrf_violation",
            "method": "WS",
            "path": f"/ws/{target_kind}/terminal",
            "reason": reason,
            "remote_addr": _remote_addr(ws),
        }
    )


def _audit_ws_violation(ws: WebSocket, *, target_kind: str, reason: str) -> None:
    _write_audit_row(
        {
            "ts": _now_iso(),
            "event": "ws_violation",
            "method": "WS",
            "path": f"/ws/{target_kind}/terminal",
            "reason": reason,
            "remote_addr": _remote_addr(ws),
        }
    )


# ---------------------------------------------------------------------------
# Registry helpers (R14, R15, R18).
# ---------------------------------------------------------------------------


def _get_or_create_pty_session(tmux_name: str) -> tuple[PtySession, bool]:
    """Return ``(pty, created_now)``.

    Single-thread asyncio invariant (R14): no ``await`` between the
    ``get`` and the ``insert``, so concurrent coroutines on the SAME
    event loop cannot race to construct two PtySessions for the same
    name (AC-L8).
    """
    entry = _REGISTRY.get(tmux_name)
    if entry is not None:
        return entry.pty, False
    pty = _PTY_SESSION_FACTORY(tmux_name)
    _REGISTRY[tmux_name] = _SessionEntry(
        pty=pty,
        subscriber_count=0,
        created_at_loop_time=asyncio.get_running_loop().time(),
    )
    return pty, True


def _evict_if_same(tmux_name: str, pty: PtySession) -> None:
    """Delete the registry entry IFF the stored helper IS ``pty``.

    Object-identity check defends against AC-L10: a parallel reconnect
    may have already constructed a fresh PtySession and replaced the
    entry; the closing connection MUST NOT evict the replacement.
    """
    entry = _REGISTRY.get(tmux_name)
    if entry is not None and entry.pty is pty:
        del _REGISTRY[tmux_name]


# ---------------------------------------------------------------------------
# Subscribe callback + per-connection backpressure.
# ---------------------------------------------------------------------------


def _make_subscribe_callback(
    state: _ConnectionState,
) -> Callable[[bytes], Awaitable[None]]:
    """Return the chunk-enqueueing closure.

    NEVER raises — a failed enqueue would otherwise trip the helper's
    fanout R9 auto-unsubscribe and break the connection (R16). Under
    queue saturation, drops the oldest chunk and warns once per drop.
    """

    async def _callback(chunk: bytes) -> None:
        try:
            state.queue.put_nowait(chunk)
        except asyncio.QueueFull:
            try:
                state.queue.get_nowait()
            except asyncio.QueueEmpty:
                # Defensive: should not happen — QueueFull implies the
                # queue is non-empty. Log and bail.
                logger.warning("event=ws.subscribe.callback_fault unexpected QueueEmpty")
                return
            state.callback_drops += 1
            logger.warning(
                "event=ws.callback.queue_dropped subscriber drops=%d",
                state.callback_drops,
            )
            try:
                state.queue.put_nowait(chunk)
            except asyncio.QueueFull:
                logger.warning("event=ws.subscribe.callback_fault retry put failed")
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "event=ws.subscribe.callback_fault %s",
                type(exc).__name__,
            )

    return _callback


def _append_with_backpressure(state: _ConnectionState, batch: bytes) -> bool:
    """Append ``batch`` and apply drop-oldest if past the high watermark.

    Returns ``True`` IFF this is the first overflow transition since
    the buffer last drained below the low watermark — signals that the
    caller should emit ONE sentinel.  Pure synchronous logic, no I/O —
    the WebSocket send happens in ``_drain_one`` / ``_send_pump``.
    """
    state.out_buffer.append(batch)
    state.out_bytes += len(batch)
    needs_sentinel = False
    if state.out_bytes > _BUFFER_HIGH_WATERMARK:
        while state.out_buffer and state.out_bytes > _BUFFER_HIGH_WATERMARK:
            dropped = state.out_buffer.popleft()
            state.out_bytes -= len(dropped)
            state.bytes_dropped_this_window += len(dropped)
        if not state.overflow_suppressed:
            state.overflow_suppressed = True
            needs_sentinel = True
    elif state.overflow_suppressed and state.out_bytes <= _BUFFER_LOW_WATERMARK:
        state.overflow_suppressed = False
        state.bytes_dropped_this_window = 0
    return needs_sentinel


async def _drain_one(state: _ConnectionState, ws: WebSocket) -> None:
    """Pop ONE batch from the outbound buffer and send it."""
    if not state.out_buffer:
        return
    batch = state.out_buffer.popleft()
    state.out_bytes -= len(batch)
    await ws.send_bytes(batch)


async def _emit_overflow_sentinel(state: _ConnectionState, ws: WebSocket) -> None:
    """Send ONE ``buffer_overflow`` JSON text frame."""
    payload = BufferOverflowSentinel(
        type="buffer_overflow",
        bytes_dropped=state.bytes_dropped_this_window,
        at=int(time.time() * 1000),
    ).model_dump_json()
    try:
        await ws.send_text(payload)
        logger.info(
            "event=ws.overflow.fired bytes_dropped=%d",
            state.bytes_dropped_this_window,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "event=ws.overflow.send_failed %s",
            type(exc).__name__,
        )
        raise


# ---------------------------------------------------------------------------
# Send pump state machine.
# ---------------------------------------------------------------------------


async def _send_pump(ws: WebSocket, state: _ConnectionState) -> None:
    """Frame batching (16 ms OR 4 KB) + drop-oldest backpressure.

    State 1 (idle): block on ``queue.get()`` — no timer running.
    State 2 (accumulating): elapsed-time vs threshold drives flush.

    The loop exits on ``WebSocketDisconnect`` from ``send_bytes`` /
    ``send_text``, or on ``asyncio.CancelledError`` from the outer
    finally cleanup.
    """
    loop = asyncio.get_running_loop()
    while True:
        # State 1 — idle.
        chunk = await state.queue.get()
        accumulator = bytearray(chunk)
        first_ts = loop.time()
        # State 2 — accumulating.
        while True:
            elapsed = loop.time() - first_ts
            if elapsed >= _BATCH_TIME_THRESHOLD_S:
                break
            if len(accumulator) >= _BATCH_BYTES_THRESHOLD:
                break
            remaining = max(0.0, _BATCH_TIME_THRESHOLD_S - elapsed)
            try:
                more = await asyncio.wait_for(state.queue.get(), timeout=remaining)
            except TimeoutError:
                break
            accumulator.extend(more)
        batch = bytes(accumulator)
        needs_sentinel = _append_with_backpressure(state, batch)
        if needs_sentinel:
            await _emit_overflow_sentinel(state, ws)
        await _drain_one(state, ws)


# ---------------------------------------------------------------------------
# Inbound drain — single-statement body (R26).
# ---------------------------------------------------------------------------


async def _inbound_drain(ws: WebSocket) -> None:
    """Receive-and-discard every inbound frame; never forward bytes.

    The body is one ``await ws.receive()`` inside a ``while True`` —
    a static-source assertion (G4) checks that no other statement is
    inserted between the receive and the next loop iteration. The
    PtySession Protocol has no write surface by construction, so even
    a malicious patch could not forward bytes anywhere (DN-4).
    """
    while True:
        await ws.receive()


# ---------------------------------------------------------------------------
# Router + endpoint.
# ---------------------------------------------------------------------------


router = APIRouter()


def _decide_status_close(status: SessionStatus, deterministic: str) -> tuple[int, str] | None:
    """Return (code, reason) for a status-precondition close, or None.

    Centralises the status-routing decisions (R12, R13). Step 8c of
    the endpoint flow calls this after ws.accept() so any close rides
    a real WebSocket frame.
    """
    if status["status"] in ("idle", "cancelled", "completed", "failed"):
        return 4404, REASON_NOT_FOUND
    if status.get("tmux_session") is None:
        return 1011, REASON_LIFECYCLE_MISSING
    if status.get("tmux_session") != deterministic:
        return 1011, REASON_LOOKUP_INCONSISTENT
    return None


@router.websocket("/ws/{target_kind}/terminal")
async def _endpoint(
    ws: WebSocket,
    target_kind: _TargetKind,
    target_id: str = Query(..., alias="id", min_length=1, max_length=64),
    csrf: str = Query(..., min_length=1, max_length=_CSRF_QUERY_MAX_LEN),
) -> None:
    """Connection orchestrator.

    Pre-accept gates: CSRF (R9), subscriber-cap reserve (R10).
    Accept (R29 prerequisite — 4xxx close codes must ride a real WS).
    Post-accept gauntlet: id regex (R7), deterministic-name re-derivation
    (R11), status routing (R12 / R13), pty bring-up failure (R-Risk-1).
    Subscribe → TOCTOU re-check → spawn pump + drain → await
    FIRST_COMPLETED → finally cleanup.
    """
    # --- step 2: CSRF gate (pre-accept).
    # controls-07 #8 pt 2 — loopback short-circuit; mirrors the HTTP
    # middleware skip (csrf.py:1xx). Origin allowlist on the WS scope
    # (OriginMiddleware) is still enforced regardless. See pt 1 commit
    # for the full threat-model rationale.
    if not _is_loopback_client(_remote_addr(ws)):
        reason_csrf = _validate_csrf(ws.cookies, csrf)
        if reason_csrf is not None:
            _audit_csrf_violation(ws, target_kind=target_kind, reason=reason_csrf)
            logger.info(
                "event=ws.reject.csrf target_kind=%s target_id=%s reason=%s remote_addr=%s",
                target_kind,
                _safe_log_id(target_id),
                reason_csrf,
                _remote_addr(ws),
            )
            await ws.close(code=4001, reason=REASON_CSRF)
            return

    # --- step 3: subscriber-cap reserve. Compute the deterministic name
    # to look up the entry; full validate_safe_id is deferred to step 8a.
    try:
        tmux_name = tmux_session.deterministic_name(target_kind, target_id)
    except ValueError:
        # target_id slipped FastAPI's min/max length cap (unreachable
        # since FastAPI already enforced len 1..64 + we are about to
        # re-check) OR target_kind is bypassed. Defer to post-accept
        # 4400 path.
        tmux_name = ""

    slot_reserved = False
    if tmux_name:
        entry = _REGISTRY.get(tmux_name)
        current_count = entry.subscriber_count if entry is not None else 0
        if current_count >= _MAX_SUBSCRIBERS_PER_SESSION:
            logger.info(
                "event=ws.reject.subscriber_cap target_kind=%s target_id=%s remote_addr=%s",
                target_kind,
                _safe_log_id(target_id),
                _remote_addr(ws),
            )
            await ws.close(code=1013, reason=REASON_SUBSCRIBER_CAP)
            return
        if entry is not None:
            entry.subscriber_count += 1
            slot_reserved = True

    # --- step 4: resolve / construct helper. Failure is deferred to 8d.
    pty: PtySession | None = None
    factory_failed = False
    created_now = False
    if tmux_name:
        try:
            pty, created_now = _get_or_create_pty_session(tmux_name)
            if created_now:
                # First-connect path absorbed the count-1 reservation.
                _REGISTRY[tmux_name].subscriber_count = 1
                slot_reserved = True
                logger.info(
                    "event=ws.pty.created target_kind=%s target_id=%s tmux_session=%s",
                    target_kind,
                    target_id,
                    tmux_name,
                )
        except Exception as exc:  # noqa: BLE001
            factory_failed = True
            logger.warning(
                "event=ws.pty.create_failed target_kind=%s target_id=%s exc=%s",
                target_kind,
                target_id,
                type(exc).__name__,
            )

    # --- step 5: capture status BEFORE accept so 4404 / 1011 decisions
    # ride a real WebSocket frame from step 8c.
    initial_status: SessionStatus | None = None
    try:
        initial_status = derive_status(target_kind, target_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "event=ws.status.lookup_failed target_kind=%s target_id=%s exc=%s",
            target_kind,
            target_id,
            type(exc).__name__,
        )

    # --- step 6: ws.accept().
    await ws.accept()

    # --- step 7: build per-connection state.
    state = _ConnectionState(queue=asyncio.Queue(maxsize=_QUEUE_DEPTH))
    callback = _make_subscribe_callback(state)

    try:
        # --- step 8a / 8b: post-accept id validation.
        try:
            validate_safe_id(target_id, field="target_id")
        except ValueError:
            _audit_ws_violation(ws, target_kind=target_kind, reason="invalid_id")
            logger.info(
                "event=ws.reject.invalid_id target_kind=%s target_id=%s remote_addr=%s",
                target_kind,
                _safe_log_id(target_id),
                _remote_addr(ws),
            )
            await ws.close(code=4400, reason=REASON_INVALID_ID)
            return

        if not tmux_name:
            try:
                tmux_name = tmux_session.deterministic_name(target_kind, target_id)
            except ValueError:
                _audit_ws_violation(ws, target_kind=target_kind, reason="invalid_id")
                await ws.close(code=4400, reason=REASON_INVALID_ID)
                return

        # --- step 8c: status-precondition routing.
        if initial_status is None:
            await ws.close(code=1011, reason=REASON_LIFECYCLE_MISSING)
            logger.info(
                "event=ws.reject.not_found target_kind=%s target_id=%s reason=lookup_failed",
                target_kind,
                target_id,
            )
            return
        close_decision = _decide_status_close(initial_status, tmux_name)
        if close_decision is not None:
            code, reason = close_decision
            logger.info(
                "event=ws.reject.not_found target_kind=%s target_id=%s code=%d reason=%s",
                target_kind,
                target_id,
                code,
                reason,
            )
            await ws.close(code=code, reason=reason)
            return

        # --- step 8d: deferred pty bring-up failure.
        if factory_failed:
            await ws.close(code=1011, reason=REASON_PTY_BRINGUP)
            return

        assert pty is not None  # narrowing for type checker

        # --- step 9: subscribe.
        # controls-06 #15 — replay-then-tail seed: capture the tmux
        # pane's scrollback BEFORE subscribing to the live fanout, so
        # the operator's first frame is historical context, not the
        # next byte that happens to arrive. Industry-standard pattern
        # (GitHub Actions / Vercel / Render / Heroku / kubectl logs
        # / docker logs / CloudWatch Live Tail / Buildkite all do
        # this — last N lines on attach, then live tail). The
        # scrollback is enqueued via put_nowait so it lands FIRST in
        # the per-connection queue; live frames arriving via the
        # subsequent `pty.subscribe(callback)` path land behind it.
        # A capture failure (no tmux binary, dead session, timeout)
        # returns b"" and the live-attach path is unaffected.
        try:
            scrollback = pty.current_scrollback()
        except Exception:  # noqa: BLE001
            scrollback = b""
        if scrollback:
            # controls-07 #12 — chunk at the batch threshold BEFORE
            # enqueuing. Pre-#12 a single put_nowait(scrollback)
            # delivered 85kB+ to the send pump as one chunk; the pump
            # then handed it to _append_with_backpressure which tripped
            # the 64KB drop-oldest ceiling and the operator saw
            # "Output buffer overflow — 82698 bytes dropped" with the
            # scrollback effectively gone. Chunking matches the pump's
            # accumulation window so each batch flushes cleanly without
            # touching backpressure.
            try:
                for offset in range(0, len(scrollback), _BATCH_BYTES_THRESHOLD):
                    state.queue.put_nowait(
                        scrollback[offset : offset + _BATCH_BYTES_THRESHOLD]
                    )
            except asyncio.QueueFull:
                # Vanishingly unlikely on a fresh queue (default
                # maxsize > 0), but defensive — if it does happen,
                # drop the scrollback and continue with the live
                # attach.
                logger.warning(
                    "event=ws.scrollback.queue_full target_kind=%s target_id=%s",
                    target_kind, target_id,
                )
        try:
            pty.subscribe(callback)
        except PtySessionClosedError:
            _evict_if_same(tmux_name, pty)
            logger.info(
                "event=ws.close.helper_closed target_kind=%s target_id=%s tmux_session=%s",
                target_kind,
                target_id,
                tmux_name,
            )
            await ws.close(code=1011, reason=REASON_HELPER_CLOSED)
            return

        logger.info(
            "event=ws.subscribe.ok target_kind=%s target_id=%s tmux_session=%s scrollback_bytes=%d",
            target_kind,
            target_id,
            tmux_name,
            len(scrollback),
        )

        # --- step 10: TOCTOU re-check.
        try:
            recheck = derive_status(target_kind, target_id)
        except Exception:  # noqa: BLE001
            recheck = None
        if recheck is None or (
            recheck.get("started_at") != initial_status.get("started_at")
            or recheck.get("tmux_session") != initial_status.get("tmux_session")
        ):
            try:
                pty.unsubscribe(callback)
            except (KeyError, PtySessionClosedError):
                pass
            _evict_if_same(tmux_name, pty)
            while not state.queue.empty():
                state.queue.get_nowait()
            await ws.close(code=1011, reason=REASON_LIFECYCLE_MISSING)
            return

        logger.info(
            "event=ws.accept target_kind=%s target_id=%s tmux_session=%s remote_addr=%s",
            target_kind,
            target_id,
            tmux_name,
            _remote_addr(ws),
        )

        # --- step 11: spawn background tasks.
        pump_task = asyncio.create_task(_send_pump(ws, state))
        drain_task = asyncio.create_task(_inbound_drain(ws))

        # --- step 12: await first-completed.
        try:
            await asyncio.wait(
                {pump_task, drain_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
        finally:
            for task in (pump_task, drain_task):
                if not task.done():
                    task.cancel()
            await asyncio.gather(pump_task, drain_task, return_exceptions=True)
            for task in (pump_task, drain_task):
                if task.cancelled():
                    continue
                task_exc = task.exception()
                if task_exc is not None and not isinstance(task_exc, WebSocketDisconnect):
                    logger.warning(
                        "event=ws.task.exception exc_type=%s exc_message=%s",
                        type(task_exc).__name__,
                        str(task_exc),
                    )

        subscribers_remaining = (
            _REGISTRY[tmux_name].subscriber_count - 1
            if (slot_reserved and tmux_name in _REGISTRY)
            else 0
        )
        logger.info(
            "event=ws.close.client target_kind=%s target_id=%s tmux_session=%s subscribers_remaining=%d",
            target_kind,
            target_id,
            tmux_name,
            subscribers_remaining,
        )

        # --- step 13a: unsubscribe (clean disconnect path).
        try:
            pty.unsubscribe(callback)
            logger.info(
                "event=ws.unsubscribe.ok target_kind=%s target_id=%s tmux_session=%s",
                target_kind,
                target_id,
                tmux_name,
            )
        except KeyError:
            logger.debug(
                "event=ws.unsubscribe.already_cleared target_kind=%s target_id=%s",
                target_kind,
                target_id,
            )
        except PtySessionClosedError:
            _evict_if_same(tmux_name, pty)
            logger.info(
                "event=ws.close.helper_closed target_kind=%s target_id=%s",
                target_kind,
                target_id,
            )

    except asyncio.CancelledError:
        logger.info(
            "event=ws.close.cancelled target_kind=%s target_id=%s",
            target_kind,
            target_id,
        )
        raise
    finally:
        # --- step 13b: ALWAYS decrement subscriber count if reserved.
        if slot_reserved and tmux_name:
            entry = _REGISTRY.get(tmux_name)
            if entry is not None:
                entry.subscriber_count = max(0, entry.subscriber_count - 1)


__all__ = (
    "router",
    "REASON_CSRF",
    "REASON_INVALID_ID",
    "REASON_NOT_FOUND",
    "REASON_HELPER_CLOSED",
    "REASON_LIFECYCLE_MISSING",
    "REASON_LOOKUP_INCONSISTENT",
    "REASON_PTY_BRINGUP",
    "REASON_SUBSCRIBER_CAP",
    "BufferOverflowSentinel",
)
