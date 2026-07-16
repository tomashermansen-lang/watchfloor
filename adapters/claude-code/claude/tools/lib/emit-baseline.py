#!/usr/bin/env python3
"""Emit docs/grinder/baseline.json after all grinder passes complete.

Reads grinder-plan.yaml to verify all passes are done, collects coverage,
findings counts, and tool versions, then writes a schema-validated
baseline.json.

CLI:
    python3 emit-baseline.py \
        --project-dir <path> \
        --grinder-dir <docs/grinder/path> \
        --schema-dir <schema/path>
"""

from __future__ import annotations

import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

import jsonschema
import yaml


def _all_passes_complete(plan: dict) -> bool:
    """Check that no pass has pending/in_progress/failed batches."""
    for p in plan.get("passes", []):
        for b in p.get("batches", []):
            if b.get("status") in ("pending", "in_progress", "failed"):
                return False
    return True


def _collect_findings_count(grinder_dir: Path) -> dict[str, int]:
    """Count findings per tool from scanner-output/ directory."""
    scanner_dir = grinder_dir / "scanner-output"
    counts: dict[str, int] = {}
    if not scanner_dir.is_dir():
        return counts
    for f in sorted(scanner_dir.iterdir()):
        if f.suffix == ".json":
            tool = f.stem
            try:
                data = json.loads(f.read_text())
                if isinstance(data, list):
                    counts[tool] = len(data)
                else:
                    counts[tool] = 0
            except (json.JSONDecodeError, OSError):
                counts[tool] = 0
    return counts


def _collect_coverage(grinder_dir: Path) -> dict[str, float]:
    """Read coverage data from coverage report if available."""
    for name in ("coverage-report.json", "coverage-final.json", "coverage.json"):
        report = grinder_dir / name
        if report.is_file():
            try:
                data = json.loads(report.read_text())
                if isinstance(data, dict):
                    result: dict[str, float] = {}
                    for k, v in data.items():
                        if isinstance(v, (int, float)) and 0.0 <= v <= 1.0:
                            result[k] = v
                    return result
            except (json.JSONDecodeError, OSError):
                pass
    return {}


def _collect_tool_versions(findings_count: dict[str, int]) -> dict[str, str]:
    """Get version strings for tools that produced findings."""
    versions: dict[str, str] = {}
    for tool in findings_count:
        try:
            result = subprocess.run(
                [tool, "--version"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            version = result.stdout.strip().split("\n")[0] if result.stdout.strip() else "unknown"
            versions[tool] = version
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            versions[tool] = "unknown"
    return versions


def _get_git_sha() -> str:
    """Get current git SHA."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() or "unknown"
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return "unknown"


def emit_baseline(
    project_dir: str,
    grinder_dir: str,
    schema_dir: str,
) -> dict:
    """Emit baseline data. Returns the baseline dict (does not write to disk).

    Raises ValueError if not all passes are complete.
    """
    grinder_path = Path(grinder_dir)
    schema_path = Path(schema_dir)

    # Read plan
    plan_file = grinder_path / "grinder-plan.yaml"
    if plan_file.is_file():
        plan = yaml.safe_load(plan_file.read_text()) or {}
    else:
        plan = {}

    # Verify all passes complete
    if not _all_passes_complete(plan):
        raise ValueError("not all passes complete — cannot emit baseline")

    # Collect data
    findings_count = _collect_findings_count(grinder_path)
    coverage = _collect_coverage(grinder_path)
    tool_versions = _collect_tool_versions(findings_count)
    git_sha = _get_git_sha()

    deferred_findings_ref = "docs/grinder/deferred-findings.json"
    try:
        from plan_yaml_deferred import (
            detect_plan_version,
            find_colocated_plan,
        )

        plan = find_colocated_plan(grinder_path)
        if plan and detect_plan_version(plan) == "2.0":
            try:
                deferred_findings_ref = str(plan.relative_to(Path.cwd())) + "#deferred"
            except ValueError:
                deferred_findings_ref = f"{plan}#deferred"
    except ImportError:  # pragma: no cover
        pass

    baseline = {
        "created_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "git_sha": git_sha,
        "coverage": coverage,
        "findings_count": findings_count,
        "tool_versions": tool_versions,
        "deferred_findings_ref": deferred_findings_ref,
    }

    # Validate against schema
    schema_file = schema_path / "baseline.schema.json"
    if schema_file.is_file():
        schema = json.loads(schema_file.read_text())
        jsonschema.validate(baseline, schema, format_checker=jsonschema.FormatChecker())

    return baseline


def main() -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="Emit baseline.json")
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--grinder-dir", required=True)
    parser.add_argument("--schema-dir", required=True)
    args = parser.parse_args()

    try:
        baseline = emit_baseline(args.project_dir, args.grinder_dir, args.schema_dir)
    except ValueError as e:
        print(f"emit-baseline: {e}", file=sys.stderr)
        return 1

    # Write baseline.json
    out_path = Path(args.grinder_dir) / "baseline.json"
    out_path.write_text(json.dumps(baseline, indent=2) + "\n")
    print(f"emit-baseline: wrote {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
