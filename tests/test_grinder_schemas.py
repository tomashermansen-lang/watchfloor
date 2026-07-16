"""Tests for grinder JSON schemas: plan, state, events.

Validates schema/grinder-plan.schema.json, schema/grinder-state.schema.json,
and schema/events.schema.json against valid and invalid fixtures using
jsonschema.validate().
"""

from __future__ import annotations

import json

import jsonschema
import pytest
from conftest import SCHEMA_DIR

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_schema(name: str) -> dict:
    path = SCHEMA_DIR / name
    return json.loads(path.read_text())


def _validate(instance: dict, schema: dict) -> None:
    jsonschema.validate(
        instance,
        schema,
        format_checker=jsonschema.FormatChecker(),
    )


def _assert_rejects(instance: dict, schema: dict) -> jsonschema.ValidationError:
    with pytest.raises(jsonschema.ValidationError) as exc_info:
        _validate(instance, schema)
    return exc_info.value


# ---------------------------------------------------------------------------
# Fixtures: minimal valid documents
# ---------------------------------------------------------------------------


def _minimal_batch(**overrides: object) -> dict:
    base = {
        "id": "batch-001",
        "files": ["src/foo.py"],
        "estimated_turns": 3,
        "status": "pending",
    }
    base.update(overrides)
    return base


def _minimal_pass(**overrides: object) -> dict:
    base = {
        "id": "pass-1",
        "kind": "mechanical",
        "batches": [_minimal_batch()],
    }
    base.update(overrides)
    return base


def _minimal_plan(**overrides: object) -> dict:
    base = {
        "created_at": "2026-04-17T10:00:00Z",
        "git_sha_at_start": "abc1234",
        "estimated_batches": 1,
        "estimated_hours": 0.5,
        "passes": [_minimal_pass()],
    }
    base.update(overrides)
    return base


def _minimal_state(**overrides: object) -> dict:
    base = {
        "current_pass": "pass-1",
        "started_at": "2026-04-17T10:00:00Z",
        "last_updated": "2026-04-17T10:05:00Z",
        "git_sha_at_start": "abc1234",
    }
    base.update(overrides)
    return base


def _minimal_event(event_type: str = "started", **overrides: object) -> dict:
    base = {
        "ts": "2026-04-17T10:00:00Z",
        "batch": "batch-001",
        "event": event_type,
    }
    base.update(overrides)
    return base


# ===========================================================================
# Component 1: Grinder Plan Schema
# ===========================================================================


class TestGrinderPlanSchema:
    @pytest.fixture(autouse=True)
    def _load(self) -> None:
        self.schema = _load_schema("grinder-plan.schema.json")

    # --- Accept cases ---

    def test_valid_plan_accepted(self) -> None:
        """P1 / AS-6: minimal valid plan with one pass, one batch."""
        _validate(_minimal_plan(), self.schema)

    def test_empty_batches_accepted(self) -> None:
        """P5 / EC-1.2: pass with batches: [] is valid (degenerate)."""
        plan = _minimal_plan(passes=[_minimal_pass(batches=[])])
        _validate(plan, self.schema)

    def test_depends_on_empty_accepted(self) -> None:
        """P6 / EC-1.3: depends_on: [] is valid (no dependencies)."""
        plan = _minimal_plan(passes=[_minimal_pass(batches=[_minimal_batch(depends_on=[])])])
        _validate(plan, self.schema)

    def test_files_all_sentinel_accepted(self) -> None:
        """P7 / EC-1.4: files: ["all"] is a valid sentinel."""
        plan = _minimal_plan(passes=[_minimal_pass(batches=[_minimal_batch(files=["all"])])])
        _validate(plan, self.schema)

    def test_estimated_batches_zero_accepted(self) -> None:
        """P8 / EC-1.6: estimated_batches: 0 is valid."""
        _validate(_minimal_plan(estimated_batches=0), self.schema)

    def test_optional_fields_accepted(self) -> None:
        """P11 / REQ-1: all optional fields present."""
        plan = _minimal_plan(
            staleness_commit_threshold=3,
            batch_size=10,
            project="my-project",
        )
        _validate(plan, self.schema)

    # --- Reject cases ---

    def test_empty_passes_rejected(self) -> None:
        """P2 / EC-1.1: passes: [] rejected (minItems: 1)."""
        _assert_rejects(_minimal_plan(passes=[]), self.schema)

    def test_invalid_status_rejected(self) -> None:
        """P3 / AS-3 / REQ-4: status: 'running' rejected."""
        plan = _minimal_plan(passes=[_minimal_pass(batches=[_minimal_batch(status="running")])])
        _assert_rejects(plan, self.schema)

    def test_unknown_kind_rejected(self) -> None:
        """P4 / EC-1.7: kind: 'custom' rejected."""
        plan = _minimal_plan(passes=[_minimal_pass(kind="custom")])
        _assert_rejects(plan, self.schema)

    def test_additional_properties_rejected(self) -> None:
        """P9 / REQ-11: unknown top-level field rejected."""
        plan = _minimal_plan(extra_field="bad")
        _assert_rejects(plan, self.schema)

    def test_missing_required_field_rejected(self) -> None:
        """P10 / REQ-1: omit created_at."""
        plan = _minimal_plan()
        del plan["created_at"]
        _assert_rejects(plan, self.schema)

    def test_batch_additional_properties_rejected(self) -> None:
        """P12 / REQ-11: unknown field on batch rejected."""
        plan = _minimal_plan(passes=[_minimal_pass(batches=[_minimal_batch(unknown="x")])])
        _assert_rejects(plan, self.schema)

    def test_pass_additional_properties_rejected(self) -> None:
        """P13 / REQ-11: unknown field on pass rejected."""
        bad_pass = _minimal_pass()
        bad_pass["unknown"] = "x"
        _assert_rejects(_minimal_plan(passes=[bad_pass]), self.schema)

    # --- needs_review (REQ-14 / SC-01..SC-04) ---

    def test_needs_review_true_accepted(self) -> None:
        """SC-01 / REQ-14: needs_review: true validates."""
        plan = _minimal_plan(passes=[_minimal_pass(batches=[_minimal_batch(needs_review=True)])])
        _validate(plan, self.schema)

    def test_needs_review_false_accepted(self) -> None:
        """SC-02 / REQ-14: needs_review: false validates."""
        plan = _minimal_plan(passes=[_minimal_pass(batches=[_minimal_batch(needs_review=False)])])
        _validate(plan, self.schema)

    def test_needs_review_omitted_accepted(self) -> None:
        """SC-03 / REQ-14: needs_review omitted validates (default)."""
        batch = _minimal_batch()
        assert "needs_review" not in batch
        plan = _minimal_plan(passes=[_minimal_pass(batches=[batch])])
        _validate(plan, self.schema)

    def test_needs_review_non_boolean_rejected(self) -> None:
        """SC-04 / REQ-14: needs_review: "yes" rejected."""
        plan = _minimal_plan(passes=[_minimal_pass(batches=[_minimal_batch(needs_review="yes")])])
        _assert_rejects(plan, self.schema)


# ===========================================================================
# Component 2: Grinder State Schema
# ===========================================================================


class TestGrinderStateSchema:
    @pytest.fixture(autouse=True)
    def _load(self) -> None:
        self.schema = _load_schema("grinder-state.schema.json")

    # --- Accept cases ---

    def test_valid_state_accepted(self) -> None:
        """S1 / AS-8: minimal valid state."""
        _validate(_minimal_state(), self.schema)

    def test_current_batch_null_accepted(self) -> None:
        """S3 / EC-5.1: current_batch: null is valid."""
        _validate(_minimal_state(current_batch=None), self.schema)

    def test_all_counters_zero_accepted(self) -> None:
        """S4 / EC-5.2: all counter fields at 0."""
        state = _minimal_state(
            batches_completed=0,
            batches_failed=0,
            batches_pending=0,
            batches_deferred=0,
        )
        _validate(state, self.schema)

    def test_paused_with_current_batch_accepted(self) -> None:
        """S5 / EC-5.3: paused: true with current_batch set."""
        state = _minimal_state(paused=True, current_batch="batch-001")
        _validate(state, self.schema)

    def test_all_optional_fields_accepted(self) -> None:
        """S7 / REQ-5: all optional fields present."""
        state = _minimal_state(
            current_batch="batch-001",
            batches_completed=5,
            batches_failed=1,
            batches_pending=3,
            batches_deferred=2,
            paused=False,
            staleness_commit_threshold=3,
        )
        _validate(state, self.schema)

    # --- Reject cases ---

    def test_missing_current_pass_rejected(self) -> None:
        """S2 / AS-5 / REQ-6: omit current_pass."""
        state = _minimal_state()
        del state["current_pass"]
        _assert_rejects(state, self.schema)

    def test_missing_started_at_rejected(self) -> None:
        """REQ-5: omit started_at."""
        state = _minimal_state()
        del state["started_at"]
        _assert_rejects(state, self.schema)

    def test_missing_last_updated_rejected(self) -> None:
        """REQ-5: omit last_updated."""
        state = _minimal_state()
        del state["last_updated"]
        _assert_rejects(state, self.schema)

    def test_missing_git_sha_at_start_rejected(self) -> None:
        """REQ-5: omit git_sha_at_start."""
        state = _minimal_state()
        del state["git_sha_at_start"]
        _assert_rejects(state, self.schema)

    def test_current_batch_empty_string_rejected(self) -> None:
        """current_batch: '' is semantically meaningless — rejected by minLength."""
        _assert_rejects(_minimal_state(current_batch=""), self.schema)

    def test_additional_properties_rejected(self) -> None:
        """S6 / REQ-11: unknown field rejected."""
        _assert_rejects(_minimal_state(unknown="x"), self.schema)


# ===========================================================================
# Component 3: Events Schema
# ===========================================================================


class TestEventsSchema:
    @pytest.fixture(autouse=True)
    def _load(self) -> None:
        self.schema = _load_schema("events.schema.json")

    # --- Accept cases ---

    def test_valid_started_event_accepted(self) -> None:
        """E1 / AS-7: started event with session_id."""
        _validate(_minimal_event("started", session_id="abc-123"), self.schema)

    def test_valid_completed_event_accepted(self) -> None:
        """E2 / AS-7: completed event with files_fixed, turns."""
        _validate(
            _minimal_event("completed", files_fixed=2, turns=5),
            self.schema,
        )

    def test_valid_failed_event_accepted(self) -> None:
        """E3 / AS-7: failed event with reason, reverted."""
        _validate(
            _minimal_event("failed", reason="test regression", reverted=True),
            self.schema,
        )

    def test_zero_files_fixed_accepted(self) -> None:
        """E8 / EC-7.2: files_fixed: 0 on completed event."""
        _validate(
            _minimal_event("completed", files_fixed=0, turns=1),
            self.schema,
        )

    def test_failed_without_reason_accepted(self) -> None:
        """E9 / EC-7.3: failed event, no reason (crash recovery)."""
        _validate(_minimal_event("failed"), self.schema)

    def test_valid_deferred_event_accepted(self) -> None:
        """E11 / REQ-7: deferred event with reason and cve."""
        _validate(
            _minimal_event("deferred", reason="not fixable", cve="CVE-2026-001"),
            self.schema,
        )

    def test_valid_paused_event_accepted(self) -> None:
        """E12 / REQ-7: paused event (required fields only)."""
        _validate(_minimal_event("paused"), self.schema)

    def test_valid_resumed_event_accepted(self) -> None:
        """E13 / REQ-7: resumed event (required fields only)."""
        _validate(_minimal_event("resumed"), self.schema)

    def test_valid_abandoned_event_accepted(self) -> None:
        """E14 / REQ-7: abandoned event with reason."""
        _validate(
            _minimal_event("abandoned", reason="stale plan"),
            self.schema,
        )

    # --- Reject cases ---

    def test_missing_batch_rejected(self) -> None:
        """E4 / AS-4 / REQ-8: omit batch."""
        event = _minimal_event("started")
        del event["batch"]
        _assert_rejects(event, self.schema)

    def test_missing_ts_rejected(self) -> None:
        """E5 / REQ-8: omit ts."""
        event = _minimal_event("started")
        del event["ts"]
        _assert_rejects(event, self.schema)

    def test_missing_event_rejected(self) -> None:
        """E6 / REQ-8: omit event."""
        event = _minimal_event("started")
        del event["event"]
        _assert_rejects(event, self.schema)

    def test_unknown_event_type_rejected(self) -> None:
        """E7 / EC-7.1 / REQ-9: event: 'cancelled' rejected."""
        _assert_rejects(_minimal_event("cancelled"), self.schema)

    def test_additional_properties_rejected(self) -> None:
        """E10 / EC-7.4: unknown field rejected."""
        _assert_rejects(_minimal_event("started", unknown="x"), self.schema)


# ===========================================================================
# Component 4: Schema Conventions
# ===========================================================================

SCHEMA_FILES = [
    "grinder-plan.schema.json",
    "grinder-state.schema.json",
    "events.schema.json",
]


class TestSchemaConventions:
    @pytest.fixture(autouse=True)
    def _load(self) -> None:
        self.schemas = {name: _load_schema(name) for name in SCHEMA_FILES}

    def test_all_schemas_have_draft_2020_12(self) -> None:
        """C1 / REQ-11: each schema declares draft 2020-12."""
        for name, schema in self.schemas.items():
            assert schema.get("$schema") == "https://json-schema.org/draft/2020-12/schema", name

    def test_all_schemas_have_id(self) -> None:
        """C2 / REQ-11: each schema has $id matching filename."""
        for name, schema in self.schemas.items():
            assert schema.get("$id") == name, name

    def test_all_schemas_have_comment(self) -> None:
        """C3 / REQ-11: each schema has $comment."""
        for name, schema in self.schemas.items():
            assert "$comment" in schema, f"{name} missing $comment"

    def test_all_schemas_have_additional_properties_false(self) -> None:
        """C4 / REQ-11: top-level additionalProperties: false."""
        for name, schema in self.schemas.items():
            assert schema.get("additionalProperties") is False, name


# ===========================================================================
# Component 5: Manifest Schema — never_auto_upgrade requires name
# ===========================================================================


class TestManifestNeverAutoUpgrade:
    @pytest.fixture(autouse=True)
    def _load(self) -> None:
        self.schema = _load_schema("manifest.schema.json")

    def test_sc01_never_auto_upgrade_requires_name(self) -> None:
        """SC-01 / C5b / REQ-6: never_auto_upgrade items must have 'name'."""
        valid = {
            "languages": ["python"],
            "dependencies": {
                "never_auto_upgrade": [{"name": "requests", "semver_range": ">=3.0.0"}]
            },
        }
        _validate(valid, self.schema)

        invalid = {
            "languages": ["python"],
            "dependencies": {"never_auto_upgrade": [{"semver_range": ">=3.0.0"}]},
        }
        _assert_rejects(invalid, self.schema)
