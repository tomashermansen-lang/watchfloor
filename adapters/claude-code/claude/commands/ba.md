---
description: Business Analyst — define requirements and acceptance criteria for a feature
argument-hint: <feature-name> OR flow <feature-name>
---

# Business Analyst: $ARGUMENTS

Define WHAT this feature must do before anyone designs or builds it.

## Domain Knowledge

Look for project-specific domain skills in `.claude/skills/` (e.g., `*-domain`, `*-conventions`).
Read any that exist — they provide domain terminology, constraints, and principles.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[ux / plan / amend / stop]`
- `ux` → Feature has UI changes → continues to `/ux flow`
- `plan` → Backend-only feature → continues to `/plan flow`
- `amend` → Revise requirements → loop back
- `stop` → Pause flow

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

- If found: Read the YAML file, then follow the plan-detection skill
  § Project Orientation for task matching and context loading.
- If not found: proceed standalone (no warnings, no behavior change).

If a plan is loaded and a matching task is found:
- Run auto-orient (Step 0.6) to understand full project scope and completed work
- **Run predecessor context loading (Step 0.8)** per the plan-detection
  skill § Predecessor Context Loading:
  - **Schema 2.0 (preferred):** invoke
    `python3 adapters/claude-code/claude/tools/predecessor-context.py
    --plan <execution-plan.yaml> --task <task-id> --phase ba`
    to get a compact decision-shadow block per completed dependency
    (constraints + rejected + contract; ~10-30 lines per dep). This
    replaces the old practice of reading full REQUIREMENTS.md +
    QA_REPORT.md + DESIGN.md per dependency (per backlog #64 + the
    Chroma "Context Rot" + ETH AGENTS.md research showing verbose
    repo context reduces task success and inflates cost ~20%+).
  - **Fallback / Schema 1.x:** if the helper's output for a dependency
    shows the fallback marker ("no codebase_snapshot/predecessor_context
    yet"), read that dep's REQUIREMENTS.md + QA_REPORT.md + DESIGN.md
    directly. Incremental migration works because the helper signals
    per-dep which path to take.
- Synthesize what was promised vs what was actually delivered. Use this
  to ensure new requirements build on (not conflict with) established
  interfaces, and account for any drift from original specs.
- Plan acceptance criteria augment the requirements output — include them in
  REQUIREMENTS.md alongside feature-specific criteria
- Use project plan vision/strategy to ensure requirements align with overall project goals

If no plan found: proceed as normal (no change to existing behavior).

### Step 0.9: Scope Self-Validation (MANDATORY)

Before writing REQUIREMENTS.md, internally verify scope coverage:

1. List every input source (user prompt, plan context, existing docs)
2. Count all requirements/topics you intend to cover
3. Verify the count matches the source material — if the user mentioned N items, you must cover N items
4. Check for operational scope: error handling, timeouts, policies, edge cases — not just the happy path / UI surface

If anything is excluded, **STOP and ask the user why** before proceeding. Do not silently narrow scope.

### Steps 1-10: Requirements Analysis

1. **Read context.** Scan source code, docs, and config files. Understand architecture from CLAUDE.md.

2. **Research** (for non-trivial features). Follow Research Protocol in the flow-mode skill.

3. **Ask one clarifying question** if the feature is vague.

4. **Extract requirements.** Testable statements: "The system shall [verb] [object] when [condition]." Include error/refusal scenarios. Flag requirements that could lead to hardcoding — all configurable values must use config files, not magic numbers.

5. **Write acceptance scenarios.** GIVEN/WHEN/THEN format.

6. **Identify edge cases.** At least 3 per major requirement: error states, boundaries, fail-closed case.

7. **SOLID check.** Can each requirement trace to one module? Can new requirements be added without rewriting?

8. **Write `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md`** — First line: `<!-- phase: ba | date: YYYY-MM-DD | branch: <branch> -->`. Sections: Feature Summary, Research Findings, Requirements, Acceptance Scenarios, Edge Cases, Open Questions.

9. **Identify eval cases** for `data/evals/`.

10. **Summarize** in 3-5 sentences.

### Step 11: Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Requirements complete: ✅

<Summary — 3-5 sentences>

Files written: docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md
Branch: <branch>

On [ux]:
  1. git add docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md
     git commit -m "docs(<feature>): define requirements"
  2. STOP — open a new chat and run: /ux flow <feature>

On [plan]:
  1. git add docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md
     git commit -m "docs(<feature>): define requirements"
  2. STOP — open a new chat and run: /plan flow <feature>

On [amend]:
  → Revise REQUIREMENTS.md based on your feedback, then re-present checkpoint

On [stop]:
  → Pause flow. Resume later in a new chat: /ba flow <feature>

Continue? [ux / plan / amend / stop]
```

**Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Rules

- **NO DEFERRING.** Every requirement must be complete and self-contained. Do NOT write "to be refined later", "future enhancement", or "out of scope for MVP". If it's needed, specify it fully. If it's not needed, don't mention it.
- **FULL VISIBILITY.** Show ALL requirements, ALL edge cases, ALL open questions to the user. Never truncate or summarize. The user must see the complete list to make informed decisions.
- **NO BACKLOG DUMPING.** Do not create a "backlog" or "nice-to-have" section as a way to defer work. Requirements are either in scope (fully specified) or not mentioned.
