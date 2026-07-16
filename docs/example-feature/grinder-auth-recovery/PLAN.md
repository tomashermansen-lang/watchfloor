<!-- phase: plan | date: 2026-05-09 | branch: feature/grinder-auth-recovery -->

# Plan — grinder-auth-recovery

## Summary

Three coupled defences against the silent authentication-failure mode
observed in dotfiles grinder session `7ed5dd25` (2026-05-09):

1. **Preflight** — a `claude -p` auth probe at `cmd_run` / `cmd_resume`
   start that hard-stops with exit `2` before any batch spawns.
2. **Symmetric env-strip** — extend the run-time `claude -p` invocation
   in `run_phase` to strip the same eight proxy variables already
   stripped on the assessor wire (`claude-session-lib.sh:699`).
3. **Result-event classifier + retry-loop short-circuit** — detect
   the two authentication-failure shapes inside the result-event
   pipeline that `run_phase` already streams, emit one structured
   `auth_failed` NDJSON event, and return a sentinel exit code that
   `run_gated_phase` recognises as fatal-not-retryable.

A self-contained bash test (`tests/test_grinder_auth_recovery.sh`)
plus two NDJSON fixtures verify the classifier + retry-loop behaviour
without invoking real `claude`. The host plan's
`task.what`/`task.why`/`task.where`/`task.acceptance` fields stay
authoritative — this PLAN.md only covers the free-form architecture
sections per the schema 2.0 split.

## Research

### Code seams already identified

| Seam | File:line | Use |
|---|---|---|
| Assessor proxy strip (8-var) | `claude-session-lib.sh:699` | Literal copy target for R2 |
| Run-phase proxy strip (6-var) | `claude-session-lib.sh:1307` | Site of R2 extension |
| `process_stream` python consumer | `claude-session-lib.sh:1150` | Reference for malformed-JSON tolerance (R3.6); classifier reads the same per-phase NDJSON file |
| `phase_ndjson` per-phase capture | `claude-session-lib.sh:1292,1336` | Authoritative artifact the classifier reads; already created/cleaned by `run_phase` |
| `_classify_phase_exit` | `claude-session-lib.sh:123` | Pattern for "post-stream exit-code reclassification"; the auth classifier piggybacks on the same hook position |
| `run_gated_phase` retry loop | `claude-session-lib.sh:1448–1488` | Site of R3.4 short-circuit |
| `cmd_run` lock-acquire boundary | `grinder.sh:1395` | Probe placement (immediately before `acquire_grinder_lock`) |
| `cmd_resume` lock-acquire boundary | `grinder.sh:1511` | Same probe placement on the resume re-entry |
| `track_phase` deviation guard | `claude-session-lib.sh:1242` | Already gates `track_deviation` on `status == "completed"` — `auth_failed` status flows through unchanged, no special-case needed (EC-J) |
| Existing fixture pattern | `tests/test_grinder_orchestrator.sh` + `tests/fixtures/grinder-orchestrator/` | Template for the new test + fixture folder |

### Failure-shape evidence

Two literal substrings define the predicate (R3.1):

- `subtype == "success" AND is_error == true AND result CONTAINS "Not logged in"`
- `error == "authentication_failed"` (top-level field)

Both shapes were observed in the 2026-05-09 stream. Adding a third
shape (e.g., a future `error_code: "AUTH_LOST"`) is a single-line
extension to the predicate list (OCP, see SOLID Results).

### Sentinel exit-code selection

`gtimeout` reserves `124` (timeout) and `137`/`143` (signal kills).
Bash reserves `0`–`2`, `126`–`128`, `130`. POSIX reserves
`128+signum`. The interval `[64, 113]` is documented as available for
application-defined exits. Pick **`42`** (matches the example in
R3.3 and is unambiguously application-level).

### Test-fixture pattern

`tests/test_grinder_orchestrator.sh` already wraps subprocess
invocations against synthetic NDJSON fixtures stored under
`tests/fixtures/<feature>/`. The `make_mock_validate` helper writes a
shim script onto the test's `PATH`; the auth-recovery test follows
the same shape with `make_mock_claude` that emits one of the two
fixture NDJSON streams when invoked as `claude -p ...`.

## Components

### C1 — `auth_preflight_probe` (new function in `grinder.sh`)

- **File:** `adapters/claude-code/claude/tools/grinder.sh`
- **Signature:** `auth_preflight_probe()` — no arguments; returns
  `0` on success, exits `2` on any failure path.
- **Responsibility:** Verify `claude` CLI authentication before any
  batch can spawn. One job; no side-effects beyond a single `claude
  -p` invocation, stderr writes, and exit-code propagation.
- **Dependencies (read):**
  - `GRINDER_SKIP_AUTH_PREFLIGHT` env var (R1.7).
  - `_resolve_timeout_bin` from `claude-session-lib.sh` (already
    sourced by grinder.sh at line 56).
  - The named constants `AUTH_PROBE_TIMEOUT_S=5` and
    `AUTH_PROBE_PROMPT="reply with the single character 'k'"` (new,
    declared in `grinder.sh` defaults block ~line 70).
- **Dependents:** `cmd_run`, `cmd_resume`.
- **Behaviour:**
  1. If `GRINDER_SKIP_AUTH_PREFLIGHT == 1` → write
     `WARNING: auth preflight skipped via GRINDER_SKIP_AUTH_PREFLIGHT`
     to stderr and `return 0` (R1.7).
  2. If `command -v claude` fails → write
     `claude binary not found on PATH` to stderr and `exit 2` (R1.6).
  3. Run, with the eight-var proxy strip applied (matches R2's
     pattern so the probe is exercised under the same env as
     `run_phase`):
     ```
     env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u NO_PROXY \
         -u all_proxy -u https_proxy -u http_proxy -u no_proxy \
         "$timeout_bin" "$AUTH_PROBE_TIMEOUT_S" \
         claude -p "$AUTH_PROBE_PROMPT" --output-format stream-json --max-turns 1 \
         < /dev/null > "$probe_out" 2> "$probe_err" \
         || probe_rc=$?
     ```
     where `probe_out` / `probe_err` are `mktemp` files cleaned by an
     EXIT trap inside the function.
  4. If `probe_rc == 124` → write
     `claude auth probe timed out after ${AUTH_PROBE_TIMEOUT_S}s` to
     stderr and `exit 2` (R1.6).
  5. Pipe `probe_out` to `_auth_probe_classify_python` (a small
     inline `python3 -c` block — see C3 for the predicate; the probe
     and classifier share the same predicate to avoid drift).
     - On classifier match → write
       `claude auth required — run claude login and retry` to stderr
       and `exit 2` (R1.5).
     - On no match and `probe_rc == 0` → `return 0`. The success
       path stays silent (R1.4).
     - On no match and `probe_rc != 0` → write
       `claude auth probe failed (exit ${probe_rc})` to stderr and
       `exit 2`. (Defensive — covers the case where `claude -p`
       exits non-zero but the result event was not an auth-failed
       shape; treat as a probe failure rather than silently
       proceeding into batch execution.)
- **Performance contract (R1.2):** Success-path wall-clock ≤ 1s. The
  `--max-turns 1` flag plus a one-character prompt is the cheapest
  contract `claude -p` exposes; gtimeout enforces the 5s ceiling on
  any failure mode that violates that contract.

### C2 — `cmd_run` / `cmd_resume` probe insertion (`grinder.sh`)

- **File:** `adapters/claude-code/claude/tools/grinder.sh`
- **Modification:** Insert one call to `auth_preflight_probe`
  immediately before `acquire_grinder_lock` (line 1395 in `cmd_run`,
  line 1511 in `cmd_resume`).
- **Responsibility:** Sequence the probe inside the existing
  startup-validation order (pause-check → plan-validate →
  staleness → state-corruption → **probe** → lock).
- **Why both `cmd_run` and `cmd_resume`:** R1.8's main statement
  ("on `grinder.sh run` only") is contradicted by EC-G's example
  flow ("operator pauses, fixes auth, runs `grinder.sh resume`").
  The functional intent is "probe runs at every entry point that
  leads to batch execution"; both `cmd_run` and `cmd_resume` lead to
  `run_batch_loop`. Discover/pause/status/ack-review do not, so they
  do not invoke the probe (R1.8 secondary list satisfied). See
  Risks §RK-1 for the open-question disposition.
- **Dependencies:** `auth_preflight_probe` (C1), the existing
  ordering of pre-lock checks.
- **Dependents:** Operator UX.

### C3 — `_auth_failed_classify` (new helper in `claude-session-lib.sh`)

- **File:** `adapters/claude-code/claude/tools/lib/claude-session-lib.sh`
- **Signature:** `_auth_failed_classify <phase_ndjson>` → stdout
  prints either `"<reason>"` (one of `not_logged_in` |
  `authentication_failed`) on a match, or empty string on no match.
- **Responsibility:** Single-source predicate for "is this
  per-phase NDJSON stream an auth-failed shape?". Used by C1
  (preflight) and C5 (run_phase post-stream hook).
- **Dependencies:** Python `json` module (already used elsewhere in
  the file). No external state.
- **Dependents:** C1 (`auth_preflight_probe`), C5 (`run_phase`).
- **Implementation:** A `python3 -u -c '...'` block following the
  same posture as `process_stream` (line 1150) — `json.loads` per
  line, malformed lines silently skipped (R3.6), first match wins.
  Pseudocode:
  ```python
  for line in open(sys.argv[1]):
      try: e = json.loads(line)
      except json.JSONDecodeError: continue
      if e.get("type") != "result": continue
      if e.get("subtype") == "success" \
         and e.get("is_error") is True \
         and "Not logged in" in (e.get("result") or ""):
          print("not_logged_in"); break
      if e.get("error") == "authentication_failed":
          print("authentication_failed"); break
  ```
- **OCP note:** Adding a third shape is a `if e.get(...) == ...:`
  branch — single-point-of-change. No callers need to know about
  the predicate's internals.

### C4 — `_emit_auth_failed_event` (new helper in `claude-session-lib.sh`)

- **File:** `adapters/claude-code/claude/tools/lib/claude-session-lib.sh`
- **Signature:** `_emit_auth_failed_event <phase_name> <session_id>
  <reason>` → appends one NDJSON line to `$STREAM_FILE`.
- **Responsibility:** Append exactly one structured `auth_failed`
  event to the shared grinder stream (R3.2). Idempotency contract:
  the caller (`run_phase`) only invokes this helper once per phase
  invocation (deduplicated by C5's first-match-wins predicate); EC-E
  is satisfied because the second matching event in the same stream
  is observed by the predicate but does not trigger a second
  emission (the classifier already returned the first reason).
- **Dependencies:** `STREAM_FILE` global, `date` for the UTC ISO
  timestamp.
- **Dependents:** C5 (`run_phase`).
- **Implementation:**
  ```bash
  _emit_auth_failed_event() {
    local phase=$1 sid=$2 reason=$3
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    { printf '{"type":"auth_failed","phase":"%s","session_id":"%s","reason":"%s","ts":"%s"}\n' \
        "$phase" "$sid" "$reason" "$ts" >> "${STREAM_FILE:-/dev/null}"; } 2>/dev/null || true
  }
  ```
  The `2>/dev/null || true` matches `_emit_orchestrator_kill_event`
  at line 213 — append failure must not abort the kill path.

### C5 — `run_phase` post-stream auth hook (modify `claude-session-lib.sh`)

- **File:** `adapters/claude-code/claude/tools/lib/claude-session-lib.sh`
- **Modification:** Insert the auth-classifier hook AFTER the
  existing `session_id` extraction block (current lines 1339–1350)
  and BEFORE the `rm -f "$phase_ndjson" "$pid_file"` cleanup
  (current line 1351). The post-`_classify_phase_exit` position
  is required so the watchdog reclassification has already run;
  the post-extraction position is required so `session_id` is
  populated before `_emit_auth_failed_event` reads it; the
  pre-`rm` position is required so `_auth_failed_classify` can
  still read the per-phase NDJSON file. The hook returns early
  (skipping the resume loop) on a match, so the existing rm at
  line 1351 only runs on the no-match path. Pseudocode:
  ```bash
  # exit_code already reclassified by _classify_phase_exit above
  if [[ $exit_code -ne 0 ]]; then
    local auth_reason
    auth_reason=$(_auth_failed_classify "$phase_ndjson")
    if [[ -n "$auth_reason" ]]; then
      _emit_auth_failed_event "$phase_name" "$session_id" "$auth_reason"
      log "${RED}✗${NC} ${phase_name}: claude auth failed (${auth_reason})"
      rm -f "$phase_ndjson" "$pid_file"
      dashboard_event "PhaseStop" "$phase_name" "auth_failed (${auth_reason})"
      return $AUTH_FAILED_EXIT_CODE
    fi
  fi
  ```
- **Why post-`_classify_phase_exit`:** the timeout-reclassification
  branch (`grep -q '"type":"result"'`) might already have collapsed
  a 124/143/137 to 0 if the agent emitted the result event before
  the watchdog fired. We re-check the same `phase_ndjson` for the
  auth-failed shape only when `exit_code != 0`, so a successful
  phase doesn't pay the cost of an auth-classifier scan.
- **Why before the resume loop:** the resume loop only fires on
  `exit_code == 0` (line 1358); an auth-failed phase has `exit_code
  != 0` after C5 sets the sentinel. The early `return` skips the
  resume path cleanly.
- **session_id source:** the session-id extraction at line 1339
  already runs before this hook. Empty string on no-match is
  acceptable (`_emit_auth_failed_event` accepts empty `sid` — the
  field is informational, not load-bearing).
- **Sentinel constant:** declare `AUTH_FAILED_EXIT_CODE=42` at the
  top of `claude-session-lib.sh` (~line 73, alongside the existing
  `DEVIATION_TRACKER_DEFAULT_TIMEOUT_S` block) using the
  `: "${VAR:=value}"` idempotent-default idiom.
- **Dependencies:** C3, C4, the sentinel constant.
- **Dependents:** C6.

### C6 — `run_gated_phase` retry-loop short-circuit (modify `claude-session-lib.sh`)

- **File:** `adapters/claude-code/claude/tools/lib/claude-session-lib.sh`
- **Modification:** Inside the retry loop (lines 1453–1488), check
  for the sentinel exit code BEFORE the existing
  `[[ $attempt -lt $max_attempts ]]` retry branch:
  ```bash
  run_phase "$command" "$phase_name" "$workdir" || phase_exit=$?
  if [[ $phase_exit -eq $AUTH_FAILED_EXIT_CODE ]]; then
    track_phase "$phase_name" "auth_failed" "$(( $(date +%s) - PHASE_START ))" "null"
    log "${RED}✗${NC} grinder halted: claude authentication lost mid-run — run claude login and re-run grinder.sh run"
    fail_pipeline "$phase_name" "authentication failed; not retrying"
    return 1   # unreachable — fail_pipeline exits
  fi
  ```
- **Why this position:** It MUST run before the existing
  `if [[ $phase_exit -ne 0 ]]` block (line 1464) — the existing
  block's "retry on attempt 1" path is exactly the silent-retry
  failure mode this feature is closing.
- **Why `track_phase` with status `"auth_failed"`:** `track_phase`
  at line 1229 already gates `track_deviation` on
  `status == "completed"` (line 1242). Passing `"auth_failed"`
  satisfies R3.4's "shall not invoke `track_deviation`" contract
  with no special-casing — the existing dispatcher already does the
  right thing because the value is not `"completed"`. The phase row
  appears in the run summary so the operator sees what failed.
- **Why `fail_pipeline`:** `grinder.sh:91` already implements
  `fail_pipeline` as `log + exit 1`. R3.4's "exit the cmd_run flow
  with a non-zero exit code so the lock is released by the existing
  trap" is satisfied because `cmd_run`'s `setup_traps` (line 1399)
  registers a release handler on EXIT.
- **Why no `commit_phase`:** the early `return` skips the existing
  `commit_phase` call at line 1475 — R3.4 satisfied.
- **Dependencies:** `AUTH_FAILED_EXIT_CODE`, `track_phase`,
  `fail_pipeline`, `log`.
- **Dependents:** Operator UX (the halt message + non-zero exit).

### C7 — `run_phase` env-strip extension (modify `claude-session-lib.sh`)

- **File:** `adapters/claude-code/claude/tools/lib/claude-session-lib.sh`
- **Modification:** At line 1307, extend the existing six-var strip
  to eight vars verbatim from the assessor wire at line 699:
  ```bash
  $timeout_cmd env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u NO_PROXY \
      -u all_proxy -u https_proxy -u http_proxy -u no_proxy \
      python3 -c "$_setsid_exec_python" \
      claude -p "$command" \
      ...
  ```
- **Resume-path symmetry (R2.3):** The resume `claude -p`
  invocation at line 1397–1409 currently has NO env strip at all
  (only the initial invocation strips). R2.3 requires "every direct
  `claude -p` invocation in `run_phase`'s execution path uses the
  same eight-variable env strip". The resume invocation is inside
  the same `run_phase` body, so it MUST receive the same eight-var
  strip. The plan extends both call sites:
  ```bash
  CLAUDE_PID_FILE="$resume_pid_file" \
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u NO_PROXY \
      -u all_proxy -u https_proxy -u http_proxy -u no_proxy \
      python3 -c "$_setsid_exec_python" \
      claude -p "$keyword" --resume "$session_id" ...
  ```
  This closes a latent gap the BA's literal R2.1 wording would
  otherwise leave open. R2.3's "every direct invocation" wording
  is the controlling clause.
- **Dependencies:** None — this is an `env -u` flag-list extension,
  no new shell logic.
- **Dependents:** None — env propagation only.

### C8 — Test fixture infrastructure

- **Files:**
  - `tests/test_grinder_auth_recovery.sh` (new, ~150 lines)
  - `tests/fixtures/grinder-auth-recovery/auth_failed_not_logged_in.ndjson` (new, ~10 lines)
  - `tests/fixtures/grinder-auth-recovery/auth_failed_top_level_error.ndjson` (new, ~10 lines)
  - `tests/fixtures/grinder-auth-recovery/non_auth_failure.ndjson` (new, ~10 lines — the R3.5 negative case)
- **Responsibility:**
  - Inject synthetic auth-failed result events into the per-phase
    NDJSON stream consumed by `process_stream` and the new C3
    classifier.
  - Assert the three R4.3 outcomes on each fixture: exactly one
    `auth_failed` event in `STREAM_FILE`, zero `attempt 2/`
    log lines, non-zero exit from `run_gated_phase`.
- **Test driver shape:**
  - The test sources `claude-session-lib.sh` directly and invokes
    `run_gated_phase` with a mocked `claude` shim on `PATH` — the
    same pattern `test_grinder_orchestrator.sh::make_mock_validate`
    already uses for `validate-plan.py`.
  - The shim is a tiny bash script in the test's `$TMPDIR/mock-bin/`
    that, on `claude -p ...`, `cat`s the chosen fixture NDJSON to
    stdout. It has no network access and no real `claude` install
    is required (R4.5).
  - `GRINDER_SKIP_AUTH_PREFLIGHT=1` is exported per-invocation (R4.1)
    so the preflight probe doesn't fire against the same shim.
  - Required globals (`STREAM_FILE`, `AUTOPILOT_SID`,
    `DASHBOARD_DATA`, `PHASE_TIMEOUT`, `MAX_TURNS_PHASE`,
    `ALLOWED_TOOLS`, `TASK`, `PHASE_NAMES`, `PHASE_STATUSES`,
    `PHASE_DURATIONS`, `PHASE_ARTIFACTS`, `PHASE_COSTS`) are
    initialised in the test's `setup_env` helper to ephemeral
    `$TMPDIR` paths.
  - A stub `log()` and stub `fail_pipeline()` are defined in the
    test before sourcing the lib so the lib's caller-provided
    contract (file header lines 48–53) is satisfied without
    pulling in `grinder.sh`. The stub `fail_pipeline` returns 1
    instead of `exit 1` so the test process survives to assert on
    the post-state.
- **Three test cases:**
  1. `auth_failed_not_logged_in.ndjson` → assert exactly one
     `"reason":"not_logged_in"` event, zero retry, exit non-zero.
  2. `auth_failed_top_level_error.ndjson` → assert exactly one
     `"reason":"authentication_failed"` event, zero retry, exit
     non-zero.
  3. `non_auth_failure.ndjson` (R3.5 negative) → emits a result
     event with `is_error:true result:"validation failed"` (NOT one
     of the auth shapes); assert ZERO `auth_failed` events emitted
     and the existing two-attempt retry path is exercised
     (`attempt 2/$max_attempts` log line IS present). This proves
     non-auth failures are unaffected.
- **Self-containment (R4.5):** All work happens in `$TMPDIR`; trap
  on EXIT/INT/TERM cleans up. The test asserts `git status` is
  unchanged at start vs. end as a defence-in-depth check.
- **Runtime budget (R4.4):** Each invocation runs the shim with
  `< /dev/null` and no real network — wall-clock is bounded by
  bash subshell startup × 3 cases ≈ 3–5s, well under 30s.

## Data Flow

### Probe path (R1, AC-1)

```
operator runs grinder.sh run
  ↓
cmd_run: pause-check → validate-plan → staleness-check → state-check
  ↓
auth_preflight_probe()              ← NEW (C1, C2)
  ├─ skip env set?  → WARNING + return 0
  ├─ claude on PATH? → no  → exit 2 (binary-not-found message)
  ├─ run claude -p "k" with 8-var env strip + 5s timeout
  ├─ timeout?  → exit 2 (timeout message)
  ├─ classify probe stdout via _auth_failed_classify (C3)
  │     ├─ match → exit 2 (auth-required message)
  │     └─ no match + rc==0 → return 0  (success-path silent, R1.4)
  │     └─ no match + rc!=0 → exit 2 (probe-failed message)
  ↓
acquire_grinder_lock → setup_traps → run_batch_loop
```

### Run-time auth-loss path (R3, AC-3)

```
run_gated_phase loop iteration N:
  ↓
run_phase
  ├─ env -u (8 vars, C7) python3 -c setsid_exec claude -p ...
  ├─ tee → STREAM_FILE, phase_ndjson, process_stream
  ├─ exit_code = _classify_phase_exit (existing — masks 124/143/137 if result emitted)
  ├─ NEW (C5): if exit_code != 0:
  │     reason = _auth_failed_classify(phase_ndjson)        (C3)
  │     if reason:
  │       _emit_auth_failed_event(phase, sid, reason)       (C4 → STREAM_FILE)
  │       log + dashboard_event + cleanup tmps
  │       return AUTH_FAILED_EXIT_CODE                       (sentinel = 42)
  │
  ↓ run_phase returns 42
  ↓
run_gated_phase: NEW (C6)
  if phase_exit == AUTH_FAILED_EXIT_CODE:
    track_phase(phase, "auth_failed", duration, null)        ← skips track_deviation per existing gate
    log "grinder halted: claude authentication lost mid-run — run claude login and re-run grinder.sh run"
    fail_pipeline → exit 1 → trap releases lock              (R3.4 satisfied)
```

### Negative path (R3.5, EC-F)

A non-auth `is_error:true` result event flows through unchanged:
- `_classify_phase_exit` returns the original non-zero code.
- `_auth_failed_classify` returns empty → C5 hook skipped.
- `run_gated_phase`'s existing `if [[ $phase_exit -ne 0 ]]` branch
  fires → existing 2-attempt retry runs → existing failure
  semantics preserved bit-for-bit.

A malformed JSON line in `phase_ndjson` is skipped by the python
`json.loads` try/except (R3.6) — same posture as `process_stream`
at line 1167.

## SOLID Results

### S — Single Responsibility

| Component | Single reason to change |
|---|---|
| C1 `auth_preflight_probe` | The shape of "claude is unauthenticated" at startup |
| C3 `_auth_failed_classify` | The predicate for auth-failure shapes (one source of truth) |
| C4 `_emit_auth_failed_event` | The wire format of the structured event |
| C5 run_phase hook | Where in the existing pipeline the classifier runs |
| C6 run_gated_phase short-circuit | The retry-loop's contract for fatal-not-retryable failures |
| C7 env-strip extension | The proxy-variable list inside `run_phase` |
| C8 test fixture | What evidence proves the contract holds |

### O — Open/Closed

- C3 is the single point of extension for new auth-failure shapes —
  add a branch, no callers change.
- C5 + C6 communicate via the named sentinel `AUTH_FAILED_EXIT_CODE`
  — any future caller that wraps `run_phase` (today only
  `run_gated_phase`) can short-circuit by checking that constant
  (EC-K satisfied as a closed extension point).
- The `_emit_auth_failed_event` wire format is additive — adding
  a `commit_ref` or `attempt` field later is a string change in C4;
  consumers parse JSON and ignore unknown fields.

### L — Liskov

`run_phase` already promises "returns 0 on success, non-zero on
failure". Returning `AUTH_FAILED_EXIT_CODE` is a non-zero value,
which is contract-compatible. `run_gated_phase` previously assumed
"any non-zero ⇒ retry" — that was the bug. The post-condition is
strengthened to "any non-zero ⇒ retry UNLESS sentinel". Existing
callers that did not check the sentinel see no behavioural change
(no caller other than `run_gated_phase` exists today; the contract
extension is therefore safe).

### I — Interface Segregation

- C3 has a single-argument interface (`<phase_ndjson>`) — no
  caller needs to know about auth-tracker timeouts, deviation state,
  or stream wire format.
- C4 has a 3-argument interface — caller doesn't see the `STREAM_FILE`
  global except through this seam. Test C8 can pre-set
  `STREAM_FILE` and call C4 directly.
- C1 has a zero-argument interface — the env-var skip is the only
  external dial.

### D — Dependency Inversion

- C1, C3, C4 are pure functions of their inputs (env, file path,
  arguments) — testable in isolation by C8.
- C5/C6 depend on the C3/C4 abstractions (function names), not on
  inline regex or printf. The classifier predicate can be swapped
  by editing C3 alone.
- The sentinel constant is declared in the lib that owns
  `run_gated_phase`; consumers that include the lib import the
  symbol — there is no string-literal "42" anywhere in C5 or C6.

## Agent Navigability

| Check | Disposition |
|---|---|
| Module names self-describing | `auth_preflight_probe`, `_auth_failed_classify`, `_emit_auth_failed_event`, `AUTH_FAILED_EXIT_CODE` — names announce purpose without context |
| Interfaces explicit | Each function has a header comment stating arguments + return contract; matches the existing `_resolve_timeout_bin` / `_classify_phase_exit` pattern in the file |
| Structured logging on error paths | Every error path writes a single-line stderr message with the actionable next step (R6.2). The structured `auth_failed` event (R3.2) is the discoverable signal in `STREAM_FILE` |
| CLAUDE.md update | YES — `adapters/claude-code/claude/CLAUDE.md` (the "Pipelines" / "Grinder" section) needs one paragraph describing the preflight probe + the `GRINDER_SKIP_AUTH_PREFLIGHT` env var. The project-root `CLAUDE.md` is unchanged (no new directories, no new top-level commands) |
| Header comment block on `claude-session-lib.sh` | Add `AUTH_FAILED_EXIT_CODE` to the "Caller-Provided Globals" / "Tunables" table at the top of the file so future readers see it next to `DEVIATION_TRACKER_DEFAULT_TIMEOUT_S` |
| New file headers | `tests/test_grinder_auth_recovery.sh` gets a 6-line header matching `test_grinder_orchestrator.sh:1–8` (purpose, usage, exit semantics) |

## TDD Assessment

| Component | Test in isolation? | Notes |
|---|---|---|
| C1 `auth_preflight_probe` | YES | Shim `claude` on `$PATH` writes either of the fixture NDJSONs; assert exit code + stderr line. Three cases: success, auth-failed (each shape), missing-binary, timeout. |
| C2 `cmd_run` insertion | YES via integration | Existing `test_grinder_orchestrator.sh` patterns (mock validate-plan, mock claude) suffice. The probe-call ordering is testable by asserting "lock is not acquired when probe fails". |
| C3 `_auth_failed_classify` | YES | Pure function of one argument (file path). Can be unit-tested by sourcing the lib in `bash -c` and calling the function directly with a fixture file. |
| C4 `_emit_auth_failed_event` | YES | Set `STREAM_FILE=$TMPDIR/x`, call function, grep the file. |
| C5 run_phase hook | YES via shim | Mock `claude` shim emits fixture NDJSON; assert classifier-emitted event in `STREAM_FILE`, sentinel exit code, no resume-loop invocation. |
| C6 run_gated_phase short-circuit | YES via stub | Stub `run_phase` to return `$AUTH_FAILED_EXIT_CODE` directly; assert no second `run_phase` call (e.g. via a counter file), `track_phase` row recorded as `auth_failed`, `fail_pipeline` called once. |
| C7 env-strip extension | YES via grep | Static check is sufficient: `grep -c '\-u no_proxy' claude-session-lib.sh` returns the expected count. AC-2 explicitly accepts a static check (REQUIREMENTS.md line 286–289). |
| C8 fixture infra | n/a (it IS the test) | Self-checks that fixtures parse as valid JSON via `python3 -c "import json; [json.loads(l) for l in open(sys.argv[1])]"` in test setup. |

**Missing abstraction risk:** None identified. The
`_auth_failed_classify` ↔ `_emit_auth_failed_event` split is
deliberate so the predicate can be tested without the side-effect.

## Config Changes

### `adapters/claude-code/claude/tools/grinder.sh` defaults block (~line 70)

```bash
GRINDER_BATCH_TIMEOUT="${GRINDER_BATCH_TIMEOUT:-1800}"
GRINDER_LOCK_MAX_WAIT="${GRINDER_LOCK_MAX_WAIT:-60}"
PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Projekter}"
# NEW:
AUTH_PROBE_TIMEOUT_S="${AUTH_PROBE_TIMEOUT_S:-5}"
AUTH_PROBE_PROMPT="${AUTH_PROBE_PROMPT:-reply with the single character k}"
```

Both are operator-overridable via env so a future debug/diagnostic
path can extend the timeout without code change.

### `adapters/claude-code/claude/tools/lib/claude-session-lib.sh` tunables block (~line 73)

```bash
: "${DEVIATION_TRACKER_DEFAULT_TIMEOUT_S:=10}"
: "${DEVIATION_TRACKER_KILL_GRACE_S:=2}"
: "${DEVIATION_ASSESSOR_TIMEOUT_S:=60}"
# NEW:
: "${AUTH_FAILED_EXIT_CODE:=42}"
```

Idempotent default — matches the existing `: "${VAR:=value}"` pattern
so a caller that pre-sets the value (e.g., a test) is honoured.

### `config/settings.yaml`

No entries. This feature has no project-level config —
all dials are env vars consumed at the orchestrator boundary.

### Environment variables (operator-facing)

| Var | Default | Effect |
|---|---|---|
| `GRINDER_SKIP_AUTH_PREFLIGHT` | unset | If `=1`, probe writes WARNING and returns 0 without invoking `claude` (test-only knob, R1.7) |
| `AUTH_PROBE_TIMEOUT_S` | `5` | Hard deadline for the `claude -p` probe (R1.3) |
| `AUTH_PROBE_PROMPT` | `reply with the single character k` | Probe prompt (deterministic, ≤1 token expected response, R1.3) |
| `AUTH_FAILED_EXIT_CODE` | `42` | Sentinel exit code from `run_phase` on auth-failed (R3.3); operator-overridable for future collision avoidance |

## CLAUDE.md / ARCHITECTURE.md Updates

- **`adapters/claude-code/claude/CLAUDE.md`** — append one paragraph
  to the "Continuous workflows / Grinder" line documenting the
  preflight probe + the `GRINDER_SKIP_AUTH_PREFLIGHT` test knob.
  This is in scope for `/implement` (the docs change ships with the
  code that introduces the behaviour).
- **Project-root `CLAUDE.md`** — no change. No new directories, no
  new top-level commands, no new schema versions.
- **`adapters/claude-code/claude/tools/lib/claude-session-lib.sh`
  header table** — add `AUTH_FAILED_EXIT_CODE` to the
  "Caller-Provided Globals" / "Tunables" section (file lines 12–44)
  so the contract is discoverable.
- **`adapters/claude-code/claude/tools/grinder.sh` header** — add
  one bullet under "Caller Globals (session-scoped, set once)" for
  `AUTH_PROBE_TIMEOUT_S` / `AUTH_PROBE_PROMPT` so the env-var
  contract is discoverable from the entry point.

## Risks

### RK-1 — `cmd_run` vs `cmd_resume` probe symmetry (BA contradiction)

REQUIREMENTS.md R1.8 says the probe runs on `grinder.sh run` only;
EC-G says it runs on resume too. Resolution chosen by Architect:
**probe runs on both** because the BA's parenthetical ("Resume
re-enters cmd_run after the pause check") shows the intent was
"every entry path that leads to batch execution". Both functions
call `run_batch_loop`. Discover/pause/status/ack-review do not, so
they are excluded — R1.8's secondary list is honoured.

**Mitigation:** /review will see this disposition explicitly. If
the operator (BA) wants strict R1.8 literal interpretation, this
is the single point of change — remove the `cmd_resume` insertion
in C2 and add an explicit comment.

### RK-2 — Sentinel exit code collision

`AUTH_FAILED_EXIT_CODE=42` is in the `[64, 113]` application range,
clear of bash and POSIX reserved codes. **But** if a future
contributor adds an `EAGER_EXIT_KILL_CODE` or similar in the same
file with the same numeric value, the dispatch in C6 silently
mis-classifies. **Mitigation:** the constant is named, declared
once at the top of `claude-session-lib.sh`, and used by name (not
numeric literal) in C5 and C6. A grep for `\b42\b` in
`claude-session-lib.sh` post-implementation should hit only the
constant declaration.

### RK-3 — Probe `claude -p` first-call latency

A cold `claude -p` invocation (no warm runtime, model not yet
JIT'd) can take 1–3s on slow networks even on the success path.
R1.2's "≤1s on success" is aspirational for an already-warm
binary. **Mitigation:** the contract is a soft target — the hard
ceiling is `AUTH_PROBE_TIMEOUT_S=5`. If the operator hits the soft
ceiling regularly, the env-var dial allows extending the budget
without code change.

### RK-4 — `phase_ndjson` removed before classifier reads it

The current `run_phase` cleans up `phase_ndjson` at line 1351
(`rm -f "$phase_ndjson" "$pid_file"`) BEFORE the resume loop. The
auth-classifier hook (C5) must run AFTER the session-id extraction
(line 1339) but BEFORE the rm (line 1351). The plan places the
hook between those two lines. **Mitigation:** explicit
positioning callout in C5; /review must verify the sequence.

### RK-5 — Test fixture parsing collision with assessor wire

The new `_auth_failed_classify` predicate looks for
`error == "authentication_failed"` at the top level. The assessor
wire (`_assessor_validate_payload`) parses JSON output from a
sub-`claude -p`; a malformed assessor-output line that happens to
contain `error: "authentication_failed"` would be detected by C3
if it ever reached `phase_ndjson`. **Mitigation:** C3 only inspects
events with `type == "result"`. Assessor output is a phase_result
schema object (no `type: "result"` field), so the predicate cannot
fire on assessor output. Document this in the C3 docstring.

### RK-6 — Resume-path env-strip latent gap (R2.3 enforcement)

The resume `claude -p` invocation at line 1397–1409 currently has
NO proxy strip at all. R2.3 wording ("every direct `claude -p`
invocation in `run_phase`'s execution path") makes this in-scope,
but the BA's narrative focuses on the initial invocation. **If
/review interprets R2.3 narrowly as "the same line, just longer"**,
the resume-path strip would not ship and a future auth-loss during
resume would re-create the same proxy-bleed bug for the resume
case only. **Disposition:** the plan ships the resume-path strip
under R2.3's controlling clause. If /review prefers the narrow
read, this is a single-line revert — drop the eight `env -u` flags
from the resume invocation in C7, leaving the initial-invocation
strip in place.

### RK-7 — `track_phase` row format for `auth_failed` status

The existing `track_phase` writes the status string verbatim into
`PHASE_STATUSES[]`. Downstream summary code (`print_run_summary`
in `grinder.sh:1318` and assorted dashboards) prints the status
literal without colour-mapping for unknown values, so an
`auth_failed` row will appear as the bare string `auth_failed`
rather than a colour-coded entry. This matches the existing
posture for any non-`completed`/non-`failed` status — there is no
special render path to extend.

**Disposition:** the operator-facing signal per R6.1 is the
stderr halt message in C6 plus the structured NDJSON event in
C4, both of which are unambiguous and actionable. The summary
table's literal-string rendering of `auth_failed` is sufficient
context for the post-run summary; `print_run_summary` is not
modified by this task and no behaviour change is required.

## Component-to-Requirement Trace

| Requirement | Components |
|---|---|
| R1.1 | C1 + C2 |
| R1.2 | C1 (success path budget) |
| R1.3 | C1 (timeout, prompt, classifier shape) |
| R1.4 | C1 (silent success) |
| R1.5 | C1 (auth-required stderr + exit 2) |
| R1.6 | C1 (binary-not-found / timeout messages) |
| R1.7 | C1 (`GRINDER_SKIP_AUTH_PREFLIGHT` short-circuit) |
| R1.8 | C2 (placement in `cmd_run` + `cmd_resume`; not in discover/pause/status/ack-review) — see RK-1 |
| R2.1 | C7 (env-strip extension at line 1307) |
| R2.2 | C7 (`env -u` flags only) |
| R2.3 | C7 (resume-path symmetry) — see RK-6 |
| R3.1 | C3 (predicate, both shapes) |
| R3.2 | C4 + C5 (one event, no duplication via first-match-wins) |
| R3.3 | C5 + sentinel constant in `claude-session-lib.sh` |
| R3.4 | C6 (no commit, no track_deviation, halt message, non-zero exit) |
| R3.5 | C5 (hook gated on `exit_code != 0` + classifier returning empty) |
| R3.6 | C3 (`json.loads` try/except, mirroring `process_stream`) |
| R4.1 | C8 (test sets `GRINDER_SKIP_AUTH_PREFLIGHT=1`) |
| R4.2 | C8 (fixture NDJSONs cover both shapes) |
| R4.3 | C8 (three assertions per case) |
| R4.4 | C8 (≤30s budget, ≤5s actual) |
| R4.5 | C8 (TMPDIR isolation, EXIT trap cleanup, no real claude) |
| R4.6 | C8 (`tests/fixtures/grinder-auth-recovery/`) |
| R5.1 / R5.2 | not in this task — verified in parent plan's `sonarqube-and-verification` phase, against the infrastructure C1–C8 ship |
| R6.1 | C4 + C5 (single discoverable signal) |
| R6.2 | C1 (actionable stderr message) |
| R6.3 | C1 (probe writes only to `$TMPDIR`) |

Every requirement maps to at least one component; no requirement is
deferred or scope-narrowed. RK-1 (R1.8 vs EC-G) and RK-6 (R2.3
breadth) are explicit risk callouts for /review, not gaps.

## Open Questions

None for the operator. RK-1 and RK-6 are dispositions, not
questions — the plan ships the broader interpretation in both
cases and surfaces the alternative for /review's veto. Both are
single-line reverts if /review prefers the narrow read.
