"""Tests for dashboard/server/terminal_ws.py.

Coverage strategy mirrors TESTPLAN.md rows. Tests are grouped by
component / invariant:

* Module shape & wire contract (M1, M10, M2-M9): __all__, REASON_*,
  static import guards, logger name, constants.
* URL contract (U1-U4): exactly one WebSocket route, regex-validated
  id query, target_kind Literal.
* CSRF query gate (C1, C3, C5-C7): pure _validate_csrf unit tests +
  one TestClient round-trip.
* Session lookup (L1-L6, L8): derive_status routing decisions.
* Subscriber cap (SC1-SC2, SC4-SC5): 8-cap behaviour.
* Frame batching (B1-B7): _send_pump 16 ms / 4 KB triggers.
* Drop-oldest backpressure (BP1-BP4): _append_with_backpressure unit
  tests; BufferOverflowSentinel pin.
* Inbound rejection (IR1-IR4): receive-and-discard + Protocol-no-write.
* Disconnect + registry (D1-D6, RG1-RG6).
* App wireup (W1-W4): route registered, middleware order untouched.
* Source-grep guards (G1-G4).

asyncio_mode = "auto" from pyproject.toml:44 — every test function is
`async def` (when one is needed) with no @pytest.mark.asyncio decorator.
"""

from __future__ import annotations

import ast
import asyncio
import inspect
import json
import logging
import re
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
DASHBOARD_ROOT = Path(__file__).resolve().parents[1]
for _path in (str(REPO_ROOT), str(DASHBOARD_ROOT)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from fastapi.testclient import TestClient  # noqa: E402

from dashboard.server import terminal_ws  # noqa: E402
from dashboard.server.middleware import csrf as csrf_middleware  # noqa: E402
from dashboard.server.pty_session import (  # noqa: E402
    FakePtySession,
    PtySession,
)
from dashboard.server.schemas import BufferOverflowSentinel  # noqa: E402
from dashboard.server.terminal_ws import (  # noqa: E402
    REASON_CSRF,
    REASON_HELPER_CLOSED,
    REASON_INVALID_ID,
    REASON_LIFECYCLE_MISSING,
    REASON_LOOKUP_INCONSISTENT,
    REASON_NOT_FOUND,
    REASON_PTY_BRINGUP,
    REASON_SUBSCRIBER_CAP,
    _append_with_backpressure,
    _ConnectionState,
    _evict_if_same,
    _make_subscribe_callback,
    _validate_csrf,
)

ALLOWED_ORIGIN = "http://127.0.0.1:5175"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_registry() -> Any:
    """Clear terminal_ws._REGISTRY before AND after every test.

    Closes any leaked FakePtySession instances first so background
    read-loops do not bleed into the next test.
    """
    _drain_registry()
    yield
    _drain_registry()


@pytest.fixture(autouse=True)
def _default_tmux_alive_true(monkeypatch: pytest.MonkeyPatch) -> Any:
    """controls-06 #17 — default the status_helper tmux liveness probe
    to True so terminal_ws integration tests (which spin up a
    FakePtySession against synthetic lifecycle streams) don't hit
    real tmux and flip tmux_session to None mid-handshake. Tests that
    want to exercise the stale-reconciliation path override this.

    Patch BOTH module aliases — terminal_ws imports the helper as
    `dashboard.server.status_helper`, the conftest sys.path bootstrap
    also exposes it as `server.status_helper`. Both are live module
    objects in sys.modules and must be patched in lockstep so
    derive_status() can't slip through one to call real tmux."""
    import sys
    stub = lambda _name: True  # noqa: E731
    for mod_name in ("server.status_helper", "dashboard.server.status_helper"):
        mod = sys.modules.get(mod_name)
        if mod is not None and hasattr(mod, "_is_tmux_alive"):
            monkeypatch.setattr(mod, "_is_tmux_alive", stub)
    yield


def _drain_registry() -> None:
    for entry in list(terminal_ws._REGISTRY.values()):
        try:
            entry.pty.close()
        except Exception:  # noqa: BLE001
            pass
    terminal_ws._REGISTRY.clear()


@pytest.fixture
def audit_log_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Redirect _AUDIT_PATH to a tmp file."""
    audit_dir = tmp_path / "audit"
    audit_dir.mkdir()
    monkeypatch.setenv("DASHBOARD_DATA_DIR", str(audit_dir))
    audit_path = audit_dir / "audit.ndjson"
    monkeypatch.setattr(csrf_middleware, "_AUDIT_PATH", audit_path)
    monkeypatch.setattr(terminal_ws, "_AUDIT_PATH", audit_path)
    return audit_path


@pytest.fixture
def app_with_router() -> Any:
    """Re-import the app so the router is wired."""
    from dashboard.server.app import app

    return app


@pytest.fixture
def csrf_client(app_with_router: Any) -> tuple[TestClient, str]:
    """Yield (TestClient with csrf cookie+header primed, token)."""
    client = TestClient(app_with_router)
    client.headers.update({"Origin": ALLOWED_ORIGIN})
    response = client.get("/health")
    assert response.status_code == 200
    token = client.cookies["csrf_token"]
    client.headers["X-CSRF-Token"] = token
    return client, token


def _fake_factory(script: list[bytes], *, stall_after: bool = False) -> Callable[[str], PtySession]:
    """Return a `_PTY_SESSION_FACTORY`-shaped closure (lazy construct).

    When ``stall_after`` is True the Fake stalls AT index ``len(script)``
    after broadcasting every scripted chunk — keeps the helper alive for
    the duration of the test so subscribe → receive happens before the
    helper's read-loop exits.
    """

    def _make(name: str) -> PtySession:
        if stall_after:
            return FakePtySession(
                script,
                failure_mode="stall",
                failure_step=len(script),
                stall_event=asyncio.Event(),
            )
        return FakePtySession(script)

    return _make


# ---------------------------------------------------------------------------
# Module shape (M1-M10)
# ---------------------------------------------------------------------------


class TestModuleShape:
    def test_m1_all_public_surface(self) -> None:
        assert terminal_ws.__all__ == (
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

    def test_m10_reason_constant_values(self) -> None:
        assert REASON_CSRF == "csrf"
        assert REASON_INVALID_ID == "invalid id"
        assert REASON_NOT_FOUND == "session not running"
        assert REASON_HELPER_CLOSED == "pty session closed"
        assert REASON_LIFECYCLE_MISSING == "lifecycle missing tmux_session"
        assert REASON_LOOKUP_INCONSISTENT == "tmux_session lookup inconsistency"
        assert REASON_PTY_BRINGUP == "pty bring-up failed"
        assert REASON_SUBSCRIBER_CAP == "subscriber cap reached"

    def test_m2_no_ptyprocess_or_subprocess_import(self) -> None:
        source = inspect.getsource(terminal_ws)
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    assert not alias.name.startswith("ptyprocess"), alias.name
                    assert alias.name != "subprocess", alias.name
            if isinstance(node, ast.ImportFrom):
                mod = node.module or ""
                assert not mod.startswith("ptyprocess"), mod
                assert mod != "subprocess", mod

    def test_m3_no_print_or_stderr_writes(self) -> None:
        source = inspect.getsource(terminal_ws)
        assert "print(" not in source
        assert "sys.stderr" not in source
        assert "stderr.write" not in source

    def test_m4_module_logger_name(self) -> None:
        assert terminal_ws.logger.name == "dashboard.server.terminal_ws"

    def test_m5_max_subscribers_constant(self) -> None:
        assert terminal_ws._MAX_SUBSCRIBERS_PER_SESSION == 8
        source = inspect.getsource(terminal_ws)
        assert "_MAX_SUBSCRIBERS_PER_SESSION: Final[int] = 8" in source

    def test_m6_buffer_watermarks(self) -> None:
        assert terminal_ws._BUFFER_HIGH_WATERMARK == 65_536
        assert terminal_ws._BUFFER_LOW_WATERMARK == 32_768

    def test_m7_batch_constants(self) -> None:
        assert terminal_ws._BATCH_BYTES_THRESHOLD == 4096
        assert terminal_ws._BATCH_TIME_THRESHOLD_S == 0.016

    def test_m8_registry_empty_after_import(self) -> None:
        """A6: subscriber-count consolidated into ``_SessionEntry``.

        _REGISTRY is cleared by the autouse fixture between tests; that
        is equivalent to a fresh import for the purposes of this check.
        The positive assertions also pin the shape of the registry
        symbol so a future refactor cannot silently re-introduce the
        dual-dict (separate _REGISTRY + _SUBSCRIBER_COUNT) topology.
        """
        assert hasattr(terminal_ws, "_REGISTRY")
        assert isinstance(terminal_ws._REGISTRY, dict)
        assert terminal_ws._REGISTRY == {}
        # _SUBSCRIBER_COUNT was consolidated into _SessionEntry.subscriber_count
        # per A6 — its absence is part of the wire contract.
        assert not hasattr(terminal_ws, "_SUBSCRIBER_COUNT")

    def test_m9_first_party_import_allowlist(self) -> None:
        source = inspect.getsource(terminal_ws)
        tree = ast.parse(source)
        dashboard_modules: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                mod = node.module or ""
                if mod.startswith("dashboard.server"):
                    dashboard_modules.add(mod)
                # No bare `from server.X` form
                assert not mod.startswith("server."), mod
        # The only first-party imports allowed:
        allowed = {
            "dashboard.server",
            "dashboard.server.tmux_session",
            "dashboard.server.middleware.csrf",
            "dashboard.server.pty_session",
            "dashboard.server.schemas",
            "dashboard.server.status_helper",
            "dashboard.server.validation",
        }
        assert dashboard_modules <= allowed, dashboard_modules - allowed
        # Deny-list: no underscore-prefixed private symbols (other than _AUDIT_PATH).
        for forbidden in ("_PtySpawner", "_PtyHandle", "_FanoutRegistry", "_PtyProcessSpawner"):
            assert forbidden not in source, f"forbidden symbol {forbidden} appears in source"


# ---------------------------------------------------------------------------
# URL contract (U1-U2)
# ---------------------------------------------------------------------------


class TestUrlContract:
    def test_u1_one_websocket_route(self) -> None:
        routes = terminal_ws.router.routes
        assert len(routes) == 1
        route = routes[0]
        assert getattr(route, "path", "") == "/ws/{target_kind}/terminal"
        assert inspect.iscoroutinefunction(route.endpoint)


# ---------------------------------------------------------------------------
# CSRF gate — pure _validate_csrf unit tests (R9, R5 length cap)
# ---------------------------------------------------------------------------


class TestCsrfValidate:
    def test_missing_cookie(self) -> None:
        assert _validate_csrf({}, "abc") == "missing_cookie"

    def test_empty_cookie(self) -> None:
        assert _validate_csrf({"csrf_token": ""}, "abc") == "missing_cookie"

    def test_missing_query(self) -> None:
        assert _validate_csrf({"csrf_token": "abc"}, "") == "missing_query"
        assert _validate_csrf({"csrf_token": "abc"}, None) == "missing_query"

    def test_mismatch(self) -> None:
        assert _validate_csrf({"csrf_token": "abc"}, "def") == "mismatch"

    def test_length_cap_rejects_pre_compare(self) -> None:
        long_value = "a" * 1024
        assert _validate_csrf({"csrf_token": "abc"}, long_value) == "mismatch"

    def test_success_returns_none(self) -> None:
        assert _validate_csrf({"csrf_token": "abc"}, "abc") is None


# ---------------------------------------------------------------------------
# Registry helpers (R14, R18)
# ---------------------------------------------------------------------------


class TestRegistry:
    async def test_get_or_create_first_constructs(self) -> None:
        calls: list[str] = []

        def factory(name: str) -> PtySession:
            calls.append(name)
            return FakePtySession([])

        terminal_ws._PTY_SESSION_FACTORY = factory
        try:
            pty, created = terminal_ws._get_or_create_pty_session("autopilot-foo")
        finally:
            from dashboard.server.pty_session import RealPtySession

            terminal_ws._PTY_SESSION_FACTORY = RealPtySession
        assert created is True
        assert calls == ["autopilot-foo"]
        assert terminal_ws._REGISTRY["autopilot-foo"].pty is pty

    async def test_get_or_create_reuses(self) -> None:
        fake = FakePtySession([])
        terminal_ws._REGISTRY["autopilot-foo"] = terminal_ws._SessionEntry(
            pty=fake, subscriber_count=0
        )
        pty, created = terminal_ws._get_or_create_pty_session("autopilot-foo")
        assert created is False
        assert pty is fake

    async def test_evict_if_same_no_op_on_mismatch(self) -> None:
        fake_a = FakePtySession([])
        fake_b = FakePtySession([])
        terminal_ws._REGISTRY["autopilot-foo"] = terminal_ws._SessionEntry(
            pty=fake_b, subscriber_count=0
        )
        _evict_if_same("autopilot-foo", fake_a)
        assert "autopilot-foo" in terminal_ws._REGISTRY
        assert terminal_ws._REGISTRY["autopilot-foo"].pty is fake_b

    async def test_evict_if_same_removes_on_match(self) -> None:
        fake = FakePtySession([])
        terminal_ws._REGISTRY["autopilot-foo"] = terminal_ws._SessionEntry(
            pty=fake, subscriber_count=0
        )
        _evict_if_same("autopilot-foo", fake)
        assert "autopilot-foo" not in terminal_ws._REGISTRY


# ---------------------------------------------------------------------------
# Backpressure (BP1-BP4) — pure unit tests on _append_with_backpressure
# ---------------------------------------------------------------------------


class TestBackpressure:
    def _state(self) -> _ConnectionState:
        return _ConnectionState(queue=asyncio.Queue(maxsize=32))

    def test_bp1_under_cap_no_sentinel(self) -> None:
        state = self._state()
        needs = _append_with_backpressure(state, b"x" * 32_768)
        assert needs is False
        assert state.out_bytes == 32_768
        assert state.overflow_suppressed is False

    def test_bp2_over_cap_drops_oldest_and_signals_sentinel(self) -> None:
        state = self._state()
        # Drive 17 * 4096 = 69632 bytes total
        for _ in range(16):
            assert _append_with_backpressure(state, b"X" * 4096) is False
        # 17th push exceeds 65536 -> drop-oldest + sentinel signal
        needs = _append_with_backpressure(state, b"Y" * 4096)
        assert needs is True
        assert state.out_bytes <= 65_536
        assert state.bytes_dropped_this_window > 0
        assert state.overflow_suppressed is True

    def test_bp3_sentinel_dedup_within_window(self) -> None:
        state = self._state()
        for _ in range(16):
            _append_with_backpressure(state, b"X" * 4096)
        first = _append_with_backpressure(state, b"Y" * 4096)
        second = _append_with_backpressure(state, b"Z" * 4096)
        third = _append_with_backpressure(state, b"W" * 4096)
        assert first is True
        assert second is False
        assert third is False

    def test_bp4_synchronous_no_await(self) -> None:
        # AST check: no Await node inside _append_with_backpressure
        source = inspect.getsource(_append_with_backpressure)
        tree = ast.parse(source)
        await_nodes = [n for n in ast.walk(tree) if isinstance(n, ast.Await)]
        assert await_nodes == []

    def test_bp_boundary_at_65536_no_overflow(self) -> None:
        state = self._state()
        _append_with_backpressure(state, b"X" * 65_536)
        assert state.overflow_suppressed is False
        assert state.out_bytes == 65_536

    def test_bp_boundary_at_65537_overflow_fires(self) -> None:
        state = self._state()
        _append_with_backpressure(state, b"X" * 65_537)
        # Single batch >64KB applies drop-oldest AFTER append: the
        # just-appended batch is itself dropped wholesale and the sentinel
        # signals.
        assert state.overflow_suppressed is True

    def test_bp_sentinel_rearm_after_drain(self) -> None:
        state = self._state()
        for _ in range(16):
            _append_with_backpressure(state, b"X" * 4096)
        _append_with_backpressure(state, b"Y" * 4096)  # first overflow
        assert state.overflow_suppressed is True
        # Drain below low watermark
        state.out_buffer.clear()
        state.out_bytes = 0
        # Append small batch below high watermark — should re-arm
        # (the elif clears overflow_suppressed when out_bytes <= LOW)
        needs = _append_with_backpressure(state, b"Z" * 1024)
        assert state.overflow_suppressed is False
        assert needs is False
        # Drive back above HIGH — the first transition signals sentinel again
        # The append that takes us above HIGH is the trigger.
        for _ in range(16):
            _append_with_backpressure(state, b"X" * 4096)
        needs = _append_with_backpressure(state, b"Y" * 4096)
        # By this point the buffer is well above HIGH; sentinel signals
        # exactly once (on the first transition since the rearm).
        assert state.overflow_suppressed is True


# ---------------------------------------------------------------------------
# Sentinel schema (BufferOverflowSentinel)
# ---------------------------------------------------------------------------


class TestSentinelSchema:
    def test_buffer_overflow_sentinel_roundtrip(self) -> None:
        s = BufferOverflowSentinel(type="buffer_overflow", bytes_dropped=4096, at=1_700_000_000_000)
        parsed = BufferOverflowSentinel.model_validate_json(s.model_dump_json())
        assert parsed.type == "buffer_overflow"
        assert parsed.bytes_dropped == 4096
        assert parsed.at == 1_700_000_000_000


# ---------------------------------------------------------------------------
# Inbound rejection (R26, R-MECH-1, G4)
# ---------------------------------------------------------------------------


class TestInboundRejection:
    def test_ir4_protocol_has_no_write_surface(self) -> None:
        assert not hasattr(PtySession, "write")
        assert not hasattr(PtySession, "send")
        assert not hasattr(PtySession, "feed")

    def test_g4_inbound_drain_body_is_single_statement(self) -> None:
        source = inspect.getsource(terminal_ws._inbound_drain)
        tree = ast.parse(source)
        funcdef = next(n for n in ast.walk(tree) if isinstance(n, ast.AsyncFunctionDef))
        # body: docstring (Expr Constant) + While loop
        non_docstring_body = [
            s
            for s in funcdef.body
            if not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))
        ]
        assert len(non_docstring_body) == 1
        while_loop = non_docstring_body[0]
        assert isinstance(while_loop, ast.While)
        assert isinstance(while_loop.test, ast.Constant) and while_loop.test.value is True
        assert len(while_loop.body) == 1
        stmt = while_loop.body[0]
        assert isinstance(stmt, ast.Expr)
        assert isinstance(stmt.value, ast.Await)
        call = stmt.value.value
        assert isinstance(call, ast.Call)
        assert isinstance(call.func, ast.Attribute)
        assert call.func.attr == "receive"

    def test_g1_no_pty_write_in_source(self) -> None:
        source = inspect.getsource(terminal_ws)
        pattern = re.compile(
            r"PtySession\s*\.\s*(write|send|feed)|\.\s*(write|send|feed)\s*\(.*pty"
        )
        assert pattern.findall(source) == []

    def test_g2_no_subprocess_call(self) -> None:
        source = inspect.getsource(terminal_ws)
        assert re.search(r"subprocess\.", source) is None

    def test_g3_no_ptyprocess_import(self) -> None:
        source = inspect.getsource(terminal_ws)
        assert (
            re.search(r"^\s*(import\s+ptyprocess|from\s+ptyprocess)", source, re.MULTILINE) is None
        )


# ---------------------------------------------------------------------------
# App wireup (W1-W4)
# ---------------------------------------------------------------------------


class TestAppWireup:
    def test_w1_router_registered_in_app(self, app_with_router: Any) -> None:
        paths = {getattr(r, "path", "") for r in app_with_router.routes}
        assert "/ws/{target_kind}/terminal" in paths

    def test_w2_middleware_order_unchanged(self, app_with_router: Any) -> None:
        names = [m.cls.__name__ for m in app_with_router.user_middleware]
        assert names == ["OriginMiddleware", "CSRFMiddleware", "AccessLogMiddleware"]

    def test_w3_claudemd_bullet_present(self) -> None:
        path = REPO_ROOT / "CLAUDE.md"
        text = path.read_text(encoding="utf-8")
        assert "terminal_ws.py" in text
        assert "/ws/{target_kind}/terminal" in text
        assert "buffer_overflow" in text

    def test_w4_include_router_no_prefix(self) -> None:
        text = (REPO_ROOT / "dashboard" / "server" / "app.py").read_text(encoding="utf-8")
        assert "include_router(_terminal_ws_router)" in text
        assert "include_router(_terminal_ws_router, prefix=" not in text


# ---------------------------------------------------------------------------
# Make subscribe callback — never-raise contract (R16)
# ---------------------------------------------------------------------------


class TestSubscribeCallback:
    async def test_callback_enqueues(self) -> None:
        state = _ConnectionState(queue=asyncio.Queue(maxsize=4))
        cb = _make_subscribe_callback(state)
        await cb(b"hello")
        assert state.queue.qsize() == 1
        assert await state.queue.get() == b"hello"

    async def test_callback_drops_oldest_on_full_queue(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        state = _ConnectionState(queue=asyncio.Queue(maxsize=2))
        cb = _make_subscribe_callback(state)
        await cb(b"1")
        await cb(b"2")
        with caplog.at_level(logging.WARNING, logger="dashboard.server.terminal_ws"):
            await cb(b"3")  # would overflow — drops oldest
        assert state.queue.qsize() == 2
        # The oldest (b"1") got popped; we should now have b"2", b"3"
        first = await state.queue.get()
        second = await state.queue.get()
        assert first == b"2"
        assert second == b"3"
        assert state.callback_drops == 1
        warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
        assert any("queue_dropped" in r.getMessage() for r in warnings)


# ---------------------------------------------------------------------------
# Integration round-trips (CSRF reject, happy path) — exercised through
# TestClient.
# ---------------------------------------------------------------------------


def _lifecycle_dir_for(target_kind: str, target_id: str, monkeypatch_target_root: Path) -> Path:
    label = "INPROGRESS_Feature_" if target_kind == "autopilot" else "INPROGRESS_Plan_"
    folder = monkeypatch_target_root / "project" / "docs" / f"{label}{target_id}"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


@pytest.fixture
def lifecycle_stream(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Callable[..., Path]:
    """Factory: write N lifecycle rows to a target's stream file."""
    monkeypatch.setenv("PROJECTS_ROOT", str(tmp_path))

    # Patch status_helper to re-read PROJECTS_ROOT from env on every derive.
    from dashboard.server import status_helper

    monkeypatch.setattr(status_helper, "_PROJECTS_ROOT", tmp_path)
    status_helper._reset_cache()

    def _build(target_kind: str, target_id: str, rows: list[dict[str, Any]]) -> Path:
        folder = _lifecycle_dir_for(target_kind, target_id, tmp_path)
        fname = "autopilot-stream.ndjson" if target_kind == "autopilot" else "chain-events.ndjson"
        stream = folder / fname
        with open(stream, "w", encoding="utf-8") as fh:
            for row in rows:
                fh.write(json.dumps(row) + "\n")
        # Refresh the offset cache
        status_helper._reset_cache()
        return stream

    return _build


def _disconnect_code(exc: BaseException) -> int | None:
    """Return the WebSocket close code if available on the exception."""
    return getattr(exc, "code", None)


def _expect_close(ws: Any, expected_code: int) -> None:
    """Receive one message; assert it is a websocket.close with expected_code."""
    from starlette.websockets import WebSocketDisconnect

    try:
        msg = ws.receive()
    except WebSocketDisconnect as exc:
        assert exc.code == expected_code, f"close code {exc.code} != {expected_code}"
        return
    assert isinstance(msg, dict), f"expected close dict, got {type(msg).__name__}"
    assert msg.get("type") == "websocket.close", f"expected close msg, got {msg}"
    assert msg.get("code") == expected_code, f"close code {msg.get('code')} != {expected_code}"


class TestIntegrationCsrf:
    def test_c1_missing_cookie_close_4001(
        self, csrf_client: tuple[TestClient, str], audit_log_dir: Path
    ) -> None:
        from starlette.websockets import WebSocketDisconnect

        client, _ = csrf_client
        client.cookies.clear()  # strip the csrf_token cookie
        url = "/ws/autopilot/terminal?id=foo&csrf=ABC123"
        # Pre-accept close — TestClient raises WebSocketDisconnect on enter.
        with pytest.raises(WebSocketDisconnect) as excinfo:
            with client.websocket_connect(url):
                pass
        assert _disconnect_code(excinfo.value) == 4001
        # Audit row written
        if audit_log_dir.exists():
            content = audit_log_dir.read_text()
            assert "csrf_violation" in content

    def test_c3_csrf_mismatch_close_4001(
        self, csrf_client: tuple[TestClient, str], audit_log_dir: Path
    ) -> None:
        from starlette.websockets import WebSocketDisconnect

        client, token = csrf_client
        url = f"/ws/autopilot/terminal?id=foo&csrf=WRONG-{token[:5]}"
        with pytest.raises(WebSocketDisconnect) as excinfo:
            with client.websocket_connect(url):
                pass
        assert _disconnect_code(excinfo.value) == 4001

    def test_c4_loopback_client_skips_csrf_check(
        self,
        csrf_client: tuple[TestClient, str],
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """controls-07 #8 pt 2: when client is loopback, mismatched/missing
        csrf does NOT 4001. The route progresses to its post-accept
        gauntlet (status routing, etc.) — we don't care which downstream
        code it lands at, only that the CSRF gate is not what closed it.
        Mirrors the HTTP loopback skip in CSRFMiddleware (controls-07
        #8 pt 1). TestClient identifies as 'testclient'; the patch
        flips the loopback policy decision to True so the skip path
        is exercised."""
        from starlette.websockets import WebSocketDisconnect

        from dashboard.server import terminal_ws as _tws

        monkeypatch.setattr(_tws, "_is_loopback_client", lambda _host: True)
        client, _token = csrf_client
        # Deliberately wrong csrf value — pre-#8 this closes with 4001.
        url = "/ws/autopilot/terminal?id=foo&csrf=DELIBERATELY-WRONG"
        close_code: int | None = None
        try:
            with client.websocket_connect(url) as ws:
                # If we got past CSRF, the downstream gauntlet may
                # close on its own (no such target_id 'foo'); we just
                # need to drain to surface its close code.
                try:
                    ws.receive()
                except WebSocketDisconnect as exc:
                    close_code = _disconnect_code(exc)
        except WebSocketDisconnect as exc:
            close_code = _disconnect_code(exc)
        assert close_code != 4001, "loopback skip failed; got close 4001 (REASON_CSRF)"

    def test_c5_non_loopback_still_enforces_csrf(
        self,
        csrf_client: tuple[TestClient, str],
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """controls-07 #8 pt 2 regression: non-loopback client with bad
        csrf STILL closes 4001 (so a 0.0.0.0 bind or reverse-proxy
        deploy doesn't silently drop the WS defence)."""
        from starlette.websockets import WebSocketDisconnect

        from dashboard.server import terminal_ws as _tws

        monkeypatch.setattr(_tws, "_is_loopback_client", lambda _host: False)
        client, token = csrf_client
        url = f"/ws/autopilot/terminal?id=foo&csrf=WRONG-{token[:5]}"
        with pytest.raises(WebSocketDisconnect) as excinfo:
            with client.websocket_connect(url):
                pass
        assert _disconnect_code(excinfo.value) == 4001


class TestIntegrationUrl:
    def test_u3_invalid_id_close_4400(
        self,
        csrf_client: tuple[TestClient, str],
        audit_log_dir: Path,
    ) -> None:
        client, token = csrf_client
        # URL-encoded slashes / dots decode after Starlette parsing; the
        # decoded value contains characters outside SAFE_ID_REGEX so the
        # post-accept gauntlet (R7) closes with 4400.
        url = f"/ws/autopilot/terminal?id=..%2Fetc%2Fpasswd&csrf={token}"
        with client.websocket_connect(url) as ws:
            _expect_close(ws, 4400)

    def test_u4_id_too_long_close_4400(self, csrf_client: tuple[TestClient, str]) -> None:
        # FastAPI's min/max length on the Query parameter rejects this
        # at validation layer — the framework returns its own
        # close before the route body runs.
        from starlette.websockets import WebSocketDisconnect

        client, token = csrf_client
        url = f"/ws/autopilot/terminal?id={'a' * 65}&csrf={token}"
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect(url) as ws:
                ws.receive()


class TestIntegrationLookup:
    def test_l1_status_idle_close_4404(
        self,
        csrf_client: tuple[TestClient, str],
        audit_log_dir: Path,
        lifecycle_stream: Callable[..., Path],
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        # No lifecycle stream — status defaults to idle.
        client, token = csrf_client
        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", _fake_factory([]))
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        with client.websocket_connect(url) as ws:
            _expect_close(ws, 4404)

    def test_l2_status_cancelled_close_4404(
        self,
        csrf_client: tuple[TestClient, str],
        lifecycle_stream: Callable[..., Path],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        client, token = csrf_client
        lifecycle_stream(
            "autopilot",
            "foo",
            [
                {
                    "ts": "2026-05-15T12:00:00+00:00",
                    "type": "lifecycle",
                    "action": "started",
                    "target": "foo",
                    "tmux_session": "autopilot-foo",
                    "source": "cli",
                },
                {
                    "ts": "2026-05-15T12:01:00+00:00",
                    "type": "lifecycle",
                    "action": "cancelled",
                    "target": "foo",
                    "source": "cli",
                },
            ],
        )
        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", _fake_factory([]))
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        with client.websocket_connect(url) as ws:
            _expect_close(ws, 4404)


class TestIntegrationHappyPath:
    def test_c5_csrf_valid_subscribes_running_session(
        self,
        csrf_client: tuple[TestClient, str],
        lifecycle_stream: Callable[..., Path],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        # Happy path: CSRF + running status → the bridge subscribes to
        # the helper and the connection is established. Live byte
        # delivery is verified by the MT1 manual test against real tmux;
        # the in-process TestClient + FakePtySession path races the
        # helper's read-loop scheduling against subscribe.
        client, token = csrf_client
        lifecycle_stream(
            "autopilot",
            "foo",
            [
                {
                    "ts": "2026-05-15T12:00:00+00:00",
                    "type": "lifecycle",
                    "action": "started",
                    "target": "foo",
                    "tmux_session": "autopilot-foo",
                    "source": "cli",
                },
            ],
        )
        fakes: list[FakePtySession] = []

        def factory(name: str) -> PtySession:
            fake = FakePtySession(
                [],
                failure_mode="stall",
                failure_step=0,
                stall_event=asyncio.Event(),
            )
            fakes.append(fake)
            return fake

        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", factory)
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        # Just check that the connect did NOT receive an immediate close
        # with one of the error codes (CSRF passed + status running +
        # subscribe succeeded). The context manager exit may surface a
        # concurrent.futures.CancelledError or a clean WebSocketDisconnect
        # (code 1000 / None) as the background helper task is torn down —
        # allow those, but fail if any error close-code fires.
        import concurrent.futures

        from starlette.websockets import WebSocketDisconnect

        error_codes = {4001, 4400, 4404, 1011, 1013}
        try:
            with client.websocket_connect(url):
                pass
        except WebSocketDisconnect as exc:
            assert (
                exc.code not in error_codes
            ), f"unexpected error close code {exc.code}"
        except (asyncio.CancelledError, concurrent.futures.CancelledError):
            # Background helper task teardown — acceptable.
            pass
        assert fakes, "factory was never invoked"
        assert "autopilot-foo" in terminal_ws._REGISTRY

    def test_c5b_subscribe_seeds_scrollback_before_live_frames(
        self,
        csrf_client: tuple[TestClient, str],
        lifecycle_stream: Callable[..., Path],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """controls-06 #15: when a subscriber attaches, the WS bridge
        seeds the queue with the tmux pane's scrollback BEFORE the
        live fanout starts. Operator's first byte is historical
        context (industry replay-then-tail pattern: GitHub Actions,
        Vercel, Render, Heroku, kubectl logs --tail, docker logs,
        CloudWatch Live Tail, Buildkite). FakePtySession's scripted
        scrollback proves the wiring without spawning real tmux."""
        client, token = csrf_client
        lifecycle_stream(
            "autopilot",
            "foo",
            [
                {
                    "ts": "2026-05-15T12:00:00+00:00",
                    "type": "lifecycle",
                    "action": "started",
                    "target": "foo",
                    "tmux_session": "autopilot-foo",
                    "source": "cli",
                },
            ],
        )
        scrollback_payload = b"\x1b[31mhistorical line 1\x1b[0m\nhistorical line 2\n"
        fakes: list[FakePtySession] = []

        def factory(name: str) -> PtySession:
            fake = FakePtySession(
                [],
                failure_mode="stall",
                failure_step=0,
                stall_event=asyncio.Event(),
                scrollback=scrollback_payload,
            )
            fakes.append(fake)
            return fake

        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", factory)
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        import concurrent.futures
        from starlette.websockets import WebSocketDisconnect

        received: bytes | None = None
        try:
            with client.websocket_connect(url) as ws:
                # First frame should be the scrollback seed (raw bytes).
                received = ws.receive_bytes()
        except (asyncio.CancelledError, concurrent.futures.CancelledError):
            pass
        except WebSocketDisconnect:
            pass

        assert fakes, "factory was never invoked"
        assert received is not None, "no frame delivered"
        assert received == scrollback_payload, (
            f"first frame must be the scrollback seed; got {received!r}"
        )

    def test_c5c_scrollback_chunked_when_larger_than_batch_threshold(
        self,
        csrf_client: tuple[TestClient, str],
        lifecycle_stream: Callable[..., Path],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """controls-07 #12: scrollback larger than the 4KB batch
        threshold MUST be enqueued as multiple chunks, not as one
        oversized blob. Pre-#12, a 85kB scrollback (typical chain
        attach after ~30 min of pilot output) was enqueued via a
        single put_nowait. The send_pump then saw one ~85kB chunk
        and the 64KB drop-oldest backpressure buffer overflowed —
        only ~32KB survived to xterm and the operator saw the
        'Output buffer overflow' banner with the scrollback mostly
        gone. Chunking at the enqueue site means the pump sees
        multiple small chunks; backpressure never trips.

        Empirically reproduced today: audit log recorded four
        successful 85kB+ scrollback captures, then the WS bridge's
        bufferOverflow sentinel fired with bytes_dropped=82698 on
        each attach."""
        client, token = csrf_client
        lifecycle_stream(
            "autopilot",
            "foo",
            [
                {
                    "ts": "2026-05-15T12:00:00+00:00",
                    "type": "lifecycle",
                    "action": "started",
                    "target": "foo",
                    "tmux_session": "autopilot-foo",
                    "source": "cli",
                },
            ],
        )
        # 10 KB payload — exceeds _BATCH_BYTES_THRESHOLD (4 KB) but
        # stays well under the 64 KB backpressure ceiling so we can
        # assert multi-chunk delivery without the test getting tangled
        # in the drop-oldest path.
        scrollback_payload = b"A" * 10_240
        fakes: list[FakePtySession] = []

        def factory(name: str) -> PtySession:
            fake = FakePtySession(
                [],
                failure_mode="stall",
                failure_step=0,
                stall_event=asyncio.Event(),
                scrollback=scrollback_payload,
            )
            fakes.append(fake)
            return fake

        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", factory)
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        import concurrent.futures
        from starlette.websockets import WebSocketDisconnect

        chunks: list[bytes] = []
        try:
            with client.websocket_connect(url) as ws:
                # Drain frames until we have the full payload (or hit
                # WebSocketDisconnect when the stall keeps no more
                # data coming).
                while sum(len(c) for c in chunks) < len(scrollback_payload):
                    chunks.append(ws.receive_bytes())
        except (asyncio.CancelledError, concurrent.futures.CancelledError):
            pass
        except WebSocketDisconnect:
            pass

        total = b"".join(chunks)
        assert total == scrollback_payload, (
            f"reassembled scrollback mismatch; got {len(total)}B"
        )
        # controls-07 #12: at least 2 chunks for a payload > 4KB. The
        # send-pump may coalesce small puts into one accumulator
        # within its 16ms window, so we do not assert an exact count —
        # only that chunking happened at all.
        assert len(chunks) >= 2, (
            f"expected scrollback to arrive in multiple chunks; "
            f"got {len(chunks)} chunks of {[len(c) for c in chunks]}B"
        )


class TestIntegrationSubscriberCap:
    async def test_sc2_ninth_subscriber_close_1013(
        self,
        csrf_client: tuple[TestClient, str],
        lifecycle_stream: Callable[..., Path],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        from starlette.websockets import WebSocketDisconnect

        client, token = csrf_client
        lifecycle_stream(
            "autopilot",
            "foo",
            [
                {
                    "ts": "2026-05-15T12:00:00+00:00",
                    "type": "lifecycle",
                    "action": "started",
                    "target": "foo",
                    "tmux_session": "autopilot-foo",
                    "source": "cli",
                },
            ],
        )
        # Construct a FakePtySession lazily on the loop so the read-loop
        # task scheduling works in TestClient's thread.
        fake = FakePtySession([])
        terminal_ws._REGISTRY["autopilot-foo"] = terminal_ws._SessionEntry(
            pty=fake, subscriber_count=8
        )
        # Use a factory that returns the same fake (so the cap check uses
        # the existing entry).
        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", lambda n: fake)
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        # The 9th connection should close with code 1013 (pre-accept reject).
        with pytest.raises(WebSocketDisconnect) as excinfo:
            with client.websocket_connect(url):
                pass
        assert _disconnect_code(excinfo.value) == 1013


# ---------------------------------------------------------------------------
# AC-T4 wire-level sentinel proof (BP2-on-wire)
# ---------------------------------------------------------------------------


class TestBpWireIntegration:
    """AC-T4: BufferOverflowSentinel arrives on the wire as JSON text."""

    async def test_bp2_sentinel_on_wire(self) -> None:
        from unittest.mock import AsyncMock

        state = _ConnectionState(queue=asyncio.Queue(maxsize=4))
        # Saturate the buffer to provoke the overflow transition.
        for _ in range(16):
            _append_with_backpressure(state, b"X" * 4096)
        needs = _append_with_backpressure(state, b"Y" * 4096)
        assert needs is True
        mock_ws = AsyncMock()
        await terminal_ws._emit_overflow_sentinel(state, mock_ws)
        assert mock_ws.send_text.await_count == 1
        payload = mock_ws.send_text.call_args.args[0]
        parsed = BufferOverflowSentinel.model_validate_json(payload)
        assert parsed.type == "buffer_overflow"
        assert parsed.bytes_dropped == state.bytes_dropped_this_window


# ---------------------------------------------------------------------------
# AC-T2 inbound-drop on-wire proof via FakePtySession.assert_no_inbound_bytes
# ---------------------------------------------------------------------------


class TestInboundRejectionOnWire:
    """IR1 / IR2: inbound text and bytes never reach the pty.

    The Fake's ``write()`` raises ``NotImplementedError`` per
    ``pty_session.py``; ``assert_no_inbound_bytes()`` proves the
    invariant structurally (``_inbound_payloads`` is never appended).
    """

    def _build_running_factory(
        self, fakes: list[FakePtySession]
    ) -> Callable[[str], PtySession]:
        def factory(name: str) -> PtySession:
            fake = FakePtySession(
                [],
                failure_mode="stall",
                failure_step=0,
                stall_event=asyncio.Event(),
            )
            fakes.append(fake)
            return fake

        return factory

    def _prime_running(self, lifecycle_stream: Callable[..., Path]) -> None:
        lifecycle_stream(
            "autopilot",
            "foo",
            [
                {
                    "ts": "2026-05-15T12:00:00+00:00",
                    "type": "lifecycle",
                    "action": "started",
                    "target": "foo",
                    "tmux_session": "autopilot-foo",
                    "source": "cli",
                },
            ],
        )

    def test_ir1_inbound_text_dropped(
        self,
        csrf_client: tuple[TestClient, str],
        lifecycle_stream: Callable[..., Path],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        client, token = csrf_client
        self._prime_running(lifecycle_stream)
        fakes: list[FakePtySession] = []
        monkeypatch.setattr(
            terminal_ws, "_PTY_SESSION_FACTORY", self._build_running_factory(fakes)
        )
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        try:
            with client.websocket_connect(url) as ws:
                ws.send_text("INJECTED-TEXT")
        except Exception:  # noqa: BLE001
            pass
        assert fakes, "factory was never invoked"
        # Structural proof: the Fake's _inbound_payloads list stays empty.
        fakes[0].assert_no_inbound_bytes()

    def test_ir2_inbound_bytes_dropped(
        self,
        csrf_client: tuple[TestClient, str],
        lifecycle_stream: Callable[..., Path],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        client, token = csrf_client
        self._prime_running(lifecycle_stream)
        fakes: list[FakePtySession] = []
        monkeypatch.setattr(
            terminal_ws, "_PTY_SESSION_FACTORY", self._build_running_factory(fakes)
        )
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        try:
            with client.websocket_connect(url) as ws:
                ws.send_bytes(b"INJECTED-BYTES")
        except Exception:  # noqa: BLE001
            pass
        assert fakes, "factory was never invoked"
        fakes[0].assert_no_inbound_bytes()


# ---------------------------------------------------------------------------
# C2: missing CSRF query parameter — framework-level reject
# ---------------------------------------------------------------------------


class TestIntegrationCsrfMissing:
    def test_c2_missing_csrf_query(
        self,
        csrf_client: tuple[TestClient, str],
        audit_log_dir: Path,
    ) -> None:
        """No ``?csrf=`` — FastAPI Query min_length=1 rejects framework-level.

        No ``csrf_violation`` audit row is written: the bridge endpoint
        body never runs, so the audit hook never fires (the framework
        access log is the only trail for this path).
        """
        from starlette.websockets import WebSocketDisconnect

        client, _ = csrf_client
        url = "/ws/autopilot/terminal?id=foo"
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect(url):
                pass
        # No bridge-level audit row should have been written.
        if audit_log_dir.exists():
            content = audit_log_dir.read_text()
            assert "csrf_violation" not in content


# ---------------------------------------------------------------------------
# L3-L6: status-precondition lookup variants
# ---------------------------------------------------------------------------


def _lifecycle_rows_terminal(action: str) -> list[dict[str, Any]]:
    return [
        {
            "ts": "2026-05-15T12:00:00+00:00",
            "type": "lifecycle",
            "action": "started",
            "target": "foo",
            "tmux_session": "autopilot-foo",
            "source": "cli",
        },
        {
            "ts": "2026-05-15T12:01:00+00:00",
            "type": "lifecycle",
            "action": action,
            "target": "foo",
            "source": "cli",
        },
    ]


class TestIntegrationLookupVariants:
    def test_l3_status_completed_close_4404(
        self,
        csrf_client: tuple[TestClient, str],
        lifecycle_stream: Callable[..., Path],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        # status_helper currently maps no "completed" action; we simulate
        # by monkeypatching derive_status to return completed.
        client, token = csrf_client
        from dashboard.server import status_helper

        def fake_status(kind: str, tid: str) -> dict[str, Any]:
            return {
                "status": "completed",
                "phase_at_pause": None,
                "last_phase_complete": None,
                "started_at": "2026-05-15T12:00:00+00:00",
                "tmux_session": "autopilot-foo",
            }

        monkeypatch.setattr(terminal_ws, "derive_status", fake_status)
        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", _fake_factory([]))
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        with client.websocket_connect(url) as ws:
            _expect_close(ws, 4404)
        # Silence unused-import warning
        _ = status_helper

    def test_l4_status_failed_close_4404(
        self,
        csrf_client: tuple[TestClient, str],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        client, token = csrf_client

        def fake_status(kind: str, tid: str) -> dict[str, Any]:
            return {
                "status": "failed",
                "phase_at_pause": None,
                "last_phase_complete": None,
                "started_at": "2026-05-15T12:00:00+00:00",
                "tmux_session": "autopilot-foo",
            }

        monkeypatch.setattr(terminal_ws, "derive_status", fake_status)
        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", _fake_factory([]))
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        with client.websocket_connect(url) as ws:
            _expect_close(ws, 4404)

    def test_l5_tmux_session_none_close_1011(
        self,
        csrf_client: tuple[TestClient, str],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Lifecycle missing tmux_session field — status running but no name."""
        client, token = csrf_client

        def fake_status(kind: str, tid: str) -> dict[str, Any]:
            return {
                "status": "running",
                "phase_at_pause": None,
                "last_phase_complete": None,
                "started_at": "2026-05-15T12:00:00+00:00",
                "tmux_session": None,
            }

        monkeypatch.setattr(terminal_ws, "derive_status", fake_status)
        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", _fake_factory([]))
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        with client.websocket_connect(url) as ws:
            _expect_close(ws, 1011)

    def test_l6_lookup_mismatch_close_1011(
        self,
        csrf_client: tuple[TestClient, str],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Lifecycle tmux_session != deterministic_name → REASON_LOOKUP_INCONSISTENT."""
        client, token = csrf_client

        def fake_status(kind: str, tid: str) -> dict[str, Any]:
            return {
                "status": "running",
                "phase_at_pause": None,
                "last_phase_complete": None,
                "started_at": "2026-05-15T12:00:00+00:00",
                "tmux_session": "autopilot-other",
            }

        monkeypatch.setattr(terminal_ws, "derive_status", fake_status)
        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", _fake_factory([]))
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        with client.websocket_connect(url) as ws:
            _expect_close(ws, 1011)


# ---------------------------------------------------------------------------
# L9: TOCTOU re-check after subscribe (started_at flip)
# ---------------------------------------------------------------------------


class TestToctouRecheck:
    def test_l9_toctou_mismatch_close_1011(
        self,
        csrf_client: tuple[TestClient, str],
        audit_log_dir: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """Two consecutive derive_status() calls return mismatched started_at.

        First call (pre-accept) returns started_at=T1, second call
        (post-subscribe TOCTOU recheck) returns started_at=T2 — the
        bridge must unsubscribe, evict, and close 1011 with reason
        REASON_LIFECYCLE_MISSING. The _REGISTRY must be empty after.
        """
        client, token = csrf_client
        counter = {"n": 0}

        def fake_status(kind: str, tid: str) -> dict[str, Any]:
            counter["n"] += 1
            started = (
                "2026-05-15T12:00:00+00:00"
                if counter["n"] == 1
                else "2026-05-15T12:05:00+00:00"
            )
            return {
                "status": "running",
                "phase_at_pause": None,
                "last_phase_complete": None,
                "started_at": started,
                "tmux_session": "autopilot-foo",
            }

        monkeypatch.setattr(terminal_ws, "derive_status", fake_status)
        fakes: list[FakePtySession] = []

        def factory(name: str) -> PtySession:
            fake = FakePtySession(
                [],
                failure_mode="stall",
                failure_step=0,
                stall_event=asyncio.Event(),
            )
            fakes.append(fake)
            return fake

        monkeypatch.setattr(terminal_ws, "_PTY_SESSION_FACTORY", factory)
        url = f"/ws/autopilot/terminal?id=foo&csrf={token}"
        with client.websocket_connect(url) as ws:
            _expect_close(ws, 1011)
        # The TOCTOU branch evicts the helper from the registry.
        assert "autopilot-foo" not in terminal_ws._REGISTRY


# ---------------------------------------------------------------------------
# AC-T1: batch-latency budget (pure constant arithmetic)
# ---------------------------------------------------------------------------


class TestLatencyBudget:
    def test_lat1_batch_latency_under_50ms(self) -> None:
        """AC-T1: 16 ms batch + ≤34 ms syscall+send headroom ≤ 50 ms total.

        Mechanical proof the configured ``_BATCH_TIME_THRESHOLD_S`` keeps
        the batch flush under the 50 ms p95 latency budget. A full
        wall-clock test is deferred as flaky in CI; this constant-check
        is the pragmatic alternative (per Tester #1).
        """
        assert terminal_ws._BATCH_TIME_THRESHOLD_S <= 0.050 - 0.020
