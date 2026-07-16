"""Tests for claude/tools/normalise-findings.py — per-tool scanner normaliser.

Covers TC1–TC17 from TESTPLAN.md. Unit tests import functions directly via
import_tool(); CLI integration tests use run_tool() with stdin piping.
"""
from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path

import pytest

from conftest import REPO_ROOT, import_tool, run_tool

FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "scanner-normaliser"
SOURCE_DIR = FIXTURE_DIR / "source-files"

# ---------------------------------------------------------------------------
# Module import
# ---------------------------------------------------------------------------

mod = import_tool("normalise-findings.py")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_fixture(name: str) -> str:
    return (FIXTURE_DIR / name).read_text()


def _expected_hash(text: str) -> str:
    """Compute expected 8-char hex SHA-256 of text."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:8]


# ===========================================================================
# TC1: Ruff Adapter (parse_ruff)
# ===========================================================================


class TestParseRuff:
    def test_1_1_three_violations(self):
        raw = _load_fixture("fixture-ruff.json")
        findings = mod.parse_ruff(raw)
        assert len(findings) == 3

    def test_1_2_all_severity_error(self):
        raw = _load_fixture("fixture-ruff.json")
        findings = mod.parse_ruff(raw)
        assert all(f["severity"] == "error" for f in findings)

    def test_1_3_field_mapping(self):
        raw = _load_fixture("fixture-ruff.json")
        findings = mod.parse_ruff(raw)
        f = findings[0]
        assert f["file"] == "src/foo.py"
        assert f["line"] == 10
        assert f["rule"] == "E501"
        assert f["message"] == "Line too long (120 > 88)"

    def test_1_4_extra_fields_ignored(self):
        """Extra fields (fix, noqa_row, cell) silently ignored."""
        raw = _load_fixture("fixture-ruff.json")
        findings = mod.parse_ruff(raw)
        for f in findings:
            assert set(f.keys()) == {"file", "line", "rule", "message", "severity"}

    def test_1_5_empty_array(self):
        findings = mod.parse_ruff("[]")
        assert findings == []

    def test_1_6_non_array_raises(self):
        with pytest.raises(mod.ParseError):
            mod.parse_ruff('{"not": "array"}')


# ===========================================================================
# TC2: Shellcheck Adapter (parse_shellcheck)
# ===========================================================================


class TestParseShellcheck:
    def test_2_1_sc_prefix(self):
        raw = _load_fixture("fixture-shellcheck.json")
        findings = mod.parse_shellcheck(raw)
        assert findings[0]["rule"] == "SC2086"

    def test_2_2_level_error(self):
        raw = _load_fixture("fixture-shellcheck.json")
        findings = mod.parse_shellcheck(raw)
        assert findings[0]["severity"] == "error"

    def test_2_3_level_warning(self):
        raw = _load_fixture("fixture-shellcheck.json")
        findings = mod.parse_shellcheck(raw)
        assert findings[1]["severity"] == "warning"

    def test_2_4_level_info(self):
        raw = _load_fixture("fixture-shellcheck.json")
        findings = mod.parse_shellcheck(raw)
        assert findings[2]["severity"] == "info"

    def test_2_5_level_style(self):
        raw = _load_fixture("fixture-shellcheck.json")
        findings = mod.parse_shellcheck(raw)
        assert findings[3]["severity"] == "info"

    def test_2_6_fix_field_ignored(self):
        raw = _load_fixture("fixture-shellcheck.json")
        findings = mod.parse_shellcheck(raw)
        for f in findings:
            assert set(f.keys()) == {"file", "line", "rule", "message", "severity"}

    def test_2_7_uses_start_line(self):
        raw = _load_fixture("fixture-shellcheck.json")
        findings = mod.parse_shellcheck(raw)
        assert findings[0]["line"] == 15


# ===========================================================================
# TC3: ESLint Adapter (parse_eslint)
# ===========================================================================


class TestParseEslint:
    def test_3_1_flattened_count(self):
        raw = _load_fixture("fixture-eslint.json")
        findings = mod.parse_eslint(raw)
        assert len(findings) == 4  # 2 files × 2 messages (empty file skipped)

    def test_3_2_file_matches_parent(self):
        raw = _load_fixture("fixture-eslint.json")
        findings = mod.parse_eslint(raw)
        for f in findings[:2]:
            assert f["file"] == "/home/user/project/src/app.ts"
        for f in findings[2:]:
            assert f["file"] == "/home/user/project/src/utils.ts"

    def test_3_3_severity_mapping(self):
        raw = _load_fixture("fixture-eslint.json")
        findings = mod.parse_eslint(raw)
        assert findings[0]["severity"] == "error"  # severity 2
        assert findings[2]["severity"] == "warning"  # severity 1

    def test_3_4_null_rule_id(self):
        raw = _load_fixture("fixture-eslint.json")
        findings = mod.parse_eslint(raw)
        assert findings[1]["rule"] == "PARSE-ERROR"

    def test_3_5_file_with_zero_messages(self):
        raw = _load_fixture("fixture-eslint.json")
        findings = mod.parse_eslint(raw)
        files = [f["file"] for f in findings]
        assert "/home/user/project/src/empty.ts" not in files

    def test_3_6_line_zero_becomes_one(self):
        raw = _load_fixture("fixture-eslint.json")
        findings = mod.parse_eslint(raw)
        # Second finding in first file has line: 0
        assert findings[1]["line"] == 1


# ===========================================================================
# TC4: Mypy Adapter (parse_mypy)
# ===========================================================================


class TestParseMypy:
    def test_4_1_error_with_bracket(self):
        raw = _load_fixture("fixture-mypy.txt")
        findings = mod.parse_mypy(raw)
        f = findings[0]
        assert f["severity"] == "error"
        assert f["rule"] == "return-value"
        assert f["file"] == "src/foo.py"
        assert f["line"] == 10

    def test_4_2_note_level(self):
        raw = _load_fixture("fixture-mypy.txt")
        findings = mod.parse_mypy(raw)
        note_findings = [f for f in findings if f["severity"] == "info"]
        assert len(note_findings) == 1
        assert note_findings[0]["rule"] == "note-ref"

    def test_4_3_warning_level(self):
        raw = _load_fixture("fixture-mypy.txt")
        findings = mod.parse_mypy(raw)
        warn_findings = [f for f in findings if f["severity"] == "warning"]
        assert len(warn_findings) == 1

    def test_4_4_no_bracket(self):
        raw = _load_fixture("fixture-mypy.txt")
        findings = mod.parse_mypy(raw)
        no_bracket = [f for f in findings if f["rule"] == "UNKNOWN"]
        assert len(no_bracket) == 1
        assert no_bracket[0]["message"] == "Some error message"

    def test_4_5_summary_lines_skipped(self):
        raw = _load_fixture("fixture-mypy.txt")
        findings = mod.parse_mypy(raw)
        assert len(findings) == 4  # 4 matching lines, 1 summary skipped

    def test_4_6_empty_input(self):
        findings = mod.parse_mypy("")
        assert findings == []

    def test_4_7_column_info_ignored(self):
        """Newer mypy: src/foo.py:10:5: error: msg [rule] — column ignored."""
        raw = "src/foo.py:10: error: Incompatible type  [type-error]\n"
        findings = mod.parse_mypy(raw)
        assert len(findings) == 1
        assert findings[0]["line"] == 10


# ===========================================================================
# TC5: TSC Adapter (parse_tsc)
# ===========================================================================


class TestParseTsc:
    def test_5_1_error_line(self):
        raw = _load_fixture("fixture-tsc.txt")
        findings = mod.parse_tsc(raw)
        f = findings[0]
        assert f["rule"] == "TS2304"
        assert f["severity"] == "error"
        assert f["file"] == "src/app.ts"
        assert f["line"] == 10

    def test_5_2_warning_line(self):
        raw = _load_fixture("fixture-tsc.txt")
        findings = mod.parse_tsc(raw)
        assert findings[1]["severity"] == "warning"

    def test_5_3_non_matching_skipped(self):
        raw = _load_fixture("fixture-tsc.txt")
        findings = mod.parse_tsc(raw)
        assert len(findings) == 2

    def test_5_4_empty_input(self):
        findings = mod.parse_tsc("")
        assert findings == []


# ===========================================================================
# TC6: Bandit Adapter (parse_bandit)
# ===========================================================================


class TestParseBandit:
    def test_6_1_results_extraction(self):
        raw = _load_fixture("fixture-bandit.json")
        findings = mod.parse_bandit(raw)
        assert len(findings) == 3
        assert findings[0]["file"] == "src/app.py"
        assert findings[0]["line"] == 10
        assert findings[0]["rule"] == "B101"

    def test_6_2_severity_mapping(self):
        raw = _load_fixture("fixture-bandit.json")
        findings = mod.parse_bandit(raw)
        assert findings[0]["severity"] == "error"    # HIGH
        assert findings[1]["severity"] == "warning"  # MEDIUM
        assert findings[2]["severity"] == "info"     # LOW

    def test_6_3_test_id_as_rule(self):
        raw = _load_fixture("fixture-bandit.json")
        findings = mod.parse_bandit(raw)
        assert findings[0]["rule"] == "B101"

    def test_6_4_empty_results(self):
        findings = mod.parse_bandit('{"results": []}')
        assert findings == []


# ===========================================================================
# TC7: Semgrep Adapter (parse_semgrep)
# ===========================================================================


class TestParseSemgrep:
    def test_7_1_results_extraction(self):
        raw = _load_fixture("fixture-semgrep.json")
        findings = mod.parse_semgrep(raw)
        assert len(findings) == 3
        f = findings[0]
        assert f["file"] == "src/app.py"
        assert f["line"] == 15
        assert f["rule"] == "python.lang.security.audit.exec-detected"
        assert f["message"] == "Detected use of exec()."

    def test_7_2_severity_mapping(self):
        raw = _load_fixture("fixture-semgrep.json")
        findings = mod.parse_semgrep(raw)
        assert findings[0]["severity"] == "error"    # ERROR
        assert findings[1]["severity"] == "warning"  # WARNING
        assert findings[2]["severity"] == "info"     # INFO

    def test_7_3_empty_results(self):
        findings = mod.parse_semgrep('{"results": []}')
        assert findings == []


# ===========================================================================
# TC8: pip-audit Adapter (parse_pip_audit)
# ===========================================================================


class TestParsePipAudit:
    def test_8_1_two_vulns(self):
        raw = _load_fixture("fixture-pip-audit.json")
        findings = mod.parse_pip_audit(raw)
        assert len(findings) == 2

    def test_8_2_severity_critical(self):
        raw = _load_fixture("fixture-pip-audit.json")
        findings = mod.parse_pip_audit(raw)
        assert all(f["severity"] == "critical" for f in findings)

    def test_8_3_file_is_none(self):
        raw = _load_fixture("fixture-pip-audit.json")
        findings = mod.parse_pip_audit(raw)
        assert all(f["file"] is None for f in findings)

    def test_8_4_line_is_one(self):
        raw = _load_fixture("fixture-pip-audit.json")
        findings = mod.parse_pip_audit(raw)
        assert all(f["line"] == 1 for f in findings)

    def test_8_5_rule_is_vuln_id(self):
        raw = _load_fixture("fixture-pip-audit.json")
        findings = mod.parse_pip_audit(raw)
        assert findings[0]["rule"] == "CVE-2024-1234"
        assert findings[1]["rule"] == "PYSEC-2024-5678"

    def test_8_6_message_format(self):
        raw = _load_fixture("fixture-pip-audit.json")
        findings = mod.parse_pip_audit(raw)
        assert findings[0]["message"] == "requests 2.25.0: SSRF via crafted URL"

    def test_8_7_empty_vulns_skipped(self):
        raw = _load_fixture("fixture-pip-audit.json")
        findings = mod.parse_pip_audit(raw)
        # flask has 0 vulns → no findings for it
        names_in_messages = [f["message"] for f in findings]
        assert not any("flask" in m for m in names_in_messages)


# ===========================================================================
# TC9: npm audit Adapter (parse_npm_audit)
# ===========================================================================


class TestParseNpmAudit:
    def test_9_1_four_vulnerabilities(self):
        raw = _load_fixture("fixture-npm-audit.json")
        findings = mod.parse_npm_audit(raw)
        assert len(findings) == 4

    def test_9_2_severity_mapping(self):
        raw = _load_fixture("fixture-npm-audit.json")
        findings = mod.parse_npm_audit(raw)
        sev_map = {f["message"].split(":")[0]: f["severity"] for f in findings}
        assert sev_map["lodash"] == "critical"
        assert sev_map["express"] == "error"
        assert sev_map["minimist"] == "warning"
        assert sev_map["qs"] == "info"

    def test_9_3_via_string(self):
        """via is a plain string, not object."""
        raw = _load_fixture("fixture-npm-audit.json")
        findings = mod.parse_npm_audit(raw)
        minimist = [f for f in findings if "minimist" in f["message"]][0]
        assert minimist["rule"] == "prototype-pollution-pkg"

    def test_9_4_no_via_entries(self):
        raw = _load_fixture("fixture-npm-audit.json")
        findings = mod.parse_npm_audit(raw)
        qs = [f for f in findings if "qs" in f["message"]][0]
        assert qs["rule"] == "qs"  # package name as fallback

    def test_9_5_file_is_none(self):
        raw = _load_fixture("fixture-npm-audit.json")
        findings = mod.parse_npm_audit(raw)
        assert all(f["file"] is None for f in findings)


# ===========================================================================
# TC10: Content-Hash (compute_content_hash)
# ===========================================================================


class TestComputeContentHash:
    def test_10_1_middle_of_file(self):
        """Line 7 of 15-line file → window lines 5–9."""
        lines = SOURCE_DIR.joinpath("sample.py").read_text().splitlines()
        window = "\n".join(lines[4:9])  # 0-indexed 4–8 = lines 5–9
        expected = _expected_hash(window)
        result = mod.compute_content_hash(
            "sample.py", 7, str(SOURCE_DIR), "ruff", "E501"
        )
        assert result == expected
        assert len(result) == 8

    def test_10_2_first_line(self):
        """Line 1 → window lines 1–3."""
        lines = SOURCE_DIR.joinpath("sample.py").read_text().splitlines()
        window = "\n".join(lines[0:3])
        expected = _expected_hash(window)
        result = mod.compute_content_hash(
            "sample.py", 1, str(SOURCE_DIR), "ruff", "E501"
        )
        assert result == expected

    def test_10_3_last_line(self):
        """Last line of 15-line file → window is last 3 lines."""
        lines = SOURCE_DIR.joinpath("sample.py").read_text().splitlines()
        window = "\n".join(lines[-3:])
        expected = _expected_hash(window)
        result = mod.compute_content_hash(
            "sample.py", len(lines), str(SOURCE_DIR), "ruff", "E501"
        )
        assert result == expected

    def test_10_4_one_line_file(self):
        lines = SOURCE_DIR.joinpath("oneliner.py").read_text().splitlines()
        window = lines[0]
        expected = _expected_hash(window)
        result = mod.compute_content_hash(
            "oneliner.py", 1, str(SOURCE_DIR), "ruff", "E501"
        )
        assert result == expected

    def test_10_5_two_line_file_line_1(self):
        lines = SOURCE_DIR.joinpath("twoliner.py").read_text().splitlines()
        window = "\n".join(lines[0:2])
        expected = _expected_hash(window)
        result = mod.compute_content_hash(
            "twoliner.py", 1, str(SOURCE_DIR), "ruff", "E501"
        )
        assert result == expected

    def test_10_6_binary_file(self, tmp_path):
        """Non-UTF-8 file → no crash, uses errors='replace'."""
        bf = tmp_path / "binary.bin"
        bf.write_bytes(b"\x80\x81\x82\n\xff\xfe\n\x00\x01\n")
        result = mod.compute_content_hash(
            "binary.bin", 1, str(tmp_path), "ruff", "E501"
        )
        assert len(result) == 8

    def test_10_7_empty_file(self, tmp_path):
        ef = tmp_path / "empty.py"
        ef.write_text("")
        result = mod.compute_content_hash(
            "empty.py", 1, str(tmp_path), "ruff", "E501"
        )
        assert result == _expected_hash("")

    def test_10_8_line_exceeds_length(self, tmp_path, capsys):
        f = tmp_path / "short.py"
        f.write_text("line1\nline2\nline3\n")
        result = mod.compute_content_hash(
            "short.py", 100, str(tmp_path), "ruff", "E501"
        )
        # Should clamp to last line — window is lines 1–3
        assert len(result) == 8
        # capsys captures stderr from compute_content_hash
        captured = capsys.readouterr()
        assert "WARNING:" in captured.err
        assert "exceeds file length" in captured.err

    def test_10_9_file_not_found(self, capsys):
        result = mod.compute_content_hash(
            "nonexistent.py", 1, str(SOURCE_DIR), "ruff", "E501"
        )
        expected = _expected_hash("ruff:E501:nonexistent.py:1")
        assert result == expected
        captured = capsys.readouterr()
        assert "WARNING: cannot read nonexistent.py for content-hash" in captured.err

    def test_10_10_stability(self, tmp_path):
        """Insert 5 lines at top, recompute on shifted line → same hash."""
        src = SOURCE_DIR / "sample.py"
        dest = tmp_path / "sample.py"
        shutil.copy(src, dest)

        original_hash = mod.compute_content_hash(
            "sample.py", 7, str(tmp_path), "ruff", "E501"
        )

        # Insert 5 lines at top
        content = dest.read_text()
        dest.write_text("# added 1\n# added 2\n# added 3\n# added 4\n# added 5\n" + content)

        shifted_hash = mod.compute_content_hash(
            "sample.py", 12, str(tmp_path), "ruff", "E501"
        )
        assert original_hash == shifted_hash

    def test_10_11_eight_hex_chars(self):
        result = mod.compute_content_hash(
            "sample.py", 7, str(SOURCE_DIR), "ruff", "E501"
        )
        assert len(result) == 8
        assert all(c in "0123456789abcdef" for c in result)

    def test_10_12_path_escape(self, tmp_path, capsys):
        """Path with ../ escaping project root → fallback hash."""
        result = mod.compute_content_hash(
            "../../../etc/passwd", 1, str(tmp_path), "ruff", "E501"
        )
        expected = _expected_hash("ruff:E501:../../../etc/passwd:1")
        assert result == expected
        captured = capsys.readouterr()
        assert "WARNING: path" in captured.err
        assert "escapes project root" in captured.err

    def test_10_13_symlink_escape(self, tmp_path):
        """Symlink pointing outside project root → fallback hash."""
        symlink = tmp_path / "escape.py"
        symlink.symlink_to("/etc/hosts")
        result = mod.compute_content_hash(
            "escape.py", 1, str(tmp_path), "ruff", "E501"
        )
        expected = _expected_hash("ruff:E501:escape.py:1")
        assert result == expected


# ===========================================================================
# TC11: Path Normalisation (normalise_path)
# ===========================================================================


class TestNormalisePath:
    def test_11_1_absolute_to_relative(self):
        result = mod.normalise_path("/home/user/project/src/foo.py", "/home/user/project")
        assert result == "src/foo.py"

    def test_11_2_strip_dot_slash(self):
        result = mod.normalise_path("./src/foo.py", "/any/root")
        assert result == "src/foo.py"

    def test_11_3_already_relative(self):
        result = mod.normalise_path("src/foo.py", "/any/root")
        assert result == "src/foo.py"

    def test_11_4_path_escape(self):
        _path, escaped = mod.normalise_path_with_check(
            "../../../etc/passwd", str(SOURCE_DIR)
        )
        assert escaped is True


# ===========================================================================
# TC12: Finding Enrichment (enrich_findings)
# ===========================================================================


class TestEnrichFindings:
    def test_12_1_adds_fields(self):
        raw = [{"file": "sample.py", "line": 7, "rule": "E501",
                "message": "Line too long", "severity": "error"}]
        enriched = mod.enrich_findings(raw, "ruff", str(SOURCE_DIR))
        f = enriched[0]
        assert "id" in f
        assert "tool" in f
        assert "content_hash" in f
        assert f["tool"] == "ruff"

    def test_12_2_id_format(self):
        raw = [{"file": "sample.py", "line": 7, "rule": "E501",
                "message": "Line too long", "severity": "error"}]
        enriched = mod.enrich_findings(raw, "ruff", str(SOURCE_DIR))
        f = enriched[0]
        # ruff:E501-sample.py-<hash8>
        parts = f["id"].split(":")
        assert parts[0] == "ruff"
        rest = parts[1]
        segments = rest.split("-")
        assert segments[0] == "E501"
        # basename is sample.py (contains dot, split by last - for hash)
        assert f["id"].endswith(f["content_hash"])

    def test_12_3_rule_uppercased(self):
        raw = [{"file": "sample.py", "line": 7, "rule": "e501",
                "message": "test", "severity": "error"}]
        enriched = mod.enrich_findings(raw, "ruff", str(SOURCE_DIR))
        assert ":E501-" in enriched[0]["id"]

    def test_12_4_hyphenated_filename(self):
        raw = [{"file": "grinder-check.sh", "line": 1, "rule": "SC2086",
                "message": "test", "severity": "error"}]
        enriched = mod.enrich_findings(raw, "shellcheck", str(SOURCE_DIR))
        assert "grinder-check.sh" in enriched[0]["id"]

    def test_12_5_dotted_filename(self):
        raw = [{"file": "my.module.py", "line": 1, "rule": "E501",
                "message": "test", "severity": "error"}]
        enriched = mod.enrich_findings(raw, "ruff", str(SOURCE_DIR))
        assert "my.module.py" in enriched[0]["id"]

    def test_12_6_hyphenated_rule(self):
        raw = [{"file": "sample.py", "line": 1, "rule": "no-unused-vars",
                "message": "test", "severity": "error"}]
        enriched = mod.enrich_findings(raw, "eslint", str(SOURCE_DIR))
        assert ":NO-UNUSED-VARS-" in enriched[0]["id"]

    def test_12_7_duplicate_findings(self):
        raw = [
            {"file": "sample.py", "line": 7, "rule": "E501",
             "message": "test", "severity": "error"},
            {"file": "sample.py", "line": 7, "rule": "E501",
             "message": "test", "severity": "error"},
        ]
        enriched = mod.enrich_findings(raw, "ruff", str(SOURCE_DIR))
        assert len(enriched) == 2

    def test_12_8_pip_audit_manifest_resolution(self):
        raw = [{"file": None, "line": 1, "rule": "CVE-2024-1234",
                "message": "test", "severity": "critical"}]
        enriched = mod.enrich_findings(raw, "pip-audit", str(SOURCE_DIR))
        assert enriched[0]["file"] == "requirements.txt"

    def test_12_9_pip_audit_no_manifest(self, tmp_path, capsys):
        raw = [{"file": None, "line": 1, "rule": "CVE-2024-1234",
                "message": "test", "severity": "critical"}]
        enriched = mod.enrich_findings(raw, "pip-audit", str(tmp_path))
        assert enriched[0]["file"] == "requirements.txt"
        captured = capsys.readouterr()
        assert "WARNING: no pip manifest found" in captured.err

    def test_12_10_npm_audit_manifest_resolution(self):
        raw = [{"file": None, "line": 1, "rule": "GHSA-xxxx",
                "message": "test", "severity": "critical"}]
        enriched = mod.enrich_findings(raw, "npm-audit", str(SOURCE_DIR))
        assert enriched[0]["file"] == "package.json"

    def test_12_11_npm_audit_no_manifest(self, tmp_path, capsys):
        raw = [{"file": None, "line": 1, "rule": "GHSA-xxxx",
                "message": "test", "severity": "critical"}]
        enriched = mod.enrich_findings(raw, "npm-audit", str(tmp_path))
        assert enriched[0]["file"] == "package.json"
        captured = capsys.readouterr()
        assert "WARNING: no npm manifest found" in captured.err

    def test_12_12_pip_audit_pyproject_fallback(self, tmp_path):
        """When only pyproject.toml exists (no requirements.txt),
        _resolve_manifest returns pyproject.toml."""
        (tmp_path / "pyproject.toml").write_text("[project]\nname = 'x'\n")
        raw = [{"file": None, "line": 1, "rule": "CVE-2024-5678",
                "message": "test", "severity": "critical"}]
        enriched = mod.enrich_findings(raw, "pip-audit", str(tmp_path))
        assert enriched[0]["file"] == "pyproject.toml"


# ===========================================================================
# TC13: CLI Integration — Happy Path
# ===========================================================================


class TestCLIHappyPath:
    def test_13_1_ruff(self):
        raw = _load_fixture("fixture-ruff.json")
        r = run_tool("normalise-findings.py", "--tool", "ruff",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert len(findings) == 3
        for f in findings:
            assert set(f.keys()) == {"id", "tool", "rule", "file", "line",
                                      "severity", "message", "content_hash"}

    def test_13_2_mypy(self):
        raw = _load_fixture("fixture-mypy.txt")
        r = run_tool("normalise-findings.py", "--tool", "mypy",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert len(findings) == 4

    def test_13_3_shellcheck(self):
        raw = _load_fixture("fixture-shellcheck.json")
        r = run_tool("normalise-findings.py", "--tool", "shellcheck",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert findings[0]["rule"] == "SC2086"

    def test_13_4_eslint(self):
        raw = _load_fixture("fixture-eslint.json")
        r = run_tool("normalise-findings.py", "--tool", "eslint",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert len(findings) == 4

    def test_13_5_bandit(self):
        raw = _load_fixture("fixture-bandit.json")
        r = run_tool("normalise-findings.py", "--tool", "bandit",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert findings[0]["severity"] == "error"

    def test_13_6_semgrep(self):
        raw = _load_fixture("fixture-semgrep.json")
        r = run_tool("normalise-findings.py", "--tool", "semgrep",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert len(findings) == 3

    def test_13_7_pip_audit(self):
        raw = _load_fixture("fixture-pip-audit.json")
        r = run_tool("normalise-findings.py", "--tool", "pip-audit",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert len(findings) == 2
        assert all(f["severity"] == "critical" for f in findings)

    def test_13_8_npm_audit(self):
        raw = _load_fixture("fixture-npm-audit.json")
        r = run_tool("normalise-findings.py", "--tool", "npm-audit",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert len(findings) == 4

    def test_13_9_tsc(self):
        raw = _load_fixture("fixture-tsc.txt")
        r = run_tool("normalise-findings.py", "--tool", "tsc",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert len(findings) == 2


# ===========================================================================
# TC14: CLI Integration — Error Handling
# ===========================================================================


class TestCLIErrorHandling:
    def test_14_1_empty_json_array(self):
        r = run_tool("normalise-findings.py", "--tool", "ruff", stdin="[]")
        assert r.exit_code == 0
        assert json.loads(r.stdout) == []

    def test_14_2_empty_results_object(self):
        r = run_tool("normalise-findings.py", "--tool", "bandit",
                      stdin='{"results": []}')
        assert r.exit_code == 0
        assert json.loads(r.stdout) == []

    def test_14_3_empty_text_mypy(self):
        r = run_tool("normalise-findings.py", "--tool", "mypy", stdin="")
        assert r.exit_code == 0
        assert json.loads(r.stdout) == []

    def test_14_4_empty_text_tsc(self):
        r = run_tool("normalise-findings.py", "--tool", "tsc", stdin="")
        assert r.exit_code == 0
        assert json.loads(r.stdout) == []

    def test_14_5_truncated_json(self):
        raw = _load_fixture("fixture-truncated.json")
        r = run_tool("normalise-findings.py", "--tool", "ruff", stdin=raw)
        assert r.exit_code == 1
        assert "normalise: failed to parse ruff output" in r.stderr

    def test_14_6_wrong_json_structure(self):
        raw = _load_fixture("fixture-wrong-structure.json")
        r = run_tool("normalise-findings.py", "--tool", "ruff", stdin=raw)
        assert r.exit_code == 1

    def test_14_7_unknown_tool(self):
        r = run_tool("normalise-findings.py", "--tool", "unknown-scanner", stdin="[]")
        assert r.exit_code == 1
        assert "normalise: unknown tool: unknown-scanner" in r.stderr

    def test_14_8_source_file_not_found(self, tmp_path):
        """Scanner output references nonexistent file → fallback hash, exit 0."""
        raw = json.dumps([{
            "code": "E501", "filename": "deleted.py",
            "location": {"row": 1}, "message": "test"
        }])
        r = run_tool("normalise-findings.py", "--tool", "ruff",
                      "--project-root", str(tmp_path), stdin=raw)
        assert r.exit_code == 0
        assert "WARNING: cannot read deleted.py for content-hash" in r.stderr

    def test_14_9_completely_empty_stdin_json(self):
        r = run_tool("normalise-findings.py", "--tool", "ruff", stdin="")
        assert r.exit_code == 1

    def test_14_10_bandit_bare_array(self):
        """Bandit adapter given bare array instead of object → exit 1, clean message."""
        r = run_tool("normalise-findings.py", "--tool", "bandit", stdin="[1,2,3]")
        assert r.exit_code == 1
        assert "normalise: failed to parse bandit output" in r.stderr

    def test_14_11_line_exceeds_file_length_cli(self, tmp_path):
        """Finding references line beyond file length → WARNING on stderr."""
        short = tmp_path / "short.py"
        short.write_text("line1\nline2\nline3\n")
        raw = json.dumps([{
            "code": "E501", "filename": "short.py",
            "location": {"row": 100}, "message": "test"
        }])
        r = run_tool("normalise-findings.py", "--tool", "ruff",
                      "--project-root", str(tmp_path), stdin=raw)
        assert r.exit_code == 0
        assert "WARNING:" in r.stderr
        assert "exceeds file length" in r.stderr

    def test_14_12_path_escape_cli(self, tmp_path):
        """Finding with ../../etc/passwd path → exit 0, warning, safe output."""
        raw = json.dumps([{
            "code": "E501", "filename": "../../etc/passwd",
            "location": {"row": 1}, "message": "test"
        }])
        r = run_tool("normalise-findings.py", "--tool", "ruff",
                      "--project-root", str(tmp_path), stdin=raw)
        assert r.exit_code == 0
        assert "escapes project root" in r.stderr
        findings = json.loads(r.stdout)
        assert not findings[0]["file"].startswith("../")


# ===========================================================================
# TC15: CLI Integration — Path and Manifest
# ===========================================================================


class TestCLIPathAndManifest:
    def test_15_1_absolute_path_normalised(self):
        raw = json.dumps([{
            "code": "E501",
            "filename": str(SOURCE_DIR / "sample.py"),
            "location": {"row": 1},
            "message": "test"
        }])
        r = run_tool("normalise-findings.py", "--tool", "ruff",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert findings[0]["file"] == "sample.py"

    def test_15_2_dot_slash_stripped(self):
        raw = json.dumps([{
            "code": "E501", "filename": "./sample.py",
            "location": {"row": 1}, "message": "test"
        }])
        r = run_tool("normalise-findings.py", "--tool", "ruff",
                      "--project-root", str(SOURCE_DIR), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert findings[0]["file"] == "sample.py"

    def test_15_3_pip_audit_no_manifest(self, tmp_path):
        raw = _load_fixture("fixture-pip-audit.json")
        r = run_tool("normalise-findings.py", "--tool", "pip-audit",
                      "--project-root", str(tmp_path), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert findings[0]["file"] == "requirements.txt"
        assert "WARNING: no pip manifest found" in r.stderr

    def test_15_4_npm_audit_no_manifest(self, tmp_path):
        raw = _load_fixture("fixture-npm-audit.json")
        r = run_tool("normalise-findings.py", "--tool", "npm-audit",
                      "--project-root", str(tmp_path), stdin=raw)
        assert r.exit_code == 0
        findings = json.loads(r.stdout)
        assert findings[0]["file"] == "package.json"
        assert "WARNING: no npm manifest found" in r.stderr


# ===========================================================================
# TC16: No Network Calls (REQ-18)
# ===========================================================================


class TestNoNetworkCalls:
    def test_16_1_no_network_imports(self):
        source = (REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "normalise-findings.py").read_text()
        forbidden = ["import socket", "import urllib", "import http",
                      "import requests", "from socket", "from urllib",
                      "from http", "from requests"]
        for pattern in forbidden:
            assert pattern not in source, f"Found forbidden import: {pattern}"


# ===========================================================================
# TC17: Adapter Registry (REQ-19)
# ===========================================================================


class TestAdapterRegistry:
    EXPECTED_TOOLS = {"ruff", "shellcheck", "eslint", "mypy", "tsc",
                      "bandit", "semgrep", "pip-audit", "npm-audit"}

    def test_17_1_all_tools_registered(self):
        assert set(mod.ADAPTER_REGISTRY.keys()) == self.EXPECTED_TOOLS

    def test_17_2_all_callable(self):
        for name, func in mod.ADAPTER_REGISTRY.items():
            assert callable(func), f"{name} adapter is not callable"


# ===========================================================================
# TC18: fix_version Enhancement (NF-01..NF-05)
# ===========================================================================


class TestFixVersion:
    """Tests for fix_version field population in CVE scanner adapters."""

    def test_nf01_pip_audit_fix_version_populated(self):
        """NF-01 / C5a: pip-audit finding includes fix_version from fix_versions array."""
        raw = json.dumps({
            "dependencies": [{
                "name": "requests",
                "version": "2.25.0",
                "vulns": [{
                    "id": "CVE-2024-1234",
                    "fix_versions": ["2.31.0"],
                    "description": "SSRF via crafted URL",
                }],
            }],
        })
        findings = mod.parse_pip_audit(raw)
        assert len(findings) == 1
        assert findings[0]["fix_version"] == "2.31.0"

    def test_nf02_pip_audit_no_fix_version_null(self):
        """NF-02 / C5a: pip-audit finding with empty fix_versions gets null."""
        raw = json.dumps({
            "dependencies": [{
                "name": "requests",
                "version": "2.25.0",
                "vulns": [{
                    "id": "CVE-2024-9999",
                    "fix_versions": [],
                    "description": "No fix available",
                }],
            }],
        })
        findings = mod.parse_pip_audit(raw)
        assert len(findings) == 1
        assert findings[0]["fix_version"] is None

    def test_nf01b_pip_audit_multiple_fix_versions_picks_highest(self):
        """NF-01b: pip-audit with multiple fix_versions picks the highest."""
        raw = json.dumps({
            "dependencies": [{
                "name": "requests",
                "version": "2.25.0",
                "vulns": [{
                    "id": "CVE-2024-1234",
                    "fix_versions": ["2.28.0", "2.31.0", "2.29.0"],
                    "description": "SSRF",
                }],
            }],
        })
        findings = mod.parse_pip_audit(raw)
        assert findings[0]["fix_version"] == "2.31.0"

    def test_nf03_npm_audit_fix_available_object(self):
        """NF-03 / C5a: npm audit finding with fixAvailable object."""
        raw = json.dumps({
            "vulnerabilities": {
                "lodash": {
                    "name": "lodash",
                    "severity": "critical",
                    "via": [{"url": "https://ghsa.example", "title": "PP"}],
                    "fixAvailable": {"name": "lodash", "version": "4.17.21"},
                },
            },
        })
        findings = mod.parse_npm_audit(raw)
        assert len(findings) == 1
        assert findings[0]["fix_version"] == "4.17.21"

    def test_nf04_npm_audit_fix_available_false(self):
        """NF-04 / C5a: npm audit finding with fixAvailable: false."""
        raw = json.dumps({
            "vulnerabilities": {
                "lodash": {
                    "name": "lodash",
                    "severity": "critical",
                    "via": [{"url": "https://ghsa.example", "title": "PP"}],
                    "fixAvailable": False,
                },
            },
        })
        findings = mod.parse_npm_audit(raw)
        assert len(findings) == 1
        assert findings[0]["fix_version"] is None

    def test_nf04b_npm_audit_no_fix_available_key(self):
        """NF-04b: npm audit finding without fixAvailable key."""
        raw = json.dumps({
            "vulnerabilities": {
                "lodash": {
                    "name": "lodash",
                    "severity": "critical",
                    "via": [{"url": "https://ghsa.example", "title": "PP"}],
                },
            },
        })
        findings = mod.parse_npm_audit(raw)
        assert len(findings) == 1
        assert findings[0]["fix_version"] is None

    def test_nf05_non_cve_scanner_no_fix_version(self):
        """NF-05 / C5a: ruff findings do not have fix_version field."""
        raw = json.dumps([{
            "filename": "test.py",
            "location": {"row": 1, "column": 1},
            "code": "E501",
            "message": "Line too long",
        }])
        findings = mod.parse_ruff(raw)
        assert len(findings) == 1
        assert "fix_version" not in findings[0]
