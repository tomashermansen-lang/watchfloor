"""Tests for baseline.schema.json and deferred-findings.schema.json.

Validates both schemas against all acceptance scenarios (AS-1 through AS-9)
and edge cases using jsonschema.Draft202012Validator.
"""
from __future__ import annotations

import json
from pathlib import Path

import jsonschema
import pytest

from conftest import REPO_ROOT, SCHEMA_DIR


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def baseline_schema() -> dict:
    """Load baseline.schema.json."""
    return json.loads((SCHEMA_DIR / "baseline.schema.json").read_text())


@pytest.fixture(scope="session")
def deferred_schema() -> dict:
    """Load deferred-findings.schema.json."""
    return json.loads((SCHEMA_DIR / "deferred-findings.schema.json").read_text())


def _valid_baseline() -> dict:
    """Minimal valid baseline.json document."""
    return {
        "created_at": "2026-04-17T12:00:00Z",
        "git_sha": "abc123def",
        "coverage": {"python": 0.85},
        "findings_count": {"ruff": 3, "shellcheck": 0},
        "tool_versions": {"ruff": "0.4.0", "shellcheck": "0.9.0"},
        "deferred_findings_ref": "docs/grinder/deferred-findings.json",
    }


def _valid_entry() -> dict:
    """Minimal valid deferred-findings entry."""
    return {
        "finding_id": "ruff:E501-server.py-a3f2c8d1",
        "rule": "python:E501",
        "file": "src/server.py",
        "line": 42,
        "state": "WontFix",
        "reason": "This line exceeds the limit but splitting would harm readability significantly",
        "owner": "tomashermansen",
        "reviewed_at": "2026-04-15",
    }


# ---------------------------------------------------------------------------
# TestBaselineSchema
# ---------------------------------------------------------------------------

class TestBaselineSchema:
    """Tests for schema/baseline.schema.json (C1)."""

    def test_valid_baseline(self, baseline_schema: dict) -> None:
        """AS-8: All required fields present with valid values → accepts."""
        jsonschema.validate(_valid_baseline(), baseline_schema)

    @pytest.mark.parametrize("field", [
        "created_at", "git_sha", "coverage", "findings_count",
        "tool_versions", "deferred_findings_ref",
    ])
    def test_missing_required_field(self, baseline_schema: dict, field: str) -> None:
        """AS-9: Each required field omitted → rejects."""
        doc = _valid_baseline()
        del doc[field]
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(doc, baseline_schema)

    def test_coverage_above_range(self, baseline_schema: dict) -> None:
        """AS-5: coverage value 1.5 → rejects."""
        doc = _valid_baseline()
        doc["coverage"] = {"python": 1.5}
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(doc, baseline_schema)

    def test_coverage_below_range(self, baseline_schema: dict) -> None:
        """AS-6: coverage value -0.1 → rejects."""
        doc = _valid_baseline()
        doc["coverage"] = {"python": -0.1}
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(doc, baseline_schema)

    def test_coverage_exactly_zero(self, baseline_schema: dict) -> None:
        """EC-1.2: coverage 0.0 → accepts."""
        doc = _valid_baseline()
        doc["coverage"] = {"python": 0.0}
        jsonschema.validate(doc, baseline_schema)

    def test_coverage_exactly_one(self, baseline_schema: dict) -> None:
        """EC-1.2: coverage 1.0 → accepts."""
        doc = _valid_baseline()
        doc["coverage"] = {"python": 1.0}
        jsonschema.validate(doc, baseline_schema)

    def test_coverage_integer_one(self, baseline_schema: dict) -> None:
        """EC-1.2: coverage integer 1 → accepts (JSON number includes integers)."""
        doc = _valid_baseline()
        doc["coverage"] = {"python": 1}
        jsonschema.validate(doc, baseline_schema)

    def test_empty_coverage(self, baseline_schema: dict) -> None:
        """EC-1.1: coverage {} → accepts."""
        doc = _valid_baseline()
        doc["coverage"] = {}
        jsonschema.validate(doc, baseline_schema)

    def test_findings_count_zero(self, baseline_schema: dict) -> None:
        """EC-1.3: findings_count value 0 → accepts."""
        doc = _valid_baseline()
        doc["findings_count"] = {"ruff": 0}
        jsonschema.validate(doc, baseline_schema)

    def test_findings_count_negative(self, baseline_schema: dict) -> None:
        """REQ-9: findings_count value -1 → rejects."""
        doc = _valid_baseline()
        doc["findings_count"] = {"ruff": -1}
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(doc, baseline_schema)

    def test_findings_count_float(self, baseline_schema: dict) -> None:
        """REQ-9: findings_count value 2.5 → rejects (must be integer)."""
        doc = _valid_baseline()
        doc["findings_count"] = {"ruff": 2.5}
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(doc, baseline_schema)

    def test_empty_tool_versions(self, baseline_schema: dict) -> None:
        """EC-1.4: tool_versions {} → accepts."""
        doc = _valid_baseline()
        doc["tool_versions"] = {}
        jsonschema.validate(doc, baseline_schema)

    def test_additional_properties_rejected(self, baseline_schema: dict) -> None:
        """REQ-1: Extra top-level field → rejects."""
        doc = _valid_baseline()
        doc["extra_field"] = "should fail"
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(doc, baseline_schema)


# ---------------------------------------------------------------------------
# TestDeferredFindingsSchema
# ---------------------------------------------------------------------------

class TestDeferredFindingsSchema:
    """Tests for schema/deferred-findings.schema.json (C2)."""

    def test_valid_entry(self, deferred_schema: dict) -> None:
        """AS-4: All required fields, valid finding_id with content-hash → accepts."""
        jsonschema.validate([_valid_entry()], deferred_schema)

    def test_reason_too_short(self, deferred_schema: dict) -> None:
        """AS-1: reason is 10 chars → rejects."""
        entry = _valid_entry()
        entry["reason"] = "too short!"
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    def test_reason_exactly_40_chars(self, deferred_schema: dict) -> None:
        """EC-3.1: reason exactly 40 chars → accepts."""
        entry = _valid_entry()
        entry["reason"] = "a" * 40
        jsonschema.validate([entry], deferred_schema)

    def test_reason_39_chars(self, deferred_schema: dict) -> None:
        """REQ-7: reason 39 chars → rejects (boundary)."""
        entry = _valid_entry()
        entry["reason"] = "a" * 39
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    def test_invalid_state_lowercase(self, deferred_schema: dict) -> None:
        """AS-2: state "wontfix" (lowercase) → rejects."""
        entry = _valid_entry()
        entry["state"] = "wontfix"
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    def test_invalid_state_unknown(self, deferred_schema: dict) -> None:
        """REQ-6: state "Suppressed" → rejects."""
        entry = _valid_entry()
        entry["state"] = "Suppressed"
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    @pytest.mark.parametrize("state", ["WontFix", "FalsePositive", "Deferred", "Accepted"])
    def test_valid_states(self, deferred_schema: dict, state: str) -> None:
        """REQ-6: Each valid state → accepts."""
        entry = _valid_entry()
        entry["state"] = state
        jsonschema.validate([entry], deferred_schema)

    def test_invalid_finding_id_line_number(self, deferred_schema: dict) -> None:
        """AS-3: finding_id with line number instead of content-hash → rejects."""
        entry = _valid_entry()
        entry["finding_id"] = "python:S3776-auth.py-42"
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    def test_invalid_finding_id_no_hash(self, deferred_schema: dict) -> None:
        """REQ-4: finding_id without hash suffix → rejects."""
        entry = _valid_entry()
        entry["finding_id"] = "ruff:E501-server.py"
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    def test_valid_finding_id_content_hash(self, deferred_schema: dict) -> None:
        """AS-4: finding_id "ruff:E501-server.py-a3f2c8d1" → accepts."""
        entry = _valid_entry()
        entry["finding_id"] = "ruff:E501-server.py-a3f2c8d1"
        jsonschema.validate([entry], deferred_schema)

    def test_hyphenated_tool_name(self, deferred_schema: dict) -> None:
        """EC-3.2: sonar-scanner in finding_id → accepts."""
        entry = _valid_entry()
        entry["finding_id"] = "sonar-scanner:S3776-auth.py-a3f2c8d1"
        jsonschema.validate([entry], deferred_schema)

    def test_dotted_file_basename(self, deferred_schema: dict) -> None:
        """EC-3.3: dotted basename in finding_id → accepts."""
        entry = _valid_entry()
        entry["finding_id"] = "ruff:E501-my.module.py-a3f2c8d1"
        jsonschema.validate([entry], deferred_schema)

    def test_empty_array(self, deferred_schema: dict) -> None:
        """EC-3.4, AS-7: empty array → accepts."""
        jsonschema.validate([], deferred_schema)

    @pytest.mark.parametrize("field", [
        "finding_id", "rule", "file", "line", "state", "reason", "owner", "reviewed_at",
    ])
    def test_missing_required_field(self, deferred_schema: dict, field: str) -> None:
        """REQ-3: Each required field omitted → rejects."""
        entry = _valid_entry()
        del entry[field]
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    def test_line_zero(self, deferred_schema: dict) -> None:
        """REQ-3: line 0 → rejects (minimum 1)."""
        entry = _valid_entry()
        entry["line"] = 0
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    def test_line_negative(self, deferred_schema: dict) -> None:
        """REQ-3: line -5 → rejects."""
        entry = _valid_entry()
        entry["line"] = -5
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)

    def test_optional_fields_absent(self, deferred_schema: dict) -> None:
        """REQ-3: review_trigger and ticket omitted → accepts."""
        entry = _valid_entry()
        assert "review_trigger" not in entry
        assert "ticket" not in entry
        jsonschema.validate([entry], deferred_schema)

    def test_optional_fields_present(self, deferred_schema: dict) -> None:
        """REQ-3: review_trigger and ticket present → accepts."""
        entry = _valid_entry()
        entry["review_trigger"] = "quarterly"
        entry["ticket"] = "PROJ-123"
        jsonschema.validate([entry], deferred_schema)

    def test_additional_properties_rejected(self, deferred_schema: dict) -> None:
        """REQ-3: Extra field on entry → rejects."""
        entry = _valid_entry()
        entry["extra"] = "should fail"
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate([entry], deferred_schema)


# ---------------------------------------------------------------------------
# TestBootstrapFile
# ---------------------------------------------------------------------------

class TestBootstrapFile:
    """Tests for docs/grinder/deferred-findings.json (C3)."""

    def test_bootstrap_exists(self) -> None:
        """REQ-8: File exists."""
        assert (REPO_ROOT / "docs" / "grinder" / "deferred-findings.json").exists()

    def test_bootstrap_content_is_empty_array(self) -> None:
        """REQ-8: File content parses to []."""
        content = json.loads(
            (REPO_ROOT / "docs" / "grinder" / "deferred-findings.json").read_text()
        )
        assert content == []

    def test_bootstrap_validates_against_schema(self, deferred_schema: dict) -> None:
        """REQ-8, AS-7: File validates against deferred-findings.schema.json."""
        content = json.loads(
            (REPO_ROOT / "docs" / "grinder" / "deferred-findings.json").read_text()
        )
        jsonschema.validate(content, deferred_schema)


# ---------------------------------------------------------------------------
# TestSchemaDocumentation
# ---------------------------------------------------------------------------

class TestSchemaDocumentation:
    """Tests for $comment documentation in both schemas (C4)."""

    def test_deferred_schema_has_comment(self, deferred_schema: dict) -> None:
        """REQ-10: Root $comment exists and is non-empty."""
        assert "$comment" in deferred_schema
        assert len(deferred_schema["$comment"]) > 0

    def test_deferred_comment_mentions_content_hash(self, deferred_schema: dict) -> None:
        """REQ-5, REQ-10: $comment references content-hash algorithm."""
        comment = deferred_schema["$comment"]
        assert "SHA-256" in comment or "sha-256" in comment or "sha256" in comment
        assert "5-line" in comment or "five-line" in comment or "5 line" in comment

    def test_baseline_schema_has_comment(self, baseline_schema: dict) -> None:
        """REQ-10: Root $comment exists and is non-empty."""
        assert "$comment" in baseline_schema
        assert len(baseline_schema["$comment"]) > 0

    def test_baseline_comment_mentions_deferred_ref(self, baseline_schema: dict) -> None:
        """REQ-10: $comment references deferred-findings relationship."""
        comment = baseline_schema["$comment"]
        assert "deferred" in comment.lower()
