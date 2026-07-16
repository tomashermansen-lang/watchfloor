# Flow Mode Reference

Extended reference for flow mode. Loaded by `/recover`, `/status`, and `/help` — NOT loaded during active pipeline phases.

## Parallel Sessions

Each flow gets its own worktree directory:

```
my-project/                      ← Main (run /start here)
├── ../<worktree-analytics>/     ← VSCode 1: /ba flow analytics
├── ../<worktree-ui-skeleton>/   ← VSCode 2: /ba flow ui-skeleton
└── ../<worktree-hotfix-crash>/  ← VSCode 3: /hotfix crash
```

**To start parallel work:**
1. In main project, run `/start <feature>` — creates worktree
2. Open worktree in new VSCode window (File → Open Folder)
3. Start new Claude chat in that window, run `/ba flow <feature>`
4. Repeat in main project for more features

**Manual worktree management:** `./scripts/worktree.sh`

## Stopping Mid-Flow

When user chooses `stop`:
- Worktree and branch remain intact
- Resume later by running the same command in the worktree
- To abandon: `./scripts/worktree.sh remove <feature-name>`

## Mid-Flow Course Correction

**If plan is wrong during `/implement`:**
1. Claude says "STOP — plan issue discovered: [description]"
2. User chooses action:
   - `revise` → Go back to `/plan flow` in same worktree
   - `continue` → Proceed anyway (user accepts risk)
   - `abandon` → Run `./scripts/worktree.sh remove <feature>`

**If `/review` rejects plan:**
1. Review gives `❌ REVISION NEEDED` verdict
2. User chooses `amend` at checkpoint
3. Claude runs `/plan flow` to revise (same worktree, same branch)
4. New `/review flow` after revision

**If tests fail in `/qa`:**
1. QA gives `❌ BLOCKED` status
2. User fixes issues manually or asks Claude
3. Re-run `/qa flow` (NOT `/implement flow`)

## Resuming After VSCode Restart

If you close VSCode mid-flow:
1. Open the worktree folder again (File → Open Folder)
2. Start a new Claude chat
3. Check status: `git status` and `ls docs/*<feature>/`
4. Run the appropriate command based on which docs exist (resolve prefix first):
   - Only REQUIREMENTS.md → `/plan flow <feature>`
   - REQUIREMENTS.md + PLAN.md → `/review flow <feature>`
   - REQUIREMENTS.md + PLAN.md + TESTPLAN.md → `/manualtest flow <feature>`
   - REQUIREMENTS.md + PLAN.md + TESTPLAN.md + MANUAL_TEST_LOG.md → `/qa flow <feature>`
