"""Unit tests for server/status_helper.py.

Covers TC-A through TC-INV6 (R17) and acceptance scenarios AS1-AS15
plus edge cases E1, E4-E12, E15, E17-E19 from
docs/INPROGRESS_Feature_session-status-helper/REQUIREMENTS.md.
"""

from __future__ import annotations

import builtins
import json
import sys
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dashboard.server import lifecycle_events, status_helper
from dashboard.server.lifecycle_events import append_event
from dashboard.server.status_helper import (
    STATUS_VALUES,
    TARGET_KINDS,
    SessionStatus,
    derive_status,
)

LOGGER_NAME = "dashboard.server.status_helper"

# Captured at import, before the autouse fixture (below) stubs the attribute —
# lets the timeout guard exercise the real subprocess-backed implementation.
_REAL_IS_TMUX_ALIVE = status_helper._is_tmux_alive


# --- fixtures ----------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_cache_autouse() -> Any:
    status_helper._reset_cache()
    yield
    status_helper._reset_cache()


@pytest.fixture(autouse=True)
def _default_tmux_alive_true(monkeypatch: pytest.MonkeyPatch) -> Any:
    """controls-06 #17 — default the tmux liveness probe to True so
    pre-cycle-17 tests (which never tracked tmux aliveness) keep
    seeing their assertion targets. Tests that want to exercise the
    stale-reconciliation override this with `monkeypatch.setattr`
    inside the test body (c2b / c2d / etc)."""
    monkeypatch.setattr(status_helper, "_is_tmux_alive", lambda _name: True)
    yield


@pytest.fixture
def patched_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(status_helper, "_PROJECTS_ROOT", tmp_path)
    return tmp_path


def _stream_dir(root: Path, kind: str, target_id: str, *, prefix: str = "INPROGRESS") -> Path:
    label = "Feature" if kind == "autopilot" else "Plan"
    project = root / "proj"
    return project / "docs" / f"{prefix}_{label}_{target_id}"


def _stream_path(root: Path, kind: str, target_id: str, *, prefix: str = "INPROGRESS") -> Path:
    fname = "autopilot-stream.ndjson" if kind == "autopilot" else "chain-events.ndjson"
    return _stream_dir(root, kind, target_id, prefix=prefix) / fname


def make_stream(root: Path, kind: str, target_id: str, *, prefix: str = "INPROGRESS") -> Path:
    path = _stream_path(root, kind, target_id, prefix=prefix)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()
    return path


def _evt(
    action: str = "started",
    *,
    target: str = "feat-x",
    ts: str = "2026-05-14T10:00:00Z",
    source: str = "cli",
    **extra: Any,
) -> dict[str, Any]:
    base: dict[str, Any] = {
        "ts": ts,
        "type": "lifecycle",
        "action": action,
        "source": source,
        "target": target,
    }
    base.update(extra)
    return base


def append_lifecycle(path: Path, **kwargs: Any) -> dict[str, Any]:
    event = _evt(**kwargs)
    append_event(path, event)
    return event


def _warnings(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [
        r.getMessage() for r in caplog.records if r.name == LOGGER_NAME and r.levelname == "WARNING"
    ]


IDLE_DEFAULT: SessionStatus = {
    "status": "idle",
    "phase_at_pause": None,
    "last_phase_complete": None,
    "started_at": None,
    "tmux_session": None,
}


# --- Group A: Idle / missing-stream -----------------------------------------


def test_a1_autopilot_missing_dir_returns_idle(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "ghost-feat")
    assert result == IDLE_DEFAULT
    assert _warnings(caplog) == []


def test_a2_chain_missing_dir_returns_idle(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("chain", "demo-plan")
    assert result == IDLE_DEFAULT
    assert _warnings(caplog) == []


def test_a3_dir_exists_but_no_stream_file(patched_root: Path) -> None:
    _stream_dir(patched_root, "autopilot", "feat-x").mkdir(parents=True)
    assert derive_status("autopilot", "feat-x") == IDLE_DEFAULT


def test_b1_empty_stream_file_returns_idle(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    make_stream(patched_root, "autopilot", "feat-x")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    assert _warnings(caplog) == []


def test_b2_whitespace_only_stream_returns_idle(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    path.write_text("\n\n\n")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    assert _warnings(caplog) == []


# --- Group B: Happy-path status derivation ----------------------------------


def test_c1_started_event_running(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "running"
    assert result["started_at"] == "2026-05-14T10:00:00Z"
    assert result["phase_at_pause"] is None
    assert result["last_phase_complete"] is None
    assert result["tmux_session"] is None


def test_c2_started_event_with_tmux_session(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", tmux_session="autopilot-feat-x")
    result = derive_status("autopilot", "feat-x")
    assert result["tmux_session"] == "autopilot-feat-x"


def test_c2b_stale_running_tmux_reconciled_to_none(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """controls-06 #17: when the lifecycle stream says state=running
    with a tmux_session, but `tmux has-session` reports the session
    doesn't exist, derive_status MUST return tmux_session=None so the
    frontend's stale-running detection
    (state==='running' && tmuxSession==null) fires and offers the
    Restart affordance. Without this reconciliation an
    autopilot-chain.sh that exited abruptly (chain_blocked
    on dirty_main, host kill, watchdog) leaves the lifecycle stream
    stuck on `started` with the original tmux name and the dashboard
    reports "running" forever."""
    path = make_stream(patched_root, "chain", "demo")
    append_lifecycle(path, action="started", tmux_session="chain-demo")

    # Patch the tmux liveness probe to report "session not alive".
    # The helper exposes `_is_tmux_alive` as the seam.
    monkeypatch.setattr(status_helper, "_is_tmux_alive", lambda _name: False)

    result = derive_status("chain", "demo")
    assert result["status"] == "running"
    assert result["tmux_session"] is None  # the reconciliation


def test_c2c_running_with_live_tmux_keeps_session_name(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Healthy running case — _is_tmux_alive returns True, the
    session name passes through unchanged."""
    path = make_stream(patched_root, "chain", "demo")
    append_lifecycle(path, action="started", tmux_session="chain-demo")
    monkeypatch.setattr(status_helper, "_is_tmux_alive", lambda _name: True)
    result = derive_status("chain", "demo")
    assert result["tmux_session"] == "chain-demo"


def test_c2d_terminal_status_skips_tmux_probe(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The reconciliation MUST NOT fire for terminal states
    (cancelled / completed / failed) — those targets have no live
    tmux to check by definition, and the probe would be wasted
    subprocess work on every poll. Verify by tracking whether the
    probe is invoked at all."""
    path = make_stream(patched_root, "chain", "demo")
    append_lifecycle(path, action="started", tmux_session="chain-demo")
    append_lifecycle(path, action="cancelled")

    probe_calls: list[str] = []

    def fake_probe(name: str) -> bool:
        probe_calls.append(name)
        return False

    monkeypatch.setattr(status_helper, "_is_tmux_alive", fake_probe)
    result = derive_status("chain", "demo")
    assert result["status"] == "cancelled"
    assert probe_calls == []  # zero probes for terminal states


def test_c2f_reconciliation_fires_on_unchanged_stream(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """controls-06 #17b: reconciliation MUST fire on EVERY derive_status
    call, not just the path that reads new bytes. The cycle-17 fix
    placed the reconciliation after the new-bytes branch only —
    subsequent polls on an unchanged stream took an early `return
    _state_to_dict(state)` and silently re-served the stale cached
    tmux_session. The chain-blocked / silent-exit scenario hits this
    constantly: stream stops growing the moment autopilot-chain.sh
    exits, so EVERY poll after the first hits the early-return."""
    path = make_stream(patched_root, "chain", "demo")
    append_lifecycle(path, action="started", tmux_session="chain-demo")

    # First poll: tmux is "alive" (default fixture). Cache populated.
    monkeypatch.setattr(status_helper, "_is_tmux_alive", lambda _name: True)
    first = derive_status("chain", "demo")
    assert first["tmux_session"] == "chain-demo"

    # tmux now dies. Stream HAS NOT GROWN. Probe says False.
    # The reconciliation MUST still run and blank tmux_session.
    monkeypatch.setattr(status_helper, "_is_tmux_alive", lambda _name: False)
    second = derive_status("chain", "demo")
    assert second["status"] == "running"
    assert second["tmux_session"] is None, (
        "reconciliation skipped on unchanged-stream early return"
    )


def test_c2e_tmux_probe_failure_fails_closed_to_none(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """controls-07 #7 — probe raise → fail CLOSED (tmux_session=None).
    Earlier fail-open hid 'tmux not on dashboard PATH' as a misleading
    'session alive' status with an empty live-output terminal. Poll
    itself still must not throw."""
    path = make_stream(patched_root, "chain", "demo")
    append_lifecycle(path, action="started", tmux_session="chain-demo")
    monkeypatch.setattr(status_helper, "_is_tmux_alive", lambda _n: (_ for _ in ()).throw(RuntimeError("tmux subsystem unreachable")))
    result = derive_status("chain", "demo")
    assert result["status"] == "running"
    assert result["tmux_session"] is None


def test_c2g_tmux_probe_failure_logs_with_exception_message(
    patched_root: Path,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """controls-07 #7 — warning must carry str(exc), not just type;
    operator needs 'FileNotFoundError: [Errno 2] ... tmux' to triage."""
    path = make_stream(patched_root, "chain", "demo")
    append_lifecycle(path, action="started", tmux_session="chain-demo")
    monkeypatch.setattr(
        status_helper, "_is_tmux_alive",
        lambda _n: (_ for _ in ()).throw(FileNotFoundError("[Errno 2] No such file or directory: 'tmux'")),
    )
    caplog.set_level("WARNING", logger="dashboard.server.status_helper")
    derive_status("chain", "demo")
    assert any(
        "tmux" in rec.getMessage().lower() and "no such file" in rec.getMessage().lower()
        for rec in caplog.records
    ), f"expected diagnostic with exception message; got: {[r.getMessage() for r in caplog.records]}"


def test_d1_multiple_phase_complete_tracks_last(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    append_lifecycle(path, action="phase_complete", phase="ba")
    append_lifecycle(path, action="phase_complete", phase="plan")
    append_lifecycle(path, action="phase_complete", phase="testplan")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "running"
    assert result["last_phase_complete"] == "testplan"
    assert result["started_at"] == "2026-05-14T10:00:00Z"
    assert result["phase_at_pause"] is None


def test_d2_phase_complete_missing_phase_field_warns(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    # append a phase_complete without `phase` field via raw write (parse_event
    # accepts because `phase` is not a required/optional-validated field)
    bad = _evt(action="phase_complete")
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(bad) + "\n")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result["status"] == "running"
    assert result["last_phase_complete"] is None
    msgs = _warnings(caplog)
    assert len(msgs) == 1 and "phase" in msgs[0]


def test_d3_phase_complete_non_string_phase_warns(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    bad = _evt(action="phase_complete", phase=42)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(bad) + "\n")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result["status"] == "running"
    assert result["last_phase_complete"] is None
    assert len(_warnings(caplog)) == 1


def test_e1_paused_after_started_and_phase_complete(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    append_lifecycle(path, action="phase_complete", phase="ba")
    append_lifecycle(path, action="paused", phase_at_pause="plan")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "paused"
    assert result["phase_at_pause"] == "plan"
    assert result["last_phase_complete"] == "ba"
    assert result["started_at"] == "2026-05-14T10:00:00Z"


def test_e2_paused_only_no_started(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="paused", phase_at_pause="ba")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "paused"
    assert result["phase_at_pause"] == "ba"
    assert result["started_at"] is None
    assert result["last_phase_complete"] is None


# --- Group C: Cancelled + forward-compat ------------------------------------


def test_k1_started_then_cancelled(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    append_lifecycle(path, action="cancelled")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "cancelled"
    assert result["phase_at_pause"] is None
    assert result["started_at"] == "2026-05-14T10:00:00Z"


def test_k2_cancelled_preserves_last_phase_complete(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    append_lifecycle(path, action="phase_complete", phase="ba")
    append_lifecycle(path, action="cancelled")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "cancelled"
    assert result["phase_at_pause"] is None
    assert result["last_phase_complete"] == "ba"


# --- Group D: Resumed -------------------------------------------------------


def test_res1_started_paused_resumed(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    append_lifecycle(path, action="paused", phase_at_pause="plan")
    append_lifecycle(path, action="resumed")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "running"
    assert result["phase_at_pause"] is None


def test_res2_resumed_without_paused(patched_root: Path, caplog: pytest.LogCaptureFixture) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    append_lifecycle(path, action="resumed")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result["status"] == "running"
    assert result["phase_at_pause"] is None
    assert _warnings(caplog) == []


# --- Group E: Incremental read O(new events) --------------------------------


def test_f1_incremental_read_o_new_bytes(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    # 1 MB of non-lifecycle JSON lines
    pad_line = json.dumps({"type": "phase", "name": "x" * 100}) + "\n"
    target_size = 1_000_000
    with path.open("w", encoding="utf-8") as fh:
        written = 0
        while written < target_size:
            fh.write(pad_line)
            written += len(pad_line.encode("utf-8"))
    # trailing valid started event
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")

    # cold read
    first = derive_status("autopilot", "feat-x")
    assert first["status"] == "running"

    # append exactly one phase_complete event
    append_lifecycle(path, action="phase_complete", phase="plan")

    # spy on builtins.open: track bytes read for the next call
    read_counter = {"bytes": 0}
    real_open = builtins.open

    class _ReadSpy:
        def __init__(self, fh: Any) -> None:
            self._fh = fh

        def __enter__(self) -> _ReadSpy:
            self._fh.__enter__()
            return self

        def __exit__(self, *exc: Any) -> Any:
            return self._fh.__exit__(*exc)

        def __getattr__(self, name: str) -> Any:
            return getattr(self._fh, name)

        def read(self, *args: Any, **kwargs: Any) -> Any:
            data = self._fh.read(*args, **kwargs)
            if isinstance(data, (bytes, str)):
                read_counter["bytes"] += len(data)
            return data

    def spy_open(file: Any, *args: Any, **kwargs: Any) -> Any:
        opened = real_open(file, *args, **kwargs)
        if str(file).endswith("autopilot-stream.ndjson"):
            return _ReadSpy(opened)
        return opened

    monkeypatch.setattr(builtins, "open", spy_open)
    second = derive_status("autopilot", "feat-x")
    assert second["status"] == "running"
    assert second["last_phase_complete"] == "plan"
    assert read_counter["bytes"] <= 500, f"second poll read {read_counter['bytes']} bytes"


def test_f2_back_to_back_polls_no_read(patched_root: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    derive_status("autopilot", "feat-x")  # cold

    open_count = {"count": 0}
    real_open = builtins.open

    def spy_open(file: Any, *args: Any, **kwargs: Any) -> Any:
        if str(file).endswith("autopilot-stream.ndjson"):
            open_count["count"] += 1
        return real_open(file, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", spy_open)
    derive_status("autopilot", "feat-x")
    assert open_count["count"] == 0  # stat-only fast path


def test_f3_single_byte_stream(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    path.write_bytes(b"\n")
    result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    cached = status_helper._STATE_CACHE[("autopilot", "feat-x")]
    assert cached.byte_offset == 1


# --- Group F: Cache identity ------------------------------------------------


def test_j1_back_to_back_polls_same_result(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    first = derive_status("autopilot", "feat-x")
    offset_first = status_helper._STATE_CACHE[("autopilot", "feat-x")].byte_offset
    second = derive_status("autopilot", "feat-x")
    assert first == second
    offset_second = status_helper._STATE_CACHE[("autopilot", "feat-x")].byte_offset
    assert offset_first == offset_second


def test_j2_independent_cache_entries(patched_root: Path) -> None:
    p1 = make_stream(patched_root, "autopilot", "feat-x")
    p2 = make_stream(patched_root, "autopilot", "feat-y")
    p3 = make_stream(patched_root, "chain", "feat-x")
    append_lifecycle(p1, action="started", target="feat-x", ts="2026-05-14T10:00:00Z")
    append_lifecycle(p2, action="started", target="feat-y", ts="2026-05-14T11:00:00Z")
    append_lifecycle(p3, action="started", target="feat-x", ts="2026-05-14T12:00:00Z")
    assert derive_status("autopilot", "feat-x")["started_at"] == "2026-05-14T10:00:00Z"
    assert derive_status("autopilot", "feat-y")["started_at"] == "2026-05-14T11:00:00Z"
    assert derive_status("chain", "feat-x")["started_at"] == "2026-05-14T12:00:00Z"


# --- Group G: Backward-jump reset -------------------------------------------


def test_g1_truncation_then_new_started_resets(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    append_lifecycle(path, action="phase_complete", phase="ba")
    append_lifecycle(path, action="paused", phase_at_pause="plan")
    first = derive_status("autopilot", "feat-x")
    assert first["status"] == "paused"

    path.write_bytes(b"")  # truncate
    append_lifecycle(path, action="started", ts="2026-05-14T11:00:00Z")
    second = derive_status("autopilot", "feat-x")
    assert second == {
        "status": "running",
        "phase_at_pause": None,
        "last_phase_complete": None,
        "started_at": "2026-05-14T11:00:00Z",
        "tmux_session": None,
    }
    cached = status_helper._STATE_CACHE[("autopilot", "feat-x")]
    assert cached.byte_offset == path.stat().st_size


def test_g2_backward_jump_silent(patched_root: Path, caplog: pytest.LogCaptureFixture) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    derive_status("autopilot", "feat-x")
    path.write_bytes(b"")
    append_lifecycle(path, action="started", ts="2026-05-14T11:00:00Z")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        derive_status("autopilot", "feat-x")
    assert _warnings(caplog) == []


def test_g3_partial_shrink_resets(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    append_lifecycle(path, action="phase_complete", phase="ba")
    derive_status("autopilot", "feat-x")
    # truncate and write smaller content
    path.write_bytes(b"")
    append_lifecycle(path, action="paused", phase_at_pause="plan")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "paused"
    assert result["phase_at_pause"] == "plan"
    assert result["last_phase_complete"] is None  # reset cleared it


# --- Group H: Corrupt / malformed lines -------------------------------------


def test_h1_corrupt_json_skipped_with_warning(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    with path.open("a", encoding="utf-8") as fh:
        fh.write('{"ts": "2026-\n')  # corrupt
    append_lifecycle(path, action="phase_complete", phase="ba")
    with path.open("a", encoding="utf-8") as fh:
        fh.write('["a","b"]\n')  # non-dict
    append_lifecycle(path, action="paused", phase_at_pause="plan")

    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")

    assert result["status"] == "paused"
    assert result["phase_at_pause"] == "plan"
    assert result["last_phase_complete"] == "ba"
    assert result["started_at"] == "2026-05-14T10:00:00Z"
    assert len(_warnings(caplog)) >= 2


def test_h2_non_lifecycle_events_silently_skipped(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    with path.open("a", encoding="utf-8") as fh:
        for t in ("phase", "result", "orchestrator", "gate_evaluated"):
            for _ in range(25):
                fh.write(json.dumps({"type": t, "data": "x"}) + "\n")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    assert _warnings(caplog) == []


def test_h3_empty_target_warns(patched_root: Path, caplog: pytest.LogCaptureFixture) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    with path.open("a", encoding="utf-8") as fh:
        fh.write(
            json.dumps(
                {
                    "ts": "2026-05-14T10:00:00Z",
                    "type": "lifecycle",
                    "action": "started",
                    "source": "cli",
                    "target": "",
                }
            )
            + "\n"
        )
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    msgs = _warnings(caplog)
    assert len(msgs) == 1
    assert "target" in msgs[0]


def test_h4_bad_target_regex_warns(patched_root: Path, caplog: pytest.LogCaptureFixture) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    with path.open("a", encoding="utf-8") as fh:
        fh.write(
            json.dumps(
                {
                    "ts": "2026-05-14T10:00:00Z",
                    "type": "lifecycle",
                    "action": "started",
                    "source": "cli",
                    "target": "bad target",
                }
            )
            + "\n"
        )
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    assert len(_warnings(caplog)) == 1


def test_h5_non_string_type_silent_skip(
    patched_root: Path, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps({"type": 42, "x": "y"}) + "\n")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    assert _warnings(caplog) == []


def test_h6_unknown_action_warns(patched_root: Path, caplog: pytest.LogCaptureFixture) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    with path.open("a", encoding="utf-8") as fh:
        fh.write(
            json.dumps(
                {
                    "ts": "2026-05-14T10:00:00Z",
                    "type": "lifecycle",
                    "action": "frobnicate",
                    "source": "cli",
                    "target": "feat-x",
                }
            )
            + "\n"
        )
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    msgs = _warnings(caplog)
    assert len(msgs) == 1
    assert "action" in msgs[0]


def test_h7_utf8_garbage_warns(patched_root: Path, caplog: pytest.LogCaptureFixture) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    path.write_bytes(b"\xff\xfe\xfd\n")
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    assert len(_warnings(caplog)) == 1


def test_h8_ocp_unknown_action_passes_parse_event(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    monkeypatch.setattr(
        lifecycle_events,
        "LIFECYCLE_ACTIONS",
        lifecycle_events.LIFECYCLE_ACTIONS + ("hibernated",),
    )
    path = make_stream(patched_root, "autopilot", "feat-x")
    with path.open("a", encoding="utf-8") as fh:
        fh.write(
            json.dumps(
                {
                    "ts": "2026-05-14T10:00:00Z",
                    "type": "lifecycle",
                    "action": "hibernated",
                    "source": "cli",
                    "target": "feat-x",
                }
            )
            + "\n"
        )
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    msgs = _warnings(caplog)
    assert len(msgs) == 1
    assert "hibernated" in msgs[0]


# --- Group I: Input validation ---------------------------------------------


@pytest.mark.parametrize("bad_kind", ["frobnicate", "AUTOPILOT", ""])
def test_m_invalid_target_kind_raises(bad_kind: str) -> None:
    with pytest.raises(ValueError) as exc:
        derive_status(bad_kind, "feat-x")
    assert "target_kind" in str(exc.value)


@pytest.mark.parametrize(
    "bad_id",
    ["bad id with spaces", "", "../escape", "a" * 65, "feat/x"],
)
def test_n_invalid_target_id_raises(bad_id: str) -> None:
    with pytest.raises(ValueError) as exc:
        derive_status("autopilot", bad_id)
    assert "target_id" in str(exc.value)


def test_n4_target_id_64_chars_accepted(patched_root: Path) -> None:
    result = derive_status("autopilot", "a" * 64)
    assert result == IDLE_DEFAULT


def test_m_no_io_on_invalid_kind(monkeypatch: pytest.MonkeyPatch) -> None:
    called = {"flag": False}

    def fail_is_file(self: Path) -> bool:
        called["flag"] = True
        return False

    monkeypatch.setattr(Path, "is_file", fail_is_file)
    with pytest.raises(ValueError):
        derive_status("nope", "feat-x")
    assert not called["flag"]


# --- Group J: OSError handling ---------------------------------------------


def test_o1_permission_error_returns_cached(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    first = derive_status("autopilot", "feat-x")
    offset_before = status_helper._STATE_CACHE[("autopilot", "feat-x")].byte_offset
    # force a re-read by appending a phase_complete, then make open() fail
    append_lifecycle(path, action="phase_complete", phase="ba")

    real_open = builtins.open

    def raising_open(file: Any, *args: Any, **kwargs: Any) -> Any:
        if str(file).endswith("autopilot-stream.ndjson"):
            raise PermissionError("simulated EACCES")
        return real_open(file, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", raising_open)
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        second = derive_status("autopilot", "feat-x")
    assert second == first
    msgs = _warnings(caplog)
    assert len(msgs) == 1
    assert "PermissionError" in msgs[0] or "autopilot-stream.ndjson" in msgs[0]
    assert status_helper._STATE_CACHE[("autopilot", "feat-x")].byte_offset == offset_before


def test_o2_file_not_found_race(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    derive_status("autopilot", "feat-x")
    append_lifecycle(path, action="phase_complete", phase="ba")

    real_open = builtins.open

    def raising_open(file: Any, *args: Any, **kwargs: Any) -> Any:
        if str(file).endswith("autopilot-stream.ndjson"):
            raise FileNotFoundError("race after stat")
        return real_open(file, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", raising_open)
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result["status"] == "running"
    assert result["last_phase_complete"] is None  # the failing read couldn't pick it up
    assert len(_warnings(caplog)) == 1


def test_o3_first_call_oserror_returns_idle(
    patched_root: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    real_open = builtins.open

    def raising_open(file: Any, *args: Any, **kwargs: Any) -> Any:
        if str(file).endswith("autopilot-stream.ndjson"):
            raise PermissionError("simulated EACCES")
        return real_open(file, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", raising_open)
    with caplog.at_level("WARNING", logger=LOGGER_NAME):
        result = derive_status("autopilot", "feat-x")
    assert result == IDLE_DEFAULT
    assert len(_warnings(caplog)) == 1


# --- Group K: Chain target_kind --------------------------------------------


def test_l1_chain_resolves_chain_events(patched_root: Path) -> None:
    path = make_stream(patched_root, "chain", "demo-plan")
    append_lifecycle(path, action="started", target="demo-plan", ts="2026-05-14T10:00:00Z")
    result = derive_status("chain", "demo-plan")
    assert result["status"] == "running"
    assert result["started_at"] == "2026-05-14T10:00:00Z"


def test_l2_cross_kind_isolation(patched_root: Path) -> None:
    p_a = make_stream(patched_root, "autopilot", "feat-x")
    p_c = make_stream(patched_root, "chain", "feat-x")
    append_lifecycle(p_a, action="started", ts="2026-05-14T10:00:00Z")
    append_lifecycle(p_c, action="started", ts="2026-05-14T20:00:00Z")
    assert derive_status("autopilot", "feat-x")["started_at"] == "2026-05-14T10:00:00Z"
    assert derive_status("chain", "feat-x")["started_at"] == "2026-05-14T20:00:00Z"


def test_l3_wrong_kind_does_not_fallback(patched_root: Path) -> None:
    make_stream(patched_root, "chain", "demo-plan")
    result = derive_status("autopilot", "demo-plan")
    assert result == IDLE_DEFAULT


def test_l4_inprogress_wins_over_done_chain(patched_root: Path) -> None:
    p_done = make_stream(patched_root, "chain", "demo-plan", prefix="DONE")
    p_inprog = make_stream(patched_root, "chain", "demo-plan", prefix="INPROGRESS")
    append_lifecycle(p_done, action="started", target="demo-plan", ts="2026-05-14T05:00:00Z")
    append_lifecycle(p_inprog, action="started", target="demo-plan", ts="2026-05-14T10:00:00Z")
    assert derive_status("chain", "demo-plan")["started_at"] == "2026-05-14T10:00:00Z"


def test_l5_inprogress_wins_over_done_autopilot(patched_root: Path) -> None:
    p_done = make_stream(patched_root, "autopilot", "feat-x", prefix="DONE")
    p_inprog = make_stream(patched_root, "autopilot", "feat-x", prefix="INPROGRESS")
    append_lifecycle(p_done, action="started", ts="2026-05-14T05:00:00Z")
    append_lifecycle(p_inprog, action="started", ts="2026-05-14T10:00:00Z")
    assert derive_status("autopilot", "feat-x")["started_at"] == "2026-05-14T10:00:00Z"


def test_l6_fallback_to_done(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x", prefix="DONE")
    append_lifecycle(path, action="started", ts="2026-05-14T05:00:00Z")
    assert derive_status("autopilot", "feat-x")["started_at"] == "2026-05-14T05:00:00Z"


# --- Group L: tmux_session stickiness --------------------------------------


def test_tmux1_sticky_across_phase_complete(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", tmux_session="autopilot-feat-x")
    append_lifecycle(path, action="phase_complete", phase="ba")
    assert derive_status("autopilot", "feat-x")["tmux_session"] == "autopilot-feat-x"


def test_tmux2_none_when_no_event_carries_field(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    append_lifecycle(path, action="phase_complete", phase="ba")
    assert derive_status("autopilot", "feat-x")["tmux_session"] is None


def test_tmux3_explicit_override(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", tmux_session="A")
    append_lifecycle(path, action="started", tmux_session="B")
    assert derive_status("autopilot", "feat-x")["tmux_session"] == "B"


def test_tmux4_reset_clears_tmux_session(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", tmux_session="A")
    derive_status("autopilot", "feat-x")
    path.write_bytes(b"")
    append_lifecycle(path, action="started", ts="2026-05-14T11:00:00Z")
    assert derive_status("autopilot", "feat-x")["tmux_session"] is None


def test_tmux5_paused_carries_tmux_session(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    append_lifecycle(path, action="paused", phase_at_pause="plan", tmux_session="autopilot-feat-x")
    assert derive_status("autopilot", "feat-x")["tmux_session"] == "autopilot-feat-x"


# --- Group M: started_at semantics ------------------------------------------


def test_st1_two_started_events_most_recent_wins(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    append_lifecycle(path, action="started", ts="2026-05-14T11:00:00Z")
    assert derive_status("autopilot", "feat-x")["started_at"] == "2026-05-14T11:00:00Z"


def test_st2_phase_complete_before_started_keeps_started_at_none(
    patched_root: Path,
) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="phase_complete", phase="ba")
    result = derive_status("autopilot", "feat-x")
    assert result["started_at"] is None
    assert result["last_phase_complete"] == "ba"
    assert result["status"] == "running"


def test_st3_started_at_updates_across_polls(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started", ts="2026-05-14T10:00:00Z")
    first = derive_status("autopilot", "feat-x")
    assert first["started_at"] == "2026-05-14T10:00:00Z"
    append_lifecycle(path, action="started", ts="2026-05-14T11:00:00Z")
    second = derive_status("autopilot", "feat-x")
    assert second["started_at"] == "2026-05-14T11:00:00Z"


# --- Group N: Multiple paused events ----------------------------------------


def test_pause1_multiple_paused_most_recent_wins(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    append_lifecycle(path, action="paused", phase_at_pause="plan")
    append_lifecycle(path, action="paused", phase_at_pause="qa")
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "paused"
    assert result["phase_at_pause"] == "qa"


# --- Group P: Cache reset hook ----------------------------------------------


def test_cache1_reset_hook_clears(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_lifecycle(path, action="started")
    derive_status("autopilot", "feat-x")
    assert ("autopilot", "feat-x") in status_helper._STATE_CACHE
    status_helper._reset_cache()
    assert status_helper._STATE_CACHE == {}


def test_cache2_autouse_fixture_isolates() -> None:
    status_helper._STATE_CACHE[("autopilot", "sentinel")] = status_helper._CachedState(
        byte_offset=0,
        status="idle",
        phase_at_pause=None,
        last_phase_complete=None,
        started_at=None,
        tmux_session=None,
    )
    status_helper._reset_cache()
    assert status_helper._STATE_CACHE == {}


# --- Group Q: lifecycle_events.parse_event reuse ---------------------------


def test_reuse1_helper_imports_parse_event() -> None:
    assert status_helper.parse_event is lifecycle_events.parse_event


def test_reuse2_round_trip_through_append_event(patched_root: Path) -> None:
    path = make_stream(patched_root, "autopilot", "feat-x")
    append_event(
        path,
        {
            "ts": "2026-05-14T10:00:00Z",
            "type": "lifecycle",
            "action": "started",
            "source": "cli",
            "target": "feat-x",
        },
    )
    result = derive_status("autopilot", "feat-x")
    assert result["status"] == "running"


# --- Group R: Plan-level invariants -----------------------------------------


_HELPER_FILE = Path(__file__).resolve().parents[1] / "server" / "status_helper.py"
_TEST_FILE = Path(__file__).resolve()
_ALLOWED_STDLIB = {
    "json",
    "logging",
    "os",
    "re",
    "pathlib",
    "typing",
    "dataclasses",
    "collections",
    "__future__",
    # controls-06 #17 — _is_tmux_alive shells out to `tmux has-session`
    # via subprocess.run; kept in the pure-stdlib set so status_helper
    # doesn't need a server.tmux_session cross-import.
    "subprocess",
}
_ALLOWED_FIRST_PARTY = {
    "server.lifecycle_events",
    "dashboard.server.lifecycle_events",
    ".lifecycle_events",
}


def _collect_imports(source: str) -> list[str]:
    import ast

    tree = ast.parse(source)
    names: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            mod = node.module or ""
            prefix = "." * node.level
            names.append(prefix + mod)
    return names


def test_inv1_no_fastapi_imports() -> None:
    source = _HELPER_FILE.read_text(encoding="utf-8")
    imports = _collect_imports(source)
    forbidden = ("fastapi", "starlette", "pydantic", "uvicorn")
    for name in imports:
        for bad in forbidden:
            assert not name.startswith(bad), f"forbidden import: {name}"


def test_inv2_stdlib_only_imports() -> None:
    source = _HELPER_FILE.read_text(encoding="utf-8")
    imports = _collect_imports(source)
    for name in imports:
        top = name.split(".", 1)[0]
        if name in _ALLOWED_FIRST_PARTY:
            continue
        assert top in _ALLOWED_STDLIB, f"unexpected import: {name}"


def test_inv6_loc_budget() -> None:
    # R19 declared budgets: helper ≤ 140, tests ≤ 320. Both files overrun
    # because the TESTPLAN authored ~50 scenarios (not 15) and the helper
    # required ~200 LOC for the full state machine + cache + I/O recovery
    # + OCP fall-through + structured logging. Per R19's "flag overrun as
    # deviation, do not silently expand scope" clause, both overruns are
    # disclosed in the /implement checkpoint report. This guard pins the
    # current realistic ceiling so future drift is caught.
    helper_lines = _HELPER_FILE.read_text(encoding="utf-8").splitlines()
    test_lines = _TEST_FILE.read_text(encoding="utf-8").splitlines()
    # controls-06 #17 raised the ceiling from 220 → 260 to absorb the
    # tmux-liveness reconciliation (_is_tmux_alive + the reconciliation
    # branch in derive_status). The feature is necessary to surface
    # stale-running chains (chain_blocked / watchdog kill exits without
    # a terminal lifecycle event); the cycle-19 split-into-submodule
    # refactor will rebudget if drift continues.
    # controls-07 #7 raised the test ceiling 1130 → 1140 for c2e
    # (fail-closed on probe raise) + c2g (warning carries str(exc)).
    # Both are 5-9 lines; the cost is justified because the prior
    # fail-open contract was the actual root cause of an empirically-
    # observed UI bug (tmux not on dashboard PATH → status claimed
    # alive → terminal empty).
    # dashboard-perf 2026-06-02 raised helper 280 → 285 (the
    # _TMUX_PROBE_TIMEOUT_S constant + its rationale comment) and tests
    # 1145 → 1175 (the bounded-timeout perf guard + import-time real-fn
    # capture). The probe fires once per live session on every poll; a
    # bounded timeout removes the head-of-line stall a wedged tmux caused.
    assert len(helper_lines) <= 285, f"helper {len(helper_lines)} LOC > 285 ceiling"
    assert len(test_lines) <= 1175, f"tests {len(test_lines)} LOC > 1175 ceiling"


# --- Sanity: public surface ------------------------------------------------


def test_public_surface_status_values() -> None:
    assert STATUS_VALUES == (
        "idle",
        "running",
        "paused",
        "cancelled",
        "completed",
        "failed",
    )


def test_public_surface_target_kinds() -> None:
    assert TARGET_KINDS == ("autopilot", "chain")


def test_tmux_probe_uses_bounded_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    """Perf guard (dashboard-perf 2026-06-02): the per-poll ``tmux has-session``
    probe must use a short timeout. A 2 s timeout multiplied by N live sessions
    can pin a threadpool thread for seconds when tmux is wedged, which is the
    exact head-of-line stall this work removed. Bound it to <= 0.5 s."""
    captured: dict[str, Any] = {}

    class _FakeResult:
        returncode = 0
        stderr = b""

    def fake_run(argv: list[str], **kwargs: Any) -> _FakeResult:
        captured.update(kwargs)
        return _FakeResult()

    monkeypatch.setattr(status_helper.subprocess, "run", fake_run)
    # Real implementation (autouse fixture stubs the module attribute).
    assert _REAL_IS_TMUX_ALIVE("chain-demo") is True
    assert captured.get("timeout", 99.0) <= 0.5
