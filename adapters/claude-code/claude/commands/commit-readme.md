---
description: Update README stats from codebase, commit, and push to main
disable-model-invocation: true
---

# Commit README

Auto-update all numbers in README.md from codebase facts, then commit and push.

## Workflow

1. **Verify branch.** Must be on `main`. If not:
   ```
   You're on branch <branch>. Switch to main first, or use /docs to update README in a feature branch.
   ```
   STOP.

2. **Run stats update script.**
   ```bash
   .venv/bin/python scripts/update_readme_badges.py
   ```
   Show the summary output to user.

3. **Check for changes.**
   ```bash
   git diff README.md
   ```
   If no changes: "README.md already up to date." → STOP.

4. **Show diff** to user for review.

5. **Checkpoint:**
   ```
   README.md updated:
   - Tests: <count>
   - Coverage: <pct>
   - Golden evals: <count>
   - Corpora: <count>
   - Engine modules: <count>

   Commit and push to main? [yes / stop]
   ```

6. **On `yes`:** Commit and push.
   ```bash
   git add README.md
   git commit -m "docs(docs): update README stats"
   git push
   ```

7. **Report:**
   ```
   README.md committed and pushed to main.
   ```

## What Gets Updated

The script (`scripts/update_readme_badges.py`) patches these locations:

| Location | Source |
|----------|--------|
| Tests badge | pytest --collect-only + vitest --run |
| Coverage badge | .coverage file |
| Evals badge | data/evals/*.yaml (YAML parse) |
| Last Eval badge | runs/eval_*.json timestamps |
| Technical Highlights table | All of the above + engine file count |
| Supported Legislation count | corpus_registry.json |
| Narrative numbers | eval count + corpus count |
| Mermaid diagram | eval case count |
| Cost estimates | Proportional to eval case count |

## Rules

- NEVER run on a feature branch — stats belong on main
- NEVER skip showing the diff to the user
- NEVER push without user confirmation
