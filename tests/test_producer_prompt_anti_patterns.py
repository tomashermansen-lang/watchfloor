"""Structural assertions on producer command markdown (R24).

These tests verify the rewritten ``plan-project.md`` and ``plan.md`` carry
the producer-quality pattern references and self-review wiring documented
in the plan. They do not exercise behaviour — only file contents.
"""
from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
PLAN_PROJECT = REPO_ROOT / "adapters" / "claude-code" / "claude" / "commands" / "plan-project.md"
PLAN = REPO_ROOT / "adapters" / "claude-code" / "claude" / "commands" / "plan.md"
PRODUCER_PATTERNS_SKILL = REPO_ROOT / "adapters" / "claude-code" / "claude" / "skills" / "plan-producer-patterns" / "SKILL.md"

ANTI_PATTERN_NAMES = (
    "Stub strings",
    "Aspirational success_criteria",
    "Glob where.modify",
    "Tautological acceptance",
    "Dangling cross-references",
)


@pytest.fixture(scope="module")
def plan_project_text() -> str:
    return PLAN_PROJECT.read_text()


@pytest.fixture(scope="module")
def plan_text() -> str:
    return PLAN.read_text()


@pytest.fixture(scope="module")
def skill_text() -> str:
    return PRODUCER_PATTERNS_SKILL.read_text()


def test_plan_project_references_skill(plan_project_text):
    assert "claude/skills/plan-producer-patterns/" in plan_project_text


def test_plan_md_references_skill(plan_text):
    assert "claude/skills/plan-producer-patterns/" in plan_text


def test_plan_project_has_self_review_step(plan_project_text):
    assert "self-review" in plan_project_text.lower()
    assert "max 2 retries" in plan_project_text.lower()
    assert "quality_warnings" in plan_project_text


def test_plan_project_lists_five_anti_pattern_names(plan_project_text):
    for name in ANTI_PATTERN_NAMES:
        assert name in plan_project_text, f"{name!r} missing from plan-project.md"


def test_plan_md_lists_five_anti_pattern_names(plan_text):
    for name in ANTI_PATTERN_NAMES:
        assert name in plan_text, f"{name!r} missing from plan.md"


def test_skill_has_frontmatter_disable_invocation(skill_text):
    assert "disable-model-invocation: true" in skill_text
    assert "user-invocable: false" in skill_text


def test_skill_has_each_pattern_section(skill_text):
    for needle in (
        "Pattern 1 — Stub strings",
        "Pattern 2 — Aspirational success_criteria",
        "Pattern 3 — Glob",
        "Pattern 4 — Tautological acceptance",
        "Pattern 5 — Dangling cross-references",
        "Self-Review Protocol",
    ):
        assert needle in skill_text, f"{needle!r} missing from skill body"


def test_skill_documents_max_retries(skill_text):
    assert "two retries" in skill_text or "max_retries" in skill_text


def test_plan_project_marks_task_type_other_as_last_resort(plan_project_text):
    assert "last resort" in plan_project_text.lower()
    assert "task_type=other" in plan_project_text or "`task_type=other`" in plan_project_text


def test_plan_project_lists_all_eight_task_types(plan_project_text):
    """TC-PPA08 / issue #14: plan-project.md enumerates all 8 task_type enum values."""
    eight_types = (
        "development",
        "documentation",
        "research",
        "setup",
        "review",
        "refactor",
        "testing",
        "other",
    )
    for task_type in eight_types:
        assert task_type in plan_project_text, (
            f"task_type '{task_type}' missing from plan-project.md guidance table"
        )


def test_no_setup_plan_md_write_template(plan_text):
    """TC-PPA11: plan.md (feature-level /plan) must not contain a SETUP_PLAN.md
    write template — that belongs to /plan-project only."""
    assert "SETUP_PLAN.md" not in plan_text, (
        "plan.md must not reference SETUP_PLAN.md (project-level artefact belongs in plan-project.md)"
    )


def test_no_execution_plan_md_write_template_outside_legacy_notes(plan_text):
    """TC-PPA10: plan.md must not reference EXECUTION_PLAN.md outside legacy/migration
    context (the feature-level /plan command works with execution-plan.yaml only)."""
    assert "EXECUTION_PLAN.md" not in plan_text, (
        "plan.md must not reference EXECUTION_PLAN.md — use execution-plan.yaml (2.0) instead"
    )


def test_self_review_invocation_in_plan_project(plan_project_text):
    """TC-PPA12: plan-project.md must contain the literal self-review CLI invocation."""
    assert "python3 claude/tools/lib/plan_self_review.py" in plan_project_text, (
        "plan-project.md must invoke plan_self_review.py for the self-review step"
    )


def test_plan_md_anti_pattern_self_review(plan_text):
    """TC-PPA15: plan.md must document the anti-pattern self-review step."""
    text_lower = plan_text.lower()
    assert "anti-pattern self-review" in text_lower or "anti-pattern" in text_lower, (
        "plan.md must reference anti-pattern self-review"
    )


# --- Patterns 7-9 in SKILL.md (BACKLOG #45 — R-B1..R-B6 + AS-B1..AS-B3) -------


def _section(skill_text: str, heading: str) -> str:
    """Return the substring of skill_text from `heading` to the next `## ` heading.

    Used so we can assert markers appear *inside* a specific Pattern section.
    """
    start = skill_text.find(heading)
    assert start >= 0, f"{heading!r} not found in skill_text"
    after = skill_text.find("\n## ", start + 1)
    return skill_text[start:] if after < 0 else skill_text[start:after]


class TestPattern7Section:
    def test_pattern_7_section_present(self, skill_text):
        assert "## Pattern 7" in skill_text

    def test_pattern_7_pairs_with_validator_r_numbers(self, skill_text):
        section = _section(skill_text, "## Pattern 7")
        for r in ("R-A1", "R-A2", "R-A3", "R-A4"):
            assert r in section, f"{r} missing from Pattern 7 section"

    def test_pattern_7_documents_behavioral_seam(self, skill_text):
        section = _section(skill_text, "## Pattern 7")
        assert "behavioral seam" in section

    def test_pattern_7_includes_anti_pattern_block(self, skill_text):
        section = _section(skill_text, "## Pattern 7")
        assert "Anti-pattern" in section

    def test_pattern_7_includes_exemplar_block(self, skill_text):
        section = _section(skill_text, "## Pattern 7")
        assert "Exemplar" in section


class TestPattern8Section:
    def test_pattern_8_section_present(self, skill_text):
        assert "## Pattern 8" in skill_text

    def test_pattern_8_xml_markers_documented(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        for marker in ("<scope>", "<acceptance>", "<requirements>", "<boundaries>", "<out_of_scope>"):
            assert marker in section, f"marker {marker!r} missing from Pattern 8"

    def test_pattern_8_mandatory_markers_called_out(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        text = section.lower()
        # MANDATORY (case-insensitive) must appear, near scope/acceptance.
        assert "mandatory" in text or "MANDATORY" in section

    def test_pattern_8_verbosity_threshold_400_documented(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        assert "400" in section

    def test_pattern_8_documents_english_only_proxy(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        assert "English-only" in section or "English only" in section
        assert "extensions.language" in section

    def test_pattern_8_ears_in_requirements_block(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        assert "shall" in section

    def test_pattern_8_gherkin_in_acceptance_block(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        for kw in ("Given", "When", "Then"):
            assert kw in section, f"Gherkin keyword {kw!r} missing from Pattern 8"

    def test_pattern_8_boundaries_always_ask_never(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        for kw in ("Always", "Ask", "Never"):
            assert kw in section, f"Always/Ask/Never keyword {kw!r} missing"

    def test_pattern_8_references_self_review_protocol(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        assert "Self-Review Protocol" in section

    def test_pattern_8_documents_two_retry_max(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        text = section.lower()
        assert "2 retries" in text or "≤2 retries" in text or "max 2" in text or "two retries" in text

    def test_pattern_8_documents_quality_warnings_fallback(self, skill_text):
        section = _section(skill_text, "## Pattern 8")
        assert "quality_warnings" in section


class TestPattern9Section:
    def test_pattern_9_section_present(self, skill_text):
        assert "## Pattern 9" in skill_text

    def test_pattern_9_walking_skeleton_terminology(self, skill_text):
        section = _section(skill_text, "## Pattern 9")
        assert "walking skeleton" in section.lower()

    def test_pattern_9_ddd_vocab_allowed(self, skill_text):
        section = _section(skill_text, "## Pattern 9")
        for term in ("bounded context", "core subdomain", "supporting subdomain", "generic subdomain"):
            assert term in section, f"DDD term {term!r} missing from Pattern 9"

    def test_pattern_9_ddd_vocab_excluded_called_out(self, skill_text):
        section = _section(skill_text, "## Pattern 9")
        for term in ("aggregate", "entit", "value object", "repositor", "domain event"):
            assert term in section, f"excluded DDD term {term!r} missing from Pattern 9"

    def test_pattern_9_pairs_with_sequencing_rationale_enum(self, skill_text):
        section = _section(skill_text, "## Pattern 9")
        assert "sequencing_rationale" in section
        # at least one enum value present
        assert any(
            v in section
            for v in ("walking-skeleton", "data-model-first", "riskiest-first", "smallest-first")
        )


class TestPatterns1Through6Unchanged:
    def test_self_review_protocol_unchanged(self, skill_text):
        assert "## Self-Review Protocol" in skill_text

    def test_patterns_1_through_6_unchanged(self, skill_text):
        for n in range(1, 7):
            assert f"## Pattern {n} " in skill_text or f"## Pattern {n} —" in skill_text or f"## Pattern {n}\n" in skill_text
