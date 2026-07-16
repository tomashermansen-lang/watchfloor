"""Structural assertions on ``claude/skills/plan-detection/SKILL.md``.

The skill body is the contract for graph-as-index orientation; these
tests assert the binding sections (5-step flow, consumption table,
read-budget, R30 prohibition, version dispatch) survive future edits.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SKILL = REPO_ROOT / "adapters" / "claude-code" / "claude" / "skills" / "plan-detection" / "SKILL.md"
COMMANDS_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "commands"


@pytest.fixture(scope="module")
def text() -> str:
    return SKILL.read_text()


def test_schema_version_dispatch_present(text):
    assert "Schema-Version Dispatch" in text
    assert "schema_version: 2.x.y" in text
    assert "schema_version: 1.x.y" in text


def test_5_step_flow_numbered(text):
    # Plan-ownership Track 1 (2026-05-25) collapsed Steps 1+2+3 into a
    # single "Step 1 — Project + phase + task orientation (one Bash call)"
    # that invokes task-view.py to obtain a per-phase slice. The legacy
    # three-step fallback path remains documented but is no longer
    # numbered as separate steps in the flow.
    for needle in (
        "Step 1 — Project + phase + task orientation",
        "Step 4 — Dependency-aware artefact loading",
        "Step 5 — Status awareness",
    ):
        assert needle in text, f"missing required heading: {needle!r}"


def test_read_budget_statement(text):
    assert "≤4 reads + 1 glob" in text
    assert "(3 + N)" in text or "3+N" in text


def test_r30_prohibition_present(text):
    assert "EXECUTION_PLAN.md" in text
    assert "SHALL NOT" in text or "shall not" in text.lower()


def test_consumption_table_includes_all_phase_agents(text):
    expected = [
        "/ba", "/ux", "/plan", "/review", "/team-review", "/implement",
        "/static-analysis", "/manualtest", "/qa", "/team-qa", "/commit",
        "/done", "/hotfix", "/retro",
    ]
    for cmd in expected:
        assert f"| {cmd} " in text, f"{cmd!r} missing from consumption table"


def test_per_phase_consumption_table_rows_have_command_files(text):
    """Every phase agent name should map to a command markdown file or be
    documented as virtual-only. Catches rename drift."""
    rows = re.findall(r"\| (/[a-z-]+) \|", text)
    virtual = {"/retro"}  # /retro is referenced but the command may live elsewhere
    for cmd in set(rows):
        if cmd in virtual:
            continue
        path = COMMANDS_DIR / f"{cmd[1:]}.md"
        assert path.exists(), f"command file missing for {cmd}: {path}"


def test_orientation_sentinel_markers_present(text):
    assert "plan-detection-start" in text
    assert "plan-detection-end" in text


def test_multi_plan_disambiguation_paragraph(text):
    """TC-PDS07: disambiguation section must document the git branch --show-current strategy."""
    assert "git branch --show-current" in text, (
        "plan-detection/SKILL.md must document 'git branch --show-current' for disambiguation"
    )


def test_retro_marked_exempt(text):
    """TC-PDS08: /retro row in the consumption table must carry the R29 exempt marking."""
    # The skill documents /retro as exempt from the R29 read budget.
    assert "/retro" in text
    assert "exempt" in text.lower(), (
        "plan-detection/SKILL.md must mark /retro as exempt from the R29 read budget"
    )


def test_legacy_heading_match_fallback_documented(text):
    """TC-PDS09: legacy fallback section must reference both EXECUTION_PLAN.md and heading-match."""
    assert "EXECUTION_PLAN.md" in text, (
        "plan-detection/SKILL.md must reference EXECUTION_PLAN.md in the legacy fallback section"
    )
    assert "heading-match" in text or "Heading-match" in text, (
        "plan-detection/SKILL.md must document heading-match in the legacy 1.x fallback"
    )
