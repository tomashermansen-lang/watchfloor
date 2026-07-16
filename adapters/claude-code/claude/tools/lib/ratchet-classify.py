#!/usr/bin/env python3
"""Classify normalised findings into MUST-fix / SHOULD-fix / MAY-defer tiers.

Reads a JSON array of normalised findings from stdin, compares each
finding's file:line against the branch diff (three-dot), and emits a
JSON object with three tier arrays.

Usage:
    ratchet-classify.py [--diff-base <ref>]

stdin:  JSON array of normalised findings (from get-findings.sh --no-filter)
stdout: JSON object {"must_fix": [...], "should_fix": [...], "may_defer": [...]}

Exit codes:
    0  Success
    1  Invalid --diff-base or git failure
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

_SAFE_REF_RE = re.compile(r"^[a-zA-Z0-9/_.\-]+$")


def _validate_diff_base(ref: str) -> None:
    if not _SAFE_REF_RE.match(ref):
        print(f"ratchet-classify: invalid --diff-base: {ref}", file=sys.stderr)
        sys.exit(1)


def _run_git_diff_name_only(diff_base: str) -> list[str]:
    """Return list of changed file paths from three-dot diff."""
    result = subprocess.run(
        ["git", "diff", f"{diff_base}...HEAD", "--name-only", "--diff-filter=ACMR"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"ratchet-classify: git diff failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return [line for line in result.stdout.strip().splitlines() if line]


def _run_git_diff(diff_base: str) -> str:
    """Return the full unified diff text from three-dot diff."""
    result = subprocess.run(
        ["git", "diff", f"{diff_base}...HEAD", "--find-renames"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"ratchet-classify: git diff failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def _extract_file_path(header_line: str) -> str | None:
    """Extract file path from a +++ diff header, or None for /dev/null."""
    path = header_line[4:]
    if path.startswith("b/"):
        path = path[2:]
    return None if path == "/dev/null" else path


def _parse_hunk_start(hunk_line: str) -> int | None:
    """Extract destination start line from @@ hunk header."""
    m = re.search(r"\+(\d+)", hunk_line)
    return int(m.group(1)) if m else None


def _track_content_line(
    line: str, current_file: str, current_line: int, added: dict[str, set[int]],
) -> int:
    """Process a content line (added/deleted/context) and return updated line counter."""
    if line.startswith("+"):
        added[current_file].add(current_line)
        return current_line + 1
    if line.startswith("-"):
        return current_line
    return current_line + 1


def parse_added_lines(diff_text: str) -> dict[str, set[int]]:
    """Parse unified diff to extract added line numbers per file.

    Returns a dict mapping filename → set of added line numbers.
    Skips binary files and deleted files (destination /dev/null).
    """
    added: dict[str, set[int]] = {}
    current_file: str | None = None
    current_line = 0

    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            current_file = _extract_file_path(line)
            if current_file is not None:
                added.setdefault(current_file, set())
            continue

        if line.startswith("Binary files"):
            continue

        if line.startswith("@@"):
            current_line = _parse_hunk_start(line) or current_line
            continue

        if current_file is not None:
            current_line = _track_content_line(line, current_file, current_line, added)

    return added


def classify(
    findings: list[dict],
    diff_base: str = "main",
) -> dict[str, list[dict]]:
    """Classify findings into tiers based on git diff scope."""
    changed_files = set(_run_git_diff_name_only(diff_base))
    diff_text = _run_git_diff(diff_base)
    added_lines = parse_added_lines(diff_text)

    # Dedupe by `id` (content-addressed: tool + rule + file + content_hash).
    # Multiple scanners may surface the same finding (e.g. ruff and shellcheck
    # both reporting on a polyglot file), and `commit-preflight.sh` accumulates
    # all scanner outputs before classification — without dedup, the same
    # finding ends up counted N times where N = scanners-that-fired.
    seen: set[str] = set()
    deduped: list[dict] = []
    for finding in findings:
        fid = finding.get("id")
        if fid is None or fid in seen:
            continue
        seen.add(fid)
        deduped.append(finding)

    result: dict[str, list[dict]] = {
        "must_fix": [],
        "should_fix": [],
        "may_defer": [],
    }

    for finding in deduped:
        f = dict(finding)
        file_path = f["file"]

        if file_path not in changed_files:
            f["tier"] = "may_defer"
            result["may_defer"].append(f)
        elif file_path in added_lines and f["line"] in added_lines[file_path]:
            f["tier"] = "must_fix"
            result["must_fix"].append(f)
        else:
            f["tier"] = "should_fix"
            result["should_fix"].append(f)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Classify findings into MUST/SHOULD/MAY tiers.",
    )
    parser.add_argument(
        "--diff-base", default="main",
        help="Git ref for three-dot diff base (default: main)",
    )
    args = parser.parse_args()

    _validate_diff_base(args.diff_base)

    try:
        findings = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        print("ratchet-classify: stdin is not valid JSON", file=sys.stderr)
        return 1

    result = classify(findings, diff_base=args.diff_base)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
