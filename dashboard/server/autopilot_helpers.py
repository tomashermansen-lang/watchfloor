"""Autopilot session discovery, log parsing, and incremental reading.

Functions: discover_autopilots, parse_log_phases, read_log_incremental,
load_summary, _resolve_log_path, _extract_cost, _parse_header.
"""

import json
import os
import re
import subprocess
import time
from pathlib import Path

# Configurable project root — override via PROJECTS_ROOT env var
PROJECTS_ROOT = Path(os.environ.get("PROJECTS_ROOT", str(Path.home() / "Projekter")))

# --- Canonical phase name constants ---
_PHASE_TEAM_REVIEW = "Team Review"
_PHASE_STATIC_ANALYSIS = "Static Analysis"
_PHASE_TEAM_QA = "Team QA"
_PHASE_TEST_PLAN = "Test Plan"
_PHASE_MANUAL_TEST = "Manual Test"
_PHASE_BA = "BA"
_PHASE_PLAN = "Plan"
_PHASE_REVIEW = "Review"
_PHASE_IMPLEMENT = "Implement"
_PHASE_QA = "QA"
_PHASE_COMMIT = "Commit"
_PHASE_DONE = "Done"
_PHASE_MERGE = "Merge"

# Phase name → artifact file mapping
PHASE_ARTIFACTS = {
    _PHASE_BA: "REQUIREMENTS.md",
    _PHASE_PLAN: "PLAN.md",
    _PHASE_TEAM_REVIEW: "TEAM_REVIEW.md",
    _PHASE_REVIEW: "REVIEW.md",
    _PHASE_STATIC_ANALYSIS: "STATIC_ANALYSIS.md",
    _PHASE_TEAM_QA: "TEAM_QA.md",
    _PHASE_QA: "QA_REPORT.md",
    _PHASE_TEST_PLAN: "TESTPLAN.md",
    _PHASE_IMPLEMENT: None,
    _PHASE_COMMIT: None,
    _PHASE_DONE: None,
    _PHASE_MERGE: None,
}

_TASK_RE = re.compile(r"^[a-zA-Z0-9_-]+$")
_ANSI_RE = re.compile(r"(?:\x1b|\\033)\[[0-9;?]*[A-Za-z]|\r")
_COST_RE = re.compile(r"\$(\d+\.\d+)")
_PHASE_START_RE = re.compile(r"Phase: ([^━]+)(?:\s*━|$)")
_SENDING_RE = re.compile(r"(?:Sending|Running): /(\S+) flow")
_PHASE_DONE_RE = re.compile(r"Phase completed in (\d+)s")
_CHECKPOINT_RE = re.compile(r"Phase checkpoint reached")

# Map slash commands to display phase names
_COMMAND_TO_PHASE = {
    "ba": _PHASE_BA,
    "plan": _PHASE_PLAN,
    "team-review": _PHASE_TEAM_REVIEW,
    "review": _PHASE_REVIEW,
    "implement": _PHASE_IMPLEMENT,  # also matches --step testplan via phase header
    "static-analysis": _PHASE_STATIC_ANALYSIS,
    "manualtest": _PHASE_MANUAL_TEST,
    "team-qa": _PHASE_TEAM_QA,
    "qa": _PHASE_QA,
    "commit": _PHASE_COMMIT,
    "done": _PHASE_MERGE,
}

# Map full phase names to canonical short names
_PHASE_NAME_NORMALIZE = {
    "Business Analysis": _PHASE_BA,
    "BA": _PHASE_BA,
    "Architecture Plan": _PHASE_PLAN,
    "Plan": _PHASE_PLAN,
    _PHASE_TEAM_REVIEW: _PHASE_TEAM_REVIEW,
    "Review": _PHASE_REVIEW,
    _PHASE_TEST_PLAN: _PHASE_TEST_PLAN,
    "Implementation (TDD)": _PHASE_IMPLEMENT,
    "Implement": _PHASE_IMPLEMENT,
    "Done": _PHASE_DONE,
    _PHASE_STATIC_ANALYSIS: _PHASE_STATIC_ANALYSIS,
    _PHASE_MANUAL_TEST: _PHASE_MANUAL_TEST,
    _PHASE_TEAM_QA: _PHASE_TEAM_QA,
    "QA": _PHASE_QA,
    "Commit": _PHASE_COMMIT,
    "Commit & Merge": _PHASE_COMMIT,
    "Merge": _PHASE_MERGE,
}

# Discovery cache
_discovery_cache = {"data": [], "ts": 0}
_DISCOVERY_TTL = 3  # seconds


def _extract_cost(line):
    """Extract first dollar amount from a log line. Returns float or None."""
    m = _COST_RE.search(line)
    return float(m.group(1)) if m else None


def _parse_header(log_lines):
    """Extract task, project, branch, mode from log header.

    Supports both ASCII-art box format (║ Task: X ║) and
    autopilot.sh timestamped format ([HH:MM:SS] Key: value).
    """
    result = {"task": None, "project": None, "branch": None, "mode": None}
    for line in log_lines:
        # Strip ASCII box chars and timestamps
        stripped = line.strip().strip("║").strip()
        # Strip [HH:MM:SS] timestamps
        stripped = re.sub(r"^\[\d{2}:\d{2}:\d{2}\]\s*", "", stripped)

        if stripped.startswith("Task:"):
            result["task"] = stripped[5:].strip()
        elif stripped.startswith("Autopilot started for task:"):
            result["task"] = stripped[len("Autopilot started for task:") :].strip()
        elif stripped.startswith("Project:"):
            result["project"] = stripped[8:].strip()
        elif stripped.startswith("Worktree:"):
            # Derive project name from worktree path
            wt_path = stripped[9:].strip()
            # e.g. /Users/.../OIH-two-layer-allocation → OIH
            dirname = wt_path.rstrip("/").rsplit("/", 1)[-1]
            # Remove task suffix: OIH-two-layer-allocation → OIH
            if result["task"] and dirname.endswith(f"-{result['task']}"):
                result["project"] = dirname[: -(len(result["task"]) + 1)]
            elif "-" in dirname:
                result["project"] = dirname.split("-")[0]
            else:
                result["project"] = dirname
        elif stripped.startswith("Branch:"):
            result["branch"] = stripped[7:].strip()
        elif stripped.startswith("Mode:") or stripped.startswith("Full mode:"):
            result["mode"] = stripped.split(":", 1)[1].strip()
    return result


def _try_match_sending(line):
    """Try to match a Sending/Running command line. Returns phase name or None."""
    m = _SENDING_RE.search(line)
    if not m:
        return None
    cmd = m.group(1)
    return _COMMAND_TO_PHASE.get(cmd, cmd.title())


def _finalize_phase_completion(current_phase, line):
    """Check for phase completion markers. Returns True if matched."""
    m = _PHASE_DONE_RE.search(line)
    if m:
        current_phase["duration_s"] = int(m.group(1))
        current_phase["status"] = "completed"
        return True
    if _CHECKPOINT_RE.search(line):
        current_phase["status"] = "completed"
        return True
    return False


def _create_phase_dict(phase_name):
    """Create a new phase dict with default values.

    The five token/turn keys are part of the always-present sidebar contract
    (audit-23 #5). The log-based parser path can't populate them (logs don't
    carry usage data) so they stay None — only the NDJSON stream parser fills
    them via `_assign_costs_to_phases`. Same applies to started_at + ended_at
    (audit-23 #2): only the stream parser sees `ts` on phase events.
    """
    return {
        "name": phase_name,
        "status": "running",
        "duration_s": None,
        "cost": None,
        "artifact": PHASE_ARTIFACTS.get(phase_name),
        "input_tokens": None,
        "cache_creation_tokens": None,
        "cache_read_tokens": None,
        "output_tokens": None,
        "num_turns": None,
        "started_at": None,
        "ended_at": None,
    }


def _process_log_line(line, phases, current_phase):
    """Process a single cleaned log line. Returns updated current_phase."""
    # Phase start — command format
    phase_name = _try_match_sending(line)
    if phase_name is not None:
        if current_phase and current_phase["name"] == phase_name:
            return current_phase
        current_phase = _create_phase_dict(phase_name)
        phases.append(current_phase)
        return current_phase

    if not current_phase:
        return current_phase

    # Phase completion markers
    if _finalize_phase_completion(current_phase, line):
        return current_phase

    # Cost extraction
    cost = _extract_cost(line)
    if cost is not None:
        current_phase["cost"] = cost

    # Task-level failure
    if "AUTOPILOT FAILED" in line and current_phase["status"] == "running":
        current_phase["status"] = "failed"

    return current_phase


def parse_log_phases(log_path):
    """Parse an autopilot log file for phase markers.

    Returns ordered list of phase dicts:
    [{name, status, duration_s, cost, artifact}, ...]
    """
    try:
        with open(log_path, encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError:
        return []

    if not content.strip():
        return []

    phases = []
    current_phase = None
    for raw_line in content.splitlines():
        line = _ANSI_RE.sub("", raw_line)
        current_phase = _process_log_line(line, phases, current_phase)

    return phases


def _handle_phase_event(event, phase_map, phases):
    """Process a phase-type event from an NDJSON stream. Mutates phase_map and phases.

    Captures `event["ts"]` into started_at on first sighting (status=running)
    and into ended_at on terminal status (completed | failed). The ts is
    written by autopilot.sh as ISO 8601 — we store it raw so the frontend
    decides format (audit-23 #2).
    """
    raw_name = event.get("phase", "")
    phase_name = _PHASE_NAME_NORMALIZE.get(raw_name, raw_name)
    status = event.get("status", "running")
    ts = event.get("ts")

    if phase_name not in phase_map:
        phase_dict = {
            "name": phase_name,
            "status": status,
            "duration_s": event.get("duration_s"),
            "cost": None,
            "artifact": PHASE_ARTIFACTS.get(phase_name),
            "input_tokens": None,
            "cache_creation_tokens": None,
            "cache_read_tokens": None,
            "output_tokens": None,
            "num_turns": None,
            "started_at": ts if status == "running" else None,
            "ended_at": ts if status in ("completed", "failed") else None,
        }
        phase_map[phase_name] = phase_dict
        phases.append(phase_dict)
        return

    existing = phase_map[phase_name]
    if status == "completed":
        existing["status"] = "completed"
        if event.get("duration_s") is not None:
            existing["duration_s"] = event["duration_s"]
        if ts is not None:
            existing["ended_at"] = ts
    elif status == "failed":
        existing["status"] = "failed"
        if ts is not None:
            existing["ended_at"] = ts


def _parse_ndjson_events(content):
    """Parse NDJSON content into a list of event dicts, skipping malformed lines."""
    events = []
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def _credit_result_to_phase(phase, result):
    """Add a result event's metrics to a phase dict.

    Cost handling is asymmetric from the other fields:

    - `total_cost_usd` is **cumulative per session_id**. A phase with
      multiple result events sharing one session (auto-resume after a
      "Continue?" checkpoint in /implement) reports e.g. $2.65 → $3.48
      → $3.68 across three segments. Summing those triple-counts the
      first segment. Fix: track max-per-session, then sum across distinct
      sessions when rendering the phase total.
    - `num_turns` and the usage fields (input/output/cache_*_tokens) are
      **per-segment**. Summing them across all result events in the
      phase gives the right total. (Verified against canary G's
      /implement stream 2026-05-25.)

    Multi-agent phases (/team-review) and retries (failed /qa then
    success) each spawn distinct claude -p invocations with separate
    session_ids — those legitimately sum because each session has its
    own cumulative-cost domain. Phantom auto-resume segments share a
    session_id so they collapse to one max.

    Bug surfaced 2026-05-25 on canary G: dashboard showed /implement
    cost as $9.81 (sum of three cumulative values $2.65 + $3.48 + $3.68)
    while cost-summary.py correctly reported $3.68.

    Result events with no session_id are treated as distinct
    pseudo-sessions (preserves legacy behaviour for older streams or
    test stubs that omit the field).
    """
    usage = result.get("usage") or {}
    cost = result.get("total_cost_usd")
    if cost is not None:
        # Per-session max-cost tracking. _session_costs maps a session
        # key to that session's cumulative cost; phase["cost"] is the
        # sum across distinct sessions. The leading underscore marks
        # this as an internal accumulator — consumers read phase["cost"].
        if "_session_costs" not in phase:
            phase["_session_costs"] = {}
        # Missing session_id → synthesise a unique pseudo-session key so
        # legacy streams without sids keep the old sum semantics.
        sid = result.get("session_id")
        if not sid:
            sid = f"__anon_{len(phase['_session_costs'])}__"
        prior = phase["_session_costs"].get(sid, 0)
        # cost is cumulative within a session, so take max.
        if cost > prior:
            phase["_session_costs"][sid] = cost
        phase["cost"] = round(sum(phase["_session_costs"].values()), 2)
    if "input_tokens" in usage:
        phase["input_tokens"] = (phase["input_tokens"] or 0) + usage["input_tokens"]
    if "cache_creation_input_tokens" in usage:
        phase["cache_creation_tokens"] = (phase["cache_creation_tokens"] or 0) + usage[
            "cache_creation_input_tokens"
        ]
    if "cache_read_input_tokens" in usage:
        phase["cache_read_tokens"] = (phase["cache_read_tokens"] or 0) + usage[
            "cache_read_input_tokens"
        ]
    if "output_tokens" in usage:
        phase["output_tokens"] = (phase["output_tokens"] or 0) + usage["output_tokens"]
    if result.get("num_turns") is not None:
        phase["num_turns"] = (phase["num_turns"] or 0) + result["num_turns"]


def parse_stream_phases(stream_path):
    """Parse phase events from an NDJSON stream file.

    Returns ordered list of phase dicts compatible with parse_log_phases output.
    Merges running+completed events for the same phase into one entry.

    Result events are attributed CHRONOLOGICALLY: each result is credited
    to the phase whose `running` event most recently preceded it in the
    stream. A phase that emits multiple result events (e.g. multi-agent
    /team-review) sums them — each result is a separate claude -p call
    with independent num_turns/cost/tokens.

    Pre-fix the attribution walked phases in REVERSE order per result, so
    result#0 hit phases[-1], result#1 hit phases[-2], etc. — every phase
    got its temporally-mirrored sibling's data. Bug surfaced once token
    + turn fields were added (audit-23 #5) since cost-only outputs hid
    the symmetry.
    """
    try:
        with open(stream_path, encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError:
        return []

    phases = []
    phase_map = {}
    current_phase_name = None

    for event in _parse_ndjson_events(content):
        event_type = event.get("type")
        # lifecycle events are emitted by autopilot.sh/chain.sh — see
        # dashboard/server/lifecycle_events.py. They are additive and
        # have no phase/result semantics; skip them explicitly.
        if event_type == "lifecycle":
            continue
        if event_type == "phase":
            raw_name = event.get("phase", "")
            phase_name = _PHASE_NAME_NORMALIZE.get(raw_name, raw_name)
            _handle_phase_event(event, phase_map, phases)
            # Track the active phase so subsequent result events attribute
            # to it. Latch on ANY phase event (running or completed) so
            # the attribution still works for streams that only carry
            # completion events (e.g. log-derived or repaired streams)
            # AND for the canonical running -> result -> completed flow.
            current_phase_name = phase_name
        elif event_type == "result":
            if current_phase_name is not None and current_phase_name in phase_map:
                _credit_result_to_phase(phase_map[current_phase_name], event)

    return phases


def _resolve_artifact_path(task, filename):
    """Find an artifact file in the task's feature folder.

    Searches docs/INPROGRESS_Feature_<task>/<filename> across all projects.
    Also checks DONE_ folders. Returns absolute path string or None.
    """
    if not _TASK_RE.match(task):
        return None

    roots = _get_all_project_roots()
    for prefix in ("INPROGRESS_Feature_", "DONE_Feature_"):
        for root in roots:
            candidate = Path(root) / "docs" / f"{prefix}{task}" / filename
            if candidate.is_file():
                # Security: resolve symlinks and validate under PROJECTS_ROOT
                resolved = candidate.resolve()
                if str(resolved).startswith(str(PROJECTS_ROOT) + "/"):
                    return str(resolved)
    return None


_KNOWN_ARTIFACTS = sorted(
    [
        "REQUIREMENTS.md",
        "PLAN.md",
        "DESIGN.md",
        "REVIEW.md",
        "TEAM_REVIEW.md",
        "STATIC_ANALYSIS.md",
        "TEAM_QA.md",
        "QA_REPORT.md",
        "TESTPLAN.md",
        "MANUAL_TEST_LOG.md",
    ]
)


def _find_feature_dir(task):
    """Find the feature directory for a task across all project roots.

    Returns the first matching feature dir (Path) or None.
    """
    roots = _get_all_project_roots()
    for prefix in ("INPROGRESS_Feature_", "DONE_Feature_"):
        for root in roots:
            feature_dir = Path(root) / "docs" / f"{prefix}{task}"
            if feature_dir.is_dir():
                return feature_dir
    return None


def list_autopilot_artifacts(task):
    """List available doc artifacts for an autopilot task.

    Searches docs/{INPROGRESS,DONE}_Feature_<task>/ across all project roots.
    Returns list of {"name": str, "file": str} dicts.
    """
    if not _TASK_RE.match(task):
        return []

    feature_dir = _find_feature_dir(task)
    if feature_dir is None:
        return []

    results = []
    for filename in _KNOWN_ARTIFACTS:
        if (feature_dir / filename).is_file():
            results.append({"name": filename, "file": filename})
    return results


def read_log_incremental(log_path, offset, max_tail_bytes=None):
    """Read log file from byte offset. Returns (content, new_offset) or None.

    Security: validates path is under PROJECTS_ROOT after resolving symlinks.
    Strips ANSI escape sequences and carriage returns from output.

    Perf (dashboard-perf 2026-06-02 #5): when ``max_tail_bytes`` is set and the
    initial (``offset == 0``) read would exceed it, only the trailing
    ``max_tail_bytes`` are read and the partial first line is dropped. This
    bounds the cold-load cost on multi-MB logs without changing the wire
    contract — ``new_offset`` still points at EOF so subsequent polls stream
    deltas exactly as before. Ignored once ``offset > 0``.
    """
    try:
        resolved = Path(log_path).resolve()
    except (OSError, ValueError):
        return None

    if not _is_allowed_path(resolved):
        return None

    if not resolved.is_file():
        return None

    try:
        with open(str(resolved), "rb") as f:
            start, drop_partial = _tail_start(f, offset, max_tail_bytes)
            f.seek(start)
            raw = f.read()
            new_offset = start + len(raw)
        content = raw.decode("utf-8", errors="replace")
        if drop_partial:
            content = _drop_partial_first_line(content)
        content = _ANSI_RE.sub("", content)
        return (content, new_offset)
    except OSError:
        return None


def _tail_start(file_obj, offset, max_tail_bytes):
    """Resolve the byte to seek to and whether the first line is partial.

    Returns ``(start, drop_partial)``. The tail window only applies to the
    initial read (``offset == 0``) and only when the file is larger than the
    budget; otherwise ``start == offset`` and nothing is dropped.
    """
    if offset == 0 and max_tail_bytes is not None and max_tail_bytes > 0:
        file_obj.seek(0, 2)  # SEEK_END
        size = file_obj.tell()
        if size > max_tail_bytes:
            return size - max_tail_bytes, True
    return offset, False


def _drop_partial_first_line(content):
    """Drop everything up to and including the first newline (a truncated
    record produced by seeking into the middle of the file)."""
    nl = content.find("\n")
    return content[nl + 1 :] if nl != -1 else ""


def _resolve_log_path(task, search_roots=None):
    """Find the log file for a task.

    Checks docs/INPROGRESS_Feature_<task>/autopilot.log across search roots.
    When no search_roots provided, scans all projects under PROJECTS_ROOT
    (not just the current git repo's worktrees) to support multi-project discovery.
    Falls back to /tmp/autopilot-<task>.log for backward compatibility.
    """
    if not _TASK_RE.match(task):
        return None

    # Search provided roots, or all project directories under PROJECTS_ROOT
    roots = search_roots or _get_all_project_roots()
    for prefix in ("INPROGRESS_Feature_", "DONE_Feature_"):
        for root in roots:
            candidate = Path(root) / "docs" / f"{prefix}{task}" / "autopilot.log"
            if candidate.is_file():
                return str(candidate)

    # Fallback to /tmp
    tmp_path = f"/tmp/autopilot-{task}.log"
    if os.path.isfile(tmp_path):
        return tmp_path

    return None


def _get_worktree_roots():
    """Get worktree roots from git. Returns list of paths."""
    try:
        result = subprocess.run(
            ["git", "worktree", "list", "--porcelain"], capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return []
        roots = []
        for line in result.stdout.splitlines():
            if line.startswith("worktree "):
                roots.append(line[len("worktree ") :])
        return roots
    except Exception:
        return []


def _get_all_project_roots():
    """Get all project directories under PROJECTS_ROOT.

    Scans top-level dirs (both main repos and worktrees) to support
    multi-project autopilot discovery — not limited to the current git repo.
    """
    projekter = PROJECTS_ROOT
    if not projekter.is_dir():
        return []
    try:
        return [str(d) for d in projekter.iterdir() if d.is_dir() and not d.name.startswith(".")]
    except OSError:
        return []


def _is_allowed_path(resolved_path):
    """Check if a resolved path is under PROJECTS_ROOT or test tmp dirs.

    Single source of truth for the path security allowlist used by both
    read_stream_incremental and read_log_incremental.

    macOS note: /var and /tmp are root-level symlinks to /private/var and
    /private/tmp. Path.resolve() always returns the canonical /private/...
    form, so both prefix shapes must be on the allowlist for the post-
    resolve check to succeed regardless of whether the caller's TMPDIR is
    /var/folders/... (default) or /tmp/... (Claude sandbox override).
    """
    resolved = str(resolved_path)
    if resolved.startswith(str(PROJECTS_ROOT) + "/"):
        return True
    tmp_prefixes = (
        "/tmp/",
        "/private/tmp/",
        "/var/folders/",
        "/private/var/folders/",
        "/private/var/tmp/",
    )
    return any(resolved.startswith(p) for p in tmp_prefixes)


def _status_from_log(log_path, now):
    """Determine autopilot status from text log file content and mtime."""
    try:
        with open(log_path, encoding="utf-8", errors="replace") as f:
            full_content = f.read()
    except OSError:
        return "completed"

    if "AUTOPILOT COMPLETE" in full_content:
        return "completed"
    if "AUTOPILOT FAILED" in full_content or "Stopping." in full_content:
        return "failed"

    try:
        mtime = Path(log_path).stat().st_mtime
        return "running" if now - mtime < 60 else "completed"
    except OSError:
        return "completed"


def _status_from_stream(stream_path, now):
    """Determine autopilot status from NDJSON stream file."""
    try:
        resolved = Path(stream_path).resolve()
        mtime = resolved.stat().st_mtime
    except OSError:
        return "completed"

    # Read only the tail of the file to check for failure markers
    try:
        with open(stream_path, "rb") as f:
            f.seek(0, 2)  # seek to end
            size = f.tell()
            read_size = min(size, 8192)  # 8KB is plenty for 20 JSON lines
            f.seek(size - read_size)
            tail = f.read().decode("utf-8", errors="replace")
        lines = tail.splitlines()
    except OSError:
        return "completed"

    for line in reversed(lines[-20:]):
        try:
            event = json.loads(line.strip())
        except ValueError:
            continue
        # lifecycle events are emitted by autopilot.sh/chain.sh — see
        # dashboard/server/lifecycle_events.py. Skip them so a paused
        # lifecycle record is not mis-classified as a failure marker.
        if event.get("type") == "lifecycle":
            continue
        if event.get("type") == "phase" and event.get("status") == "failed":
            return "failed"
        if event.get("type") == "result" and event.get("is_error"):
            return "failed"

    # If file was modified recently, still running
    if now - mtime < 60:
        return "running"

    return "completed"


def _extract_task_from_entry(entry):
    """Extract task name and done-status from a docs/ directory entry.

    Returns (task, is_done) or (None, None) if not a feature dir.
    """
    name = entry.name
    if name.startswith("INPROGRESS_Feature_"):
        return name[len("INPROGRESS_Feature_") :], False
    if name.startswith("DONE_Feature_"):
        return name[len("DONE_Feature_") :], True
    return None, None


def _read_log_header(log_file):
    """Read and parse header from a log file. Returns header dict."""
    if not log_file.is_file():
        return {}
    try:
        with open(str(log_file), encoding="utf-8", errors="replace") as f:
            return _parse_header(f.readlines()[:20])
    except OSError:
        return {}


def _force_done_phases(phases):
    """Force all running phases to completed status (for DONE features)."""
    for p in phases:
        if p["status"] == "running":
            p["status"] = "completed"


def _sum_phase_costs(phases):
    """Sum phase costs. Returns total or None if no costs recorded."""
    costs = [p["cost"] for p in phases if p["cost"] is not None]
    return sum(costs) if costs else None


def _build_session_dict(entry, task, is_done, root, now):
    """Build a session dict from a feature directory entry.

    Returns a session dict or None if no log/stream files exist.
    """
    stream_file = entry / "autopilot-stream.ndjson"
    log_file = entry / "autopilot.log"
    stream_exists = stream_file.is_file()
    log_exists = log_file.is_file()
    if not stream_exists and not log_exists:
        return None
    if not _TASK_RE.match(task):
        return None

    active_path = str(stream_file if stream_exists else log_file)

    phases = parse_stream_phases(active_path) if stream_exists else parse_log_phases(active_path)
    header = _read_log_header(log_file)

    if is_done:
        _force_done_phases(phases)

    return {
        "task": task,
        "project": header.get("project") or Path(root).name,
        "branch": header.get("branch"),
        "status": _determine_overall_status(is_done, stream_exists, active_path, now, phases),
        "phases": phases,
        "elapsed_s": sum(p["duration_s"] or 0 for p in phases),
        "cost": _sum_phase_costs(phases),
        "log_path": str(log_file) if log_exists else None,
        "stream_path": active_path if stream_exists else None,
    }


def _determine_overall_status(is_done, has_stream, active_path, now, phases):
    """Determine the overall autopilot session status.

    Audit-16 — phase data overrides the mtime-based 'completed' fallback.
    The autopilot wrapper can exit (file mtime stops advancing) while the
    underlying claude session is paused on a permission prompt; the
    stream still shows the last phase as 'running'. Reporting 'completed'
    in that state hides progress UI even though work is incomplete.
    Failure markers in the log/stream tail still win — they are explicit
    terminal signals.
    """
    if is_done:
        return "completed"
    base = (
        _status_from_stream(active_path, now) if has_stream else _status_from_log(active_path, now)
    )
    if base == "completed" and any(p.get("status") == "running" for p in phases):
        return "running"
    return base


def _scan_docs_dir(docs, root, now):
    """Scan a docs directory for autopilot feature entries. Returns list of session dicts."""
    try:
        entries = list(docs.iterdir())
    except OSError:
        return []

    sessions = []
    for entry in entries:
        task, is_done = _extract_task_from_entry(entry)
        if task is None:
            continue
        session = _build_session_dict(entry, task, is_done, root, now)
        if session is not None:
            sessions.append(session)
    return sessions


def discover_autopilots(_tmux_cmd=None):
    """Discover autopilot sessions by scanning for log and stream files.

    Returns list of session dicts with task, project, branch, status,
    phases, elapsed_s, cost, log_path, stream_path.

    Scans all projects under PROJECTS_ROOT for INPROGRESS_Feature_* and
    DONE_Feature_* directories containing autopilot-stream.ndjson or
    autopilot.log. Stream files take precedence for phase parsing.
    A session is 'running' if the file was modified in the last 60 seconds.

    _tmux_cmd parameter kept for test compatibility (ignored in v2).
    """
    now = time.time()
    if _tmux_cmd is None and now - _discovery_cache["ts"] < _DISCOVERY_TTL:
        return _discovery_cache["data"]

    sessions = []
    for root in _get_all_project_roots():
        docs = Path(root) / "docs"
        if docs.is_dir():
            sessions.extend(_scan_docs_dir(docs, root, now))

    sessions = _dedupe_worktree_copies(sessions)

    if _tmux_cmd is None:
        _discovery_cache["data"] = sessions
        _discovery_cache["ts"] = now

    return sessions


def _dedupe_worktree_copies(sessions):
    """Collapse worktree-copy duplicates while preserving real retries.

    When `git worktree add` snapshots a project that already shipped
    features, every existing DONE_Feature_*/ directory ends up in the new
    worktree as a byte-identical clone. `_get_all_project_roots` then
    scans both main and worktree as independent project roots and reports
    each clone as a separate session — so a feature with 7 active canary
    worktrees gets counted 8 times in per-task cost rollups
    (terminal-websocket-bridge displayed $1012.24 = $126.53 × 8 on the
    Run Economy view 2026-05-25).

    Dedupe key is (task, stream_md5):
      - identical streams collapse to one session (the worktree-copy case)
      - same task with diverged stream content stays as separate sessions
        (legitimate independent runs — e.g. two clones with different
        retry histories)
      - sessions without a stream file (log-only) are passed through
        unchanged so legacy autopilot.log discoveries don't disappear

    First-seen wins. Order of sessions in the returned list is preserved
    so chronological consumers (e.g. earliest started_at for the period
    filter) keep working.

    O(N) on file size: hashes each stream exactly once. The dashboard
    discovery cache (45s TTL) absorbs the overhead across rapid calls.
    """
    import hashlib

    out = []
    seen_keys = set()
    for s in sessions:
        stream_path = s.get("stream_path")
        if not stream_path:
            out.append(s)
            continue
        try:
            with open(stream_path, "rb") as f:
                digest = hashlib.md5(f.read()).hexdigest()
        except OSError:
            out.append(s)
            continue
        key = (s.get("task"), digest)
        if key in seen_keys:
            continue
        seen_keys.add(key)
        out.append(s)
    return out


def _resolve_stream_path(task, search_roots=None):
    """Find the NDJSON stream file for a task.

    Checks docs/INPROGRESS_Feature_<task>/autopilot-stream.ndjson across search roots.
    When no search_roots provided, scans all projects under PROJECTS_ROOT.
    """
    if not _TASK_RE.match(task):
        return None

    roots = search_roots or _get_all_project_roots()
    for prefix in ("INPROGRESS_Feature_", "DONE_Feature_"):
        for root in roots:
            candidate = Path(root) / "docs" / f"{prefix}{task}" / "autopilot-stream.ndjson"
            if candidate.is_file():
                return str(candidate)

    return None


def read_stream_incremental(stream_path, offset, max_tail_bytes=None):
    """Read NDJSON stream file from byte offset, parse and filter events.

    Returns (events_list, new_byte_offset) or None on error.
    Filters out 'system' and 'rate_limit_event' type events.
    Security: validates path is under PROJECTS_ROOT after resolving symlinks.

    Perf (dashboard-perf 2026-06-02 #5): when ``max_tail_bytes`` is set and the
    initial (``offset == 0``) read would exceed it, only the trailing
    ``max_tail_bytes`` are parsed and the partial first line is dropped. This
    kills the cold-load full-file re-parse on multi-MB streams; ``new_offset``
    still points at EOF so live deltas stream unchanged. Ignored once
    ``offset > 0``.
    """
    try:
        resolved = Path(stream_path).resolve()
    except (OSError, ValueError):
        return None

    if not _is_allowed_path(resolved):
        return None

    if not resolved.is_file():
        return None

    try:
        with open(str(resolved), "rb") as f:
            start, drop_partial = _tail_start(f, offset, max_tail_bytes)
            f.seek(start)
            raw = f.read()
            new_offset = start + len(raw)
        content = raw.decode("utf-8", errors="replace")
        if drop_partial:
            content = _drop_partial_first_line(content)
    except OSError:
        return None

    events = []
    filtered_types = {"system", "rate_limit_event"}
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("type") not in filtered_types:
            events.append(event)

    return (events, new_offset)


def _search_summary_in_folders(task, roots):
    """Search for autopilot-summary.json in INPROGRESS and DONE folders.

    Returns parsed dict or None.
    """
    for prefix in ("INPROGRESS_Feature_", "DONE_Feature_"):
        for root in roots:
            candidate = Path(root) / "docs" / f"{prefix}{task}" / "autopilot-summary.json"
            if candidate.is_file():
                try:
                    return json.loads(candidate.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, OSError):
                    return None
    return None


def load_summary(task, search_roots=None):
    """Load autopilot-summary.json for a task. Returns parsed dict or None."""
    if not _TASK_RE.match(task):
        return None

    roots = search_roots or _get_all_project_roots()
    return _search_summary_in_folders(task, roots)
