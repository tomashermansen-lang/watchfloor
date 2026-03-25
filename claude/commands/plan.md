---
description: Architect — design the structural plan for a feature based on its requirements
argument-hint: <feature-name> OR flow <feature-name>
---

# Architect: Plan $ARGUMENTS

Design HOW this feature will be built. Do NOT write code.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Plan approved → continues to `/review flow`
- `amend` → Revise plan → loop back
- `stop` → Pause flow

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

10. **Flag CLAUDE.md / ARCHITECTURE.md update** if system structure changes or new components/services are added.

11. **Summarize** what was designed, what's new vs. modified, main risk.

### Step 12: Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Plan complete: ✅

<Summary — 3-5 sentences>

Files written: docs/INPROGRESS_Feature_<feature>/PLAN.md
Branch: <branch>

On [yes]:
  1. git add docs/INPROGRESS_Feature_<feature>/PLAN.md
     git commit -m "docs(<feature>): architect plan"
  2. STOP — open a new chat and run: /review flow <feature>

On [amend]:
  → Revise PLAN.md based on your feedback, then re-present checkpoint

On [stop]:
  → Pause flow. Resume later in a new chat: /plan flow <feature>

Continue? [yes / amend / stop]
```

**Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Rules

- Do NOT write code or tests.
- Follow all CLAUDE.md architecture rules.
- **NO DEFERRING.** Every component in the plan MUST be fully specified. Do NOT write "deferred to later phase", "future work", "out of scope for now", or similar. If something is needed, plan it. If it's not needed, omit it. There is no middle ground.
- **FULL VISIBILITY.** When presenting the plan, show ALL components, ALL risks, ALL open questions. Never truncate or summarize away details. The user must see the complete picture.
