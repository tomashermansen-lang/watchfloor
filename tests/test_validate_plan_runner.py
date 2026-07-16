"""Tests for the runner-overrides semantic validator (Component C).

Covers TESTPLAN.md rows AS8, AS9, AS13, T-C1..T-C5, T-R10-value-non-string,
T-R11, T-Q5 — the python-driven coverage of the
``compute_runner_override_findings`` pure function and its two dispatcher
shims in ``validate-plan.py`` (1.x) and ``plan_validators.py`` (2.0).
"""

from __future__ import annotations

import copy
import sys
from pathlib import Path
from typing import Any, cast

import pytest
from conftest import REPO_ROOT, TOOLS_DIR, import_tool, run_tool

# ---------------------------------------------------------------------------
# Helpers — import the modules under test once per session.
# ---------------------------------------------------------------------------

_LIB_DIR = TOOLS_DIR / "lib"
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))


@pytest.fixture(scope="session")
def plan_validators_module():
    import plan_validators

    return plan_validators


@pytest.fixture(scope="session")
def validate_plan_module():
    return import_tool("validate-plan.py")


FIXTURES = REPO_ROOT / "tests" / "fixtures"


def _load_yaml(path: Path) -> dict[Any, Any]:
    import yaml

    with open(path) as f:
        return cast(dict[Any, Any], yaml.safe_load(f))


# ---------------------------------------------------------------------------
# T-C1 — Validator returns empty list when no runner violations exist.
# ---------------------------------------------------------------------------


def test_C1_empty_list_for_clean_fixture(plan_validators_module) -> None:
    """Happy-path fixture has no malformed runner blocks → empty findings."""
    plan = _load_yaml(FIXTURES / "runner-overrides-fixture-plan.yaml")
    findings = plan_validators_module.compute_runner_override_findings(plan)
    assert findings == [], f"Expected no findings on a clean fixture, got: {findings}"


# ---------------------------------------------------------------------------
# T-C2 — Validator wires into the 1.x dispatcher entry-point.
# ---------------------------------------------------------------------------


def test_C2_wires_into_legacy_1x_dispatcher(validate_plan_module) -> None:
    """validate_runner_overrides_semantic exists and returns findings."""
    plan = _load_yaml(FIXTURES / "runner-overrides-invalid-env-key.yaml")
    assert hasattr(validate_plan_module, "validate_runner_overrides_semantic"), (
        "validate-plan.py must expose validate_runner_overrides_semantic for "
        "the 1.x dispatcher to call."
    )
    findings = validate_plan_module.validate_runner_overrides_semantic(plan)
    assert any("task-8" in line for line in findings), (
        f"Expected a finding naming task-8, got: {findings}"
    )


# ---------------------------------------------------------------------------
# T-C3 — Validator registered in VALIDATORS_2_0 (2.0 dispatcher).
# ---------------------------------------------------------------------------


def test_C3_registered_in_VALIDATORS_2_0(plan_validators_module) -> None:
    """validate_runner_overrides is appended to the 2.0 dispatcher list."""
    assert hasattr(plan_validators_module, "validate_runner_overrides"), (
        "plan_validators.py must expose validate_runner_overrides for the 2.0 dispatcher."
    )
    assert plan_validators_module.validate_runner_overrides in (
        plan_validators_module.VALIDATORS_2_0
    ), "validate_runner_overrides must be registered in VALIDATORS_2_0."


def test_C3_2_0_dispatcher_emits_diagnostic(plan_validators_module) -> None:
    """run_all on a 2.0 fixture with a bad runner key surfaces the finding."""
    plan = _load_yaml(FIXTURES / "runner-overrides-invalid-env-key.yaml")
    ctx = plan_validators_module.ValidationContext.build(plan, FIXTURES)
    findings = plan_validators_module.run_all(ctx)
    assert any("task-8" in line and "local_llm_routing" in line for line in findings), (
        f"Expected a finding naming task-8 + local_llm_routing, got: {findings}"
    )


# ---------------------------------------------------------------------------
# T-C4 — Validator does not mutate the plan dict.
# ---------------------------------------------------------------------------


def test_C4_does_not_mutate_plan(plan_validators_module) -> None:
    plan = _load_yaml(FIXTURES / "runner-overrides-fixture-plan.yaml")
    snapshot = copy.deepcopy(plan)
    plan_validators_module.compute_runner_override_findings(plan)
    assert plan == snapshot, "Validator must not mutate the input plan dict."


# ---------------------------------------------------------------------------
# T-C5 — Non-dict runner is skipped gracefully (no exception).
# ---------------------------------------------------------------------------


def test_C5_non_dict_runner_skipped(plan_validators_module) -> None:
    """Schema-structural validation catches non-dict runner; semantic must skip."""
    plan = {
        "phases": [
            {
                "tasks": [
                    {"id": "task-null", "runner": None},
                    {"id": "task-string", "runner": "bogus"},
                    {"id": "task-list", "runner": [1, 2]},
                ]
            }
        ]
    }
    findings = plan_validators_module.compute_runner_override_findings(plan)
    assert findings == [], f"Non-dict runner must not raise and must not emit, got: {findings}"


# ---------------------------------------------------------------------------
# T-R10-value-non-string — Diagnose non-string runner.env value (EC9).
# ---------------------------------------------------------------------------


def test_R10_value_non_string(plan_validators_module) -> None:
    plan = {
        "phases": [
            {
                "tasks": [
                    {
                        "id": "task-num-value",
                        "runner": {"env": {"NUM_VAR": 1}},
                    }
                ]
            }
        ]
    }
    findings = plan_validators_module.compute_runner_override_findings(plan)
    assert any(
        "task-num-value" in line and "NUM_VAR" in line and "int" in line for line in findings
    ), f"Expected diagnostic naming task-num-value + NUM_VAR + int, got: {findings}"


# ---------------------------------------------------------------------------
# AS8 — invalid env key: validate-plan.py exit non-zero with both errors.
# ---------------------------------------------------------------------------


def test_AS8_invalid_env_key_double_diagnostic() -> None:
    result = run_tool(
        "validate-plan.py",
        str(FIXTURES / "runner-overrides-invalid-env-key.yaml"),
    )
    assert result.exit_code != 0, (
        f"validate-plan.py must exit non-zero on bad env key; got "
        f"{result.exit_code}, stdout={result.stdout!r}, stderr={result.stderr!r}"
    )
    combined = result.stdout + result.stderr
    # Structural backstop — schema-driven message.
    assert "local_llm_routing" in combined and "regex" in combined.lower(), (
        f"Expected structural error mentioning local_llm_routing + regex; "
        f"combined output: {combined!r}"
    )
    # Semantic operator-facing diagnostic.
    assert "Task 'task-8'" in combined, (
        f"Expected operator-facing diagnostic naming task-8; got: {combined!r}"
    )
    assert "POSIX convention" in combined, f"Expected POSIX convention phrasing; got: {combined!r}"


# ---------------------------------------------------------------------------
# AS9 — non-string flags item: validate-plan.py exit non-zero with both errors.
# ---------------------------------------------------------------------------


def test_AS9_non_string_flags_item_double_diagnostic() -> None:
    result = run_tool(
        "validate-plan.py",
        str(FIXTURES / "runner-overrides-invalid-flags-item.yaml"),
    )
    assert result.exit_code != 0
    combined = result.stdout + result.stderr
    assert "42 is not of type 'string'" in combined or "is not of type" in combined, (
        f"Expected structural items-type error; got: {combined!r}"
    )
    assert "Task 'task-9'" in combined, (
        f"Expected operator-facing diagnostic naming task-9; got: {combined!r}"
    )
    assert "runner.flags entry at index 1" in combined, (
        f"Expected mention of index 1; got: {combined!r}"
    )


# ---------------------------------------------------------------------------
# AS13 — deterministic ordering across multiple violations.
# ---------------------------------------------------------------------------


def test_AS13_multi_violation_deterministic_ordering() -> None:
    result = run_tool(
        "validate-plan.py",
        str(FIXTURES / "runner-overrides-multi-violation.yaml"),
    )
    assert result.exit_code != 0
    combined = result.stdout + result.stderr
    lines = combined.splitlines()
    # Find the line numbers of each semantic diagnostic by task ID.
    pos_x = next((i for i, line in enumerate(lines) if "Task 'task-x'" in line), -1)
    pos_y = next((i for i, line in enumerate(lines) if "Task 'task-y'" in line), -1)
    pos_z = next((i for i, line in enumerate(lines) if "Task 'task-z'" in line), -1)
    assert pos_x >= 0 and pos_y >= 0 and pos_z >= 0, (
        f"Expected diagnostics for task-x, task-y, task-z; output: {combined!r}"
    )
    assert pos_x < pos_y < pos_z, (
        f"Expected ordering task-x < task-y < task-z; positions: x={pos_x}, y={pos_y}, z={pos_z}"
    )


# ---------------------------------------------------------------------------
# T-R11 — non-zero exit for every runner-shape violation fixture.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "fixture_name",
    [
        "runner-overrides-invalid-env-key.yaml",
        "runner-overrides-invalid-flags-item.yaml",
        "runner-overrides-multi-violation.yaml",
    ],
)
def test_R11_non_zero_exit_on_violation(fixture_name: str) -> None:
    result = run_tool("validate-plan.py", str(FIXTURES / fixture_name))
    assert result.exit_code != 0, (
        f"{fixture_name}: validate-plan.py must reject; stdout={result.stdout!r}"
    )


# ---------------------------------------------------------------------------
# T-Q5 — structural errors appear BEFORE semantic errors in combined output.
# ---------------------------------------------------------------------------


def test_Q5_structural_before_semantic_ordering() -> None:
    result = run_tool(
        "validate-plan.py",
        str(FIXTURES / "runner-overrides-invalid-env-key.yaml"),
    )
    assert result.exit_code != 0
    combined = result.stdout + result.stderr
    lines = combined.splitlines()
    structural_idx = next(
        (
            i
            for i, line in enumerate(lines)
            if "local_llm_routing" in line and "regex" in line.lower()
        ),
        -1,
    )
    semantic_idx = next((i for i, line in enumerate(lines) if "Task 'task-8'" in line), -1)
    assert structural_idx >= 0 and semantic_idx >= 0, (
        f"Expected both diagnostics in output: {combined!r}"
    )
    assert structural_idx < semantic_idx, (
        f"Structural error must precede semantic diagnostic; got "
        f"structural at line {structural_idx}, semantic at line {semantic_idx}"
    )
