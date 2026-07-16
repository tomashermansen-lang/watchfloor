"""Metrics computation from the full JSONL event stream.

Computes all 8 metrics (M1-M8) from data/sessions.jsonl in a single read.
Unlike session_helpers.py (which keeps only the latest event per sid),
this module processes ALL events to derive analytics.
"""
import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)

# Patterns for test/temp sessions to exclude (same as session_helpers.py)
_EXCLUDE_PATTERNS = (".test-tmp", "/tmp/", "/test-project")

# Event-to-category mapping for M8 timeline
_EVENT_CATEGORIES = {
    "PreToolUse": "tool",
    "PostToolUse": "tool",
    "PostToolUseFailure": "error",
    "Notification": "notification",
    "SubagentStart": "subagent",
    "SubagentStop": "subagent",
    "SessionStart": "session",
    "SessionEnd": "session",
    "PermissionRequest": "permission",
    "TaskCompleted": "task",
    "UserPromptSubmit": "prompt",
    "Stop": "session",
}

# Module-level cache with 2-second TTL
_cache: dict = {"key": None, "result": None, "ts": 0}
_CACHE_TTL = 2


def compute_metrics(sid: str | None = None, since: str | None = None) -> dict:
    """Compute all 8 metrics from the JSONL event stream.

    Args:
        sid: Optional session ID filter.
        since: Optional ISO 8601 timestamp to include only events after.

    Returns:
        Dict with keys: tool_usage, error_tracking, session_lifecycle,
        permission_friction, subagent_utilization, file_activity,
        task_completion, activity_timeline.
    """
    key = (sid, since)
    now = time.time()
    if _cache["key"] == key and now - _cache["ts"] < _CACHE_TTL:
        return _cache["result"]
    result = _compute_metrics_uncached(sid, since)
    _cache.update(key=key, result=result, ts=now)
    return result


def _compute_metrics_uncached(sid: str | None, since: str | None) -> dict:
    events = _read_events(sid, since)
    return {
        "tool_usage": _tool_usage(events),
        "error_tracking": _error_tracking(events),
        "session_lifecycle": _session_lifecycle(events),
        "permission_friction": _permission_friction(events),
        "subagent_utilization": _subagent_utilization(events),
        "file_activity": _file_activity(events),
        "task_completion": _task_completion(events),
        "activity_timeline": _activity_timeline(events),
    }


def _read_events(sid: str | None, since: str | None) -> list[dict]:
    """Read all JSONL events, filtered by sid and since."""
    data_dir = os.environ.get("DASHBOARD_DATA_DIR")
    if data_dir:
        jsonl_path = Path(data_dir) / "sessions.jsonl"
    else:
        jsonl_path = Path(__file__).resolve().parent.parent / "data" / "sessions.jsonl"

    if not jsonl_path.is_file():
        return []

    since_dt = None
    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
        except ValueError:
            logger.warning("Invalid 'since' timestamp: %s", since)

    events = []
    try:
        text = jsonl_path.read_text(encoding="utf-8")
    except Exception:
        logger.warning("Failed to read %s", jsonl_path, exc_info=True)
        return []

    for line in text.strip().splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        entry_sid = entry.get("sid", "")
        if not entry_sid:
            continue

        # Exclude test/temp sessions
        cwd_val = entry.get("cwd", "")
        if any(p in cwd_val for p in _EXCLUDE_PATTERNS):
            continue

        # Apply sid filter
        if sid and entry_sid != sid:
            continue

        # Apply since filter
        if since_dt:
            ts_str = entry.get("ts", "")
            if ts_str:
                try:
                    ts_dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                    if ts_dt <= since_dt:
                        continue
                except ValueError:
                    continue

        events.append(entry)

    return events


def _tool_usage(events: list[dict]) -> dict:
    """M1: Tool call counts, rates, and most-used tool."""
    by_tool: dict[str, int] = {}
    by_session: dict[str, dict] = {}

    for e in events:
        if e.get("event") != "PreToolUse":
            continue
        tool = e.get("type", "")
        if not tool:
            continue
        by_tool[tool] = by_tool.get(tool, 0) + 1

        sid = e.get("sid", "")
        if sid not in by_session:
            by_session[sid] = {"count": 0, "first_ts": e.get("ts", ""), "last_ts": e.get("ts", "")}
        by_session[sid]["count"] += 1
        by_session[sid]["last_ts"] = e.get("ts", "")

    # Compute rates (calls per minute)
    session_rates = {}
    for sid, info in by_session.items():
        duration_s = _ts_diff(info["first_ts"], info["last_ts"])
        duration_min = duration_s / 60.0 if duration_s > 0 else 1.0 / 60.0
        session_rates[sid] = {
            "count": info["count"],
            "rate": round(info["count"] / duration_min, 1),
        }

    total = sum(by_tool.values())
    most_used = max(by_tool, key=by_tool.get) if by_tool else ""

    return {
        "by_tool": by_tool,
        "by_session": session_rates,
        "most_used": most_used,
        "total": total,
    }


def _error_tracking(events: list[dict]) -> dict:
    """M2: Error counts, rates, tool breakdown, interrupt/failure split."""
    by_tool: dict[str, int] = {}
    by_tool_detail: dict[str, dict] = {}  # tool → {failures, interrupts}
    by_session: dict[str, dict] = {}
    interrupts = 0
    failures = 0
    timeline: list[dict] = []

    # Count PreToolUse per session for rate calculation
    pretool_by_session: dict[str, int] = {}
    for e in events:
        if e.get("event") == "PreToolUse":
            sid = e.get("sid", "")
            pretool_by_session[sid] = pretool_by_session.get(sid, 0) + 1

    for e in events:
        if e.get("event") != "PostToolUseFailure":
            continue
        tool = e.get("type", "")
        sid = e.get("sid", "")
        is_interrupt = e.get("intr") == "true"

        if tool:
            by_tool[tool] = by_tool.get(tool, 0) + 1
            if tool not in by_tool_detail:
                by_tool_detail[tool] = {"failures": 0, "interrupts": 0}
            if is_interrupt:
                by_tool_detail[tool]["interrupts"] += 1
            else:
                by_tool_detail[tool]["failures"] += 1

        if sid not in by_session:
            by_session[sid] = {"errors": 0}
        by_session[sid]["errors"] += 1

        if is_interrupt:
            interrupts += 1
        else:
            failures += 1

        timeline.append({
            "ts": e.get("ts", ""),
            "sid": sid,
            "tool": tool,
            "is_interrupt": is_interrupt,
        })

    # Compute rates
    for sid, info in by_session.items():
        pretool_count = pretool_by_session.get(sid, 0)
        if pretool_count > 0:
            info["rate"] = round(info["errors"] / pretool_count * 100, 1)
        else:
            info["rate"] = 100.0 if info["errors"] > 0 else 0.0

    total_errors = interrupts + failures

    return {
        "total_errors": total_errors,
        "by_tool": by_tool,
        "by_tool_detail": by_tool_detail,
        "by_session": by_session,
        "interrupts": interrupts,
        "failures": failures,
        "timeline": timeline,
    }


def _session_lifecycle(events: list[dict]) -> dict:
    """M3: Session durations, model/source distributions, end reasons."""
    sessions_data: dict[str, dict] = {}
    model_dist: dict[str, int] = {}
    source_dist: dict[str, int] = {}
    end_reasons: dict[str, int] = {}

    for e in events:
        sid = e.get("sid", "")
        ts = e.get("ts", "")
        event = e.get("event", "")

        if sid not in sessions_data:
            sessions_data[sid] = {
                "sid": sid, "start": ts, "end": ts,
                "model": "", "source": "", "end_reason": "",
            }

        # Update time bounds
        if ts < sessions_data[sid]["start"] or not sessions_data[sid]["start"]:
            sessions_data[sid]["start"] = ts
        if ts > sessions_data[sid]["end"]:
            sessions_data[sid]["end"] = ts

        if event == "SessionStart":
            model = e.get("model", "")
            src = e.get("src", "")
            if model:
                sessions_data[sid]["model"] = model
                model_dist[model] = model_dist.get(model, 0) + 1
            if src:
                sessions_data[sid]["source"] = src
                source_dist[src] = source_dist.get(src, 0) + 1

        if event == "SessionEnd":
            rsn = e.get("rsn", "")
            if rsn:
                sessions_data[sid]["end_reason"] = rsn
                end_reasons[rsn] = end_reasons.get(rsn, 0) + 1

    # Compute durations
    sessions_list = []
    for sid, info in sessions_data.items():
        dur = _ts_diff(info["start"], info["end"])
        sessions_list.append({
            "sid": sid,
            "start": info["start"],
            "end": info["end"],
            "duration_s": dur,
            "model": info["model"],
            "source": info["source"],
            "end_reason": info["end_reason"],
        })

    # Sort by start time
    sessions_list.sort(key=lambda s: s["start"])

    # Compute concurrency timeline (M3-R2)
    concurrency_events: list[tuple[str, int]] = []
    for s in sessions_list:
        if s["start"]:
            concurrency_events.append((s["start"], 1))
        if s["end"]:
            concurrency_events.append((s["end"], -1))
    concurrency_events.sort(key=lambda x: x[0])

    concurrency_timeline: list[dict] = []
    concurrent = 0
    for ts, delta in concurrency_events:
        concurrent += delta
        concurrency_timeline.append({"ts": ts, "concurrent": concurrent})

    return {
        "sessions": sessions_list,
        "model_distribution": model_dist,
        "source_distribution": source_dist,
        "end_reasons": end_reasons,
        "concurrency_timeline": concurrency_timeline,
    }


def _permission_friction(events: list[dict]) -> dict:
    """M4: Permission prompts, blocked durations, mode distribution."""
    by_tool: dict[str, int] = {}
    by_session: dict[str, dict] = {}
    mode_dist: dict[str, int] = {}
    blocked_durations: list[dict] = []
    has_tuid_data = False
    total_prompts = 0

    # Index events by session for tuid matching
    events_by_sid: dict[str, list[dict]] = {}
    for e in events:
        sid = e.get("sid", "")
        if sid not in events_by_sid:
            events_by_sid[sid] = []
        events_by_sid[sid].append(e)

        if e.get("tuid"):
            has_tuid_data = True

    by_tool_mode: dict[str, dict[str, int]] = {}  # tool → mode → count
    timeline: list[dict] = []

    for e in events:
        if e.get("event") != "PermissionRequest":
            continue
        total_prompts += 1
        tool = e.get("type", "")
        sid = e.get("sid", "")

        if tool:
            by_tool[tool] = by_tool.get(tool, 0) + 1

        if sid not in by_session:
            by_session[sid] = {"prompts": 0, "blocked_s": 0}
        by_session[sid]["prompts"] += 1

        pmode = e.get("pmode", "")
        if pmode:
            mode_dist[pmode] = mode_dist.get(pmode, 0) + 1
            if tool:
                if tool not in by_tool_mode:
                    by_tool_mode[tool] = {}
                by_tool_mode[tool][pmode] = by_tool_mode[tool].get(pmode, 0) + 1

        # Truncate msg for timeline display
        msg = e.get("msg", "")
        if len(msg) > 80:
            msg = msg[:77] + "..."
        timeline.append({
            "ts": e.get("ts", ""),
            "sid": sid,
            "tool": tool,
            "mode": pmode,
            "msg": msg,
        })

    # Compute blocked durations via tuid matching
    # For each session, find PreToolUse → PermissionRequest → PostToolUse sequences
    seen_tuids: set[str] = set()
    for sid, sid_events in events_by_sid.items():
        sorted_events = sorted(sid_events, key=lambda x: x.get("ts", ""))
        pre_by_tuid: dict[str, dict] = {}
        perm_between: dict[str, bool] = {}

        for ev in sorted_events:
            event = ev.get("event", "")
            tuid = ev.get("tuid", "")

            if event == "PreToolUse" and tuid:
                pre_by_tuid[tuid] = ev

            if event == "PermissionRequest":
                # Mark all open pre-tool events as having a permission request
                for t in pre_by_tuid:
                    perm_between[t] = True

            if event in ("PostToolUse", "PostToolUseFailure") and tuid:
                if tuid in pre_by_tuid and tuid in perm_between and tuid not in seen_tuids:
                    dur = _ts_diff(pre_by_tuid[tuid].get("ts", ""), ev.get("ts", ""))
                    if dur > 0:
                        blocked_durations.append({
                            "sid": sid,
                            "tuid": tuid,
                            "duration_s": dur,
                        })
                        if sid in by_session:
                            by_session[sid]["blocked_s"] += dur
                    seen_tuids.add(tuid)
                # Clean up
                pre_by_tuid.pop(tuid, None)
                perm_between.pop(tuid, None)

    return {
        "total_prompts": total_prompts,
        "by_tool": by_tool,
        "by_tool_mode": by_tool_mode,
        "by_session": by_session,
        "mode_distribution": mode_dist,
        "blocked_durations": blocked_durations,
        "has_tuid_data": has_tuid_data,
        "timeline": timeline,
    }


def _subagent_utilization(events: list[dict]) -> dict:
    """M5: Subagent spawn count, type distribution, concurrency, durations."""
    by_type: dict[str, int] = {}
    by_session: dict[str, int] = {}
    durations: list[dict] = []
    running: list[dict] = []
    starts: dict[str, dict] = {}  # aid → event

    for e in events:
        event = e.get("event", "")
        aid = e.get("aid", "")
        atype = e.get("atype", "")
        sid = e.get("sid", "")

        if event == "SubagentStart":
            by_session[sid] = by_session.get(sid, 0) + 1
            if atype:
                by_type[atype] = by_type.get(atype, 0) + 1
            if aid:
                starts[aid] = e

        if event == "SubagentStop" and aid and aid in starts:
            dur = _ts_diff(starts[aid].get("ts", ""), e.get("ts", ""))
            durations.append({
                "aid": aid,
                "atype": starts[aid].get("atype", ""),
                "duration_s": dur,
            })
            del starts[aid]

    # Remaining starts are still running (EC-B2)
    for aid, e in starts.items():
        running.append({
            "aid": aid,
            "atype": e.get("atype", ""),
            "start": e.get("ts", ""),
        })

    # Peak concurrent: scan events in order
    peak = 0
    active = 0
    sorted_events = sorted(
        [e for e in events if e.get("event") in ("SubagentStart", "SubagentStop")],
        key=lambda x: x.get("ts", ""),
    )
    for e in sorted_events:
        if e.get("event") == "SubagentStart":
            active += 1
            peak = max(peak, active)
        elif e.get("event") == "SubagentStop":
            active = max(0, active - 1)

    total_spawned = sum(by_session.values())

    return {
        "total_spawned": total_spawned,
        "by_type": by_type,
        "by_session": by_session,
        "peak_concurrent": peak,
        "durations": durations,
        "running": running,
    }


def _file_activity(events: list[dict]) -> dict:
    """M6: File activity heatmap, conflicts, read/write distinction."""
    file_tools = {"Read", "Write", "Edit"}
    write_tools = {"Write", "Edit"}
    files: dict[str, dict] = {}  # path → {sessions: set, access: set, last_ts: str}
    has_fp_data = False

    for e in events:
        if e.get("event") != "PreToolUse":
            continue
        fp = e.get("fp", "")
        tool = e.get("type", "")
        if not fp or tool not in file_tools:
            continue

        has_fp_data = True
        sid = e.get("sid", "")
        ts = e.get("ts", "")

        if fp not in files:
            files[fp] = {"sessions": set(), "write_sessions": set(), "access": set(), "last_ts": ts}

        files[fp]["sessions"].add(sid)
        files[fp]["access"].add("edit" if tool in write_tools else "read")
        if tool in write_tools:
            files[fp]["write_sessions"].add(sid)
        if ts > files[fp]["last_ts"]:
            files[fp]["last_ts"] = ts

    # Detect conflicts: files edited by 2+ sessions
    conflicts = []
    for path, info in files.items():
        if len(info["write_sessions"]) >= 2:
            conflicts.append({
                "path": path,
                "sessions": sorted(info["write_sessions"]),
            })

    # Build file list
    file_list = []
    edited = 0
    read_only = 0
    for path, info in files.items():
        access = "edit" if "edit" in info["access"] else "read"
        if access == "edit":
            edited += 1
        else:
            read_only += 1
        file_list.append({
            "path": path,
            "sessions": sorted(info["sessions"]),
            "access": access,
            "last_ts": info["last_ts"],
        })

    # Sort: edits first, then by session count descending
    file_list.sort(key=lambda f: (0 if f["access"] == "edit" else 1, -len(f["sessions"])))

    return {
        "files": file_list,
        "conflicts": conflicts,
        "summary": {"total": len(files), "edited": edited, "read_only": read_only},
        "has_fp_data": has_fp_data,
    }


def _task_completion(events: list[dict]) -> dict:
    """M7: Task counts, subjects, completion rates, and response counts."""
    tasks: list[dict] = []
    by_session: dict[str, int] = {}
    responses_by_session: dict[str, int] = {}
    total_responses = 0
    session_bounds: dict[str, dict] = {}

    for e in events:
        sid = e.get("sid", "")
        ts = e.get("ts", "")
        event = e.get("event", "")

        # Track session time bounds for rate calculation
        if sid not in session_bounds:
            session_bounds[sid] = {"first": ts, "last": ts}
        if ts < session_bounds[sid]["first"]:
            session_bounds[sid]["first"] = ts
        if ts > session_bounds[sid]["last"]:
            session_bounds[sid]["last"] = ts

        if event == "Stop":
            total_responses += 1
            responses_by_session[sid] = responses_by_session.get(sid, 0) + 1

        if event == "TaskCompleted":
            subject = e.get("tsub", "") or e.get("msg", "")
            tasks.append({"sid": sid, "subject": subject, "ts": ts})
            by_session[sid] = by_session.get(sid, 0) + 1

    # Compute rates (tasks per hour)
    rates: dict[str, float] = {}
    for sid, count in by_session.items():
        if sid in session_bounds:
            dur = _ts_diff(session_bounds[sid]["first"], session_bounds[sid]["last"])
            hours = dur / 3600.0 if dur > 0 else 1.0 / 3600.0
            rates[sid] = round(count / hours, 1)

    return {
        "total": len(tasks),
        "by_session": by_session,
        "tasks": tasks,
        "rates": rates,
        "total_responses": total_responses,
        "responses_by_session": responses_by_session,
    }


def _activity_timeline(events: list[dict]) -> dict:
    """M8: Per-session event timeline with categories and idle gaps."""
    by_session: dict[str, list[dict]] = {}

    for e in events:
        sid = e.get("sid", "")
        event_name = e.get("event", "")
        ts = e.get("ts", "")
        category = _EVENT_CATEGORIES.get(event_name, "other")
        branch = e.get("branch", "")

        if sid not in by_session:
            by_session[sid] = []
        by_session[sid].append({"ts": ts, "category": category, "branch": branch})

    sessions = []
    for sid, evts in by_session.items():
        evts.sort(key=lambda x: x["ts"])
        if not evts:
            continue

        start = evts[0]["ts"]
        end = evts[-1]["ts"]
        branch = evts[0].get("branch", "")
        label = f"{branch} — {sid[:7]}" if branch else sid[:7]

        # Detect idle gaps (> 60s between consecutive events)
        idle_gaps = []
        for i in range(1, len(evts)):
            gap = _ts_diff(evts[i - 1]["ts"], evts[i]["ts"])
            if gap > 60:
                idle_gaps.append({
                    "start": evts[i - 1]["ts"],
                    "end": evts[i]["ts"],
                    "duration_s": gap,
                })

        # Compute density (events per minute)
        total_dur = _ts_diff(start, end)
        density = round(len(evts) / (total_dur / 60.0), 1) if total_dur > 0 else 0.0

        # Strip branch from event dicts (not needed in output)
        clean_events = [{"ts": ev["ts"], "category": ev["category"]} for ev in evts]

        sessions.append({
            "sid": sid,
            "label": label,
            "start": start,
            "end": end,
            "events": clean_events,
            "idle_gaps": idle_gaps,
            "density": density,
        })

    sessions.sort(key=lambda s: s["start"])

    return {"sessions": sessions}


def _ts_diff(ts1: str, ts2: str) -> int:
    """Compute seconds between two ISO 8601 timestamps. Returns 0 on error."""
    try:
        dt1 = datetime.fromisoformat(ts1.replace("Z", "+00:00"))
        dt2 = datetime.fromisoformat(ts2.replace("Z", "+00:00"))
        return int((dt2 - dt1).total_seconds())
    except (ValueError, AttributeError):
        return 0
