---
description: Commit changes using conventional commit format after verifying tests pass
argument-hint: [optional commit message hint] OR flow
---

# Commit Changes

Commit staged/unstaged changes using conventional commit format. Tests must pass first.

## Flow Mode

See the flow-mode skill for protocol.

**Flow mode completes the pipeline:**
1. Verify tests pass
2. Commit uncommitted changes
3. Merge feature branch to main
4. Push to remote
5. Clean up feature branch

**Requirements:** Must be in a worktree on a `feature/*` or `hotfix/*` branch, tests pass. QA report required for features (not hotfixes).

## Pre-flight is long-running — call Bash correctly

`commit-preflight.sh` runs the project's full test suite. On medium projects
this takes **4–5 minutes** (1097 tests / 4m14s observed on dotfiles-monorepo,
2026-05-06). The default Bash tool timeout (120 s = 2 min) is **NOT** enough.

You have two correct ways to run it:

1. **Synchronous (preferred for /commit):** call Bash with `timeout: 600000`
   (10 minutes). The tool blocks until preflight exits; you get the JSON
   directly. No polling.

2. **Background:** call Bash with `run_in_background: true`. You receive a
   task_id, the command keeps running, and a `<task-notification>` fires
   when it exits. **Wait for that notification — do not poll BashOutput.**
   Polling early returns empty output (process still running), which has
   tricked agents into starting a *second* preflight run, doubling cost
   and runtime (observed in plans-filter-ui chain run, 2026-05-06).

**Forbidden failure mode:** if BashOutput on a running preflight returns
empty/short output, the preflight is **not stale** — it is still running
pytest. Do NOT start a fresh `commit-preflight.sh`. Either wait for the
existing task's completion notification, or kill the existing task with
TaskStop before starting a new one.

## Standard Workflow

1. **Pre-flight check.** Run the commit pre-flight script to gather all context in one call (see "Pre-flight is long-running" above for Bash tool config):
   ```bash
   bash ~/.claude/tools/commit-preflight.sh --test-cmd "./scripts/run_tests.sh"
   ```
   Parse the JSON output:
   - If `tests_passed` is `false`: show `test_output` to user and **STOP**
   - If `tests_passed` is `null`: warn user no test runner found, ask to continue
   - Use `status` for file selection (step 2)
   - Use `diff_stat` for change summary
   - Use `recent_commits` for commit message style reference

2. **[Removed — merged into pre-flight]**

3. **Confirm files.** Ask user which to include if multiple unrelated changes. Stage with `git add <file>` (never `git add .`).

4. **Generate commit message.** Conventional format:
   ```
   <type>(<scope>): <description>
   ```
   Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
   Scopes: `retrieval`, `ranking`, `rag`, `eval`, `ui`, `config`, `docs`, `ux`

5. **Show message** for approval.

6. **Commit.** `git commit -m "<message>"`

7. **Ask about push.** Default is NO.

## Flow Mode Workflow

### Steps 0-3: Pre-flight Check

Run the commit flow pre-flight script to gather all context in one call.
**Use `timeout: 600000` on the Bash tool** — pytest runs the full suite,
which takes 4–5 minutes (see "Pre-flight is long-running" near the top
of this skill). **Do not poll BashOutput** if you used `run_in_background`
— wait for the completion notification instead.

```bash
bash ~/.claude/tools/commit-preflight.sh --flow --test-cmd "./scripts/run_tests.sh"
```
Parse the JSON output:
- If `is_worktree` is `false` or `branch` is `null` or does not start with `feature/` or `hotfix/`:
  ```
  ⚠️ Cannot run /commit flow on main.

  /commit flow merges a feature branch into main and deletes the worktree.
  You are already on main — there is nothing to merge.

  Did you mean:
    /commit          — commit changes on main (no merge)
    /start <feature> — start a new feature flow in a worktree
  ```
  **STOP.**
- If `tests_passed` is `false`: show `test_output` and **STOP**
- Note `has_qa_report` for the checkpoint display (features only — skip for hotfixes)
- Note `uncommitted` for Step 5 (finalize commit)
- Note `main_worktree` for Step 6 (merge target)

### Step 4: Pre-merge Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Ready to merge and push:

Branch: <branch-name>
Tests: ✅ passing
QA Report: ✅ exists / n/a (hotfix)

On [yes]:
  1. Commit any uncommitted changes
  2. cd <main_worktree> && git merge --no-ff <branch>
  3. Update docs prefix + execution plan YAML + execution guide
  4. git push
  5. Cleanup worktree and branch
  6. STOP — working directory deleted. Close this window.

On [stop]:
  → Pause flow. Resume later in a new chat: /commit flow

Continue? [yes / stop]
```

Wait for user confirmation before proceeding.

### Step 5: Commit Remaining Changes

If `uncommitted` from pre-flight is non-empty:
```bash
git add src/ tests/ config/ ui_react/ docs/
git commit -m "chore(<feature>): finalize for merge"
```

### Step 5b–6d: Finalize, Merge, Push, Cleanup — SCRIPTED

**All deterministic operations are handled by `commit-finalize.sh`.**
This script renames docs, updates the execution plan YAML, commits
finalization, merges to main, pushes, and cleans up the worktree.

**Autopilot mode:** If `$ARGUMENTS` contains `autopilot`, **SKIP this step.**
The autopilot orchestrator calls `commit-finalize.sh` directly after this
phase ends — running it here would conflict (duplicate merge, broken
working directory). Just commit remaining changes (Step 5) and STOP.

**Manual flow mode:** Run the script:
```bash
bash ~/.claude/tools/commit-finalize.sh \
  --task <feature> \
  --worktree "$(pwd)" \
  --main "<main_worktree>" \
  --branch "<branch>"
```

Parse the JSON output. Each step has a status (`ok`, `skip`, or `fail`):
- `docs_rename` — INPROGRESS → DONE folder rename
- `plan_yaml` — execution plan task.status = done
- `exec_guide` — EXECUTION_GUIDE.md marked ✓ DONE
- `finalize_commit` — commit the above on the feature branch
- `merge` — merge --no-ff to main
- `push` — git push origin main
- `cleanup` — remove worktree + delete branch
- `docs_verify` — DONE_Feature_ exists on main
- `git_clean` — no untracked/modified files

If `ok` is `false`, check which steps failed and report them in Step 7.

**⚠️ CRITICAL:** After this script runs, the worktree is deleted. The Bash
tool's working directory no longer exists. Do NOT run any further Bash
commands — proceed directly to Step 7 (report).

### Step 7: Report and STOP

Output a completion report. Adapt based on what succeeded and what needs manual action:

**Always include these lines** (mark each ✓ or ⚠️ based on actual result):
```
Merged to main:       ✓ / ⚠️
Pushed to remote:     ✓ / ⚠️
Docs renamed:         ✓ DONE_Feature_<feature> / ⚠️
Execution plan YAML:  ✓ task.status = done / ⚠️ not found / ⚠️ edit failed
Execution guide:      ✓ marked ✓ DONE / ⚠️ not found
Worktree + branch:    ✓ cleaned up / ⚠️ pending
```

**If cleanup pending**, append:
```
⚠️ Cleanup pending. Run in a terminal:
rm -rf <worktree_path> && cd <main_worktree> && git worktree prune && git branch -D <branch>
```

Always report every line — never omit a line because it succeeded.
Use `rm -rf` for worktree cleanup — `git worktree remove` fails in sandbox.

**STOP.** Do NOT run any further tool calls after cleanup succeeds or after
outputting manual commands. The working directory may no longer exist.

## Rules

- NEVER commit if tests fail
- NEVER use `git add .` (except flow mode for feature completion)
- NEVER push without explicit confirmation
- NEVER commit sensitive files (`.env`, `*credentials*`, `*.key`)
- NEVER call `commit-preflight.sh` with the default 2-min Bash timeout — pytest takes 4–5 min on medium projects. Use `timeout: 600000` or `run_in_background: true`.
- NEVER start a second `commit-preflight.sh` because the first looks stale — it isn't stale, it's running pytest. Wait for the completion notification or `TaskStop` the running one first.
- In flow mode: NEVER force push, NEVER merge without passing tests
- In flow mode: NEVER run `/commit flow` on main — it only works in worktrees
- In flow mode: After cleanup, STOP immediately — working directory is deleted
