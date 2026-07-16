---
paths:
  - "claude/schema/**/*.json"
  - "**/*execution-plan*.yaml"
  - "**/*execution-plan*.yml"
---

# Execution Plan Schema Conventions

## YAML Format
- Must validate against `claude/schema/execution-plan.schema.json`
- Required top-level: `schema_version`, `name`, `phases`
- Each task needs: `id`, `name`, `status`, `depends`, `prompt`, `acceptance`
- Status enum: pending | wip | done | failed | skipped | blocked

## Autopilot Flag
- `autopilot: true` only when ALL criteria met: pure backend, no manual testing,
  unambiguous acceptance criteria, no novel architecture, no security-sensitive changes
- Default is `false` — must be explicitly set during team planning (5T.4)

## Changelog
- Every plan update adds a changelog entry: `date`, `type`, `description`, `affected`
- Types: added | changed | removed | reordered | scope_change

## Auto-Populated Task Fields (do NOT author at planning time)

These fields are written by downstream phases, not by `/plan-project` or
`/plan-project --update`. They form the knowledge graph consumed by
`predecessor-context.py` (backlog #64) and by the dashboard.

| Field | Populated by | Consumed by |
|---|---|---|
| `codebase_snapshot` | `/done` Step 3.5 | `predecessor-context.py` for dependent tasks |
| `predecessor_context` | `/done` Step 3.5 | `predecessor-context.py` decision-shadow block |
| `artifact_refs` | each phase that produces an artifact | dashboard, plan-detection orientation |
| `phase_results` | Shared Closing Step (every plan-aware phase) | deviation-tracker, dashboard |
| `deviations` | deviation-assessor | dashboard, retro |
| `auto_update` | various auto-updaters | downstream tools |

**Planning rule:** never write these fields when authoring or updating a
plan. **Preservation rule:** `/plan-project --update` MUST preserve them
on any `done`/`skipped` task it touches (see plan-update-flow §4U).
Silently dropping them breaks the lean-context contract for any task
that depends on the modified task.
