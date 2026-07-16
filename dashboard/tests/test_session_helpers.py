"""Tests for server/session_helpers.py.

Currently focused on the DASHBOARD_DATA_DIR override that aligns
session_helpers with feature_helpers and metrics_helpers — when the env
var is set, session reads must come from that directory rather than the
hardcoded ``<repo>/dashboard/data/`` default.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dashboard.server import session_helpers


def _write_jsonl(path: Path, entries: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for entry in entries:
            fh.write(json.dumps(entry) + "\n")


def test_data_dir_honors_dashboard_data_dir_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``_data_dir`` returns DASHBOARD_DATA_DIR when set."""
    monkeypatch.setenv("DASHBOARD_DATA_DIR", str(tmp_path))
    assert session_helpers._data_dir() == tmp_path


def test_data_dir_falls_back_to_default_when_unset(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """``_data_dir`` returns ``<repo>/dashboard/data`` when env unset."""
    monkeypatch.delenv("DASHBOARD_DATA_DIR", raising=False)
    expected = Path(session_helpers.__file__).resolve().parent.parent / "data"
    assert session_helpers._data_dir() == expected


def test_get_session_states_reads_from_env_data_dir(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """get_session_states must source sessions.jsonl from DASHBOARD_DATA_DIR."""
    fake_data = tmp_path / "dashboard-data"
    # cwd must not contain "/tmp/" (excluded as a test/temp pattern). Use a
    # plausible-looking absolute path string that won't be mistaken for one.
    _write_jsonl(
        fake_data / "sessions.jsonl",
        [
            {
                "sid": "test-session-1",
                "cwd": "/var/work/example",
                "branch": "feature/example",
                "event": "Stop",
                "type": "",
                "msg": "hermetic test event",
                "ts": "2024-01-01T00:00:00Z",
            }
        ],
    )
    monkeypatch.setenv("DASHBOARD_DATA_DIR", str(fake_data))
    states = session_helpers.get_session_states()
    sids = {s.get("sid") for s in states}
    assert "test-session-1" in sids, (
        f"Expected get_session_states to read the env-pointed sessions.jsonl, got sids={sids!r}"
    )


def test_get_session_activity_reads_from_env_data_dir(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """get_session_activity must source sessions.jsonl from DASHBOARD_DATA_DIR."""
    fake_data = tmp_path / "dashboard-data"
    _write_jsonl(
        fake_data / "sessions.jsonl",
        [
            {
                "sid": "act-1",
                "cwd": "/work",
                "branch": "feature/hermetic",
                "event": "PreToolUse",
                "type": "Bash",
                "msg": '{"command":"echo hi"}',
                "ts": "2024-01-01T00:00:00Z",
            }
        ],
    )
    monkeypatch.setenv("DASHBOARD_DATA_DIR", str(fake_data))
    events = session_helpers.get_session_activity("hermetic")
    assert events, "Expected get_session_activity to find the env-pointed event"
    assert events[0]["sid"] == "act-1"


def test_get_session_activity_reads_only_byte_tail(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Perf (dashboard-perf 2026-06-02 #4): get_session_activity must read only
    a bounded trailing slice of sessions.jsonl, never the whole (unbounded,
    all-projects) log on every poll. Events older than the tail window are not
    returned, and the truncated first line is dropped without a parse error."""
    fake_data = tmp_path / "dashboard-data"
    fake_data.mkdir(parents=True)
    path = fake_data / "sessions.jsonl"

    def ev(sid: str, ts: str) -> dict:
        return {
            "sid": sid,
            "cwd": "/work",
            "branch": "feature/tailcase",
            "event": "PreToolUse",
            "type": "Bash",
            "msg": json.dumps({"command": f"cmd-{sid}"}),
            "ts": ts,
        }

    # Oldest line matches the feature but sits before the tail window; the
    # newer lines push it past the byte budget set below.
    lines = [json.dumps(ev("OLD", "2024-01-01T00:00:00Z"))]
    lines += [json.dumps(ev(f"new-{i}", "2024-01-02T00:00:00Z")) for i in range(50)]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    monkeypatch.setenv("DASHBOARD_DATA_DIR", str(fake_data))
    monkeypatch.setattr(session_helpers, "_ACTIVITY_TAIL_BYTES", 400)

    events = session_helpers.get_session_activity("tailcase", limit=100)
    sids = {e["sid"] for e in events}
    assert "OLD" not in sids, "event before the tail window must not be read"
    assert any(s.startswith("new-") for s in sids), "recent events must still be returned"


def test_get_session_states_returns_empty_when_env_dir_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """When env var points to a non-existent dir, returns empty list (no crash)."""
    monkeypatch.setenv("DASHBOARD_DATA_DIR", str(tmp_path / "does-not-exist"))
    states = session_helpers.get_session_states()
    assert states == []
