---
name: plan-team-flow
description: Team Plan Design subflow for /plan-project when --team or --team-lite is set. Owns Step 5T.1 specialist definitions, 5T.2 independent analysis, 5T.3 synthesis, 5T.4 team discussion, 5T.5 synthesis verdict, and 5T.6 resolution loop. Read inline by /plan-project at Step 5T.
disable-model-invocation: true
user-invocable: false
---

# Plan Team Flow — Step 5T

This file is read verbatim by `/plan-project` when `--team` or
`--team-lite` is set. Replaces Step 5 (solo flow) with multi-specialist
collaborative plan design.

**Event-emit convention.** When this skill instructs *"Emit NDJSON event
`X` with `{key1, key2, ...}`"* (e.g., in §5T.2 validator), the operational
meaning is a Bash tool invocation of the plan event writer:
```bash
bash ~/.claude/tools/lib/plan-event-writer.sh emit <plan-name> X \
  key1=<value1> key2=<value2> ...
```
The writer appends to `docs/INPROGRESS_Plan_<plan-name>/_PLANPROJECT_STREAM.ndjson`
(local I/O only — no API call). See `commands/plan-project.md`
"Plan event stream" section above Step 0 for the full convention.

## Contents

- §5T.1 Specialist Definitions
- §5T.2 Phase A — Independent Analysis (parallel)
- §5T.3 Phase B — Synthesis
- §5T.4 Phase C — Team Discussion
- §5T.5 Phase D — Synthesis Verdict (mandatory checkpoint)
- §5T.6 Phase E — Resolution Loop (max 3 rounds)

After 5T concludes (verdict APPROVED), return to `/plan-project` Step 5.5
(Anti-Pattern Self-Review).

---

## §5T.1: Specialist Definitions

**Full team (`--team`) — 8 specialists:**

| # | Role | Agent definition | Focus |
|---|------|-----------------|-------|
| 1 | **Solution Architect** | `.claude/agents/architect.md` | System boundaries, module decomposition, phase structure |
| 2 | **Business Analyst** | `.claude/agents/analyst.md` | Requirements completeness, EARS acceptance criteria |
| 3 | **UX Designer** | `.claude/agents/ux-designer.md` | User flows, interaction states, accessibility |
| 4 | **Lead Developer** | `.claude/agents/lead-developer.md` | Feasibility, TDD readiness, existing code constraints |
| 5 | **Security Auditor** | `.claude/agents/security-auditor.md` | Threat model, auth flows, data boundaries |
| 6 | **Performance Engineer** | `.claude/agents/performance-engineer.md` | Data volume, query patterns, scaling bottlenecks |
| 7 | **QA Engineer** | `.claude/agents/qa-engineer.md` | Testability, edge cases, test strategy |
| 8 | **DevOps/Infra** | `.claude/agents/devops-engineer.md` | CI/CD, deployment, environment setup, monitoring |

**Lite team (`--team-lite`) — 3 specialists:**
Solution Architect (#1), Business Analyst (#2), Lead Developer (#4).

**Spawning:** Each specialist is spawned as a teammate using the Agent tool with
the matching `subagent_type`. This ensures each agent gets its full definition
(tools, skills, model, structured analysis process) — not just an inline prompt.

| Role | `subagent_type` |
|------|----------------|
| Solution Architect | `architect` |
| Business Analyst | `analyst` |
| UX Designer | `ux-designer` |
| Lead Developer | `lead-developer` |
| Security Auditor | `security-auditor` |
| Performance Engineer | `performance-engineer` |
| QA Engineer | `qa-engineer` |
| DevOps/Infra | `devops-engineer` |

Each specialist receives in their prompt:
- **Dialog output** from Step 1 (the planning conversation)
- **Codebase scan** from Phase D (if applicable)
- **Dependency Sequencing Principles** (from `plan-producer-conventions/SKILL.md` §5)
- **Existing plan context** (if `--update` mode)

## §5T.2: Phase A — Independent Analysis (parallel)

Spawn all specialists in parallel. Each independently:
1. Analyzes the dialog output and proposes tasks from their perspective
2. Identifies risks and concerns specific to their domain
3. Suggests acceptance criteria for tasks in their domain (EARS notation)
4. Proposes dependency ordering with rationale (applying sequencing principles)
5. Identifies affected files/modules from the codebase scan

**Downstream awareness:** Each task in this plan becomes input for the feature
pipeline (`/start` → `/ba flow` → `/plan flow` → ... → `/done`). The BA works
from what specialists write here. Propose tasks with enough detail that the BA
can start immediately: what, why, where (files), constraints, and testable
acceptance criteria. See **Task Detail Requirements** in
`plan-producer-conventions/SKILL.md` §1.

**Output format (per specialist):**
```markdown
## <Role> Analysis

### Proposed Tasks
| Task | Phase | Depends on | Affected files | Acceptance criteria | Autopilot? | Rationale |

### Risks & Concerns
| # | Severity | Description | Mitigation |

### Sequencing Recommendations
<Which tasks should come first and why, applying the data-first principle>

### Council Brief citations
<At least one row each from §1 (canary), §2 (friction), §3 (counter-evidence)
 cited by section name. Required when /plan-project Step 4.5 produced
 _COUNCIL_BRIEF.md; optional when --skip-council was set.>
```

### Specialist response validator (NEW)

After each specialist returns, the orchestrator structurally validates the response BEFORE proceeding to §5T.3 synthesis. This closes Gap 5 from `docs/INPROGRESS_Refactor_plan-project-quality-upgrade/_PLANNING_BRIEF.md` §1 — the cost-efficiency v1 brief documents that 2 of 8 specialists terminated early without producing structured output and the producer had no detection mechanism.

**Required sections** (one validator pass per spawned specialist) — **header matching is FUZZY by design** to avoid false-positive rejection of valid output with slight wording variation:

| Section type | Fuzzy match regex | Notes |
|---|---|---|
| Role analysis header | `^##\s+.*\bAnalysis\b` | `## Solution Architect Analysis`, `## Architect Analysis`, `## <Role> Analysis` all match. Role label must be present but its exact wording is flexible. |
| Proposed tasks section | `^###\s+.*\b(?:Tasks?\|Proposed)\b` | `### Proposed Tasks`, `### Tasks`, `### Task List` all match. Body must contain at least the column header row, even if no rows below (specialist may legitimately propose zero tasks in their domain). |
| Risks section | `^###\s+.*\b(?:Risks?\|Concerns?)\b` | `### Risks & Concerns`, `### Risks`, `### Concerns` all match. Empty body acceptable when no risks identified. |
| Sequencing section | `^###\s+.*\b(?:Sequencing\|Ordering\|Order)\b` | `### Sequencing Recommendations`, `### Ordering`, `### Sequencing` all match. Free-form prose body. |
| Council Brief citations | **Two-part check.** Part A — header: `^###\s+.*\b(?:Council\|Brief\|Citations?)\b`. Part B — body content: within the 20 lines following the matched header, at least one line must reference a Council Brief section by name (regex `§[1-4]\b` or `(?:Section\|§)\s*[1-4]`). The header alone is insufficient evidence that the specialist actually used the brief — empty or "(none)" bodies fail the content check and trigger re-spawn just like a missing header. Required ONLY when `docs/INPROGRESS_Plan_<plan-name>/_COUNCIL_BRIEF.md` exists on disk. Skipped when the file is absent (e.g., `--update` mode with no new tasks proposed — Step 4.5 was orchestrator-skipped). Check the artefact's presence, not any bypass flag. |

The validator pattern set was deliberately loosened from the original literal-match design after the 2026-05-19 risk review flagged that strict-header matching would reject substantively correct specialist output and trigger costly false re-spawns. See **Known caveats** below.

**Validation procedure:**

1. Parse the specialist's response. For each required section type, scan for the first line matching the fuzzy regex. Verify the body satisfies the "Notes" column.

   **On structural success (all required sections present and bodies satisfy their "Notes" column):**
   - Count proposed tasks, risks, and Council Brief section citations in the body.
   - Emit NDJSON event `specialist_returned` with `{role, finding_count, citation_count, council_sections_cited}` where `finding_count` = number of rows in the Risks & Concerns body, `citation_count` = number of `§N` references in the Council Brief citations body, and `council_sections_cited` is a comma-separated list of the cited section numbers (e.g., `1,2,3` if §1, §2, §3 were cited).
   - For each `§N` reference found in the Council Brief citations section, also emit `council_brief_section_cited` with `{specialist, section, citation_excerpt}` where `section` is the integer 1–5 and `citation_excerpt` is the first 100 chars of the line citing it. Closes the R1 mitigation: not just header presence but real per-citation evidence.

2. **On structural failure (no matching header found, or body empty when content required):**
   - Emit NDJSON event `specialist_response_invalid` with `{role, missing_section_types, response_excerpt}`.
   - Re-spawn the specialist **once** using the same `subagent_type`, prepending a `STRUCTURAL_FAILURE_CONTEXT` block to the prompt:
     ```
     ## STRUCTURAL_FAILURE_CONTEXT
     Your previous response was rejected by the §5T.2 structural validator
     because the following required section types were missing:
     - <list of missing section types>

     Re-attempt with all required sections present. Header wording is
     flexible (e.g., "### Proposed Tasks", "### Tasks", or "### Task List"
     all satisfy the proposed-tasks requirement) — what matters is that
     each section TYPE is identifiable. If your domain has nothing to
     propose in a section, include the section header followed by an
     empty table with column headers only.
     ```
   - Emit NDJSON event `specialist_respawn` with `{role, reason}`.

3. **On second-attempt failure (still structurally invalid):** behaviour branches on `PLAN_PROJECT_AUTOFALLBACK_SPECIALIST` env var (see `commands/plan-project.md` Step 0.1 escape-hatch list).

   **Default path (env var UNSET) — operator escalation:**
   - Emit NDJSON event `specialist_escalation_to_operator` with `{role, missing_section_types, second_response_excerpt}`.
   - Print to operator console:
     ```
     ⚠ SPECIALIST FAILED STRUCTURAL VALIDATION TWICE: <role>
       Missing: <list of section types>
       Re-spawn cost so far: 2x specialist invocation

       Choose how to proceed:
       [r] re-spawn once more with explicit template (third attempt)
       [a] accept without this role's input — plan continues with N-1
           specialists, role's coverage recorded in quality_warnings[]
       [x] abort planning — revisit specialist prompt template / agent
           definition outside the planning run

     Choice [r/a/x]?
     ```
   - On `r`: emit `specialist_respawn` (round 3) and retry. If round 3 also fails: present the operator with `[a/x]` (re-spawn is no longer offered — 3 strikes is the empirical cap from CRITIC / Self-Refine 2026 diminishing-returns evidence).
   - On `a`: emit `specialist_accepted_without_role` with `{role}`. Record in plan `quality_warnings[]`:
     ```yaml
     - pattern_id: specialist-coverage-gap
       task_or_phase_id: 5T.2
       description: "<role> specialist failed structural validation. Plan synthesis proceeded with N-1 specialists; that domain is uncovered for this planning run. Re-evaluate during /retro."
       retried_count: 2
     ```
   - On `x`: emit `planning_aborted_specialist_failure` and exit Step 5T.2 with operator-supplied reason.

   **Auto-fallback path (`PLAN_PROJECT_AUTOFALLBACK_SPECIALIST=1`):**
   - Emit NDJSON event `specialist_locally_produced_fallback` with `{role, missing_section_types}`.
   - Print to console (non-blocking):
     ```
     ⚠ QUALITY GATE BYPASSED: Specialist <role> failed twice; auto-fallback enabled.
       env: PLAN_PROJECT_AUTOFALLBACK_SPECIALIST=1
       Substituting orchestrator-produced lens for <role>'s domain.
       Consequence: specialist domain expertise is replaced by general
       reasoning. quality_warnings[] captures the substitution.
     ```
   - Orchestrator produces a **locally-produced lens** using dialog output + codebase scan + Council Brief. Mirrors the cost-efficiency v1 `_PERF_DEVOPS_LOCAL_LENSES.md` workaround. Record in `quality_warnings[]`:
     ```yaml
     - pattern_id: specialist-locally-produced
       task_or_phase_id: 5T.2
       description: "<role> specialist failed structural validation twice; auto-fallback substituted a locally-produced lens via PLAN_PROJECT_AUTOFALLBACK_SPECIALIST=1. Re-evaluate that role's coverage during /retro."
       retried_count: 2
     ```

**Why operator-escalation is the default, not auto-fallback:** silently substituting orchestrator output for a specialist's domain expertise looks like success in the audit trail but hides a quality regression. The operator deserves to see the failure and choose. Auto-fallback exists for headless autopilot where no operator is present to choose — explicit opt-in via env var.

**Audit trail.** The full event vocabulary is observable in `autopilot-stream.ndjson` and surfaces in the Council Brief's §2 Friction Table on subsequent plans:

- `specialist_response_invalid` (first failure)
- `specialist_respawn` (re-spawn attempted)
- `specialist_escalation_to_operator` (default-path strike-two)
- `specialist_accepted_without_role` (operator chose `a`)
- `planning_aborted_specialist_failure` (operator chose `x`)
- `specialist_locally_produced_fallback` (env-var auto-fallback)

### Known caveats — validator limits

The structural validator is best-effort, not a correctness oracle. Three caveats the operator should keep in mind:

1. **False rejection risk (mitigated, not eliminated).** Fuzzy regex matching catches most legitimate wording variations, but a specialist that responds with deeply unconventional structure (e.g., wraps everything in `<analysis>` XML tags, or uses HTML-comment markers as section delimiters) will still fail. Cost of a false rejection: one extra specialist invocation (~$3-5). The fuzzy regex band was tuned against the cost-efficiency v1 specialist outputs to minimise this; further loosening risks false acceptance.

2. **Content-correctness is NOT validated.** The validator checks structure (sections exist, bodies non-empty where required), not content quality. A specialist that emits valid section structure with nonsense content (token-budget-exhausted hallucination) will PASS the validator but contribute garbage to §5T.3 synthesis. The Council Brief citation requirement is a partial safeguard — a specialist that cites §1/§2/§3 by section name had to read the Brief — but a determined hallucinator can produce plausible-looking citations.

3. **Auto-fallback hides quality regression.** When `PLAN_PROJECT_AUTOFALLBACK_SPECIALIST=1` is set, the substitution is logged but not blocking. An operator who never reads `quality_warnings[]` after the planning run may not notice that one specialist's domain expertise was silently replaced by general orchestrator reasoning. Use the env var only for genuinely headless runs.

These caveats are also surfaced in the operator-escalation console prompt (point 3 of the validation procedure) so the choice is informed.

## §5T.3: Phase B — Synthesis

The Solution Architect (or orchestrator in lite mode) synthesizes all
specialist input into a draft `execution-plan.yaml` (schema 2.0):

1. Merge proposed tasks, deduplicating and resolving conflicts
2. Organize into `phases[]` respecting all dependency recommendations
3. Include acceptance criteria from each specialist (additive — a task may
   have criteria from BA, Security, Performance, and QA) in `task.acceptance[]`
4. Apply the Dependency Sequencing Principles explicitly (rationale goes
   into each phase's `description` field). See
   `plan-producer-conventions/SKILL.md` §5.
5. Ensure every task meets the **Task Detail Requirements** from
   `plan-producer-conventions/SKILL.md` §1 — in 2.0 these map to structured
   fields: `task.what`, `task.why`, `task.where.{modify,create,delete}`,
   `task.depends`, `task.acceptance`, `task.constraints`. Enrich any thin
   proposal during synthesis using the codebase scan and dialog context.
6. Write draft directly to `docs/INPROGRESS_Plan_<plan-name>/execution-plan.yaml`
   with `schema_version: 2.0.0`. No separate EXECUTION_PLAN.md is produced.

## §5T.4: Phase C — Team Discussion

Share the draft with all specialists (re-spawn with their `subagent_type` —
see table in 5T.1). Each reviews and challenges.

**Anti-sycophancy protocol (same as team-review):**
- Banned phrases: "You're absolutely right!", "Great point!", etc.
- Every response must include technical reasoning
- Agreement requires stronger justification than disagreement

**Finding format (structured — mandatory):**
```
| # | Severity | Category | Section | Description | Fix suggestion |
```
Severities: `CRITICAL`, `WARNING`, `SUGGESTION`

**Discussion focuses on:**
- Missing tasks from any specialist's domain
- Incorrect dependency ordering (especially sequencing principle violations)
- Over-engineering or premature complexity
- Acceptance criteria gaps
- Autopilot eligibility and pipeline weight — review each task against the criteria
  in `plan-producer-conventions/SKILL.md` §4. Eligible tasks get `autopilot: true` plus
  `pipeline: full` (multi-file, architectural) or `pipeline: light` (single-module,
  known patterns like migrations, config changes, dependency bumps)

**Tie-breaking:** Orchestrator resolves after 2 rounds of back-and-forth
per finding. Document reasoning.

## §5T.5: Phase D — Synthesis Verdict

**MANDATORY checkpoint.** After discussion concludes, the orchestrator (you)
reviews all findings and makes an explicit verdict. Print this state block:

```
## Team Design Synthesis

### Surviving findings (after discussion)
| # | Severity | Category | Description | Challenged? | Resolution |
|---|----------|----------|-------------|-------------|------------|

### Verdict: APPROVED | NEEDS RESOLUTION

CRITICAL: <count>  |  WARNING: <count>  |  SUGGESTION: <count (deferred)>
```

**Emit per-finding events.** For each row in the "Surviving findings" table above, emit one `finding_recorded` event so the stream captures the actual content (not just aggregates):
```bash
bash ~/.claude/tools/lib/plan-event-writer.sh emit <plan-name> finding_recorded \
  source_step=5T.5 \
  severity=<CRITICAL|WARNING|SUGGESTION> \
  category=<category> \
  source_specialist=<role> \
  title="<first 80 chars of description>" \
  resolution=<resolved|deferred|pending>
```
This is the level-1 content that `/retro` cross-plan analysis needs — without it the stream only shows aggregate counts, which is too coarse for pattern detection. Closes the gap surfaced by the pipeline-smoke-test 2026-05-19 run where the stream had `critical:0, warning:3, suggestion:2` but no per-finding content.

- **APPROVED** — zero CRITICAL, zero WARNING. All findings were resolved
  through discussion or downgraded to SUGGESTION. Return to `/plan-project`
  Step 5.5.
- **NEEDS RESOLUTION** — one or more CRITICAL or WARNING findings survived
  discussion. Enter §5T.6 (Resolution Loop). Do NOT return to Step 5.5.

## §5T.6: Phase E — Resolution Loop

**Entry condition:** §5T.5 verdict is NEEDS RESOLUTION.

**Loop invariants:**
- `max_rounds = 3`
- `round = 1` (the discussion was Round 0)
- `fixed_issues_log = []`

**Loop procedure:**

1. **Resolution brief.** The orchestrator compiles CRITICAL + WARNING findings
   from the synthesis (§5T.5) into a resolution brief for the Fixer:
   ```markdown
   ## Resolution Brief — Team Design, Round <N>

   ### Issues to resolve (CRITICAL + WARNING only)
   | # | Severity | Category | Section | Fix suggestion | Original reviewer |
   |---|----------|----------|---------|----------------|-------------------|

   ### Previously fixed issues (DO NOT revert)
   | # | Fixed in round | Description |
   |---|----------------|-------------|

   ### Scope constraint
   You may ONLY edit: docs/INPROGRESS_Plan_<plan-name>/execution-plan.yaml
   Do not touch source code or any file outside the plan directory.

   ### Out of scope
   - SUGGESTION-severity findings
   - Any changes beyond the listed issues
   ```

2. **Fixer execution.** Spawn the Fixer (`subagent_type: fixer`) with the
   filled resolution brief. The Fixer applies surgical edits and returns a
   fix report.

3. **Update fixed-issues log.** Add all FIXED/PARTIALLY_FIXED items with
   round number. For each FIXED item, emit `finding_recorded` with
   `resolution=resolved_round_<N>` so the stream captures which round
   resolved which finding (level-1 content for /retro analysis).

4. **Re-review (focused).** Re-spawn ALL specialists that had CRITICAL or
   WARNING findings in the synthesis (not just one). Each specialist verifies
   their own findings were correctly resolved. Use the same `subagent_type`
   for each. Narrowed scope: review ONLY sections the Fixer modified.
   Verify fixes resolve original findings. Check for regressions.

5. **Re-synthesize.** Print the synthesis state block again (same format as
   §5T.5). Make a new verdict: APPROVED or NEEDS RESOLUTION.

6. **Convergence detection.** If the same findings persist from the previous
   round, the loop has stalled. Exit with remaining issues for user review.

7. **Loop termination summary:**
   ```
   Team Design, Round <N>/<max>: <APPROVED | NEEDS RESOLUTION>
     Fixed: <count>  |  Remaining: <count>  |  Regressions: <count>
   ```

**Iteration cap: 3 rounds.** If issues remain after 3 rounds, present remaining
findings to user with what was tried and why it couldn't be resolved.

**After resolution (or after APPROVED in §5T.5):** Return to `/plan-project`
Step 5.5 (Anti-Pattern Self-Review), then Step 6 (Adversarial Review) for a
final independent check. The team designed the plan; a separate critic
reviews it.
