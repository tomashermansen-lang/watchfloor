#!/usr/bin/env python3
"""Generate grinder-plan.yaml from merged normalised findings.

Reads a JSON file of normalised findings (produced by normalise-findings.py),
groups them into batches by file affinity, assigns pass kinds based on
scanner tool names, generates a grinder-plan.yaml, and validates it against
the grinder-plan schema.

CLI:
    python3 grinder-discover.py \
        --project-dir <path> \
        --grinder-dir <path> \
        --schema-dir <path> \
        --tools-dir <path> \
        --findings-json <path> \
        --project-name <name> \
        --git-sha <full-sha> \
        [--batch-size <int>]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path

import yaml

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCANNER_TO_KIND: dict[str, str] = {
    "shellcheck": "mechanical",
    "ruff": "mechanical",
    "eslint": "mechanical",
    "prettier": "mechanical",
    "bandit": "static_analysis",
    "semgrep": "static_analysis",
    "mypy": "static_analysis",
    "tsc": "static_analysis",
    "pip-audit": "cve",
    "npm-audit": "cve",
}

# Per-pass turn-budget constants. Each batch's budget is computed via
# ``compute_estimated_turns(kind, total_findings)`` below, which expands to
# the formula ``max(FLOOR, min(CEILING, N * MULTIPLIER + HEADROOM))`` over
# these named values. Tuning grinder's turn-budget policy is done by
# editing these constants — no other code change is required.
MECHANICAL_TURNS_FLOOR = 8
# Ceiling raised 25→40 and headroom 3→5 on 2026-05-12 after empirical
# observation of pass-mechanical saturation: batches 3, 4, 5, 7 hit
# error_max_turns under the prior caps because claude needs ~1.5-2 turns
# per finding (read → fix → verify) plus 5-7 turns overhead (scanner
# rerun → test → commit). A batch with 15+ findings + 5 turns of
# overhead lands ~30-35 turns total. The prior 25 ceiling chopped
# claude's runtime mid-fix and left partial work. The new 40 ceiling +
# 5 headroom covers batches up to ~35 findings within budget; larger
# batches still clamp but get more useful work done before the cap.
MECHANICAL_TURNS_CEILING = 40
MECHANICAL_TURNS_HEADROOM = 5
STATIC_TURNS_FLOOR = 10
# Ceiling raised 30→50 and headroom 4→6 on 2026-05-12 paralleling the
# mechanical bump. Static-analysis fixes (mypy errors, bandit warnings,
# semgrep findings) are more expensive per-finding than mechanical
# auto-fixes, justifying the multiplier=2 over the mechanical
# multiplier=1 — and likewise need more total budget to converge.
STATIC_TURNS_CEILING = 50
STATIC_TURNS_MULTIPLIER = 2
STATIC_TURNS_HEADROOM = 6

COVERAGE_ESTIMATED_TURNS = 15
# CVE batches: cve.sh ignores the passed-in value; this constant is the
# YAML-side budget recorded for symmetry with the other passes.
CVE_ESTIMATED_TURNS = 15
# Headroom for retries and manual intervention commits during multi-batch runs
STALENESS_BUFFER = 5


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------


def compute_estimated_turns(kind: str, total_findings: int) -> int:
    """Map ``(kind, total_findings)`` to a per-batch turn budget.

    Single source of truth for the turn-budget arithmetic. The shell
    orchestrators consume the result verbatim from ``grinder-plan.yaml``
    and never duplicate the formula.

    - ``mechanical``:      ``max(8, min(25, N + 3))`` — auto-fix passes
      need read+fix+test+commit headroom but cap out quickly because
      mechanical fixes are bounded per file.
    - ``static_analysis``: ``max(10, min(30, 2N + 4))`` — proposals tend
      to require more reasoning per finding, so the slope is steeper and
      the ceiling is higher.
    - ``coverage``:        constant ``COVERAGE_ESTIMATED_TURNS`` (15);
      ``total_findings`` is ignored on this branch — coverage uses a
      fixed budget per the design.
    - ``cve``:             constant ``CVE_ESTIMATED_TURNS`` (15). Per
      ``grinder-cve.sh:219`` the consumer ignores the passed-in value;
      a fixed budget here preserves "existing CVE behaviour" (R3) while
      keeping the dispatch total over the kinds that ``build_plan``
      hands to ``build_batches_for_files``.

    Raises ``ValueError`` for unknown kinds. Today only mechanical /
    static_analysis / coverage / cve reach this path; the raise is a
    defensive signal for any future caller that introduces a new kind
    without updating this dispatch.
    """
    if kind == "mechanical":
        return max(
            MECHANICAL_TURNS_FLOOR,
            min(
                MECHANICAL_TURNS_CEILING,
                total_findings + MECHANICAL_TURNS_HEADROOM,
            ),
        )
    if kind == "static_analysis":
        return max(
            STATIC_TURNS_FLOOR,
            min(
                STATIC_TURNS_CEILING,
                total_findings * STATIC_TURNS_MULTIPLIER + STATIC_TURNS_HEADROOM,
            ),
        )
    if kind == "coverage":
        return COVERAGE_ESTIMATED_TURNS
    if kind == "cve":
        return CVE_ESTIMATED_TURNS
    raise ValueError(f"unknown pass kind for turn budget: {kind!r}")


def group_findings_by_file(findings: list[dict]) -> dict[str, list[dict]]:
    """Group findings by file path."""
    by_file: dict[str, list[dict]] = defaultdict(list)
    for f in findings:
        by_file[f["file"]].append(f)
    return dict(by_file)


def build_batches_for_files(
    kind: str,
    files: list[str],
    by_file: dict[str, list[dict]],
    batch_size: int,
    batch_counter: list[int],
) -> list[dict]:
    """Build batch dicts for a list of files.

    Files sorted by finding count descending (highest-churn first).
    batch_counter is a mutable list[int] for global sequential numbering.
    The pass ``kind`` selects the per-pass formula via
    :func:`compute_estimated_turns`.
    """
    sorted_files = sorted(files, key=lambda f: len(by_file[f]), reverse=True)

    batches: list[dict] = []
    for i in range(0, len(sorted_files), batch_size):
        chunk = sorted_files[i : i + batch_size]
        total_findings = sum(len(by_file[f]) for f in chunk)
        estimated_turns = compute_estimated_turns(kind, total_findings)
        batch_counter[0] += 1
        batch_id = f"batch-{batch_counter[0]:03d}"
        batches.append(
            {
                "id": batch_id,
                "files": chunk,
                "estimated_turns": estimated_turns,
                "status": "pending",
            }
        )
    return batches


def group_files_by_kind(
    by_file: dict[str, list[dict]],
) -> dict[str, list[str]]:
    """Group files by the pass kind of their findings.

    Per EC-5.2, a file with findings from multiple pass kinds appears
    in each kind's file list. This ensures separate passes per kind.
    """
    kind_files: dict[str, set[str]] = defaultdict(set)
    for file_path, findings in by_file.items():
        for f in findings:
            tool = f["tool"]
            kind = SCANNER_TO_KIND.get(tool)
            if kind is None:
                print(
                    f"discover: unknown tool '{tool}' -- assigning to static_analysis",
                    file=sys.stderr,
                )
                kind = "static_analysis"
            kind_files[kind].add(file_path)
    return {k: list(v) for k, v in kind_files.items()}


def build_coverage_pass(
    coverage_files: dict[str, float],
    batch_size: int,
) -> dict:
    """Build a coverage pass dict from a map of {file_path: coverage_pct}.

    Files are sorted by coverage ascending (lowest first = highest impact).
    Batch IDs use cov- prefix. estimated_turns is fixed at COVERAGE_ESTIMATED_TURNS.
    """
    sorted_files = sorted(coverage_files.keys(), key=lambda f: coverage_files[f])

    batches: list[dict] = []
    for i in range(0, len(sorted_files), batch_size):
        chunk = sorted_files[i : i + batch_size]
        batch_num = (i // batch_size) + 1
        batches.append(
            {
                "id": f"cov-{batch_num:03d}",
                "files": chunk,
                "estimated_turns": compute_estimated_turns("coverage", 0),
                "status": "pending",
            }
        )

    return {
        "id": "pass-coverage",
        "kind": "coverage",
        "batches": batches,
    }


def build_plan(
    findings: list[dict],
    batch_size: int,
    project_name: str,
    git_sha: str,
    coverage_files: dict[str, float] | None = None,
) -> dict:
    """Build the full grinder-plan dict."""
    by_file = group_findings_by_file(findings)
    kind_files = group_files_by_kind(by_file)

    # Build passes (sorted by kind for determinism)
    batch_counter = [0]
    kind_batches: dict[str, list[dict]] = {}
    for kind in sorted(kind_files.keys()):
        kind_batches[kind] = build_batches_for_files(
            kind,
            kind_files[kind],
            by_file,
            batch_size,
            batch_counter,
        )

    # Build passes (sorted by kind for determinism)
    passes = []
    for kind in sorted(kind_batches.keys()):
        pass_batches = kind_batches[kind]
        pass_id = f"pass-{kind}"
        passes.append(
            {
                "id": pass_id,
                "kind": kind,
                "batches": pass_batches,
            }
        )

    # Append coverage pass if coverage files provided
    if coverage_files is not None:
        passes.append(build_coverage_pass(coverage_files, batch_size))

    total_batches = sum(len(p["batches"]) for p in passes)

    return {
        "created_at": datetime.now(UTC).isoformat(),
        "git_sha_at_start": git_sha,
        "estimated_batches": total_batches,
        "estimated_hours": total_batches * 0.5,
        "staleness_commit_threshold": total_batches + STALENESS_BUFFER,
        "project": project_name,
        "passes": passes,
    }


def validate_plan_file(plan_path: Path, schema_path: Path, tools_dir: Path) -> tuple[bool, str]:
    """Validate the plan file using validate-plan.py --schema."""
    validator = tools_dir / "validate-plan.py"
    result = subprocess.run(
        [sys.executable, str(validator), "--schema", str(schema_path), str(plan_path)],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0, result.stdout + result.stderr


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate grinder-plan.yaml from findings.")
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--grinder-dir", required=True)
    parser.add_argument("--schema-dir", required=True)
    parser.add_argument("--tools-dir", required=True)
    parser.add_argument("--findings-json", required=True)
    parser.add_argument("--project-name", required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--batch-size", type=int, default=5)
    parser.add_argument(
        "--coverage-files",
        default=None,
        help="JSON map of {file_path: coverage_pct} for coverage pass",
    )

    args = parser.parse_args()

    # Parse coverage files if provided
    coverage_files: dict[str, float] | None = None
    if args.coverage_files is not None:
        coverage_files = json.loads(args.coverage_files)

    # Load findings
    findings_path = Path(args.findings_json)
    findings = json.loads(findings_path.read_text())

    # Exit 1 only when BOTH findings are empty AND no coverage files provided
    if not findings and not coverage_files:
        print("error: empty findings array", file=sys.stderr)
        sys.exit(1)

    # Build plan
    plan = build_plan(
        findings, args.batch_size, args.project_name, args.git_sha, coverage_files=coverage_files
    )

    # Write to temp file
    grinder_dir = Path(args.grinder_dir)
    grinder_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = grinder_dir / ".grinder-plan.tmp.yaml"
    final_path = grinder_dir / "grinder-plan.yaml"

    tmp_path.write_text(yaml.dump(plan, default_flow_style=False, sort_keys=False))

    # Validate
    schema_path = Path(args.schema_dir) / "grinder-plan.schema.json"
    valid, output = validate_plan_file(tmp_path, schema_path, Path(args.tools_dir))

    if not valid:
        tmp_path.unlink(missing_ok=True)
        print(f"validation failed:\n{output}", file=sys.stderr)
        sys.exit(1)

    # Atomic replace
    tmp_path.rename(final_path)
    sys.exit(0)


if __name__ == "__main__":
    main()
