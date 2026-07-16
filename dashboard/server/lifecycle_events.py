"""Lifecycle event schema, validator, and append helper.

Required fields: ts, type, action, source, target.
Optional fields: phase_at_pause, tmux_session. Extra fields preserved.
Pure stdlib — no FastAPI, no Pydantic.

Host plan task: lifecycle-event-schema. Downstream consumer:
lifecycle-event-bash-emitters.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger("dashboard.server.lifecycle_events")

LIFECYCLE_ACTIONS: tuple[str, ...] = (
    "started",
    "paused",
    "resumed",
    "cancelled",
    "phase_complete",
)
LIFECYCLE_SOURCES: tuple[str, ...] = ("cli", "dashboard")

_REQUIRED_FIELDS: tuple[str, ...] = ("ts", "type", "action", "source", "target")
_OPTIONAL_STR_FIELDS: tuple[str, ...] = ("phase_at_pause", "tmux_session")
# Mirrors FeatureId pattern in dashboard/server/schemas.py:20-27 — keep in sync.
_TARGET_PATTERN: re.Pattern[str] = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")


class LifecycleEventInvalid(ValueError):
    """Raised when a lifecycle event payload fails validation. args[0] is the offending field name."""


def _validate_optional_fields(event: dict[str, Any]) -> None:
    for opt in _OPTIONAL_STR_FIELDS:
        if opt not in event:
            continue
        value = event[opt]
        if not isinstance(value, str) or not value:
            raise LifecycleEventInvalid(opt)


def _validate_event(event: dict[str, Any]) -> None:
    for name in _REQUIRED_FIELDS:
        if name not in event:
            raise LifecycleEventInvalid(name)
    if event["type"] != "lifecycle":
        raise LifecycleEventInvalid("type")
    ts = event["ts"]
    if not isinstance(ts, str) or not ts.strip():
        raise LifecycleEventInvalid("ts")
    try:
        datetime.fromisoformat(ts)
    except (ValueError, TypeError) as exc:
        raise LifecycleEventInvalid("ts") from exc
    if event["action"] not in LIFECYCLE_ACTIONS:
        raise LifecycleEventInvalid("action")
    if event["source"] not in LIFECYCLE_SOURCES:
        raise LifecycleEventInvalid("source")
    target = event["target"]
    if not isinstance(target, str) or not _TARGET_PATTERN.match(target):
        raise LifecycleEventInvalid("target")
    _validate_optional_fields(event)


def parse_event(line: str) -> dict[str, Any]:
    """Parse one NDJSON line into a validated event dict or raise LifecycleEventInvalid."""
    if not isinstance(line, str):
        raise LifecycleEventInvalid("json")
    stripped = line.strip()
    if not stripped:
        raise LifecycleEventInvalid("json")
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise LifecycleEventInvalid("json") from exc
    if not isinstance(parsed, dict):
        raise LifecycleEventInvalid("root")
    _validate_event(parsed)
    return parsed


def append_event(path: str | Path, event: dict[str, Any]) -> None:
    """Validate event then append as one NDJSON line; OSError is logged, not raised."""
    _validate_event(event)
    serialized = json.dumps(event)
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(serialized + "\n")
    except OSError as exc:
        logger.warning("lifecycle append failed: %s: %s", type(exc).__name__, exc)
