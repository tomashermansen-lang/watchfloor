"""Tests for claude/tools/lib/ratchet-discover.py — C4 scanner discovery."""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch, MagicMock

from conftest import import_tool, run_tool

mod = import_tool("lib/ratchet-discover.py")

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "ratchet"


# ---------------------------------------------------------------------------
# TC-RD01: Manifest with grinder.findings → correct scanner specs
# ---------------------------------------------------------------------------

def test_rd01_manifest_with_findings(tmp_path):
    pipeline_yaml = tmp_path / "pipeline.yaml"
    pipeline_yaml.write_text((FIXTURES / "manifest-with-findings.yaml").read_text())

    result = mod.discover(str(tmp_path))

    scanners = result["scanners"]
    tool_names = {s["tool"] for s in scanners}
    assert "shellcheck" in tool_names
    assert "ruff" in tool_names

    # Verify shellcheck has correct paths
    sc = next(s for s in scanners if s["tool"] == "shellcheck")
    assert "claude/tools/" in sc["paths"]


# ---------------------------------------------------------------------------
# TC-RD02: No manifest → auto-detect via shutil.which
# ---------------------------------------------------------------------------

def test_rd02_no_manifest_auto_detect(tmp_path):
    # No CLAUDE.md at project root
    with patch("shutil.which", side_effect=lambda t: f"/usr/bin/{t}" if t in ("ruff", "shellcheck") else None):
        result = mod.discover(str(tmp_path))

    tool_names = {s["tool"] for s in result["scanners"]}
    assert "ruff" in tool_names
    assert "shellcheck" in tool_names
    assert "eslint" not in tool_names  # not available


# ---------------------------------------------------------------------------
# TC-RD03: Zero scanners → warning
# ---------------------------------------------------------------------------

def test_rd03_zero_scanners_warning(tmp_path):
    with patch("shutil.which", return_value=None):
        result = mod.discover(str(tmp_path))

    assert result["scanners"] == []
    assert any("no scanners discovered" in w for w in result["warnings"])


# ---------------------------------------------------------------------------
# TC-RD04: Manifest present but no grinder.findings → auto-detect fallback
# ---------------------------------------------------------------------------

def test_rd04_manifest_no_grinder_block(tmp_path):
    claude_md = tmp_path / "CLAUDE.md"
    claude_md.write_text("# CLAUDE.md\n\nNo pipeline block here.\n")

    with patch("shutil.which", side_effect=lambda t: f"/usr/bin/{t}" if t == "shellcheck" else None):
        result = mod.discover(str(tmp_path))

    tool_names = {s["tool"] for s in result["scanners"]}
    assert "shellcheck" in tool_names


# ---------------------------------------------------------------------------
# TC-RD05: validate-manifest.py failure → auto-detect fallback
# ---------------------------------------------------------------------------

def test_rd05_manifest_parser_failure(tmp_path):
    claude_md = tmp_path / "CLAUDE.md"
    claude_md.write_text((FIXTURES / "manifest-with-findings.md").read_text())

    with patch.object(mod, "_run_parse_grinder", side_effect=Exception("parse failed")), \
         patch("shutil.which", side_effect=lambda t: f"/usr/bin/{t}" if t == "ruff" else None):
        result = mod.discover(str(tmp_path))

    tool_names = {s["tool"] for s in result["scanners"]}
    assert "ruff" in tool_names


# ---------------------------------------------------------------------------
# TC-RD06: Scanner invocation specs match normaliser expectations
# ---------------------------------------------------------------------------

def test_rd06_scanner_specs_correct_flags(tmp_path):
    claude_md = tmp_path / "CLAUDE.md"
    claude_md.write_text((FIXTURES / "manifest-with-findings.md").read_text())

    result = mod.discover(str(tmp_path))

    for scanner in result["scanners"]:
        if scanner["tool"] == "ruff":
            assert "--output-format" in scanner["command"]
            assert "json" in scanner["command"]
        elif scanner["tool"] == "shellcheck":
            assert "-f" in scanner["command"]
            assert "json" in scanner["command"]


# ---------------------------------------------------------------------------
# TC-RD07: --project-root flag respected
# ---------------------------------------------------------------------------

def test_rd07_project_root_flag(tmp_path):
    claude_md = tmp_path / "CLAUDE.md"
    claude_md.write_text((FIXTURES / "manifest-with-findings.md").read_text())

    result = run_tool("lib/ratchet-discover.py", "--project-root", str(tmp_path))
    assert result.exit_code == 0
    output = json.loads(result.stdout)
    assert "scanners" in output


# ---------------------------------------------------------------------------
# TC-RD08: get-findings.sh --no-filter in all scanner commands
# ---------------------------------------------------------------------------

def test_rd08_no_filter_in_commands(tmp_path):
    claude_md = tmp_path / "CLAUDE.md"
    claude_md.write_text((FIXTURES / "manifest-with-findings.md").read_text())

    result = mod.discover(str(tmp_path))

    for scanner in result["scanners"]:
        assert scanner["command"][0] == "get-findings.sh"
        assert scanner["command"][1] == "--no-filter"
