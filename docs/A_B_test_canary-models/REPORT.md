<!-- A/B/C test: model-tier + context-engineering comparison for autopilot pipeline -->
<!-- Final: 2026-05-24 (all 3 canaries done through /static-analysis) -->

# Model-tier + context-engineering A/B/C test — autopilot pipeline

## Purpose

Measure whether (a) a cheaper model can substitute for Opus 4.7 in the
autopilot pipeline, and (b) whether backlog #64 lean predecessor context
amplifies the value of cheaper-model substitution. All three canaries
implement the **same** feature spec (`cost-measurement-baseline`) through
the same 8-phase pipeline, halting at `/static-analysis`.

## Variants

| | A — Opus baseline | B — Sonnet routed | C — Sonnet+Haiku+#64 |
|---|---|---|---|
| Model strategy | claude-opus-4-7 (all phases) | claude-sonnet-4-6 (all phases) | claude-sonnet-4-6 for /ba../qa, claude-haiku-4-5 for /static-analysis |
| Predecessor context | Full artifact reads (legacy) | Full artifact reads (legacy) | Compact via `predecessor-context.py` (#64) |
| Stops after | `/static-analysis` | `/static-analysis` | `/static-analysis` |
| Worktree | `dotfiles-canary-anthropic-baseline` | `dotfiles-canary-sonnet-routed` | `dotfiles-canary-sonnet-haiku-leancontext` |
| Status | DONE | DONE | DONE |

## Headline numbers

Authoritative via `adapters/claude-code/claude/tools/cost-summary.py`
(which dedupes phantom result events per session and sums failed-attempt
costs across retries — both of which `autopilot-summary.json` gets wrong).

| | A (Opus) | B (Sonnet) | **C (Sonnet+#64)** |
|---|---|---|---|
| **Total cost** | $38.01 | $18.35 | **$16.78** ← cheapest |
| Cost vs A | 1.00x | 0.48x | **0.44x** |
| Cost vs B | 2.07x | 1.00x | **0.91x** |
| API time (Σ phase durations) | **103.5 min** ← fastest | 127.7 min | 121.2 min |
| Wall bracket | 144 min (incl. 79-min operator gap) | 130 min | **125.5 min** ← fastest |
| Turns | **328** ← fewest | 445 | 409 |
| Sessions | 7 | 7 | 8 (1 QA retry) |
| Artifact lines (req+plan+test+rev+qa+sa) | 1986 | 1023 | 1247 |
| Feature LOC | 303 | 107 | 148 |
| Test file LOC | 1124 | 676 | 805 |

### Caveat on A's accounting

A ran in **two autopilot invocations** (implement halted, then operator
resumed via `--from qa` ~40 minutes later). The stream NDJSON is
append-only across invocations, so the cost-summary tool sees all 7
phases — but any partial/failed run between invocations that didn't
write to the stream is invisible. **A's numbers are lower-bounds.** The
relative comparison still holds (C cheapest, A most expensive).

A's `autopilot-summary.json` is broken — it only captured the second
invocation's 2 phases. Cost on the dashboard would have read ~$10.76
instead of the real $38.01. Exactly the bug the
`cost-measurement-baseline` feature being implemented in these canaries
is designed to fix (via `predecessor_cost_usd` tracking).

## Cost per phase

| Phase | A | B | C | Best | Notes |
|---|---|---|---|---|---|
| /ba | $1.69 | $1.06 | **$0.75** | C | C 56% cheaper than A |
| /plan | $2.14 | **$0.61** | $0.77 | B | C and B near tie; A 3.5× |
| /testplan | $1.95 | $1.05 | **$0.40** | C | C 79% cheaper than A — predecessor-context payoff |
| /review | $4.43 | $2.47 | **$2.45** | C | C and B tied; A 80% more |
| /implement | $17.02 | $9.40 | **$6.00** | C | C 65% cheaper than A — biggest single win |
| /qa | $7.28 | **$2.78** | $5.92* | B | *includes failed retry attempt that found a real BLOCKER bug |
| /static-analysis | $3.48 | $0.97 | **$0.49** | C | Haiku for SA — 86% cheaper than A |

## Quality verdict per canary

### A (Opus) — "Polished but with hidden regression"

**Strengths:**
- Most defensive code (`isinstance` for null vs 0 cache token, fail-closed enum defaults)
- Cleanest `read_predecessor_cost` (env-var python pattern, structured errors)
- 0 thinking-bloat blocks — Opus thinks tersely
- Most thorough acceptance scenarios + edge cases

**Defects:**
- **CRITICAL: Reverted `ANTHROPIC_MODEL=$routed_model` line in `compute_local_llm_env_array`** — broke Ollama routing. A's own QA missed it. Stale TC7 test made it "pass" silently. Direct evidence of Opus' "let me clean while I'm here" failure mode
- Missed dual `claude -p` spawn site (resume-loop not patched)
- Diverged from estimate by 3.4× (303 vs 90 lines)
- Most verbose artifacts (1986 lines)

### B (Sonnet uniform) — "Lean and correct, missed some semantic nuance"

**Strengths:**
- Caught dual spawn site (resume-loop covered)
- Fixed TC7 stale test correctly (updated test, didn't revert production)
- Closest to estimate (107 lines vs 90 = 1.2×)
- Most compact artifacts (1023 lines)
- No regression in production code

**Defects:**
- `cache_read_input_tokens` defaults to `0` not `null` (loses semantic distinction)
- Speculative flag-name `--max-turns-budget-usd` (unverified against real claude CLI)

### C (Sonnet+Haiku+#64) — "Cheapest, caught its own BLOCKER"

**Strengths:**
- **QA caught BLOCKER bug B1 (in C's own design)**: `MAX_BUDGET_USD=""` at line 1052 silently wiped the CLI-parsed value. The budget cap feature was **completely non-functional** before fix. No unit test caught it (all injected the variable directly).
- **QA caught N1 NOTE**: path injection in `read_predecessor_cost` Python literal
- Used predecessor metadata via #64 (Research Findings section cites it; EC9/EC10 reference predecessor primitives)
- Cleanest static analysis: 0 in-scope SonarQube findings, shellcheck clean
- Avoided A's ANTHROPIC_MODEL regression (lean context didn't lure C into "clean up while here" mode)
- Closest test estimate adherence under Sonnet variants

**Defects:**
- Inherited B's cache_read_input_tokens=0 (Sonnet-class semantic weakness — not context-fixable)
- **Spec drift on --max-budget-usd**: implemented as autopilot-level `check_budget_cap` instead of pass-through to `claude -p`. C's version is arguably more useful but doesn't match spec
- Scope creep: added `test_pipeline_yaml_unified.py` scope guard (unrelated to feature)
- 1 QA retry needed (initial attempt produced incomplete report; retry found and fixed B1)

## Antipattern analysis — agent behavior in stream NDJSON

Detected via `/tmp/claude/antipattern_scan.py`. Surfaces behaviors that
inflate cost, hurt quality, or slow runs.

| Antipattern | A | B | C | Reading |
|---|---|---|---|---|
| **Thinking-bloat blocks (>800 chars)** | **0** | 70 (185K chars) | 54 (125K chars) | Sonnet emits ~100K+ chars of thinking; pay output-token price |
| Max single thinking block | 0 | 9,888 chars | 8,230 chars | |
| Total Reads | 73 | 136 | **143** | C has MOST reads — counter to #64 hypothesis |
| Reads of `autopilot.sh` | 18× | 25× | **35×** | All three re-read the working file heavily |
| Reads of `execution-plan.yaml` | 5× | 16× | **27×** | Plan re-fetching across phases |
| Total Bash calls | 173 | 226 | **298** | |
| Failed tool results | 54 (31%) | 87 (38%) | 72 (24%) | C has lowest failure rate |
| Bash bursts (>40 in one phase) | impl=61, qa=50 | impl=118, qa=56 | impl=55, **qa=168** | C's QA retry doubled bash activity |
| Cross-canary leakage | n/a | n/a | 0 ✓ | After 2026-05-23 task-spec fix |
| Redundant globs | 6× INPROGRESS_Plan | 7× INPROGRESS_Plan | 7× INPROGRESS_Plan | Same across all — harness issue, not model |

### Surprising findings

1. **Opus has ZERO thinking-bloat blocks.** Sonnet variants emit 100K+ characters of thinking — output tokens you pay for. **This is a Sonnet cost driver that #64 cannot fix** (thinking happens regardless of input context size). Roughly $1-3 of B's and C's cost is thinking output that Opus simply doesn't do.

2. **C re-read `autopilot.sh` 35 times** — MORE than A (18×) and B (25×). The lean predecessor context didn't reduce re-reads of the working file; if anything, Sonnet's higher iteration count for /implement and /qa retry caused more re-reads.

3. **All three have plan-detection re-globbing 5-7×** — harness-level antipattern, not model-specific. Cache opportunity.

4. **C had the highest bash-burst in /qa (168 calls)** — partly from the retry doubling activity, partly because Sonnet's deeper QA review (the one that caught B1) required more exploratory commands.

5. **C's failed-tool-result rate is lowest (24%)** vs B (38%) and A (31%). Lean context may help the agent issue more-correct tool calls.

## Which canary was best, by axis

| Axis | Winner | Margin |
|---|---|---|
| **Total cost** | **C** ($16.78) | 9% < B, 56% < A |
| Cost per real bug caught at QA | **C** ($2.96/bug) | A caught 0 real bugs; B caught 0; C caught 2 |
| API time per dollar | A (2.7 min/$) | Opus is fast per dollar — but 2.3× total |
| Wall time | **C** (125.5 min) | 3% < B, 13% < A |
| Adherence to plan estimate | **B** (1.2×) | A worst (3.4×) |
| Final code correctness | **B & C tied** | A introduced ANTHROPIC_MODEL regression |
| Defensive coding richness | A | More null/error edge cases handled |
| Static analysis cleanliness | A & C tied | Both clean on changed files |
| Lowest thinking output waste | **A** | 0 bloat blocks vs B's 70 / C's 54 |
| Spec fidelity | A & B | C diverged on --max-budget-usd implementation |
| Fewest re-reads of working file | A | 18× vs 25× vs 35× |
| Fewest failed tool calls | C | 24% vs 31% vs 38% |

## Recommendation

**For substrate features with clear specs, C wins as the default:**
- 56% cheaper than A, 9% cheaper than B
- Fastest wall clock
- Cleanest static analysis on changed files
- QA caught a real BLOCKER bug (the only canary whose QA produced actionable findings)
- Avoided A's "let me clean while I'm here" regression

**Reserve A (Opus) for:**
- Security-sensitive features (auth, secrets, input boundaries)
- Multi-agent coordination (where Specification Gap matters per arXiv:2603.24284)
- Novel architecture (no existing pattern to clone)
- Any feature where post-merge regression cost > $30

**B has no unique strength** of its own — it gets you half the cost of A but without #64's context economy and without Opus' defensive depth. If you're switching to Sonnet, also adopt #64.

## Antipatterns worth fixing in the harness

These hit ALL THREE canaries — they're harness-level, not model-specific.
Subject of separate research (see § Research follow-up below):

1. **Plan re-globbing** — `INPROGRESS_Plan_*/execution-plan.yaml` globbed 5-7× per run across all variants. Cache the plan-detection result per session.
2. **Working-file re-reads** — `autopilot.sh` read 18-35× per run. Possible mitigation: surface relevant line-ranges from `codebase_snapshot.modules_changed` so the agent knows where to look.
3. **Failed-tool-result rate of 24-38%** — worth investigating which tool calls fail (Bash sandbox restrictions? non-zero exits handled as errors?).
4. **Sonnet thinking-bloat (Sonnet-specific)** — 50-70 blocks of >800 chars per run. Mitigated by interleaved-thinking config or "think briefly" prompt instruction.

## Methodology + reproducibility

- Cost numbers: `python3 adapters/claude-code/claude/tools/cost-summary.py <stream>.ndjson`
- Antipattern scan: `python3 /tmp/claude/antipattern_scan.py <stream>.ndjson [<more streams>]`
- Each canary halted via `--stop-after-phase static-analysis`. Worktrees never merged.
- C used `MODEL_PER_PHASE="ba=claude-sonnet-4-6,...,static-analysis=claude-haiku-4-5"` via `runner.env`
- C inherited backlog #64 metadata on 3 done predecessor tasks (`pause-after-phase-flag`, `local-llm-routing`, `chain-runner-overrides`) populated 2026-05-23
- All trustworthy numbers above re-confirmable by running the tool against the source streams

## Source data references

- A: `~/Projekter/dotfiles-canary-anthropic-baseline/`
- B: `~/Projekter/dotfiles-canary-sonnet-routed/`
- C: `~/Projekter/dotfiles-canary-sonnet-haiku-leancontext/`
- All worktrees are local-only branches; none merge to main

## Research follow-up

Deep investigation of the 4 harness antipatterns above is being conducted
against 2025-2026 authoritative sources. Findings + recommended fixes
will be appended to this document as `RESEARCH.md` once complete.
