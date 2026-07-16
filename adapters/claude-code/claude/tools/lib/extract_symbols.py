#!/usr/bin/env python3
"""Symbol-map extractor for the compact predecessor-context block
(backlog #64 + canary A/B/C antipattern fix for working-file re-reads).

Given a file path, emit a JSON array of (name, kind, line_start,
line_end, defined_in) records covering the top-level functions, classes,
and methods. The agent uses this map to navigate large files with
`Read --offset --limit` rather than re-reading the whole file (the
canary measurements showed 18-35 re-reads of `autopilot.sh` per run —
the documented Aider pattern targets exactly this).

Language coverage (incremental):
  .py        → stdlib `ast` (functions, classes, methods)
  .sh / .bash → regex (function foo(), foo() {}, function foo {})
  other      → empty array

tree-sitter would extend coverage to ts/js/go/rust but is not installed
in the sandboxed dev env (network blocked); adding it requires
pyproject.toml + uv sync provisioning. The current shape captures the
bulk of value for the two languages that dominate this repo
(bash orchestrators + python helpers + dashboard server).

Usage:
  python3 extract_symbols.py <file>            # → JSON array on stdout
  python3 extract_symbols.py --format text <f> # → flat text per line

Exit:
  0 on success (including empty array for unsupported extensions)
  2 on argv error
  3 on missing file
"""
from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from collections.abc import Iterable
from pathlib import Path

# Single-line bash function declarations:
#   foo() {
#   function foo() {
#   function foo {
_BASH_FUNC_RE = re.compile(
    r"""
    ^\s*                            # leading indent
    (?:function\s+)?                # optional 'function' keyword
    ([A-Za-z_][A-Za-z0-9_:.\-]*)    # name (rare chars allowed by bash)
    \s*
    (?:\(\)\s*)?                    # optional empty parens
    \{?\s*$                         # optional opening brace
    """,
    re.VERBOSE,
)

# Stricter re-check: require either parens, or 'function' prefix, so we
# don't mis-classify random "name {" lines (heredoc, json fragments).
_BASH_FUNC_STRICT_RE = re.compile(
    r"""
    ^\s*
    (?:
       (?:function\s+)([A-Za-z_][A-Za-z0-9_:.\-]*)\s*(?:\(\))?\s*\{?\s*$
     |
       ([A-Za-z_][A-Za-z0-9_:.\-]*)\s*\(\)\s*\{?\s*$
    )
    """,
    re.VERBOSE,
)


def _extract_python(path: Path) -> list[dict]:
    try:
        tree = ast.parse(path.read_text(errors="replace"))
    except (SyntaxError, ValueError, UnicodeDecodeError):
        # Malformed source — return empty, do not crash. The agent has
        # the file in front of them; the symbol map is best-effort.
        return []

    out: list[dict] = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            out.append({
                "name": node.name,
                "kind": "function",
                "line_start": node.lineno,
                "line_end": getattr(node, "end_lineno", node.lineno),
                "defined_in": str(path),
            })
        elif isinstance(node, ast.ClassDef):
            out.append({
                "name": node.name,
                "kind": "class",
                "line_start": node.lineno,
                "line_end": getattr(node, "end_lineno", node.lineno),
                "defined_in": str(path),
            })
            for sub in node.body:
                if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    out.append({
                        "name": f"{node.name}.{sub.name}",
                        "kind": "method",
                        "line_start": sub.lineno,
                        "line_end": getattr(sub, "end_lineno", sub.lineno),
                        "defined_in": str(path),
                    })
    return out


def _extract_bash(path: Path) -> list[dict]:
    lines = path.read_text(errors="replace").splitlines()
    out: list[dict] = []
    for i, line in enumerate(lines, start=1):
        m = _BASH_FUNC_STRICT_RE.match(line)
        if not m:
            continue
        name = m.group(1) or m.group(2)
        if not name:
            continue
        out.append({
            "name": name,
            "kind": "function",
            "line_start": i,
            "line_end": _find_bash_func_end(lines, i),
            "defined_in": str(path),
        })
    return out


def _find_bash_func_end(lines: list[str], start_idx: int) -> int:
    """Naive brace-balance walk from the function declaration to the
    matching `}`. Returns start_idx on failure so callers always get a
    valid line. Good enough for navigation; not a parser."""
    depth = 0
    seen_open = False
    for j in range(start_idx - 1, len(lines)):  # 0-indexed
        line = lines[j]
        for ch in line:
            if ch == "{":
                depth += 1
                seen_open = True
            elif ch == "}":
                depth -= 1
                if seen_open and depth == 0:
                    return j + 1
    return start_idx


def extract(path: Path) -> list[dict]:
    if not path.exists():
        raise FileNotFoundError(path)
    suffix = path.suffix.lower()
    if suffix == ".py":
        return _extract_python(path)
    if suffix in (".sh", ".bash"):
        return _extract_bash(path)
    # Shebang-based detection for extension-less scripts.
    try:
        first = path.read_text(errors="replace").splitlines()[0]
    except (OSError, IndexError):
        return []
    if first.startswith("#!") and ("bash" in first or "sh" in first):
        return _extract_bash(path)
    if first.startswith("#!") and "python" in first:
        return _extract_python(path)
    return []


def format_text(symbols: Iterable[dict]) -> str:
    """Human-readable one-line-per-symbol output used inside the
    predecessor-context per-dep block."""
    out = []
    for s in symbols:
        out.append(
            f"  L{s['line_start']:>5}-{s['line_end']:<5} {s['kind']:8} {s['name']}"
        )
    return "\n".join(out)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("file", type=Path)
    p.add_argument("--format", choices=("json", "text"), default="json")
    args = p.parse_args()

    try:
        syms = extract(args.file)
    except FileNotFoundError as e:
        print(f"ERROR: file not found: {e}", file=sys.stderr)
        return 3

    if args.format == "json":
        print(json.dumps(syms))
    else:
        print(format_text(syms))
    return 0


if __name__ == "__main__":
    sys.exit(main())
