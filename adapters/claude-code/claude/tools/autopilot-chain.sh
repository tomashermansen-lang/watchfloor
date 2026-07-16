#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Autopilot Chain — Plan-level DAG execution
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Usage:
#    autopilot-chain.sh [run|status] [options] [plan-dir]
#
#  Options:
#    --max-parallel N       Max concurrent tasks (default: 2)
#    --max-tasks N          Max total tasks to execute (default: unlimited)
#    --strict-gates         Always halt at gates regardless of check kind
#    --continue-on-failure  Continue past failures for independent tasks
#    --retry-failed         Clear failed_tasks from chain-state.json at start.
#                           Default: warn loudly that prior failures will be
#                           skipped, then proceed without retrying them.
#    --stop-after-phase <phase-name>
#                           Forward --stop-after-phase to every launched
#                           autopilot subprocess and halt the chain after the
#                           first per-task partial-summary exit. <phase-name>
#                           must be a member of PHASE_ORDER (sourced from
#                           lib/phase-selector.sh). Opt-in only; no env-var
#                           fallback.
#
#  Per-task runner overrides: each task's optional `task.runner` block
#  (schema: core/schema/execution-plan.schema.json $defs.task_runner) is
#  applied to the spawned autopilot.sh — env vars from `runner.env` are
#  exported subprocess-scoped; flags from `runner.flags` are appended to
#  the argv after chain-level flags and before the trailing task id.
#  Absent / empty runner is a no-op (byte-identical to the pre-feature
#  launch). Unknown CLI flags surface as chain_blocked
#  reason=unknown_runner_flag bad_flag=<F>.
#
#  Depends on: autopilot.sh (task executor), lib/merge-lock.sh (serialization)
#  State files (in plan-dir):
#    chain-state.json       Active/completed/failed task tracking
#    chain-events.ndjson    Append-only audit log
#    merge.lock             File lock for merge serialization
#    chain.PAUSE            Touch to pause chain after in-flight tasks
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CHAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/merge-lock.sh
source "${CHAIN_DIR}/lib/merge-lock.sh"
# shellcheck source=lib/worktree-reaper.sh
source "${CHAIN_DIR}/lib/worktree-reaper.sh"
# shellcheck source=lib/lifecycle-emit.sh
source "${CHAIN_DIR}/lib/lifecycle-emit.sh"
# shellcheck source=lib/phase-selector.sh
# Source phase-selector.sh so the chain can validate --stop-after-phase
# arguments against PHASE_ORDER and forward the flag to per-task
# autopilot subprocesses.
source "${CHAIN_DIR}/lib/phase-selector.sh"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "$@" >&2; }

# ── Parse arguments ──
ACTION="run"
MAX_PARALLEL=2
MAX_TASKS=999999  # effectively unlimited; 0 means dry-run
STRICT_GATES=false
CONTINUE_ON_FAILURE=false
RETRY_FAILED=false
STOP_AFTER_PHASE=""
_STOP_AFTER_PHASE_SEEN=false
PLAN_DIR=""

# Allow overriding autopilot.sh path for testing
AUTOPILOT_CMD="${AUTOPILOT_CMD:-bash ${CHAIN_DIR}/autopilot.sh}"

if [[ "${1:-}" == "status" || "${1:-}" == "run" ]]; then
  ACTION="$1"; shift
fi

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --max-parallel) MAX_PARALLEL="${2:?--max-parallel requires N}"; shift 2 ;;
    --max-tasks)    MAX_TASKS="${2:?--max-tasks requires N}"; shift 2 ;;
    --strict-gates) STRICT_GATES=true; shift ;;
    --continue-on-failure) CONTINUE_ON_FAILURE=true; shift ;;
    --retry-failed) RETRY_FAILED=true; shift ;;
    --stop-after-phase)
      # Explicit guard for exit-2 contract (R12 / C4.3) — bash's ${2:?msg}
      # exits 1, which violates the chain contract.
      if [[ $# -lt 2 ]]; then
        echo "Error: --stop-after-phase requires a phase name" >&2
        echo "Valid phases: ${PHASE_ORDER[*]}" >&2
        exit 2
      fi
      STOP_AFTER_PHASE="$2"; _STOP_AFTER_PHASE_SEEN=true; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Validate --stop-after-phase against PHASE_ORDER (R12 / C4.2). Exit 2
# on rejection; validate_phase_name returns 1 so `|| exit 2` lifts the
# code. The SEEN sentinel routes an explicit empty value through
# validation (R9-equivalent on the chain side).
if [[ "$_STOP_AFTER_PHASE_SEEN" == true ]]; then
  validate_phase_name "$STOP_AFTER_PHASE" || exit 2
fi

PLAN_DIR="${1:-}"

# ── Helpers ──

emit_event() {
  local event_file="$1"; shift
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  # Build JSON from key=value pairs
  local json="{\"ts\":\"$ts\""
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local val="${1#*=}"
    # Detect numeric values
    if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      json+=",\"$key\":$val"
    else
      # JSON-escape the value
      local escaped
      escaped=$(printf '%s' "$val" | jq -Rs '.' 2>/dev/null || printf '"%s"' "$val")
      json+=",\"$key\":$escaped"
    fi
    shift
  done
  json+="}"
  echo "$json" >> "$event_file"
}

get_tasks_json() {
  # Extract all tasks as JSON array from execution-plan.yaml
  local yaml_file="$1"
  python3 -c "
import yaml, json, sys
with open('$yaml_file') as f:
    data = yaml.safe_load(f)
tasks = []
for phase in data.get('phases', []):
    phase_id = phase.get('id', '')
    for task in phase.get('tasks', []):
        task['_phase_id'] = phase_id
        tasks.append(task)
print(json.dumps(tasks))
" 2>/dev/null
}

get_gates_json() {
  # Extract all gates as JSON array
  local yaml_file="$1"
  python3 -c "
import yaml, json
with open('$yaml_file') as f:
    data = yaml.safe_load(f)
gates = []
for phase in data.get('phases', []):
    gate = phase.get('gate')
    if gate:
        gate['_phase_id'] = phase.get('id', '')
        gates.append(gate)
print(json.dumps(gates))
" 2>/dev/null
}

compute_ready_set() {
  # Given tasks JSON + gates JSON, compute ready tasks
  # (pending + autopilot:true + all deps done + all preceding gates passed)
  local tasks_json="$1"
  local gates_json="${2:-[]}"
  printf '%s\n%s' "$tasks_json" "$gates_json" | python3 -c "
import json, sys
lines = sys.stdin.read().split('\n')
tasks = json.loads(lines[0])
gates = json.loads(lines[1]) if len(lines) > 1 and lines[1].strip() else []

done_ids = {t['id'] for t in tasks if t.get('status') in ('done', 'skipped')}

# Build phase order and gate-passed map
phase_ids = []
seen = set()
for t in tasks:
    pid = t.get('_phase_id', '')
    if pid and pid not in seen:
        phase_ids.append(pid)
        seen.add(pid)

gate_passed = {}
for g in gates:
    gate_passed[g.get('_phase_id', '')] = g.get('passed', False)

# A task is gate-blocked if ANY preceding phase has an unpassed gate
def preceding_gates_passed(task_phase_id):
    for pid in phase_ids:
        if pid == task_phase_id:
            break  # reached the task's own phase — all prior gates passed
        if pid in gate_passed and not gate_passed[pid]:
            return False
    return True

ready = []
for t in tasks:
    if t.get('status') != 'pending':
        continue
    if not t.get('autopilot', False):
        continue
    deps = t.get('depends', [])
    if not all(d in done_ids for d in deps):
        continue
    if not preceding_gates_passed(t.get('_phase_id', '')):
        continue
    ready.append(t['id'])
print(json.dumps(ready))
" 2>/dev/null
}

get_non_autopilot_pending() {
  # Find pending tasks that are not autopilot-eligible
  local tasks_json="$1"
  echo "$tasks_json" | python3 -c "
import json, sys
tasks = json.load(sys.stdin)
manual = []
for t in tasks:
    if t.get('status') == 'pending' and not t.get('autopilot', False):
        manual.append(t['id'])
print(json.dumps(manual))
" 2>/dev/null
}

get_blocked_by_manual() {
  # Find tasks blocked by manual prerequisites (transitively)
  local tasks_json="$1"
  echo "$tasks_json" | python3 -c "
import json, sys
tasks = json.load(sys.stdin)
done_ids = {t['id'] for t in tasks if t.get('status') in ('done', 'skipped')}
manual_ids = {t['id'] for t in tasks if t.get('status') == 'pending' and not t.get('autopilot', False)}
blocked = set()
def is_blocked(tid, visited=None):
    if visited is None: visited = set()
    if tid in visited: return False
    visited.add(tid)
    task = next((t for t in tasks if t['id'] == tid), None)
    if not task: return False
    for d in task.get('depends', []):
        if d in manual_ids or d in blocked or is_blocked(d, visited):
            blocked.add(tid)
            return True
    return False
for t in tasks:
    if t.get('status') == 'pending' and t.get('autopilot', False):
        is_blocked(t['id'])
print(json.dumps(sorted(blocked)))
" 2>/dev/null
}

get_blocked_by_failed() {
  # Find tasks transitively blocked by a failed task
  local tasks_json="$1" failed_ids_json="$2"
  printf '%s\n%s' "$tasks_json" "$failed_ids_json" | python3 -c "
import json, sys
lines = sys.stdin.read().split('\n')
tasks = json.loads(lines[0])
failed = set(json.loads(lines[1]))
blocked = set()
def is_blocked(tid, visited=None):
    if visited is None: visited = set()
    if tid in visited: return False
    visited.add(tid)
    task = next((t for t in tasks if t['id'] == tid), None)
    if not task: return False
    for d in task.get('depends', []):
        if d in failed or d in blocked or is_blocked(d, visited):
            blocked.add(tid)
            return True
    return False
for t in tasks:
    if t.get('status') == 'pending':
        is_blocked(t['id'])
print(json.dumps(sorted(blocked)))
" 2>/dev/null
}

check_phase_complete() {
  # Check if all tasks in a phase are done/skipped/failed
  local tasks_json="$1" phase_id="$2"
  echo "$tasks_json" | python3 -c "
import json, sys
tasks = json.load(sys.stdin)
phase_id = '$phase_id'
phase_tasks = [t for t in tasks if t.get('_phase_id') == phase_id]
if not phase_tasks:
    print('false')
else:
    all_terminal = all(t.get('status') in ('done', 'skipped', 'failed') for t in phase_tasks)
    all_failed = all(t.get('status') == 'failed' for t in phase_tasks)
    if all_failed:
        print('all_failed')
    elif all_terminal:
        print('true')
    else:
        print('false')
" 2>/dev/null
}

# ── Plan Discovery ──

discover_plan_dir() {
  if [[ -n "$PLAN_DIR" ]]; then
    if [[ ! -d "$PLAN_DIR" ]]; then
      log "${RED}ERROR:${NC} Plan directory not found: $PLAN_DIR"
      exit 1
    fi
    if [[ ! -f "$PLAN_DIR/execution-plan.yaml" ]]; then
      log "${RED}ERROR:${NC} execution-plan.yaml not found in: $PLAN_DIR"
      exit 1
    fi
    return
  fi

  # Auto-discover
  local plans=()
  while IFS= read -r -d '' f; do
    plans+=("$(dirname "$f")")
  done < <(find docs -maxdepth 2 -name "execution-plan.yaml" -path "*/INPROGRESS_Plan_*/*" -print0 2>/dev/null || true)

  if [[ ${#plans[@]} -eq 0 ]]; then
    log "${RED}ERROR:${NC} No plan found. Expected docs/INPROGRESS_Plan_*/execution-plan.yaml"
    exit 1
  elif [[ ${#plans[@]} -gt 1 ]]; then
    log "${RED}ERROR:${NC} Multiple plans found:"
    for p in "${plans[@]}"; do log "  - $p"; done
    log "Specify one: autopilot-chain.sh run <plan-dir>"
    exit 1
  fi

  PLAN_DIR="${plans[0]}"
}

# ── Status Command ──

run_status() {
  discover_plan_dir
  local yaml_file="$PLAN_DIR/execution-plan.yaml"
  local state_file="$PLAN_DIR/chain-state.json"

  local tasks_json
  tasks_json=$(get_tasks_json "$yaml_file")

  python3 -c "
import json, sys, yaml
from datetime import datetime

with open('$yaml_file') as f:
    data = yaml.safe_load(f)

# Derive tasks with phase IDs directly from YAML
tasks = []
for phase in data.get('phases', []):
    for t in phase.get('tasks', []):
        t['_phase_id'] = phase.get('id', '')
        tasks.append(t)

counts = {'pending': 0, 'wip': 0, 'done': 0, 'failed': 0, 'skipped': 0, 'blocked': 0}
current_phase = None
for t in tasks:
    s = t.get('status', 'pending')
    counts[s] = counts.get(s, 0) + 1
    if s in ('wip', 'pending') and current_phase is None:
        current_phase = t.get('_phase_id', '?')

# Read state for elapsed time
state = {}
try:
    with open('$state_file') as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    pass

elapsed = ''
if 'started_at' in state:
    try:
        start = datetime.fromisoformat(state['started_at'].replace('Z', '+00:00'))
        now = datetime.now(start.tzinfo) if start.tzinfo else datetime.now()
        delta = now - start
        hours, remainder = divmod(int(delta.total_seconds()), 3600)
        minutes, seconds = divmod(remainder, 60)
        elapsed = f'{hours}h {minutes}m {seconds}s'
    except (ValueError, TypeError):
        elapsed = 'unknown'

# Compute ready set (respecting phase gates)
done_ids = {t['id'] for t in tasks if t.get('status') in ('done', 'skipped')}
phase_ids = []
seen_phases = set()
for t in tasks:
    pid = t.get('_phase_id', '')
    if pid and pid not in seen_phases:
        phase_ids.append(pid)
        seen_phases.add(pid)
gate_passed = {}
for phase in data.get('phases', []):
    gate = phase.get('gate')
    if gate:
        gate_passed[phase.get('id', '')] = gate.get('passed', False)
def preceding_gates_ok(task_phase_id):
    for pid in phase_ids:
        if pid == task_phase_id:
            break
        if pid in gate_passed and not gate_passed[pid]:
            return False
    return True
ready = []
for t in tasks:
    if t.get('status') == 'pending' and t.get('autopilot', False):
        deps = t.get('depends', [])
        if all(d in done_ids for d in deps) and preceding_gates_ok(t.get('_phase_id', '')):
            ready.append(t['id'])

print(f'Completed: {counts[\"done\"]}')
print(f'Active:    {counts[\"wip\"]}')
print(f'Pending:   {counts[\"pending\"]}')
print(f'Failed:    {counts[\"failed\"]}')
print(f'Skipped:   {counts[\"skipped\"]}')
print(f'Blocked:   {counts[\"blocked\"]}')
if current_phase:
    print(f'Phase:     {current_phase}')
if elapsed:
    print(f'Elapsed:   {elapsed}')
if ready:
    print(f'Ready:     {\" \".join(ready)}')
else:
    print('Ready:     (none)')
"
}

# ── Run Command ──

run_chain() {
  discover_plan_dir
  # controls-07 #14 — tee stdout+stderr to a persistent log file in
  # the plan dir. start-system.sh redirects uvicorn stderr to
  # /dev/null and tmux pane scrollback is capped at 3000 lines, so
  # without this redirect a chain death leaves no recoverable trace
  # (observed multiple times during the controls-07 session). The
  # tee preserves the original stdout so the live tmux pane is
  # unaffected; the WS terminal viewer and per-task prefix all
  # continue to work.
  #
  # Defensive: process substitution opens /dev/fd/N to feed tee. In
  # restricted sandboxes (test runners under macOS Seatbelt) that
  # open can be blocked — `|| true` keeps the script alive without
  # the persistent log so the rest of the run still completes.
  exec > >(tee -a "$PLAN_DIR/chain-stdout.log") 2>&1 || true

  local yaml_file="$PLAN_DIR/execution-plan.yaml"
  local state_file="$PLAN_DIR/chain-state.json"
  local events_file="$PLAN_DIR/chain-events.ndjson"
  local lock_file="$PLAN_DIR/merge.lock"
  local pause_file="$PLAN_DIR/chain.PAUSE"

  # Guard: shlock required
  if ! command -v shlock &>/dev/null; then
    log "${RED}ERROR:${NC} shlock not found — required for merge serialization (ships with macOS)"
    exit 1
  fi

  # Guard: jq required
  if ! command -v jq &>/dev/null; then
    log "${RED}ERROR:${NC} jq not found — required for JSON processing"
    exit 1
  fi

  # Guard: --max-tasks 0 is a no-op
  if [[ "$MAX_TASKS" -eq 0 ]]; then
    log "max-tasks is 0 — exiting (dry-run)"
    exit 0
  fi

  # Crash recovery check
  if [[ -f "$state_file" ]]; then
    local state_valid
    state_valid=$(python3 -c "
import json, sys
try:
    with open('$state_file') as f:
        state = json.load(f)
    print('valid')
except (json.JSONDecodeError, ValueError):
    print('corrupt')
" 2>/dev/null)

    if [[ "$state_valid" == "corrupt" ]]; then
      log "${RED}ERROR:${NC} chain-state.json corrupt — delete to restart chain from plan state"
      exit 1
    fi

    # Check for active tasks from a previous run
    local active_check
    active_check=$(python3 -c "
import json, os, signal
with open('$state_file') as f:
    state = json.load(f)
active = state.get('active_tasks', [])
if not active:
    print('none')
else:
    for item in active:
        tid = item if isinstance(item, str) else item.get('id', '')
        pid = item.get('pid', 0) if isinstance(item, dict) else 0
        if pid > 0:
            try:
                os.kill(pid, 0)
                print(f'running:{tid}')
            except (OSError, ProcessLookupError):
                print(f'abandoned:{tid}')
        else:
            print(f'abandoned:{tid}')
" 2>/dev/null)

    while IFS= read -r line; do
      if [[ "$line" == running:* ]]; then
        local tid="${line#running:}"
        log "${RED}ERROR:${NC} chain already running — task '$tid' is still active"
        exit 1
      elif [[ "$line" == abandoned:* ]]; then
        local tid="${line#abandoned:}"
        log "${YELLOW}⚠${NC} Task '$tid' was abandoned (process terminated)"
        emit_event "$events_file" "event=task_failed" "task=$tid" "reason=abandoned — process terminated" "duration_s=0"
        # Clean up worktree if it exists
        if [[ ! "$tid" =~ ^[a-zA-Z0-9_-]+$ ]]; then
          log "WARNING: invalid task ID for cleanup: $tid"
          continue
        fi
        local wt_dir="${PLAN_DIR}/../../worktrees/feature-${tid}"
        if [[ -d "$wt_dir" ]]; then
          reap_worktree_orphans "$wt_dir"
          rm -rf "$wt_dir" 2>/dev/null || true
          git worktree prune 2>/dev/null || true
        fi
      fi
    done <<< "$active_check"

    # Reset state active_tasks
    python3 -c "
import json
with open('$state_file') as f:
    state = json.load(f)
state['active_tasks'] = []
with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true
  fi

  # Initialize state if needed
  if [[ ! -f "$state_file" ]]; then
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "{\"started_at\":\"$now\",\"max_parallel\":$MAX_PARALLEL,\"active_tasks\":[],\"completed_tasks\":[],\"failed_tasks\":[],\"blocked_tasks\":[]}" > "$state_file"
  fi

  # Blocked-tasks auto-resolution — reason-aware oracle per entry:
  #   merge_conflict / lock_timeout: resolved iff task.status=done in YAML
  #     (commit-finalize.sh's post-merge YAML update flipped status, OR
  #     the lock holder finished and committed status=done).
  #   dirty_main: resolved iff main is now clean (git status porcelain
  #     filtered for tracked changes is empty). Task was NEVER started,
  #     so resolution removes it from blocked_tasks WITHOUT adding to
  #     completed_tasks — the chain re-attempts it fresh on this run.
  #
  # CHAIN_MAIN_DIRTY_OVERRIDE env var (test seam): when set to "true"
  # or "false", overrides the git-based dirty check. Production uses the
  # git status check; tests set the override to avoid needing a real
  # git working tree in the test fixture. Unknown override values fall
  # through to the git check.
  local main_dirty_state="unknown"
  if [[ "${CHAIN_MAIN_DIRTY_OVERRIDE:-}" == "true" ]]; then
    main_dirty_state="true"
  elif [[ "${CHAIN_MAIN_DIRTY_OVERRIDE:-}" == "false" ]]; then
    main_dirty_state="false"
  elif command -v git &>/dev/null; then
    # Determine main repo dir: PLAN_DIR is somewhere inside the repo,
    # so git -C $PLAN_DIR rev-parse --show-toplevel returns the repo root.
    local _main_dir
    _main_dir=$(git -C "$PLAN_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_main_dir" ]]; then
      local _dirty
      _dirty=$(git -C "$_main_dir" status --porcelain 2>/dev/null | grep -v '^??' | head -1 || true)
      if [[ -n "$_dirty" ]]; then
        main_dirty_state="true"
      else
        main_dirty_state="false"
      fi
    fi
  fi
  export _CHAIN_MAIN_DIRTY_STATE="$main_dirty_state"

  python3 -c "
import json
import os
import yaml
import sys
state_file = '$state_file'
yaml_file = '$yaml_file'
main_dirty = os.environ.get('_CHAIN_MAIN_DIRTY_STATE', 'unknown')
with open(state_file) as f:
    state = json.load(f)
blocked = state.get('blocked_tasks', [])
if not blocked:
    sys.exit(0)
with open(yaml_file) as f:
    plan = yaml.safe_load(f)
status_by_id = {}
for phase in plan.get('phases', []):
    for task in phase.get('tasks', []):
        status_by_id[task.get('id')] = task.get('status')
resolved_done = []  # task IS done — move to completed_tasks
resolved_retry = []  # task was never started — just remove from blocked
still_blocked = []
for entry in blocked:
    if isinstance(entry, dict):
        tid = entry.get('id')
        reason = entry.get('reason', 'merge_conflict')
    else:
        # Backward-compat: old format was just task IDs as strings
        tid = entry
        reason = 'merge_conflict'

    if reason == 'dirty_main':
        # Resolved when main is clean (test override OR git check).
        # 'unknown' falls through to 'remove from blocked, let preflight
        # re-validate' — self-correcting if main is still dirty.
        if main_dirty == 'false':
            resolved_retry.append(tid)
        elif main_dirty == 'true':
            still_blocked.append(entry)
        else:
            # unknown — pessimistically keep blocked (don't loop)
            still_blocked.append(entry)
    else:
        # merge_conflict, lock_timeout, unknown reasons: task.status=done oracle.
        if status_by_id.get(tid) == 'done':
            resolved_done.append(tid)
        else:
            still_blocked.append(entry)

state['blocked_tasks'] = still_blocked
for tid in resolved_done:
    if tid not in state.get('completed_tasks', []):
        state.setdefault('completed_tasks', []).append(tid)
# resolved_retry: just removed from blocked_tasks; chain will re-attempt
with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
all_resolved = resolved_done + resolved_retry
if all_resolved:
    print('RESOLVED:' + ','.join(all_resolved))
if still_blocked:
    print('BLOCKED:' + ','.join(e.get('id') if isinstance(e, dict) else e for e in still_blocked))
" 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" == RESOLVED:* ]]; then
      local resolved_ids="${line#RESOLVED:}"
      log "${GREEN}✓${NC} Auto-resolved blocked task(s) — task.status=done detected:"
      for tid in ${resolved_ids//,/ }; do
        log "    - $tid"
      done
    elif [[ "$line" == BLOCKED:* ]]; then
      local blocked_ids="${line#BLOCKED:}"
      log "${YELLOW}⏸${NC}  Still-blocked task(s) — merge conflict not yet resolved:"
      for tid in ${blocked_ids//,/ }; do
        log "    - $tid"
      done
      log "  Resolve the merge manually, then re-run chain. See AUTOPILOT BLOCKED banner from prior run for the recovery command."
    fi
  done

  # If still-blocked entries exist after the auto-resolution pass, halt:
  # don't launch dependents on a partially-merged state.
  local still_blocked_count
  still_blocked_count=$(python3 -c "
import json
with open('$state_file') as f:
    print(len(json.load(f).get('blocked_tasks', [])))
" 2>/dev/null || echo "0")
  if [[ "$still_blocked_count" -gt 0 ]]; then
    log ""
    log "${BOLD}${YELLOW}Chain halted — $still_blocked_count blocked task(s) remain. Resolve and re-run.${NC}"
    log ""
    exit 0
  fi

  # Failed-tasks awareness — operators previously hit silent "nothing happens"
  # when restarting a chain whose chain-state.json had failed_tasks entries
  # from a prior run. compute_ready_set excludes those from the ready set, so
  # the chain found no work and exited via chain_completed without any
  # operator-visible signal. Now we either reset (with --retry-failed) or
  # warn loudly so the operator knows what to do.
  local existing_failed
  existing_failed=$(python3 -c "
import json
with open('$state_file') as f:
    print(' '.join(json.load(f).get('failed_tasks', [])))
" 2>/dev/null || echo "")
  existing_failed="${existing_failed## }"
  existing_failed="${existing_failed%% }"
  if [[ -n "$existing_failed" ]]; then
    local failed_count
    failed_count=$(echo "$existing_failed" | wc -w | tr -d ' ')
    if [[ "$RETRY_FAILED" == "true" ]]; then
      log "${YELLOW}⚠${NC} --retry-failed: clearing $failed_count failed task(s) from chain-state.json"
      for tid in $existing_failed; do
        log "    - $tid"
      done
      python3 -c "
import json
with open('$state_file') as f:
    state = json.load(f)
state['failed_tasks'] = []
with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
    else
      log "${YELLOW}⚠${NC} chain-state.json has $failed_count failed task(s) from a prior run — these will be SKIPPED:"
      for tid in $existing_failed; do
        log "    - $tid"
      done
      log "  Use --retry-failed to clear them and re-attempt."
    fi
  fi

  # Stale-stash check: commit-finalize.sh's defensive guard preserves the
  # pre-merge stash on conflict so the operator can recover manually. If
  # such stashes accumulate across runs they pollute `git stash list`
  # and may confuse future operators. Warn at chain start so the
  # operator can drop them with `git stash drop` before proceeding.
  # `grep -c` exits 1 when zero matches and prints "0"; the `|| echo 0`
  # then appends a SECOND "0" to stdout, producing the multiline value
  # "0\n0" that breaks `[[ ... -gt 0 ]]` arithmetic. Pipe through `head -1`
  # to keep only the count and silence the exit-1 path with `|| true`.
  local stale_stash_count
  stale_stash_count=$(cd "$(git -C "$PLAN_DIR" rev-parse --show-toplevel 2>/dev/null || echo .)" && git stash list 2>/dev/null | grep -c "autopilot-finalize: pre-merge stash" 2>/dev/null | head -1 || true)
  stale_stash_count="${stale_stash_count:-0}"
  if [[ "$stale_stash_count" =~ ^[0-9]+$ ]] && [[ "$stale_stash_count" -gt 0 ]]; then
    log "${YELLOW}⚠${NC} ${stale_stash_count} stale autopilot-finalize stash(es) detected — inspect with: git stash list"
    log "  Drop after verifying contents are not needed:  git stash drop stash@{0}"
  fi

  local tasks_launched=0
  local chain_start
  chain_start=$(date +%s)

  # Lifecycle wire-up — derive plan_id from PLAN_DIR basename and emit a
  # `started` lifecycle record. A plan_id that fails the validator regex
  # disables all three chain lifecycle emits (R8, AS9) — one stderr
  # warning per run. LAST_CHAIN_PHASE is initialised here so the paused
  # emit can echo the most-recently gate-passed phase id (or "unknown"
  # if no phase has completed yet in this run).
  PLAN_ID=$(basename "$PLAN_DIR")
  PLAN_ID="${PLAN_ID#INPROGRESS_Plan_}"
  PLAN_ID="${PLAN_ID#DONE_Plan_}"
  LIFECYCLE_DISABLED=""
  LAST_CHAIN_PHASE=""
  if ! _lifecycle_target_valid "$PLAN_ID"; then
    printf 'WARNING: chain plan_id %q fails target regex — lifecycle events disabled\n' "$PLAN_ID" >&2
    LIFECYCLE_DISABLED=1
  else
    lifecycle_emit_started "$events_file" "$PLAN_ID"
  fi

  # Track child PIDs for signal propagation
  CHILD_PIDS=()

  # Signal handler: propagate SIGTERM/SIGINT to all child autopilot processes.
  # The "${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}" idiom expands to nothing when the
  # array is empty — necessary because bash 3.2 (macOS default) treats
  # "${CHILD_PIDS[@]}" on an empty array as unbound under `set -u`. Without
  # this, Ctrl-C during early chain startup raises a confusing
  # "CHILD_PIDS[@]: unbound variable" instead of running cleanup.
  cleanup_chain() {
    log "${YELLOW}⚠${NC} Chain interrupted — killing child processes..."
    for pid in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        log "  Sent SIGTERM to PID $pid"
      fi
    done
    # Give children 5 seconds to exit gracefully
    sleep 5
    for pid in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        log "  Force-killed PID $pid"
      fi
    done
    # Clean up caffeinate
    [[ -n "${caffeinate_pid:-}" ]] && kill "$caffeinate_pid" 2>/dev/null || true
    log "Chain stopped."
    exit 1
  }
  trap cleanup_chain SIGTERM SIGINT

  # Wrap in caffeinate to prevent macOS sleep.
  #
  # Redirect caffeinate's stdout/stderr to /dev/null so it does NOT
  # inherit run_chain's FD 1 — the `exec > >(tee …)` pipe write-end
  # (see line ~464). Without this, the backgrounded caffeinate holds
  # the tee pipe open; on the early `exit` branches (chain_blocked /
  # stop-after-phase / failure-halt) the end-of-main-loop
  # `kill "$caffeinate_pid"` is never reached, so in bash 3.2 the shell
  # blocks forever at exit waiting for tee to receive EOF (the chain
  # finishes its work, prints "Chain run complete" on the normal path,
  # but the process never returns to its caller). Detaching caffeinate
  # from the pipe makes tee receive EOF as soon as run_chain's own FDs
  # close, on every exit path. `-w $$` still self-terminates caffeinate
  # when this shell dies, so no process is leaked.
  local caffeinate_pid=""
  if command -v caffeinate &>/dev/null; then
    caffeinate -s -w $$ >/dev/null 2>&1 &
    caffeinate_pid=$!
  fi

  # Sliding-window scheduler state
  # ACTIVE_SLOTS entries: "pid:task_id:task_start"
  local ACTIVE_SLOTS=()
  local FAILED_TASKS=()
  local POLL_INTERVAL=2
  # PAUSE_REQUESTED: latched once chain.PAUSE is observed. Switches the
  # main loop to "no new launches" mode. The loop continues to poll +
  # harvest in-flight tasks via the normal harvest block (so
  # task_completed / task_failed / task_blocked / chain_stopped events
  # are still emitted and chain-state.json + execution-plan.yaml stay
  # consistent); chain_paused fires once ACTIVE_SLOTS drains to zero.
  # Replaces the pre-2026-05-21 `wait $pid` + bare exit drain that
  # silently skipped harvest, leaving completed tasks in active_tasks
  # and breaking dashboard resume.
  local PAUSE_REQUESTED=false

  # Resume-aware gate evaluation: catch any phase whose tasks all completed
  # in a previous chain run but whose gate was never evaluated (e.g. when
  # the previous run paused via chain.PAUSE or crashed after a task done
  # before the gate-eval step at the end of the main-loop iteration).
  evaluate_pending_phase_gates "$yaml_file" "$events_file"

  # Main loop — sliding window over max_parallel slots
  while true; do
    # Re-read plan (may have been updated by completed tasks)
    local tasks_json
    tasks_json=$(get_tasks_json "$yaml_file")

    # Compute ready set
    local ready_json
    local gates_json
    gates_json=$(get_gates_json "$yaml_file")
    ready_json=$(compute_ready_set "$tasks_json" "$gates_json")

    # Apply chain-state.json exclusion BEFORE the terminal check.
    # compute_ready_set filters by plan-status='pending', but a task may
    # also be in active_tasks / completed_tasks / failed_tasks in
    # chain-state.json — chain-state.json is the authoritative record
    # of orchestrator-level completion (see comment block before launch
    # phase below for the race-condition rationale).
    #
    # Without applying this filter pre-terminal, a task that is plan-
    # status=pending but chain-state.json=failed produces the silent
    # hang reported on 2026-05-05: pre-filter ready_count > 0 → terminal
    # check fails → post-filter ready_count = 0 → no launches → falls
    # through to `sleep 1; continue` at the polling stage → loops forever
    # without emitting any event. Operator sees "nothing happens".
    local active_ids_json="[]"
    if [[ ${#ACTIVE_SLOTS[@]} -gt 0 ]]; then
      local _aids=()
      for entry in "${ACTIVE_SLOTS[@]}"; do
        local rest="${entry#*:}"
        _aids+=("${rest%%:*}")
      done
      active_ids_json=$(printf '%s\n' "${_aids[@]}" | python3 -c "
import json, sys
print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))
")
    fi
    ready_json=$(python3 -c "
import json
ready = json.loads('''$ready_json''')
active = set(json.loads('''$active_ids_json'''))
try:
    with open('$state_file') as f:
        state = json.load(f)
    done = set(state.get('completed_tasks', []))
    failed = set(state.get('failed_tasks', []))
except Exception:
    done = set()
    failed = set()
exclude = active | done | failed
print(json.dumps([t for t in ready if t not in exclude]))
")
    local ready_count
    ready_count=$(echo "$ready_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)

    # Log non-autopilot tasks (once per loop — noisy but informative)
    local manual_json
    manual_json=$(get_non_autopilot_pending "$tasks_json")
    local manual_count
    manual_count=$(echo "$manual_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
    if [[ "$manual_count" -gt 0 && "${#ACTIVE_SLOTS[@]}" -eq 0 ]]; then
      echo "$manual_json" | python3 -c "
import json, sys
for tid in json.load(sys.stdin):
    print(f'  requires manual execution: {tid}')
" 2>/dev/null | while IFS= read -r line; do log "$line"; done
    fi

    # Terminal condition: no ready AND nothing running
    if [[ "$ready_count" -eq 0 && "${#ACTIVE_SLOTS[@]}" -eq 0 ]]; then
      local all_done
      all_done=$(echo "$tasks_json" | python3 -c "
import json, sys
tasks = json.load(sys.stdin)
pending = [t for t in tasks if t.get('status') == 'pending']
done = [t for t in tasks if t.get('status') in ('done', 'skipped')]
failed = [t for t in tasks if t.get('status') == 'failed']
if not pending and not failed:
    print('complete')
elif failed:
    print('failed')
elif pending:
    print('blocked')
else:
    print('unknown')
" 2>/dev/null)

      case "$all_done" in
        complete)
          log "${GREEN}✓${NC} No ready tasks — plan complete or all remaining tasks are manual/blocked"
          local elapsed_s=$(( $(date +%s) - chain_start ))
          emit_event "$events_file" "event=chain_completed" "completed_count=$tasks_launched" "failed_count=${#FAILED_TASKS[@]}" "elapsed_s=$elapsed_s"
          ;;
        failed)
          log "${YELLOW}⚠${NC} No ready tasks — some tasks failed, dependents are blocked"
          ;;
        blocked)
          log "${YELLOW}⚠${NC} No ready tasks — check for circular dependencies or unmet manual prerequisites"
          ;;
      esac
      break
    fi

    # Pause detection — idempotent. Once chain.PAUSE is observed, latch
    # PAUSE_REQUESTED=true so the launch gate below skips new launches.
    # Any in-flight tasks continue through their normal harvest path
    # (state-file updates + task_completed / task_failed / task_blocked
    # / chain_stopped events all preserved). Exit fires below once
    # ACTIVE_SLOTS drains to zero.
    if [[ -f "$pause_file" && "$PAUSE_REQUESTED" != "true" ]]; then
      log "${YELLOW}⚠${NC} chain pause requested — will drain in-flight tasks and exit"
      log "  remove chain.PAUSE to cancel the pause request"
      PAUSE_REQUESTED=true
    fi

    # Pause-exit: paused + no in-flight tasks → emit chain_paused, exit.
    # Comes AFTER the terminal-condition check above so a clean completion
    # under a stray chain.PAUSE still emits chain_completed (terminal wins
    # over pause when the plan is genuinely done).
    if [[ "$PAUSE_REQUESTED" == "true" && "${#ACTIVE_SLOTS[@]}" -eq 0 ]]; then
      log "${YELLOW}⚠${NC} chain paused — in-flight drain complete, exiting"
      emit_event "$events_file" "event=chain_paused"
      if [[ -z "${LIFECYCLE_DISABLED:-}" ]]; then
        lifecycle_emit_paused "$events_file" "${PLAN_ID:-}" "${LAST_CHAIN_PHASE:-unknown}"
      fi
      exit 0
    fi

    # Check max-tasks budget (only blocks new launches — running tasks finish)
    local budget_exhausted=false
    if [[ "$tasks_launched" -ge "$MAX_TASKS" ]]; then
      budget_exhausted=true
    fi

    # Note: ready_json was already filtered against chain-state.json
    # (active_tasks, completed_tasks, failed_tasks) before the terminal
    # check above. The filter was relocated up to ensure the terminal
    # condition sees the post-filter count — otherwise a task that is
    # plan-status=pending but chain-state.json=failed produces a silent
    # infinite loop (observed 2026-05-05 on feature-plan-link-and-nav).
    # The completed-task filter rationale (RETRO Deviation 11 redux:
    # task_completed → spurious task_started 1s later → second instance
    # pre-flight fails because main is now post-merge → chain halts;
    # observed for deviation-heuristic-lib at 14:12:50/14:12:51 on
    # 2026-05-03) is preserved by the up-front filter.

    # Launch phase: fill free slots if we have ready tasks and budget.
    # When PAUSE_REQUESTED is latched, skip launches — the loop continues
    # to poll + harvest in-flight slots until ACTIVE_SLOTS drains, then
    # the pause-exit check above fires.
    local free_slots=$(( MAX_PARALLEL - ${#ACTIVE_SLOTS[@]} ))
    (( free_slots < 0 )) && free_slots=0
    local launch_count=0
    if [[ "$budget_exhausted" == false && "$ready_count" -gt 0 && "$free_slots" -gt 0 && "$PAUSE_REQUESTED" != "true" ]]; then
      local remaining=$(( MAX_TASKS - tasks_launched ))
      launch_count=$(echo "$ready_json" | python3 -c "
import json, sys
ready = json.load(sys.stdin)
print(min(len(ready), $free_slots, $remaining))
" 2>/dev/null)
    fi

    if [[ "$launch_count" -gt 0 ]]; then
      local batch_ids
      batch_ids=$(echo "$ready_json" | python3 -c "
import json, sys
ready = json.load(sys.stdin)
print(json.dumps(ready[:$launch_count]))
" 2>/dev/null)

      log "${CYAN}━━━${NC} Launching: $(echo "$batch_ids" | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin)))' 2>/dev/null)"

      for task_id in $(echo "$batch_ids" | python3 -c "import json,sys; [print(t) for t in json.load(sys.stdin)]" 2>/dev/null); do
        export CHAIN_MERGE_LOCK="$lock_file"

        local task_pipeline
        task_pipeline=$(python3 -c "
import yaml, sys
with open('$yaml_file') as f:
    data = yaml.safe_load(f)
for phase in data.get('phases', []):
    for t in phase.get('tasks', []):
        if t.get('id') == '$task_id':
            print(t.get('pipeline', 'full'))
            sys.exit()
print('full')
" 2>/dev/null)
        task_pipeline="${task_pipeline:-full}"

        # Component A — load task.runner.flags + task.runner.env (R1).
        # Emits four lines: flags_json, env_json, flag_count, env_count.
        # Returning counts from the same python invocation keeps the
        # per-task launch overhead at a single python3 startup (a
        # second invocation per task pushes the parallel-launch test
        # past its 3 s budget on hot hardware). Errors are swallowed
        # silently to preserve the zero-regression contract for
        # malformed YAML (Q6 / R-RISK-3 — operator must run
        # validate-plan.py before the chain).
        local runner_lookup runner_flags_json runner_env_json runner_flag_count runner_env_count
        runner_lookup=$(python3 -c "
import yaml, json, sys
with open('$yaml_file') as f:
    data = yaml.safe_load(f)
for phase in data.get('phases', []):
    for t in phase.get('tasks', []):
        if t.get('id') == '$task_id':
            r = t.get('runner') if isinstance(t.get('runner'), dict) else {}
            flags = r.get('flags') if isinstance(r.get('flags'), list) else []
            env = r.get('env') if isinstance(r.get('env'), dict) else {}
            print(json.dumps(flags))
            print(json.dumps(env))
            print(len(flags))
            print(len(env))
            sys.exit()
print('[]')
print('{}')
print(0)
print(0)
" 2>/dev/null)
        runner_flags_json=$(printf '%s\n' "$runner_lookup" | sed -n '1p')
        runner_env_json=$(printf '%s\n' "$runner_lookup" | sed -n '2p')
        runner_flag_count=$(printf '%s\n' "$runner_lookup" | sed -n '3p')
        runner_env_count=$(printf '%s\n' "$runner_lookup" | sed -n '4p')
        runner_flags_json="${runner_flags_json:-[]}"
        # Bash parameter expansion `${var:-default}` ends at the FIRST `}`
        # after `${`, so `${var:-{}}` is parsed as `${var:-{}` + literal
        # `}`. When the variable is EMPTY the result is `{` + `}` = `{}`
        # (which looks correct), but when SET the result is the value
        # followed by an extra literal `}` — e.g.
        # `{"LOCAL_LLM_ROUTING":"1"}` becomes `{"LOCAL_LLM_ROUTING":"1"}}`.
        # That mangled string still failed the downstream `!= "{}"` guard
        # (so the env-prefix block ran), but `python3 -c "json.load(...)"`
        # got the trailing `}` as garbage and exited 1 silently, leaving
        # `runner_env_prefix=(env)` with no key=value tokens, so no env
        # vars reached the spawned autopilot. The earlier `{\}` form had
        # the opposite bug (left literal backslashes on the empty path).
        # Conditional assignment sidesteps both — kept verbose because
        # this exact line burned 76 turns + $8.61 in QA pass 2026-05-22.
        [[ -z "${runner_env_json:-}" ]] && runner_env_json="{}"
        runner_flag_count="${runner_flag_count:-0}"
        runner_env_count="${runner_env_count:-0}"

        log "  Starting: $task_id (pipeline: $task_pipeline)"

        local task_start
        task_start=$(date +%s)

        # Wrap task to record exit code (bash 3.2 auto-reaps bg jobs so wait $pid fails after death)
        # set +e inside subshell so non-zero autopilot exit doesn't skip the write
        # controls-07 #13 — prefix every stdout/stderr line with `[task_id] `
        # so the chain orchestrator's tmux pane is filterable per task when
        # N autopilots run in parallel. PIPESTATUS[0] preserves the original
        # autopilot exit code despite the sed pipe (default $? would be sed's).
        local exit_file="${PLAN_DIR}/.chain-exit-${task_id}"
        rm -f "$exit_file" 2>/dev/null || true
        # Build the per-task argv as an array so --stop-after-phase
        # can be forward-appended without quoting bugs. AUTOPILOT_CMD
        # is intentionally word-split (e.g. "bash /path/script.sh").
        local autopilot_args=(--full --pipeline "$task_pipeline")
        if [[ -n "$STOP_AFTER_PHASE" ]]; then
          autopilot_args+=(--stop-after-phase "$STOP_AFTER_PHASE")
        fi
        # Component B — runner.flags append (R2). Each JSON-list entry
        # becomes one argv token, including empty strings (T-EC14). The
        # python helper emits one line per flag; `IFS=` + `read -r`
        # preserves leading/trailing whitespace within a single token.
        if [[ "$runner_flags_json" != "[]" ]]; then
          while IFS= read -r runner_flag; do
            autopilot_args+=("$runner_flag")
          done < <(printf '%s' "$runner_flags_json" | python3 -c "
import json, sys
for f in json.load(sys.stdin):
    print(f)
")
        fi
        autopilot_args+=("$task_id")

        # Component B — runner.env injection (R3, R4, R5). The env-prefix
        # is built as a bash ARRAY so element atomicity preserves shell
        # metacharacters in values (AS12). Empty array → zero argv tokens
        # via the `+expand-if-set` idiom, preserving byte-identical
        # pre-feature semantics for R6/R7.
        #
        # The `local -a … =()` declaration sits INSIDE the per-task for
        # loop on purpose: in bash 3.2 `local` scopes to the enclosing
        # function (not the loop iteration), so the `=()` reinitialiser
        # is what resets the array on every iteration. If this line is
        # ever hoisted out of the loop the per-task reset disappears
        # silently and the previous task's env prefix leaks into the
        # next launch (regression on R4 subprocess-scoping). See QA pass
        # 2026-05-22 — `runner_env_prefix` MUST stay inside the loop body.
        local -a runner_env_prefix=()
        if [[ "$runner_env_json" != "{}" ]]; then
          runner_env_prefix=(env)
          while IFS= read -r runner_pair; do
            [[ -n "$runner_pair" ]] && runner_env_prefix+=("$runner_pair")
          done < <(printf '%s' "$runner_env_json" | python3 -c "
import json, sys
for k, v in json.load(sys.stdin).items():
    print('{}={}'.format(k, v))
")
        fi

        # R29 — log counts (never values). Emitted only when at least
        # one of env or flags is non-empty so the zero-regression path
        # keeps the existing log noise level.
        if (( runner_flag_count > 0 || runner_env_count > 0 )); then
          log "  Runner overrides for $task_id: env=$runner_env_count, flags=$runner_flag_count"
        fi

        (
          set +e
          # shellcheck disable=SC2086
          "${runner_env_prefix[@]+"${runner_env_prefix[@]}"}" $AUTOPILOT_CMD "${autopilot_args[@]}" 2>&1 | sed "s/^/[${task_id}] /"
          echo "${PIPESTATUS[0]}" > "$exit_file"
        ) &
        local pid=$!
        CHILD_PIDS+=("$pid")
        ACTIVE_SLOTS+=("$pid:$task_id:$task_start")
        emit_event "$events_file" "event=task_started" "task=$task_id" "pid=$pid"

        python3 -c "
import json
with open('$state_file') as f:
    state = json.load(f)
state['active_tasks'].append({'id': '$task_id', 'pid': $pid})
with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true

        tasks_launched=$((tasks_launched + 1))
      done
    fi

    # If budget exhausted and no active slots, stop
    if [[ "$budget_exhausted" == true && "${#ACTIVE_SLOTS[@]}" -eq 0 ]]; then
      log "max-tasks limit reached ($MAX_TASKS) — stopping"
      break
    fi

    # Nothing active? Loop to recompute (avoids busy-spin on edge case)
    if [[ "${#ACTIVE_SLOTS[@]}" -eq 0 ]]; then
      sleep 1
      continue
    fi

    # Poll for any completed slot. Pause is NOT checked inside this
    # tight poll loop — the outer loop's pause-detect block at the top
    # handles it, so a chain.PAUSE that appears mid-poll is honoured at
    # the next outer iteration, but only AFTER the in-flight task has
    # been harvested normally (see PAUSE_REQUESTED commentary above).
    local completed_idx=-1
    while [[ "$completed_idx" -eq -1 ]]; do

      for i in "${!ACTIVE_SLOTS[@]}"; do
        local entry="${ACTIVE_SLOTS[$i]}"
        local pid="${entry%%:*}"
        if ! kill -0 "$pid" 2>/dev/null; then
          completed_idx=$i
          break
        fi
      done

      if [[ "$completed_idx" -eq -1 ]]; then
        sleep "$POLL_INTERVAL"
      fi
    done

    # Harvest the completed slot
    local completed_entry="${ACTIVE_SLOTS[$completed_idx]}"
    local completed_pid="${completed_entry%%:*}"
    local rest="${completed_entry#*:}"
    local completed_task_id="${rest%%:*}"
    local completed_task_start="${rest#*:}"

    # Read exit code from wrapper file (bash 3.2 has already reaped the pid)
    local exit_file="${PLAN_DIR}/.chain-exit-${completed_task_id}"
    local exit_code=1
    if [[ -f "$exit_file" ]]; then
      exit_code=$(cat "$exit_file" 2>/dev/null || echo 1)
      rm -f "$exit_file" 2>/dev/null || true
    fi

    local duration=$(( $(date +%s) - completed_task_start ))

    # Remove from ACTIVE_SLOTS (bash 3.2-safe rebuild)
    local new_slots=()
    for i in "${!ACTIVE_SLOTS[@]}"; do
      if [[ "$i" -ne "$completed_idx" ]]; then
        new_slots+=("${ACTIVE_SLOTS[$i]}")
      fi
    done
    ACTIVE_SLOTS=("${new_slots[@]+"${new_slots[@]}"}")

    # Remove from CHILD_PIDS
    local new_child_pids=()
    for p in "${CHILD_PIDS[@]}"; do
      [[ "$p" != "$completed_pid" ]] && new_child_pids+=("$p")
    done
    CHILD_PIDS=("${new_child_pids[@]+"${new_child_pids[@]}"}")

    emit_event "$events_file" "event=slot_released" "pid=$completed_pid" "task=$completed_task_id"

    # Remove from state.active_tasks
    python3 -c "
import json
with open('$state_file') as f:
    state = json.load(f)
state['active_tasks'] = [t for t in state['active_tasks'] if t.get('id') != '$completed_task_id']
with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true

    if [[ "$exit_code" -eq 0 ]]; then
      log "  ${GREEN}✓${NC} Completed: $completed_task_id (${duration}s)"
      emit_event "$events_file" "event=task_completed" "task=$completed_task_id" "duration_s=$duration"
      python3 -c "
import json
with open('$state_file') as f:
    state = json.load(f)
state['completed_tasks'].append('$completed_task_id')
with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true

      # --stop-after-phase harvest-time detection (R14, R15, R28, AS6, AS7).
      # When the per-task autopilot subprocess exits 0 with a partial
      # summary, halt the chain after draining any in-flight slots.
      # Guarded by STOP_AFTER_PHASE so the default chain path (R16, AS8)
      # is byte-identical — no python3 invocation when the flag is unset.
      if [[ -n "$STOP_AFTER_PHASE" ]]; then
        local task_summary="${PLAN_DIR}/../../worktrees/feature-${completed_task_id}/docs/INPROGRESS_Feature_${completed_task_id}/autopilot-summary.json"
        if [[ -f "$task_summary" ]] && \
           python3 -c "import json,sys; sys.exit(0 if json.load(open('$task_summary')).get('status')=='partial' else 1)" 2>/dev/null; then
          log "${YELLOW}⏸${NC} Stop-after-phase detected — chain halting"
          emit_event "$events_file" "event=chain_stopped" "reason=stop_after_phase" \
            "phase=$STOP_AFTER_PHASE" "feature_id=$completed_task_id"
          if [[ -z "${LIFECYCLE_DISABLED:-}" ]]; then
            lifecycle_emit_paused "$events_file" "${PLAN_ID:-}" "$STOP_AFTER_PHASE"
          fi
          # Drain remaining in-flight slots (chain.PAUSE symmetry, Q3).
          for entry in "${ACTIVE_SLOTS[@]+"${ACTIVE_SLOTS[@]}"}"; do
            local p="${entry%%:*}"
            wait "$p" 2>/dev/null || true
          done
          exit 0
        fi
      fi
    elif [[ "$exit_code" -eq 2 ]]; then
      # Blocked — operator-resolvable condition. Three known reasons:
      #   - merge_conflict: phase work done, only merge needs resolving
      #   - lock_timeout: another finalize is holding merge.lock too long
      #   - dirty_main: preflight detected uncommitted changes on main
      # The reason is communicated via a sentinel file written by
      # autopilot.sh's _write_chain_blocked_reason. Default to
      # 'merge_conflict' for backward compat with older autopilot
      # versions that didn't write a sentinel.
      local blocked_reason="merge_conflict"
      local bad_flag=""
      local reason_file="${PLAN_DIR}/.chain-blocked-reason-${completed_task_id}"
      if [[ -f "$reason_file" ]]; then
        local read_reason
        read_reason=$(head -1 "$reason_file" 2>/dev/null | tr -d '\n')
        # Whitelist known reasons — never trust unvalidated sentinel content.
        case "$read_reason" in
          merge_conflict|lock_timeout|dirty_main)
            blocked_reason="$read_reason" ;;
          unknown_runner_flag:*)
            blocked_reason="unknown_runner_flag"
            bad_flag="${read_reason#unknown_runner_flag:}" ;;
          *) ;;  # unknown reason — keep default
        esac
        rm -f "$reason_file" 2>/dev/null || true
      fi

      # Component D2 — unknown_runner_flag halt path (R14, R15, R16, R-RISK-8).
      # Emit chain_blocked (NOT task_blocked — that would double-count per
      # R-RISK-8), drain in-flight slots like the --stop-after-phase exit
      # path, and exit 1. This branch fires BEFORE the task_blocked emit
      # below so the unknown-flag path never produces a task_blocked event.
      if [[ "$blocked_reason" == "unknown_runner_flag" ]]; then
        emit_event "$events_file" "event=chain_blocked" \
          "reason=unknown_runner_flag" \
          "task_id=$completed_task_id" \
          "bad_flag=$bad_flag"
        log ""
        log "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        log "${BOLD}${YELLOW}║  ⏸  CHAIN PAUSED — misconfigured runner.flags in plan"
        log "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        log "${YELLOW}║  Task: $completed_task_id"
        log "${YELLOW}║  Bad flag: $bad_flag"
        log "${YELLOW}║"
        log "${YELLOW}║  Fix: remove or correct the runner.flags entry in the"
        log "${YELLOW}║  plan YAML, then re-run autopilot-chain.sh."
        log "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
        log ""
        # Drain remaining in-flight slots (mirror --stop-after-phase semantic).
        for entry in "${ACTIVE_SLOTS[@]+"${ACTIVE_SLOTS[@]}"}"; do
          local p="${entry%%:*}"
          wait "$p" 2>/dev/null || true
        done
        exit 1
      fi

      log "  ${YELLOW}⏸${NC}  Blocked: $completed_task_id (${duration}s) — $blocked_reason"
      emit_event "$events_file" "event=task_blocked" "task=$completed_task_id" "reason=$blocked_reason" "duration_s=$duration"
      python3 -c "
import json
with open('$state_file') as f:
    state = json.load(f)
state.setdefault('blocked_tasks', []).append({
    'id': '$completed_task_id',
    'reason': '$blocked_reason',
    'ts': '$(date -u '+%Y-%m-%dT%H:%M:%SZ')',
})
with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true

      log ""
      log "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
      if [[ "$blocked_reason" == "dirty_main" ]]; then
        log "${BOLD}${YELLOW}║  ⏸  CHAIN PAUSED — main has uncommitted changes"
        log "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        log "${YELLOW}║  Task: $completed_task_id"
        log "${YELLOW}║  No phase work was started — worktree was cleaned up."
        log "${YELLOW}║"
        log "${YELLOW}║  Operator action: commit, stash, or revert the dirty"
        log "${YELLOW}║  files on main (see preflight output above for paths)."
        log "${YELLOW}║  Then re-run chain — no flag needed:"
        log "${YELLOW}║    bash ~/.claude/tools/autopilot-chain.sh run $PLAN_DIR"
        log "${YELLOW}║"
        log "${YELLOW}║  Chain auto-detects clean main via git status and"
        log "${YELLOW}║  re-attempts the task fresh."
      elif [[ "$blocked_reason" == "lock_timeout" ]]; then
        log "${BOLD}${YELLOW}║  ⏸  CHAIN PAUSED — merge.lock timeout in $completed_task_id"
        log "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        log "${YELLOW}║  Another finalize was holding the merge lock longer than"
        log "${YELLOW}║  MERGE_LOCK_MAX_WAIT (default 300s). Likely network"
        log "${YELLOW}║  degradation or a stuck parallel chain run."
        log "${YELLOW}║"
        log "${YELLOW}║  Investigate, then re-run chain — no flag needed:"
        log "${YELLOW}║    bash ~/.claude/tools/autopilot-chain.sh run $PLAN_DIR"
        log "${YELLOW}║"
        log "${YELLOW}║  Chain auto-detects task.status=done (when the lock"
        log "${YELLOW}║  holder eventually finishes) and continues."
      else
        # merge_conflict (default)
        log "${BOLD}${YELLOW}║  ⏸  CHAIN PAUSED — merge conflict in $completed_task_id"
        log "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        log "${YELLOW}║  All phase work landed on feature/${completed_task_id}"
        log "${YELLOW}║  but the merge to main needs human intervention."
        log "${YELLOW}║"
        log "${YELLOW}║  Resolve manually, then re-run chain — no flag needed:"
        log "${YELLOW}║    bash ~/.claude/tools/autopilot-chain.sh run $PLAN_DIR"
        log "${YELLOW}║"
        log "${YELLOW}║  Chain auto-detects resolution via task.status=done"
        log "${YELLOW}║  in execution-plan.yaml and continues with remaining tasks."
      fi
      log "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
      log ""

      # Halt chain — don't continue to dependent tasks until operator resolves.
      local elapsed_s=$(( $(date +%s) - chain_start ))
      emit_event "$events_file" "event=chain_blocked" "blocked_count=1" "reason=$blocked_reason" "elapsed_s=$elapsed_s"
      break
    else
      local reason="exit code $exit_code"
      local summary_file
      for search_dir in "worktrees/feature-${completed_task_id}" "." ; do
        summary_file="${search_dir}/docs/INPROGRESS_Feature_${completed_task_id}/autopilot-summary.json"
        if [[ -f "$summary_file" ]]; then
          local sr
          sr=$(python3 -c "import json; d=json.load(open('$summary_file')); print(d.get('failure_reason', d.get('status', '')))" 2>/dev/null || true)
          [[ -n "$sr" ]] && reason="$sr"
          break
        fi
      done

      log "  ${RED}✗${NC} Failed: $completed_task_id ($reason)"
      emit_event "$events_file" "event=task_failed" "task=$completed_task_id" "reason=$reason" "duration_s=$duration"
      python3 -c "
import json
with open('$state_file') as f:
    state = json.load(f)
state['failed_tasks'].append('$completed_task_id')
with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true
      FAILED_TASKS+=("$completed_task_id")

      if [[ "$CONTINUE_ON_FAILURE" == true ]]; then
        # Mark transitive dependents as blocked (logged only)
        local failed_json
        failed_json=$(printf '%s' "$completed_task_id" | python3 -c "import json,sys; print(json.dumps([sys.stdin.read()]))" 2>/dev/null)
        local blocked_json
        tasks_json=$(get_tasks_json "$yaml_file")
        blocked_json=$(get_blocked_by_failed "$tasks_json" "$failed_json")
        local blocked_count
        blocked_count=$(echo "$blocked_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
        if [[ "$blocked_count" -gt 0 ]]; then
          log "${YELLOW}⚠${NC} Blocked by failure: $(echo "$blocked_json" | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin)))' 2>/dev/null)"
        fi
      else
        log "${RED}✗${NC} Chain halted due to task failure"
        # Drain remaining active tasks
        for entry in "${ACTIVE_SLOTS[@]+"${ACTIVE_SLOTS[@]}"}"; do
          local p="${entry%%:*}"
          wait "$p" 2>/dev/null || true
        done
        local elapsed_s=$(( $(date +%s) - chain_start ))
        emit_event "$events_file" "event=chain_completed" "completed_count=$tasks_launched" "failed_count=${#FAILED_TASKS[@]}" "elapsed_s=$elapsed_s"
        exit 1
      fi
    fi

    # Re-evaluate gates (unchanged from batch-wait design)
    evaluate_pending_phase_gates "$yaml_file" "$events_file"

  done  # main loop

  # Clean up caffeinate
  if [[ -n "$caffeinate_pid" ]]; then
    kill "$caffeinate_pid" 2>/dev/null || true
  fi

  log "${GREEN}✓${NC} Chain run complete"
}

# ── Gate Evaluation ──

# evaluate_pending_phase_gates yaml_file events_file
#
# Find phases where all tasks are terminal (done/skipped/failed, but not
# all failed) and the phase gate is not yet passed=true, then evaluate
# them. Idempotent — already-passed gates are skipped.
#
# Called both at chain start (catches resume-after-pause cases where a
# phase completed in the previous run but its gate was never evaluated)
# and after each task completion in the main loop.
evaluate_pending_phase_gates() {
  local yaml_file="$1" events_file="$2"

  local tasks_json gates_json
  tasks_json=$(get_tasks_json "$yaml_file")
  gates_json=$(get_gates_json "$yaml_file")

  local gate_check_output
  gate_check_output=$(printf '%s\n%s' "$tasks_json" "$gates_json" | python3 -c "
import json, sys
lines = sys.stdin.read().split('\n')
tasks = json.loads(lines[0])
gates = json.loads(lines[1])

phases = {}
for t in tasks:
    pid = t.get('_phase_id', '')
    if pid not in phases:
        phases[pid] = []
    phases[pid].append(t)

for pid, phase_tasks in phases.items():
    all_terminal = all(t.get('status') in ('done', 'skipped', 'failed') for t in phase_tasks)
    all_failed = all(t.get('status') == 'failed' for t in phase_tasks)
    if all_terminal and not all_failed:
        gate = next((g for g in gates if g.get('_phase_id') == pid), None)
        if gate and not gate.get('passed', False):
            print(f'gate:{pid}')
" 2>/dev/null)

  while IFS= read -r line; do
    if [[ "$line" == gate:* ]]; then
      local phase_id="${line#gate:}"
      evaluate_gate "$yaml_file" "$events_file" "$phase_id" "$gates_json"
    fi
  done <<< "$gate_check_output"
}

evaluate_gate() {
  local yaml_file="$1" events_file="$2" phase_id="$3" gates_json="$4"

  local gate_json
  gate_json=$(echo "$gates_json" | python3 -c "
import json, sys
gates = json.load(sys.stdin)
phase_id = '$phase_id'
gate = next((g for g in gates if g.get('_phase_id') == phase_id), None)
print(json.dumps(gate) if gate else 'null')
" 2>/dev/null)

  if [[ "$gate_json" == "null" ]]; then
    return 0
  fi

  log "${CYAN}━━━${NC} Evaluating gate for phase: $phase_id"

  local checklist_json
  checklist_json=$(echo "$gate_json" | python3 -c "
import json, sys
gate = json.load(sys.stdin)
print(json.dumps(gate.get('checklist', [])))
" 2>/dev/null)

  local checklist_count
  checklist_count=$(echo "$checklist_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)

  # Empty checklist — auto-pass
  if [[ "$checklist_count" -eq 0 ]]; then
    log "  ${GREEN}✓${NC} Gate auto-passed (empty checklist)"
    emit_event "$events_file" "event=gate_passed" "phase=$phase_id"
    LAST_CHAIN_PHASE="$phase_id"
    if [[ -z "${LIFECYCLE_DISABLED:-}" ]]; then
      lifecycle_emit_phase_complete "$events_file" "${PLAN_ID:-}" "$phase_id"
    fi
    return 0
  fi

  # Strict gates — always halt
  if [[ "$STRICT_GATES" == true ]]; then
    log "  ${YELLOW}⚠${NC} Gate halted (--strict-gates)"
    emit_event "$events_file" "event=gate_blocked" "phase=$phase_id" "blocking_items=strict-gates override"
    return 1
  fi

  # ── Integration gate-check (real integration gates §4.4) ──
  # Route kind=integration checklist items to the phase integration gate
  # (unsandboxed run + §5 conditional trigger + INTEGRATION_REPORT.md) via the
  # isolated subprocess entrypoint, then strip them from the checklist the
  # shell/human Python pass below sees — otherwise that pass routes the unknown
  # kind to needs_human and false-blocks the gate. Only a deny-mode failure
  # blocks here; warn-mode failures and trigger-skips return "passed".
  local _ig_repo _ig_plan _ig_verdict
  _ig_repo=$(cd "$(dirname "$yaml_file")" && git rev-parse --show-toplevel 2>/dev/null || echo "")
  _ig_plan=$(cd "$(dirname "$yaml_file")" && pwd)
  if [[ -n "$_ig_repo" ]]; then
    _ig_verdict=$(printf '%s' "$checklist_json" \
      | bash "${CHAIN_DIR}/lib/phase-integration-gate.sh" "$_ig_repo" "$_ig_plan" "$phase_id") || true
  else
    _ig_verdict="none"
  fi
  case "$_ig_verdict" in
    failed)
      log "  ${YELLOW}⚠${NC} Gate blocked — integration gate failed (see ${_ig_plan}/INTEGRATION_REPORT_${phase_id}.md)"
      emit_event "$events_file" "event=gate_blocked" "phase=$phase_id" "blocking_items=integration"
      return 1 ;;
    none)
      : ;;  # no integration item — checklist passes through unchanged
    *)
      # passed (fired+pass or trigger-skip), or an unexpected verdict treated as
      # non-blocking: drop the integration item(s) so only shell/human remain.
      [[ "$_ig_verdict" != "passed" ]] && \
        log "  ${YELLOW}⚠${NC} integration gate: verdict '${_ig_verdict}' — treating as non-blocking"
      checklist_json=$(printf '%s' "$checklist_json" | python3 -c "
import json, sys
cl = json.load(sys.stdin)
print(json.dumps([it for it in cl
                  if not (isinstance(it, dict) and (it.get('check') or {}).get('kind') == 'integration')]))
" 2>/dev/null) ;;
  esac

  # Evaluate gate: Python runs shell checks and determines pass/fail.
  # The Python script handles both logging and result computation in one pass.
  local gate_result
  gate_result=$(echo "$checklist_json" | python3 -c "
import json, os, subprocess, sys, threading

TRUNCATE_LIMIT = 4096


def _run_streaming(cmd, timeout_s):
    '''Run a shell command, streaming stdout/stderr to this process's
    stderr in real time AND capturing them for the event log.

    Returns (returncode, stdout_text, stderr_text, timed_out: bool).
    The streaming side keeps the operator informed during long suites
    (run-all.sh runs 30+ test suites that previously sat silent
    behind subprocess.run(capture_output=True) for minutes).
    '''
    proc = subprocess.Popen(
        ['bash', '-c', cmd],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=1,
    )
    out_chunks, err_chunks = [], []

    def _pump(stream, sink, label):
        # Read bytes line-by-line so partial lines don't garble the TTY
        # mid-suite. Pipe each line to stderr unchanged for the
        # operator, then stash it for the event log.
        for raw in iter(stream.readline, b''):
            sink.append(raw)
            sys.stderr.buffer.write(raw)
            sys.stderr.flush()
        stream.close()

    t_out = threading.Thread(target=_pump, args=(proc.stdout, out_chunks, 'stdout'), daemon=True)
    t_err = threading.Thread(target=_pump, args=(proc.stderr, err_chunks, 'stderr'), daemon=True)
    t_out.start()
    t_err.start()

    timed_out = False
    try:
        proc.wait(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        timed_out = True
        proc.kill()
        proc.wait()

    t_out.join(timeout=2)
    t_err.join(timeout=2)

    stdout = b''.join(out_chunks).decode('utf-8', errors='replace')
    stderr = b''.join(err_chunks).decode('utf-8', errors='replace')
    return proc.returncode, stdout, stderr, timed_out

def _truncate(s):
    if len(s) > TRUNCATE_LIMIT:
        return f'[truncated — showing last {TRUNCATE_LIMIT} chars]\n' + s[-TRUNCATE_LIMIT:]
    return s

checklist = json.load(sys.stdin)
needs_human = False
any_failed = False
items = []

for i, item in enumerate(checklist):
    if isinstance(item, str):
        needs_human = True
        items.append({'text': item, 'kind': 'human', 'result': 'needs_review'})
    elif isinstance(item, dict):
        text = item.get('text', f'item {i}')
        check = item.get('check', {})
        kind = check.get('kind', 'human')
        cmd = check.get('cmd', '')
        if kind == 'shell' and cmd:
            # Per-item timeout. Full test-suite probes (e.g. bash
            # dashboard/tests/run-all.sh) routinely take 2-5 minutes
            # in real repos — 60s was a Phase-0 development setting
            # that silently failed dashboard backend-substrate gates.
            # Override via AUTOPILOT_CHAIN_GATE_TIMEOUT_S for projects
            # whose suites need longer.
            gate_timeout_s = int(os.environ.get('AUTOPILOT_CHAIN_GATE_TIMEOUT_S', '600'))
            # Header line before the streaming output so the operator
            # knows which checklist item the lines below belong to.
            print(f'  ▶ {text}', file=sys.stderr)
            sys.stderr.flush()
            rc, stdout, stderr, timed_out = _run_streaming(cmd, gate_timeout_s)
            if timed_out:
                any_failed = True
                print(f'  ✗ {text} (shell: timeout after {gate_timeout_s}s)', file=sys.stderr)
                items.append({'text': text, 'kind': 'shell', 'result': 'timeout',
                              'exit_code': None,
                              'stdout': _truncate(stdout), 'stderr': _truncate(stderr)})
            elif rc == 0:
                print(f'  ✓ {text} (shell: passed)', file=sys.stderr)
                items.append({'text': text, 'kind': 'shell', 'result': 'passed', 'exit_code': 0})
            else:
                any_failed = True
                print(f'  ✗ {text} (shell: failed, exit {rc})', file=sys.stderr)
                items.append({'text': text, 'kind': 'shell', 'result': 'failed',
                              'exit_code': rc,
                              'stdout': _truncate(stdout), 'stderr': _truncate(stderr)})
        else:
            needs_human = True
            print(f'  ? {text} (requires human review)', file=sys.stderr)
            items.append({'text': text, 'kind': 'human', 'result': 'needs_review'})

if any_failed or needs_human:
    print('blocked')
else:
    print('passed')

# Output items as JSON for event logging
print(json.dumps(items))
" 2>/dev/null)

  local result_line
  result_line=$(echo "$gate_result" | head -1)
  local items_json
  items_json=$(echo "$gate_result" | tail -1)

  emit_event "$events_file" "event=gate_evaluated" "phase=$phase_id" "items=$items_json"

  if [[ "$result_line" == "passed" ]]; then
    log "  ${GREEN}✓${NC} Gate passed — all shell checks passed"
    # Persist passed:true to YAML via in-place regex substitution.
    # Earlier versions used yaml.safe_dump, which re-serialized the entire
    # file (block-scalars become flow-style, quoting differs, etc.) on
    # every gate eval. The dirty working tree then tripped autopilot's
    # pre-flight ("Uncommitted tracked changes in main"), halting the
    # chain. Worse, when commit-finalize.sh ran, the regex post-merge
    # update missed task blocks in the re-serialized form, so status:
    # done was never written. Regex preserves formatting and matches
    # the same convention commit-finalize.sh uses.
    local persist_ok=0
    python3 -c "
import re, sys
yaml_file = '$yaml_file'
phase_id = '$phase_id'
with open(yaml_file) as f:
    content = f.read()
# Match: '- id: <phase>\n' then any number of indented OR blank lines
# (block-scalar PyYAML output contains blank \n lines that fail a strict
# [ \t]-prefix-only pattern), then the indented 'passed: false' line.
pattern = r'(- id: ' + re.escape(phase_id) + r'\n(?:[ \t].*\n|\n)*?[ \t]+passed: )false'
new_content, n = re.subn(pattern, r'\g<1>true', content, count=1)
if n == 1:
    with open(yaml_file, 'w') as f:
        f.write(new_content)
    sys.exit(0)
sys.exit(1)
" 2>/dev/null && persist_ok=1
    if [[ $persist_ok -eq 1 ]]; then
      # Commit the gate state flip immediately. Autopilot's pre-flight bails
      # if main has any uncommitted tracked changes, and chain dispatches
      # feature autopilots right after this gate eval — so leaving the
      # passed:true write uncommitted halted the chain (observed
      # 2026-05-04 on watchfloor-list-filters after backend-foundations
      # passed). Commit is silent and surgical: only the YAML file, with
      # a chore() prefix so /retro and changelog filters can ignore it.
      local repo_root
      repo_root=$(cd "$(dirname "$yaml_file")" && git rev-parse --show-toplevel 2>/dev/null || echo "")
      if [[ -n "$repo_root" ]]; then
        ( cd "$repo_root" && \
          git add "$yaml_file" >/dev/null 2>&1 && \
          git commit -m "chore(gate): ${phase_id} passed" >/dev/null 2>&1 ) \
          || log "  ${YELLOW}⚠${NC} gate persisted but git commit failed (chain may halt on dirty tree)"
      fi
    else
      log "  ${YELLOW}⚠${NC} Could not persist gate passed:true to YAML"
    fi
    emit_event "$events_file" "event=gate_passed" "phase=$phase_id"
    LAST_CHAIN_PHASE="$phase_id"
    if [[ -z "${LIFECYCLE_DISABLED:-}" ]]; then
      lifecycle_emit_phase_complete "$events_file" "${PLAN_ID:-}" "$phase_id"
    fi
    return 0
  else
    # Distinguish two block modes so the recovery banner can be specific.
    # Pure-human-review block: every blocking item has kind=human → operator
    #   runs the smoke tests, then flips the gate via finalize-plan.sh.
    # Mixed/shell-failure block: at least one shell check failed → operator
    #   fixes the failure, then re-runs the chain (gate auto-evaluates next pass).
    local block_mode
    block_mode=$(echo "$items_json" | python3 -c "
import json, sys
items = json.load(sys.stdin)
blocked = [i for i in items if i['result'] != 'passed']
if all(i['kind'] == 'human' for i in blocked):
    print('human')
else:
    print('mixed')
" 2>/dev/null)

    log "  ${YELLOW}⚠${NC} Gate blocked — requires human review or has failures"

    # Recovery banner — operator-facing, quotable as-is (no flags, no env).
    if [[ "$block_mode" == "human" ]]; then
      log ""
      log "  ${CYAN}▶${NC} All blocking items are kind: human (manual checks)."
      log "    Run the manual smokes, then flip the gate to record approval:"
      log ""
      log "      ${CYAN}bash ~/.claude/tools/finalize-plan.sh approve-gate \\${NC}"
      log "      ${CYAN}    \"$yaml_file\" $phase_id${NC}"
      log ""
      log "    If this was the last gate, finalize the plan as done:"
      log ""
      local plan_dir
      plan_dir=$(dirname "$yaml_file")
      log "      ${CYAN}bash ~/.claude/tools/finalize-plan.sh mark-done \"$plan_dir\"${NC}"
      log ""
    else
      log ""
      log "  ${CYAN}▶${NC} At least one shell check failed. Fix the underlying issue, then"
      log "    re-run the chain — the gate auto-evaluates on the next pass:"
      log ""
      log "      ${CYAN}bash ~/.claude/tools/autopilot-chain.sh run${NC}"
      log ""
    fi

    local blocking
    blocking=$(echo "$items_json" | python3 -c "
import json, sys
items = json.load(sys.stdin)
blocked = [i['text'] for i in items if i['result'] != 'passed']
print(json.dumps(blocked))
" 2>/dev/null)
    emit_event "$events_file" "event=gate_blocked" "phase=$phase_id" "block_mode=$block_mode" "blocking_items=$blocking"
    return 1
  fi
}

# ── Main ──

case "$ACTION" in
  status) run_status ;;
  run)    run_chain ;;
  *)
    echo "Usage: autopilot-chain.sh {run|status} [options] [plan-dir]" >&2
    exit 1
    ;;
esac
