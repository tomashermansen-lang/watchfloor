"""Tests for claude/tools/grinder-audit.py (C6).

Validates all audit script behavior per TESTPLAN.md: acceptance scenarios
AS3–AS9, edge cases EC4–EC10, and requirement R3.6.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import Any

from conftest import run_tool

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _valid_entry(**overrides: Any) -> dict:
    """Minimal valid deferred-findings entry."""
    base = {
        "finding_id": "shellcheck:SC2086-tools/foo.sh-abcd1234",
        "rule": "SC2086",
        "file": "tools/foo.sh",
        "line": 42,
        "state": "Deferred",
        "reason": "This finding is deferred because the variable is always set by the caller and quoting would break the glob",
        "owner": "tomas",
        "reviewed_at": "2026-04-01",
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# TestAuditErrorHandling
# ---------------------------------------------------------------------------


class TestAuditErrorHandling:
    """Error handling: missing file, corrupt JSON, empty array."""

    def test_missing_file(self) -> None:
        """R3.8, AS8: Non-existent path -> exit 1, stderr contains path."""
        result = run_tool("grinder-audit.py", "/nonexistent/path.json")
        assert result.exit_code == 1
        assert "/nonexistent/path.json not found" in result.stderr

    def test_corrupt_json(self, tmp_json_file) -> None:
        """R3.9, AS9: Corrupt JSON -> exit 1, stderr 'invalid JSON'."""
        # Write corrupt content directly (bypass JSON serialisation)
        path = tmp_json_file([])
        path.write_text("{broken")
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 1
        assert "invalid JSON" in result.stderr

    def test_empty_findings(self, tmp_json_file) -> None:
        """R3.7, AS7: [] -> exit 0, stdout 'No deferred findings'."""
        path = tmp_json_file([])
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "No deferred findings" in result.stdout


# ---------------------------------------------------------------------------
# TestAuditAllowlistPromotion
# ---------------------------------------------------------------------------


class TestAuditAllowlistPromotion:
    """R3.2: Rules appearing 5+ times flagged for allowlist promotion."""

    def test_allowlist_promotion_5plus(self, tmp_json_file) -> None:
        """AS3, R4.4: 6 entries with rule SC2086 -> flagged."""
        entries = [
            _valid_entry(
                finding_id=f"shellcheck:SC2086-tools/foo{i}.sh-abcd123{i}",
                file=f"tools/foo{i}.sh",
            )
            for i in range(6)
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Candidate for allowlist promotion" in result.stdout
        assert "rule SC2086 deferred 6 times" in result.stdout

    def test_below_threshold_not_flagged(self, tmp_json_file) -> None:
        """EC4: 4 entries with same rule -> NOT flagged."""
        entries = [
            _valid_entry(
                finding_id=f"shellcheck:SC2086-tools/foo{i}.sh-abcd123{i}",
                file=f"tools/foo{i}.sh",
            )
            for i in range(4)
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Candidate for allowlist promotion" not in result.stdout


# ---------------------------------------------------------------------------
# TestAuditStaleDeferrals
# ---------------------------------------------------------------------------


class TestAuditStaleDeferrals:
    """R3.3: Stale quarterly deferrals (>90 days)."""

    def test_stale_quarterly_deferral(self, tmp_json_file) -> None:
        """AS4, R4.5: reviewed_at 91+ days ago -> flagged."""
        stale_date = (date.today() - timedelta(days=91)).isoformat()
        entries = [
            _valid_entry(
                review_trigger="quarterly",
                reviewed_at=stale_date,
            )
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Stale deferrals requiring review" in result.stdout

    def test_exactly_90_days_not_stale(self, tmp_json_file) -> None:
        """EC5: reviewed_at exactly 90 days ago -> NOT flagged."""
        boundary_date = (date.today() - timedelta(days=90)).isoformat()
        entries = [
            _valid_entry(
                review_trigger="quarterly",
                reviewed_at=boundary_date,
            )
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Stale deferrals requiring review" not in result.stdout


# ---------------------------------------------------------------------------
# TestAuditMissingTickets
# ---------------------------------------------------------------------------


class TestAuditMissingTickets:
    """R3.4: Deferred entries without ticket reference."""

    def test_deferred_without_ticket(self, tmp_json_file) -> None:
        """AS5, R4.6: state=Deferred, no ticket -> flagged."""
        entries = [_valid_entry()]  # default: state=Deferred, no ticket
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Deferred without ticket reference" in result.stdout

    def test_deferred_with_ticket_not_flagged(self, tmp_json_file) -> None:
        """EC7: state=Deferred + ticket -> NOT flagged."""
        entries = [_valid_entry(ticket="JIRA-123")]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Deferred without ticket reference" not in result.stdout


# ---------------------------------------------------------------------------
# TestAuditTemplateReasons
# ---------------------------------------------------------------------------


class TestAuditTemplateReasons:
    """R3.5: Auto-generated/template reasons flagged."""

    def test_auto_generated_reason(self, tmp_json_file) -> None:
        """AS6, R4.7: reason starts with 'Pre-existing' -> flagged."""
        entries = [
            _valid_entry(
                reason="Pre-existing issue in legacy authentication module that predates the current review cycle",
            )
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Likely auto-generated reason" in result.stdout

    def test_reason_mid_string_not_flagged(self, tmp_json_file) -> None:
        """EC6: 'Pre-existing' in middle (not start) -> NOT flagged."""
        entries = [
            _valid_entry(
                reason="This is a Pre-existing issue that was found during the initial code review and documented properly",
            )
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Likely auto-generated reason" not in result.stdout

    def test_legacy_code_reason_flagged(self, tmp_json_file) -> None:
        """R3.5: reason starts with 'Legacy code' -> flagged."""
        entries = [
            _valid_entry(
                reason="Legacy code that was written before the current standards were established and needs review",
            )
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Likely auto-generated reason" in result.stdout

    def test_not_changed_reason_flagged(self, tmp_json_file) -> None:
        """R3.5: reason starts with 'Not changed in this PR' -> flagged."""
        entries = [
            _valid_entry(
                reason="Not changed in this PR — existing behavior from the original implementation of the module",
            )
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Likely auto-generated reason" in result.stdout


# ---------------------------------------------------------------------------
# TestAuditValidation
# ---------------------------------------------------------------------------


class TestAuditValidation:
    """R3.10: Invalid entries warned but still processed."""

    def test_invalid_entry_warned(self, tmp_json_file) -> None:
        """EC8: Invalid finding_id -> warning in output, still processed."""
        entries = [
            _valid_entry(finding_id="INVALID_FORMAT"),
            _valid_entry(
                finding_id="shellcheck:SC2086-tools/bar.sh-abcd1234",
                file="tools/bar.sh",
            ),
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "warning" in result.stdout.lower() or "Warning" in result.stdout


# ---------------------------------------------------------------------------
# TestAuditCombined
# ---------------------------------------------------------------------------


class TestAuditCombined:
    """Combined/integration scenarios."""

    def test_multiple_flags_same_entry(self, tmp_json_file) -> None:
        """EC9: Entry that is stale + no ticket + template reason -> all flagged."""
        stale_date = (date.today() - timedelta(days=91)).isoformat()
        entries = [
            _valid_entry(
                review_trigger="quarterly",
                reviewed_at=stale_date,
                reason="Pre-existing issue in legacy authentication module that predates the current review cycle",
            )
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0
        assert "Stale deferrals requiring review" in result.stdout
        assert "Deferred without ticket reference" in result.stdout
        assert "Likely auto-generated reason" in result.stdout

    def test_large_file_completes(self, tmp_json_file) -> None:
        """EC10: 1000+ entries -> exit 0, completes."""
        entries = [
            _valid_entry(
                finding_id=f"shellcheck:SC2086-tools/f{i}.sh-{i:08x}",
                file=f"tools/f{i}.sh",
            )
            for i in range(1001)
        ]
        path = tmp_json_file(entries)
        result = run_tool("grinder-audit.py", str(path))
        assert result.exit_code == 0

    def test_default_path_argument(self) -> None:
        """R3.6: No path argument -> uses default docs/grinder/deferred-findings.json."""
        result = run_tool("grinder-audit.py")
        # The default file exists and is [] -> should get "No deferred findings"
        assert result.exit_code == 0
        assert "No deferred findings" in result.stdout
