"""Tests for grinder-discover.py (Component B / Suite D1).

Covers: D1-01..D1-15 from TESTPLAN.md.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml
from conftest import REPO_ROOT, SCHEMA_DIR, TOOLS_DIR, RunResult

LIB_DIR = TOOLS_DIR / "lib"
FIXTURES = REPO_ROOT / "tests" / "fixtures" / "discovery-pass"


def run_discover_py(
    *args: str, findings_data: list | None = None, tmp_path: Path | None = None
) -> RunResult:
    """Run grinder-discover.py with given args.

    If findings_data is provided, writes it to a temp file and adds --findings-json.
    """
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


class TestBasicPlanGeneration:
    """D1-01: Basic plan generation."""

    def test_basic_plan_generation(self, tmp_path: Path) -> None:
        findings = [
            make_finding("shellcheck", "SC2086", "scripts/deploy.sh", 15),
            make_finding("shellcheck", "SC2034", "scripts/deploy.sh", 22),
            make_finding("shellcheck", "SC2155", "scripts/build.sh", 8),
        ]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        plan_path = tmp_path / "grinder" / "grinder-plan.yaml"
        assert plan_path.exists()
        plan = yaml.safe_load(plan_path.read_text())

        assert len(plan["passes"]) == 1
        assert plan["passes"][0]["kind"] == "mechanical"
        assert len(plan["passes"][0]["batches"]) == 1
        assert plan["project"] == "test-project"
        assert plan["git_sha_at_start"] == "abc1234567890def"


class TestBatchGrouping:
    """D1-02: Batch grouping with 12 files."""

    def test_batch_grouping(self, tmp_path: Path) -> None:
        findings = []
        for i in range(12):
            count = 12 - i  # file_00 has most findings
            for j in range(count):
                findings.append(
                    make_finding("shellcheck", f"SC200{j}", f"scripts/file_{i:02d}.sh", j + 1)
                )

        result = run_discover_py(
            *default_args(tmp_path), "--batch-size", "5", findings_data=findings, tmp_path=tmp_path
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        plan_path = tmp_path / "grinder" / "grinder-plan.yaml"
        plan = yaml.safe_load(plan_path.read_text())

        batches = plan["passes"][0]["batches"]
        assert len(batches) == 3
        assert batches[0]["id"] == "batch-001"
        assert batches[1]["id"] == "batch-002"
        assert batches[2]["id"] == "batch-003"
        assert len(batches[0]["files"]) == 5
        assert len(batches[1]["files"]) == 5
        assert len(batches[2]["files"]) == 2


class TestEstimatedTurns:
    """D1-03, D1-04: estimated_turns clamping."""

    def test_estimated_turns_clamped_min(self, tmp_path: Path) -> None:
        # Updated for grinder-turn-budget: shellcheck → mechanical →
        # max(8, min(25, 1+3)) == 8 (floor pin).
        findings = [make_finding("shellcheck", "SC2086", "scripts/one.sh")]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert plan["passes"][0]["batches"][0]["estimated_turns"] == 8

    def test_estimated_turns_clamped_max(self, tmp_path: Path) -> None:
        # mechanical formula (since 2026-05-12 ceiling/headroom bump):
        #   max(MECHANICAL_TURNS_FLOOR=8, min(MECHANICAL_TURNS_CEILING=40, N + MECHANICAL_TURNS_HEADROOM=5))
        # 50 findings → min(40, 50+5) → clamped to 40 (ceiling enforced).
        findings = [
            make_finding("shellcheck", f"SC{2000 + i}", "scripts/one.sh", i) for i in range(50)
        ]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert plan["passes"][0]["batches"][0]["estimated_turns"] == 40


class TestMultiplePassKinds:
    """D1-05: Multiple pass kinds from different scanners."""

    def test_multiple_pass_kinds(self, tmp_path: Path) -> None:
        findings = [
            make_finding("shellcheck", "SC2086", "scripts/deploy.sh"),
            make_finding("shellcheck", "SC2034", "scripts/build.sh"),
            make_finding("bandit", "B101", "src/auth.py"),
            make_finding("bandit", "B105", "src/config.py"),
        ]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        kinds = {p["kind"] for p in plan["passes"]}
        assert kinds == {"mechanical", "static_analysis"}


class TestPassKindMapping:
    """D1-06, D1-07: Scanner-to-kind mapping."""

    @pytest.mark.parametrize(
        "tool,expected_kind",
        [
            ("shellcheck", "mechanical"),
            ("ruff", "mechanical"),
            ("eslint", "mechanical"),
            ("prettier", "mechanical"),
            ("bandit", "static_analysis"),
            ("semgrep", "static_analysis"),
            ("mypy", "static_analysis"),
            ("tsc", "static_analysis"),
            ("pip-audit", "cve"),
            ("npm-audit", "cve"),
        ],
    )
    def test_pass_kind_mapping_all_scanners(
        self, tmp_path: Path, tool: str, expected_kind: str
    ) -> None:
        findings = [make_finding(tool, "RULE1", "src/file.py")]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert plan["passes"][0]["kind"] == expected_kind

    def test_unknown_tool_defaults_static_analysis(self, tmp_path: Path) -> None:
        findings = [make_finding("unknown_tool", "RULE1", "src/file.py")]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0
        assert "unknown tool" in result.stderr.lower()

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert plan["passes"][0]["kind"] == "static_analysis"


class TestSchemaValidation:
    """D1-08, D1-09: Schema validation."""

    def test_schema_validation_success(self, tmp_path: Path) -> None:
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0
        assert (tmp_path / "grinder" / "grinder-plan.yaml").exists()

    def test_schema_validation_failure_no_plan_written(self, tmp_path: Path) -> None:
        """D1-09: If schema validation fails, exit 1 and no plan on disk."""
        # Use valid findings so we get past the empty-findings guard,
        # but point --schema-dir to a nonexistent directory so the
        # validate-plan.py schema validation actually fails.
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        bad_schema_dir = tmp_path / "nonexistent-schema-dir"
        grinder_dir = tmp_path / "grinder"
        grinder_dir.mkdir(exist_ok=True)
        args = [
            "--project-dir",
            str(tmp_path),
            "--grinder-dir",
            str(grinder_dir),
            "--schema-dir",
            str(bad_schema_dir),
            "--tools-dir",
            str(TOOLS_DIR),
            "--project-name",
            "test-project",
            "--git-sha",
            "abc1234567890def",
        ]
        result = run_discover_py(*args, findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 1
        assert not (tmp_path / "grinder" / "grinder-plan.yaml").exists()


class TestEmptyFindings:
    """D1-10: Empty findings array."""

    def test_empty_findings_exits_1(self, tmp_path: Path) -> None:
        findings: list = []
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 1


class TestPlanFields:
    """D1-11: Plan field values."""

    def test_plan_fields(self, tmp_path: Path) -> None:
        findings = [
            make_finding("shellcheck", "SC2086", "scripts/a.sh"),
            make_finding("shellcheck", "SC2034", "scripts/b.sh"),
        ]
        result = run_discover_py(
            *default_args(tmp_path), "--batch-size", "5", findings_data=findings, tmp_path=tmp_path
        )
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert plan["git_sha_at_start"] == "abc1234567890def"
        assert plan["project"] == "test-project"
        assert plan["staleness_commit_threshold"] == 6  # 1 batch + STALENESS_BUFFER(5)
        assert plan["estimated_batches"] == 1
        assert abs(plan["estimated_hours"] - 0.5) < 1e-9
        # created_at should be ISO 8601
        assert "T" in plan["created_at"]


class TestCliContract:
    """D1-12: CLI contract test."""

    def test_cli_contract(self, tmp_path: Path) -> None:
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            "--batch-size",
            "5",
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0
        assert (tmp_path / "grinder" / "grinder-plan.yaml").exists()


class TestAtomicWrite:
    """D1-13: Atomic write — no plan on validation failure."""

    def test_atomic_write(self, tmp_path: Path) -> None:
        # Use valid findings so we get past the empty-findings guard,
        # but point --schema-dir to a nonexistent directory so schema
        # validation actually fails and we exercise the temp-file cleanup.
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        bad_schema_dir = tmp_path / "nonexistent-schema-dir"
        grinder_dir = tmp_path / "grinder"
        grinder_dir.mkdir(exist_ok=True)
        args = [
            "--project-dir",
            str(tmp_path),
            "--grinder-dir",
            str(grinder_dir),
            "--schema-dir",
            str(bad_schema_dir),
            "--tools-dir",
            str(TOOLS_DIR),
            "--project-name",
            "test-project",
            "--git-sha",
            "abc1234567890def",
        ]
        result = run_discover_py(*args, findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 1
        assert not (tmp_path / "grinder" / "grinder-plan.yaml").exists()
        # Check no temp file left behind
        tmp_files = list(grinder_dir.glob("*.tmp*"))
        assert len(tmp_files) == 0


class TestSingleFileManyFindings:
    """D1-14: Single file with many findings."""

    def test_single_file_many_findings(self, tmp_path: Path) -> None:
        # Updated for grinder-turn-budget: 15 shellcheck findings →
        # mechanical → max(8, min(40, 15+5)) == 20 (post 2026-05-12 turn-budget bump).
        findings = [
            make_finding("shellcheck", f"SC{2000 + i}", "scripts/big.sh", i) for i in range(15)
        ]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        batch = plan["passes"][0]["batches"][0]
        assert len(batch["files"]) == 1
        assert batch["estimated_turns"] == 20


class TestFilesSortedByCount:
    """D1-15: Files sorted by finding count descending."""

    def test_files_sorted_by_count_desc(self, tmp_path: Path) -> None:
        findings = [
            make_finding("shellcheck", "SC2086", "scripts/few.sh"),
            make_finding("shellcheck", "SC2086", "scripts/many.sh", 1),
            make_finding("shellcheck", "SC2034", "scripts/many.sh", 2),
            make_finding("shellcheck", "SC2155", "scripts/many.sh", 3),
        ]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        files = plan["passes"][0]["batches"][0]["files"]
        assert files[0] == "scripts/many.sh"
        assert files[1] == "scripts/few.sh"


# ===========================================================================
# Coverage discovery extension tests (D-01 through D-09)
# ===========================================================================


class TestCoveragePassGeneration:
    """D-01: Coverage pass generated with correct structure."""

    def test_coverage_pass_structure(self, tmp_path: Path) -> None:
        coverage_files = json.dumps({"src/a.ts": 0.3, "src/b.ts": 0.7})
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            "--coverage-files",
            coverage_files,
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        coverage_passes = [p for p in plan["passes"] if p["kind"] == "coverage"]
        assert len(coverage_passes) == 1
        assert coverage_passes[0]["id"] == "pass-coverage"
        assert len(coverage_passes[0]["batches"]) == 1


class TestCoverageFilesSortedAscending:
    """D-02: Files sorted by coverage ascending."""

    def test_sorted_ascending(self, tmp_path: Path) -> None:
        coverage_files = json.dumps({"src/high.ts": 0.9, "src/low.ts": 0.1, "src/mid.ts": 0.5})
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            "--coverage-files",
            coverage_files,
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        cov_pass = [p for p in plan["passes"] if p["kind"] == "coverage"][0]
        files = cov_pass["batches"][0]["files"]
        assert files[0] == "src/low.ts"
        assert files[-1] == "src/high.ts"


class TestCoverageBatching:
    """D-03: Files batched by batch_size."""

    def test_12_files_batch_size_5(self, tmp_path: Path) -> None:
        cov = {f"src/file_{i:02d}.ts": 0.1 * i for i in range(12)}
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            "--batch-size",
            "5",
            "--coverage-files",
            json.dumps(cov),
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        cov_pass = [p for p in plan["passes"] if p["kind"] == "coverage"][0]
        assert len(cov_pass["batches"]) == 3
        assert len(cov_pass["batches"][0]["files"]) == 5
        assert len(cov_pass["batches"][1]["files"]) == 5
        assert len(cov_pass["batches"][2]["files"]) == 2


class TestCoverageBatchIds:
    """D-04: Batch IDs use cov- prefix."""

    def test_cov_prefix(self, tmp_path: Path) -> None:
        cov = {"src/a.ts": 0.3, "src/b.ts": 0.5}
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            "--coverage-files",
            json.dumps(cov),
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        cov_pass = [p for p in plan["passes"] if p["kind"] == "coverage"][0]
        assert cov_pass["batches"][0]["id"] == "cov-001"


class TestCoverageEstimatedTurns:
    """D-05: estimated_turns is 15 per batch."""

    def test_estimated_turns_15(self, tmp_path: Path) -> None:
        cov = {"src/a.ts": 0.3}
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            "--coverage-files",
            json.dumps(cov),
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        cov_pass = [p for p in plan["passes"] if p["kind"] == "coverage"][0]
        assert cov_pass["batches"][0]["estimated_turns"] == 15


class TestEmptyCoverageFiles:
    """D-06: Empty coverage files produces 0 batches."""

    def test_empty_coverage_files(self, tmp_path: Path) -> None:
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            "--coverage-files",
            "{}",
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        cov_pass = [p for p in plan["passes"] if p["kind"] == "coverage"][0]
        assert len(cov_pass["batches"]) == 0


class TestMixedMechanicalAndCoverage:
    """D-07: Mixed mechanical + coverage."""

    def test_both_passes(self, tmp_path: Path) -> None:
        cov = {"src/a.ts": 0.3}
        findings = [make_finding("shellcheck", "SC2086", "scripts/deploy.sh")]
        result = run_discover_py(
            *default_args(tmp_path),
            "--coverage-files",
            json.dumps(cov),
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        kinds = {p["kind"] for p in plan["passes"]}
        assert "mechanical" in kinds
        assert "coverage" in kinds


class TestCoverageOnlyEmptyFindings:
    """D-08: Coverage-only (empty findings) should exit 0."""

    def test_coverage_only(self, tmp_path: Path) -> None:
        cov = {"src/a.ts": 0.3, "src/b.ts": 0.5}
        result = run_discover_py(
            *default_args(tmp_path),
            "--coverage-files",
            json.dumps(cov),
            findings_data=[],
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"

        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert len(plan["passes"]) == 1
        assert plan["passes"][0]["kind"] == "coverage"


class TestNoCoverageNoFindings:
    """D-09: No coverage files, no findings -> exit 1."""

    def test_exit_1(self, tmp_path: Path) -> None:
        result = run_discover_py(
            *default_args(tmp_path),
            findings_data=[],
            tmp_path=tmp_path,
        )
        assert result.exit_code == 1
