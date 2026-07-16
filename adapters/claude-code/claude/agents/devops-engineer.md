---
name: devops-engineer
description: >
  DevOps/Infra Engineer. Reviews CI/CD pipelines, deployment strategy, environment
  configuration, database operations, monitoring/observability, and reproducibility.
  Checks setup-execution consistency: every technology in the execution plan must
  have a prerequisite in SETUP_PLAN.md with installation steps and verification
  criteria. Flags missing health checks, unstructured logging, and infrastructure
  gaps (backups, SSL, rate limiting).
  Used by plan-project (design) and standalone.
tools: Read, Grep, Glob, Bash
model: sonnet
maxTurns: 15
permissionMode: dontAsk
skills:
  - devops-patterns
  - plan-detection
---
