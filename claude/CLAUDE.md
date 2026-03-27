# Global Claude Configuration

## Pipeline Overview

Three-tier execution model for all projects:

1. **Planning** (`/plan-project`) — structured YAML execution plans with team review
2. **Development** (`/start` → `/ba` → `/ux` → `/plan` → `/implement` → `/static-analysis` → `/qa` → `/done`) — worktree-isolated workflow with phase commits and human checkpoints
3. **Autonomy** (`autopilot.sh`) — fully hands-off tmux pipeline for autopilot-eligible tasks

**Pipelines:**
```
Full (team):  /start → /ba → /plan → /team-review → /implement (inkl. lint+types) → /static-analysis (SonarQube+coverage) → /manualtest → /team-qa → /commit → /done
Light (solo): /start → /ba → /plan → /review → /implement (inkl. lint+types) → /static-analysis (SonarQube+coverage) → /qa → /commit → /done
```

Key design decisions (based on empirical analysis of 11 features, 13.8h total):
- `/implement` runs linters and type checkers inline — `/static-analysis` only runs SonarQube + coverage
- Light pipeline keeps solo `/qa` after implementation — review checks the plan, QA checks the code
- Full pipeline has no solo `/review` — `/team-review` includes deep dive phase
- Team phases (team-review, team-qa) are the highest-value review phases — they find architectural/feasibility bugs that solo cannot

**When to use which mode:**
- **Flow mode** (`/command flow <feature>`): Standard — worktree isolation, phase commits, audit trail
- **Standalone** (`/command <feature>`): Quick one-off without worktree (e.g., hotfix, docs)
- **Autopilot** (`bash ~/.claude/tools/autopilot.sh <task>`): Backend-only tasks with unambiguous criteria

## System Port Registry

All local dev servers use reserved ports to avoid conflicts.
Start everything: `start-system` (or `~/start-system.sh`).

Configure project paths via env vars or `~/.claude/project-dirs.conf`.
Default projects root: `$PROJECTS_ROOT` (defaults to `~/Projekter`).

| Project | Backend | Frontend | Notes |
|---------|---------|----------|-------|
| Claude Dashboard | 8787 | 5175 | `$PROJECTS_ROOT/claude-agent-dashboard/` |
| OIH | 8100 | 5174 | `$PROJECTS_ROOT/OIH/` — also Postgres 5432/5433, Langfuse 3000 |
| Eulex RAG | 8200 | 5173 | `$PROJECTS_ROOT/eulex-single-law-retrieval-artikel99/` |
| SonarQube | 9100 | — | `$PROJECTS_ROOT/sonarqube/` — static analysis |

Commands: `start-system {all|dashboard|oih|eulex|sonarqube|stop}`

## Dotfiles Repo

The dotfiles repo is the source of truth for the CLI pipeline.
Deploy changes: `bash sync.sh restore` then restart Claude Code.
Validate sync: `bash sync.sh diff`

## Security Model

**Trust boundary:** `$PROJECTS_ROOT` (default `~/Projekter/`) — all projects live
here. The macOS Seatbelt sandbox enforces this at the kernel level.

**Three layers:**
1. **Sandbox (kernel):** Bash writes only to `$PROJECTS_ROOT` + `/tmp`. Credential
   paths (`~/.ssh`, `~/.aws`, etc.) are kernel-blocked from Bash reads.
2. **Permission deny rules (application):** Edit/Write/Read blocked on credential
   paths and shell config (`~/.bashrc`, `~/.zshrc`, `~/.claude/settings.json`).
3. **Git (reactive):** Tracked file changes reversible via `git checkout`.

**Permission inheritance:** Global `~/.claude/settings.json` defines sandbox,
deny rules, and default allow list. Per-project settings contain only hooks,
WebFetch domains, and env vars — everything else is inherited.
