#!/usr/bin/env python3
"""Parse coverage reports (vitest/Istanbul, pytest-cov) to normalised JSON.

CLI:
    python3 parse-coverage.py --format vitest|pytest-cov|auto \
        --report-path <path> [--project-root <path>]

Output (stdout):
    {"project_wide": 0.72, "files": {"src/foo.ts": 0.45, ...}}

Exit codes:
    0 — success
    1 — error (missing file, unparseable, empty report)
"""
from __future__ import annotations

import argparse
import json
import os
import sys


def parse_vitest(data: dict, project_root: str) -> dict:
    """Parse vitest/Istanbul coverage-final.json (also handles v8 format).

    Both Istanbul and v8 use the same s-map structure:
    { "/abs/path/file.ts": { "s": {"0": count, "1": count, ...}, ... } }
    """
    if not data:
        print("coverage: empty coverage report", file=sys.stderr)
        sys.exit(1)

    files: dict[str, float] = {}
    total_covered = 0
    total_stmts = 0

    # Normalise project_root for stripping
    root = project_root.rstrip("/") + "/" if project_root else ""

    for abs_path, file_data in data.items():
        if not isinstance(file_data, dict) or "s" not in file_data:
            continue
        stmts = file_data["s"]
        covered = sum(1 for v in stmts.values() if v > 0)
        total = len(stmts)
        if total == 0:
            continue

        total_covered += covered
        total_stmts += total

        # Normalise path: strip project root prefix
        rel_path = abs_path
        if root and abs_path.startswith(root):
            rel_path = abs_path[len(root):]

        files[rel_path] = covered / total

    if not files:
        print("coverage: no parseable files in coverage report", file=sys.stderr)
        sys.exit(1)

    project_wide = total_covered / total_stmts if total_stmts > 0 else 0.0
    return {"project_wide": project_wide, "files": files}


def parse_pytest_cov(data: dict) -> dict:
    """Parse pytest-cov coverage.json.

    { "files": { "path": { "summary": { "percent_covered": 85.0 } } },
      "totals": { "percent_covered": 72.5 } }
    """
    if "files" not in data:
        print("coverage: missing 'files' key in pytest-cov report", file=sys.stderr)
        sys.exit(1)

    files_data = data["files"]
    if not files_data:
        print("coverage: empty files in pytest-cov report", file=sys.stderr)
        sys.exit(1)

    files: dict[str, float] = {}
    for path, info in files_data.items():
        pct = info.get("summary", {}).get("percent_covered", 0.0)
        files[path] = pct / 100.0

    # Use totals if available, otherwise average
    totals = data.get("totals", {})
    project_wide = totals.get("percent_covered", 0.0) / 100.0

    return {"project_wide": project_wide, "files": files}


def detect_format(data: dict) -> str:
    """Auto-detect coverage report format.

    vitest/Istanbul: top-level keys are file paths with s/b/f sub-objects.
    pytest-cov: top-level 'files' key with 'summary' sub-objects.
    """
    # Check for pytest-cov structure first (has explicit 'files' key)
    if "files" in data and isinstance(data["files"], dict):
        sample = next(iter(data["files"].values()), None)
        if isinstance(sample, dict) and "summary" in sample:
            return "pytest-cov"

    # Check for vitest/Istanbul structure (keys are paths with s/b/f)
    for key, val in data.items():
        if isinstance(val, dict) and "s" in val:
            return "vitest"

    return "unknown"


def main() -> None:
    parser = argparse.ArgumentParser(description="Parse coverage reports to normalised JSON.")
    parser.add_argument("--format", required=True, choices=["vitest", "pytest-cov", "auto"],
                        dest="fmt")
    parser.add_argument("--report-path", required=True)
    parser.add_argument("--project-root", default="")
    args = parser.parse_args()

    # Read report
    report_path = args.report_path
    if not os.path.isfile(report_path):
        print(f"coverage: no coverage report found at {report_path}", file=sys.stderr)
        sys.exit(1)

    try:
        with open(report_path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"coverage: cannot parse coverage report: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(data, dict) or not data:
        print("coverage: empty or invalid coverage report", file=sys.stderr)
        sys.exit(1)

    # Determine format
    fmt = args.fmt
    if fmt == "auto":
        fmt = detect_format(data)
        if fmt == "unknown":
            print("coverage: cannot auto-detect report format", file=sys.stderr)
            sys.exit(1)

    # Parse
    if fmt == "vitest":
        result = parse_vitest(data, args.project_root)
    elif fmt == "pytest-cov":
        result = parse_pytest_cov(data)
    else:
        print(f"coverage: unsupported format: {fmt}", file=sys.stderr)
        sys.exit(1)

    print(json.dumps(result))


if __name__ == "__main__":
    main()
