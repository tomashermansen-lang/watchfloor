---
name: plan-producer-patterns
description: Producer-quality patterns — five anti-pattern → exemplar pairs that /plan-project and /plan must reject in their own output before emitting a 2.0 execution-plan.yaml.
disable-model-invocation: true
user-invocable: false
---

# Plan Producer — Five Quality Patterns

This file is read verbatim by `/plan-project` and `/plan` at producer-prompt
run time. The Read event on this file is the audit trail for the
self-review step (observable in `autopilot-stream.ndjson`). Each pattern
defines an anti-example, the validator rule that catches it (R-number),
and a worked exemplar the producer must regenerate against.

The producer agent SHALL run the five checks against its own output BEFORE
emitting `execution-plan.yaml`. Up to **two retries** per task per pattern
are allowed; after two retries, the offending finding is logged into
`project.quality_warnings[]` and the plan is emitted anyway.

---

## Pattern 1 — Stub strings vs. concrete deliverables (R15)

**Anti-pattern (rejected):**

```yaml
- id: schema-core
  what: "Implement feature"           # 17 chars — too short
  why: "Because it's needed."         # 23 chars — too short
```

**Exemplar:**

```yaml
- id: schema-core
  what: Define the JSON Schema 2.0.0 contract covering project, phase, and task field sets with additionalProperties false at every level so unknown fields are rejected.
  why: The schema is the single source of truth for validate-plan and downstream agents; without a complete contract, drift between producers and consumers cannot be detected programmatically and the producer-quality patterns have nothing to anchor against.
```

**Validator rule:** `task.<id>.what: minimum length 80 characters not met`
plus 60-character shingle duplication scan across tasks.

**Producer self-fix:** rewrite the offending field with concrete deliverable
language. If two tasks share more than 60 characters of `what`, one of them
needs different content — they cannot share boilerplate.

---

## Pattern 2 — Aspirational success_criteria vs. measurable outcomes (R16)

**Anti-pattern (rejected):**

```yaml
success_criteria:
  - id: SC-1
    description: "The system is well-designed and robust."
```

**Exemplar:**

```yaml
success_criteria:
  - id: SC-1
    description: validate-plan.py exits 0 against tests/fixtures/plan-2.0.0/full.yaml with no warnings.
    measurable_via: test
    verified_at_phase: testplan
```

**Validator rule:** descriptions matching `\b(well-designed|robust|good|nice|clean)\b`
without a measurable artefact (file path, exit code, count, log line) emit a
WARNING. `measurable_via: manual-check` requires `verification_steps` or
`verified_at_phase`.

**Producer self-fix:** replace aspirational tokens with a concrete artefact
the validator can resolve.

---

## Pattern 3 — Glob `where.modify` vs. exact paths (R17)

**Anti-pattern (rejected):**

```yaml
where:
  modify: ["claude/**"]      # globs forbidden
  create: []
  delete: []
```

**Exemplar:**

```yaml
where:
  modify:
    - claude/tools/lib/plan_validators.py
    - claude/tools/validate-plan.py
  create:
    - tests/test_plan_validators.py
  delete: []
```

**Validator rule:** any of `*`, `?`, `[`, or `**` in
`where.modify | where.create | where.delete` exits 1 with
`task.<id>.where.<sub>[<index>]: glob pattern not allowed, use exact paths`.
A pending|wip task with all three arrays empty exits 1 too.

**Producer self-fix:** enumerate the actual files. If you don't know yet,
the task is too coarse — split it.

---

## Pattern 4 — Tautological acceptance vs. EARS observable assertions (R18)

**Anti-pattern (rejected):**

```yaml
acceptance:
  - "The schema works."
  - "Implementation should pass tests."
```

**Exemplar:**

```yaml
acceptance:
  - When validate-plan.py runs against tests/fixtures/plan-2.0.0/missing-what.yaml, the system shall exit 1.
  - While the schema is loaded, every nested object shall declare additionalProperties false.
  - If a 2.0 plan declares `deferred[].kind: code_finding`, then the validator shall enforce the kind-specific required-field set.
```

**Validator rule:** every entry must start (case-sensitive) with `When `,
`While `, `If `, or `Where ` AND contain a `\bshall\b` token. Failures
exit 1 with `task.<id>.acceptance[<index>]: must use EARS notation`.

**Producer self-fix:** state the event/state and the observable expectation
explicitly. Tests should be able to be derived directly from each entry.

---

## Pattern 5 — Dangling cross-references vs. resolved IDs (R19)

**Anti-pattern (rejected):**

```yaml
phases:
  - id: foundation
    kill_criteria_refs: [KC-A, KC-Z]   # KC-Z is undefined
    tasks:
      - id: t1
        depends: [non-existent]         # dangling task ref
```

**Exemplar:**

```yaml
kill_criteria:
  - id: KC-A
    description: schema rejects valid 1.x plans

phases:
  - id: foundation
    kill_criteria_refs: [KC-A]
    tasks:
      - id: schema-core
        depends: []
      - id: validator-2-0
        depends: [schema-core]
```

**Validator rule:** `_refs` fields and `depends` arrays must resolve to
top-level IDs (`project.kill_criteria[].id`, `project.design_notes[].id`,
`project.risks[].id`, `project.deferred[].id`, or any
`phases[].tasks[].id`). Dangling references exit 1 with
`<containing-path>.<field>[<index>]: ID '<value>' does not resolve`.

**Producer self-fix:** before emitting, build the set of IDs and check every
`_refs`/`depends` entry resolves.

---

## Pattern 6 — Incomplete migration: producer half missed (cross-cutting)

**Anti-pattern (rejected):** A migration feature whose plan modifies CONSUMER
files (readers) of a legacy artifact but does NOT modify the PRODUCER files
(writers) — or the inverse. Tests pass on what was implemented; the legacy
artifact keeps being produced unchallenged.

```yaml
# Migrating from legacy DEFERRED.md to schema-2.0 project.deferred[]
phases:
  - id: foundation
    tasks:
      - id: validator-reads-deferred
        what: "Update validate-plan.py to read project.deferred[] from yaml..."
        where:
          modify:
            - claude/tools/validate-plan.py             # CONSUMER updated
            - claude/tools/lib/filter-deferred.py       # CONSUMER updated
            - claude/tools/lib/finalise-deferred.py     # CONSUMER updated
        # ❌ MISSING: producer-side .md commands that WRITE deferred entries
        # claude/commands/team-review.md still writes DEFERRED.md (legacy)
        # claude/commands/team-qa.md still writes DEFERRED.md (legacy)
```

**Exemplar:** Both halves of the migration are explicit in `where.modify`:

```yaml
phases:
  - id: foundation
    tasks:
      - id: validator-reads-deferred
        what: "..."
        where:
          modify:
            # Consumers (readers)
            - claude/tools/validate-plan.py
            - claude/tools/lib/filter-deferred.py
            - claude/tools/lib/finalise-deferred.py
            # Producers (writers) — the half that writes the legacy artifact
            - claude/commands/team-review.md
            - claude/commands/team-qa.md
            - claude/tools/lib/ratchet-autolog.py
```

**Detection heuristic (producer self-review):**

Before emitting, scan `where.modify`/`where.create`/`where.delete` paths
and ask: *"For the legacy thing this task migrates, are both READERS and
WRITERS covered?"* Common asymmetries the heuristic flags:

| If task touches… | Also expect to touch… |
|------------------|----------------------|
| `validate-*.py` (validator) | The commands/scripts that produce the format being validated |
| `filter-*.py` / `*-deferred.py` (consumers of artifact) | Commands that emit the artifact |
| `phase-selector.sh` (phase order) | `autopilot.sh` and per-phase command files |
| `schema/*.json` ($id rename) | Tests that lock in the old $id; SEMANTIC_VALIDATORS dispatch tables |
| `~/.claude/settings.json` (config) | Hook scripts referenced by the config |

If the task description includes words like "migrate", "rename", "reorder",
"convert", "deprecate", "consolidate", or "unify": the producer self-review
SHALL run a discovery grep before locking the task. The grep targets the
legacy pattern across `.md`, `.py`, `.sh`, and `*.yaml` and reports any
file the legacy pattern is found in but is NOT in the task's `where[]`.

**Producer self-fix:** before emitting a migration task, run:

```bash
# For each legacy pattern being migrated
grep -rln "<legacy-pattern>" --include="*.md" --include="*.py" --include="*.sh" --include="*.yaml"
```

Cross-check the result against `where.modify[]`. Any path in the grep
output that is NOT in `where.modify[]` is either a missed producer or
must be moved to `out_of_scope[]` with explicit reason.

**Provenance:** Pattern observed twice (2026-04):
1. **Pipeline reorder (commit `6fe1fd2`)** — updated docs+`phase-selector.sh`
   but missed `autopilot.sh` orchestrator. Result: autopilot ran old order
   silently for weeks.
2. **Schema 2.0 adoption (`unified-plan-yaml-schema` feature)** — updated
   7 consumer scripts (filter-deferred.py, finalise-deferred.py, etc.) but
   missed 2 producer commands (team-review.md, team-qa.md). Result: those
   commands kept writing legacy DEFERRED.md alongside 2.0 plans, surfaced
   only as R14 stderr warnings that no autopilot phase escalates.

Both gaps came from the BA's "producer" mental model being too narrow
(only the central-purpose producer, not side-effect producers). This
pattern catches it at plan-time when the discovery grep is cheap; without
it, the gap survives all phases (BA → plan → review → implement → qa →
static-analysis) because tests verify the implemented work, not the
unimplemented producer-leak.

---

## Pattern 7 — Oversize-task split-proposal (R-B1, paired with R-A1..R-A4)

**Anti-pattern (rejected):** a single task that bundles multiple
behavioral seams and trips one or more sizing hard caps.

```yaml
- id: auth-and-ui-and-persistence
  acceptance:                          # 7 ACs (> 5 cap — R-A1)
    - When the user opens /login, the system shall render the form.
    - When the user submits valid credentials, the system shall set a session cookie.
    - When the user submits invalid credentials, the system shall show an error.
    - When the user navigates away mid-flow, the system shall preserve draft input.
    - When the operator rotates the secret, the system shall re-issue cookies.
    - When the rate limiter trips, the system shall lock for 60s.
    - When the audit log fails, the system shall fail closed.
  where:
    modify:
      - src/auth/handlers.py
      - src/auth/middleware.py
      - src/ui/login.tsx
      - src/ui/error.tsx
      - src/storage/session.py
      - src/storage/cookies.py        # 6 paths (> 5 cap — R-A4)
  estimate:
    lines_estimate: 400               # > 300 hard cap (R-A2)
    duration_hours: 5                 # > 4 hard cap (R-A3)
```

**Exemplar (vertical split by behavioral seam, NOT by file boundary):**

```yaml
- id: login-walking-skeleton
  acceptance:
    - When the user submits valid credentials, the system shall set a session cookie.
    - When the user opens /login, the system shall render the form.
  where:
    modify: [src/auth/handlers.py, src/ui/login.tsx, src/storage/session.py]
  estimate: { lines_estimate: 130, duration_hours: 2 }

- id: login-validation-rules
  depends: [login-walking-skeleton]
  acceptance:
    - When the user submits invalid credentials, the system shall show an error.
    - When the rate limiter trips, the system shall lock for 60s.
  where:
    modify: [src/auth/middleware.py, src/ui/error.tsx]
  estimate: { lines_estimate: 110, duration_hours: 2 }

- id: login-persistence-cleanup
  depends: [login-validation-rules]
  acceptance:
    - When the operator rotates the secret, the system shall re-issue cookies.
    - When the audit log fails, the system shall fail closed.
  where:
    modify: [src/storage/cookies.py]
  estimate: { lines_estimate: 90, duration_hours: 1.5 }
```

Each child satisfies R-A1..R-A4 (≤5 acceptance, ≤300 LOC, ≤4 hours,
≤5 paths). The split is by **behavioral seam** — independently
testable user flows / observable outcomes — not by file boundary
(`auth.py-extraction` + `ui.py-extraction` would be a refactor split,
not a feature split, and would still bundle the same behaviors).

**Validator rules paired:** R-A1 acceptance count, R-A2 lines_estimate,
R-A3 duration_hours, R-A4 touched paths (see
`claude/tools/lib/plan_validators.py::validate_task_sizing`). The
validator catches the cap; this pattern catches it earlier (at
producer-emit time) AND prescribes the split shape.

**Producer self-fix prompt:** "rewrite the task as N children
decomposed by behavioral seam (user flows / observable outcomes), NOT
by file boundary; each child must satisfy R-A1..R-A4. Use `depends`
edges to encode ordering between children."

**Empirical anchor:** METR (2024) — agent task success drops sharply
above ~50 turn-equivalent sub-tasks. SWE-Bench Pro (avg 107 LOC, 4.1
files) — Pass@1 < 45% on changes >100 LOC / >4 files.

---

## Pattern 8 — Verbose-content structure (R-B2, R-B4, R-B5, R-B6)

**Anti-pattern (rejected):** free-form prose (English or Danish)
inside `task.what`, `task.why`, `task.acceptance[]`, `task.description`
with no structured markup. The producer LLM and downstream agents have
to reparse the prose for each consumer.

```yaml
- id: deviation-tracker-rewrite
  description: |
    Vi skal omskrive deviation-trackeren så den kan lytte til alle
    fasers output og opsamle afvigelser på tværs af hele pipelinen.
    Der er en del kanter der skal håndteres, særligt omkring
    samtidighed og logfiltre. Måske skal vi også overveje om
    output-formatet skal ændres så det passer bedre med dashboardet.
    [...400+ chars of free-form prose...]
```

**Exemplar (Anthropic-style XML wrappers + EARS + Gherkin + Always/Ask/Never):**

```yaml
- id: deviation-tracker-rewrite
  description: |
    <scope>Rewrite deviation-tracker.py so it consumes phase_results from every pipeline phase and emits a single normalised event stream consumable by the dashboard.</scope>

    <background>Current implementation only listens to /qa output (see DONE_Feature_deviation-tracker-wire). The dashboard product brief 2026-04 requires cross-phase coverage; without it, the audit timeline drops events from /implement and /static-analysis silently.</background>

    <requirements>
      When deviation-tracker.py receives a phase_results entry with kind=deviation, the system shall append a normalised record to the event stream.
      While the pipeline is running, every successful phase shall flush its phase_results to the tracker before exiting.
      If the tracker subprocess crashes, then the orchestrator shall continue without blocking the phase exit.
    </requirements>

    <acceptance>
      Given a synthetic phase_results.json with two deviation entries,
      When deviation-tracker.py is invoked,
      Then the output stream shall contain exactly two normalised records.

      Given the tracker subprocess is killed mid-flush,
      When the next phase exits,
      Then the orchestrator shall log a WARNING and continue.
    </acceptance>

    <boundaries>
      Always: emit one event per deviation, normalised to the schema in core/schema/deviation.schema.json.
      Ask: clarify with operator if a phase emits unknown kinds.
      Never: block the orchestrator on tracker subprocess failure.
    </boundaries>

    <out_of_scope>Dashboard renderer changes; schema-versioning of the event stream.</out_of_scope>
```

**Mandatory vs recommended markers (R-B5):** above the **400-character
verbosity threshold** (description length ≥ 400 chars), `<scope>` and
`<acceptance>` are MANDATORY. `<requirements>`, `<boundaries>`, and
`<out_of_scope>` are RECOMMENDED. `<background>` is OPTIONAL. Below the
threshold the convention is recommended but not enforced.

**Inside `<requirements>`:** EARS clauses (`When X, the system shall
Y`; `While S, the system shall Z`; `If C, then the system shall T`).
Pattern 4 (R18) already enforces EARS notation on `task.acceptance[]`;
this pattern extends the convention into the verbose `description`
block.

**Inside `<acceptance>`:** Gherkin scenarios — Given/When/Then triples.
The producer SHALL keep `task.acceptance[]` synchronised with the
Gherkin block: every Gherkin scenario corresponds to one EARS entry in
`task.acceptance[]`.

**Inside `<boundaries>`:** Always / Ask / Never lists (Addy Osmani
spec-for-AI 2025). The lists shrink the agent's decision space at the
prompt boundary and reduce ambiguous follow-ups.

**English-only proxy (R-B4, AS-B1).** Producer self-checks each
`task.what` and `task.why` against a Unicode-letter-aware non-ASCII
regex (target only alphabetic Latin Extended A/B and Western European
letters — em-dashes, smart quotes, ellipsis, en-dashes are common in
tech prose and are NOT flagged). Bypass: the task carries the opt-in
field `extensions.language: <code>` (e.g. `extensions: { language: da }`,
`extensions: { language: de }`). The schema already permits arbitrary
`extensions` content (`extensions: { type: object }`), so no schema
change required.
The check fires at producer-emit time; per OQ-1 + C-4 (English-only is
a recommendation, not a hard fail), this check is NOT in the validator.

**Strict nesting depth out of scope (EC-B.4).** Marker presence is
enforced; nesting structure is not. An XML parser would be
over-engineering for a documentation contract.

**Self-review and retries (R-B6, EC-B.5).** Pattern 8 plugs into the
existing § Self-Review Protocol below — **max 2 retries** per task per
pattern. After two retries, the violation is appended to
`project.quality_warnings[]` with `pattern_id: 8`, `task_or_phase_id`,
`description`, `retried_count: 3`, and the plan is emitted anyway.

---

## Pattern 9 — Walking-skeleton-first sequencing with DDD-informed prioritization (R-B3)

**Anti-pattern (rejected):** phase-1 first task is a leaf feature — UI
polish, peripheral capability, or a generic-subdomain utility — with
no end-to-end thread through the **core subdomain**. Result: the plan
ships infrastructure that nothing exercises end-to-end until phase-3.

```yaml
phases:
  - id: foundation
    sequencing_rationale: smallest-first
    tasks:
      - id: tooltip-polish              # leaf UI feature; no end-to-end thread
      - id: cli-help-text-rewording     # generic-subdomain task
```

**Exemplar:** phase-1 first task is the **walking skeleton** — the
thinnest end-to-end slice through the **core subdomain** (the
differentiating logic of the system per DDD). Then expansion proceeds
**bounded-context-by-bounded-context**: supporting subdomains follow
the core; **generic subdomains** come last.

```yaml
phases:
  - id: foundation
    sequencing_rationale: walking-skeleton — one end-to-end slice through the core subdomain (deviation event flow) before expanding
    tasks:
      - id: deviation-event-walking-skeleton
        what: One synthetic deviation flows from a phase_results.json sample through deviation-tracker.py into the event stream and is rendered in the dashboard timeline.
        why: Validates the entire seam (producer → tracker → consumer) against a real artefact before the bounded-context expansion lands; fails fast if any seam is wrong.
      - id: deviation-cross-phase-collection   # supporting subdomain — feeds the core
      - id: cli-help-text-rewording             # generic subdomain — last
```

**Encoding:** `phase.sequencing_rationale: walking-skeleton`
(matches `SEQUENCING_RATIONALE_ENUM`) OR a custom rationale ≥40 chars
that includes `walking skeleton` or `core subdomain` terminology.

**DDD vocabulary ALLOWED at plan level:** bounded context, core
subdomain, supporting subdomain, generic subdomain, context map. These
are about **prioritisation** (which slice ships first) and are
plan-level concerns.

**DDD vocabulary EXCLUDED at plan level:** aggregate, entity,
value object, repository, domain event. These are
**implementation-level** — they belong inside `task.what` /
`task.description`, not in plan-level sequencing rationale. (NG-3
forbids schema extensions like `walking_skeleton: bool` or
`subdomain_type: core|supporting|generic`; use `description` and
`sequencing_rationale` instead.)

**Validator rule paired:** R-C4 enforces the
`sequencing_rationale` enum/min-length via
`validate_sequencing_rationale_enum`.

**Self-review and retries:** ≤2 retries via the existing
§ Self-Review Protocol; after 2 retries, log to
`project.quality_warnings[]` with `pattern_id: 9`.

**Empirical anchor:** arXiv 2509.16941 / 2604.04990 / 2512.18470 —
walking-skeleton-first + DDD core-subdomain prioritization reduces
architectural rework.

---

## Self-Review Protocol

1. After emitting a draft plan, run:

   ```
   python3 claude/tools/lib/plan_self_review.py docs/INPROGRESS_Plan_<name>/execution-plan.yaml
   ```

2. Parse the JSON output. If `errors` is non-empty AND `attempt < max_retries`:
   - Regenerate the offending field(s) with the exemplar above as guide.
   - Re-emit and re-run self-review with `attempt + 1`.

3. If `attempt == max_retries (= 2)` and errors remain:
   - Populate `project.quality_warnings[]` with one entry per remaining
     violation: `{pattern_id, task_or_phase_id, description, retried_count}`.
   - Emit the plan anyway — the quality_warnings make the residual drift
     observable to the operator and to subsequent /retro analysis.
