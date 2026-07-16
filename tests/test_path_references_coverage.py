"""Direct unit tests for the path-references-update (T3) modifications.

These tests import the affected modules in-process so coverage.py records
the new lines added on this branch — the existing subprocess-based tests
in test_grinder_audit.py exercise the same code but coverage.py cannot
see across the subprocess boundary.

Lines targeted (from `git diff main` + coverage.xml diff):

* `lib/schema_paths.py` — lines 43, 55, 59, 68 (negative-walk return,
  deployed-wins return, FileNotFoundError raise, schema_path join).
* `validate-plan.py` — lines 51-52 (load_schema body using schema_paths).
* `validate-manifest.py` — line 25 (sys.path insert), 233 (schema_path
  call inside main()).
* `grinder-audit.py` — lines 26-30 (sys.path insert + import),
  37-38 (_schema_path helper), 175-181 (validate_entries schema lookup).
"""
from __future__ import annotations

import importlib
import importlib.util
import sys
from pathlib import Path

import pytest

from conftest import REPO_ROOT, SCHEMA_DIR, import_tool

LIB_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib"


@pytest.fixture(autouse=True)
def _ensure_lib_on_path():
    """Make ``schema_paths`` importable for tests that load it directly."""
    if str(LIB_DIR) not in sys.path:
        sys.path.insert(0, str(LIB_DIR))
    yield


# ---------------------------------------------------------------------------
# schema_paths.py — direct coverage of the four uncovered branches.
# ---------------------------------------------------------------------------


def _fresh_schema_paths():
    """Reload schema_paths from its real on-disk location."""
    if "schema_paths" in sys.modules:
        del sys.modules["schema_paths"]
    return importlib.import_module("schema_paths")


def test_schema_path_joins_filename() -> None:
    """Covers schema_paths.py line 68 — schema_path() returns schema_dir() / filename."""
    sp = _fresh_schema_paths()
    result = sp.schema_path("execution-plan.schema.json")
    assert result == sp.schema_dir() / "execution-plan.schema.json"
    assert result.is_file()


def test_walk_for_in_repo_returns_none_when_no_ancestor_has_core_schema(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Covers schema_paths.py line 43 — _walk_for_in_repo returns None on miss."""
    sp = _fresh_schema_paths()
    orphan = tmp_path / "orphan" / "lib" / "schema_paths.py"
    orphan.parent.mkdir(parents=True)
    orphan.write_text("# placeholder")
    monkeypatch.setattr(sp, "_module_file", lambda: orphan)
    assert sp._walk_for_in_repo() is None


def test_schema_dir_returns_deployed_when_present(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Covers schema_paths.py line 55 — deployed branch returns first."""
    sp = _fresh_schema_paths()
    deployed = tmp_path / "deployed" / "schema"
    deployed.mkdir(parents=True)
    monkeypatch.setattr(sp, "_deployed_candidate", lambda: deployed)
    assert sp.schema_dir() == deployed


def test_schema_dir_raises_with_both_paths_in_message(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Covers schema_paths.py line 59 — FileNotFoundError raised, both paths named."""
    sp = _fresh_schema_paths()
    fake_deployed = tmp_path / "no-deployed" / "schema"
    fake_module = tmp_path / "orphan" / "schema_paths.py"
    fake_module.parent.mkdir(parents=True)
    fake_module.write_text("# placeholder")
    monkeypatch.setattr(sp, "_deployed_candidate", lambda: fake_deployed)
    monkeypatch.setattr(sp, "_module_file", lambda: fake_module)
    with pytest.raises(FileNotFoundError) as exc_info:
        sp.schema_dir()
    msg = str(exc_info.value)
    assert str(fake_deployed) in msg
    assert "core/schema/" in msg


# ---------------------------------------------------------------------------
# validate-plan.py — exercise load_schema() against the real schema.
# ---------------------------------------------------------------------------


def test_validate_plan_load_schema_returns_dict() -> None:
    """Covers validate-plan.py lines 51-52 — load_schema reads the JSON file."""
    mod = import_tool("validate-plan.py")
    schema = mod.load_schema()
    assert isinstance(schema, dict)
    assert "$id" in schema or "$schema" in schema or "properties" in schema


# ---------------------------------------------------------------------------
# validate-manifest.py — exercise main() schema_path lookup via parse path.
# ---------------------------------------------------------------------------


def test_validate_manifest_module_imports_schema_paths() -> None:
    """Covers validate-manifest.py line 25 (sys.path insert) plus the schema_paths import."""
    mod = import_tool("validate-manifest.py")
    assert hasattr(mod, "schema_paths")
    assert mod.schema_paths.schema_path("manifest.schema.json").is_file()


def test_validate_manifest_main_resolves_schema(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Covers validate-manifest.py line 233 — schema_path call inside main().

    The line under test is ``schema_path = schema_paths.schema_path("manifest.schema.json")``.
    Reaching it requires main() to advance past the early --parse-grinder branch
    and parse_grinder_block() — we feed the repo's own pipeline.yaml so the
    structural validation succeeds without needing to maintain a fake fixture.
    """
    mod = import_tool("validate-manifest.py")
    pipeline_yaml = REPO_ROOT / "pipeline.yaml"
    monkeypatch.setattr(sys, "argv", ["validate-manifest.py", str(pipeline_yaml)])
    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0
    out = capsys.readouterr().out
    assert "Valid" in out


# ---------------------------------------------------------------------------
# grinder-audit.py — module-level imports + _schema_path + validate_entries.
# ---------------------------------------------------------------------------


def test_grinder_audit_module_imports_schema_paths() -> None:
    """Covers grinder-audit.py lines 26-30 (sys.path insert + import schema_paths)."""
    mod = import_tool("grinder-audit.py")
    assert hasattr(mod, "schema_paths")
    assert hasattr(mod, "_schema_path")


def test_grinder_audit_schema_path_helper_returns_real_file() -> None:
    """Covers grinder-audit.py lines 37-38 — _schema_path resolves to real schema."""
    mod = import_tool("grinder-audit.py")
    p = mod._schema_path()
    assert p == SCHEMA_DIR / "deferred-findings.schema.json"
    assert p.is_file()


def test_grinder_audit_validate_entries_with_valid_entry_returns_no_warnings() -> None:
    """Covers grinder-audit.py lines 175-176, 179-181 — schema lookup + validation success path."""
    mod = import_tool("grinder-audit.py")
    valid_entry = {
        "finding_id": "shellcheck:SC2086-tools/foo.sh-abcd1234",
        "rule": "SC2086",
        "file": "tools/foo.sh",
        "line": 42,
        "state": "Deferred",
        "reason": (
            "This finding is deferred because the variable is always set "
            "by the caller and quoting would break the glob"
        ),
        "owner": "tomas",
        "reviewed_at": "2026-04-01",
    }
    warnings = mod.validate_entries([valid_entry])
    assert warnings == []


def test_grinder_audit_validate_entries_handles_missing_schema(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Covers grinder-audit.py lines 177-178 — FileNotFoundError silent-skip path."""
    mod = import_tool("grinder-audit.py")

    def _raise_missing() -> Path:
        raise FileNotFoundError("synthetic — schema dir missing")

    monkeypatch.setattr(mod, "_schema_path", _raise_missing)
    warnings = mod.validate_entries([{"any": "entry"}])
    assert warnings == []
