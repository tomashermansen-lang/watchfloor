# Autopilot — Autonom SDLC-pipeline

Formål: kør én task gennem hele flowet (BA → Plan → Review → TDD-implementation
→ Static Analysis → QA → Commit → Merge) fuldt headless via `claude -p`, uden
menneskelige checkpoints.

```
╔════════════════════════════════════════════════════════════════════════════════╗
║                  AUTOPILOT — AUTONOM SDLC-PIPELINE                             ║
║                                                                                ║
║  Formål: én task → headless slash-commands pr. fase → artifact-verificering    ║
║          → phase commit → merge til main → post-merge smoke + contracts        ║
╚════════════════════════════════════════════════════════════════════════════════╝

┌─────────────── ENTRYPOINT ─────────────────────────────────────────┐
│  bash ~/.claude/tools/autopilot.sh [flags] <task-id>               │
│                                                                    │
│  --full                fra main → opret worktree → merge → cleanup │
│  --pipeline full|light team-review/team-qa vs solo review/qa       │
│  --from <phase>        resume — spring tidligere faser over        │
└───────────────┬────────────────────────────────────────────────────┘
                │ sources
                ▼
┌──────────────────── lib/ (delte helpers) ────────────────────────────┐
│  claude-session-lib.sh  ← run_phase / run_gated_phase / claude -p    │
│                           wrapper med stream-json + gtimeout         │
│  merge-lock.sh          ← flock for autopilot-chain samkørsel        │
│  phase-selector.sh      ← PHASE_ORDER + phase_enabled + --from gate  │
│  sonar-preflight.sh     ← auto-start SonarQube docker + properties   │
│  manifest_parser.py     ← parse pipeline: blok i CLAUDE.md           │
│  finalize_result.py     ← læs commit-finalize.sh JSON-output         │
└──────────────────────────────────────────────────────────────────────┘

┌─────────────── BOOTSTRAP ───────────────────────────────────────────┐
│  1. Parse args → validate_phase_name() hvis --from                  │
│  2. --full: opret worktree via scripts/worktree.sh (kræver main)    │
│  3. Kill orphaned "claude.*<task>" processer + sleep 2              │
│  4. Init NDJSON stream: $FEATURE_DIR/autopilot-stream.ndjson        │
│  5. preflight_check(MAIN_DIR):                                      │
│       parse_manifest(CLAUDE.md pipeline:)                           │
│         ├─ toolchain.python/node/imports/infra/network              │
│         └─ verify hver entry (command -v / python -c import)        │
│       strip ALL_PROXY/HTTPS_PROXY (ellers knækker pip/tiktoken)     │
│  6. Execution-plan guards (YAML_FILE):                              │
│       ├─ ui: true  → afvis (autopilot skipper /ux + /manualtest)    │
│       └─ depends:  → alle skal være done/skipped                    │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── PHASE EXECUTION CONTRACT ────────────────────────────┐
│                                                                     │
│   phase_enabled <name>   ◄── phase-selector.sh (honours --from)     │
│         │                                                           │
│         ▼                                                           │
│   gtimeout $PHASE_TIMEOUT \            ◄── 1800s safety valve       │
│     claude -p "<slash-command>" \      ◄── headless mode            │
│       --output-format stream-json \    ◄── NDJSON → stream-filen    │
│       --max-turns $MAX_TURNS_PHASE \   ◄── 75 / 200 pr. fase        │
│       --allowedTools "$ALLOWED_TOOLS"  ◄── Read,Edit,Write,Bash,... │
│         │                                                           │
│         ▼                                                           │
│   check artifact exists (REQUIREMENTS.md / PLAN.md / …)             │
│         ├─ exists   → track_phase(completed, duration, cost)        │
│         └─ missing  → fail_pipeline → worktree PRESERVED for retry  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── PIPELINE PHASES (PHASE_ORDER) ───────────────────────┐
│                                                                     │
│                         FULL (team)              LIGHT (solo)       │
│   1. ba         ───►  /ba flow autopilot          (samme)           │
│                       → REQUIREMENTS.md                             │
│                                                                     │
│   2. plan       ───►  /plan flow autopilot        (samme)           │
│                       → PLAN.md                                     │
│                                                                     │
│   3. review     ───►  /team-review                /review           │
│                       → TEAM_REVIEW.md            → REVIEW.md       │
│                       MAX_TURNS=200               MAX_TURNS=75      │
│                                                                     │
│   4a. testplan  ───►  /implement --step testplan                    │
│                       EXTRA_SYSTEM_PROMPT låser scope til           │
│                       kun TESTPLAN.md (ingen kode)                  │
│                                                                     │
│   4b. implement ───►  /implement flow autopilot   (TDD)             │
│                       MAX_TURNS=200, inkl. lint + types + commit    │
│                       preflight: docker compose up db-test          │
│                                                                     │
│   5. static-                                                        │
│      analysis   ───►  sonar_preflight (start SQ + kopier props)     │
│                       /static-analysis → STATIC_ANALYSIS.md         │
│                                                                     │
│   6. qa         ───►  /team-qa                    /qa               │
│                       → TEAM_QA.md                → QA_REPORT.md    │
│                                                                     │
│   7. commit     ───►  /commit flow autopilot      (samme)           │
│                                                                     │
│   8. finalize   ───►  (kun --full)                                  │
│                       commit-finalize.sh:                           │
│                         ├─ merge feature/ → main (--ff-only pull)   │
│                         ├─ rename INPROGRESS_ → DONE_                │
│                         ├─ push + worktree cleanup                  │
│                         └─ trailing JSON → finalize_result.py       │
│                       postmerge_check (smoke_test m. retry/backoff) │
│                       contract_check  (grep-limits + pytest)        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── OBSERVABILITY ───────────────────────────────────────┐
│  STREAM_FILE : $FEATURE_DIR/autopilot-stream.ndjson                 │
│    ├─ {"type":"orchestrator","msg":...}   (bash log-linjer)         │
│    ├─ {"type":"assistant", ...}           (claude -p turns)         │
│    └─ {"type":"finalize","result":{...}}  (merge outcome)           │
│                ▲                                                    │
│                │ tailer                                             │
│  DASHBOARD ────┘  watchfloor dashboard   (port 8787)                │
│                                                                     │
│  SUMMARY_FILE: autopilot-summary.json                               │
│    { task, project, branch, workdir, start_ts, end_ts,              │
│      duration_s, status, phases:[{name,status,duration_s,cost}] }   │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── STATE & ISOLATION ───────────────────────────────────┐
│  Worktree       : $MAIN_DIR/../<project>-<task>/                    │
│                   oprettet via scripts/worktree.sh (feature/<task>) │
│  Merge lock     : /tmp/autopilot-chain.lock (flock)                 │
│                   acquire i finalize-fase hvis CHAIN_MERGE_LOCK set │
│  Kill orphans   : pkill -f "claude.*<task>" før stream truncates    │
│  Sandbox proxy  : strip ALL_PROXY/HTTPS_PROXY (pip/tiktoken)        │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────── FAILURE SEMANTICS ───────────────────────────────────┐
│  Hver fase fejler → fail_pipeline(phase, msg):                      │
│    ├─ PIPELINE_STATUS = failed                                      │
│    ├─ write_summary (før exit — overlever crash)                    │
│    ├─ worktree + branch BEVARES (retry-materiale)                   │
│    ├─ dashboard_event "SessionEnd … failed at <phase>"              │
│    └─ resume: autopilot.sh --full --from <phase> <task>             │
│                                                                     │
│  Merge conflict → commit-finalize.sh logger og exit'er non-zero     │
│                   finalize_result.py --merge-failed → manual fix    │
└─────────────────────────────────────────────────────────────────────┘
```

## Tekniske valg

- **Sprogvalg**: ren bash-orkestrator ([autopilot.sh](../../claude/tools/autopilot.sh))
  + små Python-moduler i [claude/tools/lib/](../../claude/tools/lib/)
  (`manifest_parser.py`, `finalize_result.py`) som er pytest-dækket. CLI-flowet
  er dermed let at unit-teste isoleret.
- **Fase-kontrakt**: hver fase er *"kør én slash-command headless, bekræft
  artifact, ellers fail"*. Ingen interaktiv state — alt går via filer i
  `docs/INPROGRESS_Feature_<task>/`.
- **Gating**: [phase-selector.sh](../../claude/tools/lib/phase-selector.sh) ejer
  `PHASE_ORDER`, så `--from <phase>` er deterministisk og validerbart.
- **Preflight-kontrakt**: projektet skal have en `pipeline:` YAML-blok i
  `CLAUDE.md` med `toolchain`, `smoke_test`, `contracts`.
  [manifest_parser.py](../../claude/tools/lib/manifest_parser.py) parser den;
  autopilot refuserer at starte uden.
- **Finalize er ikke Claude**: merge/rename/cleanup kører deterministisk via
  [commit-finalize.sh](../../claude/tools/commit-finalize.sh) — ingen LLM-turns
  brændt på mekanisk arbejde.
- **Worktree bevares ved fejl**: REQUIREMENTS.md / PLAN.md fra tidlige faser er
  værdifuldt ved retry. `--from <phase>` genbruger worktreet.
