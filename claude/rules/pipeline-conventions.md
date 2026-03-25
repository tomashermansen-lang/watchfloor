---
paths:
  - "claude/commands/**/*.md"
---

# Pipeline Command Conventions

## Structure
- Frontmatter: `description`, `argument-hint`, optional `disable-model-invocation`
- Support two modes: **flow** (worktree-isolated, phase commits) and **standalone** (direct)
- Flow mode uses the flow-mode skill protocol

## Checkpoints (flow mode)
- Format: `Continue? [option1 / option2 / stop]`
- `On [yes]` block is a contract — execute those exact commands
- Always include `stop` option for pausing
- If `$ARGUMENTS` contains `autopilot`: auto-approve, do not wait

## Phase Commits
- Each phase commits its artifacts before handing off
- Commit message: `phase(<phase>): <what was produced>`
- Never skip the phase commit — next phase reads from disk

## Plan Detection
- Commands that read feature artifacts must start with Step 0.5 (plan detection glob)
- Pattern: `docs/INPROGRESS_Plan_*/execution-plan.yaml`
