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
- tool-dependency-policy rule — never fly-install missing packages; declare in manifest instead

## Live Observability

Newer Claude Code defaults are terse. To preserve audit trail in the
autopilot stream, **print a one-line rationale before each tool-call
sequence of ≥3 calls toward the same subgoal**. Example:

> Verifying test_api_plan failure is self-inflicted (re-running on main).

Then run the tools. Do NOT spiral into multi-paragraph explanations —
those consume turns without adding information beyond what tool
descriptions and the final report carry. One line, then act. The
20-tool-call cap on fix attempts (Step 4.4 Loop Guard) still applies;
rationales count as zero tool calls.

## Prerequisites

Read ALL feature docs: `docs/INPROGRESS_Feature_<feature>/REQUIREMENTS.md`,
`docs/INPROGRESS_Feature_<feature>/PLAN.md`.

If `docs/INPROGRESS_Feature_<feature>/QA_REPORT.md` exists (light pipeline)
OR `docs/INPROGRESS_Feature_<feature>/TEAM_QA.md` exists (full pipeline),
read it as input — qa fix loops may have introduced changes since
/implement, and this phase is the FINAL quality gate validating that
combined state.

As of 2026-04-29 this phase runs AFTER /qa or /team-qa (was previously
between /implement and /qa). Source-of-truth: SonarQube + coverage
verdict in this phase reflects the FINAL code state that will be
committed — qa fixes are no longer bypassed.

Implementation must be complete (`/implement` phase done). QA must also
be complete (`/qa` or `/team-qa`). If REQUIREMENTS.md is missing or no
source changes on the branch, tell user to complete the prior phases
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
git diff main...HEAD --name-only
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

Check if `pytest-cov` is available (look for it in `pyproject.toml` dependencies).

**Coverage scope detection (mandatory — `--cov=src` is NOT a safe default):**
Many projects do NOT use a `src/` layout. Hardcoding `--cov=src` produces an
empty `coverage.xml` (pytest-cov logs `No data to report` and exits 0 because
of `|| true`), then SonarQube reports every Python line as 0% covered — the
"TDD work invisible on dashboard" failure mode (diagnosed 2026-05-22, dotfiles
monorepo, real coverage ~70% reported as 42%). Detect scope per project:

```bash
# Prefer pyproject.toml [tool.coverage.run] source — the project's declared
# scope. pytest-cov reads it when --cov is invoked without an argument.
if [[ -f pyproject.toml ]] && grep -q '^\[tool\.coverage\.run\]' pyproject.toml; then
  COV_ARGS="--cov"
elif [[ -d src ]]; then
  COV_ARGS="--cov=src"
else
  echo "WARNING: no [tool.coverage.run] in pyproject.toml AND no src/ directory."
  echo "Coverage.xml will be empty. Fix: add to pyproject.toml:" >&2
  echo "  [tool.coverage.run]" >&2
  echo "  source = [\"<your-package-or-dir>\", ...]" >&2
  COV_ARGS=""  # pytest will run without coverage; xml will be empty
fi

$RUN pytest ${COV_ARGS} --cov-report=xml:coverage.xml -q 2>&1 || true
```

If `pytest-cov` is not installed, skip with a warning. If the scope warning
above fires, surface it in `STATIC_ANALYSIS.md` as a CONFIG finding (the
phase can still complete; the dashboard will just be inaccurate until fixed).

### 2.2: TypeScript Coverage

If frontend directory exists and vitest is configured:

```bash
cd <frontend-dir> && npx vitest run --coverage 2>/dev/null || true
```

### 2.3: mypy Baseline Regression

If `BASELINE_MYPY.md` exists:

```bash
CURRENT=$(get-findings.sh mypy $RUN mypy src/ | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
BASELINE=$(grep -oP 'error_count: \K\d+' BASELINE_MYPY.md 2>/dev/null || echo 999999)
```

If `CURRENT > BASELINE`: report as WARNING — mypy error count has regressed.
If `CURRENT <= BASELINE`: log as OK.
If `BASELINE_MYPY.md` does not exist: skip silently.

### 2.4: shellcheck on changed `.sh` files (final safety net)

`/implement` Step 5.2 ran shellcheck on changed `.sh` files at the time of the
implementation commit. Since then, `/qa` (and `/team-qa`) may have edited
`.sh` files during their fix-loop without re-running shellcheck — the
`.tests-green-sha` marker covers tests + lint + type-check but the QA
Fixer is not strictly obligated to re-run shellcheck on bash files it
touched. This final pass closes that gap before merge.

Scope: only `.sh` files **changed on this branch** (`git diff main...HEAD`).
Pre-existing issues in untouched files are still the grinder's job
(`grinder.sh discover` + mechanical / static-analysis passes) — not this
phase. This matches the scope-to-branch rule that `/implement` follows.

```bash
CHANGED_SH=$(git diff --name-only main...HEAD | grep -E '\.sh$' || true)
if [[ -n "$CHANGED_SH" ]]; then
  echo "$CHANGED_SH" | xargs get-findings.sh shellcheck shellcheck -f json -S warning
fi
```

If shellcheck is not installed: skip with a loud WARNING (bash is the
orchestrator layer; shipping bash without shellcheck IS a regression
risk — same rule as `/implement` Step 5.4). Install via
`brew install shellcheck`.

If no `.sh` files changed on this branch: skip silently (no work to do).

**Findings route to Step 4 fix loop** like every other finding in this
phase. Severity follows static-analysis-conventions.md mapping:
- shellcheck error → CRITICAL
- shellcheck warning → WARNING (the `-S warning` flag filters out info/style)

Cost note: shellcheck is ~1-2s on changed files only. Zero LLM tokens
unless findings need fixing — at which point the fix-loop's per-fix
scoped re-run (Step 4.3 (a)) re-validates only the affected `.sh` files.

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

**Resolve the project key — `sonar-project.properties` is the source of
truth.** The directory basename is a fallback only used when no
properties file exists. NEVER derive the key from the worktree directory
name when a properties file is present — worktrees are named
`<repo>-<feature>` and would point at a non-existent project, prompting
sonar-scanner to spawn a new one on every feature branch.

```bash
PROJECT_KEY=$(awk -F= '/^sonar\.projectKey=/{print $2}' sonar-project.properties 2>/dev/null)
PROJECT_KEY="${PROJECT_KEY:-$(basename "$PWD")}"
echo "Project key: $PROJECT_KEY"
```

Verify the project exists by HTTP status — `curl -sf` swallows the body
on 4xx so a status-code probe is the only reliable signal:

```bash
HTTP=$(curl -s -o /tmp/sq.json -w "%{http_code}" \
  -H "Authorization: Bearer $SONAR_TOKEN" \
  "http://localhost:9100/api/qualitygates/project_status?projectKey=$PROJECT_KEY")
case "$HTTP" in
  200) echo "EXISTS" ;;
  404) echo "NOT_FOUND — first scan will create it" ;;
  *)   echo "UNKNOWN (HTTP $HTTP) — proceed; sonar-scanner will surface errors" ;;
esac
```

Do NOT infer existence from the `analysisDate` polling baseline in 3.3 —
that field is `null` for projects that exist but have never been
analyzed, and `curl -sf` returns empty stdin on transient API hiccups.
Both produce the literal string `none`, which is NOT a "doesn't exist"
signal. The HTTP-status probe above is the only authoritative check.

### 3.3: Run Scanner

Verify `sonar-scanner` is available:
```bash
command -v sonar-scanner || echo "NOT_FOUND"
```

If not found:
- Print: "sonar-scanner not installed. Install: `brew install sonar-scanner`"
- **Skip SonarQube steps.** Continue with coverage findings only.

**Scope the scan to changed files on feature branches.** Scanning every
file under `sonar.sources` takes 30–60s on a 29k-LOC monorepo, and the
fix-scope rule already restricts work to files changed on this branch.
Match the scan scope to the fix scope via `-Dsonar.inclusions`. On
`main` (or any branch tracking the canonical project state) run a full
scan so coverage and cross-file analysis stay accurate.

```bash
if [[ "$(git symbolic-ref --short HEAD 2>/dev/null)" == "main" ]]; then
  INCLUSIONS=""
else
  INCLUSIONS=$(git diff --name-only main...HEAD \
    | grep -E '\.(py|ts|tsx|js|jsx)$' \
    | tr '\n' ',' | sed 's/,$//')
fi
```

Caveats to call out in the report when inclusions are non-empty:
- Sonar will not see callers/callees in excluded files, so taint and
  cross-file analyses may miss findings rooted in unchanged code.
- The project-wide coverage % in the SonarQube UI will reflect only the
  included files until the next full scan from `main` overwrites it.
- First scan on a fresh project still takes normal time (Sonar needs a
  baseline before delta-only paths are available).

**Guard A — refuse to scan without a repo-root `sonar-project.properties`.**
Without the file, `sonar-scanner` derives `sonar.projectKey` from the
working-directory basename, which on a worktree is `<repo>-<feature>`
and spawns a ghost project in SonarQube on every feature scan. This is
how `dotfiles-grinder-orchestrator`, `dotfiles-scanner-normaliser`, and
~10 other orphans were created before properties-file tracking landed
(commit dcffd88, 2026-04-24). If the file is absent, ABORT and report
the gap — do NOT auto-fallback to `-Dsonar.projectKey`.

```bash
if [[ ! -f sonar-project.properties ]]; then
  echo "ABORT: no sonar-project.properties at repo root ($PWD)." >&2
  echo "Refusing to invoke sonar-scanner — it would spawn a ghost project" >&2
  echo "keyed on '$(basename "$PWD")'. Add a tracked sonar-project.properties" >&2
  echo "with sonar.projectKey=<canonical-key> first." >&2
  exit 1
fi
```

`sonar-scanner` reads the properties file automatically — do NOT pass
`-D` flags that it already defines. The token is read from `$SONAR_TOKEN`
natively by sonar-scanner. The optional inclusions arg is the only flag
to pass:

```bash
sonar-scanner ${INCLUSIONS:+-Dsonar.inclusions="$INCLUSIONS"}
```

Wait for the scan to complete. The `/api/ce/activity` endpoint requires
global Browse permission and returns 403 for project-scoped tokens
(env-gap-sonar-token-403-on-ce-activity, 2026-05-09). Instead, snapshot
the project's last analysisDate before the scan, then poll
`/api/qualitygates/project_status` until analysisDate advances:

```bash
PRE_DATE=$(curl -sf -H "Authorization: Bearer $SONAR_TOKEN" \
  "http://localhost:9100/api/qualitygates/project_status?projectKey=$PROJECT_KEY" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['projectStatus'].get('analysisDate','none'))")

# Poll every 5s, max 2 minutes (deadline = 24 iterations)
for i in $(seq 1 24); do
  POST_DATE=$(curl -sf -H "Authorization: Bearer $SONAR_TOKEN" \
    "http://localhost:9100/api/qualitygates/project_status?projectKey=$PROJECT_KEY" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['projectStatus'].get('analysisDate','none'))")
  [[ "$POST_DATE" != "$PRE_DATE" && "$POST_DATE" != "none" ]] && break
  sleep 5
done
```

If `POST_DATE` equals `PRE_DATE` after the 2-minute deadline, treat the
scan as TIMED_OUT (not FAILED) and proceed to 3.4 — the response will
still surface the prior gate state. The qualitygates endpoint works with
project-scoped tokens (no Browse permission needed).

### 3.4: Fetch Results

Fetch quality gate status:
```bash
curl -sf -H "Authorization: Bearer $SONAR_TOKEN" "http://localhost:9100/api/qualitygates/project_status?projectKey=$PROJECT_KEY" | \
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
  "http://localhost:9100/api/qualitygates/project_status?projectKey=$PROJECT_KEY" | \
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
(`git diff main...HEAD --name-only`). Pre-existing issues in untouched files are
logged but not fixed.

**No Task() sub-agent delegation for fixes.** Apply fixes INLINE in
this session using Edit/Write tools directly. Do NOT spawn a Task()
sub-agent to delegate fix work — sub-agents run in their own session
with a default 76-turn budget that bypasses the 20-tool-call cap in
Step 4.4 Loop Guard, producing death spirals (observed in
plan-schema-2-0-adoption autopilot run 2026-04-27, where a sub-agent
burned 76 turns / $6.40 refactoring Pipeline.tsx after the parent
delegated the fix).

If a single finding requires more than ~10 edits to resolve (true
multi-file refactor), DEFER it to human review — log it under
"Findings Remaining" in STATIC_ANALYSIS.md with reason
`requires architectural refactor — operator review needed`.
Static-analysis is not the right phase for large refactors;
multi-file architecture changes belong in their own feature.

If a sub-agent IS spawned for legitimate parallel work (e.g.,
multi-file scan analysis, never multi-file fix), the spawning prompt
MUST include verbatim: "Hard cap: 15 tool calls. If you cannot
complete in 15 turns, report partial state and exit — do not spiral."

### 4.3: Re-Verify

Re-verification is **scoped** — re-running every tool on the whole
project after every fix duplicates work `/implement` Step 5 already
gated. Apply this hierarchy instead:

**(a) After each individual fix** — re-run **only the tool that
flagged the finding being fixed**, scoped to **the changed file(s)**.
Examples:
```bash
# SonarQube finding on src/foo.py — no per-finding re-scan (Sonar is
# slow); rely on the end-of-loop full re-scan.
# mypy finding on src/foo.py:
$RUN mypy src/foo.py --no-error-summary
# ruff/eslint/tsc finding on changed file: same pattern, one file.
# shellcheck finding on scripts/bar.sh:
shellcheck -f json -S warning scripts/bar.sh
```
Do **not** invoke the full-project lint/type/test suite per-fix —
that's the loop-end gate (b) below, not the per-fix verifier.

**(b) Once at the end of each fix pass** — after all findings in this
pass are addressed (or BLOCKED per Step 4.4 cap), run the cumulative
gates:
```bash
# Regenerate coverage (feeds SonarQube + reveals coverage regression).
# Use the same scope-detection logic from Step 2.1 — do not hardcode `--cov=src`.
if [[ -f pyproject.toml ]] && grep -q '^\[tool\.coverage\.run\]' pyproject.toml; then
  COV_ARGS="--cov"
elif [[ -d src ]]; then
  COV_ARGS="--cov=src"
else
  COV_ARGS=""
fi
$RUN pytest ${COV_ARGS} --cov-report=xml:coverage.xml -q 2>&1 || true

# Re-scan SonarQube (if it was available)
sonar-scanner  # uses sonar-project.properties
# Wait for scan, re-fetch results (same as Step 3.3–3.4)

# Run the project's test suite to catch cross-file regressions that
# the per-fix tool re-runs in (a) cannot detect.
$RUN ./scripts/run_tests.sh  # or the project's CLAUDE.md test command
```

Test failures here trigger the **Test Failure Classification** block
below.

### Test Failure Classification

After running the test suite, classify any failures:

1. **Self-inflicted regression** — test was passing on main but a fix YOU applied
   in this pass broke it (e.g., you renamed a string, extracted a constant, or
   refactored a component, and the test asserted on the old shape). **REVERT
   your own fix first; do not spiral debugging downstream symptoms.** Then
   reconsider: either find a different fix that doesn't break the test, or
   update the test to assert the new shape — but the test update must be a
   single deliberate edit, not iterative tweaking. If you cannot tell whether
   a failure was caused by your fix or pre-existed, run the failing test on
   main (see classification command below); if it passes there, it's
   self-inflicted and you must revert.
2. **Code regression (pre-existing on this branch)** — test was passing on main
   AND failed before you started this pass. Fix immediately (existing rule).
3. **Environment gap** — test fails on both main and this branch due to
   missing dependency, sandbox restriction, or network block (e.g., socksio
   import error from proxy, tiktoken download blocked). **Do NOT spend turns
   debugging or retrying network failures.** One turn max per environment gap.

   Log in TWO places (cross-feature visibility):

   (a) **Per-feature view** — add a `## Environment gaps (verified pre-existing on main)`
   section to `STATIC_ANALYSIS.md`. One block per gap with: symptom, root
   cause, verification command showing same failure on main, workaround if
   any. Do NOT create a separate ENV_ISSUES.md (artefact fragmentation).

   (b) **Cross-feature view** — IF the project has an `execution-plan.yaml`
   with `schema_version: 2.0.0` (graph mode), append an entry to
   `project.deferred[]` with `kind: environment_gap`. Use
   `claude/tools/lib/plan_yaml_deferred.py::make_environment_gap_entry`
   factory. Required fields: `id`, `date`, `detected_at_phase` (typically
   `static-analysis`), `symptom`, `root_cause` (≥40 chars),
   `verification_command`. Optional: `detected_at_task_id`,
   `affected_test_suites[]`, `workaround`, `status` (`open|mitigated|fixed`).
   This makes the gap visible to /retro and /qa across features so recurring
   gaps surface as patterns rather than per-feature surprises. Skip (b) if
   the project is on legacy 1.x schema or has no execution-plan.yaml.
4. **Pre-existing code issue** — test fails on main due to a code bug in
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
  Self-inflicted reverts: <count>   ← MUST be emitted; 0 is valid
```

**Within a single pass, hard cap on debugging tool calls: 20.** If a single fix
attempt causes test failures and you cannot resolve them within 20 additional
tool calls (Bash, Read, Edit combined), REVERT your fix in this pass and log
the original finding as deferred for human review. This guards against the
death-spiral pattern observed in dashboard autopilot run 2026-04-26 where one
fix-pass burned 100+ tool calls debugging self-inflicted regressions before
hitting max_turns.

**The 20-tool-call cap counts INLINE work in this session only.** It does NOT
constrain Task() sub-agents (their default 76-turn budget bypasses our cap and
caused a second death-spiral observed 2026-04-27). Per Step 4.2, fixes MUST be
applied inline; sub-agent delegation for fixes is forbidden. If you legitimately
need a sub-agent for parallel analysis (never for fixes), the sub-agent prompt
MUST include the verbatim hard-cap clause from Step 4.2.

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

## Environment gaps (verified pre-existing on main)

<one block per gap; omit section entirely if no gaps detected>

### <gap-id, e.g., git-init-sandbox-block>

**Symptom:**
```
<exact error output>
```

**Affected suites:**
- <suite-name-1>
- <suite-name-2>

**Root cause:** <one paragraph>

**Verification:** Same failure on main (`git stash && <test-cmd>; git stash pop` shows identical traceback).

**Workaround:** <if any, else "None — defer to environment fix">

## Self-inflicted reverts

<list any fixes you applied then reverted because they broke tests; "None" is valid and expected>

| # | Original finding | Fix attempted | Reason for revert |
|---|------------------|---------------|-------------------|

## Verdict

<PASSED — all findings resolved, tests pass>
or <PASSED WITH NOTES — N low-severity items remaining in untouched files>
or <PASSED WITH ENV GAPS — N environment gaps documented, all fixable findings resolved>
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
  2. After the commit lands, update the tests-green-sha marker so
     /commit-preflight can skip the redundant full test rerun:
     ```bash
     git rev-parse HEAD > docs/INPROGRESS_Feature_<feature>/.tests-green-sha
     ```
     (Marker is gitignored. /static-analysis is the last green-gate
     phase before /commit, so writing it here closes the loop the
     legacy `.qa-passed-sha` marker missed when fix-loop commits
     moved HEAD past /qa's marker.)
  3. STOP — open a new chat and run: /commit flow <feature>

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
- **NO FLY-INSTALLS.** Per the tool-dependency-policy rule
  (claude/rules/tool-dependency-policy.md), never run pip/uv/npm install on
  the fly. Sandbox blocks the package CDNs. If a tool reports a missing
  package, check `.venv/lib/python*/site-packages/` first. If genuinely
  missing, add it to `pyproject.toml` and surface as a finding. One tunnel
  error is enough — never retry.
- **LINTERS AND TYPE CHECKERS RAN IN /IMPLEMENT** — with two carve-outs.
  `/implement` Step 5 already gated ruff, eslint, mypy, tsc, and shellcheck
  on changed files. Re-running them on the whole project here duplicates
  that work. **Two exceptions are legitimate and must NOT be removed:**
  1. **mypy baseline regression** (Step 2.3) — only place where the
     repo-wide error count is compared against `BASELINE_MYPY.md`.
     `/implement` cannot perform this signal. Keep.
  2. **Scoped post-fix re-verification** (Step 4.3) — when this phase
     edits a file to resolve a SonarQube/coverage finding, re-run **only
     the tool that flagged the finding**, scoped to **the file just
     edited**. This is a per-fix sanity check, not a full re-validation.
  Outside these two carve-outs, do not re-run lint/type checkers on the
  whole project — the cost is duplicated, the signal is not.
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
