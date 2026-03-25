---
name: flow-mode
description: Flow mode protocol for semi-autonomous skill chaining with human checkpoints. Defines worktree management, checkpoint format, and pipeline progression.
user-invocable: false
---

# Flow Mode Protocol

Semi-autonomous skill chaining with human checkpoints.

## Activation

First argument `flow` activates: `/ba flow <feature>`, `/plan flow <feature>`, etc.

## Principles

1. **Human-in-the-loop** — Every phase needs explicit approval
2. **Fail-safe** — Failures stop the flow
3. **Reversible** — Feature branches isolate changes
4. **Transparent** — Checkpoints show what happens next
5. **Context-aware** — Large features checkpoint per component
6. **No broken windows** — Surface issues, don't bury them

### Quality Protocol: Observe-Log-Surface (applies to ALL commands)

AI agents are local optimizers — they fix what they see without modeling
downstream effects. Research shows 75% of AI agents break previously working
code during long-term maintenance (SWE-CI 2025). Drive-by fixes carry real
regression risk. But silently ignoring issues is equally bad — it accumulates
technical debt that reduces future velocity by 50-64% (Cursor study 2025).

**The protocol is: observe, log, surface — then let the human decide.**

**When you encounter a pre-existing issue during any phase:**

1. **Blocking issues** (test suite won't pass, build broken):
   → Fix it — you can't ship with a broken suite. Commit separately with
   `fix(<scope>): <description>`. Run full test suite before AND after the
   fix. If any previously-passing test fails, revert immediately.

2. **Non-blocking issues** (warnings, code smells, stale code, tech debt):
   → **Do NOT silently fix or silently ignore.** Instead:
   - Note what you found and where
   - At checkpoint, present a **Quality Findings** section:
     ```
     ## Quality Findings (discovered during this phase)
     | # | File | Line | Description | Estimated effort |
     ```
   - The user decides: fix now (separate commit), create hotfix task, or defer.

3. **Issues in files you are already modifying:**
   → These are safer to fix because you have context. Ask: "Found [issue] in
   [file] which I'm already editing. Fix in a separate commit? (~N min)"
   The user may approve inline since the regression risk is lower.

**Why not "fix everything":**
- AI agents lack the temporal model to know if a fix is safe system-wide
- Drive-by fixes in untouched code have high regression risk
- Mixed commits (feature + fixes) are unreviewable and hard to revert
- Context window fills with fix attempts, degrading primary task quality

**Why not "ignore everything":**
- "Pre-existing, not related to our changes" is how broken windows accumulate
- The issue was invisible before — you've now surfaced it, which has value
- Silently skipping means the human never learns about the problem

**Commit separation (MANDATORY when fixing):**
- Feature work: `feat(<scope>):` or `docs(<scope>):`
- Drive-by fixes: `fix(<scope>):` — always a separate commit
- Never mix feature and fix code in the same commit

## Two Modes

| | Flow Mode | Standalone Mode |
|---|---|---|
| Activation | `/ba flow <feature>` | `/ba <feature>` |
| Requires worktree | Yes | No |
| Phase commits | Yes (audit trail) | No |
| Next step suggestion | `/plan flow <feature>` | `/plan <feature>` |
| Completion | `/commit flow` → merge + cleanup | `/commit` → normal commit |

**Flow mode requires a worktree.** If not in a worktree, commands refuse and point to `/start`.

**Standalone mode works anywhere** — main or worktree.

## Worktree Management

| Command | Creates | Branch |
|---|---|---|
| `/start <feature>` | Worktree sibling dir | `feature/<feature>` |
| `/start-hotfix <name>` | Worktree sibling dir | `hotfix/<name>` |

After creation, the user must switch to the worktree in VSCode and start a new Claude session.
The worktree path is determined by the project's `scripts/worktree.sh` script.

### Worktree Structure

```
../<worktree-dir>/
  ├── .env → symlink (if project uses .env)
  ├── CLAUDE.md                              ← Git-tracked (from checkout)
  └── feature/<feature>                      ← Feature branch
```

### Cleanup (at flow end)

`/commit flow` automatically (all in ONE Bash call, starting with `cd main_worktree`):
1. `cd` to main worktree (MUST happen before any destructive step)
2. Merges to main
3. Pushes to remote
4. Removes worktree directory (`git worktree remove`, never `rm -rf`)
5. Deletes feature branch
6. **STOP** — no further tool calls (working directory is deleted)

**Why one call:** If the worktree is deleted while it's the Bash cwd, the shell
becomes permanently broken for this session (every command fails with "Path does
not exist"). The `cd` to main_worktree prevents this.

## Pipeline

```
/start <feature> → creates worktree → user switches window
                                            ↓
/ba flow ──┬──→ /ux flow → /plan flow → /review flow (auto-fix loop)
           │                                 │
           └──→ /plan flow ─────────────────→┤
                (backend-only)               │
                                             ↓
                                     /implement flow
                                             │
                                             ↓
                                  /static-analysis flow
                                             │
                                             ↓
                                   /manualtest flow
                                             │
                                             ↓
                                       /qa flow
                                             │
                                             ↓
                                     /commit flow → STOP
```

**Hotfix flow:**
```
/start-hotfix <name> → creates worktree → user switches window
                                               ↓
                        /hotfix → TDD fix → manual test → commit
                                               ↓
                                      /commit flow → STOP
```

**Team pipeline (optional):**
```
/start → /ba flow → /ux flow → /plan flow → /team-review flow → /review flow → /implement flow → /static-analysis flow → /manualtest flow → /team-qa flow → /qa flow → /commit flow
```

**Autopilot pipeline (for autopilot-eligible tasks):**
```
Option A — from worktree:
  bash ~/.claude/tools/autopilot.sh <task>

Option B — from main project (creates worktree automatically):
  bash ~/.claude/tools/autopilot.sh --full <task>

Pipeline:
  /ba flow → /plan flow → /team-review flow → /implement flow → /static-analysis flow → /team-qa flow → /commit flow
                                    ↓
  Fully autonomous. Each phase runs in a fresh interactive Claude session
  via tmux. Agent teams, fixer loops, and all features work.
  Merges to main and cleans up worktree on success.

Skipped: /ux (backend), /manualtest (no UI), /review (team-review covers it)
Each phase: separate tmux Claude session (fresh context), artifacts on disk.
Dashboard receives events for monitoring.
```

**Standalone (no worktree):**
```
/ba <feature> → /ux → /plan → /review → /implement → /static-analysis → /manualtest → /qa → /commit
```

**Refactoring flow:**
```
/start <feature> → creates worktree → user switches window
                                            ↓
                          /refactor flow <feature>
                                            ↓
                                    /manualtest flow
                                            ↓
                                      /qa flow
                                            ↓
                                    /commit flow → STOP
```

## Checkpoint Contract

Every checkpoint MUST use this exact format. No variations, no improvisation.

```
<Phase> complete: <status>

<Summary — 3-5 sentences>

Files written: <list>
Branch: <branch>

On [yes]:
  1. <phase commit — exact git add + git commit>
  2. STOP — open a new chat and run: /<next-command> flow <feature>

On [amend]:
  → <what specifically gets revised>

On [stop]:
  → Pause flow. Resume later in a new chat: /<current-command> flow <feature>

Continue? [yes / amend / stop]
```

### Autopilot Mode

When `$ARGUMENTS` contains `autopilot`, the pipeline is running headless.
In autopilot mode:
- **Auto-approve all checkpoints** — select `yes` automatically, do not wait
- **Skip token cost confirmations** — auto-proceed
- **Execute the `On [yes]` block** (commit), then exit cleanly
- The autopilot shell script handles launching the next phase

**CRITICAL: Autopilot does NOT change quality or process.** The `autopilot`
keyword ONLY affects checkpoints and confirmations. It does NOT:
- Lower the quality bar or skip steps
- Grant authority to auto-apply suggestions that would require human review
- Change how agents make decisions or what findings they report
- Allow "quick wins" or "domain expert authority" shortcuts

Autopilot means "no human at the checkpoint" — NOT "no human oversight."
Run the exact same process as manual mode. The human reviews the result
at the end.

### Checkpoint Rules (MANDATORY)

1. **The `On [yes]` block is a contract.** Execute those exact commands in that
   exact order. No additions, no substitutions, no "helpful" extra steps.
2. **STOP after phase commit.** Do NOT invoke the next command in the same session.
   Output the "next session" prompt and stop. This prevents context exhaustion
   across phases and gives the dashboard distinct session events per phase.
3. **Never commit files not listed** in the `On [yes]` block.
4. **Never improvise cleanup**, refactoring, or additional steps beyond the contract.
5. **Each choice maps to exactly one outcome.** If the user says "yes", there is
   only one possible action sequence — the one written in the checkpoint.

### Why STOP Between Phases

Each phase (ba, plan, review, implement, etc.) runs in its own chat session:
- **Context isolation** — each phase gets full context window, no "prompt too long"
- **Dashboard visibility** — distinct sessions per phase for monitoring
- **Skill access** — each session loads the correct command with all skills
- **Crash recovery** — if a session dies, only one phase is lost

### User choices

- `yes` → Execute phase commit, then STOP. User opens new chat for next phase.
- `amend` → Revise current output (loop back within same session)
- `stop` → Pause flow, keep worktree for later resumption

## Phase Commits

Each phase commits its artifact when the user approves (`yes`). Only in flow mode.

```
docs(<feature>): define requirements     ← /ba approved
docs(<feature>): design UX              ← /ux approved
docs(<feature>): architect plan          ← /plan approved
docs(<feature>): team review report      ← /team-review approved
docs(<feature>): review — auto-fixed plan ← /review approved
feat(<scope>): implement <feature>       ← /implement complete
docs(<feature>): static analysis report  ← /static-analysis approved
docs(<feature>): manual test log         ← /manualtest approved
docs(<feature>): team QA report           ← /team-qa approved
docs(<feature>): QA report               ← /qa approved
Merge feature/<feature>                  ← /commit flow
```

**Rules:**
- Only commit in flow mode (not standalone usage)
- Selective staging: `git add src/ tests/ config/ ui/ docs/ generators/ migrations/` (never `git add -A`)
- Commit AFTER user approves, BEFORE STOP
- Scopes: `analytics`, `agents`, `api`, `eval`, `ui`, `config`, `docs`, `db`

## Docs Path Resolution

Feature docs have a status-and-type prefix: `PENDING_Feature_<feature>/`, `INPROGRESS_Feature_<feature>/`, or `DONE_Feature_<feature>/`.
Plan docs use: `PENDING_Plan_<plan>/`, `INPROGRESS_Plan_<plan>/`, or `DONE_Plan_<plan>/`.

**Rule:** When any command references `docs/<feature>/`, resolve the actual path first:
- Look for `docs/INPROGRESS_Feature_<feature>/`, then `DONE_Feature_`, then `PENDING_Feature_`, then unprefixed
- If none exists, create as `docs/INPROGRESS_Feature_<feature>/` (inside worktree) or `docs/PENDING_Feature_<feature>/` (on main)

## Research Protocol

- **Use custom subagents** for research: `test-explorer` for test analysis, `code-reviewer` for quality checks. For general research, use `general-purpose` Task subagents.
- **Parallelize**: one subagent per research area.
- **Weight newest sources** — prefer 2025-2026 over older.
- WebSearch is OK. WebFetch ONLY for domains in `.claude/config/research_sources.md`.

## Phase Detection

| Docs present | Phase complete | Next command |
|---|---|---|
| None | Not started | `/ba flow` |
| REQUIREMENTS.md | BA | `/ux flow` or `/plan flow` |
| + DESIGN.md | UX | `/plan flow` |
| + PLAN.md | Plan | `/review flow` |
| + TEAM_REVIEW.md (optional) | Team Review | `/review flow` or `/implement flow` |
| + PLAN.md (reviewed) | Review | `/implement flow` |
| + TESTPLAN.md | Implement | `/static-analysis flow` |
| + STATIC_ANALYSIS.md | Static Analysis | `/manualtest flow` |
| + MANUAL_TEST_LOG.md | Manual test | `/qa flow` |
| + TEAM_QA.md (optional) | Team QA | `/qa flow` or `/commit flow` |
| + QA_REPORT.md | QA | `/commit flow` |

## Worktree Validation

Flow mode commands ALWAYS validate they are in a worktree. If on main, refuse and point to `/start`.

This prevents accidentally running `/ba flow feature-b` inside the wrong worktree.

## Rules

- NEVER skip checkpoints
- NEVER continue after failure
- NEVER merge without passing tests
- NEVER run parallel flows on same working directory
- NEVER proceed in a worktree that doesn't match the requested feature
- NEVER run commands after worktree cleanup
- NEVER run `/commit flow` on main
