#!/usr/bin/env python3
"""Per-phase plan slicer (plan-ownership Track 1).

Projects ``execution-plan.yaml`` down to the consumption-table-allowed
subset for a single (task, phase) tuple, replacing direct full-file Reads
of the plan by phase agents.

Public surface
==============

Usage::

    python3 task-view.py --plan <path> --task <task-id> --phase <phase-name>

Stdout: a self-contained YAML fragment containing exactly:

  - project: <project-level fields named in plan-field-ownership.yaml
              read_scope.<phase>.project_fields>
  - phase:   <parent-phase fields per read_scope.<phase>.phase_fields>
  - task:    <the current task's block, projected to read_scope.<phase>.task_fields>
  - deps:    <dependency task blocks, each projected to {id, name, status} +
              the artifact_refs keys in read_scope.<phase>.dep_artifact_refs>
  - footer:  <a one-paragraph escape valve listing sibling task IDs and the
              command to inspect them via this same tool>

Whole-plan readers (plan-project, retro, done) bypass projection and emit
the entire plan verbatim.

Stderr: warnings (non-fatal) — e.g. missing optional fields.

Exit codes:
  0  success (the slice is on stdout)
  2  argv error (unknown phase, malformed args)
  3  plan-file read error / task-id not found

Mechanical guarantees
=====================

- Deterministic: same (plan, task, phase) inputs always produce byte-identical
  stdout. Field ordering follows the matrix declaration order.
- Sibling-task-free: for any phase NOT in the whole-plan-readers set, sibling
  task content (everything except the current task + its deps) is mechanically
  absent from the output.
- Schema 1.x plans are out of scope; the slicer requires schema_version ^2\\..

Consumed by
===========

- Phase agents (via system-prompt directive injected by
  ``run_phase`` in ``lib/claude-session-lib.sh``)
- ``hooks/plan-ownership-guard.sh`` (Track 2) — may route intercepted direct
  Reads of execution-plan.yaml through this slicer transparently in a future
  iteration
"""

from __future__ import annotations

import argparse
import sys
from collections import OrderedDict
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required (uv sync --extra dev installs it)", file=sys.stderr)
    sys.exit(3)


# ─── Defaults for whole-plan readers ────────────────────────────────────────
WHOLE_PLAN_READERS = frozenset({"plan-project", "retro", "done"})


def _load_matrix(repo_root: Path) -> dict:
    """Load core/schema/plan-field-ownership.yaml.

    The matrix is the single source of truth for per-phase read scope.
    """
    matrix_path = repo_root / "core" / "schema" / "plan-field-ownership.yaml"
    if not matrix_path.exists():
        # Fallback: search upward from the script location
        here = Path(__file__).resolve()
        for parent in here.parents:
            candidate = parent / "core" / "schema" / "plan-field-ownership.yaml"
            if candidate.exists():
                matrix_path = candidate
                break
    if not matrix_path.exists():
        print(
            f"ERROR: plan-field-ownership.yaml not found (searched {matrix_path})",
            file=sys.stderr,
        )
        sys.exit(3)
    try:
        with open(matrix_path) as f:
            return yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        print(f"ERROR: cannot read ownership matrix at {matrix_path}: {e}", file=sys.stderr)
        sys.exit(3)


def _load_plan(plan_path: Path) -> dict:
    if not plan_path.exists():
        print(f"ERROR: plan not found at {plan_path}", file=sys.stderr)
        sys.exit(3)
    try:
        with open(plan_path) as f:
            return yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        print(f"ERROR: cannot read plan at {plan_path}: {e}", file=sys.stderr)
        sys.exit(3)


def _find_task(plan: dict, task_id: str) -> tuple[dict | None, dict | None]:
    """Return (phase, task) blocks for the given task_id, or (None, None)."""
    for phase in plan.get("phases", []) or []:
        for task in phase.get("tasks", []) or []:
            if task.get("id") == task_id:
                return phase, task
    return None, None


def _project_fields(source: dict, fields: list[str]) -> OrderedDict[str, object]:
    """Return an OrderedDict with the named fields, preserving declaration order.

    Missing fields are silently skipped (not all phases populate every field).
    """
    out: OrderedDict[str, object] = OrderedDict()
    for field in fields:
        if field in source:
            out[field] = source[field]
    return out


def _project_dep(dep_task: dict, artifact_keys: list[str]) -> dict:
    """Project a dependency task to its identity + the artifact_refs the
    consuming phase is allowed to read.
    """
    out: OrderedDict[str, object] = OrderedDict()
    out["id"] = dep_task.get("id")
    out["name"] = dep_task.get("name")
    out["status"] = dep_task.get("status")
    if artifact_keys:
        refs = dep_task.get("artifact_refs") or {}
        selected = OrderedDict()
        for key in artifact_keys:
            if key in refs:
                selected[key] = refs[key]
        if selected:
            out["artifact_refs"] = selected
    return out


def _emit(data: OrderedDict[str, object]) -> str:
    """YAML-dump with stable key order (no sorting)."""
    return yaml.safe_dump(
        _to_plain(data),
        sort_keys=False,
        default_flow_style=False,
        width=100,
        allow_unicode=True,
    )


def _to_plain(obj: object) -> object:
    """Convert OrderedDict to plain dict for PyYAML — yaml.safe_dump prefers it."""
    if isinstance(obj, OrderedDict):
        return {k: _to_plain(v) for k, v in obj.items()}
    if isinstance(obj, dict):
        return {k: _to_plain(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_to_plain(x) for x in obj]
    return obj


def _all_task_ids(plan: dict) -> list[str]:
    out: list[str] = []
    for phase in plan.get("phases", []) or []:
        for task in phase.get("tasks", []) or []:
            tid = task.get("id")
            if tid:
                out.append(tid)
    return out


def slice_for(
    plan: dict,
    matrix: dict,
    task_id: str,
    phase_name: str,
) -> str:
    """Compute the per-(task, phase) slice as a YAML string."""

    read_scope = (matrix or {}).get("read_scope") or {}

    # Whole-plan readers: emit verbatim, no projection
    if phase_name in WHOLE_PLAN_READERS:
        return _emit(_to_plain(plan))  # type: ignore[arg-type]

    if phase_name not in read_scope:
        print(
            f"ERROR: unknown phase '{phase_name}'. Valid phases:\n  "
            + ", ".join(sorted(set(read_scope) | WHOLE_PLAN_READERS)),
            file=sys.stderr,
        )
        sys.exit(2)

    parent_phase, task = _find_task(plan, task_id)
    if task is None or parent_phase is None:
        print(
            f"ERROR: task-id '{task_id}' not found in plan. Available: "
            + ", ".join(_all_task_ids(plan)[:20])
            + ("..." if len(_all_task_ids(plan)) > 20 else ""),
            file=sys.stderr,
        )
        sys.exit(3)

    profile = read_scope[phase_name] or {}
    project_fields = profile.get("project_fields") or []
    phase_fields = profile.get("phase_fields") or []
    task_fields = profile.get("task_fields") or []
    dep_artifact_keys = profile.get("dep_artifact_refs") or []

    # Build the output structure
    output: OrderedDict[str, object] = OrderedDict()

    # project block
    project_block = _project_fields(plan, project_fields)
    if project_block:
        output["project"] = project_block

    # phase block (parent phase of the current task)
    phase_block = _project_fields(parent_phase, phase_fields)
    if phase_block:
        output["phase"] = phase_block

    # task block (current task, projected)
    task_block = _project_fields(task, task_fields)
    output["task"] = task_block

    # deps block
    deps_ids = task.get("depends") or []
    if deps_ids and dep_artifact_keys is not None:
        deps_out = []
        for dep_id in deps_ids:
            _, dep_task = _find_task(plan, dep_id)
            if dep_task is None:
                print(f"WARN: dependency '{dep_id}' not found in plan", file=sys.stderr)
                continue
            deps_out.append(_project_dep(dep_task, dep_artifact_keys))
        if deps_out:
            output["deps"] = deps_out

    return _emit(output)


def _footer_text(plan: dict, current_task_id: str, phase_name: str, plan_path: str) -> str:
    """Operator/agent escape-valve footer.

    Lists sibling task IDs so the agent can re-invoke task-view.py with a
    different --task if it genuinely needs another task's context. Avoids
    forcing the agent into a corner where it can't see anything else.
    """
    sibling_ids = [tid for tid in _all_task_ids(plan) if tid != current_task_id]
    lines = [
        "",
        f"# --- task-view footer (phase={phase_name}) ---",
        f"# To view another task: python3 task-view.py --plan {plan_path}"
        f" --task <id> --phase {phase_name}",
        "# Sibling task IDs in this plan:",
    ]
    for tid in sibling_ids:
        lines.append(f"#   - {tid}")
    if not sibling_ids:
        lines.append("#   (none)")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="task-view.py",
        description="Per-phase plan slicer (plan-ownership Track 1).",
    )
    ap.add_argument("--plan", required=True, help="path to execution-plan.yaml")
    ap.add_argument("--task", required=True, help="task id to focus on")
    ap.add_argument(
        "--phase",
        required=True,
        help="phase name (e.g. ba, plan, implement, static-analysis, qa, ...)",
    )
    ap.add_argument(
        "--repo-root",
        default=None,
        help="repo root for locating plan-field-ownership.yaml (auto-detected if omitted)",
    )
    args = ap.parse_args(argv)

    plan_path = Path(args.plan).expanduser().resolve()
    if args.repo_root:
        repo_root = Path(args.repo_root).expanduser().resolve()
    else:
        # Walk up from plan_path looking for core/schema/plan-field-ownership.yaml
        repo_root = plan_path.parent
        while repo_root != repo_root.parent:
            if (repo_root / "core" / "schema" / "plan-field-ownership.yaml").exists():
                break
            repo_root = repo_root.parent
        else:
            # Fall back to the script's repo root walk
            here = Path(__file__).resolve()
            for parent in here.parents:
                if (parent / "core" / "schema" / "plan-field-ownership.yaml").exists():
                    repo_root = parent
                    break

    plan = _load_plan(plan_path)
    matrix = _load_matrix(repo_root)

    out = slice_for(plan, matrix, args.task, args.phase)
    sys.stdout.write(out)
    sys.stdout.write(_footer_text(plan, args.task, args.phase, str(plan_path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
