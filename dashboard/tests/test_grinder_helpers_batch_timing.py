"""Tests for grinder_helpers._extract_batch_timing.

Regression coverage for the stale-event-bleed bug surfaced 2026-05-12:
when events.ndjson contains entries from multiple discover cycles
(grinder discover appends; it does not truncate), the same batch_id
can appear twice with different timestamps. The function previously
iterated all matches and overwrote started_at each time — so given a
newest-first input list, the OLDEST matching event won, and the
dashboard's GrinderDetail displayed timestamps from a previous cycle.

The fix: select the started event with the maximum timestamp among
matches, not the last one iterated.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Make `from server.grinder_helpers import ...` resolve like the
# existing dashboard tests do (see test_grinder_stream.py).
_DASHBOARD_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_DASHBOARD_ROOT))

from dashboard.server.grinder_helpers import _extract_batch_timing  # noqa: E402


def test_single_started_event_returns_its_timestamp() -> None:
    events = [
        {"ts": "2026-05-12T10:52:15Z", "batch": "batch-001", "event": "started", "turns": 0},
    ]
    turns, started_at = _extract_batch_timing(events, "batch-001", None)
    assert started_at == "2026-05-12T10:52:15Z"
    assert turns == 0


def test_duplicate_started_events_returns_newest_timestamp() -> None:
    # Newest-first ordering (matches what _read_events emits via reversed deque)
    events = [
        {"ts": "2026-05-12T10:52:15Z", "batch": "batch-001", "event": "started", "turns": 0},
        {"ts": "2026-04-22T13:04:07Z", "batch": "batch-001", "event": "completed"},
        {"ts": "2026-04-22T12:59:53Z", "batch": "batch-001", "event": "started", "turns": 8},
    ]
    _, started_at = _extract_batch_timing(events, "batch-001", None)
    # The newest started event for batch-001 is the 2026-05-12 entry.
    # Before the fix, the older 2026-04-22 entry won (it overwrote in the loop).
    assert started_at == "2026-05-12T10:52:15Z"


def test_duplicate_started_events_oldest_first_ordering_returns_newest() -> None:
    # Order-of-iteration robustness — same data, oldest-first.
    events = [
        {"ts": "2026-04-22T12:59:53Z", "batch": "batch-001", "event": "started", "turns": 8},
        {"ts": "2026-04-22T13:04:07Z", "batch": "batch-001", "event": "completed"},
        {"ts": "2026-05-12T10:52:15Z", "batch": "batch-001", "event": "started", "turns": 0},
    ]
    _, started_at = _extract_batch_timing(events, "batch-001", None)
    assert started_at == "2026-05-12T10:52:15Z"


def test_only_completed_events_returns_default() -> None:
    events = [
        {"ts": "2026-05-12T10:52:16Z", "batch": "batch-001", "event": "completed"},
    ]
    _, started_at = _extract_batch_timing(events, "batch-001", "2026-05-12T10:52:14Z")
    assert started_at == "2026-05-12T10:52:14Z"  # default ts preserved


def test_other_batch_ignored() -> None:
    events = [
        {"ts": "2026-05-12T11:00:00Z", "batch": "batch-002", "event": "started", "turns": 0},
        {"ts": "2026-04-22T12:59:53Z", "batch": "batch-001", "event": "started", "turns": 8},
    ]
    turns, started_at = _extract_batch_timing(events, "batch-001", "default-ts")
    assert started_at == "2026-04-22T12:59:53Z"
    assert turns == 8


def test_turns_taken_from_newest_started_event() -> None:
    # If the same batch has two started events with different turn counts,
    # the dashboard should reflect the CURRENT cycle's turn count, not
    # the historical one.
    events = [
        {"ts": "2026-05-12T10:52:15Z", "batch": "batch-001", "event": "started", "turns": 0},
        {"ts": "2026-04-22T12:59:53Z", "batch": "batch-001", "event": "started", "turns": 8},
    ]
    turns, _ = _extract_batch_timing(events, "batch-001", None)
    assert turns == 0  # the new cycle started at turn 0; old cycle had 8


def test_missing_ts_field_skipped() -> None:
    # A malformed event without ts should not crash; the valid one wins.
    events = [
        {"batch": "batch-001", "event": "started"},  # no ts
        {"ts": "2026-05-12T10:52:15Z", "batch": "batch-001", "event": "started", "turns": 0},
    ]
    _, started_at = _extract_batch_timing(events, "batch-001", "fallback-ts")
    assert started_at == "2026-05-12T10:52:15Z"
