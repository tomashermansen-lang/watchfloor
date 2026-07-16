"""Tests for claude/tools/lib/filter-deferred.py — C6 test component."""
from __future__ import annotations

import json
from pathlib import Path

from conftest import run_tool

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "filter-deferred"


def _read_fixture(name: str) -> str:
    return (FIXTURES / name).read_text()


def _run(deferred_path: str, stdin: str) -> tuple[int, str, str]:
    """Run filter-deferred.py with --deferred and stdin, return (exit, stdout, stderr)."""
    result = run_tool("lib/filter-deferred.py", "--deferred", deferred_path, stdin=stdin)
    return result.exit_code, result.stdout, result.stderr


# ---------------------------------------------------------------------------
# TC-FD01: Normal filtering — deferred findings removed (AS-1, REQ-2)
# ---------------------------------------------------------------------------

def test_fd01_deferred_findings_filtered():
    stdin = _read_fixture("normalised-3-findings.json")
    deferred = str(FIXTURES / "deferred-2-matching.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    findings = json.loads(stdout)
    assert exit_code == 0
    assert len(findings) == 1
    assert findings[0]["id"] == "ruff:F401-foo.py-beef5678"


# ---------------------------------------------------------------------------
# TC-FD02: No deferred-findings file — unfiltered fallback (AS-2, REQ-3)
# ---------------------------------------------------------------------------

def test_fd02_no_deferred_file():
    stdin = _read_fixture("normalised-3-findings.json")

    exit_code, stdout, stderr = _run("/nonexistent/path/deferred.json", stdin)

    findings = json.loads(stdout)
    assert exit_code == 0
    assert len(findings) == 3
    assert "no deferred-findings.json" in stderr
    assert "running unfiltered" in stderr


# ---------------------------------------------------------------------------
# TC-FD03: Corrupt deferred file — truncated JSON (AS-3, REQ-4)
# ---------------------------------------------------------------------------

def test_fd03_corrupt_truncated():
    stdin = _read_fixture("normalised-3-findings.json")
    deferred = str(FIXTURES / "deferred-corrupt-truncated.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    assert exit_code == 1
    assert stdout.strip() == ""
    assert "deferred-findings.json corrupt (invalid JSON)" in stderr


# ---------------------------------------------------------------------------
# TC-FD04: Corrupt deferred file — wrong JSON type (EC-4.2)
# ---------------------------------------------------------------------------

def test_fd04_corrupt_object():
    stdin = _read_fixture("normalised-3-findings.json")
    deferred = str(FIXTURES / "deferred-corrupt-object.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    assert exit_code == 1
    assert stdout.strip() == ""
    assert "deferred-findings.json corrupt (not a JSON array)" in stderr


# ---------------------------------------------------------------------------
# TC-FD05: Corrupt deferred file — entry missing finding_id (EC-4.3)
# ---------------------------------------------------------------------------

def test_fd05_corrupt_missing_id():
    stdin = _read_fixture("normalised-3-findings.json")
    deferred = str(FIXTURES / "deferred-corrupt-missing-id.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    assert exit_code == 1
    assert stdout.strip() == ""
    assert "entry missing finding_id" in stderr


# ---------------------------------------------------------------------------
# TC-FD06: Corrupt deferred file — empty 0-byte file (EC-4.1)
# ---------------------------------------------------------------------------

def test_fd06_corrupt_empty_file(tmp_path):
    empty_file = tmp_path / "empty.json"
    empty_file.write_text("")
    stdin = _read_fixture("normalised-3-findings.json")

    exit_code, stdout, stderr = _run(str(empty_file), stdin)

    assert exit_code == 1
    assert stdout.strip() == ""
    assert "deferred-findings.json corrupt (empty file)" in stderr


# ---------------------------------------------------------------------------
# TC-FD07: Audit trail log format (AS-5, REQ-6)
# ---------------------------------------------------------------------------

def test_fd07_audit_trail_log():
    # Create stdin with 10 findings (replicate 3 findings + add 7 more unique ones)
    base = json.loads(_read_fixture("normalised-3-findings.json"))
    extra = []
    for i in range(7):
        f = {
            "id": f"ruff:W{i:03d}-extra.py-0000{i:04d}",
            "tool": "ruff",
            "rule": f"W{i:03d}",
            "file": "src/extra.py",
            "line": i + 1,
            "severity": "warning",
            "message": f"Extra finding {i}",
            "content_hash": f"0000{i:04d}",
        }
        extra.append(f)
    all_findings = base + extra
    stdin = json.dumps(all_findings)

    # deferred-2-matching matches 2 of the 3 base findings
    deferred = str(FIXTURES / "deferred-2-matching.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    assert exit_code == 0
    assert "filter-at-ingestion: 2 deferred suppressed, 8 active findings" in stderr


# ---------------------------------------------------------------------------
# TC-FD08: All findings deferred (EC-2.1)
# ---------------------------------------------------------------------------

def test_fd08_all_deferred():
    stdin = _read_fixture("normalised-3-findings.json")
    deferred = str(FIXTURES / "deferred-all-matching.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    findings = json.loads(stdout)
    assert exit_code == 0
    assert findings == []
    assert "3 deferred suppressed, 0 active findings" in stderr


# ---------------------------------------------------------------------------
# TC-FD09: No findings deferred (EC-2.2)
# ---------------------------------------------------------------------------

def test_fd09_none_deferred():
    stdin = _read_fixture("normalised-3-findings.json")
    deferred = str(FIXTURES / "deferred-none-matching.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    findings = json.loads(stdout)
    assert exit_code == 0
    assert len(findings) == 3
    assert "0 deferred suppressed, 3 active findings" in stderr


# ---------------------------------------------------------------------------
# TC-FD10: Empty deferred array (EC-2.3)
# ---------------------------------------------------------------------------

def test_fd10_empty_deferred():
    stdin = _read_fixture("normalised-3-findings.json")
    deferred = str(FIXTURES / "deferred-empty.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    findings = json.loads(stdout)
    assert exit_code == 0
    assert len(findings) == 3
    assert "0 deferred suppressed, 3 active findings" in stderr


# ---------------------------------------------------------------------------
# TC-FD11: Duplicate finding_ids in deferred file (EC-2.4)
# ---------------------------------------------------------------------------

def test_fd11_duplicate_ids():
    stdin = _read_fixture("normalised-3-findings.json")
    deferred = str(FIXTURES / "deferred-duplicate-ids.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    findings = json.loads(stdout)
    assert exit_code == 0
    # The duplicated ID matches one finding — should still be removed once
    assert len(findings) == 2
    ids = {f["id"] for f in findings}
    assert "ruff:E501-foo.py-abcd1234" not in ids


# ---------------------------------------------------------------------------
# TC-FD13: Corrupt stdin — invalid JSON (stdin parse failure)
# ---------------------------------------------------------------------------

def test_fd13_corrupt_stdin():
    deferred = str(FIXTURES / "deferred-2-matching.json")

    exit_code, stdout, stderr = _run(deferred, "not json")

    assert exit_code == 1
    assert stdout.strip() == ""
    assert "filter-deferred: stdin is not valid JSON" in stderr


# ---------------------------------------------------------------------------
# TC-FD14: Corrupt stdin with missing deferred file — invalid JSON on fallback
# ---------------------------------------------------------------------------

def test_fd14_corrupt_stdin_no_deferred():
    exit_code, stdout, stderr = _run("/nonexistent/path/deferred.json", "not json")

    assert exit_code == 1
    assert stdout.strip() == ""
    assert "filter-deferred: stdin is not valid JSON" in stderr


# ---------------------------------------------------------------------------
# TC-FD12: Empty scanner output — zero findings (EC-1.2)
# ---------------------------------------------------------------------------

def test_fd12_empty_scanner_output():
    stdin = _read_fixture("normalised-empty.json")
    deferred = str(FIXTURES / "deferred-2-matching.json")

    exit_code, stdout, stderr = _run(deferred, stdin)

    findings = json.loads(stdout)
    assert exit_code == 0
    assert findings == []
    assert "0 deferred suppressed, 0 active findings" in stderr
