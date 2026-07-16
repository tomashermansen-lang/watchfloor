---
name: plan-producer-conventions
description: Producer-during conventions for /plan-project — task detail requirements, gate checklist format (anti-patterns + good patterns + shell-check pitfalls), decomposition rules and size targets, autopilot eligibility plus pipeline weight, dependency sequencing principles, and plan-wide invariants. Read inline by /plan-project at Steps 5, 5T, 5U, and 4U while writing the execution-plan.yaml.
disable-model-invocation: true
user-invocable: false
---

# Plan Producer — Conventions

This file is read verbatim by `/plan-project` while it writes
`execution-plan.yaml`. The Read event on this file is the audit trail
for the producer-conventions step (observable in
`autopilot-stream.ndjson`).

## Contents

- §1 Task Detail Requirements
- §2 Gate Checklist Format (anti-patterns, good patterns, shell-check pitfalls)
- §3 Decomposition Rules
- §4 Autopilot Eligibility and Pipeline Weight
- §5 Dependency Sequencing Principles
- §6 Plan-wide Rules

---

## §1 Task Detail Requirements — downstream-ready for the feature pipeline

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

---

## §2 Gate Checklist Format

**Gate checklist MUST test cross-feature integration, not duplicate feature ACs or regression tests.**

**Also never put full regression test suites in gate checks.** Post-merge
smoke (from CLAUDE.md `pipeline.smoke_test`) already runs the full test
suite after every merge. Duplicating "all tests pass" in a gate:
1. Runs expensive tests twice per feature (gate + post-merge smoke)
2. Grows beyond gate timeouts as suite grows (empirical: 648 tests = 71s
   on M1 Mac, past default 60s)
3. Doesn't add signal — if post-merge smoke passes, regression is caught
4. The gate fails but the feature was correct — false negative

Gate timeouts should be <30s. If you need >30s it's a hint the check is
wrong (probably regression, not integration).

Empirical lesson: gate items that restate a single feature's acceptance
criteria are pure ceremony — those ACs already passed at the feature's
commit step (via QA phase + static analysis + commit-preflight). The gate
adds zero value as a redundant check.

Phase gates must test things feature-level ACs cannot:

1. **Cross-feature integration** — the combined behavior when two or more
   of the phase's features interact on `main`. Example: "grinder.sh discover
   invokes normalise-findings.py correctly and emits a plan that validates
   against the schema" — tests integration, not individual components.
2. **Phase-level deliverable** — does the phase enable what the next phase
   requires? Example: "Phase 3 grinder passes can successfully read the
   orchestrator's state files and emit events" — this is Phase 2's real
   deliverable to Phase 3.
3. **Regression on main after all merges** — the full project test suite
   passes after ALL phase features are merged. Catches conflicts invisible
   to individual feature branches.
4. **Infrastructure/setup prerequisites for the next phase** — tools
   installed, services running, fixture data committed.

**Gate checklist anti-patterns (reject during plan authoring):**

| Anti-pattern | Why it's pointless | Fix |
|---|---|---|
| "Feature X's tests pass" | Already verified at feature's commit step | Replace with integration test combining X + Y |
| "grinder.sh discover runs to completion" (duplicate of discovery-pass AC) | Individual feature's AC | "grinder.sh discover + scanner-normaliser integration produces valid plan" |
| "All 18 fixture tests pass" (from one feature) | Feature-level detail | "All Python tests pass on main after merge" (catches regressions from other merges) |
| "X file exists" | Trivial; Git would have failed if it didn't | Test the file's actual behavior in context |

**Gate checklist good patterns:**

| Good pattern | Why it adds value |
|---|---|
| "uv run python3 -m pytest tests/ -q" (whole suite) | Catches cross-feature regressions on main |
| "bash claude/tools/grinder.sh discover && test -s docs/grinder/grinder-plan.yaml" | Integration: orchestrator + normaliser + discovery together |
| "grep -q 'schema_version' schema/baseline.schema.json" | Phase deliverable: downstream phases can consume it |
| "Next phase's prerequisite check script passes" | Forward-compatibility |

**MANDATORY — author a real integration gate when a phase touches the
integration surface.** This is a required step, not advice — do it for EVERY
phase before writing its gate:

1. Read the target project's `pipeline.yaml` `integration_test.trigger` globs.
   If the project has no `integration_test` block, skip this rule (there is no
   integration gate to author) and use the `kind: shell`/`human` rules below.
2. Take the union of the phase's task paths (`where.modify` + `where.create`).
3. **If that union intersects ANY `integration_test.trigger` glob**, the phase's
   gate MUST include a `kind: integration` check — the manifest-driven gate that
   runs the emergent cross-task suite unsandboxed at the phase boundary, with
   leaddev remediation. Its `trigger` MUST be `integration_test.trigger` copied
   **verbatim** (same globs, same order — NEVER scoped to the phase's own paths,
   which under-fires), plus a `remediation` block (`agent: lead-developer`,
   `max_iterations` 1..5, `on_unfixable: escalate`); omit `command` so the
   orchestrator resolves it from the manifest. A trigger-surface phase that ships
   a `kind: shell` gate INSTEAD of `kind: integration` silently loses the
   emergent verification — that is a defect, reject it in self-review.
4. **If it does not intersect**, do NOT author a `kind: integration` check —
   use the `kind: shell` cross-feature checks below.

A `kind: integration` check MAY coexist with `kind: shell` checks in the same
gate. Full shape, examples, and anti-patterns: `integration-gate-authoring/SKILL.md`.

**MANDATORY: Gates use `kind: shell` by default. `kind: human` is the exception.**

**MANDATORY: Gates use `kind: shell` by default. `kind: human` is the exception.**

Every gate checklist item MUST use the structured format:
```yaml
- item: "<description>"
  check: { kind: shell, cmd: "<verification command>" }
```

String-only checklist items (e.g., `- "description"`) are REJECTED during
plan authoring. They default to `kind: human` which blocks the
autopilot-chain for operator review — usually unnecessary ceremony.

Use `kind: human` ONLY when genuinely unverifiable by script:

| Legitimate `kind: human` | Example |
|---|---|
| Visual inspection of UI | "Operator confirms layout renders correctly at 320px and 1440px" |
| Subjective judgment of content | "Operator confirms deferred-findings.json reasons are genuine (not boilerplate)" |
| Production readiness sign-off | "Stakeholder has approved the release" |
| Safety-critical acknowledgement | "Operator confirms backup exists before schema migration" |

Illegitimate `kind: human` (convert to `kind: shell`):

| Pattern | Shell equivalent |
|---|---|
| "Tests pass" | `check: { kind: shell, cmd: "uv run python3 -m pytest tests/ -q" }` |
| "File X exists" | `check: { kind: shell, cmd: "test -f path/to/X" }` |
| "Schema validates" | `check: { kind: shell, cmd: "python3 validate.py schema file" }` |
| "Command runs" | `check: { kind: shell, cmd: "bash claude/tools/cmd.sh status" }` |
| "Grep for X in Y" | `check: { kind: shell, cmd: "grep -q 'X' Y" }` |

When writing the cmd: prefer idempotent, fast (<30s) checks that exit 0
on success, non-zero on fail. Output is captured but not parsed — only
exit code matters for gate evaluation.

**Shell-check pitfalls to avoid (empirical, learned the hard way):**

1. **`wc -l` pads with whitespace on macOS.**
   `wc -l` outputs `       5` (with leading spaces), not `5`. Combining
   with `grep -q '^[1-9]'` fails because the pattern doesn't match the
   space prefix. **Fix:** check files directly with `grep -q` per file
   AND'd together, or strip whitespace with `tr -d ' '`:
   ```bash
   # WRONG (pads with whitespace, may fail unexpectedly):
   grep -l 'pattern' a b c | wc -l | grep -q '^[1-9]'
   # RIGHT:
   grep -q 'pattern' a && grep -q 'pattern' b && grep -q 'pattern' c
   # OR if counting matters:
   [[ $(grep -lc 'pattern' a b c | wc -l | tr -d ' ') -ge 1 ]]
   ```

2. **Pipe exit codes default to last command.**
   `cmd1 | cmd2 | cmd3` returns cmd3's exit code by default. Earlier
   failures get masked. Use `set -o pipefail` in scripts; in inline
   shell-checks, prefer `&&` chaining over pipes when each step's
   success matters.

3. **Don't guess check coverage — align with audit artifacts.**
   If a task produces an audit document (e.g., `scanner-call-sites.md`
   listing what was refactored), the gate should reference that document
   as truth, not enumerate files independently. Mismatched gates produce
   false negatives (gate fails despite work being correct).
   Example anti-pattern from zero-tech-debt-pipeline Phase 4: gate
   listed 4 files to check, but the feature's audit determined only 2
   needed refactoring → gate failed despite correct work.
   **Fix:** either reference the audit (`grep -q "complete" audit.md`)
   OR write the check to match the audit's actual scope.

4. **`grep -l` exit code semantics.**
   `grep -l` returns 0 if matches found in ANY file, 1 if no matches in
   any file. It does NOT fail just because some files lack the pattern.
   Use this for "at least one file matches" checks, not "all files match".

5. **Shell substitutions in YAML.**
   `$(pwd)` and `${VAR}` expand at eval-time inside the shell-check.
   Test the cmd manually in your shell before committing — what looks
   right in YAML may eval to something unexpected.

**Authoring-time validation:** adversarial review C9+ should flag any
remaining string-only items AND any `kind: human` without an explicit
justification in the gate's `notes:` field.

---

## §3 Decomposition Rules

**MANDATORY: Avoid Over-Decomposition.** Each task carries ~30-60 minutes of
pipeline overhead (BA → Plan → Review → Implement → Static Analysis → QA →
Commit → Done). Over-decomposed plans pay this overhead many times for small
units of work. Empirical lesson from zero-tech-debt-pipeline: 18 tasks ≈ 10-13
hours of pipeline overhead alone, separate from actual implementation time.

**Merge tasks together when ALL of these apply:**
1. **Shared files** — the tasks touch the same set of files or module
2. **Shared mental context** — understanding one requires understanding the
   other (e.g., two JSON schemas that reference each other's fields)
3. **Same language / same test framework** — no toolchain switch between them
4. **Sequential anyway** — no parallelism possible (same-phase deps)
5. **Combined task would still fit one pipeline run** — under ~1500 lines
   of code, under 4-6 hours of implementation

**Keep tasks separate when ANY of these apply:**
1. **Parallelism possible** — tasks can run concurrently in different worktrees
2. **Different test-target language** — Python adapter vs TypeScript adapter
3. **Different reviewer expertise** — security-heavy vs performance-heavy
4. **Refactoring vs greenfield** — touching existing pipeline vs new module
5. **Different agent specialists needed in pipeline**

**Task size target (BACKLOG #45 / R-A1..R-A5):** ≤150 LOC, ≤3 hours,
≤3 touched files, ≤5 acceptance criteria. **Hard cap:** 300 LOC, 4 hours,
5 touched files, 5 acceptance criteria. Validators in
[`claude/tools/lib/plan_validators.py`](../../tools/lib/plan_validators.py)
(`validate_task_sizing` + `validate_phase_parallelism`) enforce the hard
caps with exit 1; the band between target and cap emits a `WARNING:` line.
The "Examples of legitimate over-decomposition" / "Examples of legitimate
separation" tables below remain authoritative for granularity decisions —
only the numeric envelope changes.

Empirical anchor (full citation chain in
[`claude/skills/plan-producer-patterns/SKILL.md`](../plan-producer-patterns/SKILL.md)
§ Pattern 7): METR (2024) — agent task success drops sharply above ~50
turn-equivalent sub-tasks. SWE-Bench Pro (avg 107 LOC, 4.1 files) — Pass@1
< 45% on changes >100 LOC / >4 files. SWE-EVO (avg 21 files) — Pass@1 ≈
21% on cross-file refactors.

**Examples of legitimate over-decomposition to avoid:**

| Bad decomposition | Better |
|---|---|
| `schema-a` + `schema-b` + `schema-c` as separate tasks when all three are JSON Schemas in the same `schema/` directory | One task `write-schemas` that produces all three + validator in one pipeline run |
| `module-extraction` (extract `foo()`) + `function-rename` (rename `foo` to `bar` everywhere) + `inline-cleanup` (remove old stubs) | One refactor task — splitting this creates merge hell |
| Per-scanner adapter as separate task (ruff-adapter, mypy-adapter, eslint-adapter...) | One task `scanner-normaliser` with all adapters, since they share the schema and test fixture pattern |
| `hook-a` + `hook-b` when both are pre-commit hook additions | One task `pre-commit-hooks` that registers both |
| Two hooks/modules/adapters with structurally identical acceptance criteria differing only in defaults, storage keys, or enum values — e.g. `useFooFilters` + `useBarFilters` with same {state shape, hydration, debounce, fallback} | One task: `createXFactory<...>(config)` + N thin named exports. The factory owns the behavior; wrappers carry only the per-instance config |

**Examples of legitimate separation:**

| Shouldn't merge | Why |
|---|---|
| Python backend task + TypeScript frontend task | Different languages, different test runners, different specialist reviewers |
| Orchestrator task + grinder-pass task that uses it | Contract-before-consumer — orchestrator stability is a prerequisite |
| Mechanical auto-fix pass + coverage grinder pass | Different risk profiles (deterministic vs LLM-authored tests require different QA) |

**Team-lite / team planning hint:** The Solution Architect should explicitly
apply these rules during Step 5T.3 synthesis and challenge any sub-1-hour
task for merge candidacy. The Business Analyst should flag when the same
acceptance criterion is artificially split across tasks.

**Heuristic — Rule of Two on identical AC patterns:** When two tasks have
structurally identical acceptance-criterion templates (same verbs, same
shape, only nouns and values differ), they are evidence duplicates — not
"different domains that may diverge." Lead Developer should challenge this
pattern at 5T.3 synthesis: ship one factory task with thin named exports,
not two parallel tasks. "Avoid premature abstraction" applies to one
instance + speculation about a second; with two concrete instances in the
plan it is not premature, it is overdue.

---

## §4 Autopilot Eligibility and Pipeline Weight

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

When `autopilot: true`, the team also assigns a **pipeline weight**.

**Default to `light`. Escalate to `full` only when at least TWO of the
triggers below apply.** This default-light bias is empirically grounded:
team-review on autopilot-eligible tasks routinely produces SUGGESTION-only
findings (no CRITICAL, no WARNING) at ~$10 cost per phase plus a 60-min
watchdog that frequently expires before the synthesis artifact is written.
Solo review with the right skill bundle (security-checklist, solid-principles,
agentic-code) catches the same issues at a fraction of the cost.

**`pipeline: light`** (default) — BA → Plan → Review → Implement → Static Analysis → QA
- Single-domain change (one of: backend logic, refactor, UI, infra, docs)
- Acceptance criteria are testable by automated tests alone
- Existing patterns to follow (refactors, migrations, config, dependency bumps, CRUD endpoints)
- UI tasks where the operator does post-merge visual verification (the
  /qa pass + automated tests catch behavioral regressions; visual fit
  is the operator's responsibility, not the autopilot's)
- Operational changes with a strong regression-test gate (e.g., byte-equivalent
  golden file diff)
- Small scope — one to three files, one concern

**`pipeline: full`** — BA → Plan → Team Review → Implement → Static Analysis → Manual Test → Team QA
*Use ONLY when at least TWO of these triggers apply:*

| Trigger | Example |
|---|---|
| **Cross-domain concerns** that no single specialist owns | Security + concurrency + protocol semantics in WebSocket bridge; security + write semantics + subprocess invocation in a new control endpoint |
| **First-of-its-kind architectural decision** for the project | First write endpoint in a previously read-only system; first WebSocket; first auth surface |
| **Foundational substrate** that downstream tasks bind against | Security middleware that every later write endpoint depends on; data-model task whose shape is encoded in many consumers |
| **Irreversible at scale** | Schema migrations on populated tables; public API contracts |

A task with **only one** trigger (e.g., "this is a refactor" or "this is a
UI change") is `light`. A task with **two or more** is `full`. This forces
the planner to articulate why team review's marginal cost is justified.

**Anti-patterns — do NOT use `full` for:**
- Routine refactors with regression-test gates ("byte-equivalent" or "golden file" tests catch the cross-cutting risk)
- UI tasks where operator does post-merge verification (post-merge eyes catch what team review would have caught visually anyway)
- Operational scripts and config changes (single-domain, low novelty)
- Tasks whose only "cross-cutting" claim is "it touches multiple files" (that's just normal multi-file work, not a domain crossing)

**Empirical anchor:** A 2026-05 fastapi-routes-port task in this repo ran
team-review at ~$10.49 cost with 60-min watchdog and produced 0 CRITICAL,
0 WARNING, 5 SUGGESTION-adopted, 7 SUGGESTION-deferred. Solo review with
the same skill bundle would have produced equivalent value at a fraction
of the cost. The cost asymmetry is real; default to light.

In the YAML, autopilot tasks get: `autopilot: true` and `pipeline: light` (default) or `pipeline: full`.
The `/start` command shows the user both options — autopilot (terminal script) or normal flow
(Claude Code chat with checkpoints).

**Parallel-execution recommendation (BACKLOG #45 / R-D3):** when multiple
`autopilot: true` tasks share a phase and have no `depends` edge, an
operator MAY launch them in parallel via separate worktrees
(`scripts/worktree.sh`). Empirical guidance (BACKLOG #45 § Parallelism —
MindStudio + Vantor multi-agent saturation): **≤4 concurrent autopilots
per developer machine** is the practical saturation point. Coordination
merges between parallel branches count as **deviations** (logged to
`phase_results.deviations[]`), NOT as features. The Part C parallelism
validator (`validate_phase_parallelism` in
[`claude/tools/lib/plan_validators.py`](../../tools/lib/plan_validators.py))
emits a `WARNING:` if two parallel-eligible tasks overlap in
`where.modify ∪ where.create` — add a `depends` edge to serialise, or
move one task to a different phase. Worktree isolation is the de facto
practice (Cognition / Devin / Composio / Augment Code, 2025) — branches
isolate filesystem state so parallel autopilots can't stomp each other's
WIP.

---

## §5 Dependency Sequencing Principles

**MANDATORY** — Apply these during plan design (Step 5, 5T, or 4U).
Document the sequencing rationale in each phase's `description` field in
`execution-plan.yaml` (legacy 1.x plans use EXECUTION_PLAN.md phase
headings).

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

In `execution-plan.yaml`, each phase's `description` field carries the
one-line sequencing rationale:
```yaml
- id: data-layer
  name: "Phase 2: Data Layer"
  description: "Sequencing rationale: data model + viewer first enables iterative validation of entity relationships before downstream features encode assumptions."
```

Legacy 1.x plans put the same rationale under each `## Phase` heading in
EXECUTION_PLAN.md.

---

## §6 Plan-wide Rules

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
