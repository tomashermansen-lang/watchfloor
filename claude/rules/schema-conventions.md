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
