"""Pure-stdlib wrapper around the tmux CLI.

Five argv-array subprocess functions (``start_session``, ``kill_session``,
``list_sessions``, ``session_exists``, ``deterministic_name``) plus an
injectable ``Runner`` ``typing.Protocol`` so tests run with no ``tmux``
binary on ``$PATH`` (REQUIREMENTS.md R23, AC-5). Phase 2 / Phase 3
consumers (``control.py``, ``terminal-websocket-bridge``) MUST route
every tmux invocation and every session-name construction through this
module — no inline ``subprocess.run`` for tmux, no string-interpolated
session names (host plan execution-plan.yaml:3057-3059).

Zero ``fastapi`` / ``starlette`` / ``pydantic`` / ``uvicorn`` imports
(R1). The only ``dashboard.server.*`` dependency is ``validation`` —
keeps the import graph one-deep through the bottom-of-graph regex
module and circular-free (EC-M2).
"""

from __future__ import annotations

import logging
import re
import subprocess
from collections.abc import Sequence
from pathlib import Path
from typing import Literal, Protocol, TypedDict

from dashboard.server.validation import SAFE_ID_REGEX, validate_safe_id

logger = logging.getLogger(__name__)

_TMUX_BIN = "tmux"

_NOT_FOUND_RE = re.compile(r"(can't find session|session not found)", re.IGNORECASE)
_DUPLICATE_SESSION_RE = re.compile(r"duplicate session", re.IGNORECASE)
# controls-06 #9 — tmux reports the "no server running" state in two
# distinct wordings depending on platform + tmux version:
#   1. `no server running on /tmp/tmux-501/default`         (older / Linux)
#   2. `error connecting to /tmp/tmux-501/default (...)`    (macOS, recent tmux)
# Both mean "there is no running tmux server right now"; the cap-check
# must treat both as zero active sessions instead of a TmuxError-503.
_NO_SERVER_RE = re.compile(
    r"(no server running)|(error connecting to .*/tmux-)",
    re.IGNORECASE,
)

_SEG = SAFE_ID_REGEX.removeprefix("^").removesuffix("$")
_NAME_PATTERN = re.compile(rf"^{_SEG}-{_SEG}$")

_ALLOWED_TARGET_KINDS: frozenset[str] = frozenset({"autopilot", "chain"})


class KillResult(TypedDict):
    status: Literal["ok", "not_found"]


class Runner(Protocol):
    """Injectable subprocess runner.

    Implementations MUST execute the argv list with ``shell=False`` and
    return a ``CompletedProcess`` whose ``stdout`` / ``stderr`` are
    captured text. Tests substitute a ``FakeRunner``; production uses
    ``_DEFAULT_RUNNER`` (``_SubprocessRunner``).
    """

    def run(self, argv: Sequence[str], *, cwd: Path | None) -> subprocess.CompletedProcess[str]: ...


class _SubprocessRunner:
    def run(self, argv: Sequence[str], *, cwd: Path | None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            list(argv),
            cwd=cwd,
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )


_DEFAULT_RUNNER: Runner = _SubprocessRunner()


class TmuxError(RuntimeError):
    """Raised on any unrecognised non-zero tmux exit.

    Carries the failed ``argv``, the tmux ``returncode``, and the
    captured ``stderr`` so a downstream HTTP handler can surface them
    verbatim.
    """

    def __init__(self, *, argv: list[str], returncode: int, stderr: str) -> None:
        self.argv = argv
        self.returncode = returncode
        self.stderr = stderr
        super().__init__(self._render())

    def _render(self) -> str:
        subcommand = self.argv[1] if len(self.argv) > 1 else "?"
        return f"tmux {subcommand} failed (exit {self.returncode}): {self.stderr.strip()}"

    def __str__(self) -> str:
        return self._render()


class SessionExistsError(TmuxError):
    """Raised by ``start_session`` when the target name is already in use."""


def deterministic_name(target_kind: str, target_id: str) -> str:
    """Return ``f"{target_kind}-{target_id}"`` after validating both.

    ``target_kind`` must be in ``_ALLOWED_TARGET_KINDS`` (defense in
    depth — Pydantic at the route layer is the primary guard).
    ``target_id`` must match ``SAFE_ID_REGEX``.
    """
    if target_kind not in _ALLOWED_TARGET_KINDS:
        allowed = sorted(_ALLOWED_TARGET_KINDS)
        raise ValueError(f"target_kind must be one of {allowed}; got {target_kind!r}")
    validate_safe_id(target_id, field="target_id")
    return f"{target_kind}-{target_id}"


def _validate_name(name: str) -> None:
    if _NAME_PATTERN.match(name) is None:
        raise ValueError(f"name failed structural validation: {name!r}")


def _invoke(
    runner: Runner | None, argv: list[str], *, cwd: Path | None
) -> subprocess.CompletedProcess[str]:
    real = runner if runner is not None else _DEFAULT_RUNNER
    try:
        result = real.run(argv, cwd=cwd)
    except FileNotFoundError as fnf:
        raise TmuxError(argv=argv, returncode=-1, stderr=str(fnf)) from fnf
    subcommand = argv[1] if len(argv) > 1 else "?"
    logger.debug("tmux %s argv=%r exit=%d", subcommand, argv, result.returncode)
    return result


def start_session(
    name: str,
    launch_argv: Sequence[str],
    cwd: Path | None,
    *,
    runner: Runner | None = None,
) -> None:
    """Run ``tmux new-session -d -s <name> -x 200 -y 50 -- <launch_argv...>``.

    ``launch_argv`` is passed verbatim — shell metacharacters are NEVER
    interpreted because the runner contract is ``shell=False``.
    Raises ``ValueError`` for invalid ``name`` / empty ``launch_argv``,
    ``SessionExistsError`` if the name is already in use, and
    ``TmuxError`` for every other non-zero exit (including a missing
    ``tmux`` binary).

    controls-07 #15 — pane geometry is pinned at 200×50 because tmux
    defaults detached panes to 80×24, which forced the chain
    orchestrator's output to hard-wrap at column 80. The wrapped
    lines + cursor-positioning ANSI sequences then arrived at the
    xterm.js WS viewer (rendering at ~200 cols) with offsets the
    viewer interpreted relative to its own width — producing the
    "random mid-screen indents" symptom observed during the
    controls-07 session.
    """
    if not launch_argv:
        raise ValueError("launch_argv must be non-empty")
    _validate_name(name)
    argv = [
        _TMUX_BIN, "new-session", "-d", "-s", name,
        "-x", "200", "-y", "50",
        "--", *launch_argv,
    ]
    result = _invoke(runner, argv, cwd=cwd)
    if result.returncode == 0:
        logger.info("tmux session started: %s", name)
        return
    stderr = result.stderr or ""
    if _DUPLICATE_SESSION_RE.search(stderr):
        raise SessionExistsError(argv=argv, returncode=result.returncode, stderr=stderr)
    raise TmuxError(argv=argv, returncode=result.returncode, stderr=stderr)


def kill_session(name: str, *, runner: Runner | None = None) -> KillResult:
    """Run ``tmux kill-session -t <name>``.

    Returns ``{"status": "ok"}`` on success, ``{"status": "not_found"}``
    if the session does not exist (idempotent ENOENT mapping), and
    raises ``TmuxError`` for any other failure.
    """
    _validate_name(name)
    argv = [_TMUX_BIN, "kill-session", "-t", name]
    result = _invoke(runner, argv, cwd=None)
    if result.returncode == 0:
        return {"status": "ok"}
    stderr = result.stderr or ""
    # controls-07 #1 — "no server running" stderr means the whole tmux
    # server is gone, which is a stronger ENOENT than per-session
    # not_found. Treat it the same so the stale-running Restart sequence
    # (cancel-then-start on a dead chain) doesn't 500 at the cancel leg.
    # Matches the cycle-6 #10 contract already honoured by list_sessions
    # (line 214) and session_exists (line 231).
    if _NOT_FOUND_RE.search(stderr) or _NO_SERVER_RE.search(stderr):
        logger.debug("tmux kill-session: %s already gone (not_found)", name)
        return {"status": "not_found"}
    raise TmuxError(argv=argv, returncode=result.returncode, stderr=stderr)


def list_sessions(
    prefix_filter: str | Sequence[str],
    *,
    runner: Runner | None = None,
) -> list[str]:
    """Run ``tmux list-sessions -F '#{session_name}'`` and filter by prefix.

    ``prefix_filter`` accepts either a single string or a sequence of
    strings (R14 — consumer call shape at execution-plan.yaml:3191).
    Returns ``[]`` when tmux stdout is empty or no server is running;
    raises ``TmuxError`` for any other non-zero exit.
    """
    if isinstance(prefix_filter, str):
        prefixes: tuple[str, ...] = (prefix_filter,)
    else:
        prefixes = tuple(prefix_filter)
    if not prefixes or any(not p for p in prefixes):
        raise ValueError("prefix_filter must be non-empty")
    argv = [_TMUX_BIN, "list-sessions", "-F", "#{session_name}"]
    result = _invoke(runner, argv, cwd=None)
    if result.returncode == 0:
        names = [ln for ln in (result.stdout or "").split("\n") if ln]
        return [n for n in names if any(n.startswith(p) for p in prefixes)]
    stderr = result.stderr or ""
    if _NO_SERVER_RE.search(stderr):
        return []
    raise TmuxError(argv=argv, returncode=result.returncode, stderr=stderr)


def session_exists(name: str, *, runner: Runner | None = None) -> bool:
    """Run ``tmux has-session -t <name>``: True iff the session exists.

    Maps no-such-session and no-server stderr signatures to ``False``.
    Any other non-zero exit raises ``TmuxError``.
    """
    _validate_name(name)
    argv = [_TMUX_BIN, "has-session", "-t", name]
    result = _invoke(runner, argv, cwd=None)
    if result.returncode == 0:
        return True
    stderr = result.stderr or ""
    if _NOT_FOUND_RE.search(stderr) or _NO_SERVER_RE.search(stderr):
        return False
    raise TmuxError(argv=argv, returncode=result.returncode, stderr=stderr)


__all__ = [
    "KillResult",
    "Runner",
    "SessionExistsError",
    "TmuxError",
    "deterministic_name",
    "kill_session",
    "list_sessions",
    "session_exists",
    "start_session",
]
