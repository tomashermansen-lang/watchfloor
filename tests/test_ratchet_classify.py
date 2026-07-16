"""Tests for claude/tools/lib/ratchet-classify.py — C1 tier classifier."""
from __future__ import annotations

import json
import subprocess
import sys
import textwrap
from pathlib import Path
from unittest.mock import patch

from conftest import import_tool, run_tool

mod = import_tool("lib/ratchet-classify.py")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_finding(file: str, line: int, rule: str = "SC2086", tool: str = "shellcheck") -> dict:
    """Build a finding with a per-line-distinct id.

    The classifier dedupes by `id`. Real-world ids are content-addressed
    (tool + rule + file + content_hash) so a hash collision is enough to
    identify "the same finding", but this fixture varies content_hash by
    line so each call produces a distinct finding.
    """
    content_hash = f"l{line:04x}"
    return {
        "id": f"{tool}:{rule.upper()}-{Path(file).name}-{content_hash}",
        "tool": tool,
        "rule": rule,
        "file": file,
        "line": line,
        "severity": "warning",
        "message": "test finding",
        "content_hash": content_hash,
    }


def _mock_diff_output(changed_files: dict[str, list[int]]) -> str:
    """Build a unified diff where changed_files maps filename → list of added line numbers."""
    parts = []
    for fname, lines in changed_files.items():
        if not lines:
            # File changed but no added lines (e.g. only deletions)
            parts.append(
                f"diff --git a/{fname} b/{fname}\n"
                f"--- a/{fname}\n"
                f"+++ b/{fname}\n"
                f"@@ -1,3 +1,2 @@\n"
                f" unchanged\n"
                f"-deleted line\n"
                f" unchanged\n"
            )
            continue
        # Build hunk with added lines at specific positions
        start = min(lines)
        hunk_lines = []
        for ln in range(start, max(lines) + 1):
            if ln in lines:
                hunk_lines.append(f"+added line {ln}\n")
            else:
                hunk_lines.append(f" context line {ln}\n")
        count_new = len(hunk_lines)
        count_old = count_new - len(lines)
        parts.append(
            f"diff --git a/{fname} b/{fname}\n"
            f"--- a/{fname}\n"
            f"+++ b/{fname}\n"
            f"@@ -{start},{count_old} +{start},{count_new} @@\n"
            + "".join(hunk_lines)
        )
    return "".join(parts)


# ---------------------------------------------------------------------------
# TC-RC01: Finding on changed line → MUST-fix
# ---------------------------------------------------------------------------

def test_rc01_finding_on_changed_line_is_must_fix(tmp_path):
    diff_text = _mock_diff_output({"src/main.py": [5, 6, 7]})

    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["src/main.py"]):
        result = mod.classify(
            [_make_finding("src/main.py", 5)],
            diff_base="main",
        )

    assert len(result["must_fix"]) == 1
    assert result["must_fix"][0]["tier"] == "must_fix"


# ---------------------------------------------------------------------------
# TC-RC02: Finding on unchanged line in touched file → SHOULD-fix
# ---------------------------------------------------------------------------

def test_rc02_finding_on_unchanged_line_is_should_fix(tmp_path):
    diff_text = _mock_diff_output({"src/main.py": [5, 6, 7]})

    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["src/main.py"]):
        result = mod.classify(
            [_make_finding("src/main.py", 20)],
            diff_base="main",
        )

    assert len(result["should_fix"]) == 1
    assert result["should_fix"][0]["tier"] == "should_fix"


# ---------------------------------------------------------------------------
# TC-RC03: Finding in untouched file → MAY-defer
# ---------------------------------------------------------------------------

def test_rc03_finding_in_untouched_file_is_may_defer():
    diff_text = _mock_diff_output({"src/main.py": [5]})

    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["src/main.py"]):
        result = mod.classify(
            [_make_finding("src/other.py", 10)],
            diff_base="main",
        )

    assert len(result["may_defer"]) == 1
    assert result["may_defer"][0]["tier"] == "may_defer"


# ---------------------------------------------------------------------------
# TC-RC04: Zero findings → empty tier arrays
# ---------------------------------------------------------------------------

def test_rc04_zero_findings_produces_empty_arrays():
    with patch.object(mod, "_run_git_diff", return_value=""), \
         patch.object(mod, "_run_git_diff_name_only", return_value=[]):
        result = mod.classify([], diff_base="main")

    assert result["must_fix"] == []
    assert result["should_fix"] == []
    assert result["may_defer"] == []


# ---------------------------------------------------------------------------
# TC-RC05: Renamed file — finding matched against new name
# ---------------------------------------------------------------------------

def test_rc05_renamed_file_finding_uses_new_name():
    diff_text = (
        "diff --git a/old.py b/new.py\n"
        "similarity index 90%\n"
        "rename from old.py\n"
        "rename to new.py\n"
        "--- a/old.py\n"
        "+++ b/new.py\n"
        "@@ -1,3 +1,4 @@\n"
        " line 1\n"
        "+added line 2\n"
        " line 3\n"
        " line 4\n"
    )
    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["new.py"]):
        # Finding for new name on added line → MUST-fix
        result = mod.classify(
            [_make_finding("new.py", 2), _make_finding("old.py", 1)],
            diff_base="main",
        )

    assert len(result["must_fix"]) == 1
    assert result["must_fix"][0]["file"] == "new.py"
    # old.py is not in changed files → MAY-defer
    assert len(result["may_defer"]) == 1
    assert result["may_defer"][0]["file"] == "old.py"


# ---------------------------------------------------------------------------
# TC-RC06: Binary file skipped
# ---------------------------------------------------------------------------

def test_rc06_binary_file_skipped():
    diff_text = (
        "diff --git a/image.png b/image.png\n"
        "Binary files a/image.png and b/image.png differ\n"
    )
    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["image.png"]):
        result = mod.classify(
            [_make_finding("image.png", 1)],
            diff_base="main",
        )

    # Binary files have no parseable hunks → finding on unchanged line → SHOULD-fix
    # (file is in changed set but no added lines detected)
    assert len(result["should_fix"]) == 1


# ---------------------------------------------------------------------------
# TC-RC07: Deleted file skipped
# ---------------------------------------------------------------------------

def test_rc07_deleted_file_findings_are_may_defer():
    diff_text = (
        "diff --git a/removed.py b/removed.py\n"
        "deleted file mode 100644\n"
        "--- a/removed.py\n"
        "+++ /dev/null\n"
        "@@ -1,3 +0,0 @@\n"
        "-line 1\n"
        "-line 2\n"
        "-line 3\n"
    )
    # Deleted files won't appear in name-only for current tree findings
    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=[]):
        result = mod.classify(
            [_make_finding("removed.py", 1)],
            diff_base="main",
        )

    assert len(result["may_defer"]) == 1


# ---------------------------------------------------------------------------
# TC-RC08: Multiple findings across all tiers
# ---------------------------------------------------------------------------

def test_rc08_multiple_findings_across_tiers():
    diff_text = _mock_diff_output({"src/a.py": [10, 11], "src/b.py": [5]})

    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["src/a.py", "src/b.py"]):
        findings = [
            _make_finding("src/a.py", 10),   # MUST-fix (changed line)
            _make_finding("src/a.py", 50),   # SHOULD-fix (unchanged line in touched file)
            _make_finding("src/b.py", 5),    # MUST-fix (changed line)
            _make_finding("src/b.py", 20),   # SHOULD-fix
            _make_finding("src/c.py", 1),    # MAY-defer (untouched file)
        ]
        result = mod.classify(findings, diff_base="main")

    assert len(result["must_fix"]) == 2
    assert len(result["should_fix"]) == 2
    assert len(result["may_defer"]) == 1


# ---------------------------------------------------------------------------
# TC-RC09: Custom diff_base passed through to git helpers
# ---------------------------------------------------------------------------

def test_rc_dedup_by_id():
    """Duplicate findings (same id) collapse to one entry.

    commit-preflight.sh accumulates output from every discovered scanner;
    when the discovery layer finds e.g. shellcheck + ruff + mypy on PATH,
    each scanner invocation may surface the same finding (especially in
    test setups where get-findings.sh is mocked to return a fixed payload
    regardless of which scanner was invoked). Without dedup, the same
    finding ends up counted N times. The classifier dedupes by `id` —
    which is content-addressed (tool + rule + file + content_hash) so
    duplicates are unambiguous.
    """
    diff_text = _mock_diff_output({"src/main.py": [5]})
    duplicate = _make_finding("src/main.py", 5)

    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["src/main.py"]):
        result = mod.classify(
            [duplicate, dict(duplicate), dict(duplicate)],   # 3 copies
            diff_base="main",
        )

    assert len(result["must_fix"]) == 1


def test_rc_dedup_keeps_distinct_ids():
    """Findings with different ids are NOT collapsed."""
    diff_text = _mock_diff_output({"src/main.py": [5, 6]})
    f1 = _make_finding("src/main.py", 5, rule="SC2086")
    f2 = _make_finding("src/main.py", 6, rule="SC2034")
    assert f1["id"] != f2["id"]

    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["src/main.py"]):
        result = mod.classify([f1, f2], diff_base="main")

    assert len(result["must_fix"]) == 2


def test_rc09_custom_diff_base_passed_through():
    diff_text = _mock_diff_output({"src/main.py": [5]})
    captured_refs: list[str] = []

    def _mock_run_git_diff(diff_base: str) -> str:
        captured_refs.append(diff_base)
        return diff_text

    def _mock_run_git_diff_name_only(diff_base: str) -> list[str]:
        captured_refs.append(diff_base)
        return ["src/main.py"]

    with patch.object(mod, "_run_git_diff", side_effect=_mock_run_git_diff), \
         patch.object(mod, "_run_git_diff_name_only", side_effect=_mock_run_git_diff_name_only):
        mod.classify(
            [_make_finding("src/main.py", 5)],
            diff_base="develop",
        )

    assert all(ref == "develop" for ref in captured_refs)
    assert len(captured_refs) == 2  # both helpers called with "develop"


# ---------------------------------------------------------------------------
# TC-RC10: --diff-base injection rejected
# ---------------------------------------------------------------------------

def test_rc10_diff_base_injection_rejected():
    result = run_tool("lib/ratchet-classify.py", "--diff-base", "main; rm -rf /", stdin="[]")
    assert result.exit_code == 1
    assert "invalid --diff-base" in result.stderr


# ---------------------------------------------------------------------------
# TC-RC11: CLI stdin/stdout interface
# ---------------------------------------------------------------------------

def test_rc11_cli_stdin_stdout():
    import os
    import tempfile
    import shutil

    tmp_path = Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR", "/tmp")))
    try:
        # Create a minimal git repo for the CLI test
        subprocess.run(["git", "init", str(tmp_path)], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "test@test.com"], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "Test"], capture_output=True, check=True)

        # Create initial commit on main
        (tmp_path / "file.py").write_text("line 1\nline 2\n")
        subprocess.run(["git", "-C", str(tmp_path), "add", "."], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(tmp_path), "commit", "-m", "init"], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(tmp_path), "branch", "-M", "main"], capture_output=True, check=True)

        # Create feature branch with change
        subprocess.run(["git", "-C", str(tmp_path), "checkout", "-b", "feature/test"], capture_output=True, check=True)
        (tmp_path / "file.py").write_text("line 1\nadded line\nline 2\n")
        subprocess.run(["git", "-C", str(tmp_path), "add", "."], capture_output=True, check=True)
        subprocess.run(["git", "-C", str(tmp_path), "commit", "-m", "add line"], capture_output=True, check=True)

        findings = [_make_finding("file.py", 2)]  # Line 2 is the added line
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parent.parent / "adapters" / "claude-code" / "claude" / "tools" / "lib" / "ratchet-classify.py"),
             "--diff-base", "main"],
            input=json.dumps(findings),
            capture_output=True, text=True,
            cwd=str(tmp_path),
        )

        assert result.returncode == 0
        output = json.loads(result.stdout)
        assert "must_fix" in output
        assert "should_fix" in output
        assert "may_defer" in output
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-RC12: Finding at hunk boundary (first/last added line)
# ---------------------------------------------------------------------------

def test_rc12_finding_at_hunk_boundary():
    diff_text = _mock_diff_output({"src/main.py": [10, 11, 12]})

    with patch.object(mod, "_run_git_diff", return_value=diff_text), \
         patch.object(mod, "_run_git_diff_name_only", return_value=["src/main.py"]):
        findings = [
            _make_finding("src/main.py", 10),  # First added line
            _make_finding("src/main.py", 12),  # Last added line
        ]
        result = mod.classify(findings, diff_base="main")

    assert len(result["must_fix"]) == 2
