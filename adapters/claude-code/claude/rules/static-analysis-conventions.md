# Static Analysis Conventions

## Severity Mapping

All tools map to a unified severity scale:

| Tool | Tool Severity | Unified Severity |
|------|--------------|-----------------|
| SonarQube | BLOCKER, CRITICAL | CRITICAL |
| SonarQube | MAJOR | WARNING |
| SonarQube | MINOR, INFO | SUGGESTION |
| mypy | error | WARNING |
| mypy | note | SUGGESTION |
| tsc | error | WARNING |
| ruff | auto-fixed | N/A (already resolved) |
| eslint | auto-fixed | N/A (already resolved) |
| shellcheck | error | WARNING |
| shellcheck | warning | WARNING |
| shellcheck | info, style | SUGGESTION |

CRITICAL and WARNING findings must be fixed. SUGGESTION findings are logged.

## Fix Scope

- **In-scope:** findings in files changed on this branch (`git diff main...HEAD --name-only`)
  Use the **three-dot form** so the diff is pinned to the merge-base
  (fork commit), not the tip of `main`. Under parallel autopilot a
  sibling task may merge to `main` while this task is still running;
  the two-dot form (`main..HEAD` or the shorthand `main` without `...`)
  would then list the sibling's files as "in-scope" and waste turns
  trying to fix code this branch never touched.
- **Out-of-scope:** findings in files this branch does not touch
- Never fix out-of-scope files during static analysis — log them in the report
  as "pre-existing, untouched file" so they're visible but don't block the pipeline

## Commit Separation

### In `/implement` (lint + type checking + bash lint)

Two distinct commits, in order:

1. `fix(<feature>): lint auto-fixes` — ruff format, eslint --fix (safe, mechanical)
2. `fix(<feature>): resolve inline lint findings` — manual fixes for
   mypy/tsc/shellcheck findings (renamed 2026-05-20 when shellcheck
   joined the inline-lint set; bash is ~30% of dotfiles LOC and the
   autopilot/grinder orchestrators are bash, so it must gate per-PR).
   Note: `/static-analysis` uses the distinct message `resolve static
   analysis findings` for its SonarQube/coverage fixes — the two
   phases have separate commit names to keep git log searchable.

### In `/static-analysis` (SonarQube + coverage)

Two distinct commits, in order:

1. `fix(<feature>): resolve static analysis findings` — manual fixes from SonarQube issues
2. `docs(<feature>): static analysis report` — the STATIC_ANALYSIS.md artifact

Skip any commit where no files changed. Never combine auto-fixes and
manual fixes — clean git history lets you revert them independently.

## Tool Runner Detection

Projects use different package managers. Detect the runner before invoking
Python tools:

- If `pyproject.toml` exists and `uv` is available → `uv run <tool>`
- If `.venv/bin/<tool>` exists → `.venv/bin/<tool>`
- Otherwise → bare `<tool>` (global install)

TypeScript tools always use `npx` from the project's frontend directory.

## SonarQube Integration

- Project key convention: directory name (e.g., `OIH`, `RAG-framework`)
- Token stored in `sonar-project.properties` (gitignored, never committed)
- Quality gate is the authoritative pass/fail signal
- If SonarQube is not running or scanner not installed, skip gracefully —
  the phase still runs linters and type checkers

## Coverage Enforcement

If a project has `BASELINE_MYPY.md`, `/static-analysis` checks for regression:
- Compare current mypy error count with baseline
- If errors increased: report as WARNING
- If errors decreased: update baseline (optional, at user discretion)

If `coverage.xml` exists from a previous run:
- Compare line coverage percentage
- Coverage regression: WARNING

## SonarQube New-Code Gate

If `sonar-project.properties` exists, `/static-analysis` checks the new-code
quality gate after scanner run:
- `curl -sf http://localhost:9100/api/qualitygates/project_status?projectKey=$KEY`
- FAILED gate = WARNING minimum
- Skip gracefully if SonarQube is not running

## Interaction with Implementation and QA Phases

- **Linters and type checkers run in `/implement`** (Step 5):
  ruff/eslint (auto-fix), mypy/tsc (type), shellcheck (bash lint on
  changed `.sh` files only). In `/static-analysis` they are **not
  re-run on the whole project** — that would duplicate `/implement`'s
  gate. Two carve-outs are legitimate exceptions and must stay:
    1. **mypy baseline regression** — Step 2.3 of `/static-analysis`
       runs `mypy src/` once to compare the repo-wide error count
       against `BASELINE_MYPY.md`. This is a different signal than
       `/implement`'s "no NEW errors on changed files" gate; only
       `/static-analysis` produces it.
    2. **Scoped post-fix re-verification** — Step 4.3 of
       `/static-analysis` re-runs **only the tool that flagged the
       finding being fixed**, on **the file just edited** (e.g.,
       `mypy src/foo.py`, not `mypy src/`). This is a per-fix sanity
       check, not a full re-validation.
  Anything beyond those two carve-outs is duplicated work without
  duplicated signal.
- `/static-analysis` owns SonarQube, coverage enforcement, and baseline
  regression — fix findings from these tools here.
- `/qa` and `/team-qa` own behavior, correctness, and test coverage — they
  read STATIC_ANALYSIS.md to avoid re-flagging resolved issues. They also
  skip their opening "Run all tests" + "Syntax/type check" steps when the
  `.tests-green-sha` marker from `/implement` matches HEAD (marker covers
  tests + lint + type-check; falls back to running them when absent/stale).
- If QA finds a type error or lint issue that `/implement` missed, that's
  a gap in the inline lint step — fix the issue AND note it for future runs.
