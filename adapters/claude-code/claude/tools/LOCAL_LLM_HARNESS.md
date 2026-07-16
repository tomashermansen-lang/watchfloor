# Local-LLM Test Harness — Operator Guide

Opt-in env-var routing of selected `autopilot.sh` phases through a local
Ollama daemon for cost-controlled A/B comparison against the default
Anthropic path. Default-Anthropic behavior is byte-identical when the env
vars are unset — zero regression on the hot path.

## Setup

The harness assumes [Ollama v0.14+](https://ollama.com/) is installed and
running locally. Ollama exposes a native Anthropic Messages endpoint
(`POST /v1/messages`) since v0.14, so no proxy or translation layer is
needed — Claude Code talks to Ollama directly when
`ANTHROPIC_BASE_URL=http://localhost:11434` is set.

```sh
brew install ollama
brew services start ollama
ollama pull qwen3.6:35b-a3b
```

`qwen3.6:35b-a3b` is the recommended baseline model (SWE-Bench 77.2,
close enough to Sonnet 4.6 for prose-shaped phases like `/ba` and
`/plan`; not close enough to Opus 4.7 for adversarial security review,
which is why `/review` and `/qa` are denylisted — see below).

Any other Ollama-served model will work; pass it via the operator's
pre-run `ollama run <model>` (the harness does not select the model,
Ollama does).

## Environment Variables

| Variable | Type | Purpose |
|---|---|---|
| `LOCAL_LLM_ROUTING` | boolean | Master switch. **Only the literal string `1` enables routing.** Any other value — including unset, empty, `0`, `true`, `yes`, `01`, or `"1\n"` (trailing newline) — leaves autopilot on the default Anthropic path. |
| `LOCAL_LLM_PHASES`  | string  | Comma-separated subset of `PHASE_ORDER` (`ba,plan,testplan,review,implement,qa,static-analysis,commit`). Phases listed here route to Ollama; phases NOT listed route to Anthropic. Required when `LOCAL_LLM_ROUTING=1`; empty list is equivalent to disabled. Tokens may have leading/trailing whitespace (trimmed); empty tokens (consecutive commas) are discarded. |

**Edge cases:**

- A trailing newline in `LOCAL_LLM_ROUTING` (e.g. `$'1\n'`) does NOT enable routing — strict literal-`1` comparison.
- An unknown phase name in `LOCAL_LLM_PHASES` (e.g. `foobar`) aborts autopilot at startup with exit 2.
- If `LOCAL_LLM_ROUTING=1` but the Ollama daemon is not reachable (`curl -sf http://localhost:11434/api/tags` returns non-zero), autopilot aborts at startup with exit 2 BEFORE any worktree mutation.

## Example A/B Comparison

Run the same fixture task twice — once on Anthropic (baseline), once on
Ollama — and diff the artefacts. The `--stop-after-phase` flag halts
both runs at the same boundary so the comparison is clean.

```sh
# Baseline: default Anthropic path
bash adapters/claude-code/claude/tools/autopilot.sh \
  --stop-after-phase static-analysis my-fixture-task

# Routed: Qwen via Ollama for the prose-shaped phases
LOCAL_LLM_ROUTING=1 \
LOCAL_LLM_PHASES=ba,plan,testplan,implement,static-analysis \
  bash adapters/claude-code/claude/tools/autopilot.sh \
  --stop-after-phase static-analysis my-fixture-task
```

Both runs produce `docs/INPROGRESS_Feature_my-fixture-task/REQUIREMENTS.md`,
`PLAN.md`, `TESTPLAN.md`, source code, and `STATIC_ANALYSIS.md` in
parallel worktrees. Diff the artefact directories to assess routing
quality.

## Denylist (/review, /qa)

The denylist is hardcoded in `claude-session-lib.sh` as
`LOCAL_LLM_DENYLIST=(review review-team qa qa-team)`. Even if the
operator explicitly names `review` or `qa` in `LOCAL_LLM_PHASES`, those
phases ALWAYS run against Anthropic — the denylist wins.

The denylist exists because the cost-quality tradeoff inverts for
adversarial phases. Qwen3.6 SWE-Bench 77.2 is close to Sonnet 4.6 (79.6)
on prose-shaped work, but the 10-point gap to Opus 4.7 on adversarial
security review is too risky for `/review` and `/qa` — those phases
must catch subtle bugs that a less-capable model would miss. The
defensive `review-team` / `qa-team` entries cover a possible future
schema migration where team variants become distinct PHASE_ORDER members.

There is no env var to disable the denylist; the safety is a structural
invariant.

## Explicit Opt-In Policy

The harness is opt-in at every invocation. There is **no** persistent
config file, **no** shell rc default, **no** autopilot.sh internal
default that enables routing. Every operator run that wants routing
must set both env vars on the command line.

This is intentional: a future operator inheriting a session SHOULD see
`bash autopilot.sh <task>` as a default-Anthropic run, period — no
hidden state, no surprises.

## Sibling Primitive: `MODEL_PER_PHASE` (Anthropic-paid path)

For cost-tier mixing on the Anthropic-paid path (no Ollama involved),
set `MODEL_PER_PHASE` to a comma-separated list of `<phase>=<model>`
pairs. Each phase's `claude -p` spawn receives `ANTHROPIC_MODEL=<model>`
overriding the operator default.

```sh
# Example: cheap on mechanical phases, mid-tier on reasoning, top-tier on review
MODEL_PER_PHASE="ba=claude-sonnet-4-6,plan=claude-sonnet-4-6,testplan=claude-sonnet-4-6,review=claude-opus-4-7,implement=claude-sonnet-4-6,qa=claude-sonnet-4-6,static-analysis=claude-haiku-4-5" \
  bash autopilot.sh <task>
```

### Composition with LOCAL_LLM_ROUTING

When both `LOCAL_LLM_ROUTING=1` and `MODEL_PER_PHASE` are set:
- A phase routed to local (in `LOCAL_LLM_PHASES`, not in DENYLIST) uses
  Ollama's `ANTHROPIC_MODEL` from `LOCAL_LLM_ENV_VARS` (local routing wins).
- A phase NOT routed to local (default Anthropic path) uses the
  per-phase `ANTHROPIC_MODEL` from `MODEL_PER_PHASE` (if a pair matches).
- A phase in neither uses the operator's environment-default `ANTHROPIC_MODEL`.

Implementation: `get_model_for_phase` in `lib/claude-session-lib.sh`
parses the CSV. Bash 3.2 portable (no associative arrays). The override
is injected into both `claude -p` spawn sites (primary + resume-loop)
between the `env -u` flags and `LOCAL_LLM_ENV_VARS` so local routing
takes precedence.

Same opt-in policy: unset = byte-identical default Anthropic spawn.

## Troubleshooting

**"Error: Ollama health check failed"** — the daemon is not running or
`/api/tags` is broken. Run `brew services start ollama` and retry.

**"Unknown phase in LOCAL_LLM_PHASES: 'foobar'"** — a phase name in
`LOCAL_LLM_PHASES` is not in `PHASE_ORDER`. Valid phases:
`ba`, `plan`, `testplan`, `review`, `implement`, `qa`, `static-analysis`, `commit`.

**A routed phase fails immediately with a 404 from Ollama** — the
configured model is not pulled. Run `ollama pull qwen3.6:35b-a3b`
(or whatever model you have selected) and re-invoke. The harness does
NOT auto-pull models — that is an operator decision.

**A routed phase produced lower-quality output than expected** —
expected for `/implement` on architecturally complex features. Switch
`LOCAL_LLM_PHASES` to a smaller subset (e.g. `ba,plan,testplan` only)
and let `/implement` run on Anthropic.

**The default path looks slower after enabling the harness** — should
not happen. If you observe a regression on a `LOCAL_LLM_ROUTING` unset
invocation, file a bug — the design contract (R8/R13) is zero curl
probe, zero env mutation, byte-identical spawn on the default path.
