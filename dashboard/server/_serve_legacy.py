"""Holding pen for the 17 symbols ``routes/api.py`` used to import from
``dashboard.serve``.

Created at fastapi-cutover (T0.3): the launcher swaps from stdlib
``http.server`` to uvicorn, the body of ``dashboard/serve.py`` is replaced
by a tombstone, and the constants/validators/worktree helpers
``routes/api.py`` consumes are moved here verbatim. No behaviour changes —
this is a cut-paste move so the cutover diff stays focused on the launcher
swap.

The module is intentionally not single-responsibility (constants +
validators + worktree probing live side by side). A SOLID-clean split into
three modules is tracked as a ``deferred[]`` ``future_enhancement`` entry
on the host execution plan; see PLAN OQ-B.
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
from pathlib import Path

from dashboard.server.validation import SAFE_ID_REGEX as _RE_SAFE_ID

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Shared constants (S1192) — the literal error strings stdlib used to raise.
# The safe-identifier regex is owned by dashboard/server/validation.py and
# re-exported as _RE_SAFE_ID above so every consumer (routes/api.py,
# tmux_session.py, the legacy identity-equality tests) binds the same
# string object (PLAN.md C-3 / R4). The cap is `{1,64}` — DN-12 of the
# host plan poc-watchfloor-autopilot-control.
# ---------------------------------------------------------------------------


_WORKTREE_PREFIX = "worktree "
_ERR_MISSING_TASK = "Missing task parameter"
_ERR_INVALID_TASK = "Invalid task parameter"
_ERR_INVALID_OFFSET = "Invalid offset parameter"
_ERR_INVALID_FILE = "Invalid file parameter"
_ERR_ARTIFACT_NOT_FOUND = "Artifact not found"
_ERR_MISSING_CWD = "Missing cwd parameter"
_ERR_GRINDER_NOT_FOUND = "Project not found or has no grinder data"
_ERR_INVALID_PROJECT = "Missing or invalid project parameter"


# ---------------------------------------------------------------------------
# Worktree probing — used by detect_flow_status / get_all_worktrees /
# get_main_worktree below.
# ---------------------------------------------------------------------------


def get_main_worktree(cwd):
    """Given a cwd, resolve the main (first) worktree root for that repo."""
    if not cwd or not os.path.isabs(cwd) or ".." in cwd:
        return None
    resolved = Path(cwd).resolve()
    if not resolved.is_dir():
        return None
    home = Path.home()
    if not str(resolved).startswith(str(home) + "/") and str(resolved) != str(home):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", str(resolved), "worktree", "list", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if line.startswith(_WORKTREE_PREFIX):
                    return line[len(_WORKTREE_PREFIX) :]
    except Exception:
        pass
    return None


def _scan_docs_dir(docs_dir):
    """Scan a single docs/ directory for feature/plan status entries."""
    results = []
    if not docs_dir.is_dir():
        return results
    try:
        for entry in docs_dir.iterdir():
            if not entry.is_dir():
                continue
            name = entry.name
            if name.startswith("."):
                continue
            if name.startswith("DONE_Feature_"):
                feature = name[13:]
                phase = "done"
            elif name.startswith("DONE_Plan_"):
                feature = name[10:]
                phase = "done"
            elif name.startswith("INPROGRESS_Feature_"):
                feature = name[19:]
                phase = _detect_phase(entry)
            elif name.startswith("INPROGRESS_Plan_"):
                feature = name[16:]
                phase = _detect_phase(entry)
            elif name.startswith("PENDING_Feature_"):
                feature = name[16:]
                phase = "pending"
            elif name.startswith("PENDING_Plan_"):
                feature = name[13:]
                phase = "pending"
            else:
                continue
            results.append({"feature": feature, "phase": phase, "dir": name})
    except Exception:
        pass
    return results


def _validate_cwd_path(cwd):
    """Validate cwd is a safe, existing directory under home. Returns resolved Path or None."""
    if not cwd or not os.path.isabs(cwd) or ".." in cwd:
        return None
    resolved = Path(cwd).resolve()
    if not resolved.is_dir():
        return None
    home = Path.home()
    if not str(resolved).startswith(str(home) + "/") and str(resolved) != str(home):
        return None
    return resolved


def _collect_worktree_roots(resolved):
    """Collect all worktree roots for the git repo at resolved path."""
    roots = {str(resolved)}
    try:
        proc = subprocess.run(
            ["git", "-C", str(resolved), "worktree", "list", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                if line.startswith(_WORKTREE_PREFIX):
                    wt = line[len(_WORKTREE_PREFIX) :]
                    if Path(wt).is_dir():
                        roots.add(wt)
    except Exception:
        pass
    return roots


def detect_flow_status(cwd):
    """Detect flow phase for all features across a repo's worktrees.

    Scans docs/ in the given CWD and all sibling worktrees so that
    features in progress on worktree branches are visible from main.
    """
    resolved = _validate_cwd_path(cwd)
    if not resolved:
        return []

    worktree_roots = _collect_worktree_roots(resolved)

    seen = {}
    for root in sorted(worktree_roots):
        docs_dir = Path(root) / "docs"
        for entry in _scan_docs_dir(docs_dir):
            feat = entry["feature"]
            if feat not in seen or entry["phase"] not in ("done", "pending"):
                seen[feat] = entry

    return list(seen.values())


def _detect_phase(docs_feature_dir):
    """Determine flow phase from which files exist in docs/<feature>/."""
    has = set()
    try:
        for f in docs_feature_dir.iterdir():
            has.add(f.name)
    except Exception:
        return "unknown"
    if "QA_REPORT.md" in has or "TEAM_QA.md" in has:
        return "qa"
    if "MANUAL_TEST_LOG.md" in has:
        return "manualtest"
    if "TESTPLAN.md" in has:
        return "implement"
    if "TEAM_REVIEW.md" in has:
        return "review"
    if "PLAN.md" in has:
        return "plan"
    if "DESIGN.md" in has:
        return "design"
    if "REQUIREMENTS.md" in has:
        return "ba"
    return "unknown"


def _parse_worktree_porcelain(output):
    """Parse git worktree list --porcelain output into list of {path, branch}."""
    worktrees = []
    current = {}
    for line in output.splitlines():
        if line.startswith(_WORKTREE_PREFIX):
            if current and "path" in current:
                worktrees.append(current)
            current = {"path": line[len(_WORKTREE_PREFIX) :]}
        elif line.startswith("branch ") and current:
            current["branch"] = line[len("branch ") :].rsplit("/", 1)[-1]
    if current and "path" in current:
        worktrees.append(current)
    return worktrees


def get_all_worktrees(cwd):
    """Return list of {path, branch} for all worktrees in the repo."""
    resolved = _validate_cwd_path(cwd)
    if not resolved:
        return []
    try:
        result = subprocess.run(
            ["git", "-C", str(resolved), "worktree", "list", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return []
        return _parse_worktree_porcelain(result.stdout)
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Validators consumed directly by routes/api.py.
# ---------------------------------------------------------------------------


def _validate_cwd_param(cwd):
    """Validate a cwd parameter for security. Returns None if invalid."""
    if not cwd or not os.path.isabs(cwd) or ".." in cwd:
        return None
    resolved = Path(cwd).resolve()
    if not resolved.is_dir():
        return None
    home = Path.home()
    if not str(resolved).startswith(str(home) + "/") and str(resolved) != str(home):
        return None
    return str(resolved)


def _validate_artifact_filename(filename, *, descended, allowed):
    """Return True if filename is acceptable for artifact lookup.

    Descended paths (task-scoped, contains "/") must have an allowed basename
    and must not contain any path component that is exactly "..".
    Non-descended paths must be a bare allowed filename with no traversal.
    """
    if descended:
        if any(part == ".." for part in Path(filename).parts):
            return False
        return Path(filename).name in allowed
    if ".." in filename or "/" in filename:
        return False
    return filename in allowed


def _validate_project_name(name):
    """Validate a project name parameter. Returns True if valid."""
    if not name:
        return False
    return bool(re.match(_RE_SAFE_ID, name))


def _resolve_project_root(name):
    """Map project name to validated path within known roots. Returns path or None."""
    from dashboard.server.autopilot_helpers import _get_all_project_roots

    for root in _get_all_project_roots():
        if Path(root).name == name:
            grinder_dir = Path(root) / "docs" / "grinder"
            if grinder_dir.is_dir():
                return root
    return None
