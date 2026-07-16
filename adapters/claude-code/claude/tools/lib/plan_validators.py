"""Schema-2.0 plan validators not expressible in JSON Schema.

Each function takes a ``ValidationContext`` and returns a list of error or
warning lines (warnings are prefixed ``WARNING:``; errors are unprefixed
path-pointing strings per R10). The dispatcher in ``validate-plan.py``
iterates ``VALIDATORS_2_0`` and concatenates the results.

Module-level constants make threshold values grep-traceable from error
messages back to the requirement that fixed them.
"""

from __future__ import annotations

import re
import subprocess
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass, field
from pathlib import Path

# Threshold constants — see REQUIREMENTS.md R15-R20 for sources.
WHAT_MIN_CHARS = 80
WHY_MIN_CHARS = 120
DUP_WHAT_MIN_OVERLAP = 60
SUCCESS_CRITERIA_REASON_MIN = 40
GATE_RUNTIME_BUDGET_SECONDS = 30
MAX_GATE_CMD_LEN = 4096
BASH_SYNTAX_TIMEOUT = 2

# Plan decomposition rules — caps sized to fit autopilot's solo /review
# phase budget (MAX_TURNS=75 in autopilot.sh).
MAX_ACCEPTANCE_COUNT = 5  # R-A1
LINES_ESTIMATE_TARGET = 100  # R-A5 soft target
LINES_ESTIMATE_HARD_CAP = 200  # R-A2 hard cap
DURATION_HOURS_TARGET = 2  # R-A5 soft target
DURATION_HOURS_HARD_CAP = 3  # R-A3 hard cap
MAX_TOUCHED_PATHS_TARGET = 3  # R-A5 soft target
MAX_TOUCHED_PATHS_HARD_CAP = 4  # R-A4 hard cap
SIZING_EXEMPT_STATUSES = frozenset({"done", "skipped", "blocked", "failed"})
SEQUENCING_RATIONALE_ENUM = frozenset(
    {
        "walking-skeleton",
        "data-model-first",
        "riskiest-first",
        "smallest-first",
    }
)  # R-C4
SEQUENCING_RATIONALE_MIN_CHARS_CUSTOM = 40  # R-C4
MAX_PARALLELISM_PAIR_WARNINGS = 20  # EC-C.5

ASPIRATIONAL_PATTERN = re.compile(r"\b(well-designed|robust|good|nice|clean)\b")
EARS_PREFIXES = ("When ", "While ", "If ", "Where ")
EARS_VERB_RE = re.compile(r"\bshall\b")
GLOB_CHARS = ("*", "?", "[")
PATH_QUALIFIER_RE = re.compile(r"^([a-z0-9-]+):([^:].*)$")
CODE_FILE_EXTS = (".py", ".js", ".ts", ".tsx", ".sh", ".go", ".rs", ".java")

LEGACY_SIBLINGS = (
    "deferred-findings.json",
    "EXECUTION_PLAN.md",
    "SETUP_PLAN.md",
    "PLANNING_BRIEF.md",
    "DEFERRED.md",
    "RETRO.md",
)


def _default_bash_syntax_check(cmd: str) -> tuple[bool, str]:
    """Run ``bash -n -c <cmd>`` with shell=False and return (ok, stderr).

    The function neutralises env-var expansion via ``env={}`` and rejects
    excessive lengths or control bytes before invoking subprocess.
    """
    if "\x00" in cmd or any(0x01 <= ord(c) <= 0x1F and c not in "\t\n" for c in cmd):
        return False, "control characters in cmd"
    if len(cmd) > MAX_GATE_CMD_LEN:
        return False, f"cmd exceeds {MAX_GATE_CMD_LEN} chars"
    try:
        result = subprocess.run(
            ["bash", "-n", "-c", cmd],
            capture_output=True,
            text=True,
            shell=False,
            timeout=BASH_SYNTAX_TIMEOUT,
            env={},
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:  # pragma: no cover
        return False, str(exc)
    return result.returncode == 0, result.stderr


@dataclass
class ValidationContext:
    """Context object passed to each plan_validator function."""

    plan: dict
    plan_dir: Path
    test_targets_index: dict[str, Path] = field(default_factory=dict)
    bash_checker: Callable[[str], tuple[bool, str]] = _default_bash_syntax_check
    # R-G2 opt-in: when True, validate_gate_dry_run executes negative
    # gate checks against the current working tree to detect gates that
    # are mathematically broken before any work happens. Off by default
    # because it runs shell processes; toggle via validate-plan.py
    # --dry-run-gates flag.
    dry_run_gates: bool = False

    @classmethod
    def build(cls, plan: dict, plan_dir: Path, dry_run_gates: bool = False) -> ValidationContext:
        index: dict[str, Path] = {}
        for target in plan.get("test_targets", []) or []:
            tid = target.get("id")
            tpath = target.get("path")
            if tid and tpath:
                index[tid] = (plan_dir / tpath).resolve()
        return cls(
            plan=plan, plan_dir=plan_dir, test_targets_index=index, dry_run_gates=dry_run_gates
        )


def _phases(plan: dict) -> Iterable[dict]:
    return plan.get("phases", []) or []


def _tasks(plan: dict) -> Iterable[tuple[dict, dict]]:
    for phase in _phases(plan):
        for task in phase.get("tasks", []) or []:
            yield phase, task


def _path_qualifier_match(value: str) -> tuple[str, str] | None:
    m = PATH_QUALIFIER_RE.match(value)
    if not m:
        return None
    return m.group(1), m.group(2)


def validate_2_0_completeness(ctx: ValidationContext) -> list[str]:
    """Walk the plan and emit ``project.<field> required`` style errors per R10."""
    plan = ctx.plan
    errors: list[str] = []
    project_required = (
        "schema_version",
        "name",
        "vision",
        "users",
        "success_criteria",
        "scope",
        "tech_stack",
        "existing_infrastructure_to_reuse",
        "test_targets",
        "setup",
        "kill_criteria",
        "design_notes",
        "risks",
        "phases",
    )
    for field_name in project_required:
        if field_name not in plan:
            errors.append(f"project.{field_name} required")
    phase_required = ("id", "name", "tasks", "overview_summary", "sequencing_rationale")
    task_required = (
        "id",
        "name",
        "task_type",
        "status",
        "what",
        "why",
        "where",
        "acceptance",
        "prompt",
    )
    for phase in _phases(plan):
        pid = phase.get("id", "?")
        for f in phase_required:
            if not phase.get(f) and phase.get(f) != []:
                if f not in phase:
                    errors.append(f"phase.{pid}.{f} required")
        for task in phase.get("tasks", []) or []:
            tid = task.get("id", "?")
            for f in task_required:
                if f not in task or task.get(f) in (None, ""):
                    errors.append(f"task.{tid}.{f} required")
    return errors


def validate_unique_task_ids(ctx: ValidationContext) -> list[str]:
    """Emit error per duplicate task id across all phases (edge case 6)."""
    seen: dict[str, str] = {}
    errors: list[str] = []
    for phase in _phases(ctx.plan):
        pid = phase.get("id", "?")
        for task in phase.get("tasks", []) or []:
            tid = task.get("id")
            if not tid:
                continue
            if tid in seen:
                errors.append(
                    f"task.id duplicated across phases (id={tid}, found in phase={seen[tid]}, phase={pid})"
                )
            else:
                seen[tid] = pid
    return errors


def validate_polymorphic_deferred(ctx: ValidationContext) -> list[str]:
    """Dispatch on ``deferred[].kind`` and apply kind-specific required sets."""
    errors: list[str] = []
    valid_kinds = {
        "code_finding",
        "review_suggestion",
        "scope_decision",
        "future_enhancement",
        "environment_gap",
    }
    seen_ids: set[str] = set()
    for idx, entry in enumerate(ctx.plan.get("deferred", []) or []):
        kind = entry.get("kind")
        if kind not in valid_kinds:
            errors.append(
                f"project.deferred[{idx}].kind: must be one of code_finding|review_suggestion|scope_decision|future_enhancement|environment_gap"
            )
            continue
        eid = entry.get("id")
        if eid:
            if eid in seen_ids:
                errors.append(f"project.deferred[{idx}].id duplicated (id={eid})")
            else:
                seen_ids.add(eid)
    return errors


def detect_pattern_1_stub_strings(ctx: ValidationContext) -> list[str]:
    """R15: minimum length on what/why plus 60-char shingle duplication scan."""
    errors: list[str] = []
    shingles: dict[str, str] = {}
    for _phase, task in _tasks(ctx.plan):
        tid = task.get("id", "?")
        what = task.get("what") or ""
        why = task.get("why") or ""
        if len(what) < WHAT_MIN_CHARS:
            errors.append(
                f"task.{tid}.what: minimum length {WHAT_MIN_CHARS} characters not met ({len(what)})"
            )
        if len(why) < WHY_MIN_CHARS:
            errors.append(
                f"task.{tid}.why: minimum length {WHY_MIN_CHARS} characters not met ({len(why)})"
            )
        if len(what) >= DUP_WHAT_MIN_OVERLAP:
            for i in range(0, len(what) - DUP_WHAT_MIN_OVERLAP + 1):
                window = what[i : i + DUP_WHAT_MIN_OVERLAP]
                prev = shingles.get(window)
                if prev and prev != tid:
                    errors.append(
                        f"task.{tid}.what duplicates task.{prev}.what — content must be task-specific"
                    )
                    break
                shingles[window] = tid
    seen = set()
    deduped: list[str] = []
    for e in errors:
        if e not in seen:
            seen.add(e)
            deduped.append(e)
    return deduped


def detect_pattern_2_measurable_criteria(ctx: ValidationContext) -> list[str]:
    """R16: success_criteria measurable_via=manual-check requires verification binding.

    Also (REQUIREMENTS.md edge 3): ``measurable_via: test`` without a
    ``verified_at_phase`` binding is a WARNING, not an error — the binding
    is recommended but not strictly enforced for automated criteria.
    """
    out: list[str] = []
    for sc in ctx.plan.get("success_criteria", []) or []:
        sid = sc.get("id", "?")
        measurable_via = sc.get("measurable_via")
        if measurable_via == "manual-check":
            if not sc.get("verification_steps") and not sc.get("verified_at_phase"):
                out.append(
                    f"project.success_criteria.{sid}: manual-check requires verification_steps or verified_at_phase"
                )
        elif measurable_via == "test" and not sc.get("verified_at_phase"):
            out.append(
                f"WARNING: project.success_criteria.{sid}: measurable_via=test without verified_at_phase binding (recommended for traceability)"
            )
        desc = sc.get("description") or ""
        if ASPIRATIONAL_PATTERN.search(desc.lower()):
            if not re.search(r"[/.]\w+|exit\s*\d+|line|count", desc):
                out.append(
                    f"WARNING: project.success_criteria.{sid}: description uses aspirational language without measurable artefact"
                )
    return out


def detect_pattern_3_exact_paths(ctx: ValidationContext) -> list[str]:
    """R17: glob chars rejected; pending|wip tasks must declare at least one path."""
    out: list[str] = []
    for _phase, task in _tasks(ctx.plan):
        tid = task.get("id", "?")
        where = task.get("where") or {}
        modify = where.get("modify") or []
        create = where.get("create") or []
        delete = where.get("delete") or []
        for sub_name, items in (("modify", modify), ("create", create), ("delete", delete)):
            for i, val in enumerate(items):
                if not isinstance(val, str):
                    continue
                for ch in GLOB_CHARS:
                    if ch in val:
                        out.append(
                            f"task.{tid}.where.{sub_name}[{i}]: glob pattern not allowed, use exact paths"
                        )
                        break
                if "**" in val:
                    out.append(
                        f"task.{tid}.where.{sub_name}[{i}]: glob pattern not allowed, use exact paths"
                    )
        status = task.get("status")
        if status in ("pending", "wip") and not modify and not create and not delete:
            out.append(
                f"task.{tid}.where: at least one of modify|create|delete must contain a path"
            )
    seen = set()
    deduped = []
    for e in out:
        if e not in seen:
            seen.add(e)
            deduped.append(e)
    return deduped


def detect_pattern_4_ears(ctx: ValidationContext) -> list[str]:
    """R18: every acceptance entry must use EARS notation (When/While/If/Where + shall)."""
    out: list[str] = []
    for _phase, task in _tasks(ctx.plan):
        tid = task.get("id", "?")
        for i, entry in enumerate(task.get("acceptance") or []):
            if not isinstance(entry, str):
                continue
            if not entry.startswith(EARS_PREFIXES):
                out.append(
                    f"task.{tid}.acceptance[{i}]: must use EARS notation (When/While/If/Where ... shall ...)"
                )
                continue
            if not EARS_VERB_RE.search(entry):
                out.append(
                    f"task.{tid}.acceptance[{i}]: must use EARS notation (When/While/If/Where ... shall ...)"
                )
    return out


def detect_pattern_5_xrefs(ctx: ValidationContext) -> list[str]:
    """R19: every _refs / depends / plan_phase_id must resolve to a top-level definition."""
    plan = ctx.plan
    kc_ids = {kc.get("id") for kc in plan.get("kill_criteria") or [] if kc.get("id")}
    dn_ids = {dn.get("id") for dn in plan.get("design_notes") or [] if dn.get("id")}
    risk_ids = {r.get("id") for r in plan.get("risks") or [] if r.get("id")}
    deferred_ids = {d.get("id") for d in plan.get("deferred") or [] if d.get("id")}
    phase_ids = {p.get("id") for p in _phases(plan) if p.get("id")}
    task_ids = {t.get("id") for _p, t in _tasks(plan) if t.get("id")}

    ref_map = {
        "kill_criteria_refs": kc_ids,
        "design_notes_refs": dn_ids,
        "risks_refs": risk_ids,
        "deferred_refs": deferred_ids,
    }

    out: list[str] = []
    for phase in _phases(plan):
        pid = phase.get("id", "?")
        for ref_field, target_ids in ref_map.items():
            for i, val in enumerate(phase.get(ref_field) or []):
                if val not in target_ids:
                    out.append(f"phase.{pid}.{ref_field}[{i}]: ID '{val}' does not resolve")
        for task in phase.get("tasks") or []:
            tid = task.get("id", "?")
            for i, dep in enumerate(task.get("depends") or []):
                if dep not in task_ids:
                    out.append(f"task.{tid}.depends[{i}]: ID '{dep}' does not resolve")
            for ref_field, target_ids in ref_map.items():
                for i, val in enumerate(task.get(ref_field) or []):
                    if val not in target_ids:
                        out.append(f"task.{tid}.{ref_field}[{i}]: ID '{val}' does not resolve")
    for i, entry in enumerate(plan.get("scope_mapping_from_backlog") or []):
        ppid = entry.get("plan_phase_id")
        if ppid not in phase_ids:
            out.append(
                f"project.scope_mapping_from_backlog[{i}].plan_phase_id: ID '{ppid}' does not resolve"
            )
    return out


def _path_has_invalid_chars(value: str) -> bool:
    """Return True if ``value`` contains NUL bytes, backslashes, or control
    characters (excluding ``\\t`` / ``\\n``).

    Mirrors the rejection pattern used in :func:`_default_bash_syntax_check`.
    Backslashes are rejected because Windows-style separators are never valid
    plan paths (the schema is POSIX) and they also happen to be a common
    smuggling vector for path-traversal payloads.
    """
    if "\x00" in value:
        return True
    if "\\" in value:
        return True
    if any(0x01 <= ord(c) <= 0x1F and c not in "\t\n" for c in value):
        return True
    return False


def _resolve_path(
    ctx: ValidationContext, value: str
) -> tuple[Path | None, str | None, Path | None]:
    """Return (resolved_path, error_or_None, target_root).

    Resolves qualified paths against test_targets_index when len ≥ 2 and
    rejects path traversal that escapes the target root. Rejects NUL bytes,
    control characters and backslash separators up-front so ``Path.resolve()``
    never sees a smuggled payload.
    """
    if _path_has_invalid_chars(value):
        return None, "invalid path characters (NUL/control/backslash)", None
    qual = _path_qualifier_match(value)
    targets = ctx.test_targets_index
    if qual:
        prefix, rest = qual
        if prefix not in targets:
            return None, f"qualifier '{prefix}:' does not resolve to a test_target", None
        root = targets[prefix].resolve()
        candidate = (root / rest).resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            return None, "path traversal not allowed (resolves outside test_target)", root
        return candidate, None, root
    # Unqualified — repo-relative against plan_dir's parent (worktree root).
    if len(targets) >= 2:
        return (
            None,
            "must be qualified as <test_target_id>:path when test_targets has multiple entries",
            None,
        )
    if targets:
        root = next(iter(targets.values()))
    else:
        root = ctx.plan_dir.resolve()
    candidate = (root / value).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None, "path traversal not allowed (resolves outside test_target)", root
    return candidate, None, root


def validate_path_qualifier(ctx: ValidationContext) -> list[str]:
    """R8: qualifier required when test_targets length ≥ 2; prefix must resolve."""
    out: list[str] = []
    targets = ctx.test_targets_index
    if not targets:
        return out
    for _phase, task in _tasks(ctx.plan):
        tid = task.get("id", "?")
        where = task.get("where") or {}
        for sub in ("modify", "create", "delete"):
            for i, val in enumerate(where.get(sub) or []):
                if not isinstance(val, str):
                    continue
                if any(ch in val for ch in GLOB_CHARS):
                    continue
                _resolved, err, _root = _resolve_path(ctx, val)
                if err:
                    out.append(f"task.{tid}.where.{sub}[{i}]: {err}")
    return out


def validate_artifact_refs(ctx: ValidationContext) -> list[str]:
    """R21: every artifact_refs path on a status: done task must exist on disk."""
    out: list[str] = []
    for _phase, task in _tasks(ctx.plan):
        if task.get("status") != "done":
            continue
        tid = task.get("id", "?")
        refs = task.get("artifact_refs") or {}
        for key, val in refs.items():
            if not isinstance(val, str) or not val:
                continue
            resolved, err, root = _resolve_path(ctx, val)
            if err:
                out.append(f"task.{tid}.artifact_refs.{key}: {err}")
                continue
            if root and not root.exists():
                out.append(f"task.{tid}.artifact_refs.{key}: test_target path not found at {root}")
                continue
            if resolved and not resolved.exists():
                out.append(f"task.{tid}.artifact_refs.{key}: file not found at {resolved}")
    return out


def validate_gate_meta(ctx: ValidationContext) -> list[str]:
    """R20: bash -n every shell cmd; warn on human-only checks for code-bearing phases."""
    out: list[str] = []
    for phase in _phases(ctx.plan):
        pid = phase.get("id", "?")
        gate = phase.get("gate") or {}
        checklist = gate.get("checklist") or []
        has_shell = False
        has_code_acceptance = False
        for task in phase.get("tasks") or []:
            where = task.get("where") or {}
            for sub in ("modify", "create"):
                for entry in where.get(sub) or []:
                    if isinstance(entry, str) and any(
                        entry.endswith(ext) for ext in CODE_FILE_EXTS
                    ):
                        has_code_acceptance = True
        for i, item in enumerate(checklist):
            if not isinstance(item, dict):
                continue
            check = item.get("check") or {}
            # kind=integration is machine-verifiable too (the orchestrator runs
            # the suite at the phase gate) — counts as a non-human check so an
            # integration-only gate on a code-bearing phase is not flagged
            # "human-only" (real integration gates).
            if check.get("kind") == "integration":
                has_shell = True
            if check.get("kind") == "shell":
                has_shell = True
                cmd = check.get("cmd") or ""
                ok, stderr = ctx.bash_checker(cmd)
                if not ok:
                    out.append(
                        f"phase.{pid}.gate.checklist[{i}].cmd: bash syntax error: {stderr.strip()}"
                    )
                runtime = check.get("expected_runtime_seconds")
                if isinstance(runtime, int) and runtime > GATE_RUNTIME_BUDGET_SECONDS:
                    out.append(
                        f"WARNING: phase.{pid}.gate.checklist[{i}]: expected runtime {runtime}s exceeds {GATE_RUNTIME_BUDGET_SECONDS}s budget"
                    )
        if has_code_acceptance and checklist and not has_shell:
            out.append(f"WARNING: phase.{pid}.gate: human-only checklist for code-bearing phase")
    return out


def detect_legacy_artefacts(ctx: ValidationContext) -> list[str]:
    """R14: emit WARNING per sibling legacy file alongside a 2.0 plan."""
    out: list[str] = []
    plan_dir = ctx.plan_dir
    if not plan_dir.exists():
        return out
    for sibling in LEGACY_SIBLINGS:
        if (plan_dir / sibling).exists():
            out.append(
                f"WARNING: {sibling} present alongside 2.0.0 plan at {plan_dir}; "
                f"merge entries into execution-plan.yaml and delete the file. "
                f"See claude/tools/lib/plan_yaml_deferred.py --help for migration patterns."
            )
    return out


def detect_legacy_2_0_field_in_1_x(ctx: ValidationContext) -> list[str]:
    """R13: 1.x plan declaring 2.0-only fields gets a migration warning."""
    out: list[str] = []
    plan = ctx.plan
    legacy_2_0_fields = (
        "vision",
        "users",
        "success_criteria",
        "scope",
        "tech_stack",
        "test_targets",
        "kill_criteria",
        "design_notes",
        "risks",
        "scope_mapping_from_backlog",
        "chain_runtime",
    )
    for f in legacy_2_0_fields:
        if f in plan:
            out.append(
                f"WARNING: 1.x plan declares 2.0 field {f}; consider migrating schema_version to 2.0.0."
            )
    deferred = plan.get("deferred") or []
    for entry in deferred:
        if isinstance(entry, dict) and "kind" in entry:
            out.append(
                "WARNING: 1.x plan declares 2.0 field deferred (with kind); consider migrating schema_version to 2.0.0."
            )
            break
    return out


def _check_acceptance_count(tid: str, task: dict) -> list[str]:
    """R-A1 — acceptance list length must not exceed the hard cap."""
    acc = task.get("acceptance") or []
    if isinstance(acc, list) and len(acc) > MAX_ACCEPTANCE_COUNT:
        return [f"task.{tid}: acceptance count > {MAX_ACCEPTANCE_COUNT} (got {len(acc)})"]
    return []


def _check_lines_estimate(tid: str, estimate: dict) -> list[str]:
    """R-A2 / R-A5 / EC-A.4 — lines_estimate hard cap, warning band, or missing.

    Returns either the missing-estimate WARNING (EC-A.4 / EC-A.5), the hard-cap
    error (R-A2), the warning-band line (R-A5, EC-A.3), or no findings.
    """
    lines = estimate.get("lines_estimate")
    if not estimate or lines in (None, 0):
        return [
            f"WARNING: task.{tid}: estimate missing — populate lines_estimate so the sizing rules can apply"
        ]
    if not isinstance(lines, (int, float)):
        return []
    if lines > LINES_ESTIMATE_HARD_CAP:
        return [f"task.{tid}: lines_estimate > {LINES_ESTIMATE_HARD_CAP} hard cap (got {lines})"]
    if LINES_ESTIMATE_TARGET < lines < LINES_ESTIMATE_HARD_CAP:
        # EC-A.3 — hard cap is silent (cap inclusive); only the
        # open interval (target, cap) warns.
        return [
            f"WARNING: task.{tid}: lines_estimate above {LINES_ESTIMATE_TARGET}-LOC target (got {lines}); split candidate"
        ]
    return []


def _check_duration_hours(tid: str, estimate: dict) -> list[str]:
    """R-A3 / R-A5 — duration_hours hard cap and warning band."""
    hours = estimate.get("duration_hours")
    if not isinstance(hours, (int, float)):
        return []
    if hours > DURATION_HOURS_HARD_CAP:
        return [f"task.{tid}: duration_hours > {DURATION_HOURS_HARD_CAP} hard cap (got {hours})"]
    if DURATION_HOURS_TARGET < hours < DURATION_HOURS_HARD_CAP:
        return [
            f"WARNING: task.{tid}: duration_hours above {DURATION_HOURS_TARGET}h target (got {hours}); split candidate"
        ]
    return []


def _check_touched_paths(tid: str, task: dict) -> list[str]:
    """R-A4 / R-A5 — combined modify+create+delete count must respect the cap."""
    where = task.get("where") or {}
    modify = where.get("modify") or []
    create = where.get("create") or []
    delete = where.get("delete") or []
    path_count = len(modify) + len(create) + len(delete)
    if path_count > MAX_TOUCHED_PATHS_HARD_CAP:
        return [
            f"task.{tid}: touched paths > {MAX_TOUCHED_PATHS_HARD_CAP} hard cap (got {path_count})"
        ]
    if MAX_TOUCHED_PATHS_TARGET < path_count < MAX_TOUCHED_PATHS_HARD_CAP:
        return [
            f"WARNING: task.{tid}: touched paths above {MAX_TOUCHED_PATHS_TARGET}-file target (got {path_count}); split candidate"
        ]
    return []


def validate_task_sizing(ctx: ValidationContext) -> list[str]:
    """Part A — per-task sizing limits (R-A1..R-A9).

    Skipped/done/blocked/failed tasks are exempt (EC-A.6: rules apply forward).
    Each rule emits independently — no short-circuit (EC-A.7). The
    missing-estimate WARNING (EC-A.4 / EC-A.5) does not suppress the
    duration/path checks on populated fields.
    """
    out: list[str] = []
    for _phase, task in _tasks(ctx.plan):
        if task.get("status") in SIZING_EXEMPT_STATUSES:
            continue
        tid = task.get("id", "?")
        estimate = task.get("estimate") or {}
        out.extend(_check_acceptance_count(tid, task))
        out.extend(_check_lines_estimate(tid, estimate))
        out.extend(_check_duration_hours(tid, estimate))
        out.extend(_check_touched_paths(tid, task))
    return out


def _transitive_depends(tasks: list[dict]) -> dict[str, set[str]]:
    """Return ``{task_id: set_of_all_transitive_dependencies}``."""
    direct: dict[str, set[str]] = {}
    for task in tasks:
        tid = task.get("id")
        if not tid:
            continue
        direct[tid] = set(task.get("depends") or [])

    closure: dict[str, set[str]] = {}

    def _walk(node: str, seen: set[str]) -> set[str]:
        if node in closure:
            return closure[node]
        if node in seen:
            return set()
        seen.add(node)
        result: set[str] = set()
        for parent in direct.get(node, set()):
            result.add(parent)
            result |= _walk(parent, seen)
        seen.discard(node)
        closure[node] = result
        return result

    for tid in direct:
        _walk(tid, set())
    return closure


_PARALLELISM_ACTIVE_STATUSES = frozenset({"pending", "wip"})


def _shared_modify_create_paths(a: dict, b: dict) -> list[str]:
    """Return ``where.modify ∪ where.create`` paths shared between two tasks (R-C3).

    ``where.delete`` is excluded by contract.
    """
    a_where = a.get("where") or {}
    b_where = b.get("where") or {}
    paths_a = set(a_where.get("modify") or []) | set(a_where.get("create") or [])
    paths_b = set(b_where.get("modify") or []) | set(b_where.get("create") or [])
    return sorted(paths_a & paths_b)


def _iter_phase_overlap_lines(
    pid: str, active: list[dict], closure: dict[str, set[str]]
) -> Iterator[str]:
    """Yield one warning line per (pair × shared path) without depends coverage.

    Truncation is the caller's job — this generator emits everything it finds.
    """
    for i in range(len(active)):
        for j in range(i + 1, len(active)):
            a, b = active[i], active[j]
            aid = a.get("id", "?")
            bid = b.get("id", "?")
            if bid in closure.get(aid, set()) or aid in closure.get(bid, set()):
                continue
            for path in _shared_modify_create_paths(a, b):
                yield (
                    f"WARNING: phase.{pid}: tasks {aid}, {bid} "
                    f"both write {path} — add depends edge or split phase"
                )


def _validate_phase_parallelism_one(phase: dict) -> list[str]:
    """Emit the parallelism warnings (with truncation summary) for one phase."""
    pid = phase.get("id", "?")
    tasks = phase.get("tasks") or []
    active = [t for t in tasks if t.get("status") in _PARALLELISM_ACTIVE_STATUSES]
    if len(active) < 2:
        return []
    closure = _transitive_depends(active)
    warnings_for_phase: list[str] = []
    truncated = 0
    for line in _iter_phase_overlap_lines(pid, active, closure):
        if len(warnings_for_phase) >= MAX_PARALLELISM_PAIR_WARNINGS:
            truncated += 1
            continue
        warnings_for_phase.append(line)
    if truncated:
        warnings_for_phase.append(
            f"WARNING: phase.{pid}: and {truncated} more parallelism conflicts truncated — disambiguate listed pairs first"
        )
    return warnings_for_phase


def validate_phase_parallelism(ctx: ValidationContext) -> list[str]:
    """Part C — per-phase disjointness check (R-C1..R-C3, R-C5).

    For each phase, every pair of active (pending/wip) tasks with no
    transitive depends edge must have disjoint
    ``where.modify ∪ where.create``. ``where.delete`` is excluded (R-C3).
    All emissions are WARNINGs (C-5). Output is capped at
    ``MAX_PARALLELISM_PAIR_WARNINGS`` per phase with a truncation summary
    line (EC-C.5).
    """
    out: list[str] = []
    for phase in _phases(ctx.plan):
        out.extend(_validate_phase_parallelism_one(phase))
    return out


def _matches_sequencing_enum(stripped: str) -> bool:
    """True if ``stripped`` is an enum value, optionally followed by non-word prose.

    Risk R5 mitigation: ``walking-skeleton — chosen…`` matches, but
    ``walking-skeletons-everywhere`` does not (next char must not be alnum, ``-``, or ``_``).
    """
    for value in SEQUENCING_RATIONALE_ENUM:
        if stripped == value:
            return True
        if stripped.startswith(value):
            next_char = stripped[len(value) : len(value) + 1]
            if next_char and not next_char.isalnum() and next_char not in "-_":
                return True
    return False


def validate_sequencing_rationale_enum(ctx: ValidationContext) -> list[str]:
    """R-C4 — rationale must match enum or be ≥40 chars custom prose.

    Empty/missing rationale is silently passed here (R10 owns presence).
    """
    out: list[str] = []
    for phase in _phases(ctx.plan):
        rationale = phase.get("sequencing_rationale")
        if not rationale or not isinstance(rationale, str):
            continue
        stripped = rationale.strip()
        if _matches_sequencing_enum(stripped):
            continue
        if len(stripped) >= SEQUENCING_RATIONALE_MIN_CHARS_CUSTOM:
            continue
        pid = phase.get("id", "?")
        enum_list = "/".join(sorted(SEQUENCING_RATIONALE_ENUM))
        out.append(
            f"phase.{pid}.sequencing_rationale: must be one of {enum_list} "
            f"OR >={SEQUENCING_RATIONALE_MIN_CHARS_CUSTOM} chars (got {rationale!r}, length {len(stripped)})"
        )
    return out


# Gate scope validation (R-G1, R-G3) — see BACKLOG #48 + watchfloor-list-filters
# Phase 4 STATUS_SORT_ORDER incident (2026-05-06). Path-extraction heuristic:
# tokens that look like project-relative paths starting with a top-level repo
# directory or a known glob root. Conservative — false negatives preferred to
# false positives, since a flagged gate forces the operator to read the rule.
PATH_TOKEN_PREFIXES = (
    "dashboard/",
    "core/",
    "tests/",
    "adapters/",
    "docs/",
    "scripts/",
    "src/",
    "app/",
    "lib/",
    "server/",
    "components/",
    "hooks/",
    "**/",
    "./",
)
# Negative-check pattern detector. Captures the three common shell idioms:
#   !  grep ...
#   test !  -f ...
#   [ !  -e ... ]
# The space after `!` is significant — `!` alone (no space) at start of a
# string can be history expansion; with a following space it's bash NOT.
NEGATIVE_CHECK_RE = re.compile(r"(^|\s|;|&&|\|\|)!\s|\btest\s+!\s|\[\s+!\s")
PATH_TOKEN_RE = re.compile(r"[\w*\-]+(?:/[\w.*\-]*)+/?")  # rough path-shape; allows trailing slash


def _extract_paths_from_cmd(cmd: str) -> list[str]:
    """Extract project-relative path-like tokens from a shell cmd string.

    Heuristic: take every whitespace-separated token, strip surrounding
    quotes, and keep tokens that (a) start with a known top-level repo
    directory prefix and (b) match the rough path-shape regex (must contain
    at least one slash). Filters out flag arguments (`-rn`, `--include=...`)
    and shell operators.

    Returns paths in source order (deduped). Empty list if no path-like
    token is found — a gate cmd with no paths (e.g. `npx vitest run`) is
    treated as scope-less and skipped by R-G1.
    """
    tokens = cmd.split()
    paths: list[str] = []
    seen: set[str] = set()
    for raw in tokens:
        # Strip surrounding quotes (' or ")
        t = raw.strip("'\"")
        # Skip flags
        if t.startswith("-"):
            continue
        # Must look like a path
        if not PATH_TOKEN_RE.fullmatch(t):
            continue
        # Must start with a known prefix (repo-relative)
        if not any(t.startswith(p) for p in PATH_TOKEN_PREFIXES):
            continue
        if t in seen:
            continue
        seen.add(t)
        paths.append(t)
    return paths


def _phase_task_paths(phase: dict) -> list[str]:
    """Collect the union of where.{modify,create,delete} paths across all
    tasks in a phase. Strips path qualifier prefix (`<id>:`) so the
    returned strings are comparable to gate cmd path tokens.
    """
    out: list[str] = []
    for task in phase.get("tasks", []):
        where = task.get("where") or {}
        for bucket in ("modify", "create", "delete"):
            for entry in where.get(bucket, []) or []:
                if not isinstance(entry, str):
                    continue
                # Strip qualifier prefix
                m = PATH_QUALIFIER_RE.match(entry)
                path = m.group(2) if m else entry
                out.append(path)
    return out


def _path_within_scope(gate_path: str, task_paths: list[str]) -> bool:
    """Return True if gate_path is a subpath of, or exactly matches, at
    least one task_path or its immediate parent directory.

    Handles trailing slash variations and glob characters at directory
    boundaries. Treats `**/` glob at start of gate_path as matching any
    parent (equivalent to "anywhere under repo root").
    """
    g = gate_path.rstrip("/")
    if g.startswith("**/"):
        return True  # explicit "search anywhere" — operator's intent
    for tp in task_paths:
        t = tp.rstrip("/")
        # Exact match
        if g == t:
            return True
        # gate is subdir of task (rare but possible — task says dashboard/,
        # gate says dashboard/foo/)
        if g.startswith(t + "/"):
            return True
        # task is subdir of gate's parent — gate looks at task's parent dir
        # Only accept if gate is parent of task by exactly one level OR
        # gate equals task's parent. Anything broader is a scope violation.
        t_parent = "/".join(t.split("/")[:-1])
        if g == t_parent:
            return True
        # gate is subdir of task's parent (still narrower than task's grandparent)
        if g.startswith(t_parent + "/") and len(g) >= len(t_parent):
            return True
    return False


def validate_gate_scope(ctx: ValidationContext) -> list[str]:
    """R-G1 — negative gate check path scope must be subset of phase task scope.

    Restricted to NEGATIVE checks (`! grep`, `test !`, `[ ! ... ]`) because
    those are the only gate kind where path scope error-mode is real and
    high-impact: a `! grep -rn 'X' <broad path>` may match unrelated code
    in domains the phase didn't touch, falsely blocking the gate.
    Positive checks (`grep -q`, `vitest run`, `tsc --noEmit`) reference
    paths that are the constraint itself, not a scope to scan, so a
    "broader than task scope" check would produce false positives on
    legitimate cwd-change (`cd dashboard/app && ...`) and direct file
    references (`vitest run src/__tests__/X.test.tsx`).

    For each negative gate.checklist[i].check.cmd, extract path-like
    tokens. Verify each is a subpath of at least one task_path (or equal
    to a task path's parent directory). Broader paths require an explicit
    `scope_rationale` field on the checklist item to suppress the warning.

    Catches the historical STATUS_SORT_ORDER incident: gate cmd
    `! grep -rn 'X' dashboard/app/src` matches files in feature/,
    autopilot/, etc. — much broader than the phase's task paths in
    dashboard/app/src/components/features/.
    """
    findings: list[str] = []
    for phase in _phases(ctx.plan):
        gate = phase.get("gate") or {}
        if not gate:
            continue
        task_paths = _phase_task_paths(phase)
        if not task_paths:
            # No tasks → no scope reference → can't verify; skip.
            continue
        for idx, item in enumerate(gate.get("checklist") or []):
            check = item.get("check") or {}
            if check.get("kind") != "shell":
                continue
            cmd = check.get("cmd") or ""
            if not cmd:
                continue
            # R-G1 scope: only negative checks. Positive checks have
            # different scope semantics (path is the artefact, not a
            # search scope) and produce too many false positives.
            if not NEGATIVE_CHECK_RE.search(cmd):
                continue
            paths = _extract_paths_from_cmd(cmd)
            if not paths:
                continue
            for gp in paths:
                if _path_within_scope(gp, task_paths):
                    continue
                if (item.get("scope_rationale") or "").strip():
                    continue  # operator explicitly justified the broader scope
                phase_id = phase.get("id", "?")
                findings.append(
                    f"WARNING: gate.{phase_id}.checklist[{idx}]: cmd path "
                    f"'{gp}' is broader than phase task scope "
                    f"({', '.join(sorted(set(task_paths))[:3])}{'...' if len(set(task_paths)) > 3 else ''}); "
                    f"narrow the path or add scope_rationale field"
                )
    return findings


def validate_gate_scope_rationale(ctx: ValidationContext) -> list[str]:
    """R-G3 — negative gate checks require scope_rationale.

    A negative check (`! grep`, `test !`, `[ ! ... ]`) asserts that
    something does NOT exist post-implementation — easiest gate kind to
    over-author with a too-broad path. Requiring a scope_rationale field
    forces the planner to justify the chosen scope before the gate
    ships, surfacing the subtle reasoning that today only lives in the
    Solution Architect's head.

    Emits WARNING (not error) so existing plans validate clean during
    migration. Future plans authored by team-lite/team should fail this
    check until they add the rationale.
    """
    findings: list[str] = []
    for phase in _phases(ctx.plan):
        gate = phase.get("gate") or {}
        if not gate:
            continue
        for idx, item in enumerate(gate.get("checklist") or []):
            check = item.get("check") or {}
            if check.get("kind") != "shell":
                continue
            cmd = check.get("cmd") or ""
            if not cmd:
                continue
            if not NEGATIVE_CHECK_RE.search(cmd):
                continue
            rationale = (item.get("scope_rationale") or "").strip()
            if not rationale:
                phase_id = phase.get("id", "?")
                findings.append(
                    f"WARNING: gate.{phase_id}.checklist[{idx}]: negative check "
                    f"'{cmd[:60]}{'...' if len(cmd) > 60 else ''}' requires "
                    f"scope_rationale field (one-sentence justification of why "
                    f"the chosen path is the right scope)"
                )
    return findings


def _run_negative_check_dry(cmd: str, repo_root: Path) -> tuple[bool, str]:
    """Execute a negative gate check against the current repo state.

    Returns (matched, output). matched=True means the negative check's
    body matched something (i.e. the gate is mathematically pre-broken
    if work hasn't happened yet). Conservative: only runs if cmd looks
    like a safe absence-check (whitelist of grep/find/test forms).
    Anything else returns (False, 'skipped: not whitelisted').
    """
    # Whitelist: cmd must start with `!` followed by grep/find/test/[
    # OR `test !` OR `[ !`.
    safe_re = re.compile(r"^\s*(!\s+(grep|find|test|\[)|test\s+!\s|\[\s+!\s)")
    if not safe_re.match(cmd):
        return False, "skipped: not whitelisted"
    # Reject cmd that includes destructive operators
    if any(tok in cmd for tok in (">", ">>", "rm ", "rm\t", "|tee ", " | tee ")):
        return False, "skipped: contains destructive operator"
    if len(cmd) > MAX_GATE_CMD_LEN:
        return False, "skipped: cmd exceeds length budget"
    try:
        result = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            cwd=str(repo_root),
            timeout=BASH_SYNTAX_TIMEOUT,
            shell=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:  # pragma: no cover
        return False, f"skipped: {exc}"
    # Negative check via `!`: cmd exits 0 when the inner command found
    # NOTHING (success of the negation). Exit non-zero means the inner
    # command found something (negation fails). For `test !` the same
    # logic applies. So:
    #   exit 0  → check passes against current state (not pre-broken)
    #   exit 1+ → check fails against current state (pre-broken)
    matched = result.returncode != 0
    return matched, (result.stdout or result.stderr or "")[:200]


def validate_gate_dry_run(ctx: ValidationContext, repo_root: Path | None = None) -> list[str]:
    """R-G2 — dry-run negative gate checks against the current working tree.

    For each gate.checklist[i] with a negative shell check, execute the
    cmd against the current repo state. If the inner command finds a
    match (gate fails its assertion), the gate is mathematically broken
    before any work has happened — no implementation can satisfy it
    until the existing matches are removed or the path scope is
    narrowed.

    Opt-in via the `dry_run_gates=True` flag on ValidationContext. Off
    by default because it executes shell processes; use --dry-run-gates
    on validate-plan.py to opt in at CLI level.
    """
    if not getattr(ctx, "dry_run_gates", False):
        return []
    if repo_root is None:
        repo_root = Path.cwd()
    findings: list[str] = []
    for phase in _phases(ctx.plan):
        gate = phase.get("gate") or {}
        if not gate:
            continue
        for idx, item in enumerate(gate.get("checklist") or []):
            check = item.get("check") or {}
            if check.get("kind") != "shell":
                continue
            cmd = check.get("cmd") or ""
            if not NEGATIVE_CHECK_RE.search(cmd):
                continue
            matched, output = _run_negative_check_dry(cmd, repo_root)
            if matched:
                phase_id = phase.get("id", "?")
                findings.append(
                    f"gate.{phase_id}.checklist[{idx}]: cmd already matches "
                    f"against current state — gate is mathematically pre-broken "
                    f"before any work has happened. Output: {output[:120]!r}"
                )
    return findings


RUNNER_ENV_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


def _runner_env_findings(
    pi: int, ti: int, tid: str, env: dict
) -> list[tuple[int, int, int, str, str]]:
    """Check one task's runner.env dict — returns sortable finding tuples."""
    out: list[tuple[int, int, int, str, str]] = []
    for k, v in env.items():
        if not isinstance(k, str) or not RUNNER_ENV_KEY_RE.match(k):
            out.append((pi, ti, 0, str(k),
                f"ERROR: Task '{tid}' runner.env key '{k}' "
                f"violates POSIX convention (^[A-Z][A-Z0-9_]*$)."))
        if not isinstance(v, str):
            out.append((pi, ti, 1, str(k),
                f"ERROR: Task '{tid}' runner.env value for key '{k}' "
                f"is not a string (got: {type(v).__name__})."))
    return out


def _runner_flags_findings(
    pi: int, ti: int, tid: str, flags: list
) -> list[tuple[int, int, int, str, str]]:
    """Check one task's runner.flags list — returns sortable finding tuples."""
    return [
        (pi, ti, 2, f"{fi:09d}",
         f"ERROR: Task '{tid}' runner.flags entry at index {fi} "
         f"is not a string (got: {type(f).__name__}).")
        for fi, f in enumerate(flags)
        if not isinstance(f, str)
    ]


def _runner_task_findings(
    pi: int, ti: int, task: dict
) -> list[tuple[int, int, int, str, str]]:
    """Check one task's runner block — dispatches to env + flags helpers."""
    runner = task.get("runner")
    if not isinstance(runner, dict):
        return []
    tid = task.get("id", "?")
    out: list[tuple[int, int, int, str, str]] = []
    env = runner.get("env")
    if isinstance(env, dict):
        out.extend(_runner_env_findings(pi, ti, tid, env))
    flags = runner.get("flags")
    if isinstance(flags, list):
        out.extend(_runner_flags_findings(pi, ti, tid, flags))
    return out


def compute_runner_override_findings(plan: dict) -> list[str]:
    """Pure function — single source of truth for R10/R30 diagnostics.

    Walks every task in the plan and emits operator-facing diagnostics
    for any malformed ``task.runner.env`` key (POSIX pattern violation
    or non-string value) or non-string ``task.runner.flags`` entry.
    Augments — does NOT replace — the schema-structural errors of R8/R9
    (Q1 = augment). The env-key regex mirrors the schema's
    ``$defs.task_runner.env.patternProperties`` at
    ``core/schema/execution-plan.schema.json`` — if one moves, update
    ``RUNNER_ENV_KEY_RE`` to match.

    Output is deterministic per R30: findings are sorted by
    ``(phase_index, task_index, violation_type, key_or_index_string)``
    so multi-violation plans render identical line ordering across runs.

    Public symbol called by both the legacy 1.x dispatcher (via
    ``validate-plan.py``'s ``validate_runner_overrides_semantic``) and
    the 2.0 dispatcher (via ``validate_runner_overrides`` below). Kept
    public (no leading underscore) because the cross-module 1.x call
    site relies on the import surface being stable.
    """
    findings: list[tuple[int, int, int, str, str]] = []
    for pi, phase in enumerate(plan.get("phases", []) or []):
        for ti, task in enumerate(phase.get("tasks", []) or []):
            findings.extend(_runner_task_findings(pi, ti, task))
    findings.sort()
    return [m for *_, m in findings]


def validate_runner_overrides(ctx: ValidationContext) -> list[str]:
    """2.0 dispatcher entry-point — thin shim over the pure function."""
    return compute_runner_override_findings(ctx.plan)


# Frozen-evidence WORM fields — populated once by /done at the wip→done
# transition, then immutable. Only /plan-project --update (with full
# $.** authority) may rewrite them. Mirrors the ``worm_when_done``
# section of core/schema/plan-field-ownership.yaml — kept in sync there.
FROZEN_EVIDENCE_FIELDS = ("codebase_snapshot", "predecessor_context")


def detect_frozen_evidence_drift(ctx: ValidationContext) -> list[str]:
    """Plan-ownership Track 4: surface modifications to frozen-evidence
    fields on done tasks.

    A WARNING-level finding (not an error) is emitted for any done task
    whose ``codebase_snapshot`` or ``predecessor_context`` differs from
    the version in the file's git HEAD parent. The PreToolUse hook + the
    pre-commit validator already block such writes at the source; this
    validator is a third-layer trip-wire that runs during
    ``validate-plan.py`` (e.g. in CI) to catch any drift that slipped
    through (e.g. a manual operator edit that bypassed both hooks).

    Returns the empty list when ``ctx.plan_dir`` is not a git worktree
    (e.g. tests that build a plan in /tmp without a parent commit).

    The check is intentionally observational: it does NOT block validate-
    plan.py from succeeding — drift here is informational because the
    hook + pre-commit layers are the binding enforcement points. Only
    the warning ratchet would surface this to operators reviewing the
    autopilot stream.
    """
    findings: list[str] = []
    plan_dir = ctx.plan_dir
    if not plan_dir or not plan_dir.exists():
        return findings
    try:
        # Identify the canonical plan file
        plan_yaml = plan_dir / "execution-plan.yaml"
        if not plan_yaml.exists():
            return findings
        # Get prior version of this file at HEAD~1 (or HEAD if no parent)
        rev = "HEAD"
        prior = subprocess.run(
            ["git", "-C", str(plan_dir), "show", f"{rev}:./{plan_yaml.name}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if prior.returncode != 0:
            # No git history yet (fresh plan) — nothing to compare.
            return findings
    except (subprocess.SubprocessError, OSError):
        return findings

    try:
        import yaml as _yaml
    except ImportError:
        return findings
    try:
        prior_plan = _yaml.safe_load(prior.stdout or "") or {}
    except _yaml.YAMLError:
        return findings

    def _task_snapshot(plan: dict, tid: str) -> dict | None:
        for phase in plan.get("phases", []) or []:
            for task in phase.get("tasks", []) or []:
                if task.get("id") == tid:
                    return dict(task) if isinstance(task, dict) else None
        return None

    for _phase, task in _tasks(ctx.plan):
        if task.get("status") != "done":
            continue
        tid = task.get("id")
        if not tid:
            continue
        prior_task = _task_snapshot(prior_plan, tid)
        if prior_task is None:
            # New done task (just transitioned) — no prior version to
            # compare against. Skip.
            continue
        for fld in FROZEN_EVIDENCE_FIELDS:
            cur_val = task.get(fld)
            prior_val = prior_task.get(fld)
            if cur_val is None and prior_val is None:
                continue
            if cur_val != prior_val:
                findings.append(
                    f"WARNING: task.{tid}.{fld} drifted from HEAD on a done "
                    f"task — frozen-evidence WORM violation. Only "
                    f"/plan-project --update may rewrite this field. "
                    f"If this drift is intentional, run /plan-project --update."
                )
    return findings


VALIDATORS_2_0: list[Callable[[ValidationContext], list[str]]] = [
    validate_2_0_completeness,
    validate_polymorphic_deferred,
    validate_unique_task_ids,
    detect_pattern_1_stub_strings,
    detect_pattern_2_measurable_criteria,
    detect_pattern_3_exact_paths,
    detect_pattern_4_ears,
    detect_pattern_5_xrefs,
    validate_path_qualifier,
    validate_artifact_refs,
    validate_gate_meta,
    detect_legacy_artefacts,
    validate_task_sizing,
    validate_phase_parallelism,
    validate_sequencing_rationale_enum,
    validate_gate_scope,
    validate_gate_scope_rationale,
    validate_runner_overrides,
    detect_frozen_evidence_drift,
    # validate_gate_dry_run intentionally omitted — opt-in via CLI flag
    # to avoid surprise shell execution during routine validation.
]


def run_all(ctx: ValidationContext) -> list[str]:
    """Run every registered validator and concatenate findings.

    The opt-in dry-run-gates pass runs separately because it needs the
    repo root path that the dispatcher knows but ctx does not carry
    explicitly. validate-plan.py invokes it after run_all when
    --dry-run-gates is passed.
    """
    out: list[str] = []
    for fn in VALIDATORS_2_0:
        out.extend(fn(ctx))
    return out
