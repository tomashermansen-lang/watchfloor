"""Acceptance check for the /plan-project-GENERATED integration-gate smoke plan.

This plan must be produced by `/plan-project smoke-test-pipeline-workflow` in a real
session — NOT hand-authored — otherwise it tests our assumptions, not what the
command actually emits (the whole point of an end-to-end test). Until it is
generated this module SKIPS; once the plan exists at the expected path it
becomes the acceptance harness, asserting the generated plan flows through the
real tooling:

  1. it VALIDATES under validate-plan.py (schema 2.0, exit 0),
  2. /plan-project actually authored a real kind=integration gate,
  3. every authored integration-gate trigger EQUALS the dotfiles manifest
     trigger by value (§7 coherence — the author↔executor agreement), and
  4. each gate has the exact shape the chain executor parses.

Generate it with:
    /plan-project smoke-test-pipeline-workflow
(describe a small dotfiles change that touches the dashboard so the planner
emits an integration gate per integration-gate-authoring/SKILL.md), then:
    bash ~/.claude/tools/autopilot-chain.sh --plan-dir docs/INPROGRESS_Plan_smoke-test-pipeline-workflow
"""
from __future__ import annotations

import subprocess

import pytest
import yaml
from conftest import REPO_ROOT

PLAN = REPO_ROOT / "docs/INPROGRESS_Plan_smoke-test-pipeline-workflow/execution-plan.yaml"
MANIFEST = REPO_ROOT / "pipeline.yaml"
VALIDATE = REPO_ROOT / "adapters/claude-code/claude/tools/validate-plan.py"

pytestmark = pytest.mark.skipif(
    not PLAN.exists(),
    reason="generate it first: /plan-project smoke-test-pipeline-workflow (end-to-end test)",
)


def _integration_checks() -> list[dict]:
    """Every kind=integration check across all phases (robust to whatever phase
    names /plan-project chose)."""
    plan = yaml.safe_load(PLAN.read_text())
    checks = []
    for phase in plan.get("phases", []):
        for item in (phase.get("gate") or {}).get("checklist", []):
            if isinstance(item, dict) and (item.get("check") or {}).get("kind") == "integration":
                checks.append(item["check"])
    return checks


def test_smoke_plan_validates():
    """The generated plan validates clean under schema 2.0 (exit 0, no ERROR)."""
    r = subprocess.run(
        ["python3", str(VALIDATE), str(PLAN)],
        capture_output=True, text=True, check=False,
    )
    assert r.returncode == 0, f"validate-plan failed: {r.stdout}\n{r.stderr}"
    assert "ERROR" not in r.stdout


def test_plan_project_authored_an_integration_gate():
    """The core end-to-end assertion: /plan-project actually emitted a real
    kind=integration gate (not just shell/human checks). If this fails, the
    integration-gate-authoring skill did not fire for a dashboard-touching phase."""
    checks = _integration_checks()
    assert checks, (
        "no kind=integration gate found — /plan-project did not author one. "
        "Ensure the planned feature touches the manifest trigger surface "
        "(dashboard/**, adapters/claude-code/claude/tools/**, core/schema/**)."
    )


def test_every_integration_gate_trigger_matches_manifest_by_value():
    """§7 coherence: each authored gate trigger == the manifest integration_test
    trigger, by value. Drift here is the green-theater failure the design exists
    to prevent — and the thing a hand-authored plan could never catch."""
    manifest_trigger = yaml.safe_load(MANIFEST.read_text())["integration_test"]["trigger"]
    for check in _integration_checks():
        assert check.get("trigger") == manifest_trigger, (
            f"gate trigger {check.get('trigger')} != manifest trigger {manifest_trigger}"
        )


def test_every_integration_gate_is_executor_parseable():
    """Each gate has the shape evaluate_phase_integration_checks parses:
    a trigger list + remediation with the contract's fields/enums."""
    for check in _integration_checks():
        assert isinstance(check.get("trigger"), list) and check["trigger"]
        rem = check.get("remediation") or {}
        assert rem.get("agent") == "lead-developer"
        assert isinstance(rem.get("max_iterations"), int) and 1 <= rem["max_iterations"] <= 5
        assert rem.get("on_unfixable") == "escalate"
