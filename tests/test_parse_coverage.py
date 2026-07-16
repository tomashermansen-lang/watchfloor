"""Tests for parse-coverage.py (Component C2).

Covers: P-01 through P-13 from TESTPLAN.md.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import RunResult


LIB_DIR = Path(__file__).resolve().parent.parent / "adapters" / "claude-code" / "claude" / "tools" / "lib"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "coverage"


def run_parse_coverage(*args: str) -> RunResult:
    """Run parse-coverage.py with given args."""
    tool_path = LIB_DIR / "parse-coverage.py"
    result = subprocess.run(
        [sys.executable, str(tool_path), *args],
        capture_output=True,
        text=True,
    )
    return RunResult(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)


# ---------------------------------------------------------------------------
# Fixture data builders
# ---------------------------------------------------------------------------

def _vitest_istanbul(files: dict[str, tuple[int, int]]) -> dict:
    """Build vitest/Istanbul coverage-final.json fixture.

    files: {abs_path: (covered_stmts, total_stmts)}
    """
    result = {}
    for path, (covered, total) in files.items():
        stmts = {}
        for i in range(total):
            stmts[str(i)] = 1 if i < covered else 0
        result[path] = {"s": stmts, "b": {}, "f": {}}
    return result


def _pytest_cov(files: dict[str, float], totals_pct: float | None = None) -> dict:
    """Build pytest-cov coverage.json fixture.

    files: {rel_path: percent_covered}
    """
    file_data = {}
    for path, pct in files.items():
        file_data[path] = {"summary": {"percent_covered": pct}}
    total = totals_pct if totals_pct is not None else (
        sum(files.values()) / len(files) if files else 0.0
    )
    return {"files": file_data, "totals": {"percent_covered": total}}


# ===========================================================================
# P-01: Vitest Istanbul format — multi-file
# ===========================================================================

class TestVitestIstanbul:
    def test_multi_file(self, tmp_path: Path) -> None:
        """P-01: 3 files, mixed coverage."""
        data = _vitest_istanbul({
            "/project/src/foo.ts": (3, 10),   # 30%
            "/project/src/bar.ts": (9, 10),   # 90%
            "/project/src/baz.ts": (5, 10),   # 50%
        })
        report = tmp_path / "coverage-final.json"
        report.write_text(json.dumps(data))

        result = run_parse_coverage(
            "--format", "vitest",
            "--report-path", str(report),
            "--project-root", "/project",
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        output = json.loads(result.stdout)
        assert abs(output["project_wide"] - 17 / 30) < 0.01
        assert abs(output["files"]["src/foo.ts"] - 0.3) < 0.01
        assert abs(output["files"]["src/bar.ts"] - 0.9) < 0.01
        assert abs(output["files"]["src/baz.ts"] - 0.5) < 0.01

    def test_all_covered(self, tmp_path: Path) -> None:
        """P-02: All statements covered -> 1.0."""
        data = _vitest_istanbul({"/project/src/a.ts": (5, 5)})
        report = tmp_path / "coverage-final.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "vitest", "--report-path", str(report), "--project-root", "/project")
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert output["project_wide"] == 1.0

    def test_zero_coverage(self, tmp_path: Path) -> None:
        """P-03: All uncovered -> 0.0."""
        data = _vitest_istanbul({"/project/src/a.ts": (0, 5)})
        report = tmp_path / "coverage-final.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "vitest", "--report-path", str(report), "--project-root", "/project")
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert output["project_wide"] == 0.0


# ===========================================================================
# P-04, P-05: pytest-cov format
# ===========================================================================

class TestPytestCov:
    def test_multi_file(self, tmp_path: Path) -> None:
        """P-04: multi-file pytest-cov."""
        data = _pytest_cov(
            {"src/auth.py": 72.5, "src/config.py": 90.0, "src/main.py": 45.0},
            totals_pct=69.17,
        )
        report = tmp_path / "coverage.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "pytest-cov", "--report-path", str(report))
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert abs(output["project_wide"] - 0.6917) < 0.01
        assert abs(output["files"]["src/auth.py"] - 0.725) < 0.01

    def test_single_file(self, tmp_path: Path) -> None:
        """P-05: single file pytest-cov."""
        data = _pytest_cov({"src/app.py": 85.0}, totals_pct=85.0)
        report = tmp_path / "coverage.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "pytest-cov", "--report-path", str(report))
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert abs(output["project_wide"] - 0.85) < 0.01
        assert abs(output["files"]["src/app.py"] - 0.85) < 0.01


# ===========================================================================
# P-06, P-07: Auto-detect format
# ===========================================================================

class TestAutoDetect:
    def test_auto_detect_vitest(self, tmp_path: Path) -> None:
        """P-06: auto-detect vitest format."""
        data = _vitest_istanbul({"/project/src/a.ts": (7, 10)})
        report = tmp_path / "coverage-final.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "auto", "--report-path", str(report), "--project-root", "/project")
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert abs(output["project_wide"] - 0.7) < 0.01

    def test_auto_detect_pytest_cov(self, tmp_path: Path) -> None:
        """P-07: auto-detect pytest-cov format."""
        data = _pytest_cov({"src/app.py": 80.0}, totals_pct=80.0)
        report = tmp_path / "coverage.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "auto", "--report-path", str(report))
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert abs(output["project_wide"] - 0.8) < 0.01


# ===========================================================================
# P-08, P-09: Path normalisation
# ===========================================================================

class TestPathNormalisation:
    def test_absolute_paths_normalised(self, tmp_path: Path) -> None:
        """P-08: vitest absolute paths -> relative."""
        data = _vitest_istanbul({"/my/project/src/foo.ts": (5, 10)})
        report = tmp_path / "coverage-final.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "vitest", "--report-path", str(report), "--project-root", "/my/project")
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert "src/foo.ts" in output["files"]
        assert "/my/project/src/foo.ts" not in output["files"]

    def test_relative_paths_preserved(self, tmp_path: Path) -> None:
        """P-09: pytest-cov relative paths preserved."""
        data = _pytest_cov({"src/app.py": 50.0}, totals_pct=50.0)
        report = tmp_path / "coverage.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "pytest-cov", "--report-path", str(report))
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert "src/app.py" in output["files"]


# ===========================================================================
# P-10, P-11, P-12: Error handling
# ===========================================================================

class TestErrorHandling:
    def test_missing_report_file(self) -> None:
        """P-10: non-existent report path -> exit 1."""
        result = run_parse_coverage("--format", "vitest", "--report-path", "/nonexistent/file.json")
        assert result.exit_code == 1
        assert result.stderr.strip()

    def test_malformed_json(self, tmp_path: Path) -> None:
        """P-11: truncated/invalid JSON -> exit 1."""
        report = tmp_path / "bad.json"
        report.write_text("{truncated")
        result = run_parse_coverage("--format", "vitest", "--report-path", str(report))
        assert result.exit_code == 1
        assert result.stderr.strip()

    def test_empty_coverage_report(self, tmp_path: Path) -> None:
        """P-12: valid JSON but {} -> exit 1."""
        report = tmp_path / "empty.json"
        report.write_text("{}")
        result = run_parse_coverage("--format", "vitest", "--report-path", str(report))
        assert result.exit_code == 1
        assert result.stderr.strip()


# ===========================================================================
# P-13: vitest v8 format
# ===========================================================================

class TestVitestV8:
    def test_v8_format_same_structure(self, tmp_path: Path) -> None:
        """P-13: v8 uses same s-map structure as Istanbul."""
        # v8 format is structurally identical for our purposes
        data = _vitest_istanbul({"/project/src/comp.tsx": (8, 10)})
        report = tmp_path / "coverage-final.json"
        report.write_text(json.dumps(data))
        result = run_parse_coverage("--format", "vitest", "--report-path", str(report), "--project-root", "/project")
        assert result.exit_code == 0
        output = json.loads(result.stdout)
        assert abs(output["files"]["src/comp.tsx"] - 0.8) < 0.01
