---
description: Start a new feature flow — create worktree and branch, then switch to it
argument-hint: <feature-name>
---

# Start Flow: $ARGUMENTS

Create a worktree and feature branch for a new feature.

## Workflow

### Step 1: Validate Context

**If no feature name provided:** Ask the user for a feature name. **STOP** until they provide one.

Run the start validation script to check context in one call:
```bash
bash ~/.claude/tools/start-validate.sh <feature>
```
Parse the JSON output:
- If `is_main_project` is `false`:
  ```
  ⚠️ You are in a worktree.

  To start a new feature, switch to the main project first:
    File → Open Folder → select the main project folder
  ```
  **STOP.**
- If `feature_exists` is `true`: show `error` message (includes worktree path or branch info) and **STOP.**

### Step 1.5: Plan Detection & Orientation

**MANDATORY — run this glob BEFORE any other file reads:**
```
Glob pattern: docs/INPROGRESS_Plan_*/execution-plan.yaml
```
If found: Read the YAML, then follow the plan-detection skill
§ Project Orientation for task matching and context loading.
If not found: proceed standalone (no warnings, no behavior change).

If a plan is loaded and a matching task is found:
- Check `task.depends` — warn if any dependency is not `done`/`skipped` (allow override)

If no plan found: proceed as normal (no change to existing behavior).

### Step 1.75: Autopilot Early Exit

Check if the matching task in the execution plan has `autopilot: true`.
Also check `pipeline: full` or `pipeline: light` (default: full).

**If autopilot: true:** Do NOT create a worktree. Show the following and **STOP:**
```
This task is marked AUTOPILOT (<pipeline>) in the execution plan.
The planning team assessed: <assessment> — pipeline can run autonomously.

  Run in terminal:
    bash ~/.claude/tools/autopilot.sh --full <feature>

  Pipeline (<pipeline>):
    full:  /ba → /plan → /team-review → /implement → /static-analysis → /team-qa → /commit
    light: /ba → /plan → /review → /implement → /static-analysis → /qa → /commit

  Runs fully autonomously via tmux. Creates worktree, runs pipeline,
  merges, and cleans up on success.

  Or run manually instead:
    /start --no-autopilot <feature>
```
**STOP.** Do not create worktree or run any further commands.

**If `$ARGUMENTS` contains `--no-autopilot`:** Strip the flag from the feature name and proceed to Step 2 regardless of autopilot status.

**If autopilot: false or no plan:** Proceed to Step 2.

### Step 2: Create Worktree

```bash
FEATURE="<feature-name>"
./scripts/worktree.sh new "$FEATURE"
```

After worktree creation:
- If a plan was loaded: use Edit tool to set `task.status` → `wip` and `task.last_updated` → now in execution-plan.yaml
- Use Write tool to create `.planning/active-<task_id>.json` crash recovery marker

### Step 3: Guide User

```
✓ Worktree created
✓ Branch: feature/<feature>

To continue:
1. In VSCode: File → Open Folder → select the new worktree folder shown above
2. Start a new Claude chat in that window
3. Run: /ba flow <feature>
```

**STOP.** Do not run any further commands. The user must switch to the new worktree window.

## Rules

- Only runs from the main project (not from a worktree)
- Does not modify any files beyond what `worktree.sh new` does
- Does not start the BA phase — that happens after the user switches
