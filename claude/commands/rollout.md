---
description: Roll out shared commands, skills, tools, schema, and templates from dotfiles to ~/.claude/. Optionally install dashboard hooks.
disable-model-invocation: true
---

# Rollout Global Claude Setup

Deploy the CLI pipeline (commands, skills, tools, schema, templates) from the
dotfiles repo to `~/.claude/`. Optionally install dashboard observability hooks.

## Workflow

Print the following commands for the user to run in their terminal.
The sandbox blocks writes to `~/.claude/settings.json`, so these must
be run outside Claude Code.

```
# Deploy CLI pipeline (commands, skills, tools, schema, templates, agents)
bash ~/Projekter/dotfiles/sync.sh restore

# Optional: install dashboard observability hooks
bash ~/Projekter/claude-agent-dashboard/install.sh

# Verify everything is in sync
bash ~/Projekter/dotfiles/sync.sh diff
```

Do NOT attempt to run these commands via Bash. Just print them.

## Rules

- Works from ANY project — always runs against the dotfiles repo
- Writes to `~/.claude/` which is sandbox-blocked — must be run by user in terminal
- Idempotent — safe to run repeatedly
- Projects should NOT have local copies of shared pipeline commands — they inherit from `~/.claude/`
- Only project-specific commands (not in dotfiles) belong in a project's `.claude/commands/`
- The dotfiles repo owns the CLI pipeline (producer). The dashboard repo owns hooks (consumer/observer).
