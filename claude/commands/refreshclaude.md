---
description: Refresh Claude — reload CLAUDE.md and detect context changes mid-session
disable-model-invocation: true
---

# Refresh Claude Instructions

Reload project instructions and context without starting a new session. Safe to use mid-flow — the active pipeline phase resumes after refresh.

## Workflow

1. **Re-read CLAUDE.md.**
   Read the full `CLAUDE.md` file and acknowledge the current rules.

2. **Detect context.**
   - Current branch: `git branch --show-current`
   - Working tree status: `git status`
   - If in a worktree: identify feature name and which docs exist in `docs/` for it

3. **Identify active flow phase** (if any).
   Use Phase Detection table in the flow-mode skill to determine position from existing docs in `docs/*<feature>/`.

4. **Report:**
   ```
   Instructions refreshed.
   Branch: <branch>
   Rules loaded: <count of NON-NEGOTIABLE rules>
   Changes detected: <list of changed instruction files, or "none">
   Active flow phase: <next command to run, or "none">
   ```

5. **Resume.** If a flow phase was active, say:
   ```
   Ready to continue. Next step: /<next-command> flow
   ```

## Rules

- This command is READ-ONLY — never modify any files
- Always re-read CLAUDE.md even if it appears unchanged (context may have been compacted)
- Do NOT re-run any flow phase — only identify where the flow is and report it
