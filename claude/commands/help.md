---
description: Help — quick-start guide for the Claude workflow system
disable-model-invocation: true
---

# Help: Workflow Quick Start

Quick orientation for the Claude workflow system.

## Workflow

IMPORTANT: Print the ENTIRE guide below VERBATIM. Do NOT summarize, condense,
or omit any sections. Output every line exactly as written, including all
diagrams, tables, and the full Project Planning section.

---

## Development Quick Start

### Workflow Philosophy

This project uses a **structured AI-assisted workflow** with three core principles:

1. **Human-in-the-loop** — Every phase requires your approval before continuing
2. **Test-Driven Development** — Tests are written BEFORE implementation
3. **Three modes** — Flow mode (full pipeline), hotfix mode (quick TDD fix), standalone (no worktree)

### Three Ways to Work

**Flow mode** — Full pipeline with isolated worktree, phase commits, and audit trail:
```
/start <feature>  → creates worktree, switch to it in VSCode
/ba flow <feature> → requirements → /plan flow → /review flow → ...
/commit flow       → merge to main, cleanup worktree, DONE
```

**Hotfix mode** — Quick TDD bug fix with isolated worktree, no formal QA:
```
/start-hotfix <name> → creates hotfix worktree, switch to it
/hotfix <bug>        → TDD fix + manual test
/commit flow         → merge to main, cleanup worktree, DONE
```

**Standalone** — Same commands, no worktree, works directly on main:
```
/ba <feature> → requirements → suggests /plan <feature> → ...
/commit       → normal commit (no merge, no cleanup)
```

### Flow Mode Pipeline

```
┌───────────────────────────────────────────────────────────────────┐
│                       FEATURE PIPELINE                            │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  /start <feature> ──→ creates worktree ──→ switch window          │
│                                                ↓                  │
│  /ba flow ──┬──→ /ux flow ──→ /plan flow ──→ REVIEW              │
│             │                                    │                │
│             └─────────────→ /plan flow ─────────→┤                │
│                             (backend-only)       │                │
│                                   ┌──────────────┴──────────┐    │
│                                   │                         │    │
│                            /team-review flow          /review flow│
│                           (two-phase: team             (single   │
│                            sweep + deep dive)        perspective) │
│                                   │                         │    │
│                                   └──────────┬──────────────┘    │
│                                              ↓                   │
│                                       /implement flow            │
│                                              │                   │
│                                              ↓                   │
│                                   /static-analysis flow          │
│                                              │                   │
│                                              ↓                   │
│                                     /manualtest flow             │
│                                        │            │            │
│                                  /checkpoint    (bypass)         │
│                                  (save point)       │            │
│                                              ↓                   │
│                                         QA GATE                  │
│                                   ┌──────┴──────┐               │
│                                   │             │               │
│                            /team-qa flow    /qa flow             │
│                           (two-phase: team   (single             │
│                            sweep + deep QA) perspective)         │
│                                   │             │               │
│                                   └──────┬──────┘               │
│                                          ↓                       │
│                                    /commit flow                  │
│                                          │                       │
│                                        DONE                      │
├───────────────────────────────────────────────────────────────────┤
│  ANYTIME TOOLS (usable at any flow phase)                        │
│                                                                   │
│  /checkpoint — save tagged progress without leaving phase        │
│  /sync       — pull latest main into feature branch              │
├───────────────────────────────────────────────────────────────────┤
│                        HOTFIX FLOW                                │
│                                                                   │
│  /start-hotfix <name> ──→ switch window ──→ /hotfix <bug>        │
│      ──→ TDD fix ──→ manual test ──→ /commit flow → DONE        │
└───────────────────────────────────────────────────────────────────┘
```

### Team Commands (Agent Teams)

When the `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` flag is enabled, three commands
use multi-specialist teams. Each specialist is a reusable agent defined in
`.claude/agents/` with a thin role (expertise + standards). The command injects
the task-specific prompt at spawn time.

**Team Review** (`/team-review`) — replaces `/review`:
```
Phase 1: Team Sweep         Phase 2: Deep Dive          Triage
┌─────────────────────┐     ┌─────────────────────┐     ┌──────────┐
│  4 specialists       │     │  Single deep pass    │     │ Vote on  │
│  (analyst, ux-       │──→  │  (SOLID, TDD, code   │──→  │ adopt or │
│   designer, archi-   │     │   review, regressions)│     │ defer    │
│   tect, lead-dev)    │     │  + fixer loop        │     │ each one │
│  + discussion        │     │                      │     │          │
│  + fixer loop        │     │                      │     │          │
└─────────────────────┘     └─────────────────────┘     └──────────┘
```

**Team QA** (`/team-qa`) — replaces `/qa`:
```
Phase 1: Team Sweep         Phase 2: Deep QA            Triage
┌─────────────────────┐     ┌─────────────────────┐     ┌──────────┐
│  5 specialists       │     │  Adversarial QA      │     │ Vote on  │
│  (qa-engineer,       │──→  │  (test runs, coverage │──→  │ adopt or │
│   security-auditor,  │     │   verification, code  │     │ defer    │
│   performance-eng,   │     │   review, regressions)│     │ each one │
│   code-reviewer,     │     │  + fixer loop        │     │          │
│   qa-engineer lead)  │     │                      │     │          │
└─────────────────────┘     └─────────────────────┘     └──────────┘
```

**Team Planning** (`/plan-project --team` or `--team-lite`):
```
Phase A: Analysis          Phase B: Synthesis       Phase C: Discussion
┌─────────────────────┐    ┌───────────────────┐    ┌──────────────────┐
│  8 specialists       │    │  Architect merges  │    │  Team challenges  │
│  (architect, analyst,│──→ │  all input into    │──→ │  the draft plan   │
│   ux, lead-dev,      │    │  draft plan        │    │  + fixer loop     │
│   security, perf,    │    │                    │    │  (same evaluator- │
│   qa, devops)        │    │                    │    │   optimizer as     │
└─────────────────────┘    └───────────────────┘    │   team-review)    │
  --team-lite: 3 only                               └──────────────────┘
  (architect, analyst,                             Then: adversarial review
   lead-dev)                                       (critic + fixer loop)
```

Common to all team commands:
- **Evaluator-Optimizer pattern** — reviewers evaluate (read-only), Fixer fixes (write), no agent marks its own work
- **Explicit `subagent_type`** — each specialist spawned with its agent definition (tools, skills, model), not inline prompts
- **One checkpoint** — you see the combined result after all phases
- **Anti-sycophancy** — specialists must challenge with reasoning, not praise
- **Suggestion triage** — reviewers vote adopt/defer; majority-adopt items applied automatically
- **Shared fixed-issues log** — later phases skip what earlier phases fixed
- **Graceful fallback** — partial results reported if any phase fails

### Project Planning (`/plan-project`)

For multi-feature work, `/plan-project` creates a project-level plan that sits
ABOVE the feature pipeline. Each task in the plan becomes a feature that goes
through the full SDLC pipeline independently.

**Three modes:**

| Mode | Flag | Use when |
|------|------|----------|
| **Create** | (default) | New project plan from scratch |
| **Update** | `--update` | Modify existing plan — add tasks, restructure phases, expand scope. Preserves all done/wip statuses and adds changelog |
| **Team** | `--team` or `--team-lite` | Collaborative plan design with specialist agents (requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` flag) |

Modes combine: `--update --team` uses the full specialist team to review plan changes.

```
┌─────────────────────────────────────────────────────────────────────┐
│                      PROJECT PLANNING FLOW                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  CREATE MODE: /plan-project <name> [--team|--team-lite]             │
│       │                                                             │
│       ├──→ Dialog (scope, vision, tech stack, codebase scan)        │
│       ├──→ Template selection (greenfield / feature / refactor)     │
│       ├──→ Generate SETUP_PLAN.md + EXECUTION_PLAN.md               │
│       │    └──→ With --team: 8 specialists design collaboratively   │
│       ├──→ Adversarial review loop (critic → fix → re-check)       │
│       ├──→ YAML synthesis → execution-plan.yaml (with changelog)    │
│       ├──→ Schema validation                                        │
│       └──→ Commit to main (so worktrees can access the plan)        │
│                                                                     │
│  UPDATE MODE: /plan-project <name> --update [--team|--team-lite]    │
│       │                                                             │
│       ├──→ Load existing plan, show status summary                  │
│       ├──→ Change dialog (what to add/modify/restructure)           │
│       ├──→ Classify changes (add/modify/reorder/split/remove)       │
│       ├──→ Surgical edits to EXECUTION_PLAN.md + YAML               │
│       │    (preserves done/wip statuses, adds changelog entry)      │
│       ├──→ Update review (focused on changed sections only)         │
│       ├──→ Schema validation                                        │
│       └──→ Commit update to main                                    │
│                                                                     │
│  Result: docs/INPROGRESS_Plan_<name>/                               │
│    ├── SETUP_PLAN.md          (infrastructure & prerequisites)      │
│    ├── EXECUTION_PLAN.md      (phases, tasks, acceptance criteria)  │
│    └── execution-plan.yaml    (machine-readable task graph)         │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                     PLAN EXECUTION                                  │
│                                                                     │
│  Phase 1: Setup                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│  │ Task A   │  │ Task B   │  │ Task C   │  ← parallel worktrees    │
│  │ /start A │  │ /start B │  │ /start C │                          │
│  │ ba→plan→ │  │ ba→plan→ │  │ ba→plan→ │  ← each runs full SDLC   │
│  │ impl→qa  │  │ impl→qa  │  │ impl→qa  │                          │
│  │ →done    │  │ →done    │  │ →done    │                          │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                          │
│       └──────────────┼──────────────┘                               │
│                      ↓                                              │
│               ┌─────────────┐                                       │
│               │ PHASE GATE  │  ← all tasks done + checklist pass    │
│               └──────┬──────┘                                       │
│                      ↓                                              │
│  Phase 2: Core Features                                             │
│  ┌──────────┐  ┌──────────┐                                         │
│  │ Task D   │  │ Task E   │  ← depends on Phase 1 gate             │
│  │ /start D │  │ /start E │                                         │
│  │ ...      │  │ ...      │                                         │
│  └──────────┘  └──────────┘                                         │
│       ...          ...                                              │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Key concepts:**
- **Tasks = features** — each task runs `/start <task-id>` → full SDLC pipeline → `/done`
- **Parallel execution** — tasks within a phase run in separate worktrees simultaneously
- **Phase gates** — all tasks in a phase must complete before the next phase starts
- **Plan-aware commands** — pipeline commands auto-load task context (acceptance criteria, dependencies) from the execution plan
- **Status tracking** — task statuses update in the YAML as work progresses

**What happens in flow mode:**
1. `/start <feature>` → Creates worktree, renames docs to `INPROGRESS_Feature_`
2. You switch to that folder in VSCode (File → Open Folder)
3. Each step produces a doc in `docs/INPROGRESS_Feature_<feature>/` and ends with a checkpoint
4. `/commit flow` → Merges to main, renames docs to `DONE_Feature_`, cleans up worktree

### Execution Plan Integration

When a project has an execution plan (YAML task graph), all pipeline commands automatically:
- Load task context (prompt, acceptance criteria, dependencies)
- Orient to the project's current state (completed work, parallel tasks)
- Check for drift between implementation and plan

Without an execution plan, commands work identically — no setup needed.

### Before the Pipeline: Product Manager

Run `/productmanager` to get a strategic overview. It reviews all backlog items, scores them with a Benefit/Ease/Confidence/Risk/Time Criticality matrix, identifies obsolete requirements, and recommends what to build next. Output: `docs/PRODUCT_REVIEW.md`.

### Pipeline Roles

| Command | Role | Responsibility |
|---------|------|----------------|
| `/productmanager` | Product Manager | Review backlog, prioritize, identify gaps, recommend what to build next |
| `/start` | Setup | Create worktree and feature branch for flow mode |
| `/start-hotfix` | Setup | Create hotfix worktree for quick bug fixes |
| `/ba` | Business Analyst | Define WHAT to build — requirements, acceptance criteria, edge cases |
| `/ux` | UX Designer | Design user experience — flows, wireframes, accessibility |
| `/plan` | Architect | Design HOW to build — components, data flow, SOLID verification |
| `/review` | Senior Dev | Verify plan feasibility — TDD readiness, risks, blockers |
| `/team-review` | Review Team | Two-phase: 4 specialists sweep + deep dive. Replaces `/review` when teams enabled |
| `/implement` | Lead Dev | Build with strict TDD — test first, then minimum implementation |
| `/static-analysis` | Static Analysis | Run ruff, eslint, mypy, tsc, SonarQube — auto-fix safe issues, gate on blockers |
| `/hotfix` | Lead Dev | TDD bug fix with manual test — quick fix without full pipeline |
| `/manualtest` | Manual Tester | Verify in browser — propose scenarios, debug/fix loop, produce test log |
| `/qa` | QA Engineer | Verify it works — test coverage, regressions, cross-document consistency |
| `/team-qa` | QA Team | Two-phase: 4 specialists sweep + deep adversarial QA. Replaces `/qa` when teams enabled |
| `/commit` | Release | Merge safely — tests pass, conventional commit, cleanup |

### Checkpoint System

At each checkpoint, choose:

| Choice | Meaning |
|--------|---------|
| `yes` | Approved → phase commit + continue to next step |
| `amend` | Revise → go back and fix issues |
| `stop` | Pause → keep worktree, resume later |

### Audit Trail (Phase Commits)

In flow mode, each phase commits its artifact to the feature branch when approved:

```
git log --oneline feature/dark-mode

a1b2c3d docs(dark-mode): QA report
b2c3d4e docs(dark-mode): manual test log
e4f5g6h feat(ui): implement dark-mode
i7j8k9l docs(dark-mode): add test plan
m0n1o2p docs(dark-mode): architect plan
q3r4s5t docs(dark-mode): design UX
u6v7w8x docs(dark-mode): define requirements
```

This means:
- Every decision is traceable in git history
- Abandoned features keep approved artifacts on their branch
- Session crashes don't lose approved work

### Docs Status Prefixes

Feature docs directories are prefixed with their status:

| Prefix | Meaning | Set by |
|--------|---------|--------|
| `PENDING_Feature_` | Planned, not started | Default |
| `INPROGRESS_Feature_` | Active worktree exists | `/start` |
| `INPROGRESS_Plan_` | Active execution plan | `/plan-project` |
| `DONE_Feature_` | Completed and merged | `/commit flow` |

```
docs/
├── PENDING_Feature_enterprise/          ← Not started
├── INPROGRESS_Feature_dark-mode/        ← Being worked on
├── INPROGRESS_Plan_my-saas-app/         ← Execution plan
├── DONE_Feature_pdf-hyperlinks/         ← Completed
```

### Which Workflow to Use

| Situation | Workflow |
|-----------|----------|
| New feature with UI (flow) | `/start` → `/ba flow` → `/ux flow` → `/plan flow` → `/review flow` → `/implement flow` → `/static-analysis flow` → `/manualtest flow` → `/qa flow` → `/commit flow` |
| New feature with UI (team) | `/start` → `/ba flow` → `/ux flow` → `/plan flow` → `/team-review flow` → `/implement flow` → `/static-analysis flow` → `/manualtest flow` → `/team-qa flow` → `/commit flow` |
| New feature backend (flow) | `/start` → `/ba flow` → `/plan flow` → `/review flow` → `/implement flow` → `/static-analysis flow` → `/manualtest flow` → `/qa flow` → `/commit flow` |
| Technical work (flow) | `/start` → `/plan flow` → `/review flow` → `/implement flow` → `/static-analysis flow` → `/qa flow` → `/commit flow` |
| New feature (standalone) | `/ba` → `/plan` → `/review` → `/implement` → `/static-analysis` → `/qa` → `/commit` |
| Simple bug (1-2 files) | `/start-hotfix` → `/hotfix <bug>` → `/commit flow` |
| Complex bug (many files) | `/start` → `/plan flow` → ... |
| Multi-feature project | `/plan-project <name>` → then `/start <task-id>` per task (see Project Planning above) |
| Multi-feature (team) | `/plan-project <name> --team` → collaborative plan design with 8 specialists |
| Update existing plan | `/plan-project <name> --update` → add tasks, restructure phases, expand scope |
| Update plan (team) | `/plan-project <name> --update --team` → team reviews the proposed changes |
| Backend autopilot | `/start <task>` → `bash ~/.claude/tools/autopilot.sh <task>` in terminal. Runs /ba → /plan → /team-review → /implement → /static-analysis → /team-qa autonomously. Review QA result, then `/commit flow` |

### Utility Commands

| Command | Role | Use When |
|---------|------|----------|
| `/status` | Navigator | Check current flow position and next step |
| `/checkpoint` | Save Point | Save tagged progress mid-flow without closing |
| `/sync` | Updater | Pull latest main into active feature branch |
| `/docs` | Tech Writer | Update or audit documentation |
| `/docs readme` | Tech Writer | Rewrite README for portfolio + technical audience (11-section template) |
| `/commit-readme` | Stats Updater | Auto-update README numbers from codebase, commit + push |
| `/critic` | Devil's Advocate | Challenge assumptions with research (forked) |
| `/productmanager` | Product Manager | Project review, backlog prioritization, strategic analysis |
| `/cleaner` | Janitor | Remove temp and generated files |
| `/cleaner public` | Releaser | Prepare sanitized copy for public repo (no history, no secrets) |
| `/recover` | Recovery | Diagnose and fix: merge conflicts, stale worktrees, mid-flow interruptions |
| `/optimize` | Security | Review settings security, find repeated permission approvals |
| `/refreshclaude` | Refresh | Reload CLAUDE.md mid-session after instruction changes |
| `/health` | Integrity | Validate cross-references, hooks, and permissions |
| `/rollout` | Deploy | Roll out latest commands/skills/tools from golden repo to `~/.claude/` |
| `/grill` | Adversarial | Attack implementation quality and force you to defend choices |
| `/idea` | Intake | Explore an idea through dialog, then dismiss or add to backlog |
| `/plan-project` | Project Planner | Create/update execution plans. Flags: `--update`, `--team`/`--team-lite` |

### Non-Negotiable Rules

1. **TDD** — Write failing test FIRST for ALL code changes. Doc/analysis phases are exempt.
2. **SOLID** — Verify every component against SOLID checklist. Refactor immediately if any fail.
3. **NO HARDCODING** — All configurable values in config files. No magic numbers, no embedded strings.
4. **RESEARCH** — Use authoritative sources, weight newest. Document findings with citations.

Additional rules:
- **One component at a time** — Don't batch changes
- **Conventional commits** — `feat/fix/refactor(scope): message`

### Running Tests & App

Check `CLAUDE.md` for project-specific test and serve commands. Common patterns:
- Tests: listed under `## Commands` in CLAUDE.md
- Serve: listed under `## Commands` in CLAUDE.md
- Frontend: listed under `## Commands` in CLAUDE.md

### Subagents (Specialized AI Workers)

13 agents in `.claude/agents/`. Frontmatter (tools, model, skills, permissionMode)
is enforced; body content is not yet injected (GitHub #13627). Domain knowledge
comes from skills; role context from enriched descriptions (max 1024 chars).

**Specialist agents** (thin role — used by team commands and plan-project):
| Agent | Expertise |
|-------|-----------|
| `architect` | System boundaries, SOLID, module decomposition |
| `analyst` | Requirements traceability, EARS acceptance criteria |
| `ux-designer` | User flows, accessibility, design system compliance |
| `lead-developer` | Feasibility, TDD readiness, existing code constraints |
| `security-auditor` | OWASP Top 10, threat modeling, auth flows |
| `performance-engineer` | N+1 queries, data volume, caching, scaling |
| `qa-engineer` | Test coverage, edge cases, regression risk |
| `devops-engineer` | CI/CD, deployment, environment setup, monitoring |
| `code-reviewer` | SOLID, agentic navigability, project conventions |

**Utility agents** (standalone tools):
| Agent | Use |
|-------|-----|
| `test-explorer` | Fast test analysis (Haiku model, quick scans) |
| `dependency-auditor` | Outdated packages, CVEs, license issues |

**Write agent** (only agent with file modification access):
| Agent | Use |
|-------|-----|
| `fixer` | Surgical edits from resolution briefs (team-review, team-qa, plan-project) |

**Key properties:**
- Each agent gets its own context window (no pollution from main conversation)
- Haiku agents cost ~5x less than Opus and run ~5-10x faster
- Read-only agents cannot accidentally modify code
- Same agent, different task: `architect` designs plans AND reviews them

### Getting Help

- **Project rules:** `CLAUDE.md`
- **Skills (domain knowledge):** `.claude/skills/`
- **Commands (workflows):** `.claude/commands/`
- **Subagents (AI workers):** `.claude/agents/`

---

## Rules

- Read-only — does not modify anything
- Print the guide above, nothing more
