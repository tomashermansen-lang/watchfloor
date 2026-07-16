"""Tests for emit-baseline.py (Component C4).

Covers: BL-01..BL-06 from TESTPLAN.md.
"""
from __future__ import annotations

import json
from pathlib import Path

import jsonschema
import pytest
import yaml

from conftest import SCHEMA_DIR, import_tool

baseline_mod = import_tool("lib/emit-baseline.py")


def _load_schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / name).read_text())


def _setup_grinder(
    tmp_path: Path,
    passes: list[dict] | None = None,
    scanner_output: dict[str, list] | None = None,
    coverage_data: dict | None = None,
) -> tuple[Path, Path, Path]:
    """Set up mock grinder directory with plan, scanner output, and coverage."""
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    grinder_dir = project_dir / "docs" / "grinder"
    grinder_dir.mkdir(parents=True)
    schema_dir = SCHEMA_DIR

    # Write grinder-plan.yaml
    if passes is None:
        passes = [
            {"id": "pass-1", "kind": "mechanical", "batches": [
                {"id": "b1", "files": ["f.py"], "estimated_turns": 3, "status": "completed"}
            ]},
            {"id": "pass-2", "kind": "coverage", "batches": [
                {"id": "b2", "files": ["f.py"], "estimated_turns": 3, "status": "completed"}
            ]},
            {"id": "pass-3", "kind": "static_analysis", "batches": [
                {"id": "b3", "files": ["f.py"], "estimated_turns": 3, "status": "completed"}
            ]},
            {"id": "pass-4", "kind": "cve", "batches": [
                {"id": "b4", "files": ["all"], "estimated_turns": 3, "status": "completed"}
            ]},
        ]
    plan = {
        "created_at": "2026-04-18T10:00:00Z",
        "git_sha_at_start": "abc1234",
        "estimated_batches": 4,
        "estimated_hours": 2.0,
        "passes": passes,
    }
    (grinder_dir / "grinder-plan.yaml").write_text(yaml.dump(plan))

    # Write scanner output
    scanner_dir = grinder_dir / "scanner-output"
    scanner_dir.mkdir()
    if scanner_output:
        for tool, findings in scanner_output.items():
            (scanner_dir / f"{tool}.json").write_text(json.dumps(findings))

    # Write deferred-findings.json (bootstrap)
    (grinder_dir / "deferred-findings.json").write_text("[]")

    # Write coverage data
    if coverage_data is not None:
        (grinder_dir / "coverage-report.json").write_text(json.dumps(coverage_data))

    return project_dir, grinder_dir, schema_dir


# ---------------------------------------------------------------------------
# BL-01: Baseline schema valid
# ---------------------------------------------------------------------------

def test_bl01_baseline_schema_valid(tmp_path: Path):
    """AS-7: baseline.json validates against baseline.schema.json."""
    project_dir, grinder_dir, schema_dir = _setup_grinder(
        tmp_path,
        scanner_output={"shellcheck": [{"id": "sc:SC2086-f-aaa", "tool": "shellcheck"}]},
        coverage_data={"project_wide": 0.85, "files": {}},
    )
    result = baseline_mod.emit_baseline(
        project_dir=str(project_dir),
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    schema = _load_schema("baseline.schema.json")
    jsonschema.validate(result, schema, format_checker=jsonschema.FormatChecker())

    # Required fields
    assert "created_at" in result
    assert "git_sha" in result
    assert "coverage" in result
    assert "findings_count" in result
    assert "tool_versions" in result
    assert "deferred_findings_ref" in result


# ---------------------------------------------------------------------------
# BL-02: Empty coverage
# ---------------------------------------------------------------------------

def test_bl02_empty_coverage(tmp_path: Path):
    """EC-7.1: no coverage data → coverage: {}."""
    project_dir, grinder_dir, schema_dir = _setup_grinder(tmp_path)
    result = baseline_mod.emit_baseline(
        project_dir=str(project_dir),
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    assert result["coverage"] == {}


# ---------------------------------------------------------------------------
# BL-03: Tools only from plan
# ---------------------------------------------------------------------------

def test_bl03_tools_only_from_plan(tmp_path: Path):
    """EC-7.2: only tools that actually ran appear in findings_count."""
    passes = [
        {"id": "pass-1", "kind": "mechanical", "batches": [
            {"id": "b1", "files": ["f.sh"], "estimated_turns": 3, "status": "completed"}
        ]},
        {"id": "pass-2", "kind": "coverage", "batches": []},
        {"id": "pass-3", "kind": "static_analysis", "batches": [
            {"id": "b3", "files": ["f.sh"], "estimated_turns": 3, "status": "completed"}
        ]},
        {"id": "pass-4", "kind": "cve", "batches": [
            {"id": "b4", "files": ["all"], "estimated_turns": 3, "status": "completed"}
        ]},
    ]
    project_dir, grinder_dir, schema_dir = _setup_grinder(
        tmp_path,
        passes=passes,
        scanner_output={"shellcheck": [{"id": "x", "tool": "shellcheck"}, {"id": "y", "tool": "shellcheck"}]},
    )
    result = baseline_mod.emit_baseline(
        project_dir=str(project_dir),
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    # shellcheck findings should be counted
    assert "shellcheck" in result["findings_count"]
    assert result["findings_count"]["shellcheck"] == 2
    # No npm/eslint tools should appear
    assert "eslint" not in result["findings_count"]


# ---------------------------------------------------------------------------
# BL-04: Required fields present
# ---------------------------------------------------------------------------

def test_bl04_required_fields_present(tmp_path: Path):
    """REQ-7: output has exactly the required baseline fields."""
    project_dir, grinder_dir, schema_dir = _setup_grinder(tmp_path)
    result = baseline_mod.emit_baseline(
        project_dir=str(project_dir),
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    required = {"created_at", "git_sha", "coverage", "findings_count", "tool_versions", "deferred_findings_ref"}
    assert required == set(result.keys())


# ---------------------------------------------------------------------------
# BL-05: Deferred findings ref
# ---------------------------------------------------------------------------

def test_bl05_deferred_findings_ref(tmp_path: Path):
    """REQ-7: deferred_findings_ref points to correct path."""
    project_dir, grinder_dir, schema_dir = _setup_grinder(tmp_path)
    result = baseline_mod.emit_baseline(
        project_dir=str(project_dir),
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    assert result["deferred_findings_ref"] == "docs/grinder/deferred-findings.json"


# ---------------------------------------------------------------------------
# BL-06: Incomplete passes rejected
# ---------------------------------------------------------------------------

def test_bl06_incomplete_passes_rejected(tmp_path: Path):
    """REQ-7: refuses to emit baseline if any pass is pending."""
    passes = [
        {"id": "pass-1", "kind": "mechanical", "batches": [
            {"id": "b1", "files": ["f.py"], "estimated_turns": 3, "status": "completed"}
        ]},
        {"id": "pass-4", "kind": "cve", "batches": [
            {"id": "b4", "files": ["all"], "estimated_turns": 3, "status": "pending"}
        ]},
    ]
    project_dir, grinder_dir, schema_dir = _setup_grinder(tmp_path, passes=passes)
    with pytest.raises(ValueError, match="not all passes complete"):
        baseline_mod.emit_baseline(
            project_dir=str(project_dir),
            grinder_dir=str(grinder_dir),
            schema_dir=str(schema_dir),
        )
