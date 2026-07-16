#!/usr/bin/env python3
"""Compose compact predecessor context for a downstream task (backlog #64).

For each dependency in the task's `depends` list, emit a per-dependency
block tuned to the consuming phase:

  /ba          decision shadow only (constraints + contract)
  /plan        decision shadow + interfaces + diff stat
  /testplan    tests_added + interfaces
  /implement   full diff (with code) + interfaces + decision shadow
  /review      decision shadow + interfaces
  /qa          interfaces + tests_added

Backward-compat: if a dependency has no `codebase_snapshot` /
`predecessor_context` yet (older completed task), fall back to the
existing artifact-read behavior path so callers can incrementally migrate.

Usage:
  python3 predecessor-context.py --plan <execution-plan.yaml> \\
                                 --task <task-id> \\
                                 --phase <ba|plan|testplan|implement|review|qa> \\
                                 [--max-lines-per-dep N] \\
                                 [--repo-root <path>]

Stdout: a single text block ready to splice into a phase prompt.
Stderr: warnings about fallback / missing data (non-fatal).
Exit:   0 on success (including empty output when task has no deps)
        2 on argv error (unknown phase)
        3 on plan-file read error / task not found
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required (uv sync --extra dev installs it)", file=sys.stderr)
    sys.exit(3)

PHASE_PROFILES = {
    "ba":         {"shadow": True,  "interfaces": False, "tests": False, "diff_stat": False, "diff_full": False, "symbol_map": False},
    "plan":       {"shadow": True,  "interfaces": True,  "tests": False, "diff_stat": True,  "diff_full": False, "symbol_map": True},
    "testplan":   {"shadow": False, "interfaces": True,  "tests": True,  "diff_stat": False, "diff_full": False, "symbol_map": False},
    "implement":  {"shadow": True,  "interfaces": True,  "tests": False, "diff_stat": True,  "diff_full": True,  "symbol_map": True},
    "review":     {"shadow": True,  "interfaces": True,  "tests": False, "diff_stat": True,  "diff_full": False, "symbol_map": True},
    "qa":         {"shadow": False, "interfaces": True,  "tests": True,  "diff_stat": False, "diff_full": False, "symbol_map": False},
    "team-review": {"shadow": True,  "interfaces": True,  "tests": False, "diff_stat": True,  "diff_full": False, "symbol_map": True},
    "team-qa":     {"shadow": False, "interfaces": True,  "tests": True,  "diff_stat": False, "diff_full": False, "symbol_map": False},
}

# Symbol-map cap: per the canary measurements, the agent's bottleneck on
# autopilot.sh-class files is discovery, not raw symbol count. Cap at 60
# entries per file so a 200-function file doesn't drown the prompt.
_SYMBOL_MAP_MAX_PER_FILE = 60


def _load_plan(path: Path) -> dict:
    try:
        with open(path) as f:
            return yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        print(f"ERROR: cannot read plan at {path}: {e}", file=sys.stderr)
        sys.exit(3)


def _find_task(plan: dict, task_id: str) -> dict | None:
    for phase in plan.get("phases", []) or []:
        for task in phase.get("tasks", []) or []:
            if task.get("id") == task_id:
                return task
    return None


def _git_show_commit(commit_ref: str, repo_root: Path) -> tuple[str, str]:
    """Return (diff_stat, full_diff) for the commit. Empty strings on failure."""
    if not commit_ref:
        return "", ""
    try:
        stat = subprocess.run(
            ["git", "-C", str(repo_root), "show", "--stat", "--format=", commit_ref],
            capture_output=True, text=True, timeout=10,
        )
        full = subprocess.run(
            ["git", "-C", str(repo_root), "show", "--format=", commit_ref, "--", ":!docs/"],
            capture_output=True, text=True, timeout=15,
        )
        return stat.stdout.strip(), full.stdout
    except (subprocess.SubprocessError, OSError) as e:
        print(f"WARN: git show failed for {commit_ref}: {e}", file=sys.stderr)
        return "", ""


def _truncate_block(text: str, max_lines: int) -> str:
    lines = text.splitlines()
    if len(lines) <= max_lines:
        return text
    truncated = "\n".join(lines[:max_lines])
    return f"{truncated}\n... [{len(lines) - max_lines} more lines truncated]"


def _format_shadow(pc: dict, max_lines: int) -> list[str]:
    out = []
    for field in ("constraints", "rejected", "contract"):
        val = (pc.get(field) or "").strip()
        if not val:
            continue
        out.append(f"  {field}:")
        for line in _truncate_block(val, max_lines).splitlines():
            out.append(f"    {line}")
    return out


def _format_interfaces(cs: dict) -> list[str]:
    interfaces = cs.get("interfaces_introduced", []) or []
    if not interfaces:
        return []
    out = ["  interfaces:"]
    for i in interfaces:
        name = i.get("name", "?")
        defined_in = i.get("defined_in", "?")
        sig = i.get("signature", "")
        if sig:
            out.append(f"    - {name} ({defined_in}): {sig}")
        else:
            out.append(f"    - {name} ({defined_in})")
    return out


def _format_modules(cs: dict) -> list[str]:
    mods = cs.get("modules_changed", []) or []
    if not mods:
        return []
    out = ["  modules_changed:"]
    for m in mods:
        path = m.get("path", "?")
        role = m.get("role", "")
        lines = m.get("lines")
        line_part = f" (+{lines})" if lines else ""
        if role:
            out.append(f"    - {path}{line_part}: {role}")
        else:
            out.append(f"    - {path}{line_part}")
    return out


def _format_tests(cs: dict) -> list[str]:
    tests = cs.get("tests_added", []) or []
    if not tests:
        return []
    return ["  tests_added:"] + [f"    - {t}" for t in tests]


def _format_symbol_map(cs: dict, repo_root: Path) -> list[str]:
    """Emit a per-file symbol map for files in modules_changed.

    Two sources, in order:
      1. cs["symbol_map"] — pre-extracted, persisted by /done at task
         completion (preferred — zero subprocess cost at compose time).
      2. On-the-fly extraction via lib/extract_symbols.py for any file
         in modules_changed that has no entry in cs["symbol_map"]
         (backward-compat for done tasks pre-symbol-map).

    Files that don't exist (e.g. moved, renamed, archived) are silently
    skipped — the map is best-effort.
    """
    mods = cs.get("modules_changed", []) or []
    if not mods:
        return []
    persisted = cs.get("symbol_map") or {}

    out: list[str] = []
    for m in mods:
        path = m.get("path")
        if not path:
            continue
        syms = persisted.get(path)
        if syms is None:
            syms = _extract_symbols_now(repo_root / path)
        if not syms:
            continue
        out.append(f"  symbols [{path}]:")
        for s in syms[:_SYMBOL_MAP_MAX_PER_FILE]:
            line_start = s.get("line_start", "?")
            line_end = s.get("line_end", line_start)
            kind = s.get("kind", "?")
            name = s.get("name", "?")
            out.append(f"    L{line_start}-{line_end}  {kind:8} {name}")
        if len(syms) > _SYMBOL_MAP_MAX_PER_FILE:
            out.append(f"    ... [{len(syms) - _SYMBOL_MAP_MAX_PER_FILE} more symbols truncated]")
    return out


def _extract_symbols_now(file_path: Path) -> list[dict]:
    """Subprocess-call extract_symbols.py so we don't import-couple this
    helper to the lib module. Cheap (one process per dep file) and
    isolates the agent from any extractor bugs."""
    import subprocess
    extractor = Path(__file__).resolve().parent / "lib" / "extract_symbols.py"
    if not extractor.exists() or not file_path.exists():
        return []
    try:
        result = subprocess.run(
            ["python3", str(extractor), str(file_path)],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return []
        import json
        parsed = json.loads(result.stdout or "[]")
        # Defensive isinstance check: extractor contract is a JSON array,
        # but a future regression that emits a dict/null/string must not
        # crash the predecessor-context compose. Type-narrows mypy's
        # json.loads -> Any so the function honors its annotation.
        return parsed if isinstance(parsed, list) else []
    except (subprocess.SubprocessError, OSError, ValueError):
        return []


def _fallback_artifact_block(dep_id: str) -> str:
    return (
        f"  [no codebase_snapshot/predecessor_context yet — fall back to "
        f"reading docs/DONE_Feature_{dep_id}/REQUIREMENTS.md + PLAN.md + REVIEW.md]"
    )


def _format_dep_block(
    dep_id: str, dep_task: dict, profile: dict, max_lines_per_dep: int,
    repo_root: Path,
) -> str:
    cs = dep_task.get("codebase_snapshot") or {}
    pc = dep_task.get("predecessor_context") or {}
    has_metadata = bool(cs or pc)

    header = f"# Dependency: {dep_id}"
    if not has_metadata:
        return f"{header}\n{_fallback_artifact_block(dep_id)}"

    commit_ref = cs.get("commit_ref", "")
    if commit_ref:
        header += f" (commit {commit_ref[:12]})"

    sections: list[str] = []
    if profile["shadow"] and pc:
        sections.extend(_format_shadow(pc, max_lines_per_dep))
    if profile["interfaces"] and cs:
        sections.extend(_format_modules(cs))
        sections.extend(_format_interfaces(cs))
    if profile.get("symbol_map") and cs:
        sections.extend(_format_symbol_map(cs, repo_root))
    if profile["tests"] and cs:
        sections.extend(_format_tests(cs))
    if profile["diff_stat"] and commit_ref:
        stat, _ = _git_show_commit(commit_ref, repo_root)
        if stat:
            sections.append("  diff_stat:")
            for line in stat.splitlines():
                sections.append(f"    {line}")
    if profile["diff_full"] and commit_ref:
        _, full = _git_show_commit(commit_ref, repo_root)
        if full:
            sections.append("  diff:")
            truncated = _truncate_block(full, max_lines_per_dep * 5)
            for line in truncated.splitlines():
                sections.append(f"    {line}")

    if not sections:
        sections.append("  [metadata present but no fields match this phase's profile]")

    return "\n".join([header] + sections)


def compose(
    plan_path: Path, task_id: str, phase: str,
    max_lines_per_dep: int = 30, repo_root: Path | None = None,
) -> str:
    if phase not in PHASE_PROFILES:
        print(f"ERROR: unknown phase '{phase}'; expected one of {sorted(PHASE_PROFILES)}",
              file=sys.stderr)
        sys.exit(2)

    plan = _load_plan(plan_path)
    if not isinstance(plan, dict):
        print("ERROR: plan root is not a mapping", file=sys.stderr)
        sys.exit(3)

    task = _find_task(plan, task_id)
    if task is None:
        print(f"ERROR: task '{task_id}' not found in plan", file=sys.stderr)
        sys.exit(3)

    deps = task.get("depends", []) or []
    if not deps:
        return ""

    if repo_root is None:
        repo_root = plan_path.resolve().parent
        while repo_root != repo_root.parent:
            if (repo_root / ".git").exists():
                break
            repo_root = repo_root.parent

    profile = PHASE_PROFILES[phase]
    blocks: list[str] = []
    for dep_id in deps:
        dep_task = _find_task(plan, dep_id)
        if dep_task is None:
            blocks.append(f"# Dependency: {dep_id}\n  [WARNING: dependency not found in plan]")
            continue
        if dep_task.get("status") not in ("done", "skipped"):
            continue
        blocks.append(_format_dep_block(dep_id, dep_task, profile, max_lines_per_dep, repo_root))

    if not blocks:
        return ""

    return (
        f"=== Predecessor context for /{phase} "
        f"(from {len(blocks)} completed dependencies) ===\n\n"
        + "\n\n".join(blocks)
        + "\n\n=== End predecessor context ==="
    )


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--plan", required=True, type=Path, help="Path to execution-plan.yaml")
    p.add_argument("--task", required=True, help="Task id to compose context for")
    p.add_argument("--phase", required=True, help="Consuming phase name (no slash)")
    p.add_argument("--max-lines-per-dep", type=int, default=30,
                   help="Hard cap on decision-shadow lines per field per dep (default: 30)")
    p.add_argument("--repo-root", type=Path, default=None,
                   help="Override repo root (default: walk up from plan dir)")
    args = p.parse_args()

    out = compose(args.plan, args.task, args.phase, args.max_lines_per_dep, args.repo_root)
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
