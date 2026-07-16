# Example feature: one complete audit trail

This folder contains the full artifact chain for **grinder-auth-recovery**, one real feature delivered through the Watchfloor pipeline on 2026-05-09, exactly as the pipeline committed it. The only edit is path sanitization (`/Users/<name>` → `~`).

The feature itself closes a failure mode described in the [portfolio write-up](https://tomashermansen-lang.github.io/portfolio/projects/watchfloor-autopilot.html): during a long unattended run, CLI authentication expired mid-loop, the orchestrator treated every failure as transient, retried, and reverted its own commits. This feature added a preflight auth probe and a structured `auth_failed` classifier so autonomous runs can tell the difference between an error worth retrying and one that means stop.

## The artifact chain

Read in pipeline order:

| Phase | Artifact | What it is |
|-------|----------|------------|
| ba | [REQUIREMENTS.md](REQUIREMENTS.md) | Acceptance criteria, grounded in the failing session's actual log data |
| plan | [PLAN.md](PLAN.md) | Module design and file-level implementation plan |
| testplan | [TESTPLAN.md](TESTPLAN.md) | Test scenarios, written **before** review so reviewers verify test scope |
| review | [REVIEW.md](REVIEW.md) | Independent review of plan + test plan (approved) |
| qa | [QA_REPORT.md](QA_REPORT.md) | Verdict: **passed after a fix loop** — QA found gaps and added 13 test scenarios (54 → 67 tests) before approving |
| static-analysis | [STATIC_ANALYSIS.md](STATIC_ANALYSIS.md) | SonarQube + lint gates, run **after** QA so they see the code that actually merges |
| (run metadata) | [autopilot-summary.json](autopilot-summary.json) | Machine summary of the unattended run: per-phase durations and costs, 2h49m end to end |

## The phase-labeled commit sequence

From the development repo's history (chronological):

```
f9a8017  2026-05-09  docs(grinder-auth-recovery): define requirements
fc7f6a8  2026-05-09  docs(grinder-auth-recovery): architect plan
1e39a62  2026-05-09  docs(grinder-auth-recovery): add test plan
2bc6cb2  2026-05-09  docs(grinder-auth-recovery): review — approved
09bcec0  2026-05-09  feat(grinder-auth-recovery): preflight probe + auth_failed classifier
93eacfb  2026-05-09  docs(grinder-auth-recovery): QA report
915f290  2026-05-09  docs(grinder-auth-recovery): static analysis report
ee8133f  2026-05-09  chore(grinder-auth-recovery): finalize for merge
d66779a  2026-05-09  docs(grinder-auth-recovery): mark as done
ca7c2ba  2026-05-09  Merge branch 'feature/grinder-auth-recovery'
```

## What to notice

- **The order is the current one.** Test plan lands before review; static analysis runs after QA. Both reorderings exist because earlier runs revealed leaks, and this trail shows the corrected sequence in practice.
- **QA was not a rubber stamp.** The run passed only after a fix loop in which the QA phase added 13 test scenarios the implementation phase had not written.
- **The whole run was unattended.** Every checkpoint was auto-approved (that is all autopilot changes); the gates did the gatekeeping. The summary file records what each phase cost and how long it took.
- **What is not here:** the full tool-level stream log (`autopilot-stream.ndjson`, ~5.7 MB of every tool call and result) exists for this run but is not published for size reasons. The artifacts above are the human-readable layer of the same trail.

The implementation this trail describes ships in this repo: see `adapters/claude-code/claude/tools/grinder.sh` (auth preflight) and its tests under `tests/`.
