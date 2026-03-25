---
description: Static Analysis — run linters, type checkers, and SonarQube, then report findings
argument-hint: <feature-name> OR flow <feature-name>
---

# Static Analysis: $ARGUMENTS

Run fast linters with auto-fix, type checkers, and SonarQube static analysis.
Produce a findings report and gate on blockers.

## Flow Mode

See the flow-mode skill for protocol.

**Checkpoint:** `[yes / amend / stop]`
- `yes` → Commit report → continues to `/manualtest flow` (or `/team-qa flow` in autopilot)
- `amend` → User provides feedback, re-run specific checks
- `stop` → Pause flow

## Domain Knowledge

- tdd-workflow skill — test commands per project
- solid-principles skill — architecture rules to cross-reference

## Prerequisites

Read ALL feature docs: `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md`,
`docs/INPROGRESS_Feature_<feature>/PLAN.md`.

Implementation must be complete (`/implement` phase done). If PLAN.md is
missing or no source changes on the branch, tell user to complete `/implement`
first and exit.

## Step 0: Detect Context

**Flow mode:** Verify worktree matches the requested feature. If on main,
refuse and point to `/start`.

**Standalone mode:** Skip worktree validation.

## Step 0.5: Plan Detection & Orientation

**MANDATORY — run this glob BEFORE any other file reads:**
```
Glob pattern: docs/INPROGRESS_Plan_*/execution-plan.yaml
```
If found: Read the YAML, then follow the plan-detection skill
§ Project Orientation for task matching and context loading.
If not found: proceed standalone (no warnings, no behavior change).

## Step 1: Detect Project Type

Determine which languages are present and which files changed on this branch:

```bash
git diff main --name-only
```

Classify:
- **Python**: any `.py` files changed (check for `pyproject.toml`, `ruff.toml`,
  or `setup.cfg` to confirm tooling)
- **TypeScript**: any `.ts`/`.tsx` files changed (check for `tsconfig.json`,
  `eslint.config.*`, or `.eslintrc.*`)
- **Both**: both types changed

Also check if `ui/` or `ui_react/` was modified (determines whether to run
frontend linters).

## Step 2: Fast Linters with Auto-Fix

Run linters appropriate to the detected project type. Auto-fix what can be
auto-fixed.

### Python

Detect the runner: if `pyproject.toml` exists and the project uses `uv`, prefix
commands with `uv run`. Otherwise use bare commands.

```bash
# Detect runner
if [[ -f pyproject.toml ]] && command -v uv &>/dev/null; then
  RUN="uv run"
else
  RUN=""
fi

# Lint + auto-fix
$RUN ruff check --fix .

# Format
$RUN ruff format .
```

If `ruff` is not available (neither globally nor via uv), skip with a warning.

### TypeScript (only if TS files changed)

```bash
cd ui/  # or ui_react/frontend/ — use the project's frontend directory
npx eslint --fix .
```

If `eslint` is not configured, skip with a warning.

### Commit Auto-Fixes

If any files were modified by auto-fix:

```bash
git add -u
git commit -m "fix(<feature>): static analysis auto-fixes"
```

If no files changed, skip the commit.

## Step 3: Type Checking

Run type checkers and collect findings.

### Python

Use the same runner detected in Step 2:

```bash
$RUN mypy src/ --no-error-summary 2>&1 || true
```

Use the project's mypy config if present (`mypy.ini`, `pyproject.toml [tool.mypy]`).

### TypeScript

```bash
cd ui/  # or the project's frontend directory
npx tsc --noEmit 2>&1 || true
```

Collect all findings for the fix loop (Step 5).

## Step 4: SonarQube Scan

### 4.1: Pre-flight

Verify SonarQube is reachable:

```bash
curl -sf http://localhost:9100/api/system/status | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','UNKNOWN'))"
```

If not `UP`:
- Print: "SonarQube is not running. Start it: `start-system sonarqube`"
- **Skip SonarQube steps.** Continue with linter/type-check findings only.

### 4.2: Ensure Project Exists

**Authentication:** `$SONAR_TOKEN` is pre-configured as an env var. Use it
for all API calls via `-H "Authorization: Bearer $SONAR_TOKEN"`. Do NOT
waste turns searching for tokens or trying other auth methods.

Check if the project key exists in SonarQube. The project key convention is
the directory name (e.g., `OIH`, `eulex-single-law-retrieval-artikel99`,
`claude-agent-dashboard`). Read it from `sonar-project.properties` if present.

```bash
curl -sf -H "Authorization: Bearer $SONAR_TOKEN" \
  "http://localhost:9100/api/projects/search?q=<project-key>" | python3 -c "
import sys, json
data = json.load(sys.stdin)
components = data.get('components', [])
print('EXISTS' if any(c['key'] == '<project-key>' for c in components) else 'NOT_FOUND')
"
```

If `NOT_FOUND`, create it:
```bash
curl -sf -X POST -H "Authorization: Bearer $SONAR_TOKEN" \
  "http://localhost:9100/api/projects/create" \
  -d "name=<project-key>&project=<project-key>"
```

### 4.3: Run Scanner

Verify `sonar-scanner` is available:
```bash
command -v sonar-scanner || echo "NOT_FOUND"
```

If not found:
- Print: "sonar-scanner not installed. Install: `brew install sonar-scanner`"
- **Skip SonarQube steps.** Continue with linter/type-check findings only.

### 4.3.1: Run the scan

If `sonar-project.properties` exists, `sonar-scanner` reads it automatically
— do NOT pass `-D` flags that it already defines. The token is read from
`$SONAR_TOKEN` natively by sonar-scanner.

```bash
sonar-scanner
```

That's it. No extra flags needed when `sonar-project.properties` is present.

If `sonar-project.properties` does NOT exist, pass explicit flags:
```bash
sonar-scanner \
  -Dsonar.projectKey=<project-key> \
  -Dsonar.sources=src \
  -Dsonar.host.url=http://localhost:9100 \
  -Dsonar.token=$SONAR_TOKEN \
  -Dsonar.exclusions="**/node_modules/**,**/.venv/**,**/migrations/**,**/__pycache__/**,**/dist/**,**/build/**"
```

Wait for the scan to complete (check task status):
```bash
# Get the task ID from scanner output, then poll
curl -sf -H "Authorization: Bearer $SONAR_TOKEN" "http://localhost:9100/api/ce/activity?component=<project-key>&ps=1" | \
  python3 -c "import sys,json; t=json.load(sys.stdin)['tasks'][0]; print(t['status'])"
```

Poll every 5s until status is `SUCCESS` or `FAILED` (max 2 minutes).

### 4.4: Fetch Results

Fetch quality gate status:
```bash
curl -sf -H "Authorization: Bearer $SONAR_TOKEN" "http://localhost:9100/api/qualitygates/project_status?projectKey=<project-key>" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
status = data['projectStatus']['status']
print(f'Quality Gate: {status}')
for cond in data['projectStatus'].get('conditions', []):
    print(f'  {cond[\"metricKey\"]}: {cond[\"actualValue\"]} (threshold: {cond[\"errorThreshold\"]})')
"
```

Fetch issues (bugs, vulnerabilities, code smells):
```bash
curl -sf -H "Authorization: Bearer $SONAR_TOKEN" "http://localhost:9100/api/issues/search?componentKeys=<project-key>&resolved=false&ps=100" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for issue in data.get('issues', []):
    sev = issue.get('severity', '?')
    comp = issue.get('component', '?').split(':')[-1]
    line = issue.get('line', '?')
    msg = issue.get('message', '?')
    itype = issue.get('type', '?')
    print(f'{sev} | {itype} | {comp}:{line} | {msg}')
"
```

## Step 4.5: Tool Coverage Gate

Count how many tool categories executed (not skipped):
- **Linters:** ruff OR eslint (at least one ran)
- **Type checkers:** mypy OR tsc (at least one ran)
- **Code analysis:** SonarQube (optional, warn-only)

If zero linters AND zero type checkers ran:
- **FAIL the phase.** Print: "Static analysis environment incomplete —
  no linters or type checkers available. Fix the environment before
  proceeding. Check the project's `pipeline.toolchain` manifest in CLAUDE.md."
- Do NOT continue to the fix loop or report.

If at least one category ran but others were skipped, log a warning but
proceed. Include tool coverage status in the report header.

## Step 5: Fix Loop

All findings from Steps 3–4 must be resolved before proceeding. This phase
owns its findings end-to-end — detect, fix, verify. QA should receive a
clean codebase.

### 5.1: Compile All Findings

Merge findings from all sources into a single list:

| # | Source | Severity | File | Line | Message |
|---|--------|----------|------|------|---------|

**Severity mapping:**
- SonarQube BLOCKER/CRITICAL → CRITICAL
- SonarQube MAJOR → WARNING
- SonarQube MINOR/INFO → SUGGESTION
- mypy errors → WARNING
- tsc errors → WARNING

### 5.2: Fix CRITICAL and WARNING Findings

Fix all CRITICAL and WARNING findings. For each finding:
1. Read the file and understand the issue in context
2. Apply the fix (minimal, surgical — don't refactor surrounding code)
3. Run the relevant checker again on that file to verify

**Scope:** Only fix findings in files changed on this branch
(`git diff main --name-only`). Pre-existing issues in untouched files are
logged but not fixed.

### 5.3: Re-Verify

After fixing, re-run all checks:

```bash
# Type checkers
$RUN mypy src/ --no-error-summary 2>&1 || true
npx tsc --noEmit 2>&1 || true  # if TS project

# Generate coverage data before re-scanning SonarQube
# Python projects
$RUN pytest --cov=src --cov-report=xml:coverage.xml -q 2>&1 || true

# Node projects (if applicable)
cd ui_react/frontend/ && npx vitest run --coverage 2>/dev/null || true && cd -

# Re-scan SonarQube (if it was available)
sonar-scanner  # uses sonar-project.properties
# Wait for scan, re-fetch results (same as Step 4.3–4.4)
```

This ensures `sonar.python.coverage.reportPaths=coverage.xml` (or equivalent)
has data to report. Without this, SonarQube coverage gate auto-fails at 0%.

Also run the project's test suite to ensure fixes didn't break anything:
```bash
# Use the project's test command from CLAUDE.md
```

### Test Failure Classification

After running the test suite, classify any failures:

1. **Code regression** — test was passing on main, now fails on this branch.
   Fix immediately (existing rule).
2. **Environment gap** — test fails on both main and this branch due to
   missing dependency, sandbox restriction, or network block (e.g., socksio
   import error from proxy, tiktoken download blocked). **Do NOT spend turns
   debugging or retrying network failures.** If a test fails because a package
   tries to download data from a blocked host, classify it immediately and
   move on. One turn max per environment gap. Log to
   `docs/ENV_ISSUES.md` (create if missing):

   ```markdown
   # Environment Issues

   Issues caused by the execution environment, not code. Fix these to
   unblock the full test suite.

   | Date | Test File | Failure | Root Cause | Fix |
   |------|-----------|---------|------------|-----|
   ```

3. **Pre-existing code issue** — test fails on main due to a code bug in
   an untouched file. Log as out-of-scope (existing rule).

To verify classification, run the failing test on main:
```bash
git stash && $RUN pytest <failing_test> -x 2>&1; git stash pop
```
If it fails on main too → environment gap or pre-existing. If it passes on
main → code regression (fix immediately).

### 5.4: Loop Guard

**Maximum 3 fix passes.** After each pass, print:
```
Static Analysis, Pass <N>/3: <CLEAN | NEEDS FIX>
  Fixed: <count>  |  Remaining: <count>
  Tests: <pass/fail>
```

If findings remain after 3 passes, proceed to report with remaining issues
listed. Present to user at checkpoint — don't block the pipeline indefinitely.

### 5.5: Commit Fixes — Separate Commits

Commits must be separate for clean git history (auto-fixes are safe to
revert independently from manual fixes).

1. **Auto-fix commit** (from Step 2, if not already committed):
   ```bash
   git diff --cached --stat  # verify staged changes exist
   git commit -m "fix(<feature>): static analysis auto-fixes"
   ```

2. **Manual fix commit** (from Step 5 fix loop):
   ```bash
   git add -u
   git diff --cached --stat  # verify staged changes exist
   git commit -m "fix(<feature>): resolve static analysis findings"
   ```

3. **Report commit** happens in Step 6/7 (existing).

**Guard:** Before each commit, check `git diff --cached --stat`. If empty,
skip that commit. Never combine auto-fixes and manual fixes into one commit.

## Step 6: Write Report

Write `docs/INPROGRESS_Feature_<feature>/STATIC_ANALYSIS.md`:

```markdown
<!-- phase: static-analysis | date: YYYY-MM-DD | branch: <branch> -->

# Static Analysis Report: <feature>

## Summary

| Check | Status | Initial Findings | Fixed | Remaining |
|-------|--------|-----------------|-------|-----------|
| Ruff (lint + format) | PASS/SKIP | <count> | <count> auto-fixed | 0 |
| ESLint | PASS/SKIP | <count> | <count> auto-fixed | 0 |
| mypy | PASS/SKIP | <count> | <count> | <count> |
| TypeScript (tsc) | PASS/SKIP | <count> | <count> | <count> |
| SonarQube | PASSED/FAILED/SKIPPED | <count> | <count> | <count> |

## Auto-Fixes Applied (Step 2)

<list of files modified by ruff/eslint auto-fix, or "None">

Commit: `fix(<feature>): static analysis auto-fixes`

## Fix Loop (Step 5)

### Findings Resolved
| # | Source | File | Line | Issue | Fix Applied |
|---|--------|------|------|-------|-------------|

### Findings Remaining (if any)
| # | Source | Severity | File | Line | Issue | Reason |
|---|--------|----------|------|------|-------|--------|

(Reason: out-of-scope file, 3-pass limit reached, etc.)

Commit: `fix(<feature>): resolve static analysis findings`

## SonarQube Results

### Quality Gate: <PASSED/FAILED/SKIPPED>

| Metric | Value | Threshold | Status |
|--------|-------|-----------|--------|

### Issues (post-fix)
| # | Severity | Type | File | Line | Message |
|---|----------|------|------|------|---------|

(If SonarQube was skipped, note why.)

## Test Results

<test suite output summary — pass/fail count>

## Verdict

<PASSED — all findings resolved, tests pass>
or <PASSED WITH NOTES — N low-severity items remaining in untouched files>
or <FAILED — N findings could not be resolved after 3 passes>
```

## Step 7: Flow Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Static analysis complete: <PASSED or FAILED>

<Summary — auto-fixes applied, type checker findings, SonarQube gate status>

Files written: docs/INPROGRESS_Feature_<feature>/STATIC_ANALYSIS.md
Branch: <branch>

On [yes]:
  1. git add docs/INPROGRESS_Feature_<feature>/STATIC_ANALYSIS.md
     git commit -m "docs(<feature>): static analysis report"
  2. STOP — open a new chat and run: /manualtest flow <feature>

On [amend]:
  → Re-run specific checks or fix additional findings.

On [stop]:
  → Pause flow. Resume later in a new chat: /static-analysis flow <feature>

Continue? [yes / amend / stop]
```

**Standalone mode:** Same format but omit phase commit and say "run:" instead
of "open a new chat and run:".

**Autopilot mode:** Auto-approve if verdict is PASSED or PASSED WITH NOTES.
If verdict is FAILED (unresolved findings after 3 passes), do NOT auto-approve
— present to user.

## Rules

- **FIX EVERYTHING.** This phase owns its findings. Detect, fix, verify. Don't
  pass unfixed findings to QA — QA validates behavior, not lint.
- **THREE COMMITS MAX.** (1) Auto-fixes from ruff/eslint `--fix` (Step 2),
  (2) Manual fixes from the fix loop (Step 5), (3) Report (Step 6). Keep them
  separate for clean git history.
- **SCOPE TO BRANCH.** Only fix findings in files changed on this branch.
  Pre-existing issues in untouched files are logged as out-of-scope.
- **RUN TESTS.** After every fix pass, run the project's test suite. Fixes
  that break tests are reverted.
- **3-PASS HARD CAP.** Maximum 3 fix passes. If findings persist, report them
  and let the human decide — don't loop forever.
- **SKIP INDIVIDUAL TOOLS GRACEFULLY** but enforce minimum coverage. If a specific
  tool is missing (ruff, eslint, sonar-scanner), skip that tool with a warning.
  However, Step 4.5 requires at least one linter AND one type checker to run —
  if the environment can't provide that minimum, the phase fails.
- **EVIDENCE IN THIS MESSAGE.** Show actual output from each tool. Banned:
  "should pass", "probably clean", "seems fine".
- **NO DEFERRING.** Never mark findings as "will fix in QA phase". Fix them
  here or explain why they couldn't be fixed.
