---
description: Manual Tester — verify feature manually, debug issues, produce test log
argument-hint: <feature-name> OR flow <feature-name>
---

# Manual Test: $ARGUMENTS

Verify the feature works in the browser, find bugs, fix them, and produce a test log.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[qa / amend / stop]`
- `qa` → Generate test log, phase commit → `/qa flow`
- `amend` → Continue testing/fixing
- `stop` → Pause flow

## Prerequisites

1. `docs/INPROGRESS_Feature_<feature>/TESTPLAN.md` must exist (from `/implement`).
2. Read `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md` for acceptance criteria.
3. Read `docs/INPROGRESS_Feature_<feature>/DESIGN.md` if exists (for UX expectations).
4. Implementation must be committed (from `/implement` phase commit).

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
- Plan acceptance criteria become additional manual test checklist items

If no plan found: proceed as normal (no change to existing behavior).

## Step 1: Start the App

```bash
./ui_react/start.sh
```

Tell user:
- **URLs:** Shown in terminal output
- **Auto-reload:** Both backend and frontend reload on code changes
- Press `Ctrl+C` to stop

## Step 2: Propose Manual Test Scenarios

Read REQUIREMENTS.md and TESTPLAN.md. Generate 5-10 manual test scenarios covering:

1. **Happy paths** — Each acceptance criterion from requirements
2. **Edge cases** — Empty inputs, boundary values, unusual data
3. **UX flows** — Navigation, loading states, error messages
4. **Regression areas** — Features adjacent to the change that could break
5. **Accessibility** — Keyboard navigation, screen reader, contrast (if UI feature)

Present as a numbered checklist:
```
## Suggested Manual Tests

1. [ ] <scenario description> — verifies <requirement>
2. [ ] <scenario description> — edge case for <behavior>
...
```

Ask user if they want to add or skip any scenarios.

## Step 3: Test and Fix Loop

**User tests in browser and reports findings.**

For each issue reported:

1. **Reproduce.** Understand the exact steps and expected vs. actual behavior.
2. **Write a failing test** that captures the bug.
3. **Fix** with minimum code change.
4. **Run `./scripts/run_tests.sh`** — all tests must pass.
5. **Lint check on changed files.** Run ruff/mypy (Python) or eslint/tsc
   (TypeScript) on the files you just modified. Fix any findings before
   continuing — don't let manual test fixes bypass static analysis.
6. **Confirm fix** — tell user to re-test in browser.

For each passing scenario:
- Mark it as checked in the scenario list.

**Use `/checkpoint` for saving progress on large features** — creates a tagged commit without leaving the manual test phase.

Repeat until user says "ready", "looks good", or "qa".

## Step 4: Generate Manual Test Log

When user is ready to proceed, generate `docs/INPROGRESS_Feature_<feature>/MANUAL_TEST_LOG.md` based on the conversation:

```markdown
<!-- phase: manualtest | date: YYYY-MM-DD | branch: <branch> -->
# Manual Test Log: <feature>

**Date:** <date>
**Tester:** <user> + Claude

## Test Scenarios

| # | Scenario | Result | Notes |
|---|----------|--------|-------|
| 1 | <description> | PASS/FAIL/FIXED | <details if fixed> |
| 2 | ... | ... | ... |

## Bugs Found and Fixed

### Bug 1: <title>
- **Steps to reproduce:** ...
- **Expected:** ...
- **Actual:** ...
- **Fix:** <commit ref or description>
- **Test added:** `tests/test_<module>.py::test_<name>`

## Summary

- **Scenarios tested:** X
- **Passed first try:** X
- **Bugs found and fixed:** X
- **Skipped:** X (with reasons)
```

## Step 5: Flow Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Manual testing complete: ✅ APPROVED

- Scenarios tested: X/Y
- Bugs found and fixed: Z
- All tests passing: ✅

Files written: docs/INPROGRESS_Feature_<feature>/MANUAL_TEST_LOG.md
Branch: <branch>

On [qa]:
  1. git add src/ tests/ config/ ui_react/ docs/
     git commit -m "docs(<feature>): manual test log"
  2. STOP — open a new chat and run: /qa flow <feature>

On [amend]:
  → Continue testing/fixing, then re-present checkpoint

On [stop]:
  → Pause flow. Resume later in a new chat: /manualtest flow <feature>

Continue? [qa / amend / stop]
```

**Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Bypass

User can skip manual testing by running `/qa flow` directly. This is appropriate for:
- Backend-only changes with no UI impact
- Pure refactoring with comprehensive automated tests
- Trivial changes where manual verification adds no value

## Rules

- NEVER skip to QA if user reports an unfixed issue
- NEVER mark a scenario as PASS without user confirmation
- Fix bugs using TDD — write test FIRST, then fix
- Run `./scripts/run_tests.sh` after every fix
- The test log must reflect what actually happened in the conversation
