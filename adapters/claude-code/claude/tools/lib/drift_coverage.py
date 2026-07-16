"""Drift-coverage helper for R40.

Computes what fraction of files declared in ``task.where.modify[]`` and
``task.where.create[]`` (across all tasks of all phases) are covered by
a given set of touched files (e.g. from ``git diff --name-only``).

Public API
----------
compute_drift_coverage(declared_paths, touched_files)
    -> tuple[float, bool]

``declared_paths``  — iterable of path strings from where.modify ∪ where.create
``touched_files``   — iterable of path strings actually touched on the branch
Returns ``(coverage_pct, passed)`` where:
  - ``coverage_pct`` is 0.0–100.0 (percentage of declared covered by touched)
  - ``passed``  is True iff coverage_pct >= DRIFT_COVERAGE_THRESHOLD

Edge cases
----------
- Empty declared_paths and empty touched_files → 100.0, True  (vacuous pass)
- Empty declared_paths with non-empty touched → 100.0, True  (nothing to cover)
"""
from __future__ import annotations

# Minimum acceptable drift coverage (R40).
DRIFT_COVERAGE_THRESHOLD = 80.0


def compute_drift_coverage(
    declared_paths: list[str],
    touched_files: list[str],
) -> tuple[float, bool]:
    """Return ``(coverage_pct, passed)`` for the given declared/touched sets.

    ``coverage_pct`` is the percentage of declared paths that appear in
    ``touched_files``.  The comparison is normalised: leading ``./`` is
    stripped and paths are compared as-is (no filesystem resolution, so
    tests stay hermetic).
    """
    def _norm(p: str) -> str:
        return p.lstrip("./").rstrip("/")

    declared = [_norm(p) for p in declared_paths if p]
    touched = {_norm(p) for p in touched_files if p}

    if not declared:
        # Nothing declared → vacuous pass (100%).
        return 100.0, True

    covered = sum(1 for p in declared if p in touched)
    coverage_pct = covered / len(declared) * 100.0
    passed = coverage_pct >= DRIFT_COVERAGE_THRESHOLD
    return coverage_pct, passed
