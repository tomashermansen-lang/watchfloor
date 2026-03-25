---
description: Health check — validate cross-references, hooks, permissions, and agent body injection
argument-hint: [--skip-canary]
---

# Health Check

Validate that the Claude command infrastructure is internally consistent. Read-only — does not modify anything.

## Workflow

Run all checks below, then report a summary table.

### Check 1: Skill References

Extract every `.claude/skills/*/SKILL.md` path referenced in `.claude/commands/*.md` and verify each exists:

```bash
grep -roh '\.claude/skills/[^/]*/SKILL\.md' .claude/commands/ | sort -u
```

Use `ls` to confirm each exists. Report: `✅ found` or `❌ MISSING`.

### Check 2: Script References

Extract every script path (`./scripts/*.sh`, `./tools/*.sh`) referenced in `.claude/commands/*.md` and verify each exists:

```bash
grep -roh '\./\(scripts\|tools\)/[^ )*"]*\.sh' .claude/commands/ | sort -u
```

Use `ls` to confirm. Report: `✅ found` or `❌ MISSING`.

### Check 3: Hook Scripts

Extract every hook command path from `.claude/settings.json` and verify each exists and is executable:

```bash
# Parse hook commands from settings.json
jq -r '.. | .command? // empty' .claude/settings.json 2>/dev/null | grep -o '\./[^ ]*\.sh' | sort -u
```

Use `ls -l` to confirm each exists and is executable. Report: `✅ ok` or `❌ MISSING/not executable`.

### Check 4: Agent Definitions

Verify `.claude/agents/*.md` files exist and have valid frontmatter (model, description fields):

```bash
ls .claude/agents/*.md
```

For each: read first 10 lines, confirm `model:` and `description:` are present. Report: `✅ valid` or `⚠️ missing fields`.

### Check 5: Permission Syntax

Read `.claude/settings.json` permissions array. Flag any entries using deprecated colon syntax (`Bash(cmd:*)` instead of `Bash(cmd *)`). Report count of valid vs deprecated entries.

### Check 6: Agent Body Injection (Canary)

Spawn the `canary` agent to test if GitHub issue #13627 (agent body not injected)
is fixed:

```
Agent tool:
  subagent_type: canary
  prompt: "What is the canary phrase? Respond with CANARY_OK or CANARY_FAIL."
```

- If response contains `CANARY_OK` → body injection is working. Report:
  `✅ #13627 FIXED — agent bodies are now injected. Consider restoring agent
  body content from git history (commit before body stripping).`
- If response contains `CANARY_FAIL` or anything else → still broken. Report:
  `⚠️ #13627 open — agent bodies not injected. Skills provide domain knowledge.`

### Check 7: Frontmatter Consistency

For each `.claude/commands/*.md`, verify:
- Has `description:` field
- Pipeline commands (ba, ux, plan, review, implement, static-analysis, manualtest, qa, commit, refactor) have `argument-hint:`
- Utility commands (checkpoint, sync, commit-readme, optimize, cleaner, critic, recover, refreshclaude, help, rollout, health) have `disable-model-invocation: true`

Report any missing fields.

## Output Format

```
## Health Check Report

| Check | Status | Details |
|-------|--------|---------|
| Skills | ✅/❌ | X/Y found |
| Scripts | ✅/❌ | X/Y found |
| Hooks | ✅/❌ | X/Y executable |
| Agents | ✅/❌ | X/Y valid |
| Permissions | ✅/⚠️ | X valid, Y deprecated |
| Canary #13627 | ✅/⚠️ | Body injection working or not |
| Frontmatter | ✅/⚠️ | X/Y consistent |

### Issues Found
- (list any problems)

### Recommendations
- (list fixes if any)
```

## Rules

- Read-only — does not modify any files
- Report ALL issues, not just the first one found
- Run checks in parallel where possible
