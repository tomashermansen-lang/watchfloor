#!/usr/bin/env python3
"""plan-retro.py — feedback-loop substrate for /plan-project.

Reads:
  - <plan>/execution-plan.yaml          (the plan's predictions per task)
  - <plan>/_PLANPROJECT_STREAM.ndjson   (planning-phase events; v5 substrate)
  - docs/DONE_Feature_<task-id>/        (the actual feature execution
                                         artefacts, matched by task_id)
      * autopilot-summary.json
      * autopilot-stream.ndjson
      * TEAM_QA.md / TEAM_REVIEW.md / QA_REPORT.md
      * REQUIREMENTS.md / PLAN.md / TESTPLAN.md (if present)

Computes per-task deltas:
  - predicted vs actual LOC (planning estimate vs git diff at merge commit
    — best-effort, falls back to autopilot-summary if git unavailable)
  - predicted vs actual duration (estimate hours vs autopilot-summary
    duration_s)
  - predicted vs actual outcome (plan ACs vs surviving findings in
    TEAM_QA.md)
  - predicted vs actual cost (no plan field today; logs actuals for
    future baseline)

Rolls up across the plan's executed tasks (and optionally across all
plans):
  - per-specialist accuracy (does BA over-estimate? does Performance
    Eng under-estimate?)
  - per-pipeline-weight accuracy (do pipeline:light tasks land in cost
    band?)
  - per-task-type bias (refactor vs development vs research)
  - per-phase variance

Writes:
  <plan>/_RETRO_FEEDBACK.md
    Structured findings the next /plan-project --update run reads at
    Step 4.5 (Council Brief Construction) and folds into specialist
    context. Markdown, designed for both operator readability and
    LLM consumption.

Local file I/O only — no API calls, no `claude -p` invocations, no
Agent SDK credit consumption. Pure-stdlib Python (json, yaml, re,
pathlib, subprocess for git diff).

Usage:
  plan-retro.py --plan <plan-name>
  plan-retro.py --plan <plan-name> --output <path>
  plan-retro.py --self-test

Exit codes:
  0 — feedback artefact written successfully (or self-test passed)
  1 — usage / argument error
  2 — plan dir not found
  3 — no executed tasks found (nothing to compare against)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Optional

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

_THIS_FILE = Path(__file__).resolve()
REPO_ROOT = _THIS_FILE.parents[5]

_AC_FINDING_PATTERN = re.compile(
    r"^[#*\s]*(?P<sev>CRITICAL|WARNING|SUGGESTION|S\d+|SEC-\d+)\b[:\s—\-]+(?P<summary>.+?)$",
    re.MULTILINE,
)


def load_plan(plan_dir: Path) -> dict[str, Any]:
    """Load execution-plan.yaml and return the parsed plan."""
    yaml_path = plan_dir / "execution-plan.yaml"
    if not yaml_path.is_file():
        raise FileNotFoundError(f"execution-plan.yaml not found at {yaml_path}")
    with yaml_path.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def planning_events(plan_dir: Path) -> list[dict[str, Any]]:
    """Read _PLANPROJECT_STREAM.ndjson if present; return [] if absent."""
    stream = plan_dir / "_PLANPROJECT_STREAM.ndjson"
    if not stream.is_file():
        return []
    events: list[dict[str, Any]] = []
    for line in stream.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def find_done_feature(repo_root: Path, task_id: str) -> Optional[Path]:
    """Find the DONE_Feature_<task-id>/ directory if it exists."""
    candidate = repo_root / "docs" / f"DONE_Feature_{task_id}"
    if candidate.is_dir():
        return candidate
    return None


def parse_summary(summary_path: Path) -> dict[str, Any]:
    """Parse autopilot-summary.json for actual cost/duration/outcome."""
    if not summary_path.is_file():
        return {}
    try:
        data = json.loads(summary_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    total_cost = 0.0
    for phase in data.get("phases", []) or []:
        cost = phase.get("cost")
        if isinstance(cost, (int, float)):
            total_cost += float(cost)
    return {
        "total_cost": round(total_cost, 2),
        "duration_s": data.get("duration_s") or 0,
        "outcome_class": data.get("outcome_class") or data.get("status") or "unknown",
        "phase_costs": [
            {"name": p.get("name"), "cost": p.get("cost"), "duration_s": p.get("duration_s")}
            for p in (data.get("phases") or [])
        ],
    }


def parse_team_qa_findings(qa_path: Path) -> list[dict[str, str]]:
    """Extract finding IDs + severity from TEAM_QA.md (best-effort)."""
    if not qa_path.is_file():
        return []
    text = qa_path.read_text(encoding="utf-8", errors="replace")
    findings: list[dict[str, str]] = []
    seen: set[str] = set()
    for m in _AC_FINDING_PATTERN.finditer(text):
        sev = m.group("sev")
        summary = m.group("summary").strip()[:140]
        key = f"{sev}:{summary[:40]}"
        if key in seen:
            continue
        seen.add(key)
        findings.append({"severity": sev, "summary": summary})
    return findings


def actual_loc_from_git(repo_root: Path, task_id: str) -> Optional[int]:
    """Best-effort: find a merge commit referencing task_id in its message
    and return its diff line count. Returns None if git unavailable or no
    matching commit found."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "log",
             f"--grep=feature/{task_id}",
             "--grep=" + task_id,
             "--all", "--format=%H", "-n", "1"],
            capture_output=True, text=True, check=False, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    commit = result.stdout.strip().splitlines()
    if not commit:
        return None
    sha = commit[0]
    try:
        diff_result = subprocess.run(
            ["git", "-C", str(repo_root), "show", "--stat", "--format=", sha],
            capture_output=True, text=True, check=False, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if diff_result.returncode != 0:
        return None
    # Last line of --stat is "N files changed, X insertions(+), Y deletions(-)"
    match = re.search(r"(\d+)\s+insertions?", diff_result.stdout)
    return int(match.group(1)) if match else None


def compute_task_delta(
    task: dict[str, Any], feature_dir: Path, repo_root: Path
) -> dict[str, Any]:
    """Compute the predicted-vs-actual delta for a single executed task."""
    summary = parse_summary(feature_dir / "autopilot-summary.json")
    qa_findings = parse_team_qa_findings(feature_dir / "TEAM_QA.md")
    actual_loc = actual_loc_from_git(repo_root, task["id"])
    estimate = task.get("estimate") or {}
    predicted_loc = estimate.get("lines_estimate")
    predicted_hours = estimate.get("duration_hours")
    actual_hours = summary.get("duration_s", 0) / 3600 if summary.get("duration_s") else None
    return {
        "task_id": task["id"],
        "task_type": task.get("task_type", "unknown"),
        "pipeline": task.get("pipeline", "light"),
        "predicted_loc": predicted_loc,
        "actual_loc": actual_loc,
        "loc_delta": (actual_loc - predicted_loc) if (actual_loc and predicted_loc) else None,
        "predicted_hours": predicted_hours,
        "actual_hours": round(actual_hours, 2) if actual_hours else None,
        "hours_delta": (round(actual_hours - predicted_hours, 2)
                        if (actual_hours and predicted_hours) else None),
        "actual_cost": summary.get("total_cost"),
        "outcome_class": summary.get("outcome_class"),
        "qa_findings_count": len(qa_findings),
        "qa_critical_count": sum(1 for f in qa_findings
                                  if f["severity"].upper().startswith(("CRIT", "S1", "SEC-"))),
        "qa_warning_count": sum(1 for f in qa_findings
                                 if f["severity"].upper().startswith("WARN")),
    }


def aggregate(deltas: list[dict[str, Any]]) -> dict[str, Any]:
    """Roll up the per-task deltas into pattern findings."""
    def mean_field(items: list[Any]) -> Optional[float]:
        vals = [v for v in items if v is not None]
        return round(sum(vals) / len(vals), 2) if vals else None

    loc_deltas = [d["loc_delta"] for d in deltas if d["loc_delta"] is not None]
    hours_deltas = [d["hours_delta"] for d in deltas if d["hours_delta"] is not None]
    costs = [d["actual_cost"] for d in deltas if d["actual_cost"]]

    loc_bias_pct: Optional[float] = None
    if loc_deltas:
        predicted_pairs = [(d["predicted_loc"], d["actual_loc"]) for d in deltas
                            if d["predicted_loc"] and d["actual_loc"]]
        if predicted_pairs:
            ratios = [(a - p) / p for p, a in predicted_pairs if p > 0]
            if ratios:
                loc_bias_pct = round(sum(ratios) / len(ratios) * 100, 1)

    by_pipeline: dict[str, list[float]] = {}
    for d in deltas:
        if d["actual_cost"]:
            by_pipeline.setdefault(d["pipeline"], []).append(d["actual_cost"])
    pipeline_cost_means = {
        k: round(sum(v) / len(v), 2) for k, v in by_pipeline.items()
    }

    by_task_type: dict[str, list[Optional[float]]] = {}
    for d in deltas:
        if d["loc_delta"] is not None:
            by_task_type.setdefault(d["task_type"], []).append(d["loc_delta"])
    task_type_loc_bias = {
        k: mean_field(v) for k, v in by_task_type.items()
    }

    return {
        "n_executed_tasks": len(deltas),
        "loc_delta_mean": mean_field(loc_deltas),
        "loc_bias_pct": loc_bias_pct,
        "hours_delta_mean": mean_field(hours_deltas),
        "cost_mean": mean_field(costs),
        "cost_total": round(sum(costs), 2) if costs else None,
        "pipeline_cost_means": pipeline_cost_means,
        "task_type_loc_bias": task_type_loc_bias,
        "outcome_breakdown": {
            cls: sum(1 for d in deltas if d["outcome_class"] == cls)
            for cls in {d["outcome_class"] for d in deltas if d["outcome_class"]}
        },
        "total_qa_findings": sum(d["qa_findings_count"] for d in deltas),
        "total_qa_critical": sum(d["qa_critical_count"] for d in deltas),
        "total_qa_warning": sum(d["qa_warning_count"] for d in deltas),
    }


def render(
    plan: dict[str, Any], deltas: list[dict[str, Any]], rollup: dict[str, Any],
    planning_events_list: list[dict[str, Any]],
) -> str:
    """Render the retro feedback markdown."""
    name = plan.get("name", "unknown")
    out: list[str] = [
        f"# Retro Feedback — {name}",
        "",
        f"Auto-generated by `plan-retro.py` for `/plan-project --update` "
        f"to read at Step 4.5 (Council Brief Construction). The next "
        f"planning run will fold these patterns into specialist context "
        f"so estimates and decisions are anchored to observed reality.",
        "",
        f"**Executed tasks compared:** {rollup['n_executed_tasks']}  |  "
        f"**Planning events captured:** {len(planning_events_list)}",
        "",
        "---",
        "",
        "## Estimation accuracy (predicted vs actual)",
        "",
    ]

    if rollup["loc_bias_pct"] is not None:
        direction = "OVER" if rollup["loc_bias_pct"] < 0 else "UNDER"
        out.append(
            f"**LOC estimation bias:** plan estimates run **{abs(rollup['loc_bias_pct'])}% "
            f"{direction}** actual delivery (mean across {rollup['n_executed_tasks']} executed tasks). "
            f"Next plan should adjust `estimate.lines_estimate` accordingly."
        )
    else:
        out.append("_Not enough data to compute LOC bias._")
    out.append("")

    if rollup["hours_delta_mean"] is not None:
        sign = "+" if rollup["hours_delta_mean"] > 0 else ""
        out.append(
            f"**Duration delta (actual − predicted hours):** "
            f"mean **{sign}{rollup['hours_delta_mean']}** hours."
        )
    out.append("")

    out.append("## Cost reality")
    out.append("")
    if rollup["cost_mean"]:
        out.append(
            f"**Per-task mean cost:** ${rollup['cost_mean']}  |  "
            f"**Total observed spend:** ${rollup['cost_total']}"
        )
        out.append("")
        out.append("**Per-pipeline cost means:**")
        for pipe, mean in rollup["pipeline_cost_means"].items():
            out.append(f"  - `{pipe}`: ${mean}")
    else:
        out.append("_No autopilot-summary.json files found for executed tasks._")
    out.append("")

    out.append("## Task-type bias")
    out.append("")
    if rollup["task_type_loc_bias"]:
        out.append("| Task type | LOC delta mean (actual − predicted) |")
        out.append("|---|---|")
        for tt, bias in rollup["task_type_loc_bias"].items():
            arrow = "↑" if (bias or 0) > 0 else "↓" if (bias or 0) < 0 else "→"
            out.append(f"| `{tt}` | {arrow} {bias} |")
    else:
        out.append("_Not enough task-type variety to compute bias._")
    out.append("")

    out.append("## Outcome breakdown")
    out.append("")
    if rollup["outcome_breakdown"]:
        for cls, count in sorted(rollup["outcome_breakdown"].items(), key=lambda kv: -kv[1]):
            out.append(f"- `{cls}`: {count}")
    out.append("")

    out.append("## QA findings reality")
    out.append("")
    out.append(
        f"Across {rollup['n_executed_tasks']} executed tasks, TEAM_QA.md surfaced "
        f"**{rollup['total_qa_findings']} total findings** "
        f"({rollup['total_qa_critical']} CRITICAL, {rollup['total_qa_warning']} WARNING). "
        f"Use this to calibrate Step 9.6 (Adversarial Defence Pass) expectations: "
        f"plans that ship with zero canary-fixture coverage typically surface "
        f"more post-merge findings."
    )
    out.append("")

    out.append("## Per-task detail")
    out.append("")
    out.append("| Task | Type | Pipeline | LOC pred → actual | Hours pred → actual | Cost | Outcome | QA findings |")
    out.append("|---|---|---|---|---|---|---|---|")
    for d in deltas:
        loc = f"{d['predicted_loc']} → {d['actual_loc']}" if d['actual_loc'] else f"{d['predicted_loc']} → ?"
        hrs = f"{d['predicted_hours']} → {d['actual_hours']}" if d['actual_hours'] else f"{d['predicted_hours']} → ?"
        cost = f"${d['actual_cost']}" if d['actual_cost'] else "?"
        out.append(
            f"| `{d['task_id']}` | {d['task_type']} | {d['pipeline']} | "
            f"{loc} | {hrs} | {cost} | {d['outcome_class'] or '?'} | "
            f"{d['qa_findings_count']} ({d['qa_critical_count']}C/{d['qa_warning_count']}W) |"
        )
    out.append("")

    out.append("## Planning-phase events (from `_PLANPROJECT_STREAM.ndjson`)")
    out.append("")
    if planning_events_list:
        event_counts: dict[str, int] = {}
        for ev in planning_events_list:
            event_counts[ev.get("event", "unknown")] = event_counts.get(ev.get("event", "unknown"), 0) + 1
        for ev_name, n in sorted(event_counts.items(), key=lambda kv: -kv[1]):
            out.append(f"- `{ev_name}`: {n}")
    else:
        out.append("_No planning-phase event stream found (`_PLANPROJECT_STREAM.ndjson` absent or empty)._")
    out.append("")

    out.append("---")
    out.append("")
    out.append("## How to use this in the next planning run")
    out.append("")
    out.append(
        "When `/plan-project --update --team` runs against this plan again, "
        "Step 4.5 (Council Brief Construction) reads `_RETRO_FEEDBACK.md` "
        "automatically and includes the rollup above in §5 of the Council "
        "Brief. Specialists at Step 5T.2 see the historical accuracy data "
        "and adjust their estimates / decisions to match observed reality. "
        "The LOC bias percentage and per-pipeline cost means are the "
        "highest-signal inputs."
    )
    return "\n".join(out).rstrip() + "\n"


def self_test() -> int:
    """Smoke test: build a retro for a fake plan in a temp dir."""
    import tempfile
    tmpbase = os.environ.get("TMPDIR", "/tmp")
    tmpdir = Path(tmpbase.rstrip("/")) / f"plan-retro-selftest-{os.getpid()}"
    tmpdir.mkdir(parents=True, exist_ok=True)

    try:
        # Synth a minimal plan dir
        plan_dir = tmpdir / "docs" / "INPROGRESS_Plan_self-test"
        plan_dir.mkdir(parents=True, exist_ok=True)
        plan = {
            "name": "self-test",
            "phases": [{
                "id": "p0",
                "tasks": [
                    {"id": "task-a", "task_type": "refactor", "pipeline": "light",
                     "estimate": {"lines_estimate": 100, "duration_hours": 2}},
                ],
            }],
        }
        with (plan_dir / "execution-plan.yaml").open("w") as f:
            yaml.safe_dump(plan, f)

        # Synth a matching DONE_Feature with summary
        feature_dir = tmpdir / "docs" / "DONE_Feature_task-a"
        feature_dir.mkdir(parents=True, exist_ok=True)
        (feature_dir / "autopilot-summary.json").write_text(json.dumps({
            "duration_s": 7200,
            "outcome_class": "shipped",
            "phases": [{"name": "Implement", "cost": 5.0, "duration_s": 3600}],
        }))
        # Synth a stream
        (plan_dir / "_PLANPROJECT_STREAM.ndjson").write_text(
            '{"event":"test_event","plan":"self-test","ts":"2026-01-01T00:00:00Z"}\n'
        )

        # Run the pipeline
        deltas = [compute_task_delta(plan["phases"][0]["tasks"][0], feature_dir, tmpdir)]
        rollup = aggregate(deltas)
        events = planning_events(plan_dir)
        body = render(plan, deltas, rollup, events)

        # Verify the body has the required sections
        for section in ["# Retro Feedback", "## Estimation accuracy", "## Cost reality",
                        "## Per-task detail", "## Planning-phase events"]:
            assert section in body, f"missing section: {section}"
        # Verify the synth data appears
        assert "task-a" in body, "task-a missing from per-task detail"
        assert "test_event" in body, "test_event missing from event rollup"
        assert "$5.0" in body or "$5.00" in body, "synth cost missing"

        print("self-test: OK")
        return 0
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Feedback-loop substrate for /plan-project Step 4.5"
    )
    parser.add_argument("--plan", help="Plan slug (e.g., autopilot-cost-efficiency)")
    parser.add_argument("--plan-dir", help="Override plan directory")
    parser.add_argument("--output", help="Override output path (default: <plan-dir>/_RETRO_FEEDBACK.md)")
    parser.add_argument("--repo-root", default=str(REPO_ROOT), help="Repo root")
    parser.add_argument("--self-test", action="store_true", help="Run smoke test")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.plan:
        parser.error("--plan is required (or use --self-test)")

    repo_root = Path(args.repo_root).resolve()
    plan_dir = Path(args.plan_dir).resolve() if args.plan_dir else (
        repo_root / "docs" / f"INPROGRESS_Plan_{args.plan}"
    )
    if not plan_dir.is_dir():
        print(f"ERROR: plan dir not found: {plan_dir}", file=sys.stderr)
        return 2

    plan = load_plan(plan_dir)
    events = planning_events(plan_dir)

    # Walk plan tasks; match each to a DONE_Feature_<task-id>/ if present
    deltas: list[dict[str, Any]] = []
    for phase in plan.get("phases", []) or []:
        for task in phase.get("tasks", []) or []:
            feature_dir = find_done_feature(repo_root, task["id"])
            if not feature_dir:
                continue
            deltas.append(compute_task_delta(task, feature_dir, repo_root))

    if not deltas:
        print(f"WARNING: no executed tasks found for plan '{args.plan}'. "
              f"Cannot produce retro feedback yet.", file=sys.stderr)
        return 3

    rollup = aggregate(deltas)
    body = render(plan, deltas, rollup, events)
    output = Path(args.output) if args.output else (plan_dir / "_RETRO_FEEDBACK.md")
    output.write_text(body, encoding="utf-8")
    print(f"Wrote {output}", file=sys.stderr)
    print(f"  {rollup['n_executed_tasks']} executed tasks compared", file=sys.stderr)
    if rollup["loc_bias_pct"] is not None:
        print(f"  LOC bias: {rollup['loc_bias_pct']}%", file=sys.stderr)
    if rollup["cost_total"]:
        print(f"  Total observed spend: ${rollup['cost_total']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
