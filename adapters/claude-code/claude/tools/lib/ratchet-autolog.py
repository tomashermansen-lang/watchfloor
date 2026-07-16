#!/usr/bin/env python3
"""Append MAY-defer findings to deferred-findings.json with auto-generated metadata.

Reads a JSON array of MAY-defer findings from stdin, checks for duplicates,
appends new entries with state: Accepted, and writes atomically.

Usage:
    ratchet-autolog.py --deferred <path>

stdin:  JSON array of MAY-defer findings
stdout: JSON array of entries with auto_logged: true/false flag per finding
Exit 0 on success, 1 on corrupt deferred file.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

# Schema-version routing — append into the YAML graph when a 2.0 plan is
# colocated with the deferred path; otherwise legacy JSON behaviour applies.
try:
    from plan_yaml_deferred import (  # type: ignore[import-not-found]
        LegacyPlanError,
        SchemaViolation,
        detect_plan_version,
        find_colocated_plan,
        make_code_finding_entry,
        read_deferred,
        write_deferred,
    )
except ImportError:  # pragma: no cover
    find_colocated_plan = None  # type: ignore[assignment]


def _get_git_user_name() -> str:
    """Get git user.name, falling back to 'unknown'."""
    try:
        result = subprocess.run(
            ["git", "config", "user.name"],
            capture_output=True,
            text=True,
        )
        name = result.stdout.strip()
        return name if name else "unknown"
    except Exception:
        return "unknown"


def _load_deferred(deferred_path: str) -> list[dict]:
    """Load and validate deferred-findings.json. Exit 1 on corrupt file."""
    if not os.path.exists(deferred_path):
        return []
    raw = Path(deferred_path).read_text()
    if not raw.strip():
        print("ratchet-autolog: deferred file is empty (corrupt)", file=sys.stderr)
        sys.exit(1)
    try:
        existing = json.loads(raw)
    except json.JSONDecodeError:
        print("ratchet-autolog: deferred file is corrupt (invalid JSON)", file=sys.stderr)
        sys.exit(1)
    if not isinstance(existing, list):
        print("ratchet-autolog: deferred file is corrupt (not an array)", file=sys.stderr)
        sys.exit(1)
    return existing


def _autolog_to_2_0_plan(findings: list[dict], plan_path: Path) -> list[dict] | None:
    """Append into project.deferred[] of a 2.0 plan; return per-finding results.

    Returns ``None`` when the plan is not 2.0 so the caller can fall through
    to the legacy JSON path.
    """
    if find_colocated_plan is None or detect_plan_version(plan_path) != "2.0":
        return None
    try:
        existing = read_deferred(plan_path)
    except LegacyPlanError:
        return None
    existing_ids = {e.get("finding_id") for e in existing if e.get("finding_id")}
    owner = _get_git_user_name() or "ratchet-autolog"
    now = datetime.now(UTC)
    today = now.strftime("%Y-%m-%d")
    timestamp = now.isoformat()

    results: list[dict] = []
    new_entries: list[dict] = []
    for finding in findings:
        try:
            fid = finding["id"]
        except (KeyError, TypeError):
            print(
                f"ratchet-autolog: finding missing 'id' field, skipping: {finding!r}",
                file=sys.stderr,
            )
            continue
        if fid in existing_ids:
            results.append({"finding_id": fid, "auto_logged": False})
            continue
        entry_id = f"DF-{fid.split(':')[-1][:8]}"
        try:
            entry = make_code_finding_entry(
                id=entry_id,
                finding_id=fid,
                rule=finding["rule"],
                file=finding["file"],
                line=int(finding.get("line", 0) or 0),
                state="Accepted",
                reason=f"auto-logged by ratchet-autolog at {timestamp}",
                owner=owner,
                reviewed_at=today,
                review_trigger="may-defer-autolog",
            )
        except KeyError as exc:
            print(
                f"ratchet-autolog: finding missing required field {exc}; skipping",
                file=sys.stderr,
            )
            continue
        new_entries.append(entry)
        existing_ids.add(fid)
        results.append({"finding_id": fid, "auto_logged": True})
    if new_entries:
        try:
            write_deferred(plan_path, list(existing) + new_entries)
        except SchemaViolation as exc:
            print(f"ratchet-autolog: {exc}", file=sys.stderr)
            sys.exit(1)
    return results


def autolog(findings: list[dict], deferred_path: str) -> list[dict]:
    """Append new MAY-defer findings to deferred-findings.json.

    Returns a list of dicts with an ``auto_logged`` flag per finding.
    """
    if not findings:
        return []

    if find_colocated_plan is not None:
        plan = find_colocated_plan(Path(deferred_path).parent)
        if plan is not None:
            yaml_results = _autolog_to_2_0_plan(findings, plan)
            if yaml_results is not None:
                return yaml_results

    existing = _load_deferred(deferred_path)
    existing_ids = {e["finding_id"] for e in existing if "finding_id" in e}
    owner = _get_git_user_name()
    now = datetime.now(UTC)
    today = now.strftime("%Y-%m-%d")
    timestamp = now.isoformat()

    results: list[dict] = []
    new_entries: list[dict] = []

    for finding in findings:
        # Normalised finding "id" → deferred entry "finding_id"
        try:
            finding_id = finding["id"]
        except (KeyError, TypeError):
            print(
                f"ratchet-autolog: finding missing 'id' field, skipping: {finding!r}",
                file=sys.stderr,
            )
            continue

        if finding_id in existing_ids:
            results.append({"finding_id": finding_id, "auto_logged": False})
            continue

        reason = f"auto-logged by commit-preflight at {timestamp}"
        # Ensure reason >= 40 chars (it already is for any valid timestamp)

        entry = {
            "finding_id": finding_id,
            "rule": finding["rule"],
            "file": finding["file"],
            "line": finding["line"],
            "state": "Accepted",
            "reason": reason,
            "owner": owner,
            "reviewed_at": today,
        }

        new_entries.append(entry)
        existing_ids.add(finding_id)
        results.append({"finding_id": finding_id, "auto_logged": True})

    if new_entries:
        updated = existing + new_entries
        # Atomic write: temp file + os.replace()
        dir_path = os.path.dirname(deferred_path) or "."
        os.makedirs(dir_path, exist_ok=True)
        fd, tmp_file = tempfile.mkstemp(dir=dir_path, suffix=".json.tmp")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(updated, f, indent=2)
                f.write("\n")
            os.replace(tmp_file, deferred_path)
        except Exception:
            # Clean up temp file on failure
            try:
                os.unlink(tmp_file)
            except OSError:
                pass
            raise

    return results


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Auto-log MAY-defer findings to deferred-findings.json.",
    )
    parser.add_argument(
        "--deferred",
        required=True,
        help="Path to deferred-findings.json",
    )
    args = parser.parse_args()

    try:
        findings = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        print("ratchet-autolog: stdin is not valid JSON", file=sys.stderr)
        return 1

    results = autolog(findings, args.deferred)
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
