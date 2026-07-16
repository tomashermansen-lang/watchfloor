"""Unit tests for server/lifecycle_events.py.

Covers TC-A through TC-E (R13) and acceptance scenarios AS1-AS11 from
docs/INPROGRESS_Feature_lifecycle-event-schema/REQUIREMENTS.md.
"""

import builtins
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dashboard.server.lifecycle_events import (
    LIFECYCLE_ACTIONS,
    LIFECYCLE_SOURCES,
    LifecycleEventInvalid,
    append_event,
    parse_event,
)

LOGGER_NAME = "dashboard.server.lifecycle_events"
_BASE: dict[str, object] = {"ts": "2026-05-14T10:00:00Z", "type": "lifecycle",
                            "action": "started", "source": "cli", "target": "feat-x"}


def _evt(**o: object) -> dict[str, object]:
    return {**_BASE, **o}


def _assert_rejects(field: str, arg: object) -> None:
    with pytest.raises(LifecycleEventInvalid) as exc:
        parse_event(arg)  # type: ignore[arg-type]
    assert field in str(exc.value)


def _warnings(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [r.getMessage() for r in caplog.records
            if r.name == LOGGER_NAME and r.levelname == "WARNING"]


class TestActionEnumAccepted:
    @pytest.mark.parametrize("action", list(LIFECYCLE_ACTIONS))
    def test_a1_a5_each_action_value_accepted(self, action: str) -> None:
        event = _evt(action=action)
        assert parse_event(json.dumps(event) + "\n") == event

    @pytest.mark.parametrize("override,key,val", [
        ({"action": "phase_complete", "phase": "implement"}, "phase", "implement"),
        ({"action": "paused", "phase_at_pause": "implement"}, "phase_at_pause", "implement"),
        ({"correlation_id": "uuid-1234"}, "correlation_id", "uuid-1234"),
    ])
    def test_a6_a7_a11_extra_fields_preserved(self, override, key, val) -> None:
        assert parse_event(json.dumps(_evt(**override)))[key] == val

    @pytest.mark.parametrize("override,suffix", [
        ({"tmux_session": "autopilot-feat-x"}, ""),
        ({"target": "a" * 64}, ""),
        ({}, "\r\n"),
    ])
    def test_a8_a9_a10_round_trip_accepted(self, override, suffix) -> None:
        event = _evt(**override)
        assert parse_event(json.dumps(event) + suffix) == event

    def test_a12_lifecycle_actions_tuple(self) -> None:
        assert LIFECYCLE_ACTIONS == ("started", "paused", "resumed", "cancelled", "phase_complete")

    def test_a13_lifecycle_sources_tuple(self) -> None:
        assert LIFECYCLE_SOURCES == ("cli", "dashboard")


class TestInvalidActionRejected:
    @pytest.mark.parametrize("bad", ["frobnicate", "Paused", "", "STARTED"])
    def test_b1_b4_invalid_action_rejected(self, bad: str) -> None:
        _assert_rejects("action", json.dumps(_evt(action=bad)))


class TestMissingOrInvalidFieldRejected:
    @pytest.mark.parametrize("field", ["ts", "type", "action", "source", "target"])
    def test_c1_c5_missing_required_field_rejected(self, field: str) -> None:
        event = _evt()
        del event[field]
        _assert_rejects(field, json.dumps(event))

    def test_c6_wrong_event_type_rejected(self) -> None:
        _assert_rejects("type", json.dumps(_evt(type="gate_evaluated")))

    @pytest.mark.parametrize("bad_ts", ["1715688000.0", "Wed May 14 10:00:00 UTC 2026", None, ""])
    def test_c7_c10_ts_rejections(self, bad_ts: object) -> None:
        _assert_rejects("ts", json.dumps(_evt(ts=bad_ts)))

    @pytest.mark.parametrize("bad", ["CLI", "unknown"])
    def test_c11_c12_source_rejections(self, bad: str) -> None:
        _assert_rejects("source", json.dumps(_evt(source=bad)))

    @pytest.mark.parametrize("bad", ["feat; rm -rf /", "", "a" * 65])
    def test_c13_c15_target_rejections(self, bad: str) -> None:
        _assert_rejects("target", json.dumps(_evt(target=bad)))

    @pytest.mark.parametrize("field,event", [
        ("phase_at_pause", _evt(action="paused", phase_at_pause="")),
        ("phase_at_pause", _evt(action="paused", phase_at_pause=123)),
        ("tmux_session", _evt(tmux_session="")),
    ])
    def test_c16_c18_optional_field_rejections(self, field: str, event: dict) -> None:
        _assert_rejects(field, json.dumps(event))

    @pytest.mark.parametrize("field,arg", [
        ("json", '{"ts": "2026-05-14T10:00:00Z", "type": "lifecyc'),
        ("root", '["ts", "type", "action"]'),
        ("json", ""),
        ("json", "   \n"),
    ])
    def test_c19_c20_c24_c25_misc_parser_rejections(self, field: str, arg: str) -> None:
        _assert_rejects(field, arg)

    @pytest.mark.parametrize("bad", [None, b"bytes", 123])
    def test_c21_c23_non_string_argument_rejected(self, bad: object) -> None:
        _assert_rejects("json", bad)

    def test_c26_exception_is_value_error_subclass(self) -> None:
        assert issubclass(LifecycleEventInvalid, ValueError)


class TestAppendWriteSucceeds:
    def test_d1_single_append_round_trips(self, tmp_path: Path) -> None:
        path = tmp_path / "stream.ndjson"
        event = _evt(action="phase_complete")
        append_event(path, event)
        text = path.read_text(encoding="utf-8")
        assert text.endswith("\n") and text.count("\n") == 1
        assert parse_event(text) == event

    def test_d2_two_appends_produce_two_lines(self, tmp_path: Path) -> None:
        path = tmp_path / "stream.ndjson"
        first, second = _evt(action="started"), _evt(action="phase_complete", target="feat-y")
        append_event(path, first)
        append_event(path, second)
        lines = [ln for ln in path.read_text(encoding="utf-8").split("\n") if ln]
        assert len(lines) == 2
        assert parse_event(lines[0]) == first and parse_event(lines[1]) == second

    def test_d3_pathlib_path_argument_accepted(self, tmp_path: Path) -> None:
        path = tmp_path / "stream.ndjson"
        append_event(path, _evt())
        assert path.exists()

    @pytest.mark.parametrize("field,bad_event", [
        ("action", _evt(action="Paused")),
        ("target", {k: v for k, v in _evt().items() if k != "target"}),
        ("ts", {k: v for k, v in _evt().items() if k != "ts"}),
    ])
    def test_d4_d6_validate_before_io(self, tmp_path: Path, field: str, bad_event: dict) -> None:
        path = tmp_path / "stream.ndjson"
        with pytest.raises(LifecycleEventInvalid) as exc:
            append_event(path, bad_event)
        assert field in str(exc.value) and not path.exists()

    def test_d7_output_is_single_line_no_carriage_return(self, tmp_path: Path) -> None:
        path = tmp_path / "stream.ndjson"
        append_event(path, _evt())
        text = path.read_text(encoding="utf-8")
        assert text.count("\n") == 1 and "\r" not in text


class TestAppendUnderIOErrorLogsWithoutRaising:
    def test_e1_monkeypatched_permission_error_swallowed(self, tmp_path, monkeypatch, caplog):
        path, real_open = tmp_path / "stream.ndjson", builtins.open
        def raising_open(file, *a, **kw):
            if str(file).endswith("stream.ndjson"):
                raise PermissionError("simulated EACCES")
            return real_open(file, *a, **kw)
        monkeypatch.setattr(builtins, "open", raising_open)
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert append_event(path, _evt()) is None
        joined = " ".join(_warnings(caplog))
        assert not path.exists()
        assert "PermissionError" in joined or "simulated EACCES" in joined

    def test_e2_missing_parent_directory_swallowed(self, tmp_path, caplog):
        path = tmp_path / "nope" / "stream.ndjson"
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert append_event(path, _evt()) is None
        assert _warnings(caplog) and not (tmp_path / "nope").exists()

    def test_e3_directory_path_swallowed(self, tmp_path, caplog):
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert append_event(tmp_path, _evt()) is None
        joined = " ".join(_warnings(caplog)).lower()
        assert "isadirectoryerror" in joined or "directory" in joined

    def test_e4_no_sticky_state_after_failure(self, tmp_path, caplog):
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            append_event(tmp_path / "nope" / "stream.ndjson", _evt())
        good = tmp_path / "ok.ndjson"
        assert append_event(good, _evt()) is None
        assert parse_event(good.read_text(encoding="utf-8")) == _evt()
