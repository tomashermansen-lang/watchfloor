#!/usr/bin/env python3
"""Partition normalised findings into skip/propose/fix groups.

Reads normalised scanner output, applies allowlist/never_touch filtering,
and emits categorised JSON. Used by grinder-static.sh for the static-
analysis grinder pass (pass-3).

CLI:
    python3 grinder-static-partition.py \
        --files-json '<files_json>' \
        --allowlist '<newline-separated rules>' \
        --never-touch '<newline-separated patterns>'

Output: JSON on stdout with keys: fix, propose, skip_count, propose_count, fix_count
"""
from __future__ import annotations

import argparse
import json
import sys
from fnmatch import fnmatch


def partition_findings(
    findings: list[dict],
    allowlist: list[str],
    never_touch: list[str],
) -> dict:
    """Partition findings into skip/propose/fix groups.

    Args:
        findings: List of normalised finding dicts (tool, rule, file, line, ...).
        allowlist: Rule IDs approved for automated fixing.
        never_touch: Glob patterns for files that must never be modified.

    Returns:
        Dict with keys: fix, propose, skip_count, propose_count, fix_count.
    """
    allowlist_set = set(allowlist)
    fix: list[dict] = []
    propose: list[dict] = []
    skip_count = 0

    for finding in findings:
        rule = finding.get("rule")
        file_path = finding.get("file", "")

        # EC-1.2: Finding with missing rule field — skip with warning
        if rule is None:
            print(
                f"static: finding missing rule field -- skipping: {finding.get('id', 'unknown')}",
                file=sys.stderr,
            )
            skip_count += 1
            continue

        # REQ-2: Check never_touch_files first (takes precedence over allowlist)
        if _matches_never_touch(file_path, never_touch):
            skip_count += 1
            continue

        # REQ-1: Check allowlist
        if rule in allowlist_set:
            fix.append(finding)
        else:
            propose.append(finding)

    return {
        "fix": fix,
        "propose": propose,
        "skip_count": skip_count,
        "propose_count": len(propose),
        "fix_count": len(fix),
    }


def _matches_never_touch(file_path: str, never_touch: list[str]) -> bool:
    """Check if file_path matches any never_touch glob pattern."""
    for pattern in never_touch:
        if fnmatch(file_path, pattern):
            return True
    return False


def main() -> None:
    parser = argparse.ArgumentParser(description="Partition normalised findings")
    parser.add_argument("--files-json", required=True, help="JSON array of batch files")
    parser.add_argument("--allowlist", default="", help="Newline-separated rule IDs")
    parser.add_argument("--never-touch", default="", help="Newline-separated glob patterns")
    parser.add_argument("--findings-json", default="", help="Path to normalised findings JSON file")
    args = parser.parse_args()

    # Parse inputs
    batch_files = json.loads(args.files_json)
    allowlist = [r for r in args.allowlist.split("\n") if r.strip()]
    never_touch = [p for p in args.never_touch.split("\n") if p.strip()]

    # Load findings
    if args.findings_json:
        with open(args.findings_json) as f:
            all_findings = json.load(f)
    else:
        all_findings = json.load(sys.stdin)

    # Filter findings to batch files only
    batch_files_set = set(batch_files)
    findings = [f for f in all_findings if f.get("file") in batch_files_set]

    result = partition_findings(findings, allowlist, never_touch)
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
