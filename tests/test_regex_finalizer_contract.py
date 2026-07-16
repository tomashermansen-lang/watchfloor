"""Contract tests for regex finalizers in commit-finalize.sh and autopilot-chain.sh.

Both scripts mutate execution-plan.yaml in-place via Python regex substitutions
to avoid the formatting drift that yaml.safe_dump round-trips produce. The
regexes anchor on `- id: <id>` followed by indented lines; if any caller
rewrites the plan with sort_keys=True (the default), keys get alphabetized
and the entry starts with `- depends:` (or whatever sorts first), breaking
the anchor.

These tests fix the contract between:
- the writers: deviation-tracker.py, plan_yaml_deferred.py, autopilot-chain.sh
  itself (gate-eval), grinder-plan-update.py, grinder-discover.py
- the readers: commit-finalize.sh's post-merge regex, autopilot-chain.sh's
  gate-passed regex

If a future writer drops sort_keys=False (or alphabetizes some other way),
these tests will fail. If a reader's regex pattern changes, the helper
constants here MUST be updated to match — they are the contract.
"""

from __future__ import annotations

import io
import re
import subprocess
import sys

import pytest
import yaml
from conftest import REPO_ROOT

# Regex patterns that the production scripts use. Mirror these verbatim.
# Update both this file AND the shell scripts together if either changes.
TASK_STATUS_PATTERN = (
    # commit-finalize.sh post-merge update — matches `- id: TASK\n[indented_with_word]*?status: WORD`
    r"(- id: {tid}\n(?:[ \t]+\w.*\n)*?)([ \t]+status: )\w+"
)
GATE_PASSED_PATTERN = (
    # autopilot-chain.sh gate-eval persistence — matches `- id: PHASE\n[indented]*?passed: false`
    r"(- id: {pid}\n(?:[ \t].*\n)*?[ \t]+passed: )false"
)


@pytest.fixture
def block_style_plan() -> dict:
    """A minimal plan in the block-style form the producer authors."""
    return {
        "schema_version": "2.0.0",
        "name": "regex-contract-fixture",
        "phases": [
            {
                "id": "phase-1",
                "name": "Phase 1",
                "tasks": [
                    {
                        "id": "task-a",
                        "name": "First task",
                        "task_type": "development",
                        "status": "pending",
                        "phase_results": [],
                    },
                    {
                        "id": "task-b",
                        "name": "Second task",
                        "task_type": "development",
                        "status": "pending",
                        "depends": ["task-a"],
                        "phase_results": [],
                    },
                ],
                "gate": {
                    "name": "Phase 1 Gate",
                    "checklist": [],
                    "passed": False,
                },
            },
        ],
    }


def _dump_with(plan: dict, **kwargs) -> str:
    """Dump plan via yaml.dump and return resulting YAML text."""
    buf = io.StringIO()
    yaml.dump(plan, buf, default_flow_style=False, **kwargs)
    return buf.getvalue()


def _safe_dump_with(plan: dict, **kwargs) -> str:
    """Dump plan via yaml.safe_dump (mirrors plan_yaml_deferred)."""
    buf = io.StringIO()
    yaml.safe_dump(plan, buf, default_flow_style=False, **kwargs)
    return buf.getvalue()


# ── Task status regex ──────────────────────────────────────────────────


def test_task_status_regex_matches_after_safe_dump_sort_keys_false(block_style_plan):
    """plan_yaml_deferred.py uses safe_dump with sort_keys=False. Regex must match."""
    rendered = _safe_dump_with(block_style_plan, sort_keys=False)
    pattern = TASK_STATUS_PATTERN.format(tid=re.escape("task-a"))
    new, n = re.subn(pattern, r"\g<1>\g<2>done", rendered)
    assert n == 1, f"task-a status regex missed in safe_dump output:\n{rendered}"
    assert "status: done" in new


def test_task_status_regex_matches_after_yaml_dump_sort_keys_false(block_style_plan):
    """deviation-tracker.py uses yaml.dump with sort_keys=False. Regex must match."""
    rendered = _dump_with(block_style_plan, sort_keys=False)
    pattern = TASK_STATUS_PATTERN.format(tid=re.escape("task-b"))
    new, n = re.subn(pattern, r"\g<1>\g<2>done", rendered)
    assert n == 1, f"task-b status regex missed in yaml.dump output:\n{rendered}"
    assert "status: done" in new


def test_task_status_regex_misses_when_keys_alphabetized(block_style_plan):
    """Control: with sort_keys=True (the default), the regex MISSES task-b.

    task-b has a `depends:` key which sorts alphabetically BEFORE `id:` so
    the entry no longer starts with `- id:`. This is the exact failure
    mode that caused deviation-tracker-full-monty Phase 2's tasks to lose
    their status updates: every task in that plan had a `depends:` key
    (or some other field that sorts before `id:`), so each yaml.dump
    rewrite without sort_keys=False shifted the entry's first key.

    If this assertion ever passes (regex matches despite alphabetization),
    either the regex was relaxed or yaml.dump's behaviour changed —
    investigate before assuming the contract still holds.
    """
    rendered = _dump_with(block_style_plan, sort_keys=True)
    pattern = TASK_STATUS_PATTERN.format(tid=re.escape("task-b"))
    _, n = re.subn(pattern, r"\g<1>\g<2>done", rendered)
    assert n == 0, (
        "Expected the regex to MISS when keys are alphabetized — but it matched. "
        "Either the regex was relaxed (good news) or yaml.dump's behaviour changed. "
        f"Rendered:\n{rendered}"
    )


# ── Gate passed regex ──────────────────────────────────────────────────


def test_gate_passed_regex_matches_after_safe_dump_sort_keys_false(block_style_plan):
    rendered = _safe_dump_with(block_style_plan, sort_keys=False)
    pattern = GATE_PASSED_PATTERN.format(pid=re.escape("phase-1"))
    new, n = re.subn(pattern, r"\g<1>true", rendered, count=1)
    assert n == 1, f"phase-1 gate regex missed:\n{rendered}"
    assert "passed: true" in new


def test_gate_passed_regex_matches_after_yaml_dump_sort_keys_false(block_style_plan):
    rendered = _dump_with(block_style_plan, sort_keys=False)
    pattern = GATE_PASSED_PATTERN.format(pid=re.escape("phase-1"))
    new, n = re.subn(pattern, r"\g<1>true", rendered, count=1)
    assert n == 1, f"phase-1 gate regex missed:\n{rendered}"


# ── Round-trip via deviation-tracker.py's actual code path ─────────────


def test_deviation_tracker_preserves_regex_anchors(tmp_path, block_style_plan):
    """End-to-end: write plan, invoke deviation-tracker.py to append a phase_result,
    re-read the result, assert both regexes still match."""
    plan_path = tmp_path / "execution-plan.yaml"
    # Author the plan in block style so the regex anchors exist initially.
    with plan_path.open("w") as f:
        yaml.dump(block_style_plan, f, default_flow_style=False, sort_keys=False)

    # Invoke deviation-tracker.py with a valid phase_result entry.
    phase_result = {
        "phase": "qa",
        "timestamp": "2026-05-03T10:00:00Z",
        "conformance": "aligned",
        "acceptance_status": "met",
        "deviations": [],
    }
    import json as _json

    tracker = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "deviation-tracker.py"
    proc = subprocess.run(
        [sys.executable, str(tracker), "--plan-yaml", str(plan_path), "--task-id", "task-a"],
        input=_json.dumps(phase_result),
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == 0, f"tracker failed: {proc.stderr}"

    rendered = plan_path.read_text()

    # Both regex anchors must still find their tasks/phases.
    for tid in ("task-a", "task-b"):
        pattern = TASK_STATUS_PATTERN.format(tid=re.escape(tid))
        match = re.search(pattern, rendered)
        assert match is not None, (
            f"task-status regex anchor lost for {tid} after deviation-tracker write. "
            f"This is the deviation-tracker-full-monty Phase 2 bug. "
            f"File:\n{rendered}"
        )

    pattern = GATE_PASSED_PATTERN.format(pid=re.escape("phase-1"))
    match = re.search(pattern, rendered)
    assert match is not None, (
        f"gate-passed regex anchor lost after deviation-tracker write:\n{rendered}"
    )
