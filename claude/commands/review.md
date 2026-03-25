---
description: Lead Developer — review an architect's feature plan for feasibility and quality
argument-hint: <feature-name> OR flow <feature-name>
---

# Lead Developer: Review $ARGUMENTS

Review the plan for feasibility and quality. Automatically fix all issues found — loop until the plan is clean.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[yes / stop]` (presented only after plan passes all checks)
- `yes` → Plan approved → continues to `/implement flow`
- `stop` → Pause flow

## Domain Knowledge

- solid-principles skill — SOLID verification, architecture rules
- tdd-workflow skill — TDD readiness assessment
- agentic-code skill — Agent navigability checklist

## Prerequisites

Read ALL feature docs: `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md`, `docs/INPROGRESS_Feature_<feature>/DESIGN.md` (if exists), `docs/INPROGRESS_Feature_<feature>/PLAN.md`. If PLAN.md missing, tell user to run `/plan`.

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
- Plan acceptance criteria become additional review targets
- Execution plan strategy becomes the drift baseline (Step 2b)

If no plan found: proceed as normal (skip step 2b).

## Step 0.7: Team Review Context

Check for `docs/INPROGRESS_Feature_<feature>/TEAM_REVIEW.md`:

- **If exists and APPROVED (two-phase):** The `/team-review` command already
  includes a deep review phase. Note "Full team review (including deep dive)
  already passed" in output. Suggest the user proceed to `/implement` instead.
  If the user wants to continue anyway, proceed with normal review.
- **If exists and REJECTED with conditions:** Read the `## Consensus Decision` and
  `### Conditions` sections. Add each numbered condition to the review checklist as
  an additional target (same weight as SOLID findings). These conditions were raised
  by multi-perspective team review and must be verified or addressed.
- **If exists and APPROVED (legacy, no Phase 2 section):** Note "Team review
  passed — no additional conditions" in output. Proceed with normal review.
- **If not exists:** Skip silently (backward compatible).

## Workflow: Review-Fix Loop

Run steps 1-6 (review), then step 7 (fix). Repeat until step 7 produces zero findings.

### Review Phase (steps 1-6)

1. **Cross-document consistency.** Verify the full chain REQUIREMENTS → DESIGN → PLAN is consistent:
   - [ ] Every requirement in REQUIREMENTS.md has a corresponding component in PLAN.md
   - [ ] If DESIGN.md exists: PLAN.md components match the designed UI/UX flows
   - [ ] No requirement dropped or reinterpreted between documents
   - [ ] No component in PLAN.md that has no basis in REQUIREMENTS.md (scope creep)

2. **Check feasibility.** Can this be built with the existing architecture? Dependencies available? Paths consistent with conventions?

2b. **Execution plan alignment** (only when plan context is loaded from Step 0.5):
   Compare PLAN.md against the execution plan task and its context:
   - [ ] **Scope match:** Does PLAN.md deliver what the execution plan task specifies? Flag additions not in the task scope or missing items from the task acceptance criteria.
   - [ ] **Dependency respect:** Does PLAN.md build on completed dependencies (DONE_* docs) correctly? Does it reference the right interfaces/contracts from predecessor tasks?
   - [ ] **Strategy alignment:** Is the approach consistent with the overall execution plan's architecture? Would this plan conflict with parallel in-progress features?
   - [ ] **Requirements traceability:** Every execution plan acceptance criterion maps to a concrete element in PLAN.md.

   Findings from 2b are categorized as `DRIFT` severity (same weight as SOLID violations).

3. **Verify CLAUDE.md architecture rules** (orchestrator pattern, EVAL=PROD, fail-closed, import directions, DAL rules).

4. **Verify SOLID.** Delegate to `code-reviewer` subagent (Sonnet, read-only) — run SOLID checklist only. Return structured findings per component with severity. Don't trust the Architect's self-assessment.

5. **Verify agentic navigability.** Check plan against the agentic-code checklist: navigable names, explicit interfaces, traceable flow, observable errors, documented topology, versioned specs.

6. **Verify TDD readiness.** Delegate to `test-explorer` subagent (Haiku, read-only) to check: can each component be tested in isolation? What fixtures exist? What patterns are used in similar tests?

### Fix Phase (step 7)

7. **Collect all findings** from steps 2-6 into a structured list:
   ```
   Finding #N: [severity] [category] — description
   Fix: what to change in PLAN.md
   ```

   - If **zero findings** → plan is clean, proceed to step 8.
   - If **any findings** → apply ALL fixes directly to `docs/INPROGRESS_Feature_<feature>/PLAN.md`, then:
     - Print: `Review pass N: fixed K issues. Re-reviewing...`
     - **Loop back to step 1** with the updated plan.

   **Loop guard:** Maximum 3 passes. If findings remain after pass 3, present remaining issues to user and ask for guidance.

### Approval (step 8)

8. **Write review report.** Create `docs/INPROGRESS_Feature_<feature>/REVIEW.md`:

   ```markdown
   <!-- phase: review | date: YYYY-MM-DD | branch: <branch> -->

   # Review Report: <feature>

   ## Verdict: APPROVED (N passes, K fixes)

   ## Summary
   <3-5 sentences on the final plan state>

   ## Findings Resolved
   | # | Pass | Category | Description | Fix Applied |
   |---|------|----------|-------------|-------------|

   ## Findings Remaining (if any after 3 passes)
   | # | Category | Description | Reason |
   |---|----------|-------------|--------|

   ## Checklist
   - [ ] Cross-document consistency: REQUIREMENTS → PLAN
   - [ ] Feasibility against existing architecture
   - [ ] CLAUDE.md architecture rules
   - [ ] SOLID compliance
   - [ ] Agentic navigability
   - [ ] TDD readiness
   ```

9. **Flow checkpoint.** Present using the Checkpoint Contract from the flow-mode skill:

   ```
   Review complete: ✅ APPROVED (N passes, K fixes)

   <Summary — 3-5 sentences>

   Files written:
     docs/INPROGRESS_Feature_<feature>/PLAN.md (reviewed)
     docs/INPROGRESS_Feature_<feature>/REVIEW.md

   Branch: <branch>

   On [yes]:
     1. git add docs/INPROGRESS_Feature_<feature>/PLAN.md docs/INPROGRESS_Feature_<feature>/REVIEW.md
        git commit -m "docs(<feature>): review — approved"
     2. STOP — open a new chat and run: /implement flow <feature>

   On [stop]:
     → Pause flow. Resume later in a new chat: /review flow <feature>

   Continue? [yes / stop]
   ```

   **Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Rules

- Be specific: "violates SRP" is not enough — name the component, explain why, describe the fix.
- Fixes must preserve the plan's intent — correct structure and compliance, don't redesign.
- Each fix must be traceable: state what finding triggered it and what changed.
- Do NOT write implementation code — only modify the plan document.
- **NO DEFERRING.** If the plan contains "deferred", "future work", "later phase", "out of scope for now", or similar — that IS a finding. Either the plan must fully specify the component or explicitly remove it. Nothing gets kicked down the road.
- **FULL VISIBILITY.** Show ALL findings to the user — every single one, with severity. Never summarize as "and N more minor issues". The user must see the complete list.
- **CAPTURE GOTCHAS.** If you hit a non-obvious failure during this phase — something that wasted time, required a counterintuitive fix, or would trip up a future agent — add it to the relevant skill's Gotchas section before presenting the checkpoint. One sentence: what happened and why it's surprising.
