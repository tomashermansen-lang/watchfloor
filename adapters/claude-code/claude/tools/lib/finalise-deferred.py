#!/usr/bin/env python3
"""Finalise docs/grinder/deferred-findings.json after all grinder passes.

Collects deferred findings from proposals.md (static pass) and
cve-review.md (CVE pass), generates schema-compliant entries, deduplicates
against existing entries, and validates the result.

CLI:
    python3 finalise-deferred.py \
        --grinder-dir <docs/grinder/path> \
        --schema-dir <schema/path>
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import jsonschema

# Minimum length for the free-text reason field on deferred entries.
# Mirrors plan_yaml_deferred.DEFERRED_REASON_MIN_CHARS — duplicated as a
# constant rather than imported because this script must be runnable
# stand-alone without the lib on sys.path.
MIN_REASON_CHARS = 40

# Schema-version routing — when a 2.0 plan is colocated, write deferred
# entries into project.deferred[] inside execution-plan.yaml instead of the
# legacy JSON file.
try:
    from plan_yaml_deferred import (  # type: ignore[import-not-found]
        LegacyPlanError,
        detect_plan_version,
        find_colocated_plan,
        make_code_finding_entry,
        read_deferred,
        write_deferred,
    )
except ImportError:  # pragma: no cover
    find_colocated_plan = None  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

_PROPOSAL_RE = re.compile(r"^### (\S+) — (.+?):(\d+)\s*$")
_PROPOSAL_FIELD_RE = re.compile(r"^- \*\*(\w+):\*\* (.+)$")

_CVE_REVIEW_RE = re.compile(r"^### (CVE-\S+|PYSEC-\S+|GHSA-\S+) — (.+)$")
_CVE_FIELD_RE = re.compile(r"^- \*\*(.+?):\*\* (.+)$")


def _content_hash(text: str) -> str:
    """8-char hex SHA-256 hash."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:8]


def _get_owner() -> str:
    """Get git user.name or fallback."""
    try:
        result = subprocess.run(
            ["git", "config", "user.name"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        name = result.stdout.strip()
        if name:
            return name
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    return os.environ.get("USER", "unknown")


def _today() -> str:
    """ISO 8601 date string."""
    return datetime.date.today().isoformat()


def _make_finding_id(tool: str, rule: str, file_stem: str, content_hash: str) -> str:
    """Compose finding_id matching schema pattern.

    Pattern: ^[a-z0-9-]+:[A-Z0-9]+-[^-]+-[a-f0-9]{8}$
    The rule part must be [A-Z0-9]+ (no hyphens), so strip them.
    The file_stem must be [^-]+ (no hyphens), so replace with underscores.
    """
    rule_clean = re.sub(r"[^A-Z0-9]", "", rule.upper())
    stem_clean = file_stem.replace("-", "_")
    return f"{tool}:{rule_clean}-{stem_clean}-{content_hash}"


def _ensure_min_reason(reason: str, context: str = "") -> str:
    """Ensure reason is at least ``MIN_REASON_CHARS`` characters."""
    if len(reason) >= MIN_REASON_CHARS:
        return reason
    if context:
        reason = f"{reason} — {context}"
    while len(reason) < MIN_REASON_CHARS:
        reason += " (see grinder report for details)"
    return reason[: max(MIN_REASON_CHARS, len(reason))]


def parse_proposals(content: str) -> list[dict]:
    """Parse proposals.md into deferred finding entries."""
    entries: list[dict] = []
    lines = content.splitlines()
    i = 0
    while i < len(lines):
        m = _PROPOSAL_RE.match(lines[i])
        if not m:
            i += 1
            continue

        rule = m.group(1)
        file_path = m.group(2)
        line = int(m.group(3))
        fields: dict[str, str] = {}

        i += 1
        while i < len(lines) and lines[i].startswith("- **"):
            fm = _PROPOSAL_FIELD_RE.match(lines[i])
            if fm:
                fields[fm.group(1).lower()] = fm.group(2)
            i += 1

        tool = fields.get("tool", "unknown")
        severity = fields.get("severity", "unknown")
        message = fields.get("message", "")

        file_stem = os.path.basename(file_path)
        ch = _content_hash(f"{tool}:{rule}:{file_path}:{line}")
        finding_id = _make_finding_id(tool, rule, file_stem, ch)

        reason = _ensure_min_reason(
            f"Static analysis proposal: {rule} in {file_path}",
            f"{message} (severity: {severity})",
        )

        entries.append(
            {
                "finding_id": finding_id,
                "rule": rule,
                "file": file_path,
                "line": line,
                "state": "Deferred",
                "reason": reason,
                "owner": _get_owner(),
                "reviewed_at": _today(),
            }
        )

    return entries


def parse_cve_review(content: str) -> list[dict]:
    """Parse cve-review.md into deferred finding entries."""
    entries: list[dict] = []
    lines = content.splitlines()
    i = 0
    while i < len(lines):
        m = _CVE_REVIEW_RE.match(lines[i])
        if not m:
            i += 1
            continue

        cve_id = m.group(1)
        pkg_info = m.group(2).strip()
        fields: dict[str, str] = {}

        i += 1
        while i < len(lines) and lines[i].startswith("- **"):
            fm = _CVE_FIELD_RE.match(lines[i])
            if fm:
                fields[fm.group(1).lower()] = fm.group(2)
            i += 1

        severity = fields.get("severity", "unknown")
        scanner = fields.get("scanner", "pip-audit")
        impact = fields.get("impact", "")
        defer_reason = fields.get("reason deferred", "deferred")

        # Extract package name from pkg_info (format: "pkg (v1 → v2)")
        pkg_name = pkg_info.split("(")[0].strip() if "(" in pkg_info else pkg_info

        ch = _content_hash(f"{scanner}:{cve_id}:{pkg_name}:1")
        finding_id = _make_finding_id(scanner, cve_id, pkg_name, ch)

        reason = _ensure_min_reason(
            f"CVE deferral: {cve_id} in {pkg_name} ({severity})",
            f"{defer_reason}. {impact}",
        )

        entries.append(
            {
                "finding_id": finding_id,
                "rule": cve_id,
                "file": pkg_name,
                "line": 1,
                "state": "Deferred",
                "reason": reason,
                "owner": _get_owner(),
                "reviewed_at": _today(),
            }
        )

    return entries


# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------


def _deduplicate(existing: list[dict], new_entries: list[dict]) -> list[dict]:
    """Merge new entries into existing, deduplicating by finding_id."""
    by_id: dict[str, dict] = {}
    for e in existing:
        by_id[e["finding_id"]] = e
    for e in new_entries:
        if e["finding_id"] in by_id:
            # Update reviewed_at only
            by_id[e["finding_id"]]["reviewed_at"] = e["reviewed_at"]
        else:
            by_id[e["finding_id"]] = e
    return list(by_id.values())


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def finalise_deferred(
    grinder_dir: str,
    schema_dir: str,
) -> list[dict]:
    """Finalise deferred findings. Returns the list (does not write to disk).

    Collects from proposals.md and cve-review.md, deduplicates against
    existing deferred-findings.json.
    """
    grinder_path = Path(grinder_dir)
    schema_path = Path(schema_dir)

    # Read existing deferred
    deferred_file = grinder_path / "deferred-findings.json"
    existing: list[dict] = []
    if deferred_file.is_file():
        try:
            existing = json.loads(deferred_file.read_text())
        except json.JSONDecodeError:
            existing = []

    # Collect from proposals.md
    new_entries: list[dict] = []
    proposals_file = grinder_path / "proposals.md"
    if proposals_file.is_file():
        new_entries.extend(parse_proposals(proposals_file.read_text()))

    # Collect from cve-review.md
    cve_review_file = grinder_path / "cve-review.md"
    if cve_review_file.is_file():
        new_entries.extend(parse_cve_review(cve_review_file.read_text()))

    # Deduplicate
    result = _deduplicate(existing, new_entries)

    # Validate
    schema_file = schema_path / "deferred-findings.schema.json"
    if schema_file.is_file():
        schema = json.loads(schema_file.read_text())
        jsonschema.validate(result, schema, format_checker=jsonschema.FormatChecker())

    return result


def main() -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="Finalise deferred-findings.json")
    parser.add_argument("--grinder-dir", required=True)
    parser.add_argument("--schema-dir", required=True)
    args = parser.parse_args()

    try:
        result = finalise_deferred(args.grinder_dir, args.schema_dir)
    except (ValueError, jsonschema.ValidationError) as e:
        print(f"finalise-deferred: {e}", file=sys.stderr)
        return 1

    # 2.0 plan colocation routing — append (kind: code_finding) into the YAML.
    if find_colocated_plan is not None:
        plan = find_colocated_plan(Path(args.grinder_dir))
        if plan and detect_plan_version(plan) == "2.0":
            try:
                existing = read_deferred(plan)
                existing_ids = {e.get("id") for e in existing}
                merged = list(existing)
                for entry in result:
                    fid = entry.get("finding_id", "")
                    eid = entry.get("id") or f"DF-{fid.split(':')[-1][:8]}"
                    if eid in existing_ids:
                        continue
                    merged.append(
                        make_code_finding_entry(
                            id=eid,
                            finding_id=fid,
                            rule=entry.get("rule", ""),
                            file=entry.get("file", ""),
                            line=int(entry.get("line", 0) or 0),
                            state=entry.get("state", "Deferred"),
                            reason=entry.get("reason", ""),
                            owner=entry.get("owner", "finalise-deferred"),
                            reviewed_at=entry.get("reviewed_at", entry.get("date", "")),
                            review_trigger=entry.get("review_trigger", "manual-review"),
                            ticket=entry.get("ticket"),
                        )
                    )
                write_deferred(plan, merged)
                print(
                    f"finalise-deferred: routed {len(result)} entries into 2.0 plan {plan}",
                    file=sys.stderr,
                )
                return 0
            except LegacyPlanError:
                pass

    # Legacy 1.x — write deferred-findings.json next to grinder-dir.
    out_path = Path(args.grinder_dir) / "deferred-findings.json"
    out_path.write_text(json.dumps(result, indent=2) + "\n")
    print(f"finalise-deferred: wrote {len(result)} entries to {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
