"""Feature discovery from docs folders and sessions.jsonl.

Scans PENDING_Feature_*/, INPROGRESS_Feature_*/, and DONE_Feature_*/
under each project root's docs/, merges with session events from
sessions.jsonl, applies stuck detection, and emits a unified feature
list with lifecycle ∈ {pending, inprogress, done} and an optional
done_at ISO 8601 timestamp for DONE features.

Functions: discover_features (public entry point).
"""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import TypedDict

from dashboard.server import plan_helpers
from dashboard.server.autopilot_helpers import _get_all_project_roots as get_project_roots
from dashboard.server.autopilot_helpers import discover_autopilots
from dashboard.server.session_helpers import FLOW_PHASES_FULL
from dashboard.server.session_helpers import _detect_flow_phase as detect_flow_phase
from dashboard.server.stuck_detection import detect_stuck_sessions

logger = logging.getLogger(__name__)


class FeatureDict(TypedDict, total=False):
    name: str
    project: str
    project_root: str
    phase: str
    phase_index: int
    total_phases: int
    pipeline_type: str
    artifacts: list[dict]
    sessions: list[dict]
    status: str
    stuck_info: dict | None
    last_activity: str | None
    is_autopilot: bool
    lifecycle: str
    done_at: str | None
    plan_dir: str
    plan_task_id: str
    # Long human-readable task name (task.name on the linked plan task).
    # Surfaced server-side so FeatureCard can render it as a subtitle
    # without an N+1 fetch per card. Omitted when no plan-link match
    # exists, or when task.name equals the feature folder slug.
    plan_task_name: str


FEATURE_ARTIFACT_ALLOWLIST = [
    "REQUIREMENTS.md",
    "DESIGN.md",
    "PLAN.md",
    "REVIEW.md",
    "TEAM_REVIEW.md",
    "TESTPLAN.md",
    "STATIC_ANALYSIS.md",
    "MANUAL_TEST_LOG.md",
    "QA_REPORT.md",
    "TEAM_QA.md",
]

LIFECYCLE_PREFIXES: tuple[tuple[str, str], ...] = (
    ("INPROGRESS_Feature_", "inprogress"),
    ("DONE_Feature_", "done"),
    ("PENDING_Feature_", "pending"),
)
# Lower rank wins on cross-lifecycle collision (REQ-10).
LIFECYCLE_PRECEDENCE: dict[str, int] = {
    "inprogress": 0,
    "done": 1,
    "pending": 2,
}

# Module-level cache with 3-second TTL
_cache: dict = {"data": [], "ts": 0}
_CACHE_TTL = 3


def discover_features() -> list[FeatureDict]:
    """Discover all in-progress features by merging docs and session data.

    Uses a 3-second TTL cache to avoid repeated filesystem scans.
    """
    now = time.time()
    if now - _cache["ts"] < _CACHE_TTL and _cache["data"]:
        return _cache["data"]

    project_roots = get_project_roots()
    docs_features = _discover_from_docs(project_roots)
    session_features = _discover_from_sessions()
    features = _merge_features(docs_features, session_features)

    plans_by_root = _collect_plans_by_root(features)
    _apply_plan_link(features, plans_by_root)

    # Run stuck detection on all active sessions
    _apply_stuck_detection(features)

    # Mark autopilot features
    _mark_autopilot_features(features)

    # Sort by status urgency
    features.sort(key=lambda f: _STATUS_ORDER.get(f.get("status", ""), 99))

    _cache["data"] = features
    _cache["ts"] = now
    return features


_STATUS_ORDER = {
    "stuck": 0,
    "waiting": 1,
    "active": 2,
    "paused": 3,
    "done": 4,
}


def _canonical_project_root(path: str) -> str:
    """Return the main repo path for a project directory.

    A secondary git worktree's `.git` is a regular file containing
    `gitdir: <main>/.git/worktrees/<name>`. This helper resolves such a
    pointer to the main repo path. Main worktrees and non-git utility
    directories are returned unchanged. Used so that docs- and
    sessions-discovery key features under the main repo regardless of
    whether the path on disk is the main checkout or a worktree.
    """
    p = Path(path)
    git = p / ".git"
    if not git.is_file():
        return str(p)
    try:
        line = git.read_text(encoding="utf-8").splitlines()[0]
    except (OSError, IndexError):
        return str(p)
    if not line.startswith("gitdir:"):
        return str(p)
    gitdir = Path(line[len("gitdir:"):].strip())
    parts = gitdir.parts
    if ".git" not in parts:
        return str(p)
    git_idx = parts.index(".git")
    if git_idx == 0:
        return str(p)
    return str(Path(*parts[:git_idx]))


def _collect_plans_by_root(
    features: list[FeatureDict],
) -> dict[str, list[dict]]:
    """Build a per-canonical-root plan dict, calling find_plans at most once per root.

    Iterates features, canonicalises each project_root, and invokes
    plan_helpers.find_plans exactly once per unique canonical key (REQ-5).
    On any exception from find_plans, stores [] under that key so a
    subsequent feature under the same root falls through the REQ-3 path
    without retrying find_plans (REQ-4).
    """
    result: dict[str, list[dict]] = {}
    for feat in features:
        key = _canonical_project_root(feat.get("project_root", ""))
        if key in result:
            continue
        try:
            result[key] = plan_helpers.find_plans(key)
        except Exception as e:
            logger.warning(
                "_collect_plans_by_root: find_plans raised root=%s exc=%s",
                key, e,
            )
            result[key] = []
    return result


def _apply_plan_link(
    features: list[FeatureDict],
    plans_by_root: dict[str, list[dict]],
) -> None:
    """Mutate features in place: set plan_dir and plan_task_id when a match is found.

    For each feature, walks plans_by_root[canonical_root] in iteration
    order (alphabetical from sorted(docs_dir.iterdir()) — AS-2 / EC-5
    first-match semantics) and stops on the first plan whose find_task
    returns a task. Leaves both keys absent when no match is found.
    Callers must not rely on the absence of these keys before this call.
    """
    for feat in features:
        canonical = _canonical_project_root(feat.get("project_root", ""))
        plans = plans_by_root.get(canonical, [])
        for plan in plans:
            task = plan_helpers.find_task(plan["plan"], feat["name"])
            if task is None:
                continue
            feat["plan_dir"] = str(Path(plan["path"]).parent)
            feat["plan_task_id"] = task.get("id", "")
            task_name = task.get("name", "")
            if task_name and task_name != feat["name"]:
                feat["plan_task_name"] = task_name
            # Surface the planner's hour estimate so Run Economy / sidebar
            # can render estimate-vs-actual without a second hop through
            # /api/plan. lines_estimate stays plan-internal — it's a
            # planning heuristic, not a comparable runtime metric.
            estimate = task.get("estimate") or {}
            duration_hours = estimate.get("duration_hours")
            if isinstance(duration_hours, (int, float)) and duration_hours > 0:
                feat["plan_task_estimate_hours"] = duration_hours
            break


def _match_lifecycle_prefix(name: str) -> tuple[str, str] | None:
    """Map a directory name to its (prefix, lifecycle) pair, or None."""
    for prefix, lifecycle in LIFECYCLE_PREFIXES:
        if name.startswith(prefix):
            return prefix, lifecycle
    return None


def _done_at_iso(entry: Path) -> str | None:
    """Return UTC ISO 8601 mtime of `entry` or None on OSError.

    Used only for DONE_Feature_*/ directories. The mtime is approximate
    (RSK-D in the host plan: git checkout resets mtime), so callers
    must not surface this value as authoritative.
    """
    try:
        mtime = entry.stat().st_mtime
    except OSError:
        return None
    return datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()


def _discover_from_docs(project_roots: list[str]) -> dict[str, FeatureDict]:
    """Scan PENDING/INPROGRESS/DONE_Feature_*/ in all project roots."""
    features: dict[str, FeatureDict] = {}
    for root in project_roots:
        _scan_docs_dir(root, features)
    return features


def _scan_docs_dir(root: str, features: dict[str, FeatureDict]) -> None:
    """Scan a single project root's docs/ for feature directories.

    Iterates PENDING_Feature_*/, INPROGRESS_Feature_*/, and DONE_Feature_*/
    via LIFECYCLE_PREFIXES dispatch. On cross-lifecycle prefix collision
    under one canonical root, lower LIFECYCLE_PRECEDENCE wins
    (inprogress > done > pending). On equal-precedence collision (e.g.,
    main + worktree both INPROGRESS), the artifact-richer row wins so the
    worktree's full artifact list dominates main's anchor stub.
    """
    docs_dir = Path(root) / "docs"
    if not docs_dir.is_dir():
        return

    canonical_root = _canonical_project_root(root)
    try:
        entries = list(docs_dir.iterdir())
    except OSError:
        # EC-2 fail-silent on PermissionError, mirroring _discover_from_sessions.
        return

    for entry in entries:
        if not entry.is_dir():
            continue
        match = _match_lifecycle_prefix(entry.name)
        if match is None:
            continue
        prefix, lifecycle = match
        feature_name = entry.name[len(prefix):]
        if not feature_name:
            continue
        new_feat = _build_docs_feature(
            canonical_root, entry, feature_name, lifecycle,
        )
        key = f"{canonical_root}:{feature_name}"
        existing = features.get(key)
        if existing is None:
            features[key] = new_feat
            continue
        existing_rank = LIFECYCLE_PRECEDENCE[existing["lifecycle"]]
        new_rank = LIFECYCLE_PRECEDENCE[lifecycle]
        if new_rank < existing_rank:
            features[key] = new_feat
        elif new_rank == existing_rank:
            if len(new_feat["artifacts"]) > len(existing["artifacts"]):
                features[key] = new_feat
        # else: existing wins by precedence, drop new


def _build_docs_feature(
    root: str, entry: Path, feature_name: str, lifecycle: str,
) -> FeatureDict:
    """Build a FeatureDict from a single docs/<lifecycle>_Feature_*/ directory.

    `lifecycle` ∈ {"inprogress", "done", "pending"} drives per-lifecycle
    field assignment for `phase`, `phase_index`, `status`, and `done_at`.
    """
    try:
        files = {f.name for f in entry.iterdir()}
    except OSError:
        files = set()

    pipeline_type = "full" if ("TEAM_REVIEW.md" in files or "TEAM_QA.md" in files) else "light"
    artifacts = [{"name": af, "file": af} for af in FEATURE_ARTIFACT_ALLOWLIST if af in files]

    if lifecycle == "inprogress":
        phase_info = detect_flow_phase(root, f"feature/{feature_name}")
        phase = phase_info.get("phase", "started") if phase_info else "started"
        phase_index = phase_info.get("phase_index", 0) if phase_info else 0
        total_phases = (
            phase_info.get("total_phases", len(FLOW_PHASES_FULL))
            if phase_info
            else len(FLOW_PHASES_FULL)
        )
        status = "paused"
        done_at: str | None = None
    elif lifecycle == "done":
        phase = "done"
        total_phases = len(FLOW_PHASES_FULL)
        phase_index = total_phases
        status = "done"
        done_at = _done_at_iso(entry)
    else:  # pending
        phase = "started"
        phase_index = 0
        total_phases = len(FLOW_PHASES_FULL)
        status = "paused"
        done_at = None

    return FeatureDict(
        name=feature_name,
        project=Path(root).name,
        project_root=root,
        phase=phase,
        phase_index=phase_index,
        total_phases=total_phases,
        pipeline_type=pipeline_type,
        artifacts=artifacts,
        sessions=[],
        status=status,
        stuck_info=None,
        last_activity=None,
        is_autopilot=False,
        lifecycle=lifecycle,
        done_at=done_at,
    )


def _discover_from_sessions() -> dict[str, dict]:
    """Extract feature branches from sessions.jsonl."""
    data_dir = os.environ.get("DASHBOARD_DATA_DIR", "")
    if data_dir:
        jsonl_path = Path(data_dir) / "sessions.jsonl"
    else:
        jsonl_path = Path(__file__).resolve().parent.parent / "data" / "sessions.jsonl"

    features: dict[str, dict] = {}
    if not jsonl_path.is_file():
        return features

    try:
        lines = jsonl_path.read_text(encoding="utf-8").strip().splitlines()
    except Exception:
        return features

    for line in lines:
        entry = _parse_session_line(line)
        if entry is not None:
            _integrate_session_entry(entry, features)

    return features


_EXCLUDE_PATTERNS = (".test-tmp", "/tmp/", "/test-project")

_SESSION_STATUS_MAP = {
    "SessionEnd": "completed",
    "Stop": "completed",
    "TaskCompleted": "needs_input",
    "PermissionRequest": "needs_input",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "Notification": "working",
    "SubagentStart": "working",
}


def _parse_session_line(line: str) -> dict | None:
    """Parse a JSONL line, returning the entry if it's a feature branch event."""
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        return None

    branch = entry.get("branch", "")
    if not branch.startswith("feature/"):
        return None

    cwd = entry.get("cwd", "")
    if any(p in cwd for p in _EXCLUDE_PATTERNS):
        return None

    return entry


def _integrate_session_entry(entry: dict, features: dict[str, dict]) -> None:
    """Integrate a single session event into the features dict."""
    branch = entry["branch"]
    feature_name = branch[len("feature/"):]
    sid = entry.get("sid", "")
    ts = entry.get("ts", "")
    event = entry.get("event", "")
    cwd = entry.get("cwd", "")

    project_root = _guess_project_root(cwd)
    feature_key = f"{project_root}:{feature_name}"

    if feature_key not in features:
        features[feature_key] = {
            "name": feature_name,
            "project": Path(project_root).name if project_root else "",
            "project_root": project_root or cwd,
            "sessions": {},
            "last_activity": ts,
            "events": [],
        }

    feat = features[feature_key]
    _update_session_tracking(feat, sid, ts, event)
    feat["events"].append(entry)


def _update_session_tracking(feat: dict, sid: str, ts: str, event: str) -> None:
    """Update session tracking and last activity for a feature."""
    if sid and sid not in feat["sessions"]:
        feat["sessions"][sid] = {"sid": sid, "status": "working", "last_ts": ts}
    elif sid:
        feat["sessions"][sid]["last_ts"] = ts

    if ts and (not feat["last_activity"] or ts > feat["last_activity"]):
        feat["last_activity"] = ts

    if not sid or sid not in feat["sessions"]:
        return

    new_status = _SESSION_STATUS_MAP.get(event)
    if new_status:
        feat["sessions"][sid]["status"] = new_status


def _guess_project_root(cwd: str) -> str:
    """Guess project root from a cwd path.

    Returns the canonical main repo path: the first path segment under
    PROJECTS_ROOT, resolved through `_canonical_project_root` so that a
    secondary worktree maps back to the main repo. This guarantees
    session events from a worktree key under the same project root as
    docs-discovery, eliminating duplicate rows in /api/features.
    """
    projects_root = os.environ.get("PROJECTS_ROOT", str(Path.home() / "Projekter"))
    if cwd.startswith(projects_root + "/"):
        relative = cwd[len(projects_root) + 1:]
        top_dir = relative.split("/")[0]
        candidate = os.path.join(projects_root, top_dir)
        return _canonical_project_root(candidate)
    return cwd


def _merge_features(
    docs_features: dict[str, FeatureDict],
    session_features: dict[str, dict],
) -> list[FeatureDict]:
    """Merge docs-based and session-based discoveries."""
    result: dict[str, FeatureDict] = {}

    # Start with docs features
    for key, feat in docs_features.items():
        result[key] = feat

    # Merge or add session features
    for key, sfeat in session_features.items():
        sessions_list = list(sfeat.get("sessions", {}).values())
        events = sfeat.get("events", [])

        if key in result:
            # Merge: docs wins for phase/artifacts, sessions win for activity
            result[key]["sessions"] = sessions_list
            result[key]["last_activity"] = sfeat.get("last_activity")
            result[key]["_events"] = events  # type: ignore[typeddict-unknown-key]
        else:
            # Session-only feature: skip if worktree has been removed.
            # After /done, worktree directories are deleted but old events
            # remain in sessions.jsonl — those features are no longer active.
            project_root = sfeat.get("project_root", "")
            if not project_root or not Path(project_root).is_dir():
                continue
            result[key] = FeatureDict(
                name=sfeat["name"],
                project=sfeat.get("project", ""),
                project_root=sfeat.get("project_root", ""),
                phase="started",
                phase_index=0,
                total_phases=len(FLOW_PHASES_FULL),
                pipeline_type="full",
                artifacts=[],
                sessions=sessions_list,
                status="active",
                stuck_info=None,
                last_activity=sfeat.get("last_activity"),
                is_autopilot=False,
                lifecycle="inprogress",
                done_at=None,
            )
            result[key]["_events"] = events  # type: ignore[typeddict-unknown-key]

    # Derive status for all features
    for feat in result.values():
        feat["status"] = _derive_feature_status(feat)

    return list(result.values())


def _derive_feature_status(feature: FeatureDict) -> str:
    """Derive overall status from session data."""
    if feature.get("lifecycle") == "done":
        return "done"

    sessions = feature.get("sessions", [])
    if not sessions:
        return "paused"

    if feature.get("phase") == "done":
        return "done"

    # Check for stuck (set later by _apply_stuck_detection)
    if feature.get("stuck_info"):
        return "stuck"

    # Check session statuses
    has_working = any(s.get("status") == "working" for s in sessions)
    has_needs_input = any(s.get("status") == "needs_input" for s in sessions)
    has_active = has_working or has_needs_input

    if has_needs_input and not has_working:
        return "waiting"
    if has_working:
        return "active"
    if not has_active:
        # All sessions completed
        return "paused"

    return "paused"


def _apply_stuck_detection(features: list[FeatureDict]) -> None:
    """Run stuck detection on features with active sessions."""
    for feat in features:
        events = feat.pop("_events", [])  # type: ignore[misc]
        if not events:
            continue

        session_ids = [s["sid"] for s in feat.get("sessions", [])]
        if not session_ids:
            continue

        stuck = detect_stuck_sessions(events, session_ids)
        if stuck:
            # Take the first stuck session's info
            first_stuck = next(iter(stuck.values()))
            feat["stuck_info"] = dict(first_stuck)
            feat["status"] = "stuck"


def _apply_autopilot_phase_progress(feat: FeatureDict, autopilot: dict) -> None:
    """Override file-based phase_index with the live autopilot phase
    count. The file-based detect_flow_phase scan reads artifact files
    in docs/INPROGRESS_Feature_*/, which lag the autopilot stream by
    1+ phases (artifacts are typically written at phase end). The
    autopilot session's `phases` list is the authoritative current
    state — count completed phases for the new index, capped at
    total_phases so we never claim more progress than exists.

    Empty `phases` (autopilot just started, no events yet) leaves the
    file-based index untouched so the card has *some* signal.
    """
    feat["is_autopilot"] = True
    phases = autopilot.get("phases") or []
    completed = sum(1 for p in phases if p.get("status") == "completed")
    if not phases:
        return
    total = feat.get("total_phases") or len(FLOW_PHASES_FULL)
    feat["phase_index"] = min(completed, total)


def _mark_autopilot_features(features: list[FeatureDict]) -> None:
    """Mark features that have autopilot streams and override their
    phase_index with the live phase count from the autopilot session."""
    try:
        autopilots = discover_autopilots()
    except Exception:
        return

    by_task = {ap.get("task", ""): ap for ap in autopilots if ap.get("task")}

    for feat in features:
        ap = by_task.get(feat["name"])
        if ap is not None:
            _apply_autopilot_phase_progress(feat, ap)
