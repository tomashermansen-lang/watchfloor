---
paths:
  - "claude/agents/**/*.md"
---

# Agent Definition Conventions

## Required Frontmatter
```yaml
model: sonnet           # Use sonnet for cost efficiency
tools: [Read, Grep, Glob, Bash]  # Minimal toolset needed
max-turns: 15           # Default limit
```

## Structure
- Lead with role identity and focus area
- List skills the agent should reference (e.g., `tdd-workflow`, `solid-principles`)
- Define structured output format (tables with severity levels)
- Include anti-sycophancy protocol for review agents

## Output Format
- Findings table: `| # | Severity | Category | Section | Description | Fix suggestion |`
- Severities: CRITICAL, WARNING, SUGGESTION
- Every finding must reference a specific file, function, or component

## Constraints
- Agents are read-only by default (Read, Grep, Glob, Bash)
- Only `fixer` and `code-reviewer` agents get Edit/Write tools
- Keep agent definitions focused — one specialist role per agent
