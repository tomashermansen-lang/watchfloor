"""Session state derivation from JSONL data.

Contains the canonical session-state derivation algorithm.
Both this module and index.html's stateManager must follow the same spec.

Canonical algorithm:
- Group events by sid (session ID)
- For each sid, take the latest event
- Derive status from event type and timing:
  - completed: latest event is "Stop" or "SessionEnd"
  - needs_input: "TaskCompleted" (turn finished, awaiting input) or "PermissionRequest"
  - working: any other event < 5 min old (Notification, SubagentStart/Stop, tool use, etc.)
  - idle: any other event > 5 min old
- Augment with worktree discovery: any worktree+branch not in JSONL gets a "stale" entry
"""

import json
import os
import subprocess
from datetime import UTC, datetime
from pathlib import Path

# Phase sequences per pipeline type (determined by which review artifact exists)
FLOW_PHASES_FULL = [
    "ba",
    "plan",
    "team-review",
    "implement",
    "static-analysis",
    "manualtest",
    "team-qa",
    "commit",
    "done",
]
FLOW_PHASES_LIGHT = ["ba", "plan", "review", "implement", "static-analysis", "qa", "commit", "done"]
# Legacy fallback for sessions without clear pipeline type
FLOW_PHASES = FLOW_PHASES_FULL


def _data_dir() -> Path:
    """Resolve the dashboard data directory.

    Honors ``DASHBOARD_DATA_DIR`` (consistent with metrics_helpers and
    feature_helpers); falls back to ``<repo>/dashboard/data/`` when unset.
    """
    override = os.environ.get("DASHBOARD_DATA_DIR")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent / "data"


def _resolve_worktree_root(cwd: str) -> str | None:
    """Resolve a cwd to its git worktree root. Returns None if not a git repo."""
    if not cwd or not os.path.isabs(cwd) or ".." in cwd:
        return None
    resolved = Path(cwd).resolve()
    if not resolved.is_dir():
        return None
    try:
        result = subprocess.run(
            ["git", "-C", str(resolved), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return None


def _detect_flow_phase(worktree_root: str, branch: str) -> dict | None:
    """Detect flow phase for the feature on this branch.

    Returns {feature, phase, phase_index, total_phases} or None.
    """
    if not worktree_root or not branch:
        return None
    # Feature name is typically the branch suffix: feature/foo → foo
    feature = branch.rsplit("/", 1)[-1] if "/" in branch else branch
    if feature in ("main", "master", "develop"):
        return None

    docs_dir = Path(worktree_root) / "docs"
    if not docs_dir.is_dir():
        # Check parent (main worktree) for DONE_ markers
        try:
            result = subprocess.run(
                ["git", "-C", worktree_root, "worktree", "list", "--porcelain"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if line.startswith("worktree "):
                        main_root = line[len("worktree ") :]
                        main_docs = Path(main_root) / "docs"
                        if main_docs.is_dir():
                            docs_dir = main_docs
                            break
        except Exception:
            pass

    if not docs_dir.is_dir():
        return None

    # Check for DONE_ prefix first (with Feature_ type segment per convention)
    for prefix in (f"DONE_Feature_{feature}", f"DONE_{feature}"):
        if (docs_dir / prefix).is_dir():
            # Check done dir for pipeline type
            done_dir = docs_dir / prefix
            done_files = {f.name for f in done_dir.iterdir()} if done_dir.is_dir() else set()
            is_full = "TEAM_REVIEW.md" in done_files or "TEAM_QA.md" in done_files
            phases = FLOW_PHASES_FULL if is_full else FLOW_PHASES_LIGHT
            return {
                "feature": feature,
                "phase": "done",
                "phase_index": len(phases) - 1,
                "total_phases": len(phases),
            }

    # Check for feature docs directory (convention: INPROGRESS_Feature_<name>)
    target_dir = None
    for candidate in (
        f"INPROGRESS_Feature_{feature}",
        f"INPROGRESS_{feature}",
        feature,
    ):
        if (docs_dir / candidate).is_dir():
            target_dir = docs_dir / candidate
            break

    if not target_dir:
        return {
            "feature": feature,
            "phase": "started",
            "phase_index": 0,
            "total_phases": len(FLOW_PHASES_FULL),
        }

    # Determine phase from which files exist
    has = set()
    try:
        for f in target_dir.iterdir():
            has.add(f.name)
    except Exception:
        return {
            "feature": feature,
            "phase": "unknown",
            "phase_index": 0,
            "total_phases": len(FLOW_PHASES_FULL),
        }

    # Detect pipeline type: TEAM_REVIEW.md → full, REVIEW.md → light
    is_full = "TEAM_REVIEW.md" in has or "TEAM_QA.md" in has
    is_light = not is_full and "REVIEW.md" in has
    phases = FLOW_PHASES_LIGHT if is_light else FLOW_PHASES_FULL
    total = len(phases)

    # Determine current phase from artifact presence
    if "TEAM_QA.md" in has:
        phase, idx = "team-qa", phases.index("team-qa") if "team-qa" in phases else total - 2
    elif "MANUAL_TEST_LOG.md" in has:
        phase, idx = (
            "manualtest",
            phases.index("manualtest") if "manualtest" in phases else total - 3,
        )
    elif "STATIC_ANALYSIS.md" in has:
        phase, idx = (
            "static-analysis",
            phases.index("static-analysis") if "static-analysis" in phases else 4,
        )
    elif "TESTPLAN.md" in has:
        phase, idx = "implement", phases.index("implement") if "implement" in phases else 3
    elif "TEAM_REVIEW.md" in has:
        phase, idx = "team-review", phases.index("team-review") if "team-review" in phases else 2
    elif "REVIEW.md" in has:
        phase, idx = "review", phases.index("review") if "review" in phases else 2
    elif "PLAN.md" in has:
        phase, idx = "plan", phases.index("plan") if "plan" in phases else 1
    elif "DESIGN.md" in has:
        phase, idx = "design", 1
    elif "REQUIREMENTS.md" in has:
        phase, idx = "ba", 0
    else:
        phase, idx = "started", 0

    return {"feature": feature, "phase": phase, "phase_index": idx, "total_phases": total}


def _discover_worktrees(repo_root: str) -> list[dict]:
    """Return [{path, branch}] for all worktrees in a repo."""
    try:
        result = subprocess.run(
            ["git", "-C", repo_root, "worktree", "list", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return []
        worktrees: list[dict] = []
        current: dict = {}
        for line in result.stdout.splitlines():
            if line.startswith("worktree "):
                if current and "path" in current:
                    worktrees.append(current)
                current = {"path": line[len("worktree ") :]}
            elif line.startswith("branch "):
                if current:
                    current["branch"] = line[len("branch ") :]
        if current and "path" in current:
            worktrees.append(current)
        return worktrees
    except Exception:
        return []


def _derive_status(event: str, entry_type: str, ts: str, now) -> str:
    """Derive session status from a single JSONL event."""
    if event == "SessionEnd":
        return "completed"
    if event == "Stop":
        return "needs_input"
    if event == "TaskCompleted":
        return "needs_input"
    if event in ("Notification", "PermissionRequest") and "user" in entry_type.lower():
        return "needs_input"
    if event == "PermissionRequest":
        return "needs_input"
    # PreToolUse with no PostToolUse following: if >10s, likely a permission dialog
    if event == "PreToolUse":
        try:
            event_time = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            age_seconds = (now - event_time).total_seconds()
            return "needs_input" if age_seconds > 10 else "working"
        except (ValueError, TypeError):
            return "working"
    # All other events: use age to distinguish working vs idle
    try:
        event_time = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        age_seconds = (now - event_time).total_seconds()
        return "idle" if age_seconds > 300 else "working"
    except (ValueError, TypeError):
        return "working"


# Perf bound (dashboard-perf 2026-06-02 #4): sessions.jsonl is an append-only
# log that grows without bound across all projects. get_session_activity is
# polled on every dashboard refresh and only needs the most recent events, so
# it reads at most this many trailing bytes instead of the whole file.
_ACTIVITY_TAIL_BYTES = 1_048_576  # 1 MiB


def _read_tail_lines(path: Path, max_bytes: int) -> list[str]:
    """Return the file's trailing lines within ``max_bytes``.

    Reads only the last ``max_bytes`` bytes. When the file exceeds the budget
    the first (partial) line is dropped so callers never parse a truncated
    record. For files smaller than the budget every line is returned, so the
    behaviour is byte-identical to a full ``read_text().strip().splitlines()``.
    """
    try:
        size = path.stat().st_size
        start = max(0, size - max_bytes)
        with path.open("rb") as fh:
            fh.seek(start)
            raw = fh.read()
    except OSError:
        return []
    text = raw.decode("utf-8", errors="replace")
    if start > 0:
        nl = text.find("\n")
        text = text[nl + 1 :] if nl != -1 else ""
    return text.strip().splitlines()


def get_session_activity(feature: str, since: str | None = None, limit: int = 50) -> list[dict]:
    """Return recent tool-call events for sessions matching a feature branch.

    Scans sessions.jsonl for PreToolUse/PostToolUse events on branches
    ending with the given feature name (e.g., feature/absence-analytics
    matches 'absence-analytics'). Returns events newest-first.

    Args:
        feature: Task/feature name to match against branch suffix.
        since: Optional ISO 8601 timestamp; only return events after this.
        limit: Max events to return (default 50).

    Returns:
        List of {event, type, msg, ts, branch, sid} dicts, newest first.
    """
    data_dir = _data_dir()
    jsonl_path = data_dir / "sessions.jsonl"

    if not jsonl_path.is_file() or not feature:
        return []

    # Parse since timestamp
    since_dt = None
    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
        except ValueError:
            pass

    _EXCLUDE_PATTERNS = (".test-tmp", "/tmp/", "/test-project")
    # Only keep tool-use events (the ones that show actual work)
    _TOOL_EVENTS = {"PreToolUse", "PostToolUse"}

    matches: list[dict] = []
    # Perf (#4): bounded trailing read, not a full-file read on every poll.
    lines = _read_tail_lines(jsonl_path, _ACTIVITY_TAIL_BYTES)

    for line in reversed(lines):
        if len(matches) >= limit:
            break
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        event = entry.get("event", "")
        if event not in _TOOL_EVENTS:
            continue

        branch = entry.get("branch", "")
        branch_feature = branch.rsplit("/", 1)[-1] if "/" in branch else branch
        if branch_feature != feature:
            continue

        cwd_val = entry.get("cwd", "")
        if any(p in cwd_val for p in _EXCLUDE_PATTERNS):
            continue

        ts = entry.get("ts", "")
        if since_dt and ts:
            try:
                event_dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if event_dt <= since_dt:
                    break  # Past events are older, stop scanning
            except ValueError:
                continue

        # Only keep PreToolUse (avoids duplicates with PostToolUse)
        if event != "PreToolUse":
            continue

        tool_type = entry.get("type", "")
        msg = entry.get("msg", "")

        # Extract useful info from msg (first 200 chars of JSON params)
        summary = ""
        if msg:
            try:
                params = json.loads(msg)
                if tool_type == "Read":
                    summary = params.get("file_path", "")
                elif tool_type == "Edit":
                    summary = params.get("file_path", "")
                elif tool_type == "Write":
                    summary = params.get("file_path", "")
                elif tool_type == "Bash":
                    cmd = params.get("command", "")
                    summary = cmd[:120]
                elif tool_type == "Grep":
                    summary = params.get("pattern", "")
                elif tool_type == "Glob":
                    summary = params.get("pattern", "")
                else:
                    summary = msg[:120]
            except (json.JSONDecodeError, TypeError):
                summary = msg[:120]

        matches.append(
            {
                "tool": tool_type,
                "summary": summary,
                "ts": ts,
                "sid": entry.get("sid", ""),
            }
        )

    return matches


def get_session_states() -> list[dict]:
    """Read sessions.jsonl and derive current session states.

    Augments JSONL-derived sessions with worktree discovery so that
    all active worktrees always appear, even without recent hook events.

    Returns array of {sid, cwd, worktree, branch, event, type, msg, ts, status, flow}.
    """
    data_dir = _data_dir()
    jsonl_path = data_dir / "sessions.jsonl"

    # Patterns that indicate test/temp sessions to exclude
    _EXCLUDE_PATTERNS = (".test-tmp", "/tmp/", "/test-project")

    latest_by_sid: dict[str, dict] = {}
    if jsonl_path.is_file():
        try:
            lines = jsonl_path.read_text(encoding="utf-8").strip().splitlines()
        except Exception:
            lines = []

        # Read ALL lines (file maxes at 1MB via rotation)
        for line in lines:
            try:
                entry = json.loads(line)
                sid = entry.get("sid", "")
                if not sid:
                    continue
                cwd_val = entry.get("cwd", "")
                if any(p in cwd_val for p in _EXCLUDE_PATTERNS):
                    continue
                latest_by_sid[sid] = entry
            except json.JSONDecodeError:
                continue

    # Cache worktree resolution and flow detection per cwd
    worktree_cache: dict[str, str | None] = {}
    flow_cache: dict[str, dict | None] = {}
    now = datetime.now(UTC)

    results = []
    # Track which worktree+branch combos we've seen from JSONL
    seen_wt_branch: set[str] = set()

    for sid, entry in latest_by_sid.items():
        event = entry.get("event", "")
        entry_type = entry.get("type", "")
        ts = entry.get("ts", "")
        cwd = entry.get("cwd", "")
        branch = entry.get("branch", "")

        status = _derive_status(event, entry_type, ts, now)

        # Resolve worktree root (cached)
        if cwd not in worktree_cache:
            worktree_cache[cwd] = _resolve_worktree_root(cwd)
        worktree = worktree_cache[cwd]

        # If worktree path no longer exists on disk, mark as closed
        if not Path(worktree or cwd).is_dir():
            status = "closed"

        # Detect flow phase (cached by worktree+branch)
        flow_key = f"{worktree or cwd}:{branch}"
        if flow_key not in flow_cache:
            flow_cache[flow_key] = _detect_flow_phase(worktree or cwd, branch)
        flow = flow_cache[flow_key]

        seen_wt_branch.add(f"{worktree or cwd}::{branch}")

        results.append(
            {
                "sid": sid,
                "cwd": cwd,
                "worktree": worktree or cwd,
                "branch": branch,
                "event": event,
                "type": entry_type,
                "msg": entry.get("msg", ""),
                "ts": ts,
                "status": status,
                "flow": flow,
            }
        )

    # Augment: discover worktrees from known repos and add stale entries
    # for any worktree+branch not already represented in JSONL
    seen_repos: set[str] = set()
    for r in results:
        wt = r.get("worktree", "")
        if wt:
            # Find the main repo root (first entry from worktree list)
            if wt not in seen_repos:
                seen_repos.add(wt)

    for repo_root in seen_repos:
        for wt_info in _discover_worktrees(repo_root):
            wt_path = wt_info.get("path", "")
            # branch from porcelain is refs/heads/foo — strip prefix, keep full name
            raw_branch = wt_info.get("branch", "")
            branch = (
                raw_branch.removeprefix("refs/heads/")
                if raw_branch.startswith("refs/heads/")
                else raw_branch
            )
            if not wt_path or not branch:
                continue
            key = f"{wt_path}::{branch}"
            if key in seen_wt_branch:
                continue
            seen_wt_branch.add(key)

            # Detect flow phase for this worktree
            flow_key = f"{wt_path}:{branch}"
            if flow_key not in flow_cache:
                flow_cache[flow_key] = _detect_flow_phase(wt_path, branch)
            flow = flow_cache[flow_key]

            results.append(
                {
                    "sid": f"wt-{branch}",
                    "cwd": wt_path,
                    "worktree": wt_path,
                    "branch": branch,
                    "event": "",
                    "type": "",
                    "msg": "",
                    "ts": "",
                    "status": "stale",
                    "flow": flow,
                }
            )

    # Deduplicate by worktree+branch, keeping the most recent entry
    deduped: dict[str, dict] = {}
    for r in results:
        key = f"{r['worktree']}::{r['branch']}"
        existing = deduped.get(key)
        if not existing or r["ts"] > existing["ts"]:
            deduped[key] = r
    return list(deduped.values())
