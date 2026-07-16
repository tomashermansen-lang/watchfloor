"""Producer-side self-review wrapper invoked by /plan-project and /plan.

The wrapper runs ``validate-plan.py`` plus the five pattern checks in
``plan_validators`` and emits a structured JSON result that producer
markdown prompts parse to drive a deterministic retry loop.

Public API
==========

* :func:`self_review(plan_path, attempt=0)` — returns
  :class:`SelfReviewResult` with ``errors``, ``warnings``, ``retry_advised``.
* CLI: ``python3 plan_self_review.py <plan>`` — exit 0 on clean,
  exit 1 if errors remain. The JSON shape on stdout is the contract:

.. code-block:: json

   {
     "errors": [{"pattern_id": "...", "task_id": "...", "field": "...",
                 "exemplar_ref": "claude/skills/plan-producer-patterns/SKILL.md#..."}],
     "warnings": [...],
     "retry_advised": true,
     "attempt": 0,
     "max_retries": 2
   }
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Ensure plan_validators is importable from this same dir.
_LIB_DIR = Path(__file__).resolve().parent
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))

import plan_validators as pv  # noqa: E402

MAX_RETRIES = 2

# Map error substrings → (pattern_id, exemplar anchor) for the producer to
# regenerate against. Pattern 7-9 entries (BACKLOG #45) come BEFORE the
# "required" needle so a sizing/parallelism violation isn't shadowed by a
# completeness match.
_PATTERN_HINTS = (
    ("minimum length", ("stub-strings", "pattern-1")),
    ("duplicates task.", ("stub-strings", "pattern-1")),
    ("aspirational language", ("aspirational-criteria", "pattern-2")),
    ("manual-check requires", ("aspirational-criteria", "pattern-2")),
    ("glob pattern not allowed", ("exact-paths", "pattern-3")),
    ("at least one of modify|create|delete", ("exact-paths", "pattern-3")),
    ("must use EARS notation", ("ears-acceptance", "pattern-4")),
    ("does not resolve", ("xrefs", "pattern-5")),
    # Pattern 7 — oversize-task split (R-A1..R-A4, R-C1).
    ("acceptance count", ("oversize-task-split", "pattern-7")),
    ("lines_estimate", ("oversize-task-split", "pattern-7")),
    ("duration_hours", ("oversize-task-split", "pattern-7")),
    ("touched paths", ("oversize-task-split", "pattern-7")),
    ("estimate missing", ("oversize-task-split", "pattern-7")),
    ("both write", ("oversize-task-split", "pattern-7")),
    # Pattern 9 — walking-skeleton-first sequencing (R-C4). The needle
    # uses the field-prefix instead of the enum-list because the validator
    # alphabetises the enum, putting walking-skeleton last.
    ("sequencing_rationale: must be one of", ("walking-skeleton", "pattern-9")),
    ("required", ("completeness", "pattern-1")),
    ("must be qualified", ("exact-paths", "pattern-3")),
    ("path traversal", ("exact-paths", "pattern-3")),
)
_SKILL_PATH = "claude/skills/plan-producer-patterns/SKILL.md"


@dataclass
class SelfReviewResult:
    errors: list[dict] = field(default_factory=list)
    warnings: list[dict] = field(default_factory=list)
    attempt: int = 0
    max_retries: int = MAX_RETRIES

    @property
    def retry_advised(self) -> bool:
        return bool(self.errors) and self.attempt < self.max_retries

    def to_dict(self) -> dict:
        return {
            "errors": self.errors,
            "warnings": self.warnings,
            "retry_advised": self.retry_advised,
            "attempt": self.attempt,
            "max_retries": self.max_retries,
        }


def _classify(line: str) -> dict:
    """Map a validator error line to a structured finding dict."""
    pattern_id = "unclassified"
    anchor = "self-review"
    for needle, (pid, anc) in _PATTERN_HINTS:
        if needle in line:
            pattern_id, anchor = pid, anc
            break
    task_id = ""
    field_name = ""
    if line.startswith("task.") or line.startswith("phase.") or line.startswith("project."):
        head = line.split(":", 1)[0]
        parts = head.split(".")
        if len(parts) >= 2 and parts[0] == "task":
            task_id = parts[1]
            field_name = ".".join(parts[2:])
        elif len(parts) >= 2 and parts[0] == "phase":
            task_id = parts[1]
            field_name = ".".join(parts[2:])
        else:
            field_name = ".".join(parts[1:])
    return {
        "pattern_id": pattern_id,
        "task_id": task_id,
        "field": field_name,
        "exemplar_ref": f"{_SKILL_PATH}#{anchor}",
        "raw": line,
    }


def self_review(plan_path: Path, attempt: int = 0) -> SelfReviewResult:
    """Run validators and pattern checks against ``plan_path``."""
    import yaml

    plan_path = Path(plan_path)
    plan = yaml.safe_load(plan_path.read_text()) or {}
    ctx = pv.ValidationContext.build(plan, plan_path.parent)
    findings = pv.run_all(ctx)

    errors: list[dict] = []
    warnings: list[dict] = []
    for line in findings:
        target = warnings if line.startswith("WARNING:") else errors
        target.append(_classify(line))

    return SelfReviewResult(errors=errors, warnings=warnings, attempt=attempt)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Self-review a 2.0 plan.")
    parser.add_argument("plan", help="Path to execution-plan.yaml")
    parser.add_argument("--attempt", type=int, default=0)
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit only the JSON result on stdout (default).",
    )
    args = parser.parse_args(argv)
    result = self_review(Path(args.plan), attempt=args.attempt)
    json.dump(result.to_dict(), sys.stdout)
    sys.stdout.write("\n")
    return 1 if result.errors else 0


if __name__ == "__main__":
    sys.exit(main())
