"""Schema 2.0.0 + plan_validators end-to-end tests.

Drives every fixture under ``tests/fixtures/plan-2.0.0/`` through
``validate-plan.py`` and asserts exit code, stderr WARNINGs, and stdout
ERROR substrings. Maps each test case to the requirements/eval cases it
covers.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml
from conftest import REPO_ROOT, run_tool
from jsonschema import Draft202012Validator

FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "plan-2.0.0"
SCHEMA_PATH = REPO_ROOT / "core" / "schema" / "execution-plan.schema.json"


def _load_schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


def _validator():
    return Draft202012Validator(_load_schema())


class TestFixtureInventory:
    """A.T1 — every promised fixture exists and is YAML/markdown loadable."""

    EXPECTED_FILES = (
        "minimal.yaml",
        "full.yaml",
        "missing-what.yaml",
        "stub-what.yaml",
        "dup-what.yaml",
        "glob-where.yaml",
        "empty-where.yaml",
        "non-ears-acc.yaml",
        "dangling-ref.yaml",
        "bad-finding-id.yaml",
        "done-with-bad-refs.yaml",
        "path-traversal.yaml",
        "malicious-gate-cmd.yaml",
        "fixture-vision.md",
        "legacy-fallback/execution-plan.yaml",
        "legacy-fallback/EXECUTION_PLAN.md",
        "legacy-stragglers/execution-plan.yaml",
        "legacy-stragglers/EXECUTION_PLAN.md",
        "legacy-stragglers/deferred-findings.json",
    )

    @pytest.mark.parametrize("rel", EXPECTED_FILES)
    def test_fixture_present_and_loadable(self, rel):
        path = FIXTURE_DIR / rel
        assert path.exists(), f"missing fixture {rel}"
        if path.suffix in (".yaml", ".yml"):
            yaml.safe_load(path.read_text())
        elif path.suffix == ".json":
            json.loads(path.read_text())


class TestSchemaStructural:
    """A.T2 — JSON Schema acceptance/rejection per R1-R3."""

    def test_minimal_passes_2_0_branch(self):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        assert _validator().is_valid(plan)

    def test_full_passes_2_0_branch(self):
        plan = yaml.safe_load((FIXTURE_DIR / "full.yaml").read_text())
        assert _validator().is_valid(plan)

    def test_unknown_project_field_rejected(self):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        plan["unexpected_field"] = "x"
        assert not _validator().is_valid(plan)

    def test_unknown_phase_field_rejected(self):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        plan["phases"][0]["bogus_phase_field"] = 1
        assert not _validator().is_valid(plan)

    def test_unknown_task_field_rejected(self):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        plan["phases"][0]["tasks"][0]["bogus_task_field"] = 1
        assert not _validator().is_valid(plan)

    def test_empty_phases_array_rejected(self):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        plan["phases"] = []
        assert not _validator().is_valid(plan)

    def test_pre_release_semver_rejected(self):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        plan["schema_version"] = "2.0.0-rc1"
        assert not _validator().is_valid(plan)

    def test_existing_1x_zero_tech_debt_plan_still_passes(self):
        plan = yaml.safe_load(
            (
                REPO_ROOT / "docs" / "DONE_Plan_zero-tech-debt-pipeline" / "execution-plan.yaml"
            ).read_text()
        )
        assert _validator().is_valid(plan)

    def test_forward_compat_deviations_must_be_array(self):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        plan["phases"][0]["tasks"][0]["deviations"] = "not-an-array"
        assert not _validator().is_valid(plan)

    def test_forward_compat_auto_update_must_be_object(self):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        plan["phases"][0]["tasks"][0]["auto_update"] = 17
        assert not _validator().is_valid(plan)


class TestValidatePlanCLI:
    """A.T3/B.T1 — validate-plan.py exit codes and message format."""

    def _run(self, fixture: str):
        return run_tool("validate-plan.py", str(FIXTURE_DIR / fixture))

    def test_minimal_exits_0(self):
        r = self._run("minimal.yaml")
        assert r.exit_code == 0
        assert r.stderr == ""

    def test_full_exits_0(self):
        r = self._run("full.yaml")
        assert r.exit_code == 0

    def test_missing_what_exits_1_with_required_error(self):
        r = self._run("missing-what.yaml")
        assert r.exit_code == 1
        assert "task.bad-task.what required" in r.stdout

    def test_stub_what_min_length_error(self):
        r = self._run("stub-what.yaml")
        assert r.exit_code == 1
        assert "minimum length 80 characters not met" in r.stdout
        assert "task.stub-task.what" in r.stdout

    def test_dup_what_duplication_error(self):
        r = self._run("dup-what.yaml")
        assert r.exit_code == 1
        assert "duplicates task." in r.stdout

    def test_glob_where_rejected(self):
        r = self._run("glob-where.yaml")
        assert r.exit_code == 1
        assert "glob pattern not allowed" in r.stdout

    def test_empty_where_pending_rejected(self):
        r = self._run("empty-where.yaml")
        assert r.exit_code == 1
        assert "at least one of modify|create|delete" in r.stdout

    def test_non_ears_acceptance_rejected(self):
        r = self._run("non-ears-acc.yaml")
        assert r.exit_code == 1
        assert "must use EARS notation" in r.stdout

    def test_dangling_kill_criteria_ref_rejected(self):
        r = self._run("dangling-ref.yaml")
        assert r.exit_code == 1
        assert "ID 'KC-Z' does not resolve" in r.stdout

    def test_bad_finding_id_rejected(self):
        r = self._run("bad-finding-id.yaml")
        assert r.exit_code == 1
        assert "deferred" in r.stdout

    def test_done_with_missing_artifact_ref_rejected(self):
        r = self._run("done-with-bad-refs.yaml")
        assert r.exit_code == 1
        assert "file not found" in r.stdout

    def test_path_traversal_rejected(self):
        r = self._run("path-traversal.yaml")
        assert r.exit_code == 1
        assert "path traversal" in r.stdout

    def test_legacy_stragglers_emits_warnings_exit_0(self):
        r = self._run("legacy-stragglers/execution-plan.yaml")
        assert r.exit_code == 0
        assert "WARNING:" in r.stderr
        assert "deferred-findings.json" in r.stderr
        assert "EXECUTION_PLAN.md" in r.stderr

    def test_legacy_fallback_1_x_passes(self):
        r = self._run("legacy-fallback/execution-plan.yaml")
        assert r.exit_code == 0

    def test_malicious_gate_cmd_does_not_execute(self):
        r = self._run("malicious-gate-cmd.yaml")
        assert r.exit_code == 0
        # bash -n must NOT execute the substitution.
        assert not Path("/tmp/pwned-by-validator").exists()

    def test_existing_1x_plan_in_repo_still_validates(self):
        r = run_tool(
            "validate-plan.py",
            str(REPO_ROOT / "docs" / "DONE_Plan_zero-tech-debt-pipeline" / "execution-plan.yaml"),
        )
        assert r.exit_code == 0


class TestPolymorphicDeferred:
    """A.T2/B.T1 — deferred[] dispatch on kind."""

    def _build(self, kind_block):
        plan = yaml.safe_load((FIXTURE_DIR / "minimal.yaml").read_text())
        plan["deferred"] = [kind_block]
        return plan

    def test_code_finding_accepted(self):
        plan = self._build(
            {
                "id": "DF-1",
                "kind": "code_finding",
                "finding_id": "dotfiles:abcdef12",
                "rule": "ruff:E501",
                "file": "x.py",
                "line": 1,
                "state": "Deferred",
                "reason": "Forty plus character reason content for the deferred entry",
                "owner": "lead-dev",
                "reviewed_at": "2026-04-26T08:00:00Z",
                "review_trigger": "may-defer-autolog",
            }
        )
        assert _validator().is_valid(plan)

    def test_review_suggestion_accepted(self):
        plan = self._build(
            {
                "id": "DF-2",
                "kind": "review_suggestion",
                "date": "2026-04-26",
                "feature_or_task_id": "f",
                "phase_id": "foundation",
                "reviewer": "architect",
                "category": "SOLID",
                "description": "Split modules",
                "reason_deferred": "Cohesion is good for now; revisit if module exceeds 800 lines threshold.",
            }
        )
        assert _validator().is_valid(plan)

    def test_unknown_kind_rejected(self):
        plan = self._build({"id": "x", "kind": "made-up"})
        assert not _validator().is_valid(plan)

    def test_missing_kind_rejected(self):
        plan = self._build({"id": "x"})
        assert not _validator().is_valid(plan)
