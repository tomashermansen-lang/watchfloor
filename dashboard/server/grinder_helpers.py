"""Grinder status data assembly for dashboard API.

Reads grinder-plan.yaml, grinder-state.json, events.ndjson, and
deferred-findings.json from per-project docs/grinder/ directories.
Assembles schema-compliant JSON responses for the /api/grinder endpoint.

Functions: assemble_project_detail, list_grinder_projects,
create_pause, remove_pause, get_grinder_stream_path, filter_batch_events.
"""

import json
import logging
from collections import deque
from pathlib import Path

logger = logging.getLogger(__name__)

_GRINDER_DIR = "docs/grinder"
_PLAN_FILE = "grinder-plan.yaml"
_STATE_FILE = "grinder-state.json"
_EVENTS_FILE = "events.ndjson"
_DEFERRALS_FILE = "deferred-findings.json"
_PAUSE_FILE = "PAUSE"
_STREAM_FILE = "grinder-stream.ndjson"
_BATCH_START_KEYWORDS = {"started", "begin", "starting"}
_BATCH_END_KEYWORDS = {"completed", "finished", "done", "failed"}


def get_grinder_stream_path(project_root: str) -> str | None:
    """Resolve grinder-stream.ndjson path, validated under PROJECTS_ROOT.

    Returns the resolved absolute path string, or None if the file
    doesn't exist or fails path validation.
    """
    from dashboard.server.autopilot_helpers import _is_allowed_path

    path = Path(project_root) / _GRINDER_DIR / _STREAM_FILE
    try:
        resolved = path.resolve()
    except (OSError, ValueError):
        return None

    if not _is_allowed_path(resolved) or not resolved.is_file():
        return None
    return str(resolved)


def _find_batch_bounds(events: list[dict], batch_id: str) -> tuple[int, int]:
    """Find (start_index, end_index) for a batch in the event list.

    Returns (-1, -1) if batch not found. end_index is len(events) if
    batch is still running (no end marker).  Uses last start marker
    (handles retries).
    """

    start = -1
    end = -1

    for i, ev in enumerate(events):
        if ev.get("type") != "orchestrator":
            continue
        msg = (ev.get("msg") or "").lower()
        if f"batch {batch_id}" not in msg:
            continue

        words = set(msg.split())
        if words & _BATCH_START_KEYWORDS:
            start = i  # Last start marker wins
            end = -1  # Reset end on retry
        elif words & _BATCH_END_KEYWORDS and start != -1:
            end = i + 1  # Inclusive of end marker
            break

    if start == -1:
        return (-1, -1)
    if end == -1:
        return (start, len(events))
    return (start, end)


def filter_batch_events(events: list[dict], batch_id: str | None) -> list[dict]:
    """Filter events to a specific batch, or return all if batch_id is None."""
    if batch_id is None:
        return events
    start, end = _find_batch_bounds(events, batch_id)
    if start == -1:
        return []
    return events[start:end]


def _read_plan(grinder_dir: Path) -> dict | None:
    """Parse grinder-plan.yaml. Returns None on missing/malformed."""
    plan_path = grinder_dir / _PLAN_FILE
    try:
        import yaml
        return yaml.safe_load(plan_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except ImportError:
        logger.warning("PyYAML not installed — cannot read %s", plan_path)
        return None
    except Exception:
        logger.warning("Malformed YAML in %s", plan_path, exc_info=True)
        return None


def _read_state(grinder_dir: Path) -> dict | None:
    """Parse grinder-state.json. Returns None on missing/malformed."""
    state_path = grinder_dir / _STATE_FILE
    try:
        return json.loads(state_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (json.JSONDecodeError, OSError):
        logger.warning("Malformed or unreadable %s", state_path)
        return None


def _read_events(grinder_dir: Path, limit: int = 50) -> list[dict]:
    """Stream events.ndjson, return last `limit` valid events via deque.

    Malformed lines are skipped. Returns newest-first in the output.
    """
    events_path = grinder_dir / _EVENTS_FILE
    try:
        buf: deque[dict] = deque(maxlen=limit)
        with open(events_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    buf.append(json.loads(line))
                except json.JSONDecodeError:
                    logger.warning("Skipping malformed NDJSON line in %s", events_path)
        # Return newest-first
        return list(reversed(buf))
    except FileNotFoundError:
        return []
    except OSError:
        logger.warning("Cannot read %s", events_path)
        return []


def _read_deferrals(grinder_dir: Path) -> list[dict]:
    """Parse deferred-findings.json, sorted by count descending."""
    deferrals_path = grinder_dir / _DEFERRALS_FILE
    try:
        data = json.loads(deferrals_path.read_text(encoding="utf-8"))
        if not isinstance(data, list):
            return []
        return sorted(data, key=lambda d: d.get("count", 0), reverse=True)
    except FileNotFoundError:
        return []
    except (json.JSONDecodeError, OSError):
        logger.warning("Malformed or unreadable %s", deferrals_path)
        return []


def _derive_pass_statuses(plan: dict | None, state: dict | None) -> list[dict]:
    """Merge plan passes with state to derive status and batch counts."""
    if not plan or "passes" not in plan:
        return []

    current_pass = state.get("current_pass") if state else None
    result = []

    for p in plan["passes"]:
        pass_id = p.get("id", "")
        batches = p.get("batches", [])
        batches_total = len(batches)
        batches_completed = sum(1 for b in batches if b.get("status") == "completed")

        if batches_total > 0 and batches_completed == batches_total:
            status = "completed"
        elif pass_id == current_pass:
            status = "in_progress"
        elif any(b.get("status") == "failed" for b in batches):
            status = "failed"
        else:
            status = "pending"

        result.append({
            "id": pass_id,
            "name": p.get("name", pass_id),
            "status": status,
            "batches_total": batches_total,
            "batches_completed": batches_completed,
        })

    return result


def _find_parent_pass(plan: dict | None, batch_id: str, fallback: str) -> str:
    """Find the parent pass ID for a batch in the plan."""
    if not plan or "passes" not in plan:
        return fallback
    for p in plan["passes"]:
        for b in p.get("batches", []):
            if b.get("id") == batch_id:
                return p.get("id", fallback)
    return fallback


def _extract_batch_timing(events: list[dict], batch_id: str, default_ts: str | None) -> tuple[int, str | None]:
    """Extract turns_elapsed and started_at for a batch.

    events.ndjson is append-only across discover cycles — the same
    batch_id can appear multiple times (one entry per discover cycle).
    Pick the NEWEST started event by timestamp, not the last one
    iterated; otherwise the dashboard's GrinderDetail displays a
    historical cycle's timestamps + turn count instead of the current
    run. See dashboard/tests/test_grinder_helpers_batch_timing.py for
    the regression scenarios.
    """
    newest_ts: str | None = None
    turns_elapsed = 0
    for ev in events:
        if ev.get("batch") != batch_id or ev.get("event") != "started":
            continue
        ts = ev.get("ts")
        if not ts:
            continue
        if newest_ts is None or ts > newest_ts:
            newest_ts = ts
            turns_elapsed = ev.get("turns", 0)
    started_at = newest_ts if newest_ts is not None else default_ts
    return turns_elapsed, started_at


def _derive_current_batch(
    state: dict | None,
    events: list[dict],
    plan: dict | None = None,
) -> dict | None:
    """Build current_batch object with turns_elapsed from events."""
    if not state or not state.get("current_batch"):
        return None

    batch_id = state["current_batch"]
    current_pass = state.get("current_pass", "")
    parent_pass = _find_parent_pass(plan, batch_id, current_pass)
    turns_elapsed, started_at = _extract_batch_timing(events, batch_id, state.get("started_at"))

    return {
        "id": batch_id,
        "pass": parent_pass,
        "started_at": started_at,
        "turns_elapsed": turns_elapsed,
    }


def assemble_project_detail(project_root: str) -> dict:
    """Full schema-compliant response for one project."""
    grinder_dir = Path(project_root) / _GRINDER_DIR

    plan = _read_plan(grinder_dir)
    state = _read_state(grinder_dir)
    events = _read_events(grinder_dir)
    deferrals = _read_deferrals(grinder_dir)

    passes = _derive_pass_statuses(plan, state)
    current_batch = _derive_current_batch(state, events, plan)

    return {
        "passes": passes,
        "current_batch": current_batch,
        "recent_events": events,
        "top_deferrals": deferrals,
    }


def _derive_overall_status(passes: list[dict]) -> str:
    """Derive overall grinder status from pass statuses."""
    statuses = [p["status"] for p in passes]
    if not statuses:
        return "idle"
    if "in_progress" in statuses:
        return "in_progress"
    if "failed" in statuses:
        return "failed"
    if all(s == "completed" for s in statuses):
        return "completed"
    return "pending"


def _find_current_pass(passes: list[dict]) -> str | None:
    """Find the ID of the in-progress pass, or None."""
    for p in passes:
        if p["status"] == "in_progress":
            return p["id"]
    return None


def _is_paused(grinder_dir: Path, state: dict | None) -> bool:
    """Check if grinder is paused via state flag or PAUSE file."""
    return bool(state and state.get("paused")) or (grinder_dir / _PAUSE_FILE).is_file()


def _build_project_summary(root: str) -> dict:
    """Build a single project summary dict."""
    grinder_dir = Path(root) / _GRINDER_DIR
    state = _read_state(grinder_dir)
    plan = _read_plan(grinder_dir)
    events = _read_events(grinder_dir)
    deferrals = _read_deferrals(grinder_dir)
    passes = _derive_pass_statuses(plan, state)
    paused = _is_paused(grinder_dir, state)

    return {
        "project": Path(root).name,
        "path": root,
        "status": _derive_overall_status(passes),
        "current_pass": _find_current_pass(passes),
        "batches_completed": sum(p["batches_completed"] for p in passes),
        "batches_total": sum(p["batches_total"] for p in passes),
        "deferrals_count": len(deferrals),
        "last_event_ts": events[0]["ts"] if events else None,
        "paused": paused,
    }


def list_grinder_projects() -> list[dict]:
    """Summary array of all projects with grinder data."""
    from dashboard.server.autopilot_helpers import _get_all_project_roots
    roots = _get_all_project_roots()
    projects = []

    for root in roots:
        plan_path = Path(root) / _GRINDER_DIR / _PLAN_FILE
        if not plan_path.is_file():
            continue
        projects.append(_build_project_summary(root))

    return projects


def create_pause(project_root: str) -> None:
    """Create docs/grinder/PAUSE file. Idempotent."""
    pause_path = Path(project_root) / _GRINDER_DIR / _PAUSE_FILE
    try:
        pause_path.touch(exist_ok=False)
    except FileExistsError:
        pass  # idempotent


def remove_pause(project_root: str) -> None:
    """Remove docs/grinder/PAUSE file. Idempotent."""
    pause_path = Path(project_root) / _GRINDER_DIR / _PAUSE_FILE
    try:
        pause_path.unlink()
    except FileNotFoundError:
        pass  # idempotent
