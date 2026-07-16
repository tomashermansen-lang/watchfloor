# Global Claude Configuration

## Pipelines

The canonical phase order lives in
`adapters/claude-code/claude/tools/lib/phase-selector.sh` as the
`PHASE_ORDER` bash array. Slash commands and `commands/` markdown live
in `adapters/claude-code/claude/commands/`. Treat both as the source
of truth — do not duplicate the order in prose elsewhere.

**Light vs Full** are semantic variants of the same `PHASE_ORDER`:
- **Light (solo)** — uses `/review` and `/qa` (single agent each).
- **Full (team)** — uses `/team-review` and `/team-qa` (multi-agent
  fan-out + Fixer pass) and inserts `/manualtest` before `/team-qa`.

Phase-placement design notes (rationale lives near the change in
`phase-selector.sh`):
- `/implement` runs linters + type checkers inline.
- `/static-analysis` runs SonarQube + coverage at the END so it sees
  post-`/qa` code (avoids the qa-bypass observed in plan-schema-2-0
  autopilot run, 2026-04-29).
- `/testplan` runs BEFORE `/review` so review can verify TESTPLAN.md
  scope (added 2026-05-04 to close the silent-pass loop where qa only
  checks "every TESTPLAN scenario has a test").

Per-project manifest (toolchain, smoke commands, preconditions) lives
in `pipeline.yaml` at each project's root. **Note:** `pipeline.yaml`
does NOT define phase order.

**When to use which mode:**
- **Flow mode** (`/<command> flow <feature>`): Standard — worktree isolation, phase commits, audit trail
- **Standalone** (`/<command> <feature>`): Quick one-off without worktree (hotfix, docs)
- **Autopilot** (`bash ~/.claude/tools/autopilot.sh <task>`): Single backend-only task with unambiguous criteria — fully hands-off tmux pipeline
- **Autochain** (`bash ~/.claude/tools/autopilot-chain.sh <plan>`): Sequentially runs autopilot through every autopilot-eligible task in a plan
- **Planning** (`/plan-project`): Produce structured `execution-plan.yaml` with team review

**Continuous workflows (independent of feature pipeline):**
- **Grinder** (`bash ~/.claude/tools/grinder.sh <subcmd>`): Codebase improvement loop — discover findings then run mechanical / coverage / static-analysis / CVE passes. Subcommands: `discover | run | resume | pause | status | ack-review`.

**Local-LLM routing (opt-in, autopilot only).** Two env vars route
selected phases through a local Ollama daemon for cost-controlled A/B
comparison: `LOCAL_LLM_ROUTING=1` enables, `LOCAL_LLM_PHASES=<csv>`
names the phases (subset of `PHASE_ORDER`). `/review` and `/qa` are
denylisted (`LOCAL_LLM_DENYLIST` in `claude-session-lib.sh`) and always
run on Anthropic. Both vars unset = byte-identical default. See
`adapters/claude-code/claude/tools/LOCAL_LLM_HARNESS.md` for setup,
the A/B example, and the denylist rationale.

**Per-phase Anthropic model routing.** Sibling primitive to LOCAL_LLM_ROUTING
for the Anthropic-paid path. As of 2026-05-24 the **default routing is
the Sonnet+Haiku combo canary C proved cheapest** (56% under Opus
baseline, $16.78 vs $38.01 on cost-measurement-baseline): Sonnet 4.6
for every reasoning phase (BA, plan, testplan, review, implement, QA),
Haiku 4.5 for the mechanical phases (static-analysis, commit). The
default lives in `DEFAULT_MODEL_PER_PHASE` in `claude-session-lib.sh`.

Override surfaces, narrowest to broadest:
- **Per-task** — set `runner.env.MODEL_PER_PHASE` on the task in the
  execution plan. Preferred for A/B canary work.
- **Per-invocation** — prefix `MODEL_PER_PHASE="ba=claude-opus-4-7,..."`
  on the autopilot call. Partial overrides are honored: any unmentioned
  phase still falls through to the default (no "all-or-nothing" tax).
- **Per-shell** — `export MODEL_PER_PHASE="..."` for every run in this
  shell. Use sparingly.
- **Disable the default entirely** — `MODEL_PER_PHASE=""` (empty
  string) returns to the legacy ANTHROPIC_MODEL (Opus) path. Used for
  the canary-A-style cost-sensitive A/B comparisons.

Composes with LOCAL_LLM_ROUTING: local routing takes precedence for
routed phases because LOCAL_LLM_ENV_VARS expands after the per-phase
ANTHROPIC_MODEL setting.

**Sonnet thinking-bloat nudge (opt-in).** When `AUTOPILOT_SONNET_NUDGE_ENABLE=1`
is set in the spawn env AND the phase routes to a Sonnet model,
`run_phase` sets `CLAUDE_CODE_EFFORT_LEVEL=medium` and appends a
one-sentence "Think briefly. Do not enumerate alternatives unless
explicitly asked." nudge to the system prompt. Anthropic's documented
knob, ~76% fewer output tokens at SWE-bench parity (Opus 4.5 launch).

**The nudge is OFF by default** — the same-day D-vs-F canary comparison
on 2026-05-24 found that the nudge correlated with `/implement` commit
failures (D with nudge on never committed its work; F with nudge off
committed cleanly with the same model). Anthropic's adaptive-thinking
docs already warn that medium effort may degrade reasoning-heavy
workloads, and skipping the careful "did I `git add` everything?" step
is exactly that failure mode. Only the literal string `"1"` enables;
other values leave the nudge off.

**Compact predecessor context (backlog #64, schema 2.0 plans only).**
The `predecessor-context.py` helper produces a phase-tuned compact block
(decision shadow + interfaces + diff stat/body) for each completed
dependency, replacing the old practice of reading full REQUIREMENTS.md +
PLAN.md per dep. Producer: `/done` Step 3.5 populates `codebase_snapshot`
and `predecessor_context` on the completing task. Consumer: phase commands
(/ba, /plan, /testplan, /implement, /review, /qa) invoke the helper per
their phase profile (see `skills/plan-detection/SKILL.md`). Backward-compat:
falls back to artifact reads per-dep if metadata is absent. Empirically
backed by Chroma "Context Rot" (Jul 2025) and arXiv:2602.11988 "Evaluating
AGENTS.md" (Feb 2026) showing verbose repo context degrades accuracy and
inflates cost ~20%+. Symbol-map extension added 2026-05-24 (canary
A/B/C antipattern fix): for `/plan`, `/implement`, `/review`, the helper
emits a per-file function/class/method listing with line ranges for each
file in `codebase_snapshot.modules_changed`, sourced from
`codebase_snapshot.symbol_map` if persisted by `/done` or extracted
on-the-fly via `lib/extract_symbols.py`. Lets the agent navigate the
predecessor's touched files with `Read --offset --limit` instead of
pulling the whole file (Aider repo-map pattern; claude-code #34304
measured 80% context reduction on multi-file work).

**Grinder auth preflight.** `grinder.sh run` and `grinder.sh resume` invoke a cheap headless `claude -p` probe before acquiring the lock and abort with exit 2 (`claude auth required — run claude login and retry`) if `claude` is unauthenticated, missing from PATH, or times out. This closes the silent-retry failure mode that produced reverted commits during the 2026-05-09 dotfiles run. Tests bypass the probe via `GRINDER_SKIP_AUTH_PREFLIGHT=1` (loud WARNING on stderr). Tunables: `AUTH_PROBE_TIMEOUT_S` (default 15s), `AUTH_PROBE_PROMPT`. The mid-run classifier emits a structured `auth_failed` NDJSON event and short-circuits the retry loop via the named sentinel `AUTH_FAILED_EXIT_CODE` (default 42).

## Bash error class rubric

The PostToolUse hook `classify-bash-result.sh` prepends one of seven
classes to every Bash tool result via the `additionalContext` channel:

```
[exit_code=1 stderr_class=sandbox_denied]
```

React to each class deterministically — do not waste turns mutating
parameters on errors that cannot be made to succeed:

- **`sandbox_denied`** on `ps`, `pkill`, `lsof`, `sysmon` — expected;
  the macOS Seatbelt sandbox blocks these. Do not retry, do not switch
  flags. If the command was a diagnostic check, treat the absence of
  data as "unknown" and move on.
- **`network_blocked`** — the sandbox allowlist did not match. The
  operation cannot work in this session. Surface the limitation to the
  user; do not retry.
- **`timeout`** (exit 124/137/143 or matching stderr) — increase the
  `timeout` parameter or split the work into smaller commands. Do not
  retry as-is.
- **`permission_denied`** — different command needed; do not retry the
  same command with `sudo` (not allowed in the sandbox).
- **`not_found`** on a path you just constructed — your path logic is
  wrong; fix it, do not blindly retry.
- **`other`** — surface to user; do not assume the error is transient.
- **`ok`** (exit 0) — proceed normally.

This rubric exists because the canary A/B/C runs showed 24-38% of all
Bash tool calls returned non-zero exits, and undifferentiated retries on
sandbox-denied operations were the single largest source of wasted
turns. The classifier is sourced via
`adapters/claude-code/claude/tools/lib/bash-stderr-classify.sh` (also
callable directly for scripts).

## System Port Registry

All local dev servers use reserved ports to avoid conflicts.
Start everything: `start-system` (or `~/start-system.sh`).

Configure project paths via env vars or `~/.claude/project-dirs.conf`.
Default projects root: `$PROJECTS_ROOT` (defaults to `~/Projekter`).

| Project | Backend | Frontend | Notes |
|---------|---------|----------|-------|
| Claude Dashboard | 8787 | 5175 | `./dashboard/` (subtree in dotfiles monorepo) |
| OIH | 8100 | 5174 | `$PROJECTS_ROOT/OIH/` — also Postgres 5432/5433, Langfuse 3000 |
| Eulex RAG | 8200 | 5173 | `$PROJECTS_ROOT/eulex-single-law-retrieval-artikel99/` |
| SonarQube | 9100 | — | `$PROJECTS_ROOT/sonarqube/` — static analysis |

Commands: `start-system {all|dashboard|oih|eulex|sonarqube|stop}`

## Dotfiles Repo

The dotfiles repo is the source of truth for the CLI pipeline.
Deploy changes: `bash adapters/claude-code/sync.sh restore` then restart Claude Code.
Validate sync: `bash adapters/claude-code/sync.sh diff`

**Agent constraint:** `~/.claude/CLAUDE.md`, `~/.claude/settings.json`,
`~/.claude/agents/`, `~/.claude/commands/`, `~/.claude/skills/`,
`~/.claude/rules/`, and `~/.claude/hooks/` are in the sandbox deny list —
the agent cannot run `sync.sh restore` itself. After editing any deployed
file in the dotfiles repo, **always present the deploy command to the
user explicitly** so they can run it manually:

```
bash adapters/claude-code/sync.sh diff      # review pending changes
bash adapters/claude-code/sync.sh restore   # deploy to ~/.claude/
# then restart Claude Code for the change to take effect
```

Never silently skip this step — the user needs to know that an edit in
the repo is not yet active in their running session.

## Codebase Orientation

When orienting in a project or searching for current behavior, **skip
`docs/DONE_*` folders**. They are archived feature artifacts (PLAN.md,
REQUIREMENTS.md, QA_REPORT.md, autopilot-stream.ndjson, etc.) — often
megabytes per folder — and they pollute Glob/Grep results with stale
state that no longer reflects how the system works now.

The current truth is the code itself, `CLAUDE.md` files, `git log` /
`git blame`, and `docs/INPROGRESS_*` + `docs/BACKLOG.md` for active work.

**Read inside `DONE_*` only when:**
- The user explicitly asks ("check what we did in feature X")
- A bug is traced via `git log` or `git blame` to a specific feature folder
- Performing a retro that requires cross-feature comparison

The same rule applies to any equivalent archive convention in other
projects (e.g., `archive/`, `legacy/`, `_old/`).

## Security Model

**Trust boundary:** `$PROJECTS_ROOT` (default `~/Projekter/`) — all projects live
here. The macOS Seatbelt sandbox enforces this at the kernel level.

**Three layers:**
1. **Sandbox (kernel):** Bash writes only to `$PROJECTS_ROOT` + `/tmp`. Credential
   paths (`~/.ssh`, `~/.aws`, etc.) are kernel-blocked from Bash reads.
2. **Permission deny rules (application):** Edit/Write/Read blocked on credential
   paths and shell config (`~/.bashrc`, `~/.zshrc`, `~/.claude/settings.json`).
3. **Git (reactive):** Tracked file changes reversible via `git checkout`.

**Permission inheritance:** Global `~/.claude/settings.json` defines sandbox,
deny rules, and default allow list. Per-project settings contain only hooks,
WebFetch domains, and env vars — everything else is inherited.
