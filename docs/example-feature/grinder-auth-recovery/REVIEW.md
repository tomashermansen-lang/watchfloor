<!-- phase: review | date: 2026-05-09 | branch: feature/grinder-auth-recovery -->

# Review Report: grinder-auth-recovery

## Verdict: APPROVED (2 passes, 4 fixes)

## Summary

Plan ships three coupled defences (preflight probe, eight-var env strip,
result-event classifier + retry-loop sentinel) plus a self-contained
fixture test, mapped 1:1 against R1–R6 and against all five acceptance
criteria from the parent execution plan task `grinder-auth-recovery`.
Code seams referenced in PLAN.md were verified against the actual
source (line 699 eight-var assessor strip, line 1307 six-var run_phase
strip, line 1336 `_classify_phase_exit`, line 1397 unstripped resume
invocation, line 1448 `run_gated_phase`). Pass 1 surfaced and removed
deferment / follow-up wording from RK-7 and the TESTPLAN OOS section,
removed the "deferred[]" contingent clause from RK-6, and tightened the
C5 placement description to match RK-4's precise positioning between
session_id extraction and `phase_ndjson` cleanup. Pass 2 is clean.

## Findings Resolved

| # | Pass | Category | Description | Fix Applied |
|---|------|----------|-------------|-------------|
| 1a | 1 | NO_DEFERRING (WARNING) | RK-7 logged `print_run_summary` rendering as a "follow-up nice-to-have but explicitly NOT in scope" | Reframed RK-7 as a no-modification disposition: documents that `print_run_summary` prints status literals without colour-mapping for unknown values (matching existing posture for non-`completed`/non-`failed` rows); the operator-facing signal per R6.1 is the stderr halt message + NDJSON event |
| 1b | 1 | NO_DEFERRING (WARNING) | TESTPLAN OOS bullet "A summary-table render upgrade is logged as a follow-up nice-to-have." | Replaced bullet with a positive disclosure that no `print_run_summary` modification is required and the existing literal render is sufficient |
| 2 | 1 | NO_DEFERRING (SUGGESTION) | RK-6 contingent clause "the plan flags this as a follow-up requirement in the host plan's `deferred[]`" surfaced the deferment keyword | Reworded to a clean revert disposition matching RK-1's style: "If /review prefers the narrow read, this is a single-line revert — drop the eight `env -u` flags from the resume invocation in C7" |
| 3 | 1 | CLARITY (SUGGESTION) | C5 modification opening said "immediately after `_classify_phase_exit` (current line 1336)" but RK-4 specified placement AFTER session_id extraction (lines 1339–1350) and BEFORE rm (line 1351); the latter is required so `session_id` is populated when `_emit_auth_failed_event` reads it | Tightened C5's opening modification description to specify the exact placement window with the three placement constraints (post-`_classify_phase_exit`, post-session_id-extraction, pre-rm) |
| 4 | 1 | CLARITY (SUGGESTION) | TESTPLAN risk-map row for RK-7 contained "logged as a follow-up" wording | Updated to match the new RK-7 disposition: "`print_run_summary` rendering is unmodified per RK-7 disposition and not tested" |

## Findings Remaining

None. Pass 2 review on the updated plan produced zero findings.

## Cross-Document Trace (verified)

- **All 5 task acceptance criteria** from `docs/INPROGRESS_Plan_grinder-full-stack/execution-plan.yaml` (`grinder-auth-recovery`) map to PLAN components:
  AC-1 → C1+C2; AC-2 → C7; AC-3 → C3+C4+C5+C6; AC-4 → C8; AC-5 → parent plan's `sonarqube-and-verification` phase (correctly scoped out of this task).
- **All R1.1–R6.3** trace to ≥1 PLAN component (PLAN § Component-to-Requirement Trace).
- **All R1.1–R6.3** trace to ≥1 TESTPLAN scenario (TESTPLAN § Coverage Map).
- **All C1–C8** have ≥1 TESTPLAN scenario.
- **Operator stderr strings** match verbatim across REQUIREMENTS / PLAN / TESTPLAN: `claude auth required — run claude login and retry`, `claude binary not found on PATH`, `claude auth probe timed out after Ns`, `WARNING: auth preflight skipped via GRINDER_SKIP_AUTH_PREFLIGHT`, `grinder halted: claude authentication lost mid-run — run claude login and re-run grinder.sh run`.
- **Negative paths** covered: C3.4/C3.7/C3.8/C3.9/C3.11 (classifier non-matches), C5.1/C5.4 (hook does-not-fire), C6.7/C6.8/C6.9 (sentinel mismatch / non-auth retry preserved).

## Code-Seam Verification

| Plan claim | Verified at |
|---|---|
| Assessor 8-var proxy strip | `claude-session-lib.sh:699` ✓ |
| `run_phase` 6-var strip (extension target) | `claude-session-lib.sh:1307–1308` ✓ |
| Resume `claude -p` has NO env strip currently | `claude-session-lib.sh:1397–1409` ✓ |
| `_classify_phase_exit` reclassification | `claude-session-lib.sh:1336` ✓ |
| `session_id` extraction block | `claude-session-lib.sh:1339–1350` ✓ |
| `phase_ndjson` cleanup | `claude-session-lib.sh:1351` ✓ |
| `process_stream` python consumer | `claude-session-lib.sh:1150` ✓ |
| `track_phase` deviation gate (status=="completed") | `claude-session-lib.sh:1242` ✓ |
| `run_gated_phase` retry loop (max_attempts=2) | `claude-session-lib.sh:1448–1488` ✓ |
| `cmd_run` lock-acquire boundary | `grinder.sh:1396` (PLAN says 1395 — off-by-one, acceptable) |
| `cmd_resume` lock-acquire boundary | `grinder.sh:1512` (PLAN says 1511 — off-by-one, acceptable) |
| `fail_pipeline` defined | `grinder.sh:91` ✓ |

## Checklist

- [x] Cross-document consistency: REQUIREMENTS → PLAN → TESTPLAN
- [x] Feasibility against existing architecture (all line references verified)
- [x] CLAUDE.md architecture rules (orchestrator pattern preserved, fail-closed via sentinel, no DAL violations)
- [x] SOLID compliance (S/O/L/I/D verified per-component)
- [x] Agentic navigability (named constants, header-table updates, single-source predicate)
- [x] TDD readiness + test plan covers requirements and components (every R1.1–R6.3 and every C1–C8 mapped)
- [x] Execution plan alignment (5/5 task acceptance criteria mapped; constraints honoured: bash 3.2, fixture pattern, ≤1s success path)
- [x] No deferment / follow-up / kicked-down-the-road wording

## Gotchas Captured

- **C5 hook placement is constrained by THREE invariants** (not just two): post-`_classify_phase_exit` so the watchdog reclassification has run, post-session_id-extraction so `_emit_auth_failed_event` has a sid, pre-rm so `_auth_failed_classify` can still read `phase_ndjson`. The valid window is a single 1-line slot between `claude-session-lib.sh:1350` and `:1351`. (Surprised me on first read of C5 — the wording in PLAN.md line 218 was relaxed to match RK-4's precise statement.)
