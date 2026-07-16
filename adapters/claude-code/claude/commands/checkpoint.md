---
description: Checkpoint — save progress with a named tag without closing the flow
argument-hint: [optional description]
disable-model-invocation: true
---

# Checkpoint: Save Progress

Save current work as a tagged commit without leaving the current flow phase. Use during `/manualtest` or `/implement` for large features where you want named rollback points.

## Workflow

1. **Run tests.** `./scripts/run_tests.sh`. If fail → STOP. Fix first.

2. **Show changes.** `git status` and `git diff --stat`.

3. **Determine tag name.**
   ```bash
   FEATURE=$(git branch --show-current | sed 's|^feature/||; s|^hotfix/||')
   # Count existing checkpoint tags for this feature
   N=$(git tag -l "checkpoint/$FEATURE/*" | wc -l | tr -d ' ')
   NEXT=$((N + 1))
   TAG="checkpoint/$FEATURE/$NEXT"
   ```

4. **Commit.**
   ```bash
   git add src/ tests/ config/ ui_react/ docs/
   git commit -m "wip(<scope>): checkpoint — <description>"
   ```
   Use the user's description from `$ARGUMENTS` if provided, otherwise summarize changes.

5. **Tag.**
   ```bash
   git tag "$TAG"
   ```

6. **Report:**
   ```
   ✓ Checkpoint saved
     Commit: <short-hash>
     Tag: checkpoint/<feature>/<n>

   To roll back to this point:
     git reset --hard checkpoint/<feature>/<n>

   Continuing in current phase.
   ```

## Rolling Back

To restore a checkpoint:
```bash
git reset --hard checkpoint/<feature>/<n>
```

To list checkpoints:
```bash
git tag -l "checkpoint/*"
```

## Cleanup

Checkpoint tags are **local only** (not pushed). They are deleted automatically when `/commit flow` completes:
```bash
git tag -l "checkpoint/$FEATURE/*" | xargs git tag -d
```

## Rules

- NEVER commit if tests fail
- NEVER push checkpoint tags to remote
- NEVER leave the current flow phase — this is a save point, not a phase transition
- Tags are local and ephemeral — they exist only for the duration of the feature
