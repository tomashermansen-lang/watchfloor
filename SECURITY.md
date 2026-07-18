# Security Model

Watchfloor enforces a three-layer security model that constrains what the AI agent can access and modify.

## Layer 1: Sandbox (kernel)

macOS Seatbelt restricts all Bash commands to:

- **Write:** Only `$PROJECTS_ROOT` (your projects directory) and `/tmp`
- **Read:** Credential paths are kernel-blocked — `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.azure`, `~/.kube`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, `~/.netrc`
- **Network:** Allowlisted domains only (GitHub, npm, PyPI, Anthropic API)

This is enforced at the macOS kernel level. Claude Code cannot bypass it.

## Layer 2: Permission deny rules (application)

Claude Code's own permission system blocks Edit/Write/Read on:

- All credential paths listed above
- Shell configuration: `~/.bashrc`, `~/.zshrc`
- Its own settings: `~/.claude/settings.json`

These rules are defined in `claude/settings.json` and deployed by `install.sh`.

## Layer 3: Git (reactive)

All tracked file changes are reversible via `git checkout`. Phase commits create an audit trail of every change the pipeline makes.

## The golden repo pattern

The pipeline repo lives **inside** the sandbox (in your projects directory). Changes are made here, then deployed to `~/.claude/` via `sync.sh restore` — a manual step that crosses the sandbox boundary.

This means:
- The AI agent can modify pipeline files in the repo (inside sandbox)
- But cannot deploy them to `~/.claude/` without you running `sync.sh restore`
- Settings changes require manual deployment — the agent cannot self-modify its own constraints

## Verifying your sandbox

After installation, run:

```bash
bash verify.sh
```

This checks that:
- All pipeline files are deployed correctly
- The sandbox is enabled in settings.json
- Hooks are configured
- Project directories exist

## Reporting security issues

If you find a security vulnerability in this pipeline, please open a GitHub issue.
