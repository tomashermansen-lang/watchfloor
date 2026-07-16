#!/usr/bin/env python3
"""Filter normalised findings against deferred-findings.json.

Reads a JSON array of normalised findings from stdin, removes entries
whose ``id`` matches any ``finding_id`` in the deferred-findings file,
and emits the filtered array to stdout.

Usage:
    filter-deferred.py --deferred <path>

Exit codes:
    0  Success (including missing-file fallback).
    1  Corrupt deferred file or stdin parse failure.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Schema-version dispatch — when the deferred path is colocated with a 2.0
# execution-plan.yaml, source the deferred entries from project.deferred[]
# (filtered to kind=code_finding) instead of opening the JSON file.
try:
    from plan_yaml_deferred import (  # type: ignore[import-not-found]
        find_colocated_plan,
        detect_plan_version,
        read_deferred,
        LegacyPlanError,
    )
except ImportError:  # pragma: no cover
    # When invoked outside the dotfiles tree (e.g. tests with sys.path missing
    # claude/tools/lib), fall back to legacy JSON-only behaviour.
    find_colocated_plan = None  # type: ignore[assignment]


def _load_from_2_0_plan(path: Path) -> list[dict] | None:
    """Return deferred entries from a 2.0 plan colocated with ``path``.

    Returns ``None`` when no 2.0 plan is found and the caller should fall
    back to the legacy JSON file behaviour.
    """
    if find_colocated_plan is None:
        return None
    plan = find_colocated_plan(path.parent if path.is_file() else path)
    if not plan or detect_plan_version(plan) != "2.0":
        return None
    try:
        entries = read_deferred(plan, kind_filter="code_finding")
    except LegacyPlanError:
        return None
    # Normalise to legacy {finding_id} shape for downstream consumers.
    return [{"finding_id": e["finding_id"], **e} for e in entries if "finding_id" in e]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Filter normalised findings against deferred-findings.json.",
    )
    parser.add_argument(
        "--deferred",
        required=True,
        help="Path to deferred-findings.json",
    )
    args = parser.parse_args()

    deferred_path = Path(args.deferred)

    # 2.0 plan colocation routing — supersedes the JSON file when present.
    yaml_entries = _load_from_2_0_plan(deferred_path)
    if yaml_entries is not None:
        deferred_ids = {e["finding_id"] for e in yaml_entries}
        try:
            findings = json.loads(sys.stdin.read())
        except json.JSONDecodeError:
            print("filter-deferred: stdin is not valid JSON", file=sys.stderr)
            return 1
        if not isinstance(findings, list):
            print("filter-deferred: stdin must be a JSON array", file=sys.stderr)
            return 1
        filtered = [f for f in findings if f.get("id") not in deferred_ids]
        print(json.dumps(filtered, indent=2))
        return 0

    # ------------------------------------------------------------------
    # Load deferred-findings file
    # ------------------------------------------------------------------
    try:
        with open(args.deferred) as f:
            raw = f.read()
    except FileNotFoundError:
        # REQ-3: missing file → pass through unfiltered
        try:
            findings = json.loads(sys.stdin.read())
        except json.JSONDecodeError:
            print("filter-deferred: stdin is not valid JSON", file=sys.stderr)
            return 1
        print(
            "no deferred-findings.json \u2014 running unfiltered",
            file=sys.stderr,
        )
        print(json.dumps(findings, indent=2))
        return 0

    # Parse deferred JSON
    if not raw.strip():
        # EC-4.1: empty 0-byte file is corrupt
        print(
            "deferred-findings.json corrupt (empty file) \u2014 restore from git or delete to unfilter",
            file=sys.stderr,
        )
        return 1

    try:
        deferred = json.loads(raw)
    except json.JSONDecodeError:
        # REQ-4: corrupt JSON
        print(
            "deferred-findings.json corrupt (invalid JSON) \u2014 restore from git or delete to unfilter",
            file=sys.stderr,
        )
        return 1

    if not isinstance(deferred, list):
        # EC-4.2: valid JSON but wrong type
        print(
            "deferred-findings.json corrupt (not a JSON array) \u2014 restore from git or delete to unfilter",
            file=sys.stderr,
        )
        return 1

    # EC-4.3: validate all entries have finding_id
    for entry in deferred:
        if "finding_id" not in entry:
            print(
                "deferred-findings.json corrupt \u2014 entry missing finding_id",
                file=sys.stderr,
            )
            return 1

    # ------------------------------------------------------------------
    # Build deferred ID set (natural dedup — EC-2.4)
    # ------------------------------------------------------------------
    deferred_ids = {entry["finding_id"] for entry in deferred}

    # ------------------------------------------------------------------
    # Read and filter findings from stdin
    # ------------------------------------------------------------------
    try:
        findings = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        print("filter-deferred: stdin is not valid JSON", file=sys.stderr)
        return 1
    active = [f for f in findings if f["id"] not in deferred_ids]

    suppressed = len(findings) - len(active)
    print(
        f"filter-at-ingestion: {suppressed} deferred suppressed, {len(active)} active findings",
        file=sys.stderr,
    )

    print(json.dumps(active, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
