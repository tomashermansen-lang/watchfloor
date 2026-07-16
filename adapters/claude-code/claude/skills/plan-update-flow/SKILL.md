---
name: plan-update-flow
description: Update-mode subflow for /plan-project when --update flag is set. Owns schema-version detection (1.x vs 2.0), Step 1U update dialog with current-state load and change elicitation, 2U change classification (8 change types), 3U narrative updates for legacy 1.x plans, 4U YAML edits with status preservation, and 5U update review (solo C1-C8 or team variant). Read inline by /plan-project at Step 1U.
disable-model-invocation: true
user-invocable: false
---

# Plan Update Flow — Steps 1U through 5U

This file is read verbatim by `/plan-project` when `--update` is set
and an existing plan is found.

## Contents

- Schema-version detection (mandatory first step)
- §1U Update Dialog (current-state load + change elicitation)
- §2U Change Classification
- §3U Apply Changes to Narrative (Legacy 1.x only)
- §4U Apply Changes to YAML
- §5U Update Review (solo and team variants)

After 5U concludes, return to `/plan-project` Step 7 (YAML Synthesis).

---

## Schema-version detection (mandatory first step)

Read `schema_version` from `execution-plan.yaml`:
- `2.0.0` → **2.0 update path** (yaml-only). All structural changes go to
  the yaml. No markdown reads or writes.
- `1.x` → **legacy update path**. Continues to read/write SETUP_PLAN.md +
  EXECUTION_PLAN.md + yaml triplet to preserve compatibility with plans
  authored before the 2.0 cutover.

The path branches in §1U Phase A and §3U.

## §1U: Update Dialog

**Phase A — Load current state (automatic):**
1. Read `execution-plan.yaml` — parse all phases, tasks, statuses, and
   `schema_version`
2. **2.0 path:** all narrative content lives in yaml fields (`vision`,
   `description`, `phases[].description`, `task.what`, `task.why`).
   No markdown read.
   **Legacy 1.x path:** also read `EXECUTION_PLAN.md` for the narrative
   plan (1.x stores prose there, not in yaml fields).
3. Present a status summary:
   ```
   Current plan: <name>
   Phases: <count> | Tasks: <done>/<total> done | WIP: <count>

   Phase 1: <name> — <done>/<total> tasks done
     ✓ task-a (done)
     ◉ task-b (wip)
     ○ task-c (pending)
   Phase 2: <name> — 0/<total> tasks done
     ...
   ```

**Phase A.5 — Absorbed task detection (automatic):**
For each `pending` task in future phases, check whether its acceptance criteria
have already been satisfied by completed (`done`) tasks. If ALL criteria are met:
flag the task as a candidate for removal in the status summary:
```
  ⚠ task-x (pending — criteria absorbed by task-a, task-b)
```
Present these candidates to the user during the change dialog.

**Phase B — Change elicitation (2-4 questions):**
1. What needs to change? (new tasks, restructured phases, scope expansion,
   reprioritization, lessons learned)
2. Which parts of the plan are affected? (specific phases/tasks)
3. Are there any completed tasks whose scope changed during implementation?
   (capture `scope_change` and `delivered_beyond_plan` for those tasks)
4. Any new constraints or dependencies discovered?
5. Review absorbed task candidates (from Phase A.5) — confirm removal or keep

**Turn limit:** Maximum 5 dialog turns for update elicitation.

## §2U: Change Classification

Classify each proposed change:

| Type | Description | YAML impact |
|------|-------------|-------------|
| **Add task** | New task in existing or new phase | New task entry, status: pending |
| **Add phase** | New phase with tasks | New phase entry with tasks |
| **Modify task** | Change acceptance criteria, dependencies, or description | Edit existing task fields |
| **Reorder** | Move task between phases or change dependencies | Edit depends + possibly phase membership |
| **Remove task** | Task no longer needed | Set status: skipped with scope_change note |
| **Absorb task** | Pending task whose criteria were met by other work | Remove from plan with changelog entry (see below) |
| **Split task** | One task becomes multiple | Original → skipped, new tasks added |
| **Restructure** | Major phase reorganization | Multiple edits, preserve done statuses |

**Absorbed tasks — removal rule:**
A `pending` task whose acceptance criteria have ALL been satisfied by work done
in other tasks was never explicitly started, so it is not historical record — it
is dead weight. During update, identify these and **remove them entirely** from
the yaml (and from EXECUTION_PLAN.md for legacy 1.x plans). Add a changelog entry:
```yaml
- date: "YYYY-MM-DD"
  type: removed
  description: "Removed <task-id>: all acceptance criteria absorbed by <absorbing-task-ids>"
  affected_tasks: [<task-id>]
  affected_phases: [<phase-id>]
```
Do NOT mark absorbed tasks as `done` — they were never started through the
pipeline. Marking them `done` inflates completion metrics and confuses the
audit trail. Only tasks that went through `/start` → pipeline → `/done` earn
`done` status.

**Immutability rules for updates:**
- **NEVER change status of `done` tasks** — completed work is permanent.
  `done` means the task went through the SDLC pipeline (`/start` → `/done`).
- **NEVER delete `done` tasks** — they are historical record
- **NEVER modify acceptance criteria of `done` tasks** — use `delivered_beyond_plan`
  and `scope_change` fields instead
- **DO remove absorbed `pending` tasks** — if a pending task's criteria are fully
  met by other completed work, remove it (not mark done). See "Absorbed tasks" above.
- `wip` tasks: may modify acceptance criteria (warn user first)
- `pending` tasks: may modify or remove freely

## §3U: Apply Changes to Narrative (Legacy 1.x Only)

**Skip this step in 2.0 update mode** — all narrative content is captured
in yaml fields (§4U covers it).

**Legacy 1.x plans only:** for each classified change:
1. Use the Edit tool to surgically modify EXECUTION_PLAN.md
2. Preserve all existing content for unchanged sections
3. Mark changed sections with `<!-- updated YYYY-MM-DD: <reason> -->`
4. Apply Dependency Sequencing Principles (see
   `plan-producer-conventions/SKILL.md` §5) to any new or reordered tasks

## §4U: Apply Changes to YAML

For each classified change, use the Edit tool on execution-plan.yaml:
1. Add/modify task entries preserving all existing fields
2. Preserve operational state on all tasks: `status`, `last_updated`,
   `delivered_beyond_plan`, `scope_change`, `remaining_gaps`
3. Preserve post-completion metadata on all `done`/`skipped` tasks:
   `codebase_snapshot`, `predecessor_context`, `artifact_refs`,
   `phase_results`, `deviations`, `auto_update`. These are written by
   `/done` and the per-phase Shared Closing Step (see
   plan-detection/SKILL.md § Phase-to-Artifact Mapping) and form the
   knowledge graph consumed by downstream tasks via `predecessor-context.py`
   (backlog #64). An update that drops them silently breaks the lean-context
   contract for any task that depends on the modified task.
4. Add changelog entry (see `/plan-project` Step 7 YAML changelog format)
5. Update `updated` field to today's date

**Verification:** After all edits, re-read the YAML and confirm:
- [ ] All `done` task statuses preserved
- [ ] All `wip` task statuses preserved
- [ ] All `done`/`skipped` tasks still carry their original `codebase_snapshot`,
      `predecessor_context`, `artifact_refs`, `phase_results` blocks (no
      silent stripping)
- [ ] New tasks have status: `pending`
- [ ] Absorbed tasks removed (not marked done) with changelog entries
- [ ] Changelog entry added
- [ ] No orphan dependencies (every `depends` reference points to a real task)

## §5U: Update Review

### Solo update review (no --team flag)

Run a focused adversarial review on changed sections only:
- Same criteria as `/plan-project` Step 6 (C1-C8) but scoped to modified/added content
- Maximum 2 rounds (lighter since most of the plan is already validated)
- Skip criteria that don't apply to the change type

### Team update review (--update --team or --update --team-lite)

When both `--update` and `--team`/`--team-lite` are set, replace the solo
review with a team-based review of the proposed changes:

1. **Spawn specialists** using the Agent tool with the matching `subagent_type`
   (same roster and mapping table as `plan-team-flow/SKILL.md` §5T.1 — full or lite).
2. Each specialist receives:
   - The current plan state (from §1U Phase A)
   - The classified changes (from §2U)
   - The modified yaml subtrees (and the modified EXECUTION_PLAN.md from
     §3U if this is a legacy 1.x plan)
   - The Dependency Sequencing Principles (`plan-producer-conventions/SKILL.md` §5)
3. Each specialist **reviews only the changed yaml subtrees** (or, for
   legacy 1.x, also the modified EXECUTION_PLAN.md sections from §3U)
   from their domain perspective. Output format:
   ```markdown
   ## <Role> Update Review
   | # | Severity | Change | Assessment | Suggestion |
   ```
   Severities: `CRITICAL`, `WARNING`, `SUGGESTION`
4. **Discussion phase** — apply the anti-sycophancy protocol from
   `plan-team-flow/SKILL.md` §5T.4. Focused on: does the change break
   existing assumptions? Are new dependencies correct? Does sequencing
   still hold?
5. **Synthesis** — apply the mandatory checkpoint from
   `plan-team-flow/SKILL.md` §5T.5. Print the synthesis state block with
   surviving findings and explicit verdict: `APPROVED` or `NEEDS RESOLUTION`.
6. **Resolution loop** (only if NEEDS RESOLUTION) — apply the
   resolution-loop pattern from `plan-team-flow/SKILL.md` §5T.6 with
   `max_rounds = 2` (instead of 3): compile CRITICAL + WARNING findings
   into a resolution brief, spawn the Fixer (`subagent_type: fixer`),
   re-review with affected specialists, re-synthesize with verdict,
   check convergence.
7. **Maximum 2 rounds** of review-fix (lighter since most of the plan is
   already validated). If issues remain after 2 rounds, present to user.

This is valuable for major restructuring (phase reordering, splitting tasks,
adding entire phases) where multiple perspectives catch more issues.

After 5U concludes, return to `/plan-project` Step 7 (YAML Synthesis).
