"""Tests for grinder-dashboard-api.schema.json (C5).

Validates the dashboard API response schema against valid and invalid
fixtures per TESTPLAN.md and acceptance scenarios AS1, AS2, EC1–EC3.
"""
from __future__ import annotations

import json

import jsonschema
import pytest

from conftest import SCHEMA_DIR


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def dashboard_schema() -> dict:
    """Load grinder-dashboard-api.schema.json with $ref resolution."""
    schema_path = SCHEMA_DIR / "grinder-dashboard-api.schema.json"
    schema = json.loads(schema_path.read_text())
    # Build a resolver so $ref to events.schema.json resolves locally
    registry = jsonschema.RefResolver(
        base_uri=schema_path.as_uri(),
        referrer=schema,
    )
    return schema, registry


def _valid_response() -> dict:
    """Minimal valid dashboard API response."""
    return {
        "passes": [{
            "id": "pass-1",
            "name": "mechanical",
            "status": "completed",
            "batches_total": 3,
            "batches_completed": 3,
        }],
        "current_batch": None,
        "recent_events": [{
            "ts": "2026-04-22T10:00:00Z",
            "batch": "batch-001",
            "event": "completed",
        }],
        "top_deferrals": [{
            "rule": "SC2086",
            "count": 5,
            "example_file": "tools/foo.sh",
        }],
    }


def _validate(fixture: dict, schema_and_resolver: tuple) -> None:
    """Validate fixture against dashboard schema with $ref resolution."""
    schema, resolver = schema_and_resolver
    jsonschema.validate(fixture, schema, resolver=resolver)


# ---------------------------------------------------------------------------
# TestDashboardSchemaValid
# ---------------------------------------------------------------------------

class TestDashboardSchemaValid:
    """Valid fixtures that the schema must accept."""

    def test_valid_fixture_accepted(self, dashboard_schema: tuple) -> None:
        """AS1, R1.7, R4.1: Full valid response accepted."""
        _validate(_valid_response(), dashboard_schema)

    def test_empty_passes_valid(self, dashboard_schema: tuple) -> None:
        """EC1: passes: [] accepted (grinder hasn't run yet)."""
        doc = _valid_response()
        doc["passes"] = []
        _validate(doc, dashboard_schema)

    def test_current_batch_null_valid(self, dashboard_schema: tuple) -> None:
        """EC2, R1.4: current_batch: null accepted."""
        doc = _valid_response()
        doc["current_batch"] = None
        _validate(doc, dashboard_schema)

    def test_empty_recent_events_valid(self, dashboard_schema: tuple) -> None:
        """EC3: recent_events: [] accepted."""
        doc = _valid_response()
        doc["recent_events"] = []
        _validate(doc, dashboard_schema)

    def test_empty_top_deferrals_valid(self, dashboard_schema: tuple) -> None:
        """top_deferrals: [] accepted (no deferrals)."""
        doc = _valid_response()
        doc["top_deferrals"] = []
        _validate(doc, dashboard_schema)


# ---------------------------------------------------------------------------
# TestDashboardSchemaInvalid
# ---------------------------------------------------------------------------

class TestDashboardSchemaInvalid:
    """Invalid fixtures that the schema must reject."""

    def test_missing_passes_rejected(self, dashboard_schema: tuple) -> None:
        """AS2, R1.8, R4.2: Omit passes field — rejected."""
        doc = _valid_response()
        del doc["passes"]
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)

    def test_missing_current_batch_rejected(self, dashboard_schema: tuple) -> None:
        """R1.2: Omit current_batch — rejected."""
        doc = _valid_response()
        del doc["current_batch"]
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)

    def test_missing_recent_events_rejected(self, dashboard_schema: tuple) -> None:
        """R1.2: Omit recent_events — rejected."""
        doc = _valid_response()
        del doc["recent_events"]
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)

    def test_missing_top_deferrals_rejected(self, dashboard_schema: tuple) -> None:
        """R1.2: Omit top_deferrals — rejected."""
        doc = _valid_response()
        del doc["top_deferrals"]
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)

    def test_invalid_pass_status_rejected(self, dashboard_schema: tuple) -> None:
        """R1.3: status: "unknown" in pass entry — rejected."""
        doc = _valid_response()
        doc["passes"][0]["status"] = "unknown"
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)

    def test_negative_batches_total_rejected(self, dashboard_schema: tuple) -> None:
        """R1.3: batches_total: -1 — rejected."""
        doc = _valid_response()
        doc["passes"][0]["batches_total"] = -1
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)

    def test_missing_pass_required_fields(self, dashboard_schema: tuple) -> None:
        """R1.3: Pass entry missing id — rejected."""
        doc = _valid_response()
        del doc["passes"][0]["id"]
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)

    def test_invalid_current_batch_missing_fields(self, dashboard_schema: tuple) -> None:
        """R1.4: Non-null current_batch missing started_at — rejected."""
        doc = _valid_response()
        doc["current_batch"] = {
            "id": "batch-001",
            "pass": "pass-1",
            "turns_elapsed": 5,
        }
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)

    def test_invalid_deferral_count_zero(self, dashboard_schema: tuple) -> None:
        """R1.6: count: 0 in top_deferrals — rejected (minimum 1)."""
        doc = _valid_response()
        doc["top_deferrals"][0]["count"] = 0
        with pytest.raises(jsonschema.ValidationError):
            _validate(doc, dashboard_schema)
