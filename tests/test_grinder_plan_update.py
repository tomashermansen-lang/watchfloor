"""C5: Unit tests for grinder-plan-update.py — YAML batch status updater."""
from __future__ import annotations

import os
import stat
from pathlib import Path

import pytest
import yaml

from conftest import REPO_ROOT, import_tool, run_tool

FIXTURES = REPO_ROOT / "tests" / "fixtures" / "grinder-orchestrator"

# Import the module for function-level tests
grinder_plan_update = import_tool("lib/grinder-plan-update.py")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_plan_file(tmp_path: Path, plan_data: dict | None = None) -> Path:
    """Create a temporary YAML plan file from fixture or custom data."""
    if plan_data is None:
        src = FIXTURES / "valid-plan.yaml"
        plan_data = yaml.safe_load(src.read_text())
    p = tmp_path / "grinder-plan.yaml"
    p.write_text(yaml.dump(plan_data, default_flow_style=False, sort_keys=False))
    return p


def _read_batch_status(plan_path: Path, batch_id: str) -> str:
    """Read a batch's status from a plan YAML file."""
    data = yaml.safe_load(plan_path.read_text())
    for p in data["passes"]:
        for b in p["batches"]:
            if b["id"] == batch_id:
                return b["status"]
    raise KeyError(f"batch {batch_id} not found")


# ---------------------------------------------------------------------------
# PU-1: Successful status update
# ---------------------------------------------------------------------------

def test_pu1_successful_update(tmp_path: Path) -> None:
    plan_file = _make_plan_file(tmp_path)
    assert _read_batch_status(plan_file, "batch-1") == "pending"

    exit_code = grinder_plan_update.update_batch_status(
        str(plan_file), "batch-1", "completed"
    )
    assert exit_code == 0
    assert _read_batch_status(plan_file, "batch-1") == "completed"


# ---------------------------------------------------------------------------
# PU-2: Batch not found
# ---------------------------------------------------------------------------

def test_pu2_batch_not_found(tmp_path: Path) -> None:
    plan_file = _make_plan_file(tmp_path)
    result = run_tool("lib/grinder-plan-update.py", str(plan_file), "nonexistent", "completed")
    assert result.exit_code == 1
    assert "batch not found" in result.stderr.lower()


# ---------------------------------------------------------------------------
# PU-3: File not writable
# ---------------------------------------------------------------------------

def test_pu3_file_not_writable(tmp_path: Path) -> None:
    # Put plan in a subdirectory so we can make the directory read-only
    sub = tmp_path / "readonly"
    sub.mkdir()
    plan_file = _make_plan_file(sub)
    sub.chmod(stat.S_IRUSR | stat.S_IXUSR)  # read+exec only — no writes
    try:
        result = run_tool("lib/grinder-plan-update.py", str(plan_file), "batch-1", "completed")
        assert result.exit_code == 1
        assert result.stderr.strip()  # some diagnostic on stderr
    finally:
        sub.chmod(stat.S_IRWXU)  # restore for cleanup


# ---------------------------------------------------------------------------
# PU-4: Atomic write (no partial) — original unchanged on error
# ---------------------------------------------------------------------------

def test_pu4_atomic_write_no_partial(tmp_path: Path) -> None:
    plan_file = _make_plan_file(tmp_path)
    original_content = plan_file.read_text()

    # Try updating a nonexistent batch — should fail, file unchanged
    exit_code = grinder_plan_update.update_batch_status(
        str(plan_file), "no-such-batch", "completed"
    )
    assert exit_code == 1
    assert plan_file.read_text() == original_content


# ---------------------------------------------------------------------------
# PU-5: YAML round-trip preserves structure
# ---------------------------------------------------------------------------

def test_pu5_roundtrip_preserves_structure(tmp_path: Path) -> None:
    plan_file = _make_plan_file(tmp_path)
    before = yaml.safe_load(plan_file.read_text())

    grinder_plan_update.update_batch_status(str(plan_file), "batch-1", "in_progress")

    after = yaml.safe_load(plan_file.read_text())

    # All fields except batch-1 status should be unchanged
    assert after["created_at"] == before["created_at"]
    assert after["git_sha_at_start"] == before["git_sha_at_start"]
    assert after["estimated_batches"] == before["estimated_batches"]
    assert len(after["passes"]) == len(before["passes"])

    # batch-2, batch-3, batch-4 unchanged
    for p_idx, p in enumerate(after["passes"]):
        for b_idx, b in enumerate(p["batches"]):
            if b["id"] != "batch-1":
                assert b == before["passes"][p_idx]["batches"][b_idx]


# ---------------------------------------------------------------------------
# PU-6: All valid status values accepted
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("status", ["pending", "in_progress", "completed", "failed", "deferred"])
def test_pu6_valid_status_values(tmp_path: Path, status: str) -> None:
    plan_file = _make_plan_file(tmp_path)
    exit_code = grinder_plan_update.update_batch_status(
        str(plan_file), "batch-1", status
    )
    assert exit_code == 0
    assert _read_batch_status(plan_file, "batch-1") == status


# ---------------------------------------------------------------------------
# PU-7: Invalid status value rejected
# ---------------------------------------------------------------------------

def test_pu7_invalid_status_value(tmp_path: Path) -> None:
    plan_file = _make_plan_file(tmp_path)
    result = run_tool("lib/grinder-plan-update.py", str(plan_file), "batch-1", "invalid")
    assert result.exit_code == 1
    assert "invalid" in result.stderr.lower() or "status" in result.stderr.lower()


# ---------------------------------------------------------------------------
# PU-8..PU-11: --set-flag support for needs_review
# ---------------------------------------------------------------------------


def _read_batch_flag(plan_path: Path, batch_id: str, flag: str) -> object:
    """Read a batch's flag from a plan YAML file."""
    data = yaml.safe_load(plan_path.read_text())
    for p in data["passes"]:
        for b in p["batches"]:
            if b["id"] == batch_id:
                return b.get(flag)
    raise KeyError(f"batch {batch_id} not found")


def test_pu8_set_flag_needs_review_true(tmp_path: Path) -> None:
    """--set-flag needs_review=true sets the flag."""
    plan_file = _make_plan_file(tmp_path)
    result = run_tool(
        "lib/grinder-plan-update.py",
        str(plan_file), "batch-1", "pending",
        "--set-flag", "needs_review=true",
    )
    assert result.exit_code == 0
    assert _read_batch_flag(plan_file, "batch-1", "needs_review") is True


def test_pu9_set_flag_needs_review_false(tmp_path: Path) -> None:
    """--set-flag needs_review=false clears the flag."""
    plan_file = _make_plan_file(tmp_path)
    # First set it to true
    grinder_plan_update.update_batch_status(
        str(plan_file), "batch-1", "pending", flags={"needs_review": True}
    )
    assert _read_batch_flag(plan_file, "batch-1", "needs_review") is True
    # Now set to false
    result = run_tool(
        "lib/grinder-plan-update.py",
        str(plan_file), "batch-1", "pending",
        "--set-flag", "needs_review=false",
    )
    assert result.exit_code == 0
    assert _read_batch_flag(plan_file, "batch-1", "needs_review") is False


def test_pu10_set_flag_batch_not_found(tmp_path: Path) -> None:
    """--set-flag on nonexistent batch exits 1."""
    plan_file = _make_plan_file(tmp_path)
    result = run_tool(
        "lib/grinder-plan-update.py",
        str(plan_file), "nonexistent", "pending",
        "--set-flag", "needs_review=true",
    )
    assert result.exit_code == 1


def test_pu11_set_flag_preserves_status(tmp_path: Path) -> None:
    """--set-flag changes flag without altering status."""
    plan_file = _make_plan_file(tmp_path)
    assert _read_batch_status(plan_file, "batch-1") == "pending"
    grinder_plan_update.update_batch_status(
        str(plan_file), "batch-1", "pending", flags={"needs_review": True}
    )
    assert _read_batch_status(plan_file, "batch-1") == "pending"
    assert _read_batch_flag(plan_file, "batch-1", "needs_review") is True


# ---------------------------------------------------------------------------
# PU-12: --set-flag rejects unknown flag keys
# ---------------------------------------------------------------------------

def test_pu12_set_flag_rejects_unknown_key(tmp_path: Path) -> None:
    """--set-flag with unknown key exits 1 (security: prevents arbitrary YAML injection)."""
    plan_file = _make_plan_file(tmp_path)
    result = run_tool(
        "lib/grinder-plan-update.py",
        str(plan_file), "batch-1", "pending",
        "--set-flag", "status=completed",
    )
    assert result.exit_code == 1
    assert "unknown flag" in result.stderr.lower()


def test_pu13_set_flag_rejects_arbitrary_key(tmp_path: Path) -> None:
    """--set-flag with arbitrary key exits 1."""
    plan_file = _make_plan_file(tmp_path)
    result = run_tool(
        "lib/grinder-plan-update.py",
        str(plan_file), "batch-1", "pending",
        "--set-flag", "__proto__=evil",
    )
    assert result.exit_code == 1
