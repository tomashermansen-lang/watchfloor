---
description: Optimize — security review of settings + permission pattern analysis
disable-model-invocation: true
---

# Optimize: Security & Permission Review

Analyze Claude Code settings for security issues, redundancy, and repeated permission approvals.

## Workflow

### Step 1: Read all relevant files

Read these files in parallel:
- `.claude/settings.json` (project permissions — committed)
- `.claude/settings.local.json` (local permissions — per-machine)
- `.claude/config/research_sources.md` (whitelisted research domains)
- `.claude/logs/permissions.jsonl` (permission request log, may not exist yet)

### Step 2: Security Audit of Settings

Check both settings files for these issues:

**Critical (fix immediately):**
- Deprecated colon syntax: `Bash(cmd:*)` silently fails — must be `Bash(cmd *)`
- Overly broad wildcards that could enable injection: `source *`, `export PATH *`, `git reset *`, `rm *`, `eval *`, `bash *`
- `WebFetch(domain:github.com)` — prompt injection risk from user-generated content

**Warning (recommend fix):**
- Duplicate permissions between settings.json and settings.local.json
- Redundant entries (e.g. both `Bash(python3 *)` and `Bash(.venv/bin/python3 *)`)
- WebFetch domains in settings.json that aren't in research_sources.md (or vice versa)
- settings.local.json entries that should be promoted to settings.json (used by all contributors)
- settings.local.json entries with deprecated colon syntax (silently broken)

**Info:**
- Total permission count per file
- Categorized breakdown (Bash, Edit, Write, WebFetch, WebSearch, Read)

### Step 3: Whitelist Consistency Check

Compare domains listed in `research_sources.md` vs `WebFetch(domain:...)` entries in `settings.json`:
- Domains in research_sources.md but MISSING from settings.json → Claude will be asked for permission every time
- Domains in settings.json but NOT in research_sources.md → access is auto-approved but source isn't marked as trusted
- Flag the drift and suggest a unified fix

### Step 4: Permission Log Analysis

If `.claude/logs/permissions.jsonl` exists and has entries:
1. Count unique tool+input patterns
2. Find the **top 10 most repeated permission requests**
3. For each, suggest the exact `settings.json` entry to add (with correct syntax)
4. Flag any patterns that should NOT be auto-approved (destructive commands, force-push, etc.)

If the log doesn't exist or is empty, note that the PermissionRequest hook is now active and will start collecting data. Suggest running `/optimize` again after a few sessions.

### Step 5: Output Report

Present findings as a structured report:

```
## Security & Permission Optimization Report

### 🔴 Critical Issues
(issues that silently break or create security holes)

### 🟡 Warnings
(redundancy, drift, deprecated syntax)

### 🟢 Recommendations
(permission promotions, whitelist sync)

### 📊 Permission Log Insights
(top repeated approvals, suggested additions)

### Summary
- Total permissions: X (settings.json) + Y (settings.local.json)
- Issues found: N critical, M warnings
- Suggested actions: (numbered list)
```

### Step 6: Offer to fix

After presenting the report, offer to fix issues in priority order:
1. Critical issues (deprecated syntax, dangerous wildcards)
2. Whitelist sync (add missing WebFetch entries or research_sources.md entries)
3. Permission promotions (move repeated local approvals to project settings)

Wait for user approval before modifying any file. Present exact diffs for review.

## Rules

- **Read-only by default** — only modify files after explicit user approval
- **Conservative security posture** — when in doubt, recommend NOT auto-approving
- **Never suggest auto-approving**: `git push *`, `git reset *`, `rm -rf *`, `source *`, `eval *`
- **Explain WHY** each recommendation matters (security impact, not just "best practice")
