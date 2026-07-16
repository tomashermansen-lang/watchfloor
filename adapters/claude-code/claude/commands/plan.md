---
description: Architect — design the structural plan and test plan for a feature based on its requirements
argument-hint: <feature-name> OR flow <feature-name>
---

# Architect: Plan $ARGUMENTS

Design HOW this feature will be built **and** what scenarios verify it. Do NOT write code.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Plan + test plan approved → continues to `/review flow`
- `amend` → Revise plan or test plan → loop back
- `stop` → Pause flow

## --step Modes (autopilot only)

The autopilot pipeline gates each artifact independently. When `$ARGUMENTS`
contains a `--step` flag, only the matching artifact is produced and
committed:

- `--step plan` — write PLAN.md only, commit, STOP. Skip TESTPLAN generation.
- `--step testplan` — verify PLAN.md exists, then write TESTPLAN.md only,
  commit, STOP. Skip the architecture sections.

Without `--step`, the full flow runs: PLAN.md → TESTPLAN.md → checkpoint.
Each artifact is committed separately so /review can review both.

## Domain Knowledge

- solid-principles skill — SOLID verification, architecture rules
- agentic-code skill — Agent navigability checklist

## Prerequisites

- **Feature work:** Read `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md` and `docs/INPROGRESS_Feature_<feature>/DESIGN.md` (if exists).
- **Technical work:** No requirements needed — the technical goal is the requirement.

## Workflow

### Step 0: Detect Context

Run worktree validation per the flow-mode skill § Worktree Validation.
- **Flow mode** (argument contains `flow`): must be in matching worktree, STOP if not.
- **Standalone mode** (no `flow`): works anywhere, no phase commits.

### Step 0.5: Plan Detection & Orientation

**MANDATORY — run this glob BEFORE any other file reads:**
```
Glob pattern: docs/INPROGRESS_Plan_*/execution-plan.yaml
```
If found: Read the YAML, then follow the plan-detection skill
§ Project Orientation for task matching and context loading.
If not found: proceed standalone (no warnings, no behavior change).

If a plan is loaded and a matching task is found:
- Run auto-orient (Step 0.6) to understand full project scope and completed work
- Plan acceptance criteria become additional architecture targets
- Use project plan vision/strategy to ensure the technical plan aligns with overall project direction

If no plan found: proceed as normal (no change to existing behavior).

### Step 0.8: Scope Self-Validation (MANDATORY)

After reading REQUIREMENTS.md but before writing the plan, internally verify scope coverage:

1. Count all requirements in REQUIREMENTS.md (e.g., R1-R42 = 42 requirements)
2. Verify your planned component list covers every single one — map each requirement to at least one component
3. If any requirement has no component: add one. Do not proceed with gaps.
4. Check for operational scope: error handling, timeouts, policies, configuration — not just the UI surface

If anything from REQUIREMENTS.md would be excluded, **STOP and ask the user why** before proceeding. Do not silently narrow scope.

### Steps 1-10: Design Process

1. **Read context.** Source code, config files, architecture docs. Understand architecture rules from CLAUDE.md.

2. **Research** (for non-trivial design). Follow Research Protocol in the flow-mode skill.

3. **Identify affected components.** List every module the feature touches.

4. **Design solution.** Per component: file path, responsibility (one sentence), dependencies (abstractions), dependents, orchestration.

5. **SOLID verification.** Use the solid-principles checklist. Revise if any fail.

6. **Agent navigability.** Use the agentic-code checklist. For each component: Is the module name self-describing? Are interfaces explicit (Protocol/ABC, typed dataclasses)? Is structured logging planned for error paths? Will CLAUDE.md need updating to describe new services/interactions?

7. **TDD readiness.** Can each component be tested in isolation? What abstraction is missing if not?

8. **Configuration.** New `config/settings.yaml` entries? Specify keys and defaults. NO HARDCODING.

9. **Write `docs/INPROGRESS_Feature_<feature>/PLAN.md`** — First line: `<!-- phase: plan | date: YYYY-MM-DD | branch: <branch> -->`. Sections: Summary, Research, Components, Data Flow, SOLID Results, Agent Navigability, TDD Assessment, Config Changes, Risks.

   For features inside a 2.0 host plan (`schema_version: 2.0.0` host
   `execution-plan.yaml`), structured field population
   (`task.what`, `task.why`, `task.where`, `task.acceptance`,
   `task.constraints`, `task.estimate`, `task.manualtest_scenarios`)
   goes into the host plan's task subtree directly, NOT into PLAN.md.
   The free-form architecture sections (Components, Data Flow, SOLID
   Results, etc.) still live in PLAN.md.

9a. **Anti-pattern self-review (Step 4.5).** If the plan touches structured
    fields in the host `execution-plan.yaml`:
    - Read `claude/skills/plan-producer-patterns/SKILL.md` verbatim.
    - For each touched task, internally check the five anti-patterns
      (Stub strings, Aspirational success_criteria, Glob where.modify,
      Tautological acceptance, Dangling cross-references) — see
      "Stub strings" / "Aspirational success_criteria" /
      "Glob where.modify" / "Tautological acceptance" /
      "Dangling cross-references" in the skill.
    - Run `python3 claude/tools/lib/plan_self_review.py <host-plan>` and
      iterate up to **max 2 retries** per pattern. After 2 retries,
      append `quality_warnings[]` to the host plan and proceed.

10. **Flag CLAUDE.md / ARCHITECTURE.md update** if system structure changes or new components/services are added.

11. **Summarize** what was designed, what's new vs. modified, main risk.

**If `--step plan` mode:** STOP HERE — commit PLAN.md only, skip Step 12 (test plan generation). The autopilot will start a fresh session for `--step testplan`.

### Step 12: Test Plan

Skip this step if `--step plan` was passed. Run when in default mode or when `--step testplan` was passed (in which case PLAN.md must already exist and Steps 1-11 are skipped — only this step runs).

Delegate to `test-explorer` subagent (Haiku, read-only) to analyse existing
test patterns, fixtures, and coverage relevant to the components in PLAN.md.
Use its findings to write `docs/INPROGRESS_Feature_<feature>/TESTPLAN.md` —
every testable behaviour, grouped by component, mapped to requirements.

The testplan must include:

- **One row per testable behaviour**, with columns: scenario, requirement
  ID, component (matches PLAN.md), test type (unit/integration/manual),
  fixture/mock notes.
- **Coverage for negative paths**: error handling, validation rejection,
  empty inputs, boundary cases — not just the golden path.
- **Coverage for cross-cutting concerns**: auth, logging, observability,
  feature flags — for any component that touches them.
- **Manual test scenarios** if a UI surface exists (mapped to
  `task.manualtest_scenarios` in the host execution-plan.yaml when on a
  2.0 schema plan).

Tests are NOT written here — only scenarios. Implementation comes later
in `/implement` Step 2 (TDD cycle).

**Phase commit** (flow mode):
```bash
git add docs/INPROGRESS_Feature_<feature>/TESTPLAN.md
git commit -m "docs(<feature>): add test plan"
```

**If `--step testplan` mode:** STOP HERE.

### Step 13: Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Plan + test plan complete: ✅

<Summary — 3-5 sentences covering both architecture and test scenarios>

Files written:
  docs/INPROGRESS_Feature_<feature>/PLAN.md
  docs/INPROGRESS_Feature_<feature>/TESTPLAN.md
Branch: <branch>

On [yes]:
  1. git add docs/INPROGRESS_Feature_<feature>/PLAN.md
     git commit -m "docs(<feature>): architect plan"
  2. git add docs/INPROGRESS_Feature_<feature>/TESTPLAN.md
     git commit -m "docs(<feature>): add test plan"
  3. STOP — open a new chat and run: /review flow <feature>

On [amend]:
  → Revise PLAN.md or TESTPLAN.md based on your feedback, then re-present checkpoint

On [stop]:
  → Pause flow. Resume later in a new chat: /plan flow <feature>

Continue? [yes / amend / stop]
```

**Standalone mode:** Same format but omit phase commits and say "run:" instead of "open a new chat and run:".

## Rules

- Do NOT write code or tests.
- **NO TEST OR LINT RUNS.** This is a doc-writing phase. Do not run
  pytest, vitest, ruff, mypy, eslint, tsc, shellcheck, or any other
  test suite, linter, or type-checker. Behavioral verification is
  `/implement`'s job (Step 5 gates tests + lint + type-check inline);
  the `.tests-green-sha` marker is the downstream trust mechanism. If
  you find yourself wanting to "verify" or "double-check" something
  here, write the corresponding scenario into TESTPLAN.md instead —
  that's how this phase contributes to verification.
- Follow all CLAUDE.md architecture rules.
- **NO DEFERRING.** Every component in the plan MUST be fully specified. Do NOT write "deferred to later phase", "future work", "out of scope for now", or similar. If something is needed, plan it. If it's not needed, omit it. There is no middle ground.
- **FULL VISIBILITY.** When presenting the plan, show ALL components, ALL risks, ALL open questions. Never truncate or summarize away details. The user must see the complete picture.
