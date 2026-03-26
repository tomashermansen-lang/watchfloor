# Requirements

macOS only — the security model depends on macOS Seatbelt (kernel-level sandboxing).

## Required

These must be installed before running `install.sh`.

| Tool | Min version | Install | Used by |
|------|-------------|---------|---------|
| macOS | 14+ | — | Seatbelt sandbox |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Latest | `npm i -g @anthropic-ai/claude-code` | All commands |
| git | 2.30+ | `xcode-select --install` | Worktrees, commits, flow mode |
| Python | 3.10+ | `brew install python3` | Autopilot, plan validation, hooks |
| jq | 1.6+ | `brew install jq` | Commit hooks, JSON parsing |
| tmux | 3.0+ | `brew install tmux` | Autopilot mode |
| Homebrew | — | [brew.sh](https://brew.sh) | Installing the above |

## Recommended

Not strictly required, but the pipeline will use them when available.

| Tool | Install | Used by |
|------|---------|---------|
| terminal-notifier | `brew install terminal-notifier` | macOS notifications (`notify-macos.sh`) |
| coreutils | `brew install coreutils` | Phase timeout safety valve in autopilot |
| PyYAML | `pip3 install pyyaml` | YAML execution plan validation |
| Docker Desktop | [docker.com](https://www.docker.com/products/docker-desktop/) | `start-system.sh` for containerized services |

## Per-Project (Python)

Install these in your project if you use Python. The pipeline's `/static-analysis` and `/implement` commands will invoke them.

| Tool | Install | Purpose |
|------|---------|---------|
| ruff | `pip install ruff` or `uv add ruff` | Linter + formatter (auto-fix) |
| mypy | `pip install mypy` or `uv add mypy` | Static type checking |
| uv | `brew install uv` | Fast Python package manager |
| pytest | `pip install pytest` | Test runner |

## Per-Project (TypeScript/JavaScript)

Install these in your project if you use TypeScript. Run from your project's frontend directory.

| Tool | Install | Purpose |
|------|---------|---------|
| Node.js | `brew install node` | Runtime + npm |
| ESLint | `npm install --save-dev eslint` | Linter (auto-fix) |
| TypeScript | `npm install --save-dev typescript` | Type checking via `tsc --noEmit` |
| Vite | `npm install --save-dev vite` | Dev server + build |

## Optional (Static Analysis Server)

SonarQube provides centralized code quality analysis. The pipeline skips it gracefully if not running.

| Tool | Install | Purpose |
|------|---------|---------|
| sonar-scanner | `brew install sonar-scanner` | CLI scanner |
| SonarQube | Docker or standalone | Analysis server (default port 9100) |

Configure via `sonar-project.properties` in your project root (gitignored — contains token).

Set the token: `export SONAR_TOKEN="your-token-here"` or add to `.env`.

## Verification

After installing, run:

```bash
bash verify.sh
```

This checks that all required tools are present and the pipeline is correctly deployed.
