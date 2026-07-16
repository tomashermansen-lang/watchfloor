#!/usr/bin/env python3
"""Atomic in-place update of a single batch's status in grinder-plan.yaml.

Usage:
    python3 grinder-plan-update.py <plan-path> <batch-id> <new-status>

Exit 0 on success, exit 1 on error.
Atomic write via temp-file-then-rename.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import yaml

VALID_STATUSES = {"pending", "in_progress", "completed", "failed", "deferred"}
VALID_FLAGS = {"needs_review"}


def _find_batch(data: dict, batch_id: str) -> dict | None:
    """Find a batch by ID in plan data. Returns the batch dict or None."""
    for p in data.get("passes", []):
        for b in p.get("batches", []):
            if b.get("id") == batch_id:
                return b
    return None


def _atomic_write_yaml(path: Path, data: dict) -> str | None:
    """Write data to path atomically. Returns error message or None on success."""
    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(
            dir=str(path.parent), suffix=".tmp", prefix=".grinder-plan-"
        )
        with os.fdopen(fd, "w") as f:
            yaml.dump(data, f, default_flow_style=False, sort_keys=False)
        os.rename(tmp_path, str(path))
    except Exception as e:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        return str(e)
    return None


def update_batch_status(
    plan_path: str,
    batch_id: str,
    new_status: str,
    flags: dict[str, object] | None = None,
) -> int:
    """Update a batch's status and optional flags in a grinder-plan YAML file.

    Returns 0 on success, 1 on error. Prints diagnostics to stderr.
    """
    if new_status not in VALID_STATUSES:
        print(
            f"error: invalid status '{new_status}' — "
            f"must be one of {sorted(VALID_STATUSES)}",
            file=sys.stderr,
        )
        return 1

    path = Path(plan_path)
    try:
        data = yaml.safe_load(path.read_text())
    except Exception as e:
        print(f"error: cannot read {plan_path}: {e}", file=sys.stderr)
        return 1

    batch = _find_batch(data, batch_id)
    if batch is None:
        print(f"error: batch not found: {batch_id}", file=sys.stderr)
        return 1

    batch["status"] = new_status
    if flags:
        for key, val in flags.items():
            batch[key] = val

    err = _atomic_write_yaml(path, data)
    if err:
        print(f"error: cannot write {plan_path}: {err}", file=sys.stderr)
        return 1

    return 0


def _parse_flags(flag_args: list[str]) -> dict[str, object]:
    """Parse --set-flag key=value pairs into a dict.

    Only keys in VALID_FLAGS are accepted. Unknown keys are rejected to
    prevent arbitrary YAML key injection (including status override).
    """
    flags: dict[str, object] = {}
    for arg in flag_args:
        key, _, val = arg.partition("=")
        if key not in VALID_FLAGS:
            print(
                f"error: unknown flag '{key}' — "
                f"must be one of {sorted(VALID_FLAGS)}",
                file=sys.stderr,
            )
            sys.exit(1)
        if val.lower() == "true":
            flags[key] = True
        elif val.lower() == "false":
            flags[key] = False
        else:
            flags[key] = val
    return flags


def main() -> None:
    # Parse args: <plan-path> <batch-id> <new-status> [--set-flag key=value ...]
    args = sys.argv[1:]
    if len(args) < 3:
        print(
            "Usage: grinder-plan-update.py <plan-path> <batch-id> <new-status> "
            "[--set-flag key=value ...]",
            file=sys.stderr,
        )
        sys.exit(1)

    plan_path = args[0]
    batch_id = args[1]
    new_status = args[2]

    flag_args: list[str] = []
    i = 3
    while i < len(args):
        if args[i] == "--set-flag" and i + 1 < len(args):
            flag_args.append(args[i + 1])
            i += 2
        else:
            i += 1

    flags = _parse_flags(flag_args) if flag_args else None
    sys.exit(update_batch_status(plan_path, batch_id, new_status, flags=flags))


if __name__ == "__main__":
    main()
