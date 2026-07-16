"""Parse chain-events.ndjson for gate evaluation state.

Reads gate_evaluated events from an autopilot chain's event log and
returns per-phase evaluation results for dashboard enrichment.

Functions: parse_gate_evaluations
"""
import json
import logging
from pathlib import Path
from typing import TypedDict

logger = logging.getLogger(__name__)


class EvalItem(TypedDict):
    text: str
    kind: str       # "shell" | "human"
    result: str | None  # "passed" | "failed" | "timeout" | "needs_review" | None


def parse_gate_evaluations(plan_dir: str) -> dict[str, list[EvalItem]]:
    """Return {phase_id: [EvalItem, ...]} from chain-events.ndjson.

    Reads the file line by line, keeps only gate_evaluated events.
    For multiple events on the same phase, the last one wins (EC2.2).
    Malformed lines are skipped silently (EC2.4).
    File not found returns empty dict (EC2.1).
    """
    events_path = Path(plan_dir) / "chain-events.ndjson"
    if not events_path.is_file():
        logger.debug("chain-events.ndjson not found at %s", plan_dir)
        return {}

    result: dict[str, list[EvalItem]] = {}
    try:
        text = events_path.read_text(encoding="utf-8")
    except (OSError, IOError) as e:
        logger.warning("Failed to read chain-events.ndjson: %s", e)
        return {}

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        if not isinstance(event, dict):
            continue
        if event.get("type") != "gate_evaluated":
            continue

        phase = event.get("phase")
        if not phase:
            continue

        items_raw = event.get("items", [])
        items: list[EvalItem] = []
        if isinstance(items_raw, list):
            for item in items_raw:
                if isinstance(item, dict):
                    items.append(EvalItem(
                        text=item.get("text", ""),
                        kind=item.get("kind", "human"),
                        result=item.get("result"),
                    ))

        result[phase] = items

    return result
