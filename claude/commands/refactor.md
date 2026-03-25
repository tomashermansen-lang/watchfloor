---
description: Lead Developer — analyze and refactor modules using parallel agents and strict TDD
argument-hint: <module-or-file> [<module-or-file>...] OR flow <feature-name>
---

# Lead Developer: Refactor $ARGUMENTS

Analyze existing modules for SOLID violations, coupling issues, and test coverage gaps — then refactor with strict TDD. Behavior MUST remain unchanged.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Refactoring approved → continues to `/manualtest flow`
- `amend` → Revise plan or continue refactoring
- `stop` → Pause flow

## Domain Knowledge

- solid-principles skill — SOLID verification, architecture rules
- agentic-code skill — Agent navigability checklist
- tdd-workflow skill — TDD cycle, test structure

## Prerequisites

- **Flow mode:** Must be in matching worktree. No `REQUIREMENTS.md` or `PLAN.md` needed — refactoring preserves behavior, not adds it.
- **Standalone:** Works anywhere. Specify module paths as arguments.

## Workflow

### Step 0: Detect Context

Run worktree validation per the flow-mode skill § Worktree Validation.
- **Flow mode** (argument contains `flow`): must be in matching worktree, STOP if not.
- **Standalone mode** (no `flow`): works anywhere, no phase commits.

### Step 1: Identify Targets

Parse arguments to determine target modules. If arguments are vague (e.g., "rag and citations"), resolve to actual file paths:
```bash
# Find the files
ls src/engine/*.py
ls *.py  # for top-level files like rag.py
```

List the target files and confirm with user before proceeding.

### Step 2: Parallel Analysis (spawn 3 agents)

Spawn all three agents simultaneously — they are read-only and independent:

**Agent 1: `code-reviewer`** (Sonnet)
> Analyze these modules for refactoring: `<target-files>`.
> For each module:
> 1. Run SOLID checklist — which principles are violated and where?
> 2. Identify responsibilities (SRP) — does the module do more than one thing?
> 3. Map coupling — what does it import, what imports it?
> 4. Check for hardcoded values
> 5. Check `rag.py` orchestrator rule: engine modules must NOT import `rag.py`
>
> Output: structured findings per module with severity (critical/warning/suggestion).

**Agent 2: `test-explorer`** (Haiku)
> Analyze test coverage for these modules: `<target-files>`.
> For each module:
> 1. Find existing tests in `tests/`
> 2. Map which functions/methods have tests and which don't
> 3. Identify fixtures and patterns in use
> 4. Assess: can we safely refactor with current coverage? What's missing?
>
> Output: coverage map, gaps list, risk assessment for refactoring.

**Agent 3: `Explore`** (dependency mapper)
> Map the dependency graph for these modules: `<target-files>`.
> 1. For each file: list all imports (internal and external)
> 2. For each file: find all other files that import it (`grep` for import statements)
> 3. Map the call graph: which functions call which?
> 4. Identify circular dependencies or tight coupling
> 5. Check `config/settings.yaml` for configuration used by these modules
>
> Output: dependency graph (who imports whom), call flow, configuration keys used.

### Step 3: Synthesize Findings

Run agentic navigability checklist (the agentic-code skill) against target modules using agent findings, then combine all results into `docs/INPROGRESS_Feature_<feature>/REFACTOR_PLAN.md`:

```markdown
<!-- phase: refactor | date: YYYY-MM-DD | branch: <branch> -->
# Refactoring Plan: <module-names>

## Target Modules
- `<file>` — current responsibility (one sentence)

## Analysis Summary

### SOLID Violations
- [file:line] Violation — severity — recommended fix

### Dependency Map
- `module_a` → imports → `module_b`, `module_c`
- `module_d` → imports → `module_a` (reverse dependency)

### Test Coverage
- `<file>`: N/M functions covered — risk level for refactoring
- **Gaps:** list of untested functions that need tests BEFORE refactoring

### Agent Navigability
- pass/fail per check, with specific issues

## Refactoring Strategy

### Phase 1: Safety Net (write missing tests)
- [ ] Test for `<function>` — ensures behavior is preserved
- [ ] Test for `<function>` — ...

### Phase 2: Decomposition
- [ ] Extract `<responsibility>` from `<module>` into `<new-module>`
- [ ] Move `<function>` to `<target>`
- [ ] ...

### Phase 3: Agent Navigability
- [ ] Verify navigable names for all new/moved modules
- [ ] Ensure explicit interfaces (Protocol/ABC, typed dataclasses)
- [ ] Add structured logging for error paths
- [ ] Update CLAUDE.md topology if module structure changed

### Phase 4: Cleanup
- [ ] Update imports across codebase
- [ ] Remove dead code
- [ ] Update `config/settings.yaml` if keys moved
- [ ] Update ARCHITECTURE.md if applicable

## Risks
- <risk> — mitigation
```

### Step 4: Checkpoint — Plan Approval

Present using the Checkpoint Contract from the flow-mode skill:

```
Refactoring plan complete: ✅

<Summary — target modules, findings count, strategy>

Files written: docs/INPROGRESS_Feature_<feature>/REFACTOR_PLAN.md
Branch: <branch>

On [yes]:
  1. git add docs/INPROGRESS_Feature_<feature>/REFACTOR_PLAN.md
     git commit -m "docs(<feature>): refactoring plan"
  2. Proceed to Step 5 (safety net) in this session

On [amend]:
  → Revise REFACTOR_PLAN.md based on your feedback, then re-present checkpoint

On [stop]:
  → Pause flow. Resume later in a new chat: /refactor flow <feature>

Continue? [yes / amend / stop]
```

**Note:** Unlike other checkpoints, plan approval does NOT stop the session — refactoring implementation continues in the same session (Steps 5-10).

### Step 5: Safety Net (write missing tests FIRST)

Before ANY refactoring, write tests for uncovered behavior identified in Step 3.

For each gap:
1. Write test that exercises current behavior
2. Run test — it MUST pass (we're testing existing code)
3. If test fails, the code has a bug — flag it, don't fix during refactoring

```bash
./scripts/run_tests.sh
```

All tests must be green before proceeding. This is the safety net.

### Step 5b: Context Budget Check

Count refactoring tasks in the plan. If >3 tasks:
- Implement ONE task at a time using Step 6
- Run `/checkpoint` after each task (saves progress, frees context)
- If context feels constrained: STOP, run `/checkpoint`, tell user to continue in new session

### Step 6: TDD Refactoring Cycle (per task)

For each item in the refactoring plan:

**a) Announce.** "Refactoring: [task description]. Extracting/moving [what] from [where] to [where]."

**b) Refactor.** Make the structural change.

**c) Run ALL tests.** `./scripts/run_tests.sh` — every test must still pass. Refactoring must NOT change behavior.

**d) SOLID checkpoint.** Use the solid-principles checklist. The whole point is improving this — verify it actually improved.

**e) Agent navigability checkpoint.** Use the agentic-code checklist. For each refactored module verify: navigable names, explicit interfaces (Protocol/ABC, typed dataclasses), traceable flow, observable errors (structured logging), documented topology. A refactoring that improves SOLID but worsens navigability is not done.

**f) Fix imports.** Update all files that imported the moved code.

**g) Run ALL tests again.** Confirm nothing broke from import changes.

**h) Summarize** in 2-3 sentences: what changed, SOLID improvement, navigability improvement.

### Step 7: Final Verification

1. `./scripts/run_tests.sh` — full suite, report results
2. `.venv/bin/python -m compileall src/engine` — no syntax errors
3. Verify no behavior changed (same tests pass, no new failures)
4. Update `docs/INPROGRESS_Feature_<feature>/REFACTOR_PLAN.md` — mark completed tasks
5. Update `CLAUDE.md` if module structure changed
6. Update `docs/ARCHITECTURE.md` if applicable

### Step 8: Start App (flow mode)

```bash
./ui_react/start.sh
```

Tell user app is running for manual verification.

### Step 9: Flow Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Refactoring complete: ✅

<Summary — modules refactored, test results, structural changes>

Files written: <list of changed files>
Branch: <branch>

On [yes]:
  1. git add src/ tests/ config/ ui_react/ docs/
     git commit -m "refactor(<scope>): <description of structural change>"
  2. STOP — open a new chat and run: /manualtest flow <feature>

On [amend]:
  → Continue refactoring — specify what needs more work. Loop back to Step 6.

On [stop]:
  → Pause flow. Resume later in a new chat: /refactor flow <feature>

Continue? [yes / amend / stop]
```

**Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Rules

- **Behavior MUST NOT change.** Refactoring = same inputs → same outputs. If a bug is found, flag it — don't fix it here.
- Follow all CLAUDE.md code standards (TDD, SOLID, no hardcoding).
- Write missing tests BEFORE refactoring (Step 5), not after.
- Run full test suite after EVERY structural change, not just at the end.
- If the refactoring reveals the plan was wrong: STOP and present revised plan.
