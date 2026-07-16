# Grinder — Tech Debt Orkestrator

Formål: scan → planlæg → kør Claude i batches → commit pr. fix → loop.

```
╔════════════════════════════════════════════════════════════════════════════════╗
║                      GRINDER — TECH DEBT ORKESTRATOR                           ║
║                                                                                ║
║  Formål: scan → planlæg → kør Claude i batches → commit pr. fix → loop         ║
╚════════════════════════════════════════════════════════════════════════════════╝

┌─────────────── ENTRYPOINT ───────────────┐
│  claude/tools/grinder.sh <subcommand>    │
│                                          │
│  discover | run | resume | pause |       │
│  status   | ack-review                   │
└───────────────┬──────────────────────────┘
                │ sources
                ▼
┌──────────────────── lib/ (delte helpers) ───────────────────────┐
│  claude-session-lib.sh   ← run_phase / Claude headless wrapper  │
│  merge-lock.sh           ← .grinder.lock (atomic commits)       │
│  grinder-discover.sh/.py ← scanner-runners + plan-emitter       │
│  grinder-mechanical.sh   ← pass 1 batch-eksekvering             │
│  grinder-coverage.sh     ← pass 2 (test-generering)             │
│  grinder-static.sh       ← pass 3 (proposals.md)                │
│  grinder-cve.sh          ← pass 4 (auto-upgrade / defer)        │
│  emit-baseline.py        ← skriver docs/grinder/baseline.json   │
│  finalise-deferred.py    ← samler deferred-findings.json        │
└─────────────────────────────────────────────────────────────────┘


╔══════════════════════════════ FASE 1: DISCOVER ═══════════════════════════════╗
║                                                                                ║
║   CLAUDE.md ── pipeline.grinder block ──┐                                      ║
║   (manifest:                            │                                      ║
║     languages, findings,                │ parser (manifest_parser.py)          ║
║     fix_rules_allowlist,                ▼                                      ║
║     never_touch_files)         ┌────────────────────┐                          ║
║                                │ For hver scanner:  │                          ║
║                                │   shellcheck       │                          ║
║                                │   ruff / eslint    │  → scanner-output/*.json ║
║                                │   mypy / tsc       │  → normalise-findings.py ║
║                                │   pip-audit/npm    │                          ║
║                                └────────┬───────────┘                          ║
║                                         │ findings + coverage gaps             ║
║                                         ▼                                      ║
║                              ┌───────────────────────────┐                     ║
║                              │ grinder-discover.py       │                     ║
║                              │  → batches grupperes      │                     ║
║                              │  → estimated_turns/hours  │                     ║
║                              └───────────┬───────────────┘                     ║
║                                          ▼                                     ║
║                            docs/grinder/grinder-plan.yaml                      ║
║                            (committet: chore(grinder): discovery)              ║
║                                                                                ║
║   Idempotency: hvis git_sha_at_start == HEAD → "plan is current", exit 0       ║
╚════════════════════════════════════════════════════════════════════════════════╝


╔══════════════════════════════ FASE 2: RUN ═══════════════════════════════════╗
║                                                                                ║
║      run_batch_loop()          process_batch()         execute_batch()         ║
║      ─────────────────         ───────────────         ───────────────         ║
║      iterér passes ── pr. ──→  status/deps check ──→  dispatcher pr. kind:     ║
║      sekventielt   batch       transition→in_progress                          ║
║                                                          │                     ║
║                                                          ▼                     ║
║                ┌──────────────────────────────────────────────────────┐        ║
║                │   PASS 1 — MECHANICAL  (sikre auto-fixes)            │        ║
║                │   shellcheck/ruff/eslint findings                    │        ║
║                │   guard: revert hvis findings_increased              │        ║
║                │         eller test-regression                        │        ║
║                │   commit: fix(grinder): pass-1-autofix (batch X)     │        ║
║                ├──────────────────────────────────────────────────────┤        ║
║                │   PASS 2 — COVERAGE                                  │        ║
║                │   genererer manglende tests                          │        ║
║                │   guard: ingen inline-suppression, mock_depth ≤ 3    │        ║
║                │         coverage må ikke falde                       │        ║
║                │   needs_review=true → pass halt → ack-review         │        ║
║                ├──────────────────────────────────────────────────────┤        ║
║                │   PASS 3 — STATIC_ANALYSIS                           │        ║
║                │   kun fix på allowlist; ellers → proposals.md        │        ║
║                │   never_touch_files: ekskluderet                     │        ║
║                ├──────────────────────────────────────────────────────┤        ║
║                │   PASS 4 — CVE                                       │        ║
║                │   pip-audit / npm audit → severity-gating            │        ║
║                │   minor/patch: auto-upgrade   major: defer           │        ║
║                │   → cve-review.md                                    │        ║
║                └────────────────────────┬─────────────────────────────┘        ║
║                                         │                                      ║
║                Hver batch eksekveres som en headless Claude-session            ║
║                via run_phase()  (PHASE_TIMEOUT, MAX_TURNS_PHASE,               ║
║                EXTRA_SYSTEM_PROMPT pr. pass-kind)                              ║
║                                                                                ║
║                Resultat parses fra stdout (key=value):                         ║
║                  findings_before/after, files_fixed, coverage_*, cves_*        ║
║                Stderr scanned for grunde: "test regression",                   ║
║                  "pre-commit hook failure", "mock depth exceeded" osv.         ║
╚════════════════════════════════════════════════════════════════════════════════╝


╔════════════════════════ STATE & ARTIFACTS (docs/grinder/) ═══════════════════╗
║                                                                                ║
║   grinder-plan.yaml      ← single source of truth (passes/batches/status)      ║
║   grinder-state.json     ← session_id, current batch, lock-info                ║
║   events.ndjson          ← append-only audit log (started/completed/failed)   ║
║   grinder-stream.ndjson  ← realtime log til dashboard (autopilot pattern)      ║
║   scanner-output/*.json  ← rå scanner-output (input til normalise)             ║
║   baseline.json          ← aggregeret findings/coverage efter alle passes      ║
║   deferred-findings.json ← findings der ikke fixes (bevidst defereret)         ║
║   .grinder.lock          ← merge-lock så commits er atomare                    ║
╚════════════════════════════════════════════════════════════════════════════════╝


╔════════════════════════════ KONTROL-FLOW PR. BATCH ══════════════════════════╗
║                                                                                ║
║   ┌─ status: pending ─┐                                                        ║
║   │                   │ deps OK? needs_review=false?                           ║
║   │                   ▼                                                        ║
║   │            transition → in_progress  (events.ndjson)                       ║
║   │                   │                                                        ║
║   │                   ▼                                                        ║
║   │            execute_batch (Claude headless)                                 ║
║   │                   │                                                        ║
║   │       ┌───────────┴───────────┐                                            ║
║   │       ▼                       ▼                                            ║
║   │  exit_code=0              exit_code≠0                                      ║
║   │       │                       │                                            ║
║   │  parse stdout            parse stderr → reason                             ║
║   │  git add/commit          git checkout -- .  (revert)                       ║
║   │       │                       │                                            ║
║   │       ▼                       ▼                                            ║
║   │  → completed             → failed (m. reason+reverted=true)                ║
║   └───────────────────────────────────────────────────────────────────────┘    ║
║                                                                                ║
║   Efter alle passes:  emit-baseline.py + finalise-deferred.py                  ║
╚════════════════════════════════════════════════════════════════════════════════╝


╔══════════════════════════ INTEGRATION & TRIGGERS ═════════════════════════════╗
║                                                                                ║
║   • autopilot.sh kører grinder-check.sh i smoke-tests                          ║
║   • CLAUDE.md's pipeline.grinder block er manifest-kontrakten                  ║
║   • commit-preflight.sh --ratchet håndhæver three-tier (MUST/SHOULD/MAY)       ║
║     fra deferred-findings.json                                                 ║
║   • get-findings.sh (med/uden --no-filter) bruger filter-deferred.py           ║
║     til at skjule allerede-defererede findings i andre faser                   ║
╚════════════════════════════════════════════════════════════════════════════════╝
```

## Designprincipper

- **Adskillelse**: Én tynd orkestrator ([grinder.sh](../../claude/tools/grinder.sh)) + fire pass-specifikke libs. Hver pass har sit eget `execute_*_batch()`, sin egen guard-logik, og sit eget commit-mønster.
- **Manifest-drevet**: Alt scanner-konfig læses fra `pipeline.grinder` blokken i projektets [CLAUDE.md](../../CLAUDE.md) — ikke hardcoded.
- **Atomar pr. batch**: Claude-session → kør → guard-check → commit eller revert. Aldrig halvfærdige tilstande.
- **Resumerbar**: Status holdes i `grinder-plan.yaml` (status pr. batch) + `grinder-state.json` (session). `resume` plukker op hvor `pause`/crash slap.
- **Audit-bart**: `events.ndjson` (append-only) + `grinder-stream.ndjson` (live til dashboard) — du kan altid rekonstruere hvad der skete.
