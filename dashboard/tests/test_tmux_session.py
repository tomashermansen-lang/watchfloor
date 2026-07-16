"""Unit tests for dashboard/server/tmux_session.py.

Covers TESTPLAN rows D1-D11 (TestDeterministicName), S1-S16
(TestStartSession), K1-K11 (TestKillSession), L1-L15 (TestListSessions),
E1-E6 (TestSessionExists), and M1-M14 (TestModuleShape) — see
docs/INPROGRESS_Feature_tmux-session-helper/TESTPLAN.md.

Every helper takes an injectable ``Runner``; tests construct a per-test
``FakeRunner`` and never mutate the module-level ``_DEFAULT_RUNNER``.
The suite passes with no ``tmux`` binary on ``$PATH`` (R23, AC-5).
"""

from __future__ import annotations

import ast
import importlib
import inspect
import logging
import subprocess
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from subprocess import CompletedProcess
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from dashboard.server import tmux_session  # noqa: E402
from dashboard.server.tmux_session import (  # noqa: E402
    KillResult,
    Runner,
    SessionExistsError,
    TmuxError,
    deterministic_name,
    kill_session,
    list_sessions,
    session_exists,
    start_session,
)

LOGGER_NAME = "dashboard.server.tmux_session"


def _warnings(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [
        r.getMessage()
        for r in caplog.records
        if r.name == LOGGER_NAME and r.levelno >= logging.WARNING
    ]


class FakeRunner:
    """In-process stand-in for the real subprocess Runner.

    ``calls`` records every ``run`` invocation as ``(argv, cwd)`` BEFORE
    consuming ``script`` — captured even when the script raises.

    ``script`` is either a FIFO list of ``CompletedProcess`` instances
    (raises ``IndexError`` on exhaustion — tests must size scripts to
    expected call counts) or a callable invoked positionally with
    ``(argv, cwd)``.
    """

    def __init__(
        self,
        script: (
            list[CompletedProcess[str]]
            | Callable[[list[str], Path | None], CompletedProcess[str]]
            | None
        ) = None,
    ) -> None:
        self.calls: list[tuple[list[str], Path | None]] = []
        self.script: Any = script if script is not None else []

    def run(self, argv: Sequence[str], *, cwd: Path | None) -> CompletedProcess[str]:
        argv_list = list(argv)
        self.calls.append((argv_list, cwd))
        if callable(self.script):
            result: CompletedProcess[str] = self.script(argv_list, cwd)
            return result
        if not self.script:
            raise IndexError("FakeRunner: script exhausted")
        return self.script.pop(0)  # type: ignore[no-any-return]


class FileNotFoundRunner:
    """Runner that always raises FileNotFoundError, as if tmux missing."""

    def __init__(self) -> None:
        self.calls: list[tuple[list[str], Path | None]] = []

    def run(self, argv: Sequence[str], *, cwd: Path | None) -> CompletedProcess[str]:
        self.calls.append((list(argv), cwd))
        raise FileNotFoundError("tmux")


def _cp(returncode: int = 0, stdout: str = "", stderr: str = "") -> CompletedProcess[str]:
    return CompletedProcess(args=["tmux"], returncode=returncode, stdout=stdout, stderr=stderr)


# ---------------------------------------------------------------------------
# TestDeterministicName (D1-D11)
# ---------------------------------------------------------------------------


class TestDeterministicName:
    def test_d1_autopilot_kind(self) -> None:
        assert deterministic_name("autopilot", "feat-001") == "autopilot-feat-001"

    def test_d2_chain_kind(self) -> None:
        assert deterministic_name("chain", "plan-x") == "chain-plan-x"

    def test_d3_boundary_64_chars_accepted(self) -> None:
        assert deterministic_name("autopilot", "a" * 64) == "autopilot-" + "a" * 64

    def test_d4_65_chars_rejected(self) -> None:
        with pytest.raises(ValueError) as exc:
            deterministic_name("autopilot", "a" * 65)
        assert repr("a" * 65) in str(exc.value)

    def test_d5_metachars_rejected(self) -> None:
        with pytest.raises(ValueError) as exc:
            deterministic_name("autopilot", "feat; rm -rf /")
        assert "'feat; rm -rf /'" in str(exc.value)

    def test_d6_empty_target_id_rejected(self) -> None:
        with pytest.raises(ValueError):
            deterministic_name("autopilot", "")

    def test_d7_unknown_kind_rejected_with_enum_in_message(self) -> None:
        with pytest.raises(ValueError) as exc:
            deterministic_name("grinder", "x")
        msg = str(exc.value)
        assert "grinder" in msg
        assert "autopilot" in msg and "chain" in msg

    def test_d8_kind_casing_rejected(self) -> None:
        with pytest.raises(ValueError):
            deterministic_name("Autopilot", "x")

    def test_d9_kind_hyphenated_rejected(self) -> None:
        with pytest.raises(ValueError):
            deterministic_name("auto-pilot", "x")

    def test_d10_does_not_invoke_runner(self) -> None:
        # deterministic_name has no `runner=` parameter — pure function.
        # Confirm via signature introspection.
        sig = inspect.signature(deterministic_name)
        assert "runner" not in sig.parameters

    @pytest.mark.parametrize(
        "bad",
        ["", "a" * 65, "feat.x", "feat/x", "feat\nnl", "$home", "feat;rm"],
    )
    def test_d11_invalid_target_id_table(self, bad: str) -> None:
        with pytest.raises(ValueError):
            deterministic_name("autopilot", bad)


# ---------------------------------------------------------------------------
# TestStartSession (S1-S16)
# ---------------------------------------------------------------------------


class TestStartSession:
    def test_s1_argv_happy_path(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        start_session(
            "autopilot-feat",
            ["bash", "-lc", "echo hi"],
            cwd=Path("/tmp"),
            runner=fake,
        )
        # controls-07 #15 — -x 200 -y 50 pins the pane geometry.
        assert fake.calls[0][0] == [
            "tmux",
            "new-session",
            "-d",
            "-s",
            "autopilot-feat",
            "-x", "200",
            "-y", "50",
            "--",
            "bash",
            "-lc",
            "echo hi",
        ]

    def test_s2_metachars_pass_through_uninterpreted(self) -> None:
        payload = "echo $HOME | tee /tmp/x; rm -rf .git"
        fake = FakeRunner(script=[_cp(returncode=0)])
        start_session(
            "autopilot-feat",
            ["bash", "-lc", payload],
            cwd=Path("/tmp"),
            runner=fake,
        )
        assert fake.calls[0][0][-1] == payload

    def test_s3_runner_protocol_has_no_shell_param(self) -> None:
        sig = inspect.signature(Runner.run)
        assert "shell" not in sig.parameters

    def test_s4_default_runner_uses_shell_false(self, monkeypatch: pytest.MonkeyPatch) -> None:
        captured: dict[str, Any] = {}

        def spy(argv: Any, **kwargs: Any) -> CompletedProcess[str]:
            captured["argv"] = argv
            captured["kwargs"] = kwargs
            return CompletedProcess(args=argv, returncode=0, stdout="", stderr="")

        monkeypatch.setattr(tmux_session.subprocess, "run", spy)
        # Use the module-level runner via the default path.
        start_session("autopilot-x", ["bash", "-c", "echo"], cwd=None)
        assert captured["kwargs"].get("shell") is False
        assert captured["kwargs"].get("capture_output") is True
        assert captured["kwargs"].get("text") is True

    def test_s5_cwd_passes_through(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        start_session("autopilot-x", ["bash"], cwd=Path("/tmp/work"), runner=fake)
        assert fake.calls[0][1] == Path("/tmp/work")

    def test_s6_cwd_none_permitted(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        start_session("autopilot-x", ["bash"], cwd=None, runner=fake)
        assert fake.calls[0][1] is None

    def test_s7_pane_size_is_200x50_to_avoid_80col_wrap(self) -> None:
        """controls-07 #15 — tmux defaults detached panes to 80×24 when
        -x/-y are omitted. Chain orchestrator output then hard-wraps at
        column 80 and the wrapped lines + cursor-positioning ANSI
        sequences confuse the xterm.js WS viewer (which renders at the
        operator's actual ~200-col viewport width). Forcing 200×50 on
        every new-session aligns the spawn-time pane geometry with the
        downstream display and eliminates the wrap-then-rewrap mess.

        Empirically observed today: chain output displayed with
        random mid-screen indents because each 80-col tmux wrap was
        interpreted by xterm as a fresh line at the wrong column."""
        fake = FakeRunner(script=[_cp(returncode=0)])
        start_session("chain-x", ["bash"], cwd=None, runner=fake)
        argv = fake.calls[0][0]
        # Locate the -x / -y flags; values must be the documented
        # defaults so the contract change is mechanically detectable.
        assert "-x" in argv, f"missing -x flag in argv: {argv}"
        assert "-y" in argv, f"missing -y flag in argv: {argv}"
        x_value = argv[argv.index("-x") + 1]
        y_value = argv[argv.index("-y") + 1]
        assert x_value == "200", f"expected -x 200; got -x {x_value}"
        assert y_value == "50", f"expected -y 50; got -y {y_value}"

    def test_s7_invalid_name_rejected_before_subprocess(self) -> None:
        fake = FakeRunner()
        with pytest.raises(ValueError):
            start_session("bad name!", ["bash"], cwd=None, runner=fake)
        assert fake.calls == []

    def test_s8_empty_launch_argv_rejected(self) -> None:
        fake = FakeRunner()
        with pytest.raises(ValueError, match="launch_argv must be non-empty"):
            start_session("autopilot-x", [], cwd=None, runner=fake)
        assert fake.calls == []

    def test_s9_success_logs_info(self, caplog: pytest.LogCaptureFixture) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        with caplog.at_level(logging.INFO, logger=LOGGER_NAME):
            start_session("autopilot-feat", ["bash", "-c", "x"], cwd=None, runner=fake)
        info_messages = [
            r.getMessage()
            for r in caplog.records
            if r.name == LOGGER_NAME and r.levelname == "INFO"
        ]
        assert any("autopilot-feat" in m for m in info_messages)

    def test_s10_duplicate_session_raises_session_exists_error(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr="duplicate session: autopilot-feat")])
        with pytest.raises(SessionExistsError) as exc:
            start_session("autopilot-feat", ["bash"], cwd=None, runner=fake)
        err = exc.value
        assert err.returncode == 1
        assert "duplicate session" in err.stderr
        assert err.argv[:2] == ["tmux", "new-session"]

    def test_s11_session_exists_error_is_tmux_error_subclass(self) -> None:
        assert issubclass(SessionExistsError, TmuxError)

    def test_s12_other_failure_raises_tmux_error(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=2, stderr="permission denied")])
        with pytest.raises(TmuxError) as exc:
            start_session("autopilot-x", ["bash"], cwd=None, runner=fake)
        assert not isinstance(exc.value, SessionExistsError)
        assert exc.value.returncode == 2

    def test_s13_file_not_found_wrapped_in_tmux_error(self) -> None:
        runner = FileNotFoundRunner()
        with pytest.raises(TmuxError) as exc:
            start_session("autopilot-x", ["bash"], cwd=None, runner=runner)
        assert isinstance(exc.value.__cause__, FileNotFoundError)

    @pytest.mark.parametrize(
        "stderr_text",
        ["Duplicate Session: x", "DUPLICATE SESSION: x", "duplicate session: x"],
    )
    def test_s14_duplicate_match_case_insensitive(self, stderr_text: str) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr=stderr_text)])
        with pytest.raises(SessionExistsError):
            start_session("autopilot-x", ["bash"], cwd=None, runner=fake)

    def test_s15_single_segment_name_rejected(self) -> None:
        fake = FakeRunner()
        with pytest.raises(ValueError):
            start_session("singlename", ["bash"], cwd=None, runner=fake)
        assert fake.calls == []

    def test_s16_argv_elements_are_all_str(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        start_session("autopilot-x", ["bash", "-c", "echo"], cwd=Path("/tmp"), runner=fake)
        assert all(isinstance(a, str) for a in fake.calls[0][0])


# ---------------------------------------------------------------------------
# TestKillSession (K1-K11)
# ---------------------------------------------------------------------------


class TestKillSession:
    def test_k1_success_returns_ok(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        assert kill_session("autopilot-x", runner=fake) == {"status": "ok"}

    def test_k2_argv(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        kill_session("autopilot-x", runner=fake)
        assert fake.calls[0][0] == ["tmux", "kill-session", "-t", "autopilot-x"]

    def test_k3_cant_find_session_returns_not_found(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr="can't find session: autopilot-gone")])
        assert kill_session("autopilot-gone", runner=fake) == {"status": "not_found"}

    @pytest.mark.parametrize(
        "stderr_text",
        ["can't find session: x", "session not found: x"],
    )
    def test_k4_not_found_wording_alternatives(self, stderr_text: str) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr=stderr_text)])
        assert kill_session("autopilot-x", runner=fake) == {"status": "not_found"}

    @pytest.mark.parametrize(
        "stderr_text",
        ["Can't Find Session: x", "SESSION NOT FOUND: x"],
    )
    def test_k5_not_found_case_insensitive(self, stderr_text: str) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr=stderr_text)])
        assert kill_session("autopilot-x", runner=fake) == {"status": "not_found"}

    def test_k6_not_found_emits_no_warning_or_higher(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr="can't find session: x")])
        with caplog.at_level(logging.DEBUG, logger=LOGGER_NAME):
            kill_session("autopilot-x", runner=fake)
        assert _warnings(caplog) == []

    def test_k7_not_found_emits_single_debug(self, caplog: pytest.LogCaptureFixture) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr="can't find session: x")])
        with caplog.at_level(logging.DEBUG, logger=LOGGER_NAME):
            kill_session("autopilot-x", runner=fake)
        debug_records = [
            r for r in caplog.records if r.name == LOGGER_NAME and r.levelname == "DEBUG"
        ]
        assert any(
            "already gone" in r.getMessage() or "not_found" in r.getMessage() for r in debug_records
        )

    def test_k8_empty_stderr_nonzero_raises_tmux_error(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr="")])
        with pytest.raises(TmuxError):
            kill_session("autopilot-x", runner=fake)

    def test_k9_other_failure_attributes(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=2, stderr="permission denied")])
        with pytest.raises(TmuxError) as exc:
            kill_session("autopilot-x", runner=fake)
        assert exc.value.returncode == 2
        assert "permission denied" in exc.value.stderr
        assert exc.value.argv[:2] == ["tmux", "kill-session"]

    def test_k10_bad_name_rejected(self) -> None:
        fake = FakeRunner()
        with pytest.raises(ValueError):
            kill_session("bad name!", runner=fake)
        assert fake.calls == []

    def test_k11_file_not_found_wrapped(self) -> None:
        with pytest.raises(TmuxError):
            kill_session("autopilot-x", runner=FileNotFoundRunner())

    @pytest.mark.parametrize(
        "stderr_text",
        [
            # Linux / older tmux phrasing
            "no server running on /tmp/tmux-501/default",
            # macOS phrasing (controls-06 #10 caught this for list-sessions)
            "error connecting to /private/tmp/tmux-501/default (No such file or directory)",
        ],
    )
    def test_k12_no_server_running_returns_not_found(self, stderr_text: str) -> None:
        """controls-07 #1 — kill_session must treat 'no server running' as
        idempotent ENOENT. When the chain script exits and takes the tmux
        server with it, the stale-running Restart sequence calls cancel()
        first; without this branch the operator gets a 500 tmux_error and
        Restart Chain never advances to the start() leg. session_exists()
        (line 231) and list_sessions() (line 214) already honour
        _NO_SERVER_RE; kill_session is the outlier.
        """
        fake = FakeRunner(script=[_cp(returncode=1, stderr=stderr_text)])
        assert kill_session("chain-x", runner=fake) == {"status": "not_found"}


# ---------------------------------------------------------------------------
# TestListSessions (L1-L15)
# ---------------------------------------------------------------------------


class TestListSessions:
    def test_l1_filter_single_prefix(self) -> None:
        fake = FakeRunner(
            script=[
                _cp(
                    returncode=0,
                    stdout="autopilot-feat-a\nchain-plan-x\ngrinder-noise\n",
                )
            ]
        )
        assert list_sessions("autopilot-", runner=fake) == ["autopilot-feat-a"]

    def test_l2_argv(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0, stdout="")])
        list_sessions("autopilot-", runner=fake)
        assert fake.calls[0][0] == [
            "tmux",
            "list-sessions",
            "-F",
            "#{session_name}",
        ]

    def test_l3_multi_prefix(self) -> None:
        fake = FakeRunner(
            script=[
                _cp(
                    returncode=0,
                    stdout="autopilot-feat-a\nchain-plan-x\ngrinder-noise\n",
                )
            ]
        )
        assert list_sessions(["autopilot-", "chain-"], runner=fake) == [
            "autopilot-feat-a",
            "chain-plan-x",
        ]

    def test_l4_tuple_prefix(self) -> None:
        fake = FakeRunner(
            script=[
                _cp(
                    returncode=0,
                    stdout="autopilot-feat-a\nchain-plan-x\n",
                )
            ]
        )
        assert list_sessions(("autopilot-",), runner=fake) == ["autopilot-feat-a"]

    def test_l5_empty_stdout_returns_empty(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0, stdout="")])
        assert list_sessions("autopilot-", runner=fake) == []

    def test_l6_trailing_newline_drops_empty(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0, stdout="autopilot-a\nautopilot-b\n")])
        assert list_sessions("autopilot-", runner=fake) == [
            "autopilot-a",
            "autopilot-b",
        ]

    def test_l7_strict_startswith(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0, stdout="not-autopilot-x\n")])
        assert list_sessions("autopilot-", runner=fake) == []

    def test_l8_no_server_returns_empty(self) -> None:
        fake = FakeRunner(
            script=[
                _cp(
                    returncode=1,
                    stderr="no server running on /tmp/tmux-501/default",
                )
            ]
        )
        assert list_sessions("autopilot-", runner=fake) == []

    @pytest.mark.parametrize(
        "stderr_text",
        ["No Server Running", "NO SERVER RUNNING on x"],
    )
    def test_l9_no_server_case_insensitive(self, stderr_text: str) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr=stderr_text)])
        assert list_sessions("autopilot-", runner=fake) == []

    @pytest.mark.parametrize(
        "stderr_text",
        [
            # controls-06 #9: macOS tmux (and many Linux builds) reports
            # the missing-socket case with this verbatim phrasing —
            # different from the "no server running" wording the cycle-5
            # regex was tuned for. Both mean "no tmux server is running
            # right now", which the cap-check must treat as zero active
            # sessions instead of a 500.
            "error connecting to /private/tmp/tmux-501/default (No such file or directory)",
            "error connecting to /tmp/tmux-0/default (No such file or directory)",
            "Error connecting to /tmp/tmux-501/default",
        ],
    )
    def test_l9b_no_server_socket_missing_returns_empty(
        self, stderr_text: str
    ) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr=stderr_text)])
        assert list_sessions("autopilot-", runner=fake) == []

    def test_l10_other_failure_raises_tmux_error(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr="permission denied")])
        with pytest.raises(TmuxError):
            list_sessions("autopilot-", runner=fake)

    def test_l11_empty_prefix_str_rejected(self) -> None:
        fake = FakeRunner()
        with pytest.raises(ValueError, match="prefix_filter must be non-empty"):
            list_sessions("", runner=fake)
        assert fake.calls == []

    def test_l12_empty_sequence_rejected(self) -> None:
        fake = FakeRunner()
        with pytest.raises(ValueError):
            list_sessions([], runner=fake)
        assert fake.calls == []

    def test_l13_unicode_session_name_passes_through(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0, stdout="autopilot-α\n")])
        assert list_sessions("autopilot-", runner=fake) == ["autopilot-α"]

    def test_l14_empty_element_in_sequence_rejected(self) -> None:
        fake = FakeRunner()
        with pytest.raises(ValueError):
            list_sessions(["autopilot-", ""], runner=fake)
        assert fake.calls == []

    def test_l15_file_not_found_wrapped(self) -> None:
        with pytest.raises(TmuxError):
            list_sessions("autopilot-", runner=FileNotFoundRunner())


# ---------------------------------------------------------------------------
# TestSessionExists (E1-E6)
# ---------------------------------------------------------------------------


class TestSessionExists:
    def test_e1_exists_returns_true(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        assert session_exists("autopilot-x", runner=fake) is True

    def test_e2_argv(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=0)])
        session_exists("autopilot-x", runner=fake)
        assert fake.calls[0][0] == ["tmux", "has-session", "-t", "autopilot-x"]

    def test_e3_not_found_returns_false(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr="can't find session: autopilot-x")])
        assert session_exists("autopilot-x", runner=fake) is False

    def test_e4_no_server_returns_false(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=1, stderr="no server running")])
        assert session_exists("autopilot-x", runner=fake) is False

    def test_e5_other_failure_raises_tmux_error(self) -> None:
        fake = FakeRunner(script=[_cp(returncode=2, stderr="permission denied")])
        with pytest.raises(TmuxError):
            session_exists("autopilot-x", runner=fake)

    def test_e6_bad_name_rejected(self) -> None:
        fake = FakeRunner()
        with pytest.raises(ValueError):
            session_exists("bad name!", runner=fake)
        assert fake.calls == []


# ---------------------------------------------------------------------------
# TestModuleShape (M1-M14)
# ---------------------------------------------------------------------------


_FORBIDDEN_IMPORTS = {"fastapi", "starlette", "pydantic", "uvicorn"}
_ALLOWED_IMPORTS = {
    "__future__",
    "logging",
    "re",
    "subprocess",
    "collections.abc",
    "pathlib",
    "typing",
    "dashboard.server.validation",
}


def _module_imports(mod_source: str) -> set[str]:
    tree = ast.parse(mod_source)
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.add(node.module)
    return names


class TestModuleShape:
    def test_m1_import_does_not_invoke_subprocess(self, monkeypatch: pytest.MonkeyPatch) -> None:
        # Mandatory module-cache eviction — without del sys.modules, the
        # re-import is a no-op and the test silently passes.
        sys.modules.pop("dashboard.server.tmux_session", None)

        def spy(*args: Any, **kwargs: Any) -> Any:
            pytest.fail("subprocess.run called during import")

        monkeypatch.setattr(subprocess, "run", spy)
        importlib.import_module("dashboard.server.tmux_session")

    def test_m2_path_empty_subprocess_import(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                "import dashboard.server.tmux_session",
            ],
            env={"PATH": "", "PYTHONPATH": str(REPO_ROOT)},
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"stderr={result.stderr!r}"
        assert result.stderr == ""
        assert result.stdout == ""

    def test_m3_no_forbidden_imports(self) -> None:
        source = inspect.getsource(tmux_session)
        names = _module_imports(source)
        for name in names:
            for forbidden in _FORBIDDEN_IMPORTS:
                assert not name.startswith(forbidden), (
                    f"tmux_session imports forbidden package: {name}"
                )

    def test_m4_imports_match_allowlist(self) -> None:
        source = inspect.getsource(tmux_session)
        names = _module_imports(source)
        assert names == _ALLOWED_IMPORTS, (
            f"unexpected imports: {names - _ALLOWED_IMPORTS}; "
            f"missing imports: {_ALLOWED_IMPORTS - names}"
        )

    def test_m5_runner_protocol_signature(self) -> None:
        sig = inspect.signature(Runner.run)
        params = sig.parameters
        assert "argv" in params
        assert "cwd" in params
        assert params["cwd"].kind == inspect.Parameter.KEYWORD_ONLY
        assert "shell" not in params

    def test_m6_runner_argv_annotation_is_sequence(self) -> None:
        ann = Runner.run.__annotations__["argv"]
        # Sequence[str] or typing.Sequence[str] — both render as Sequence[str].
        assert "Sequence" in repr(ann), f"got annotation {ann!r}"

    @pytest.mark.parametrize(
        "fn",
        [start_session, kill_session, list_sessions, session_exists],
    )
    def test_m7_runner_is_keyword_only(self, fn: Any) -> None:
        sig = inspect.signature(fn)
        assert "runner" in sig.parameters
        assert sig.parameters["runner"].kind == inspect.Parameter.KEYWORD_ONLY

    def test_m8_default_runner_exists_and_runs(self) -> None:
        assert hasattr(tmux_session, "_DEFAULT_RUNNER")
        assert callable(tmux_session._DEFAULT_RUNNER.run)

    def test_m9_exception_hierarchy(self) -> None:
        assert issubclass(TmuxError, RuntimeError)
        assert issubclass(SessionExistsError, TmuxError)

    def test_m10_tmux_error_str(self) -> None:
        err = TmuxError(
            argv=["tmux", "kill-session", "-t", "x"],
            returncode=2,
            stderr="oops",
        )
        assert str(err) == "tmux kill-session failed (exit 2): oops"

    def test_m11_kill_result_typed_dict(self) -> None:
        from typing import get_type_hints

        hints = get_type_hints(KillResult)
        assert "status" in hints
        assert "Literal" in repr(hints["status"])
        assert "'ok'" in repr(hints["status"])
        assert "'not_found'" in repr(hints["status"])

    def test_m12_allowed_target_kinds(self) -> None:
        assert tmux_session._ALLOWED_TARGET_KINDS == frozenset({"autopilot", "chain"})

    def test_m13_full_isolation_probe(self) -> None:
        # Optional deep-isolation probe — skipped unless explicitly enabled.
        import os

        if not os.environ.get("TMUX_HELPER_FULL_ISOLATION"):
            pytest.skip("TMUX_HELPER_FULL_ISOLATION not set; M2 is the AC-5 gate")
        # Run with stripped env; the venv pytest binary may or may not be
        # reachable, so consider failure to launch as 'skip', not 'fail'.
        result = subprocess.run(
            ["env", "-i", "PATH=", sys.executable, "-c", "import dashboard.server.tmux_session"],
            capture_output=True,
            text=True,
            env={"PYTHONPATH": str(REPO_ROOT)},
        )
        assert result.returncode == 0, f"stderr={result.stderr!r}"

    def test_m14_only_one_dashboard_server_import(self) -> None:
        source = inspect.getsource(tmux_session)
        names = _module_imports(source)
        dashboard_imports = {n for n in names if n.startswith("dashboard.server")}
        assert dashboard_imports == {"dashboard.server.validation"}
