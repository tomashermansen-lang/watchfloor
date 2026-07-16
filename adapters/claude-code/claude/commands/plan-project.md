---
description: Project planner — interactive planning dialog that produces a validated schema 2.0 execution-plan.yaml. Supports update mode (--update) and team-based planning (--team/--team-lite).
argument-hint: <plan-name> [--template greenfield|feature|refactor] [--update] [--team|--team-lite]
---

# /plan-project: $ARGUMENTS

Project-level planning skill that sits ABOVE the feature-level flow pipeline.
Through iterative dialog, produces a single validated `execution-plan.yaml`
(schema_version 2.0.0) — the unified knowledge graph that absorbs everything
that previously lived in SETUP_PLAN.md, EXECUTION_PLAN.md, PLANNING_BRIEF.md,
DEFERRED.md, RETRO.md, chain-state.json, and chain-events.ndjson.

**Modes:**
- **Create** (default) — new 2.0 plan from scratch
- **Update** (`--update`) — modify an existing plan while preserving completed work (auto-detects 1.x vs 2.0)
- **Team** (`--team` / `--team-lite`) — multi-specialist collaborative planning

**Output:** `docs/INPROGRESS_Plan_<plan-name>/execution-plan.yaml` only.
No separate markdown artefacts are written for new (2.0) plans — the yaml
is the single source of truth. Legacy 1.x plans are still supported in
update mode and continue to use the SETUP_PLAN.md + EXECUTION_PLAN.md +
yaml triplet they were created with.

---

## Plan event stream — how to emit (read once, apply everywhere)

`/plan-project` writes a per-plan NDJSON event stream at
`docs/INPROGRESS_Plan_<plan-name>/_PLANPROJECT_STREAM.ndjson`. The stream
is append-only, mirrors the convention used by `chain-events.ndjson` and
`autopilot-stream.ndjson`, and is read by `/retro` and operator audit
tools. Every event-emit instruction in the steps below resolves to a
single Bash tool invocation of the writer:

```bash
bash ~/.claude/tools/lib/plan-event-writer.sh emit <plan-name> <event_name> \
  key1=value1 key2="value with spaces" ...
```

The writer auto-injects `ts`, `event`, `schema_version`, and `plan` fields.
Reserved field names cannot be supplied as keys. Keys must match `^[a-zA-Z0-9_]+$`.
Local file I/O only — **no API call, no `claude -p` invocation, no Agent SDK
credit consumption.** The writer fails fast (non-zero exit) on missing plan
dir, malformed payload, or filesystem error.

When a step below says *"Emit NDJSON event `X` with `{key1, key2, ...}`"*,
the operational meaning is: invoke `plan-event-writer.sh emit <plan-name> X
key1=... key2=...`. The orchestrator MAY skip emission only if the writer
itself is unavailable on the deploy path; in that case it MUST surface a
warning to the operator and continue (the skip is a degraded mode, not a
silent failure).

---

## Step 0: Mode Detection

### 0.1: Parse Flags

Extract from `$ARGUMENTS`:
- `--update` → update mode
- `--team` → full team (8 specialists)
- `--team-lite` → lite team (3 specialists: Solution Architect + BA + Lead Dev)
- `--template <type>` → template selection
- Remaining positional args → plan name

**Load-bearing environment variable** (one — only when genuinely necessary; not exposed as a CLI flag by design):

- `PLAN_PROJECT_AUTOFALLBACK_SPECIALIST=1` → on second consecutive structural-validation failure of a specialist (see `plan-team-flow/SKILL.md` §5T.2), substitute a locally-produced lens automatically instead of pausing for operator decision. **Necessity:** required for headless autopilot — without it, a specialist double-failure hangs the planning run with no recovery path. Use this env var ONLY when no operator is present to choose. Visible quality degradation; audit-logged via `specialist_locally_produced_fallback` in the NDJSON stream and `quality_warnings[]` in the produced plan.

**Note on intentionally-absent skip env vars.** Earlier iterations introduced `PLAN_PROJECT_SKIP_COUNCIL` and `PLAN_PROJECT_SKIP_LIT_PREFLIGHT` as "emergency escape hatches." Risk review (2026-05-19) concluded both were convenience dressed as necessity:

- Step 4.5 (Council Brief) already has an orchestrator-judgement skip (`--update` mode with no new tasks proposed) AND the builder script handles greenfield gracefully (prints "No DONE_Feature folders matched" without failing). No env-var bypass is necessary.
- Step 1.6 (Literature Pre-flight) already has orchestrator-judgement skip conditions (no fresh tech topics in dialog; `--update` with recent literature already cited). No env-var bypass is necessary.

If a future legitimate "must bypass" case emerges, propose it via the principled escape-hatch design: documented necessity + audit event + console banner + caveats subsection. Don't reintroduce the convenience flags.

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

**Output:** Capture the skills in the yaml under `setup.project_specific_skills[]`
with `{name, purpose, references}` per entry. Create stub SKILL.md files in
`.claude/skills/<name>/` with the key sections identified during the dialog
(the yaml is the source of truth; the stub markdowns are deployable artifacts).

If no domain-specific skills are needed, skip this step.

## Step 1.6: Literature Pre-flight (NEW)

**Purpose.** Fetch fresh external facts on the tools, SDKs, benchmarks, and patterns the dialog surfaced, before specialists fan out at Step 5T.2. Closes Gap 2 from `docs/INPROGRESS_Refactor_plan-project-quality-upgrade/_PLANNING_BRIEF.md` §1 (stale facts shape design — e.g., the cost-efficiency v1 plan deferred a caching lever that 2026 literature shows is feasible without SDK migration).

**Skip conditions** (orchestrator judgement from observable context — no env-var bypass exists by design; see Step 0.1 "Note on intentionally-absent skip env vars"):

- Step 1 dialog surfaced no fresh tech topics (greenfield with all-known tools), OR
- `--update` mode AND the existing plan's `design_notes[]` already cites recent (≤6 months) literature on the topics being modified

Both conditions are legitimate gating decisions made by the orchestrator from observable context (dialog content, plan state). They do not print a bypass banner because they reflect correct system judgement, not operator override. If neither condition applies, the literature pre-flight runs.

**When the skip fires (judgement path) — emit an audit event so the skip is observable:**

Invoke the plan event writer (Bash tool) to append the event to the plan's NDJSON stream:
```bash
bash ~/.claude/tools/lib/plan-event-writer.sh emit <plan-name> \
  literature_preflight_judged_unnecessary \
  step=1.6 \
  trigger=<no_fresh_topics|update_with_recent_literature> \
  evidence="<one-line: which dialog content or which design_notes IDs justify the skip>"
```

This appends one line to `docs/INPROGRESS_Plan_<plan-name>/_PLANPROJECT_STREAM.ndjson` with `ts`, `event`, `schema_version`, `plan`, and the supplied payload fields. Local file I/O only — no API call, no subscription / Agent SDK credit consumption.

Rationale for the audit event (added 2026-05-19 v4 hardening): the v3 run of `autopilot-cost-efficiency` skipped Step 1.6 via this judgement path, but the skip was invisible in artefacts. Operators reviewing the v3 run could not confirm whether the skip was legitimate without rebuilding the orchestrator's reasoning. The audit event makes the judgement visible without requiring an operator banner (the skip is not a bypass).

**Protocol:**

1. **Extract topic list.** From the Step 1 dialog output, identify ≤5 topics worth fact-checking:
   - Tools / SDKs newly referenced (e.g., "Anthropic Agent SDK credit", "MCP server", "1M context")
   - Benchmarks the plan references (e.g., "SWE-bench Verified", "HELMET", "RULER")
   - Architecture patterns proposed (e.g., "team-phase context trim", "Reflexion loop cap")
   - Cost / performance claims that need quantitative anchoring

2. **Spawn `claude-code-guide`** with the Agent tool (`subagent_type: claude-code-guide`):
   ```
   For each of these topics, fetch the most recent (2025-2026) authoritative
   guidance from the official vendor docs, release notes, or top-cited papers.
   Topics: <topic-list>. Return 1-2 paragraphs per topic with verbatim quotes
   and source URLs. Cap: 5 web fetches total. Report under 1500 words.
   ```

3. **Cap.** Maximum 5 fetches per invocation (the spawned agent enforces; the orchestrator records the count in the NDJSON stream as `event=literature_preflight_invoked`).

4. **Append to Council Brief.** Write the agent's output to `docs/INPROGRESS_Plan_<plan-name>/_LIT_CACHE/findings.md` (create directory if absent). Step 4.5 (Council Brief construction) appends this to `_COUNCIL_BRIEF.md` as §4 Literature.

5. **Failure tolerance.** If the agent times out, returns empty, or web fetches fail, log `event=literature_preflight_failed` and proceed. Step 4.5 will still produce a valid Council Brief without §4.

**Audit trail.** The `claude-code-guide` invocation MUST emit `event=literature_preflight_invoked` with `{topics, fetch_count, output_path}` to the NDJSON stream. Operators can grep for this event to confirm literature was checked.

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

## Step 4: Capture Setup into YAML `setup:` Block (R2)

The 2.0 schema absorbs the entire former SETUP_PLAN.md content as the
top-level `setup:` block in `execution-plan.yaml`. Capture the following
fields from the dialog and codebase scan — they will be written to the
yaml in Step 7:

```yaml
setup:
  prerequisites:           # tools/runtimes that must exist on the machine
    - name: <tool>
      verify_cmd: <command>
      expected_exit: 0
      install_hint: <how to install>
  runtime_dependencies:    # libraries imported by the project
    - name: <package>
      already_installed: <bool>
  services_to_provision:   # databases, APIs, local servers, CI/CD
    - name: <service>
      port: <int>
      verify_cmd: <command>
      start_cmd: <command>
      notes: <optional context>
  environment_verification: # commands that confirm setup is complete
    - cmd: <command>
      expected_exit: 0
      description: <what this verifies>
  sandbox_compatibility:
    write_paths: [<allowed write locations>]
    read_restrictions: [<paths the project must not read>]
  out_of_scope:            # explicit non-goals for setup
    - <thing not provisioned by this plan>
```

For existing projects: identify only what is **missing** from the current
environment. Reuse via `existing_infrastructure_to_reuse[]` (top-level
field, see Step 5).

**Legacy 1.x plans** continue to use `docs/INPROGRESS_Plan_<plan>/SETUP_PLAN.md`
in update mode (Step 1U detects schema version automatically).

## Step 4.5: Council Brief Construction (NEW)

**Purpose.** Auto-generate the Stage 1 materials package — canary fixtures from `DONE_Feature_*`, friction table from sibling `INPROGRESS_Plan_*` chain streams, counter-evidence ledger template — that specialists need to start saturated rather than searching at Step 5T.2. Closes Gap 1 from `docs/INPROGRESS_Refactor_plan-project-quality-upgrade/_PLANNING_BRIEF.md` §1 (specialists fly blind without curated evidence; cost-efficiency v1's `_PLANNING_BRIEF.md` was hand-written by the operator because the skill could not produce it).

**Skip condition** (orchestrator judgement from observable context — no env-var bypass exists by design; see Step 0.1 "Note on intentionally-absent skip env vars"):

- `--update` mode AND no new tasks proposed (the existing plan's `design_notes[]` and DONE artefacts ARE the evidence base for that case)

This is a legitimate gating decision made by the orchestrator from observable context (plan state, change classification). No bypass banner printed because it reflects correct system judgement, not operator override.

**When the skip fires (judgement path) — emit an audit event so the skip is observable:**

Invoke the plan event writer (Bash tool):
```bash
bash ~/.claude/tools/lib/plan-event-writer.sh emit <plan-name> \
  council_brief_judged_unnecessary \
  step=4.5 \
  trigger=update_with_no_new_tasks \
  evidence="<one-line: existing plan version + change classification confirming no new tasks>"
```

Appends to `docs/INPROGRESS_Plan_<plan-name>/_PLANPROJECT_STREAM.ndjson`. Local file I/O only — no API call.

Rationale (added 2026-05-19 v4 hardening): matches the Step 1.6 judgement-skip audit event. Makes the orchestrator's reasoning visible without printing an operator banner (skip is not a bypass).

**Greenfield runs without DONE_Feature evidence:** the builder script handles this gracefully — it prints "No DONE_Feature folders matched" and produces a Council Brief with §1 empty + §2 empty + §3 ledger template. The brief is still injected into Step 5T.2 specialist prompts; specialists fall back to dialog content + codebase scan when the brief is sparse. No special handling needed.

**Protocol:**

1. **Derive topic list.** Extract ≤5 topical keywords from the Step 1 dialog output (vision, scope, tech stack) — used to filter the canary inventory to features relevant to this plan's domain. Example: for `autopilot-cost-efficiency`, topics might be `autopilot, cost, team, pipeline`.

2. **Invoke the builder.** Run the Python substrate that mines the repo:
   ```bash
   python3 ~/.claude/tools/lib/council_brief_builder.py \
     --plan-name <plan-name> \
     --topics <topic-list>
   ```
   The builder writes `docs/INPROGRESS_Plan_<plan-name>/_COUNCIL_BRIEF.md` with three sections: §1 Canary Fixture Inventory, §2 Friction Table, §3 Counter-Evidence Ledger (empty template).

3. **Append Literature §4 (if Step 1.6 ran).** If `docs/INPROGRESS_Plan_<plan-name>/_LIT_CACHE/findings.md` exists from Step 1.6, append it to `_COUNCIL_BRIEF.md` as `## §4 Literature`. If absent, skip.

3a. **Append Retro Feedback §5 (if prior execution evidence exists).** Run:
```bash
python3 ~/.claude/tools/lib/plan-retro.py --plan <plan-name> 2>&1
```
The retro substrate walks `docs/DONE_Feature_*/` for features whose `task_id` maps to a task in this plan's `execution-plan.yaml`, computes predicted-vs-actual deltas (LOC, hours, cost, outcome), rolls up by specialist / pipeline / task-type / phase, and writes `docs/INPROGRESS_Plan_<plan-name>/_RETRO_FEEDBACK.md`. **If the file is produced** (exit 0 — at least one executed task found), append its body to `_COUNCIL_BRIEF.md` as `## §5 Retro Feedback (historical accuracy from prior executions)`. **If exit is 3** (no executed tasks yet), skip this section. The retro substrate is pure local I/O — no API call, no Agent SDK credit consumption. This closes the feedback loop where Step 9.7 (pilot mode) was originally proposed: continuous learning across N executed features, not one-shot synchronous pilot.

4. **Inject into 5T.2 specialist prompts.** Every Step 5T.2 specialist spawn MUST include the Council Brief content in its prompt with the instruction: *"Cite at least one row from §1 (canary), one row from §2 (friction), and one row from §3 (counter-evidence) by section name in your output. If §5 Retro Feedback is present, calibrate your LOC / duration / cost estimates against the observed biases (e.g., if §5 reports `LOC estimation bias: 123% UNDER`, do not estimate at the historical mean — estimate at the bias-corrected mean). Responses that do not cite the Council Brief by section trigger a structural re-spawn per `plan-team-flow/SKILL.md` §5T.2."*

5. **Audit trail.** The Edit/Write event on `_COUNCIL_BRIEF.md` is the audit-trail signal. The Council Brief is committed alongside the plan at Step 9.5.

**Cost guard.** The Python builder is read-only and runs in ≤30 s on a repo with ~80 DONE_Feature folders. No LLM tokens consumed; no agent spawn. The Council Brief itself is markdown, costs <2k tokens to inject into each specialist prompt — well below the Step 5T.2 per-specialist context ceiling.

**Failure tolerance.** If the builder script exits non-zero (e.g., no DONE folders, repo path unresolved), log `event=council_brief_skipped` and proceed without it. The plan can still be authored; specialists rely on dialog output as fallback.

## Step 5: Capture Execution into YAML Fields (R3)

**If `--team` or `--team-lite`:** Skip to Step 5T (Team Plan Design).

The 2.0 schema absorbs the entire former EXECUTION_PLAN.md content as
structured fields in `execution-plan.yaml`. Capture the following from
the dialog — they will be written in Step 7:

**Top-level fields** (project-wide):
- `name`, `description`, `vision` — what the project is and the desired outcome
- `users[]` — primary users / personas
- `success_criteria[]` — `{id, description, measurable_via, verified_at_phase}`
- `scope.in_scope[]` and `scope.out_of_scope[]` — explicit boundaries
- `tech_stack[]` — the technology choices
- `existing_infrastructure_to_reuse[]` — paths/modules to leverage (existing projects)
- `test_targets[]` — `{id, path, description}` — projects under test (multi-project plans use multiple entries)
- `kill_criteria[]` — `{id, description, trigger}` — conditions that should abort the plan
- `design_notes[]` — `{id, note}` — architectural decisions and rationale

**Phases array** (`phases[]`):
- Each phase has: `id`, `name`, `description` (one-line sequencing rationale), `tasks[]`, `gate`
- Tasks within each phase (see **Task Detail Requirements** below)
- Dependencies between tasks via `depends[]` (same-phase only — see Rules)
- Acceptance criteria per task in EARS notation:
  - Event-driven: `When [trigger], the system shall [response]`
  - State-driven: `While [state], when [event], the system shall [response]`
  - Unwanted: `If [error condition], then the system shall [recovery behavior]`
- Flow command prompts per task: every task uses `prompt: "/start <task-id>"`
  so each task enters the full SDLC pipeline (worktree → `/ba` → `/plan` →
  `/implement` → `/static-analysis` → `/qa` → `/done`)
- Quality gates between phases (`gate.checklist[]` — see Gate guidance below)

**Producer conventions (dispatch):** When writing each task and authoring gates,
Read [`claude/skills/plan-producer-conventions/SKILL.md`](../skills/plan-producer-conventions/SKILL.md)
inline and apply its sections:

- §1 Task Detail Requirements (what / why / where / acceptance / constraints)
- §2 Gate Checklist Format (anti-patterns, good patterns, kind:shell vs kind:human, shell-check pitfalls)
- §3 Decomposition Rules (≤150 LOC / ≤3 hours / ≤3 files / ≤5 ACs target; merge/split criteria)
- §4 Autopilot Eligibility and Pipeline Weight (autopilot:true/false + pipeline:light/full triggers)

The Read event on the skill file is the audit trail in `autopilot-stream.ndjson`.
Sequencing Principles (§5) and Plan-wide Rules (§6) of the same skill are
referenced below (after Step 10).

## Step 5T: Team Plan Design (--team/--team-lite only)

**Dispatch:** When the team-mode flag is set, Read
[`claude/skills/plan-team-flow/SKILL.md`](../skills/plan-team-flow/SKILL.md)
inline and follow its 5T.1–5T.6 protocol. The skill body owns:

- §5T.1 Specialist Definitions (8-agent roster for `--team`, 3 for `--team-lite`,
  with the `subagent_type` mapping table)
- §5T.2 Independent Analysis (parallel specialist spawn + output format)
- §5T.3 Synthesis (Architect drafts the YAML)
- §5T.4 Team Discussion (anti-sycophancy protocol + structured finding format)
- §5T.5 Synthesis Verdict (APPROVED / NEEDS RESOLUTION checkpoint)
- §5T.6 Resolution Loop (Fixer + re-review, max 3 rounds, convergence detection)

After §5T concludes (verdict APPROVED), proceed to Step 5.5 below.

## Step 5.5: Anti-Pattern Self-Review (Schema 2.0)

When the plan declares `schema_version: 2.0.0`, the producer SHALL run an
anti-pattern self-review against its own draft BEFORE entering the
Adversarial Review Loop in Step 6. Reference for verbatim anti-pattern →
exemplar pairs:
`claude/skills/plan-producer-patterns/SKILL.md`. Read the skill file
inline at producer-prompt run time (the Read event is the audit trail in
`autopilot-stream.ndjson`).

The five patterns are:
- **Stub strings** (R15) — `task.what` < 80 chars or `task.why` < 120 chars
  or 60-char overlap between two tasks' `what`.
- **Aspirational success_criteria** (R16) — descriptions matching
  `\b(well-designed|robust|good|nice|clean)\b` with no measurable artefact.
- **Glob where.modify** (R17) — any `*`, `?`, `[`, or `**` in
  `where.modify | where.create | where.delete`.
- **Tautological acceptance** (R18) — entries that don't start with
  `When |While |If |Where ` and contain a `\bshall\b` token.
- **Dangling cross-references** (R19) — any `_refs` or `depends` value
  that does not resolve to a top-level ID.

**Patterns 7-9 (BACKLOG #45 / Plan Decomposition Rules):**

- **Oversize-task split-proposal** (R-B1, paired with R-A1..R-A4) —
  validators in `claude/tools/lib/plan_validators.py`
  (`validate_task_sizing`) flag tasks exceeding ≤5 acceptance, ≤300 LOC,
  ≤4 hours, or ≤5 touched-paths. Producer self-review catches it earlier
  and prescribes a vertical split by **behavioral seam** (user flows /
  observable outcomes), NOT by file boundary.
- **Verbose-content structure** (R-B2, R-B4, R-B5) — XML wrappers
  `<scope>` / `<acceptance>` MANDATORY above the 400-character
  description threshold; EARS clauses inside `<requirements>`, Gherkin
  scenarios inside `<acceptance>`, Always/Ask/Never lists inside
  `<boundaries>`. English-only proxy regex with the
  `extensions.language: <code>` opt-out.
- **Walking-skeleton-first sequencing** (R-B3) — phase-1 first task is
  the thinnest end-to-end thread through the **core subdomain** (DDD
  differentiating logic). Encoded in `phase.sequencing_rationale` as
  one of `walking-skeleton` / `data-model-first` / `riskiest-first` /
  `smallest-first` OR a custom rationale ≥40 chars. Validator:
  `validate_sequencing_rationale_enum`.

**Self-review protocol:**
1. Run `python3 claude/tools/lib/plan_self_review.py
   docs/INPROGRESS_Plan_<name>/execution-plan.yaml` and parse the JSON
   result.
2. While `retry_advised: true`, regenerate the offending field(s) using
   the exemplar in the skill file as guide and re-run. **max 2 retries**
   per task per pattern.
3. After two retries, append remaining violations to
   `project.quality_warnings[]` (`{pattern_id, task_or_phase_id, description, retried_count}`)
   and proceed.
4. The `task_type=other` enum value is a **last resort** — when any
   specific type's `where`-distribution matches, prefer the specific type.

**`task_type` guidance table (R26) — all 8 enum values with `where[]` emphasis:**

| `task_type` | Typical `where[]` emphasis |
|-------------|---------------------------|
| `development` | emphasize `where.modify[]` for code files (`.py`, `.ts`, `.sh`, etc.) |
| `documentation` | emphasize `where.create[]` or `where.modify[]` for `.md`, `.rst`, docs |
| `research` | `where[]` often empty or minimal — output is a doc, not a code change |
| `setup` | emphasize `where.create[]` for config, infra files (`docker-compose.yml`, etc.) |
| `review` | `where[]` typically empty — artifact is a review document, not code |
| `refactor` | emphasize `where.modify[]` for existing code; `where.create[]` should be minimal |
| `testing` | emphasize `where.create[]` for new test files, `where.modify[]` for test helpers |
| `other` | **last resort** — use only when none of the above types match the `where`-distribution |

The Step 5T.4 team-mode discussion topic likewise includes anti-pattern
review so team mode does not bypass it.

## Step 6: Adversarial Review Loop (R4)

Iteratively review and fix plans until the critic finds nothing to fix,
or the iteration cap is reached.

**Critic evaluation criteria (mandatory checklist):**

| # | Criterion | What to check |
|---|-----------|---------------|
| C1 | Testability | Every task has EARS-formatted acceptance criteria that map to a concrete test |
| C2 | Dependency validity | Dependencies form a valid DAG; no orphan tasks with unmet deps |
| C3 | Setup-execution consistency | Every tech/service referenced in `phases[].tasks[]` (or task `where`/`constraints`) has a corresponding entry in `setup.prerequisites[]`, `setup.runtime_dependencies[]`, or `setup.services_to_provision[]` |
| C4 | Completeness | No `[NEEDS CLARIFICATION]` markers remain unresolved |
| C5 | Feasibility | Tasks are achievable with the stated tech stack and constraints |
| C6 | Risk coverage | For existing projects: regression risks and migration hazards identified |
| C7 | Sequencing soundness | Dependency Sequencing Principles applied: data-model tasks early, feedback-loop tasks before consumers, no implicit ordering assumptions |
| C8 | Downstream readiness | Every task has: what (description), why (motivation), where (affected files/modules), EARS acceptance criteria, and key constraints. A BA reading this task can start `/ba flow` without re-discovering context |
| C9 | Task granularity | No over-decomposition: tasks that share files, mental context, language, and sequential dependency are merged (unless parallelism possible). No task under ~200 lines / 1 hour of implementation exists without a merge justification. Flag any task that would take <1 hour and has a neighbor sharing files/context. |
| C10 | Gate automation | Every gate checklist item uses `{ item, check: { kind: shell \| human, cmd } }` format. String-only items fail. `kind: human` items must have explicit justification in the gate's `notes:` field (visual UI inspection, production sign-off, genuine judgment). Items that restate "tests pass" or "file exists" or similar mechanical checks as `kind: human` are rejected. |

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
   do not rewrite."** The critic evaluates `execution-plan.yaml` against
   all ten criteria (C1-C10) and returns structured findings. For 2.0
   plans the critic reads the unified yaml; for legacy 1.x plans (update
   mode only) the critic reads SETUP_PLAN.md + EXECUTION_PLAN.md + yaml
   triplet. For existing projects: include the codebase scan results from
   Phase D.

   **Structured output format (per criterion):**
   ```
   C1 Testability: PASS | FAIL
      Evidence: [specific task/criteria that passed or failed]
      Suggestion: [actionable fix if FAIL]
   ```

   **Per-criterion event emission.** For each of C1–C10 that the critic
   evaluates, emit one `step_6_criterion_evaluated` event so `/retro`
   can grep cross-plan for which compliance dimensions tend to fail:
   ```bash
   bash ~/.claude/tools/lib/plan-event-writer.sh emit <plan-name> step_6_criterion_evaluated \
     criterion=<C1|C2|C3|C4|C5|C6|C7|C8|C9|C10> \
     verdict=<PASS|FAIL> \
     round=<N> \
     evidence="<first 80 chars from the critic's Evidence line>"
   ```
   Emit one event per criterion per round. A typical Step 6 round generates 10 events; if the loop runs multiple rounds, the stream captures the per-criterion verdict progression. Closes the gap surfaced in pipeline-smoke-test 2026-05-19 where Step 6 "ALL PASS" was useful operator-facing summary but the per-criterion verdicts were lost from the stream entirely.

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
   `execution-plan.yaml` (or, for legacy 1.x update flows, to
   SETUP_PLAN.md / EXECUTION_PLAN.md / yaml). Do not modify the critic's
   evaluation — only the plan artifacts.

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

**Dispatch:** Read [`claude/skills/plan-update-flow/SKILL.md`](../skills/plan-update-flow/SKILL.md)
inline and follow its 1U–5U protocol. The skill body owns:

- Schema-version detection (1.x vs 2.0 — first action)
- §1U Update Dialog (current-state load + change elicitation)
- §2U Change Classification (8 change types + absorbed-task removal rule + immutability rules)
- §3U Narrative Updates (legacy 1.x only)
- §4U YAML Edits (status-preservation checklist)
- §5U Update Review (solo C1–C8 OR team variant — applies the resolution-loop
  pattern from [`plan-team-flow/SKILL.md`](../skills/plan-team-flow/SKILL.md) §5T.6
  with `max_rounds = 2`)

After §5U concludes, proceed to Step 8 (Validation) below.

---

# COMMON STEPS (both modes converge here)

## Step 7: YAML Synthesis (R5)

### Create Mode

Generate `docs/INPROGRESS_Plan_<plan-name>/execution-plan.yaml` conforming to
`~/.claude/schema/execution-plan.schema.json` — this is the **only** artefact
produced for new plans:

- `schema_version: "2.0.0"` (the new default for fresh plans)
- Top-level fields populated from Step 5 capture: `name`, `description`,
  `vision`, `users[]`, `success_criteria[]`, `scope`, `tech_stack[]`,
  `existing_infrastructure_to_reuse[]`, `test_targets[]`, `kill_criteria[]`,
  `design_notes[]`
- `setup:` block populated from Step 4 capture
- `phases[]` with each phase having `id`, `name`, `description` (sequencing
  rationale), `tasks[]`, `gate`
- Each task carries: `id`, `name`, `status: pending`, `depends`, `prompt`,
  `task_type` (one of: development, documentation, research, setup, review,
  refactor, testing, other — see R26), `what`, `why`, `where.{modify,create,delete}[]`,
  `acceptance[]`, `constraints[]` (and optional `estimate`, `manualtest_scenarios[]`,
  `_refs`)
- **Acceptance criteria are EARS-formatted strings**: `When ... shall ...` /
  `While ... when ... shall ...` / `If ... then the system shall ...` /
  `Where ... shall ...`. The 2.0 validator (R18) rejects tautological criteria.
- **Gate checklists** use `{ item, check: { kind: shell|human, cmd } }` (R10).
  String-only items are rejected.
- **`where[]` paths must be concrete** — no glob patterns (R17).
- **`task.what` ≥ 80 chars and `task.why` ≥ 120 chars** (R15) so the BA can
  start `/ba flow` without re-discovering context.
- **Task prompts:** Always `prompt: "/start <task-id>"` — never
  `/implement flow` or other pipeline-phase commands. Each task is a feature
  that enters the full SDLC pipeline via `/start`.
- Task IDs: ASCII slugs matching `^[a-z0-9-]+$` (R9)
- Plan text in the dialog language, IDs as ASCII slugs (R9)

No SETUP_PLAN.md or EXECUTION_PLAN.md is written. The yaml IS the plan.

### Update Mode

**2.0 plans:** Changes were already applied to `execution-plan.yaml` in Step
4U. Re-validate the yaml — no regeneration needed.

**Legacy 1.x plans:** Changes were applied to both EXECUTION_PLAN.md and the
1.0.0 yaml in Steps 3U + 4U. Verify they remain consistent by checking:
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

## Step 9.6: Adversarial Defence Pass (NEW)

**Purpose.** Stress-test the produced YAML at the **premise** level — distinct from Step 6's C1–C10 **compliance** critic. Closes Gap 3 from `docs/INPROGRESS_Refactor_plan-project-quality-upgrade/_PLANNING_BRIEF.md` §1 (the cost-efficiency v1 plan PASSED C1–C10 but the 2026-05-16 deep review found 10 material gaps that emerged only when the plan was reviewed as a product).

**Distinction from Step 6:**
- Step 6 critic asks: *"is this AC formatted correctly? does this dep resolve? is this gate kind:shell?"* — compliance.
- Step 9.6 critic asks: *"is the biggest-ROI task in the first phase? does the cost math hold up against the success criteria? what concrete observation would invalidate this task? what proposed lever is missing that a comparable industry pattern would adopt?"* — premise.

**Protocol:**

1. **Spawn 4 specialists** in parallel using the Agent tool. Same 4 every run (not all 8 — adversarial defence is targeted, not exhaustive):
   - `architect` — phase sequencing premise + module-boundary blindspots
   - `lead-developer` — feasibility premise + reused-substrate blindspots
   - `performance-engineer` — cost/ROI math integrity
   - `security-auditor` — quality-protection premise + safety-trigger blindspots

2. **Premise-adversarial prompt** (template — fill in `<plan-path>`):
   ```
   You are an adversarial reviewer of the plan at <plan-path>. Your job is to
   ATTACK its premises, not check its compliance (Step 6 already did that).

   Three axes:
   (a) Sequencing — is the biggest-ROI task in the first phase? If not, why
       not? Cite the ROI table or success_criteria.
   (b) Integrity — does the cost / quality math hold against the
       success_criteria? Find one task whose claimed savings depend on
       infrastructure that does not exist or is not in scope.
   (c) Blindspots — what proposed lever is MISSING that a comparable
       industry pattern (cite a 2025-2026 source if possible) would adopt?

   Constraints:
   - You may NOT suggest changes to formatting, dependency graphs, or AC wording
     (Step 6 owns that). Focus on premise-level issues only.
   - Each finding must be one of {CRITICAL, WARNING}. SUGGESTION-only is a
     pass — emit only if you have something premise-level to challenge.
   - Cite the Council Brief sections (§1 canary, §2 friction, §3 counter-
     evidence) if relevant — the Brief is at
     docs/INPROGRESS_Plan_<plan-name>/_COUNCIL_BRIEF.md.

   Output format:
   | # | Severity | Axis | Premise being attacked | Evidence | Suggested resolution |
   ```

3. **Synthesis.** Orchestrator collects findings, deduplicates, presents the verdict block (same shape as Step 5T.5):
   ```
   ## Adversarial Defence Synthesis

   ### Surviving findings
   | # | Severity | Axis | Premise | Evidence | Resolution |

   ### Verdict: APPROVED | NEEDS RESOLUTION
   CRITICAL: <count>  |  WARNING: <count>
   ```

   **Emit per-finding events** so the stream captures the actual content (not just aggregate counts in `adversarial_defence_completed`). For each row in the "Surviving findings" table:
   ```bash
   bash ~/.claude/tools/lib/plan-event-writer.sh emit <plan-name> finding_recorded \
     source_step=9.6 \
     severity=<CRITICAL|WARNING> \
     axis=<sequencing|integrity|blindspots> \
     source_specialist=<architect|lead-developer|performance-engineer|security-auditor> \
     title="<first 80 chars of premise>" \
     resolution=<pending|resolved_round_1|resolved_round_2|to_quality_warnings>
   ```
   This is the level-1 content the pipeline-smoke-test 2026-05-19 run was missing (the run produced `critical_count:1, warning_count:8` but the actual KC-enforcement cross-plan CRITICAL was not in the stream).

4. **Resolution loop (max 2 rounds — tighter than 5T.6's max 3).** If `NEEDS RESOLUTION`, apply the resolution-loop pattern from [`plan-team-flow/SKILL.md`](../skills/plan-team-flow/SKILL.md) §5T.6 with `max_rounds = 2`. Rationale: the Council Brief should already have surfaced most premise issues; if 2 rounds don't converge, escalate to the operator. Findings that survive 2 rounds become `quality_warnings[]` entries with `severity: premise_unresolved`.

   **For each warning that demotes to `quality_warnings[]`** (i.e., survived 2 rounds without resolution), emit:
   ```bash
   bash ~/.claude/tools/lib/plan-event-writer.sh emit <plan-name> quality_warning_recorded \
     source_step=9.6 \
     pattern_id="premise_unresolved_step_9_6_round_<N>" \
     severity_demoted_from=WARNING \
     title="<first 80 chars>"
   ```
   For each finding that gets resolved during the loop, emit a `finding_recorded` update with `resolution=resolved_round_<N>` (mirrors the §5T.6 resolution-loop event pattern).

5. **Audit trail.** Emit NDJSON events `adversarial_defence_started` and `adversarial_defence_completed` with `{round_count, critical_count, warning_count}`. The per-finding events in step 3 above provide the level-1 content; these aggregate events provide the level-0 phase boundaries. Both are needed: aggregates for fast scans, per-finding events for `/retro` cross-plan pattern detection.

**Cost guard.** 4 specialists × max 2 rounds × ~$3/specialist = ~$24 ceiling per plan. The premise-critic prompt is bounded (no codebase scan; no team-discussion fan-out).

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

See [`claude/skills/plan-producer-conventions/SKILL.md`](../skills/plan-producer-conventions/SKILL.md) §5.

## Rules

See [`claude/skills/plan-producer-conventions/SKILL.md`](../skills/plan-producer-conventions/SKILL.md) §6.

## Reference fixture

A complete, validated 2.0 plan exemplar is at
[`tests/fixtures/plan-2.0.0/full.yaml`](../../../tests/fixtures/plan-2.0.0/full.yaml).
Use it as the shape reference rather than inlining sample YAML here.
