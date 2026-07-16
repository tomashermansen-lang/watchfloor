"""Tests for validate-plan.py and conftest fixtures/helpers.

Covers: C1-3, C2-1..C2-14, C3-1..C3-3 from TESTPLAN.md.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

from conftest import RunResult, import_tool, run_tool


# ---------------------------------------------------------------------------
# C1: pyproject.toml validation
# ---------------------------------------------------------------------------

class TestPyprojectConfig:
    """C1-3: requires-python declares >=3.11 (raised from 3.9 — required by
    dependencies like FastAPI 0.110+ and Pydantic 2.x)."""

    def test_requires_python(self, repo_root: Path) -> None:
        content = (repo_root / "pyproject.toml").read_text()
        assert 'requires-python = ">=3.11"' in content


# ---------------------------------------------------------------------------
# C2: conftest fixtures and helpers
# ---------------------------------------------------------------------------

class TestTmpClaudeMd:
    """C2-1, C2-2, C2-14: tmp_claude_md fixture."""

    def test_creates_file_with_content(self, tmp_claude_md, tmp_path: Path) -> None:
        content = "pipeline:\n  toolchain:\n    infra: [jq]"
        p = tmp_claude_md(content)
        assert p.exists()
        assert p.read_text() == content
        assert str(tmp_path) in str(p)

    def test_factory_creates_multiple_files(self, tmp_claude_md) -> None:
        p1 = tmp_claude_md("first")
        p2 = tmp_claude_md("second")
        assert p1 != p2
        assert p1.read_text() == "first"
        assert p2.read_text() == "second"


class TestTmpYamlFile:
    """C2-3: tmp_yaml_file fixture."""

    def test_creates_valid_yaml(self, tmp_yaml_file) -> None:
        data = {"key": "val", "nested": {"a": 1}}
        p = tmp_yaml_file(data)
        assert p.exists()
        loaded = yaml.safe_load(p.read_text())
        assert loaded == data


class TestTmpJsonFile:
    """C2-4: tmp_json_file fixture."""

    def test_creates_valid_json(self, tmp_json_file) -> None:
        data = {"key": "val", "list": [1, 2, 3]}
        p = tmp_json_file(data)
        assert p.exists()
        loaded = json.loads(p.read_text())
        assert loaded == data


class TestSchemaDir:
    """C2-5: schema_dir fixture."""

    def test_returns_existing_directory(self, schema_dir: Path) -> None:
        assert schema_dir.exists()
        assert schema_dir.is_dir()
        assert schema_dir.name == "schema"


class TestRepoRoot:
    """C2-6: repo_root fixture."""

    def test_contains_claude_md(self, repo_root: Path) -> None:
        assert (repo_root / "CLAUDE.md").exists()


class TestImportTool:
    """C2-7, C2-9, C2-10: import_tool helper."""

    def test_import_validate_plan(self) -> None:
        mod = import_tool("validate-plan.py")
        assert hasattr(mod, "validate_structural")
        assert hasattr(mod, "validate_semantic")

    def test_nonexistent_raises_file_not_found(self) -> None:
        with pytest.raises(FileNotFoundError):
            import_tool("nonexistent.py")

    def test_multi_hyphen_name(self, tmp_path: Path, monkeypatch) -> None:
        """C2-10: import_tool handles arbitrary hyphens in filenames."""
        tool_file = tmp_path / "multi-hyphen-name.py"
        tool_file.write_text("SENTINEL = 42\n")
        import conftest
        monkeypatch.setattr(conftest, "TOOLS_DIR", tmp_path)
        mod = import_tool("multi-hyphen-name.py")
        assert mod.SENTINEL == 42


class TestRunResult:
    """C2-13: RunResult dataclass."""

    def test_has_expected_attributes(self) -> None:
        r = RunResult(exit_code=0, stdout="out", stderr="err")
        assert r.exit_code == 0
        assert r.stdout == "out"
        assert r.stderr == "err"


class TestRunTool:
    """C2-11, C2-12: run_tool helper."""

    def test_valid_plan_exits_zero(self) -> None:
        plan_path = Path(__file__).resolve().parent.parent / \
            "docs" / "INPROGRESS_Plan_zero-tech-debt-pipeline" / "execution-plan.yaml"
        if not plan_path.exists():
            pytest.skip("execution-plan.yaml not available")
        result = run_tool("validate-plan.py", str(plan_path))
        assert result.exit_code == 0
        assert "Valid" in result.stdout

    def test_nonexistent_file_exits_nonzero(self) -> None:
        result = run_tool("validate-plan.py", "/nonexistent/path.yaml")
        assert result.exit_code != 0
        assert "ERROR" in result.stdout


# ---------------------------------------------------------------------------
# C3: validate-plan.py smoke tests
# ---------------------------------------------------------------------------

class TestValidatePlanSmoke:
    """C3-1..C3-3: smoke tests for validate-plan.py."""

    def test_import_has_validate_structural(self) -> None:
        mod = import_tool("validate-plan.py")
        assert hasattr(mod, "validate_structural")

    def test_import_has_validate_semantic(self) -> None:
        mod = import_tool("validate-plan.py")
        assert hasattr(mod, "validate_semantic")

    def test_validate_structural_returns_list(self) -> None:
        mod = import_tool("validate-plan.py")
        result = mod.validate_structural({}, {})
        assert isinstance(result, list)
