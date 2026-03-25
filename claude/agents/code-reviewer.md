---
name: code-reviewer
description: >
  Code quality reviewer. Checks SOLID compliance, agentic navigability, project
  conventions (from CLAUDE.md and .claude/rules/), hardcoded values, missing type
  annotations on public interfaces, import direction violations, dead code, and
  commented-out code. Returns structured findings with severity per component.
  Use proactively after code changes.
tools: Read, Grep, Glob, Bash
model: sonnet
maxTurns: 20
permissionMode: dontAsk
memory: user
skills:
  - solid-principles
  - agentic-code
  - tdd-workflow
---
