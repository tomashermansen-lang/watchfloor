---
description: Team QA — two-phase quality review (team sweep + deep dive) with single checkpoint
argument-hint: <feature-name> OR flow <feature-name>
---

# Team QA: $ARGUMENTS

Two-phase quality review. Phase 1: five specialists examine implementation
artifacts, discuss findings, and fix issues. Phase 2: a single QA lead does a
deep adversarial dive — running tests, verifying coverage, checking regressions.
One combined report, one checkpoint.

**Architecture:** Evaluator-Optimizer pattern (Anthropic) with role separation.
Reviewers never modify files. The Fixer never evaluates its own work. The
orchestrator (you) owns the loop, the verdict, and the report.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Commit QA report → continues to `/commit flow`
- `amend` → User provides feedback, re-run from the phase that needs changes
- `stop` → Pause flow

## Domain Knowledge

- solid-principles skill — Architecture rule verification
- tdd-workflow skill — TDD patterns and test structure
- agentic-code skill — Agent navigability checklist

## Prerequisites

Read ALL feature docs: `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md`, `docs/INPROGRESS_Feature_<feature>/DESIGN.md`
(if exists), `docs/INPROGRESS_Feature_<feature>/PLAN.md`, `docs/INPROGRESS_Feature_<feature>/TESTPLAN.md`,
`docs/INPROGRESS_Feature_<feature>/STATIC_ANALYSIS.md` (if exists).
If TESTPLAN.md is missing, tell user to complete `/implement` and `/manualtest`
first and exit.

If STATIC_ANALYSIS.md exists, reviewers should read it to avoid re-flagging
issues that SonarQube already caught. Cross-reference its findings — don't
duplicate them, but verify they were actually addressed.

## Step 0: Detect Context

**Flow mode:** Verify worktree matches the requested feature. If on main, refuse
and point to `/start`.

**Standalone mode:** Skip worktree validation.

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
- All four reviewers receive the execution plan context
- QA Lead checks execution plan drift (scope, dependencies, completeness)

If no plan found: proceed as normal.

## Step 1: Feature Flag Guard

Check for the agent teams feature flag:

```bash
echo $CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
```

If empty or unset:
- Print: "Agent teams require the `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` feature flag."
- Print: "Enable it in your Claude Code settings, then retry."
- Suggest: "Alternatively, use `/qa` for single-perspective quality verification."
- **EXIT — do not proceed.**

## Step 2: Token Cost Confirmation

**If `$ARGUMENTS` contains `autopilot`:** Skip this confirmation — auto-proceed.

Before spawning the team, inform the user:

> **Token cost warning:** This command runs a two-phase QA: team sweep (5
> specialists + fixer loop) followed by a deep adversarial QA dive (test runs,
> coverage verification, regressions, code review + fixer loop). Worst case uses
> approximately **18–25× the tokens** of the single-perspective `/qa` command.
> Typical runs complete in 1–2 rounds per phase (~10–15×).
>
> Proceed? `[proceed / cancel]`

On `cancel`:
- Print: "Cancelled. Use `/qa <feature>` for single-perspective QA."
- **EXIT — do not proceed.**

---

# PHASE 1: Team Sweep

Broad quality review across five specialist perspectives.

## Step 3: Team Spawning Instructions

Create an agent team with 5 reviewer teammates. Each reviewer receives:
- **Tools:** Read, Grep, Glob, Bash only (read-only — no Write, no Edit)
- **Bash restriction:** Only for `git` commands and viewing test output files
- **Context:** All feature docs + source code + test code
- **Execution plan context** (if loaded from Step 0.5)

### Reviewer Definitions

Each reviewer is spawned using the Agent tool with the matching `subagent_type`.
This ensures each agent gets its full definition (tools, skills, model, structured
analysis process) — not just an inline prompt. The task-specific prompt below is
injected at spawn time.

| Role | `subagent_type` |
|------|----------------|
| Tester | `qa-engineer` |
| Security Reviewer | `security-auditor` |
| Performance Reviewer | `performance-engineer` |
| Code Reviewer | `code-reviewer` |
| QA Lead | `qa-engineer` |

**Tester** — `subagent_type: qa-engineer`
- Task: Verify test coverage against acceptance criteria. Map every requirement
  to a test. Check that tests actually test the right behavior — not tautologies,
  not stubs, not tests that pass even if the feature were broken. Check TESTPLAN.md
  scenarios all have corresponding test cases. Read test code to verify assertions
  are meaningful.
- Categories: `COVERAGE`, `TEST_QUALITY`

**Security Reviewer** — `subagent_type: security-auditor`
- Task: Review implementation for OWASP Top 10 vectors. Check for command
  injection, XSS, SQL injection, eval/innerHTML usage, hardcoded secrets, path
  traversal. Verify security tests exist for each attack vector relevant to
  the feature. Check input validation at system boundaries.
- Categories: `SECURITY`

**Performance Reviewer** — `subagent_type: performance-engineer`
- Task: Review implementation for performance concerns. Check for unnecessary
  re-renders (React), unbounded data structures, missing pagination, polling
  intervals, memory leaks, O(n^2) algorithms on potentially large datasets.
  Check that performance-sensitive paths have benchmarks or load tests.
- Categories: `PERFORMANCE`

**Code Reviewer** — `subagent_type: code-reviewer`
- Task: Review implementation against CLAUDE.md architecture rules and project
  conventions. Check for hardcoded values (URLs, ports, origins, paths — must use
  config), missing type annotations on public interfaces, SOLID violations in
  implementation, code duplication, naming conventions, import direction rules,
  dead code, commented-out code. Read CLAUDE.md and .claude/rules/ first to
  know what rules apply.
- Categories: `CONVENTION`, `SOLID`, `AGENTIC`

**QA Lead** — `subagent_type: qa-engineer`
- Task: Verify cross-document consistency across the full chain
  REQUIREMENTS → DESIGN → PLAN → TESTPLAN → implementation. Check for dropped
  requirements, scope creep, deferred items (TODOs, FIXMEs, stubs). Check
  execution plan drift when plan context is loaded. Synthesize team findings.
- Note: Same agent as Tester but different task prompt — focuses on completeness
  and drift rather than test coverage.
- Categories: `COMPLETENESS`, `DRIFT`, `REGRESSION`

### Fixer Definition (spawned during resolution loops in both phases)

The Fixer is spawned via the Agent tool with `subagent_type: fixer` — a subagent
(NOT a teammate). It has write access, runs tests, and follows a strict numbered
procedure. See Step 7.2 for the prompt template used when spawning it.

## Step 4: Review Phase (Round 0)

Each reviewer reads all relevant artifacts and produces findings independently.

**Finding format (structured — mandatory):**
```
| # | Severity | Category | File | Section/Line | Description | Fix suggestion |
```

Severities: `CRITICAL`, `WARNING`, `SUGGESTION`

**Severity floor rules (MANDATORY):**
- **SECURITY findings** (from Security Reviewer or any reviewer): minimum
  severity is WARNING. Security issues are never SUGGESTION — they enter the
  fix loop. This includes: information disclosure, missing CORS, missing auth,
  injection vectors, defense-in-depth gaps.
- **Missing test coverage for acceptance criteria** (from Tester): if a
  requirement or acceptance scenario has no corresponding test, minimum
  severity is WARNING.
- **Performance findings with safety implications** (from Performance Reviewer):
  unbounded queries, missing pagination on user-facing endpoints, and missing
  rate limits are WARNING minimum.
- Only cosmetic, stylistic, or preference-based findings may be SUGGESTION.
- When in doubt, classify as WARNING. False positives are filtered in discussion;
  false negatives slip through the vote and get deferred.

**Severity classification criteria (mandatory for all reviewers):**

A finding is **WARNING** (mandatory fix) if ANY of these apply:
- Would cause a bug, crash, or incorrect behavior at runtime
- Violates a security boundary (injection, auth bypass, data exposure)
- Breaks an interface contract or API compatibility
- Violates a project convention documented in CLAUDE.md or rules/
- Missing test coverage for a requirement or acceptance criterion
- Data loss, corruption, or inconsistency risk
- Frontend-backend parameter mismatch (e.g., fetch params exceed API validation limits)

A finding is **SUGGESTION** (subject to vote) ONLY if ALL of these apply:
- Cosmetic, stylistic, or preference-based
- No runtime impact if left unchanged
- Does not violate any documented convention
- Alternative approaches exist but current approach is functional

**When in doubt, classify as WARNING.** It's cheaper to fix a false
WARNING than to miss a real defect through deferral.

**API boundary coverage (projects with frontend + backend):**
- If the project's `CLAUDE.md` has a `pipeline.contracts` section, those
  contracts are deterministic checks that the pipeline runs mechanically.
  Any contract failure is WARNING minimum.
- If no contracts are configured but the feature touches both frontend and
  backend: verify at least one test exercises the real API boundary (not
  mocked). If all API tests use mocks, flag as WARNING: "No real API
  boundary tests — frontend/backend parameter drift will not be caught."

**Pre-existing issues policy:**
- Issues in files the feature **modifies**: treat as in-scope. The code is open,
  tests are running, risk is low. Fix them — don't defer as "pre-existing."
- Issues in files the feature **does not touch**: defer as out-of-scope.
- Never use "pre-existing" as a reason to skip a fix in modified files.

The `Fix suggestion` column gives the Fixer enough context to act without
re-analyzing the entire codebase. Keep it specific: "Add null check at
`src/utils/parse.ts:42` before accessing `.data`" not "input validation missing."

Each reviewer completes their full analysis before sharing findings. No
premature discussion — findings-first ensures complete analysis.

## Step 5: Discussion Phase

After all reviewers complete Step 4, initiate cross-reviewer discussion:

1. Each reviewer shares their findings with the team via messaging.
2. Reviewers challenge each other's findings with technical reasoning.
3. Reviewers respond substantively to challenges.

**Cross-role interaction examples:**
- Security finds unvalidated input → Tester checks if a security test exists for
  that path → Performance checks if validation adds latency concern.
- Tester finds weak assertion → QA Lead checks if the requirement it maps to is
  actually implemented correctly.

**Anti-sycophancy protocol (MANDATORY):**
- Banned phrases: "You're absolutely right!", "Great point!", "Good catch!",
  "Excellent observation!", "Well spotted!" and synonyms.
- Every response to a challenge must include technical reasoning.
- Agreement requires stronger justification than disagreement.
- If a reviewer cannot defend a finding against a challenge, the finding is
  downgraded or removed.

**Tie-breaking:** The orchestrating session (you, the lead) resolves disagreements
after 2 rounds of back-and-forth on any single finding. Document the reasoning
in the report.

## Step 6: Phase 1 Synthesis

After discussion concludes, synthesize all surviving findings into a consensus:

- **PHASE 1 PASSED**: Zero critical findings, zero unresolved warnings.
  Proceed to Phase 2 (Step 8).
- **NEEDS RESOLUTION**: One or more CRITICAL or WARNING findings survived
  discussion. Enter the Resolution Loop (Step 7).

The orchestrating session (you) makes the call — no teammate has verdict authority.

---

## Step 7: Phase 1 Resolution Loop

**Entry condition:** Phase 1 synthesis verdict is NEEDS RESOLUTION.

**Loop invariants:**
- `max_rounds = 3`
- `round = 1` (the initial review was Round 0 — this is the first fix round)
- `fixed_issues_log = []` (tracks all issues fixed across ALL rounds in BOTH phases)

### 7.1: Resolution Brief

The orchestrator (you) compiles a **resolution brief** for the Fixer:

```markdown
## Resolution Brief — Phase 1, Round <N>

### Issues to resolve (CRITICAL + WARNING only)
| # | Severity | Category | File | Section/Line | Fix suggestion | Original reviewer |
|---|----------|----------|------|-------------|----------------|-------------------|

### Previously fixed issues (DO NOT revert)
| # | Fixed in round | Description |
|---|----------------|-------------|

### Out of scope
- SUGGESTION-severity findings (triaged after both phases complete)
- Any refactoring or improvement beyond the listed issues
```

### 7.2: Fixer Execution

Spawn the Fixer with `subagent_type: fixer` and the prompt template below.
Fill in all `<placeholders>` before spawning.

**Fixer Prompt Template (Phase 1):**

````
## Resolution Brief — Phase 1, Round <N>

### Test command
<test command from CLAUDE.md, e.g., "bash tests/run-all.sh" or "cd app && npm test">

### Issues to resolve
| # | Severity | Category | File | Section/Line | Fix suggestion | Original reviewer |
|---|----------|----------|------|-------------|----------------|-------------------|
<paste CRITICAL + WARNING findings from synthesis>

### Previously fixed issues (DO NOT revert)
| # | Fixed in round | File | Description |
|---|----------------|------|-------------|
<paste from fixed_issues_log, or "None yet" for round 1>

### Out of scope
- SUGGESTION-severity findings (triaged after both phases)
- Any refactoring or improvement beyond the listed issues
- Files not mentioned in the issues table
````

The Fixer returns a **fix report** (defined in its agent file):
```markdown
| # | Status | What changed | File | Lines affected | Tests |
```
Status: `FIXED`, `PARTIALLY_FIXED` (with explanation), `BLOCKED` (with reason)
Tests: `PASS`, `FAIL` (with details), `N/A`

Any BLOCKED items are escalated to the orchestrator. If the block is a
conflicting requirement or ambiguous spec, pause the loop and ask the user.

### 7.3: Update Fixed-Issues Log

Add all FIXED and PARTIALLY_FIXED items to `fixed_issues_log` with phase and round number.

### 7.4: Re-Review (Focused)

Re-spawn the 5 reviewers (each with their original `subagent_type` — see table
in Step 3), but with a **narrowed scope:**
- Review ONLY the files/sections that the Fixer modified
- Verify each fix actually resolves the original finding
- Check for regressions: does this fix break something that was previously correct?
- Produce findings in the same structured format

**All CRITICAL and WARNING findings must be resolved before approval.** Both
severities trigger loop iterations in all rounds. The 3-round hard cap prevents
bikeshedding — if issues remain after 3 rounds, the verdict is REJECTED with
conditions for the human to decide.

### 7.5: Re-Discuss and Re-Synthesize

Same protocol as Steps 5–6, but scoped to new/changed findings only.

Possible outcomes:
- **PHASE 1 PASSED** → Exit loop, proceed to Phase 2 (Step 8)
- **NEEDS RESOLUTION** + `round < max_rounds` → Loop back to 7.1
- **NEEDS RESOLUTION** + `round >= max_rounds` → Exit loop with FAILED verdict.
  Skip Phase 2. Proceed directly to Report (Step 10).

### 7.6: Convergence Detection

Before looping back to 7.1, check:
- If the exact same findings persist from the previous round (same category,
  same file, same description), the loop has stalled. Exit with FAILED verdict
  and note "convergence failure — same issues persist after fix attempt."
- If a previously-fixed issue reappears, flag as REGRESSION in the report.
  Regressions count as CRITICAL regardless of original severity.

### 7.7: Loop Termination Summary

Print after each round:
```
Phase 1, Round <N>/<max>: <PASSED | NEEDS RESOLUTION | FAILED>
  Fixed: <count>  |  Remaining: <count>  |  Regressions: <count>
  New findings this round: <count>
  Tests: <pass count>/<total count>
```

---

# PHASE 2: Deep QA

Adversarial single-perspective deep dive. Runs actual tests, verifies coverage
line-by-line, checks regressions, and audits architecture compliance.

**Entry condition:** Phase 1 PASSED. If Phase 1 FAILED, skip Phase 2 entirely.

## Step 8: Deep QA

The orchestrator (you) performs a comprehensive, adversarial QA pass on the
implementation in its post-Phase-1 state.

### Adversarial Framing

Assume the implementer cut corners. Their report may be incomplete or optimistic.
Approach every check with distrust:
- **Do NOT take the implementer's word.** Read actual source code and compare
  line-by-line against every acceptance criterion.
- **Passing tests do not prove correctness.** Verify each test actually tests the
  right behavior — not a tautology, not a stub, not something that passes vacuously.
- **Check what's missing, not just what's present.** Untested paths, unhandled
  errors, and silently dropped requirements are more dangerous than failing tests.

### 8.1: Deep QA Checks

Run these checks against the post-Phase-1 implementation. **Exclude anything
already fixed in Phase 1** — cross-reference the fixed-issues log.

1. **Run all tests.** Use the project's test command from CLAUDE.md. If fail → fix
   immediately, re-run.

2. **Syntax/type check.** Run checks appropriate to the project's language and
   tooling. If fail → fix immediately.

3. **Eval suite** (if project has one): run evaluation tests per CLAUDE.md. Report.

4. **Code review.** Delegate to `code-reviewer` subagent (Sonnet, read-only,
   preloaded with SOLID + agentic-code skills). Review all files changed on this
   branch (`git diff main --name-only`). Return structured findings with severity:
   BLOCKER / WARNING / NOTE.

5. **Map tests to acceptance criteria.** For EVERY scenario in requirements:
   test exists? If missing → write it NOW, re-run.

6. **UX design compliance** (if DESIGN doc exists):
   - [ ] User flows implemented as specified?
   - [ ] Component specs followed?
   - [ ] Accessibility met? (44×44 CSS px touch targets, 4.5:1 contrast,
     keyboard nav, ARIA labels)
   If violated → fix immediately, re-run.

7. **Regressions.** Previously passing tests now fail? Fix immediately.

8. **Architecture rules.** Check all rules defined in CLAUDE.md:
   - [ ] Import direction rules respected
   - [ ] No hardcoded values
   - [ ] Project-specific constraints followed
   If violated → fix immediately, re-run.

9. **Completeness and cross-document consistency.**
   Verify the full chain REQUIREMENTS → DESIGN → PLAN → TESTPLAN → implementation:
   - [ ] Every requirement has a component, an implementation, AND a test
   - [ ] TESTPLAN.md scenarios all have corresponding test cases
   - [ ] No dropped, reinterpreted, or silently changed requirements
   - [ ] No scope creep (implementation beyond REQUIREMENTS.md)
   - [ ] Any TODOs, FIXMEs, stubs? List ALL.
   If incomplete → fix NOW, re-run.

10. **Execution plan drift** (only when plan context is loaded):
    - [ ] Every execution plan acceptance criterion is satisfied
    - [ ] No scope additions beyond the task spec
    - [ ] Interface contracts from predecessor tasks used correctly
    Drift findings use severity BLOCKER.

11. **Risk assessment.** Rank high/medium/low: untested paths, complexity,
    dependencies, accessibility gaps.

### 8.2: Fix-and-Reverify Loop

For each pass, compile all findings into a resolution brief and spawn the
`fixer` subagent using the **same prompt template from Step 7.2** (carry over
the full fixed-issues log from both phases). The orchestrator evaluates; the
Fixer fixes — same role separation as Phase 1.

For each pass:
1. Compile resolution brief (CRITICAL + WARNING findings from checks 1-11)
2. Spawn the Fixer (`subagent_type: fixer`) with the filled template
3. Update fixed-issues log from the Fixer's report
4. Re-run checks on modified files only. If clean → done. If findings remain
   + passes left → loop.

**Loop guard:** Maximum 3 fix passes. If issues remain after pass 3, present ALL
remaining issues to user and ask for guidance.

Print after each pass:
```
Phase 2, Pass <N>/3: <CLEAN | NEEDS FIX>
  Fixed: <count>  |  Remaining: <count>
  Tests: <pass count>/<total count>
```

### 8.3: Deep QA Verdict

- **PASSED**: All checks green. Proceed to Suggestion Triage (Step 9).
- **FAILED**: Issues could not be resolved after 3 passes. Proceed to Report
  (Step 10) with FAILED verdict.

---

## Step 9: Suggestion Triage

**Entry condition:** Both phases PASSED.

After approval, triage SUGGESTION-severity findings from BOTH phases
collaboratively. This is a single, bounded pass — no loops, no debate.

### 9.1: Collect Suggestions

Gather all SUGGESTION-severity findings from all rounds of both phases into a
numbered list:
```
| # | Phase | Reviewer | Category | Description | Fix suggestion |
```

If zero suggestions exist, skip to Step 10.

### 9.2: Reviewer Vote

**Autopilot mode:** Skip the vote entirely. Apply domain expert authority
directly — if a suggestion's category matches a reviewer's domain (see
mapping below), auto-adopt it. Only defer suggestions that are explicitly
out-of-scope (pre-existing file not changed by this branch) or would
require architectural changes beyond the feature scope. The goal is zero
unnecessary deferrals — deferred suggestions accumulate across features
and never get fixed.

**Interactive mode:** Send the suggestion list to all 5 reviewers (from
Phase 1). Each reviewer responds with a single vote per suggestion — no
discussion, no justification:
- **adopt** — quick win, should be applied now
- **defer** — save for later, not worth the cost now

Format: `#1: adopt | #2: defer | #3: adopt | ...`

### 9.3: Tally and Apply

Count votes per suggestion. Apply these adoption rules:

1. **Domain expert authority:** If the suggestion's category matches a
   reviewer's domain, that reviewer's single "adopt" vote is sufficient —
   no majority needed. Domain mapping:
   - Security Reviewer owns: `SECURITY`
   - Tester owns: `COVERAGE`, `TEST_QUALITY`
   - Performance Reviewer owns: `PERFORMANCE`
   - Code Reviewer owns: `CONVENTION`, `SOLID`, `AGENTIC`
   - QA Lead owns: `COMPLETENESS`, `DRIFT`, `REGRESSION`
2. **Majority adopt** (3+ of 5 votes) → adopted regardless of category.
3. All others → logged as deferred in the report.

### 9.3.1: Deferral Review

If more than 10 suggestions were deferred in the tally above:
1. The orchestrator re-examines the top 5 deferred items (those with the
   most reviewer concern or closest vote margins)
2. For each: does it actually meet ALL criteria for SUGGESTION (cosmetic,
   no runtime impact, no convention violation, functional alternative)?
   If not, promote to WARNING and add to the next fix round.
3. Log: "Deferral review: N items re-examined, M promoted to WARNING"

This prevents severity misclassification from compounding across features.
Promotion triggers one additional Fixer round for the promoted items only.

If any suggestions reached majority adopt:
1. Compile a **suggestion fix brief** (same format as resolution brief, but
   severity marked as `SUGGESTION-ADOPTED`).
2. Spawn the Fixer with the brief. Same constraints as resolution rounds:
   minimal, surgical edits only.
3. The Fixer must run relevant tests after changes (same test obligation as
   resolution rounds).
4. **No re-review.** Adopted suggestions do not trigger another review cycle.
   The Fixer's changes are recorded in the report as-is.

If no suggestions reached majority: skip the Fixer, log all as deferred.

### 9.4: Triage Summary

Print:
```
Suggestion triage: <total> suggestions | <adopted> adopted | <deferred> deferred
```

### 9.5: Persist Deferred Suggestions

If any suggestions were deferred, append them to a central tracker so they
aren't lost in individual QA reports.

**Target file:** `docs/INPROGRESS_Plan_*/DEFERRED.md` (same directory as the
execution plan). If no plan exists, use `docs/DEFERRED.md` at the project root.

**Create the file** if it doesn't exist, with this header:
```markdown
# Deferred Suggestions

Items deferred during team reviews and QA. Review periodically during
`/productmanager` sessions or when starting related features.

| Date | Feature | Phase | Reviewer | Category | Description | Reason deferred |
|------|---------|-------|----------|----------|-------------|-----------------|
```

**Append one row per deferred suggestion.** Use the Edit tool to add rows to
the existing table. Fields:
- **Date:** today's date (YYYY-MM-DD)
- **Feature:** the feature being reviewed
- **Phase:** `team-review` or `team-qa`
- **Reviewer:** which reviewer raised it
- **Category:** from the finding's category
- **Description:** the suggestion description
- **Reason deferred:** `no majority` / `orchestrator deferred` / brief reason

This file is **append-only** during reviews. Rows are removed or marked done
by `/productmanager` or manually when addressed.

---

## Step 10: Report

Write `docs/INPROGRESS_Feature_<feature>/TEAM_QA.md` with this structure:

```markdown
<!-- phase: team-qa | date: YYYY-MM-DD | branch: <branch> -->

# Team QA Report: <feature>

## Team
- Tester | Security Reviewer | Performance Reviewer | Code Reviewer | QA Lead | Deep QA (orchestrator) | Fixer

## QA Summary
- **Verdict:** PASSED | FAILED
- **Phase 1 (Team Sweep):** <N> rounds | <count> findings | <count> fixed
- **Phase 2 (Deep QA):** <N> passes | <count> findings | <count> fixed
- **Total findings:** <count> | Fixed: <count> | Remaining: <count>

---

## Phase 1: Team Sweep

### Round 0: Initial Review

#### Tester
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

#### Security Reviewer
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

#### Performance Reviewer
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

#### Code Reviewer
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

#### QA Lead
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

### Coverage Matrix
| Requirement | Test File | Test Case | Status |
|-------------|-----------|-----------|--------|

### Security Assessment Summary
<Overall security posture, key findings>

### Performance Assessment Summary
<Overall performance posture, key findings>

### Discussion Summary (Round 0)
Key challenges and how they were resolved.

### Resolution Rounds

#### Round <N>
**Fixer actions:**
| # | Original finding | Status | What changed | Tests |
|---|-----------------|--------|-------------|-------|

**Re-review findings:**
| # | Severity | Category | Reviewer | Description | New/Regression |
|---|----------|----------|----------|-------------|----------------|

**Round outcome:** <PASSED | NEEDS RESOLUTION>

(Repeat for each round)

### Phase 1 Verdict: <PASSED | FAILED>

---

## Phase 2: Deep QA

### Checks Performed
1. Test suite run
2. Syntax/type check
3. Eval suite (if applicable)
4. Code review (via code-reviewer subagent)
5. Acceptance criteria coverage mapping
6. UX design compliance (if applicable)
7. Regression check
8. Architecture rules
9. Completeness and cross-document consistency
10. Execution plan drift (if applicable)
11. Risk assessment

### Findings
| # | Pass | Severity | Category | Description | Fix applied |
|---|------|----------|----------|-------------|-------------|

### Risk Assessment
| Risk | Severity | Mitigation |
|------|----------|------------|

### Phase 2 Verdict: <PASSED | FAILED>

---

## Fixed-Issues Log (both phases)
| # | Phase | Description | Fixed in round/pass | Regression? |
|---|-------|-------------|---------------------|-------------|

## Consensus Decision
**PASSED** | **FAILED with conditions**

### Conditions (if FAILED)
1. [Condition traceable to finding — could not be auto-resolved because...]
2. ...

### Suggestions — Adopted
| # | Phase | Description | Votes (adopt/defer) | Fixer action | Tests |
|---|-------|-------------|---------------------|--------------|-------|
(Items that reached majority adopt and were applied by the Fixer.)
If none: "No suggestions reached majority adopt."

### Suggestions — Deferred
1. [SUGGESTION-severity items deferred for future consideration]
2. ...
```

If the report file already exists from a previous run, overwrite it.

## Step 11: Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Team QA complete: <PASSED or FAILED>
  Phase 1 (Team Sweep): <PASSED after N rounds | FAILED>
  Phase 2 (Deep QA): <PASSED after N passes | FAILED | skipped>

<Summary — findings count, resolution count, remaining issues if any>

Files modified: <list of source/test files changed by Fixer, if any>
Files written: docs/INPROGRESS_Feature_<feature>/TEAM_QA.md
Branch: <branch>

On [yes]:
  1. git add <all modified files>
     git commit -m "docs(<feature>): team QA — passed"
  2. STOP — open a new chat and run: /commit flow

On [amend]:
  → User provides feedback. Re-run from the relevant phase.

On [stop]:
  → Pause flow. Resume later in a new chat: /team-qa flow <feature>

Continue? [yes / amend / stop]
```

**Standalone mode:** Same format but omit phase commit and say "run:" instead of
"open a new chat and run:".

## Graceful Degradation

When any teammate crashes, times out, or fails:

1. Report which teammates completed and which failed.
2. Present partial findings from completed reviewers.
3. If in a resolution round and the Fixer fails: revert to last known-good state
   of modified files (git checkout the files), log the failure, and present
   findings from the last completed review round.
4. Mark the consensus as INCOMPLETE — cannot reach full consensus.
5. Suggest: "Run `/qa <feature>` for single-perspective QA as fallback."
6. Never leave orphaned teammates running.

If Phase 1 completes but Phase 2 fails (e.g., subagent crash, test infra down):
- Report Phase 1 results normally.
- Mark Phase 2 as INCOMPLETE in the report.
- Suggest: "Run `/qa <feature>` to complete the deep QA separately."

## Rules

- **ROLE SEPARATION.** Reviewers are read-only. Only the Fixer modifies files.
  The Fixer never evaluates — only the reviewers judge quality. No agent marks
  its own homework. (TACL 2024, ICLR 2024: self-evaluation degrades quality.)
- **STRUCTURED FEEDBACK.** All findings use the tabular format with file, section,
  and fix suggestion. No prose-only feedback — it wastes tokens and is ambiguous.
- **ALL FINDINGS FIXED.** CRITICAL + WARNING findings trigger resolution in ALL
  rounds. The 3-round hard cap prevents bikeshedding (rounds 4+
  typically yield <3% quality improvement for 7–10× cost).
- **REGRESSION TRACKING.** The fixed-issues log persists across ALL rounds in
  BOTH phases. A reappearing issue is automatically elevated to CRITICAL.
- **TEST OBLIGATION.** The Fixer must run relevant tests after every code change.
  No fix is considered complete until tests pass.
- **MINIMAL FIXES.** The Fixer applies surgical edits — no refactoring, no
  improvements, no scope expansion. If in doubt, fix less.
- **FULL VISIBILITY.** Show ALL findings from ALL reviewers in ALL rounds. Never
  truncate with "and N more". The user must see the complete picture.
- **NO SYCOPHANCY.** Banned in discussion: "You're absolutely right!", "Great point!",
  "Good catch!" — every evaluation must be technical. Challenge with reasoning.
- **EVIDENCE REQUIRED.** Every finding must reference a specific file, function,
  line, or test. "The code seems insecure" is not a finding.
- **EVIDENCE IN THIS MESSAGE.** Phase 2 checks must show actual output. Banned:
  "should work", "probably passes", "seems to", "likely works".
- **HARD CAP.** Maximum 3 resolution rounds per phase. No exceptions. If
  unresolved after 3 rounds, FAIL with conditions and let the human decide.
- **NO DUPLICATE FINDINGS.** Phase 2 must cross-reference the fixed-issues log
  before reporting. Findings already resolved in Phase 1 are skipped silently.
- **CAPTURE GOTCHAS.** If any reviewer or fix round hits a non-obvious failure —
  something that wasted time, required a counterintuitive fix, or would trip up a
  future agent — add it to the relevant skill's Gotchas section before presenting
  the checkpoint. One sentence: what happened and why it's surprising.
