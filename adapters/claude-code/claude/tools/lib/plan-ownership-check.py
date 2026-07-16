#!/usr/bin/env python3
"""Plan-ownership write authority checker (plan-ownership Track 2 helper).

Called by ``adapters/claude-code/claude/hooks/plan-ownership-guard.sh``.
Encapsulates the YAML / JSON parsing the bash hook would otherwise need.

Input (stdin): a single JSON object with at minimum::

    {
      "tool_name": "Edit"|"Write"|"NotebookEdit",
      "tool_input": {
        "file_path": "<absolute or relative path>",
        "old_string": "<for Edit only>",
        "new_string": "<for Edit only>",
        "content":    "<for Write only>",
        ...
      }
    }

Plus environment::

    AUTOPILOT_CURRENT_PHASE     ba|plan|implement|qa|... ("interactive" if unset)
    AUTOPILOT_CURRENT_TASK_ID   the active task id ("" if unset)
    PLAN_WRITE_INTENT           phase_results|finalize_phase_results|...
                                (set by orchestrator helpers; empty otherwise)
    PLAN_OWNERSHIP_GUARD_MODE   warn|deny (default: deny). warn = log + allow.

Output (stdout): a single JSON object the hook will pass through verbatim
to the Claude Code PreToolUse contract::

    {"permissionDecision": "allow"}            # silent allow
    {"permissionDecision": "deny",
     "permissionDecisionReason": "<text>"}      # block + agent-visible reason

When in warn mode, even denies are mapped to {"permissionDecision":"allow"}
and the would-be denial is logged to stderr instead.

Exit codes:
    0   any decision (allow OR deny). The hook routes accordingly.
    2   malformed input (the hook will allow + log; fail-safe for the agent).

The hook (bash) is intentionally thin so the parsing logic + YAML loader
have a stable, testable Python surface. The hook decides what to do with
the JSON returned here (exit 0 vs 2).
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required", file=sys.stderr)
    sys.exit(2)


# ─── Matrix loader ──────────────────────────────────────────────────────────


def _repo_root() -> Path:
    """Walk upward from this script to find the repo root (looks for core/schema/)."""
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "core" / "schema" / "plan-field-ownership.yaml").exists():
            return parent
    return Path("/")


def _load_matrix() -> dict:
    matrix_path = _repo_root() / "core" / "schema" / "plan-field-ownership.yaml"
    if not matrix_path.exists():
        # Fall back to ~/.claude/schema if deployed there
        alt = Path.home() / ".claude" / "schema" / "plan-field-ownership.yaml"
        if alt.exists():
            matrix_path = alt
    if not matrix_path.exists():
        return {}
    try:
        with open(matrix_path) as f:
            return yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return {}


# ─── Path utilities ─────────────────────────────────────────────────────────

PLAN_PATH_PATTERNS = (
    re.compile(r"/docs/INPROGRESS_Plan_[^/]+/execution-plan\.yaml$"),
    re.compile(r"/docs/DONE_Plan_[^/]+/execution-plan\.yaml$"),
    re.compile(r"/execution-plan\.yaml$"),  # bare path during tests
)


def _is_plan_file(path: str) -> bool:
    if not path:
        return False
    canonical = path
    return any(p.search(canonical) for p in PLAN_PATH_PATTERNS)


def _matches_oracle(file_path: str, globs: list[str]) -> bool:
    """True if file_path matches any integration-oracle glob (Guard #2).

    Matches against both the path as given and its repo-relative form, so an
    absolute Edit target and a repo-relative glob (e.g. ``dashboard/tests/**``)
    still meet. ``fnmatch`` ``*`` spans ``/`` (like the bash trigger matcher), so
    ``dashboard/tests/**`` matches ``dashboard/tests/_lib/sandbox.sh``.
    """
    import fnmatch

    candidates = {file_path, file_path.lstrip("./")}
    try:
        root = str(_repo_root())
        if file_path.startswith(root):
            candidates.add(file_path[len(root):].lstrip("/"))
    except Exception:
        pass
    return any(
        fnmatch.fnmatch(cand, g)
        for cand in candidates
        for g in globs
        if g.strip()
    )


# ─── Diff analysis ──────────────────────────────────────────────────────────


def _touched_task_ids(diff_text: str) -> set[str]:
    """Best-effort extraction of which task `id:` values the diff touches.

    The naive heuristic: any line in the diff containing `id: <task-id>` is
    counted. The hook treats any non-current task ID as a sibling write.

    `diff_text` is the union of old_string + new_string for Edit, or content
    for Write. We don't have access to the full file context; we use what's
    in the diff window.
    """
    out: set[str] = set()
    for m in re.finditer(r"\bid:\s*([A-Za-z0-9][A-Za-z0-9_-]+)", diff_text):
        out.add(m.group(1))
    return out


def _key_value_pairs(text: str) -> set[tuple[str, str]]:
    """Parse text as YAML-ish key:value lines, return (key, normalized-value) set.

    Whitespace-stripped value comparison so cosmetic re-indentation
    isn't counted as a modification.
    """
    pairs: set[tuple[str, str]] = set()
    for m in re.finditer(
        r"^[\s+-]*([A-Za-z_][A-Za-z0-9_-]*):\s*(.*?)\s*$",
        text,
        re.MULTILINE,
    ):
        pairs.add((m.group(1), m.group(2).strip()))
    return pairs


def _diff_paths(old_text: str, new_text: str = "") -> set[str]:
    """Return field tokens whose values DIFFER between old and new.

    For Edit calls, this is the union of:
      - Keys present in `new` but absent (or different value) in `old`  (added/modified)
      - Keys present in `old` but absent in `new`                       (deleted)

    For Write calls, the caller passes the full content as `old_text`
    with `new_text=""` so every key is reported as touched (the file is
    replaced wholesale).
    """
    old_pairs = _key_value_pairs(old_text)
    new_pairs = _key_value_pairs(new_text) if new_text else set()

    # Pure Write (no new_text): everything in old is touched
    if not new_text:
        return {k for (k, _) in old_pairs}

    only_in_new = new_pairs - old_pairs
    only_in_old = old_pairs - new_pairs
    return {k for (k, _) in only_in_new | only_in_old}


def _diff_status_done(diff_text: str) -> bool:
    """Heuristic: does the diff touch a `status: done` line (in either old or new)?"""
    return bool(re.search(r"\bstatus:\s*done\b", diff_text))


def _diff_touches_codebase_snapshot(diff_text: str) -> bool:
    return bool(
        re.search(
            r"\b(codebase_snapshot|predecessor_context|signature|interfaces_introduced)\b",
            diff_text,
        )
    )


# ─── Allowlist matching ─────────────────────────────────────────────────────


def _extract_path_field_tokens(jsonpath: str) -> list[str]:
    """Extract every field token from a JSONPath expression.

    For a path like
    ``$.phases[*].tasks[?(@.id==$CURRENT_TASK_ID)].artifact_refs.static_analysis_path``
    return ``['phases', 'tasks', 'artifact_refs', 'static_analysis_path']``.

    Wildcards (``.*``, ``[*]``) contribute their parent only — the parent
    becomes a "subtree-allowed" anchor that lets any child token pass.

    The full-plan wildcard ``$.**`` returns ``['*']`` (sentinel: any field).
    """
    if jsonpath == "$.**":
        return ["*"]
    tokens: list[str] = []
    # Match each `.name` or `.name.*` segment after the root.
    # Filter expressions like [?(@.id==...)] and [*] are not field names.
    for seg in re.split(r"\[[^\]]*\]", jsonpath):
        for m in re.finditer(r"\.([A-Za-z_][A-Za-z0-9_-]*)", seg):
            tokens.append(m.group(1))
    return tokens


def _phase_field_allowlist(matrix: dict, phase: str) -> list[str]:
    """Return all field-tokens this phase is allowed to write.

    Includes both leaf fields and their ancestor container fields so that
    e.g. writing ``artifact_refs.static_analysis_path`` does not trip
    on the structurally-required ``artifact_refs:`` parent key.
    """
    rule = (matrix.get("write_allowlist") or {}).get(phase) or {}
    raw_paths = rule.get("paths") or []
    fields: list[str] = []
    for p in raw_paths:
        fields.extend(_extract_path_field_tokens(p))
    return fields


def _intent_allowlist(matrix: dict, intent: str) -> list[str]:
    """Return field-tokens allowed under a PLAN_WRITE_INTENT carve-out.

    Includes ancestor fields per ``_extract_path_field_tokens``.
    """
    intents = matrix.get("legitimate_writers") or {}
    rule = intents.get(intent) or {}
    raw_paths = rule.get("allowed_paths") or []
    fields: list[str] = []
    for p in raw_paths:
        fields.extend(_extract_path_field_tokens(p))
    return fields


# ─── Decision logic ─────────────────────────────────────────────────────────

# Top-level plan/phase/task field names we care about. Anything else in a
# diff is treated as YAML structural noise (descendants of container fields
# like codebase_snapshot.commit_ref, phase_results[].phase, etc.). The hook
# checks ONLY the intersection of touched-tokens × this set against the
# allowlist; non-task-level tokens are ignored.
#
# Sourced from core/schema/execution-plan.schema.json $defs.task_2_0 +
# phase_2_0 + plan_2_0 properties.
TASK_LEVEL_FIELDS: frozenset[str] = frozenset(
    {
        # Required task fields
        "id",
        "name",
        "task_type",
        "status",
        "what",
        "why",
        "where",
        "acceptance",
        "prompt",
        # Common optional task fields
        "depends",
        "constraints",
        "estimate",
        "last_updated",
        "manualtest_scenarios",
        "manual_test",
        "parallel_group",
        "runner",
        "autopilot",
        "description",
        # Auto-populated by /done + Shared Closing Step
        "artifact_refs",
        "codebase_snapshot",
        "predecessor_context",
        "phase_results",
        "deviations",
        "deferred_refs",
        "delivered_beyond_plan",
        "remaining_gaps",
        "scope_change",
        "auto_update",
        "pipeline",
        "extensions",
        # Common artifact_refs sub-keys (each phase may set one of these)
        "requirements_path",
        "plan_path",
        "testplan_path",
        "review_path",
        "team_review_path",
        "static_analysis_path",
        "qa_report_path",
        "team_qa_path",
        "manualtest_path",
        # Phase-level fields
        "tasks",
        "overview_summary",
        "sequencing_rationale",
        "cross_cutting_constraints",
        "kill_criteria_refs",
        "gate",
        "advisory",
        # Plan-level fields
        "phases",
        "schema_version",
        "vision",
        "users",
        "success_criteria",
        "scope",
        "tech_stack",
        "setup",
        "test_targets",
        "kill_criteria",
        "design_notes",
        "risks",
        "deferred",
        "changelog",
        "retro",
        "retro_findings",
        "existing_infrastructure_to_reuse",
    }
)

# Container fields — when present in an allowed-write diff, their children
# are auto-allowed (operator wrote the parent; YAML structurally requires
# the children to appear in the diff).
CONTAINER_PARENTS: frozenset[str] = frozenset(
    {
        "codebase_snapshot",
        "predecessor_context",
        "artifact_refs",
        "phase_results",
        "deviations",
        "where",
        "estimate",
        "runner",
        "interfaces_introduced",
        "modules_changed",
        "tests_added",
    }
)


def _decision(
    matrix: dict,
    phase: str,
    task_id: str,
    intent: str,
    old_text: str,
    new_text: str = "",
) -> tuple[str, str]:
    """Return (decision, reason). decision ∈ {"allow", "deny"}.

    Pure function — no env reads, no I/O. Easy to unit test.
    """
    # Whole-plan authors get an unconditional pass.
    if phase == "plan-project":
        return "allow", ""

    # Restrict to known task/phase/plan-level field names. Other diff tokens
    # (commit_ref, role, signature, conformance, phase, etc.) are children
    # of CONTAINER_PARENTS that appear in the diff for YAML structural
    # reasons — they are evaluated only via their container parent.
    raw_touched = _diff_paths(old_text, new_text)
    touched_fields = raw_touched & TASK_LEVEL_FIELDS

    # Detect ANY genuine value change in the diff (not just task-level
    # keys — also nested container children like `signature:`). This is
    # the sibling-task-edit detection signal: if old_text → new_text
    # changes any key:value pair AND the diff context anchors on a task
    # ID that's not the current one, it's a sibling rewrite.
    diff_has_value_change = bool(raw_touched)

    # Task IDs anywhere in the diff context (old OR new).
    all_ids_in_diff = _touched_task_ids(old_text) | _touched_task_ids(new_text)
    # If the diff produced ANY value change AND the surrounding context
    # mentions task IDs, those IDs are the agents' targets.
    touched_tasks: set[str] = set()
    if diff_has_value_change:
        touched_tasks = all_ids_in_diff

    # PLAN_WRITE_INTENT carve-out: the orchestrator declared an intent;
    # the diff must match the intent's allowed fields AND must touch only
    # the current task.
    if intent:
        intent_fields = set(_intent_allowlist(matrix, intent))
        if not intent_fields:
            return "deny", (
                f"PLAN_WRITE_INTENT={intent} is not a recognized intent in "
                f"plan-field-ownership.yaml/legitimate_writers"
            )
        unauthorized = touched_fields - intent_fields
        if unauthorized:
            return "deny", (
                f"PLAN_WRITE_INTENT={intent} allows {sorted(intent_fields)} but "
                f"the diff also touches {sorted(unauthorized)}. Carve-out scope "
                f"is exceeded."
            )
        # The diff is consistent with the intent. Allow.
        return "allow", ""

    # Phase write_allowlist check
    phase_fields = set(_phase_field_allowlist(matrix, phase))
    if "*" in phase_fields:
        return "allow", ""
    if not phase_fields:
        return "deny", (
            f"Phase /{phase} has no plan-write authority under autopilot. "
            f"The diff touches plan fields {sorted(touched_fields)}. "
            f"If this is intended (e.g. operator-driven update to canary "
            f"task descriptions), invoke /plan-project --update interactively."
        )
    unauthorized = touched_fields - phase_fields
    if unauthorized:
        return "deny", (
            f"Phase /{phase} may write {sorted(phase_fields)} but the diff "
            f"touches {sorted(unauthorized)}."
        )

    # Cross-task check: even an authorized field is forbidden if the diff
    # rewrites a sibling task.
    if task_id and touched_tasks and (touched_tasks - {task_id}):
        siblings = sorted(touched_tasks - {task_id})
        return "deny", (
            f"Phase /{phase} edits should only touch the current task "
            f"({task_id}). The diff also touches task IDs {siblings}. "
            f"Sibling task rewrites must go through /plan-project --update."
        )

    return "allow", ""


# ─── Entry point ────────────────────────────────────────────────────────────


_WHOLE_PLAN_READERS = frozenset({"plan-project", "retro", "done"})


def _handle_read(phase: str, mode: str, file_path: str) -> int:
    """Track 1 hard-enforcement: under autopilot, phase agents must use
    task-view.py instead of Read-ing execution-plan.yaml directly.

    Whole-plan readers (/plan-project, /retro, /done) and interactive
    sessions are allowed.
    """
    # Interactive session — operator in the loop — allow
    if not phase:
        print(json.dumps({"permissionDecision": "allow"}))
        return 0
    # Whole-plan readers always allowed
    if phase in _WHOLE_PLAN_READERS:
        print(json.dumps({"permissionDecision": "allow"}))
        return 0
    # Restricted phase under autopilot — deny with redirect to slicer
    reason = (
        f"Phase /{phase} should use task-view.py for plan orientation, "
        f"not Read directly. Invoke: "
        f"python3 ~/.claude/tools/task-view.py --plan $PLAN_FILE "
        f"--task {os.environ.get('AUTOPILOT_CURRENT_TASK_ID', '<task-id>')} "
        f"--phase {phase}. This returns a per-phase projection of the plan "
        f"with sibling tasks excluded — see plan-detection/SKILL.md Step 1."
    )
    if mode == "warn":
        print(
            f"[plan-ownership-guard] WARN (would_deny Read): phase=/{phase} "
            f"path={file_path} reason={reason}",
            file=sys.stderr,
        )
        print(json.dumps({"permissionDecision": "allow"}))
        return 0
    print(json.dumps({"permissionDecision": "deny", "permissionDecisionReason": reason}))
    return 1


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as e:
        print(f"ERROR: malformed input JSON: {e}", file=sys.stderr)
        sys.exit(2)

    tool_name = payload.get("tool_name", "") if isinstance(payload, dict) else ""
    tool_input = (payload.get("tool_input") or {}) if isinstance(payload, dict) else {}
    file_path = (tool_input.get("file_path") or tool_input.get("file") or "").strip()

    # Guard #2 — integration-gate test-immutability (real integration gates §6.2).
    # During the §4.4 remediation loop the orchestrator runs the fixer subprocess
    # with INTEGRATION_REMEDIATION_ACTIVE=1 and INTEGRATION_ORACLE_GLOBS (newline
    # globs from the manifest's integration_test.oracle_globs). A write to the
    # oracle is DENIED regardless of plan-field rules and regardless of
    # plan-ownership warn/deny mode — a fixer that edits the test it must satisfy
    # produces false green, worse than no gate. The fixer fixes the CODE under
    # test and may add UNIT tests elsewhere (TDD §6b), never the oracle.
    if tool_name in ("Edit", "Write", "NotebookEdit") and (
        os.environ.get("INTEGRATION_REMEDIATION_ACTIVE") or ""
    ).strip() == "1":
        oracle_globs = [
            g for g in (os.environ.get("INTEGRATION_ORACLE_GLOBS") or "").splitlines() if g.strip()
        ]
        if file_path and _matches_oracle(file_path, oracle_globs):
            reason = (
                "[plan-ownership-guard] Guard #2 (test-immutability): the integration "
                f"remediation fixer may not {tool_name} the oracle ({file_path}). Fix the "
                "CODE under test and add UNIT tests elsewhere — never the integration test "
                "that judges the gate (real integration gates §6.2)."
            )
            print(json.dumps({"permissionDecision": "deny", "permissionDecisionReason": reason}))
            return 1  # deny convention: hook maps 1 → exit 2 (Claude Code denial)

    # Not a plan file → silent allow
    if not _is_plan_file(file_path):
        print(json.dumps({"permissionDecision": "allow"}))
        return 0

    phase = (os.environ.get("AUTOPILOT_CURRENT_PHASE") or "").strip()
    task_id = (os.environ.get("AUTOPILOT_CURRENT_TASK_ID") or "").strip()
    intent = (os.environ.get("PLAN_WRITE_INTENT") or "").strip()
    mode = (os.environ.get("PLAN_OWNERSHIP_GUARD_MODE") or "deny").strip().lower()

    # Read tool on the plan: route through Track 1 hard enforcement
    if tool_name == "Read":
        return _handle_read(phase, mode, file_path)

    # Interactive session = operator in the loop = allow with a courtesy log
    if not phase:
        print(
            "[plan-ownership-guard] interactive write to plan: "
            f"tool={payload.get('tool_name')} path={file_path}",
            file=sys.stderr,
        )
        print(json.dumps({"permissionDecision": "allow"}))
        return 0

    # Pull the diff halves separately so the decision function can compare
    # them and only count fields whose values actually differ.
    old_text = ""
    new_text = ""
    if "old_string" in tool_input or "new_string" in tool_input:
        old_text = str(tool_input.get("old_string") or "")
        new_text = str(tool_input.get("new_string") or "")
    elif "content" in tool_input:
        old_text = str(tool_input.get("content") or "")
        # Write tool: no comparison anchor; every key in the content is "touched"
        new_text = ""

    matrix = _load_matrix()
    if not matrix:
        # Matrix missing — fail OPEN so we don't break pipelines on misconfig.
        # Loud log so the operator notices.
        print(
            "[plan-ownership-guard] ERROR: plan-field-ownership.yaml not found, "
            "allowing write by default (fail-open).",
            file=sys.stderr,
        )
        print(json.dumps({"permissionDecision": "allow"}))
        return 0

    decision, reason = _decision(matrix, phase, task_id, intent, old_text, new_text)

    if decision == "allow":
        print(json.dumps({"permissionDecision": "allow"}))
        return 0

    # Denied
    if mode == "warn":
        print(
            f"[plan-ownership-guard] WARN (would_deny): phase=/{phase} task={task_id} "
            f"path={file_path} reason={reason}",
            file=sys.stderr,
        )
        print(json.dumps({"permissionDecision": "allow"}))
        return 0

    # deny mode
    payload_out = {
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }
    print(json.dumps(payload_out))
    # Exit non-zero so callers (including our test) can distinguish deny from allow.
    return 1


if __name__ == "__main__":
    sys.exit(main())
