"""Unit tests for dashboard/server/pty_session.py.

Covers TESTPLAN rows M1-M9 (TestModuleShape), N1-N4 (TestNameValidation),
F1-F17 (TestFanoutRegistry), R1-R12 (TestRealPtySession), K1-K12
(TestFakePtySession), L1-L2 (TestProtocolLiskov), H1
(TestHostileEnvironment), and S1 (TestRealPtySessionSmoke) — see
docs/INPROGRESS_Feature_pty-session-helper/TESTPLAN.md.

R25: asyncio_mode=auto at pyproject.toml:44. NO @pytest.mark.asyncio
decorators in this file. A grep -n '@pytest.mark.asyncio'
dashboard/tests/test_pty_session.py MUST return zero matches.

Risk R-6 (PLAN.md): ``_FanoutRegistry`` is module-private but imported
directly here to cover R5-R9 in isolation; testing it via
``FakePtySession`` would couple the registry's tests to the Fake's
read-loop semantics.
"""

from __future__ import annotations

import ast
import asyncio
import inspect
import logging
import re
import shutil
import sys
from collections.abc import Awaitable, Callable, Sequence
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from dashboard.server import pty_session  # noqa: E402
from dashboard.server.pty_session import (  # noqa: E402
    _NAME_PATTERN,
    FakePtySession,
    PtySession,
    PtySessionClosedError,
    RealPtySession,
    _FanoutRegistry,
    _validate_tmux_session_name,
    logger,
)

_LOGGER_NAME = "dashboard.server.pty_session"


def _pty_session_warnings(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [
        r.getMessage()
        for r in caplog.records
        if r.name == _LOGGER_NAME and r.levelno >= logging.WARNING
    ]


def _module_imports(source: str) -> set[str]:
    """Collect every ``ast.Import.alias.name`` and ``ast.ImportFrom.module``."""
    tree = ast.parse(source)
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module is not None:
                names.add(node.module)
    return names


# ---------------------------------------------------------------------------
# Mocks
# ---------------------------------------------------------------------------


class FakeHandle:
    """Implements the ``_PtyHandle`` Protocol surface for unit tests.

    ``read_script`` is a FIFO list of ``bytes`` (returned) or
    ``BaseException`` subclasses / instances (raised). Each ``read`` size
    is recorded into ``read_calls`` for argv-shape assertions.
    """

    def __init__(
        self, read_script: list[bytes | type[BaseException] | BaseException] | None = None
    ) -> None:
        self.read_script: list[bytes | type[BaseException] | BaseException] = (
            list(read_script) if read_script is not None else [b"hello\n", EOFError()]
        )
        self.closed = False
        self.close_calls = 0
        self.read_calls: list[int] = []

    def read(self, size: int) -> bytes:
        self.read_calls.append(size)
        if not self.read_script:
            # Default: block forever once exhausted by yielding EOFError;
            # tests size scripts to expected call counts.
            raise EOFError("script exhausted")
        entry = self.read_script.pop(0)
        if isinstance(entry, type) and issubclass(entry, BaseException):
            raise entry()
        if isinstance(entry, BaseException):
            raise entry
        assert isinstance(entry, bytes)
        return entry

    def close(self) -> None:
        self.closed = True
        self.close_calls += 1


class FakeSpawner:
    """Implements ``_PtySpawner``; records argv and returns preconfigured handles."""

    def __init__(self, handles: list[FakeHandle] | None = None) -> None:
        self.spawn_calls: list[list[str]] = []
        self.handles: list[FakeHandle] = handles if handles is not None else [FakeHandle()]

    def spawn(self, argv: Sequence[str]) -> FakeHandle:
        self.spawn_calls.append(list(argv))
        idx = len(self.spawn_calls) - 1
        if idx >= len(self.handles):
            raise IndexError("FakeSpawner: handles exhausted")
        return self.handles[idx]


class RaisingSpawner:
    """``spawn(argv)`` raises ``FileNotFoundError('tmux')`` — Real edge §3."""

    def __init__(self) -> None:
        self.spawn_calls: list[list[str]] = []

    def spawn(self, argv: Sequence[str]) -> Any:
        self.spawn_calls.append(list(argv))
        raise FileNotFoundError("tmux")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def fake_spawner() -> FakeSpawner:
    return FakeSpawner()


@pytest.fixture
def fake_handle() -> FakeHandle:
    return FakeHandle()


@pytest.fixture
def captured_chunks() -> tuple[list[bytes], Callable[[bytes], Awaitable[None]]]:
    received: list[bytes] = []

    async def append(chunk: bytes) -> None:
        received.append(chunk)

    return received, append


@pytest.fixture(autouse=True)
def _reset_warn_filter_autouse() -> None:
    """No-op placeholder — documents the absence of module-level cache state.

    Mirrors ``test_status_helper.py:_reset_cache_autouse`` so the
    no-state invariant is grep-discoverable.
    """
    return None


# ---------------------------------------------------------------------------
# TestModuleShape (M1-M9)
# ---------------------------------------------------------------------------


class TestModuleShape:
    def test_m1_all_exports_exactly_four(self) -> None:
        assert sorted(pty_session.__all__) == sorted(
            ["FakePtySession", "PtySession", "PtySessionClosedError", "RealPtySession"]
        )

    def test_m2_pty_session_is_runtime_checkable_protocol(self) -> None:
        assert hasattr(PtySession, "_is_runtime_protocol")
        assert PtySession.__module__ == "dashboard.server.pty_session"

    def test_m3_protocol_declares_exactly_four_methods(self) -> None:
        # Protocol methods appear in __dict__ as plain functions.
        # controls-06 #15 added `current_scrollback` so the WS bridge can
        # seed late-attaching subscribers with tmux pane scrollback
        # (replay-then-tail pattern). DN-4 / RSK-4 forbidden write-
        # direction names still must not appear.
        declared = {
            name
            for name in vars(PtySession)
            if not name.startswith("_") and callable(vars(PtySession)[name])
        }
        assert declared == {"subscribe", "unsubscribe", "close", "current_scrollback"}
        for forbidden in ("read", "write", "send", "feed"):
            assert forbidden not in declared

    def test_m4_protocol_method_signatures_are_positional(self) -> None:
        sub_sig = inspect.signature(PtySession.subscribe)
        unsub_sig = inspect.signature(PtySession.unsubscribe)
        assert set(sub_sig.parameters) == {"self", "callback"}
        assert set(unsub_sig.parameters) == {"self", "callback"}
        for sig in (sub_sig, unsub_sig):
            cb = sig.parameters["callback"]
            assert cb.kind in (
                inspect.Parameter.POSITIONAL_OR_KEYWORD,
                inspect.Parameter.POSITIONAL_ONLY,
            )

    def test_m5_no_forbidden_top_level_imports(self) -> None:
        source = Path(pty_session.__file__).read_text()
        imports = _module_imports(source)
        forbidden = {"fastapi", "starlette", "pydantic", "uvicorn"}
        for name in imports:
            head = name.split(".")[0]
            assert head not in forbidden, f"forbidden import: {name}"

    def test_m6_first_party_imports_restricted(self) -> None:
        source = Path(pty_session.__file__).read_text()
        imports = _module_imports(source)
        dashboard_imports = {n for n in imports if n.startswith("dashboard.")}
        assert dashboard_imports <= {"dashboard.server.validation"}

    def test_m7_logger_identity(self) -> None:
        assert logger.name == _LOGGER_NAME

    def test_m8_no_print_or_stderr_in_source(self) -> None:
        source = inspect.getsource(pty_session)
        assert "print(" not in source
        assert "sys.stderr" not in source

    def test_m9_read_loop_is_private(self) -> None:
        assert "_read_loop" not in pty_session.__all__
        assert "_read_loop" not in dir(PtySession)


# ---------------------------------------------------------------------------
# TestNameValidation (N1-N4)
# ---------------------------------------------------------------------------


class TestNameValidation:
    @pytest.mark.parametrize(
        "name, expected",
        [
            # Valid: two safe-id segments joined by a dash. Inner dashes
            # are permitted (mirrors tmux_session._NAME_PATTERN at
            # tmux_session.py:38 — `pty-session-helper`-style feature
            # ids must round-trip through deterministic_name).
            ("autopilot-feature_x", True),
            ("autopilot-feat-001", True),
            ("chain-plan-x", True),
            ("autopilot-pty-session-helper", True),
            ("a-" + "x" * 64, True),  # second segment at 64-char upper bound
            # Invalid: missing the joining dash, or one segment is empty,
            # or a segment contains a character outside the safe-id class.
            ("nodash", False),
            ("autopilot-", False),
            ("-feature", False),
            ("autopilot.feature", False),
            ("autopilot/feature", False),
            ("a-" + "x" * 65, False),  # second segment over the cap
        ],
    )
    def test_n1_name_pattern_match(self, name: str, expected: bool) -> None:
        match = _NAME_PATTERN.match(name)
        assert (match is not None) is expected

    def test_n2_segment_with_disallowed_char_rejected(self) -> None:
        # The regex composes two SAFE_ID_REGEX segments — characters
        # outside [a-zA-Z0-9_-] fail. ``.`` is the canonical example.
        assert _NAME_PATTERN.match("chain.poc.watchfloor") is None

    def test_n3_validator_raises_with_diagnostic(self) -> None:
        with pytest.raises(ValueError) as exc:
            _validate_tmux_session_name("autopilot-")
        msg = str(exc.value)
        assert "autopilot-" in msg
        assert _NAME_PATTERN.pattern in msg

    def test_n4_derived_from_safe_id_regex(self) -> None:
        # Guards against literal duplication regression if validation regex loosens.
        assert "SAFE_ID_REGEX" in inspect.getsource(pty_session)


# ---------------------------------------------------------------------------
# TestFanoutRegistry (F1-F17)
# ---------------------------------------------------------------------------


class _Recorder:
    """Bound async callable that records every chunk it receives."""

    def __init__(self, label: str | None = None) -> None:
        self.label = label
        self.received: list[bytes] = []

    async def __call__(self, chunk: bytes) -> None:
        self.received.append(chunk)


class TestFanoutRegistry:
    async def test_f1_empty_registry_no_callbacks(self) -> None:
        reg = _FanoutRegistry()
        await reg.broadcast(b"x")
        assert reg._iterating is False

    async def test_f2_two_subscribers_one_chunk_in_order(self) -> None:
        reg = _FanoutRegistry()
        order: list[tuple[str, bytes]] = []

        async def cb_a(chunk: bytes) -> None:
            order.append(("A", chunk))

        async def cb_b(chunk: bytes) -> None:
            order.append(("B", chunk))

        reg.add(cb_a)
        reg.add(cb_b)
        await reg.broadcast(b"x")
        assert order == [("A", b"x"), ("B", b"x")]

    async def test_f3_three_chunks_in_order_no_drops(self) -> None:
        reg = _FanoutRegistry()
        a, b = _Recorder("A"), _Recorder("B")
        reg.add(a)
        reg.add(b)
        for chunk in [b"1", b"2", b"3"]:
            await reg.broadcast(chunk)
        assert a.received == [b"1", b"2", b"3"]
        assert b.received == [b"1", b"2", b"3"]

    async def test_f4_unsubscribe_between_chunks(self) -> None:
        reg = _FanoutRegistry()
        a, b = _Recorder("A"), _Recorder("B")
        reg.add(a)
        reg.add(b)
        await reg.broadcast(b"1")
        reg.remove(a)
        await reg.broadcast(b"2")
        await reg.broadcast(b"3")
        assert a.received == [b"1"]
        assert b.received == [b"1", b"2", b"3"]

    async def test_f5_self_unsubscribe_during_broadcast(self) -> None:
        reg = _FanoutRegistry()
        b = _Recorder("B")

        async def cb_a(chunk: bytes) -> None:
            reg.remove(cb_a)

        reg.add(cb_a)
        reg.add(b)
        await reg.broadcast(b"1")
        await reg.broadcast(b"2")
        assert b.received == [b"1", b"2"]

    async def test_f6_unknown_callback_raises_keyerror(self) -> None:
        reg = _FanoutRegistry()

        async def never_added(chunk: bytes) -> None:
            return None

        with pytest.raises(KeyError) as exc:
            reg.remove(never_added)
        assert repr(never_added) in str(exc.value) or "never_added" in str(exc.value)

    async def test_f7_resubscribe_raises_valueerror(self) -> None:
        reg = _FanoutRegistry()
        a = _Recorder("A")
        reg.add(a)
        with pytest.raises(ValueError) as exc:
            reg.add(a)
        assert "already subscribed" in str(exc.value)
        await reg.broadcast(b"x")
        assert a.received == [b"x"]

    async def test_f8_subscriber_raise_isolated_with_warning(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        reg = _FanoutRegistry()
        b, c = _Recorder("B"), _Recorder("C")

        async def cb_a(chunk: bytes) -> None:
            raise RuntimeError("boom")

        reg.add(cb_a)
        reg.add(b)
        reg.add(c)
        with caplog.at_level(logging.WARNING, logger=_LOGGER_NAME):
            await reg.broadcast(b"1")
        assert b.received == [b"1"]
        assert c.received == [b"1"]
        assert cb_a not in reg._subs
        warnings = _pty_session_warnings(caplog)
        assert len(warnings) == 1
        assert "RuntimeError" in warnings[0]

    async def test_f9_no_reinvoke_after_auto_unsubscribe(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        reg = _FanoutRegistry()
        b, c = _Recorder("B"), _Recorder("C")
        a_calls = 0

        async def cb_a(chunk: bytes) -> None:
            nonlocal a_calls
            a_calls += 1
            raise RuntimeError("boom")

        reg.add(cb_a)
        reg.add(b)
        reg.add(c)
        with caplog.at_level(logging.WARNING, logger=_LOGGER_NAME):
            await reg.broadcast(b"1")
            await reg.broadcast(b"2")
        assert a_calls == 1
        assert b.received == [b"1", b"2"]
        assert c.received == [b"1", b"2"]
        assert len(_pty_session_warnings(caplog)) == 1

    async def test_f10_cancelled_error_reraises_not_auto_removed(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        reg = _FanoutRegistry()

        async def cb_a(chunk: bytes) -> None:
            raise asyncio.CancelledError()

        reg.add(cb_a)
        with caplog.at_level(logging.WARNING, logger=_LOGGER_NAME):
            with pytest.raises(asyncio.CancelledError):
                await reg.broadcast(b"1")
        assert cb_a in reg._subs
        assert _pty_session_warnings(caplog) == []

    async def test_f11_subscribe_during_in_flight_broadcast(self) -> None:
        reg = _FanoutRegistry()
        b = _Recorder("B")

        async def cb_a(chunk: bytes) -> None:
            if b not in reg._subs:
                reg.add(b)

        reg.add(cb_a)
        await reg.broadcast(b"1")
        assert b.received == []
        await reg.broadcast(b"2")
        assert b.received == [b"2"]

    async def test_f12_subscribe_after_close_raises(self) -> None:
        reg = _FanoutRegistry()
        a = _Recorder("A")
        reg.close()
        with pytest.raises(PtySessionClosedError):
            reg.add(a)
        with pytest.raises(PtySessionClosedError):
            reg.remove(a)

    async def test_f13_close_idempotent(self) -> None:
        reg = _FanoutRegistry()
        reg.close()
        reg.close()  # no raise
        assert reg._closed is True
        assert len(reg._subs) == 0

    async def test_f14_close_from_inside_callback(self) -> None:
        reg = _FanoutRegistry()
        b, c = _Recorder("B"), _Recorder("C")

        async def cb_a(chunk: bytes) -> None:
            reg.close()

        reg.add(cb_a)
        reg.add(b)
        reg.add(c)
        await reg.broadcast(b"1")
        assert b.received == [b"1"]
        assert c.received == [b"1"]

        async def cb_x(chunk: bytes) -> None:
            return None

        with pytest.raises(PtySessionClosedError):
            reg.add(cb_x)

    async def test_f15_broadcast_after_close_short_circuits(self) -> None:
        reg = _FanoutRegistry()
        a = _Recorder("A")

        async def cb_close(chunk: bytes) -> None:
            reg.close()

        reg.add(cb_close)
        reg.add(a)
        await reg.broadcast(b"1")
        assert a.received == [b"1"]
        # Subsequent broadcast is a no-op because the registry is closed.
        await reg.broadcast(b"3")
        assert a.received == [b"1"]

    async def test_f16_pending_removes_flushed(self, caplog: pytest.LogCaptureFixture) -> None:
        reg = _FanoutRegistry()
        b = _Recorder("B")

        async def cb_a(chunk: bytes) -> None:
            raise RuntimeError("boom")

        reg.add(cb_a)
        reg.add(b)
        with caplog.at_level(logging.WARNING, logger=_LOGGER_NAME):
            await reg.broadcast(b"1")
        assert reg._pending_removes == set()

    async def test_f17_cross_subscriber_unsubscribe_skips_pending(self) -> None:
        reg = _FanoutRegistry()
        a = _Recorder("A")
        c = _Recorder("C")
        removed = [False]

        async def cb_b(chunk: bytes) -> None:
            if not removed[0]:
                reg.remove(a)
                removed[0] = True

        # Insertion order: B, A, C — cb_b stages cb_a for removal before
        # the iteration reaches cb_a, exercising the
        # `if callback in _pending_removes: skip` branch.
        reg.add(cb_b)
        reg.add(a)
        reg.add(c)
        await reg.broadcast(b"1")
        await reg.broadcast(b"2")
        assert a.received == []
        assert c.received == [b"1", b"2"]
        assert a not in reg._subs
        assert cb_b in reg._subs
        assert c in reg._subs


# ---------------------------------------------------------------------------
# TestRealPtySession (R1-R12)
# ---------------------------------------------------------------------------


async def _await_received(received: list[bytes], n: int, timeout: float = 1.0) -> None:
    """Spin until ``len(received) >= n`` or ``timeout`` expires."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while len(received) < n:
        if loop.time() > deadline:
            raise AssertionError(f"timeout: received={received!r}, expected >= {n}")
        await asyncio.sleep(0.01)


class TestRealPtySession:
    async def test_r1_construction_spawns_correct_argv(self, fake_spawner: FakeSpawner) -> None:
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            assert fake_spawner.spawn_calls == [
                ["tmux", "attach", "-r", "-t", "autopilot-pty-session-helper"]
            ]
            assert session._pty is fake_spawner.handles[0]
        finally:
            session.close()

    async def test_r2_invalid_name_rejected_before_spawn(self, fake_spawner: FakeSpawner) -> None:
        # "autopilot/feature" contains a character outside the safe-id
        # class, so it fails the regex.
        with pytest.raises(ValueError):
            RealPtySession("autopilot/feature", spawner=fake_spawner)
        assert fake_spawner.spawn_calls == []

    async def test_r3_subscribe_receives_chunk_via_read_loop(
        self,
        captured_chunks: tuple[list[bytes], Callable[[bytes], Awaitable[None]]],
    ) -> None:
        received, cb = captured_chunks
        spawner = FakeSpawner(handles=[FakeHandle(read_script=[b"hello\n", EOFError()])])
        session = RealPtySession("autopilot-pty-session-helper", spawner=spawner)
        try:
            session.subscribe(cb)
            await _await_received(received, 1, timeout=1.0)
            assert received == [b"hello\n"]
        finally:
            session.close()

    async def test_r4_subscribe_twice_spawn_once(self, fake_spawner: FakeSpawner) -> None:
        a, b = _Recorder("A"), _Recorder("B")
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            session.subscribe(a)
            session.subscribe(b)
            assert len(fake_spawner.spawn_calls) == 1
        finally:
            session.close()

    async def test_r5_read_loop_is_private(self, fake_spawner: FakeSpawner) -> None:
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            assert "_read_loop" not in pty_session.__all__
            assert hasattr(session, "_task")
            assert session._task is not None
        finally:
            session.close()

    async def test_r6_eof_triggers_close_and_warning(
        self,
        caplog: pytest.LogCaptureFixture,
        captured_chunks: tuple[list[bytes], Callable[[bytes], Awaitable[None]]],
    ) -> None:
        received, cb = captured_chunks
        handle = FakeHandle(read_script=[b"x", EOFError()])
        spawner = FakeSpawner(handles=[handle])
        with caplog.at_level(logging.WARNING, logger=_LOGGER_NAME):
            session = RealPtySession("autopilot-pty-session-helper", spawner=spawner)
            session.subscribe(cb)
            await asyncio.wait_for(session._task, timeout=1.0)
        assert session._closed is True
        assert handle.closed is True
        warnings = _pty_session_warnings(caplog)
        assert any(("SIGHUP" in w or "EOFError" in w) for w in warnings)
        assert any("autopilot-pty-session-helper" in w for w in warnings)

    async def test_r7_second_close_is_noop(self) -> None:
        handle = FakeHandle(read_script=[EOFError()])
        spawner = FakeSpawner(handles=[handle])
        session = RealPtySession("autopilot-pty-session-helper", spawner=spawner)
        await asyncio.wait_for(session._task, timeout=1.0)
        first_close_count = handle.close_calls
        session.close()
        assert handle.close_calls == first_close_count

    async def test_r8_subscribe_after_close_raises(self, fake_spawner: FakeSpawner) -> None:
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)

        async def cb(chunk: bytes) -> None:
            return None

        session.close()
        with pytest.raises(PtySessionClosedError):
            session.subscribe(cb)
        with pytest.raises(PtySessionClosedError):
            session.unsubscribe(cb)

    async def test_r9_spawner_raises_propagates(self) -> None:
        spawner = RaisingSpawner()
        with pytest.raises(FileNotFoundError) as exc:
            RealPtySession("autopilot-pty-session-helper", spawner=spawner)
        assert "tmux" in str(exc.value)
        assert spawner.spawn_calls == [
            ["tmux", "attach", "-r", "-t", "autopilot-pty-session-helper"]
        ]

    async def test_r10_transient_empty_read_does_not_break_loop(
        self,
        captured_chunks: tuple[list[bytes], Callable[[bytes], Awaitable[None]]],
    ) -> None:
        received, cb = captured_chunks
        handle = FakeHandle(read_script=[b"", b"data", EOFError()])
        spawner = FakeSpawner(handles=[handle])
        session = RealPtySession("autopilot-pty-session-helper", spawner=spawner)
        try:
            session.subscribe(cb)
            await asyncio.wait_for(session._task, timeout=1.0)
            assert received == [b"data"]
        finally:
            session.close()

    async def test_r11_spawn_argv_is_a_list(self, fake_spawner: FakeSpawner) -> None:
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            assert isinstance(fake_spawner.spawn_calls[0], list)
            assert fake_spawner.spawn_calls[0][0] == "tmux"
        finally:
            session.close()

    async def test_r12_close_from_subscriber_callback(self) -> None:
        handle = FakeHandle(read_script=[b"x", b"y", b"z"])
        spawner = FakeSpawner(handles=[handle])
        session = RealPtySession("autopilot-pty-session-helper", spawner=spawner)
        received: list[bytes] = []

        async def cb(chunk: bytes) -> None:
            received.append(chunk)
            session.close()

        session.subscribe(cb)
        await asyncio.wait_for(session._task, timeout=1.0)
        assert handle.closed is True
        assert received == [b"x"]


# ---------------------------------------------------------------------------
# TestScrollbackCapture (controls-06 #15 — Sb1-Sb6)
# ---------------------------------------------------------------------------


class TestScrollbackCapture:
    """controls-06 #15 — when a subscriber attaches to a tmux session
    that has been running, they should see the recent scrollback
    history instead of a blank screen until the next byte arrives.
    `current_scrollback()` shells out to ``tmux capture-pane -p -e -J
    -S -<N>`` and returns raw ANSI bytes. Failure modes (no tmux
    binary, session dead, timeout) all collapse to b"" so the live
    attach path stays unaffected."""

    async def test_sb1_capture_pane_argv_is_correct(
        self, monkeypatch: pytest.MonkeyPatch, fake_spawner: FakeSpawner
    ) -> None:
        captured_argv: list[list[str]] = []

        def fake_run(argv: list[str], **kwargs: object) -> object:
            captured_argv.append(argv)
            from types import SimpleNamespace
            return SimpleNamespace(returncode=0, stdout=b"history\n", stderr=b"")

        monkeypatch.setattr(pty_session.subprocess, "run", fake_run)
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            result = session.current_scrollback()
            assert result == b"history\n"
            assert len(captured_argv) == 1
            assert captured_argv[0] == [
                "tmux", "capture-pane", "-p", "-e", "-J",
                "-S", "-3000",
                "-t", "autopilot-pty-session-helper",
            ]
        finally:
            session.close()

    async def test_sb2_nonzero_exit_returns_empty(
        self, monkeypatch: pytest.MonkeyPatch, fake_spawner: FakeSpawner
    ) -> None:
        from types import SimpleNamespace
        monkeypatch.setattr(
            pty_session.subprocess, "run",
            lambda *_a, **_kw: SimpleNamespace(returncode=1, stdout=b"x", stderr=b"err"),
        )
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            assert session.current_scrollback() == b""
        finally:
            session.close()

    async def test_sb3_tmux_not_installed_returns_empty(
        self, monkeypatch: pytest.MonkeyPatch, fake_spawner: FakeSpawner
    ) -> None:
        def raise_fnf(*_a: object, **_kw: object) -> object:
            raise FileNotFoundError("tmux not in PATH")

        monkeypatch.setattr(pty_session.subprocess, "run", raise_fnf)
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            assert session.current_scrollback() == b""
        finally:
            session.close()

    async def test_sb4_timeout_returns_empty(
        self, monkeypatch: pytest.MonkeyPatch, fake_spawner: FakeSpawner
    ) -> None:
        import subprocess as sp

        def raise_timeout(*_a: object, **_kw: object) -> object:
            raise sp.TimeoutExpired(cmd="tmux capture-pane", timeout=2.0)

        monkeypatch.setattr(pty_session.subprocess, "run", raise_timeout)
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            assert session.current_scrollback() == b""
        finally:
            session.close()

    async def test_sb5_scrollback_preserves_ansi_bytes(
        self, monkeypatch: pytest.MonkeyPatch, fake_spawner: FakeSpawner
    ) -> None:
        """ANSI escape codes (color, cursor) MUST pass through
        verbatim — xterm.js re-renders them client-side. The `-e`
        flag in the argv is what asks tmux for that. Pin the byte
        equality so a refactor that strips color is caught."""
        from types import SimpleNamespace
        ansi = b"\x1b[31mred\x1b[0m\n"
        monkeypatch.setattr(
            pty_session.subprocess, "run",
            lambda *_a, **_kw: SimpleNamespace(returncode=0, stdout=ansi, stderr=b""),
        )
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            assert session.current_scrollback() == ansi
        finally:
            session.close()


# ---------------------------------------------------------------------------
# TestFakePtySession (K1-K12)
# ---------------------------------------------------------------------------


class TestFakePtySession:
    async def test_k1_script_iteration_in_order(
        self,
        captured_chunks: tuple[list[bytes], Callable[[bytes], Awaitable[None]]],
    ) -> None:
        received, cb = captured_chunks
        fake = FakePtySession(script=[b"a", b"b", b"c"])
        fake.subscribe(cb)
        await asyncio.wait_for(fake._task, timeout=1.0)
        assert received == [b"a", b"b", b"c"]
        assert fake._closed is True

    async def test_k2_empty_script_immediate_close(self) -> None:
        fake = FakePtySession(script=[])
        await asyncio.wait_for(fake._task, timeout=1.0)
        assert fake._chunks_broadcast == 0
        assert fake._closed is True
        fake.close()  # idempotent

    async def test_k3_write_raises_with_diagnostic(self) -> None:
        fake = FakePtySession(script=[b"a"])
        try:
            with pytest.raises(NotImplementedError) as exc:
                fake.write(b"injected")
            msg = str(exc.value)
            lowered = msg.lower()
            assert "read-only" in lowered or "DN-4" in msg
        finally:
            await asyncio.wait_for(fake._task, timeout=1.0)

    async def test_k4_no_inbound_after_write_attempt(
        self,
        captured_chunks: tuple[list[bytes], Callable[[bytes], Awaitable[None]]],
    ) -> None:
        received, cb = captured_chunks
        fake = FakePtySession(script=[b"a"])
        fake.subscribe(cb)
        with pytest.raises(NotImplementedError):
            fake.write(b"injected")
        fake.assert_no_inbound_bytes()
        assert fake._inbound_payloads == []
        await asyncio.wait_for(fake._task, timeout=1.0)
        # cb received chunks from the script — never `b"injected"`.
        assert b"injected" not in received

    async def test_k5_raise_on_read_closes_self_no_warning(
        self,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        received: list[bytes] = []

        async def cb(chunk: bytes) -> None:
            received.append(chunk)

        fake = FakePtySession(
            script=[b"first", b"second"],
            failure_mode="raise-on-read",
            failure_step=1,
            failure_exc=RuntimeError("scripted"),
        )
        fake.subscribe(cb)
        with caplog.at_level(logging.WARNING, logger=_LOGGER_NAME):
            with pytest.raises(RuntimeError, match="scripted"):
                await asyncio.wait_for(fake._task, timeout=1.0)
        assert received == [b"first"]
        assert fake._closed is True
        # R20 raise-on-read is the read-loop's OWN raise — distinct from
        # R9 (subscriber callback exception). No WARNING is logged.
        assert _pty_session_warnings(caplog) == []
        with pytest.raises(PtySessionClosedError):
            fake.subscribe(cb)

    async def test_k6_stall_then_resume(self) -> None:
        received: list[bytes] = []

        async def cb(chunk: bytes) -> None:
            received.append(chunk)

        event = asyncio.Event()
        fake = FakePtySession(
            script=[b"pre", b"post"],
            failure_mode="stall",
            failure_step=1,
            stall_event=event,
        )
        fake.subscribe(cb)
        await _await_received(received, 1, timeout=1.0)
        assert received == [b"pre"]
        event.set()
        await asyncio.wait_for(fake._task, timeout=1.0)
        assert received == [b"pre", b"post"]

    async def test_k7_no_fd_bearing_attributes(self) -> None:
        fake = FakePtySession(script=[b"x"])
        try:
            forbidden_re = re.compile(r"(pty|subprocess|tmux|fd|fileno)", re.IGNORECASE)
            for key in vars(fake):
                assert forbidden_re.search(key) is None, f"forbidden attr: {key}"
        finally:
            await asyncio.wait_for(fake._task, timeout=1.0)

    async def test_k8_write_after_close_still_raises_notimplemented(self) -> None:
        fake = FakePtySession(script=[])
        await asyncio.wait_for(fake._task, timeout=1.0)
        assert fake._closed is True
        with pytest.raises(NotImplementedError):
            fake.write(b"x")

    async def test_k9_stall_then_extend_resume(self) -> None:
        received: list[bytes] = []

        async def cb(chunk: bytes) -> None:
            received.append(chunk)

        event = asyncio.Event()
        fake = FakePtySession(
            script=[b"a"],
            failure_mode="stall",
            failure_step=1,
            stall_event=event,
        )
        fake.subscribe(cb)
        await _await_received(received, 1, timeout=1.0)
        assert received == [b"a"]
        fake.extend([b"b", b"c"])
        event.set()
        await asyncio.wait_for(fake._task, timeout=1.0)
        assert received == [b"a", b"b", b"c"]

    async def test_k10_satisfies_pty_session_protocol(self) -> None:
        fake = FakePtySession(script=[])
        try:
            assert isinstance(fake, PtySession)
        finally:
            await asyncio.wait_for(fake._task, timeout=1.0)

    async def test_k11_subscribe_after_close_raises(self) -> None:
        fake = FakePtySession(script=[])
        await asyncio.wait_for(fake._task, timeout=1.0)

        async def cb(chunk: bytes) -> None:
            return None

        with pytest.raises(PtySessionClosedError):
            fake.subscribe(cb)
        with pytest.raises(PtySessionClosedError):
            fake.unsubscribe(cb)

    async def test_k12_zero_subscribers_discards_chunks(self) -> None:
        fake = FakePtySession(script=[b"x", b"y"])
        await asyncio.wait_for(fake._task, timeout=1.0)
        assert fake._chunks_broadcast == 2


# ---------------------------------------------------------------------------
# TestProtocolLiskov (L1-L2)
# ---------------------------------------------------------------------------


class TestProtocolLiskov:
    async def test_l1_real_satisfies_protocol(self, fake_spawner: FakeSpawner) -> None:
        session = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        try:
            assert isinstance(session, PtySession)
        finally:
            session.close()

    async def test_l2_both_substitutable(self, fake_spawner: FakeSpawner) -> None:
        received: list[bytes] = []

        async def cb(chunk: bytes) -> None:
            received.append(chunk)

        def consume(session: PtySession) -> None:
            session.subscribe(cb)
            session.unsubscribe(cb)
            session.close()

        real = RealPtySession("autopilot-pty-session-helper", spawner=fake_spawner)
        fake = FakePtySession(script=[])
        consume(real)
        consume(fake)
        await asyncio.wait_for(fake._task, timeout=1.0)


# ---------------------------------------------------------------------------
# TestHostileEnvironment (H1)
# ---------------------------------------------------------------------------


class TestHostileEnvironment:
    def test_h1_skipif_decorator_present_in_source(self) -> None:
        # pytest.mark.skipif evaluates its condition at collection time,
        # so a runtime monkeypatch cannot retroactively change a marker
        # that has already produced a boolean. The robust replacement
        # is a static source-string assertion that the decorator is
        # present above the smoke-test class/function. Direct runtime
        # skip behaviour is self-verifying by pytest itself when the
        # suite runs on a tmux-less host.
        source = inspect.getsource(sys.modules[__name__])
        assert 'shutil.which("tmux") is None' in source


# ---------------------------------------------------------------------------
# TestRealPtySessionSmoke (S1) — gated on a real tmux binary
# ---------------------------------------------------------------------------


@pytest.mark.skipif(shutil.which("tmux") is None, reason="tmux missing")
class TestRealPtySessionSmoke:
    async def test_s1_live_tmux_roundtrip(self) -> None:
        from dashboard.server import tmux_session
        from dashboard.server.tmux_session import TmuxError

        name = "autopilot-pty-session-helper-smoke"
        received: list[bytes] = []
        event = asyncio.Event()

        async def cb(chunk: bytes) -> None:
            received.append(chunk)
            if b"hello" in chunk:
                event.set()

        session: RealPtySession | None = None
        try:
            try:
                tmux_session.start_session(
                    name, ["sh", "-c", "printf 'hello\\n'; sleep 0.5"], cwd=None
                )
            except TmuxError as exc:
                # tmux binary is present (shutil.which found it) but the
                # tmux server cannot start (sandbox: socket dir denied;
                # container: /tmp permission). Skip the smoke test —
                # this is the environment-degraded path documented in
                # TESTPLAN H2. The H1 source-string assertion still
                # holds because the @pytest.mark.skipif decorator above
                # carries the canonical predicate string.
                pytest.skip(f"tmux server unavailable: {exc}")

            session = RealPtySession(name)
            session.subscribe(cb)
            await asyncio.wait_for(event.wait(), timeout=2.0)
            assert any(b"hello" in c for c in received)
        finally:
            if session is not None:
                session.close()
            try:
                tmux_session.kill_session(name)
            except Exception:
                pass
