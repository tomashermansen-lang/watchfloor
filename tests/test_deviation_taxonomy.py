"""Tests for the deviation taxonomy YAML and its validating JSON Schema.

Covers REQ-1..REQ-6 of docs/INPROGRESS_Feature_deviation-taxonomy/REQUIREMENTS.md.

The 11 functions below mirror TESTPLAN.md § Test Inventory T-01..T-11.
"""
from __future__ import annotations

import copy
import json
import re
from pathlib import Path

import pytest
import yaml
from jsonschema import validate
from jsonschema.exceptions import ValidationError

REPO_ROOT = Path(__file__).resolve().parents[1]
TAXONOMY_PATH = REPO_ROOT / "adapters/claude-code/claude/tools/lib/deviation-taxonomy.yaml"
SCHEMA_PATH = REPO_ROOT / "core/schema/deviation-taxonomy.schema.json"

TAXONOMY = yaml.safe_load(TAXONOMY_PATH.read_text())
SCHEMA = json.loads(SCHEMA_PATH.read_text())

# Derived from the schema's `required` list so adding a category to the
# schema cannot leave T-02 silently passing on a stale literal set.
EXPECTED_KEYS = set(SCHEMA["required"])

ANCHORED_PERMITTED_DEVIATIONS = {
    "integration_gap": {8, 10},
    "gate_logic_drift": {1, 2, 9},
    "error_reporting_tautology": {3, 4, 5, 11},
}

UNVERIFIED_CATEGORIES = (
    "factual_error",
    "test_tautology",
    "sycophancy",
    "acceptance_reinterpretation",
    "architectural_change_without_anchor",
)


def _validate_or_raise(taxonomy_dict: dict[str, object]) -> None:
    validate(taxonomy_dict, SCHEMA)


# T-01 — REQ-1, REQ-2, REQ-5 (Scenario 2)
def test_taxonomy_validates_against_schema() -> None:
    validate(TAXONOMY, SCHEMA)


# T-02 — REQ-1 (Scenario 1, top-level structure)
def test_taxonomy_has_all_eight_categories() -> None:
    assert set(TAXONOMY.keys()) == EXPECTED_KEYS


# T-03 — REQ-2 (Scenario 1, per-category structure)
def test_each_category_has_three_required_fields() -> None:
    for category, value in TAXONOMY.items():
        assert isinstance(value, dict), f"{category}: value is not a mapping"
        assert set(value.keys()) == {"description", "example", "typical_phase"}, (
            f"{category}: unexpected key set {set(value.keys())}"
        )
        for field in ("description", "example", "typical_phase"):
            v = value[field]
            assert isinstance(v, str), f"{category}.{field}: not a string ({type(v).__name__})"
            assert len(v) > 0, f"{category}.{field}: empty string"


# T-04 — REQ-3 (Scenario 3)
def test_anchored_categories_reference_retro_sections() -> None:
    for category, permitted in ANCHORED_PERMITTED_DEVIATIONS.items():
        example = TAXONOMY[category]["example"]
        match = re.search(r"RETRO\.md ### Deviation (\d+)", example)
        assert match is not None, (
            f"{category}.example does not contain "
            f"'RETRO.md ### Deviation N': {example!r}"
        )
        deviation_n = int(match.group(1))
        assert deviation_n in permitted, (
            f"{category}.example anchors Deviation {deviation_n}; "
            f"REQ-3 permits only {sorted(permitted)}"
        )


# T-05 — REQ-4 (Scenario 4). Per REQ-4 default for Open Question 1 (a),
# `factual_error` is grouped with the four forward-looking categories.
def test_unverified_categories_use_token_prefix() -> None:
    for category in UNVERIFIED_CATEGORIES:
        example = TAXONOMY[category]["example"]
        assert example.startswith("unverified-candidate"), (
            f"{category}.example must start with 'unverified-candidate' "
            f"per REQ-4; got {example!r}"
        )


# T-06 — REQ-5 (Scenario 5, EDGE-1)
def test_schema_rejects_missing_category() -> None:
    bad = {k: v for k, v in copy.deepcopy(TAXONOMY).items() if k != "integration_gap"}
    with pytest.raises(ValidationError) as exc_info:
        _validate_or_raise(bad)
    assert "integration_gap" in exc_info.value.message


# T-07 — REQ-5 (Scenario 5 variant)
def test_schema_rejects_missing_field() -> None:
    bad = copy.deepcopy(TAXONOMY)
    del bad["integration_gap"]["description"]
    with pytest.raises(ValidationError) as exc_info:
        _validate_or_raise(bad)
    path = [str(p) for p in exc_info.value.absolute_path]
    assert "integration_gap" in path or "description" in exc_info.value.message


# T-08 — REQ-5 (Scenario 6)
def test_schema_rejects_empty_field() -> None:
    bad = copy.deepcopy(TAXONOMY)
    bad["integration_gap"]["description"] = ""
    with pytest.raises(ValidationError) as exc_info:
        _validate_or_raise(bad)
    assert (
        "minLength" in exc_info.value.message
        or exc_info.value.validator == "minLength"
    )
    assert list(exc_info.value.absolute_path) == ["integration_gap", "description"]


# T-09 — REQ-5 (Scenario 7 variant: top-level), EDGE-2
def test_schema_rejects_unknown_top_level_key() -> None:
    bad = copy.deepcopy(TAXONOMY)
    bad["categories"] = {}
    with pytest.raises(ValidationError) as exc_info:
        _validate_or_raise(bad)
    assert (
        "additionalProperties" in exc_info.value.message
        or exc_info.value.validator == "additionalProperties"
    )


# T-10 — REQ-5 (Scenario 7)
def test_schema_rejects_unknown_per_category_key() -> None:
    bad = copy.deepcopy(TAXONOMY)
    bad["integration_gap"]["severity"] = "high"
    with pytest.raises(ValidationError) as exc_info:
        _validate_or_raise(bad)
    assert "severity" in exc_info.value.message
    assert (
        "additionalProperties" in exc_info.value.message
        or exc_info.value.validator == "additionalProperties"
    )


# T-11 — REQ-6 / plan constraint 1 / EDGE-4 / EDGE-10 (Scenario 9)
def test_yaml_safe_load_parses_without_anchors_or_merge_keys() -> None:
    source = TAXONOMY_PATH.read_text()
    assert re.search(r"^[^#]*&\w", source, re.MULTILINE) is None, (
        "YAML source contains an anchor declaration (&name) outside a comment"
    )
    assert re.search(r"^[^#]*\*\w", source, re.MULTILINE) is None, (
        "YAML source contains an alias reference (*name) outside a comment"
    )
    assert "<<:" not in source, "YAML source contains a merge key (<<:)"
    parsed = yaml.safe_load(source)
    assert isinstance(parsed, dict), (
        f"yaml.safe_load did not return a mapping (got {type(parsed).__name__})"
    )
