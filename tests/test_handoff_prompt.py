"""Structural assertions on DASHBOARD_HANDOFF_PROMPT.md (R37, R38)."""
from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
HANDOFF = (
    REPO_ROOT
    / "docs"
    / "DONE_Feature_unified-plan-yaml-schema"
    / "DASHBOARD_HANDOFF_PROMPT.md"
)


@pytest.fixture(scope="module")
def text() -> str:
    return HANDOFF.read_text()


def test_handoff_file_present_and_nonempty(text):
    assert text


def test_required_literals_present(text):
    for needle in (
        "schema_version: 2.0.0",
        "execution-plan.yaml",
        "plan-detection",
        "deferred[]",
        "test_targets[]",
        "plan_status",
    ):
        assert needle in text, f"{needle!r} missing"


def test_four_section_headings_present(text):
    for heading in ("Renderer", "Plan editor", "Dependency graph", "Deferred audit"):
        assert heading in text


def test_handoff_cites_full_yaml(text):
    assert "tests/fixtures/plan-2.0.0/full.yaml" in text
    # TC-HP09 strengthened: at least one task id from full.yaml must appear in the handoff.
    import yaml as _yaml
    full_yaml = REPO_ROOT / "tests" / "fixtures" / "plan-2.0.0" / "full.yaml"
    plan = _yaml.safe_load(full_yaml.read_text())
    task_ids = [t.get("id", "") for ph in plan.get("phases", []) for t in ph.get("tasks", [])]
    assert any(tid and tid in text for tid in task_ids), (
        f"handoff must cite at least one task id from full.yaml; found ids: {task_ids}"
    )


def test_handoff_references_schema_path_and_validator(text):
    assert "claude/schema/execution-plan.schema.json" in text
    assert "validate-plan.py" in text
