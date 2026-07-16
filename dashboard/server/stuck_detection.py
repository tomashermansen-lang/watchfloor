"""Stuck agent detection from session event streams.

Detects attractor loops and permission oscillation patterns
from sessions.jsonl events. Pure functions — no filesystem deps.
"""

from __future__ import annotations

from typing import TypedDict


class StuckInfo(TypedDict, total=False):
    reason: str
    tool: str | None
    file: str | None


_MAX_EVENTS = 50  # R2d: bounded scan


def _detect_attractor_loop(events: list[dict]) -> StuckInfo | None:
    """Detect 3+ consecutive identical PreToolUse events (same tool + file).

    Scans from newest to oldest. The 3 identical calls must be the most
    recent consecutive sequence (E4). Different files = not stuck (E5).
    """
    pre_tool_events = [e for e in events if e.get("event") == "PreToolUse"]
    if len(pre_tool_events) < 3:
        return None

    # Check from the end (most recent) for consecutive identical tool+file
    latest = pre_tool_events[-1]
    tool = latest.get("type", "")
    fp = latest.get("fp", "")
    if not tool or not fp:
        return None

    count = 0
    for e in reversed(pre_tool_events):
        if e.get("type") == tool and e.get("fp") == fp:
            count += 1
        else:
            break

    if count >= 3:
        return StuckInfo(reason="attractor_loop", tool=tool, file=fp)
    return None


def _detect_permission_oscillation(events: list[dict]) -> StuckInfo | None:
    """Detect 3+ PermissionRequest events within any 6 consecutive events.

    Tool identity is irrelevant (E7). Scans all windows of size 6.
    """
    if len(events) < 6:
        # Check if we have at least 3 PermissionRequest in whatever we have
        perm_count = sum(1 for e in events if e.get("event") == "PermissionRequest")
        if perm_count >= 3 and len(events) >= 3:
            return StuckInfo(reason="permission_oscillation", tool=None, file=None)
        return None

    for i in range(len(events) - 5):
        window = events[i : i + 6]
        perm_count = sum(1 for e in window if e.get("event") == "PermissionRequest")
        if perm_count >= 3:
            return StuckInfo(reason="permission_oscillation", tool=None, file=None)
    return None


# Registry of detector functions — append to add new patterns (OCP)
_DETECTORS = [
    _detect_attractor_loop,
    _detect_permission_oscillation,
]


def detect_stuck_sessions(
    events: list[dict], session_ids: list[str]
) -> dict[str, StuckInfo]:
    """Detect stuck agent patterns for given sessions.

    For each session ID, extracts the last 50 events (R2d),
    runs all registered detectors. First non-None result wins.

    Returns {sid: StuckInfo} for stuck sessions only.
    """
    result: dict[str, StuckInfo] = {}

    # Group events by session
    events_by_sid: dict[str, list[dict]] = {}
    for e in events:
        sid = e.get("sid", "")
        if sid in session_ids:
            events_by_sid.setdefault(sid, []).append(e)

    for sid in session_ids:
        sid_events = events_by_sid.get(sid, [])
        # Sort by timestamp and take last N (R2d)
        sid_events.sort(key=lambda e: e.get("ts", ""))
        sid_events = sid_events[-_MAX_EVENTS:]

        for detector in _DETECTORS:
            info = detector(sid_events)
            if info is not None:
                result[sid] = info
                break

    return result
