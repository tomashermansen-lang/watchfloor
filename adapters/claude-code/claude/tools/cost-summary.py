#!/usr/bin/env python3
"""Trustworthy cost-accounting for autopilot streams.

Reads an autopilot-stream.ndjson and reports per-phase + per-session +
total cost. Handles two failure modes that naive sum-of-result-events
gets wrong:

1. PHANTOM RESULT EVENTS — claude -p sometimes emits multiple `result`
   events from the SAME session (e.g. when a background notification
   arrives after the main work is done and the agent acknowledges with
   a 1-turn message before exiting). The `total_cost_usd` field on a
   result event is CUMULATIVE PER SESSION, not incremental, so summing
   all result events double-counts the session.

   Correct behavior: take MAX(total_cost_usd) per unique session_id.

2. RETRY ATTEMPTS — `run_gated_phase` retries failed phases (default
   max_attempts=2). Each attempt is a fresh claude session with its own
   session_id. autopilot's `track_phase` uses `tail -1` of result events
   so it captures only the latest (successful) attempt — the previous
   failed attempts' cost is INVISIBLE in autopilot-summary.json.

   Correct behavior for "actual $ paid to Anthropic": sum max-per-session
   across all sessions, including failed attempts.

Phase attribution: result events don't carry a phase tag, but
`type:"phase"` orchestrator events do. We use phase events as
boundaries and attribute result events to whichever phase was most
recently `status:"running"` when the result event landed.

Usage:
    python3 cost-summary.py <autopilot-stream.ndjson> [--json] [--label LABEL]

Output (default text):
    per-phase: cost / wall-time / turns / sessions (retries flagged)
    per-session within a retried phase: cost + outcome
    totals: trustworthy paid-to-Anthropic total

Output (--json): single object with the same data, for downstream tools.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class SessionAgg:
    """Per-session aggregate. cost is the MAX over all result events for
    this session (the cumulative final value)."""
    session_id: str
    phase: str = ""
    cost: float = 0.0
    duration_ms: int = 0
    num_turns: int = 0
    is_error: bool = False
    result_event_count: int = 0
    first_ts: str = ""
    last_ts: str = ""

    def absorb(self, event: dict, current_phase: str, ts: str) -> None:
        """Update this session's aggregate from a result event."""
        c = float(event.get("total_cost_usd") or 0)
        # MAX, not sum — the field is cumulative per session.
        if c > self.cost:
            self.cost = c
        d = int(event.get("duration_ms") or 0)
        if d > self.duration_ms:
            self.duration_ms = d
        n = int(event.get("num_turns") or 0)
        if n > self.num_turns:
            self.num_turns = n
        if event.get("is_error"):
            self.is_error = True
        self.result_event_count += 1
        if not self.first_ts:
            self.first_ts = ts
        self.last_ts = ts
        if not self.phase:
            self.phase = current_phase


@dataclass
class PhaseAgg:
    """Per-phase aggregate over all sessions attributed to this phase."""
    phase: str
    sessions: list[SessionAgg] = field(default_factory=list)

    @property
    def cost(self) -> float:
        return sum(s.cost for s in self.sessions)

    @property
    def duration_min(self) -> float:
        return sum(s.duration_ms for s in self.sessions) / 60_000

    @property
    def num_turns(self) -> int:
        return sum(s.num_turns for s in self.sessions)

    @property
    def retries(self) -> int:
        return max(0, len(self.sessions) - 1)

    @property
    def had_failure(self) -> bool:
        return any(s.is_error for s in self.sessions)


def aggregate(stream_path: Path) -> list[PhaseAgg]:
    """Walk the stream, attributing each result event to a phase and
    aggregating per-session. Returns phase aggregates in chronological order."""
    sessions: dict[str, SessionAgg] = {}
    phase_order: list[str] = []
    phase_aggs: dict[str, PhaseAgg] = {}
    current_phase = "(pre-pipeline)"

    for raw_line in stream_path.read_text(errors="replace").splitlines():
        if not raw_line.strip():
            continue
        try:
            event = json.loads(raw_line)
        except Exception:
            continue

        ts = event.get("ts", "")
        etype = event.get("type")

        if etype == "phase":
            status = event.get("status", "")
            phase_name = event.get("phase", "")
            if status == "running" and phase_name:
                current_phase = phase_name
                if phase_name not in phase_aggs:
                    phase_aggs[phase_name] = PhaseAgg(phase=phase_name)
                    phase_order.append(phase_name)
        elif etype == "result":
            sid = event.get("session_id", "") or "(no-session)"
            if sid not in sessions:
                sessions[sid] = SessionAgg(session_id=sid)
                if current_phase not in phase_aggs:
                    phase_aggs[current_phase] = PhaseAgg(phase=current_phase)
                    phase_order.append(current_phase)
                phase_aggs[current_phase].sessions.append(sessions[sid])
            sessions[sid].absorb(event, current_phase, ts)

    return [phase_aggs[p] for p in phase_order]


def fmt_text(phase_aggs: list[PhaseAgg], stream_label: str) -> str:
    out: list[str] = []
    out.append(f"=== {stream_label} ===")
    out.append(f"{'Phase':30} {'Cost':>8} {'Min':>6} {'Turns':>6} {'Sess':>5} {'Notes':30}")
    out.append("-" * 95)
    total_cost = 0.0
    total_min = 0.0
    total_turns = 0
    total_sessions = 0
    for p in phase_aggs:
        notes = []
        if p.retries:
            notes.append(f"{p.retries} retry/retries")
        if p.had_failure:
            notes.append("had_failure")
        for s in p.sessions:
            if s.result_event_count > 1:
                notes.append(f"phantom×{s.result_event_count - 1}")
        out.append(
            f"{p.phase[:30]:30} ${p.cost:7.2f} {p.duration_min:6.1f} "
            f"{p.num_turns:6d} {len(p.sessions):5d} {', '.join(notes)[:30]:30}"
        )
        total_cost += p.cost
        total_min += p.duration_min
        total_turns += p.num_turns
        total_sessions += len(p.sessions)
        if p.retries:
            for i, s in enumerate(p.sessions):
                marker = "x" if s.is_error else "+"
                out.append(
                    f"    [{marker}] session #{i+1} {s.session_id[:12]} "
                    f"${s.cost:.2f} / {s.duration_ms/60000:.1f}min / {s.num_turns}t"
                    + (f" ({s.result_event_count} result events)" if s.result_event_count > 1 else "")
                )
    out.append("-" * 95)
    out.append(
        f"{'TOTAL (paid to Anthropic)':30} ${total_cost:7.2f} {total_min:6.1f} "
        f"{total_turns:6d} {total_sessions:5d}"
    )
    return "\n".join(out)


def fmt_json(phase_aggs: list[PhaseAgg], stream_label: str) -> str:
    payload = {
        "stream": stream_label,
        "total_cost_usd": round(sum(p.cost for p in phase_aggs), 4),
        "total_duration_min": round(sum(p.duration_min for p in phase_aggs), 2),
        "total_turns": sum(p.num_turns for p in phase_aggs),
        "total_sessions": sum(len(p.sessions) for p in phase_aggs),
        "phases": [
            {
                "phase": p.phase,
                "cost_usd": round(p.cost, 4),
                "duration_min": round(p.duration_min, 2),
                "num_turns": p.num_turns,
                "session_count": len(p.sessions),
                "retries": p.retries,
                "had_failure": p.had_failure,
                "sessions": [
                    {
                        "session_id": s.session_id,
                        "cost_usd": round(s.cost, 4),
                        "duration_min": round(s.duration_ms / 60000, 2),
                        "num_turns": s.num_turns,
                        "is_error": s.is_error,
                        "result_event_count": s.result_event_count,
                    }
                    for s in p.sessions
                ],
            }
            for p in phase_aggs
        ],
    }
    return json.dumps(payload, indent=2)


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("stream", type=Path, help="Path to autopilot-stream.ndjson")
    p.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    p.add_argument("--label", default=None, help="Override stream label in output")
    args = p.parse_args()

    if not args.stream.exists():
        print(f"ERROR: stream not found: {args.stream}", file=sys.stderr)
        return 2

    label = args.label or str(args.stream)
    phase_aggs = aggregate(args.stream)

    if args.json:
        print(fmt_json(phase_aggs, label))
    else:
        print(fmt_text(phase_aggs, label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
