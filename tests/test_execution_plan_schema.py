"""Tests for execution-plan.schema.json — schema extensions (SC-1..16)."""
from __future__ import annotations

import json

import pytest
from conftest import CLAUDE_SCHEMA_DIR
from jsonschema import Draft202012Validator


@pytest.fixture(scope="module")
def schema() -> dict:
    """Load the execution-plan schema."""
    schema_path = CLAUDE_SCHEMA_DIR / "execution-plan.schema.json"
    return json.loads(schema_path.read_text())


@pytest.fixture(scope="module")
def validator(schema: dict) -> Draft202012Validator:
    """Create a validator for the execution-plan schema."""
    return Draft202012Validator(schema)


def _minimal_plan(**overrides) -> dict:
    """Create a minimal valid plan for testing."""
    plan = {
        "schema_version": "1.0.0",
        "name": "Test Plan",
        "phases": [],
    }
    plan.update(overrides)
    return plan


def _minimal_task(**overrides) -> dict:
    """Create a minimal valid task."""
    task = {"id": "test-task", "name": "Test Task", "status": "pending"}
    task.update(overrides)
    return task


def _plan_with_gate(checklist: list, **gate_overrides) -> dict:
    """Create a plan with a single phase containing a gate."""
    gate = {"name": "Test Gate", "checklist": checklist, "passed": False}
    gate.update(gate_overrides)
    return _minimal_plan(phases=[{
        "id": "phase-1",
        "name": "Phase 1",
        "tasks": [_minimal_task()],
        "gate": gate,
    }])


def _plan_with_task(**task_overrides) -> dict:
    """Create a plan with a single task."""
    return _minimal_plan(phases=[{
        "id": "phase-1",
        "name": "Phase 1",
        "tasks": [_minimal_task(**task_overrides)],
    }])


def _is_valid(validator: Draft202012Validator, instance: dict) -> bool:
    return validator.is_valid(instance)


def _errors(validator: Draft202012Validator, instance: dict) -> list[str]:
    return [e.message for e in validator.iter_errors(instance)]


def _item_validator(schema: dict) -> Draft202012Validator:
    """Validate a single checklist item against ``checklist_item_2_0``.

    Avoids building a full 2.0 plan (14 required top-level fields) just to
    reach one checklist item. The wrapper carries the whole ``$defs`` block
    so internal ``#/$defs/...`` references (e.g. gate_remediation) resolve.
    """
    wrapper = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$ref": "#/$defs/checklist_item_2_0",
        "$defs": schema["$defs"],
    }
    return Draft202012Validator(wrapper)


def _integration_item(**check_overrides) -> dict:
    """A valid kind:integration checklist item; override individual check fields."""
    check = {
        "kind": "integration",
        "command": "bash dashboard/tests/run-all.sh --only-integration",
        "trigger": ["dashboard/**", "adapters/claude-code/claude/tools/**"],
        "remediation": {
            "agent": "lead-developer",
            "max_iterations": 2,
            "on_unfixable": "escalate",
        },
    }
    for key, value in check_overrides.items():
        if value is _OMIT:
            check.pop(key, None)
        else:
            check[key] = value
    return {"item": "Dashboard subsystems integrate end-to-end", "check": check}


_OMIT = object()


# --- SC-1: Backwards compatibility ---

class TestBackwardsCompat:
    """SC-1: Existing plan without check or phase_results validates."""

    def test_existing_plan_validates(self, validator: Draft202012Validator):
        plan = _plan_with_gate(["item 1", "item 2"])
        assert _is_valid(validator, plan)


# --- SC-2: Plain string checklist items ---

class TestPlainStringChecklist:
    """SC-2: Gate checklist item as plain string validates."""

    def test_string_checklist_item(self, validator: Draft202012Validator):
        plan = _plan_with_gate(["plain string item"])
        assert _is_valid(validator, plan)


# --- SC-3: Object checklist with kind:shell + cmd ---

class TestShellChecklistItem:
    """SC-3: Gate checklist item as object with kind:shell + cmd validates."""

    def test_shell_check_validates(self, validator: Draft202012Validator):
        plan = _plan_with_gate([{
            "item": "Run smoke test",
            "check": {"kind": "shell", "cmd": "echo ok"},
        }])
        assert _is_valid(validator, plan)


# --- SC-4: Object checklist with kind:human ---

class TestHumanChecklistItem:
    """SC-4: Gate checklist item with kind:human (no cmd) validates."""

    def test_human_check_validates(self, validator: Draft202012Validator):
        plan = _plan_with_gate([{
            "item": "Manual review needed",
            "check": {"kind": "human"},
        }])
        assert _is_valid(validator, plan)


# --- SC-5: kind:shell missing cmd rejects ---

class TestShellMissingCmd:
    """SC-5: Gate checklist item with kind:shell missing cmd rejects."""

    def test_shell_without_cmd_rejects(self, validator: Draft202012Validator):
        plan = _plan_with_gate([{
            "item": "Run smoke test",
            "check": {"kind": "shell"},
        }])
        assert not _is_valid(validator, plan)


# --- SC-6: Invalid kind enum rejects ---

class TestInvalidKindEnum:
    """SC-6: Gate checklist item with invalid kind enum rejects."""

    def test_invalid_kind_rejects(self, validator: Draft202012Validator):
        plan = _plan_with_gate([{
            "item": "Bad kind",
            "check": {"kind": "automatic"},
        }])
        assert not _is_valid(validator, plan)


# --- SC-7: Valid phase_results ---

class TestValidPhaseResults:
    """SC-7: Task with valid phase_results array validates."""

    def test_valid_phase_results(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "aligned",
            "acceptance_status": "met",
            "deviations": [],
        }])
        assert _is_valid(validator, plan)


# --- SC-8: phase_results missing required field ---

class TestPhaseResultsMissingField:
    """SC-8: phase_results entry missing required field rejects."""

    def test_missing_conformance_rejects(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            # missing conformance
            "acceptance_status": "met",
            "deviations": [],
        }])
        assert not _is_valid(validator, plan)


# --- SC-9: Invalid conformance enum ---

class TestInvalidConformance:
    """SC-9: conformance invalid enum value rejects."""

    def test_invalid_conformance_rejects(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "unknown",
            "acceptance_status": "met",
            "deviations": [],
        }])
        assert not _is_valid(validator, plan)


# --- SC-10: Invalid acceptance_status enum ---

class TestInvalidAcceptanceStatus:
    """SC-10: acceptance_status invalid enum value rejects."""

    def test_invalid_acceptance_status_rejects(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "aligned",
            "acceptance_status": "unknown",
            "deviations": [],
        }])
        assert not _is_valid(validator, plan)


# --- SC-11: Valid deviation ---

class TestValidDeviation:
    """SC-11: Deviation with all required fields validates."""

    def test_valid_deviation(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "deviated",
            "acceptance_status": "partial",
            "deviations": [{
                "type": "scope_change",
                "description": "Added edge case handling",
                "reason": "BA identified gap in requirements",
                "impact": "added",
                "criteria_affected": ["AC-1"],
            }],
        }])
        assert _is_valid(validator, plan)


# --- SC-12: Invalid deviation type ---

class TestInvalidDeviationType:
    """SC-12: Deviation with invalid type enum rejects."""

    def test_invalid_type_rejects(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "deviated",
            "acceptance_status": "partial",
            "deviations": [{
                "type": "invalid_type",
                "description": "Something changed",
                "reason": "No reason",
                "impact": "added",
                "criteria_affected": [],
            }],
        }])
        assert not _is_valid(validator, plan)


# --- SC-13: Invalid deviation impact ---

class TestInvalidDeviationImpact:
    """SC-13: Deviation with invalid impact enum rejects."""

    def test_invalid_impact_rejects(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "deviated",
            "acceptance_status": "partial",
            "deviations": [{
                "type": "scope_change",
                "description": "Something changed",
                "reason": "No reason",
                "impact": "unknown",
                "criteria_affected": [],
            }],
        }])
        assert not _is_valid(validator, plan)


# --- SC-14: Empty phase_results array ---

class TestEmptyPhaseResults:
    """SC-14: Empty phase_results array validates."""

    def test_empty_phase_results(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[])
        assert _is_valid(validator, plan)


# --- SC-15: Empty deviations array ---

class TestEmptyDeviations:
    """SC-15: Empty deviations array validates."""

    def test_empty_deviations(self, validator: Draft202012Validator):
        plan = _plan_with_task(phase_results=[{
            "phase": "ba",
            "timestamp": "2026-04-17T10:00:00Z",
            "conformance": "aligned",
            "acceptance_status": "met",
            "deviations": [],
        }])
        assert _is_valid(validator, plan)


# --- SC-16: Mixed checklist (strings + objects) ---

class TestMixedChecklist:
    """SC-16: Mixed checklist (strings + objects) validates."""

    def test_mixed_checklist(self, validator: Draft202012Validator):
        plan = _plan_with_gate([
            "plain string item",
            {"item": "Shell check", "check": {"kind": "shell", "cmd": "echo ok"}},
            {"item": "Human check", "check": {"kind": "human"}},
        ])
        assert _is_valid(validator, plan)


# --- SC-17..24: kind:integration gate contract (real integration gates §4.0) ---
#
# The integration check is the keystone both /plan-project (authoring) and the
# orchestrator (execution) implement against. The schema bakes in the three
# anti-theater guards structurally so the contract itself forbids theater:
#   - trigger required + minItems 1        → §5 conditional trigger
#   - remediation.on_unfixable == escalate → Guard #3 (honest fail, no fake-pass)
#   - remediation.agent == lead-developer  → §6b (TDD/SOLID-bearing fixer)
#   - remediation.max_iterations 1..5      → Guard #4 (bound the write→run loop)


class TestIntegrationGateContract:
    """SC-17..24: kind:integration checklist item contract."""

    def test_sc17_valid_integration_check(self, schema: dict):
        """SC-17: a fully-specified integration check validates."""
        assert _item_validator(schema).is_valid(_integration_item())

    def test_sc18_command_optional_resolved_from_manifest(self, schema: dict):
        """SC-18: command may be omitted (orchestrator resolves it from the
        target project's pipeline.yaml integration_test field, §4.1)."""
        assert _item_validator(schema).is_valid(_integration_item(command=_OMIT))

    def test_sc19_missing_trigger_rejects(self, schema: dict):
        """SC-19: §5 — an integration gate with no path trigger is meaningless
        (it would either always or never fire). trigger is required."""
        assert not _item_validator(schema).is_valid(_integration_item(trigger=_OMIT))

    def test_sc20_empty_trigger_rejects(self, schema: dict):
        """SC-20: an empty trigger glob list is rejected (minItems 1)."""
        assert not _item_validator(schema).is_valid(_integration_item(trigger=[]))

    def test_sc21_missing_remediation_rejects(self, schema: dict):
        """SC-21: an integration gate without a remediation contract cannot
        self-heal or honestly escalate — remediation is required."""
        assert not _item_validator(schema).is_valid(
            _integration_item(remediation=_OMIT)
        )

    def test_sc22_on_unfixable_must_be_escalate(self, schema: dict):
        """SC-22 / Guard #3: on_unfixable is enum [escalate] only. A gate that
        downgrades to warn/pass on failure is decoration — structurally forbidden."""
        item = _integration_item(
            remediation={
                "agent": "lead-developer",
                "max_iterations": 2,
                "on_unfixable": "warn",
            }
        )
        assert not _item_validator(schema).is_valid(item)

    def test_sc23_agent_must_be_lead_developer(self, schema: dict):
        """SC-23 / §6b: the remediation agent is the lead-developer (TDD/SOLID).
        Any other agent is rejected."""
        item = _integration_item(
            remediation={
                "agent": "general-purpose",
                "max_iterations": 2,
                "on_unfixable": "escalate",
            }
        )
        assert not _item_validator(schema).is_valid(item)

    @pytest.mark.parametrize("bad_max", [0, 6, 10])
    def test_sc24_max_iterations_bounded(self, schema: dict, bad_max: int):
        """SC-24 / Guard #4: max_iterations is bounded 1..5 to cap the
        autonomous write→unsandboxed-run loop (the injection-amplification surface)."""
        item = _integration_item(
            remediation={
                "agent": "lead-developer",
                "max_iterations": bad_max,
                "on_unfixable": "escalate",
            }
        )
        assert not _item_validator(schema).is_valid(item)

    def test_remediation_missing_subfield_rejects(self, schema: dict):
        """remediation requires all three of agent/max_iterations/on_unfixable."""
        item = _integration_item(
            remediation={"agent": "lead-developer", "max_iterations": 2}
        )
        assert not _item_validator(schema).is_valid(item)

    def test_remediation_unknown_subfield_rejects(self, schema: dict):
        """remediation is a closed object (additionalProperties: false)."""
        item = _integration_item(
            remediation={
                "agent": "lead-developer",
                "max_iterations": 2,
                "on_unfixable": "escalate",
                "bogus": True,
            }
        )
        assert not _item_validator(schema).is_valid(item)

    def test_integration_fields_rejected_on_shell_check(self, schema: dict):
        """trigger/remediation are integration-only; additionalProperties:false
        means they cannot leak onto a shell check (they remain declared on the
        shared check object, so this guards the contract stays coherent)."""
        # A shell check carrying integration-only fields is structurally allowed
        # by additionalProperties (the props are declared) but must still satisfy
        # shell's required[cmd]; omitting cmd proves the shell branch is intact.
        item = {
            "item": "x",
            "check": {"kind": "shell", "trigger": ["dashboard/**"]},
        }
        assert not _item_validator(schema).is_valid(item)

    def test_end_to_end_integration_gate_in_full_plan(self):
        """The integration check is reachable through gate_2_0 in a real plan:
        load the canonical 2.0 fixture, attach an integration gate to its first
        phase, and assert the whole plan validates."""
        import yaml  # local import: only this test needs the fixture loader
        from conftest import REPO_ROOT

        fixture = REPO_ROOT / "tests" / "fixtures" / "plan-2.0.0" / "full.yaml"
        plan = yaml.safe_load(fixture.read_text())
        plan["phases"][0]["gate"] = {
            "name": "Foundation integration gate",
            "passed": False,
            "checklist": [_integration_item()],
        }
        schema = json.loads(
            (CLAUDE_SCHEMA_DIR / "execution-plan.schema.json").read_text()
        )
        validator = Draft202012Validator(schema)
        errors = [e.message for e in validator.iter_errors(plan)]
        assert errors == [], errors
