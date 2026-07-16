"""JSON Schema locator for in-repo and deployed execution contexts.

The dotfiles repo deploys the contents of ``core/schema/`` to
``~/.claude/schema/`` via ``adapters/claude-code/sync.sh restore``.
Three Python tools (``validate-plan.py``, ``validate-manifest.py``,
``grinder-audit.py``) run from both locations:

* In-repo: ``<monorepo>/adapters/claude-code/claude/tools/<tool>.py``
  → schema lives at ``<monorepo>/core/schema/<file>``.
* Deployed: ``~/.claude/tools/<tool>.py`` → schema lives at
  ``~/.claude/schema/<file>``.

This helper resolves the schema directory by probing the deployed
location first (REQ-3 edge case 3 — deployed wins) and walking
ancestors looking for ``core/schema/`` only on fallback. If neither
location exists the helper raises :class:`FileNotFoundError` with both
attempted paths in the message.

Operator note: after editing in-repo schemas, run
``bash adapters/claude-code/sync.sh restore`` before running tests
in worktrees that may load the deployed copy.
"""
from __future__ import annotations

from pathlib import Path


def _module_file() -> Path:
    return Path(__file__).resolve()


def _deployed_candidate() -> Path:
    me = _module_file()
    return me.parent.parent.parent / "schema"


def _walk_for_in_repo() -> Path | None:
    me = _module_file()
    for ancestor in me.parents:
        candidate = ancestor / "core" / "schema"
        if candidate.is_dir():
            return candidate
    return None


def schema_dir() -> Path:
    """Return the directory holding the JSON Schema files.

    Probes the deployed location first; falls back to walking ancestors
    looking for ``core/schema/``. Raises :class:`FileNotFoundError`
    naming both attempted paths if neither exists.
    """
    deployed = _deployed_candidate()
    if deployed.is_dir():
        return deployed
    in_repo = _walk_for_in_repo()
    if in_repo is not None:
        return in_repo
    raise FileNotFoundError(
        "Schema directory not found. Looked in deployed location "
        f"{deployed} and walked up from {_module_file()} looking for "
        "core/schema/ — neither resolved."
    )


def schema_path(filename: str) -> Path:
    """Return the absolute path to a schema file inside :func:`schema_dir`."""
    return schema_dir() / filename
