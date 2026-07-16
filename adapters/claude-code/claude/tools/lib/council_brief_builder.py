#!/usr/bin/env python3
"""council_brief_builder.py — Stage 1 materials prep for /plan-project Step 4.5.

Mines the dotfiles repo for evidence the planning team should see before
specialists fan out at Step 5T.2 independent analysis. Outputs a single
markdown package the producer reads inline and passes verbatim to every
specialist spawn.

Three sections:

  §1 Canary Fixture Inventory   — mined from docs/DONE_Feature_*/TEAM_QA.md
                                  (top findings) and */autopilot-summary.json
                                  (cost + duration + outcome_class). Filtered
                                  by optional --topics keywords.
  §2 Friction Table             — mined from sibling docs/INPROGRESS_Plan_*/
                                  chain-events.ndjson — task_failed,
                                  task_blocked, chain_blocked events. The
                                  plan being authored is excluded.
  §3 Counter-Evidence Ledger    — empty template; specialists in 5T.2 fill
                                  one row per proposed task with the
                                  observation that would invalidate it.

Pure stdlib — no pip dependencies. The fixture-mining is read-only (never
writes to DONE folders). Writes only to the plan dir's _COUNCIL_BRIEF.md.

Usage:
  python3 council_brief_builder.py --plan-name <slug> [--topics a,b,c]
  python3 council_brief_builder.py --self-test
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

# repo root resolved from this file's location:
# adapters/claude-code/claude/tools/lib/council_brief_builder.py -> repo root
_THIS_FILE = Path(__file__).resolve()
REPO_ROOT = _THIS_FILE.parents[5]

_FINDING_PATTERN = re.compile(
    r"^[#*\s]*(?P<id>S\d+|SEC-\d+|C\d+|CRIT-\d+|R\d+|R-\w+|FINDING-\d+)"
    r"[:\s—\-]+(?P<summary>.+?)$",
    re.MULTILINE,
)

_FRICTION_EVENTS = frozenset({"task_failed", "task_blocked", "chain_blocked"})

_CANARY_CAP = 15
_FRICTION_CAP = 25


def find_done_features(repo_root: Path) -> list[Path]:
    """Return all DONE_Feature_* directories under docs/, sorted by name."""
    docs = repo_root / "docs"
    if not docs.is_dir():
        return []
    return sorted(docs.glob("DONE_Feature_*"))


def extract_team_qa_findings(team_qa_path: Path, limit: int = 3) -> list[dict[str, str]]:
    """Parse TEAM_QA.md for top-line findings (best-effort heuristic)."""
    if not team_qa_path.is_file():
        return []
    try:
        text = team_qa_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    findings: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    for match in _FINDING_PATTERN.finditer(text):
        finding_id = match.group("id").strip()
        if finding_id in seen_ids:
            continue
        seen_ids.add(finding_id)
        summary = match.group("summary").strip().rstrip(".")
        # Trim very long lines
        summary = summary[:180] + ("…" if len(summary) > 180 else "")
        findings.append({"id": finding_id, "summary": summary})
        if len(findings) >= limit:
            break
    return findings


def parse_summary_cost(summary_path: Path) -> dict[str, Any]:
    """Parse autopilot-summary.json for total cost + duration + outcome."""
    if not summary_path.is_file():
        return {}
    try:
        data = json.loads(summary_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    phases = data.get("phases", []) or []
    total_cost = 0.0
    for phase in phases:
        cost = phase.get("cost")
        if isinstance(cost, (int, float)):
            total_cost += float(cost)
    return {
        "total_cost": round(total_cost, 2),
        "duration_s": data.get("duration_s", 0) or 0,
        "outcome_class": data.get("outcome_class") or data.get("status") or "unknown",
    }


def matches_topic(text: str, topics: list[str]) -> bool:
    """Case-insensitive substring match. Empty topics list => include all."""
    if not topics:
        return True
    lowered = text.lower()
    return any(topic.lower() in lowered for topic in topics)


def build_canary_section(repo_root: Path, topics: list[str]) -> str:
    out: list[str] = [
        "## §1 Canary Fixture Inventory",
        "",
        "Mined from `docs/DONE_Feature_*/TEAM_QA.md` (top findings) and "
        "`*/autopilot-summary.json` (cost / duration / outcome). "
        f"Topic filter: `{', '.join(topics) if topics else 'none'}`. "
        f"Cap: {_CANARY_CAP} entries.",
        "",
        "Each entry is a historical run a specialist can name in a 5T.2 "
        "acceptance-criterion canary — e.g., \"trimmed-context dispatch "
        "must still surface finding S1 from feature X\".",
        "",
    ]

    features = find_done_features(repo_root)
    relevant: list[dict[str, Any]] = []
    for feat_dir in features:
        name = feat_dir.name.removeprefix("DONE_Feature_")
        if not matches_topic(name, topics):
            continue
        findings = extract_team_qa_findings(feat_dir / "TEAM_QA.md")
        summary = parse_summary_cost(feat_dir / "autopilot-summary.json")
        if not findings and not summary:
            continue
        relevant.append({"name": name, "findings": findings, "summary": summary})

    if not relevant:
        out.append(
            "_No DONE_Feature folders matched. Re-run without `--topics` "
            "filter to include all, or pick broader keywords._"
        )
        return "\n".join(out) + "\n"

    # Sort by cost descending so the biggest-budget canaries surface first.
    relevant.sort(
        key=lambda r: float(r["summary"].get("total_cost") or 0.0),
        reverse=True,
    )

    for feat in relevant[:_CANARY_CAP]:
        summary = feat["summary"]
        if summary:
            cost_line = (
                f"**${summary.get('total_cost', 0):.2f}** / "
                f"{summary.get('duration_s', 0)}s / "
                f"outcome=`{summary.get('outcome_class', 'unknown')}`"
            )
        else:
            cost_line = "_no autopilot-summary.json (standalone-flow run)_"
        out.append(f"### {feat['name']}")
        out.append(f"Cost: {cost_line}")
        if feat["findings"]:
            out.append("")
            out.append("Top findings:")
            for finding in feat["findings"]:
                out.append(f"- `{finding['id']}` — {finding['summary']}")
        out.append("")
    return "\n".join(out)


def build_friction_section(repo_root: Path, exclude_plan_name: str) -> str:
    out: list[str] = [
        "## §2 Friction Table",
        "",
        "Mined from `docs/INPROGRESS_Plan_*/chain-events.ndjson` and "
        "`docs/DONE_Plan_*/chain-events.ndjson` — `task_failed`, "
        "`task_blocked`, `chain_blocked` events. "
        f"The plan being authored (`{exclude_plan_name}`) is excluded. "
        f"Cap: {_FRICTION_CAP} rows.",
        "",
        "Each row is observable friction from a prior plan run — the kind "
        "of cost / blocker the new plan should design against.",
        "",
    ]

    docs = repo_root / "docs"
    if not docs.is_dir():
        out.append("_No `docs/` directory; nothing to mine._")
        return "\n".join(out) + "\n"

    rows: list[dict[str, Any]] = []
    # Scan both INPROGRESS_Plan_* (live runs) and DONE_Plan_* (finalised
    # plans). DONE_Plan_*/chain-events.ndjson was previously gitignored
    # and unreadable here, which silently dropped every plan's chain-
    # level friction history at completion. Fixed 2026-05-21 alongside
    # the .gitignore change that started tracking DONE_Plan_* chain-events.
    plan_dirs = sorted(
        list(docs.glob("INPROGRESS_Plan_*")) + list(docs.glob("DONE_Plan_*"))
    )
    for plan_dir in plan_dirs:
        if plan_dir.name in (
            f"INPROGRESS_Plan_{exclude_plan_name}",
            f"DONE_Plan_{exclude_plan_name}",
        ):
            continue
        events_file = plan_dir / "chain-events.ndjson"
        if not events_file.is_file():
            continue
        try:
            content = events_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in content.splitlines():
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("event") not in _FRICTION_EVENTS:
                continue
            rows.append(
                {
                    "plan": plan_dir.name.removeprefix("INPROGRESS_Plan_").removeprefix(
                        "DONE_Plan_"
                    ),
                    "ts": (event.get("ts") or "")[:19],
                    "event": event.get("event", ""),
                    "task": event.get("task", "") or event.get("reason", ""),
                    "reason": event.get("reason", ""),
                    "duration_s": event.get("duration_s") or 0,
                }
            )

    if not rows:
        out.append(
            "_No friction events found in sibling INPROGRESS_Plan_* or "
            "DONE_Plan_* chain streams._"
        )
        return "\n".join(out) + "\n"

    out.append("| Plan | Timestamp | Event | Task / Reason | Duration |")
    out.append("|---|---|---|---|---|")
    # Sort by duration descending so the most expensive friction surfaces first.
    rows.sort(key=lambda r: int(r["duration_s"] or 0), reverse=True)
    for row in rows[:_FRICTION_CAP]:
        # Escape pipes in user-content
        task = (row["task"] or "—").replace("|", r"\|")
        reason = (row["reason"] or "").replace("|", r"\|")
        body = f"`{task}` — {reason}" if reason else f"`{task}`"
        out.append(
            f"| {row['plan']} | {row['ts']} | `{row['event']}` | "
            f"{body} | {row['duration_s']}s |"
        )
    return "\n".join(out) + "\n"


def build_counter_evidence_ledger() -> str:
    return (
        "## §3 Counter-Evidence Ledger\n"
        "\n"
        "**Specialists in 5T.2 must fill this in.** For each task the plan "
        "proposes, write the observation that would INVALIDATE it (i.e., "
        "the metric or behaviour whose appearance proves the task does "
        "not pay off). Tasks shipped without an invalidation rebuttal in "
        "`design_notes[]` should be deferred or out-of-scope.\n"
        "\n"
        "| Task ID | Invalidation row | Rebuttal in `design_notes[]` |\n"
        "|---|---|---|\n"
        "| _(fill at 5T.2)_ | _e.g., if monthly $ saved < $30/mo over 2 months, this task does not pay off_ | _yes / no — if no, defer_ |\n"
    )


def render(plan_name: str, topics: list[str], repo_root: Path) -> str:
    sections = [
        f"# Council Brief — {plan_name}",
        "",
        "Auto-generated by `council_brief_builder.py` at /plan-project Step 4.5. "
        "Materials package for specialist context priming during Step 5T.2 "
        f"independent analysis. Topics filter: `{', '.join(topics) if topics else 'none'}`.",
        "",
        "**Specialists must cite this file by section name in their 5T.2 output.** "
        "A specialist response that does not reference §1 (canary), §2 (friction), "
        "or §3 (counter-evidence) by section name fails the structural validator "
        "in plan-team-flow §5T.2 and triggers a single re-spawn with a structural-"
        "failure context.",
        "",
        "---",
        "",
        build_canary_section(repo_root, topics),
        "",
        build_friction_section(repo_root, plan_name),
        "",
        build_counter_evidence_ledger(),
    ]
    return "\n".join(sections).rstrip() + "\n"


def self_test() -> int:
    """Smoke test: build a brief for a plan-name that does not exist and
    confirm output is valid, structural-only-empty when no data."""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        (tmp_path / "docs").mkdir()
        body = render("self-test-fake-plan", topics=[], repo_root=tmp_path)
        assert "# Council Brief — self-test-fake-plan" in body, "header missing"
        assert "## §1 Canary Fixture Inventory" in body, "§1 missing"
        assert "## §2 Friction Table" in body, "§2 missing"
        assert "## §3 Counter-Evidence Ledger" in body, "§3 missing"
        assert "No DONE_Feature folders matched" in body, "empty-canary fallback missing"
        assert "No friction events found" in body, "empty-friction fallback missing"
    print("self-test: OK", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Council Brief builder for /plan-project Step 4.5",
    )
    parser.add_argument(
        "--plan-name",
        help="Plan slug (e.g., autopilot-cost-efficiency). Required unless --self-test.",
    )
    parser.add_argument(
        "--plan-dir",
        help="Override plan directory (default: docs/INPROGRESS_Plan_<plan-name>/)",
    )
    parser.add_argument(
        "--topics",
        default="",
        help="Comma-separated topic keywords for canary filtering (default: empty = include all)",
    )
    parser.add_argument(
        "--repo-root",
        default=str(REPO_ROOT),
        help="Repo root (default: auto-detected from this script's location)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run smoke test against a temp dir; exit 0 on success, 1 on failure",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    if not args.plan_name:
        parser.error("--plan-name is required (or use --self-test)")

    repo_root = Path(args.repo_root).resolve()
    if not repo_root.is_dir():
        print(f"ERROR: repo root not found: {repo_root}", file=sys.stderr)
        return 1

    plan_dir = Path(args.plan_dir).resolve() if args.plan_dir else (
        repo_root / "docs" / f"INPROGRESS_Plan_{args.plan_name}"
    )
    plan_dir.mkdir(parents=True, exist_ok=True)

    topics = [t.strip() for t in args.topics.split(",") if t.strip()]
    body = render(args.plan_name, topics, repo_root)

    output = plan_dir / "_COUNCIL_BRIEF.md"
    output.write_text(body, encoding="utf-8")
    print(f"Wrote {output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
