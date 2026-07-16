"""Tests for claude/tools/lib/ratchet-autolog.py — C3 MAY-defer auto-logger."""

from __future__ import annotations

import json
import re
from unittest.mock import patch

from conftest import import_tool, run_tool

mod = import_tool("lib/ratchet-autolog.py")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_finding(
    finding_id: str, rule: str = "SC2086", file: str = "deploy.sh", line: int = 10
) -> dict:
    return {
        "id": finding_id,
        "tool": "shellcheck",
        "rule": rule,
        "file": file,
        "line": line,
        "severity": "warning",
        "message": "test finding",
        "content_hash": "aabb1122",
        "tier": "may_defer",
    }


# ---------------------------------------------------------------------------
# TC-RA01: New finding appended with correct fields
# ---------------------------------------------------------------------------


def test_ra01_new_finding_appended(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    deferred_path.write_text("[]")

    finding = _make_finding("shellcheck:SC2086-deploy.sh-aabb1122")

    with patch.object(mod, "_get_git_user_name", return_value="tomas"):
        result = mod.autolog([finding], str(deferred_path))

    assert len(result) == 1
    assert result[0]["auto_logged"] is True

    entries = json.loads(deferred_path.read_text())
    assert len(entries) == 1
    entry = entries[0]
    assert entry["finding_id"] == "shellcheck:SC2086-deploy.sh-aabb1122"
    assert entry["rule"] == "SC2086"
    assert entry["file"] == "deploy.sh"
    assert entry["line"] == 10
    assert entry["state"] == "Accepted"
    assert entry["reason"].startswith("auto-logged by commit-preflight at")
    assert entry["owner"] == "tomas"
    assert re.match(r"\d{4}-\d{2}-\d{2}", entry["reviewed_at"])


# ---------------------------------------------------------------------------
# TC-RA02: Duplicate finding_id skipped
# ---------------------------------------------------------------------------


def test_ra02_duplicate_skipped(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    existing = [
        {
            "finding_id": "shellcheck:SC2086-deploy.sh-aabb1122",
            "rule": "SC2086",
            "file": "deploy.sh",
            "line": 10,
            "state": "Accepted",
            "reason": "auto-logged by commit-preflight at 2026-04-20T00:00:00Z",
            "owner": "tomas",
            "reviewed_at": "2026-04-20",
        }
    ]
    deferred_path.write_text(json.dumps(existing))

    finding = _make_finding("shellcheck:SC2086-deploy.sh-aabb1122")
    result = mod.autolog([finding], str(deferred_path))

    assert len(result) == 1
    assert result[0]["auto_logged"] is False

    entries = json.loads(deferred_path.read_text())
    assert len(entries) == 1  # No duplicate


# ---------------------------------------------------------------------------
# TC-RA03: Missing deferred file → created
# ---------------------------------------------------------------------------


def test_ra03_missing_file_created(tmp_path):
    deferred_path = tmp_path / "new_deferred.json"

    finding = _make_finding("shellcheck:SC2086-deploy.sh-aabb1122")
    with patch.object(mod, "_get_git_user_name", return_value="tomas"):
        result = mod.autolog([finding], str(deferred_path))

    assert deferred_path.exists()
    entries = json.loads(deferred_path.read_text())
    assert len(entries) == 1
    assert result[0]["auto_logged"] is True


# ---------------------------------------------------------------------------
# TC-RA04: Corrupt JSON → exit 1
# ---------------------------------------------------------------------------


def test_ra04_corrupt_json_exits_1(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    deferred_path.write_text("{bad json")

    finding = _make_finding("shellcheck:SC2086-deploy.sh-aabb1122")

    result = run_tool(
        "lib/ratchet-autolog.py",
        "--deferred",
        str(deferred_path),
        stdin=json.dumps([finding]),
    )
    assert result.exit_code == 1
    assert "corrupt" in result.stderr.lower() or "invalid" in result.stderr.lower()


# ---------------------------------------------------------------------------
# TC-RA05: No git user.name → owner "unknown"
# ---------------------------------------------------------------------------


def test_ra05_no_git_user_owner_unknown(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    deferred_path.write_text("[]")

    finding = _make_finding("shellcheck:SC2086-deploy.sh-aabb1122")
    with patch.object(mod, "_get_git_user_name", return_value="unknown"):
        mod.autolog([finding], str(deferred_path))

    entries = json.loads(deferred_path.read_text())
    assert entries[0]["owner"] == "unknown"


# ---------------------------------------------------------------------------
# TC-RA06: Reason string >= 40 chars
# ---------------------------------------------------------------------------


def test_ra06_reason_length(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    deferred_path.write_text("[]")

    finding = _make_finding("shellcheck:SC2086-deploy.sh-aabb1122")
    with patch.object(mod, "_get_git_user_name", return_value="tomas"):
        mod.autolog([finding], str(deferred_path))

    entries = json.loads(deferred_path.read_text())
    assert len(entries[0]["reason"]) >= 40


# ---------------------------------------------------------------------------
# TC-RA07: Atomic write — valid JSON after write
# ---------------------------------------------------------------------------


def test_ra07_atomic_write(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    deferred_path.write_text("[]")

    finding = _make_finding("shellcheck:SC2086-deploy.sh-aabb1122")
    with patch.object(mod, "_get_git_user_name", return_value="tomas"):
        mod.autolog([finding], str(deferred_path))

    # Verify valid JSON — json.loads would raise if partial write
    entries = json.loads(deferred_path.read_text())
    assert isinstance(entries, list)


# ---------------------------------------------------------------------------
# TC-RA08: Multiple findings: mix of new and duplicate
# ---------------------------------------------------------------------------


def test_ra08_mix_new_and_duplicate(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    existing = [
        {
            "finding_id": "shellcheck:SC2086-deploy.sh-aabb1122",
            "rule": "SC2086",
            "file": "deploy.sh",
            "line": 10,
            "state": "Accepted",
            "reason": "auto-logged by commit-preflight at 2026-04-20T00:00:00Z",
            "owner": "tomas",
            "reviewed_at": "2026-04-20",
        }
    ]
    deferred_path.write_text(json.dumps(existing))

    findings = [
        _make_finding("shellcheck:SC2086-deploy.sh-aabb1122"),  # existing
        _make_finding("shellcheck:SC2034-deploy.sh-ccdd3344", rule="SC2034"),  # new
        _make_finding("ruff:E501-utils.py-11223344", rule="E501", file="utils.py"),  # new
    ]
    with patch.object(mod, "_get_git_user_name", return_value="tomas"):
        result = mod.autolog(findings, str(deferred_path))

    assert sum(1 for r in result if r["auto_logged"]) == 2
    assert sum(1 for r in result if not r["auto_logged"]) == 1

    entries = json.loads(deferred_path.read_text())
    assert len(entries) == 3  # 1 existing + 2 new


# ---------------------------------------------------------------------------
# TC-RA09: Schema conformance of generated entries
# ---------------------------------------------------------------------------


def test_ra09_schema_conformance(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    deferred_path.write_text("[]")

    finding = _make_finding("shellcheck:SC2086-deploy.sh-aabb1122")
    with patch.object(mod, "_get_git_user_name", return_value="tomas"):
        mod.autolog([finding], str(deferred_path))

    entries = json.loads(deferred_path.read_text())
    entry = entries[0]

    # finding_id regex from schema
    assert re.match(r"^[a-z0-9-]+:[A-Z0-9]+-[^-]+-[a-f0-9]{8}$", entry["finding_id"])
    # state enum
    assert entry["state"] in ("WontFix", "FalsePositive", "Deferred", "Accepted")
    # reason minLength
    assert len(entry["reason"]) >= 40
    # owner minLength
    assert len(entry["owner"]) >= 1
    # reviewed_at date format
    assert re.match(r"\d{4}-\d{2}-\d{2}$", entry["reviewed_at"])


# ---------------------------------------------------------------------------
# TC-RA10: Empty stdin (zero findings) → no changes
# ---------------------------------------------------------------------------


def test_ra10_empty_findings_no_changes(tmp_path):
    deferred_path = tmp_path / "deferred.json"
    deferred_path.write_text("[]")

    result = mod.autolog([], str(deferred_path))

    assert result == []
    entries = json.loads(deferred_path.read_text())
    assert entries == []
