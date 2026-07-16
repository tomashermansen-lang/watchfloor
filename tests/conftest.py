"""Shared fixtures and helpers for Python tests."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any, Callable

import pytest


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools"
SCHEMA_DIR = REPO_ROOT / "core" / "schema"
CLAUDE_SCHEMA_DIR = REPO_ROOT / "core" / "schema"


# ---------------------------------------------------------------------------
# Dataclass
# ---------------------------------------------------------------------------

@dataclass
class RunResult:
    """Result of a CLI tool invocation."""

    exit_code: int
    stdout: str
    stderr: str


# ---------------------------------------------------------------------------
# Plain helper functions (not fixtures — stateless, no setup/teardown)
# ---------------------------------------------------------------------------

def import_tool(name: str) -> ModuleType:
    """Import a Python tool from claude/tools/ by filename.

    Handles hyphenated filenames via importlib (Python cannot import
    ``validate-plan`` as a regular module name).

    Raises FileNotFoundError if the tool file does not exist.
    """
    tool_path = TOOLS_DIR / name
    if not tool_path.exists():
        raise FileNotFoundError(f"Tool not found: {tool_path}")
    module_name = tool_path.stem.replace("-", "_")
    spec = importlib.util.spec_from_file_location(module_name, tool_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load spec for: {tool_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_tool(tool_name: str, *args: str, stdin: str | None = None) -> RunResult:
    """Run a Python CLI tool as a subprocess and return the result.

    Uses ``sys.executable`` to ensure the same interpreter that runs
    pytest is used for the subprocess.

    If *stdin* is provided it is fed to the subprocess via ``input=``.
    """
    tool_path = TOOLS_DIR / tool_name
    result = subprocess.run(
        [sys.executable, str(tool_path), *args],
        capture_output=True,
        text=True,
        input=stdin,
    )
    return RunResult(
        exit_code=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def tmp_claude_md(tmp_path: Path) -> Callable[[str], Path]:
    """Factory fixture: create a temporary CLAUDE.md with given content."""

    def _create(content: str) -> Path:
        p = tmp_path / "CLAUDE.md"
        # Support multiple calls — use unique names after the first
        if p.exists():
            idx = len(list(tmp_path.glob("CLAUDE*.md")))
            p = tmp_path / f"CLAUDE_{idx}.md"
        p.write_text(content)
        return p

    return _create


@pytest.fixture
def tmp_yaml_file(tmp_path: Path) -> Callable[[dict], Path]:
    """Factory fixture: write a dict as YAML to a temp file."""
    import yaml

    counter = [0]

    def _create(data: dict) -> Path:
        counter[0] += 1
        p = tmp_path / f"data_{counter[0]}.yaml"
        p.write_text(yaml.dump(data, default_flow_style=False))
        return p

    return _create


@pytest.fixture
def tmp_json_file(tmp_path: Path) -> Callable[[Any], Path]:
    """Factory fixture: write data as JSON to a temp file."""
    counter = [0]

    def _create(data: Any) -> Path:
        counter[0] += 1
        p = tmp_path / f"data_{counter[0]}.json"
        p.write_text(json.dumps(data, indent=2))
        return p

    return _create


@pytest.fixture(scope="session")
def schema_dir() -> Path:
    """Return the absolute path to the repo's schema/ directory."""
    return SCHEMA_DIR


@pytest.fixture(scope="session")
def claude_schema_dir() -> Path:
    """Return the absolute path to the repo's claude/schema/ directory."""
    return CLAUDE_SCHEMA_DIR


@pytest.fixture(scope="session")
def repo_root() -> Path:
    """Return the absolute path to the repo root."""
    return REPO_ROOT


@pytest.fixture
def tmp_execution_plan(tmp_path: Path) -> Callable[[dict], Path]:
    """Factory fixture: write a dict as YAML to execution-plan.yaml in a plan dir."""
    import yaml

    counter = [0]

    def _create(data: dict, plan_name: str = "test-plan") -> Path:
        counter[0] += 1
        plan_dir = tmp_path / f"docs/INPROGRESS_Plan_{plan_name}_{counter[0]}"
        plan_dir.mkdir(parents=True, exist_ok=True)
        plan_file = plan_dir / "execution-plan.yaml"
        plan_file.write_text(yaml.dump(data, default_flow_style=False))
        return plan_file

    return _create
