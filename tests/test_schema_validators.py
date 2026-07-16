"""Tests for schema-validators feature: --schema PATH mode in validate-plan.py.

Covers: TC1–TC10 from TESTPLAN.md (55 tests).
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest
from conftest import REPO_ROOT, SCHEMA_DIR, import_tool, run_tool

FIXTURES = REPO_ROOT / "tests" / "fixtures" / "schema-validators"


def schema_path(name: str) -> str:
    return str(SCHEMA_DIR / name)


def fixture_path(name: str) -> str:
    return str(FIXTURES / name)


# ---------------------------------------------------------------------------
# TC1: CLI Argument Parser
# ---------------------------------------------------------------------------


class TestCLIParsing:
    """REQ-1, REQ-2, EC-1.1–EC-1.4."""

    def test_tc1_1_schema_valid_exits_0(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            fixture_path("valid-baseline.json"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc1_2_schema_without_path(self) -> None:
        r = run_tool("validate-plan.py", "--schema")
        assert r.exit_code == 1
        assert "Usage:" in r.stderr

    def test_tc1_3_nonexistent_schema(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            "/nonexistent-schema.json",
            fixture_path("valid-baseline.json"),
        )
        assert r.exit_code == 1
        assert "Schema file not found" in r.stdout

    def test_tc1_4_nonexistent_data(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            "/nonexistent-data.json",
        )
        assert r.exit_code == 1
        assert "File not found" in r.stdout

    def test_tc1_5_invalid_json_schema(self, tmp_path: Path) -> None:
        bad = tmp_path / "bad.json"
        bad.write_text("{not valid json")
        r = run_tool(
            "validate-plan.py",
            "--schema",
            str(bad),
            fixture_path("valid-baseline.json"),
        )
        assert r.exit_code == 1
        assert "not valid JSON" in r.stdout

    def test_tc1_6_legacy_exits_0(self) -> None:
        plan = (
            REPO_ROOT / "docs" / "INPROGRESS_Plan_zero-tech-debt-pipeline" / "execution-plan.yaml"
        )
        if not plan.exists():
            pytest.skip("execution-plan.yaml not available")
        r = run_tool("validate-plan.py", str(plan))
        assert r.exit_code == 0
        assert "Valid." in r.stdout


# ---------------------------------------------------------------------------
# TC2: Structural Validation via jsonschema
# ---------------------------------------------------------------------------


class TestStructuralValidation:
    """REQ-3, REQ-7, REQ-9."""

    def setup_method(self) -> None:
        self.mod = import_tool("validate-plan.py")

    def _load_schema(self, name: str) -> dict:
        with open(SCHEMA_DIR / name) as f:
            return json.load(f)

    def test_tc2_1_valid_returns_empty(self) -> None:
        data = json.loads(Path(fixture_path("valid-baseline.json")).read_text())
        schema = self._load_schema("baseline.schema.json")
        errors = self.mod.validate_schema_structural(data, schema)
        assert errors == []

    def test_tc2_2_missing_required_field(self) -> None:
        data = json.loads(Path(fixture_path("valid-baseline.json")).read_text())
        del data["created_at"]
        schema = self._load_schema("baseline.schema.json")
        errors = self.mod.validate_schema_structural(data, schema)
        assert len(errors) > 0
        assert any("created_at" in e for e in errors)

    def test_tc2_3_oneOf_violation(self) -> None:
        data = json.loads(Path(fixture_path("valid-grinder-state.json")).read_text())
        data["current_batch"] = 42  # should be string or null
        schema = self._load_schema("grinder-state.schema.json")
        errors = self.mod.validate_schema_structural(data, schema)
        assert len(errors) > 0
        assert any("current_batch" in e or "oneOf" in e for e in errors)

    def test_tc2_4_minimum_maximum_violation(self) -> None:
        data = json.loads(Path(fixture_path("invalid-baseline.json")).read_text())
        schema = self._load_schema("baseline.schema.json")
        errors = self.mod.validate_schema_structural(data, schema)
        assert len(errors) > 0
        assert any("1.5" in e or "maximum" in e for e in errors)

    def test_tc2_5_pattern_includes_value(self) -> None:
        data = [json.loads(Path(fixture_path("bad-hash-deferred-findings.json")).read_text())[0]]
        schema = self._load_schema("deferred-findings.schema.json")
        errors = self.mod.validate_schema_structural(data, schema)
        assert any("python:S3776-auth.py-42" in e for e in errors)

    def test_tc2_6_errors_prefixed(self) -> None:
        data = {"bad": "data"}
        schema = self._load_schema("baseline.schema.json")
        errors = self.mod.validate_schema_structural(data, schema)
        assert len(errors) > 0
        for e in errors:
            assert e.startswith("ERROR:")


# ---------------------------------------------------------------------------
# TC3: Schema-Specific Semantic Dispatcher
# ---------------------------------------------------------------------------


class TestSchemaDetection:
    """REQ-8."""

    def setup_method(self) -> None:
        self.mod = import_tool("validate-plan.py")

    def test_tc3_1_grinder_plan_returns_validator(self) -> None:
        schema = {"$id": "grinder-plan.schema.json"}
        fn = self.mod.get_semantic_validator(schema)
        assert fn is self.mod.validate_grinder_plan_semantic

    def test_tc3_2_deferred_returns_validator(self) -> None:
        schema = {"$id": "deferred-findings.schema.json"}
        fn = self.mod.get_semantic_validator(schema)
        assert fn is self.mod.validate_deferred_findings_semantic

    def test_tc3_3_unknown_returns_none(self) -> None:
        schema = {"$id": "baseline.schema.json"}
        fn = self.mod.get_semantic_validator(schema)
        assert fn is None

    def test_tc3_4_missing_id_returns_none(self) -> None:
        schema = {"type": "object"}
        fn = self.mod.get_semantic_validator(schema)
        assert fn is None


# ---------------------------------------------------------------------------
# TC4: Grinder-Plan Semantic Validation
# ---------------------------------------------------------------------------


class TestGrinderPlanSemantic:
    """REQ-4, AS-1, AS-2, AS-6, AS-10, EC-4.1–EC-4.5."""

    def test_tc4_1_valid_plan(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("grinder-plan.schema.json"),
            fixture_path("valid-grinder-plan.yaml"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc4_2_circular_deps(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("grinder-plan.schema.json"),
            fixture_path("circular-deps-grinder-plan.yaml"),
        )
        assert r.exit_code == 1
        assert "->" in r.stdout
        # Verify cycle wraps back to the starting node (A -> C -> B -> A or similar)
        import re

        assert re.search(r"\w+ -> \w+ -> \w+ -> \w+", r.stdout), (
            f"Expected a full cycle path in output, got: {r.stdout}"
        )

    def test_tc4_3_dangling_ref(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("grinder-plan.schema.json"),
            fixture_path("dangling-ref-grinder-plan.yaml"),
        )
        assert r.exit_code == 1
        assert "999" in r.stdout
        assert "not found" in r.stdout

    def test_tc4_4_duplicate_batch_id(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("grinder-plan.schema.json"),
            fixture_path("duplicate-batch-id-grinder-plan.yaml"),
        )
        assert r.exit_code == 1
        assert "Duplicate" in r.stdout

    def test_tc4_5_self_ref(self) -> None:
        mod = import_tool("validate-plan.py")
        import yaml

        data = yaml.safe_load(Path(fixture_path("self-ref-grinder-plan.yaml")).read_text())
        errors = mod.validate_grinder_plan_semantic(data)
        assert any("001 -> 001" in e for e in errors)

    def test_tc4_6_empty_depends_on(self) -> None:
        mod = import_tool("validate-plan.py")
        data = {
            "passes": [
                {
                    "id": "p1",
                    "kind": "mechanical",
                    "batches": [
                        {
                            "id": "001",
                            "files": [],
                            "estimated_turns": 1,
                            "status": "pending",
                            "depends_on": [],
                        }
                    ],
                }
            ]
        }
        errors = mod.validate_grinder_plan_semantic(data)
        assert errors == []

    def test_tc4_7_empty_batches(self) -> None:
        mod = import_tool("validate-plan.py")
        import yaml

        data = yaml.safe_load(Path(fixture_path("empty-batches-grinder-plan.yaml")).read_text())
        errors = mod.validate_grinder_plan_semantic(data)
        assert errors == []

    def test_tc4_8_multiple_independent_cycles(self) -> None:
        mod = import_tool("validate-plan.py")
        data = {
            "passes": [
                {
                    "id": "p1",
                    "kind": "mechanical",
                    "batches": [
                        {
                            "id": "A",
                            "files": [],
                            "estimated_turns": 1,
                            "status": "pending",
                            "depends_on": ["B"],
                        },
                        {
                            "id": "B",
                            "files": [],
                            "estimated_turns": 1,
                            "status": "pending",
                            "depends_on": ["A"],
                        },
                        {
                            "id": "C",
                            "files": [],
                            "estimated_turns": 1,
                            "status": "pending",
                            "depends_on": ["D"],
                        },
                        {
                            "id": "D",
                            "files": [],
                            "estimated_turns": 1,
                            "status": "pending",
                            "depends_on": ["C"],
                        },
                    ],
                }
            ]
        }
        errors = mod.validate_grinder_plan_semantic(data)
        cycle_errors = [e for e in errors if "Circular" in e]
        assert len(cycle_errors) >= 2


# ---------------------------------------------------------------------------
# TC5: Deferred-Findings Semantic Validation
# ---------------------------------------------------------------------------


class TestDeferredFindingsSemantic:
    """REQ-5, REQ-7, AS-4, AS-7, AS-8, AS-9, AS-12, EC-5.1–EC-5.5."""

    def test_tc5_1_valid(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("deferred-findings.schema.json"),
            fixture_path("valid-deferred-findings.json"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc5_2_duplicate_id(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("deferred-findings.schema.json"),
            fixture_path("duplicate-id-deferred-findings.json"),
        )
        assert r.exit_code == 1
        assert "Duplicate" in r.stdout

    def test_tc5_3_template_pattern(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("deferred-findings.schema.json"),
            fixture_path("template-reason-deferred-findings.json"),
        )
        assert r.exit_code == 1
        assert "template pattern" in r.stdout
        assert "shellcheck:SC2086-auth-a3f2c8d1" in r.stdout

    def test_tc5_4_deferred_no_ticket(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("deferred-findings.schema.json"),
            fixture_path("deferred-no-ticket-deferred-findings.json"),
        )
        assert r.exit_code == 1
        assert "ticket" in r.stdout
        assert "missing" in r.stdout

    def test_tc5_5_bad_hash_structural(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("deferred-findings.schema.json"),
            fixture_path("bad-hash-deferred-findings.json"),
        )
        assert r.exit_code == 1
        assert "python:S3776-auth.py-42" in r.stdout

    def test_tc5_6_empty_array(self) -> None:
        mod = import_tool("validate-plan.py")
        errors = mod.validate_deferred_findings_semantic([])
        assert errors == []

    def test_tc5_7_mid_template_passes(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("deferred-findings.schema.json"),
            fixture_path("mid-template-deferred-findings.json"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc5_8_empty_ticket(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("deferred-findings.schema.json"),
            fixture_path("empty-ticket-deferred-findings.json"),
        )
        assert r.exit_code == 1
        assert "ticket" in r.stdout

    def test_tc5_9_non_deferred_no_ticket(self) -> None:
        mod = import_tool("validate-plan.py")
        entry = {
            "finding_id": "shellcheck:SC2086-auth-a3f2c8d1",
            "rule": "SC2086",
            "file": "auth.sh",
            "line": 42,
            "state": "WontFix",
            "reason": "x" * 50,
            "owner": "pipeline",
            "reviewed_at": "2026-04-17",
        }
        errors = mod.validate_deferred_findings_semantic([entry])
        assert errors == []

    def test_tc5_10_case_insensitive_template(self) -> None:
        mod = import_tool("validate-plan.py")
        entry = {
            "finding_id": "shellcheck:SC2086-auth-a3f2c8d1",
            "rule": "SC2086",
            "file": "auth.sh",
            "line": 42,
            "state": "WontFix",
            "reason": "PRE-EXISTING technical debt from initial release that has been present since inception",
            "owner": "pipeline",
            "reviewed_at": "2026-04-17",
        }
        errors = mod.validate_deferred_findings_semantic([entry])
        assert len(errors) > 0


# ---------------------------------------------------------------------------
# TC6: NDJSON Validation
# ---------------------------------------------------------------------------


class TestNDJSON:
    """REQ-6, AS-3, AS-11, AS-13, EC-6.1–EC-6.5."""

    def test_tc6_1_valid(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            fixture_path("valid-events.ndjson"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc6_2_truncated_final(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            fixture_path("truncated-final-events.ndjson"),
        )
        assert r.exit_code == 0
        assert "WARNING: skipping truncated final line" in r.stderr

    def test_tc6_3_truncated_mid(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            fixture_path("truncated-mid-events.ndjson"),
        )
        assert r.exit_code == 1
        assert "not valid JSON" in r.stdout
        assert "line" in r.stdout

    def test_tc6_4_empty_file(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            fixture_path("empty-events.ndjson"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc6_5_single_valid_line(self, tmp_path: Path) -> None:
        f = tmp_path / "single.ndjson"
        f.write_text('{"ts":"2026-04-17T10:00:00Z","batch":"001","event":"started"}\n')
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            str(f),
        )
        assert r.exit_code == 0

    def test_tc6_6_single_truncated_line(self, tmp_path: Path) -> None:
        f = tmp_path / "trunc.ndjson"
        f.write_text('{"ts":"2026-04')
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            str(f),
        )
        assert r.exit_code == 0
        assert "WARNING" in r.stderr

    def test_tc6_7_trailing_newline(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            fixture_path("trailing-newline-events.ndjson"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc6_8_blank_lines(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            fixture_path("blank-lines-events.ndjson"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout


# ---------------------------------------------------------------------------
# TC7: Data File Loader (Input Formats)
# ---------------------------------------------------------------------------


class TestInputFormats:
    """REQ-10."""

    def test_tc7_1_yaml_extension(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            fixture_path("valid-baseline.yaml"),
        )
        assert r.exit_code == 0

    def test_tc7_2_json_extension(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            fixture_path("valid-baseline.json"),
        )
        assert r.exit_code == 0

    def test_tc7_3_unknown_extension_fallback(self, tmp_path: Path) -> None:
        src = Path(fixture_path("valid-baseline.json"))
        dst = tmp_path / "data.dat"
        shutil.copy(src, dst)
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            str(dst),
        )
        assert r.exit_code == 0


# ---------------------------------------------------------------------------
# TC8: Error Output Format
# ---------------------------------------------------------------------------


class TestErrorFormat:
    """REQ-9."""

    def test_tc8_1_errors_to_stdout(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            fixture_path("invalid-baseline.json"),
        )
        assert "ERROR:" in r.stdout
        assert "ERROR:" not in r.stderr

    def test_tc8_2_warnings_to_stderr(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("events.schema.json"),
            fixture_path("truncated-final-events.ndjson"),
        )
        assert "WARNING:" in r.stderr
        assert "WARNING:" not in r.stdout

    def test_tc8_3_success_prints_valid(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            fixture_path("valid-baseline.json"),
        )
        assert "Valid." in r.stdout


# ---------------------------------------------------------------------------
# TC9: Backward Compatibility
# ---------------------------------------------------------------------------


class TestBackwardCompatibility:
    """REQ-2, AS-5."""

    def test_tc9_1_legacy_valid(self) -> None:
        plan = (
            REPO_ROOT / "docs" / "INPROGRESS_Plan_zero-tech-debt-pipeline" / "execution-plan.yaml"
        )
        if not plan.exists():
            pytest.skip("execution-plan.yaml not available")
        r = run_tool("validate-plan.py", str(plan))
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc9_2_legacy_invalid(self, tmp_path: Path) -> None:
        bad = tmp_path / "bad-plan.yaml"
        bad.write_text("{}\n")
        r = run_tool("validate-plan.py", str(bad))
        assert r.exit_code == 1
        assert "ERROR" in r.stdout

    def test_tc9_3_legacy_uses_hand_rolled(self) -> None:
        mod = import_tool("validate-plan.py")
        assert callable(mod.validate_structural)
        result = mod.validate_structural({}, {"required": ["foo"]})
        assert isinstance(result, list)
        assert len(result) > 0


# ---------------------------------------------------------------------------
# TC10: Structural-Only Schema Validation
# ---------------------------------------------------------------------------


class TestBaseline:
    """AS-14."""

    def test_tc10_1_valid(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            fixture_path("valid-baseline.json"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout

    def test_tc10_2_invalid_formatted_errors(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("baseline.schema.json"),
            fixture_path("invalid-baseline.json"),
        )
        assert r.exit_code == 1
        assert "ERROR:" in r.stdout


class TestManifest:
    def test_tc10_4_valid(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("manifest.schema.json"),
            fixture_path("valid-manifest.json"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout


class TestGrinderState:
    """AS-15."""

    def test_tc10_3_valid(self) -> None:
        r = run_tool(
            "validate-plan.py",
            "--schema",
            schema_path("grinder-state.schema.json"),
            fixture_path("valid-grinder-state.json"),
        )
        assert r.exit_code == 0
        assert "Valid." in r.stdout
