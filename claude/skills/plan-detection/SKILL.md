---
name: plan-detection
description: Shared plan detection, task context loading, and crash recovery for flow commands. Referenced by all plan-aware commands.
user-invocable: false
---

# Plan Detection Protocol

Shared logic for detecting execution plans, loading task context, and managing
crash recovery markers. Flow commands reference this skill instead of
duplicating detection logic.

## Plan Detection

Run after worktree validation but before the command's main work.

### Step 0.5: Plan Detection (automatic, non-blocking)

1. Search for `docs/INPROGRESS_Plan_*/execution-plan.yaml` in the worktree root
   using the Glob tool with pattern `docs/INPROGRESS_Plan_*/execution-plan.yaml`
2. If exactly one plan found: load it with the Read tool
3. If multiple plans found: ask the user which plan this feature belongs to
   (list plan names, or "none" for standalone)
4. If no plan found: proceed standalone — no warnings, no behavior change (R17)

**Backward compatibility:** When no plan is found, all subsequent plan-related
steps are skipped. The command works exactly as it does without plan support.

## Project Orientation (automatic when plan exists)

When a plan is loaded, orient yourself in the project BEFORE starting the command's main work.
This replaces manual prompts like "look at the execution plan and docs folder".

### Step 0.6: Auto-Orient (context-aware, minimal reads)

**Budget: 2 file reads + 1 glob.** Do not scan everything — be surgical.

The two important project-level files are `execution-plan.yaml` (task graph) and
the **project plan** (narrative/vision). The project plan filename varies per project
(e.g., `EXECUTION_PLAN.md`, `ops-intelligence-hub-plan.md`) — discover it from the
YAML's `sources` array. `SETUP_PLAN.md` is infrastructure-only and is NOT read
during orientation.

1. **Read execution plan YAML** (1 read) — read `execution-plan.yaml` (the task graph).
   Note task statuses, identify the current task's phase, and list its direct
   dependencies (`task.depends`). This is the structural overview — phases, tasks,
   statuses, dependencies, acceptance criteria.
   Also note the `sources` array — it lists the project's key documents.

2. **Read project plan overview** (1 read, first 40 lines only) — from the YAML
   `sources` array, find the entry that is NOT `SETUP_PLAN.md` and NOT
   `execution-plan.yaml` itself (typically named "Implementation Plan",
   "Execution Plan", or "Project Plan"). Read its first 40 lines (`limit: 40`)
   to get the project vision, scope, and high-level strategy. If the `sources`
   array has no such entry or the file doesn't exist, skip silently.

   **Do NOT** read `SETUP_PLAN.md` — it's a one-time infrastructure checklist,
   irrelevant during ongoing development.

3. **Note dependencies from YAML** — extract dependency names and statuses from
   the YAML (already loaded in step 1). Do NOT read dependency files during
   orientation — projects can have 8+ dependencies and reading them would flood
   context. Dependency docs are read on-demand during Task Context Loading (below)
   only for the specific task being worked on.

4. **List (don't read) parallel work** — use Glob for `docs/INPROGRESS_*/` directory
   names only. Note them for awareness but do NOT read their contents.

5. **Summarize context** in 2-3 lines:
   - "Project: <plan name>, Phase <N>/<total>, this task: <name>"
   - "Depends on: <done tasks> (statuses from YAML)" or "No dependencies"
   - "Parallel: <in-progress task names>" or "No parallel work"

**Do NOT** read DESIGN.md, QA_REPORT.md, REQUIREMENTS.md, or PLAN.md from other
tasks during orientation. Those are only read on-demand by specific commands:
- Task Context Loading (below): reads dependency REQUIREMENTS.md for the current task
- `/review` step 2b and `/qa` step 9b: reads docs when checking drift concerns

## Task Context Loading

When a plan is loaded and a feature name is available:

### Matching Algorithm (R6a)

Match the feature name against task IDs in the plan using 4-tier matching:
1. **Exact:** feature name equals task ID
2. **Normalized:** both lowercased, hyphens and underscores treated as equivalent
3. **Fuzzy:** feature name is a substring of task ID or vice versa — warn:
   "Fuzzy match: feature '<name>' matched task '<id>'. Verify this is correct."
4. **No match:** info message "Feature '<name>' not found in plan '<plan>',
   running standalone." — proceed without plan context.

### Loading Context (R14)

If a task is found:
1. **Task prompt:** Use `task.prompt` as additional context for the command's work
2. **Acceptance criteria:** Include `task.acceptance` alongside any feature-specific
   criteria (additive, never replacing the command's own criteria)
3. **Dependencies:** Check `task.depends` — for each dependency, verify its status
   is `done` or `skipped`. If incomplete, warn:
   "Task '<id>' depends on '<dep>' (status: <status>). Proceed anyway?"
   Allow the user to override.
4. **Markdown context:** Read `EXECUTION_PLAN.md` in the same directory as the
   execution-plan.yaml. Search for a markdown heading matching the task name.
   If found, use the section content as supplementary context. If not found,
   proceed with YAML-only context (no warning — YAML is the contract).

## Predecessor Context Loading

When a task has completed dependencies, commands that produce new artifacts
(`/ba`, `/ux`) should understand what predecessors established before drafting.
This prevents conflicts with interfaces, schemas, or contracts already built.

### Step 0.8: Load Predecessor Outputs (on-demand, budget-controlled)

**Trigger:** Only when the command's Step 0.5 explicitly calls for predecessor
context AND the task has dependencies with status `done`.

**Budget:** 3 reads per dependency (REQUIREMENTS + QA + DESIGN). Read all in
parallel where possible.

For each dependency in `task.depends` where the YAML shows status `done`:

1. **Glob** for `docs/DONE_Feature_<dep-id>/` contents
   (try normalized: lowercase, hyphens = underscores)

2. **Read REQUIREMENTS.md** — the original contracts: interfaces, API specs,
   data schemas, component boundaries, acceptance criteria. This is what was
   *promised*.

3. **Read QA_REPORT.md** — what was actually verified and delivered. Compare
   against requirements to identify drift. Note:
   - Which acceptance criteria passed/failed/were adjusted
   - Any deviations from original requirements
   - Actual API surface, data shapes, and behaviors as verified

4. **Read DESIGN.md** (if it exists) — UI patterns, component names, layout
   structure, theme tokens, accessibility decisions. Essential for `/ux` but
   also useful for `/ba` to understand the user-facing contract.

5. **Synthesize** predecessor state in 2-4 bullet points per dependency:
   - What was promised (REQUIREMENTS) vs what was delivered (QA)
   - Established interfaces/contracts the current task must respect
   - UI patterns and component conventions to maintain consistency
   - Any drift or adjustments that affect downstream assumptions

**Do NOT** read PLAN.md or source code from predecessors — requirements,
QA, and design docs are the contract layer.

**Skip silently** if no DONE_Feature folder exists for a dependency (the
dependency may be infrastructure or non-feature work).

### How Commands Use Predecessor Context

| Command | Predecessor context used for |
|---------|------------------------------|
| `/ba` | Ensure new requirements build on (not conflict with) predecessor interfaces. Reference established contracts. Flag if a requirement would break a predecessor's API. |
| `/ux` | Ensure designs are visually/structurally consistent with predecessor UI. Reuse established component patterns. Reference predecessor data schemas for display. |
| `/review` | Already has Step 2b — uses DONE_* docs for drift detection (unchanged) |
| `/qa` | Already has Step 9b — uses DONE_* docs for interface verification (unchanged) |

## Status Updates

Flow commands update task status at checkpoints using Claude's Edit tool
directly on the YAML file. Status values: `pending | wip | done | failed |
skipped | blocked`.

### `/start` Updates (R15)
- Edit `task.status` from `pending` to `wip` in execution-plan.yaml
- Edit `task.last_updated` to current ISO 8601 timestamp

### `/done` Updates (R15)
- Edit `task.status` from `wip` to `done` in execution-plan.yaml
- Edit `task.last_updated` to current ISO 8601 timestamp
- With `--skip` flag: Edit `task.status` to `skipped`

### Other Commands
- `/ba`, `/ux`, `/plan`, `/review`, `/implement`, `/manualtest`, `/qa`:
  no status change (task stays `wip` throughout the flow pipeline)

**Immutability (P1):** Status updates are the ONLY modification flow commands
make to the plan file. Never modify task names, descriptions, dependencies,
or acceptance criteria.

## Crash Recovery Markers (R15a)

### Directory Convention
Markers live in `.planning/` in the worktree root (gitignored).

### Write Marker — `/start`
When `/start` sets a task to `wip`, also:
1. Create `.planning/` if it doesn't exist: `mkdir -p .planning`
2. Write marker file using the Write tool:
   ```
   .planning/active-<task_id>.json
   ```
   Content:
   ```json
   {"task_id": "<id>", "started_at": "<ISO8601>", "plan_path": "<path-to-yaml>"}
   ```

### Remove Marker — `/done`
When `/done` completes a task:
1. Remove marker: `rm -f .planning/active-<task_id>.json`
2. Silently no-op if marker doesn't exist

### Detect Stale Markers — Plan Detection
During Step 0.5 plan detection, also:
1. Scan `.planning/active-*.json` using Glob tool
2. If markers exist for the current feature:
   - Read the marker file
   - If the task status in the plan is already `done`: remove the stale marker
   - If the task status is `wip`: warn the user:
     "Task '<id>' was started in a previous session that did not complete.
     Resume or reset?"
     - **Resume:** keep `wip`, continue from current phase
     - **Reset:** set status back to `pending` via Edit tool, remove marker

### Multiple Markers (E13)
If multiple markers exist for the same task, use the most recent `started_at`.
Warn about duplicates.

## Gate Evaluation (R16)

After `/done` updates a task status, check if all tasks in the same phase
are now `done` or `skipped`:

1. Read the execution-plan.yaml
2. Find the phase containing the completed task
3. If all tasks in the phase are `done` or `skipped`:
   - Check the phase's `gate` (if defined)
   - If a gate `command` is specified, run it via Claude's Bash tool
   - Report result: "Phase '<phase>' gate: PASS" or "FAIL: <output>"
4. If tasks remain, report: "Phase '<phase>': X/Y tasks complete"

## Per-Command Context Usage

| Command | Plan context used for |
|---------|----------------------|
| `/start` | Dependency check, status → `wip`, create marker |
| `/ba` | Plan acceptance criteria augment requirements output; predecessor context (Step 0.8) for interface awareness |
| `/ux` | Plan task context as design input; predecessor context (Step 0.8) for UI/schema consistency |
| `/plan` | Plan task context as architecture input |
| `/review` | Plan acceptance criteria as additional review targets |
| `/implement` | Plan acceptance criteria become additional TDD test targets |
| `/manualtest` | Plan acceptance criteria as test checklist items |
| `/qa` | Plan acceptance criteria as quality verification targets |
| `/done` | Status → `done`/`skipped`, remove marker, gate check |
