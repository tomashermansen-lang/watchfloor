---
description: Lead Developer — implement a feature using strict TDD after plan approval
argument-hint: <feature-name> OR flow <feature-name>
---

# Lead Developer: Implement $ARGUMENTS

Implement using strict Test-Driven Development.

## Flow Mode

See the flow-mode skill for protocol.

**Verifies feature branch** (already created by `/ba flow` or `/plan flow`)

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Implementation complete → `/static-analysis flow`
- `amend` → Continue implementing (more components needed)
- `stop` → Pause flow

## Test Plan Only Mode (`--step testplan`)

If `$ARGUMENTS` contains `--step testplan`:
1. Run Step 0 (verify branch), Step 0.5 (plan detection), and Step 1 (create test plan)
2. Commit TESTPLAN.md
3. **STOP.** Do not proceed to Step 2 (TDD cycle).

This mode is used by `autopilot.sh` to gate test plan creation before
implementation. The autopilot verifies TESTPLAN.md exists before starting
the implementation phase.

## Domain Knowledge

- tdd-workflow skill — TDD cycle, test structure, mocking
- solid-principles skill — SOLID verification per component

## Prerequisites

1. `docs/INPROGRESS_Feature_<feature>/PLAN.md` must exist and be reviewed (APPROVED).
2. Read `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md` for acceptance criteria.
3. Read `docs/INPROGRESS_Feature_<feature>/DESIGN.md` if exists.

## Step 0: Verify Feature Branch (flow mode)

```bash
git branch --show-current  # Must be on feature/<feature-name>
git status                 # Must be clean
```

**If NOT on feature branch:** STOP. Branch should exist from `/ba flow` or `/plan flow`.
**If uncommitted changes:** STOP. Ask user to commit or stash first.

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
- Plan acceptance criteria become additional TDD test targets
- Use project plan context to ensure implementation aligns with overall architecture

If no plan found: proceed as normal (no change to existing behavior).

## Step 1: Create Test Plan

Delegate to `test-explorer` subagent (Haiku, read-only) to analyze existing test patterns, fixtures, and coverage. Use its findings to write `docs/INPROGRESS_Feature_<feature>/TESTPLAN.md` — every testable behavior, grouped by component, mapped to requirements.

**Phase commit** (flow mode):
```bash
git add docs/INPROGRESS_Feature_<feature>/TESTPLAN.md
git commit -m "docs(<feature>): add test plan"
```

**If `--step testplan` mode:** STOP HERE. Do not proceed to Step 1b or Step 2.
The autopilot will verify the artifact and start a fresh session for implementation.

## Step 1b: Context Budget Check

Count components in TESTPLAN.md. If >3 components:
- Implement ONE component at a time using Step 2
- Run `/checkpoint` after each component (saves progress, frees context)
- If context feels constrained (repeated instructions being forgotten):
  STOP, run `/checkpoint`, tell user to start new session and continue with the next component

## Step 2: TDD Cycle (per component)

**a) Announce.** "Implementing [component] in `[file path]`. It does [one sentence]."

**b) Write test FIRST** in `tests/test_<module>.py`.

**c) Verify test fails.** `./scripts/run_tests.sh`. If it passes, test is wrong.

**d) Write minimum implementation.** Only enough to pass.

**e) SOLID checkpoint.** Use the solid-principles checklist. Refactor NOW if any fail.

**f) Run ALL tests.** Fix regressions immediately.

**g) Refactor** if code can be simplified while tests stay green.

**h) Summarize** in 2-3 sentences.

## Step 3: Final Verification

1. `./scripts/run_tests.sh` — report results
2. Run syntax/type checks appropriate to the project's language and tooling
3. Update `docs/INPROGRESS_Feature_<feature>/TESTPLAN.md` with final status
4. Update `README.md` if user-facing changes

## Step 4: Completion Checklist

Before presenting checkpoint, verify:
- [ ] ALL components from PLAN.md are implemented (none skipped, none deferred)
- [ ] ALL acceptance criteria from REQUIREMENTS.md have tests
- [ ] ALL tests pass (`./scripts/run_tests.sh`)
- [ ] NO TODOs, FIXMEs, or "implement later" in new code
- [ ] NO hardcoded values (use config/)

**Show the COMPLETE checklist to the user with pass/fail status for each item.**

## Step 5: Inline Lint + Type Checking

After all components pass TDD and the completion checklist is green, run
linters and type checkers inline — don't defer to `/static-analysis`.

### 5.1: Auto-Fix (lint + format)

Detect the Python runner per static-analysis-conventions.md § Tool Runner Detection.

```bash
# Python (if ruff available)
$RUN ruff check --fix .
$RUN ruff format .

# TypeScript (if TS files changed on this branch)
cd <frontend-dir> && npx eslint --fix .
```

If any files were modified by auto-fix:
```bash
git add -u
git commit -m "fix(<feature>): lint auto-fixes"
```
Skip the commit if no files changed.

### 5.2: Type Checking

```bash
# Python
$RUN mypy src/ --no-error-summary 2>&1 || true

# TypeScript (if TS project)
cd <frontend-dir> && npx tsc --noEmit 2>&1 || true
```

### 5.3: Fix Type Errors

Fix all type errors in files changed on this branch (`git diff main --name-only`).
Pre-existing errors in untouched files are logged but not fixed.

**Loop guard:** Maximum 3 fix passes. After each pass:
```
Type check pass <N>/3: <CLEAN | NEEDS FIX>
  Fixed: <count>  |  Remaining: <count>
```

After fixing, re-run ALL tests to ensure fixes didn't break anything.

If type errors were fixed, commit:
```bash
git add -u
git commit -m "fix(<feature>): resolve type checker findings"
```
Skip if no files changed. Never combine auto-fixes and type fixes into one commit.

### 5.4: Skip Conditions

- If ruff/eslint is not available: skip with a warning, don't fail
- If mypy/tsc is not available: skip with a warning, don't fail
- If zero linters AND zero type checkers ran: log a warning in the checkpoint
  summary but don't block — the `/static-analysis` phase will catch this via
  its tool coverage gate

## Step 6: Start App (flow mode)

```bash
./ui_react/start.sh
```

Tell user:
- **URLs:** Shown in terminal output
- **Auto-reload:** Both backend and frontend reload on code changes
- Press `Ctrl+C` to stop
- Ready for manual testing

## Step 7: Flow Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Implementation complete: ✅

<Summary — branch, components implemented, test results, app URL>

Files written: <list of new/modified source files, test files, docs>
Branch: <branch>

On [yes]:
  1. git add src/ tests/ config/ ui_react/ docs/
     git commit -m "feat(<scope>): implement <feature>"
  2. STOP — open a new chat and run: /static-analysis flow <feature>

On [amend]:
  → Continue implementing — specify what needs more work. Loop back to Step 2.

On [stop]:
  → Pause flow. Resume later in a new chat: /implement flow <feature>

Continue? [yes / amend / stop]
```

**Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Rules

- Follow all CLAUDE.md code standards (TDD, SOLID, no hardcoding).
- If plan is wrong mid-implementation: STOP and tell user.
- **NO DEFERRING.** Implement EVERYTHING in the plan. Do NOT leave TODOs, stubs, partial implementations, or "will be completed in next phase" comments. If a component is in the plan, it gets implemented NOW with passing tests. If it can't be implemented, STOP and explain why — don't silently skip it.
- **FULL VISIBILITY.** At checkpoint, show the COMPLETE list of: all components (implemented or not), all test results, all requirements mapped to tests. Never show "X of Y implemented" without listing what's missing. The user must see everything.
- **3-FIX STOP-RULE.** If the same test/build/lint failure persists after 3 fix attempts, STOP. Do not retry the same approach — the problem is architectural, not a typo. Present to the user: (1) what was tried in each of the 3 attempts, (2) why each failed, (3) at least one alternative approach. Oscillating failures (fix A breaks B, fix B breaks A) count as retrying the same problem.
- **EVIDENCE IN THIS MESSAGE.** If you have not run the verification command in THIS message, you cannot claim it passes. Show actual output (or pass/fail summary for long output). Banned completion phrases: "should work", "probably passes", "seems to", "likely works", "I believe it passes".
