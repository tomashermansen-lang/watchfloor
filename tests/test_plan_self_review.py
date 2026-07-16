"""Unit tests for ``claude/tools/lib/plan_self_review.py`` (R25/AS-18)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib"
sys.path.insert(0, str(LIB_DIR))

import plan_self_review as psr  # noqa: E402


def _write(tmp_path: Path, plan: dict) -> Path:
    p = tmp_path / "execution-plan.yaml"
    p.write_text(yaml.safe_dump(plan, sort_keys=False))
    return p


def _minimal_plan() -> dict:
    src = REPO_ROOT / "tests" / "fixtures" / "plan-2.0.0" / "minimal.yaml"
    return yaml.safe_load(src.read_text())


def test_clean_plan_returns_no_errors(tmp_path):
    p = _write(tmp_path, _minimal_plan())
    result = psr.self_review(p, attempt=0)
    assert result.errors == []
    assert result.retry_advised is False


def test_stub_string_classified_to_pattern_1(tmp_path):
    plan = _minimal_plan()
    plan["phases"][0]["tasks"][0]["what"] = "short"
    p = _write(tmp_path, plan)
    result = psr.self_review(p, attempt=0)
    assert result.errors
    assert any(e["pattern_id"] == "stub-strings" for e in result.errors)
    assert any("pattern-1" in e["exemplar_ref"] for e in result.errors)


def test_glob_classified_to_pattern_3(tmp_path):
    plan = _minimal_plan()
    plan["phases"][0]["tasks"][0]["where"]["modify"] = ["claude/**"]
    p = _write(tmp_path, plan)
    result = psr.self_review(p, attempt=0)
    assert any(e["pattern_id"] == "exact-paths" for e in result.errors)


def test_non_ears_classified_to_pattern_4(tmp_path):
    plan = _minimal_plan()
    plan["phases"][0]["tasks"][0]["acceptance"] = ["The system works"]
    p = _write(tmp_path, plan)
    result = psr.self_review(p, attempt=0)
    assert any(e["pattern_id"] == "ears-acceptance" for e in result.errors)


def test_retry_advised_when_attempt_below_max(tmp_path):
    plan = _minimal_plan()
    plan["phases"][0]["tasks"][0]["what"] = "short"
    p = _write(tmp_path, plan)
    assert psr.self_review(p, attempt=0).retry_advised is True
    assert psr.self_review(p, attempt=1).retry_advised is True
    assert psr.self_review(p, attempt=2).retry_advised is False


def test_third_attempt_success_R25_AS18(tmp_path):
    """Drives the deterministic AS-18 retry-loop scenario.

    The producer makes two faulty drafts and a third clean one. After the
    third attempt the retry_advised flag must flip to False and there must
    be no remaining errors.
    """
    plan = _minimal_plan()
    plan["phases"][0]["tasks"][0]["what"] = "short"  # attempt 0 — bad
    p = _write(tmp_path, plan)
    r0 = psr.self_review(p, attempt=0)
    assert r0.retry_advised is True

    # Producer regenerates -- still bad (different short string).
    plan["phases"][0]["tasks"][0]["what"] = "still-too-short"
    _write(tmp_path, plan)
    r1 = psr.self_review(p, attempt=1)
    assert r1.retry_advised is True

    # Third attempt: producer applies exemplar guidance.
    plan["phases"][0]["tasks"][0]["what"] = (
        "Define the JSON Schema 2.0.0 contract covering project, phase, and task field sets with additionalProperties false at every level so unknown fields are rejected."
    )
    _write(tmp_path, plan)
    r2 = psr.self_review(p, attempt=2)
    assert r2.errors == []
    assert r2.retry_advised is False


def test_cli_emits_json_and_exit_code(tmp_path, capsys):
    plan = _minimal_plan()
    p = _write(tmp_path, plan)
    rc = psr.main([str(p)])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert rc == 0
    assert payload["retry_advised"] is False
    assert payload["max_retries"] == 2


def test_aspirational_criteria_returns_warning_no_retry(tmp_path):
    """TC-PSR03: aspirational description without measurable artefact → WARNING only,
    retry_advised=False (warnings do not drive retry)."""
    plan = _minimal_plan()
    plan["success_criteria"] = [
        {"id": "SC-1", "description": "well-designed system", "measurable_via": "test"}
    ]
    p = _write(tmp_path, plan)
    result = psr.self_review(p, attempt=0)
    # Aspirational language is a WARNING, not an error — retry must not be advised.
    assert result.retry_advised is False
    assert any("aspirational" in w.get("raw", "") for w in result.warnings)


def test_cli_stdout_json_keys(tmp_path, capsys):
    """TC-PSR07: CLI stdout JSON must contain all 5 required keys."""
    plan = _minimal_plan()
    p = _write(tmp_path, plan)
    psr.main([str(p)])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    for key in ("errors", "warnings", "retry_advised", "attempt", "max_retries"):
        assert key in payload, f"missing key {key!r} in CLI output"


def test_errors_cite_skill_pattern_ref(tmp_path):
    """TC-PSR08: errors[].exemplar_ref must reference plan-producer-patterns/SKILL.md#pattern-."""
    plan = _minimal_plan()
    plan["phases"][0]["tasks"][0]["what"] = "short"
    p = _write(tmp_path, plan)
    result = psr.self_review(p, attempt=0)
    assert result.errors, "expected at least one error for stub what"
    for err in result.errors:
        assert "claude/skills/plan-producer-patterns/SKILL.md#" in err["exemplar_ref"], (
            f"exemplar_ref missing expected prefix: {err['exemplar_ref']!r}"
        )


def test_max_retries_module_constant():
    """TC-PSR10: MAX_RETRIES module constant equals 2."""
    assert psr.MAX_RETRIES == 2


# --- Pattern 7 / 9 classifier wiring (BACKLOG #45 — F1 closure) ---------------


class TestPatternHintsClassification:
    """Verify _classify maps the new sizing/parallelism/rationale errors to
    Pattern 7 (oversize-task-split) and Pattern 9 (walking-skeleton)."""

    def test_acceptance_count_classifies_to_pattern_7(self):
        out = psr._classify("task.t1: acceptance count > 5 (got 6)")
        assert out["pattern_id"] == "oversize-task-split"
        assert out["exemplar_ref"].endswith("#pattern-7")

    def test_lines_estimate_classifies_to_pattern_7(self):
        out = psr._classify("task.t1: lines_estimate > 300 hard cap (got 400)")
        assert out["pattern_id"] == "oversize-task-split"
        assert out["exemplar_ref"].endswith("#pattern-7")

    def test_duration_hours_classifies_to_pattern_7(self):
        out = psr._classify("task.t1: duration_hours > 4 hard cap (got 6)")
        assert out["pattern_id"] == "oversize-task-split"
        assert out["exemplar_ref"].endswith("#pattern-7")

    def test_touched_paths_classifies_to_pattern_7(self):
        out = psr._classify("task.t1: touched paths > 5 hard cap (got 6)")
        assert out["pattern_id"] == "oversize-task-split"
        assert out["exemplar_ref"].endswith("#pattern-7")

    def test_estimate_missing_classifies_to_pattern_7(self):
        out = psr._classify("WARNING: task.t1: estimate missing — populate lines_estimate")
        assert out["pattern_id"] == "oversize-task-split"
        assert out["exemplar_ref"].endswith("#pattern-7")

    def test_sequencing_rationale_classifies_to_pattern_9(self):
        # Mirror the actual validator output: enum is sorted alphabetically.
        msg = "phase.p1.sequencing_rationale: must be one of data-model-first/riskiest-first/smallest-first/walking-skeleton OR >=40 chars (got 'foo', length 3)"
        out = psr._classify(msg)
        assert out["pattern_id"] == "walking-skeleton"
        assert out["exemplar_ref"].endswith("#pattern-9")

    def test_parallelism_overlap_classifies_to_pattern_7(self):
        out = psr._classify(
            "WARNING: phase.p1: tasks t1, t2 both write src/x.py — add depends edge or split phase"
        )
        assert out["pattern_id"] == "oversize-task-split"
        assert out["exemplar_ref"].endswith("#pattern-7")

    def test_unrelated_string_unclassified(self):
        out = psr._classify("nothing matches here")
        assert out["pattern_id"] == "unclassified"

    def test_existing_classifications_unchanged(self):
        """Pre-existing needles still map to their original pattern (regression guard)."""
        cases = [
            ("task.t1.what: minimum length 80 characters not met (12)", "stub-strings", "pattern-1"),
            ("task.t1.what duplicates task.t2.what — content must be task-specific", "stub-strings", "pattern-1"),
            ("WARNING: project.success_criteria.SC-1: description uses aspirational language", "aspirational-criteria", "pattern-2"),
            ("task.t1.where.modify[0]: glob pattern not allowed, use exact paths", "exact-paths", "pattern-3"),
            ("task.t1.acceptance[0]: must use EARS notation (When/While/If/Where ... shall ...)", "ears-acceptance", "pattern-4"),
            ("phase.p1.kill_criteria_refs[0]: ID 'KC-X' does not resolve", "xrefs", "pattern-5"),
        ]
        for line, pid, anchor in cases:
            out = psr._classify(line)
            assert out["pattern_id"] == pid, f"{line!r} → {out['pattern_id']!r} (expected {pid})"
            assert out["exemplar_ref"].endswith(f"#{anchor}")

    def test_exemplar_ref_format_consistent(self):
        """All new tuples must produce SKILL.md#pattern-N anchors."""
        import re as _re

        new_lines = [
            "task.t1: acceptance count > 5 (got 6)",
            "task.t1: lines_estimate > 300 hard cap (got 400)",
            "task.t1: duration_hours > 4 hard cap (got 6)",
            "task.t1: touched paths > 5 hard cap (got 6)",
            "WARNING: task.t1: estimate missing — populate lines_estimate",
            "phase.p1.sequencing_rationale: must be one of walking-skeleton OR >=40 chars",
            "WARNING: phase.p1: tasks t1, t2 both write src/x.py",
        ]
        ref_re = _re.compile(r"claude/skills/plan-producer-patterns/SKILL\.md#pattern-\d+$")
        for line in new_lines:
            out = psr._classify(line)
            assert ref_re.search(out["exemplar_ref"]), out["exemplar_ref"]

    def test_actual_validator_output_classifies_correctly(self):
        """End-to-end: real validator output (not a hand-written string) must
        route to the right pattern. Guards against the alphabetised-enum-list
        bug where the needle 'must be one of walking-skeleton' did not match
        the actual emitted 'must be one of data-model-first/...'."""
        import sys as _sys

        _sys.path.insert(0, str(LIB_DIR))
        import plan_validators as pv  # noqa: PLC0415

        plan = {
            "schema_version": "2.0.0",
            "project": {
                "id": "p", "description": "x",
                "requirements": [], "goals": [], "deferred": [],
            },
            "phases": [
                {
                    "id": "p1", "name": "P1",
                    "sequencing_rationale": "foo",
                    "gate": {"id": "g1", "on_pass": []},
                    "tasks": [],
                }
            ],
        }
        ctx = pv.ValidationContext.build(plan, REPO_ROOT)
        lines = pv.validate_sequencing_rationale_enum(ctx)
        assert lines, "validator should produce at least one error"
        out = psr._classify(lines[0])
        assert out["pattern_id"] == "walking-skeleton", (
            f"sequencing-rationale validator output did not classify to "
            f"pattern-9 — needle in _PATTERN_HINTS does not match real "
            f"output. Got: {out['pattern_id']!r}, line: {lines[0]!r}"
        )
        assert out["exemplar_ref"].endswith("#pattern-9")
