---
name: devops-patterns
description: DevOps patterns — CI/CD, deployment, environment setup, monitoring, infrastructure gaps. Used by devops-engineer agent.
user-invocable: false
---

# DevOps Patterns

## When to Use

- Reviewing CI/CD pipelines, deployment configs, or environment setup
- Planning infrastructure for a new feature or project
- Auditing execution plans for missing prerequisites

## Thinking Framework

Before auditing, identify:
1. **Deployment target** — Local dev, single server, containerized, serverless?
2. **State management** — What persists? (DB, files, env vars, secrets)
3. **Failure modes** — What happens if a service dies? Can it recover unattended?

## CI/CD Pipeline Checklist

- [ ] **Build reproducibility:** Deterministic builds (lockfiles committed, pinned versions)
- [ ] **Test in CI:** All test suites run on every PR (not just locally)
- [ ] **Lint/format in CI:** Automated style enforcement, not just advisory
- [ ] **Security scanning:** Dependency audit (npm audit / pip audit) in pipeline
- [ ] **Build artifacts:** Tagged, versioned, stored (not rebuilt on deploy)
- [ ] **Branch protection:** PR required, CI must pass, no force-push to main

## Environment Setup

### Consistency Checklist
- [ ] **Docker/containers:** Dev environment matches prod (or documented differences)
- [ ] **Environment variables:** All config via env vars, no hardcoded values
- [ ] **Secrets management:** Secrets not in source, injected at runtime
- [ ] **Database migrations:** Versioned, reversible, tested in CI
- [ ] **Seed data:** Reproducible dev/test data setup

### Setup-Execution Consistency
Every technology or service referenced in the execution plan must have:
- [ ] A prerequisite in SETUP_PLAN.md
- [ ] Installation/configuration steps
- [ ] Verification criteria (how to confirm it works)
- [ ] Version pinned or range specified

## Deployment Strategy

| Strategy | When to use | Risk |
|----------|-------------|------|
| **Rolling update** | Stateless services, backward-compatible changes | Brief mixed versions |
| **Blue-green** | Zero-downtime required, quick rollback needed | 2x infrastructure cost |
| **Canary** | High-risk changes, gradual rollout | Monitoring complexity |
| **Recreate** | Breaking changes, acceptable downtime | Full downtime window |

## Monitoring & Observability

- [ ] **Health checks:** Every service has a `/health` endpoint
- [ ] **Structured logging:** JSON logs with correlation IDs, not print statements
- [ ] **Error alerting:** Errors trigger alerts (not just logged)
- [ ] **Metrics:** Request rate, latency (p50/p95/p99), error rate
- [ ] **Dashboards:** Key metrics visible without SSH or log diving
- [ ] **Runbooks:** Common failure modes documented with remediation steps

## Infrastructure Gaps

Common gaps to check in execution plans:
- Database backups and restore testing
- SSL/TLS certificate management and renewal
- Rate limiting and DDoS mitigation
- Log retention and rotation policies
- Disaster recovery and failover procedures

## Gotchas

- **Hook scripts fail silently.** Shell hooks in this repo exit 0 even on
  error by default. If a hook writes bad JSONL or crashes, nothing alerts —
  the agent continues with missing data. Always check hook exit codes and
  stderr in post-mortem.
- **`caffeinate` doesn't survive reboot.** Night-shift workflows use
  `caffeinate -s` to prevent sleep, but a macOS update or power event kills
  it. Long-running orchestrations need a launchd plist or cron watchdog,
  not just caffeinate.
- **Port conflicts on `start-system`.** The port registry (8787, 5175, 8100,
  5174, 8200, 5173) assumes no other processes bind those ports. If a previous
  session didn't clean up, `start-system` fails with cryptic EADDRINUSE errors.
  Check `lsof -i :<port>` before blaming the config.
