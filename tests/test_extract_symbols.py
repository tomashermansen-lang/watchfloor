"""Test suite for extract_symbols.py — the symbol-map extractor that backs
the per-phase compact predecessor context (canary A/B/C antipattern fix
for working-file re-reads).

Hermetic: writes synthetic .py / .sh source files into a tmpdir and
asserts the extractor returns the expected (name, kind, line_start,
line_end) tuples.

Stdlib-only — uses ast for Python and regex for bash. tree-sitter is
deferred (not installed in the sandboxed dev env; bringing it in would
require pyproject.toml + uv sync; the current shape captures the bulk of
the value for the two languages that dominate this repo).
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
EXTRACTOR = REPO_ROOT / "adapters/claude-code/claude/tools/lib/extract_symbols.py"


def run_extractor(file_path: Path) -> list[dict]:
    """Invoke the extractor as a subprocess and parse its JSON output."""
    import json

    result = subprocess.run(
        [sys.executable, str(EXTRACTOR), str(file_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def test_extractor_exists():
    assert EXTRACTOR.exists(), f"extractor missing at {EXTRACTOR}"


def test_python_extracts_top_level_functions(tmp_path: Path):
    src = tmp_path / "module.py"
    src.write_text(
        "def alpha(x: int) -> int:\n"
        "    return x + 1\n"
        "\n"
        "def beta():\n"
        "    pass\n"
    )
    syms = run_extractor(src)
    names = [(s["name"], s["kind"]) for s in syms]
    assert ("alpha", "function") in names
    assert ("beta", "function") in names


def test_python_extracts_classes_and_methods(tmp_path: Path):
    src = tmp_path / "klass.py"
    src.write_text(
        "class Widget:\n"
        "    def __init__(self):\n"
        "        self.x = 1\n"
        "    def render(self) -> str:\n"
        "        return 'w'\n"
    )
    syms = run_extractor(src)
    kinds = {(s["name"], s["kind"]) for s in syms}
    assert ("Widget", "class") in kinds
    assert ("Widget.__init__", "method") in kinds
    assert ("Widget.render", "method") in kinds


def test_python_line_ranges_are_real(tmp_path: Path):
    src = tmp_path / "ranges.py"
    src.write_text(
        "def small():\n"  # line 1
        "    return 1\n"  # line 2
        "\n"
        "def bigger():\n"  # line 4
        "    x = 1\n"
        "    y = 2\n"
        "    return x + y\n"  # line 7
    )
    syms = run_extractor(src)
    by_name = {s["name"]: s for s in syms}
    assert by_name["small"]["line_start"] == 1
    assert by_name["small"]["line_end"] == 2
    assert by_name["bigger"]["line_start"] == 4
    assert by_name["bigger"]["line_end"] == 7


def test_bash_extracts_function_styles(tmp_path: Path):
    src = tmp_path / "lib.sh"
    src.write_text(
        "#!/usr/bin/env bash\n"
        "\n"
        "alpha() {\n"
        "  echo 1\n"
        "}\n"
        "\n"
        "function beta() {\n"
        "  echo 2\n"
        "}\n"
        "\n"
        "function gamma {\n"  # no parens, the rarer-but-legal form
        "  echo 3\n"
        "}\n"
    )
    syms = run_extractor(src)
    names = {s["name"] for s in syms if s["kind"] == "function"}
    assert {"alpha", "beta", "gamma"}.issubset(names)


def test_bash_line_starts(tmp_path: Path):
    src = tmp_path / "lines.sh"
    src.write_text(
        "#!/usr/bin/env bash\n"
        "\n"
        "first() {\n"   # line 3
        "  echo 1\n"
        "}\n"
        "\n"
        "second() {\n"  # line 7
        "  echo 2\n"
        "}\n"
    )
    syms = run_extractor(src)
    by_name = {s["name"]: s for s in syms}
    assert by_name["first"]["line_start"] == 3
    assert by_name["second"]["line_start"] == 7


def test_unsupported_extension_returns_empty(tmp_path: Path):
    src = tmp_path / "data.json"
    src.write_text('{"x": 1}')
    syms = run_extractor(src)
    assert syms == []


def test_missing_file_exits_nonzero():
    result = subprocess.run(
        [sys.executable, str(EXTRACTOR), "/no/such/path.py"],
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0


def test_python_skips_private_dunder_init_in_module_level(tmp_path: Path):
    """Top-level dunder-ish helpers should still surface — we only special-
    case methods. Keep this loose; we don't want to over-filter."""
    src = tmp_path / "m.py"
    src.write_text(
        "def _private():\n"
        "    return 1\n"
        "def __dunder__():\n"
        "    return 2\n"
    )
    syms = run_extractor(src)
    names = {s["name"] for s in syms}
    # Both surface — agents may need to navigate to them.
    assert "_private" in names
    assert "__dunder__" in names


def test_unsupported_extension_emits_valid_json_array(tmp_path: Path):
    """Locks in the contract that downstream parsers (e.g.
    predecessor-context.py:_extract_symbols_now) can safely
    json.loads + isinstance(parsed, list) check the output. If we ever
    regressed to printing 'null' or a dict, the consumer would silently
    swallow legitimate symbol maps.
    """
    import json as _json
    src = tmp_path / "weird.unknown"
    src.write_text("no symbols here")
    result = subprocess.run(
        [sys.executable, str(EXTRACTOR), str(src)],
        capture_output=True, text=True, check=True,
    )
    parsed = _json.loads(result.stdout)
    assert isinstance(parsed, list)
    assert parsed == []


def test_malformed_python_does_not_crash(tmp_path: Path):
    src = tmp_path / "broken.py"
    src.write_text("def f(:\n    not valid python")
    # Should exit cleanly with empty output, not raise.
    result = subprocess.run(
        [sys.executable, str(EXTRACTOR), str(src)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    assert result.stdout.strip() in ("[]", "")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
