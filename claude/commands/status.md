---
description: Status — show current flow position and next steps
---

# Status: Where Am I?

Show current workflow state based on existing docs and git branch.

## Workflow

1. **Check git branch.**
   ```bash
   git branch --show-current
   ```

2. **Check for flow docs.**
   ```bash
   ls docs/*/REQUIREMENTS.md docs/*/DESIGN.md docs/*/PLAN.md docs/*/TESTPLAN.md docs/*/MANUAL_TEST_LOG.md docs/*/QA_REPORT.md 2>/dev/null
   ```

3. **Determine position** using Phase Detection table in the flow-mode skill.

4. **Check for uncommitted changes.**
   ```bash
   git status --short
   ```

5. **Report:**
   ```
   ## Current Status

   **Branch:** feature/<name> (or main)
   **Phase:** <phase name>
   **Docs:** <list of existing docs>

   **Next step:** /<command> flow <feature>

   **Uncommitted changes:** <yes/no>
   ```

## In Main Project

If on `main` branch with no feature docs:
```
You're in the main project. To start a new feature:

  /ba flow <feature-name>

To continue an existing feature, open its worktree:
  File → Open Folder → select the feature worktree folder
```

## Rules

- Read-only — does not modify anything
- Works in both main project and worktrees
