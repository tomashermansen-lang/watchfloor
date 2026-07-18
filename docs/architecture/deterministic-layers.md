# Deterministiske lag i pipelinen

Oversigt over alle dele af setup'et der kører regel-baseret uden at bede
LLM'en tænke — hooks, scripts, parsere, schemas og git-queries.

LLM'en sidder indeni et skal af sandbox → permissions → hooks → scripts.
Alt det nedenstående kører uden at bruge tokens og uden model-skøn.

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                     DETERMINISTISKE LAG (ingen LLM)                           │
└───────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────┐
│ 1. SANDBOX  (kernel)     │   macOS Seatbelt — settings.json "sandbox"
│    ~/.claude/settings    │   • filesystem.allowWrite: ~/Projekter, /tmp, ...
│    OVERSTYRER ALT ANDET  │   • network.allowedDomains: github, npm, pypi, ...
└─────────────┬────────────┘   • denyRead: ~/.ssh ~/.aws ~/.gnupg ~/.kube ...
              │
┌─────────────▼────────────┐
│ 2. PERMISSIONS (app)     │   "permissions.deny" i settings.json
│    Edit/Write/Read deny  │   • credential-paths + ~/.bashrc ~/.zshrc
└─────────────┬────────────┘   • ~/.claude/settings.json (selv-beskyttelse)
              │
┌─────────────▼─────────────────────────────────────────────────────────────────┐
│ 3. HOOKS  (~/.claude/settings.json → hooks)                                   │
│                                                                               │
│   Event              Hook script                      Effekt                  │
│   ─────              ───────────                      ──────                  │
│   PreToolUse:Edit ─► tdd-gate.sh           ──► exit 2 hvis src/ rørt uden    │
│   PreToolUse:Write    (deny + feedback)        test i diff (main...HEAD)      │
│                                                                               │
│   PostToolUse:Edit ─► lint-on-edit.sh      ──► ruff / eslint på filen,       │
│   PostToolUse:Write   (advisory, exit 0)       surface til Claude som tekst   │
│                                                                               │
│   PostToolUse:Bash ─► log-bash.sh (async)  ──► audit trail                   │
│   PermissionReq.  ─► log-permissions.sh    ──► audit trail                   │
│   Stop/TaskComp.  ─► verify_before_done.sh ──► projekt-specifik gate         │
│   *                 report-status.sh (async) ► watchfloor dashboard           │
└───────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────────────────┐
│ 4. PIPELINE-FASER — deterministiske trin inde i hver /slash-command           │
└───────────────────────────────────────────────────────────────────────────────┘

  /start ──► scripts/worktree.sh                  (git worktree add)
          └► claude/tools/start-validate.sh       (branch naming, plan exists)

  /implement ─► ruff format + ruff --fix         ┐  auto-fix commit
             └► eslint --fix                     ┘  "fix: lint auto-fixes"
             ─► mypy  (error count)              ┐  manuel fix commit
             └► tsc --noEmit                     ┘  "fix: resolve type findings"

  /static-analysis ─► sonar-preflight.sh          (auto-start SonarQube docker)
                   ─► sonar-scanner               (projectKey = dir name)
                   ─► qualitygates/project_status (HTTP api, FAILED = WARNING)
                   ─► parse-coverage.py           (vitest / pytest-cov)
                   ─► BASELINE_MYPY.md regression check

  /commit ──► commit-preflight.sh                 (pre-commit validation)
           └► commit-preflight.sh --ratchet       (MUST/SHOULD/MAY tiers via
                                                   ratchet-classify.py på
                                                   git diff --name-only)

  /done ───► done-verify.sh                       (worktree removed, docs
                                                   prefixed DONE_, plan
                                                   updated)

┌───────────────────────────────────────────────────────────────────────────────┐
│ 5. GRINDER  (claude/tools/grinder.sh — rent deterministisk pass-flow)         │
└───────────────────────────────────────────────────────────────────────────────┘

     discover ─► grinder-discover.sh/.py  ──► grinder-plan.yaml (batches)
        │
        ├──► pass-1-autofix     (mechanical: ruff/eslint/shellcheck --fix)
        │         lib/grinder-mechanical.sh
        │
        ├──► pass-2-coverage    (lib/grinder-coverage.sh
        │         parse-coverage.py  →  suppression check  →  batch exec)
        │
        ├──► pass-3-static      (lib/grinder-static.sh + grinder-static-
        │         partition.py → skip/propose/fix → proposals.md)
        │
        └──► pass-4-cve         (lib/grinder-cve.sh + grinder-cve-partition.py
                  → fix/defer/skip/suggest → cve-review.md)

     finalise ─► emit-baseline.py         ──► docs/grinder/baseline.json
                                               (schema-valideret)
              ─► finalise-deferred.py     ──► deferred-findings.json
                                               (schema-valideret)

┌───────────────────────────────────────────────────────────────────────────────┐
│ 6. FINDINGS-FILTRERING (get-findings.sh — bruges af /static-analysis, /qa)    │
└───────────────────────────────────────────────────────────────────────────────┘

   scanners ─► normalise-findings.py ─► filter-deferred.py ─► stdout JSON
                                          (trimmer alt der                 │
                                          allerede er i                   │
                                          deferred-findings.json)          │
                                                                          ▼
                                                          ratchet-classify.py
                                                            MUST  → block commit
                                                            SHOULD→ warn
                                                            MAY   → auto-log
                                                                    (ratchet-
                                                                     autolog.py)

┌───────────────────────────────────────────────────────────────────────────────┐
│ 7. MANIFEST-KONTRAKT  (CLAUDE.md i hvert projekt)                             │
└───────────────────────────────────────────────────────────────────────────────┘

   validate-manifest.py  ──► parser YAML-blokken "pipeline:" i CLAUDE.md
                              • toolchain.imports   (python-moduler skal load)
                              • smoke_test         (kommandoer skal exit 0)
                              • grinder.findings   (scanner paths, allowlist)
                          autopilot preflight_check() nægter at starte
                          hvis smoke_test fejler.

┌───────────────────────────────────────────────────────────────────────────────┐
│ 8. EXECUTION-PLAN KONTRAKT  (templates + schemas + validator)                 │
└───────────────────────────────────────────────────────────────────────────────┘

   Templates (claude/templates/)          JSON Schemas (claude/schema/ + schema/)
   ─────────────────────────              ──────────────────────────────────────
   template-feature.yaml      ┐           execution-plan.schema.json  ← /plan-
   template-greenfield.yaml   ├──► fyldes   manifest.schema.json        project
   template-refactor.yaml     ┘  af /plan-  grinder-plan.schema.json  ← grinder
                                 project    grinder-state.schema.json
   pre-push.template          ┐             baseline.schema.json      ← emit-
   quality.sh.template        ┘  installs   deferred-findings.json.      baseline
                                 i projekt  events.schema.json        ← ndjson
                                            grinder-dashboard-api.json    stream

   validate-plan.py  ──► JSON Schema-check + semantiske regler:
                          • id-unikhed på tasks, requirements, acceptance
                          • cross-refs (plan → requirements → acceptance)
                          • dependencies peger på eksisterende task-ids
                          • phase_results appendes af deviation-tracker.py

   Kører i:  • smoke_test (pipeline manifest) — bryder autopilot preflight
             • /plan-project (efter team-review)
             • /start-validate (før worktree oprettes)
```

## Relaterede dokumenter

- [security-layers.md](security-layers.md) — uddybning af lag 1–2 (sandbox + permissions)
- [grinder.md](grinder.md) — uddybning af lag 5 (grinder pass-flow)
