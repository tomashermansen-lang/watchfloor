"""Tests for validate-manifest.py --parse-grinder flag (Component C / Suite D3).

Covers: D3-01..D3-04 from TESTPLAN.md.
"""
from __future__ import annotations

import pytest

import json
from pathlib import Path

from conftest import run_tool


FIXTURES = "tests/fixtures/discovery-pass"


def _write_pipeline(tmp_path: Path, content: str) -> Path:
    p = tmp_path / "pipeline.yaml"
    p.write_text(content)
    return p


class TestParseGrinder:
    """D3-01..D3-04: --parse-grinder CLI mode."""

    def test_parse_grinder_valid(self, tmp_path: Path) -> None:
        """D3-01: Valid grinder block -> JSON on stdout, exit 0."""
        content = (
            "toolchain:\n"
            "  infra: [bash, shellcheck]\n"
            "\n"
            "grinder:\n"
            "  languages: [bash]\n"
            "  findings:\n"
            "    shellcheck:\n"
            "      paths: [claude/tools/]\n"
            "    fix_rules_allowlist: []\n"
            "    never_touch_files: []\n"
        )
        p = _write_pipeline(tmp_path, content)
        result = run_tool("validate-manifest.py", "--parse-grinder", str(p))
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        assert isinstance(data, dict)
        assert "languages" in data
        assert "findings" in data
        assert "shellcheck" in data["findings"]

    def test_parse_grinder_no_block(self, tmp_path: Path) -> None:
        """D3-02: No grinder block -> exit 1, error on stderr."""
        content = "toolchain:\n  infra: [bash]\n"
        p = _write_pipeline(tmp_path, content)
        result = run_tool("validate-manifest.py", "--parse-grinder", str(p))
        assert result.exit_code == 1
        assert "no grinder block" in result.stderr.lower() or "no grinder block" in result.stdout.lower()

    def test_parse_grinder_malformed_yaml(self, tmp_path: Path) -> None:
        """D3-03: Malformed YAML -> exit 1, parse error on stderr."""
        content = (
            "grinder:\n"
            "  languages: [bash\n"  # Unclosed bracket
            "  findings:\n"
        )
        p = _write_pipeline(tmp_path, content)
        result = run_tool("validate-manifest.py", "--parse-grinder", str(p))
        assert result.exit_code == 1

    def test_backward_compat_positional(self, tmp_path: Path) -> None:
        """D3-04: validate-manifest.py with positional pipeline.yaml path works."""
        content = (
            "toolchain:\n"
            "  infra: [bash, shellcheck]\n"
            "\n"
            "grinder:\n"
            "  languages: [bash]\n"
            "  findings:\n"
            "    shellcheck:\n"
            "      paths: [claude/tools/]\n"
            "    fix_rules_allowlist: []\n"
            "    never_touch_files: []\n"
        )
        p = _write_pipeline(tmp_path, content)
        result = run_tool("validate-manifest.py", str(p))
        assert result.exit_code == 0
        assert "Valid" in result.stdout
