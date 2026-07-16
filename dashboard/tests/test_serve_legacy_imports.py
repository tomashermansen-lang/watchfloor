"""Smoke tests for ``dashboard.server._serve_legacy``.

The module is the post-cutover holding pen for the 17 symbols
``dashboard.server.routes.api`` imports today from ``dashboard.serve``. This
suite verifies (a) every name imports cleanly, (b) ``routes/api.py`` has been
flipped to the new source, (c) the validators behave as before, and (d) the
module is import-side-effect-free beyond the standard ``logger`` initialisation.

Trace: TESTPLAN § Coverage Matrix C2-01..C2-09; PLAN component C2; Risk-D
commit ordering — these tests must land and pass GREEN BEFORE C3 tombstones
``serve.py``.
"""

from __future__ import annotations

import logging
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]


# C2-01 — every name imports.
def test_all_seventeen_symbols_import() -> None:
    from dashboard.server._serve_legacy import (  # noqa: F401
        _ERR_ARTIFACT_NOT_FOUND,
        _ERR_GRINDER_NOT_FOUND,
        _ERR_INVALID_FILE,
        _ERR_INVALID_OFFSET,
        _ERR_INVALID_PROJECT,
        _ERR_INVALID_TASK,
        _ERR_MISSING_CWD,
        _ERR_MISSING_TASK,
        _RE_SAFE_ID,
        _resolve_project_root,
        _validate_artifact_filename,
        _validate_cwd_param,
        _validate_project_name,
        detect_flow_status,
        get_all_worktrees,
        get_main_worktree,
        logger,
    )


# C2-02 — routes/api.py imports point at _serve_legacy in a clean interpreter.
def test_routes_api_imports_resolve_to_serve_legacy() -> None:
    probe = (
        "import sys; "
        "import dashboard.server.routes.api as routes_api; "
        "import inspect; "
        "src = inspect.getsourcefile(routes_api._validate_cwd_param); "
        "assert src is not None and src.endswith('_serve_legacy.py'), src; "
        "assert 'dashboard.serve' not in sys.modules, list(sys.modules)"
    )
    subprocess.run(
        [sys.executable, "-c", probe],
        check=True,
        cwd=str(REPO_ROOT),
    )


# C2-03 — _validate_cwd_param accepts a normal home-relative path.
def test_validate_cwd_param_accepts_home_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from dashboard.server._serve_legacy import _validate_cwd_param

    monkeypatch.setattr(
        "dashboard.server._serve_legacy.Path.home", classmethod(lambda cls: tmp_path)
    )
    target = tmp_path / "projx"
    target.mkdir()
    assert _validate_cwd_param(str(target)) == str(target)


# C2-04 — _validate_cwd_param rejects path-traversal payload.
def test_validate_cwd_param_rejects_traversal() -> None:
    from dashboard.server._serve_legacy import _validate_cwd_param

    assert _validate_cwd_param("/tmp/../etc") is None
    assert _validate_cwd_param("") is None
    assert _validate_cwd_param("relative/path") is None


# C2-05 — _validate_artifact_filename rejects ".." segments.
def test_validate_artifact_filename_rejects_traversal() -> None:
    from dashboard.server._serve_legacy import _validate_artifact_filename

    allowed = {"PLAN.md", "REQUIREMENTS.md"}
    assert _validate_artifact_filename("../etc/passwd", descended=False, allowed=allowed) is False
    assert _validate_artifact_filename("../PLAN.md", descended=True, allowed=allowed) is False
    assert _validate_artifact_filename("PLAN.md", descended=False, allowed=allowed) is True


# C2-06 — _RE_SAFE_ID matches valid IDs and rejects shell metacharacters.
# After the R4 extraction the regex is length-capped at 64 chars; cap and
# empty-string rejection are tested here so future drift breaks the build.
def test_re_safe_id_pattern() -> None:
    import re

    from dashboard.server._serve_legacy import _RE_SAFE_ID

    assert re.match(_RE_SAFE_ID, "task-01")
    assert re.match(_RE_SAFE_ID, "feature_one")
    assert re.match(_RE_SAFE_ID, "a" * 64)
    assert not re.match(_RE_SAFE_ID, "task; rm -rf /")
    assert not re.match(_RE_SAFE_ID, "task/sub")
    assert not re.match(_RE_SAFE_ID, "a" * 65)
    assert not re.match(_RE_SAFE_ID, "")


# C2-06b — _RE_SAFE_ID is the same object as validation.SAFE_ID_REGEX
# (R4 — identity-equality contract relies on shared import binding, not
# on CPython string interning).
def test_re_safe_id_is_validation_safe_id_regex() -> None:
    from dashboard.server import _serve_legacy, validation

    assert _serve_legacy._RE_SAFE_ID is validation.SAFE_ID_REGEX


# C2-07 — detect_flow_status / worktree helpers still callable (existing
# test_routes_api.py monkeypatches the names imported into routes_api; this
# row only proves the underlying definitions still answer when called directly).
def test_detect_flow_status_and_worktree_helpers_callable() -> None:
    from dashboard.server import _serve_legacy

    assert callable(_serve_legacy.detect_flow_status)
    assert callable(_serve_legacy.get_all_worktrees)
    assert callable(_serve_legacy.get_main_worktree)
    # Empty / invalid inputs return empty containers — no exceptions.
    assert _serve_legacy.detect_flow_status("") == []
    assert _serve_legacy.get_all_worktrees("") == []
    assert _serve_legacy.get_main_worktree("") is None


# C2-08 — logger has the expected qualified name.
def test_logger_name() -> None:
    from dashboard.server._serve_legacy import logger

    assert isinstance(logger, logging.Logger)
    assert logger.name == "dashboard.server._serve_legacy"


# C2-09 — module body has no side effects beyond logger initialisation.
def test_module_import_has_no_side_effect_output() -> None:
    result = subprocess.run(
        [sys.executable, "-c", "import dashboard.server._serve_legacy"],
        check=True,
        capture_output=True,
        cwd=str(REPO_ROOT),
    )
    assert result.stdout == b""
    assert result.stderr == b""
