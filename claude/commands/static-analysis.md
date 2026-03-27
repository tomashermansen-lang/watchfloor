---
description: Static Analysis — run SonarQube, coverage enforcement, and baseline regression checks
argument-hint: <feature-name> OR flow <feature-name>
---

# Static Analysis: $ARGUMENTS

Run SonarQube code analysis, coverage enforcement, and baseline regression
checks. Linters and type checkers already ran in `/implement` (Step 5) —
this phase focuses on deeper static analysis that requires external tooling.

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

Detect the Python runner per static-analysis-conventions.md § Tool Runner Detection.

## Step 2: Coverage Enforcement

Generate coverage data for SonarQube and baseline comparison.

### 2.1: Python Coverage

Check if `pytest-cov` is available (look for it in `pyproject.toml` dependencies):

```bash
$RUN pytest --cov=src --cov-report=xml:coverage.xml -q 2>&1 || true
```

If `pytest-cov` is not installed, skip with a warning.

### 2.2: TypeScript Coverage

If frontend directory exists and vitest is configured:

```bash
cd <frontend-dir> && npx vitest run --coverage 2>/dev/null || true
```

### 2.3: mypy Baseline Regression

If `BASELINE_MYPY.md` exists:

```bash
CURRENT=$($RUN mypy src/ 2>&1 | grep -c "^.*: error:" || true)
BASELINE=$(grep -oP 'error_count: \K\d+' BASELINE_MYPY.md 2>/dev/null || echo 999999)
```

If `CURRENT > BASELINE`: report as WARNING — mypy error count has regressed.
If `CURRENT <= BASELINE`: log as OK.
If `BASELINE_MYPY.md` does not exist: skip silently.

## Step 3: SonarQube Scan

### 3.1: Pre-flight

Verify SonarQube is reachable:

```bash
curl -sf http://localhost:9100/api/system/status | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','UNKNOWN'))"
```

If not `UP`:
- Print: "SonarQube is not running. Start it: `start-system sonarqube`"
- **Skip SonarQube steps.** Continue with coverage findings only.

### 3.2: Ensure Project Exists

**Authentication:** `$SONAR_TOKEN` is pre-configured as an env var. Use it
for all API calls via `-H "Authorization: Bearer $SONAR_TOKEN"`. Do NOT
waste turns searching for tokens or trying other auth methods.

Check if the project key exists in SonarQube. The project key convention is
the directory name (e.g., `OIH`, `eulex-single-law-retrieval-artikel99`,
`claude-agent-dashboard`). Read it from `sonar-project.properties` if present.

Use the quality gate API to verify the project exists (works with analysis
tokens that lack Browse permission on `/api/projects/search`):

```bash
curl -sf -H "Authorization: Bearer $SONAR_TOKEN" \
  "http://localhost:9100/api/qualitygates/project_status?projectKey=<project-key>" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('EXISTS' if 'projectStatus' in data else 'NOT_FOUND')
"
```

If `NOT_FOUND` (HTTP 404), the project doesn't exist yet. Run `sonar-scanner`
first — it auto-creates the project on first scan.

### 3.3: Run Scanner

Verify `sonar-scanner` is available:
```bash
command -v sonar-scanner || echo "NOT_FOUND"
```

If not found:
- Print: "sonar-scanner not installed. Install: `brew install sonar-scanner`"
- **Skip SonarQube steps.** Continue with coverage findings only.

If `sonar-project.properties` exists, `sonar-scanner` reads it automatically
— do NOT pass `-D` flags that it already defines. The token is read from
`$SONAR_TOKEN` natively by sonar-scanner.

```bash
sonar-scanner
```

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
curl -sf -H "Authorization: Bearer $SONAR_TOKEN" "http://localhost:9100/api/ce/activity?component=<project-key>&ps=1" | \
  python3 -c "import sys,json; t=json.load(sys.stdin)['tasks'][0]; print(t['status'])"
```

Poll every 5s until status is `SUCCESS` or `FAILED` (max 2 minutes).

### 3.4: Fetch Results

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

### 3.5: New-Code Quality Gate

Check the new-code quality gate specifically:
```bash
curl -sf -H "Authorization: Bearer $SONAR_TOKEN" \
  "http://localhost:9100/api/qualitygates/project_status?projectKey=<project-key>" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
status = data['projectStatus']['status']
print(f'New-Code Quality Gate: {status}')
sys.exit(0 if status == 'OK' else 1)
"
```

If new-code gate is FAILED: report as WARNING minimum. This must be fixed
before the phase can pass.

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

## Step 4: Fix Loop

All findings from Steps 2–3 must be resolved before proceeding. This phase
owns SonarQube and coverage findings end-to-end.

### 4.1: Compile All Findings

Merge findings from all sources into a single list:

| # | Source | Severity | File | Line | Message |
|---|--------|----------|------|------|---------|

**Severity mapping:**
- SonarQube BLOCKER/CRITICAL → CRITICAL
- SonarQube MAJOR → WARNING
- SonarQube MINOR/INFO → SUGGESTION
- mypy baseline regression → WARNING
- Coverage regression → WARNING
- New-code quality gate FAILED → WARNING

### 4.2: Fix CRITICAL and WARNING Findings

Fix all CRITICAL and WARNING findings. For each finding:
1. Read the file and understand the issue in context
2. Apply the fix (minimal, surgical — don't refactor surrounding code)
3. Run the relevant checker again on that file to verify

**Scope:** Only fix findings in files changed on this branch
(`git diff main --name-only`). Pre-existing issues in untouched files are
logged but not fixed.

### 4.3: Re-Verify

After fixing, re-run coverage and re-scan SonarQube:

```bash
# Regenerate coverage
$RUN pytest --cov=src --cov-report=xml:coverage.xml -q 2>&1 || true

# Re-scan SonarQube (if it was available)
sonar-scanner  # uses sonar-project.properties
# Wait for scan, re-fetch results (same as Step 3.3–3.4)
```

Also run the project's test suite to ensure fixes didn't break anything.

### Test Failure Classification

After running the test suite, classify any failures:

1. **Code regression** — test was passing on main, now fails on this branch.
   Fix immediately (existing rule).
2. **Environment gap** — test fails on both main and this branch due to
   missing dependency, sandbox restriction, or network block (e.g., socksio
   import error from proxy, tiktoken download blocked). **Do NOT spend turns
   debugging or retrying network failures.** One turn max per environment gap.
   Log to `docs/ENV_ISSUES.md` (create if missing).
3. **Pre-existing code issue** — test fails on main due to a code bug in
   an untouched file. Log as out-of-scope (existing rule).

To verify classification, run the failing test on main:
```bash
git stash && $RUN pytest <failing_test> -x 2>&1; git stash pop
```

### 4.4: Loop Guard

**Maximum 3 fix passes.** After each pass, print:
```
Static Analysis, Pass <N>/3: <CLEAN | NEEDS FIX>
  Fixed: <count>  |  Remaining: <count>
  Tests: <pass/fail>
```

If findings remain after 3 passes, proceed to report with remaining issues
listed. Present to user at checkpoint — don't block the pipeline indefinitely.

### 4.5: Commit Fixes

If any source files were modified during the fix loop:

```bash
git add -u
git diff --cached --stat  # verify staged changes exist
git commit -m "fix(<feature>): resolve static analysis findings"
```

Skip the commit if no files changed.

## Step 5: Write Report

Write `docs/INPROGRESS_Feature_<feature>/STATIC_ANALYSIS.md`:

```markdown
<!-- phase: static-analysis | date: YYYY-MM-DD | branch: <branch> -->

# Static Analysis Report: <feature>

## Summary

| Check | Status | Initial Findings | Fixed | Remaining |
|-------|--------|-----------------|-------|-----------|
| Coverage (pytest-cov) | PASS/SKIP | — | — | — |
| Coverage (vitest) | PASS/SKIP | — | — | — |
| mypy baseline regression | PASS/SKIP/REGRESSION | <baseline> → <current> | — | — |
| SonarQube | PASSED/FAILED/SKIPPED | <count> | <count> | <count> |
| New-code quality gate | PASSED/FAILED/SKIPPED | — | — | — |

## Coverage Results

### Python
<coverage summary from coverage.xml, or "pytest-cov not available">

### TypeScript
<coverage summary, or "vitest coverage not configured">

## mypy Baseline

<Current: N errors | Baseline: M errors | Status: OK/REGRESSION>

## SonarQube Results

### Quality Gate: <PASSED/FAILED/SKIPPED>

| Metric | Value | Threshold | Status |
|--------|-------|-----------|--------|

### New-Code Quality Gate: <PASSED/FAILED/SKIPPED>

### Issues (post-fix)
| # | Severity | Type | File | Line | Message |
|---|----------|------|------|------|---------|

(If SonarQube was skipped, note why.)

## Fix Loop

### Findings Resolved
| # | Source | File | Line | Issue | Fix Applied |
|---|--------|------|------|-------|-------------|

### Findings Remaining (if any)
| # | Source | Severity | File | Line | Issue | Reason |
|---|--------|----------|------|------|-------|--------|

## Test Results

<test suite output summary — pass/fail count>

## Verdict

<PASSED — all findings resolved, tests pass>
or <PASSED WITH NOTES — N low-severity items remaining in untouched files>
or <FAILED — N findings could not be resolved after 3 passes>
```

## Step 6: Flow Checkpoint

Present using the Checkpoint Contract from the flow-mode skill:

```
Static analysis complete: <PASSED or FAILED>

<Summary — coverage status, SonarQube gate status, baseline regression>

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

- **FIX EVERYTHING.** This phase owns SonarQube and coverage findings. Detect,
  fix, verify. Don't pass unfixed findings to QA.
- **LINTERS AND TYPE CHECKERS RAN IN /IMPLEMENT.** Do not re-run ruff, eslint,
  mypy, or tsc here. If you suspect they missed something, note it in the report
  but do not duplicate the work.
- **SCOPE TO BRANCH.** Only fix findings in files changed on this branch.
  Pre-existing issues in untouched files are logged as out-of-scope.
- **RUN TESTS.** After every fix pass, run the project's test suite. Fixes
  that break tests are reverted.
- **3-PASS HARD CAP.** Maximum 3 fix passes. If findings persist, report them
  and let the human decide — don't loop forever.
- **SKIP GRACEFULLY.** If SonarQube is not running or scanner not installed,
  skip SonarQube with a warning. If coverage tooling is not installed, skip
  coverage with a warning. The phase still produces a report either way.
- **EVIDENCE IN THIS MESSAGE.** Show actual output from each tool. Banned:
  "should pass", "probably clean", "seems fine".
- **NO DEFERRING.** Never mark findings as "will fix in QA phase". Fix them
  here or explain why they couldn't be fixed.
