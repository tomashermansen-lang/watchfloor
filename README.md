# Watchfloor

An agentic SDLC for [Claude Code](https://docs.anthropic.com/en/docs/claude-code): AI agents take a feature from requirements to committed code through an eight-phase pipeline, and a supervision dashboard (the watch floor) is where a human watches the work run and steps in when a decision is needed.

33 slash commands, 14 specialist agents, 16 skills, 9 hooks, 11 JSON Schemas, and three orchestrators (autopilot, autopilot-chain, grinder) — all enforced by a macOS kernel sandbox and a TDD gate.

![Pipeline git log showing phase-labeled commits](https://tomashermansen-lang.github.io/portfolio/screenshots/pipeline-git-log.png)

> For architecture deep-dives, design decisions, and lessons learned, see the [portfolio write-up](https://tomashermansen-lang.github.io/portfolio/projects/watchfloor.html).

## Provenance

This repo is a curated snapshot of a private development monorepo, refreshed at milestones with dated snapshot commits. It merges what was previously published as two repos: **claude-code-pipeline** (the SDLC pipeline) and **claude-agent-dashboard** (the monitoring dashboard). The two systems grew together until keeping them apart was the obstacle; they were consolidated into one monorepo in April 2026.

## Repository layout

```
adapters/claude-code/   The Claude Code adapter: commands, agents, skills,
                        hooks, rules, templates, and the orchestrator tools
                        (autopilot.sh, autopilot-chain.sh, grinder.sh).
                        sync.sh deploys it into ~/.claude/.
core/schema/            11 JSON Schemas: execution plan 2.0, pipeline
                        manifest, deviation taxonomy, grinder state, events.
dashboard/              The watch floor UI. React 19 + MUI v7 + Recharts
                        frontend, FastAPI backend, read-only terminal view,
                        autopilot control endpoints.
docs/architecture/      Architecture notes: autopilot, chain, grinder,
                        deterministic layers, execution-graph context,
                        security layers.
scripts/                Helper scripts (worktrees, grinder watch).
tests/                  ~145 bash and Python tests for the orchestrators.
```

## The pipeline

Eight phases, each producing a versioned, git-committed artifact:

```
ba → plan → testplan → review → implement → qa → static-analysis → commit
```

Design decisions worth noting:

- **No agent marks its own work.** Review and QA phases run adversarially against the implementing agent's output.
- **TDD is enforced by a hook**, not a convention: a pre-commit gate blocks implementation code without a failing test first.
- **Static analysis runs after QA**, so SonarQube and coverage checks see the post-QA-fix state instead of being bypassed by later edits.
- **Test plans are written before review**, so the review phase can verify test scope instead of trusting it.

## Execution modes

| Mode | What it does |
|------|--------------|
| **Flow** | Standard pipeline with git-worktree isolation, phase commits, merge on completion |
| **Standalone** | Quick one-off without a worktree (hotfixes, docs) |
| **Autopilot** | Fully autonomous single-task pipeline in tmux (`autopilot.sh`) |
| **Autochain** | Plan-level DAG execution: runs every eligible task in an execution plan with configurable parallelism (`autopilot-chain.sh`) |
| **Grinder** | Continuous codebase-improvement loop: mechanical, static-analysis, coverage, and CVE passes (`grinder.sh`) |

In the full (team) pipeline, review and QA phases fan out to multi-agent teams (4-5 specialists each) with cross-reviewer discussion and fix loops; the light (solo) pipeline uses single-agent review and QA.

Plans are `execution-plan.yaml` files validated against schema 2.0 (a knowledge-graph contract with typed deferred findings). Each completed task persists a compact context block so downstream tasks read a decision summary and symbol map instead of full artifacts.

## Model routing and cost

Every phase can run on a different model. The default routes reasoning phases (ba, plan, testplan, review, implement, qa) to Sonnet and mechanical phases (static-analysis, commit) to Haiku — a combination that measured **56% cheaper than the all-Opus baseline** ($16.78 vs $38.01 on the same feature) in an A/B canary run, at equal quality gates.

An opt-in harness can also route selected phases through a local Ollama daemon; so far real runs have not succeeded (endpoint compatibility against the agent harness, plus local hardware limits), so it remains an experiment rather than a working configuration. The review and qa phases are denylisted from local routing by design: the phases that judge the work always run on the strongest models.

## Supervision (the watch floor)

The dashboard discovers running autopilot sessions, streams their tool calls and phase transitions live, renders execution plans as dependency graphs with gate evaluation, shows per-session metrics, and exposes controls: pause/resume autopilot, and a read-only WebSocket terminal view of the live tmux session. Deviation tracking flags tasks whose implementation drifts from the plan (file, size, and acceptance-criteria ratios) and hands flagged cases to an assessor agent for classification.

See [dashboard/README.md](dashboard/README.md) for setup and the full feature list.

## Platform

**macOS only.** The security model depends on macOS Seatbelt (kernel-level sandboxing) to enforce filesystem boundaries. There is no Linux or Windows equivalent. Three-layer defense, detailed in [SECURITY.md](SECURITY.md):

1. **Sandbox (kernel)** — macOS Seatbelt restricts Bash writes to your projects directory and `/tmp`. Credential paths are kernel-blocked.
2. **Permission deny rules** — Claude Code's application-level rules block Edit/Write/Read on credential paths and shell config.
3. **Git (reactive)** — all tracked file changes are reversible via `git checkout`.

## Prerequisites

| Tool | Min version | Install | Check |
|------|-------------|---------|-------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Latest | `npm i -g @anthropic-ai/claude-code` | `claude --version` |
| Python | 3.10+ | `brew install python3` | `python3 --version` |
| uv | Latest | `brew install uv` | `uv --version` |
| jq | 1.6+ | `brew install jq` | `jq --version` |
| git | 2.30+ | `xcode-select --install` | `git --version` |
| tmux | 3.0+ | `brew install tmux` | `tmux -V` |
| Node.js | 20+ | `brew install node` | `node --version` (dashboard only) |

## Quick start

```bash
git clone https://github.com/tomashermansen-lang/watchfloor.git
cd watchfloor
bash adapters/claude-code/sync.sh restore   # deploys pipeline config to ~/.claude/
# restart Claude Code, then run /status to see the pipeline
```

For the dashboard, follow [dashboard/README.md](dashboard/README.md).

## License

[MIT](LICENSE)

## Author

Tomas Hermansen — [portfolio](https://tomashermansen-lang.github.io/portfolio/) · [LinkedIn](https://linkedin.com/in/tomashermansen)
