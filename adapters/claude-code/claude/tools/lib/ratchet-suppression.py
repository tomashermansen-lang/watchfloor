#!/usr/bin/env python3
"""Scan branch diff for inline suppression patterns on added lines.

Reports violations with file:line references. Does NOT decide whether to
block — the caller (commit-preflight.sh) makes that decision.

Usage:
    ratchet-suppression.py [--diff-base <ref>]

stdout: JSON array of {"file": str, "line": int, "pattern": str, "content": str}
Exit 0 always (caller decides whether to block).
Exit 1 only on invalid --diff-base.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

_SAFE_REF_RE = re.compile(r"^[a-zA-Z0-9/_.\-]+$")

# Suppression patterns — each is (compiled_regex, human_label)
_SUPPRESSION_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"#\s*noqa\b"), "# noqa"),
    (re.compile(r"//\s*eslint-disable"), "// eslint-disable"),
    (re.compile(r"/\*\s*eslint-disable"), "/* eslint-disable"),
    (re.compile(r"#\s*type:\s*ignore\b"), "# type: ignore"),
    (re.compile(r"//\s*@ts-ignore\b"), "// @ts-ignore"),
    (re.compile(r"//\s*@ts-expect-error\b"), "// @ts-expect-error"),
    (re.compile(r"/\*\s*istanbul\s+ignore\b"), "/* istanbul ignore"),
]


def _validate_diff_base(ref: str) -> None:
    if not _SAFE_REF_RE.match(ref):
        print(f"ratchet-suppression: invalid --diff-base: {ref}", file=sys.stderr)
        sys.exit(1)


def _run_git_diff(diff_base: str) -> str:
    """Return the full unified diff text from three-dot diff."""
    result = subprocess.run(
        ["git", "diff", f"{diff_base}...HEAD", "--find-renames"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"ratchet-suppression: git diff failed: {result.stderr.strip()}", file=sys.stderr)
        return ""
    return result.stdout


def _count_unescaped_quotes(prefix: str, quote_char: str, triple: str) -> int:
    """Count unescaped single-char quotes, skipping triple-quote sequences."""
    count = 0
    i = 0
    while i < len(prefix):
        if i + 2 < len(prefix) and prefix[i:i + 3] == triple:
            i += 3
            continue
        if prefix[i] == quote_char and (i == 0 or prefix[i - 1] != "\\"):
            count += 1
        i += 1
    return count


def _has_odd_triple_quotes(prefix: str, triple: str) -> bool:
    """Check if prefix contains an odd number of triple-quote sequences."""
    return triple in prefix and prefix.count(triple) % 2 == 1


def _is_inside_string(line: str, match_start: int) -> bool:
    """Heuristic: check if match_start is inside a string literal.

    Count unescaped quote characters before the match position.
    If the match appears after an odd number of any quote type,
    it's likely inside a string. Err on the side of permitting
    (return True when ambiguous).
    """
    prefix = line[:match_start]

    if prefix.count("`") % 2 == 1:
        return True
    if _has_odd_triple_quotes(prefix, '"""'):
        return True
    if _has_odd_triple_quotes(prefix, "'''"):
        return True
    if _count_unescaped_quotes(prefix, '"', '"""') % 2 == 1:
        return True
    if _count_unescaped_quotes(prefix, "'", "'''") % 2 == 1:
        return True
    return False


def _extract_diff_file_path(header_line: str) -> str | None:
    """Extract file path from a +++ diff header, or None for /dev/null."""
    path = header_line[4:]
    if path.startswith("b/"):
        path = path[2:]
    return None if path == "/dev/null" else path


def _parse_hunk_start_line(hunk_line: str) -> int | None:
    """Extract destination start line from @@ hunk header."""
    m = re.search(r"\+(\d+)", hunk_line)
    return int(m.group(1)) if m else None


def parse_added_lines_from_diff(diff_text: str) -> list[tuple[str, int, str]]:
    """Parse unified diff to extract added lines.

    Returns list of (filename, line_number, line_content) for added lines.
    """
    results: list[tuple[str, int, str]] = []
    current_file: str | None = None
    current_line = 0

    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            current_file = _extract_diff_file_path(line)
            continue

        if line.startswith("@@"):
            start = _parse_hunk_start_line(line)
            if start is not None:
                current_line = start
            continue

        if current_file is None:
            continue

        if line.startswith("+"):
            results.append((current_file, current_line, line[1:]))
            current_line += 1
        elif not line.startswith("-"):
            current_line += 1

    return results


def scan_suppressions(diff_base: str = "main") -> list[dict]:
    """Scan branch diff for inline suppression patterns on added lines."""
    diff_text = _run_git_diff(diff_base)
    return scan_suppressions_from_diff(diff_text)


def scan_suppressions_from_diff(diff_text: str) -> list[dict]:
    """Scan a diff string for inline suppression patterns on added lines."""
    added_lines = parse_added_lines_from_diff(diff_text)
    violations: list[dict] = []

    for file_path, line_num, content in added_lines:
        for pattern, label in _SUPPRESSION_PATTERNS:
            for m in pattern.finditer(content):
                if _is_inside_string(content, m.start()):
                    continue
                violations.append({
                    "file": file_path,
                    "line": line_num,
                    "pattern": label,
                    "content": content.strip(),
                })

    return violations


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Scan branch diff for inline suppression patterns.",
    )
    parser.add_argument(
        "--diff-base", default="main",
        help="Git ref for three-dot diff base (default: main)",
    )
    args = parser.parse_args()

    _validate_diff_base(args.diff_base)

    violations = scan_suppressions(diff_base=args.diff_base)
    print(json.dumps(violations, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
