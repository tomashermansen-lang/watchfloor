"""Tests for the neutralized schema $id (REQ-1, REQ-3)."""
from __future__ import annotations

import pytest

import json

from conftest import CLAUDE_SCHEMA_DIR, REPO_ROOT, run_tool

NEUTRAL_ID = "https://claude-pipeline/execution-plan.schema.json"
SCHEMA_FILE = CLAUDE_SCHEMA_DIR / "execution-plan.schema.json"


# T-S-01
def test_schema_id_is_neutral():
    data = json.loads(SCHEMA_FILE.read_text())
    assert data["$id"] == NEUTRAL_ID


# T-S-02
def test_schema_file_trailing_newline_preserved():
    raw = SCHEMA_FILE.read_bytes()
    assert raw.endswith(b"\n")


# T-S-03
def test_schema_file_two_space_indent_preserved():
    lines = SCHEMA_FILE.read_text().splitlines()
    assert any(ln.startswith("  ") and not ln.startswith("    ") for ln in lines)


# T-S-04
def test_schema_field_unchanged():
    data = json.loads(SCHEMA_FILE.read_text())
    assert data["$schema"] == "https://json-schema.org/draft/2020-12/schema"


# T-D-03
def test_cli_validates_full_fixture():
    fixture = REPO_ROOT / "tests/fixtures/plan-2.0.0/full.yaml"
    result = run_tool("validate-plan.py", str(fixture))
    assert result.exit_code == 0, f"stderr:\n{result.stderr}\nstdout:\n{result.stdout}"
