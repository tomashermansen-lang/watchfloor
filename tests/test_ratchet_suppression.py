"""Tests for claude/tools/lib/ratchet-suppression.py — C2 suppression scanner."""

from __future__ import annotations

from unittest.mock import patch

from conftest import import_tool, run_tool

mod = import_tool("lib/ratchet-suppression.py")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_diff(filename: str, added_lines: list[str], start_line: int = 1) -> str:
    """Build a minimal unified diff with the given added lines."""
    hunk_lines = []
    for i, content in enumerate(added_lines):
        hunk_lines.append(f"+{content}\n")
    count = len(added_lines)
    return (
        f"diff --git a/{filename} b/{filename}\n"
        f"--- a/{filename}\n"
        f"+++ b/{filename}\n"
        f"@@ -0,0 +{start_line},{count} @@\n" + "".join(hunk_lines)
    )


# ---------------------------------------------------------------------------
# TC-RS01: # noqa on added line detected
# ---------------------------------------------------------------------------


def test_rs01_noqa_detected():
    diff = _make_diff("src/main.py", ["x = 1  # noqa"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1
    assert result[0]["pattern"] == "# noqa"
    assert result[0]["file"] == "src/main.py"
    assert result[0]["line"] == 1


# ---------------------------------------------------------------------------
# TC-RS02: # noqa: E501 (rule-specific) detected
# ---------------------------------------------------------------------------


def test_rs02_noqa_with_rule_detected():
    diff = _make_diff("src/main.py", ["long_line  # noqa: E501"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1
    assert "noqa" in result[0]["pattern"]


# ---------------------------------------------------------------------------
# TC-RS03: // eslint-disable-next-line detected
# ---------------------------------------------------------------------------


def test_rs03_eslint_disable_next_line():
    diff = _make_diff("src/app.js", ["// eslint-disable-next-line no-unused-vars"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1
    assert "eslint-disable" in result[0]["pattern"]


# ---------------------------------------------------------------------------
# TC-RS04: /* eslint-disable */ block detected
# ---------------------------------------------------------------------------


def test_rs04_eslint_block_disable():
    diff = _make_diff("src/app.js", ["/* eslint-disable */"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1


# ---------------------------------------------------------------------------
# TC-RS05: # type: ignore detected
# ---------------------------------------------------------------------------


def test_rs05_type_ignore():
    diff = _make_diff("src/main.py", ['x: int = "s"  # type: ignore'])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1
    assert "type: ignore" in result[0]["pattern"]


# ---------------------------------------------------------------------------
# TC-RS06: # type: ignore[assignment] (bracket form) detected
# ---------------------------------------------------------------------------


def test_rs06_type_ignore_bracket():
    diff = _make_diff("src/main.py", ['x: int = "s"  # type: ignore[assignment]'])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1


# ---------------------------------------------------------------------------
# TC-RS07: // @ts-ignore detected
# ---------------------------------------------------------------------------


def test_rs07_ts_ignore():
    diff = _make_diff("src/app.ts", ["// @ts-ignore"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1


# ---------------------------------------------------------------------------
# TC-RS08: // @ts-expect-error detected
# ---------------------------------------------------------------------------


def test_rs08_ts_expect_error():
    diff = _make_diff("src/app.ts", ["// @ts-expect-error"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1


# ---------------------------------------------------------------------------
# TC-RS09: /* istanbul ignore */ detected
# ---------------------------------------------------------------------------


def test_rs09_istanbul_ignore():
    diff = _make_diff("src/app.ts", ["/* istanbul ignore next */"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1


# ---------------------------------------------------------------------------
# TC-RS10: # noqa inside double-quoted string NOT detected
# ---------------------------------------------------------------------------


def test_rs10_noqa_in_double_quoted_string():
    diff = _make_diff("src/main.py", ['msg = "use # noqa to suppress"'])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 0


# ---------------------------------------------------------------------------
# TC-RS11: # noqa inside single-quoted string NOT detected
# ---------------------------------------------------------------------------


def test_rs11_noqa_in_single_quoted_string():
    diff = _make_diff("src/main.py", ["msg = 'use # noqa to suppress'"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 0


# ---------------------------------------------------------------------------
# TC-RS12: # noqa inside triple-quoted string NOT detected
# ---------------------------------------------------------------------------


def test_rs12_noqa_in_triple_quoted_string():
    diff = _make_diff("src/main.py", ['"""docs say # noqa is bad"""'])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 0


# ---------------------------------------------------------------------------
# TC-RS13: # noqa inside backtick template NOT detected
# ---------------------------------------------------------------------------


def test_rs13_noqa_in_backtick():
    diff = _make_diff("src/app.ts", ["const s = `use # noqa`"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 0


# ---------------------------------------------------------------------------
# TC-RS14: noqa_count variable NOT detected (word boundary)
# ---------------------------------------------------------------------------


def test_rs14_noqa_count_not_detected():
    diff = _make_diff("src/main.py", ["noqa_count = 0"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 0


# ---------------------------------------------------------------------------
# TC-RS15: # noqa in comment IS detected
# ---------------------------------------------------------------------------


def test_rs15_noqa_in_comment_detected():
    diff = _make_diff("src/main.py", ["# noqa — disable all"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1


# ---------------------------------------------------------------------------
# TC-RS16: Multiple suppressions on one line → each reported
# ---------------------------------------------------------------------------


def test_rs16_multiple_suppressions_on_one_line():
    diff = _make_diff("src/main.py", ["x = 1  # noqa  # type: ignore"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 2


# ---------------------------------------------------------------------------
# TC-RS17: Ambiguous string context → err on side of permitting
# ---------------------------------------------------------------------------


def test_rs17_ambiguous_string_permits():
    # Complex quoting scenario — pattern appears after odd number of quotes
    diff = _make_diff("src/main.py", ["""x = "it's a # noqa test" """])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    # Should NOT reject — err on side of permitting
    assert len(result) == 0


# ---------------------------------------------------------------------------
# TC-RS18: No suppressions → empty array
# ---------------------------------------------------------------------------


def test_rs18_no_suppressions_empty():
    diff = _make_diff("src/main.py", ["x = 1", "y = 2"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert result == []


# ---------------------------------------------------------------------------
# TC-RS19: Context line (no + prefix) ignored
# ---------------------------------------------------------------------------


def test_rs19_context_line_ignored():
    diff = (
        "diff --git a/src/main.py b/src/main.py\n"
        "--- a/src/main.py\n"
        "+++ b/src/main.py\n"
        "@@ -1,3 +1,4 @@\n"
        " x = 1  # noqa\n"  # context line — not added
        "+y = 2\n"
        " z = 3\n"
    )
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 0


# ---------------------------------------------------------------------------
# TC-RS20: +++ b/file header NOT treated as added line
# ---------------------------------------------------------------------------


def test_rs20_header_not_treated_as_added():
    diff = (
        "diff --git a/noqa.py b/noqa.py\n"
        "--- a/noqa.py\n"
        "+++ b/noqa.py\n"
        "@@ -1,2 +1,3 @@\n"
        " line 1\n"
        "+line 2\n"
        " line 3\n"
    )
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 0  # "noqa.py" in the header doesn't trigger


# ---------------------------------------------------------------------------
# TC-RS21: --diff-base injection rejected
# ---------------------------------------------------------------------------


def test_rs21_diff_base_injection_rejected():
    result = run_tool("lib/ratchet-suppression.py", "--diff-base", "main; rm -rf /")
    assert result.exit_code == 1
    assert "invalid --diff-base" in result.stderr


# ---------------------------------------------------------------------------
# TC-RS22: Suppression in test file detected
# ---------------------------------------------------------------------------


def test_rs22_suppression_in_test_file_detected():
    diff = _make_diff("tests/test_foo.py", ["x = 1  # noqa"])
    with patch.object(mod, "_run_git_diff", return_value=diff):
        result = mod.scan_suppressions(diff_base="main")
    assert len(result) == 1
