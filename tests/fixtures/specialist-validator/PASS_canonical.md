## Solution Architect Analysis

### Proposed Tasks
| Task | Phase | Depends on | Affected files | Acceptance criteria | Autopilot? | Rationale |
| budget-cap | 0 | none | autopilot.sh, lib/budget_cap.sh | When cap reached, exit 4 | yes | Defence against runaway |

### Risks & Concerns
| # | Severity | Description | Mitigation |
| R1 | MEDIUM | False-positive cap aborts | Per-phase override |

### Sequencing Recommendations
Phase 0 ships first because cost-measurement-baseline is the data substrate every later SC verification depends on. Then operator-substrate-slim provides rollback safety before the team-trim lever.

### Council Brief citations
§1 canary: fastapi-origin-and-schemas $87.57 confirms the budget-cap target band.
§2 friction: chain-events.ndjson shows 3 spurious gate-blocked rounds on backend-substrate phase.
§3 counter-evidence: per-feature-budget-cap invalidation row addressed by §4 secret-scan regex.
