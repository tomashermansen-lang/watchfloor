"""Tests for grinder-pass-mechanical (C9 + mechanical helpers).

Covers: M10-01..M10-03 from TESTPLAN.md (staleness threshold).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml
from conftest import SCHEMA_DIR, TOOLS_DIR, RunResult

LIB_DIR = TOOLS_DIR / "lib"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run_discover_py(
    *args: str,
    findings_data: list | None = None,
    tmp_path: Path | None = None,
) -> RunResult:
    """Run grinder-discover.py with given args."""
    import subprocess

    tool_path = LIB_DIR / "grinder-discover.py"

    if findings_data is not None and tmp_path is not None:
        findings_file = tmp_path / "findings.json"
        findings_file.write_text(json.dumps(findings_data))
        args = ("--findings-json", str(findings_file), *args)

    result = subprocess.run(
        [sys.executable, str(tool_path), *args],
        capture_output=True,
        text=True,
    )
    return RunResult(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)


def make_finding(tool: str, rule: str, file: str, line: int = 1) -> dict:
    """Create a minimal normalised finding dict."""
    return {
        "id": f"{tool}:{rule.upper()}-{Path(file).name}-{'a' * 8}",
        "tool": tool,
        "rule": rule,
        "file": file,
        "line": line,
        "severity": "warning",
        "message": f"Test finding {rule}",
        "content_hash": "a" * 8,
    }


def default_args(tmp_path: Path) -> list[str]:
    """Return the standard CLI args for grinder-discover.py."""
    grinder_dir = tmp_path / "grinder"
    grinder_dir.mkdir(exist_ok=True)
    return [
        "--project-dir",
        str(tmp_path),
        "--grinder-dir",
        str(grinder_dir),
        "--schema-dir",
        str(SCHEMA_DIR),
        "--tools-dir",
        str(TOOLS_DIR),
        "--project-name",
        "test-project",
        "--git-sha",
        "abc1234567890def",
    ]


# ---------------------------------------------------------------------------
# Group 10: Staleness Threshold (C9)
# ---------------------------------------------------------------------------


class TestStalenessThreshold:
    """M10-01..M10-03: staleness_commit_threshold equals total_batches + 5."""

    def test_threshold_equals_total_batches_plus_5(self, tmp_path: Path) -> None:
        """M10-01: 3 findings → 1 batch → threshold = 6."""
        findings = [
            make_finding("shellcheck", "SC2086", "scripts/a.sh"),
            make_finding("shellcheck", "SC2034", "scripts/b.sh"),
            make_finding("shellcheck", "SC2155", "scripts/c.sh"),
        ]
        result = run_discover_py(
            *default_args(tmp_path),
            "--batch-size",
            "5",
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        # 3 files → 1 batch at batch_size=5 → threshold = 1 + 5 = 6
        assert plan["staleness_commit_threshold"] == 6

    def test_threshold_scales_with_batch_count(self, tmp_path: Path) -> None:
        """M10-02: 30 findings across 30 files → 6 batches → threshold = 11."""
        findings = [
            make_finding("shellcheck", f"SC{2000 + i}", f"scripts/file_{i:02d}.sh")
            for i in range(30)
        ]
        result = run_discover_py(
            *default_args(tmp_path),
            "--batch-size",
            "5",
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        # 30 files / 5 per batch = 6 batches → threshold = 6 + 5 = 11
        assert plan["staleness_commit_threshold"] == 11

    def test_minimum_findings_plan_has_threshold_6(self, tmp_path: Path) -> None:
        """M10-03: Edge case — grinder-discover.py exits 1 on empty findings,
        so we test with 1 finding (1 batch) → threshold = 6.
        The zero-batch case can't happen because discover exits early."""
        # Actually grinder-discover.py rejects empty findings, so test minimum:
        # 1 finding → 1 batch → threshold = 1 + 5 = 6
        findings = [make_finding("shellcheck", "SC2086", "scripts/a.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert plan["staleness_commit_threshold"] == 6
