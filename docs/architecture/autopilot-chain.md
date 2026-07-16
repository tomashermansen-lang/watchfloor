# Autopilot Chain — Plan-niveau DAG-eksekvering

Formål: kør en hel `execution-plan.yaml` ved at eksekvere task-noder (via
autopilot.sh) efter deres `depends:`-DAG, med parallelisme, merge-serialisering
og phase-gates.

```
╔════════════════════════════════════════════════════════════════════════════════╗
║                 AUTOPILOT CHAIN — PLAN-NIVEAU DAG-EKSEKVERING                  ║
║                                                                                ║
║  Formål: læs execution-plan.yaml → compute ready-set → launch batch parallelt  ║
║          → vent → opdater state → evaluer gate → loop til plan er tom          ║
╚════════════════════════════════════════════════════════════════════════════════╝

┌─────────────── ENTRYPOINT ─────────────────────────────────────────┐
│  bash ~/.claude/tools/autopilot-chain.sh {run|status} [flags] [dir]│
│                                                                    │
│  --max-parallel N         max concurrent tasks (default: 2)        │
│  --max-tasks N            samlet budget (0 = dry-run)              │
│  --strict-gates           altid halt ved phase-gates               │
│  --continue-on-failure    mark dependents blocked, fortsæt         │
│                                                                    │
│  Auto-discover: docs/INPROGRESS_Plan_*/execution-plan.yaml         │
└───────────────┬────────────────────────────────────────────────────┘
                │ sources
                ▼
┌──────────────────── DEPS ───────────────────────────────────────────┐
│  lib/merge-lock.sh   ← flock wrapper (shlock-baseret)               │
│  autopilot.sh        ← per-task executor (kaldes --full pr. task)   │
│  python3 + yaml      ← YAML-parsing, ready-set, gate-evaluering     │
│  jq                  ← JSON-escape i emit_event                     │
│  caffeinate          ← forhindre macOS-sleep under lange runs       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── PLAN-MODEL (execution-plan.yaml) ────────────────────┐
│                                                                     │
│   phases:                                                           │
│     - id: phase-1                                                   │
│       tasks:                                                        │
│         - id: task-a                                                │
│           status: pending|wip|done|failed|skipped|blocked           │
│           autopilot: true|false      ◄── skip hvis false (manual)   │
│           depends: [task-x, task-y]  ◄── DAG-kant                   │
│           pipeline: full|light       ◄── propageres til autopilot   │
│       gate:                                                         │
│         passed: false                                               │
│         checklist:                                                  │
│           - "manual step"                       ◄── kind: human     │
│           - text: "build passes"                                    │
│             check: { kind: shell, cmd: "npm test" } ◄── shell check │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── BOOTSTRAP & CRASH RECOVERY ──────────────────────────┐
│  1. discover_plan_dir() → eksakt ét INPROGRESS_Plan_* eller fejl    │
│  2. Guards: shlock, jq, --max-tasks > 0                             │
│  3. Crash recovery på chain-state.json:                             │
│       ├─ corrupt JSON          → afvis (kræver manual rydning)      │
│       ├─ active_tasks[].pid levende? → "chain already running"      │
│       └─ pid død              → emit task_failed + cleanup worktree │
│  4. Init state hvis ingen: started_at, max_parallel, active/done/   │
│     failed-lister                                                   │
│  5. caffeinate -w $$ (holder Mac vågen, dør med chain)              │
│  6. trap SIGTERM/SIGINT → kill childs (TERM→5s→KILL)                │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── MAIN LOOP ───────────────────────────────────────────┐
│                                                                     │
│   while true:                                                       │
│     tasks_json = get_tasks_json(yaml)  ◄── re-læs hver iteration    │
│     gates_json = get_gates_json(yaml)                               │
│                                                                     │
│     ready = compute_ready_set():                                    │
│       t.status == pending                                           │
│       ∧ t.autopilot == true                                         │
│       ∧ alle t.depends er done|skipped                              │
│       ∧ alle TIDLIGERE phase-gates har passed == true               │
│                                                                     │
│     if ready empty:                                                 │
│       complete  → emit chain_completed, break                       │
│       failed    → dependents blocked, break                         │
│       blocked   → cirkulær/manual prereq, break                     │
│                                                                     │
│     if exists(chain.PAUSE):                                         │
│       emit chain_paused, exit 0                                     │
│                                                                     │
│     if tasks_launched >= MAX_TASKS: break                           │
│                                                                     │
│     batch = ready[:min(len(ready), MAX_PARALLEL, remaining_budget)] │
│                                                                     │
│     for task in batch:                                              │
│       export CHAIN_MERGE_LOCK=$PLAN_DIR/merge.lock                  │
│       pipeline = yaml_lookup(task, 'pipeline') or 'full'            │
│       autopilot.sh --full --pipeline $pipeline $task &              │
│       emit task_started, push pid til CHILD_PIDS + active_tasks     │
│                                                                     │
│     for pid in batch:                                               │
│       wait $pid                                                     │
│       success → emit task_completed, state.completed_tasks += task  │
│       fail    → læs autopilot-summary.json for failure_reason       │
│                  emit task_failed, state.failed_tasks += task       │
│                                                                     │
│     if batch_failed:                                                │
│       --continue-on-failure: marker transitive dependents blocked   │
│       else:                   emit chain_completed(failed), exit 1  │
│                                                                     │
│     for phase med all_terminal ∧ ikke all_failed ∧ gate.passed!=true│
│       evaluate_gate(phase)                                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── GATE EVALUATION ─────────────────────────────────────┐
│                                                                     │
│   evaluate_gate(phase_id):                                          │
│     checklist = phase.gate.checklist                                │
│     if empty:            auto-pass + gate_passed event              │
│     if --strict-gates:   block + gate_blocked event                 │
│                                                                     │
│     for item in checklist:                                          │
│       if str OR kind != shell       → human (needs_review)          │
│       if kind == shell:                                             │
│         subprocess.run(['bash','-c',cmd], timeout=60)               │
│         exit 0  → passed                                            │
│         exit !0 → failed  (truncate stdout/stderr til 4096)         │
│         timeout → timeout                                           │
│                                                                     │
│     emit gate_evaluated(phase, items=[…])                           │
│                                                                     │
│     if any failed/human → emit gate_blocked, return 1               │
│     if alle passed:                                                 │
│       patch YAML: phase.gate.passed = true  (yaml.safe_dump)        │
│       emit gate_passed, return 0                                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── STATE FILES (i PLAN_DIR) ────────────────────────────┐
│  chain-state.json       Aktiv state (crash-recovery kilde)          │
│    { started_at, max_parallel,                                      │
│      active_tasks:[{id,pid}], completed_tasks:[], failed_tasks:[] } │
│                                                                     │
│  chain-events.ndjson    Append-only audit log (dashboard input)     │
│    ├─ task_started      {task, pid}                                 │
│    ├─ task_completed    {task, duration_s}                          │
│    ├─ task_failed       {task, reason, duration_s}                  │
│    ├─ gate_evaluated    {phase, items:[{text,kind,result,...}]}     │
│    ├─ gate_passed       {phase}                                     │
│    ├─ gate_blocked      {phase, blocking_items}                     │
│    ├─ chain_paused                                                  │
│    └─ chain_completed   {completed_count, failed_count, elapsed_s}  │
│                                                                     │
│  merge.lock             flock-fil → serialiserer finalize-faserne   │
│                         af parallelle autopilot.sh-processer        │
│  chain.PAUSE            touch for at stoppe efter in-flight batch   │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── PARALLELISME & MERGE-SAFETY ─────────────────────────┐
│                                                                     │
│   Task A ──► autopilot.sh --full task-a ──┐                         │
│                                           │ commit-finalize.sh      │
│   Task B ──► autopilot.sh --full task-b ──┤ acquire merge.lock      │
│                                           │ ▼                       │
│   Task C ──► autopilot.sh --full task-c ──┘ merge til main (1 ad    │
│     (MAX_PARALLEL=2, så C venter)            gangen — rebase-safe)  │
│                                                                     │
│   Alle tasks har separat worktree → ingen fil-kollision før merge   │
│   Flock sikrer at KUN én finalize merger ad gangen                  │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── STATUS-KOMMANDO ─────────────────────────────────────┐
│  autopilot-chain.sh status → tæller pending/wip/done/failed/skipped │
│  viser aktuel fase, elapsed siden started_at, og ready-set          │
│  (inkl. phase-gate respekt — samme logik som run_chain)             │
└─────────────────────────────────────────────────────────────────────┘
```

## Tekniske valg

- **Re-læs YAML hver iteration**: planen er "sandheden" — chain opdaterer ikke
  task-status selv (det gør autopilot.sh/commit-finalize). Hvis en task markerer
  sig selv `done` via YAML-patch, ser næste iteration det og udløser dependents.
- **Ready-set er ren Python**: [autopilot-chain.sh](../../claude/tools/autopilot-chain.sh)
  embedder små Python-snippets inline (via heredoc) til YAML-parsing og
  DAG-analyse. Bash ejer kun orkestrering, signal-håndtering og proces-launch.
- **Merge-lock er centralt**: uden flock ville parallelle `commit-finalize.sh`
  race om `git checkout main / merge / push`. Lock-filen deles via
  `CHAIN_MERGE_LOCK` env-var, som autopilot.sh's finalize-fase respekterer.
- **Crash recovery er aktiv, ikke reaktiv**: ved opstart tjekker chain
  `active_tasks[].pid` via `kill -0` og markerer døde processer som `failed` +
  rydder deres worktree — ellers ville "chain already running" falsk-alarme
  efter et crash.
- **Gate er tre-delt** (human / shell / strict): shell er deterministiske
  checks (tests, lint), human kræver review-touch, `--strict-gates` tvinger
  halt uanset checkliste-typen.
- **--continue-on-failure udbreder "blocked"**: transitive dependents af en
  failed task markeres som blocked, så chain ikke retry'er dem i næste
  iteration. Uden flaget: chain exit'er non-zero ved første fejl.
