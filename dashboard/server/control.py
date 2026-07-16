"""FastAPI APIRouter for autopilot / chain control endpoints.

Four parameterised write routes — ``POST /api/{target_kind}/{start|pause|resume|cancel}``.
``target_kind`` is a Pydantic Literal of ``{"autopilot", "chain"}``. Each handler
translates one HTTP request into one lifecycle-event append plus one side effect
(tmux start/kill or pause-file write). Tmux mechanics route exclusively through
``dashboard.server.tmux_session``; lifecycle appends through
``lifecycle_events.append_event``; state inspection through
``status_helper.derive_status`` and ``resume_helper.detect_next_phase``.

Module owns no state beyond ``_TEST_RUNNER`` (test-injection seam). Env vars
``MAX_CONCURRENT_AUTOPILOTS`` (default 3, range 1..32) and
``CONTROL_RETRY_AFTER_SECONDS`` (default 30, range 1..3600) are read once at
import; invalid values raise ``RuntimeError``. Bundled bash-script paths
(``autopilot.sh``, ``autopilot-chain.sh``) and ``_MAIN_DIR`` are resolved
deterministically from ``__file__`` and validated; missing anchors raise
``RuntimeError``.

See ``docs/INPROGRESS_Feature_control-endpoints/{REQUIREMENTS,PLAN,TESTPLAN}.md``
for the contract.
"""

from __future__ import annotations

import logging
import os
import subprocess
from collections.abc import Mapping, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

from fastapi import APIRouter
from pydantic import BaseModel, ConfigDict

from dashboard.server import tmux_session
from dashboard.server._responses import StdlibJSONResponse
from dashboard.server.lifecycle_events import append_event
from dashboard.server.resume_helper import StreamUnavailableError, detect_next_phase
from dashboard.server.schemas import FeatureId
from dashboard.server.status_helper import derive_status

logger = logging.getLogger("dashboard.server.control")


# ---------------------------------------------------------------------------
# Module-level constants — resolved at import; fail-loud on bad values
# ---------------------------------------------------------------------------


def _has_anchors(candidate: Path) -> bool:
    return (candidate / ".git").is_dir() and (candidate / "pyproject.toml").is_file()


def _resolve_worktree_main(candidate: Path) -> Path | None:
    # When the dashboard package is loaded from inside a git worktree,
    # `candidate/.git` is a FILE (not a dir) containing
    # `gitdir: <main_repo>/.git/worktrees/<name>`. Resolve through that
    # pointer back to the main repo so the subprocess `cwd=_MAIN_DIR`
    # in `_handle_start` lands in the canonical checkout (RSK-1 cwd
    # mitigation: autopilot.sh runs against the main repo, not the
    # worktree, even if uvicorn was accidentally launched here).
    git_pointer = candidate / ".git"
    if not git_pointer.is_file():
        return None
    try:
        text = git_pointer.read_text(encoding="utf-8")
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("gitdir:"):
            gitdir = Path(line.split(":", 1)[1].strip())
            if gitdir.parent.parent.name == ".git":
                main = gitdir.parent.parent.parent.resolve()
                if _has_anchors(main):
                    return main
            break
    return None


def _resolve_main_dir() -> Path:
    # R40 — resolve from `dashboard/server/control.py` upward. The
    # conventional location is `parents[2]` (repo root); accept that
    # directly when its `.git/` is a directory and `pyproject.toml`
    # exists. When `.git` is a worktree-pointer file, follow it to the
    # main repo via `_resolve_worktree_main` (handles the
    # autopilot-pipeline case where uvicorn or pytest is loaded inside a
    # feature worktree). Falls back to a walk-up search when neither
    # holds, raising RuntimeError if no ancestor has both anchors —
    # RSK-2 fail-loud semantics preserved.
    seed = Path(__file__).resolve().parents[2]
    if _has_anchors(seed):
        return seed
    via_worktree = _resolve_worktree_main(seed)
    if via_worktree is not None:
        return via_worktree
    for ancestor in seed.parents:
        if _has_anchors(ancestor):
            return ancestor
    raise RuntimeError(
        f"control.py: _MAIN_DIR anchors missing — searched from {seed} upward; "
        f"expected a directory containing BOTH `.git/` (as a directory) and "
        f"`pyproject.toml` (as a file)"
    )


def _resolve_bash_script(name: str) -> Path:
    # R37 / EC-M2 — absolute path to a bundled bash tool, validated by is_file().
    path = _MAIN_DIR / "adapters" / "claude-code" / "claude" / "tools" / name
    if not path.is_file():
        raise RuntimeError(f"control.py: {name} missing at {path}")
    return path


def _parse_int_env(name: str, default: str, *, low: int, high: int) -> int:
    # R38 / R39 / EC-M3 — fail-loud env parsing. Empty-string value (set but
    # blank) is treated as invalid, NOT as default.
    raw = os.environ.get(name, default)
    if raw == "":
        raise RuntimeError(f"control.py: {name} env var is empty string")
    try:
        value = int(raw)
    except ValueError as exc:
        raise RuntimeError(f"control.py: {name} env var {raw!r} is not an int") from exc
    if value < low or value > high:
        raise RuntimeError(f"control.py: {name}={value} outside range {low}..{high}")
    return value


_MAIN_DIR: Path = _resolve_main_dir()
_AUTOPILOT_SH_PATH: Path = _resolve_bash_script("autopilot.sh")
_AUTOPILOT_CHAIN_SH_PATH: Path = _resolve_bash_script("autopilot-chain.sh")
MAX_CONCURRENT_AUTOPILOTS: int = _parse_int_env("MAX_CONCURRENT_AUTOPILOTS", "3", low=1, high=32)
CONTROL_RETRY_AFTER_SECONDS: int = _parse_int_env(
    "CONTROL_RETRY_AFTER_SECONDS", "30", low=1, high=3600
)

# Test-injection seam. Production keeps this None (the default tmux_session
# runner applies). Tests assign a FakeRunner instance, asserted by route + helper
# tests via `monkeypatch.setattr(control, "_TEST_RUNNER", fake)`.
_TEST_RUNNER: tmux_session.Runner | None = None

_TARGET_KIND = Literal["autopilot", "chain"]

# Env-var allowlist forwarded to the tmux subprocess (R15). Credentials
# (GH_TOKEN, *_API_KEY, AWS_*) are intentionally NOT forwarded — they have no
# business inside an autopilot tmux session and might leak into stream logs.
_SUBPROCESS_ENV_ALLOWLIST: tuple[str, ...] = (
    "PATH",
    "HOME",
    "USER",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "SHELL",
    "PROJECTS_ROOT",
    "MAX_CONCURRENT_AUTOPILOTS",
    "CONTROL_RETRY_AFTER_SECONDS",
)


# ---------------------------------------------------------------------------
# Pydantic request models (C3)
# ---------------------------------------------------------------------------


class _TargetOnlyRequest(BaseModel):
    """Pause / cancel / chain-resume body — only ``target_id`` is meaningful."""

    model_config = ConfigDict(extra="forbid")
    target_id: FeatureId


class _StartRequest(BaseModel):
    """Start body — adds optional ``pipeline`` Literal."""

    model_config = ConfigDict(extra="forbid")
    target_id: FeatureId
    pipeline: Literal["full", "light"] = "full"


class _AutopilotResumeRequest(BaseModel):
    """Autopilot resume body — same shape as ``_StartRequest`` (kept as a
    distinct named type so future fields specific to one action plug in
    without refactoring; matches PLAN §C3)."""

    model_config = ConfigDict(extra="forbid")
    target_id: FeatureId
    pipeline: Literal["full", "light"] = "full"


class _ChainResumeRequest(BaseModel):
    """Chain resume body — NO ``pipeline`` (chain has no ``--from`` semantic)."""

    model_config = ConfigDict(extra="forbid")
    target_id: FeatureId


# ---------------------------------------------------------------------------
# Helpers (C4)
# ---------------------------------------------------------------------------


def _get_runner() -> tmux_session.Runner | None:
    # R6 — returns the test-injected runner if set, else None so the
    # `tmux_session` helpers substitute their `_DEFAULT_RUNNER`. The `None`
    # return is the documented public contract of `tmux_session.*`.
    return _TEST_RUNNER


def _resolve_target_dir(target_kind: str, target_id: str) -> Path:
    label = "INPROGRESS_Feature_" if target_kind == "autopilot" else "INPROGRESS_Plan_"
    return _MAIN_DIR / "docs" / f"{label}{target_id}"


def _resolve_pause_path(target_kind: str, target_id: str) -> Path:
    name = "autopilot.PAUSE" if target_kind == "autopilot" else "chain.PAUSE"
    return _resolve_target_dir(target_kind, target_id) / name


def _resolve_stream_path(target_kind: str, target_id: str) -> Path:
    name = "autopilot-stream.ndjson" if target_kind == "autopilot" else "chain-events.ndjson"
    return _resolve_target_dir(target_kind, target_id) / name


def _target_exists(target_kind: str, target_id: str) -> bool:
    # R7 — autopilot precondition is `REQUIREMENTS.md`; chain precondition is
    # `execution-plan.yaml`. Both bind the start request to operator-issued
    # `/start` (or `/plan-project`) commands, preventing accidental autopilot
    # launches against a typo.
    target_dir = _resolve_target_dir(target_kind, target_id)
    if target_kind == "autopilot":
        return (target_dir / "REQUIREMENTS.md").is_file()
    return (target_dir / "execution-plan.yaml").is_file()


def _target_not_found_payload(target_kind: str) -> dict[str, str]:
    if target_kind == "autopilot":
        return {
            "error": "target_not_found",
            "hint": "feature has no REQUIREMENTS.md yet — run the BA phase to generate it",
        }
    return {
        "error": "target_not_found",
        "hint": "plan directory has no execution-plan.yaml — run /plan-project to generate it",
    }


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _make_lifecycle_event(
    action: str,
    target_id: str,
    *,
    tmux_session_name: str | None = None,
    phase_at_pause: str | None = None,
) -> dict[str, Any]:
    event: dict[str, Any] = {
        "ts": _now_iso(),
        "type": "lifecycle",
        "action": action,
        "source": "dashboard",
        "target": target_id,
    }
    if tmux_session_name is not None:
        event["tmux_session"] = tmux_session_name
    if phase_at_pause is not None:
        event["phase_at_pause"] = phase_at_pause
    return event


def _safe_last_phase_complete(target_kind: str, target_id: str) -> str | None:
    # R22 / EC-P4 — defensive wrapper. derive_status raising any exception
    # results in omission of the phase_at_pause field from the paused event;
    # the pause file is still written and 200 is returned.
    try:
        state = derive_status(target_kind, target_id)
    except Exception:  # noqa: BLE001 — defensive per EC-P4
        return None
    return state.get("last_phase_complete")


def _check_concurrency_cap() -> tuple[int, list[str]] | None:
    # R8 / R36 — list_sessions accepts a sequence of prefixes (tmux_session R14).
    active = tmux_session.list_sessions(["autopilot-", "chain-"], runner=_get_runner())
    if len(active) >= MAX_CONCURRENT_AUTOPILOTS:
        return len(active), active
    return None


def _build_subprocess_env() -> dict[str, str]:
    # R15 — explicit allowlist; credentials NEVER reach the subprocess.
    env: dict[str, str] = {}
    for key in _SUBPROCESS_ENV_ALLOWLIST:
        value = os.environ.get(key)
        if value is not None:
            env[key] = value
    env["CONTROL_SOURCE"] = "dashboard"
    return env


def _sanitize_stderr(raw: bytes | str | None) -> str:
    # R17 — defense against terminal-control-escape / format-string injection
    # via tmux stderr. Decode (errors='replace'), strip control bytes below
    # 0x20 (preserving \n and \t), then truncate to 512 chars.
    if raw is None:
        return ""
    if isinstance(raw, bytes):
        text = raw.decode("utf-8", errors="replace")
    else:
        text = raw
    cleaned: list[str] = []
    for ch in text:
        code = ord(ch)
        if code < 0x20 and ch not in ("\n", "\t"):
            cleaned.append("?")
        else:
            cleaned.append(ch)
    return "".join(cleaned)[:512]


def _tmux_error_response(exc: tmux_session.TmuxError, message: str) -> StdlibJSONResponse:
    # R17 / R27 — uniform 500 body shape for tmux failures. The `message`
    # field is the operator-facing summary; `stderr` carries the truncated
    # diagnostic. logger.warning captures returncode + first-512 chars.
    stderr = _sanitize_stderr(getattr(exc, "stderr", ""))
    logger.warning(
        "event=control.tmux_error message=%s returncode=%s stderr=%s",
        message,
        getattr(exc, "returncode", "?"),
        stderr,
    )
    return StdlibJSONResponse(
        {"error": "tmux_error", "message": message, "stderr": stderr},
        status_code=500,
    )


# ---------------------------------------------------------------------------
# Subprocess Runner adapter (C5)
# ---------------------------------------------------------------------------


class _ControlRunner:
    """``tmux_session.Runner`` adapter that injects an env mapping per request.

    Required because ``tmux_session.Runner.run(argv, *, cwd)`` has no ``env``
    parameter — the helper keeps its public surface frozen by predecessor
    constraint, so env propagation lives here. The env snapshot is taken at
    construction so a later ``os.environ`` mutation cannot leak into an
    in-flight subprocess.
    """

    def __init__(self, env: Mapping[str, str]) -> None:
        self._env = dict(env)

    def run(self, argv: Sequence[str], *, cwd: Path | None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            list(argv),
            cwd=cwd,
            env=self._env,
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )


def _resolve_start_runner(env: Mapping[str, str]) -> tmux_session.Runner:
    # The start path needs env propagation. In tests, the injected runner
    # takes precedence (tests assert argv shape and skip env inspection on
    # that path). In production, build a fresh _ControlRunner(env) per request.
    if _TEST_RUNNER is not None:
        return _TEST_RUNNER
    return _ControlRunner(env)


# ---------------------------------------------------------------------------
# Action handlers (C6)
# ---------------------------------------------------------------------------


def _emit_lifecycle(stream_path: Path, event: dict[str, Any]) -> None:
    # `append_event` swallows OSError per its public contract; we further
    # guard against the parent directory disappearing between the existence
    # check and the append (EC-S2 fail-soft, R11 / R22 best-effort).
    try:
        stream_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        logger.warning(
            "event=control.lifecycle.mkdir_failed path=%s error=%s",
            stream_path.parent,
            exc,
        )
    try:
        append_event(stream_path, event)
    except OSError as exc:
        logger.warning(
            "event=control.lifecycle.append_failed path=%s error=%s",
            stream_path,
            exc,
        )


def _handle_start(target_kind: _TARGET_KIND, body: _StartRequest) -> StdlibJSONResponse:
    # 1. Existence precondition (R7)
    if not _target_exists(target_kind, body.target_id):
        return StdlibJSONResponse(_target_not_found_payload(target_kind), status_code=422)

    # 2. Concurrency cap (R8)
    cap_check = _check_concurrency_cap()
    if cap_check is not None:
        active_count, _active_names = cap_check
        return StdlibJSONResponse(
            {
                "error": "concurrent_cap_reached",
                "cap": MAX_CONCURRENT_AUTOPILOTS,
                "active": active_count,
            },
            status_code=429,
            headers={"Retry-After": str(CONTROL_RETRY_AFTER_SECONDS)},
        )

    # 3. Resolve deterministic name (R9)
    try:
        name = tmux_session.deterministic_name(target_kind, body.target_id)
    except ValueError as exc:
        return StdlibJSONResponse({"detail": str(exc)}, status_code=400)

    # 4. Pre-check pre-existing session (R10)
    if tmux_session.session_exists(name, runner=_get_runner()):
        return StdlibJSONResponse({"error": "already_running", "session": name}, status_code=409)

    # 5. Append `started` lifecycle event BEFORE start_session (R11)
    stream_path = _resolve_stream_path(target_kind, body.target_id)
    event = _make_lifecycle_event("started", body.target_id, tmux_session_name=name)
    _emit_lifecycle(stream_path, event)

    # 6. Build launch argv (R12, R13, R14)
    if target_kind == "autopilot":
        launch_argv: list[str] = [
            "bash",
            str(_AUTOPILOT_SH_PATH),
            "--full",
            "--pipeline",
            body.pipeline,
            body.target_id,
        ]
    else:
        plan_dir_abs = _resolve_target_dir("chain", body.target_id).resolve()
        launch_argv = [
            "bash",
            str(_AUTOPILOT_CHAIN_SH_PATH),
            "run",
            str(plan_dir_abs),
        ]

    # 7. Build env with CONTROL_SOURCE (R15)
    env = _build_subprocess_env()

    # 8. Invoke start_session (R12, R16, R17)
    try:
        tmux_session.start_session(
            name, launch_argv, cwd=_MAIN_DIR, runner=_resolve_start_runner(env)
        )
    except tmux_session.SessionExistsError:
        return StdlibJSONResponse({"error": "already_running", "session": name}, status_code=409)
    except tmux_session.TmuxError as exc:
        return _tmux_error_response(exc, "failed to start tmux session")

    logger.info("control.start.ok target_id=%s session=%s", body.target_id, name)
    return StdlibJSONResponse(
        {"status": "started", "tmux_session": name, "target_id": body.target_id},
        status_code=200,
    )


def _handle_pause(target_kind: _TARGET_KIND, body: _TargetOnlyRequest) -> StdlibJSONResponse:
    # 1. Target existence precondition (R20)
    target_dir = _resolve_target_dir(target_kind, body.target_id)
    if not target_dir.is_dir():
        return StdlibJSONResponse({"error": "target_not_found"}, status_code=422)

    # 2. Resolve pause-file path (R19)
    pause_path = _resolve_pause_path(target_kind, body.target_id)
    already_pausing = pause_path.exists()

    # 3. Truncate-write the pause file (R21, R24)
    try:
        with open(pause_path, "w", encoding="utf-8"):
            pass  # truncate; no content needed
    except OSError as exc:
        logger.warning(
            "control.pause.write_failed target_id=%s errno=%s",
            body.target_id,
            exc.errno,
        )
        return StdlibJSONResponse(
            {"error": "pause_write_failed", "errno": exc.errno or 0},
            status_code=500,
        )

    # 4. Append `paused` lifecycle event (R22)
    phase_at_pause = _safe_last_phase_complete(target_kind, body.target_id)
    event = _make_lifecycle_event("paused", body.target_id, phase_at_pause=phase_at_pause)
    stream_path = _resolve_stream_path(target_kind, body.target_id)
    _emit_lifecycle(stream_path, event)

    # 5. Success (R23)
    payload: dict[str, Any] = {
        "status": "pausing",
        "pause_file": str(pause_path),
        "target_id": body.target_id,
    }
    if already_pausing:
        payload["already_pausing"] = True
    logger.info("control.pause.ok target_id=%s", body.target_id)
    return StdlibJSONResponse(payload, status_code=200)


def _handle_cancel(target_kind: _TARGET_KIND, body: _TargetOnlyRequest) -> StdlibJSONResponse:
    # 1. Resolve deterministic name (no existence precondition per R25.b)
    try:
        name = tmux_session.deterministic_name(target_kind, body.target_id)
    except ValueError as exc:
        return StdlibJSONResponse({"detail": str(exc)}, status_code=400)

    # 2. Call kill_session (R25)
    try:
        result = tmux_session.kill_session(name, runner=_get_runner())
    except tmux_session.TmuxError as exc:
        return _tmux_error_response(exc, "failed to kill tmux session")

    # 3. Append `cancelled` lifecycle event (R26) — for both ok and not_found
    event = _make_lifecycle_event("cancelled", body.target_id)
    stream_path = _resolve_stream_path(target_kind, body.target_id)
    _emit_lifecycle(stream_path, event)

    # 4. Map result -> response (R25)
    if result["status"] == "ok":
        logger.info("control.cancel.ok target_id=%s session=%s", body.target_id, name)
        return StdlibJSONResponse(
            {"status": "cancelled", "tmux_session": name, "target_id": body.target_id},
            status_code=200,
        )
    logger.info(
        "control.cancel.already_cancelled target_id=%s session=%s",
        body.target_id,
        name,
    )
    return StdlibJSONResponse(
        {
            "status": "already_cancelled",
            "tmux_session": name,
            "target_id": body.target_id,
        },
        status_code=200,
    )


_RESUME_STATUS_ERROR_SLUGS: dict[str, str] = {
    "cancelled": "cannot_resume_cancelled",
    "completed": "cannot_resume_completed",
    "running": "cannot_resume_running",
}


def _resume_status_reject(status_value: object) -> StdlibJSONResponse | None:
    if not isinstance(status_value, str):
        return None
    slug = _RESUME_STATUS_ERROR_SLUGS.get(status_value)
    if slug is None:
        return None
    return StdlibJSONResponse({"error": slug}, status_code=409)


def _safe_derive_status(target_kind: str, target_id: str) -> dict[str, Any]:
    try:
        return dict(derive_status(target_kind, target_id))
    except Exception:  # noqa: BLE001 — status derivation must not poison the handler
        return {"status": "idle"}


def _build_resume_argv(
    target_kind: _TARGET_KIND,
    body: _AutopilotResumeRequest | _ChainResumeRequest,
    next_phase: str,
) -> tuple[list[str], str]:
    if target_kind == "autopilot":
        # Branch-narrowed: `body` is `_AutopilotResumeRequest` here (the
        # route shim guarantees this — see the docstring at the top of
        # `_handle_resume`). Static type-checkers see the union; the
        # assertion narrows it and lets us read `.pipeline` without
        # `getattr` fallback (CR-5 type-narrowing suggestion, S7).
        assert isinstance(body, _AutopilotResumeRequest)
        argv: list[str] = [
            "bash",
            str(_AUTOPILOT_SH_PATH),
            "--full",
            "--pipeline",
            body.pipeline,
            "--from",
            next_phase,
            body.target_id,
        ]
        return argv, next_phase
    plan_dir_abs = _resolve_target_dir("chain", body.target_id).resolve()
    argv = [
        "bash",
        str(_AUTOPILOT_CHAIN_SH_PATH),
        "run",
        str(plan_dir_abs),
    ]
    return argv, "chain"


def _handle_resume(
    target_kind: _TARGET_KIND,
    body: _AutopilotResumeRequest | _ChainResumeRequest,
) -> StdlibJSONResponse:
    # The union body type is narrowed by `target_kind` at every call site:
    # `resume_endpoint` (route shim) parses the request as
    # `_AutopilotResumeRequest` when target_kind=="autopilot" and
    # `_ChainResumeRequest` otherwise. Inside the `if target_kind ==
    # "autopilot":` branch, `body` is therefore always
    # `_AutopilotResumeRequest` (carries `.pipeline`); the else branch
    # always sees `_ChainResumeRequest` (no `.pipeline`). The union is the
    # type-checker's view; runtime narrowing is enforced by the caller.
    # 1. Existence precondition (R20-parallel)
    target_dir = _resolve_target_dir(target_kind, body.target_id)
    if not target_dir.is_dir():
        return StdlibJSONResponse({"error": "target_not_found"}, status_code=422)

    # 2. Status check (R28, R29)
    state = _safe_derive_status(target_kind, body.target_id)
    reject = _resume_status_reject(state.get("status"))
    if reject is not None:
        return reject

    # 3. Next-phase derivation (R30, R31)
    try:
        next_phase = detect_next_phase(target_kind, body.target_id)
    except StreamUnavailableError:
        return StdlibJSONResponse(
            {
                "error": "stream_unavailable",
                "hint": "fall back to terminal --from <phase>",
            },
            status_code=422,
        )
    if next_phase is None:
        return StdlibJSONResponse({"error": "cannot_resume_completed"}, status_code=409)

    # 4. Concurrency cap (R36)
    cap_check = _check_concurrency_cap()
    if cap_check is not None:
        active_count, _ = cap_check
        return StdlibJSONResponse(
            {
                "error": "concurrent_cap_reached",
                "cap": MAX_CONCURRENT_AUTOPILOTS,
                "active": active_count,
            },
            status_code=429,
            headers={"Retry-After": str(CONTROL_RETRY_AFTER_SECONDS)},
        )

    # 5. Resolve deterministic name + pre-check (R32)
    try:
        name = tmux_session.deterministic_name(target_kind, body.target_id)
    except ValueError as exc:
        return StdlibJSONResponse({"detail": str(exc)}, status_code=400)
    if tmux_session.session_exists(name, runner=_get_runner()):
        return StdlibJSONResponse({"error": "already_running", "session": name}, status_code=409)

    # 6. Build launch argv (R33)
    launch_argv, from_phase_value = _build_resume_argv(target_kind, body, next_phase)

    # 7. Invoke start_session (R33, R17)
    env = _build_subprocess_env()
    try:
        tmux_session.start_session(
            name, launch_argv, cwd=_MAIN_DIR, runner=_resolve_start_runner(env)
        )
    except tmux_session.SessionExistsError:
        return StdlibJSONResponse({"error": "already_running", "session": name}, status_code=409)
    except tmux_session.TmuxError as exc:
        return _tmux_error_response(exc, "failed to start tmux session")

    # 8. For chain — remove chain.PAUSE AFTER start_session (R33 second clause)
    if target_kind == "chain":
        chain_pause = _resolve_pause_path("chain", body.target_id)
        try:
            chain_pause.unlink(missing_ok=True)
        except OSError as exc:
            logger.warning(
                "event=control.resume.chain_pause_unlink_failed target_id=%s error=%s",
                body.target_id,
                exc,
            )

    # 9. Append `resumed` lifecycle event AFTER successful start (R34)
    event = _make_lifecycle_event("resumed", body.target_id)
    stream_path = _resolve_stream_path(target_kind, body.target_id)
    _emit_lifecycle(stream_path, event)

    logger.info(
        "control.resume.ok target_id=%s session=%s from_phase=%s",
        body.target_id,
        name,
        from_phase_value,
    )
    return StdlibJSONResponse(
        {
            "status": "resumed",
            "tmux_session": name,
            "target_id": body.target_id,
            "from_phase": from_phase_value,
        },
        status_code=200,
    )


# ---------------------------------------------------------------------------
# Route declarations (C1)
# ---------------------------------------------------------------------------


router = APIRouter()


@router.post("/api/{target_kind}/start")
async def start_endpoint(
    target_kind: _TARGET_KIND,
    body: _StartRequest,
) -> StdlibJSONResponse:
    return _handle_start(target_kind, body)


@router.post("/api/{target_kind}/pause")
async def pause_endpoint(
    target_kind: _TARGET_KIND,
    body: _TargetOnlyRequest,
) -> StdlibJSONResponse:
    return _handle_pause(target_kind, body)


@router.post("/api/{target_kind}/cancel")
async def cancel_endpoint(
    target_kind: _TARGET_KIND,
    body: _TargetOnlyRequest,
) -> StdlibJSONResponse:
    return _handle_cancel(target_kind, body)


@router.post("/api/{target_kind}/resume")
async def resume_endpoint(
    target_kind: _TARGET_KIND,
    body: dict[str, Any],
) -> StdlibJSONResponse:
    # Dispatch on target_kind to pick the correct Pydantic schema. The
    # path-param Literal validation already gated `target_kind`; we re-run
    # Pydantic on the body so a chain-resume body that contains `pipeline`
    # is rejected by `extra="forbid"` (ISP — _ChainResumeRequest has no
    # pipeline field).
    from pydantic import ValidationError

    try:
        if target_kind == "autopilot":
            parsed: _AutopilotResumeRequest | _ChainResumeRequest = (
                _AutopilotResumeRequest.model_validate(body)
            )
        else:
            parsed = _ChainResumeRequest.model_validate(body)
    except ValidationError as exc:
        # Match the shape of the existing `_validation_error_to_400` handler.
        errors = [{k: v for k, v in e.items() if k not in {"input", "url"}} for e in exc.errors()]
        return StdlibJSONResponse({"detail": errors}, status_code=400)
    return _handle_resume(target_kind, parsed)


__all__ = ["router"]
