"""End-to-end dispatcher tests for the BACKLOG #45 fixtures.

Each test invokes ``validate-plan.py`` as a subprocess on the corresponding
fixture in ``tests/fixtures/plan-2.0.0/`` and asserts on exit code and the
combined stdout+stderr substrings. This exercises the full dispatch path
(``_run_legacy_mode`` → ``_run_2_0_mode`` → ``run_all``) the same way an
operator would invoke it.
"""
from __future__ import annotations

import sys
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
VALIDATE_PLAN = (
    REPO_ROOT
    / "adapters"
    / "claude-code"
    / "claude"
    / "tools"
    / "validate-plan.py"
)
FIXTURES_DIR = REPO_ROOT / "tests" / "fixtures" / "plan-2.0.0"


def _run(fixture: str) -> tuple[int, str, str]:
    fixture_path = FIXTURES_DIR / fixture
    result = subprocess.run(
        [sys.executable, str(VALIDATE_PLAN), str(fixture_path)],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout, result.stderr


def test_oversized_acceptance_yaml_exits_1():
    """AS-A1, R-A1."""
    rc, stdout, stderr = _run("oversized-acceptance.yaml")
    assert rc == 1
    combined = stdout + stderr
    assert "oversized-task" in combined
    assert "acceptance count > 5" in combined


def test_oversized_lines_estimate_yaml_exits_1():
    """AS-A2, R-A2 — hard cap is 200 LOC since 2026-05-07 (was 300)."""
    rc, stdout, stderr = _run("oversized-lines-estimate.yaml")
    assert rc == 1
    combined = stdout + stderr
    assert "huge-task" in combined
    assert "lines_estimate > 200" in combined


def test_oversized_touched_paths_yaml_exits_1():
    """AS-A3, R-A4 — hard cap is 4 paths since 2026-05-07 (was 5)."""
    rc, stdout, stderr = _run("oversized-touched-paths.yaml")
    assert rc == 1
    combined = stdout + stderr
    assert "wide-task" in combined
    assert "touched paths > 4" in combined


def test_medium_task_warning_yaml_exits_0_with_warning():
    """AS-A4, R-A5: WARNING in stderr; exit 0."""
    rc, stdout, stderr = _run("medium-task-warning.yaml")
    assert rc == 0, f"expected exit 0, got {rc}; stderr={stderr!r}"
    combined = stdout + stderr
    assert "WARNING:" in combined
    assert "medium-task" in combined


def test_parallel_modify_collision_yaml_exits_0_with_warning():
    """AS-C1, R-C1."""
    rc, stdout, stderr = _run("parallel-modify-collision.yaml")
    assert rc == 0, f"expected exit 0 (WARNING only), got {rc}; stdout={stdout!r}"
    combined = stdout + stderr
    assert "WARNING:" in combined
    assert "task-a" in combined
    assert "task-b" in combined
    assert "claude/tools/lib/foo.py" in combined


def test_bad_sequencing_rationale_yaml_exits_1():
    """AS-C2, R-C4."""
    rc, stdout, stderr = _run("bad-sequencing-rationale.yaml")
    assert rc == 1
    combined = stdout + stderr
    assert "phase-1" in combined
    assert "sequencing_rationale" in combined


def test_boundary_task_yaml_exits_0_silently():
    """EVAL-1: task at every cap boundary passes silently."""
    rc, stdout, stderr = _run("boundary-task.yaml")
    assert rc == 0
    # The task itself must not appear in any output line.
    for line in (stdout + stderr).splitlines():
        if line.startswith("Valid"):
            continue
        assert "boundary-task" not in line, f"unexpected boundary-task mention: {line!r}"


def test_full_yaml_passes_after_retrofit():
    """R2 risk regression: full.yaml must stay validation-clean as caps tighten.
    Originally tracked validator-2-0 lines 400→280; updated 2026-05-22 after the
    2026-05-07 cap tightening (hard cap 300→200) to use 100-LOC tasks."""
    rc, _stdout, _stderr = _run("full.yaml")
    assert rc == 0
