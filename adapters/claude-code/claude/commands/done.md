---
description: Verify a feature is fully closed — worktree removed, branch merged, docs prefixed DONE_Feature_, execution plan updated
argument-hint: <feature-name>
---

# Done Check: $ARGUMENTS

Verify that a feature worktree has been properly closed and mark it complete in the execution plan.

**Must run from the target project's main worktree** (not from a different project).
The Bash sandbox is scoped to the current project — running `/done` from a different
project will fail on any file operations (mv, git add, git commit).

## Workflow

### Step 1: Validate Context

**If no feature name provided:** Ask the user for a feature name. **STOP.**

**Project context check:** Verify the current working directory is the target
project's main worktree (not a feature worktree, not a different project).
Check: does `docs/` exist and contain feature folders for this project?

If running from the wrong project:
```
⚠️ /done must run from the target project's main worktree.

Open a new Claude Code session in the project directory and run:
  /done <feature>
```
**STOP.**

### Step 1.5: Plan Detection (expanded search)

**MANDATORY — search for execution plans in ALL status prefixes:**
```
Glob pattern: docs/*/execution-plan.yaml
```
This searches INPROGRESS_*, DONE_*, and PENDING_* directories. The standard
`docs/INPROGRESS_Plan_*/execution-plan.yaml` pattern misses plans when `/commit flow`
has already renamed the docs folder to DONE_Feature_.

If found: Read the YAML. Match the feature name to a task using the matching
algorithm from the plan-detection skill § Matching Algorithm.

**Do NOT update the YAML yet** — wait until Step 2 confirms merge.

If no plan found: proceed standalone (no warnings, no behavior change).

### Step 2: Verify Cleanup

Run the done verification script to check all cleanup criteria in one call:
```bash
bash ~/.claude/tools/done-verify.sh <feature>
```
Parse the JSON output:

- If `all_clean` is `true`: proceed to Step 3 (update plan YAML)

- If `is_merged` is `false`:
  ```
  ⚠️ Feature has not been merged to main yet.

  Run /commit flow from the feature worktree first.
  ```
  **STOP.**

- If `is_merged` is `true`: **proceed with remaining steps regardless of
  worktree/branch status.** The merge is the gate — everything else is cleanup.

  - If `worktree_removed` is `false` or `branch_deleted` is `false`:
    Note the pending cleanup. Will output cleanup commands in the final report.

  - If `docs_status` is `"inprogress"`: rename docs folder:
    ```bash
    mv docs/INPROGRESS_Feature_<feature> docs/DONE_Feature_<feature>
    git add docs/DONE_Feature_<feature>
    git commit -m "docs(<feature>): mark as done"
    ```
    If this fails (sandbox), add to manual commands in the report.

### Step 3: Update Plan YAML (if plan found in Step 1.5)

**MANDATORY if a plan was found and a matching task exists.** This is the step
that makes the dashboard show the green checkmark.

1. Use Edit tool to set `task.status` → `done` (or `skipped` with `--skip` flag)
   and `task.last_updated` → current ISO 8601 timestamp in execution-plan.yaml
2. Use Bash to remove crash recovery marker: `rm -f .planning/active-<task_id>.json`
3. Re-read the YAML to check gate: if all tasks in the phase are `done`/`skipped`,
   run the gate command via Bash (if defined)

**If the task status is already `done`:** skip silently (idempotent).

### Step 3.5: Populate codebase_snapshot + predecessor_context (backlog #64)

**MANDATORY for schema 2.0 plans where the task introduced or modified code.**
Skip silently for documentation-only tasks (no code commit) and for 1.x plans.

This populates the compact predecessor-context metadata that future
dependent tasks will read instead of (or in addition to) reading this
task's full REQUIREMENTS.md / PLAN.md / REVIEW.md.

**Producer protocol:**

1. **Find the feature commit:**
   ```bash
   git log main..HEAD --format='%H %s' | grep -i "feat(<task-id>)" | head -1
   ```
   Or pick the merge commit if `/done` runs after merge. Capture the long SHA.

2. **Extract structural metadata** (one Bash invocation, no LLM call):
   ```bash
   COMMIT=<sha>
   git diff "${COMMIT}^..${COMMIT}" --stat -- ':!docs/'
   git diff "${COMMIT}^..${COMMIT}" --name-only -- '*.py' '*.ts' '*.sh' | head -20
   ```
   Per file changed, infer a one-line role from the file's docstring or
   header comment if present. For each `.py` / `.ts` / `.sh` file added,
   list 3-10 introduced top-level functions (grep `^def `, `^function `,
   `^[a-zA-Z_]\+()`).

3. **Extract decision shadow via one LLM-style synthesis** (the agent
   already running /done does this in-context — no separate spawn):

   Read `REQUIREMENTS.md`, `PLAN.md`, and `REVIEW.md`. Extract:
   - **constraints**: key design rules downstream callers must respect (1 line per rule, list only load-bearing ones; soft target ≤10 lines, hard cap 30)
   - **rejected**: approaches considered and rejected with brief why (skip if none — empty string is fine)
   - **contract**: how callers should use the new interfaces (import paths, entry points, error semantics)

   **Compression heuristic** from the requirements-analysis skill: "if a
   future task that depends on this needs to know something to call your
   code correctly OR to avoid violating a design decision, write it down.
   Otherwise skip it."

4. **Use Edit on the plan YAML** to add two blocks to the completed task:

   ```yaml
   codebase_snapshot:
     commit_ref: <long sha>
     modules_changed:
       - path: <file>
         role: <one-line role>
         lines: <int from git diff --stat>
     interfaces_introduced:
       - name: <function/class>
         defined_in: <file>
         signature: <single-line signature>
     tests_added:
       - <test file path>
   predecessor_context:
     constraints: |
       <multi-line, load-bearing rules>
     rejected: |
       <optional; multi-line>
     contract: |
       <how callers should use this>
   ```

5. **If either block already exists** (re-run of /done), leave them in
   place — they were authored once, do not regenerate. The schema is
   additive; updates should be deliberate.

**Failure mode:** if extraction fails (no feature commit found, plan
read fails), log a warning and continue. Do NOT block /done — the
backward-compat fallback in `predecessor-context.py` will keep the
dependent tasks working by reading the artifact files directly.

### Step 4: Update Execution Guide

Read `EXECUTION_GUIDE.md` and find the line(s) referencing `<feature>`. Add `✓ DONE` if not already present.

**Pattern to find** — look for lines matching any of:
- `/start <feature>`
- `<feature>` in a table row or diagram line
- `>> /ba flow <feature>`

**Add checkmark** — append `✓ DONE` to the relevant line(s) in the diagram section, matching the existing style (e.g. `✓ DONE` right-aligned or at end of line).

If already marked `✓ DONE`, skip this step.

Commit:
```bash
git add EXECUTION_GUIDE.md
git commit -m "docs(config): mark <feature> as done in execution plan"
```

### Step 5: Report

```
✓ Feature: <feature>

Checks:
  Merged to main:      ✓
  Docs prefix:         ✓ DONE_Feature_<feature>/  (or ⚠️ needs manual rename)
  Plan YAML status:    ✓ task.status = done  (or ⚠️ no plan found)
  Execution guide:     ✓ marked ✓ DONE
  Worktree removed:    ✓  (or ⚠️ pending)
  Branch deleted:      ✓  (or ⚠️ pending)
```

**If worktree or branch cleanup is pending**, append:
```
⚠️ Cleanup pending. Run in a terminal:
rm -rf <worktree_path> && cd <main_worktree> && git worktree prune && git branch -D feature/<feature>
```

**If docs rename failed** (sandbox), append:
```
⚠️ Docs rename pending. Run in a terminal:
cd <main_worktree> && git mv docs/INPROGRESS_Feature_<feature> docs/DONE_Feature_<feature> && git commit -m "docs(<feature>): mark as done"
```

## Rules

- **Must run from target project's main worktree** — sandbox blocks cross-project writes
- Read-only checks first — only modifies docs prefix, plan YAML, and EXECUTION_GUIDE.md
- NEVER deletes worktrees or branches — that is /commit flow's job
- NEVER modifies source code
- Merge is the gate — proceed with state updates even if cleanup is incomplete
- All modifications use the Edit tool where possible (works cross-file), Bash only for git commands
