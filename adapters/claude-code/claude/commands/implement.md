---
description: Lead Developer — implement a feature using strict TDD after plan approval
argument-hint: <feature-name> OR flow <feature-name>
---

# Lead Developer: Implement $ARGUMENTS

Implement using strict Test-Driven Development.

## Flow Mode

See the flow-mode skill for protocol.

**Verifies feature branch** (already created by `/ba flow` or `/plan flow`)

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Implementation complete → `/static-analysis flow`
- `amend` → Continue implementing (more components needed)
- `stop` → Pause flow

## Test Plan Prerequisite

`docs/INPROGRESS_Feature_<feature>/TESTPLAN.md` is created by `/plan` (Step 12)
**before** review, not by this command. If TESTPLAN.md is missing when
/implement starts, STOP and tell the user to run `/plan flow <feature>`
(or `/plan flow autopilot <feature> --step testplan` for autopilot retry).

The legacy `--step testplan` mode is no longer accepted here — autopilot
calls `/plan flow autopilot <feature> --step testplan` instead.

## Domain Knowledge

- tdd-workflow skill — TDD cycle, test structure, mocking
- solid-principles skill — SOLID verification per component
- tool-dependency-policy rule — never fly-install missing packages; declare in manifest instead

## Live Observability

Newer Claude Code defaults are terse. To preserve audit trail in the
autopilot stream, **print a one-line rationale before each tool-call
sequence of ≥3 calls toward the same subgoal**. Example:

> Investigating test_api_plan failure — checking if it reproduces on main.

Then run the tools. Do NOT spiral into multi-paragraph explanations
(those still consume turns and don't add information that tool
descriptions and commit messages can't carry). One line, then act. If
you find yourself printing two consecutive rationales without tool
calls between them, you're over-narrating — stop and execute.

## Prerequisites

1. `docs/INPROGRESS_Feature_<feature>/PLAN.md` must exist and be reviewed (APPROVED).
2. Read `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md` for acceptance criteria.
3. Read `docs/INPROGRESS_Feature_<feature>/DESIGN.md` if exists.

## Step 0: Verify Feature Branch (flow mode)

```bash
git branch --show-current  # Must be on feature/<feature-name>
git status                 # Must be clean
```

**If NOT on feature branch:** STOP. Branch should exist from `/ba flow` or `/plan flow`.
**If uncommitted changes:** STOP. Ask user to commit or stash first.

## Step 0.5: Plan Detection & Orientation

**MANDATORY — run this glob BEFORE any other file reads:**
```
Glob pattern: docs/INPROGRESS_Plan_*/execution-plan.yaml
```
If found: Read the YAML, then follow the plan-detection skill
§ Project Orientation for task matching and context loading.
If not found: proceed standalone (no warnings, no behavior change).

If a plan is loaded and a matching task is found:
- Run auto-orient (Step 0.6) to understand full project scope and completed work
- Plan acceptance criteria become additional TDD test targets
- Use project plan context to ensure implementation aligns with overall architecture

If no plan found: proceed as normal (no change to existing behavior).

## Step 1: Verify Test Plan

`docs/INPROGRESS_Feature_<feature>/TESTPLAN.md` must already exist (created
by `/plan` Step 12 and reviewed by `/review` or `/team-review`). If missing:

```
TESTPLAN.md not found. Run `/plan flow <feature>` first to generate it.
The plan and test plan are reviewed together before implementation.
```

**STOP** if missing — do not generate TESTPLAN.md from /implement.
That breaks the review gate.

## Step 1b: Context Budget Check

Count components in TESTPLAN.md. If >3 components:
- Implement ONE component at a time using Step 2
- Run `/checkpoint` after each component (saves progress, frees context)
- If context feels constrained (repeated instructions being forgotten):
  STOP, run `/checkpoint`, tell user to start new session and continue with the next component

## Step 2: TDD Cycle (per component)

**a) Announce.** "Implementing [component] in `[file path]`. It does [one sentence]."

**b) Write test FIRST** in `tests/test_<module>.py`.

**c) Verify test fails.** `./scripts/run_tests.sh`. If it passes, test is wrong.

**d) Write minimum implementation.** Only enough to pass.

**e) SOLID checkpoint.** Use the solid-principles checklist. Refactor NOW if any fail.

**f) Run ALL tests.** Fix regressions immediately. "ALL tests" means your
unit/changed-area suite (`./scripts/run_tests.sh`). For a dashboard change you
MAY also run `bash dashboard/tests/run-all.sh` — it is safe in the sandbox now:
the git-fixture / server-bound suites self-SKIP (they run unsandboxed at the
phase **integration gate**, §5) and each suite is timeout-bounded, so the unit
suites get exercised here without wedging. What you must NOT do is try to force
those skipped integration suites to run in the sandbox — that only burns turns.
The heavy integration run happens ONCE per phase at the gate (`integration_test`
in `pipeline.yaml`, scoped `--only-integration`), never per feature task.

**g) Refactor** if code can be simplified while tests stay green.

**h) Summarize** in 2-3 sentences.

## Step 3: Final Verification

1. `./scripts/run_tests.sh` — report results
2. Run syntax/type checks appropriate to the project's language and tooling
3. Update `docs/INPROGRESS_Feature_<feature>/TESTPLAN.md` with final status
4. Update `README.md` if user-facing changes

## Step 4: Completion Checklist

Before presenting checkpoint, verify:
- [ ] ALL components from PLAN.md are implemented (none skipped, none deferred)
- [ ] ALL acceptance criteria from REQUIREMENTS.md have tests
- [ ] ALL tests pass (`./scripts/run_tests.sh`)
- [ ] NO TODOs, FIXMEs, or "implement later" in new code
- [ ] NO hardcoded values (use config/)

**Show the COMPLETE checklist to the user with pass/fail status for each item.**

## Step 5: Inline Lint + Type Checking

After all components pass TDD and the completion checklist is green, run
linters and type checkers inline — don't defer to `/static-analysis`.

### 5.1: Auto-Fix (lint + format)

Detect the Python runner per static-analysis-conventions.md § Tool Runner Detection.

```bash
# Python (if ruff available)
$RUN ruff check --fix .
$RUN ruff format .

# TypeScript (if TS files changed on this branch)
cd <frontend-dir> && npx eslint --fix .
```

If any files were modified by auto-fix:
```bash
git add -u
git commit -m "fix(<feature>): lint auto-fixes"
```
Skip the commit if no files changed.

### 5.2: Static Analysis (type + bash lint)

```bash
# Python
get-findings.sh mypy $RUN mypy src/ --no-error-summary

# TypeScript (if TS project)
cd <frontend-dir> && get-findings.sh tsc npx tsc --noEmit

# Bash — scope to files changed on this branch only. shellcheck on the
# whole repo is the grinder's job; per-feature flow runs it just on
# touched .sh files so feedback is fast and findings stay actionable.
CHANGED_SH=$(git diff --name-only main...HEAD | grep -E '\.sh$' || true)
if [[ -n "$CHANGED_SH" ]]; then
  echo "$CHANGED_SH" | xargs get-findings.sh shellcheck shellcheck -f json -S warning
fi
```

shellcheck severity: `-S warning` (error + warning levels) is the
blocking bar. info/style are advisory and reported but not gating.
Bash is ~30% of this repo's LOC and drives the autopilot/grinder
orchestrators — without inline shellcheck on changed files, bash
regressions ship to main and only get caught later by the grinder.

### 5.3: Fix Static Analysis Findings

Fix all findings (type errors AND shellcheck error/warning) in files
changed on this branch (`git diff main...HEAD --name-only`). Pre-existing
findings in untouched files are logged but not fixed.

**Loop guard:** Maximum 3 fix passes. After each pass:
```
Static analysis pass <N>/3: <CLEAN | NEEDS FIX>
  Type findings: <fixed>/<remaining>
  shellcheck findings: <fixed>/<remaining>
```

After fixing, re-run ALL tests to ensure fixes didn't break anything.

If findings were fixed, commit:
```bash
git add -u
git commit -m "fix(<feature>): resolve inline lint findings"
```
Skip if no files changed. Never combine auto-fixes and manual fixes into
one commit. The commit name covers mypy/tsc/shellcheck collectively and
is intentionally distinct from `/static-analysis`'s `resolve static
analysis findings` (SonarQube/coverage) — separate names keep `git log`
greppable per phase.

### 5.4: Skip Conditions

- If ruff/eslint is not available: skip with a warning, don't fail
- If mypy/tsc is not available: skip with a warning, don't fail
- If shellcheck is not available AND .sh files changed: skip with a
  WARNING (loud — bash is the orchestrator layer, and shipping bash
  changes without shellcheck is a real regression risk). Install via
  `brew install shellcheck`.
- If zero linters AND zero type checkers ran: log a warning in the
  checkpoint summary but don't block — the `/static-analysis` phase
  will catch this via its tool coverage gate

### 5.5: Missing Package Policy

If a tool emits `Library stubs not installed`, `ModuleNotFoundError`, or
`Cannot find module`, follow the **tool-dependency-policy** rule
(claude/rules/tool-dependency-policy.md): do NOT run pip/uv/npm install
on the fly. Sandbox network policy blocks pythonhosted/npmjs and the
install will fail with tunnel-error retries. Instead:

1. Check `.venv/lib/python*/site-packages/` (or `node_modules/`) — if the
   package is there, the real issue is configuration.
2. If the package is genuinely missing, add it to `pyproject.toml`
   (`[project.optional-dependencies] dev`) or `package.json` `devDependencies`
   and report the gap. The user runs `uv sync --extra dev` outside sandbox.
3. Never retry a failed install — one tunnel error proves the network is
   blocked; further attempts only burn turns.

## Step 6: Start App (flow mode)

```bash
./ui_react/start.sh
```

Tell user:
- **URLs:** Shown in terminal output
- **Auto-reload:** Both backend and frontend reload on code changes
- Press `Ctrl+C` to stop
- Ready for manual testing

## Step 7: Flow Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Implementation complete: ✅

<Summary — branch, components implemented, test results, app URL>

Files written: <list of new/modified source files, test files, docs>
Branch: <branch>

On [yes]:
  1. git add src/ tests/ config/ ui_react/ docs/
     git commit -m "feat(<scope>): implement <feature>"
  2. After the commit lands, write the tests-green-sha marker so
     downstream phases (/qa, /team-qa, /commit-preflight) can skip a
     redundant full test rerun when HEAD has not changed:
     ```bash
     git rev-parse HEAD > docs/INPROGRESS_Feature_<feature>/.tests-green-sha
     ```
     (Marker is gitignored — proves Step 5 exited with tests + lint +
     type-check green at this SHA. /qa and /static-analysis update the
     same file at the end of their own green passes.)
  3. STOP — open a new chat and run: /qa flow <feature>
     (full pipeline: /manualtest flow <feature>)

On [amend]:
  → Continue implementing — specify what needs more work. Loop back to Step 2.

On [stop]:
  → Pause flow. Resume later in a new chat: /implement flow <feature>

Continue? [yes / amend / stop]
```

**Standalone mode:** Same format but omit phase commit (step 1) and say "run:" instead of "open a new chat and run:".

## Rules

- Follow all CLAUDE.md code standards (TDD, SOLID, no hardcoding).
- If plan is wrong mid-implementation: STOP and tell user.
- **NO DEFERRING.** Implement EVERYTHING in the plan. Do NOT leave TODOs, stubs, partial implementations, or "will be completed in next phase" comments. If a component is in the plan, it gets implemented NOW with passing tests. If it can't be implemented, STOP and explain why — don't silently skip it.
- **FULL VISIBILITY.** At checkpoint, show the COMPLETE list of: all components (implemented or not), all test results, all requirements mapped to tests. Never show "X of Y implemented" without listing what's missing. The user must see everything.
- **3-FIX STOP-RULE.** If the same test/build/lint failure persists after 3 fix attempts, STOP. Do not retry the same approach — the problem is architectural, not a typo. Present to the user: (1) what was tried in each of the 3 attempts, (2) why each failed, (3) at least one alternative approach. Oscillating failures (fix A breaks B, fix B breaks A) count as retrying the same problem.
- **EVIDENCE IN THIS MESSAGE.** If you have not run the verification command in THIS message, you cannot claim it passes. Show actual output (or pass/fail summary for long output). Banned completion phrases: "should work", "probably passes", "seems to", "likely works", "I believe it passes".
