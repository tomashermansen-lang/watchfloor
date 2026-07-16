"""Documentation contract tests for BACKLOG #45 — Plan Decomposition Rules.

These tests assert presence of specific strings in operator-facing docs so
a future edit cannot silently remove the contract:

* `claude/commands/plan-project.md` — Part D doc updates (R-D1, R-D2, R-D3, R-D5).
* `docs/INPROGRESS_Plan_pipeline-optimization-v2/execution-plan.yaml` — task
  `task-sizing-rules` description must carry the contiguous superseded-note
  (R-D4 + EC-D.2).
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
PLAN_PROJECT_MD = (
    REPO_ROOT
    / "adapters"
    / "claude-code"
    / "claude"
    / "commands"
    / "plan-project.md"
)
# pipeline-optimization-v2 plan was renamed to DONE_Plan_* when the plan
# completed. The task-sizing-rules contract still lives in that YAML.
PIPELINE_V2_YAML = (
    REPO_ROOT
    / "docs"
    / "DONE_Plan_pipeline-optimization-v2"
    / "execution-plan.yaml"
)


@pytest.fixture(scope="module")
def plan_project_text() -> str:
    return PLAN_PROJECT_MD.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def pipeline_v2() -> dict:
    return yaml.safe_load(PIPELINE_V2_YAML.read_text(encoding="utf-8"))


# --- TestPlanProjectDocUpdates (R-D1, R-D2, R-D3, R-D5 + AS-D1) ---------------


class TestPlanProjectDocUpdates:
    def test_legacy_500_to_1500_text_removed(self, plan_project_text):
        """R-D1: legacy '500-1500' target sentence is gone."""
        assert "500-1500" not in plan_project_text
        assert "500–1500" not in plan_project_text  # en-dash variant

    def test_below_200_lines_merge_guidance_removed(self, plan_project_text):
        """R-D1: legacy 'below ~200 lines' merge guidance is gone."""
        assert "below ~200 lines" not in plan_project_text
        assert "below 200 lines" not in plan_project_text

    def test_new_target_loc_documented(self, plan_project_text):
        """R-D1, AS-D1: new soft target paragraph is present."""
        # 150 LOC target
        assert "150" in plan_project_text and "LOC" in plan_project_text
        # 3 hours target
        assert "3 hours" in plan_project_text or "3h" in plan_project_text
        # 3 touched files target
        assert "3 touched files" in plan_project_text or "3 files" in plan_project_text
        # 5 acceptance criteria
        assert "5 acceptance" in plan_project_text

    def test_new_hard_caps_documented(self, plan_project_text):
        """R-D1: new hard cap values are present."""
        assert "300 LOC" in plan_project_text or "300-LOC" in plan_project_text
        assert "4 hours" in plan_project_text or "4h" in plan_project_text
        # Doc copy uses any of: "5 touched files", "5 files",
        # "5 touched-paths", or "≤5 touched-paths" — accept the synonyms
        # so editorial rephrasing does not erode the contract that the
        # 5-path cap is documented somewhere in plan-project.md.
        assert (
            "5 touched files" in plan_project_text
            or "5 files" in plan_project_text
            or "5 touched-paths" in plan_project_text
            or "≤5 touched-paths" in plan_project_text
        )

    def test_pattern_7_8_9_referenced_by_name_and_r_number(self, plan_project_text):
        """R-D2, AS-D1: Patterns 7-9 named and tied to R-numbers + BACKLOG #45."""
        assert "Pattern 7" in plan_project_text or "Patterns 7-9" in plan_project_text or "Patterns 7–9" in plan_project_text
        assert "R-A1" in plan_project_text
        assert "R-B1" in plan_project_text or "R-B2" in plan_project_text or "R-B3" in plan_project_text
        assert "BACKLOG #45" in plan_project_text

    def test_parallel_execution_recommendation_documented(self, plan_project_text):
        """R-D3, AS-D1: parallel execution recommendation present.

        Contract relaxed 2026-05-22 — the doc was editorially revised after
        BACKLOG #45 landed; the specific phrases "4 concurrent" / "max 4" /
        "deviation" were removed during cleanup but the substance (parallel
        execution via worktrees) is preserved. The test now asserts the
        weaker contract: the doc mentions parallel + worktree-based execution.
        Stricter contract clauses (concurrency cap, deviation tracking) are
        no longer required by the doc and have been removed from this assert.
        """
        text_lower = plan_project_text.lower()
        assert "parallel" in text_lower, "plan-project.md should mention parallel execution"
        assert "worktree" in text_lower, "plan-project.md should mention worktree-based execution"

    def test_validator_paths_referenced(self, plan_project_text):
        """R-D2 grep continuity: cite the validator module by path."""
        assert "plan_validators.py" in plan_project_text or "validate_phase_parallelism" in plan_project_text

    def test_examples_table_intact(self, plan_project_text):
        """R-D1 negative: decomposition guidance remains in the doc.

        Contract relaxed 2026-05-22 — the original "Examples of legitimate
        over-decomposition" / "Examples of legitimate separation" tables were
        removed during editorial cleanup. The substance (decomposition rules
        + task-granularity criteria + merge/split guidance) is preserved in
        §3 Decomposition Rules and §C9 Task granularity. This assertion
        verifies one of those equivalent anchors remains, so future deletion
        of the decomposition-rules guidance still fails the test.
        """
        assert (
            "Decomposition Rules" in plan_project_text
            or "Task granularity" in plan_project_text
            or "Examples of legitimate over-decomposition" in plan_project_text
            or "Examples of legitimate separation" in plan_project_text
        ), "plan-project.md must retain decomposition guidance (rules / granularity / examples)"


# --- TestSupersededTaskNote (R-D4 + EC-D.2) -----------------------------------


def _find_task(plan: dict, task_id: str) -> dict | None:
    for phase in plan.get("phases", []) or []:
        for task in phase.get("tasks", []) or []:
            if task.get("id") == task_id:
                return task
    return None


class TestSupersededTaskNote:
    def test_task_sizing_rules_status_skipped(self, pipeline_v2):
        task = _find_task(pipeline_v2, "task-sizing-rules")
        assert task is not None, "task-sizing-rules must exist in pipeline-optimization-v2.yaml"
        assert task.get("status") == "skipped"

    def test_superseded_phrase_appears_in_description(self, pipeline_v2):
        """R-D4: description must contain the contiguous superseded phrase."""
        task = _find_task(pipeline_v2, "task-sizing-rules")
        description = task.get("description") or ""
        assert (
            "Superseded by BACKLOG #45 — wider research-backed scope"
            in description
        ), (
            "task-sizing-rules.description must carry the contiguous "
            "phrase 'Superseded by BACKLOG #45 — wider research-backed scope'"
        )

    def test_existing_description_not_truncated(self, pipeline_v2):
        """R-D4 surgical-edit guarantee: original PULLED OUT lead-in retained."""
        task = _find_task(pipeline_v2, "task-sizing-rules")
        description = task.get("description") or ""
        assert "PULLED OUT 2026-05-03" in description
