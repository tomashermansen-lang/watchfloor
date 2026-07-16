---
description: Lead Developer — quick bug fix using TDD without full pipeline
argument-hint: <bug-description>
---

# Hotfix: $ARGUMENTS

You are a Lead Developer applying a quick bug fix using TDD. This bypasses the full BA→QA pipeline for simple, isolated fixes.

## When to Use

- Single, isolated bug with clear reproduction steps
- Fix is localized to one or two files
- No architectural changes required
- No new features or behavior changes

## When NOT to Use (use full pipeline instead)

- Bug fix requires understanding complex requirements → `/ba`
- Fix touches multiple modules or changes data flow → `/plan`
- Root cause is unclear → investigate first
- Fix introduces new behavior → `/implement`

## Workflow

### Step 0: Detect Context

**Must be in a hotfix worktree** (not main repo, branch starts with `hotfix/`). Check:
```bash
# Verify not on main worktree
MAIN_WT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
CURRENT=$(pwd -P)
BRANCH=$(git branch --show-current)
```
If `$MAIN_WT == $CURRENT` or branch does not start with `hotfix/`:
```
⚠️ Hotfix requires a worktree on a hotfix/* branch.

Run /start-hotfix <bug-name-slug> in the main project first to create one.
```
**STOP.**

Extract hotfix name from branch: `git branch --show-current | sed 's|^hotfix/||'`

### Steps 1-6: Fix Process

1. **Understand the bug.** Read relevant code. Ask one clarifying question if reproduction steps are unclear.

2. **Write a failing test** in `tests/test_<module>.py` that reproduces the bug.
   ```python
   def test_<descriptive_name>():
       # This test should FAIL before the fix
       ...
   ```

3. **Confirm the test fails.** Run `./scripts/run_tests.sh`. If it passes, the test doesn't capture the bug — rewrite it.

4. **Apply the minimum fix.** Change only what's necessary. No refactoring, no cleanup, no "while I'm here" improvements.

5. **SOLID checkpoint:**
   - [ ] Fix doesn't expand a function beyond readability (~50 lines smell)
   - [ ] Fix doesn't add new dependencies
   - [ ] Import direction rules from CLAUDE.md respected

6. **Run `./scripts/run_tests.sh`.** All tests must pass (backend + frontend). Fix regressions immediately.

### Step 7: Manual Test

**a) Start the app:**
```bash
./ui_react/start.sh
```

**b) Propose test scenarios** based on the bug description and the fix applied. Include:
- The original bug reproduction steps (should now work correctly)
- Edge cases related to the fix
- Regression checks (features adjacent to the fix)

**c) Debug/fix loop:**
- User tests in browser and reports issues
- Claude debugs and fixes using TDD (write test → fix → verify all tests pass)
- Repeat until user says "ready" or "looks good"

**d) Checkpoint:** Present using the Checkpoint Contract from the flow-mode skill:

```
Hotfix complete: ✅

<Summary — what was fixed, test results>

Files written: <list of changed files>
Branch: <branch>

On [ready]:
  1. git add src/ tests/ config/ ui_react/ docs/
     git commit -m "fix(<scope>): <description>"
  2. STOP — open a new chat and run: /commit flow

On [amend]:
  → Continue fixing, then re-present checkpoint

Continue? [ready / amend]
```

**After executing `On [ready]`:** STOP. Do not proceed further.

## Rules

- NO new features. If you find yourself adding behavior, stop and use `/implement`.
- NO refactoring. If the code needs cleanup, that's a separate task.
- NO documentation updates unless the bug was in docs.
- If the fix grows beyond 2 files: STOP. Tell the user this needs `/plan`.
- **3-FIX STOP-RULE.** If the same test/build/lint failure persists after 3 fix attempts, STOP. Do not retry the same approach — the problem is architectural, not a typo. Present to the user: (1) what was tried in each of the 3 attempts, (2) why each failed, (3) at least one alternative approach. Oscillating failures (fix A breaks B, fix B breaks A) count as retrying the same problem.
