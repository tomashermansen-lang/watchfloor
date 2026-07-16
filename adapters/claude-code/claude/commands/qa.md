---
description: QA — verify implementation, find regressions, report risks
argument-hint: <feature-name> OR flow <feature-name>
---

# QA: Verify $ARGUMENTS

Verify implementation works, find ALL gaps, fix them, and produce a clean QA report.

## Flow Mode

See the flow-mode skill for protocol.

**QA runs in a fix loop** — issues found are fixed immediately, then re-verified. QA only presents a checkpoint when ALL checks pass.

**Checkpoint:** `[yes / stop]` (presented only after all checks pass)
- `yes` → All checks passed → continues to `/commit flow`
- `stop` → Pause flow

## Domain Knowledge

- solid-principles skill — Architecture rule verification
- tool-dependency-policy rule — never fly-install missing packages; declare in manifest instead
- Look for a `*design-system*` or `*design*` skill in `.claude/skills/` for UI/accessibility rules (if UI feature)

## Prerequisites

Read: `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md`, `docs/INPROGRESS_Feature_<feature>/DESIGN.md` (if exists), `docs/INPROGRESS_Feature_<feature>/PLAN.md`, `docs/INPROGRESS_Feature_<feature>/TESTPLAN.md`.

Note: STATIC_ANALYSIS.md is NOT a prerequisite. As of 2026-04-29 the pipeline
runs `/static-analysis` AFTER this phase, so the file does not yet exist.
Focus on behavioral correctness, regressions, and requirement coverage —
structural quality (SonarQube findings) is the next phase's responsibility.

## Step 0.5: Plan Detection & Orientation

**MANDATORY — run this glob BEFORE any other file reads:**
```
Glob pattern: docs/INPROGRESS_Plan_*/execution-plan.yaml
```
If found: Read the YAML, then follow the plan-detection skill
§ Project Orientation for task matching and context loading.
If not found: proceed standalone (no warnings, no behavior change).

If a plan is loaded and a matching task is found:
- Run auto-orient (Step 0.6) to understand full project scope and completed work
- Plan acceptance criteria become additional quality verification targets
- Execution plan strategy becomes the drift baseline (Step 9b)

If no plan found: proceed as normal (skip step 9b).

## Step 0.7: Team QA Context

Check for `docs/INPROGRESS_Feature_<feature>/TEAM_QA.md`:

- **If exists and PASSED (two-phase):** The `/team-qa` command already includes
  a deep QA phase. Note "Full team QA (including deep dive) already passed" in
  output. Suggest the user proceed to `/commit` instead. If the user wants to
  continue anyway, proceed with normal QA.
- **If exists and FAILED with conditions:** Read the `## Consensus Decision` and
  `### Conditions` sections. Add each numbered condition to the QA checklist as
  an additional verification target (same weight as BLOCKER findings). These
  conditions were raised by multi-perspective team QA and must be verified.
- **If exists and PASSED (legacy, no Phase 2 section):** Note "Team QA passed —
  no additional conditions" in output. Proceed with normal QA.
- **If not exists:** Skip silently (backward compatible).

## Workflow: QA-Fix Loop

Run all checks (steps 1-11). If ANY issue is found, fix it immediately and re-run the affected checks. Only proceed to report when everything is green.

### Adversarial Framing

Assume the implementer cut corners. Their report may be incomplete or
optimistic. Approach every check with distrust:

- **Do NOT take the implementer's word.** Read actual source code and compare
  line-by-line against every acceptance criterion in REQUIREMENTS.md.
- **Passing tests do not prove correctness.** Verify that each test actually
  tests the right behavior — not a tautology, not a trivially passing stub,
  not a test that would pass even if the feature were broken.
- **Check what's missing, not just what's present.** Untested paths, unhandled
  errors, and silently dropped requirements are more dangerous than failing tests.

### Check Phase

1. **Verify tests + lint + type-check via `.tests-green-sha` marker.**
   `/implement` Step 5 already gated the project's test command and all
   inline linters / type-checkers (ruff, eslint, mypy, tsc, shellcheck)
   on the changed files. It writes
   `docs/INPROGRESS_Feature_<feature>/.tests-green-sha` after that gate
   passes. Read the marker and compare to HEAD:
   ```bash
   marker=docs/INPROGRESS_Feature_<feature>/.tests-green-sha
   if [[ -f $marker && $(cat $marker) == $(git rev-parse HEAD) ]]; then
     echo "tests + lint + type-check proven green at this SHA — skip rerun"
   fi
   ```
   - **Marker matches HEAD** → mark step 1 ✅ and skip step 2 entirely;
     the marker is the gate. Proceed to step 3 (Eval suite).
   - **Marker absent OR stale** (no marker file, or content ≠ HEAD) →
     `/implement` did not exit green on this SHA. Fall back: run the
     project's test command from CLAUDE.md; if fail → fix immediately
     and re-run. After tests are green, continue to step 2.

2. **Syntax/type fallback** *(skipped when the `.tests-green-sha`
   marker matched HEAD in step 1 — the marker covers lint + type-check
   alongside tests)*. Only run when the marker was absent/stale: invoke
   the lint + type checkers appropriate to the project's language
   (mypy/tsc/ruff/eslint/shellcheck). If fail → fix immediately and
   re-run; after green, update the marker yourself with
   `git rev-parse HEAD > docs/INPROGRESS_Feature_<feature>/.tests-green-sha`
   so downstream phases inherit the trust.

3. **Eval suite** (if project has one): run evaluation tests per CLAUDE.md commands. Report results.

4. **Code review.** Delegate to `code-reviewer` subagent (Sonnet, read-only, preloaded with SOLID + agentic-code skills). It reviews all files changed on this branch (`git diff main...HEAD --name-only`) and returns structured findings with severity: BLOCKER / WARNING / NOTE.

5. **Map tests to acceptance criteria.** For EVERY scenario in requirements: test exists? ✅/❌. If ❌ → write the missing test NOW, then re-run.

6. **UX design compliance** (if DESIGN doc exists):
   - [ ] User flows implemented as specified?
   - [ ] Component specs followed?
   - [ ] Accessibility met? (44×44 CSS px touch targets, 4.5:1 contrast, keyboard nav, ARIA labels)
   If any violated → fix immediately, re-run.

7. **Regressions.** Previously passing tests now fail? Fix immediately. Run the
   unit/changed-area suite. For a dashboard change you MAY also run
   `bash dashboard/tests/run-all.sh` — safe in the sandbox now: the git-fixture /
   server-bound integration suites self-SKIP (they run unsandboxed at the phase
   **integration gate**, §5) and each suite is timeout-bounded, so the unit
   suites are exercised without wedging. Don't try to force the skipped
   integration suites to run in the sandbox — that only wastes turns. The heavy
   integration run is the phase gate's job (once per phase, `--only-integration`).

8. **Architecture rules.** Check all rules defined in CLAUDE.md:
   - [ ] Import direction rules respected
   - [ ] No hardcoded values
   - [ ] Project-specific constraints from CLAUDE.md followed
   If any violated → fix immediately, re-run.

9. **Completeness and cross-document consistency.**
   Verify the full chain REQUIREMENTS → DESIGN → PLAN → TESTPLAN → implementation is consistent:
   - [ ] Every requirement in REQUIREMENTS.md has a component in PLAN.md, an implementation, AND a test
   - [ ] If DESIGN.md exists: implementation matches the designed UI/UX flows and component specs
   - [ ] PLAN.md components all exist in the implementation — nothing planned but unbuilt
   - [ ] TESTPLAN.md scenarios all have corresponding test cases
   - [ ] No requirement dropped, reinterpreted, or silently changed between documents
   - [ ] No implementation that has no basis in REQUIREMENTS.md (scope creep)
   - [ ] Any TODOs, FIXMEs, stubs, or "deferred" items in code? List ALL.
   If anything incomplete or inconsistent → fix it NOW, then re-run.

9b. **Execution plan drift detection** (only when plan context is loaded from Step 0.5):
    Compare the actual implementation against the execution plan task and its strategy:
    - [ ] **Acceptance criteria coverage:** Every execution plan acceptance criterion is satisfied by the implementation (tested and verified, not just planned).
    - [ ] **Scope drift:** Implementation does not add features/components not specified in the execution plan task. Flag any additions as DRIFT — they may conflict with parallel tasks or future phases.
    - [ ] **Interface contracts:** If predecessor tasks (DONE_*) defined APIs, data schemas, or component interfaces, verify the implementation uses them correctly — not reimplementing or bypassing them.
    - [ ] **Design compliance:** Implementation matches DESIGN.md specifications (if exists). UI components, data flows, and user interactions match what was designed.
    - [ ] **Requirement coverage:** Every requirement from REQUIREMENTS.md has a corresponding implementation AND test.

    Drift findings use severity `DRIFT` (same weight as BLOCKER). If drift is intentional and justified, the developer must document why in the QA report.

10. **Eval traceability matrix.** Map requirements to eval cases:
    ```
    | Requirement | Test file | Eval case (data/evals/) | Status |
    |-------------|-----------|------------------------|--------|
    | REQ-1: ... | test_x.py | golden_cases_x.yaml | ✅/❌ |
    ```
    Every retrieval-affecting requirement MUST have an eval case.

11. **Risk assessment.** Rank high/medium/low: untested paths, complexity, dependencies, missing evals, accessibility gaps.

### Fix-and-Reverify

For EACH issue found in steps 1-11:
1. Fix the issue immediately (write test if needed, then fix code)
2. Re-run tests to verify fix doesn't break anything
3. Mark the issue as resolved

**Loop guard:** Maximum 3 fix passes. If issues remain after pass 3, present ALL remaining issues to user and ask for guidance.

### Report Phase (only after all checks pass)

12. **Write `docs/INPROGRESS_Feature_<feature>/QA_REPORT.md`** — First line: `<!-- phase: qa | date: YYYY-MM-DD | branch: <branch> -->`. Sections: Test results, Code review findings, Coverage matrix, Eval traceability, UX compliance, Regressions, Architecture, Completeness, Risks.

    **The QA report must include EVERY finding** — resolved and unresolved. Nothing omitted.

13. **Summarize** in 3-5 sentences: status, fixes applied, remaining risks.

14. **Flow checkpoint.** Present using the Checkpoint Contract from the flow-mode skill:

    ```
    QA complete: ✅ PASSED

    <Summary — 3-5 sentences>

    Files written: docs/INPROGRESS_Feature_<feature>/QA_REPORT.md
    Branch: <branch>

    On [yes]:
      1. git add docs/INPROGRESS_Feature_<feature>/QA_REPORT.md src/ tests/ config/
         git commit -m "docs(<feature>): QA report"
      2. After the commit lands, write the tests-green-sha marker so the
         next /commit-preflight (and downstream phases) can skip a
         redundant full test rerun when HEAD has not changed:
         ```bash
         git rev-parse HEAD > docs/INPROGRESS_Feature_<feature>/.tests-green-sha
         ```
         (Marker is gitignored — purely a local optimization signal. The
         same marker file is also written by /implement Step 5 and by
         /static-analysis at the end of its fix loop; whichever phase
         exits last with green tests + lint + type-check owns it.)
      3. STOP — open a new chat and run: /static-analysis flow <feature>

    On [stop]:
      → Pause flow. Resume later in a new chat: /qa flow <feature>

    Continue? [yes / stop]
    ```

    **Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Rules

- **NO DEFERRING.** If QA finds an issue, it gets fixed NOW — not "noted for future improvement", not "acceptable risk for this phase", not "will be addressed in next iteration". Fix it or explain to the user why it cannot be fixed.
- **FULL VISIBILITY.** Show ALL findings to the user — every code review note, every missing test, every architecture violation, every risk. Never truncate with "and N more items". Never summarize away details. Print the COMPLETE list even if it's long.
- **NO SILENT PASSES.** Do not mark a check as ✅ without actually running it. If a check can't be run, mark it as ⚠️ NOT RUN with explanation.
- **NO SYCOPHANCY.** Banned phrases: "You're absolutely right!", "Great point!", "Good catch!", "Excellent work!", "Well done!", "Nice job!" and synonyms. Every evaluation must be technical. Push-back with reasoning is expected — agreement requires stronger justification than disagreement.
- **EVIDENCE IN THIS MESSAGE.** If you have not run the verification command in THIS message, you cannot claim it passes. Show actual output (or pass/fail summary for long output). Banned completion phrases: "should work", "probably passes", "seems to", "likely works", "I believe it passes".
- **CAPTURE GOTCHAS.** If you hit a non-obvious failure during this phase — something that wasted time, required a counterintuitive fix, or would trip up a future agent — add it to the relevant skill's Gotchas section before presenting the checkpoint. One sentence: what happened and why it's surprising.
