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

CRITICAL and WARNING findings must be fixed. SUGGESTION findings are logged.

## Fix Scope

- **In-scope:** findings in files changed on this branch (`git diff main --name-only`)
- **Out-of-scope:** findings in files this branch does not touch
- Never fix out-of-scope files during static analysis — log them in the report
  as "pre-existing, untouched file" so they're visible but don't block the pipeline

## Commit Separation

### In `/implement` (lint + type checking)

Two distinct commits, in order:

1. `fix(<feature>): lint auto-fixes` — ruff format, eslint --fix (safe, mechanical)
2. `fix(<feature>): resolve type checker findings` — manual fixes for mypy/tsc errors

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

- **Linters and type checkers run in `/implement`** (Step 5). They do NOT
  run again in `/static-analysis`. This avoids 8-16 minutes of duplicate work
  per feature.
- `/static-analysis` owns SonarQube, coverage enforcement, and baseline
  regression — fix findings from these tools here.
- `/qa` and `/team-qa` own behavior, correctness, and test coverage — they
  read STATIC_ANALYSIS.md to avoid re-flagging resolved issues.
- If QA finds a type error or lint issue that `/implement` missed, that's
  a gap in the inline lint step — fix the issue AND note it for future runs.
