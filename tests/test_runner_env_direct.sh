#!/usr/bin/env bash
# Footgun fix (2026-06-02): a DIRECT `autopilot.sh <task>` run must honor the
# task's runner.env (esp. MODEL_PER_PHASE) from the plan. Previously only
# autopilot-chain.sh injected runner.env, so a direct run of an all-Opus canary
# silently fell back to DEFAULT_MODEL_PER_PHASE and executed as Sonnet.
#
# Precedence: explicit environment ALWAYS wins (a per-invocation prefix or a
# per-shell export, including MODEL_PER_PHASE="" to disable the default). The
# plan only fills in vars the operator did not set.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

PASS=0
FAIL=0
check() { if "$2"; then echo "  ok: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/runnerenv.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/plan.yaml" <<'YAML'
schema_version: "2.0.0"
name: t
phases:
  - id: p1
    tasks:
      - id: task-opus
        runner:
          env:
            MODEL_PER_PHASE: "ba=claude-opus-4-8,commit=claude-opus-4-8"
            LOCAL_LLM_ROUTING: "0"
      - id: task-plain
        status: pending
YAML

# Run apply_plan_runner_env for <task> after optionally pre-setting env via $2.
run_apply() {
  local task="$1" preset="${2:-:}"
  bash -c "
    unset MODEL_PER_PHASE LOCAL_LLM_ROUTING
    $preset
    STREAM_FILE=/dev/null; AUTOPILOT_SID=t; DASHBOARD_DATA=/dev/null
    source '$LIB' 2>/dev/null
    log() { :; }
    apply_plan_runner_env '$TMP/plan.yaml' '$task'
    printf 'MPP=[%s]\n' \"\${MODEL_PER_PHASE-<unset>}\"
    printf 'LLM=[%s]\n' \"\${LOCAL_LLM_ROUTING-<unset>}\"
  "
}

test_applies_when_unset() {
  local o; o=$(run_apply task-opus)
  echo "$o" | grep -q 'MPP=\[ba=claude-opus-4-8,commit=claude-opus-4-8\]' \
    || { echo "    MODEL_PER_PHASE not applied from plan; got: $o"; return 1; }
}
check "applies MODEL_PER_PHASE from plan when env is unset" test_applies_when_unset

test_applies_all_env_keys() {
  local o; o=$(run_apply task-opus)
  echo "$o" | grep -q 'LLM=\[0\]' || { echo "    other runner.env keys not applied; got: $o"; return 1; }
}
check "applies all runner.env keys (not just MODEL_PER_PHASE)" test_applies_all_env_keys

test_explicit_env_wins() {
  local o; o=$(run_apply task-opus 'export MODEL_PER_PHASE=KEEP_ME')
  echo "$o" | grep -q 'MPP=\[KEEP_ME\]' || { echo "    explicit env was overridden by plan; got: $o"; return 1; }
}
check "explicit per-invocation env wins over the plan" test_explicit_env_wins

test_empty_env_disables() {
  # MODEL_PER_PHASE="" is the documented 'disable the default' value — it is SET,
  # so the plan must NOT overwrite it.
  local o; o=$(run_apply task-opus 'export MODEL_PER_PHASE=')
  echo "$o" | grep -q 'MPP=\[\]' || { echo "    empty MODEL_PER_PHASE was clobbered by plan; got: $o"; return 1; }
}
check 'explicit MODEL_PER_PHASE="" (disable) is preserved' test_empty_env_disables

test_no_runner_is_noop() {
  local o; o=$(run_apply task-plain)
  echo "$o" | grep -q 'MPP=\[<unset>\]' || { echo "    task without runner.env should leave env untouched; got: $o"; return 1; }
}
check "task with no runner.env is a no-op" test_no_runner_is_noop

echo ""
echo "test_runner_env_direct: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
