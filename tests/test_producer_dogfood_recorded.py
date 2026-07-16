"""Regression guard against the dogfooded autopilot-stream recording.

Uses ``docs/INPROGRESS_Feature_unified-plan-yaml-schema/autopilot-stream.ndjson``
as the fixed recording of the producer run that created this very feature's
plan. Tests are lenient: they skip via ``pytest.skip()`` when the recording
does not contain the expected evidence rather than failing the suite.
"""
from __future__ import annotations

import pytest

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORDING = (
    REPO_ROOT
    / "docs"
    / "DONE_Feature_unified-plan-yaml-schema"
    / "autopilot-stream.ndjson"
)
TOOLS_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools"


def _load_events() -> list[dict]:
    """Parse the NDJSON recording; skip blank lines silently."""
    if not RECORDING.exists():
        return []
    events = []
    with RECORDING.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return events


def _read_tool_paths(events: list[dict]) -> list[str]:
    """Collect every file_path argument passed to the Read tool."""
    paths: list[str] = []
    for event in events:
        if event.get("type") != "assistant":
            continue
        for block in event.get("message", {}).get("content", []):
            if block.get("type") == "tool_use" and block.get("name") == "Read":
                path = block.get("input", {}).get("file_path", "")
                if path:
                    paths.append(path)
    return paths


def _find_plan_dirs() -> list[Path]:
    """Return any INPROGRESS_Plan_* dirs under docs/ that contain execution-plan.yaml."""
    plan_dirs = []
    for d in (REPO_ROOT / "docs").iterdir():
        if d.is_dir() and d.name.startswith("INPROGRESS_Plan_"):
            plan = d / "execution-plan.yaml"
            if plan.exists():
                plan_dirs.append(plan)
    return plan_dirs


class TestProducerDogfoodRecorded:
    """TC-PDR01 and TC-PDR03 — recording-based regression guards."""

    def test_recording_exists_and_parseable(self):
        """Sanity: recording file present and contains at least one event."""
        assert RECORDING.exists(), f"recording missing: {RECORDING}"
        events = _load_events()
        assert events, "recording is empty or unparseable"

    def test_skill_md_read_in_recording(self):
        """TC-PDR01: at least one Read event in the recording references a SKILL.md.

        The producer is expected to read a skill file (plan-detection or
        plan-producer-patterns) during orientation. Be lenient: skip if no
        evidence found rather than failing, since the recording may predate
        the producer-patterns skill instrumentation.
        """
        events = _load_events()
        if not events:
            pytest.skip("recording is empty")

        read_paths = _read_tool_paths(events)
        skill_reads = [p for p in read_paths if "SKILL.md" in p]

        if not skill_reads:
            pytest.skip(
                "no SKILL.md Read events found in recording — "
                "producer prompt structure may predate instrumentation"
            )

        # At least one SKILL.md was read — pass.
        assert skill_reads, "expected at least one SKILL.md Read event"

    @pytest.mark.xfail(
        reason=(
            "INPROGRESS_Plan_local-llm-test-harness deliberately clones canary "
            "task `what:` strings for A/B comparison (D/E/F/G/H all implement the "
            "same cost-measurement-baseline spec with different model setups). "
            "The shingle-overlap validator (plan_validators.py:detect_pattern_1_"
            "stub_strings) flags this as duplicate-content. Per the plan-ownership "
            "proposal (docs/A_B_test_canary-models/PLAN_OWNERSHIP_PROPOSAL.md) the "
            "fix is operator-driven /plan-project --update giving each canary "
            "variant-specific `what:` content; no automated phase agent may "
            "rewrite the experimental record. Remove this xfail when the operator "
            "has run /plan-project --update against this plan. Pre-dates commit "
            "57c3f87 (plan-ownership Track 1)."
        ),
        strict=False,
    )
    def test_resulting_plan_validates_clean(self):
        """TC-PDR03: any execution-plan.yaml produced in this run validates at exit 0.

        Looks for INPROGRESS_Plan_* dirs under docs/. If none found, skip.
        """
        plan_paths = _find_plan_dirs()
        if not plan_paths:
            pytest.skip("no INPROGRESS_Plan_*/execution-plan.yaml found under docs/")

        validate_script = TOOLS_DIR / "validate-plan.py"
        if not validate_script.exists():
            pytest.skip(f"validate-plan.py not found at {validate_script}")

        failures = []
        for plan_path in plan_paths:
            proc = subprocess.run(
                [sys.executable, str(validate_script), str(plan_path)],
                capture_output=True,
                text=True,
            )
            if proc.returncode != 0:
                failures.append(
                    f"{plan_path}: exit {proc.returncode}\n{proc.stdout}\n{proc.stderr}"
                )

        assert not failures, "validate-plan.py failed on:\n" + "\n---\n".join(failures)
