---
name: requirements-analysis
description: Requirements analysis patterns — EARS notation, traceability, scope management, gap detection. Used by analyst agent.
user-invocable: false
---

# Requirements Analysis

## EARS Notation (Easy Approach to Requirements Syntax)

Every acceptance criterion must use one of these patterns:

| Type | Template | Example |
|------|----------|---------|
| **Event-driven** | When [trigger], the system shall [response] | When user clicks Save, the system shall persist the record and show confirmation |
| **State-driven** | While [state], when [event], the system shall [response] | While offline, when user submits form, the system shall queue the request |
| **Unwanted** | If [error condition], then the system shall [recovery] | If API returns 500, then the system shall retry 3 times with exponential backoff |
| **Optional** | Where [feature is enabled], the system shall [behavior] | Where dark mode is enabled, the system shall use dark palette tokens |

**Anti-patterns:**
- "The system should..." — vague, not testable
- "The system must be fast" — no measurable threshold
- "The system handles errors gracefully" — undefined behavior

## Traceability Matrix

Every requirement must trace through the full chain:

```
Requirement → Acceptance Criteria → Design Element → Plan Task → Test Case
```

**Gap detection checklist:**
- [ ] Every requirement has at least one EARS acceptance criterion
- [ ] Every criterion maps to a concrete component in the plan
- [ ] Every criterion maps to a test case (or is marked as manual-test-only)
- [ ] No plan task exists without a parent requirement (scope creep)
- [ ] No requirement is partially covered (all sub-criteria addressed)

## Scope Management

**Scope creep signals:**
- Plan tasks that don't trace to any requirement
- "Nice to have" features appearing as CRITICAL
- Acceptance criteria broader than the original requirement
- Dependencies on unplanned infrastructure

**Missing requirement signals:**
- Plan tasks with no acceptance criteria
- Vague criteria: "works correctly", "handles edge cases", "is responsive"
- Cross-cutting concerns not addressed (auth, logging, error handling)

## Severity Classification

| Severity | Meaning | Action |
|----------|---------|--------|
| CRITICAL | Requirement dropped or fundamentally misinterpreted | Must fix before approval |
| WARNING | Criterion incomplete, vague, or partially covered | Must fix before approval |
| SUGGESTION | Could improve clarity or coverage | Vote in triage |

## Gotchas

- **Mixing EARS templates.** Event-driven ("When X, the system shall Y") and
  state-driven ("While X, when Y, the system shall Z") look similar but test
  differently. A state-driven criterion needs the precondition established in
  the test setup — missing this is the #1 reason tests seem to pass but don't
  actually cover the requirement.
- **"Handles errors gracefully" survives review.** Vague criteria like this
  slip past agents because they sound reasonable. Always demand: *which* errors,
  *what* recovery action, *what* the user sees. If the analyst can't answer
  these, the requirement isn't ready.
