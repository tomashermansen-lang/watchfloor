---
name: plan-detection
description: Shared plan detection, task context loading, and crash recovery for flow commands. Schema 2.0 plans use the graph-as-index orientation flow; legacy 1.x plans fall back to heading-match.
user-invocable: false
---

# Plan Detection Protocol

Shared logic for detecting execution plans, loading task context, and managing
crash recovery markers. Flow commands reference this skill instead of
duplicating detection logic.

## Schema-Version Dispatch (R31)

Read the top of `execution-plan.yaml` (offset 0, limit 5). The first
`schema_version: <X>.<Y>.<Z>` line decides the orientation flow:

- `schema_version: 2.x.y` → graph-as-index five-step flow (R27).
- `schema_version: 1.x.y` → legacy heading-match against
  `EXECUTION_PLAN.md` (preserved for backwards compatibility).

Detection is deterministic — it does not depend on file presence beyond
the YAML itself.

## 5-Step Graph-as-Index Flow (R27, schema 2.0)

Emit a sentinel marker at orientation begin / end so autopilot stream
parsers can bracket the read events:

```bash
bash -c 'echo plan-detection-start'
# ... orientation reads ...
bash -c 'echo plan-detection-end'
```

### Step 1 — Project + phase + task orientation (one Bash call)

**Preferred path (plan-ownership Track 1, 2026-05-25 onwards):** invoke
`task-view.py` to get a self-contained projection of project, phase, and
task fields permitted to this phase by the consumption table:

```bash
python3 ~/.claude/tools/task-view.py \
  --plan "$PLAN_FILE" \
  --task <current-task-id> \
  --phase <current-phase>
```

`task-view.py` reads the per-phase consumption table from
`core/schema/plan-field-ownership.yaml` (single source of truth),
projects the plan down to the allowed subset (project fields + parent-
phase fields + own task block + dependency artifact_refs), and emits a
self-contained YAML fragment to stdout. **Sibling task blocks are
mechanically absent** — this is the read-isolation guarantee that
prevents the read-then-rewrite-siblings antipattern observed in commit
`7d434e3` (2026-05-25). Sibling task IDs are listed in a footer as an
escape valve: invoke `task-view.py --task <other-id>` if you genuinely
need another task's context.

**One Bash call replaces three Reads** (project + phase + task), and the
slice is byte-stable across runs (prompt-cache friendly).

**Fallback (legacy / `task-view.py` unavailable):**
- Step 1a: Read `execution-plan.yaml` with `offset: 0, limit: 80`.
  Extract: `vision`, `scope`, `success_criteria`, `kill_criteria`,
  `design_notes`, `risks`.
- Step 1b: Re-read at the parent phase's block. Extract:
  `overview_summary`, `sequencing_rationale`, `cross_cutting_constraints`,
  `kill_criteria_refs`.
- Step 1c: Re-read at the current task's block. The full task object
  is the context — `what`, `why`, `where`, `acceptance`, `prompt`,
  plus phase-specific fields per the consumption table below.

### Step 4 — Dependency-aware artefact loading

`task-view.py` (Step 1) already returns dependency identifiers plus the
`artifact_refs` keys this phase is permitted to read. For each
`artifact_refs` key on each dependency, Read that file. **One Read
per dependency artefact.**

If the fallback path is in use, dependency `what`/`why` are visible in
the Step 1c re-read; no extra Read needed for them.

### Step 5 — Status awareness

If any depends-task has `status != done`, warn the user:
"Task '<id>' depends on '<dep>' (status: <status>). Proceed anyway?"

## Read-budget bound (R29)

For schema 2.0 plans: **≤4 reads + 1 glob** when the current task has
exactly one dependency. With **N dependencies**, the budget is
**(3 + N) reads + 1 glob** — `project + phase + task = 3 reads`, plus
one Read per dependency artefact. **N=0 collapses to 3 reads.**

`/retro` is documented as exempt from this budget — it Reads ALL
`artifact_refs` to assemble cross-phase observations.

## No EXECUTION_PLAN.md reads on schema 2.0 (R30)

The skill SHALL NOT invoke the Read tool with a path ending in
`EXECUTION_PLAN.md` while orienting on a 2.0 plan. Verifiable from
`autopilot-stream.ndjson` via the `tool_use:Read` event names between
the `plan-detection-start` / `plan-detection-end` markers.

## Per-phase Consumption Table (R28)

This table is the binding contract. Each row names, for one phase agent:
the project-level fields it Reads, the parent-phase fields it Reads,
the task-level fields it Reads, the `artifact_refs` keys it loads from
each dependency, the `artifact_refs` it writes for its own task, and
notes.

| Phase agent | Project | Phase | Task | Reads (from deps) | Writes (own task.artifact_refs) | Notes |
|---|---|---|---|---|---|---|
| /ba | vision, scope, success_criteria, kill_criteria | overview_summary, sequencing_rationale, cross_cutting_constraints | what, why, where, acceptance, prompt | requirements_path | requirements_path | source-of-truth: REQUIREMENTS.md output |
| /ux | vision, success_criteria | overview_summary, sequencing_rationale | what, why, acceptance | requirements_path, plan_path | (none) | UI-only phases — exempt for non-UI features |
| /plan | vision, scope, design_notes, kill_criteria, risks | overview_summary, sequencing_rationale, cross_cutting_constraints | what, why, where, acceptance, constraints, estimate, manualtest_scenarios, prompt | requirements_path | plan_path | output: PLAN.md plus host plan task subtree |
| /review | scope, kill_criteria, risks | overview_summary, sequencing_rationale | what, why, where, acceptance, prompt | plan_path, requirements_path | review_path | solo light-mode review |
| /team-review | scope, kill_criteria, design_notes, risks | overview_summary, sequencing_rationale, cross_cutting_constraints | what, why, where, acceptance, constraints | plan_path, requirements_path | team_review_path | output: TEAM_REVIEW.md |
| /implement | scope, kill_criteria, design_notes | overview_summary, sequencing_rationale, cross_cutting_constraints | what, why, where, acceptance, constraints, estimate, prompt | plan_path, requirements_path, review_path OR team_review_path | (none — code only) | TDD red-green-refactor |
| /static-analysis | tech_stack, success_criteria | sequencing_rationale | where (modified files only) | (none — reads code) | static_analysis_path | runs sonarqube + coverage |
| /manualtest | success_criteria | overview_summary | manualtest_scenarios, manual_test, where | plan_path, requirements_path | manualtest report path | optional, full-pipeline only |
| /qa | success_criteria, kill_criteria | sequencing_rationale | where, acceptance, manualtest_scenarios | plan_path, requirements_path, static_analysis_path | qa_report_path | output: QA_REPORT.md |
| /team-qa | success_criteria, kill_criteria, risks | sequencing_rationale, cross_cutting_constraints | where, acceptance, manualtest_scenarios | plan_path, requirements_path, static_analysis_path | team_qa_path | output: TEAM_QA.md |
| /commit | (none) | gate.checklist | where, status | (none — reads git diff) | (none) | runs commit-preflight ratchet |
| /done | (none) | gate.checklist | status, artifact_refs | all populated artifact_refs | (none) | verifies feature closure, renames INPROGRESS_ → DONE_ |
| /hotfix | kill_criteria | overview_summary, sequencing_rationale | what, why, where, acceptance, prompt | requirements_path, plan_path | (none — code only) | bug fix code diff, no full TDD ceremony |
| /retro | vision, kill_criteria, risks, retro, retro_findings, deferred | overview_summary, gate, sequencing_rationale | what, why, phase_results, deviations, deferred_refs | ALL artifact_refs (exempt R29) | retro / retro_findings (project-level) | recurring per-phase retro |

## Multi-Plan Disambiguation (edge case 13)

If the Glob `docs/INPROGRESS_Plan_*/execution-plan.yaml` returns >1 hit:
1. Prefer the plan whose `name` matches the active branch
   (`git branch --show-current` → `feature/<X>` → `INPROGRESS_Plan_<X>`).
2. Fallback: most recent mtime.
3. Emit `WARNING: multiple plan files found at <list>; using <selected>`.
   Operator action: archive stale plan dirs to `docs/DONE_Plan_*` so the
   warning stops firing.

## Plan Detection (entry point — applies to both versions)

Run after worktree validation but before the command's main work.

### Step 0.5: Plan Detection (automatic, non-blocking)

1. **Check `$PLAN_FILE` first.** If the env var is set AND the file exists,
   skip the Glob entirely and use this path directly. Autopilot exports
   `PLAN_FILE` at run-start (after multi-plan disambiguation runs once)
   precisely so every phase agent skips the redundant Glob. Verifiable via
   `[[ -n "${PLAN_FILE:-}" && -f "$PLAN_FILE" ]]` in any pre-orientation
   Bash check. Saves 5–7 Glob calls per multi-phase autopilot run.
   *Reinforced (2026-05-24 afternoon):* `run_phase` in
   `claude-session-lib.sh` now ALSO injects a `PLAN PATH: <path>`
   directive directly into every phase's system prompt when `PLAN_FILE`
   is set, instructing the agent NOT to glob `docs/INPROGRESS_Plan_*`.
   Earlier-day canary measurements showed Sonnet ignoring the
   SKILL-level advice and globbing anyway; the direct prompt injection
   bypasses the SKILL-loading round-trip.
2. Otherwise, search for `docs/INPROGRESS_Plan_*/execution-plan.yaml` in
   the worktree root using the Glob tool (standalone flow path).
3. If exactly one plan found: load it with the Read tool.
4. If multiple plans found: apply Multi-Plan Disambiguation above.
5. If no plan found: proceed standalone — no warnings, no behavior change.

When a plan is found: read its `schema_version` and dispatch to the 2.0
or 1.x flow per "Schema-Version Dispatch" above.

## Legacy 1.x Flow (preserved verbatim)

The 1.x flow remains the original Step 0.6 auto-orient described in this
file's previous revision. Summary: budget 2 reads + 1 glob; reads
`execution-plan.yaml` (task graph) and the project-plan markdown
(narrative); does NOT read `SETUP_PLAN.md`. Heading-match in
`EXECUTION_PLAN.md` provides supplementary task context per Task Context
Loading § 4 below.

### Step 0.6: Auto-Orient (1.x only — context-aware, minimal reads)

**Budget: 2 file reads + 1 glob.** Do not scan everything — be surgical.

1. **Read execution plan YAML** (1 read) — read `execution-plan.yaml`.
   Note task statuses, identify the current task's phase, and list its
   direct dependencies.

2. **Read project plan overview** (1 read, first 40 lines only) — from
   the YAML `sources` array, find the entry that is NOT `SETUP_PLAN.md`
   and NOT `execution-plan.yaml` itself; Read its first 40 lines.

3. **Note dependencies from YAML** — extract dependency names and
   statuses from the YAML (already loaded). Do NOT read dependency files
   during orientation.

4. **List (don't read) parallel work** — Glob `docs/INPROGRESS_*/`.

5. **Summarize context** in 2-3 lines.

## Task Context Loading

Match the feature name against task IDs in the plan using 4-tier matching
(Exact, Normalized, Fuzzy, No-match — unchanged).

### Loading Context

If a task is found:
1. **Task prompt:** use `task.prompt` as additional context.
2. **Acceptance criteria:** include `task.acceptance` alongside the
   command's own criteria.
3. **Dependencies:** check `task.depends`. If incomplete, warn.
4. **Markdown context (1.x only):** Read `EXECUTION_PLAN.md` in the same
   directory. Search for a markdown heading matching the task name. **Do
   NOT do this on 2.0 plans — see R30 above.**
5. **Prior phase results:** if the task has `phase_results` entries,
   display them in a summary block.

## Predecessor Context Loading

When a task has completed dependencies, commands that produce new
artifacts (`/ba`, `/plan`, `/testplan`, `/implement`, `/review`, `/qa`)
should understand what predecessors established.

### Schema 2.0 — compact predecessor context (backlog #64)

**Preferred path:** invoke `predecessor-context.py` to compose a
phase-tuned, compact context block. The helper consumes the new
`codebase_snapshot` + `predecessor_context` fields on each
dependency task and emits exactly what the consuming phase needs —
nothing more.

```bash
python3 adapters/claude-code/claude/tools/predecessor-context.py \
  --plan <execution-plan.yaml> \
  --task <current-task-id> \
  --phase <ba|plan|testplan|implement|review|qa>
```

Phase profiles (what the helper emits per dependency):

| Phase | Decision shadow | Interfaces | Tests added | Diff stat | Full diff | Symbol map |
|-------|---|---|---|---|---|---|
| `/ba` | ✓ | | | | | |
| `/plan` | ✓ | ✓ | | ✓ | | ✓ |
| `/testplan` | | ✓ | ✓ | | | |
| `/implement` | ✓ | ✓ | | ✓ | ✓ | ✓ |
| `/review` | ✓ | ✓ | | ✓ | | ✓ |
| `/qa` | | ✓ | ✓ | | | |

**Symbol map** (canary A/B/C antipattern fix, 2026-05-24): per-file
function/class/method listing with line ranges, derived from each
dependency's `codebase_snapshot.symbol_map` (if persisted by `/done`)
or extracted on-the-fly via `lib/extract_symbols.py`. Lets the agent
navigate the predecessor's touched files with `Read --offset --limit`
instead of pulling the whole file — the Aider repo-map pattern. Empirical
backing: claude-code issue #34304 measured 80% context reduction on
multi-file work.

**Backward-compat:** the helper emits a fallback note for any
dependency that lacks both `codebase_snapshot` and
`predecessor_context` — pointing the caller at the artifact files
to read directly. This makes the migration incremental: older
completed tasks keep working under the old artifact-read path
while new tasks accrete the compact metadata.

**Producer:** `/done` populates `codebase_snapshot` (commit ref,
modules, interfaces, tests) and `predecessor_context` (constraints,
rejected, contract) for the completing task. See the /done command
for the extraction protocol.

### Schema 1.x fallback (legacy plans only)

Read `docs/DONE_Feature_<dep-id>/REQUIREMENTS.md`, `QA_REPORT.md`,
and `DESIGN.md` (3 reads per dependency). The compact helper does
not apply to 1.x plans — they have no schema slot for the metadata.

## Status Updates

Flow commands update task status at checkpoints using Edit on the YAML
file. Status values: `pending | wip | done | failed | skipped | blocked`.

### `/start` Updates
- Edit `task.status` from `pending` to `wip`.
- Edit `task.last_updated` to current ISO 8601 timestamp.

### `/done` Updates
- Edit `task.status` from `wip` to `done` (or `skipped` with `--skip`).
- Edit `task.last_updated` to current ISO 8601 timestamp.

**Immutability (P1):** Status updates are the ONLY modification flow
commands make to the plan file. Never modify task names, descriptions,
dependencies, or acceptance criteria.

## Shared Closing Step (Phase Results Tracking)

All plan-aware phases (ba, plan, review, team-review, implement, hotfix,
qa, team-qa, static-analysis, manualtest) execute this step after their
primary work completes. NO-OP when no plan is loaded or when the task has
no `acceptance` criteria.

### Phase-to-Artifact Mapping

| Phase | Output artifact |
|-------|----------------|
| ba | REQUIREMENTS.md |
| plan / architect | PLAN.md |
| review | (review comments — inline in conversation) |
| team-review | TEAM_REVIEW.md |
| implement | code diff (`git diff main...HEAD`) |
| static-analysis | STATIC_ANALYSIS.md |
| manualtest | (manual test notes — inline in conversation) |
| qa | QA_REPORT.md |
| team-qa | TEAM_QA.md |
| hotfix | code diff (`git diff main...HEAD`) |

### Protocol

1. Compare the phase's output against `task.prompt` and `task.acceptance`.
2. Self-assess `conformance` (aligned|deviated) and `acceptance_status`
   (met|partial|unmet). List deviations with type, description, reason,
   impact, and affected criteria.
3. Produce a JSON `phase_result` and write it via:
   ```
   echo '<json>' | python3 claude/tools/deviation-tracker.py \
     --plan-yaml <path-to-execution-plan.yaml> --task-id <task-id>
   ```
4. If the write fails, log the error but do NOT block the phase.

## Crash Recovery Markers

### Directory Convention
Markers live in `.planning/` in the worktree root (gitignored).

### Write Marker — `/start`
1. `mkdir -p .planning`.
2. Write `.planning/active-<task_id>.json` with
   `{"task_id": "<id>", "started_at": "<ISO8601>", "plan_path": "<path>"}`.

### Remove Marker — `/done`
1. `rm -f .planning/active-<task_id>.json`.

### Detect Stale Markers — Plan Detection
During Step 0.5, also Glob `.planning/active-*.json`. If a marker exists
for the current feature:
- If task status is `done`: remove the stale marker.
- If task status is `wip`: warn — Resume or Reset.

### Multiple Markers
Use the most recent `started_at`. Warn about duplicates.

## Gate Evaluation

After `/done` updates a task status, check whether all tasks in the same
phase are now `done`/`skipped`. If so, run the phase's `gate.command`
(if defined) and report PASS/FAIL.

## Per-Command Context Usage

| Command | Plan context used for |
|---------|----------------------|
| `/start` | Dependency check, status → `wip`, create marker |
| `/ba` | Plan acceptance criteria augment requirements; predecessor context per the consumption table |
| `/ux` | Plan task context as design input; predecessor context per the consumption table |
| `/plan` | Plan task context as architecture input |
| `/review` | Plan acceptance criteria as additional review targets |
| `/implement` | Plan acceptance criteria become additional TDD test targets |
| `/manualtest` | Plan acceptance criteria as test checklist items |
| `/qa` | Plan acceptance criteria as quality verification targets |
| `/done` | Status → `done`/`skipped`, remove marker, gate check |
