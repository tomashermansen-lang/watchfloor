"""Tests for validate-plan.py execution-plan semantic validator (VP-1..11)."""
from __future__ import annotations

import pytest

from pathlib import Path

import yaml

from conftest import CLAUDE_SCHEMA_DIR, REPO_ROOT, import_tool, run_tool


@pytest.fixture(scope="module")
def vp():
    """Import validate-plan.py module."""
    return import_tool("validate-plan.py")


SCHEMA_PATH = str(CLAUDE_SCHEMA_DIR / "execution-plan.schema.json")


def _minimal_plan(**overrides) -> dict:
    plan = {
        "schema_version": "1.0.0",
        "name": "Test Plan",
        "phases": [],
    }
    plan.update(overrides)
    return plan


def _minimal_task(**overrides) -> dict:
    task = {"id": "test-task", "name": "Test Task", "status": "pending"}
    task.update(overrides)
    return task


def _plan_with_gate(checklist: list) -> dict:
    return _minimal_plan(phases=[{
        "id": "phase-1",
        "name": "Phase 1",
        "tasks": [_minimal_task()],
        "gate": {"name": "Gate", "checklist": checklist, "passed": False},
    }])


def _plan_with_task(**task_overrides) -> dict:
    return _minimal_plan(phases=[{
        "id": "phase-1",
        "name": "Phase 1",
        "tasks": [_minimal_task(**task_overrides)],
    }])


def _write_plan(tmp_path: Path, plan: dict) -> Path:
    p = tmp_path / "plan.yaml"
    p.write_text(yaml.dump(plan, default_flow_style=False))
    return p


# --- VP-1: Semantic validator registered ---

class TestSemanticValidatorRegistered:
    """VP-1: Semantic validator registered for execution-plan $id."""

    def test_registered(self, vp):
        schema_id = "https://claude-pipeline/execution-plan.schema.json"
        assert schema_id in vp.SEMANTIC_VALIDATORS

    # T-D-02 (REQ-2 / EC-2.1)
    def test_legacy_id_not_registered(self, vp):
        assert vp.LEGACY_EXECUTION_PLAN_ID not in vp.SEMANTIC_VALIDATORS


# --- VP-2: kind:shell with cmd passes ---

class TestShellWithCmdPasses:
    """VP-2: kind:shell with cmd passes semantic validation."""

    def test_passes(self, vp):
        plan = _plan_with_gate([{
            "text": "Run test",
            "check": {"kind": "shell", "cmd": "echo ok"},
        }])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert errors == []


# --- VP-3: kind:shell without cmd fails ---

class TestShellWithoutCmdFails:
    """VP-3: kind:shell without cmd fails semantic validation."""

    def test_fails(self, vp):
        plan = _plan_with_gate([{
            "text": "Run test",
            "check": {"kind": "shell"},
        }])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert any("cmd" in e.lower() for e in errors)


# --- VP-4: Invalid kind fails ---

class TestInvalidKindFails:
    """VP-4: kind value not in {shell, human} fails."""

    def test_fails(self, vp):
        plan = _plan_with_gate([{
            "text": "Bad",
            "check": {"kind": "automatic"},
        }])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert any("kind" in e.lower() for e in errors)


# --- VP-5: Invalid conformance fails ---

class TestInvalidConformanceFails:
    """VP-5: conformance value not in {aligned, deviated} fails."""

    def test_fails(self, vp):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "unknown",
            "acceptance_status": "met",
            "deviations": [],
        }])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert any("conformance" in e.lower() for e in errors)


# --- VP-6: Invalid acceptance_status fails ---

class TestInvalidAcceptanceStatusFails:
    """VP-6: acceptance_status not in {met, partial, unmet} fails."""

    def test_fails(self, vp):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "aligned",
            "acceptance_status": "bad",
            "deviations": [],
        }])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert any("acceptance_status" in e.lower() for e in errors)


# --- VP-7: Invalid deviations[].type fails ---

class TestInvalidDeviationTypeFails:
    """VP-7: deviations[].type invalid enum fails."""

    def test_fails(self, vp):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "deviated",
            "acceptance_status": "met",
            "deviations": [{
                "type": "invalid",
                "description": "x",
                "reason": "y",
                "impact": "added",
                "criteria_affected": [],
            }],
        }])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert any("type" in e.lower() for e in errors)


# --- VP-8: Invalid deviations[].impact fails ---

class TestInvalidDeviationImpactFails:
    """VP-8: deviations[].impact invalid enum fails."""

    def test_fails(self, vp):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "deviated",
            "acceptance_status": "met",
            "deviations": [{
                "type": "scope_change",
                "description": "x",
                "reason": "y",
                "impact": "invalid",
                "criteria_affected": [],
            }],
        }])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert any("impact" in e.lower() for e in errors)


# --- VP-9: Backwards compatibility ---

class TestBackwardsCompat:
    """VP-9: Plan without check/phase_results passes."""

    def test_passes(self, vp):
        plan = _plan_with_gate(["plain string"])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert errors == []


# --- VP-10: CLI --schema mode ---

class TestCliSchemaMode:
    """VP-10: CLI --schema claude/schema/execution-plan.schema.json works."""

    def test_cli_validates(self, tmp_path: Path):
        plan = _minimal_plan(phases=[{
            "id": "phase-1",
            "name": "Phase 1",
            "tasks": [_minimal_task()],
        }])
        plan_file = _write_plan(tmp_path, plan)
        result = run_tool("validate-plan.py", "--schema", SCHEMA_PATH, str(plan_file))
        assert result.exit_code == 0
        assert "Valid" in result.stdout


# --- VP-11: Object checklist without check block ---

class TestObjectChecklistWithoutCheck:
    """VP-11: Object checklist item without check block passes."""

    def test_passes(self, vp):
        plan = _plan_with_gate([{"text": "Manual item"}])
        validator = vp.SEMANTIC_VALIDATORS["https://claude-pipeline/execution-plan.schema.json"]
        errors = validator(plan)
        assert errors == []


# --- VP-12: Legacy $id deprecation warning (REQ-5) ---

class TestLegacyIdDeprecationWarning:
    """VP-12: Legacy $id triggers single deprecation warning; other $ids silent."""

    # T-W-01
    def test_legacy_id_returns_none_and_warns(self, vp, capsys):
        result = vp.get_semantic_validator({"$id": vp.LEGACY_EXECUTION_PLAN_ID})
        captured = capsys.readouterr()
        assert result is None
        lines = [ln for ln in captured.err.splitlines() if ln.strip()]
        assert len(lines) == 1
        assert lines[0].startswith("WARNING: schema $id")
        assert vp.LEGACY_EXECUTION_PLAN_ID in lines[0]
        assert "https://claude-pipeline/execution-plan.schema.json" in lines[0]

    # T-W-02
    def test_unrelated_id_is_silent(self, vp, capsys):
        result = vp.get_semantic_validator(
            {"$id": "https://example.com/something-else.schema.json"}
        )
        captured = capsys.readouterr()
        assert result is None
        assert captured.err == ""

    # T-W-03
    def test_neutral_id_returns_validator_and_silent(self, vp, capsys):
        result = vp.get_semantic_validator(
            {"$id": "https://claude-pipeline/execution-plan.schema.json"}
        )
        captured = capsys.readouterr()
        assert result is vp.validate_execution_plan_semantic
        assert captured.err == ""

    # T-W-04 (REQ-5 EC-5.1)
    def test_legacy_id_warns_per_call(self, vp, capsys):
        schema = {"$id": vp.LEGACY_EXECUTION_PLAN_ID}
        vp.get_semantic_validator(schema)
        vp.get_semantic_validator(schema)
        captured = capsys.readouterr()
        warning_lines = [ln for ln in captured.err.splitlines()
                         if ln.startswith("WARNING: schema $id")]
        assert len(warning_lines) == 2

    # T-W-05 (REQ-5 EC-5.2)
    def test_empty_id_is_silent(self, vp, capsys):
        result_empty = vp.get_semantic_validator({"$id": ""})
        result_missing = vp.get_semantic_validator({})
        captured = capsys.readouterr()
        assert result_empty is None
        assert result_missing is None
        assert captured.err == ""

    # T-W-06 (REQ-5 EC-5.3)
    def test_other_registered_ids_are_silent(self, vp, capsys):
        for other_id in ("grinder-plan.schema.json", "deferred-findings.schema.json"):
            vp.get_semantic_validator({"$id": other_id})
        captured = capsys.readouterr()
        assert captured.err == ""
