---
description: Project planner — interactive planning dialog that produces setup plan, execution plan, and validated YAML. Supports update mode (--update) and team-based planning (--team/--team-lite).
argument-hint: <plan-name> [--template greenfield|feature|refactor] [--update] [--team|--team-lite]
---

# /plan-project: $ARGUMENTS

Project-level planning skill that sits ABOVE the feature-level flow pipeline.
Through iterative dialog, produces SETUP_PLAN.md, EXECUTION_PLAN.md, and a
schema-valid execution-plan.yaml.

**Modes:**
- **Create** (default) — new plan from scratch
- **Update** (`--update`) — modify an existing plan while preserving completed work
- **Team** (`--team` / `--team-lite`) — multi-specialist collaborative planning

---

## Step 0: Mode Detection

### 0.1: Parse Flags

Extract from `$ARGUMENTS`:
- `--update` → update mode
- `--team` → full team (8 specialists)
- `--team-lite` → lite team (3 specialists: Solution Architect + BA + Lead Dev)
- `--template <type>` → template selection
- Remaining positional args → plan name

### 0.2: Detect Existing Plan

```
Glob pattern: docs/INPROGRESS_Plan_*/execution-plan.yaml
```

| Flag | Plan exists | Mode |
|------|-------------|------|
| `--update` | Yes | **Update mode** — load existing plan |
| `--update` | No | **Error** — "No existing plan found. Run `/plan-project <name>` to create one." STOP. |
| (none) | Yes | **Warning** — "Plan already exists. Use `--update` to modify it, or confirm overwrite." |
| (none) | No | **Create mode** — new plan |

### 0.3: Team Feature Flag Guard (--team/--team-lite only)

```bash
echo $CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
```

If empty or unset:
- Print: "Agent teams require the `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` feature flag."
- Print: "Enable it in your Claude Code settings, then retry."
- Suggest: "Run without `--team` for single-perspective planning."
- **EXIT — do not proceed.**

### 0.4: Team Token Cost Warning (--team/--team-lite only)

> **Token cost warning:** Team planning spawns multiple specialist agents for
> collaborative plan design. `--team` uses 8 specialists (~15-25x tokens vs solo),
> `--team-lite` uses 3 specialists (~8-12x tokens vs solo).
>
> Proceed? `[proceed / cancel]`

On `cancel`: EXIT.

## Step 0.5: Scope Gate (R1a)

**Skip in update mode** — scope was already assessed during creation.

Assess if this is a single feature or project-level work:
- If the described work maps to a single feature (one `/start` → `/done` cycle
  with no phases or dependencies), suggest:
  "This looks like a single feature. Use `/start <feature>` instead of
  `/plan-project`. Proceed with project planning anyway?"
- The user can override and proceed with full planning regardless.

---

# CREATE MODE

## Step 1: Planning Dialog (R1)

Conduct a structured elicitation dialog:

**Phase A — Scope assessment (1-2 questions):**
1. Is this greenfield (new project) or work on an existing project?
2. Rough size: how many features/components?

**Phase B — Vision capture (2-3 questions):**
1. What does the finished product/feature do? (one-paragraph answer expected)
2. Who are the primary users and what are their key use cases?
3. What does success look like? (measurable outcomes)

**Phase C — Technical constraints (1-2 questions):**
1. Tech stack preferences or mandates?
2. For existing projects: what infrastructure, modules, or constraints apply?

**Phase D — Codebase scan (existing projects only, automatic):**
Scan the existing codebase using parallel Explore agents:
- Read `package.json`/`requirements.txt`/`go.mod` for dependencies
- Scan `src/` (or equivalent) for module structure and key entry points
- Check for existing test infrastructure (`tests/`, `__tests__/`, test configs)
- Identify CI/CD configuration (`.github/workflows/`, `Makefile`, etc.)

**Completeness gate:** After phases A-C (and D if applicable), self-evaluate:
- [ ] Vision is clear (can summarize in one sentence)
- [ ] Users and use cases identified
- [ ] Tech stack known or defaulted
- [ ] Existing constraints captured (existing projects)
- [ ] Scope is estimable (can enumerate phases)

If any item is missing, ask one targeted follow-up question per gap.
If all items pass, proceed to plan generation.

**Turn limit:** Maximum 8 dialog turns. If completeness cannot be reached
in 8 turns, generate plans with available context and mark gaps with
`[NEEDS CLARIFICATION]` markers. Maximum 3 such markers — if more gaps
remain, the scope is insufficient and say so.

## Step 1.5: Project-Specific Skills Assessment

Based on the dialog and codebase scan, identify domain skills this project needs
beyond the shared pipeline skills (which are already installed globally via `/rollout`).

**Evaluate these categories:**

| Category | When to suggest | Example |
|----------|----------------|---------|
| Design system | Project has a UI with custom theme/palette | `dashboard-design`, `mui-design-system` |
| Domain knowledge | Project operates in a specialized domain | `eu-law-domain`, `workforce-analytics` |
| API conventions | Project has specific API patterns/standards | `rest-api-conventions`, `graphql-patterns` |
| Data model | Project has complex domain entities | `data-model-reference` |

**For each suggested skill, specify:**
- Skill directory name (kebab-case)
- One-sentence purpose
- Key content the SKILL.md should contain
- Whether it should reference existing project files (e.g., theme.ts, schema files)

**Output:** Add a "Project-Specific Skills" section to SETUP_PLAN.md listing
skills to create in `.claude/skills/` for this project. Include a stub SKILL.md
for each with the key sections identified.

If no domain-specific skills are needed, skip this step.

## Step 2: Template Selection (R8)

Check `$ARGUMENTS` for `--template` flag:
- `greenfield` → `~/.claude/templates/template-greenfield.yaml`
- `feature` → `~/.claude/templates/template-feature.yaml`
- `refactor` → `~/.claude/templates/template-refactor.yaml`

If no flag: infer from dialog (new project → greenfield, extending → feature,
restructuring → refactor). If ambiguous, ask the user.

## Step 3: Idempotency Check (R12)

Check if `docs/INPROGRESS_Plan_<plan-name>/` already exists:
- If yes: warn the user, show existing plan name and phase count
- Ask for confirmation before overwriting
- If user declines: STOP

The plan-name defaults to the first positional argument in `$ARGUMENTS`
(after stripping flags), falling back to a slug derived from the vision statement.

## Step 4: Generate SETUP_PLAN.md (R2)

Write to `docs/INPROGRESS_Plan_<plan-name>/SETUP_PLAN.md`:
- Infrastructure and environment prerequisites
- Dependencies to install and configure
- Services to provision (databases, APIs, CI/CD)
- Development environment setup steps
- Verification criteria (how to confirm setup is complete)

For existing projects: identify what additional infrastructure is needed
beyond what already exists.

## Step 5: Generate EXECUTION_PLAN.md (R3)

**If `--team` or `--team-lite`:** Skip to Step 5T (Team Plan Design).

Write to `docs/INPROGRESS_Plan_<plan-name>/EXECUTION_PLAN.md`:
- Phases of work with clear boundaries
- Tasks within each phase (see **Task Detail Requirements** below)
- Dependencies between tasks (explicit ordering)
- Acceptance criteria per task in EARS notation:
  - Event-driven: `When [trigger], the system shall [response]`
  - State-driven: `While [state], when [event], the system shall [response]`
  - Unwanted: `If [error condition], then the system shall [recovery behavior]`
- Flow command prompts per task: every task uses `prompt: "/start <task-id>"`
  so each task enters the full SDLC pipeline (worktree → `/ba` → `/plan` →
  `/implement` → `/static-analysis` → `/qa` → `/done`)
- A "Task Pipeline" section explaining that each task is a feature going
  through the full SDLC cycle, not just implementation
- Quality gates between phases

**Task Detail Requirements — downstream-ready for the feature pipeline:**

Each task in this plan becomes the input for `/start <task-id>` → `/ba flow` →
full SDLC pipeline. The BA, architect, and implementer will work from what you
write here. Include enough detail so the BA can start immediately without
re-discovering context:

Per task, include:
1. **What** — one-paragraph description of the feature/change
2. **Why** — business or technical motivation (what problem does it solve?)
3. **Where** — which modules, files, or components are affected (use paths
   from the codebase scan). For existing projects, reference actual files.
4. **Dependencies** — what must exist before this task starts (completed
   tasks, APIs, data models, infrastructure)
5. **Acceptance criteria** — EARS-formatted, testable, specific. These
   become the BA's starting point and the QA's verification checklist.
6. **Key constraints** — architecture rules, performance requirements,
   security considerations, or design system compliance that apply

**Anti-pattern:** A task that says "Implement analytics reconciliation" with
one vague criterion. The BA would have to re-do the entire analysis.

**Good example:**
```
### Task: absence-aware-capacity
Modify `src/analytics/capacity.py` to use AbsenceEntry records for bench
detection instead of the current NormHours heuristic. This fixes false
positives where employees on leave are flagged as bench candidates.

**Affected files:** `src/analytics/capacity.py` (find_bench_candidates,
get_bench_alerts), `src/db/queries/absence.py` (new query needed)

**Depends on:** data-model (Phase 1) — AbsenceEntry table must exist

**Acceptance criteria:**
- When calculating bench candidates, the system shall exclude employees
  with active AbsenceEntry records for the evaluation period
- When an employee has partial absence (< 100%), the system shall
  pro-rate their available capacity
- If AbsenceEntry data is missing for an employee, the system shall
  fall back to the current NormHours heuristic and log a warning

**Constraints:** `src/analytics/` is deterministic — no LLM calls.
`src/db/queries/` is read-only DAL — new query, no calculations.
```
- For phase gates with 3+ tasks: add an `advisory` field (NOT in the `checklist`
  array) with: `"Consider using /team-review for this gate evaluation (multi-perspective review, requires agent teams flag)."`

**MANDATORY: Apply Dependency Sequencing Principles (see § Dependency Sequencing
Principles below).** Before finalizing phase/task ordering, explicitly evaluate
the sequencing principles and document the rationale in EXECUTION_PLAN.md.

### Autopilot Eligibility Assessment

For each task, the planning team assesses whether it can run the full pipeline
autonomously (no human checkpoints). Set `autopilot: true` in the YAML when
ALL of these conditions are met:

**Eligible (autopilot: true):**
- Pure backend — no UI components, no user-facing changes
- No manual testing needed — all verification is automated tests
- Acceptance criteria are unambiguous — EARS-formatted, specific, testable
- No novel architecture decisions — follows established patterns
- No security-sensitive changes — no auth flows, no PII handling changes
- Dependencies are clear — no unresolved questions about interfaces

**Smoke tests vs implementation tests:** A task is autopilot-eligible if all
*implementation* work is verifiable by automated tests (`pytest`, `run_eval.sh`,
etc.). Manual smoke tests ("verify in dashboard", "check traces in Langfuse")
belong on the **phase gate checklist**, not on individual task ACs. Do not block
autopilot because a task needs a visual smoke test — move that AC to the gate.

**Not eligible (autopilot: false, the default):**
- Has UI components (needs `/ux` and `/manualtest`)
- Requires human judgement at checkpoints (ambiguous requirements)
- Security-sensitive (auth, PII, secrets — human must verify approach)
- Novel architecture (new patterns, integration design decisions)
- External API integrations with unclear specs

The team discusses autopilot eligibility during Step 5T.4 (discussion phase).
Any specialist can veto autopilot for a task with technical reasoning.

When `autopilot: true`, the team also assigns a **pipeline weight**:

**`pipeline: full`** (default for autopilot) — BA → Plan → Team Review → Implement → Static Analysis → Team QA
- Multi-file changes across layers
- Tasks that touch architecture or data models
- Any task where multiple specialists should verify

**`pipeline: light`** — BA → Plan → Review → Implement → Static Analysis → QA
- Single-module changes with known patterns (migrations, config, dependency bumps)
- Tasks where a solo reviewer catches the same issues a team would
- Small scope — one file, one concern

In the YAML, autopilot tasks get: `autopilot: true` and `pipeline: full` or `pipeline: light`.
The `/start` command shows the user both options — autopilot (terminal script) or normal flow
(Claude Code chat with checkpoints).

## Step 5T: Team Plan Design (--team/--team-lite only)

Replaces Step 5 with multi-specialist collaborative plan design.

### 5T.1: Specialist Definitions

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
- **Dependency Sequencing Principles** (from this command's § below)
- **Existing plan context** (if `--update` mode)

### 5T.2: Phase A — Independent Analysis (parallel)

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
acceptance criteria. See **Task Detail Requirements** in Step 5.

**Output format (per specialist):**
```markdown
## <Role> Analysis

### Proposed Tasks
| Task | Phase | Depends on | Affected files | Acceptance criteria | Autopilot? | Rationale |

### Risks & Concerns
| # | Severity | Description | Mitigation |

### Sequencing Recommendations
<Which tasks should come first and why, applying the data-first principle>
```

### 5T.3: Phase B — Synthesis

The Solution Architect (or orchestrator in lite mode) synthesizes all
specialist input into a draft EXECUTION_PLAN.md:

1. Merge proposed tasks, deduplicating and resolving conflicts
2. Organize into phases respecting all dependency recommendations
3. Include acceptance criteria from each specialist (additive — a task may
   have criteria from BA, Security, Performance, and QA)
4. Apply the Dependency Sequencing Principles explicitly
5. Ensure every task meets the **Task Detail Requirements** from Step 5
   (what, why, where, dependencies, EARS criteria, constraints). If any
   specialist proposed a task without sufficient detail, enrich it during
   synthesis using the codebase scan and dialog context
5. Write draft to `docs/INPROGRESS_Plan_<plan-name>/EXECUTION_PLAN.md`

### 5T.4: Phase C — Team Discussion

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
  in § Autopilot Eligibility Assessment. Eligible tasks get `autopilot: true` plus
  `pipeline: full` (multi-file, architectural) or `pipeline: light` (single-module,
  known patterns like migrations, config changes, dependency bumps)

**Tie-breaking:** Orchestrator resolves after 2 rounds of back-and-forth
per finding. Document reasoning.

### 5T.5: Phase D — Synthesis

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

- **APPROVED** — zero CRITICAL, zero WARNING. All findings were resolved
  through discussion or downgraded to SUGGESTION. Proceed to Step 6.
- **NEEDS RESOLUTION** — one or more CRITICAL or WARNING findings survived
  discussion. Enter Step 5T.6 (Resolution Loop). Do NOT proceed to Step 6.

### 5T.6: Phase E — Resolution Loop

**Entry condition:** Step 5T.5 verdict is NEEDS RESOLUTION.

**Loop invariants:**
- `max_rounds = 3`
- `round = 1` (the discussion was Round 0)
- `fixed_issues_log = []`

**Loop procedure:**

1. **Resolution brief.** The orchestrator compiles CRITICAL + WARNING findings
   from the synthesis (Step 5T.5) into a resolution brief for the Fixer:
   ```markdown
   ## Resolution Brief — Team Design, Round <N>

   ### Issues to resolve (CRITICAL + WARNING only)
   | # | Severity | Category | Section | Fix suggestion | Original reviewer |
   |---|----------|----------|---------|----------------|-------------------|

   ### Previously fixed issues (DO NOT revert)
   | # | Fixed in round | Description |
   |---|----------------|-------------|

   ### Scope constraint
   You may ONLY edit: docs/INPROGRESS_Plan_<plan-name>/EXECUTION_PLAN.md
   Do not touch source code, YAML, or SETUP_PLAN.md.

   ### Out of scope
   - SUGGESTION-severity findings
   - Any changes beyond the listed issues
   ```

2. **Fixer execution.** Spawn the Fixer (`subagent_type: fixer`) with the
   filled resolution brief. The Fixer applies surgical edits and returns a
   fix report.

3. **Update fixed-issues log.** Add all FIXED/PARTIALLY_FIXED items with
   round number.

4. **Re-review (focused).** Re-spawn ALL specialists that had CRITICAL or
   WARNING findings in the synthesis (not just one). Each specialist verifies
   their own findings were correctly resolved. Use the same `subagent_type`
   for each. Narrowed scope: review ONLY sections the Fixer modified.
   Verify fixes resolve original findings. Check for regressions.

5. **Re-synthesize.** Print the synthesis state block again (same format as
   Step 5T.5). Make a new verdict: APPROVED or NEEDS RESOLUTION.

6. **Convergence detection.** If the same findings persist from the previous
   round, the loop has stalled. Exit with remaining issues for user review.

7. **Loop termination summary:**
   ```
   Team Design, Round <N>/<max>: <APPROVED | NEEDS RESOLUTION>
     Fixed: <count>  |  Remaining: <count>  |  Regressions: <count>
   ```

**Iteration cap: 3 rounds.** If issues remain after 3 rounds, present remaining
findings to user with what was tried and why it couldn't be resolved.

**After resolution (or after APPROVED in 5T.5):** Proceed to Step 6
(Adversarial Review) for a final independent check. The team designed the
plan; a separate critic reviews it.

## Step 6: Adversarial Review Loop (R4)

Iteratively review and fix plans until the critic finds nothing to fix,
or the iteration cap is reached.

**Critic evaluation criteria (mandatory checklist):**

| # | Criterion | What to check |
|---|-----------|---------------|
| C1 | Testability | Every task has EARS-formatted acceptance criteria that map to a concrete test |
| C2 | Dependency validity | Dependencies form a valid DAG; no orphan tasks with unmet deps |
| C3 | Setup-execution consistency | Every tech/service in EXECUTION_PLAN.md has a prerequisite in SETUP_PLAN.md |
| C4 | Completeness | No `[NEEDS CLARIFICATION]` markers remain unresolved |
| C5 | Feasibility | Tasks are achievable with the stated tech stack and constraints |
| C6 | Risk coverage | For existing projects: regression risks and migration hazards identified |
| C7 | Sequencing soundness | Dependency Sequencing Principles applied: data-model tasks early, feedback-loop tasks before consumers, no implicit ordering assumptions |
| C8 | Downstream readiness | Every task has: what (description), why (motivation), where (affected files/modules), EARS acceptance criteria, and key constraints. A BA reading this task can start `/ba flow` without re-discovering context |

**Structured output format (per criterion):**
```
C1 Testability: PASS | FAIL
   Evidence: [specific task/criteria that passed or failed]
   Suggestion: [actionable fix if FAIL]
```

**Architecture:** Evaluator-Optimizer pattern — same as team-review/team-qa.
The critic evaluates; the Fixer fixes. No agent marks its own work.

**Loop invariants:**
- `max_rounds = 3`
- `round = 1`
- `fixed_issues_log` carries over from Step 5T.6 (if team mode)

**Loop procedure:**

1. **Critic round.** Spawn a critic agent using the Agent tool with
   `subagent_type: general-purpose`. Role constraint: **"evaluate only,
   do not rewrite."** The critic evaluates SETUP_PLAN.md and
   EXECUTION_PLAN.md against all seven criteria and returns structured
   findings. For existing projects: include the codebase scan results
   from Phase D.

   **Structured output format (per criterion):**
   ```
   C1 Testability: PASS | FAIL
      Evidence: [specific task/criteria that passed or failed]
      Suggestion: [actionable fix if FAIL]
   ```

2. **Check verdict.** If all C1–C8 pass → exit loop, proceed to Step 7.

3. **Resolution brief.** Compile FAIL findings into a resolution brief:
   ```markdown
   ## Resolution Brief — Adversarial Review, Round <N>

   ### Issues to resolve
   | # | Criterion | Evidence | Fix suggestion |
   |---|-----------|----------|----------------|

   ### Previously fixed issues (DO NOT revert)
   | # | Fixed in round | Description |
   |---|----------------|-------------|

   ### Scope constraint
   You may ONLY edit files in: docs/INPROGRESS_Plan_<plan-name>/
   Do not touch source code or any file outside the plan docs folder.

   ### Out of scope
   - Any changes beyond the listed issues
   ```

4. **Fixer execution.** Spawn the `fixer` subagent (`subagent_type: fixer`)
   with the filled resolution brief. The Fixer applies surgical edits to
   SETUP_PLAN.md and/or EXECUTION_PLAN.md. Do not modify the critic's
   evaluation — only the plans.

5. **Update fixed-issues log.** Add all FIXED items with round number.

6. **Convergence detection.** If the same criteria FAIL with the same evidence
   as the previous round, the loop has stalled. Exit with remaining FAILs
   and note "convergence failure."

7. **Log the round.** Display progress summary:
   ```
   Review round <N>/<max>: <criteria results>
     Fixed: <count>  |  Remaining: <count>
   ```

8. **Repeat** from step 1 with the amended plans.

**Iteration cap: 3 rounds.** If FAILs persist after 3 critic rounds,
STOP the loop and present the remaining FAILs to the user with:
- What was tried in each round
- Why the fix didn't resolve the criterion
- Whether the issue requires user input (scope decision, missing info)
  or is a genuine plan deficiency

The user can then accept despite remaining FAILs (override) or provide
the missing input to unblock the fix.

---

# UPDATE MODE

Entered when `--update` flag is set and an existing plan is found.

## Step 1U: Update Dialog

**Phase A — Load current state (automatic):**
1. Read execution-plan.yaml — parse all phases, tasks, statuses
2. Read EXECUTION_PLAN.md — the narrative plan
3. Present a status summary:
   ```
   Current plan: <name>
   Phases: <count> | Tasks: <done>/<total> done | WIP: <count>

   Phase 1: <name> — <done>/<total> tasks done
     ✓ task-a (done)
     ◉ task-b (wip)
     ○ task-c (pending)
   Phase 2: <name> — 0/<total> tasks done
     ...
   ```

**Phase A.5 — Absorbed task detection (automatic):**
For each `pending` task in future phases, check whether its acceptance criteria
have already been satisfied by completed (`done`) tasks. If ALL criteria are met:
flag the task as a candidate for removal in the status summary:
```
  ⚠ task-x (pending — criteria absorbed by task-a, task-b)
```
Present these candidates to the user during the change dialog.

**Phase B — Change elicitation (2-4 questions):**
1. What needs to change? (new tasks, restructured phases, scope expansion,
   reprioritization, lessons learned)
2. Which parts of the plan are affected? (specific phases/tasks)
3. Are there any completed tasks whose scope changed during implementation?
   (capture `scope_change` and `delivered_beyond_plan` for those tasks)
4. Any new constraints or dependencies discovered?
5. Review absorbed task candidates (from Phase A.5) — confirm removal or keep

**Turn limit:** Maximum 5 dialog turns for update elicitation.

## Step 2U: Change Classification

Classify each proposed change:

| Type | Description | YAML impact |
|------|-------------|-------------|
| **Add task** | New task in existing or new phase | New task entry, status: pending |
| **Add phase** | New phase with tasks | New phase entry with tasks |
| **Modify task** | Change acceptance criteria, dependencies, or description | Edit existing task fields |
| **Reorder** | Move task between phases or change dependencies | Edit depends + possibly phase membership |
| **Remove task** | Task no longer needed | Set status: skipped with scope_change note |
| **Absorb task** | Pending task whose criteria were met by other work | Remove from plan with changelog entry (see below) |
| **Split task** | One task becomes multiple | Original → skipped, new tasks added |
| **Restructure** | Major phase reorganization | Multiple edits, preserve done statuses |

**Absorbed tasks — removal rule:**
A `pending` task whose acceptance criteria have ALL been satisfied by work done
in other tasks was never explicitly started, so it is not historical record — it
is dead weight. During update, identify these and **remove them entirely** from
both EXECUTION_PLAN.md and the YAML. Add a changelog entry:
```yaml
- date: "YYYY-MM-DD"
  type: removed
  description: "Removed <task-id>: all acceptance criteria absorbed by <absorbing-task-ids>"
  affected_tasks: [<task-id>]
  affected_phases: [<phase-id>]
```
Do NOT mark absorbed tasks as `done` — they were never started through the
pipeline. Marking them `done` inflates completion metrics and confuses the
audit trail. Only tasks that went through `/start` → pipeline → `/done` earn
`done` status.

**Immutability rules for updates:**
- **NEVER change status of `done` tasks** — completed work is permanent.
  `done` means the task went through the SDLC pipeline (`/start` → `/done`).
- **NEVER delete `done` tasks** — they are historical record
- **NEVER modify acceptance criteria of `done` tasks** — use `delivered_beyond_plan`
  and `scope_change` fields instead
- **DO remove absorbed `pending` tasks** — if a pending task's criteria are fully
  met by other completed work, remove it (not mark done). See "Absorbed tasks" above.
- `wip` tasks: may modify acceptance criteria (warn user first)
- `pending` tasks: may modify or remove freely

## Step 3U: Apply Changes to EXECUTION_PLAN.md

For each classified change:
1. Use the Edit tool to surgically modify EXECUTION_PLAN.md
2. Preserve all existing content for unchanged sections
3. Mark changed sections with `<!-- updated YYYY-MM-DD: <reason> -->`
4. Apply Dependency Sequencing Principles to any new or reordered tasks

## Step 4U: Apply Changes to YAML

For each classified change, use the Edit tool on execution-plan.yaml:
1. Add/modify task entries preserving all existing fields
2. Preserve `status`, `last_updated`, `delivered_beyond_plan`, `scope_change`,
   `remaining_gaps` on all tasks — these are operational state
3. Add changelog entry (see Step 7 YAML changelog format)
4. Update `updated` field to today's date

**Verification:** After all edits, re-read the YAML and confirm:
- [ ] All `done` task statuses preserved
- [ ] All `wip` task statuses preserved
- [ ] New tasks have status: `pending`
- [ ] Absorbed tasks removed (not marked done) with changelog entries
- [ ] Changelog entry added
- [ ] No orphan dependencies (every `depends` reference points to a real task)

## Step 5U: Update Review

### Solo update review (no --team flag)

Run a focused adversarial review on changed sections only:
- Same criteria as Step 6 (C1-C8) but scoped to modified/added content
- Maximum 2 rounds (lighter since most of the plan is already validated)
- Skip criteria that don't apply to the change type

### Team update review (--update --team or --update --team-lite)

When both `--update` and `--team`/`--team-lite` are set, replace the solo
review with a team-based review of the proposed changes:

1. **Spawn specialists** using the Agent tool with the matching `subagent_type`
   (same roster and mapping table as Step 5T.1 — full or lite).
2. Each specialist receives:
   - The current plan state (from Step 1U Phase A)
   - The classified changes (from Step 2U)
   - The modified EXECUTION_PLAN.md (from Step 3U)
   - The Dependency Sequencing Principles
3. Each specialist **reviews only the changed sections** from their domain
   perspective. Output format:
   ```markdown
   ## <Role> Update Review
   | # | Severity | Change | Assessment | Suggestion |
   ```
   Severities: `CRITICAL`, `WARNING`, `SUGGESTION`
4. **Discussion phase** — same anti-sycophancy protocol as Step 5T.4,
   focused on: does the change break existing assumptions? Are new
   dependencies correct? Does sequencing still hold?
5. **Synthesis** — same mandatory checkpoint as Step 5T.5. Print the
   synthesis state block with surviving findings and explicit verdict:
   `APPROVED` or `NEEDS RESOLUTION`.
6. **Resolution loop** (only if NEEDS RESOLUTION) — same pattern as
   Step 5T.6: compile CRITICAL + WARNING findings into a resolution brief,
   spawn the Fixer (`subagent_type: fixer`), re-review with affected
   specialists, re-synthesize with verdict, check convergence.
7. **Maximum 2 rounds** of review-fix (lighter since most of the plan is
   already validated). If issues remain after 2 rounds, present to user.

This is valuable for major restructuring (phase reordering, splitting tasks,
adding entire phases) where multiple perspectives catch more issues.

Then proceed to Step 8 (Validation).

---

# COMMON STEPS (both modes converge here)

## Step 7: YAML Synthesis (R5)

### Create Mode

Generate `docs/INPROGRESS_Plan_<plan-name>/execution-plan.yaml` conforming to
`~/.claude/schema/execution-plan.schema.json`:

- `schema_version: "1.0.0"`
- Reference source documents in `sources` array
- Map each EXECUTION_PLAN.md phase to a schema phase
- Map each task with: id, name, status (pending), depends, prompt, acceptance
- **Acceptance criteria: VERBATIM copy.** Copy each acceptance criterion
  string exactly as written in EXECUTION_PLAN.md. Do NOT paraphrase,
  summarize, or reword. The YAML and markdown must be identical — the YAML
  is a machine-readable mirror, not a rewrite. Strip markdown formatting
  (backticks, bold) but preserve the exact wording.
- **Gate checklists: VERBATIM copy.** Same rule applies to gate checklist
  items — copy exactly from EXECUTION_PLAN.md.
- **Task prompts:** Always use `prompt: "/start <task-id>"` — never
  `/implement flow` or other pipeline-phase commands. Each task is a feature
  that enters the full SDLC pipeline via `/start`.
- Define gates between phases
- Task IDs: ASCII slugs matching `^[a-z0-9-]+$` (R9)
- Plan text in the dialog language, IDs as ASCII slugs (R9)

### Update Mode

**Do NOT regenerate the YAML.** Changes were already applied in Step 4U.
Verify the YAML is consistent with EXECUTION_PLAN.md by checking:
- All tasks in markdown exist in YAML
- All acceptance criteria match (VERBATIM)
- All dependencies match
- Changelog entry present

### Changelog Format

For both create (initial entry) and update (change entries), maintain a
`changelog` array in the YAML:

```yaml
changelog:
  - date: "2026-03-18"
    type: added          # added | removed | restructured | modified
    description: "Initial plan creation"
    affected_tasks: []
    affected_phases: []
  - date: "2026-03-20"
    type: restructured
    description: "Moved data-viewer tasks to Phase 1 for early data model validation"
    affected_tasks: [data-viewer-api, data-viewer-ui]
    affected_phases: [phase-1, phase-5]
```

## Step 8: Validation (R10)

Run:
```bash
python3 ~/.claude/tools/validate-plan.py docs/INPROGRESS_Plan_<plan-name>/execution-plan.yaml
```

If validation fails: fix errors and re-validate automatically.
Do NOT present the plan to the user until validation passes.

## Step 9: User Review (R11)

### Create Mode

Present:
- Setup plan summary (key prerequisites)
- Execution plan summary (phases, task counts, dependencies)
- Adversarial review log (rounds completed, issues found and fixed)
- Any unresolved FAILs that need user input (if iteration cap was hit)
- YAML structure overview
- **If team mode:** Team design summary (which specialists contributed what,
  key debates and resolutions)

### Update Mode

Present:
- **Change summary:** What was added/modified/removed
- **Changelog entry:** The changelog that will be recorded
- **Impact assessment:** Which phases/tasks affected
- **Status preservation check:** Confirm all done/wip statuses unchanged
- Update review log (rounds completed, issues found)

Checkpoint: `[approve / amend]`

On `amend`: ask what to change, apply to relevant documents, re-run the
adversarial review loop (Step 6 or 5U), re-validate YAML (Step 8), and
present again.

## Step 9.5: Commit Plan Documents

After the user approves, commit the plan docs so worktrees can access them:

```bash
git add docs/INPROGRESS_Plan_<plan-name>/
git commit -m "docs(plan): <verb> execution plan for <plan-name>"
```

**Verb selection:**
- Create mode: `add`
- Update mode: `update` — include one-line summary of change

This is **critical** — worktrees are created from `main` via `git worktree add`.
If plan docs are uncommitted, they won't exist in the worktree and downstream
commands (`/ba`, `/plan`, etc.) will have no plan context.

## Step 10: Execution Guidance

### Create Mode

```
## How to Execute This Plan

Each task is a feature that goes through the full SDLC pipeline:

1. From the main project, run: /start <task-id>
2. Switch to the new worktree (VSCode: File → Open Folder)
3. In the worktree, run the pipeline: /ba flow → /ux flow → /plan flow → /review flow → /implement flow → /static-analysis flow → /manualtest flow → /qa flow
4. When complete: /done flow
5. Team pipeline (for complex features): same as standard but add /team-review before /review and /team-qa before /qa
6. Team gates are optional, read-only, and require CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

Tasks within a phase can run in parallel (separate worktrees).
Phase gates must pass before starting the next phase's tasks.
```

### Update Mode

```
## Plan Updated

Changes applied to execution plan. Updated tasks:
<list of added/modified/reordered tasks with new statuses>

Next steps:
- Continue with the next pending task: /start <next-task-id>
- To update the plan again later: /plan-project <plan-name> --update
```

---

## Dependency Sequencing Principles

**MANDATORY** — Apply these during plan design (Step 5, 5T, or 3U).
Document the sequencing rationale in EXECUTION_PLAN.md.

### Principle 1: Data-Model-First

Tasks that establish or validate the data model come in the earliest possible
phase. The data model is the foundation everything else builds on — getting it
wrong early is cheap, getting it wrong late is expensive.

**Heuristic:** If a task creates database tables, defines API schemas, or
establishes entity relationships, it belongs in Phase 1 (or the earliest
phase after setup).

### Principle 2: Feedback-Loop-First

Tasks that enable iterative validation (viewers, explorers, admin panels,
data browsers) should come immediately after the data model tasks they depend
on. These tools let the team verify the data model is correct by seeing real
data, catching schema mistakes before downstream tasks encode wrong assumptions.

**Heuristic:** If building a data viewer/browser would help validate a data
model task's output, schedule the viewer right after the model task — even if
the viewer isn't the "main" feature.

**Example:** In the OIH project, the data API + data viewer UI should have been
Phase 2 (right after data model setup) instead of Phase 5. Building the viewer
early would have caught data model issues during iteration instead of after
multiple dependent features were already built.

### Principle 3: Contract-Before-Consumer

Tasks that define shared interfaces (APIs, event schemas, component contracts)
must complete before tasks that consume those interfaces. This is stricter than
"parallel by default" — explicit producer-consumer relationships demand ordering.

**Heuristic:** If task B imports from, calls, or reads data produced by task A,
task B depends on task A. Make this explicit in `depends`.

### Principle 4: Risk-Gradient Ordering

Within a phase, order tasks from highest uncertainty to lowest. Tasks with
unknown technical risk, unproven integrations, or novel requirements should
come first — they're most likely to force plan changes, and discovering that
early preserves schedule flexibility.

**Heuristic:** Ask "if this task fails or needs major rework, how many other
tasks are affected?" Tasks with high blast radius go first.

### Principle 5: Explicit Sequencing Rationale

Every phase boundary and every `depends` relationship must have a documented
reason. "These tasks are in the same phase" is not sufficient — explain WHY
they are grouped and WHY they depend on each other.

In EXECUTION_PLAN.md, each phase should have a one-line sequencing rationale:
```
## Phase 2: Data Layer
**Sequencing rationale:** Data model + viewer first enables iterative validation
of entity relationships before downstream features encode assumptions.
```

---

## Rules

- **Source language preservation (R9).** If the dialog is in a non-English
  language, produce plans in that language. Task IDs remain ASCII slugs.
- **Parallel by default.** Only add `depends` when ordering is explicit —
  but DO add `depends` when sequencing principles require it.
- **All status values start as `pending`** in create mode — the plan is a blueprint.
- **Task IDs must match** `^[a-z0-9-]+$`.
- **Same-phase dependencies only (P5).** Task `depends` must reference
  tasks within the same phase. Cross-phase ordering uses phase sequence
  and gates, not inter-phase task references.
- **Immutable task list (P1).** Once approved, only status fields change
  (via flow commands). Use `--update` for structural changes.
- **Update mode preserves state.** Never overwrite `done`/`wip` statuses,
  never delete completed tasks, never modify delivered acceptance criteria.
- **Changelog is mandatory for updates.** Every `--update` invocation adds
  a changelog entry to the YAML.
- **Do NOT invent** phases or tasks not discussed in the dialog.
- Plans live in `docs/INPROGRESS_Plan_<plan-name>/` per flow-mode convention.
- **Sequencing principles are mandatory.** Every plan must document its
  sequencing rationale. The adversarial review checks this (C7).

## Example Output

```yaml
schema_version: "1.0.0"
name: "My SaaS App"
description: "A SaaS application for managing team workflows"
created: "2026-03-01"
updated: "2026-03-18"
sources:
  - name: "Setup Plan"
    path: "docs/INPROGRESS_Plan_my-saas-app/SETUP_PLAN.md"
  - name: "Execution Plan"
    path: "docs/INPROGRESS_Plan_my-saas-app/EXECUTION_PLAN.md"
changelog:
  - date: "2026-03-01"
    type: added
    description: "Initial plan creation"
    affected_tasks: []
    affected_phases: []
  - date: "2026-03-18"
    type: restructured
    description: "Moved data-viewer to Phase 2 for early data model validation"
    affected_tasks: [data-viewer-api, data-viewer-ui]
    affected_phases: [phase-2, phase-5]
phases:
  - id: setup
    name: "Phase 0: Project Setup"
    tasks:
      - id: docker-setup
        name: "Docker Compose configuration"
        status: pending
        prompt: "/start docker-setup"
        acceptance:
          - "When running docker compose up, all services start successfully"
          - "If any service fails health check, the system shall log the error"
      - id: db-init
        name: "Database initialization"
        status: pending
        depends: [docker-setup]
        prompt: "/start db-init"
        acceptance:
          - "When migrations run, all tables are created"
    gate:
      name: "Setup Gate"
      checklist:
        - "Docker compose up works"
        - "All health checks pass"
      passed: false
  - id: data-layer
    name: "Phase 1: Data Layer"
    description: "Sequencing rationale: Data model + viewer first enables iterative validation"
    tasks:
      - id: data-api
        name: "Data API endpoints"
        status: pending
        prompt: "/start data-api"
        acceptance:
          - "When GET /api/data/employees is called, the system shall return paginated employee records"
      - id: data-viewer-ui
        name: "Data viewer UI"
        status: pending
        depends: [data-api]
        prompt: "/start data-viewer-ui"
        acceptance:
          - "When navigating to /data, the system shall display a tabbed data browser"
    gate:
      name: "Data Layer Gate"
      checklist:
        - "All data API endpoints return correct data"
        - "Data viewer renders all entity types"
      passed: false
```
