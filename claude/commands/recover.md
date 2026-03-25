---
description: Recover — diagnose and fix common workflow problems
argument-hint: [scenario] (optional: merge-conflict, stale-worktree, mid-flow, stash, failed-commit-flow)
disable-model-invocation: true
---

# Recover: $ARGUMENTS

Diagnose the current situation and guide through recovery.

## Step 1: Auto-Diagnose (if no scenario given)

Run these checks and report findings:

```bash
git status
git branch --show-current
git worktree list --porcelain
git stash list
```

**Check for:**
1. **Merge conflict** — `git status` shows "both modified" or "Unmerged paths"
2. **Stale worktree** — `git worktree list` shows paths that don't exist on disk
3. **Mid-flow interruption** — worktree exists but flow is incomplete (check which docs exist)
4. **Dirty working tree** — uncommitted changes blocking operations
5. **Stash confusion** — stash entries from multiple worktrees interleaved

Report diagnosis, then proceed to the matching scenario below.

## Scenario: Merge Conflict

**Symptoms:** `git status` shows "both modified" files after `/sync` or merge.

**Recovery steps:**

1. **List conflicted files:**
   ```bash
   git diff --name-only --diff-filter=U
   ```

2. **For each conflicted file**, read it and show the conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).

3. **Ask user** which version to keep for each conflict:
   - `ours` — keep current branch version
   - `theirs` — keep incoming (main) version
   - `manual` — present both, let user decide line by line

4. **After all conflicts resolved:**
   ```bash
   git add <resolved-files>
   git commit -m "fix(<scope>): resolve merge conflict from main"
   ```

5. **Verify:** `./scripts/run_tests.sh --fast`

## Scenario: Stale Worktree

**Symptoms:** `git worktree list` shows a path that doesn't exist on disk, or `worktree.sh` commands fail.

**Recovery steps:**

1. **Identify stale entries:**
   ```bash
   git worktree list --porcelain
   ```
   Check each path — does the directory exist?

2. **Prune stale entries:**
   ```bash
   git worktree prune
   ```

3. **Check for orphaned branches:** If the worktree had unmerged commits:
   ```bash
   git log main..<branch-name> --oneline
   ```
   Show user what would be lost.

4. **Ask user:** Delete orphaned branch or keep for later?
   - Keep: `git branch <branch-name>` (already exists, just note it)
   - Delete: `git branch -d <branch-name>` (safe — refuses if unmerged)

5. **Fix docs prefix** if needed:
   - If docs dir is still `INPROGRESS_Feature_<feature>` but worktree is gone, ask: revert to `PENDING_Feature_` or mark `DONE_Feature_`?

## Scenario: Mid-Flow Interruption

**Symptoms:** Worktree exists, feature branch has some phase commits, but flow was interrupted (session crash, context overflow, `stop`).

**Recovery steps:**

1. **Determine current phase** using Phase Detection table in the flow-mode skill:
   ```bash
   ls docs/*<feature>/
   ```

2. **Check for uncommitted work:**
   ```bash
   git status
   git diff --stat
   ```

3. **Present recovery options:**
   - **Resume:** Run the next command from the table above
   - **Rollback to checkpoint:** `git log --oneline` — find last phase commit, reset to it
   - **Abandon:** `./scripts/worktree.sh remove <feature>` (warns about unmerged commits)

4. **Tell user** the exact command to run next.

## Scenario: Stash Confusion

**Symptoms:** `git stash pop` restores wrong changes, or stash entries from multiple worktrees are interleaved.

**Recovery steps:**

1. **List all stash entries with context:**
   ```bash
   git stash list
   ```

2. **Show which branch each stash was created on** (visible in stash description).

3. **Identify the correct stash** for the current worktree/branch.

4. **Apply the correct one:**
   ```bash
   git stash apply stash@{N}  # Apply without removing from stack
   ```

5. **If wrong stash was already popped:**
   - Changes are in working tree — `git diff` to see them
   - If unwanted: `git checkout -- .` to discard (CONFIRM with user first)
   - If the right stash entry was lost: `git stash list` — it may still be there if `apply` was used instead of `pop`

6. **Clean up:** Drop applied stash entries one at a time:
   ```bash
   git stash drop stash@{N}
   ```

**Prevention reminder:** Always `git stash pop` immediately per worktree. Never leave stashes sitting across worktrees.

## Scenario: Dirty Working Tree

**Symptoms:** Commands refuse to run because of uncommitted changes.

**Recovery steps:**

1. **Show what's dirty:**
   ```bash
   git status
   git diff --stat
   ```

2. **Ask user:**
   - **Commit:** Stage and commit the changes (suggest conventional commit message)
   - **Stash:** `git stash push -m "<feature>: WIP <description>"`
   - **Discard:** `git checkout -- .` (CONFIRM with user — destructive)

3. **After cleanup**, tell user to re-run the command that failed.

## Scenario: Failed `/commit flow`

**Symptoms:** Step 6 of `/commit flow` failed partway — merge may have succeeded but push or cleanup didn't.

**Recovery steps:**

1. **Diagnose how far it got** (run from main worktree):
   ```bash
   git branch --show-current           # Should be main if merge happened
   git branch --merged main | grep -E 'feature/|hotfix/'  # Check if branch was merged
   git rev-list origin/main..main      # Check if push is needed
   git worktree list --porcelain       # Check if worktree still exists
   ```

2. **Resume from the failed step** — each step is idempotent:
   - Merge not done: `cd "<main_worktree>" && git merge --no-ff <branch> -m "<type>(<scope>): <description>"`
   - Merge done, push not done: `cd "<main_worktree>" && git push`
   - Push done, worktree not removed: `cd "<main_worktree>" && git worktree remove "<worktree_path>" && git branch -D <branch>`
   - Worktree already removed: `cd "<main_worktree>" && git worktree prune && git branch -D <branch>`

3. **If merge conflict during recovery:** Resolve conflict first (see Merge Conflict scenario above), then push.

4. **Verify:** `git log --oneline -5` to confirm merge commit exists on main.

## Rules

- NEVER run destructive commands without explicit user confirmation
- Always show what will be lost before suggesting deletion
- Prefer `git stash apply` over `git stash pop` (safer)
- After any recovery, run `./scripts/run_tests.sh --fast` to verify
