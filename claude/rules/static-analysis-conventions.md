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

Three distinct commits, in order:

1. `fix(<feature>): static analysis auto-fixes` — ruff format, eslint --fix (safe, mechanical)
2. `fix(<feature>): resolve static analysis findings` — manual fixes from the fix loop (type errors, SonarQube issues)
3. `docs(<feature>): static analysis report` — the STATIC_ANALYSIS.md artifact

Skip any commit where no files changed. Never combine these — clean git
history lets you revert auto-fixes independently from manual fixes.

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

## Interaction with QA Phases

- `/static-analysis` owns lint, types, and code smells — fix them here
- `/qa` and `/team-qa` own behavior, correctness, and coverage — they read
  STATIC_ANALYSIS.md to avoid re-flagging resolved issues
- If QA finds a type error or lint issue that static analysis missed, that's
  a gap in static analysis config — fix the issue AND note it for future runs
