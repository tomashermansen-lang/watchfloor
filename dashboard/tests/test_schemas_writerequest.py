"""Unit tests for `dashboard.server.schemas.WriteRequest` (C2).

Fast-feedback Pydantic-only layer for the fastapi-origin-and-schemas
feature; HTTP-level remap is covered by `test-security.sh` Pydantic
section. Every scenario maps to TESTPLAN.md § C2.A / C2.B / C2.C.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import get_args

import pytest
from fastapi.testclient import TestClient
from pydantic import BaseModel, ValidationError

from dashboard.server.schemas import FeatureId, PhaseName, WriteRequest

_PHASE_VALUES: tuple[str, ...] = (
    "ba",
    "plan",
    "testplan",
    "review",
    "implement",
    "qa",
    "static-analysis",
    "commit",
)


# ── C2.A — happy paths ──────────────────────────────────────────────────


def test_c2_a_1_minimal_happy_path() -> None:
    req = WriteRequest(feature_id="abc", from_phase="plan")
    assert req.feature_id == "abc"
    assert req.from_phase == "plan"


def test_c2_a_2_charset_letters_digits_dashes_underscores() -> None:
    req = WriteRequest(feature_id="a-b_c-1_2", from_phase="ba")
    assert req.feature_id == "a-b_c-1_2"


def test_c2_a_3_max_length_64_inclusive() -> None:
    req = WriteRequest(feature_id="x" * 64, from_phase="commit")
    assert len(req.feature_id) == 64


# ── C2.A — feature_id rejection paths ───────────────────────────────────


def test_c2_a_4_feature_id_over_64_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="x" * 65, from_phase="plan")


def test_c2_a_5_feature_id_empty_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="", from_phase="plan")


def test_c2_a_6_feature_id_space_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="has space", from_phase="plan")


def test_c2_a_7_feature_id_slash_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="a/b", from_phase="plan")


def test_c2_a_8_feature_id_leading_whitespace_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id=" abc", from_phase="plan")


def test_c2_a_9_feature_id_trailing_whitespace_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc ", from_phase="plan")


# ── C2.A — from_phase happy + rejection paths ───────────────────────────


@pytest.mark.parametrize("phase", _PHASE_VALUES)
def test_c2_a_10_each_phase_value_accepted(phase: str) -> None:
    req = WriteRequest(feature_id="abc", from_phase=phase)
    assert req.from_phase == phase


def test_c2_a_11_phase_outside_enum_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase="deploy")


def test_c2_a_12_phase_underscore_typo_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase="static_analysis")


def test_c2_a_13_phase_uppercase_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase="BA")


def test_c2_a_14_phase_empty_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase="")


def test_c2_a_15_phase_none_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase=None)


def test_c2_a_16_extra_field_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase="plan", extra="evil")


def test_c2_a_17_missing_feature_id_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(from_phase="plan")


def test_c2_a_18_missing_from_phase_rejected() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc")


def test_c2_a_19_phase_int_not_coerced() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase=0)


def test_c2_a_20_phase_bool_not_coerced() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase=True)


def test_c2_a_21_phase_list_not_destructured() -> None:
    with pytest.raises(ValidationError):
        WriteRequest(feature_id="abc", from_phase=["plan"])


# ── C2.B — enum-membership regression guard ────────────────────────────


def test_c2_b_1_phase_literal_matches_phase_order() -> None:
    assert get_args(PhaseName) == _PHASE_VALUES


def test_c2_b_1b_phase_literal_matches_bash_phase_order() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    selector = repo_root / "adapters/claude-code/claude/tools/lib/phase-selector.sh"
    if not selector.exists():
        pytest.skip("phase-selector.sh not present at expected path")
    out = subprocess.check_output(
        [
            "bash",
            "-c",
            f"source {selector} && printf '%s\\n' \"${{PHASE_ORDER[@]}}\"",
        ],
        text=True,
    )
    bash_phases = tuple(line for line in out.strip().splitlines() if line)
    assert get_args(PhaseName) == bash_phases


# ── C2.C — subclass extension ───────────────────────────────────────────


class _MyRequest(WriteRequest):
    scope: str


def test_c2_c_1_subclass_inherits_validators_and_adds_field() -> None:
    req = _MyRequest(feature_id="abc", from_phase="plan", scope="x")
    assert req.scope == "x"
    with pytest.raises(ValidationError):
        _MyRequest(feature_id="abc", from_phase="plan")


def test_c2_c_2_subclass_inherits_extra_forbid() -> None:
    with pytest.raises(ValidationError):
        _MyRequest(feature_id="abc", from_phase="plan", scope="x", evil="z")


# ── FeatureId composition test (Phase 2 readiness, OCP wedge) ──────────


class _SingleField(BaseModel):
    fid: FeatureId


def test_feature_id_usable_standalone() -> None:
    obj = _SingleField(fid="abc-123")
    assert obj.fid == "abc-123"
    with pytest.raises(ValidationError):
        _SingleField(fid="a/b")


# ── Security: 400 response must not echo attacker-supplied input back ───


def test_400_response_does_not_echo_input_field() -> None:
    """Fix #9 / security: _validation_error_to_400 strips the 'input' key.

    POST /api/schema-test with an obviously-attacker-controlled feature_id
    value; assert the 400 response body JSON does NOT contain that string.
    """
    from dashboard.server.app import app  # noqa: PLC0415 — local import keeps test isolation

    # feature_id contains a slash — fails regex, produces a 400. The slash
    # ensures the value is invalid while remaining unambiguous in the response.
    attacker_value = "ATTACKER/SENTINEL/XYZZY"
    client = TestClient(app, raise_server_exceptions=False)
    # Provide a valid CSRF cookie+header so the request gets past CSRF.
    # Origin must be in the default allowlist.
    cookie = "A" * 43
    client.cookies.set("csrf_token", cookie)
    response = client.post(
        "/api/schema-test",
        json={"feature_id": attacker_value, "from_phase": "plan"},
        headers={
            "Origin": "http://127.0.0.1:8787",
            "X-CSRF-Token": cookie,
        },
    )
    assert response.status_code == 400
    body_text = response.text
    assert attacker_value not in body_text, (
        f"Attacker-supplied value leaked into 400 response body: {body_text!r}"
    )
