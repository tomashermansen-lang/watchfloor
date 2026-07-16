"""Pure-stdlib + ``ptyprocess`` fanout helper.

Public surface: ``PtySession`` (``typing.Protocol``), ``RealPtySession``,
``FakePtySession``, ``PtySessionClosedError``. One
``ptyprocess.PtyProcess`` per named tmux session (attached via
``tmux attach -r -t <name>``) multicasts every output chunk to N
subscribers via ``subscribe(callback) / unsubscribe(callback) /
close()``. The Protocol surface has NO ``write``, ``read``, ``send``,
or ``feed`` method — the WebSocket bridge has nothing to forward an
inbound client message to (DN-4 / RSK-4 mechanical defense).

``FakePtySession`` is the read-only-by-construction test substrate:
``write()`` raises ``NotImplementedError`` BEFORE touching any internal
sink, and ``assert_no_inbound_bytes()`` proves the invariant from a
unit test (R19 / R26).

Zero ``fastapi`` / ``starlette`` / ``pydantic`` / ``uvicorn`` imports
(R3). The only ``dashboard.server.*`` dependency is ``validation`` —
keeps the import graph one-deep through the bottom-of-graph regex
module and circular-free (R4).

Single-thread asyncio invariant (R-2): every state mutation runs on the
event loop's single thread; the only blocking call (``_PtyHandle.read``)
is hopped off to ``loop.run_in_executor`` so the loop is never starved.
"""

from __future__ import annotations

import asyncio
import logging
import re
import subprocess
from collections.abc import Awaitable, Callable, Iterable, Sequence
from typing import Literal, Protocol, runtime_checkable

from dashboard.server.validation import SAFE_ID_REGEX

import json as _audit_json
import os as _audit_os
from datetime import UTC as _AUDIT_UTC, datetime as _audit_datetime
from pathlib import Path as _AuditPath

logger = logging.getLogger(__name__)


def _resolve_audit_path() -> _AuditPath:
    """controls-07 #10 — locally-resolved audit path (no cross-module
    import). Mirrors the resolution in middleware/csrf.py; tracked by
    `RS-fastapi-origin-and-schemas-001` for eventual extraction to a
    shared audit_log helper. M6 architectural test pins pty_session
    to a single dashboard.* import (validation), so we cannot import
    _AUDIT_PATH from middleware.csrf without breaking the constraint.
    """
    override = _audit_os.environ.get("DASHBOARD_DATA_DIR")
    if override:
        return _AuditPath(override) / "audit.ndjson"
    return _AuditPath(__file__).resolve().parent.parent / "data" / "audit.ndjson"


def _write_scrollback_audit(reason: str, tmux_session_name: str, **fields: object) -> None:
    """controls-07 #10 — write scrollback diagnostics to audit.ndjson.

    start-system.sh redirects uvicorn stderr to /dev/null, so the
    logger.warning calls would be invisible to an operator. The audit
    log is the persistent surface the operator can `tail` regardless
    of stderr routing.
    """
    payload = {
        "ts": _audit_datetime.now(_AUDIT_UTC).isoformat(),
        "event": "scrollback_diagnostic",
        "reason": reason,
        "tmux_session": tmux_session_name,
        **fields,
    }
    line = _audit_json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n"
    try:
        path = _resolve_audit_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass

# OQ-4: re-derive the two-segment name pattern from SAFE_ID_REGEX so
# tmux_session.py and pty_session.py bind the same regex source. The
# `SAFE_ID_REGEX` literal MUST stay visible in this module's source
# (TESTPLAN row N4) so a future loosening of the safe-id cap propagates
# to both validators automatically.
_SEG = SAFE_ID_REGEX.removeprefix("^").removesuffix("$")
_NAME_PATTERN = re.compile(rf"^{_SEG}-{_SEG}$")


def _validate_tmux_session_name(name: str) -> None:
    """Raise ``ValueError`` if ``name`` is not a valid two-segment tmux name."""
    if _NAME_PATTERN.match(name) is None:
        raise ValueError(f"tmux_session_name failed regex {_NAME_PATTERN.pattern}: {name!r}")


class PtySessionClosedError(RuntimeError):
    """Raised by ``subscribe`` / ``unsubscribe`` after ``close()`` has returned.

    Mirrors the named-exception idiom from ``tmux_session.TmuxError`` —
    callers branch on type identity, not on attribute fields. R12.
    """


_SESSION_CLOSED_MSG = "session is closed"

# controls-06 #15 — scrollback replay tuning.
# tmux's capture-pane defaults to the visible viewport only; `-S -N`
# extends backward into the pane's scrollback ring. 3000 lines ≈
# 100KB of text at average autopilot phase density — roughly 5 min
# of chain output. Matches the order of magnitude industry tools use
# (kubectl logs --tail defaults to 10; Heroku to 100; CloudWatch Live
# Tail to "last 1-5 minutes"); operators who want more can re-attach
# after sending a fresh tmux pane scroll or extend this constant.
_SCROLLBACK_LINES: int = 3000
# 2.0s timeout balances responsiveness vs honoring slow tmux servers
# (a busy macOS box can take >100 ms to capture 3000 lines of pane).
# On timeout the live-attach path is unaffected — the operator simply
# loses the history seed for that connection.
_SCROLLBACK_TIMEOUT_S: float = 2.0


def _capture_scrollback(tmux_session_name: str) -> bytes:
    """Shell out to ``tmux capture-pane`` and return scrollback bytes.

    Flags:
        -p    print to stdout (not into a paste buffer)
        -e    preserve ANSI escape sequences (color, cursor moves)
              so xterm.js re-renders the original styling
        -J    join wrapped lines that tmux split at the pane edge
        -S -N start N lines above the current pane top

    All failure modes (no tmux binary, dead session, timeout) return
    b"" so the caller (the WS bridge subscribe path) can fall through
    to the live-attach behaviour unchanged.

    controls-07 #10 — every outcome is logged so the operator can
    diagnose "Connected — waiting for output" against the audit
    surface. Pre-#10 a silent b"" left no trace of WHY: tmux missing
    from PATH, returncode!=0, timeout, or genuinely empty pane all
    looked identical to the WS bridge. Now each failure path names
    its cause and the success path reports the byte count.
    """
    argv = [
        "tmux", "capture-pane", "-p", "-e", "-J",
        "-S", f"-{_SCROLLBACK_LINES}",
        "-t", tmux_session_name,
    ]
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            timeout=_SCROLLBACK_TIMEOUT_S,
            check=False,
        )
    except subprocess.TimeoutExpired:
        _write_scrollback_audit("timeout", tmux_session_name, timeout_s=_SCROLLBACK_TIMEOUT_S)
        return b""
    except FileNotFoundError as exc:
        _write_scrollback_audit("tmux_not_on_path", tmux_session_name, error=str(exc))
        return b""
    if result.returncode != 0:
        stderr = (result.stderr or b"").decode("utf-8", errors="replace").strip()
        _write_scrollback_audit(
            "tmux_nonzero_exit", tmux_session_name,
            exit_code=result.returncode, stderr=stderr[:200],
        )
        return b""
    _write_scrollback_audit("ok", tmux_session_name, bytes_captured=len(result.stdout))
    return result.stdout


@runtime_checkable
class PtySession(Protocol):
    """Four-method fanout contract.

    Implementations multicast every output chunk to every registered
    subscriber's ``callback(chunk)`` exactly once (R5). The Protocol
    surface carries NO write-direction method by construction — the
    WebSocket bridge has nothing to forward an inbound client message
    to (DN-4 / RSK-4).

    controls-06 #15 added ``current_scrollback()`` so the WS bridge
    can seed a new subscriber with the tmux pane's scrollback
    history before live frames arrive (industry-standard
    "replay-then-tail" log-viewer pattern — GitHub Actions / Vercel
    / Render / Heroku / kubectl logs / docker logs / CloudWatch Live
    Tail / Buildkite all converge on this).
    """

    def subscribe(self, callback: Callable[[bytes], Awaitable[None]]) -> None: ...

    def unsubscribe(self, callback: Callable[[bytes], Awaitable[None]]) -> None: ...

    def close(self) -> None: ...

    def current_scrollback(self) -> bytes: ...


__all__ = [
    "FakePtySession",
    "PtySession",
    "PtySessionClosedError",
    "RealPtySession",
]


# ---------------------------------------------------------------------------
# Placeholder classes — implementations land in subsequent TDD steps.
# ---------------------------------------------------------------------------


_Subscriber = Callable[[bytes], Awaitable[None]]


class _FanoutRegistry:
    """Subscriber bookkeeping + snapshot-based broadcast.

    Single-thread asyncio invariant: every state mutation runs on the
    event loop's single thread. ``add`` / ``remove`` / ``close`` are
    synchronous; ``broadcast`` is the only coroutine. Composed (not
    inherited) by ``RealPtySession`` and ``FakePtySession`` so each
    implementation keeps its read-loop focused (SOLID SRP).

    Implements R5 (fanout exactness), R6 (mid-stream unsubscribe),
    R7 (in-flight unsubscribe via ``_pending_removes``), R8 (unknown
    callback → ``KeyError``), R9 (subscriber exception → log + auto-
    unsubscribe), R12 (closed-state gate), R13 (idempotent close).
    """

    def __init__(self) -> None:
        # Python dict preserves insertion order — used as an ordered set
        # of subscribers. ``None`` value is a sentinel; only keys matter.
        self._subs: dict[_Subscriber, None] = {}
        self._closed: bool = False
        self._iterating: bool = False
        self._pending_removes: set[_Subscriber] = set()

    def add(self, callback: _Subscriber) -> None:
        if self._closed:
            raise PtySessionClosedError("registry is closed")
        if callback in self._subs:
            raise ValueError(f"already subscribed: {callback!r}")
        self._subs[callback] = None

    def remove(self, callback: _Subscriber) -> None:
        if self._closed:
            raise PtySessionClosedError("registry is closed")
        if callback not in self._subs:
            raise KeyError(f"not subscribed: {callback!r}")
        if self._iterating:
            self._pending_removes.add(callback)
        else:
            del self._subs[callback]

    async def broadcast(self, chunk: bytes) -> None:
        if self._closed:
            return
        snapshot = list(self._subs)
        self._iterating = True
        try:
            for cb in snapshot:
                if cb in self._pending_removes:
                    # A sibling callback earlier in THIS iteration called
                    # remove(cb) on a callback later in the snapshot —
                    # the staged removal short-circuits the impending
                    # invocation. F17 covers this branch directly.
                    continue
                try:
                    await cb(chunk)
                except asyncio.CancelledError:
                    # Control-flow signal (event loop is cancelling the
                    # surrounding task) — re-raise out of broadcast.
                    # The `finally` block below still flushes
                    # `_pending_removes` before propagation.
                    raise
                except Exception as exc:
                    logger.warning(
                        "subscriber callback raised %s; auto-unsubscribing",
                        type(exc).__name__,
                    )
                    self._pending_removes.add(cb)
        finally:
            if self._closed:
                # close() ran from inside a callback (F14). It already
                # cleared _subs and _pending_removes; skip the pop loop.
                self._iterating = False
                self._pending_removes.clear()
            else:
                for cb in self._pending_removes:
                    self._subs.pop(cb, None)
                self._pending_removes.clear()
                self._iterating = False

    def close(self) -> None:
        # Idempotent (R13) — safe to call from inside a callback (F14)
        # and safe to call twice.
        self._closed = True
        self._subs.clear()
        self._pending_removes.clear()


class _PtyHandle(Protocol):
    """Structural protocol for the minimal pty surface ``_read_loop`` uses.

    Production: ``ptyprocess.PtyProcess``. Tests: ``FakeHandle``.
    """

    def read(self, size: int) -> bytes: ...

    def close(self) -> None: ...


class _PtySpawner(Protocol):
    """Injectable factory for ``_PtyHandle`` instances.

    Production: ``_PtyProcessSpawner`` (delegates to
    ``ptyprocess.PtyProcess.spawn``). Tests: ``FakeSpawner``.
    """

    def spawn(self, argv: Sequence[str]) -> _PtyHandle: ...


class _PtyProcessSpawner:
    """Production spawner — the only place ``ptyprocess`` is referenced.

    Lazy-imported so the module remains import-time-safe on hosts where
    ``ptyprocess`` is not installed (R23 substrate). The Real smoke test
    (S1) is the only test that exercises this path; every unit test
    injects a ``FakeSpawner`` instead.
    """

    def spawn(self, argv: Sequence[str]) -> _PtyHandle:
        from ptyprocess import PtyProcess  # local import — keeps the import-graph fence clean

        handle: _PtyHandle = PtyProcess.spawn(list(argv))
        return handle


_DEFAULT_SPAWNER: _PtySpawner = _PtyProcessSpawner()


class RealPtySession:
    """Wraps one ``ptyprocess.PtyProcess`` per named tmux session.

    Attaches via ``tmux attach -r -t <name>`` (OQ-2). Reads bytes in a
    private ``_read_loop`` coroutine and multicasts via
    ``_FanoutRegistry``. The Protocol surface has NO write-direction
    method by construction; the read-only attach flag ``-r`` is a
    defense-in-depth backup to DN-4 / RSK-4. R14-R17.

    Single-thread asyncio: every state mutation runs on one thread.
    Concurrent construction for the same tmux session name is the
    CALLER's invariant (mirrors ``status_helper.py:7``); the helper
    does not coordinate.
    """

    def __init__(
        self,
        tmux_session_name: str,
        *,
        spawner: _PtySpawner | None = None,
    ) -> None:
        _validate_tmux_session_name(tmux_session_name)
        self._tmux_session_name = tmux_session_name
        active_spawner: _PtySpawner = spawner if spawner is not None else _DEFAULT_SPAWNER
        # spawn FIRST so a spawner failure propagates verbatim before
        # any internal state is allocated (R9 / Real edge §3).
        self._pty: _PtyHandle = active_spawner.spawn(
            ["tmux", "attach", "-r", "-t", tmux_session_name]
        )
        self._registry = _FanoutRegistry()
        self._closed: bool = False
        self._loop = asyncio.get_running_loop()
        self._task: asyncio.Task[None] = self._loop.create_task(self._read_loop())

    async def _read_loop(self) -> None:
        # SIGHUP behavior: when the underlying tmux pane closes, the
        # ptyprocess raises EOFError on the next read. That is a clean
        # lifecycle terminus, not a bug (R11).
        while not self._closed:
            try:
                chunk = await self._loop.run_in_executor(None, self._pty.read, 4096)
            except EOFError:
                logger.warning(
                    "pty SIGHUP / EOFError on tmux session %s",
                    self._tmux_session_name,
                )
                self._close_internal()
                return
            except asyncio.CancelledError:
                # close() cancelled the task; let it unwind.
                raise
            if self._closed:
                # close() ran while we were blocked in run_in_executor —
                # drop the chunk and exit cleanly.
                return
            if not chunk:
                # Transient empty read (R-1 risk: platform-dependent).
                # The ``sleep(0)`` yield prevents a tight loop saturating
                # the executor worker if the platform returns b"" on
                # idle reads.
                await asyncio.sleep(0)
                continue
            await self._registry.broadcast(chunk)

    def subscribe(self, callback: Callable[[bytes], Awaitable[None]]) -> None:
        if self._closed:
            raise PtySessionClosedError(_SESSION_CLOSED_MSG)
        self._registry.add(callback)

    def unsubscribe(self, callback: Callable[[bytes], Awaitable[None]]) -> None:
        if self._closed:
            raise PtySessionClosedError(_SESSION_CLOSED_MSG)
        self._registry.remove(callback)

    def current_scrollback(self) -> bytes:
        """controls-06 #15 — capture the tmux pane's recent scrollback.

        Returns the last ~3000 lines of pane content (ANSI bytes
        preserved) so the WS bridge can seed new subscribers with
        history. Failure modes collapse to b"" — see
        ``_capture_scrollback`` docstring.
        """
        return _capture_scrollback(self._tmux_session_name)

    def close(self) -> None:
        if self._closed:
            return  # R13 idempotent
        self._close_internal()

    def _close_internal(self) -> None:
        self._closed = True
        self._registry.close()
        task = getattr(self, "_task", None)
        if task is not None and not task.done():
            # Skip task.cancel() if we are the read-loop ourselves
            # (EOFError path R11, or subscriber-callback close path):
            # cancelling our own task would raise CancelledError into
            # whoever is awaiting it. The loop's `not self._closed`
            # check exits it cleanly on the next iteration instead.
            # `asyncio.current_task()` raises RuntimeError only when
            # called outside any running event loop (e.g. from an
            # executor thread); treat that as "definitely not us" and
            # cancel.
            try:
                current = asyncio.current_task()
            except RuntimeError:
                current = None
            if current is not task:
                task.cancel()
        try:
            self._pty.close()
        except Exception:
            # Defensive: a failing close on a broken pty should not
            # mask a higher-level lifecycle event.
            logger.warning(
                "pty close raised on tmux session %s; ignoring",
                self._tmux_session_name,
            )


_FailureMode = Literal["none", "raise-on-read", "stall"]


class FakePtySession:
    """Scripted-bytes test substrate; read-only by construction.

    ``write()`` raises ``NotImplementedError`` BEFORE touching any
    internal sink, and ``assert_no_inbound_bytes()`` proves no bytes
    reached an internal buffer from a unit test (R19 / R26 / DN-4).

    Two controlled-failure modes:
      * ``"raise-on-read"`` — at ``failure_step``, the read loop raises
        ``failure_exc`` directly (NOT via the R9 subscriber-exception
        path). The Fake auto-closes per R10. K5 asserts no WARNING is
        logged (the exception itself is the diagnostic).
      * ``"stall"`` — at ``failure_step``, the read loop awaits
        ``stall_event`` indefinitely. The test resolves the event to
        resume; ``extend(chunks)`` may append new bytes before the
        resume (K6/K9 — backpressure substrate for the Phase 3
        terminal-websocket-bridge task).

    No ``ptyprocess`` / ``subprocess`` / ``tmux`` references reach
    instance state (R22 — verified structurally by K7).
    """

    def __init__(
        self,
        script: Sequence[bytes],
        *,
        failure_mode: _FailureMode = "none",
        failure_step: int = 0,
        failure_exc: Exception | None = None,
        stall_event: asyncio.Event | None = None,
        scrollback: bytes = b"",
    ) -> None:
        self._script: list[bytes] = list(script)
        self._registry = _FanoutRegistry()
        self._closed: bool = False
        self._chunks_broadcast: int = 0
        # R22 / no-write proof: this list is NEVER appended to anywhere
        # in this class — write() raises BEFORE any state mutation. The
        # assertion in tests is structural (len == 0).
        self._inbound_payloads: list[bytes] = []
        self._failure_mode: _FailureMode = failure_mode
        self._failure_step: int = failure_step
        self._failure_exc: Exception | None = failure_exc
        self._stall_event: asyncio.Event = (
            stall_event if stall_event is not None else asyncio.Event()
        )
        # controls-06 #15 — scripted scrollback payload for tests
        # exercising the WS-bridge replay-then-tail seed. Default b""
        # means existing tests see no scrollback (cycle-15 is additive).
        self._scrollback: bytes = scrollback
        self._task: asyncio.Task[None] = asyncio.get_running_loop().create_task(self._read_loop())

    async def _read_loop(self) -> None:
        # Stall gate BEFORE the script-exhaustion check so K9 ("stall at
        # idx==len(self._script), test extend()s the script, then
        # resumes") works: the loop reaches idx=failure_step, stalls,
        # the test mutates self._script via extend(), the event is set,
        # the script-exhaustion check runs against the new length, and
        # the broadcast resumes. If exhaustion were checked first, the
        # loop would exit before the stall could fire.
        idx = 0
        try:
            while not self._closed:
                if self._failure_mode == "stall" and idx == self._failure_step:
                    # One-shot stall — once the event is set, idx
                    # advances past failure_step and the guard becomes
                    # False forever after.
                    await self._stall_event.wait()
                if idx >= len(self._script):
                    break
                if (
                    self._failure_mode == "raise-on-read"
                    and idx == self._failure_step
                    and self._failure_exc is not None
                ):
                    # R20: this branch is the read-loop's OWN exception
                    # path — distinct from R9 (subscriber callback
                    # exception inside _FanoutRegistry.broadcast). The
                    # implementation does not emit a WARNING; the
                    # exception itself is the diagnostic. K5 asserts
                    # `_pty_session_warnings(caplog) == []`.
                    self._close_internal()
                    raise self._failure_exc
                chunk = self._script[idx]
                idx += 1
                self._chunks_broadcast += 1
                await self._registry.broadcast(chunk)
        finally:
            if not self._closed:
                # Script exhausted cleanly (Fake edge case § 1).
                self._close_internal()

    def subscribe(self, callback: Callable[[bytes], Awaitable[None]]) -> None:
        if self._closed:
            raise PtySessionClosedError(_SESSION_CLOSED_MSG)
        self._registry.add(callback)

    def unsubscribe(self, callback: Callable[[bytes], Awaitable[None]]) -> None:
        if self._closed:
            raise PtySessionClosedError(_SESSION_CLOSED_MSG)
        self._registry.remove(callback)

    def current_scrollback(self) -> bytes:
        """controls-06 #15 — test substrate returns the configured
        scrollback (default b""). Tests that exercise the WS-bridge
        replay-then-tail path can set this via the keyword-only
        ``scrollback`` constructor parameter, or by writing to
        ``self._scrollback`` directly."""
        return self._scrollback

    def close(self) -> None:
        if self._closed:
            return  # R13 idempotent
        self._close_internal()

    def _close_internal(self) -> None:
        self._closed = True
        self._registry.close()

    # ---- Test surface — NOT part of the PtySession Protocol ---------------

    def write(self, data: bytes) -> None:
        # R19: raise BEFORE any state mutation. The _inbound_payloads
        # list is never appended to anywhere in this class — the
        # assertion in tests is structural. The closed-state check is
        # intentionally NOT performed first: the no-write invariant is
        # stronger than the closed-state check (Fake edge case § 3 /
        # K8).
        raise NotImplementedError("FakePtySession is read-only by construction (DN-4)")

    def assert_no_inbound_bytes(self) -> None:
        assert len(self._inbound_payloads) == 0, "no-write invariant breached"

    def extend(self, chunks: Iterable[bytes]) -> None:
        """Append bytes to the script while in stall mode (K9)."""
        self._script.extend(chunks)
