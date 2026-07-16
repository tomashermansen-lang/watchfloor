"""Tests for dashboard/server/control.py — four control endpoints.

Coverage: TS-1..TS-9 from
docs/INPROGRESS_Feature_control-endpoints/TESTPLAN.md. Each test cites
the requirement(s) (R-rows) and scenario (TS-rows) it pins.

Strategy:
- ``FakeRunner`` stubs ``tmux_session.Runner`` so no real ``tmux`` is needed.
- ``feature_dir`` / ``chain_dir`` fixtures create a fixture root under
  ``tmp_path`` and monkeypatch ``control._MAIN_DIR`` to point at it.
- ``stub_runner`` patches ``control._TEST_RUNNER`` AND
  ``tmux_session._DEFAULT_RUNNER`` so every helper call resolves to the
  same fake (Gotcha #5).
- CSRF / Origin middleware are exercised through the real
  ``TestClient(app)`` with a primed cookie+header pair.
"""

from __future__ import annotations

import importlib
import json
import os
import subprocess
import sys
from collections.abc import Callable, Iterator, Sequence
from pathlib import Path
from subprocess import CompletedProcess
from typing import Any

import pytest
from fastapi.testclient import TestClient

REPO_ROOT = Path(__file__).resolve().parents[2]
DASHBOARD_ROOT = Path(__file__).resolve().parents[1]
for path in (str(REPO_ROOT), str(DASHBOARD_ROOT)):
    if path not in sys.path:
        sys.path.insert(0, path)

from dashboard.server import control, tmux_session  # noqa: E402
from dashboard.server.app import app  # noqa: E402

# Override via `DASHBOARD_TEST_ORIGIN` if the dashboard's allowed-origins
# allowlist changes (production port lives in CLAUDE.md port registry).
ALLOWED_ORIGIN = os.environ.get("DASHBOARD_TEST_ORIGIN", "http://127.0.0.1:8787")


# ---------------------------------------------------------------------------
# FakeRunner — captures argv/cwd, drives helper paths via scripted returns
# ---------------------------------------------------------------------------


class FakeRunner:
    """Stub `tmux_session.Runner`. Pop a `CompletedProcess` per `.run` call.

    `script` can be a list of `CompletedProcess` (popped FIFO) or a
    callable (argv, cwd) -> `CompletedProcess`.
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
        self.env_snapshots: list[dict[str, str]] = []

    def run(self, argv: Sequence[str], *, cwd: Path | None) -> CompletedProcess[str]:
        argv_list = list(argv)
        self.calls.append((argv_list, cwd))
        if callable(self.script):
            return self.script(argv_list, cwd)
        if not self.script:
            return CompletedProcess(argv_list, 0, stdout="", stderr="")
        return self.script.pop(0)  # type: ignore[no-any-return]


def _ok() -> CompletedProcess[str]:
    return CompletedProcess(["tmux"], 0, stdout="", stderr="")


def _list_sessions_result(names: list[str]) -> CompletedProcess[str]:
    return CompletedProcess(
        ["tmux", "list-sessions"],
        0,
        stdout="\n".join(names) + ("\n" if names else ""),
        stderr="",
    )


def _has_session_result(exists: bool) -> CompletedProcess[str]:
    return (
        CompletedProcess(["tmux", "has-session"], 0, stdout="", stderr="")
        if exists
        else CompletedProcess(["tmux", "has-session"], 1, stdout="", stderr="can't find session")
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def fixture_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Build a dotfiles-shaped fixture root and patch `control._MAIN_DIR`."""
    (tmp_path / ".git").mkdir()
    (tmp_path / "pyproject.toml").touch()
    tools = tmp_path / "adapters" / "claude-code" / "claude" / "tools"
    tools.mkdir(parents=True)
    autopilot = tools / "autopilot.sh"
    autopilot.touch()
    autopilot_chain = tools / "autopilot-chain.sh"
    autopilot_chain.touch()
    monkeypatch.setattr(control, "_MAIN_DIR", tmp_path)
    monkeypatch.setattr(control, "_AUTOPILOT_SH_PATH", autopilot)
    monkeypatch.setattr(control, "_AUTOPILOT_CHAIN_SH_PATH", autopilot_chain)
    return tmp_path


@pytest.fixture
def feature_dir(fixture_root: Path) -> Path:
    feat = fixture_root / "docs" / "INPROGRESS_Feature_demo"
    feat.mkdir(parents=True)
    (feat / "REQUIREMENTS.md").write_text("# stub\n", encoding="utf-8")
    return feat


@pytest.fixture
def chain_dir(fixture_root: Path) -> Path:
    chain = fixture_root / "docs" / "INPROGRESS_Plan_demo"
    chain.mkdir(parents=True)
    (chain / "execution-plan.yaml").write_text("schema_version: 2.0.0\n", encoding="utf-8")
    return chain


@pytest.fixture
def stub_runner(monkeypatch: pytest.MonkeyPatch) -> Iterator[FakeRunner]:
    fake = FakeRunner()
    monkeypatch.setattr(control, "_TEST_RUNNER", fake)
    monkeypatch.setattr(tmux_session, "_DEFAULT_RUNNER", fake)
    yield fake
    monkeypatch.setattr(control, "_TEST_RUNNER", None)


@pytest.fixture
def fixed_now(monkeypatch: pytest.MonkeyPatch) -> str:
    ts = "2026-05-14T12:00:00+00:00"
    monkeypatch.setattr(control, "_now_iso", lambda: ts)
    return ts


@pytest.fixture
def csrf_client() -> TestClient:
    client = TestClient(app)
    client.headers.update({"Origin": ALLOWED_ORIGIN})
    response = client.get("/health")
    assert response.status_code == 200
    token = client.cookies["csrf_token"]
    client.headers["X-CSRF-Token"] = token
    return client


# Convenience POST wrapper that always sends CSRF + Origin via the prepared
# client and posts JSON.


def _post(client: TestClient, path: str, body: dict[str, Any]) -> Any:
    return client.post(path, json=body)


# ---------------------------------------------------------------------------
# TS-1  Module shape & import-time invariants
# ---------------------------------------------------------------------------


def test_ts_1_1_router_exposes_four_post_routes() -> None:
    """TS-1.1 (R1): control.router has 4 POST routes; paths match the spec."""
    paths = {
        (getattr(r, "path", ""), tuple(sorted(getattr(r, "methods", set()))))
        for r in control.router.routes
    }
    expected = {
        ("/api/{target_kind}/start", ("POST",)),
        ("/api/{target_kind}/pause", ("POST",)),
        ("/api/{target_kind}/cancel", ("POST",)),
        ("/api/{target_kind}/resume", ("POST",)),
    }
    assert expected.issubset(paths)


def test_ts_1_2_module_main_dir_resolved() -> None:
    """TS-1.2 (R40 success-mode): _MAIN_DIR points to the main repo with both anchors."""
    assert (control._MAIN_DIR / "pyproject.toml").is_file()


def test_ts_1_3_resolve_bash_script_missing_autopilot_raises(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TS-1.3 (R37, EC-M2): missing autopilot.sh -> RuntimeError at resolve."""
    (tmp_path / ".git").mkdir()
    (tmp_path / "pyproject.toml").touch()
    # No `adapters/...` tree at all — autopilot.sh is missing.
    monkeypatch.setattr(control, "_MAIN_DIR", tmp_path)
    with pytest.raises(RuntimeError, match="autopilot.sh"):
        control._resolve_bash_script("autopilot.sh")


def test_ts_1_4_resolve_bash_script_missing_chain_raises(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TS-1.4 (R37, EC-M2): missing autopilot-chain.sh -> RuntimeError at resolve."""
    (tmp_path / ".git").mkdir()
    (tmp_path / "pyproject.toml").touch()
    # Create a tools dir holding ONLY autopilot.sh so the chain script is missing.
    tools = tmp_path / "adapters" / "claude-code" / "claude" / "tools"
    tools.mkdir(parents=True)
    (tools / "autopilot.sh").touch()
    monkeypatch.setattr(control, "_MAIN_DIR", tmp_path)
    with pytest.raises(RuntimeError, match="autopilot-chain.sh"):
        control._resolve_bash_script("autopilot-chain.sh")


def test_ts_1_11_defaults_when_env_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    """TS-1.11 (R38, R39): defaults are 3 and 30 when env unset."""
    monkeypatch.delenv("MAX_CONCURRENT_AUTOPILOTS", raising=False)
    monkeypatch.delenv("CONTROL_RETRY_AFTER_SECONDS", raising=False)
    reloaded = importlib.reload(control)
    assert reloaded.MAX_CONCURRENT_AUTOPILOTS == 3
    assert reloaded.CONTROL_RETRY_AFTER_SECONDS == 30


@pytest.mark.parametrize("bad", ["0", "-1", "abc", "100", ""])
def test_ts_1_6_8_9_max_concurrent_invalid_raises(
    monkeypatch: pytest.MonkeyPatch, bad: str
) -> None:
    """TS-1.6..TS-1.9 (R38): invalid MAX_CONCURRENT_AUTOPILOTS raises RuntimeError at import."""
    monkeypatch.setenv("MAX_CONCURRENT_AUTOPILOTS", bad)
    with pytest.raises(RuntimeError):
        importlib.reload(control)
    # Restore valid env for subsequent tests.
    monkeypatch.delenv("MAX_CONCURRENT_AUTOPILOTS", raising=False)
    importlib.reload(control)


@pytest.mark.parametrize("bad", ["0", "-5", "3601", "x", ""])
def test_ts_1_10_retry_after_invalid_raises(monkeypatch: pytest.MonkeyPatch, bad: str) -> None:
    """TS-1.10 (R39): invalid CONTROL_RETRY_AFTER_SECONDS raises RuntimeError."""
    monkeypatch.setenv("CONTROL_RETRY_AFTER_SECONDS", bad)
    with pytest.raises(RuntimeError):
        importlib.reload(control)
    monkeypatch.delenv("CONTROL_RETRY_AFTER_SECONDS", raising=False)
    importlib.reload(control)


@pytest.mark.parametrize(
    "name,value",
    [
        ("MAX_CONCURRENT_AUTOPILOTS", "1"),
        ("MAX_CONCURRENT_AUTOPILOTS", "32"),
        ("CONTROL_RETRY_AFTER_SECONDS", "1"),
        ("CONTROL_RETRY_AFTER_SECONDS", "3600"),
    ],
)
def test_ts_1_10b_boundaries_accepted(
    monkeypatch: pytest.MonkeyPatch, name: str, value: str
) -> None:
    """TS-1.10b (R38, R39): boundary values accepted at import."""
    monkeypatch.setenv(name, value)
    reloaded = importlib.reload(control)
    assert getattr(reloaded, name) == int(value)
    monkeypatch.delenv(name, raising=False)
    importlib.reload(control)


def test_ts_1_12_all_export() -> None:
    """TS-1.12 (R1): __all__ exposes only `router`."""
    assert control.__all__ == ["router"]


# ---------------------------------------------------------------------------
# TS-2  Routing & request validation
# ---------------------------------------------------------------------------


def test_ts_2_1_router_registration_order() -> None:
    """TS-2.1 (R1, R-EXT-2): control routes precede the /api/{rest:path} 404 catch-all."""
    paths = [getattr(r, "path", "") for r in app.routes]
    start_idx = paths.index("/api/{target_kind}/start")
    catchall_idx = next(i for i, p in enumerate(paths) if p == "/api/{rest:path}")
    assert start_idx < catchall_idx


def test_ts_2_2_uppercase_target_kind_rejected(csrf_client: TestClient, fixture_root: Path) -> None:
    """TS-2.2 (R2): mixed-case target_kind rejected with 400."""
    response = _post(csrf_client, "/api/Autopilot/start", {"target_id": "demo"})
    assert response.status_code == 400


def test_ts_2_3_unknown_target_kind_rejected(csrf_client: TestClient) -> None:
    """TS-2.3 (R2): unknown target_kind rejected with 400."""
    response = _post(csrf_client, "/api/grinder/start", {"target_id": "demo"})
    assert response.status_code == 400


def test_ts_2_4_extra_field_rejected(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-2.4 (R3): unknown body field rejected (extra=forbid)."""
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo", "evil": 1})
    assert response.status_code == 400
    assert stub_runner.calls == []


def test_ts_2_5_missing_target_id_rejected(csrf_client: TestClient) -> None:
    """TS-2.5 (R3): body missing target_id rejected."""
    assert _post(csrf_client, "/api/autopilot/pause", {}).status_code == 400


@pytest.mark.parametrize("length,expected", [(1, 200), (64, 200), (65, 400)])
def test_ts_2_6_7_target_id_length(
    csrf_client: TestClient,
    fixture_root: Path,
    stub_runner: FakeRunner,
    length: int,
    expected: int,
) -> None:
    """TS-2.6/2.7 (EC-S4, EC-X3): length 1 and 64 accepted; 65 rejected."""
    target_id = "a" * length
    # Pre-create the feature dir so existence check passes for the 200 cases.
    feat = fixture_root / "docs" / f"INPROGRESS_Feature_{target_id}"
    feat.mkdir(parents=True, exist_ok=True)
    (feat / "REQUIREMENTS.md").touch()
    # Pause has no tmux mechanics; use it to test the regex layer.
    response = _post(csrf_client, "/api/autopilot/pause", {"target_id": target_id})
    assert response.status_code == expected


def test_ts_2_8_full_charclass_accepted(csrf_client: TestClient, fixture_root: Path) -> None:
    """TS-2.8 (EC-X4): full permitted char class accepted at length 64."""
    target_id = ("aA0_-" * 13)[:64]
    feat = fixture_root / "docs" / f"INPROGRESS_Feature_{target_id}"
    feat.mkdir(parents=True, exist_ok=True)
    (feat / "REQUIREMENTS.md").touch()
    response = _post(csrf_client, "/api/autopilot/pause", {"target_id": target_id})
    assert response.status_code == 200


@pytest.mark.parametrize(
    "bad_id",
    ["a;rm -rf /", "$(whoami)", "`whoami`", "../../etc/passwd", "a b"],
)
def test_ts_2_9_12_shell_metacharacters_rejected(
    csrf_client: TestClient, stub_runner: FakeRunner, bad_id: str
) -> None:
    """TS-2.9..TS-2.12 (R3, EC-S5): shell metacharacters rejected with 400."""
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": bad_id})
    assert response.status_code == 400
    assert stub_runner.calls == []


def test_ts_2_13_pipeline_outside_literal_rejected(
    csrf_client: TestClient, feature_dir: Path
) -> None:
    """TS-2.13 (EC-S3): pipeline=`hybrid` rejected (not in Literal)."""
    response = _post(
        csrf_client,
        "/api/autopilot/start",
        {"target_id": "demo", "pipeline": "hybrid"},
    )
    assert response.status_code == 400


def test_ts_2_14_pipeline_omitted_defaults_full(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-2.14 (R13 default): omitted pipeline defaults to `full` in argv."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),  # tmux new-session
    ]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 200
    new_session = stub_runner.calls[-1][0]
    assert "--pipeline" in new_session
    assert new_session[new_session.index("--pipeline") + 1] == "full"


def test_ts_2_15_target_only_pipeline_rejected(csrf_client: TestClient, feature_dir: Path) -> None:
    """TS-2.15 (R3): _TargetOnlyRequest rejects `pipeline` field on pause."""
    response = _post(
        csrf_client,
        "/api/autopilot/pause",
        {"target_id": "demo", "pipeline": "full"},
    )
    assert response.status_code == 400


def test_ts_2_16_success_body_is_byte_equivalent_json(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-2.16 (R4): 200 body bytes equal json.dumps(payload).encode()."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    payload = {
        "status": "started",
        "tmux_session": "autopilot-demo",
        "target_id": "demo",
    }
    assert response.content == json.dumps(payload).encode("utf-8")


def test_ts_2_17_4xx_error_body_is_json_not_html(
    csrf_client: TestClient, fixture_root: Path, stub_runner: FakeRunner
) -> None:
    """TS-2.17 (R4, RSK-8): structured 4xx is JSON, not HTML."""
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "missing"})
    assert response.status_code == 422
    assert response.content == json.dumps(
        {
            "error": "target_not_found",
            "hint": "feature has no REQUIREMENTS.md yet — run the BA phase to generate it",
        }
    ).encode("utf-8")
    assert not response.content.startswith(b"<")


# ---------------------------------------------------------------------------
# TS-3  Runner injection seam
# ---------------------------------------------------------------------------


def test_ts_3_1_get_runner_returns_test_runner_when_set(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-3.1 (R6): _get_runner returns the test runner when set."""
    fake = FakeRunner()
    monkeypatch.setattr(control, "_TEST_RUNNER", fake)
    assert control._get_runner() is fake


def test_ts_3_2_get_runner_returns_none_when_unset() -> None:
    """TS-3.2 (R6): _get_runner returns None when _TEST_RUNNER is None."""
    assert control._get_runner() is None


def test_ts_3_4_control_runner_propagates_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """TS-3.4 (R-EXT-1, R15): _ControlRunner injects env into subprocess.run."""
    captured: dict[str, Any] = {}

    def fake_run(argv: list[str], **kwargs: Any) -> CompletedProcess[str]:
        captured["argv"] = argv
        captured["env"] = kwargs.get("env")
        captured["kwargs"] = kwargs
        return CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", fake_run)
    runner = control._ControlRunner({"CONTROL_SOURCE": "dashboard", "PATH": "/usr/bin"})
    result = runner.run(["true"], cwd=None)
    assert result.returncode == 0
    assert captured["env"] == {"CONTROL_SOURCE": "dashboard", "PATH": "/usr/bin"}
    assert captured["kwargs"]["shell"] is False
    assert captured["kwargs"]["capture_output"] is True
    assert captured["kwargs"]["text"] is True
    assert captured["kwargs"]["check"] is False


def test_ts_3_6_control_runner_env_snapshot_independent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-3.6 (R-EXT-1): _ControlRunner snapshot is decoupled from os.environ mutations."""
    captured: dict[str, Any] = {}

    def fake_run(argv: list[str], **kwargs: Any) -> CompletedProcess[str]:
        captured["env"] = dict(kwargs.get("env") or {})
        return CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", fake_run)
    seed = {"A": "1"}
    runner = control._ControlRunner(seed)
    seed["A"] = "2"  # mutate after construction; must not leak
    runner.run(["true"], cwd=None)
    assert captured["env"] == {"A": "1"}


# ---------------------------------------------------------------------------
# TS-4  start
# ---------------------------------------------------------------------------


def test_ts_4_1_autopilot_missing_dir_422(
    csrf_client: TestClient, fixture_root: Path, stub_runner: FakeRunner
) -> None:
    """TS-4.1 (R7): missing INPROGRESS_Feature_<id>/REQUIREMENTS.md -> 422; no subprocess."""
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 422
    assert json.loads(response.content)["error"] == "target_not_found"
    assert stub_runner.calls == []


def test_ts_4_2_chain_missing_yaml_422(
    csrf_client: TestClient, fixture_root: Path, stub_runner: FakeRunner
) -> None:
    """TS-4.2 (R7): chain target missing execution-plan.yaml -> 422."""
    response = _post(csrf_client, "/api/chain/start", {"target_id": "demo"})
    assert response.status_code == 422
    assert json.loads(response.content)["error"] == "target_not_found"


def test_ts_4_3_concurrency_cap_429_with_retry_after(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
) -> None:
    """TS-4.3 / AC-4 (R8): 3 active sessions, cap=3 -> 429 + Retry-After:30."""
    stub_runner.script = [_list_sessions_result(["autopilot-a", "chain-b", "autopilot-c"])]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 429
    assert response.headers["retry-after"] == "30"
    assert json.loads(response.content) == {
        "error": "concurrent_cap_reached",
        "cap": 3,
        "active": 3,
    }
    # No new-session subprocess call.
    new_sess = [c for c in stub_runner.calls if "new-session" in c[0]]
    assert new_sess == []


def test_ts_4_4_cap_boundary_proceeds(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
) -> None:
    """TS-4.4 (R8): active=2, cap=3 -> proceeds to start."""
    stub_runner.script = [
        _list_sessions_result(["autopilot-a", "chain-b"]),
        _has_session_result(False),
        _ok(),
    ]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 200


def test_ts_4_5_retry_after_env_override(
    monkeypatch: pytest.MonkeyPatch, feature_dir: Path
) -> None:
    """TS-4.5 (R39): CONTROL_RETRY_AFTER_SECONDS=60 -> Retry-After:60."""
    monkeypatch.setenv("CONTROL_RETRY_AFTER_SECONDS", "60")
    reloaded = importlib.reload(control)
    # After reload, the fixture-set _MAIN_DIR is reset; re-apply it.
    monkeypatch.setattr(reloaded, "_MAIN_DIR", feature_dir.parents[1])
    monkeypatch.setattr(
        reloaded,
        "_AUTOPILOT_SH_PATH",
        feature_dir.parents[1] / "adapters" / "claude-code" / "claude" / "tools" / "autopilot.sh",
    )
    monkeypatch.setattr(
        reloaded,
        "_AUTOPILOT_CHAIN_SH_PATH",
        feature_dir.parents[1]
        / "adapters"
        / "claude-code"
        / "claude"
        / "tools"
        / "autopilot-chain.sh",
    )
    fake = FakeRunner(script=[_list_sessions_result(["autopilot-a", "chain-b", "autopilot-c"])])
    monkeypatch.setattr(reloaded, "_TEST_RUNNER", fake)
    monkeypatch.setattr(tmux_session, "_DEFAULT_RUNNER", fake)
    # Use a fresh TestClient against the freshly-reloaded module.
    client = TestClient(app)
    client.headers.update({"Origin": ALLOWED_ORIGIN})
    assert client.get("/health").status_code == 200
    client.headers["X-CSRF-Token"] = client.cookies["csrf_token"]
    # The router instance is now stale on `app` (still pointing at the old
    # control.router). Re-include the new module's router.
    app.include_router(reloaded.router)
    response = client.post("/api/autopilot/start", json={"target_id": "demo"})
    # Reset for downstream tests.
    monkeypatch.delenv("CONTROL_RETRY_AFTER_SECONDS", raising=False)
    importlib.reload(control)
    assert response.status_code == 429
    assert response.headers["retry-after"] == "60"


def test_ts_4_6_deterministic_name_valueerror_400(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-4.6 (R9): deterministic_name ValueError -> 400."""
    stub_runner.script = [_list_sessions_result([])]

    def bad_name(*_: Any, **__: Any) -> str:
        raise ValueError("bad target_kind")

    monkeypatch.setattr(tmux_session, "deterministic_name", bad_name)
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 400
    assert "bad target_kind" in json.loads(response.content).get("detail", "")


def test_ts_4_7_session_exists_pre_409(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-4.7 (R10): session_exists True before invoking start -> 409 already_running."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(True),
    ]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 409
    assert json.loads(response.content) == {
        "error": "already_running",
        "session": "autopilot-demo",
    }
    # No new-session argv.
    assert all("new-session" not in c[0] for c in stub_runner.calls)


def test_ts_4_8_started_event_before_runner_call(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    fixed_now: str,
) -> None:
    """TS-4.8 / TS-4.9 / AC-1 (R11): `started` event appended BEFORE start_session."""
    stream_path = feature_dir / "autopilot-stream.ndjson"
    observed: dict[str, bool] = {"stream_before_runner": False}

    def scripted_run(argv: list[str], cwd: Path | None) -> CompletedProcess[str]:
        # When tmux new-session is invoked, the stream file must already
        # contain the `started` event.
        if "new-session" in argv:
            observed["stream_before_runner"] = stream_path.is_file() and (
                "started" in stream_path.read_text(encoding="utf-8")
            )
            return _ok()
        if "list-sessions" in argv:
            return _list_sessions_result([])
        if "has-session" in argv:
            return _has_session_result(False)
        return _ok()

    fake = FakeRunner(script=scripted_run)
    monkeypatch.setattr(control, "_TEST_RUNNER", fake)
    monkeypatch.setattr(tmux_session, "_DEFAULT_RUNNER", fake)
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 200, response.text
    assert observed["stream_before_runner"]
    line = stream_path.read_text(encoding="utf-8").strip()
    event = json.loads(line)
    assert event == {
        "ts": fixed_now,
        "type": "lifecycle",
        "action": "started",
        "source": "dashboard",
        "target": "demo",
        "tmux_session": "autopilot-demo",
    }


def test_ts_4_10_start_lifecycle_oserror_does_not_block(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-4.10 (R11 fail-soft): lifecycle append OSError MUST NOT block the start."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]

    def boom(*_: Any, **__: Any) -> None:
        raise OSError("read-only fs")

    monkeypatch.setattr(control, "append_event", boom)
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    # Start still proceeds despite the lifecycle write failing.
    assert response.status_code == 200, response.text
    assert json.loads(response.content)["status"] == "started"


def test_ts_4_11_autopilot_launch_argv(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
) -> None:
    """TS-4.11 / AC-1 (R12, R13): autopilot launch argv shape + cwd=_MAIN_DIR."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    assert _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"}).status_code == 200
    argv, cwd = stub_runner.calls[-1]
    # tmux helper prepends `tmux new-session -d -s <name> --`; our launch_argv
    # starts at position 6 (`bash` ...).
    assert argv[:10] == ["tmux", "new-session", "-d", "-s", "autopilot-demo", "-x", "200", "-y", "50", "--"]
    assert argv[10:] == [
        "bash",
        str(control._AUTOPILOT_SH_PATH),
        "--full",
        "--pipeline",
        "full",
        "demo",
    ]
    assert cwd == control._MAIN_DIR


def test_ts_4_12_pipeline_light_in_argv(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-4.12 (R13): pipeline=light reaches the argv."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    _post(csrf_client, "/api/autopilot/start", {"target_id": "demo", "pipeline": "light"})
    assert "light" in stub_runner.calls[-1][0]


def test_ts_4_13_chain_launch_argv(
    csrf_client: TestClient, chain_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-4.13 (R14): chain launch argv = bash autopilot-chain.sh run <plan_dir_abs>."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    assert _post(csrf_client, "/api/chain/start", {"target_id": "demo"}).status_code == 200
    argv, cwd = stub_runner.calls[-1]
    expected_tail = [
        "bash",
        str(control._AUTOPILOT_CHAIN_SH_PATH),
        "run",
        str(chain_dir.resolve()),
    ]
    assert argv[10:] == expected_tail
    assert cwd == control._MAIN_DIR


def test_ts_4_14_route_level_env_contains_control_source(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-4.14 (R15): route-level env carries CONTROL_SOURCE=dashboard and is
    the explicit allowlist — NOT os.environ.copy(). Production path: with
    _TEST_RUNNER=None, _resolve_start_runner constructs _ControlRunner(env);
    we monkeypatch that class with a spy that records the env."""
    captured: dict[str, Any] = {}

    class SpyControlRunner:
        def __init__(self, env: Any) -> None:
            captured["env"] = dict(env)

        def run(self, argv: Sequence[str], *, cwd: Path | None) -> CompletedProcess[str]:
            captured["argv"] = list(argv)
            return CompletedProcess(list(argv), 0, stdout="", stderr="")

    # `_TEST_RUNNER` is None by default — _resolve_start_runner falls through
    # to `_ControlRunner(env)`. Drive `tmux_session._DEFAULT_RUNNER` (used by
    # list_sessions + session_exists) with a separate FakeRunner so the
    # gating helpers don't touch _ControlRunner.
    gating_fake = FakeRunner(
        script=[
            _list_sessions_result([]),
            _has_session_result(False),
        ]
    )
    monkeypatch.setattr(control, "_TEST_RUNNER", None)
    monkeypatch.setattr(tmux_session, "_DEFAULT_RUNNER", gating_fake)
    monkeypatch.setattr(control, "_ControlRunner", SpyControlRunner)
    # Inject a sentinel credential that MUST NOT propagate (not in the
    # allowlist) to prove the env is built from the allowlist, not
    # os.environ.copy().
    monkeypatch.setenv("GH_TOKEN", "sentinel-leak-guard")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "sentinel-leak-guard")

    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 200, response.text
    # CONTROL_SOURCE present + tagged dashboard.
    assert captured["env"].get("CONTROL_SOURCE") == "dashboard"
    # Allowlist hygiene: credentials NOT forwarded (R15).
    assert "GH_TOKEN" not in captured["env"]
    assert "AWS_ACCESS_KEY_ID" not in captured["env"]
    # Keys must be a subset of the documented allowlist + CONTROL_SOURCE.
    allowed = set(control._SUBPROCESS_ENV_ALLOWLIST) | {"CONTROL_SOURCE"}
    assert set(captured["env"].keys()).issubset(allowed)


def test_ts_4_15_session_exists_error_409(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
) -> None:
    """TS-4.15 (R16, EC-S1): SessionExistsError race -> 409."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        CompletedProcess(
            ["tmux", "new-session"],
            1,
            stdout="",
            stderr="duplicate session: autopilot-demo",
        ),
    ]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 409
    assert json.loads(response.content)["error"] == "already_running"


def test_ts_4_16_tmux_error_500_with_warning(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """TS-4.16 (R17): generic TmuxError -> 500 with warning log."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        CompletedProcess(["tmux", "new-session"], 1, stdout="", stderr="boom"),
    ]
    caplog.set_level("WARNING", logger="dashboard.server.control")
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 500
    body = json.loads(response.content)
    assert body["error"] == "tmux_error"
    assert body["stderr"] == "boom"
    assert body["message"] == "failed to start tmux session"
    assert any("tmux_error" in rec.getMessage() for rec in caplog.records)


def test_ts_4_17_stderr_truncated_to_512(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
) -> None:
    """TS-4.17 (R17): stderr truncated to 512 chars."""
    big = "X" * 600
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        CompletedProcess(["tmux", "new-session"], 1, stdout="", stderr=big),
    ]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 500
    assert len(json.loads(response.content)["stderr"]) == 512


def test_ts_4_18_success_body_byte_equivalent(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-4.18 / AC-1 (R18): success body is exactly the documented shape."""
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.content == json.dumps(
        {"status": "started", "tmux_session": "autopilot-demo", "target_id": "demo"}
    ).encode("utf-8")


# ---------------------------------------------------------------------------
# TS-5  pause
# ---------------------------------------------------------------------------


def test_ts_5_1_missing_feature_dir_422(csrf_client: TestClient, fixture_root: Path) -> None:
    """TS-5.1 (R20): missing feature dir -> 422; no file written."""
    response = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    assert response.status_code == 422


def test_ts_5_2_missing_plan_dir_422(csrf_client: TestClient, fixture_root: Path) -> None:
    """TS-5.2 (R20): missing plan dir -> 422."""
    response = _post(csrf_client, "/api/chain/pause", {"target_id": "demo"})
    assert response.status_code == 422


def test_ts_5_3_pause_path_autopilot() -> None:
    """TS-5.3 (R19): autopilot pause path is autopilot.PAUSE under feature dir."""
    p = control._resolve_pause_path("autopilot", "demo")
    assert p.name == "autopilot.PAUSE"
    assert "INPROGRESS_Feature_demo" in str(p)


def test_ts_5_4_pause_path_chain() -> None:
    """TS-5.4 (R19): chain pause path is chain.PAUSE under plan dir."""
    p = control._resolve_pause_path("chain", "demo")
    assert p.name == "chain.PAUSE"
    assert "INPROGRESS_Plan_demo" in str(p)


def test_ts_5_5_first_pause_creates_empty_file(csrf_client: TestClient, feature_dir: Path) -> None:
    """TS-5.5 (R21): first POST creates the pause file; content is empty."""
    response = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    assert response.status_code == 200
    pause_file = feature_dir / "autopilot.PAUSE"
    assert pause_file.is_file()
    assert pause_file.read_text(encoding="utf-8") == ""


def test_ts_5_6_idempotent_pause(csrf_client: TestClient, feature_dir: Path) -> None:
    """TS-5.6 / AC-2 (R21): second POST is 200; both responses byte-equal."""
    first = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    second = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    assert first.status_code == 200
    assert second.status_code == 200
    # Second response carries already_pausing=True; first does not.
    assert json.loads(first.content).get("already_pausing") is None
    assert json.loads(second.content).get("already_pausing") is True


def test_ts_5_7_pause_write_oserror_500(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-5.7 (R24, EC-P2): OSError on open -> 500 pause_write_failed; no lifecycle event."""
    real_open = open

    def fake_open(path: Any, *args: Any, **kwargs: Any) -> Any:
        if str(path).endswith("autopilot.PAUSE"):
            err = PermissionError("read-only fs")
            err.errno = 13
            raise err
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr("builtins.open", fake_open)
    response = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    assert response.status_code == 500
    body = json.loads(response.content)
    assert body["error"] == "pause_write_failed"
    assert body["errno"] == 13
    stream_path = feature_dir / "autopilot-stream.ndjson"
    assert not stream_path.exists() or stream_path.read_text(encoding="utf-8") == ""


def test_ts_5_8_paused_event_with_phase(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    fixed_now: str,
) -> None:
    """TS-5.8 (R22): paused event includes phase_at_pause when derive_status returns one."""
    monkeypatch.setattr(
        control,
        "derive_status",
        lambda *_: {
            "status": "running",
            "phase_at_pause": None,
            "last_phase_complete": "review",
            "started_at": None,
            "tmux_session": None,
        },
    )
    _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    line = (feature_dir / "autopilot-stream.ndjson").read_text(encoding="utf-8").strip()
    event = json.loads(line)
    assert event["action"] == "paused"
    assert event["source"] == "dashboard"
    assert event["target"] == "demo"
    assert event["phase_at_pause"] == "review"
    assert event["ts"] == fixed_now


def test_ts_5_9_paused_event_omits_phase_when_none(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-5.9 (R22): phase_at_pause omitted when derive_status returns None."""
    monkeypatch.setattr(
        control,
        "derive_status",
        lambda *_: {
            "status": "running",
            "phase_at_pause": None,
            "last_phase_complete": None,
            "started_at": None,
            "tmux_session": None,
        },
    )
    _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    event = json.loads(
        (feature_dir / "autopilot-stream.ndjson").read_text(encoding="utf-8").strip()
    )
    assert "phase_at_pause" not in event


def test_ts_5_10_derive_status_raises_phase_omitted(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-5.10 (EC-P4): derive_status raising -> phase omitted; pause still 200."""

    def boom(*_: Any) -> dict[str, Any]:
        raise RuntimeError("boom")

    monkeypatch.setattr(control, "derive_status", boom)
    response = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    assert response.status_code == 200
    event = json.loads(
        (feature_dir / "autopilot-stream.ndjson").read_text(encoding="utf-8").strip()
    )
    assert "phase_at_pause" not in event


def test_ts_5_11_pause_success_body(csrf_client: TestClient, feature_dir: Path) -> None:
    """TS-5.11 (R23): pause body is byte-equivalent."""
    response = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    pause_path = feature_dir / "autopilot.PAUSE"
    expected = {
        "status": "pausing",
        "pause_file": str(pause_path),
        "target_id": "demo",
    }
    assert response.content == json.dumps(expected).encode("utf-8")


def test_ts_5_13_two_paused_events(csrf_client: TestClient, feature_dir: Path) -> None:
    """TS-5.13 (EC-X5): two pauses -> two paused events in stream."""
    _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    lines = (
        (feature_dir / "autopilot-stream.ndjson").read_text(encoding="utf-8").strip().splitlines()
    )
    paused = [json.loads(line) for line in lines if json.loads(line)["action"] == "paused"]
    assert len(paused) == 2


def test_ts_5_14_pause_lifecycle_oserror_does_not_block(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-5.14 (R22 best-effort): lifecycle append OSError MUST NOT block pause;
    PAUSE file is still written and 200 is returned."""

    def boom(*_: Any, **__: Any) -> None:
        raise OSError("read-only fs")

    monkeypatch.setattr(control, "append_event", boom)
    response = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    assert response.status_code == 200, response.text
    assert (feature_dir / "autopilot.PAUSE").is_file()


# ---------------------------------------------------------------------------
# TS-6  cancel
# ---------------------------------------------------------------------------


def test_ts_6_1_cancel_ok(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-6.1 (R25): kill_session ok -> 200 cancelled."""
    stub_runner.script = [_ok()]
    response = _post(csrf_client, "/api/autopilot/cancel", {"target_id": "demo"})
    assert response.status_code == 200
    assert json.loads(response.content) == {
        "status": "cancelled",
        "tmux_session": "autopilot-demo",
        "target_id": "demo",
    }


def test_ts_6_2_cancel_not_found_already_cancelled(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-6.2 / AC-3 (R25): not_found -> 200 already_cancelled."""
    stub_runner.script = [
        CompletedProcess(
            ["tmux", "kill-session"], 1, stdout="", stderr="can't find session: autopilot-gone"
        )
    ]
    response = _post(csrf_client, "/api/autopilot/cancel", {"target_id": "gone"})
    assert response.status_code == 200
    assert json.loads(response.content)["status"] == "already_cancelled"


def test_ts_6_3_cancelled_event_on_ok(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-6.3 (R26): cancelled lifecycle event appended on ok path."""
    stub_runner.script = [_ok()]
    _post(csrf_client, "/api/autopilot/cancel", {"target_id": "demo"})
    line = (feature_dir / "autopilot-stream.ndjson").read_text(encoding="utf-8").strip()
    event = json.loads(line)
    assert event["action"] == "cancelled"
    assert event["source"] == "dashboard"
    assert event["target"] == "demo"


def test_ts_6_4_cancelled_event_on_not_found(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-6.4 / EC-C2 (R26): cancelled event appended on not_found path."""
    stub_runner.script = [
        CompletedProcess(["tmux", "kill-session"], 1, stdout="", stderr="can't find session")
    ]
    _post(csrf_client, "/api/autopilot/cancel", {"target_id": "demo"})
    event = json.loads(
        (feature_dir / "autopilot-stream.ndjson").read_text(encoding="utf-8").strip()
    )
    assert event["action"] == "cancelled"


def test_ts_6_5_cancel_tmux_error_500_no_event(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
) -> None:
    """TS-6.5 (R27): TmuxError -> 500; NO cancelled event in stream."""
    stub_runner.script = [
        CompletedProcess(["tmux", "kill-session"], 2, stdout="", stderr="daemon dead")
    ]
    response = _post(csrf_client, "/api/autopilot/cancel", {"target_id": "demo"})
    assert response.status_code == 500
    body = json.loads(response.content)
    assert body["error"] == "tmux_error"
    assert body["stderr"] == "daemon dead"
    stream = feature_dir / "autopilot-stream.ndjson"
    assert not stream.exists() or stream.read_text(encoding="utf-8") == ""


def test_ts_6_6_cancel_no_existence_check(
    csrf_client: TestClient, fixture_root: Path, stub_runner: FakeRunner
) -> None:
    """TS-6.6 / R25.b: cancel works without INPROGRESS_* dir (kill is idempotent)."""
    stub_runner.script = [
        CompletedProcess(["tmux", "kill-session"], 1, stdout="", stderr="can't find session")
    ]
    response = _post(csrf_client, "/api/autopilot/cancel", {"target_id": "ghost"})
    assert response.status_code == 200


def test_ts_6_7_two_sequential_cancels(
    csrf_client: TestClient, feature_dir: Path, stub_runner: FakeRunner
) -> None:
    """TS-6.7 / EC-X5: two cancels -> first ok, second already_cancelled."""
    stub_runner.script = [
        _ok(),
        CompletedProcess(["tmux", "kill-session"], 1, stdout="", stderr="can't find session"),
    ]
    r1 = _post(csrf_client, "/api/autopilot/cancel", {"target_id": "demo"})
    r2 = _post(csrf_client, "/api/autopilot/cancel", {"target_id": "demo"})
    assert json.loads(r1.content)["status"] == "cancelled"
    assert json.loads(r2.content)["status"] == "already_cancelled"


# ---------------------------------------------------------------------------
# TS-7  resume
# ---------------------------------------------------------------------------


def _patched_status(monkeypatch: pytest.MonkeyPatch, state: dict[str, Any]) -> None:
    monkeypatch.setattr(control, "derive_status", lambda *_: state)


def _patched_next_phase(monkeypatch: pytest.MonkeyPatch, retval: Any) -> None:
    def fake(*_: Any, **__: Any) -> Any:
        if isinstance(retval, BaseException):
            raise retval
        return retval

    monkeypatch.setattr(control, "detect_next_phase", fake)


def test_ts_7_1_resume_missing_dir_422(csrf_client: TestClient, fixture_root: Path) -> None:
    """TS-7.1: missing target dir -> 422."""
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 422


def test_ts_7_2_resume_cancelled_409(
    csrf_client: TestClient, feature_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TS-7.2 / AC-5 (R28): derive_status cancelled -> 409 cannot_resume_cancelled."""
    _patched_status(monkeypatch, {"status": "cancelled"})
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 409
    assert json.loads(response.content)["error"] == "cannot_resume_cancelled"


def test_ts_7_3_resume_completed_409(
    csrf_client: TestClient, feature_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TS-7.3 (R28): derive_status completed -> 409 cannot_resume_completed."""
    _patched_status(monkeypatch, {"status": "completed"})
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 409
    assert json.loads(response.content)["error"] == "cannot_resume_completed"


def test_ts_7_4_resume_running_409(
    csrf_client: TestClient, feature_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TS-7.4 (R29): derive_status running -> 409 cannot_resume_running."""
    _patched_status(monkeypatch, {"status": "running"})
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 409
    assert json.loads(response.content)["error"] == "cannot_resume_running"


def test_ts_7_5_resume_paused_proceeds(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.5 (R28): paused status proceeds to next-phase derivation."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "qa")
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 200


def test_ts_7_8_resume_next_phase_none_409(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.8 / AC-5 (R30): detect_next_phase None -> 409 cannot_resume_completed."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, None)
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 409
    assert json.loads(response.content)["error"] == "cannot_resume_completed"


def test_ts_7_9_stream_unavailable_422(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.9 / AC-5 (R31): StreamUnavailableError -> 422 stream_unavailable."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, control.StreamUnavailableError("stream missing"))
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 422
    body = json.loads(response.content)
    assert body == {
        "error": "stream_unavailable",
        "hint": "fall back to terminal --from <phase>",
    }


def test_ts_7_10_resume_cap_429(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.10 (R36): resume subject to concurrency cap."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "qa")
    stub_runner.script = [_list_sessions_result(["autopilot-a", "chain-b", "autopilot-c"])]
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 429


def test_ts_7_12_resume_session_exists_409(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.12 (R32): session_exists True at resume -> 409."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "qa")
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(True),
    ]
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 409


def test_ts_7_13_autopilot_resume_argv(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.13 (R33): autopilot resume argv = bash autopilot.sh --full --pipeline full --from qa <id>."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "qa")
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    argv = stub_runner.calls[-1][0]
    assert argv[10:] == [
        "bash",
        str(control._AUTOPILOT_SH_PATH),
        "--full",
        "--pipeline",
        "full",
        "--from",
        "qa",
        "demo",
    ]


def test_ts_7_14_chain_resume_argv(
    csrf_client: TestClient,
    chain_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.14 (R33): chain resume argv = bash autopilot-chain.sh run <plan_dir_abs>."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "ignored-by-chain")
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    _post(csrf_client, "/api/chain/resume", {"target_id": "demo"})
    argv = stub_runner.calls[-1][0]
    assert argv[10:] == [
        "bash",
        str(control._AUTOPILOT_CHAIN_SH_PATH),
        "run",
        str(chain_dir.resolve()),
    ]


def test_ts_7_15_chain_pause_removed_after_start(
    csrf_client: TestClient,
    chain_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.15 (R33 second clause): chain.PAUSE removed AFTER start_session."""
    pause = chain_dir / "chain.PAUSE"
    pause.touch()
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "ignored")
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    response = _post(csrf_client, "/api/chain/resume", {"target_id": "demo"})
    assert response.status_code == 200
    assert not pause.exists()


def test_ts_7_16_chain_resume_no_pause_file(
    csrf_client: TestClient,
    chain_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.16 (R33, EC-R4): chain.PAUSE absent -> no exception."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "ignored")
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    response = _post(csrf_client, "/api/chain/resume", {"target_id": "demo"})
    assert response.status_code == 200


def test_ts_7_17_autopilot_resume_does_not_clean_pause(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.17 (OQ-4): autopilot resume does NOT pre-clean autopilot.PAUSE."""
    pause = feature_dir / "autopilot.PAUSE"
    pause.touch()
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "qa")
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        _ok(),
    ]
    _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert pause.exists()


def test_ts_7_18_resumed_event_after_start(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.18 (R34): resumed event appended AFTER start_session returns."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "qa")
    stream_path = feature_dir / "autopilot-stream.ndjson"
    seen: dict[str, bool] = {"resumed_before_start": False}

    def scripted(argv: list[str], cwd: Path | None) -> CompletedProcess[str]:
        if "list-sessions" in argv:
            return _list_sessions_result([])
        if "has-session" in argv:
            return _has_session_result(False)
        if "new-session" in argv:
            seen["resumed_before_start"] = stream_path.exists() and (
                "resumed" in stream_path.read_text(encoding="utf-8")
            )
            return _ok()
        return _ok()

    fake = FakeRunner(script=scripted)
    monkeypatch.setattr(control, "_TEST_RUNNER", fake)
    monkeypatch.setattr(tmux_session, "_DEFAULT_RUNNER", fake)
    _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert seen["resumed_before_start"] is False  # resumed event NOT present pre-start
    line = stream_path.read_text(encoding="utf-8").strip().splitlines()[-1]
    assert json.loads(line)["action"] == "resumed"


def test_ts_7_19_failed_start_no_resumed_event(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.19 (R34): start_session failure -> no resumed event."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "qa")
    stub_runner.script = [
        _list_sessions_result([]),
        _has_session_result(False),
        CompletedProcess(["tmux", "new-session"], 1, stdout="", stderr="boom"),
    ]
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 500
    stream = feature_dir / "autopilot-stream.ndjson"
    text = stream.read_text(encoding="utf-8") if stream.exists() else ""
    assert "resumed" not in text


def test_ts_7_20_autopilot_resume_body(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.20 (R35): autopilot resume success body shape."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "qa")
    stub_runner.script = [_list_sessions_result([]), _has_session_result(False), _ok()]
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.content == json.dumps(
        {
            "status": "resumed",
            "tmux_session": "autopilot-demo",
            "target_id": "demo",
            "from_phase": "qa",
        }
    ).encode("utf-8")


def test_ts_7_21_chain_resume_from_phase_chain(
    csrf_client: TestClient,
    chain_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.21 (R35): chain resume from_phase=`chain` sentinel."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, "ignored")
    stub_runner.script = [_list_sessions_result([]), _has_session_result(False), _ok()]
    response = _post(csrf_client, "/api/chain/resume", {"target_id": "demo"})
    body = json.loads(response.content)
    assert body["from_phase"] == "chain"


def test_ts_7_22_resume_first_phase(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """TS-7.22 / EC-R2: detect_next_phase returns first phase -> --from ba."""
    _patched_status(monkeypatch, {"status": "idle"})
    _patched_next_phase(monkeypatch, "ba")
    stub_runner.script = [_list_sessions_result([]), _has_session_result(False), _ok()]
    _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    argv = stub_runner.calls[-1][0]
    assert "--from" in argv
    assert argv[argv.index("--from") + 1] == "ba"


# ---------------------------------------------------------------------------
# TS-8  Cross-cutting & middleware coverage
# ---------------------------------------------------------------------------


def test_ts_8_1_no_csrf_token_403(fixture_root: Path, stub_runner: FakeRunner) -> None:
    """TS-8.1 (R-TEST-1): POST without X-CSRF-Token -> 403; handler not invoked."""
    client = TestClient(app)
    client.headers["Origin"] = ALLOWED_ORIGIN
    response = client.post("/api/autopilot/pause", json={"target_id": "demo"})
    assert response.status_code == 403
    assert json.loads(response.content) == {"error": "csrf"}
    assert stub_runner.calls == []


def test_ts_8_3_no_origin_403(stub_runner: FakeRunner) -> None:
    """TS-8.3 (EC-X2): POST without Origin -> 403."""
    client = TestClient(app)
    response = client.post("/api/autopilot/pause", json={"target_id": "demo"})
    assert response.status_code == 403


def test_ts_8_4_bad_origin_403(stub_runner: FakeRunner) -> None:
    """TS-8.4: POST with disallowed Origin -> 403."""
    client = TestClient(app)
    client.headers["Origin"] = "https://evil.example"
    response = client.post("/api/autopilot/pause", json={"target_id": "demo"})
    assert response.status_code == 403


def test_ts_8_8_logger_name() -> None:
    """TS-8.8 (EC-X7): module logger name is 'dashboard.server.control'."""
    assert control.logger.name == "dashboard.server.control"


# ---------------------------------------------------------------------------
# TS-9  Host-plan acceptance scenarios (AC-1..AC-5)
# ---------------------------------------------------------------------------


def test_ts_9_1_ac1_start_argv_and_event(
    csrf_client: TestClient,
    feature_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    fixed_now: str,
) -> None:
    """TS-9.1 (AC-1): argv shape + session-naming event + CONTROL_SOURCE env."""
    stream_path = feature_dir / "autopilot-stream.ndjson"
    captured: dict[str, Any] = {}

    def scripted(argv: list[str], cwd: Path | None) -> CompletedProcess[str]:
        if "list-sessions" in argv:
            return _list_sessions_result([])
        if "has-session" in argv:
            return _has_session_result(False)
        if "new-session" in argv:
            captured["new_argv"] = argv
            captured["new_cwd"] = cwd
            captured["stream_before"] = (
                stream_path.is_file() and "started" in stream_path.read_text(encoding="utf-8")
            )
            return _ok()
        return _ok()

    fake = FakeRunner(script=scripted)
    monkeypatch.setattr(control, "_TEST_RUNNER", fake)
    monkeypatch.setattr(tmux_session, "_DEFAULT_RUNNER", fake)

    # Spy on _resolve_start_runner so we can assert the env it sees carries
    # CONTROL_SOURCE=dashboard (AC-1's third clause — REQUIREMENTS.md R15).
    real_resolve_start_runner = control._resolve_start_runner

    def spy_resolve_start_runner(env: Any) -> Any:
        captured["resolved_env"] = dict(env)
        return real_resolve_start_runner(env)

    monkeypatch.setattr(control, "_resolve_start_runner", spy_resolve_start_runner)

    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo", "pipeline": "full"})
    assert response.status_code == 200
    # (a) `started` event appended BEFORE runner.
    assert captured["stream_before"]
    # (b) argv shape — tmux helper prepends `tmux new-session -d -s <name> -x 200 -y 50 --`.
    # controls-07 #15 — -x 200 -y 50 pins pane geometry.
    assert captured["new_argv"][:10] == [
        "tmux",
        "new-session",
        "-d",
        "-s",
        "autopilot-demo",
        "-x", "200",
        "-y", "50",
        "--",
    ]
    assert captured["new_argv"][10:] == [
        "bash",
        str(control._AUTOPILOT_SH_PATH),
        "--full",
        "--pipeline",
        "full",
        "demo",
    ]
    # (c) CONTROL_SOURCE env reached the runner-resolution path.
    assert captured["resolved_env"].get("CONTROL_SOURCE") == "dashboard"
    # (d) Success body.
    assert response.content == json.dumps(
        {"status": "started", "tmux_session": "autopilot-demo", "target_id": "demo"}
    ).encode("utf-8")


def test_ts_9_2_ac2_idempotent_pause(csrf_client: TestClient, feature_dir: Path) -> None:
    """TS-9.2 (AC-2): two pauses -> 200; PAUSE file exists; 2 paused events."""
    first = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    second = _post(csrf_client, "/api/autopilot/pause", {"target_id": "demo"})
    assert first.status_code == 200 and second.status_code == 200
    assert (feature_dir / "autopilot.PAUSE").is_file()
    lines = (
        (feature_dir / "autopilot-stream.ndjson").read_text(encoding="utf-8").strip().splitlines()
    )
    paused = [json.loads(line) for line in lines if json.loads(line).get("action") == "paused"]
    assert len(paused) == 2
    assert all(p["source"] == "dashboard" for p in paused)


def test_ts_9_3_ac3_idempotent_cancel(
    csrf_client: TestClient, fixture_root: Path, stub_runner: FakeRunner
) -> None:
    """TS-9.3 (AC-3): kill_session not_found stderr -> 200 already_cancelled."""
    stub_runner.script = [
        CompletedProcess(
            ["tmux", "kill-session"], 1, stdout="", stderr="can't find session: autopilot-gone"
        )
    ]
    response = _post(csrf_client, "/api/autopilot/cancel", {"target_id": "gone"})
    assert response.status_code == 200
    body = json.loads(response.content)
    assert body == {
        "status": "already_cancelled",
        "tmux_session": "autopilot-gone",
        "target_id": "gone",
    }


def test_ts_9_4_ac4_cap_with_retry_after(
    csrf_client: TestClient,
    feature_dir: Path,
    stub_runner: FakeRunner,
) -> None:
    """TS-9.4 (AC-4): 3 sessions + cap=3 -> 429 + Retry-After:30; no new-session."""
    stub_runner.script = [_list_sessions_result(["autopilot-a", "chain-b", "autopilot-c"])]
    response = _post(csrf_client, "/api/autopilot/start", {"target_id": "demo"})
    assert response.status_code == 429
    assert response.headers["retry-after"] == "30"
    assert json.loads(response.content) == {
        "error": "concurrent_cap_reached",
        "cap": 3,
        "active": 3,
    }
    assert all("new-session" not in c[0] for c in stub_runner.calls)


def test_ts_9_5_ac5a_resume_rejected_cancelled(
    csrf_client: TestClient, feature_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TS-9.5 (AC-5a): resume on cancelled -> 409."""
    _patched_status(monkeypatch, {"status": "cancelled"})
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 409
    assert json.loads(response.content) == {"error": "cannot_resume_cancelled"}


def test_ts_9_6_ac5b_resume_rejected_completed(
    csrf_client: TestClient, feature_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TS-9.6 (AC-5b): detect_next_phase None -> 409 cannot_resume_completed."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, None)
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 409
    assert json.loads(response.content) == {"error": "cannot_resume_completed"}


def test_ts_9_7_ac5c_resume_stream_unavailable(
    csrf_client: TestClient, feature_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TS-9.7 (AC-5c): StreamUnavailableError -> 422 stream_unavailable."""
    _patched_status(monkeypatch, {"status": "paused"})
    _patched_next_phase(monkeypatch, control.StreamUnavailableError("missing"))
    response = _post(csrf_client, "/api/autopilot/resume", {"target_id": "demo"})
    assert response.status_code == 422
    assert json.loads(response.content) == {
        "error": "stream_unavailable",
        "hint": "fall back to terminal --from <phase>",
    }
