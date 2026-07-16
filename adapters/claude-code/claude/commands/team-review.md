---
description: Team Review — two-phase plan review (team sweep + deep dive) with single checkpoint
argument-hint: <feature-name> OR flow <feature-name>
---

# Team Review: $ARGUMENTS

Two-phase plan review. Phase 1: four specialists examine plan artifacts, discuss
findings, and fix issues. Phase 2: a single Lead Dev does a deep code-level dive
on the post-sweep artifacts. One combined report, one checkpoint.

**Architecture:** Evaluator-Optimizer pattern (Anthropic) with role separation.
Reviewers never modify files. The Fixer never evaluates its own work. The
orchestrator (you) owns the loop, the verdict, and the report.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Commit review report → continues to `/implement flow`
- `amend` → User provides feedback, re-run from the phase that needs changes
- `stop` → Pause flow

## Domain Knowledge

- solid-principles skill — SOLID verification, architecture rules
- agentic-code skill — Agent navigability checklist

## Prerequisites

Read ALL feature docs:
- `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md`
- `docs/INPROGRESS_Feature_<feature>/DESIGN.md` (if exists)
- `docs/INPROGRESS_Feature_<feature>/PLAN.md`
- `docs/INPROGRESS_Feature_<feature>/TESTPLAN.md`

If PLAN.md or TESTPLAN.md is missing, tell user to run `/plan` first
(it now creates both artifacts before review) and exit.

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
- Lead Dev checks execution plan alignment (scope, dependencies, strategy, drift)

If no plan found: proceed as normal.

## Step 1: Feature Flag Guard

Check for the agent teams feature flag:

```bash
echo $CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
```

If empty or unset:
- Print: "Agent teams require the `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` feature flag."
- Print: "Enable it in your Claude Code settings, then retry."
- Suggest: "Alternatively, use `/review` for single-perspective plan review."
- **EXIT — do not proceed.**

## Step 2: Token Cost Confirmation

**If `$ARGUMENTS` contains `autopilot`:** Skip this confirmation — auto-proceed.

Before spawning the team, inform the user:

> **Token cost warning:** This command runs a two-phase review: team sweep (4
> specialists + fixer loop) followed by a deep Lead Dev dive (+ fixer loop).
> Worst case uses approximately **15–20× the tokens** of the single-perspective
> `/review` command. Typical runs complete in 1–2 rounds per phase (~8–12×).
>
> Proceed? `[proceed / cancel]`

On `cancel`:
- Print: "Cancelled. Use `/review <feature>` for single-perspective review."
- **EXIT — do not proceed.**

---

# PHASE 1: Team Sweep

Broad structural review across four specialist perspectives.

## Step 3: Team Spawning Instructions

Create an agent team with 4 reviewer teammates. Each reviewer receives:
- **Tools:** Read, Grep, Glob, Bash only (read-only — no Write, no Edit)
- **Context:** All feature docs (REQUIREMENTS.md, DESIGN.md if exists, PLAN.md)
- **Execution plan context** (if loaded from Step 0.5)

### Reviewer Definitions

Each reviewer is spawned using the Agent tool with the matching `subagent_type`.
This ensures each agent gets its full definition (tools, skills, model, structured
analysis process) — not just an inline prompt. The task-specific prompt below is
injected at spawn time.

| Role | `subagent_type` |
|------|----------------|
| BA Reviewer | `analyst` |
| UX Reviewer | `ux-designer` |
| Architect Reviewer | `architect` |
| Lead Dev Reviewer | `lead-developer` |
| QA Reviewer | `qa-engineer` |

**BA Reviewer** — `subagent_type: analyst`
- Task: Verify every requirement in REQUIREMENTS.md maps to a concrete element
  in PLAN.md. Check for dropped requirements, reinterpreted requirements, and
  scope creep. Check acceptance scenarios are testable.
- Categories: `REQUIREMENTS`
- If REQUIREMENTS.md is empty: flag CRITICAL "no requirements to review against"

**UX Reviewer** — `subagent_type: ux-designer`
- Task: Verify PLAN.md components match DESIGN.md flows (if exists). Check for
  missing interaction states, accessibility gaps, responsive breakpoints, design
  system compliance (MUI v7, border-based depth, WCAG AAA). When no DESIGN.md
  exists, review UI-touching components against project design rules (.claude/rules/).
  When no UI components exist, explicitly state "no UI components to review."
- Categories: `DESIGN`, `ACCESSIBILITY`

**Architect Reviewer** — `subagent_type: architect`
- Task: Verify SOLID compliance, agentic navigability, dependency direction,
  module boundaries, security rules. Use the solid-principles
  and agentic-code checklists. Check the Trust Boundary Awareness section
  in the security-checklist skill before flagging config values.
- Categories: `SOLID`, `AGENTIC`, `SECURITY`

**Lead Dev Reviewer** — `subagent_type: lead-developer`
- Task: Verify this can be built with the existing architecture. Are paths and
  conventions correct? TDD readiness adequate? When execution plan context is
  loaded, check alignment: scope match, dependency respect, strategy alignment,
  requirements traceability.
- Categories: `FEASIBILITY`, `TDD`, `DRIFT`

**QA Reviewer** — `subagent_type: qa-engineer`
- Task: Verify TESTPLAN.md against REQUIREMENTS.md and PLAN.md. Every
  requirement and every component must have at least one scenario.
  Negative paths (errors, validation, boundaries) must be present, not
  only golden paths. Cross-cutting concerns (auth, logging, feature
  flags) covered for components that touch them. Manual scenarios (if
  any UI surface) mapped to host plan `task.manualtest_scenarios` on
  2.0 schemas. Flag tautological scenarios ("test passes if function
  returns anything") and stub-friendly scenarios.
- Categories: `TESTPLAN`, `COVERAGE`, `MANUALTEST`
- Severity floor: missing requirement coverage in TESTPLAN.md is
  WARNING minimum. Missing component coverage is WARNING minimum.
  Missing negative-path coverage on a behaviour with documented error
  modes is WARNING minimum.

### Fixer Definition (spawned during resolution loops in both phases)

The Fixer is spawned via the Agent tool with `subagent_type: fixer` — a subagent
(NOT a teammate). It has write access to feature docs only (scoped via the prompt
template). See Step 7.2 for the prompt template used when spawning it.

## Step 4: Review Phase (Round 0)

Each reviewer reads all artifacts and produces findings independently.

**Finding format (structured — mandatory):**
```
| # | Severity | Category | File | Section/Line | Description | Fix suggestion |
```

Severities: `CRITICAL`, `WARNING`, `SUGGESTION`

**Severity floor rules (MANDATORY):**
- **SECURITY findings** (from Architect or any reviewer): minimum severity is
  WARNING. Security issues are never SUGGESTION — they enter the fix loop.
- **Missing requirement coverage** (from BA): if a requirement in REQUIREMENTS.md
  has no corresponding element in PLAN.md, minimum severity is WARNING.
- Only cosmetic, stylistic, or preference-based findings may be SUGGESTION.
- When in doubt, classify as WARNING. False positives are filtered in discussion;
  false negatives slip through the vote and get deferred.

**Severity classification criteria (mandatory for all reviewers):**

A finding is **WARNING** (mandatory fix) if ANY of these apply:
- Would cause a bug, crash, or incorrect behavior at runtime
- Violates a security boundary (injection, auth bypass, data exposure)
- Breaks an interface contract or API compatibility
- Violates a project convention documented in CLAUDE.md or rules/
- Missing coverage for a requirement or acceptance criterion
- Data loss, corruption, or inconsistency risk
- Missing test for a documented acceptance scenario

A finding is **SUGGESTION** (subject to vote) ONLY if ALL of these apply:
- Cosmetic, stylistic, or preference-based
- No runtime impact if left unchanged
- Does not violate any documented convention
- Alternative approaches exist but current approach is functional

**When in doubt, classify as WARNING.** It's cheaper to fix a false
WARNING than to miss a real defect through deferral.

**Pre-existing issues policy:**
- Issues in files the feature **modifies**: treat as in-scope. The code is open,
  tests are running, risk is low. Fix them — don't defer as "pre-existing."
- Issues in files the feature **does not touch**: defer as out-of-scope.
- Never use "pre-existing" as a reason to skip a fix in modified files.

The `Fix suggestion` column gives the Fixer enough context to act without
re-analyzing the entire plan. Keep it specific: "Add acceptance criterion for
edge case X in REQUIREMENTS.md §3.2" not "requirements seem incomplete."

Each reviewer completes their full analysis before sharing findings. No
premature discussion — findings-first ensures complete analysis.

## Step 5: Discussion Phase

After all reviewers complete Step 4, initiate cross-reviewer discussion.

**The team's ONLY authority in discussion:** adjudicate each finding as
either REAL or FALSE-POSITIVE. The team cannot defer or "downgrade to
avoid fixing". All REAL findings (CRITICAL + WARNING) route automatically
to Step 7 Resolution Loop where the Fixer agent attempts each one.
Deferral is ONLY possible as output of Fixer failure, never as team
decision.

**Rationale (research-backed, 2025):** Multi-agent debate research
(Wynn & Satija ICML 2025; arXiv 2509.16533) shows LLM agents flip from
correct to incorrect positions under rhetorical pressure in up to 88%
of autonomous configurations. The structural fix is to remove the team's
authority to decide fix-vs-defer, not to add more prompt rules. Industry
precedent (DEV/Earezki 2026, Shing Lyu ADR-in-code pattern): "the same
agent must not both write code and decide whether it's correct."

### 5.1: Cross-reviewer challenge on REAL vs FALSE-POSITIVE only

1. Each reviewer shares findings via messaging.
2. Challenges focus on classification: REAL vs FALSE-POSITIVE. Severity
   per Step 4 floor rules.
3. Challenges may NOT be "we should defer" or "this isn't worth fixing"
   — those are fix-vs-defer decisions outside team authority.

### 5.2: FALSE-POSITIVE requires two-agent concurrence with evidence

To prevent reclassification-as-escape-hatch, FALSE-POSITIVE requires:
1. **Two reviewers concur** — originating reviewer plus at least one
   other agree it's not a real issue
2. **Evidence cited** — specific file:line, AC reference, or existing
   test that demonstrates the finding doesn't apply
3. **Not severity-downgrade in disguise** — "real but low-priority" is
   severity classification, not false-positive

Single-reviewer false-positive calls or bare reclassifications remain
REAL and route to the Fixer.

### 5.3: Anti-sycophancy protocol (MANDATORY)

- Banned phrases: "You're absolutely right!", "Great point!", "Good catch!",
  "Excellent observation!", "Well spotted!" and synonyms.
- Every response to a challenge must include technical reasoning.
- Agreement requires stronger justification than disagreement.

### 5.4: Tie-breaking

Orchestrator resolves real-vs-false-positive disputes after 2 rounds.
When uncertain, classify as REAL (Fixer attempts; failure log becomes
deferral basis if fix genuinely can't land).

### 5.5: Output

Consolidated findings list with only two outcomes:

| Classification | Routing |
|---|---|
| REAL (any severity) | Step 6 → Step 7 Resolution Loop (Fixer attempts all) |
| FALSE-POSITIVE (2-agent + evidence) | Logged in TEAM_REVIEW.md, not routed |

No "deferred" classification at this stage. Deferral is output of Fixer
failure (Step 7), never team decision.

## Step 6: Phase 1 Synthesis

After discussion, compile the consolidated findings list:

- **REAL (CRITICAL or WARNING)** → Resolution Loop (Step 7). ALL route to Fixer.
- **REAL (SUGGESTION)** → Logged for triage after both phases complete.
- **FALSE-POSITIVE** → Logged with 2-agent concurrence and evidence.

**Verdict:**
- **PHASE 1 APPROVED**: Zero REAL CRITICAL/WARNING findings.
  Proceed to Phase 2 (Step 8).
- **NEEDS RESOLUTION**: One or more REAL CRITICAL/WARNING findings.
  Enter Resolution Loop. Fixer attempts every one.

**Deferral semantics (MANDATORY):**

Deferral is an OUTPUT of Step 7 Resolution Loop, never an output of
Step 5 discussion. A finding becomes "deferred" ONLY if:
1. Classified REAL in Step 5
2. Entered Resolution Loop in Step 7
3. Fixer returned `BLOCKED` with specific failure log (compilation error,
   test failure, architectural conflict, dependency problem)
4. Block persists after 3 rounds of Fixer attempts

The Fixer's failure log IS the deferral justification. Not team reasoning.
Not "downgraded" or "internal path" or "out of scope". The
`deferred-findings.json` entry records the Fixer's evidence verbatim.

---

## Step 7: Phase 1 Resolution Loop

### 7.0: Brief Sizing & Fixer Reliability

**Mandatory: Cap each Resolution Brief at ~20 findings.**

Empirical pattern (monorepo-consolidation T2, 2026-04-29): Fixer briefs
containing >50 findings consistently produce truncated responses where some
items the Fixer reports as `FIXED` were never actually applied to disk
(also previously documented in `unified-plan-yaml-schema` TEAM_REVIEW.md
phase-2 deep review: "14+ items the Fixer reported FIXED were NOT actually
applied"). Truncation happens because the Fixer's response hits the LLM
output-token limit mid-execution and surfaces an incomplete summary.

**Chunking rule:**

If the synthesis produces more than 20 CRITICAL+WARNING findings:

1. Split into chunks of ~20 findings each, ordered by file proximity
   (group findings on the same file together so the Fixer doesn't oscillate
   context per chunk).
2. Run the Fixer once per chunk **within the same round** — track sub-rounds
   as `Round 1.A`, `Round 1.B`, `Round 1.C`. Each chunk has its own
   resolution brief with its own `Issues to resolve` table.
3. The `Previously fixed issues` table accumulates across chunks within the
   round AND across rounds (per the existing fixed_issues_log invariant).
4. After each chunk's Fixer returns, run **mandatory grep verification**
   (Step 7.3a below) before launching the next chunk — catches the
   "Fixer reported FIXED but didn't apply" failure mode early instead of
   compounding it across chunks.

For ≤20 findings, run a single chunk per round (no sub-rounds; standard flow).

**Single chunk size threshold:** 20 findings is empirical (4-6 minor edits
per finding × 20 findings ≈ within typical Opus 4.7 output budget). If a
specific finding-set has unusually large per-finding edits (e.g., refactors
spanning 50+ lines each), reduce the chunk to ~10. If findings are mostly
trivial one-liners (e.g., string replacements), 30 is acceptable.

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
N/A — this is a plan/docs review. Do not run tests.

### Scope constraint
You may ONLY edit files in: docs/INPROGRESS_Feature_<feature>/
Do not touch source code, test files, or any file outside the feature docs folder.

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
- Source code and test files
````

The Fixer returns a **fix report** (defined in its agent file):
```markdown
| # | Status | What changed | File | Lines affected | Tests |
```
Status: `FIXED`, `PARTIALLY_FIXED` (with explanation), `BLOCKED` (with reason)
Tests: `N/A` (always, for plan review)

Any BLOCKED items are escalated to the orchestrator. If the block is a
conflicting requirement or ambiguous spec, pause the loop and ask the user.

### 7.3: Update Fixed-Issues Log

Add all FIXED and PARTIALLY_FIXED items to `fixed_issues_log` with phase and round number.

### 7.3a: Mandatory Fixer Grep-Verification

**Before continuing to Step 7.4 (re-review), verify the Fixer actually
applied the changes it claimed.** Empirically, ~5-15% of items the Fixer
reports as FIXED are not actually written to disk (truncation, race
conditions, or logical errors in the Fixer's edit construction).

For each item the Fixer marked `FIXED`:

1. Extract the file path and the specific change-evidence from the Fixer's
   report (e.g., a function name, a string literal, a regex pattern).
2. Run `grep -F "<evidence>" <file-path>` (or equivalent test) to confirm
   the change is present.
3. If grep returns no match: reclassify the item as **NOT_FIXED** in the
   fixed_issues_log, remove it from "previously fixed", and re-add it to
   the next round's brief.
4. Tally a "Fixer reliability" stat per round: `(claimed_fixed - actually_fixed) / claimed_fixed`. Log to phase notes.

If reliability drops below 80% in any round (i.e., >20% of FIXED claims
are wrong), escalate to orchestrator: smaller chunks (drop chunk size from
20 to 10), or pause and inspect the Fixer subagent's prompt/context for
why it's misreporting.

### 7.4: Re-Review (Focused)

Re-spawn the 4 reviewers (each with their original `subagent_type` — see table
in Step 3), but with a **narrowed scope:**
- Review ONLY the files/sections that the Fixer modified
- Verify each fix actually resolves the original finding
- Check for regressions: does this fix break something that was previously correct?
- Produce findings in the same structured format

**All CRITICAL and WARNING findings must be resolved before approval.** Both
severities trigger loop iterations in all rounds. The 3-round hard cap prevents
bikeshedding — if issues remain after 3 rounds, the plan is REJECTED with
conditions for the human to decide.

### 7.5: Re-Discuss and Re-Synthesize

Same protocol as Steps 5–6, but scoped to new/changed findings only.

Possible outcomes:
- **PHASE 1 APPROVED** → Exit loop, proceed to Phase 2 (Step 8)
- **NEEDS RESOLUTION** + `round < max_rounds` → Loop back to 7.1
- **NEEDS RESOLUTION** + `round >= max_rounds` → Exit loop with REJECTED verdict.
  Skip Phase 2. Proceed directly to Report (Step 10).

### 7.6: Convergence Detection

Before looping back to 7.1, check:
- If the exact same findings persist from the previous round (same category,
  same file, same description), the loop has stalled. Exit with REJECTED verdict
  and note "convergence failure — same issues persist after fix attempt."
- If a previously-fixed issue reappears, flag as REGRESSION in the report.
  Regressions count as CRITICAL regardless of original severity.

### 7.7: Loop Termination Summary

Print after each round:
```
Phase 1, Round <N>/<max>: <APPROVED | NEEDS RESOLUTION | REJECTED>
  Fixed: <count>  |  Remaining: <count>  |  Regressions: <count>
  New findings this round: <count>
```

---

# PHASE 2: Deep Review

Single Lead Dev deep dive on the post-sweep plan. Catches code-level issues that
the breadth-focused team sweep misses.

**Entry condition:** Phase 1 APPROVED. If Phase 1 REJECTED, skip Phase 2 entirely.

**IMPORTANT — Keep reviewers alive:** Do NOT shut down or dismiss the Phase 1
reviewer teammates yet. They are needed for suggestion voting in Step 9.2 after
Phase 2 completes. If reviewers shut down from inactivity during Phase 2, they
cannot vote. To prevent this, send each reviewer a brief hold message before
starting Phase 2:

> "Phase 1 complete. Holding for suggestion vote after Phase 2. Stand by."

This keeps their context active. Only shut down reviewers AFTER Step 9 completes.

## Step 8: Deep Review

The orchestrator (you) performs a focused code-level review of the plan artifacts
in their post-Phase-1 state. This is a deeper pass than the team's Lead Dev
reviewer — the full token budget goes to a single perspective.

### 8.1: Review Checks

Run these checks against the current PLAN.md (post-Phase-1 fixes):

1. **Cross-document consistency** (deeper than Phase 1 BA check):
   - [ ] Every requirement in REQUIREMENTS.md has a corresponding component in PLAN.md
   - [ ] If DESIGN.md exists: PLAN.md components match the designed UI/UX flows
   - [ ] No requirement dropped or reinterpreted between documents
   - [ ] No component in PLAN.md that has no basis in REQUIREMENTS.md (scope creep)

2. **Feasibility** (deeper than Phase 1 Lead Dev check):
   Can this be built with the existing architecture? Dependencies available?
   Paths consistent with conventions?

3. **Execution plan alignment** (only when plan context is loaded):
   - [ ] Scope match: PLAN.md delivers what the execution plan task specifies
   - [ ] Dependency respect: builds on completed dependencies correctly
   - [ ] Strategy alignment: consistent with overall execution plan architecture
   - [ ] Requirements traceability: every acceptance criterion maps to PLAN.md

4. **CLAUDE.md architecture rules:**
   Verify against project rules (orchestrator pattern, fail-closed, import
   directions, etc.).

5. **SOLID verification:**
   Delegate to `code-reviewer` subagent (Sonnet, read-only) — run SOLID
   checklist only. Return structured findings per component with severity.
   Don't trust the Architect's self-assessment from Phase 1.

6. **Agentic navigability:**
   Check plan against the agentic-code checklist: navigable names,
   explicit interfaces, traceable flow, observable errors, documented topology.

7. **TDD readiness:**
   Delegate to `test-explorer` subagent (Haiku, read-only) — can each component
   be tested in isolation? What fixtures exist? What patterns are used?

### 8.2: Deep Review Findings

Collect all findings from checks 1-7 into a structured list:
```
Finding #N: [severity] [category] — description
  Fix: what to change in PLAN.md
```

**Exclude anything already fixed in Phase 1.** Cross-reference the fixed-issues
log — if a finding matches something already resolved, skip it.

- If **zero findings** → Deep review clean. Proceed to Suggestion Triage (Step 9).
- If **any findings** → Enter Phase 2 Resolution Loop (Step 8.3).

### 8.3: Phase 2 Resolution Loop

Same structure as Phase 1 Resolution Loop (Step 7), but:
- The orchestrator re-checks (not the 4-reviewer team)
- The same Fixer applies fixes
- The `fixed_issues_log` carries over from Phase 1
- Maximum 3 passes (same guard as Phase 1)

For each round:
1. Compile resolution brief for the Fixer using the **same prompt template
   from Step 7.2** (CRITICAL + WARNING findings only, carry over the full
   fixed-issues log from both phases)
2. Spawn the Fixer (`subagent_type: fixer`) with the filled template
3. Update fixed-issues log from the Fixer's report
4. Orchestrator re-runs checks 1-7 on modified sections only
5. If zero findings → clean. If findings remain + rounds left → loop.

Print after each round:
```
Phase 2, Pass <N>/3: <CLEAN | NEEDS FIX>
  Fixed: <count>  |  Remaining: <count>
```

After pass 3 with remaining findings: present to user and ask for guidance
(same as the standalone `/review` behavior).

### 8.4: Deep Review Verdict

- **APPROVED**: Both phases clean. Proceed to Suggestion Triage (Step 9).
- **REJECTED**: Phase 2 findings could not be resolved after 3 passes.
  Proceed to Report (Step 10) with REJECTED verdict.

---

## Step 9: Suggestion Triage

**Entry condition:** Both phases APPROVED.

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

**Interactive mode:** Send the suggestion list to all 4 reviewers (from
Phase 1). Each reviewer responds with a single vote per suggestion — no
discussion, no justification:
- **adopt** — quick win, should be applied now
- **defer** — save for later, not worth the cost now

Format: `#1: adopt | #2: defer | #3: adopt | ...`

**Fallback — reviewers unavailable:** If any reviewers have shut down (context
exhaustion, timeout, or crash) before voting completes:
1. Count votes only from reviewers that responded.
2. If **zero reviewers** responded: the orchestrator triages suggestions directly
   using context from both phases. Apply the same adopt/defer criteria — adopt
   if the suggestion is a quick win with clear benefit, defer if it's cosmetic
   or risky. Log: "Orchestrator triage (reviewers unavailable)."
3. If **some but not all** responded: adjust majority threshold to >50% of
   responding voters (e.g., 2 of 3, or 1 of 1). Log which reviewers were
   unavailable.

### 9.3: Tally and Apply

Count votes per suggestion. Apply these adoption rules:

1. **Domain expert authority:** If the suggestion's category matches a
   reviewer's domain, that reviewer's single "adopt" vote is sufficient —
   no majority needed. Domain mapping:
   - Architect owns: `SOLID`, `AGENTIC`, `SECURITY`
   - BA owns: `REQUIREMENTS`
   - UX owns: `DESIGN`, `ACCESSIBILITY`
   - Lead Dev owns: `FEASIBILITY`, `TDD`, `DRIFT`
2. **Majority adopt** (>50% of voters) → adopted regardless of category.
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
3. **No re-review.** Adopted suggestions do not trigger another review cycle.
   The Fixer's changes are recorded in the report as-is.

If no suggestions reached majority: skip the Fixer, log all as deferred.

### 9.4: Triage Summary

Print:
```
Suggestion triage: <total> suggestions | <adopted> adopted | <deferred> deferred
```

### 9.5: Persist Deferred Suggestions

If any suggestions were deferred, append them to a central tracker so they
aren't lost in individual review reports.

**Schema-version dispatch (mandatory):**

First locate the colocated execution plan:

```
PLAN_YAML=$(find docs/INPROGRESS_Plan_*/execution-plan.yaml -maxdepth 2 2>/dev/null | head -1)
```

Read its `schema_version` field:

| `schema_version` | Target | Tooling |
|------------------|--------|---------|
| `2.0.0` | `project.deferred[]` array in the YAML, polymorphic `kind: review_suggestion` entries | `python3 -m plan_yaml_deferred` (use `claude/tools/lib/plan_yaml_deferred.py`'s `make_review_suggestion_entry()` + `append_deferred()`) |
| `1.x.y` | `docs/INPROGRESS_Plan_*/DEFERRED.md` (legacy markdown table — see "Legacy 1.x" below) | Edit tool, manual table-row append |
| (no plan or 2.0 path fails) | `docs/DEFERRED.md` at project root | Edit tool |

**2.0 path — use the helper library:**

For each deferred suggestion, create a `review_suggestion` entry and append
to `project.deferred[]`. The helper enforces schema-required fields and
rejects duplicate IDs.

Required fields per entry (from `make_review_suggestion_entry`):
- `id` — unique slug (suggested format: `RS-<task-id>-<NNN>`, e.g. `RS-T2-001`)
- `kind: review_suggestion`
- `date` — today's date (YYYY-MM-DD)
- `feature_or_task_id` — the feature being reviewed
- `phase_id` — `team-review` or `team-qa`
- `reviewer` — MUST be one of the schema enum: `ba`, `ux`, `architect`, `lead-dev`, `solid-checker`, `performance`, `security`, `code-reviewer`, `qa-lead`, `tester`, `deep-qa`, `deep-code` (NOT the agent display name like "ux-designer" or "analyst" — use the enum value)
- `category` — MUST be one of: `REQUIREMENTS`, `DESIGN`, `SOLID`, `SRP`, `OCP`, `ISP`, `DIP`, `SECURITY`, `PERFORMANCE`, `AGENTIC`, `TDD`, `CONVENTION`, `COMPLETENESS`, `DRIFT`, `COVERAGE`, `TEST_QUALITY`, `CORRECTNESS`, `FEASIBILITY`
- `description` — the suggestion description (≥1 char)
- `reason_deferred` — why deferred (≥40 chars; pad short reasons with context like "orchestrator deferred per autopilot triage")

Invocation example (one entry per suggestion; helper handles file-level locking):

```bash
python3 -c "
import sys
sys.path.insert(0, 'adapters/claude-code/claude/tools/lib')
from plan_yaml_deferred import append_deferred, make_review_suggestion_entry
from pathlib import Path
entry = make_review_suggestion_entry(
    id='RS-${TASK_ID}-001',
    date='$(date -u +%Y-%m-%d)',
    feature_or_task_id='${TASK_ID}',
    phase_id='team-review',
    reviewer='ux',                      # enum value, not 'ux-designer'
    category='DESIGN',
    description='<the deferred suggestion description>',
    reason_deferred='<reason ≥40 chars; pad if needed>',
)
append_deferred(Path('${PLAN_YAML}'), entry)
"
```

After appending all entries, verify the YAML still validates:

```bash
python3 ~/.claude/tools/validate-plan.py ${PLAN_YAML}
```

**Why this is the canonical path for 2.0 plans:** schema 2.0 absorbed the
content of DEFERRED.md (and other legacy markdown sidecars) into the unified
YAML. The `plan_yaml_deferred` library is the sole dispatch point for the
seven other consumers (filter-deferred.py, finalise-deferred.py,
ratchet-autolog.py, emit-baseline.py, get-findings.sh, commit-preflight.sh,
grinder-audit.py). Producers (this command and team-qa) MUST use the same
library so producer-consumer state matches. Writing to DEFERRED.md alongside
a 2.0 plan triggers `validate-plan.py`'s R14 warning.

**Legacy 1.x path — markdown table:**

For 1.x plans only, append to `DEFERRED.md`:

```markdown
# Deferred Suggestions

Items deferred during team reviews and QA. Review periodically during
`/productmanager` sessions or when starting related features.

| Date | Feature | Phase | Reviewer | Category | Description | Reason deferred |
|------|---------|-------|----------|----------|-------------|-----------------|
```

Append one row per deferred suggestion using the Edit tool. Fields are the
same as the 2.0 entries but use display names freely (no enum constraint).
This file is **append-only** during reviews. Rows are removed or marked done
by `/productmanager` or manually when addressed.

---

## Step 10: Report

Write `docs/INPROGRESS_Feature_<feature>/TEAM_REVIEW.md` with this structure:

```markdown
<!-- phase: team-review | date: YYYY-MM-DD | branch: <branch> -->

# Team Review Report: <feature>

## Team
- BA Reviewer | UX Reviewer | Architect | Lead Dev | Deep Reviewer (orchestrator) | Fixer

## Review Summary
- **Verdict:** APPROVED | REJECTED
- **Phase 1 (Team Sweep):** <N> rounds | <count> findings | <count> fixed
- **Phase 2 (Deep Review):** <N> passes | <count> findings | <count> fixed
- **Total findings:** <count> | Fixed: <count> | Remaining: <count>

---

## Phase 1: Team Sweep

### Round 0: Initial Review

#### BA Reviewer
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

#### UX Reviewer
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

#### Architect
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

#### Lead Dev
| # | Severity | Category | Description | Challenged | Resolution |
|---|----------|----------|-------------|------------|------------|

### Discussion Summary (Round 0)
Key challenges and how they were resolved.

### Resolution Rounds

#### Round <N>
**Fixer actions:**
| # | Original finding | Status | What changed |
|---|-----------------|--------|-------------|

**Re-review findings:**
| # | Severity | Category | Reviewer | Description | New/Regression |
|---|----------|----------|----------|-------------|----------------|

**Round outcome:** <APPROVED | NEEDS RESOLUTION>

(Repeat for each round)

### Phase 1 Verdict: <APPROVED | REJECTED>

---

## Phase 2: Deep Review

### Checks Performed
1. Cross-document consistency
2. Feasibility
3. Execution plan alignment (if applicable)
4. CLAUDE.md architecture rules
5. SOLID verification (via code-reviewer subagent)
6. Agentic navigability
7. TDD readiness (via test-explorer subagent)

### Findings
| # | Pass | Severity | Category | Description | Fix applied |
|---|------|----------|----------|-------------|-------------|

### Phase 2 Verdict: <APPROVED | REJECTED>

---

## Fixed-Issues Log (both phases)
| # | Phase | Description | Fixed in round/pass | Regression? |
|---|-------|-------------|---------------------|-------------|

## Consensus Decision
**APPROVED** | **REJECTED with conditions**

### Conditions (if REJECTED)
1. [Condition traceable to finding — could not be auto-resolved because...]
2. ...

### Suggestions — Adopted
| # | Phase | Description | Votes (adopt/defer) | Fixer action |
|---|-------|-------------|---------------------|--------------|
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
Team review complete: <APPROVED or REJECTED>
  Phase 1 (Team Sweep): <APPROVED after N rounds | REJECTED>
  Phase 2 (Deep Review): <APPROVED after N passes | REJECTED | skipped>

<Summary — findings count, resolution count, remaining issues if any>

Files modified: <list of plan docs changed by Fixer, if any>
Files written: docs/INPROGRESS_Feature_<feature>/TEAM_REVIEW.md
Branch: <branch>

On [yes]:
  1. git add <all modified files>
     git commit -m "docs(<feature>): team review — approved"
  2. STOP — open a new chat and run: /implement flow <feature>

On [amend]:
  → User provides feedback. Re-run from the relevant phase.

On [stop]:
  → Pause flow. Resume later in a new chat: /team-review flow <feature>

Continue? [yes / amend / stop]
```

**Standalone mode:** Same format but omit phase commit and say "run:" instead of
"open a new chat and run:".

## Graceful Degradation

When any teammate crashes, times out, or fails:

1. Report which teammates completed and which failed.
2. Present partial findings from completed reviewers.
3. If in a resolution round and the Fixer fails: revert to last known-good state
   of plan docs (git checkout the files), log the failure, and present findings
   from the last completed review round.
4. Mark the consensus as INCOMPLETE — cannot reach full consensus.
5. Suggest: "Run `/review <feature>` for single-perspective review as fallback."
6. Never leave orphaned teammates running.

If Phase 1 completes but Phase 2 fails (e.g., subagent crash):
- Report Phase 1 results normally.
- Mark Phase 2 as INCOMPLETE in the report.
- Suggest: "Run `/review <feature>` to complete the deep review separately."

If reviewers shut down before suggestion voting (Step 9.2):
- The orchestrator triages suggestions directly using full context from both phases.
- Log: "Orchestrator triage (reviewers shut down before voting)."
- Apply same adopt/defer criteria as reviewer voting would.

## Rules

- **ROLE SEPARATION.** Reviewers are read-only. Only the Fixer modifies files.
  The Fixer never evaluates — only the reviewers judge quality. No agent marks
  its own homework. (TACL 2024, ICLR 2024: self-evaluation degrades quality.)
- **STRUCTURED FEEDBACK.** All findings use the tabular format with file, section,
  and fix suggestion. No prose-only feedback — it wastes tokens and is ambiguous.
- **ALL FINDINGS FIXED.** CRITICAL + WARNING findings trigger resolution in ALL
  rounds. The 3-round hard cap prevents bikeshedding — if issues remain after 3
  rounds, REJECT with conditions for the human to decide.
- **REGRESSION TRACKING.** The fixed-issues log persists across ALL rounds in
  BOTH phases. A reappearing issue is automatically elevated to CRITICAL.
- **MINIMAL FIXES.** The Fixer applies surgical edits — no refactoring, no
  improvements, no scope expansion. If in doubt, fix less.
- **FULL VISIBILITY.** Show ALL findings from ALL reviewers in ALL rounds. Never
  truncate with "and N more". The user must see the complete picture.
- **NO SYCOPHANCY.** Banned in discussion: "You're absolutely right!", "Great point!",
  "Good catch!" — every evaluation must be technical. Challenge with reasoning.
- **EVIDENCE REQUIRED.** Every finding must reference a specific section, line, or
  component. "The plan seems incomplete" is not a finding.
- **HARD CAP.** Maximum 3 resolution rounds per phase. No exceptions. If
  unresolved after 3 rounds, REJECT with conditions and let the human decide.
- **NO DUPLICATE FINDINGS.** Phase 2 must cross-reference the fixed-issues log
  before reporting. Findings already resolved in Phase 1 are skipped silently.
- **CAPTURE GOTCHAS.** If any reviewer or fix round hits a non-obvious failure —
  something that wasted time, required a counterintuitive fix, or would trip up a
  future agent — add it to the relevant skill's Gotchas section before presenting
  the checkpoint. One sentence: what happened and why it's surprising.
