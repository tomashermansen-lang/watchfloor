---
name: dependency-auditor
description: >
  Dependency auditor. Checks for outdated packages, known CVEs (npm audit, pip
  audit), unused dependencies, and license issues across npm and pip/uv projects.
  Reports severity (CRITICAL for known CVEs, WARNING for outdated major versions,
  SUGGESTION for minor updates). Provides specific upgrade commands.
tools: Read, Grep, Glob, Bash, Write, Edit
model: inherit
memory: user
---
