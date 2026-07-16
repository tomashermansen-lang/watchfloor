"""Contract test: C1 and C2 diff parsers produce identical changed-line sets.

Guards against parser divergence between ratchet-classify.py (C1) and
ratchet-suppression.py (C2).
"""
from __future__ import annotations

from pathlib import Path

from conftest import import_tool

classify_mod = import_tool("lib/ratchet-classify.py")
suppress_mod = import_tool("lib/ratchet-suppression.py")

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "ratchet"


def _c1_added_lines(diff_text: str) -> set[tuple[str, int]]:
    """Extract (file, line) pairs from C1's diff parser."""
    parsed = classify_mod.parse_added_lines(diff_text)
    result = set()
    for fname, lines in parsed.items():
        for ln in lines:
            result.add((fname, ln))
    return result


def _c2_added_lines(diff_text: str) -> set[tuple[str, int]]:
    """Extract (file, line) pairs from C2's diff parser."""
    raw = suppress_mod.parse_added_lines_from_diff(diff_text)
    return {(f, ln) for f, ln, _ in raw}


# ---------------------------------------------------------------------------
# TC-DC01: Same diff → identical changed-line sets
# ---------------------------------------------------------------------------

def test_dc01_same_diff_same_lines():
    diff_text = (FIXTURES / "diff-sample.patch").read_text()
    c1_lines = _c1_added_lines(diff_text)
    c2_lines = _c2_added_lines(diff_text)
    assert c1_lines == c2_lines


# ---------------------------------------------------------------------------
# TC-DC02: Multi-file diff with renames
# ---------------------------------------------------------------------------

def test_dc02_rename_diff():
    diff_text = (
        "diff --git a/old.py b/new.py\n"
        "similarity index 90%\n"
        "rename from old.py\n"
        "rename to new.py\n"
        "--- a/old.py\n"
        "+++ b/new.py\n"
        "@@ -1,3 +1,5 @@\n"
        " line 1\n"
        "+added line 2\n"
        "+added line 3\n"
        " line 4\n"
        " line 5\n"
        "diff --git a/other.py b/other.py\n"
        "--- a/other.py\n"
        "+++ b/other.py\n"
        "@@ -5,3 +5,4 @@\n"
        " context\n"
        "+new line 6\n"
        " more context\n"
    )
    c1_lines = _c1_added_lines(diff_text)
    c2_lines = _c2_added_lines(diff_text)
    assert c1_lines == c2_lines
    assert ("new.py", 2) in c1_lines
    assert ("new.py", 3) in c1_lines
    assert ("other.py", 6) in c1_lines


# ---------------------------------------------------------------------------
# TC-DC03: Diff with binary files
# ---------------------------------------------------------------------------

def test_dc03_binary_file_diff():
    diff_text = (
        "diff --git a/image.png b/image.png\n"
        "Binary files a/image.png and b/image.png differ\n"
        "diff --git a/src/code.py b/src/code.py\n"
        "--- a/src/code.py\n"
        "+++ b/src/code.py\n"
        "@@ -1,2 +1,3 @@\n"
        " existing\n"
        "+added\n"
        " more\n"
    )
    c1_lines = _c1_added_lines(diff_text)
    c2_lines = _c2_added_lines(diff_text)
    assert c1_lines == c2_lines
    # Binary file has no parseable lines
    assert not any(f == "image.png" for f, _ in c1_lines)
    assert ("src/code.py", 2) in c1_lines
