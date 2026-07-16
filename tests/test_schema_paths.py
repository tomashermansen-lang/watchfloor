"""Tests for lib/schema_paths.py — schema-path resolver helper.

The helper locates JSON Schema files in either the deployed location
(``~/.claude/schema/``) or the in-repo monorepo location
(``<monorepo>/core/schema/``). Deployed wins when both exist
(REQ-3 edge case 3); in-repo is reached via ancestor walk
(REQ-3a); when neither exists the helper raises FileNotFoundError
naming both attempted paths (REQ-3c).
"""
from __future__ import annotations

import importlib
import importlib.util
import sys
from pathlib import Path

import pytest

LIB_DIR = (
    Path(__file__).resolve().parent.parent
    / "adapters"
    / "claude-code"
    / "claude"
    / "tools"
    / "lib"
)


def _load_schema_paths_from(file_path: Path):
    """Load schema_paths.py with a forged ``__file__`` location.

    The real module lives at ``<repo>/adapters/claude-code/claude/tools/lib/schema_paths.py``.
    Tests stage a fake layout under ``tmp_path`` and need the helper to
    resolve paths relative to a synthetic ``__file__`` inside that
    layout. We accomplish this by loading the source from the fake
    location while preserving the actual module logic.
    """
    real_source = (LIB_DIR / "schema_paths.py").read_text()
    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_path.write_text(real_source)
    spec = importlib.util.spec_from_file_location(
        f"schema_paths_test_{file_path.parent.name}", file_path
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_deployed_wins_when_both_exist(tmp_path: Path) -> None:
    """T-SP-1: REQ-3 edge case 3 — deployed copy wins precedence."""
    deployed = tmp_path / "fake_home" / ".claude" / "schema"
    deployed.mkdir(parents=True)
    (deployed / "execution-plan.schema.json").write_text("{}")

    in_repo = tmp_path / "fake_repo" / "core" / "schema"
    in_repo.mkdir(parents=True)
    (in_repo / "execution-plan.schema.json").write_text("{}")

    fake_module_path = (
        tmp_path / "fake_home" / ".claude" / "tools" / "lib" / "schema_paths.py"
    )
    sp = _load_schema_paths_from(fake_module_path)
    assert sp.schema_dir() == deployed


def test_in_repo_fallback_when_deployed_missing(tmp_path: Path) -> None:
    """T-SP-2: REQ-3a — ancestor walk to ``core/schema/`` in-repo."""
    in_repo = tmp_path / "fake_repo" / "core" / "schema"
    in_repo.mkdir(parents=True)
    (in_repo / "execution-plan.schema.json").write_text("{}")

    fake_module_path = (
        tmp_path
        / "fake_repo"
        / "adapters"
        / "claude-code"
        / "claude"
        / "tools"
        / "lib"
        / "schema_paths.py"
    )
    sp = _load_schema_paths_from(fake_module_path)
    assert sp.schema_dir() == in_repo


def test_raises_when_neither_exists(tmp_path: Path) -> None:
    """T-SP-3: REQ-3c — FileNotFoundError naming both attempted paths."""
    fake_module_path = (
        tmp_path / "orphan_home" / ".claude" / "tools" / "lib" / "schema_paths.py"
    )
    sp = _load_schema_paths_from(fake_module_path)
    with pytest.raises(FileNotFoundError) as exc_info:
        sp.schema_dir()
    msg = str(exc_info.value)
    assert ".claude/schema" in msg
    assert "core/schema" in msg


def test_schema_path_joins_filename(tmp_path: Path) -> None:
    """T-SP-4: ``schema_path(filename)`` == ``schema_dir() / filename``."""
    in_repo = tmp_path / "fake_repo" / "core" / "schema"
    in_repo.mkdir(parents=True)
    (in_repo / "execution-plan.schema.json").write_text("{}")

    fake_module_path = (
        tmp_path
        / "fake_repo"
        / "adapters"
        / "claude-code"
        / "claude"
        / "tools"
        / "lib"
        / "schema_paths.py"
    )
    sp = _load_schema_paths_from(fake_module_path)
    assert sp.schema_path("execution-plan.schema.json") == (
        sp.schema_dir() / "execution-plan.schema.json"
    )


def test_in_repo_resolution_uses_real_repo() -> None:
    """T-SP-5: real-repo smoke test — actual layout resolves correctly."""
    if str(LIB_DIR) not in sys.path:
        sys.path.insert(0, str(LIB_DIR))
    if "schema_paths" in sys.modules:
        del sys.modules["schema_paths"]
    schema_paths = importlib.import_module("schema_paths")
    sd = schema_paths.schema_dir()
    assert sd.is_dir()
    assert (sd / "execution-plan.schema.json").is_file()
