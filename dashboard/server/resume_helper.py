"""Resume-state helper deriving the next pending pipeline phase.

Reads the lifecycle NDJSON stream for a target (autopilot or chain) and
returns the next phase from PHASE_ORDER (sourced once per process from
adapters/claude-code/claude/tools/lib/phase-selector.sh) based on the most
recent phase_complete event in the stream.

Public surface:
    detect_next_phase(target_kind, target_id) -> str | None
    StreamUnavailableError(RuntimeError)

Pure-stdlib consumer of the lifecycle stream contract; no writes, no new
events, no schema changes, no shell modifications.
"""

from __future__ import annotations

import json
import logging
import re
import shlex
import subprocess
from pathlib import Path

from dashboard.server.autopilot_helpers import _get_all_project_roots, _is_allowed_path
from dashboard.server.lifecycle_events import _TARGET_PATTERN

logger = logging.getLogger("dashboard.server.resume_helper")

_PHASE_SELECTOR_PATH: Path = (
    Path(__file__).resolve().parents[2]
    / "adapters"
    / "claude-code"
    / "claude"
    / "tools"
    / "lib"
    / "phase-selector.sh"
)
_PHASE_ORDER_CACHE: tuple[str, ...] | None = None
_PHASE_ID_PATTERN: re.Pattern[str] = re.compile(r"^[a-z0-9-]{1,32}$")
_VALID_TARGET_KINDS: frozenset[str] = frozenset({"autopilot", "chain"})


class StreamUnavailableError(RuntimeError):
    """Raised when the lifecycle stream cannot be read or PHASE_ORDER is unavailable."""


def _format_unavailable(target_kind: str, target_id: str, reason: str) -> str:
    return (
        f"resume stream unavailable: target_kind={target_kind} "
        f"target_id={target_id} reason={reason}"
    )


def _validate_args(target_kind: str, target_id: str) -> None:
    if target_kind not in _VALID_TARGET_KINDS:
        raise ValueError(
            f"target_kind must be one of {sorted(_VALID_TARGET_KINDS)}; got {target_kind!r}"
        )
    if not isinstance(target_id, str) or not _TARGET_PATTERN.fullmatch(target_id):
        raise ValueError(f"target_id must match ^[a-zA-Z0-9_-]{{1,64}}$; got {target_id!r}")


def _load_phase_order() -> tuple[str, ...]:
    global _PHASE_ORDER_CACHE
    if _PHASE_ORDER_CACHE is not None:
        return _PHASE_ORDER_CACHE
    selector = _PHASE_SELECTOR_PATH
    cmd = f'set -e; source {shlex.quote(str(selector))}; printf "%s\\n" "${{PHASE_ORDER[*]}}"'
    try:
        result = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
    except (
        subprocess.CalledProcessError,
        FileNotFoundError,
        subprocess.TimeoutExpired,
    ) as exc:
        raise StreamUnavailableError(
            f"resume stream unavailable: PHASE_ORDER load failed: {type(exc).__name__}"
        ) from exc
    stdout = result.stdout.strip()
    if not stdout:
        raise StreamUnavailableError("resume stream unavailable: PHASE_ORDER is empty")
    phases = tuple(stdout.split())
    for phase in phases:
        if not _PHASE_ID_PATTERN.fullmatch(phase):
            raise StreamUnavailableError(
                f"resume stream unavailable: PHASE_ORDER element invalid: {phase!r}"
            )
    _PHASE_ORDER_CACHE = phases
    return phases


def _validate_candidate(candidate: Path, target_kind: str, target_id: str) -> Path:
    if not candidate.is_file():
        raise StreamUnavailableError(
            _format_unavailable(target_kind, target_id, "not_a_file")
        )
    try:
        resolved = candidate.resolve()
    except OSError as exc:
        raise StreamUnavailableError(
            _format_unavailable(target_kind, target_id, "io_error")
        ) from exc
    if not _is_allowed_path(resolved):
        raise StreamUnavailableError(
            _format_unavailable(target_kind, target_id, "outside_roots")
        )
    return resolved


def _resolve_stream_path(target_kind: str, target_id: str) -> Path:
    filename = "autopilot-stream.ndjson" if target_kind == "autopilot" else "chain-events.ndjson"
    prefix_kind = "Feature" if target_kind == "autopilot" else "Plan"
    roots = _get_all_project_roots()
    for state in ("INPROGRESS", "DONE"):
        for root in roots:
            candidate = Path(root) / "docs" / f"{state}_{prefix_kind}_{target_id}" / filename
            if candidate.exists():
                return _validate_candidate(candidate, target_kind, target_id)
    raise StreamUnavailableError(_format_unavailable(target_kind, target_id, "not_found"))


def _scan_last_phase_complete(stream_path: Path, target_kind: str, target_id: str) -> str | None:
    try:
        with open(stream_path, encoding="utf-8", errors="replace") as fh:
            candidate: str | None = None
            for lineno, raw in enumerate(fh, start=1):
                line = raw.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as exc:
                    logger.warning(
                        "resume_helper: skipping line %d in %s: %s",
                        lineno,
                        stream_path,
                        exc.msg,
                    )
                    continue
                if not isinstance(event, dict):
                    continue
                if event.get("type") != "lifecycle":
                    continue
                if event.get("action") != "phase_complete":
                    continue
                phase = event.get("phase")
                if not isinstance(phase, str) or not phase:
                    continue
                candidate = phase
            return candidate
    except OSError as exc:
        raise StreamUnavailableError(
            _format_unavailable(target_kind, target_id, "io_error")
        ) from exc


def _next_phase(last_phase: str | None, phase_order: tuple[str, ...]) -> str | None:
    if last_phase is None:
        return phase_order[0]
    try:
        idx = phase_order.index(last_phase)
    except ValueError:
        logger.warning(
            "resume_helper: unknown phase %r in stream; falling back to %r (known order: %s)",
            last_phase,
            phase_order[0],
            list(phase_order),
        )
        return phase_order[0]
    if idx + 1 < len(phase_order):
        return phase_order[idx + 1]
    return None


def detect_next_phase(target_kind: str, target_id: str) -> str | None:
    """Return the next pending phase in PHASE_ORDER for a target's lifecycle stream.

    Args:
        target_kind: ``"autopilot"`` reads
            ``docs/INPROGRESS_Feature_<id>/autopilot-stream.ndjson``;
            ``"chain"`` reads
            ``docs/INPROGRESS_Plan_<id>/chain-events.ndjson`` (DONE_ fallback).
        target_id: Target identifier matching ``^[a-zA-Z0-9_-]{1,64}$``.

    Returns:
        Next phase name; the first phase if the stream has no
        ``phase_complete`` event; ``None`` if the most recent
        ``phase_complete`` names the final phase.

    Raises:
        ValueError: ``target_kind`` not in {"autopilot","chain"} or
            ``target_id`` does not match the pattern.
        StreamUnavailableError: stream unreachable, candidate is not a
            regular file, symlink resolves outside the project-roots
            allowlist, OS error during read, or PHASE_ORDER cannot be
            loaded from phase-selector.sh.
    """
    _validate_args(target_kind, target_id)
    phase_order = _load_phase_order()
    stream_path = _resolve_stream_path(target_kind, target_id)
    last_phase = _scan_last_phase_complete(stream_path, target_kind, target_id)
    return _next_phase(last_phase, phase_order)
