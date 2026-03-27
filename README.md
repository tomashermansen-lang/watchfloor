# Claude Code Pipeline

A structured SDLC automation framework for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). 34 slash commands, 13 specialist agents, and a fully autonomous pipeline mode — all enforced by a macOS kernel sandbox.

![Pipeline git log showing phase-labeled commits](https://tomashermansen-lang.github.io/portfolio/screenshots/pipeline-git-log.png)

> For architecture deep-dives, design decisions, and lessons learned, see the [portfolio write-up](https://tomashermansen-lang.github.io/portfolio/projects/cli-pipeline.html).

## Platform

**macOS only.** The security model depends on macOS Seatbelt (kernel-level sandboxing) to enforce filesystem boundaries. There is no Linux or Windows equivalent.

Tested on: macOS 15 Sequoia.

## Prerequisites

| Tool | Min version | Install | Check |
|------|-------------|---------|-------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Latest | `npm i -g @anthropic-ai/claude-code` | `claude --version` |
| Python | 3.10+ | `brew install python3` | `python3 --version` |
| jq | 1.6+ | `brew install jq` | `jq --version` |
| git | 2.30+ | `xcode-select --install` | `git --version` |
| tmux | 3.0+ | `brew install tmux` | `tmux -V` |

See [REQUIREMENTS.md](REQUIREMENTS.md) for the full list — including per-project tools (ruff, mypy, ESLint, SonarQube, etc.).

## Quick Start

```bash
git clone https://github.com/tomashermansen-lang/claude-code-pipeline.git
cd claude-code-pipeline
bash install.sh   # interactive — asks for projects root, deploys to ~/.claude/
bash verify.sh    # confirms everything is in place
```

Then restart Claude Code and run `/status` to see the pipeline.

## What's Included

### Commands (34)

| Phase | Commands |
|-------|----------|
| **Setup** | `/start`, `/start-hotfix` |
| **Requirements** | `/ba`, `/ux` |
| **Design** | `/plan`, `/team-review`, `/review` |
| **Build** | `/implement` (incl. inline lint + type checking), `/hotfix`, `/refactor` |
| **Quality** | `/static-analysis` (SonarQube + coverage), `/manualtest`, `/team-qa`, `/qa`, `/grill` |
| **Release** | `/commit`, `/done`, `/rollout` |
| **Planning** | `/plan-project`, `/idea`, `/productmanager` |
| **Utility** | `/status`, `/health`, `/docs`, `/recover`, `/optimize`, `/cleaner`, `/critic`, `/sync`, `/checkpoint`, `/refreshclaude`, `/commit-readme`, `/help` |

### Agents (13)

| Agent | Role |
|-------|------|
| `analyst` | Requirements traceability, EARS notation |
| `architect` | System boundaries, SOLID compliance |
| `code-reviewer` | Code quality, project conventions |
| `devops-engineer` | CI/CD, deployment, infrastructure |
| `fixer` | Surgical code fixes from review findings |
| `lead-developer` | Feasibility, effort, code reuse |
| `performance-engineer` | N+1 queries, caching, scaling |
| `qa-engineer` | Test coverage, regression risk |
| `security-auditor` | OWASP Top 10, threat modeling |
| `test-explorer` | Fast test analysis |
| `ux-designer` | User flows, accessibility, WCAG |
| `dependency-auditor` | CVEs, licenses, outdated packages |
| `canary` | System health validation |

### Hooks (5)

| Hook | Trigger | Purpose |
|------|---------|---------|
| `tdd-gate.sh` | Edit/Write | Blocks code changes without a test file open |
| `lint-on-edit.sh` | Edit/Write | Runs linter on changed files |
| `log-bash.sh` | Bash | Audit logs all shell commands |
| `log-permissions.sh` | PermissionRequest | Audit logs permission changes |
| `notify-macos.sh` | Notification | macOS desktop notifications |

## Three Execution Modes

**Flow mode** — standard development with worktree isolation and human checkpoints:
```
Full (team):  /start → /ba → /plan → /team-review → /implement → /static-analysis → /manualtest → /team-qa → /commit → /done
Light (solo): /start → /ba → /plan → /review → /implement → /static-analysis → /qa → /commit → /done
```

In the full pipeline, `/team-review` and `/team-qa` use multi-agent teams (4-5 specialists each) with cross-reviewer discussion and fix loops. The light pipeline uses solo `/review` with integrated test verification. `/implement` runs linters and type checkers inline; `/static-analysis` focuses on SonarQube and coverage enforcement.

**Standalone** — quick one-off without worktree:
```
/hotfix fix-the-bug
```

**Autopilot** — fully autonomous via tmux, no human required:
```bash
bash ~/.claude/tools/autopilot.sh my-feature              # auto-detects pipeline
bash ~/.claude/tools/autopilot.sh --pipeline full my-feature   # force team pipeline
bash ~/.claude/tools/autopilot.sh --pipeline light my-feature  # force solo pipeline
```

## Security Model

Three-layer defense, detailed in [SECURITY.md](SECURITY.md):

1. **Sandbox (kernel)** — macOS Seatbelt restricts Bash writes to your projects directory and `/tmp`. Credential paths are kernel-blocked.
2. **Permission deny rules** — Claude Code's application-level rules block Edit/Write/Read on credential paths and shell config.
3. **Git (reactive)** — all tracked file changes are reversible via `git checkout`.

## Configuration

The installer creates `~/.claude/project-dirs.conf`:

```bash
PROJECTS_ROOT="~/Projects"           # Where your projects live
DASHBOARD_DIR="$PROJECTS_ROOT/..."   # Override individual paths
```

The sandbox `allowWrite` path in `settings.json` is set to match your `PROJECTS_ROOT` during installation.

## Companion: Agent Dashboard

For real-time monitoring of pipeline sessions, autopilot runs, and metrics, install the [Agent Dashboard](https://github.com/tomashermansen-lang/claude-agent-dashboard).

The pipeline works fully without it — the dashboard is optional observability.

## Uninstall

```bash
bash uninstall.sh
```

Removes all deployed files from `~/.claude/`. Does not touch `settings.json` (you may have customized it).

## License

[MIT](LICENSE)

## Author

**Tomas Hermansen** — [Portfolio](https://tomashermansen-lang.github.io/portfolio/) · [GitHub](https://github.com/tomashermansen-lang)
