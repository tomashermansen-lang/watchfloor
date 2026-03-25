---
description: Sync current worktree with latest main (pull merged features into your branch)
disable-model-invocation: true
---

# Sync with Main

Pull the latest changes from main into the current feature branch.

Use this when another feature was merged to main and you want those changes in your active worktree.

## Workflow

### Step 1: Validate context

- Confirm we are in a worktree (compare `pwd -P` against first entry in `git worktree list --porcelain` — if equal, we're on main). If not in worktree → STOP:
  ```
  ⚠️ Not in a worktree. Sync is only needed in feature worktrees.
  ```
- Get current branch name: `git branch --show-current`
- Check for uncommitted changes: `git status --porcelain`
- If dirty working tree → STOP:
  ```
  ⚠️ You have uncommitted changes. Commit or stash them before syncing.
  ```

### Step 2: Sync

```bash
git fetch origin main
git merge origin/main --no-edit
```

### Step 3: Handle result

**If merge succeeds (no conflicts):**
1. Run `./scripts/run_tests.sh --backend -q`
2. Report:
   ```
   ✓ Synced <branch> with main
   ✓ Tests pass

   Commits pulled in:
   <list new commits from main>
   ```

**If merge conflicts:**
1. List conflicting files
2. Help resolve each conflict
3. Run `./scripts/run_tests.sh --backend -q` after resolution
4. Commit the merge

## Rules

- NEVER sync if working tree is dirty
- ALWAYS run tests after sync
- Use merge (not rebase) to preserve flow commit history
