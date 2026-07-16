"""Plan loading, status merging, project discovery, and gate enrichment helpers.

Encapsulates all execution-plan logic so serve.py stays focused on routing.
Functions: load_execution_plan, merge_file_status, find_plans, find_task,
_match_task_to_dir, _normalize_id, evaluate_gate, discover_all_plans_v2,
_collect_active_workers, _canonical_main_root, _branch_suffix,
enrich_gates, _normalize_checklist, _apply_evaluations.
"""

import copy
import json
import logging
import os
import re
import subprocess
from datetime import UTC, datetime
from pathlib import Path

from dashboard.server import autopilot_helpers, session_helpers

# Configurable project root — override via PROJECTS_ROOT env var
PROJECTS_ROOT = Path(os.environ.get("PROJECTS_ROOT", str(Path.home() / "Projekter")))


def _data_dir() -> Path:
    """Resolve the dashboard data directory.

    Honors ``DASHBOARD_DATA_DIR`` (consistent with metrics_helpers and
    feature_helpers); falls back to ``<repo>/dashboard/data/`` when unset.
    """
    override = os.environ.get("DASHBOARD_DATA_DIR")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent / "data"


logger = logging.getLogger(__name__)

PLAN_FILENAMES = ["execution-plan.yaml", "execution-plan.json"]

# Module-scoped mtime cache: maps str(path) → (mtime, parsed_dict)
_LOAD_CACHE: dict[str, tuple[float, dict]] = {}


def _normalize_id(s: str) -> str:
    """Normalize a task/directory ID: lowercase, hyphens and underscores equivalent."""
    return s.lower().replace("_", "-")


def _plan_last_activity_iso(
    plan_path: str | Path,
    plan: dict | None = None,
) -> str | None:
    """Return the most recent activity timestamp for a plan, ISO 8601 UTC.

    Two complementary sources are merged via max():
    - Plan-2.0 per-task `last_updated` (written by /done, /plan-project
      --update, etc.) — most accurate, immune to git-checkout mtime reset.
    - Plan YAML file mtime — fallback for plan-1.x and for plan-2.0 plans
      whose tasks haven't been touched yet (covers the case where a fresh
      plan exists but no tasks have been run).

    Returns None only if both sources fail (OSError + no task last_updated).
    Surfaced as `last_activity` on /api/plans entries so Plans-tab RECENT
    sort orders by genuine work events rather than the day the operator
    last switched branches (RSK-D in feature_helpers.py:214).
    """
    candidates: list[str] = []
    try:
        mtime = os.path.getmtime(str(plan_path))
        candidates.append(datetime.fromtimestamp(mtime, tz=UTC).isoformat())
    except OSError:
        pass
    if plan is not None:
        for phase in plan.get("phases", []) or []:
            for task in phase.get("tasks", []) or []:
                lu = task.get("last_updated")
                if isinstance(lu, str) and lu:
                    candidates.append(lu)
    if not candidates:
        return None
    return max(candidates)


def load_execution_plan(main_worktree: str) -> tuple[dict, str] | None:
    """Load an execution plan from a worktree root.

    Looks for execution-plan.yaml, execution-plan.json at root.
    Falls back to EXECUTION_GUIDE.md with auto-conversion.
    Returns (plan_dict, plan_dir) or None.
    """
    root = Path(main_worktree)
    if not root.is_dir():
        return None

    for filename in PLAN_FILENAMES:
        plan_path = root / filename
        if plan_path.is_file():
            plan = _load_plan_file(plan_path)
            if plan:
                return plan, str(plan_path.parent)

    guide_path = root / "EXECUTION_GUIDE.md"
    if guide_path.is_file():
        try:
            import sys

            tools_dir = str(Path(__file__).resolve().parent.parent / "tools")
            if tools_dir not in sys.path:
                sys.path.insert(0, tools_dir)
            from convert_guide import emit_plan, parse_guide

            text = guide_path.read_text(encoding="utf-8")
            parsed = parse_guide(text)
            return emit_plan(parsed), str(root)
        except Exception:
            return None

    return None


def _match_task_to_dir(needle: str, candidates: list[str]) -> tuple[str | None, str]:
    """Match a task ID against a list of directory names using 4-tier matching.

    Tiers: exact → normalized → fuzzy → none.
    Returns (matched_candidate, match_tier).
    """
    if not candidates:
        return None, "none"

    # Tier 1: exact match
    for c in candidates:
        if needle == c:
            return c, "exact"

    # Tier 2: normalized (lowercase, hyphens/underscores equivalent)
    needle_norm = _normalize_id(needle)
    for c in candidates:
        if needle_norm == _normalize_id(c):
            return c, "normalized"

    # Tier 3: fuzzy (substring in either direction, but only if the shorter
    # string covers ≥60% of the longer string — prevents "capacity" matching
    # "absence-aware-capacity")
    for c in candidates:
        c_norm = _normalize_id(c)
        longer = max(len(needle_norm), len(c_norm))
        shorter = min(len(needle_norm), len(c_norm))
        if longer > 0 and shorter / longer >= 0.7:
            if needle_norm in c_norm or c_norm in needle_norm:
                return c, "fuzzy"

    return None, "none"


def merge_file_status(plan: dict, main_worktree: str) -> dict:
    """Override task statuses based on filesystem markers.

    For each task, checks docs/ directories using R6a 4-tier matching
    (exact → normalized → fuzzy → none).
    File-based detection wins over YAML status.
    Returns a new dict (does NOT mutate input).
    """
    result = copy.deepcopy(plan)
    docs_dir = Path(main_worktree) / "docs"

    if not docs_dir.is_dir():
        return result

    # Build lists of DONE_ and INPROGRESS_ directory names (stripped of prefix)
    # Convention: docs/{STATUS}_{Type}_{name}/ where Type is Feature or Plan
    done_dirs = []
    inprogress_dirs = []
    try:
        for entry in docs_dir.iterdir():
            if not entry.is_dir():
                continue
            name = entry.name
            if name.startswith("DONE_Feature_"):
                done_dirs.append(name[13:])
            elif name.startswith("DONE_Plan_"):
                done_dirs.append(name[10:])
            elif name.startswith("INPROGRESS_Feature_"):
                inprogress_dirs.append(name[19:])
            elif name.startswith("INPROGRESS_Plan_"):
                inprogress_dirs.append(name[16:])
    except Exception as e:
        logger.error("merge_file_status: failed to read docs dir path=%s exc=%s", docs_dir, e)
        return result

    for phase in result.get("phases", []):
        for task in phase.get("tasks", []):
            tid = task.get("id", "")
            if not tid:
                continue

            matched, tier = _match_task_to_dir(tid, done_dirs)
            if matched:
                if tier == "fuzzy":
                    logger.warning(
                        "Fuzzy match: task '%s' matched directory 'DONE_*_%s'. "
                        "Verify this mapping is correct.",
                        tid,
                        matched,
                    )
                task["status"] = "done"
                continue

            matched, tier = _match_task_to_dir(tid, inprogress_dirs)
            if matched:
                if tier == "fuzzy":
                    logger.warning(
                        "Fuzzy match: task '%s' matched directory 'INPROGRESS_*_%s'. "
                        "Verify this mapping is correct.",
                        tid,
                        matched,
                    )
                task["status"] = "wip"

    return result


def find_plans(main_worktree: str) -> list[dict]:
    """Discover all execution plans in a worktree root.

    Scans docs/{STATUS}_{Type}_{name}/ directories for execution-plan.yaml,
    where STATUS is PENDING, INPROGRESS, or DONE and Type is Feature or Plan.
    Falls back to root-level execution-plan.yaml/json.
    Returns [{"name": str, "path": str, "lifecycle": str, "type": str, "plan": dict}].
    Does NOT apply merge_file_status — caller is responsible.
    """
    root = Path(main_worktree)
    if not root.is_dir():
        return []

    results = []
    docs_dir = root / "docs"

    if docs_dir.is_dir():
        try:
            for entry in sorted(docs_dir.iterdir()):
                if not entry.is_dir():
                    continue
                name = entry.name
                if name.startswith("INPROGRESS_Plan_"):
                    feature = name[16:]
                    lifecycle = "inprogress"
                    entry_type = "plan"
                elif name.startswith("DONE_Plan_"):
                    feature = name[10:]
                    lifecycle = "done"
                    entry_type = "plan"
                elif name.startswith("INPROGRESS_Feature_"):
                    feature = name[19:]
                    lifecycle = "inprogress"
                    entry_type = "feature"
                elif name.startswith("DONE_Feature_"):
                    feature = name[13:]
                    lifecycle = "done"
                    entry_type = "feature"
                elif name.startswith("PENDING_Feature_"):
                    feature = name[16:]
                    lifecycle = "pending"
                    entry_type = "feature"
                elif name.startswith("PENDING_Plan_"):
                    feature = name[13:]
                    lifecycle = "pending"
                    entry_type = "plan"
                else:
                    continue

                plan_path = entry / "execution-plan.yaml"
                if plan_path.is_file():
                    plan = _load_plan_file(plan_path)
                    if plan:
                        results.append(
                            {
                                "name": feature,
                                "path": str(plan_path),
                                "lifecycle": lifecycle,
                                "type": entry_type,
                                "plan": plan,
                            }
                        )
        except Exception as e:
            logger.error("find_plans: failed to scan docs dir path=%s exc=%s", docs_dir, e)

    # Root-level fallback (backward compat)
    if not results:
        for filename in PLAN_FILENAMES:
            plan_path = root / filename
            if plan_path.is_file():
                plan = _load_plan_file(plan_path)
                if plan:
                    results.append(
                        {
                            "name": plan.get("name", root.name),
                            "path": str(plan_path),
                            "lifecycle": "root",
                            "plan": plan,
                        }
                    )
                    break

    return results


def _load_plan_file(plan_path: Path) -> dict | None:
    """Load a single plan file (YAML or JSON). Returns dict or None.

    Single source of truth for plan file loading. Used by both
    load_execution_plan() and find_plans(). Does NOT apply
    merge_file_status — caller is responsible.

    Results are cached by (path, mtime): the file is only re-parsed when
    its modification time changes.
    """
    key = str(plan_path)
    try:
        mtime = os.path.getmtime(plan_path)
    except OSError:
        return None

    cached = _LOAD_CACHE.get(key)
    if cached is not None and cached[0] == mtime:
        return cached[1]

    result = _parse_plan_file(plan_path)
    if result is not None:
        _LOAD_CACHE[key] = (mtime, result)
    return result


def _parse_plan_file(plan_path: Path) -> dict | None:
    """Parse a plan file from disk without caching."""
    try:
        if plan_path.suffix in (".yaml", ".yml"):
            try:
                import yaml

                with open(plan_path) as f:
                    return yaml.safe_load(f)
            except ImportError:
                # Try loading as JSON (some .yaml files may actually be JSON)
                try:
                    with open(plan_path) as f:
                        return json.load(f)
                except Exception:
                    return None
        else:
            with open(plan_path) as f:
                return json.load(f)
    except Exception:
        return None


def find_task(plan: dict, feature_name: str) -> dict | None:
    """Locate a task by feature name using R6a 4-tier matching.

    Searches all phases. Returns the task dict or None.
    """
    all_task_ids = []
    task_map = {}
    for phase in plan.get("phases", []):
        for task in phase.get("tasks", []):
            tid = task.get("id", "")
            if tid:
                all_task_ids.append(tid)
                task_map[tid] = task

    matched, tier = _match_task_to_dir(feature_name, all_task_ids)
    if matched:
        if tier == "fuzzy":
            logger.warning(
                "Fuzzy match: feature '%s' matched task '%s'. Verify this mapping is correct.",
                feature_name,
                matched,
            )
        return task_map[matched]

    return None


def evaluate_gate(plan: dict, phase_id: str) -> dict:
    """Read-only gate check for dashboard display.

    Returns {"phase_id": str, "all_complete": bool, "gate_passed": bool}.
    Gate passes when all tasks in the phase are done or skipped.
    """
    for phase in plan.get("phases", []):
        if phase.get("id") == phase_id:
            tasks = phase.get("tasks", [])
            if not tasks:
                return {"phase_id": phase_id, "all_complete": False, "gate_passed": False}
            complete_statuses = {"done", "skipped"}
            all_complete = all(t.get("status") in complete_statuses for t in tasks)
            return {
                "phase_id": phase_id,
                "all_complete": all_complete,
                "gate_passed": all_complete,
            }

    return {"phase_id": phase_id, "all_complete": False, "gate_passed": False}


def _infer_main_worktree(path: str) -> str | None:
    """Infer the main worktree from a (possibly deleted) worktree path.

    Claude Code worktrees live at <repo>/.claude/worktrees/<name>.
    If path matches this pattern and the repo root exists, return it.
    """
    marker = "/.claude/worktrees/"
    idx = path.find(marker)
    if idx >= 0:
        candidate = path[:idx]
        if Path(candidate).is_dir():
            return candidate
    return None


def _load_root_cache() -> set[str]:
    """Load cached project roots so deleted worktrees don't orphan plans.

    Filters cached roots to those under PROJECTS_ROOT to bound the blast
    radius of a corrupted cache file.
    """
    cache = _data_dir() / ".plan_roots_cache"
    if cache.is_file():
        try:
            raw = set(cache.read_text(encoding="utf-8").strip().splitlines())
            projects_root = PROJECTS_ROOT.resolve()
            return {r for r in raw if Path(r).is_relative_to(projects_root)}
        except Exception:
            return set()
    return set()


def _save_root_cache(roots: set[str]) -> None:
    """Persist discovered project roots."""
    cache = _data_dir() / ".plan_roots_cache"
    try:
        cache.write_text("\n".join(sorted(roots)) + "\n", encoding="utf-8")
    except Exception as e:
        logger.warning("_save_root_cache: failed to write cache path=%s exc=%s", cache, e)


def _branch_suffix(branch: str | None) -> str | None:
    """Return the segment after the final ``/`` in a branch ref.

    Falls back to the whole ref when there is no slash; returns ``None``
    when the input is empty, blank, or ``None``. The suffix is the
    matching key against task ids (R2 cond 3, AS5–AS7, EC1, EC11).
    """
    if not branch:
        return None
    s = branch.strip()
    if not s:
        return None
    if "/" in s:
        return s.rsplit("/", 1)[-1]
    return s


_LIVE_SESSION_STATUSES = frozenset({"working", "needs_input"})
_LIVE_AUTOPILOT_STATUS = "running"


def _collect_active_workers() -> list[tuple[str, str]]:
    """Gather the live-worker pool once per ``discover_all_plans_v2()`` call.

    Returns a list of ``(main_repo_root, branch_suffix)`` tuples — one per
    distinct live worker after dedup. Sessions dedup by
    ``(worktree, branch_suffix)`` so two report-rows for the same crashed
    session collapse to one (EC4). Autopilots dedup by
    ``(main_repo_root, branch_suffix)`` since each autopilot run is
    one-per-feature. Cross-source collisions resolve autopilot-wins:
    when the same ``(main_repo_root, branch_suffix)`` exists in both
    sources, the autopilot entry stays and any session entries on that
    pair are dropped (EC5, AS2).

    Multiplicity is preserved across distinct workers — two sessions on
    different worktrees but the same ``(main_root, branch_suffix)``
    appear as two list entries (AS12).

    Both upstream sources are wrapped in ``try/except`` so a failure in
    one does not suppress the other (R5/R6 independence). Workers with
    a missing branch, missing worktree, or non-resolvable main repo
    root are silently skipped.
    """
    try:
        autopilots = autopilot_helpers.discover_autopilots()
    except Exception as e:
        logger.error(
            "_collect_active_workers: autopilot helper raised type=%s msg=%s "
            "— autopilots treated as empty",
            type(e).__name__,
            e,
        )
        autopilots = []
    autopilot_pairs: set[tuple[str, str]] = set()
    for entry in autopilots:
        if entry.get("status") != _LIVE_AUTOPILOT_STATUS:
            continue
        suffix = _branch_suffix(entry.get("branch"))
        if suffix is None:
            continue
        path = entry.get("stream_path") or entry.get("log_path")
        if not path:
            continue
        main_root = _canonical_main_root(str(Path(path).parent))
        if not main_root:
            continue
        autopilot_pairs.add((main_root, suffix))

    try:
        sessions = session_helpers.get_session_states()
    except Exception as e:
        logger.error(
            "_collect_active_workers: session helper raised type=%s msg=%s "
            "— sessions treated as empty",
            type(e).__name__,
            e,
        )
        sessions = []
    session_dedup: dict[tuple[str, str], str] = {}
    for entry in sessions:
        if entry.get("status") not in _LIVE_SESSION_STATUSES:
            continue
        suffix = _branch_suffix(entry.get("branch"))
        if suffix is None:
            continue
        worktree = entry.get("worktree") or entry.get("cwd")
        if not worktree:
            continue
        main_root = _canonical_main_root(worktree)
        if not main_root:
            continue
        if (main_root, suffix) in autopilot_pairs:
            continue
        session_dedup[(worktree, suffix)] = main_root

    workers: list[tuple[str, str]] = list(autopilot_pairs)
    for (_worktree, suffix), main_root in session_dedup.items():
        workers.append((main_root, suffix))
    return workers


def _canonical_main_root(path: str) -> str | None:
    """Resolve any path inside a worktree to that worktree's main repo root.

    Runs ``git -C <path> worktree list --porcelain`` and returns the first
    ``worktree `` entry. Returns ``None`` and logs a WARNING when git fails
    or the output is empty (e.g., the directory was removed between the
    upstream snapshot and this call). This is the canonicalisation seam
    used by both the live-worker collector (R2 cond 2) and, after the
    refactor, by ``_resolve_repo_roots`` itself.
    """
    if not path:
        return None
    try:
        proc = subprocess.run(
            ["git", "-C", path, "worktree", "list", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as e:
        logger.warning(
            "_canonical_main_root: git worktree list failed path=%s exc=%s",
            path,
            e,
        )
        return None
    if proc.returncode != 0:
        logger.warning(
            "_canonical_main_root: git worktree list failed path=%s rc=%d stderr=%s",
            path,
            proc.returncode,
            proc.stderr.strip(),
        )
        return None
    for ln in proc.stdout.splitlines():
        if ln.startswith("worktree "):
            return ln[len("worktree ") :]
    logger.warning(
        "_canonical_main_root: git worktree list returned no worktree entries path=%s",
        path,
    )
    return None


def _resolve_repo_roots() -> set[str]:
    """Resolve unique repo roots from sessions.jsonl CWDs.

    Reads data/sessions.jsonl, resolves each CWD to its main worktree root
    via git, with fallback to path inference and parent scanning.
    Merges with cached roots so deleted worktrees remain discoverable.
    Returns set of validated root paths.
    """
    data_dir = _data_dir()
    jsonl_path = data_dir / "sessions.jsonl"

    if not jsonl_path.is_file():
        return set()

    cwds = set()
    try:
        lines = jsonl_path.read_text(encoding="utf-8").strip().splitlines()
        for line in lines[-1000:]:
            try:
                entry = json.loads(line)
                cwd = entry.get("cwd", "")
                if cwd:
                    cwds.add(cwd)
            except json.JSONDecodeError:
                continue
    except Exception:
        return set()

    seen_roots = set()

    for cwd in cwds:
        try:
            proc = subprocess.run(
                ["git", "-C", cwd, "worktree", "list", "--porcelain"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if proc.returncode != 0:
                raise RuntimeError("git failed")
            for ln in proc.stdout.splitlines():
                if ln.startswith("worktree "):
                    root = ln[len("worktree ") :]
                    if root not in seen_roots:
                        seen_roots.add(root)
                    break
        except Exception:
            inferred = _infer_main_worktree(cwd)
            if inferred and inferred not in seen_roots:
                seen_roots.add(inferred)
                continue
            parent = Path(cwd).parent
            if parent.is_dir():
                try:
                    children = list(parent.iterdir())
                    if len(children) <= 100:
                        for child in children:
                            if not child.is_dir() or child.name.startswith("."):
                                continue
                            for fn in PLAN_FILENAMES:
                                if (child / fn).is_file():
                                    seen_roots.add(str(child))
                                    break
                except Exception:
                    pass

    # Merge with cached roots (survives worktree deletion)
    cached_roots = _load_root_cache()
    for root in cached_roots:
        if root not in seen_roots and Path(root).is_dir():
            seen_roots.add(root)
    valid_roots = {r for r in seen_roots if Path(r).is_dir()}

    # Deduplicate: collapse worktrees to their main repo root
    deduped = set()
    for root in valid_roots:
        canonical = _canonical_main_root(root)
        deduped.add(canonical if canonical else root)

    _save_root_cache(deduped)
    return deduped


def discover_all_plans_v2() -> list[dict]:
    """Discover all projects with execution plans, enriched with lifecycle.

    Resolves repo roots from sessions.jsonl, then calls find_plans()
    for docs-directory scanning.
    Returns [{project, path, plan_dir, lifecycle, phases, progress, has_plan}].
    """
    seen_roots = _resolve_repo_roots()
    worker_pairs = _collect_active_workers()
    results = []
    for root in seen_roots:
        plans = find_plans(root)
        if plans:
            for entry in plans:
                plan = entry["plan"]
                plan = merge_file_status(plan, root)
                phases = plan.get("phases", [])
                total = sum(len(p.get("tasks", [])) for p in phases)
                done_count = sum(
                    1 for p in phases for t in p.get("tasks", []) if t.get("status") == "done"
                )
                progress = round((done_count / total) * 100) if total > 0 else 0
                active_session_count = _count_active_sessions(worker_pairs, root, phases)
                results.append(
                    {
                        "project": plan.get("name", entry["name"]),
                        "path": root,
                        "plan_dir": str(Path(entry["path"]).parent),
                        "lifecycle": entry["lifecycle"],
                        "phases": len(phases),
                        "progress": progress,
                        "has_plan": True,
                        "schema_version": plan.get("schema_version", "1.0.0"),
                        "active_session_count": active_session_count,
                        "last_activity": _plan_last_activity_iso(
                            entry["path"],
                            plan,
                        ),
                    }
                )
        else:
            # Fall back to root-level plan via load_execution_plan
            result = load_execution_plan(root)
            if not result:
                continue
            plan = result[0]
            plan = merge_file_status(plan, root)
            phases = plan.get("phases", [])
            total = sum(len(p.get("tasks", [])) for p in phases)
            done_count = sum(
                1 for p in phases for t in p.get("tasks", []) if t.get("status") == "done"
            )
            progress = round((done_count / total) * 100) if total > 0 else 0
            active_session_count = _count_active_sessions(worker_pairs, root, phases)
            root_plan_path = next(
                (str(Path(root) / fn) for fn in PLAN_FILENAMES if (Path(root) / fn).is_file()),
                None,
            )
            results.append(
                {
                    "project": plan.get("name", Path(root).name),
                    "path": root,
                    "plan_dir": root,
                    "lifecycle": "root",
                    "phases": len(phases),
                    "progress": progress,
                    "has_plan": True,
                    "schema_version": plan.get("schema_version", "1.0.0"),
                    "active_session_count": active_session_count,
                    "last_activity": (
                        _plan_last_activity_iso(root_plan_path, plan) if root_plan_path else None
                    ),
                }
            )

    return results


def _count_active_sessions(
    worker_pairs: list[tuple[str, str]],
    project_root: str,
    phases: list,
) -> int:
    """Count workers whose root matches and whose suffix matches a task id.

    ``worker_pairs`` is a multiplicity-preserving list (see
    ``_collect_active_workers``) — two distinct workers that both
    canonicalise to ``(project_root, suffix)`` count as 2.
    """
    task_ids = {_normalize_id(t["id"]) for p in phases for t in p.get("tasks", []) if t.get("id")}
    return sum(
        1
        for (root_p, suffix) in worker_pairs
        if root_p == project_root and _normalize_id(suffix) in task_ids
    )


# ── Gate Enrichment ───────────────────────────────────────────────────

_VALID_KINDS = {"shell", "human"}


def _normalize_checklist(checklist: list) -> list[dict]:
    """Convert mixed string/object checklist items to uniform object form.

    Derives kind: object with check.kind in {"shell","human"} → use it;
    object with no check or unknown kind → "human"; plain string → "human".
    Sets lastResult to None.
    """
    result = []
    for item in checklist:
        if isinstance(item, str):
            result.append({"item": item, "kind": "human", "lastResult": None})
        elif isinstance(item, dict):
            text = item.get("item", "")
            check = item.get("check")
            kind = "human"
            if isinstance(check, dict):
                raw_kind = check.get("kind", "")
                kind = raw_kind if raw_kind in _VALID_KINDS else "human"
            entry: dict = {"item": text, "kind": kind, "lastResult": None}
            if check:
                entry["check"] = check
            result.append(entry)
    return result


def _apply_evaluations(normalized: list[dict], eval_items: list) -> list[dict]:
    """Merge evaluation results into normalized items by position index.

    Extra eval items are ignored; missing eval items leave lastResult as None.
    """
    result = [dict(item) for item in normalized]
    for i, item in enumerate(result):
        if i < len(eval_items):
            eval_item = eval_items[i]
            if isinstance(eval_item, dict):
                item["lastResult"] = eval_item.get("result")
    return result


def enrich_gates(plan: dict, plan_dir: str) -> dict:
    """Add kind/lastResult to each gate checklist item from chain-events.

    Delegates to _normalize_checklist (data shaping) then
    _apply_evaluations (merge). Returns a new dict (does NOT mutate input).
    """
    from dashboard.server.chain_events import parse_gate_evaluations

    result = copy.deepcopy(plan)
    evaluations = parse_gate_evaluations(plan_dir)

    for phase in result.get("phases", []):
        gate = phase.get("gate")
        if not gate:
            continue

        phase_id = phase.get("id", "")
        checklist = gate.get("checklist", [])

        # Step 1: Normalize checklist items to uniform object form
        normalized = _normalize_checklist(checklist)

        # Step 2: Apply evaluation results by position index
        eval_items = evaluations.get(phase_id, [])
        enriched = _apply_evaluations(normalized, eval_items)

        # Step 3: If gate.passed is true, override all items to passed (EC3.2, AS8)
        if gate.get("passed"):
            for item in enriched:
                item["lastResult"] = "passed"

        gate["enrichedChecklist"] = enriched

    return result


# ── Plan Artifact Helpers ─────────────────────────────────────────────

_TASK_NAME_RE = re.compile(r"^[a-zA-Z0-9_-]+$")

_TASK_ARTIFACT_FILES = {
    "REQUIREMENTS.md",
    "PLAN.md",
    "DESIGN.md",
    "TEAM_REVIEW.md",
    "TEAM_QA.md",
    "QA_REPORT.md",
    "TESTPLAN.md",
    "MANUAL_TEST_LOG.md",
}

_PLAN_ARTIFACT_FILES = {
    "execution-plan.yaml",
    "SETUP_PLAN.md",
    "EXECUTION_GUIDE.md",
    "EXECUTION_PLAN.md",
    "DEFERRED.md",
}

_ALL_ALLOWED_FILES = _TASK_ARTIFACT_FILES | _PLAN_ARTIFACT_FILES


def list_task_artifacts(cwd: str, task: str) -> list[dict]:
    """List available doc artifacts for a task in a project.

    Searches docs/{DONE,INPROGRESS}_Feature_<task>/ for known filenames.
    Returns list of {"name": str, "file": str} dicts.
    """
    if not _TASK_NAME_RE.match(task):
        return []
    project = Path(cwd)
    results = []
    for prefix in ("DONE_Feature_", "INPROGRESS_Feature_"):
        feature_dir = project / "docs" / f"{prefix}{task}"
        if not feature_dir.is_dir():
            continue
        for filename in sorted(_TASK_ARTIFACT_FILES):
            if (feature_dir / filename).is_file():
                results.append({"name": filename, "file": filename})
        if results:
            break  # prefer DONE_ over INPROGRESS_ but don't duplicate
    return results


PLAN_ARTIFACT_ESCAPE_MARKER = "__ESCAPE__"
PLAN_ARTIFACT_OUTSIDE_ROOT_MARKER = "__OUTSIDE_PROJECTS_ROOT__"


def get_plan_artifact(
    cwd: str | None, plan_dir: str | None, task: str | None, filename: str
) -> str | None:
    """Read a plan or task artifact file, returning content or None.

    Three modes:
    1. Task artifacts (basename only): cwd + task → docs/{DONE,INPROGRESS}_Feature_<task>/<file>
    2. Plan artifacts (basename only): plan_dir → <plan_dir>/<file>
    3. Descended path (schema-2.0 artifact_refs): cwd + task + file containing '/'
       → <cwd>/<file>, with containment guard via Path.resolve().is_relative_to.

    Modes 1+2 require `filename` to be in _ALL_ALLOWED_FILES.
    Mode 3 requires `cwd` to be inside PROJECTS_ROOT and the basename of
    `file` to be in _ALL_ALLOWED_FILES (defence in depth).

    Validates path stays under ~/Projekter/ or the project root (for tests).

    Returns the marker constants on policy violations so the caller can map
    them to HTTP 400.
    """
    is_descended = task is not None and cwd is not None and "/" in filename

    if is_descended:
        cwd_path = Path(cwd)
        try:
            cwd_resolved = cwd_path.resolve()
        except (OSError, RuntimeError):
            return PLAN_ARTIFACT_ESCAPE_MARKER
        if not cwd_resolved.is_dir():
            return None

        project_root = Path(__file__).resolve().parent.parent
        try:
            inside_projects_root = cwd_resolved.is_relative_to(PROJECTS_ROOT.resolve())
        except (ValueError, OSError):
            inside_projects_root = False
        try:
            inside_dashboard_root = cwd_resolved.is_relative_to(project_root)
        except (ValueError, OSError):
            inside_dashboard_root = False
        if not (inside_projects_root or inside_dashboard_root):
            return PLAN_ARTIFACT_OUTSIDE_ROOT_MARKER

        joined = cwd_resolved / filename
        try:
            joined_resolved = joined.resolve()
        except (OSError, RuntimeError):
            return PLAN_ARTIFACT_ESCAPE_MARKER
        try:
            if not joined_resolved.is_relative_to(cwd_resolved):
                return PLAN_ARTIFACT_ESCAPE_MARKER
        except (ValueError, OSError):
            return PLAN_ARTIFACT_ESCAPE_MARKER

        basename = Path(filename).name
        if basename not in _ALL_ALLOWED_FILES:
            return None
        if not joined_resolved.is_file():
            return None
        try:
            return joined_resolved.read_text(encoding="utf-8")
        except OSError:
            return None

    if filename not in _ALL_ALLOWED_FILES:
        return None

    candidate = None
    if task and cwd and _TASK_NAME_RE.match(task):
        project = Path(cwd)
        for prefix in ("DONE_Feature_", "INPROGRESS_Feature_"):
            path = project / "docs" / f"{prefix}{task}" / filename
            if path.is_file():
                candidate = path
                break
    elif plan_dir:
        path = Path(plan_dir) / filename
        if path.is_file():
            candidate = path

    if candidate is None:
        return None

    # Security: resolve symlinks and validate path is under PROJECTS_ROOT or
    # the dashboard root (for tests). Use is_relative_to to avoid
    # trailing-slash / prefix-collision edge cases.
    resolved = candidate.resolve()
    dashboard_root = Path(__file__).resolve().parent.parent
    try:
        inside_projects_root = resolved.is_relative_to(PROJECTS_ROOT.resolve())
    except (ValueError, OSError):
        inside_projects_root = False
    try:
        inside_dashboard_root = resolved.is_relative_to(dashboard_root)
    except (ValueError, OSError):
        inside_dashboard_root = False
    if not (inside_projects_root or inside_dashboard_root):
        return None

    try:
        return resolved.read_text(encoding="utf-8")
    except OSError:
        return None
