# Execution graph som context-styring

Execution-plan YAML'en er ikke bare en to-do-liste — den er den mekanisme
der holder LLM-kontekstvinduet småt og fokuseret. Hver task kører i sin
egen session med kun de felter den selv skal bruge.

## Hvorfor det overhovedet er et problem

Et LLM-kontekstvindue er en delt buffer. Alt man læser ind bliver siddende
og koster tokens hver tur. Uden en plan ender man med at:

- Læse hele kodebasen ind én gang pr. feature
- Gen-læse samme filer i flere faser (BA, plan, implement, QA)
- Miste fokus fordi tidligere tasks' output fylder vinduet
- Kunne ikke genoptage arbejde efter nedbrud uden at re-opdage alt

Execution-graphen løser alt ovenstående fordi hver node i grafen er en
selvstændig kontrakt med egen prompt, egne acceptance-kriterier og egen
status.

## Grafen

```
┌──────────────────────────────────────────────────────────────────────────┐
│  execution-plan.yaml   (én fil — valideret mod execution-plan.schema)    │
│                                                                          │
│   name, description, sources                                             │
│   phases:                                                                │
│    ┌─────────────────────────────────────────────────────────────────┐  │
│    │ phase-1                                        gate: checklist  │  │
│    │  ├─ task 1a   status: done    depends: []   autopilot: true     │  │
│    │  ├─ task 1b   status: done    depends: [1a] pipeline: light     │  │
│    │  └─ task 1c   status: wip     depends: [1a] parallel_group: A   │  │
│    └─────────────────────────────────────────────────────────────────┘  │
│    ┌─────────────────────────────────────────────────────────────────┐  │
│    │ phase-2                                                          │  │
│    │  ├─ task 2a   status: pending depends: [1b, 1c]                  │  │
│    │  └─ task 2b   status: pending depends: [2a]                      │  │
│    └─────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

DAG'en er eksplicit: `depends` på task-niveau + ordnet `phases`-array +
`parallel_group` for tasks der må køre samtidigt.

## Context-isolation pr. task

```
┌─────────────────────────────────────────────────────────────────────────┐
│  PLANNING-FASE  (bred context — én gang pr. feature)                    │
│                                                                         │
│   /plan-project læser:                                                  │
│     CLAUDE.md, eksisterende kode, BACKLOG.md, requirements docs         │
│                                                                         │
│   Output:  execution-plan.yaml  ← komprimerer alt til struktureret DAG  │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
            DAG-nodes er nu "serialized context" som genstarter billigt
                                     │
┌────────────────────────────────────┼────────────────────────────────────┐
│                                    ▼                                    │
│  EXECUTION-FASE  (smal context — én gang pr. task)                      │
│                                                                         │
│   for task i topological_sort(graph):                                   │
│                                                                         │
│       ┌──────────────────────────────────────────────────┐              │
│       │ Ny session / ny subagent / ny worktree           │              │
│       │ (friskt kontekstvindue)                          │              │
│       │                                                  │              │
│       │ Loader KUN:                                      │              │
│       │   • task.prompt                                  │              │
│       │   • task.acceptance                              │              │
│       │   • depends-parents' phase_results               │              │
│       │   • filer task rent faktisk rører                │              │
│       │                                                  │              │
│       │ Loader IKKE:                                     │              │
│       │   • søstre-tasks i samme fase                    │              │
│       │   • fremtidige phases                            │              │
│       │   • planning-dialog historik                     │              │
│       └───────────────┬──────────────────────────────────┘              │
│                       │                                                 │
│                       ▼                                                 │
│              task.status = done                                         │
│              task.phase_results += {phase, conformance, ...}            │
│                                                                         │
│   ← deviation-tracker.py appender resultater tilbage til YAML           │
└─────────────────────────────────────────────────────────────────────────┘
```

## Hvordan felterne fungerer som context-gates

```
 Felt                      Formål i context-styringen
 ────                      ──────────────────────────
 id                        Stabil identifier — lader næste session finde
                           task uden at læse hele filen ind

 status                    Topological scheduler læser kun YAML'en
  pending/wip/done/...     deterministisk — ingen LLM bruges til at
                           vælge "hvad skal jeg lave nu?"

 depends: [id, id]         Eksplicit grænse for hvilke tidligere
                           phase_results der skal hentes ind i context

 prompt                    Præ-komprimeret opgavebeskrivelse. Erstatter
                           "læs alt relevant igen". Skrevet én gang i
                           planning, læst N gange i execution.

 acceptance: [ ... ]       Terminal-betingelse. Gør det muligt at afslutte
                           en session uden at LLM skal gætte "er jeg
                           færdig?" — scripts kan afkrydse.

 autopilot: true           Flag → autopilot.sh tager over. Fjerner human-
                           checkpoints = ingen interaktiv dialog i context.

 pipeline: light           Vælger kortere fase-kæde (BA→Plan→Review→
                           Implement→SA→QA). Færre faser = færre
                           context-switches med load/unload.

 parallel_group: A         Flere worktrees kan køre samtidigt, hver med
                           eget friskt vindue. Nul context-deling.

 phase_results[]           Append-only log. Næste fase læser KUN den
                           seneste entry fra sin forrige fase — ikke hele
                           historikken.

 scope_change              Gør afvigelser eksplicit — så QA ikke skal
 delivered_beyond_plan     re-læse hele diff'en for at forstå hvorfor
 remaining_gaps            implementation ikke matcher planen 1:1.
```

## Crash recovery uden context-tab

```
   Session dør (timeout, crash, restart)
              │
              ▼
   Ny session starter ─► læser execution-plan.yaml
                         │
                         ├─► finder første task med status: wip eller pending
                         ├─► læser dens depends → henter phase_results
                         └─► fortsætter — uden at genopfinde hele planen

   Ingen conversation-memory nødvendig. YAML'en ER hukommelsen.
```

Det er derfor `plan-detection` skill'en og `/status` kan genoptage arbejde
midt i en pipeline: al kritisk state er serialiseret i grafen, ikke i
samtalen.

## Samspil med andre deterministiske lag

```
   execution-plan.yaml
        │
        ├─► validate-plan.py           (schema + semantik — lag 8)
        │
        ├─► /start reads → worktree    (lag 4 — én worktree pr. task)
        │
        ├─► /implement reads task.prompt + task.acceptance
        │       └─► tdd-gate.sh gater edits (lag 3)
        │
        ├─► deviation-tracker.py appender phase_results
        │
        └─► /done reads status=done    (lag 4 — done-verify.sh)
```

## Relaterede dokumenter

- [deterministic-layers.md](deterministic-layers.md) — fuld oversigt over alle 8 lag
- [security-layers.md](security-layers.md) — sandbox + permissions
- [grinder.md](grinder.md) — grinder pass-flow (bruger samme DAG-mønster)
