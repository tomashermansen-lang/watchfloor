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

## Cross-cutting Migration Completeness

When a feature is a **migration**, **rename**, **reordering**, or **convention
change**, BA SHALL enumerate the full set of files affected — not just the
obvious ones. Common blind-spots from past features:

| Pattern | What's obvious | What's typically missed |
|---------|----------------|-------------------------|
| Migrate format A → format B | Reader/consumer scripts | Writer/producer commands (esp. .md slash-commands) |
| Rename symbol/file/$id | Definition site | String literals, schema $id values, doc references, test fixtures |
| Reorder pipeline phases | Phase definition file | Each invocation site (orchestrator script, retry logic, gate-eval) |
| Convention change | New behavior in docs | Tests that lock in old behavior; legacy producers that still emit |

**Mandatory producer/consumer matrix** (for migration features only):

For every legacy artifact/convention being migrated, BA SHALL produce a
matrix in REQUIREMENTS.md before scope locks:

| Role | File/Command | Operation | In scope? | Reason if NO |
|------|--------------|-----------|-----------|--------------|
| Consumer | `path/to/reader.py` | reads X | YES | — |
| Consumer | `path/to/another-reader.sh` | reads X | YES | — |
| Producer | `path/to/writer-command.md` | writes X | YES | — |
| Producer | `path/to/legacy-producer.py` | writes X | NO | "Out of scope per [issue/decision]; will produce R14-style warning" |

Every NO entry MUST include the reason. The matrix forces BA to confront
both halves of the migration explicitly.

**Mandatory acceptance criterion template** (for migrations):

Every migration feature SHALL include this acceptance criterion in
REQUIREMENTS.md so the migration is testable in QA:

> **AC-MIG-COMPLETE:** When `grep -rn '<legacy-pattern>' <producer-roots>` is
> run after the feature merges, the system shall return zero matches OR
> all remaining matches shall be documented in REQUIREMENTS.md
> `out_of_scope[]` with explicit reason.

Without this AC, "incomplete migration" lands silently — no later phase
catches the producer-leak because tests verify what was implemented, not
what was missed.

**Discovery commands BA SHALL run before locking scope:**

```bash
# All write-sites of legacy artifact filename
grep -rln "<legacy-filename>" claude/commands/ claude/tools/ tests/

# All read-sites of legacy convention
grep -rln "<legacy-pattern>" --include="*.py" --include="*.sh" --include="*.md"

# Identify parallel implementations (e.g., team-* mirrors of solo-*)
ls claude/commands/team-*.md claude/commands/{review,qa,plan}.md
```

Paste the output (or "(no matches)") into REQUIREMENTS.md under the
producer/consumer matrix. The grep-output IS the evidence that scope is
complete; absence of grep-output is the only acceptable basis for claiming
"migration is complete".

**Provenance:** Pattern detected after two incomplete migrations (2026-04):
(1) pipeline-reorder updated docs+phase-selector but missed `autopilot.sh`
orchestrator — autopilot ran old order silently for weeks. (2) schema 2.0
adoption updated 7 consumer scripts but missed `team-review.md` and
`team-qa.md` producers — they kept writing legacy DEFERRED.md alongside
2.0 plans. Both gaps came from BA's "producer" definition being too narrow
(only the central-purpose producers, not side-effect producers). The
mandatory matrix and discovery commands force enumeration; the AC makes
the result testable.

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
