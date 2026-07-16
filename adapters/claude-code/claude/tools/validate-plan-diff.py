#!/usr/bin/env python3
"""Pre-commit defense-in-depth plan-diff validator (plan-ownership Track 3).

Reads `git diff --cached -- '*/execution-plan.yaml'` from the current
worktree, computes which plan fields the staged change touches, and
verifies the change is authorized for the current phase per
``core/schema/plan-field-ownership.yaml``.

Pair-of-eyes for the Track 2 ``PreToolUse`` hook: catches the union of
edits done during a phase (even ones routed through shell/python that
bypass the per-tool-call hook). Stops at the commit boundary.

Usage::

    python3 validate-plan-diff.py [--plan-path <glob>]

Environment::

    AUTOPILOT_CURRENT_PHASE      ba|plan|implement|qa|... (empty = interactive)
    AUTOPILOT_CURRENT_TASK_ID    current task id (empty allowed)

Exit codes::

    0   OK to commit (no plan diff, or staged diff within phase allowlist,
        or interactive session)
    1   Denied — at least one staged plan field is outside the allowlist.
        The commit should be aborted; the operator should unstage and
        either drop the change or invoke /plan-project --update.
    2   Internal error (missing dependency, malformed input)

Intended use as a git pre-commit hook::

    # in .git/hooks/pre-commit:
    python3 ~/.claude/tools/validate-plan-diff.py || exit 1
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

# Reuse the proven matrix-loading + allowlist logic from the PreToolUse
# helper. This is the same module mounted at a different layer of the
# pipeline (pre-commit vs PreToolUse), so the field-ownership rules
# stay strictly in one place.
_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE / "lib"))
try:
    from importlib import import_module

    _check_module = import_module("plan-ownership-check")
except Exception as e:  # pragma: no cover
    print(f"ERROR: cannot import plan-ownership-check helper: {e}", file=sys.stderr)
    sys.exit(2)

_load_matrix = _check_module._load_matrix
_decision = _check_module._decision
_extract_path_field_tokens = _check_module._extract_path_field_tokens  # noqa: F401
_phase_field_allowlist = _check_module._phase_field_allowlist  # noqa: F401


# ─── Diff collection ─────────────────────────────────────────────────────────


def _staged_plan_diff() -> str:
    """Return the staged diff for any execution-plan.yaml in the worktree.

    Uses three-dot semantics implicitly via --cached (staged-vs-HEAD).
    """
    try:
        proc = subprocess.run(
            [
                "git",
                "diff",
                "--cached",
                "--no-color",
                "--unified=0",
                "--",
                "*execution-plan.yaml",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.SubprocessError, OSError) as e:
        print(f"ERROR: git diff --cached failed: {e}", file=sys.stderr)
        sys.exit(2)
    return proc.stdout or ""


# ─── Diff parsing ────────────────────────────────────────────────────────────


def _split_diff_into_old_new(diff: str) -> tuple[str, str]:
    """Collect every `-` line into old_text and every `+` line into new_text.

    Drops diff headers (``diff --git ...``, ``index ...``, ``--- a/...``,
    ``+++ b/...``) and hunk markers (``@@ -.. +..``).
    """
    old_lines: list[str] = []
    new_lines: list[str] = []
    for line in diff.splitlines():
        if line.startswith(("diff ", "index ", "---", "+++", "@@", "\\")):
            continue
        if line.startswith("-"):
            old_lines.append(line[1:])
        elif line.startswith("+"):
            new_lines.append(line[1:])
        # context lines (starting with " ") are dropped — they appear in
        # both old and new at the same place, so they'd cancel anyway.
    return "\n".join(old_lines), "\n".join(new_lines)


# ─── Entry point ─────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="validate-plan-diff.py",
        description=(
            "Defense-in-depth: validate that the staged plan diff matches "
            "the current phase's write authority per "
            "core/schema/plan-field-ownership.yaml."
        ),
    )
    ap.parse_args(argv)

    phase = (os.environ.get("AUTOPILOT_CURRENT_PHASE") or "").strip()
    task_id = (os.environ.get("AUTOPILOT_CURRENT_TASK_ID") or "").strip()

    # Interactive session — operator in the loop, allow.
    if not phase:
        return 0

    diff = _staged_plan_diff()
    if not diff.strip():
        # Nothing about the plan is staged. Pass.
        return 0

    matrix = _load_matrix()
    if not matrix:
        print(
            "[validate-plan-diff] WARN: plan-field-ownership.yaml not found, fail-open.",
            file=sys.stderr,
        )
        return 0

    old_text, new_text = _split_diff_into_old_new(diff)

    decision, reason = _decision(
        matrix=matrix,
        phase=phase,
        task_id=task_id,
        intent=(os.environ.get("PLAN_WRITE_INTENT") or "").strip(),
        old_text=old_text,
        new_text=new_text,
    )

    if decision == "allow":
        return 0

    # Denied — emit a human-readable message + abort the commit.
    print(
        f"\n[validate-plan-diff] COMMIT REJECTED on phase /{phase}:\n"
        f"  {reason}\n"
        f"\n"
        f"To proceed, either:\n"
        f"  1. Unstage the plan changes:\n"
        f"     git restore --staged docs/INPROGRESS_Plan_*/execution-plan.yaml\n"
        f"  2. If the change is intentional (e.g. canary task description "
        f"rewrite),\n     invoke /plan-project --update in an interactive "
        f"session. Phase agents may\n     not silently rewrite the plan.\n"
        f"\n"
        f"See docs/A_B_test_canary-models/PLAN_OWNERSHIP_PROPOSAL.md for context.\n",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
