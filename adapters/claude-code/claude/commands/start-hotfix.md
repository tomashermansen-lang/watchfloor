---
description: Start a hotfix — create hotfix worktree and branch, then switch to it
argument-hint: <bug-name-slug>
---

# Start Hotfix: $ARGUMENTS

Create a hotfix worktree and branch for a quick bug fix.

## Workflow

### Step 1: Validate Context

**If already in a worktree** (use `bash ~/.claude/tools/start-validate.sh hotfix-<name>` — if `is_main_project` is `false`):
```
⚠️ You are already in a worktree.

To start a hotfix, switch to the main project first:
  File → Open Folder → select the main project folder
```
**STOP.**

**If no bug name provided:** Ask the user for a short bug name slug. **STOP** until they provide one.

### Step 2: Create Worktree

```bash
HOTFIX="<bug-name-slug>"
./scripts/worktree.sh hotfix "$HOTFIX"
```

### Step 3: Guide User

```
✓ Hotfix worktree created
✓ Branch: hotfix/<name>

To continue:
1. In VSCode: File → Open Folder → select the new worktree folder shown above
2. Start a new Claude chat in that window
3. Run: /hotfix <bug-description>
```

**STOP.** Do not run any further commands. The user must switch to the new worktree window.

## Rules

- Only runs from the main project (not from a worktree)
- Does not modify any files beyond what `worktree.sh hotfix` does
- Does not start the fix — that happens after the user switches
