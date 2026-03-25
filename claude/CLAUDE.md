# Global Claude Configuration

## Pipeline Overview

Three-tier execution model for all projects:

1. **Planning** (`/plan-project`) — structured YAML execution plans with team review
2. **Development** (`/start` → `/ba` → `/ux` → `/plan` → `/implement` → `/static-analysis` → `/qa` → `/done`) — worktree-isolated workflow with phase commits and human checkpoints
3. **Autonomy** (`autopilot.sh`) — fully hands-off tmux pipeline for autopilot-eligible tasks

**Full pipeline:**
```
/start → /ba flow → /ux flow → /plan flow → /team-review flow → /review flow
→ /implement flow → /static-analysis flow → /manualtest flow → /team-qa flow → /qa flow → /commit flow → /done
```

**When to use which mode:**
- **Flow mode** (`/command flow <feature>`): Standard — worktree isolation, phase commits, audit trail
- **Standalone** (`/command <feature>`): Quick one-off without worktree (e.g., hotfix, docs)
- **Autopilot** (`bash ~/.claude/tools/autopilot.sh <task>`): Backend-only tasks with unambiguous criteria

## System Port Registry

All local dev servers use reserved ports to avoid conflicts.
Start everything: `start-system` (or `~/start-system.sh`).

Configure project paths via env vars or `~/.claude/project-dirs.conf`.
Default projects root: `$PROJECTS_ROOT` (defaults to `~/Projects`).

| Project | Backend | Frontend | Notes |
|---------|---------|----------|-------|
| Claude Dashboard | 8787 | 5175 | `$PROJECTS_ROOT/claude-agent-dashboard/` |
| Your Project A | 8100 | 5174 | Configure in `project-dirs.conf` |
| Your Project B | 8200 | 5173 | Configure in `project-dirs.conf` |
| SonarQube | 9100 | — | Optional — static analysis server |

Commands: `start-system {all|dashboard|stop}`

Customize `start-system.sh` for your own projects — it's designed to be extended.

## Dotfiles Repo

The dotfiles repo is the source of truth for the CLI pipeline.
Deploy changes: `bash sync.sh restore` then restart Claude Code.
Validate sync: `bash sync.sh diff`

## Security Model

**Trust boundary:** `$PROJECTS_ROOT` (default `~/Projects/`) — all projects live
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
