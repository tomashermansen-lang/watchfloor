#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib/sandbox.sh
source "$SCRIPT_DIR/_lib/sandbox.sh"
PASS=0
FAIL=0
SKIP=0
FAILED_SUITES=()
SKIPPED_SUITES=()

# --only-integration: run ONLY the integration suites (git-fixture / server-bound),
# skipping the unit suites. This is the scope the orchestrator integration gate
# uses (real integration gates §4.4 / §9) — the unit suites already ran
# sandboxed inside a feature phase, so re-running them at the gate is pure cost.
# Without the flag, every suite runs (the sandboxed-phase / local-dev default).
ONLY_INTEGRATION=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only-integration) ONLY_INTEGRATION=1; shift ;;
    *) echo "run-all.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Git-fixture integration suites can't run in the Claude Code sandbox (git init
# is blocked there). Detect once; SKIP them when git repo creation is
# unavailable so the sandboxed agent doesn't wedge on spurious exit-128
# failures — those suites run in the orchestrator integration gate
# (unsandboxed). RUNALL_ASSUME_NO_GIT=1 forces the skip path for tests.
if [ "${RUNALL_ASSUME_NO_GIT:-0}" = "1" ] || ! git_repo_supported; then
  GIT_REPO_OK=false
else
  GIT_REPO_OK=true
fi

# Hard per-suite timeout so one hanging suite can't wedge the whole run — a
# dashboard suite was observed to hang and ignore SIGINT (canary-models
# 2026-06-02). Override with RUNALL_SUITE_TIMEOUT.
SUITE_TIMEOUT="${RUNALL_SUITE_TIMEOUT:-180}"
# Retries to absorb transient flakiness (random ports / uvicorn boot / races).
# A suite only counts FAIL if it fails every attempt. 0 to disable.
SUITE_RETRIES="${RUNALL_SUITE_RETRIES:-1}"

# run_suite <name> <script> [needs]   needs="git" marks a git-fixture suite.
run_suite() {
  local name="$1"
  local script="$2"
  local needs="${3:-}"
  printf "%-40s " "$name"
  case "$(suite_run_decision "$needs" "$GIT_REPO_OK" "$ONLY_INTEGRATION")" in
    skip:broken)
      printf "SKIP (known-broken: hangs — quarantined, see TODO in run-all.sh)\n"
      SKIP=$((SKIP + 1)); SKIPPED_SUITES+=("$name"); return 0 ;;
    skip:sandbox)
      printf "SKIP (sandbox: git repo creation blocked — runs in orchestrator gate)\n"
      SKIP=$((SKIP + 1)); SKIPPED_SUITES+=("$name"); return 0 ;;
    skip:unit)
      printf "SKIP (unit suite — runs sandboxed in a feature phase, not the gate)\n"
      SKIP=$((SKIP + 1)); SKIPPED_SUITES+=("$name"); return 0 ;;
  esac
  local rc=0
  run_bounded_retry "$SUITE_TIMEOUT" "$SUITE_RETRIES" bash "$script" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf "PASS\n"
    PASS=$((PASS + 1))
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    printf "TIMEOUT (>%ss)\n" "$SUITE_TIMEOUT"
    FAIL=$((FAIL + 1))
    FAILED_SUITES+=("$name (timeout)")
  else
    printf "FAIL\n"
    FAIL=$((FAIL + 1))
    FAILED_SUITES+=("$name")
    # Re-run to show failure details
    run_bounded "$SUITE_TIMEOUT" bash "$script" 2>&1 | grep -E "^\s+FAIL:" || true
  fi
}

echo "=== Agent Dashboard Test Runner ==="
[ "$ONLY_INTEGRATION" = "1" ] && echo "(--only-integration: running gate suites only; unit suites skipped)"
echo ""

run_suite "Test fixture preflight lint" "$SCRIPT_DIR/../../adapters/claude-code/claude/tools/lint/test-fixture-uses-preflight.sh"
run_suite "Sonar nested properties lint" "$SCRIPT_DIR/../../adapters/claude-code/claude/tools/lint/no-nested-sonar-properties.sh"
run_suite "Test fixture lint suite tests" "$SCRIPT_DIR/test-lint-fixture.sh" "git"
run_suite "Hook functional tests" "$SCRIPT_DIR/test-hook.sh" "git"
run_suite "Concurrent write tests" "$SCRIPT_DIR/test-concurrent-writes.sh" "git"
run_suite "Security tests" "$SCRIPT_DIR/test-security.sh" "git"
run_suite "CSRF enforcement (TestClient)" "$SCRIPT_DIR/test-csrf-enforcement.sh"
run_suite "Schema & validation tests" "$SCRIPT_DIR/test-schema.sh"
run_suite "Schema sync (dotfiles) tests" "$SCRIPT_DIR/test-schema-sync.sh"
run_suite "Converter tests" "$SCRIPT_DIR/test-convert.sh"
run_suite "API plan endpoint tests" "$SCRIPT_DIR/test-api-plan.sh" "git"
run_suite "Plan helpers unit tests" "$SCRIPT_DIR/test-plan-helpers.sh"
run_suite "Plan detection tests" "$SCRIPT_DIR/test-plan-detection.sh" "git"
run_suite "Hook expanded fields tests" "$SCRIPT_DIR/test-hook-expanded.sh" "git"
run_suite "Metrics computation tests" "$SCRIPT_DIR/test-metrics.sh"
run_suite "API metrics endpoint tests" "$SCRIPT_DIR/test-api-metrics.sh" "server"
run_suite "PTC script tests" "$SCRIPT_DIR/test-ptc-scripts.sh" "git"
run_suite "Prompt quality guards" "$SCRIPT_DIR/test-prompt-guards.sh"
run_suite "Team command tests" "$SCRIPT_DIR/test-team-commands.sh"
run_suite "Autopilot parser tests" "$SCRIPT_DIR/test-autopilot-parser.sh"
run_suite "Autopilot pause tests" "$SCRIPT_DIR/test-autopilot-pause.sh"
run_suite "Stop-after-phase tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_stop_after_phase.sh"
run_suite "Stop-after-phase chain tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_stop_after_phase_chain.sh"
run_suite "Chain runner-overrides tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_chain_runner_overrides.sh"
run_suite "Local-LLM routing tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_local_llm_routing.sh"
run_suite "Lifecycle bash emitters" "$SCRIPT_DIR/test-lifecycle-bash-emitters.sh"
run_suite "API autopilot endpoint tests" "$SCRIPT_DIR/test-api-autopilot.sh" "server"
run_suite "Stuck detection tests" "$SCRIPT_DIR/test-stuck-detection.sh"
run_suite "Feature API tests" "$SCRIPT_DIR/test-features.sh" "server"
run_suite "Grinder API endpoint tests" "$SCRIPT_DIR/test-api-grinder.sh" "git"
run_suite "FastAPI app /health tests" "$SCRIPT_DIR/test-app.sh"
run_suite "Delegator script tests" "$SCRIPT_DIR/test-delegator.sh" "git"
run_suite "FastAPI integration (uvicorn)" "$SCRIPT_DIR/test-fastapi-integration.sh" "server"
run_suite "Install message tests" "$SCRIPT_DIR/test_install_message.sh"
run_suite "Port preflight + reaper tests" "$SCRIPT_DIR/test-port-preflight.sh" "server"
run_suite "Worktree reaper helper tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test-worktree-reaper.sh"
run_suite "Run phase watchdog tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_run_phase_watchdog.sh"
run_suite "Eager-exit watchdog tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test-eager-exit.sh"
run_suite "Grinder auth-recovery tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_grinder_auth_recovery.sh"
# Integration-gate machinery (real integration gates). Pure bash unit suites —
# they source the lib and exercise the decision functions, so they run sandboxed
# here rather than at the gate. Registered so they cannot rot ("runs nowhere").
run_suite "Integration gate tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_integration_gate.sh"
run_suite "Integration trigger tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_integration_trigger.sh"
run_suite "Run-all sandbox-skip tests" "$(cd "$SCRIPT_DIR/../.." && pwd)/tests/test_runall_sandbox_skip.sh"

# Frontend tests (if app/ exists). A unit suite (jsdom, in-process) — skipped at
# the integration gate, where it would re-run work a feature phase already did.
APP_DIR="$(cd "$SCRIPT_DIR/../app" 2>/dev/null && pwd)"
if [ "$ONLY_INTEGRATION" = "1" ]; then
  printf "%-40s " "Frontend tests (Vitest)"
  printf "SKIP (unit suite — runs sandboxed in a feature phase, not the gate)\n"
  SKIP=$((SKIP + 1))
  SKIPPED_SUITES+=("Frontend tests")
elif [ -d "$APP_DIR" ] && [ -f "$APP_DIR/package.json" ]; then
  printf "%-40s " "Frontend tests (Vitest)"
  if (cd "$APP_DIR" && npm test) >/dev/null 2>&1; then
    printf "PASS\n"
    PASS=$((PASS + 1))
  else
    printf "FAIL\n"
    FAIL=$((FAIL + 1))
    FAILED_SUITES+=("Frontend tests")
    (cd "$APP_DIR" && npm test) 2>&1 | grep -E "FAIL|Error" | head -5 || true
  fi
fi

echo ""
echo "---"
printf "Suites: %d passed, %d failed, %d skipped, %d total\n" "$PASS" "$FAIL" "$SKIP" $((PASS + FAIL + SKIP))

if [ "$SKIP" -gt 0 ]; then
  echo "Skipped (sandbox; run in the orchestrator integration gate): ${SKIPPED_SUITES[*]}"
fi

if [ "$FAIL" -gt 0 ]; then
  echo "Failed: ${FAILED_SUITES[*]}"
  exit 1
fi

echo "All suites passed (${SKIP} skipped)."
exit 0
