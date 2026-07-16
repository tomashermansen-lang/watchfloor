"""Unit tests for server/resume_helper.py.

Covers TC-A through TC-O (R14) and acceptance scenarios AS1-AS13 from
docs/INPROGRESS_Feature_resume-state-detection/REQUIREMENTS.md.
"""

from __future__ import annotations

import inspect
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dashboard.server import resume_helper  # noqa: E402
from dashboard.server.resume_helper import StreamUnavailableError, detect_next_phase  # noqa: E402

LOGGER_NAME = "dashboard.server.resume_helper"
REPO_ROOT = Path(__file__).resolve().parents[2]
PHASE_SELECTOR = (
    REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib" / "phase-selector.sh"
)


def _warnings(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [
        r.getMessage() for r in caplog.records if r.name == LOGGER_NAME and r.levelname == "WARNING"
    ]


@pytest.fixture(scope="session")
def phase_order() -> tuple[str, ...]:
    cmd = f'set -e; source {shlex.quote(str(PHASE_SELECTOR))}; printf "%s\\n" "${{PHASE_ORDER[*]}}"'
    out = subprocess.check_output(["bash", "-c", cmd], text=True, timeout=5)
    return tuple(out.strip().split())


@pytest.fixture
def project_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(resume_helper, "_get_all_project_roots", lambda: [str(tmp_path)])
    monkeypatch.setattr(resume_helper, "_PHASE_ORDER_CACHE", None)
    return tmp_path


def _evt(phase: str, **extra: object) -> dict[str, object]:
    base: dict[str, object] = {
        "ts": "2026-05-14T10:00:00Z",
        "type": "lifecycle",
        "action": "phase_complete",
        "source": "cli",
        "target": "x",
        "phase": phase,
    }
    base.update(extra)
    return base


def _autopilot_stream(root: Path, target_id: str, *, state: str = "INPROGRESS") -> Path:
    return root / "docs" / f"{state}_Feature_{target_id}" / "autopilot-stream.ndjson"


def _chain_stream(root: Path, target_id: str, *, state: str = "INPROGRESS") -> Path:
    return root / "docs" / f"{state}_Plan_{target_id}" / "chain-events.ndjson"


def _write_stream(stream_path: Path, lines: list) -> Path:
    stream_path.parent.mkdir(parents=True, exist_ok=True)
    rendered = [json.dumps(ln) if isinstance(ln, dict) else ln for ln in lines]
    stream_path.write_text(("\n".join(rendered) + "\n") if rendered else "", encoding="utf-8")
    return stream_path


# ---- TC-L*, TC-M* — argument validation ----


class TestValidateArgs:
    @pytest.mark.parametrize("kind", ["", "AUTOPILOT", "feature", "chain ", "autopilot "])
    def test_invalid_target_kind_raises(self, kind: str) -> None:
        with pytest.raises(ValueError, match="target_kind"):
            detect_next_phase(kind, "x")

    def test_target_kind_none_raises(self) -> None:
        with pytest.raises(ValueError, match="target_kind"):
            detect_next_phase(None, "x")  # type: ignore[arg-type]

    def test_invalid_target_kind_no_filesystem(self, monkeypatch: pytest.MonkeyPatch) -> None:
        def boom(*_a, **_kw):
            raise AssertionError("subprocess called for invalid target_kind")

        monkeypatch.setattr(resume_helper.subprocess, "run", boom)
        monkeypatch.setattr(
            resume_helper, "_get_all_project_roots", lambda: pytest.fail("touched FS")
        )
        with pytest.raises(ValueError, match="target_kind"):
            detect_next_phase("nope", "x")

    @pytest.mark.parametrize(
        "tid",
        ["", "id with space", "a/b", "x" * 65, "feat$", "../etc", "x/../y"],
    )
    def test_invalid_target_id_raises(self, tid: str) -> None:
        with pytest.raises(ValueError, match="target_id"):
            detect_next_phase("autopilot", tid)

    def test_target_id_none_raises(self) -> None:
        with pytest.raises(ValueError, match="target_id"):
            detect_next_phase("autopilot", None)  # type: ignore[arg-type]

    def test_target_id_64_chars_accepted(
        self, project_root: Path, phase_order: tuple[str, ...]
    ) -> None:
        tid = "x" * 64
        _write_stream(_autopilot_stream(project_root, tid), [_evt(phase_order[0])])
        assert detect_next_phase("autopilot", tid) == phase_order[1]

    @pytest.mark.parametrize("tid", ["abc", "AbC123", "feat-1_2", "X-Y_z-9"])
    def test_target_id_charset_accepted(
        self, tid: str, project_root: Path, phase_order: tuple[str, ...]
    ) -> None:
        _write_stream(_autopilot_stream(project_root, tid), [_evt(phase_order[0])])
        assert detect_next_phase("autopilot", tid) == phase_order[1]


# ---- TC-N*, TC-O* — _load_phase_order ----


class TestLoadPhaseOrder:
    def test_subprocess_called_once_across_calls(
        self, project_root: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        real = subprocess.run
        counter = {"n": 0}

        def counting(*args, **kw):
            counter["n"] += 1
            return real(*args, **kw)

        monkeypatch.setattr(resume_helper.subprocess, "run", counting)
        for tid in ("a", "b", "c"):
            _write_stream(_autopilot_stream(project_root, tid), [_evt("ba")])
            assert detect_next_phase("autopilot", tid) == "plan"
        assert counter["n"] == 1

    def test_called_process_error_keeps_cache_none(
        self, project_root: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        def boom(*_a, **_kw):
            raise subprocess.CalledProcessError(1, ["bash"], stderr="x")

        monkeypatch.setattr(resume_helper.subprocess, "run", boom)
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        with pytest.raises(StreamUnavailableError, match="PHASE_ORDER"):
            detect_next_phase("autopilot", "x")
        assert resume_helper._PHASE_ORDER_CACHE is None

    @pytest.mark.parametrize(
        "exc",
        [
            FileNotFoundError("bash"),
            subprocess.TimeoutExpired(["bash"], 5),
        ],
    )
    def test_subprocess_other_failures_raise(
        self,
        exc: Exception,
        project_root: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        def boom(*_a, **_kw):
            raise exc

        monkeypatch.setattr(resume_helper.subprocess, "run", boom)
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        with pytest.raises(StreamUnavailableError, match="PHASE_ORDER"):
            detect_next_phase("autopilot", "x")

    @pytest.mark.parametrize("stdout", ["\n", "", "ba plan; rm", "BA plan", "ba " + "x" * 33])
    def test_invalid_stdout_rejected(
        self,
        stdout: str,
        project_root: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        completed = subprocess.CompletedProcess(["bash"], 0, stdout=stdout, stderr="")
        monkeypatch.setattr(resume_helper.subprocess, "run", lambda *a, **kw: completed)
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        with pytest.raises(StreamUnavailableError, match="PHASE_ORDER"):
            detect_next_phase("autopilot", "x")

    def test_failed_then_successful_call(
        self, project_root: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        real = subprocess.run
        calls = {"n": 0}

        def flaky(*args, **kw):
            calls["n"] += 1
            if calls["n"] == 1:
                raise subprocess.CalledProcessError(1, args[0], stderr="x")
            return real(*args, **kw)

        monkeypatch.setattr(resume_helper.subprocess, "run", flaky)
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        with pytest.raises(StreamUnavailableError):
            detect_next_phase("autopilot", "x")
        assert detect_next_phase("autopilot", "x") == "plan"

    def test_phase_selector_path_is_real_file(self) -> None:
        assert resume_helper._PHASE_SELECTOR_PATH.is_file()
        assert resume_helper._PHASE_SELECTOR_PATH.name == "phase-selector.sh"

    def test_real_subprocess_returns_current_phases(
        self, monkeypatch: pytest.MonkeyPatch, phase_order: tuple[str, ...]
    ) -> None:
        monkeypatch.setattr(resume_helper, "_PHASE_ORDER_CACHE", None)
        assert resume_helper._load_phase_order() == phase_order


# ---- TC-RP* — _resolve_stream_path ----


class TestResolveStreamPath:
    def test_inprogress_feature_returned(self, project_root: Path) -> None:
        _write_stream(_autopilot_stream(project_root, "demo"), [_evt("ba")])
        assert detect_next_phase("autopilot", "demo") == "plan"

    def test_done_feature_returned_when_only_done(self, project_root: Path) -> None:
        _write_stream(_autopilot_stream(project_root, "demo", state="DONE"), [_evt("ba")])
        assert detect_next_phase("autopilot", "demo") == "plan"

    def test_inprogress_wins_when_both_exist(self, project_root: Path) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        _write_stream(_autopilot_stream(project_root, "x", state="DONE"), [_evt("plan")])
        assert detect_next_phase("autopilot", "x") == "plan"

    def test_chain_inprogress_returned(self, project_root: Path) -> None:
        _write_stream(_chain_stream(project_root, "demo-plan"), [_evt("review")])
        assert detect_next_phase("chain", "demo-plan") == "implement"

    def test_chain_done_returned_when_only_done(self, project_root: Path) -> None:
        _write_stream(_chain_stream(project_root, "p", state="DONE"), [_evt("review")])
        assert detect_next_phase("chain", "p") == "implement"

    def test_no_candidate_raises_not_found(self, project_root: Path) -> None:
        with pytest.raises(StreamUnavailableError) as exc:
            detect_next_phase("autopilot", "missing")
        s = str(exc.value)
        assert "target_kind=autopilot" in s
        assert "target_id=missing" in s
        assert "reason=not_found" in s

    def test_directory_at_candidate_raises_not_a_file(self, project_root: Path) -> None:
        _autopilot_stream(project_root, "x").mkdir(parents=True)
        with pytest.raises(StreamUnavailableError, match="reason=not_a_file"):
            detect_next_phase("autopilot", "x")

    def test_symlink_outside_roots_rejected(
        self,
        project_root: Path,
        tmp_path_factory: pytest.TempPathFactory,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        outside = tmp_path_factory.mktemp("outside") / "evil.ndjson"
        outside.write_text("DO NOT READ\n", encoding="utf-8")
        monkeypatch.setattr(
            resume_helper,
            "_is_allowed_path",
            lambda p: str(p).startswith(str(project_root) + "/"),
        )
        target = _autopilot_stream(project_root, "evil")
        target.parent.mkdir(parents=True)
        target.symlink_to(outside)
        with pytest.raises(StreamUnavailableError, match="reason=outside_roots"):
            detect_next_phase("autopilot", "evil")

    def test_chain_kind_does_not_match_feature_dir(self, project_root: Path) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        with pytest.raises(StreamUnavailableError, match="reason=not_found"):
            detect_next_phase("chain", "x")

    def test_multiple_roots_first_match_wins(
        self,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path_factory: pytest.TempPathFactory,
    ) -> None:
        r1 = tmp_path_factory.mktemp("r1")
        r2 = tmp_path_factory.mktemp("r2")
        monkeypatch.setattr(resume_helper, "_get_all_project_roots", lambda: [str(r1), str(r2)])
        monkeypatch.setattr(resume_helper, "_PHASE_ORDER_CACHE", None)
        _write_stream(_autopilot_stream(r2, "demo"), [_evt("ba")])
        assert detect_next_phase("autopilot", "demo") == "plan"


# ---- TC-A, TC-B, TC-C, TC-D, TC-H, TC-I, TC-E*, TC-NL*, TC-Scan-*, TC-G ----


class TestScanLastPhaseComplete:
    def test_happy_path_per_phase(self, project_root: Path, phase_order: tuple[str, ...]) -> None:
        for i, prev in enumerate(phase_order):
            tid = f"hp-{i}"
            _write_stream(_autopilot_stream(project_root, tid), [_evt(prev)])
            expected = phase_order[i + 1] if i + 1 < len(phase_order) else None
            assert detect_next_phase("autopilot", tid) == expected

    def test_as1_ba_plan_review_returns_implement(self, project_root: Path) -> None:
        _write_stream(
            _autopilot_stream(project_root, "demo"),
            [_evt("ba"), _evt("plan"), _evt("review")],
        )
        assert detect_next_phase("autopilot", "demo") == "implement"

    def test_as6_last_phase_returns_none(
        self, project_root: Path, phase_order: tuple[str, ...]
    ) -> None:
        _write_stream(_autopilot_stream(project_root, "done"), [_evt(phase_order[-1])])
        assert detect_next_phase("autopilot", "done") is None

    def test_empty_stream_returns_first_phase(
        self, project_root: Path, phase_order: tuple[str, ...]
    ) -> None:
        path = _autopilot_stream(project_root, "fresh")
        path.parent.mkdir(parents=True)
        path.write_text("", encoding="utf-8")
        assert detect_next_phase("autopilot", "fresh") == phase_order[0]

    def test_whitespace_only_stream_returns_first_no_warning(
        self,
        project_root: Path,
        phase_order: tuple[str, ...],
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        path = _autopilot_stream(project_root, "ws")
        path.parent.mkdir(parents=True)
        path.write_text("\n\n   \n", encoding="utf-8")
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("autopilot", "ws") == phase_order[0]
        assert _warnings(caplog) == []

    def test_only_non_phase_complete_events_no_warning(
        self,
        project_root: Path,
        phase_order: tuple[str, ...],
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        legacy = json.dumps({"type": "phase", "name": "ba", "status": "completed"})
        lines = [
            _evt("ba", action="started"),
            _evt("ba", action="paused"),
            legacy,
        ]
        _write_stream(_autopilot_stream(project_root, "f"), lines)
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("autopilot", "f") == phase_order[0]
        assert _warnings(caplog) == []

    def test_corrupt_json_skipped_one_warning(
        self, project_root: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        bad = '{"type":"lifecycle","action":"phase_complete","phase":"this is not valid json'
        _write_stream(
            _autopilot_stream(project_root, "x"),
            [_evt("ba"), bad, _evt("plan")],
        )
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("autopilot", "x") == "testplan"
        warnings = _warnings(caplog)
        assert len(warnings) == 1
        assert "line 2" in warnings[0]
        assert "this is not valid json" not in warnings[0]

    def test_multiple_corrupt_lines_each_warned(
        self, project_root: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        bad = "{not json"
        _write_stream(
            _autopilot_stream(project_root, "y"),
            [bad, _evt("ba"), bad, _evt("plan"), bad],
        )
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("autopilot", "y") == "testplan"
        warnings = _warnings(caplog)
        assert len(warnings) == 3
        assert any("line 1" in w for w in warnings)
        assert any("line 3" in w for w in warnings)
        assert any("line 5" in w for w in warnings)

    def test_extra_fields_tolerated(self, project_root: Path) -> None:
        ev = _evt("ba", tmux_session="t", correlation_id="c", future_field=42)
        _write_stream(_autopilot_stream(project_root, "x"), [ev])
        assert detect_next_phase("autopilot", "x") == "plan"

    def test_unknown_action_skipped(self, project_root: Path) -> None:
        unknown = _evt("ba", action="task_completed")
        _write_stream(_autopilot_stream(project_root, "x"), [unknown, _evt("plan")])
        assert detect_next_phase("autopilot", "x") == "testplan"

    @pytest.mark.parametrize("override", [{}, {"phase": ""}, {"phase": 42}])
    def test_phase_field_problems_silently_skipped(
        self,
        override: dict,
        project_root: Path,
        phase_order: tuple[str, ...],
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        ev = _evt("ba")
        ev.update(override)
        if "phase" not in override:
            ev.pop("phase", None)
        _write_stream(_autopilot_stream(project_root, "x"), [ev])
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("autopilot", "x") == phase_order[0]
        assert _warnings(caplog) == []

    @pytest.mark.parametrize("raw", ["[1,2,3]", "true", "42", '"string"'])
    def test_non_dict_top_level_silently_skipped(
        self,
        raw: str,
        project_root: Path,
        phase_order: tuple[str, ...],
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [raw])
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("autopilot", "x") == phase_order[0]
        assert _warnings(caplog) == []

    def test_open_permission_error_raises_io_error(
        self, project_root: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        path = _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        real_open = open

        def deny(p, *a, **kw):
            if Path(str(p)) == path:
                raise PermissionError("denied")
            return real_open(p, *a, **kw)

        monkeypatch.setattr("builtins.open", deny)
        with pytest.raises(StreamUnavailableError) as exc:
            detect_next_phase("autopilot", "x")
        s = str(exc.value)
        assert "reason=io_error" in s
        assert "target_kind=autopilot" in s
        assert "target_id=x" in s

    def test_open_file_not_found_after_check_raises_io_error(
        self, project_root: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        path = _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        real_open = open

        def gone(p, *a, **kw):
            if Path(str(p)) == path:
                raise FileNotFoundError("vanished")
            return real_open(p, *a, **kw)

        monkeypatch.setattr("builtins.open", gone)
        with pytest.raises(StreamUnavailableError, match="reason=io_error"):
            detect_next_phase("autopilot", "x")

    def test_duplicate_phase_complete_last_wins(self, project_root: Path) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("plan"), _evt("plan")])
        assert detect_next_phase("autopilot", "x") == "testplan"

    def test_interleaved_lifecycle_events(self, project_root: Path) -> None:
        lines = [
            _evt("xx", action="started"),
            _evt("ba"),
            _evt("xx", action="paused"),
            _evt("plan"),
        ]
        _write_stream(_autopilot_stream(project_root, "x"), lines)
        assert detect_next_phase("autopilot", "x") == "testplan"

    def test_phase_complete_followed_by_started(self, project_root: Path) -> None:
        lines = [_evt("plan"), _evt("xx", action="started")]
        _write_stream(_autopilot_stream(project_root, "x"), lines)
        assert detect_next_phase("autopilot", "x") == "testplan"


# ---- TC-J* — _next_phase pure unit ----


class TestNextPhase:
    def test_unknown_phase_returns_first_with_warning(
        self,
        project_root: Path,
        phase_order: tuple[str, ...],
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("frobnicate")])
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("autopilot", "x") == phase_order[0]
        warnings = _warnings(caplog)
        assert len(warnings) == 1
        assert "frobnicate" in warnings[0]

    def test_pure_unit_none(self) -> None:
        assert resume_helper._next_phase(None, ("ba", "plan")) == "ba"

    def test_pure_unit_last(self) -> None:
        assert resume_helper._next_phase("plan", ("ba", "plan")) is None

    def test_pure_unit_mid(self) -> None:
        assert resume_helper._next_phase("ba", ("ba", "plan", "testplan")) == "plan"


# ---- TC-K*, TC-AS*, TC-Pure*, TC-OrderArg, TC-PublicSurface, TC-Subclass, TC-MsgFormat ----


class TestDetectNextPhase:
    def test_chain_reads_chain_events(self, project_root: Path) -> None:
        _write_stream(_chain_stream(project_root, "p"), [_evt("review")])
        assert detect_next_phase("chain", "p") == "implement"

    def test_chain_unknown_phase_returns_first_with_warning(
        self,
        project_root: Path,
        phase_order: tuple[str, ...],
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        _write_stream(_chain_stream(project_root, "p"), [_evt("backend-substrate")])
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("chain", "p") == phase_order[0]
        assert any("backend-substrate" in w for w in _warnings(caplog))

    def test_cross_validation_via_append_event(
        self, project_root: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        from dashboard.server.lifecycle_events import append_event

        path = _autopilot_stream(project_root, "x")
        path.parent.mkdir(parents=True)
        append_event(path, _evt("implement"))
        with caplog.at_level("WARNING", logger=LOGGER_NAME):
            assert detect_next_phase("autopilot", "x") == "qa"
        assert _warnings(caplog) == []

    def test_phase_order_advances_via_alternate_selector(
        self, project_root: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        alt = project_root / "alt-phase-selector.sh"
        alt.write_text(
            "declare -a PHASE_ORDER=(ba plan testplan review implement qa "
            "static-analysis newphase commit)\n",
            encoding="utf-8",
        )
        monkeypatch.setattr(resume_helper, "_PHASE_SELECTOR_PATH", alt)
        monkeypatch.setattr(resume_helper, "_PHASE_ORDER_CACHE", None)
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("static-analysis")])
        assert detect_next_phase("autopilot", "x") == "newphase"

    def test_pure_function_repeated_call_same_value(self, project_root: Path) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        a = detect_next_phase("autopilot", "x")
        b = detect_next_phase("autopilot", "x")
        assert a == b == "plan"

    def test_does_not_print_to_stdout(
        self, project_root: Path, capsys: pytest.CaptureFixture
    ) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        detect_next_phase("autopilot", "x")
        assert capsys.readouterr().out == ""

    def test_does_not_mutate_environ(self, project_root: Path) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        snapshot = dict(os.environ)
        detect_next_phase("autopilot", "x")
        assert dict(os.environ) == snapshot

    def test_signature_target_kind_first(self) -> None:
        sig = inspect.signature(detect_next_phase)
        assert list(sig.parameters) == ["target_kind", "target_id"]

    def test_keyword_invocation_works(self, project_root: Path) -> None:
        _write_stream(_autopilot_stream(project_root, "x"), [_evt("ba")])
        assert detect_next_phase(target_kind="autopilot", target_id="x") == "plan"

    def test_public_surface(self) -> None:
        public = {n for n in dir(resume_helper) if not n.startswith("_")}
        assert "detect_next_phase" in public
        assert "StreamUnavailableError" in public

    def test_stream_unavailable_is_runtime_error(self) -> None:
        assert issubclass(StreamUnavailableError, RuntimeError)

    def test_no_git_in_source(self) -> None:
        src = inspect.getsource(resume_helper)
        assert "git " not in src
        assert "git log" not in src

    @pytest.mark.parametrize(
        "reason,trigger",
        [
            ("not_found", "missing"),
            ("not_a_file", "isdir"),
        ],
    )
    def test_message_format_contains_target_and_reason(
        self, reason: str, trigger: str, project_root: Path
    ) -> None:
        if trigger == "isdir":
            _autopilot_stream(project_root, trigger).mkdir(parents=True)
        with pytest.raises(StreamUnavailableError) as exc:
            detect_next_phase("autopilot", trigger)
        s = str(exc.value)
        assert "target_kind=autopilot" in s
        assert f"target_id={trigger}" in s
        assert f"reason={reason}" in s


# ---- AS13 meta-test: forbidden hard-coded PHASE_ORDER literal ----


def test_as13_no_hardcoded_phase_order_in_this_file() -> None:
    text = Path(__file__).read_text(encoding="utf-8")
    parts = [
        '"ba"',
        '"plan"',
        '"testplan"',
        '"review"',
        '"implement"',
        '"qa"',
        '"static-analysis"',
        '"commit"',
    ]
    forbidden = "[" + ", ".join(parts) + "]"
    assert forbidden not in text


# ---- TC-Const*, TC-Doc1, TC-Doc2 ----


class TestModuleConstantsAndDocs:
    def test_phase_selector_path_is_real(self) -> None:
        assert resume_helper._PHASE_SELECTOR_PATH.is_file()

    def test_cache_initialised_to_none_in_source(self) -> None:
        src = inspect.getsource(resume_helper)
        assert "_PHASE_ORDER_CACHE: tuple[str, ...] | None = None" in src

    def test_valid_target_kinds_frozen(self) -> None:
        assert resume_helper._VALID_TARGET_KINDS == frozenset({"autopilot", "chain"})
        assert isinstance(resume_helper._VALID_TARGET_KINDS, frozenset)

    def test_logger_name(self) -> None:
        assert resume_helper.logger.name == "dashboard.server.resume_helper"

    def test_claude_md_mentions_resume_helper(self) -> None:
        text = (REPO_ROOT / "CLAUDE.md").read_text(encoding="utf-8")
        assert text.count("resume_helper.py") >= 1

    def test_claude_md_describes_public_surface(self) -> None:
        text = (REPO_ROOT / "CLAUDE.md").read_text(encoding="utf-8")
        idx = text.find("resume_helper.py")
        section = text[idx : idx + 400]
        assert "detect_next_phase" in section
        assert "StreamUnavailableError" in section
