#!/usr/bin/env python3
"""Deferred-findings audit report generator.

Reads deferred-findings.json and produces a markdown report on stdout
flagging patterns that need human attention: stale deferrals, over-deferred
rules, missing tickets, and auto-generated reasons.

Usage: grinder-audit.py [path]
  path  Path to deferred-findings.json (default: docs/grinder/deferred-findings.json)

Exit codes:
  0  Report generated (including empty-findings case)
  1  File not found or corrupt JSON
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from datetime import date, timedelta
from pathlib import Path

# Allow ``import schema_paths`` from ``claude/tools/lib`` regardless of how
# this script is invoked.
_LIB_DIR = Path(__file__).resolve().parent / "lib"
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))

import schema_paths  # noqa: E402


# Schema path for entry validation: resolved lazily via lib/schema_paths.py
# (probes deployed ``~/.claude/schema/`` first, falls back to
# ``<monorepo>/core/schema/``). Resolution is deferred to first call so that
# importing this module never raises when the schema is absent — pre-T3
# behaviour is preserved (the .exists() guard at the call site decides).
def _schema_path() -> Path:
    return schema_paths.schema_path("deferred-findings.schema.json")


DEFAULT_PATH = "docs/grinder/deferred-findings.json"

TEMPLATE_PATTERNS = [
    re.compile(r"^Pre-existing"),
    re.compile(r"^Legacy code"),
    re.compile(r"^Not changed in this PR"),
]

ALLOWLIST_THRESHOLD = 5
STALE_DAYS = 90


# ---------------------------------------------------------------------------
# Audit checks — each returns a list of report lines (empty = no findings)
# ---------------------------------------------------------------------------


def check_allowlist_candidates(entries: list[dict], today: date) -> list[str]:
    """Flag rules appearing >= ALLOWLIST_THRESHOLD times."""
    counts = Counter(e["rule"] for e in entries)
    lines = []
    for rule, count in sorted(counts.items(), key=lambda x: -x[1]):
        if count >= ALLOWLIST_THRESHOLD:
            lines.append(f"- rule {rule} deferred {count} times")
    return lines


def check_stale_deferrals(entries: list[dict], today: date) -> list[str]:
    """Flag entries with review_trigger=quarterly and reviewed_at > 90 days."""
    threshold = today - timedelta(days=STALE_DAYS)
    lines = []
    for e in entries:
        if e.get("review_trigger") != "quarterly":
            continue
        reviewed_at = date.fromisoformat(e["reviewed_at"])
        if reviewed_at < threshold:
            lines.append(f"- `{e['finding_id']}` in `{e['file']}` (reviewed {e['reviewed_at']})")
    return lines


def check_missing_tickets(entries: list[dict], today: date) -> list[str]:
    """Flag entries with state=Deferred and no ticket field."""
    lines = []
    for e in entries:
        if e.get("state") == "Deferred" and "ticket" not in e:
            lines.append(f"- `{e['finding_id']}` in `{e['file']}`")
    return lines


def check_template_reasons(entries: list[dict], today: date) -> list[str]:
    """Flag entries whose reason starts with template patterns."""
    lines = []
    for e in entries:
        reason = e.get("reason", "")
        for pattern in TEMPLATE_PATTERNS:
            if pattern.match(reason):
                lines.append(f"- `{e['finding_id']}`: {reason[:60]}...")
                break
    return lines


# Dispatch list (OCP): add new checks by appending here
CHECKS: list[tuple[str, object]] = [
    ("Candidate for allowlist promotion", check_allowlist_candidates),
    ("Stale deferrals requiring review", check_stale_deferrals),
    ("Deferred without ticket reference", check_missing_tickets),
    ("Likely auto-generated reason", check_template_reasons),
]


# ---------------------------------------------------------------------------
# Core functions
# ---------------------------------------------------------------------------


def _resolve_deferred_source(path: str) -> tuple[str, list[dict] | None]:
    """Probe for a 2.0 plan colocated with ``path``.

    Returns ``(actual_source_path, parsed_entries_or_None)``. When a 2.0
    plan is found, this returns the JSON output of the
    ``plan_yaml_deferred dump`` subprocess so this module stays stdlib-only
    in its direct imports.
    """
    import subprocess

    helper = Path(__file__).resolve().parent / "lib" / "plan_yaml_deferred.py"
    target = Path(path).parent if Path(path).is_file() else Path(path)
    if not helper.exists():
        return path, None
    proc = subprocess.run(
        [sys.executable, str(helper), "dump", "--", str(target)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return path, None
    try:
        entries = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return path, None
    if not isinstance(entries, list):
        return path, None
    if entries and isinstance(entries[0], dict) and entries[0].get("kind"):
        return f"{target}#deferred (2.0 plan)", entries
    return path, None


def load_findings(path: str) -> list[dict]:
    """Load JSON from path. Raises SystemExit on error."""
    actual, parsed = _resolve_deferred_source(path)
    if parsed is not None:
        return parsed
    p = Path(path)
    if not p.exists():
        print(f"{path} not found", file=sys.stderr)
        sys.exit(1)
    try:
        data = json.loads(p.read_text())
    except json.JSONDecodeError:
        print(f"{path}: invalid JSON", file=sys.stderr)
        sys.exit(1)
    return data


def validate_entries(entries: list[dict]) -> list[str]:
    """Validate entries against schema, return warning lines for invalid ones.

    Skips validation gracefully when jsonschema is not installed or the schema
    file is not found (e.g. after sync.sh deploy to ~/.claude/tools/).
    """
    warnings = []
    try:
        import jsonschema
    except ImportError:
        return warnings
    try:
        schema_path = _schema_path()
    except FileNotFoundError:
        return warnings
    if not schema_path.exists():
        return warnings
    schema = json.loads(schema_path.read_text())
    entry_schema = schema.get("$defs", {}).get("finding_entry", schema)
    for i, entry in enumerate(entries):
        try:
            jsonschema.validate(entry, entry_schema)
        except jsonschema.ValidationError as exc:
            fid = entry.get("finding_id", f"entry[{i}]")
            warnings.append(f"Warning: entry `{fid}` failed validation: {exc.message}")
    return warnings


def run_audit(entries: list[dict], today: date) -> str:
    """Run all audit checks and return the formatted report."""
    if not entries:
        return "# Deferred Findings Audit\n\nNo deferred findings.\n"

    validation_warnings = validate_entries(entries)

    sections = []
    for title, check_fn in CHECKS:
        lines = check_fn(entries, today)
        if lines:
            sections.append(f"## {title}\n\n" + "\n".join(lines))

    report = "# Deferred Findings Audit\n\n"
    if validation_warnings:
        report += "## Validation Warnings\n\n" + "\n".join(validation_warnings) + "\n\n"
    if sections:
        report += "\n\n".join(sections) + "\n"
    else:
        report += "No audit flags raised.\n"
    return report


def main(argv: list[str] | None = None) -> None:
    """Parse args, load findings, run audit, print report."""
    args = argv if argv is not None else sys.argv[1:]
    path = args[0] if args else DEFAULT_PATH
    entries = load_findings(path)
    report = run_audit(entries, date.today())
    print(report)


if __name__ == "__main__":
    main()
