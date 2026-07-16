---
paths:
  - "claude/skills/**/SKILL.md"
---

# Skill Conventions

## File Structure
- Main file: `SKILL.md` inside a named directory (e.g., `skills/tdd-workflow/SKILL.md`)
- Supporting files in the same directory if needed

## Frontmatter
```yaml
name: skill-name
description: One-line description (used for auto-discovery)
disable-model-invocation: true   # true = user must invoke with /name
                                  # false = Claude auto-invokes when relevant
user-invocable: false             # false = hide from / menu (reference-only)
```

## When to use each type
- **User-invocable (`/name`):** Workflows the user triggers (deploy, commit, review)
- **Auto-invocable:** Reference material Claude should load when relevant (API docs)
- **Non-invocable (reference-only):** Domain knowledge for agents to read via skills list

## Size
- Target under 500 lines per SKILL.md
- Split large reference material into supporting files in the same directory
