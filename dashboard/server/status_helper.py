"""Lifecycle-derived session status helper with byte-offset incremental NDJSON reads.

Pure stdlib + first-party `server.lifecycle_events`. No FastAPI / Pydantic / Starlette.
Public: derive_status, SessionStatus, STATUS_VALUES, TARGET_KINDS.
Six-value vocabulary declared for forward compat; today four are produced
(idle/running/paused/cancelled); completed/failed are reserved for a future
schema extension. Single-thread only (R23); no locks on _STATE_CACHE.
PROJECTS_ROOT is read once at import into _PROJECTS_ROOT. If the env value
changes after import, reassign status_helper._PROJECTS_ROOT directly and
call _reset_cache() — _reset_cache() alone does not re-read the env var.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, TypedDict

from dashboard.server.lifecycle_events import LifecycleEventInvalid, parse_event

logger = logging.getLogger("dashboard.server.status_helper")

# controls-06 #17 — statuses where a live tmux session is expected.
# Terminal statuses (cancelled/completed/failed) have no tmux to probe.
_LIVE_STATUSES: frozenset[str] = frozenset({"running", "paused"})

# Perf bound (dashboard-perf 2026-06-02): `tmux has-session` answers in
# single-digit ms against a local server, so this timeout is purely a
# wedged-tmux guard. The dashboard fires one probe per live session on
# every status poll; the old 2.0 s value could pin a threadpool thread
# for seconds across N sessions when tmux hung. 0.5 s bounds the worst case.
_TMUX_PROBE_TIMEOUT_S: float = 0.5


def _is_tmux_alive(tmux_session_name: str) -> bool:
    """controls-06 #17 — probe `tmux has-session -t <name>`.

    Inline subprocess (rather than a server.tmux_session import) so
    status_helper stays at "pure stdlib + lifecycle_events". Returns
    True iff exit 0. Maps the well-known "no such session" / "no
    server running" stderr patterns to False; any other failure
    raises, which the caller swallows.
    """
    result = subprocess.run(
        ["tmux", "has-session", "-t", tmux_session_name],
        capture_output=True, timeout=_TMUX_PROBE_TIMEOUT_S, check=False,
    )
    if result.returncode == 0:
        return True
    stderr = (result.stderr or b"").decode("utf-8", errors="replace")
    if "no such" in stderr.lower() or "no server" in stderr.lower() or "error connecting" in stderr.lower():
        return False
    raise RuntimeError(f"tmux has-session unexpected stderr: {stderr[:120]}")

STATUS_VALUES: tuple[str, ...] = (
    "idle",
    "running",
    "paused",
    "cancelled",
    "completed",
    "failed",
)
TARGET_KINDS: tuple[str, ...] = ("autopilot", "chain")

_TARGET_PATTERN: re.Pattern[str] = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
_PROJECTS_ROOT: Path = Path(os.environ.get("PROJECTS_ROOT", str(Path.home() / "Projekter")))


class SessionStatus(TypedDict):
    status: Literal["idle", "running", "paused", "cancelled", "completed", "failed"]
    phase_at_pause: str | None
    last_phase_complete: str | None
    started_at: str | None
    tmux_session: str | None


@dataclass
class _CachedState:
    byte_offset: int = 0
    status: str = "idle"
    phase_at_pause: str | None = None
    last_phase_complete: str | None = None
    started_at: str | None = None
    tmux_session: str | None = None

    def reset(self) -> None:
        self.byte_offset = 0
        self.status = "idle"
        self.phase_at_pause = None
        self.last_phase_complete = None
        self.started_at = None
        self.tmux_session = None


_STATE_CACHE: dict[tuple[str, str], _CachedState] = {}


def _reset_cache() -> None:
    _STATE_CACHE.clear()


def _validate_inputs(target_kind: str, target_id: str) -> None:
    if target_kind not in TARGET_KINDS:
        raise ValueError(f"target_kind must be one of {TARGET_KINDS}; got {target_kind!r}")
    if not isinstance(target_id, str) or not _TARGET_PATTERN.match(target_id):
        raise ValueError(f"target_id failed validation: {target_id!r}")


def _iter_project_roots() -> Iterator[Path]:
    if not _PROJECTS_ROOT.is_dir():
        return
    try:
        children = sorted(_PROJECTS_ROOT.iterdir())
    except OSError:
        return
    for child in children:
        try:
            if child.is_dir() and not child.name.startswith("."):
                yield child
        except OSError:
            continue


def _resolve_stream_path(target_kind: str, target_id: str) -> Path | None:
    label, fname = (
        ("Feature", "autopilot-stream.ndjson")
        if target_kind == "autopilot"
        else ("Plan", "chain-events.ndjson")
    )
    for project in _iter_project_roots():
        for prefix in ("INPROGRESS", "DONE"):
            candidate = project / "docs" / f"{prefix}_{label}_{target_id}" / fname
            try:
                if candidate.is_file():
                    return candidate
            except OSError:
                continue
    return None


def _apply_lifecycle_action(
    event: dict[str, Any], state: _CachedState, stream_path: Path
) -> None:
    # Split out of _apply_line so each function stays under S3776's 15-branch
    # cognitive-complexity budget; dispatch order preserves R7/R11/R24.
    action = event["action"]
    if action == "started":
        state.status, state.started_at, state.phase_at_pause = "running", event["ts"], None
        return
    if action == "resumed":
        state.status, state.phase_at_pause = "running", None
        return
    if action == "phase_complete":
        state.status, state.phase_at_pause = "running", None
        phase = event.get("phase")
        if isinstance(phase, str) and phase:
            state.last_phase_complete = phase
        else:
            logger.warning(
                "status_helper: phase_complete missing/invalid phase field in %s",
                stream_path,
            )
        return
    if action == "paused":
        state.status, state.phase_at_pause = "paused", event.get("phase_at_pause")
        return
    if action == "cancelled":
        state.status, state.phase_at_pause = "cancelled", None
        return
    logger.warning("status_helper: unknown action %r in %s (OCP gap)", action, stream_path)


def _apply_line(line: str, state: _CachedState, stream_path: Path) -> None:
    stripped = line.strip()
    if not stripped:
        return
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError as exc:
        logger.warning("status_helper: invalid JSON in %s: %s", stream_path, exc)
        return
    if not isinstance(parsed, dict):
        logger.warning("status_helper: non-dict JSON in %s: %s", stream_path, type(parsed).__name__)
        return
    if parsed.get("type") != "lifecycle":
        return
    try:
        event = parse_event(stripped)
    except LifecycleEventInvalid as exc:
        logger.warning("status_helper: lifecycle field %s invalid in %s", str(exc), stream_path)
        return

    tmux = event.get("tmux_session")
    if isinstance(tmux, str) and tmux:
        state.tmux_session = tmux

    _apply_lifecycle_action(event, state, stream_path)


def _state_to_dict(state: _CachedState) -> SessionStatus:
    """Project state → response dict + reconcile against live tmux.

    controls-06 #17b — every derive_status return goes through here
    so the tmux-liveness reconciliation fires on EVERY poll, not just
    the path that read new lifecycle bytes. The cycle-17 fix placed
    the reconciliation on the new-bytes branch only; for a silent
    chain (autopilot-chain.sh exited at chain_blocked), the stream
    stops growing and every subsequent poll took an early-return,
    silently serving stale tmux_session — defeating the whole point
    of the reconciliation.

    Blanks tmux_session on the RETURN dict only (cache untouched) so
    the frontend's isStale check fires. Probe exceptions are
    swallowed with a warning; tmux_session passes through unchanged
    in that case so a flaky probe never turns a successful poll into
    "lost".
    """
    result = SessionStatus(
        status=state.status,  # type: ignore[typeddict-item]
        phase_at_pause=state.phase_at_pause,
        last_phase_complete=state.last_phase_complete,
        started_at=state.started_at,
        tmux_session=state.tmux_session,
    )
    if result["status"] in _LIVE_STATUSES and result["tmux_session"]:
        try:
            alive = _is_tmux_alive(result["tmux_session"])
        except Exception as exc:  # noqa: BLE001
            # controls-07 #7 — fail CLOSED + include str(exc). Earlier
            # fail-open hid "tmux not on dashboard PATH" cases as a
            # type-only warning, then claimed the chain was alive.
            logger.warning("tmux probe failed: %s: %s — treating as dead", type(exc).__name__, exc)
            alive = False
        if not alive:
            result["tmux_session"] = None
    return result


def derive_status(target_kind: str, target_id: str) -> SessionStatus:
    """Return current derived state for one autopilot or chain target.

    Reads only bytes appended since the previous call (per-target offset cache).
    Truncation triggers silent cache reset + full re-read. Missing stream
    returns idle default. OSError on open returns last cached state.
    Every return path runs through _state_to_dict so the cycle-17b
    tmux-liveness reconciliation fires uniformly.
    """
    _validate_inputs(target_kind, target_id)
    state = _STATE_CACHE.setdefault((target_kind, target_id), _CachedState())

    path = _resolve_stream_path(target_kind, target_id)
    if path is None:
        return _state_to_dict(state)

    try:
        current_size = path.stat().st_size
    except OSError:
        return _state_to_dict(state)

    if current_size < state.byte_offset:
        state.reset()
    if current_size == state.byte_offset:
        return _state_to_dict(state)

    try:
        with open(path, "rb") as fh:
            fh.seek(state.byte_offset)
            raw = fh.read()
    except OSError as exc:
        logger.warning("status_helper: %s opening %s", type(exc).__name__, path)
        return _state_to_dict(state)

    state.byte_offset += len(raw)
    for line in raw.decode("utf-8", errors="replace").split("\n"):
        _apply_line(line, state, path)
    return _state_to_dict(state)
