# Example feature: the static-analysis gate biting

This folder contains the full artifact chain for **session-status-endpoint**, one real feature delivered unattended through the Watchfloor pipeline on 2026-05-14, exactly as the pipeline committed it. The only edit is path sanitization (`/Users/<name>` → `~`).

The feature ships a FastAPI endpoint (`GET /api/{target_kind}/status`) in the dashboard backend — Python code that SonarQube actually analyses. That is why it is published: **the scanner flagged 2 findings in the branch's own files, the pipeline fixed both in a dedicated commit, and the re-scan came back at zero.** The quality gate here is not decorative.

## The artifact chain

| Phase | Artifact | What it is |
|-------|----------|------------|
| ba | [REQUIREMENTS.md](REQUIREMENTS.md) | Acceptance criteria for the endpoint |
| plan | [PLAN.md](PLAN.md) | Module design and file-level implementation plan |
| testplan | [TESTPLAN.md](TESTPLAN.md) | Test scenarios, written **before** review |
| review | [REVIEW.md](REVIEW.md) | Independent review of plan + test plan (approved) |
| qa | [QA_REPORT.md](QA_REPORT.md) | Verdict: **passed, 2 fixes applied** during the QA loop |
| static-analysis | [STATIC_ANALYSIS.md](STATIC_ANALYSIS.md) | SonarQube: 2 branch-introduced findings → fixed → 0 remaining; run **after** QA |
| (run metadata) | [autopilot-summary.json](autopilot-summary.json) | Machine summary of the unattended run: per-phase durations and costs |
| (run record) | [autopilot-stream.ndjson](autopilot-stream.ndjson) | The full tool-level stream: 1,087 events — every tool call, result, and phase transition. Too large for GitHub's inline viewer; use Raw or clone. |

## The phase-labeled commit sequence

From the development repo's history (chronological):

```
948b37f  2026-05-14  docs(session-status-endpoint): define requirements
12e5b4b  2026-05-14  docs(session-status-endpoint): architect plan
eaf093b  2026-05-14  docs(session-status-endpoint): add test plan
77adeea  2026-05-14  docs(session-status-endpoint): review — approved
90a343d  2026-05-14  feat(session-status-endpoint): GET /api/{target_kind}/status
1c88742  2026-05-14  docs(session-status-endpoint): QA report
5e925d0  2026-05-14  fix(session-status-endpoint): resolve static analysis findings
4360a09  2026-05-14  docs(session-status-endpoint): static analysis report
7b92734  2026-05-14  chore(session-status-endpoint): record autopilot phase_results
8bdc2d1  2026-05-14  docs(session-status-endpoint): mark as done
256fcaf  2026-05-14  feat(session-status-endpoint): merge feature/session-status-endpoint
```

## What to notice

- **`fix: resolve static analysis findings` is its own commit.** The pipeline's conventions separate mechanical auto-fixes, manual finding fixes, and reports into distinct commits so each can be reverted independently. This trail shows the convention in practice, not just in documentation.
- **The brownfield policy is visible.** The project-wide new-code quality gate fails on ~220 pre-existing findings in files this branch never touched. The pipeline's rule: findings in branch-touched files must be fixed; pre-existing findings elsewhere are logged as out-of-scope, never silently absorbed and never used as an excuse. The report documents both sides.
- **QA did its own catching too.** The verdict is "passed, 2 fixes applied" — issues found and resolved inside the QA loop before static analysis ever ran.
- **The whole run was unattended.** Every checkpoint auto-approved; the gates did the gatekeeping.

See also the companion example, [grinder-auth-recovery](../grinder-auth-recovery/), which shows the QA fix loop on a bash-only feature.
