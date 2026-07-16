#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  grinder.sh — Grinder Execution Orchestrator
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Subcommands: discover | run | resume | pause | status
#
#  ── Caller Globals (session-scoped, set once) ──────────
#
#  | Global             | Source                              |
#  |--------------------|-------------------------------------|
#  | AUTOPILOT_SID      | grinder-<project>-<unix-timestamp>  |
#  | DASHBOARD_DATA     | $CLAUDE_DASHBOARD_DATA or default   |
#  | STREAM_FILE        | $GRINDER_DIR/grinder-stream.ndjson  |
#  | ALLOWED_TOOLS      | Read,Edit,Write,Bash,Grep,Glob      |
#
#  ── Caller Globals (batch-scoped, set per-batch) ───────
#
#  | Global             | Source                              |
#  |--------------------|-------------------------------------|
#  | PHASE_TIMEOUT      | GRINDER_BATCH_TIMEOUT (default 1800)|
#  | MAX_TURNS_PHASE    | batch's estimated_turns              |
#  | EXTRA_SYSTEM_PROMPT| pass-kind-specific prompt (empty)    |
#
#  ── Auth-preflight env vars (operator-overridable) ─────
#
#  | Variable                     | Default | Effect                         |
#  |------------------------------|---------|--------------------------------|
#  | GRINDER_SKIP_AUTH_PREFLIGHT  | unset   | "1" → probe writes WARNING and |
#  |                              |         | returns 0 without invoking     |
#  |                              |         | claude (test-only knob, R1.7)  |
#  | AUTH_PROBE_TIMEOUT_S         | 15      | Hard probe wall-clock (R1.3)   |
#  | AUTH_PROBE_PROMPT            | (see)   | Probe prompt; cheap/determ.    |
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -euo pipefail

# ── TOOLS_DIR resolution (env-overridable for testing) ──
TOOLS_DIR="${TOOLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LIB_DIR="${LIB_DIR:-$TOOLS_DIR/lib}"

# Resolve schema directory: probe deployed location (~/.claude/schema)
# first, fall back to walking ancestors looking for core/schema/. Mirrors
# lib/schema_paths.py so deployed and in-repo execution both work.
_grinder_resolve_schema_dir() {
  local deployed="$TOOLS_DIR/../schema"
  if [[ -d "$deployed" ]]; then
    (cd "$deployed" && pwd)
    return 0
  fi
  local walker="$TOOLS_DIR"
  while [[ "$walker" != "/" && -n "$walker" ]]; do
    if [[ -d "$walker/core/schema" ]]; then
      (cd "$walker/core/schema" && pwd)
      return 0
    fi
    walker="$(dirname "$walker")"
  done
  return 1
}
SCHEMA_DIR="${SCHEMA_DIR:-$(_grinder_resolve_schema_dir)}"

# ── Source shared libraries ──
# shellcheck source=lib/claude-session-lib.sh
source "$LIB_DIR/claude-session-lib.sh"
# shellcheck source=lib/merge-lock.sh
source "$LIB_DIR/merge-lock.sh"
# shellcheck source=lib/grinder-discover.sh
source "$LIB_DIR/grinder-discover.sh"
# shellcheck source=lib/grinder-mechanical.sh
source "$LIB_DIR/grinder-mechanical.sh"
# shellcheck source=lib/grinder-coverage.sh
source "$LIB_DIR/grinder-coverage.sh"
# shellcheck source=lib/grinder-static.sh
source "$LIB_DIR/grinder-static.sh"
# shellcheck source=lib/grinder-cve.sh
source "$LIB_DIR/grinder-cve.sh"

# ── Defaults ──
PROJECT_DIR="."
GRINDER_DIR="docs/grinder"
GRINDER_BATCH_TIMEOUT="${GRINDER_BATCH_TIMEOUT:-1800}"
GRINDER_LOCK_MAX_WAIT="${GRINDER_LOCK_MAX_WAIT:-60}"
PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Projekter}"
# Auth-preflight tunables (grinder-auth-recovery R1.3, R1.7). The default
# prompt is a cheap deterministic single-token request. Default budget is
# 15s: real claude startup (model state load + API auth + first-token
# latency) measures 3-10s typical on a warm cache and up to 15s on a cold
# cache. The original 5s default tripped legitimate operator runs on
# 2026-05-12 — the probe fired before claude even finished its auth
# handshake. 15s gives realistic headroom while still failing fast on a
# truly broken auth state. Operators with consistently slow startups
# (offline mode, proxied API, etc.) override via the env var.
AUTH_PROBE_TIMEOUT_S="${AUTH_PROBE_TIMEOUT_S:-15}"
AUTH_PROBE_PROMPT="${AUTH_PROBE_PROMPT:-reply with the single character k}"

# ── log() — dual-write to terminal + NDJSON stream (autopilot.sh pattern) ──

log() {
  local msg="$1"
  echo -e "$msg"
  if [[ -n "${STREAM_FILE:-}" && -d "$(dirname "$STREAM_FILE" 2>/dev/null)" ]]; then
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq -nc --arg msg "$msg" --arg ts "$ts" '{type:"log",msg:$msg,ts:$ts}' >> "$STREAM_FILE" 2>/dev/null || true
  fi
}

# ── _emit_orchestrator_event() — write a batch-boundary marker to STREAM_FILE ──
#
# Emits `{"type":"orchestrator","batch":<id>,"event":<event>,"msg":"batch <id>
# <event>","ts":<utc>}` to grinder-stream.ndjson so the dashboard's
# filter_batch_events (dashboard/server/grinder_helpers.py:_find_batch_bounds)
# can slice the stream into per-batch views. Without these markers the
# BatchView shows an empty content panel because no event in the raw
# claude stream-json output is tagged with a batch id.
#
# The msg is constructed verbatim ("batch <id> <event>") so the dashboard's
# keyword scan (TestFilterBatchEvents C2.1-C2.7) matches it. Acceptable
# event values: started, completed, failed, deferred — these align with
# the transition_batch_status status→event_type table at line 459.
#
# Fail soft: STREAM_FILE unset or unwritable returns 0 without raising.
# Matches the log() function pattern.
_emit_orchestrator_event() {
  local batch_id="$1"
  local event="$2"
  [[ -z "${STREAM_FILE:-}" ]] && return 0
  [[ -d "$(dirname "$STREAM_FILE" 2>/dev/null)" ]] || return 0
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  jq -nc \
    --arg batch "$batch_id" \
    --arg event "$event" \
    --arg msg "batch $batch_id $event" \
    --arg ts "$ts" \
    '{type:"orchestrator",batch:$batch,event:$event,msg:$msg,ts:$ts}' \
    >> "$STREAM_FILE" 2>/dev/null || true
}

# ── fail_pipeline() — required by claude-session-lib.sh run_gated_phase ──

fail_pipeline() {
  local phase=$1 msg=$2
  log "${RED}✗${NC} $phase: $msg"
  exit 1
}

# ── auth_preflight_probe() — claude-auth health check (grinder-auth-recovery) ──
#
# Runs a cheap headless `claude -p` invocation with a hard 5-second
# timeout (override via AUTH_PROBE_TIMEOUT_S) so an unauthenticated state
# halts the run BEFORE any batch is spawned. Single-source predicate
# (`_auth_failed_classify`) is shared with the run-time hook so the two
# paths recognise the same authentication shapes.
#
# Returns 0 on success (claude is authenticated). Exits 2 on:
#   - GRINDER_SKIP_AUTH_PREFLIGHT unset AND claude not on PATH (EC-B)
#   - GRINDER_SKIP_AUTH_PREFLIGHT unset AND probe times out (EC-C)
#   - GRINDER_SKIP_AUTH_PREFLIGHT unset AND probe output matches an
#     auth-failed shape (R1.5)
#   - GRINDER_SKIP_AUTH_PREFLIGHT unset AND probe rc != 0 with no
#     auth-failed shape (defensive — never silently proceed)
#
# When GRINDER_SKIP_AUTH_PREFLIGHT=1 the probe writes a single WARNING
# line to stderr and returns 0 without invoking claude (R1.7, EC-D, EC-L).
auth_preflight_probe() {
  if [[ "${GRINDER_SKIP_AUTH_PREFLIGHT:-}" == "1" ]]; then
    echo "WARNING: auth preflight skipped via GRINDER_SKIP_AUTH_PREFLIGHT" >&2
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude binary not found on PATH" >&2
    exit 2
  fi
  local timeout_bin
  timeout_bin=$(_resolve_timeout_bin)
  local probe_out probe_err probe_rc=0
  probe_out=$(mktemp "${TMPDIR:-/tmp}/grinder-auth-probe.XXXXXX")
  probe_err=$(mktemp "${TMPDIR:-/tmp}/grinder-auth-probe-err.XXXXXX")
  trap 'rm -f "$probe_out" "$probe_err"' RETURN
  if [[ -n "$timeout_bin" ]]; then
    env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u NO_PROXY \
        -u all_proxy -u https_proxy -u http_proxy -u no_proxy \
        "$timeout_bin" "$AUTH_PROBE_TIMEOUT_S" \
        claude -p "$AUTH_PROBE_PROMPT" --output-format stream-json --verbose --max-turns 1 \
        < /dev/null > "$probe_out" 2> "$probe_err" \
        || probe_rc=$?
  else
    # No timeout binary available — run the probe without an external
    # timer. Real install always has gtimeout/timeout; this branch is
    # defensive so the test harness can opt out via GRINDER_SKIP_AUTH_PREFLIGHT.
    env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u NO_PROXY \
        -u all_proxy -u https_proxy -u http_proxy -u no_proxy \
        claude -p "$AUTH_PROBE_PROMPT" --output-format stream-json --verbose --max-turns 1 \
        < /dev/null > "$probe_out" 2> "$probe_err" \
        || probe_rc=$?
  fi
  if [[ "$probe_rc" -eq 124 ]]; then
    echo "claude auth probe timed out after ${AUTH_PROBE_TIMEOUT_S}s" >&2
    exit 2
  fi
  local reason=""
  reason=$(_auth_failed_classify "$probe_out")
  if [[ -n "$reason" ]]; then
    echo "claude auth required — run claude login and retry" >&2
    exit 2
  fi
  if [[ "$probe_rc" -ne 0 ]]; then
    echo "claude auth probe failed (exit ${probe_rc})" >&2
    exit 2
  fi
  return 0
}

# ── emit_event() — atomic append of one JSON line to events.ndjson ──
# Reads: GRINDER_DIR (session)

emit_event() {
  local batch_id="$1" event_type="$2"
  shift 2
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local json
  json=$(jq -nc --arg ts "$ts" --arg batch "$batch_id" --arg event "$event_type" \
    '{ts: $ts, batch: $batch, event: $event}')

  # Merge any additional fields passed as key=value pairs
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local val="${1#*=}"
    # Detect if value is numeric or boolean
    if [[ "$val" =~ ^[0-9]+$ ]]; then
      json=$(echo "$json" | jq -c --arg k "$key" --argjson v "$val" '. + {($k): $v}')
    elif [[ "$val" == "true" || "$val" == "false" ]]; then
      json=$(echo "$json" | jq -c --arg k "$key" --argjson v "$val" '. + {($k): $v}')
    else
      json=$(echo "$json" | jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}')
    fi
    shift
  done

  local events_file="$GRINDER_DIR/events.ndjson"
  printf '%s\n' "$json" >> "$events_file"
}

# ── read_events() — reads events.ndjson with truncated-final-line tolerance ──
# Reads: GRINDER_DIR (session)
# Outputs: valid JSON lines to stdout, warnings to stderr

read_events() {
  local events_file="$GRINDER_DIR/events.ndjson"
  if [[ ! -f "$events_file" ]]; then
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    if echo "$line" | jq -e '.' >/dev/null 2>&1; then
      echo "$line"
    else
      echo "events.ndjson: ignoring truncated final line" >&2
    fi
  done < "$events_file"
}

# ── read_state() — parses grinder-state.json, exits on corrupt JSON ──
# Reads: GRINDER_DIR (session)

read_state() {
  local state_file="$GRINDER_DIR/grinder-state.json"
  if [[ ! -f "$state_file" ]]; then
    echo ""
    return 0
  fi

  local state
  if ! state=$(jq '.' "$state_file" 2>/dev/null); then
    echo "grinder-state.json corrupt -- restore from last git commit or delete to start fresh"
    return 1
  fi
  echo "$state"
}

# ── write_state() — atomic temp-file-then-mv JSON write ──
# Reads: GRINDER_DIR (session)

write_state() {
  local state_json="$1"
  local state_file="$GRINDER_DIR/grinder-state.json"
  local tmp_file
  tmp_file=$(mktemp "${state_file}.XXXXXX")

  echo "$state_json" | jq '.' > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

# ── validate_plan() — invokes validate-plan.py --schema ──
# Reads: TOOLS_DIR, SCHEMA_DIR, GRINDER_DIR (session)

validate_plan() {
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  local schema_file="$SCHEMA_DIR/grinder-plan.schema.json"

  if [[ ! -f "$plan_file" ]]; then
    echo "no active plan -- run grinder.sh discover first"
    return 1
  fi

  local output
  if ! output=$(python3 "$TOOLS_DIR/validate-plan.py" --schema "$schema_file" "$plan_file" 2>&1); then
    echo "$output" >&2
    return 1
  fi
  return 0
}

# ── check_staleness() — compares git_sha_at_start vs HEAD ──
# Reads: PROJECT_DIR (session)

check_staleness() {
  local plan_sha="$1"
  local threshold="${2:-1}"

  cd "$PROJECT_DIR"

  # Check if plan SHA is an ancestor of HEAD
  if ! git merge-base --is-ancestor "$plan_sha" HEAD 2>/dev/null; then
    echo "plan stale: git_sha_at_start $plan_sha is not an ancestor of HEAD -- re-run grinder.sh discover"
    return 1
  fi

  local distance
  distance=$(git rev-list --count "$plan_sha..HEAD" 2>/dev/null) || {
    echo "staleness check failed: git error"
    return 1
  }

  if [[ "$distance" -gt "$threshold" ]]; then
    echo "plan stale: HEAD is $distance commits ahead -- re-run grinder.sh discover"
    return 1
  fi

  return 0
}

# ── acquire_grinder_lock() — calls merge-lock.sh with grinder-specific path ──
# Reads: GRINDER_DIR, GRINDER_LOCK_MAX_WAIT (session)

acquire_grinder_lock() {
  local lock_file="$GRINDER_DIR/.grinder.lock"
  MERGE_LOCK_MAX_WAIT="$GRINDER_LOCK_MAX_WAIT" acquire_merge_lock "$lock_file"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    local holder_pid
    holder_pid=$(cat "$lock_file" 2>/dev/null || echo "unknown")
    echo "grinder: another instance is running (lock held by PID $holder_pid)"
    return 1
  fi
  return 0
}

# ── release_grinder_lock() — removes lock file ──
# Reads: GRINDER_DIR (session)

release_grinder_lock() {
  release_merge_lock "$GRINDER_DIR/.grinder.lock"
}

# ── setup_traps() — traps SIGINT, SIGTERM, EXIT for lock release ──
# Reads: GRINDER_DIR (session)

setup_traps() {
  trap 'release_grinder_lock' EXIT
  trap 'release_grinder_lock; exit 130' INT
  trap 'release_grinder_lock; exit 143' TERM
}

# ── init_state() — creates grinder-state.json if absent ──
# Reads: GRINDER_DIR (session)
# On resume with events, reconstructs counters from events.ndjson (REQ-13.1)

init_state() {
  local mode="${1:-run}"  # "run" or "resume"
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  local state_file="$GRINDER_DIR/grinder-state.json"

  if [[ -f "$state_file" ]]; then
    return 0
  fi

  local git_sha
  git_sha=$(python3 -c "
import yaml, sys
with open('$plan_file') as f:
    d = yaml.safe_load(f)
print(d.get('git_sha_at_start', ''))
")

  local total_batches
  total_batches=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
total = sum(len(p.get('batches', [])) for p in d.get('passes', []))
print(total)
")

  local first_pass
  first_pass=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
passes = d.get('passes', [])
print(passes[0]['id'] if passes else '')
")

  local completed=0
  local failed_count=0

  if [[ "$mode" == "resume" ]]; then
    # Reconstruct counters from events.ndjson (REQ-13.1)
    local events_file="$GRINDER_DIR/events.ndjson"
    if [[ -f "$events_file" ]]; then
      completed=$(read_events | jq -s '[.[] | select(.event == "completed")] | length')
      failed_count=$(read_events | jq -s '[.[] | select(.event == "failed" or .event == "abandoned")] | length')

      # Find first pass with pending batches
      first_pass=$(python3 -c "
import yaml, json, sys

with open('$plan_file') as f:
    plan = yaml.safe_load(f)

# Read plan batch statuses
for p in plan.get('passes', []):
    for b in p.get('batches', []):
        if b.get('status') == 'pending':
            print(p['id'])
            sys.exit(0)
# All done — use first pass
print(plan['passes'][0]['id'] if plan.get('passes') else '')
")
    fi
  fi

  local pending=$((total_batches - completed - failed_count))
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local state
  state=$(jq -n \
    --arg cp "$first_pass" \
    --arg sa "$ts" \
    --arg lu "$ts" \
    --arg gs "$git_sha" \
    --argjson bc "$completed" \
    --argjson bf "$failed_count" \
    --argjson bp "$pending" \
    '{
      current_pass: $cp,
      started_at: $sa,
      last_updated: $lu,
      git_sha_at_start: $gs,
      current_batch: null,
      batches_completed: $bc,
      batches_failed: $bf,
      batches_pending: $bp,
      batches_deferred: 0,
      paused: false
    }')

  write_state "$state"
}

# ── transition_batch_status() — single entry point for all status transitions ──
# Strict order per REQ-13.2: (1) emit event, (2) update plan YAML, (3) update state JSON
# Reads: GRINDER_DIR, TOOLS_DIR (session)

transition_batch_status() {
  local batch_id="$1"
  local new_status="$2"
  shift 2
  # Remaining args are extra event fields (key=value)

  # Determine event type from status
  local event_type="$new_status"
  case "$new_status" in
    in_progress) event_type="started" ;;
    completed)   event_type="completed" ;;
    failed)      event_type="failed" ;;
    deferred)    event_type="deferred" ;;
  esac

  # Check if explicit event_type was passed as extra arg
  local extra_args=()
  local explicit_event=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == event_type=* ]]; then
      explicit_event="${1#event_type=}"
    else
      extra_args+=("$1")
    fi
    shift
  done
  if [[ -n "$explicit_event" ]]; then
    event_type="$explicit_event"
  fi

  # Step 1: Emit event to events.ndjson (crash-recovery authority)
  emit_event "$batch_id" "$event_type" "${extra_args[@]+"${extra_args[@]}"}" || {
    echo "transition_batch_status: emit_event failed for $batch_id" >&2
    return 1
  }

  # Step 1b: Emit a sister event to grinder-stream.ndjson so the dashboard's
  # filter_batch_events can slice per-batch views. Fail-soft (mirrors log()).
  _emit_orchestrator_event "$batch_id" "$event_type"

  # Step 2: Update plan YAML via C2
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  if ! python3 "$LIB_DIR/grinder-plan-update.py" "$plan_file" "$batch_id" "$new_status"; then
    echo "transition_batch_status: plan update failed for $batch_id" >&2
    return 1
  fi

  # Step 3: Update state JSON
  local state
  state=$(read_state) || { echo "$state"; return 1; }
  if [[ -z "$state" ]]; then
    return 0  # No state file yet; init_state will handle it
  fi

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  case "$new_status" in
    completed)
      state=$(echo "$state" | jq --arg ts "$ts" --arg b "$batch_id" '
        .current_batch = $b |
        .last_updated = $ts |
        .batches_completed += 1 |
        .batches_pending -= 1')
      ;;
    failed)
      state=$(echo "$state" | jq --arg ts "$ts" --arg b "$batch_id" '
        .current_batch = $b |
        .last_updated = $ts |
        .batches_failed += 1 |
        .batches_pending -= 1')
      ;;
    in_progress)
      state=$(echo "$state" | jq --arg ts "$ts" --arg b "$batch_id" '
        .current_batch = $b |
        .last_updated = $ts')
      ;;
    deferred)
      state=$(echo "$state" | jq --arg ts "$ts" --arg b "$batch_id" '
        .current_batch = $b |
        .last_updated = $ts |
        .batches_deferred += 1 |
        .batches_pending -= 1')
      ;;
  esac

  write_state "$state" || {
    echo "transition_batch_status: write_state failed for $batch_id" >&2
    return 1
  }
}

# ── execute_batch() — per-batch execution via run_phase ──
# Reads (session): AUTOPILOT_SID, DASHBOARD_DATA, STREAM_FILE, ALLOWED_TOOLS, GRINDER_DIR, PROJECT_DIR
# Reads (batch): PHASE_TIMEOUT, MAX_TURNS_PHASE, EXTRA_SYSTEM_PROMPT

execute_batch() {
  local batch_id="$1"
  local pass_kind="$2"
  local files_json="$3"
  local estimated_turns="$4"

  # Mechanical pass dispatches to dedicated handler (C7)
  if [[ "$pass_kind" == "mechanical" ]]; then
    execute_mechanical_batch "$@"
    return $?
  fi

  # Coverage pass dispatches to dedicated handler
  if [[ "$pass_kind" == "coverage" ]]; then
    execute_coverage_batch "$@"
    return $?
  fi

  # Static-analysis pass dispatches to dedicated handler
  if [[ "$pass_kind" == "static_analysis" ]]; then
    execute_static_batch "$@"
    return $?
  fi

  # CVE pass dispatches to dedicated handler
  if [[ "$pass_kind" == "cve" ]]; then
    execute_cve_batch "$@"
    return $?
  fi

  # ── contract: run_phase (claude-session-lib.sh) reads these exports ──
  export PHASE_TIMEOUT="$GRINDER_BATCH_TIMEOUT"   # max seconds per batch
  export MAX_TURNS_PHASE="$estimated_turns"        # max claude turns
  export EXTRA_SYSTEM_PROMPT=""                     # pass-kind prompt (empty for stub)

  local files_list
  files_list=$(echo "$files_json" | jq -r '.[]' 2>/dev/null || echo "")

  local prompt="You are running a grinder batch ($pass_kind pass, batch $batch_id).

Files to process:
$files_list

Apply $pass_kind improvements to these files following the project's CLAUDE.md conventions."

  local exit_code=0
  run_phase "$prompt" "grinder-$batch_id" "$PROJECT_DIR" || exit_code=$?

  # Commit changes if any
  cd "$PROJECT_DIR"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    local changed_files
    changed_files=$(git diff --name-only HEAD 2>/dev/null || git diff --name-only 2>/dev/null || echo "")
    if [[ -n "$changed_files" ]]; then
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        git add "$f" 2>/dev/null || true
      done <<< "$changed_files"
      if ! git commit -m "fix(grinder): $pass_kind (batch $batch_id)" 2>/dev/null; then
        log "grinder: batch $batch_id commit failed — reverting changes"
        git checkout -- . 2>/dev/null || true
        return 1
      fi
      log "grinder: batch $batch_id committed changes"
      # Log out-of-batch files
      local batch_files_flat
      batch_files_flat=$(echo "$files_json" | jq -r '.[]' 2>/dev/null || echo "")
      local extra_files
      extra_files=$(echo "$changed_files" | while IFS= read -r f; do
        if ! echo "$batch_files_flat" | grep -qF "$f"; then
          echo "$f"
        fi
      done)
      if [[ -n "$extra_files" ]]; then
        log "grinder: batch $batch_id also modified: $extra_files"
      fi
    fi
  fi

  return $exit_code
}

# ── process_batch() — per-batch logic: status check, deps, execute ──
# Returns: 0 on success, 1 on failure, 2 on skip

process_batch() {
  local batch_json="$1"
  local pass_kind="$2"
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"

  local batch_id status files estimated_turns deps
  batch_id=$(echo "$batch_json" | jq -r '.id')
  status=$(echo "$batch_json" | jq -r '.status')
  files=$(echo "$batch_json" | jq -c '.files')
  estimated_turns=$(echo "$batch_json" | jq -r '.estimated_turns')
  deps=$(echo "$batch_json" | jq -r '.depends_on // [] | .[]' 2>/dev/null || echo "")

  # Skip completed/failed/deferred batches
  case "$status" in
    completed|failed|deferred) return 2 ;;
  esac

  # Check needs_review flag (C5 — coverage/static pass halt)
  local needs_review
  needs_review=$(echo "$batch_json" | jq -r '.needs_review // false')
  if [[ "$needs_review" == "true" ]]; then
    log "$pass_kind: batch $batch_id has needs_review=true -- halting pass"
    log "$pass_kind: run grinder.sh ack-review $batch_id to continue"
    return 2
  fi

  # Check dependencies
  if [[ -n "$deps" ]]; then
    while IFS= read -r dep_id; do
      [[ -z "$dep_id" ]] && continue
      local dep_status
      dep_status=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
for p in d.get('passes', []):
    for b in p.get('batches', []):
        if b['id'] == sys.argv[2]:
            print(b['status'])
            sys.exit(0)
print('unknown')
" "$plan_file" "$dep_id")
      if [[ "$dep_status" != "completed" ]]; then
        if [[ "$dep_status" == "failed" ]]; then
          log "${YELLOW}⚠${NC} batch $batch_id blocked by failed dependency $dep_id"
        fi
        return 2  # skip — dependency not met
      fi
    done <<< "$deps"
  fi

  # Set to in_progress
  transition_batch_status "$batch_id" "in_progress" "session_id=${AUTOPILOT_SID:-grinder}" || return 1

  # Execute — capture stdout for mechanical enrichment data (C8)
  # Stderr flows to caller's stderr naturally; only stdout is parsed for key=value lines
  local exit_code=0
  local exec_output=""
  local exec_stderr_file="${TMPDIR:-/tmp}/grinder-batch-stderr-$$-$batch_id"
  exec_output=$(execute_batch "$batch_id" "$pass_kind" "$files" "$estimated_turns" 2>"$exec_stderr_file") || exit_code=$?
  # Relay stderr to caller so diagnostic messages are visible in logs
  [[ -f "$exec_stderr_file" ]] && cat "$exec_stderr_file" >&2

  if [[ $exit_code -eq 0 ]]; then
    # For mechanical batches, parse key=value lines from stdout for event enrichment
    local extra_event_args=()
    if [[ "$pass_kind" == "mechanical" ]]; then
      local fb fa ff
      fb=$(echo "$exec_output" | sed -n 's/^findings_before=\([0-9]*\)$/\1/p' | head -1)
      fa=$(echo "$exec_output" | sed -n 's/^findings_after=\([0-9]*\)$/\1/p' | head -1)
      ff=$(echo "$exec_output" | sed -n 's/^files_fixed=\([0-9]*\)$/\1/p' | head -1)
      [[ -n "$fb" ]] && extra_event_args+=("findings_before=$fb")
      [[ -n "$fa" ]] && extra_event_args+=("findings_after=$fa")
      [[ -n "$ff" ]] && extra_event_args+=("files_fixed=$ff")
    elif [[ "$pass_kind" == "coverage" ]]; then
      local cb ca tg
      cb=$(echo "$exec_output" | sed -n 's/^coverage_before=\(.*\)$/\1/p' | head -1)
      ca=$(echo "$exec_output" | sed -n 's/^coverage_after=\(.*\)$/\1/p' | head -1)
      tg=$(echo "$exec_output" | sed -n 's/^test_files_generated=\([0-9]*\)$/\1/p' | head -1)
      [[ -n "$cb" ]] && extra_event_args+=("coverage_before=$cb")
      [[ -n "$ca" ]] && extra_event_args+=("coverage_after=$ca")
      [[ -n "$tg" ]] && extra_event_args+=("test_files_generated=$tg")
    elif [[ "$pass_kind" == "static_analysis" ]]; then
      local sfb sfa sff sfs sfp
      sfb=$(echo "$exec_output" | sed -n 's/^findings_before=\([0-9]*\)$/\1/p' | head -1)
      sfa=$(echo "$exec_output" | sed -n 's/^findings_after=\([0-9]*\)$/\1/p' | head -1)
      sff=$(echo "$exec_output" | sed -n 's/^files_fixed=\([0-9]*\)$/\1/p' | head -1)
      sfs=$(echo "$exec_output" | sed -n 's/^files_skipped=\([0-9]*\)$/\1/p' | head -1)
      sfp=$(echo "$exec_output" | sed -n 's/^files_proposed=\([0-9]*\)$/\1/p' | head -1)
      [[ -n "$sfb" ]] && extra_event_args+=("findings_before=$sfb")
      [[ -n "$sfa" ]] && extra_event_args+=("findings_after=$sfa")
      [[ -n "$sff" ]] && extra_event_args+=("files_fixed=$sff")
      [[ -n "$sfs" ]] && extra_event_args+=("files_skipped=$sfs")
      [[ -n "$sfp" ]] && extra_event_args+=("files_proposed=$sfp")
    elif [[ "$pass_kind" == "cve" ]]; then
      local cf cx cd de
      cf=$(echo "$exec_output" | sed -n 's/^cves_found=\([0-9]*\)$/\1/p' | head -1)
      cx=$(echo "$exec_output" | sed -n 's/^cves_fixed=\([0-9]*\)$/\1/p' | head -1)
      cd=$(echo "$exec_output" | sed -n 's/^cves_deferred=\([0-9]*\)$/\1/p' | head -1)
      de=$(echo "$exec_output" | sed -n 's/^deps_excluded=\([0-9]*\)$/\1/p' | head -1)
      [[ -n "$cf" ]] && extra_event_args+=("cves_found=$cf")
      [[ -n "$cx" ]] && extra_event_args+=("cves_fixed=$cx")
      [[ -n "$cd" ]] && extra_event_args+=("cves_deferred=$cd")
      [[ -n "$de" ]] && extra_event_args+=("deps_excluded=$de")
    fi
    transition_batch_status "$batch_id" "completed" "${extra_event_args[@]+"${extra_event_args[@]}"}" || { rm -f "$exec_stderr_file"; return 1; }
  else
    # Extract reason from stderr for mechanical failures
    local reason="batch execution failed (exit $exit_code)"
    if [[ -f "$exec_stderr_file" ]]; then
      if [[ "$pass_kind" == "mechanical" ]]; then
        if grep -q "test regression" "$exec_stderr_file"; then
          reason="test regression"
        elif grep -q "pre-commit hook failure" "$exec_stderr_file"; then
          reason="pre-commit hook failure"
        elif grep -q "findings increased" "$exec_stderr_file"; then
          reason="findings increased after fix"
        fi
      elif [[ "$pass_kind" == "coverage" ]]; then
        if grep -q "coverage regression" "$exec_stderr_file"; then
          reason="coverage regression"
        elif grep -q "inline suppression" "$exec_stderr_file"; then
          reason="inline suppression in generated test"
        elif grep -q "mock depth exceeded" "$exec_stderr_file"; then
          reason="mock depth exceeded 3"
        elif grep -q "generated tests fail" "$exec_stderr_file"; then
          reason="generated tests fail"
        fi
      elif [[ "$pass_kind" == "static_analysis" ]]; then
        if grep -q "inline suppression in fix" "$exec_stderr_file"; then
          reason="inline suppression in fix"
        elif grep -q "test regression" "$exec_stderr_file"; then
          reason="test regression"
        elif grep -q "allowlisted finding not resolved" "$exec_stderr_file"; then
          reason="allowlisted finding not resolved"
        fi
      elif [[ "$pass_kind" == "cve" ]]; then
        if grep -q "test regression after upgrade" "$exec_stderr_file"; then
          reason="test regression after upgrade"
        elif grep -q "major bump required" "$exec_stderr_file"; then
          reason="major bump required"
        elif grep -q "normalisation failed" "$exec_stderr_file"; then
          reason="normalisation failed"
        elif grep -q "upgrade command failed" "$exec_stderr_file"; then
          reason="upgrade command failed"
        fi
      fi
    fi
    local -a fail_args=("reason=$reason")
    # Only emit reverted=true when the reason indicates an actual revert occurred
    if [[ "$pass_kind" == "mechanical" ]]; then
      case "$reason" in
        "test regression"|"pre-commit hook failure"|"findings increased after fix")
          fail_args+=("reverted=true")
          ;;
      esac
    elif [[ "$pass_kind" == "coverage" ]]; then
      case "$reason" in
        "coverage regression"|"inline suppression in generated test"|"mock depth exceeded 3"|"generated tests fail")
          fail_args+=("reverted=true")
          ;;
      esac
    elif [[ "$pass_kind" == "static_analysis" ]]; then
      case "$reason" in
        "inline suppression in fix"|"test regression"|"allowlisted finding not resolved")
          fail_args+=("reverted=true")
          ;;
      esac
    elif [[ "$pass_kind" == "cve" ]]; then
      case "$reason" in
        "test regression after upgrade"|"upgrade command failed")
          fail_args+=("reverted=true")
          ;;
      esac
    fi
    transition_batch_status "$batch_id" "failed" "${fail_args[@]}" || { rm -f "$exec_stderr_file"; return 1; }
  fi

  rm -f "$exec_stderr_file"
  return $exit_code
}

# ── run_batch_loop() — sequential pass/batch iteration ──
# Reads: GRINDER_DIR (session)

run_batch_loop() {
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  local any_executed=false

  local passes_json
  passes_json=$(python3 -c "
import yaml, json
with open('$plan_file') as f:
    d = yaml.safe_load(f)
print(json.dumps(d.get('passes', [])))
")

  local num_passes
  num_passes=$(echo "$passes_json" | jq 'length')

  for ((p_idx=0; p_idx<num_passes; p_idx++)); do
    local pass_json pass_id pass_kind num_batches
    pass_json=$(echo "$passes_json" | jq ".[$p_idx]")
    pass_id=$(echo "$pass_json" | jq -r '.id')
    pass_kind=$(echo "$pass_json" | jq -r '.kind')
    num_batches=$(echo "$pass_json" | jq '.batches | length')

    # Skip empty passes (EC-7.1)
    [[ "$num_batches" -eq 0 ]] && continue

    # Check if all batches in pass are done
    local pending_in_pass
    pending_in_pass=$(echo "$pass_json" | jq '[.batches[] | select(.status == "pending" or .status == "in_progress")] | length')
    [[ "$pending_in_pass" -eq 0 ]] && continue

    # Update current_pass in state
    local state
    state=$(read_state) || { echo "$state"; return 1; }
    if [[ -n "$state" ]]; then
      state=$(echo "$state" | jq --arg cp "$pass_id" '.current_pass = $cp')
      write_state "$state"
    fi

    # Coverage pass: early exit check — skip if project-wide coverage meets target
    if [[ "$pass_kind" == "coverage" ]]; then
      local manifest_json_check=""
      manifest_json_check=$(python3 "$TOOLS_DIR/validate-manifest.py" --parse-grinder "$PROJECT_DIR/pipeline.yaml" 2>/dev/null) || true
      if [[ -n "$manifest_json_check" ]]; then
        local cov_cmd_check=""
        cov_cmd_check=$(_coverage_resolve_command "$manifest_json_check" 2>/dev/null) || true
        if [[ -n "$cov_cmd_check" ]]; then
          local cov_measure_check=""
          cov_measure_check=$(_coverage_measure "$cov_cmd_check" "auto" "$PROJECT_DIR" 2>/dev/null) || true
          if [[ -n "$cov_measure_check" ]]; then
            local current_pw=""
            current_pw=$(echo "$cov_measure_check" | python3 -c "import json,sys; print(json.load(sys.stdin).get('project_wide',0))" 2>/dev/null) || true
            local target_pw=""
            target_pw=$(echo "$manifest_json_check" | python3 -c "import json,sys; print(json.load(sys.stdin).get('coverage',{}).get('target_project_wide',0))" 2>/dev/null) || true
            if [[ -n "$current_pw" && -n "$target_pw" ]]; then
              local should_skip=""
              should_skip=$(_should_early_exit_coverage "$current_pw" "$target_pw")
              if [[ "$should_skip" == "true" ]]; then
                log "coverage: target met (${current_pw} >= ${target_pw}) -- skipping all batches"
                # Mark all pending batches in this pass as completed
                for ((skip_idx=0; skip_idx<num_batches; skip_idx++)); do
                  local skip_batch_json
                  skip_batch_json=$(echo "$pass_json" | jq ".batches[$skip_idx]")
                  local skip_batch_id skip_batch_status
                  skip_batch_id=$(echo "$skip_batch_json" | jq -r '.id')
                  skip_batch_status=$(echo "$skip_batch_json" | jq -r '.status')
                  if [[ "$skip_batch_status" == "pending" ]]; then
                    transition_batch_status "$skip_batch_id" "completed" "reason=coverage target already met" || true
                  fi
                done
                continue
              fi
            fi
          fi
        fi
      fi
    fi

    # Track batch failures for needs_review threshold (coverage + static_analysis)
    local pass_failed=0
    local pass_completed=0

    for ((b_idx=0; b_idx<num_batches; b_idx++)); do
      # Re-read pass from plan (status may have changed)
      local current_pass_json
      current_pass_json=$(python3 -c "
import yaml, json, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
for p in d.get('passes', []):
    if p['id'] == sys.argv[2]:
        print(json.dumps(p))
        break
" "$plan_file" "$pass_id")
      local batch_json
      batch_json=$(echo "$current_pass_json" | jq ".batches[$b_idx]")

      # Check pause between batches
      if [[ -f "$GRINDER_DIR/PAUSE" ]]; then
        log "grinder paused between batches -- remove $GRINDER_DIR/PAUSE or run grinder.sh resume to continue"
        return 0
      fi

      local rc=0
      process_batch "$batch_json" "$pass_kind" || rc=$?

      case $rc in
        0) any_executed=true
           if [[ "$pass_kind" == "coverage" || "$pass_kind" == "static_analysis" ]]; then
             pass_completed=$((pass_completed + 1))
           fi
           ;;
        1) any_executed=true
           if [[ "$pass_kind" == "coverage" || "$pass_kind" == "static_analysis" ]]; then
             pass_failed=$((pass_failed + 1))
             pass_completed=$((pass_completed + 1))
             # Check needs_review threshold: >50% of batches failed
             local should_halt
             should_halt=$(_should_halt_coverage_pass "$pass_failed" "$pass_completed")
             if [[ "$should_halt" == "true" ]]; then
               # Find the next pending batch and mark it needs_review
               local next_pending_id
               next_pending_id=$(python3 -c "
import yaml, json, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
for p in d.get('passes', []):
    if p['id'] == sys.argv[2]:
        for b in p.get('batches', []):
            if b.get('status') == 'pending' and not b.get('needs_review', False):
                print(b['id'])
                sys.exit(0)
print('')
" "$plan_file" "$pass_id")
               if [[ -n "$next_pending_id" ]]; then
                 python3 "$LIB_DIR/grinder-plan-update.py" "$plan_file" "$next_pending_id" "pending" \
                   --set-flag "needs_review=true" 2>/dev/null || true
                 log "$pass_kind: pass halted -- >50% of batches failed ($pass_failed/$pass_completed). Run grinder.sh ack-review $next_pending_id to continue"
                 return 0
               fi
             fi
           fi
           ;;
        2) ;;  # skipped
      esac
    done

    # Post-pass: commit proposals.md for static_analysis passes (REQ-12)
    if [[ "$pass_kind" == "static_analysis" ]]; then
      static_commit_proposals
    fi

    # Post-pass: commit cve-review.md for CVE passes
    if [[ "$pass_kind" == "cve" ]]; then
      cve_commit_review
    fi
  done

  # After all passes: emit baseline + finalise deferred findings
  local all_complete
  all_complete=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
for p in d.get('passes', []):
    for b in p.get('batches', []):
        if b.get('status') in ('pending', 'in_progress', 'failed'):
            print('no'); import sys; sys.exit(0)
print('yes')
" 2>/dev/null) || all_complete="no"
  if [[ "$all_complete" == "yes" ]]; then
    python3 "$LIB_DIR/finalise-deferred.py" \
        --grinder-dir "$GRINDER_DIR" --schema-dir "$SCHEMA_DIR" 2>/dev/null || true
    python3 "$LIB_DIR/emit-baseline.py" \
        --project-dir "$PROJECT_DIR" --grinder-dir "$GRINDER_DIR" \
        --schema-dir "$SCHEMA_DIR" 2>/dev/null || true
  fi

  # Check if all remaining are blocked by failures (EC-7.5)
  local remaining_pending
  remaining_pending=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
count = 0
for p in d.get('passes', []):
    for b in p.get('batches', []):
        if b.get('status') == 'pending':
            count += 1
print(count)
")

  if [[ "$remaining_pending" -gt 0 && "$any_executed" == "false" ]]; then
    log "all remaining batches blocked by failed dependencies -- run completed"
  fi
}

# ── detect_abandoned() — two-pass scan for abandoned batches ──
# Reads: GRINDER_DIR (session)
# Returns: 0 to continue, 1 on error, 2 if in-progress batch found

detect_abandoned() {
  local events_file="$GRINDER_DIR/events.ndjson"
  if [[ ! -f "$events_file" ]]; then
    return 0
  fi

  local events
  events=$(read_events 2>/dev/null)

  if [[ -z "$events" ]]; then
    return 0
  fi

  # Find batches with started but no completion
  local started_batches
  started_batches=$(echo "$events" | jq -s '
    group_by(.batch) |
    map({
      batch: .[0].batch,
      events: [.[] | .event],
      started_ts: (map(select(.event == "started")) | last | .ts // null)
    }) |
    map(select(
      (.events | index("started")) != null and
      (.events | index("completed")) == null and
      (.events | index("failed")) == null and
      (.events | index("abandoned")) == null and
      (.events | index("deferred")) == null
    ))
  ')

  local num_started
  num_started=$(echo "$started_batches" | jq 'length')

  if [[ "$num_started" -eq 0 ]]; then
    return 0
  fi

  local now_epoch
  now_epoch=$(date +%s)
  local threshold_seconds="${GRINDER_ABANDON_THRESHOLD:-${GRINDER_BATCH_TIMEOUT:-1800}}"

  # First pass: mark all over-30-min batches as abandoned
  for ((i=0; i<num_started; i++)); do
    local batch_id started_ts
    batch_id=$(echo "$started_batches" | jq -r ".[$i].batch")
    started_ts=$(echo "$started_batches" | jq -r ".[$i].started_ts")

    local started_epoch elapsed
    started_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$started_ts" +%s 2>/dev/null || \
                    python3 -c "import sys; from datetime import datetime; print(int(datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$started_ts")
    elapsed=$((now_epoch - started_epoch))

    if [[ "$elapsed" -gt "$threshold_seconds" ]]; then
      local threshold_min=$((threshold_seconds / 60))
      transition_batch_status "$batch_id" "failed" \
        "event_type=abandoned" \
        "reason=no completion event within ${threshold_min} minutes" || return 1
      log "grinder: batch $batch_id marked abandoned (${elapsed}s elapsed)"
    fi
  done

  # Second pass: check for under-30-min in-progress
  for ((i=0; i<num_started; i++)); do
    local batch_id started_ts
    batch_id=$(echo "$started_batches" | jq -r ".[$i].batch")
    started_ts=$(echo "$started_batches" | jq -r ".[$i].started_ts")

    local started_epoch elapsed
    started_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$started_ts" +%s 2>/dev/null || \
                    python3 -c "import sys; from datetime import datetime; print(int(datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$started_ts")
    elapsed=$((now_epoch - started_epoch))

    if [[ "$elapsed" -le "$threshold_seconds" ]]; then
      local minutes=$((elapsed / 60))
      echo "batch $batch_id still in progress (${minutes}min ago) -- waiting for completion or timeout"
      return 2  # Signal: in-progress batch found
    fi
  done

  return 0
}

# ── print_run_summary() — end-of-run summary ──
# Reads: GRINDER_DIR (session)

print_run_summary() {
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  local summary
  summary=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
completed = failed = pending = deferred = 0
for p in d.get('passes', []):
    for b in p.get('batches', []):
        s = b.get('status', 'pending')
        if s == 'completed': completed += 1
        elif s == 'failed': failed += 1
        elif s == 'deferred': deferred += 1
        else: pending += 1
print(f'completed={completed} failed={failed} pending={pending} deferred={deferred}')
" "$plan_file")
  log "grinder run summary: $summary"
  dashboard_event "SessionEnd" "grinder" "$summary"
}

# ── cmd_discover() — read-only scan + plan generation (REQ-1..REQ-11) ──

cmd_discover() {
  # REQ-1.1: Validate pipeline.yaml exists
  if [[ ! -f "$PROJECT_DIR/pipeline.yaml" ]]; then
    echo "discover: no pipeline.yaml found in $PROJECT_DIR" >&2
    exit 1
  fi

  # REQ-1.2: Parse grinder block
  local manifest_json
  manifest_json=$(discover_parse_manifest "$PROJECT_DIR/pipeline.yaml") || true
  if [[ -z "$manifest_json" ]]; then
    echo "discover: no pipeline.grinder block in pipeline.yaml" >&2
    exit 1
  fi

  # REQ-4: Idempotency guard
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  local current_sha
  current_sha=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")
  if [[ -f "$plan_file" ]]; then
    local plan_sha=""
    plan_sha=$(python3 -c "
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        d = yaml.safe_load(f)
    print(d.get('git_sha_at_start', '') if isinstance(d, dict) else '')
except Exception:
    print('')
" "$plan_file" 2>/dev/null) || true
    if [[ -n "$plan_sha" && "$plan_sha" == "$current_sha" ]]; then
      echo "plan is current"
      exit 0
    fi
  fi

  # New cycle starting (plan absent OR plan_sha != current_sha). Archive
  # the prior cycle's append-only logs so dashboard consumers don't read
  # mixed-cycle data. See tests/test_grinder_archive_prior_cycle.sh and
  # dashboard/server/grinder_helpers.py:_extract_batch_timing for the
  # downstream consequences when this step is skipped.
  _archive_prior_cycle_logs

  # Extract scanner keys and configuration from manifest
  local scanner_keys never_touch_json
  scanner_keys=$(echo "$manifest_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
findings = data.get('findings', {})
non_tool = {'fix_rules_allowlist', 'never_touch_files'}
for k in findings:
    if k not in non_tool:
        print(k)
")
  never_touch_json=$(echo "$manifest_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
findings = data.get('findings', {})
print(json.dumps(findings.get('never_touch_files', [])))
")

  # Create scanner-output directory (REQ-3.1)
  mkdir -p "$GRINDER_DIR/scanner-output"

  # Run scanners
  local merged_tmp
  merged_tmp=$(mktemp "${TMPDIR:-/tmp}/grinder-merged-XXXXXX.json")
  echo "[]" > "$merged_tmp"
  local any_findings=false

  while IFS= read -r scanner; do
    [[ -z "$scanner" ]] && continue

    # EC-2.1: Check scanner binary exists
    local runner
    runner=$(discover_resolve_runner "$scanner")
    local binary="${runner%% *}"
    if ! command -v "$binary" >/dev/null 2>&1; then
      echo "discover: $scanner not found -- skipping" >&2
      continue
    fi

    # Collect files for this scanner
    local paths_json
    paths_json=$(echo "$manifest_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
findings = data.get('findings', {})
scanner_config = findings.get(sys.argv[1], {})
if isinstance(scanner_config, dict):
    print(json.dumps(scanner_config.get('paths', [])))
else:
    print('[]')
" "$scanner")

    local -a file_list=()
    if ! _scanner_is_project_wide "$scanner"; then
      while IFS= read -r f; do
        [[ -n "$f" ]] && file_list+=("$f")
      done < <(cd "$PROJECT_DIR" && discover_collect_files "$scanner" "$paths_json" "$never_touch_json")

      # EC-2.2: Skip if no files
      if [[ ${#file_list[@]} -eq 0 ]]; then
        log "discover: $scanner -- no files found, skipping"
        continue
      fi
    fi

    # Run scanner (REQ-2.3), store raw output (REQ-3.1)
    local raw_file="$GRINDER_DIR/scanner-output/${scanner}.json"
    local scanner_exit=0

    # Determine output file extension
    case "$scanner" in
      mypy|tsc) raw_file="$GRINDER_DIR/scanner-output/${scanner}.txt" ;;
    esac

    # Execute scanner, redirecting output to file
    if _scanner_is_project_wide "$scanner"; then
      (cd "$PROJECT_DIR" && discover_run_scanner "$scanner" > "$raw_file" 2>/dev/null) || scanner_exit=$?
    else
      (cd "$PROJECT_DIR" && discover_run_scanner "$scanner" "${file_list[@]}" > "$raw_file" 2>/dev/null) || scanner_exit=$?
    fi

    # REQ-3.3: Non-zero exit handling
    if [[ $scanner_exit -ne 0 ]]; then
      if [[ ! -s "$raw_file" ]]; then
        echo "discover: $scanner failed with exit $scanner_exit and no output -- skipping" >&2
        rm -f "$raw_file"
        continue
      fi
      # Non-zero with output: accept and continue
    fi

    # REQ-3.2: Normalise via normalise-findings.py
    local normalised
    normalised=$(cat "$raw_file" | python3 "$TOOLS_DIR/normalise-findings.py" --tool "$scanner" --project-root "$PROJECT_DIR" 2>/dev/null) || {
      echo "discover: normalise-findings.py failed for $scanner -- skipping" >&2
      continue
    }

    # Merge findings
    if [[ -n "$normalised" && "$normalised" != "[]" ]]; then
      any_findings=true
      python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    existing = json.load(f)
new = json.loads(sys.argv[2])
existing.extend(new)
with open(sys.argv[1], 'w') as f:
    json.dump(existing, f)
" "$merged_tmp" "$normalised"
    fi

  done <<< "$scanner_keys"

  # Coverage discovery — runs after scanner discovery
  local coverage_files_json=""
  coverage_files_json=$(_coverage_discover_files "$manifest_json" "$PROJECT_DIR" "$LIB_DIR" 2>/dev/null) || coverage_files_json=""

  # REQ-10: Zero findings handling — exit only when BOTH empty
  if [[ "$any_findings" == "false" ]] && [[ -z "$coverage_files_json" || "$coverage_files_json" == "{}" ]]; then
    rm -f "$merged_tmp"
    echo "discover: zero findings -- nothing to grind"
    exit 0
  fi

  # REQ-5/REQ-7: Generate plan via grinder-discover.py
  local findings_tmp
  findings_tmp="$merged_tmp"

  local project_name
  project_name=$(basename "$PROJECT_DIR")

  local -a discover_extra_args=()
  if [[ -n "$coverage_files_json" && "$coverage_files_json" != "{}" ]]; then
    discover_extra_args+=("--coverage-files" "$coverage_files_json")
  fi

  local plan_exit=0
  python3 "$LIB_DIR/grinder-discover.py" \
    --project-dir "$PROJECT_DIR" \
    --grinder-dir "$GRINDER_DIR" \
    --schema-dir "$SCHEMA_DIR" \
    --tools-dir "$TOOLS_DIR" \
    --findings-json "$findings_tmp" \
    --project-name "$project_name" \
    --git-sha "$current_sha" \
    "${discover_extra_args[@]+"${discover_extra_args[@]}"}" 2>&1 || plan_exit=$?

  rm -f "$findings_tmp"

  if [[ $plan_exit -ne 0 ]]; then
    echo "discover: plan generation failed"
    exit 1
  fi

  # Discover used to commit grinder-plan.yaml + scanner-output/ as an
  # audit trail (REQ-6). Both paths were moved to .gitignore in commit
  # c9cf24f (2026-05-12) because every discover regenerates them — the
  # per-batch `fix(grinder): pass-N-autofix` commits are the actual code
  # audit trail, and *.<sha>.bak archives preserve prior-cycle event +
  # stream logs. The lock acquisition is retained as a no-op placeholder
  # in case future code needs the cycle-boundary serialisation; it
  # releases immediately.
  local lock_file="$GRINDER_DIR/.grinder.lock"
  acquire_merge_lock "$lock_file" || {
    echo "discover: could not acquire grinder lock"
    exit 1
  }
  release_merge_lock "$lock_file"

  # Print summary (REQ-6.3)
  local batch_count estimated_hours summary_line
  summary_line=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
print(d.get('estimated_batches', 0))
print(d.get('estimated_hours', 0))
" "$plan_file")
  batch_count=$(echo "$summary_line" | head -n1)
  estimated_hours=$(echo "$summary_line" | tail -n1)
  echo "$batch_count batches, estimated ${estimated_hours}h. Run grinder.sh run to proceed."
}

# ── cmd_status() — three-branch status display (REQ-3) ──

cmd_status() {
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"

  if [[ ! -f "$plan_file" ]]; then
    echo "no active plan -- run grinder.sh discover first"
    exit 0
  fi

  local state_file="$GRINDER_DIR/grinder-state.json"
  if [[ ! -f "$state_file" ]]; then
    # Plan exists, no state — show plan summary
    local summary
    summary=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
passes = len(d.get('passes', []))
batches = sum(len(p.get('batches', [])) for p in d.get('passes', []))
hours = d.get('estimated_hours', 0)
print(f'{passes} passes, {batches} batches, estimated {hours}h')
")
    echo "$summary"
    echo "state: not started -- run grinder.sh run"
    exit 0
  fi

  # Both exist — full status
  local state
  state=$(read_state) || { echo "$state"; exit 1; }

  local current_pass completed failed_count pending deferred last_updated paused
  current_pass=$(echo "$state" | jq -r '.current_pass')
  completed=$(echo "$state" | jq -r '.batches_completed')
  failed_count=$(echo "$state" | jq -r '.batches_failed')
  pending=$(echo "$state" | jq -r '.batches_pending')
  deferred=$(echo "$state" | jq -r '.batches_deferred // 0')
  last_updated=$(echo "$state" | jq -r '.last_updated')
  paused=$(echo "$state" | jq -r '.paused // false')

  echo "current pass: $current_pass"
  echo "completed: $completed  failed: $failed_count  pending: $pending  deferred: $deferred"
  echo "last updated: $last_updated"
  if [[ "$paused" == "true" ]]; then
    echo "status: PAUSED"
  fi
  exit 0
}

# ── cmd_pause() — creates PAUSE sentinel (REQ-6) ──

cmd_pause() {
  mkdir -p "$GRINDER_DIR"
  touch "$GRINDER_DIR/PAUSE"
  echo "grinder paused -- remove $GRINDER_DIR/PAUSE or run grinder.sh resume to continue"
  exit 0
}

# ── cmd_run() — main execution entry point (REQ-4,5,6,7,12) ──

cmd_run() {
  mkdir -p "$GRINDER_DIR"

  # Check pause
  if [[ -f "$GRINDER_DIR/PAUSE" ]]; then
    echo "grinder is paused -- remove $GRINDER_DIR/PAUSE or run grinder.sh resume to continue"
    exit 0
  fi

  # Validate plan (REQ-4)
  local validation_msg
  if validation_msg=$(validate_plan 2>&1); then
    :
  else
    echo "$validation_msg"
    exit 1
  fi

  # Read plan for staleness check
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  local plan_sha threshold
  plan_sha=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
print(d.get('git_sha_at_start', ''))
")
  threshold=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
print(d.get('staleness_commit_threshold', 1))
")

  # Check staleness (REQ-5)
  local stale_msg
  if ! stale_msg=$(check_staleness "$plan_sha" "$threshold" 2>&1); then
    echo "$stale_msg"
    exit 1
  fi

  # Check for corrupt state (REQ-9)
  local state_file="$GRINDER_DIR/grinder-state.json"
  if [[ -f "$state_file" ]]; then
    local state_check
    if ! state_check=$(read_state 2>&1); then
      echo "$state_check"
      exit 1
    fi
    if [[ "$state_check" == *"corrupt"* ]]; then
      echo "$state_check"
      exit 1
    fi

    # Validate current_pass references valid pass (EC-9.2)
    if [[ -n "$state_check" ]]; then
      local current_pass
      current_pass=$(echo "$state_check" | jq -r '.current_pass')
      local pass_valid
      pass_valid=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
pass_ids = [p['id'] for p in d.get('passes', [])]
print('yes' if sys.argv[2] in pass_ids else 'no')
" "$plan_file" "$current_pass")
      if [[ "$pass_valid" == "no" ]]; then
        echo "grinder-state.json references unknown pass $current_pass -- delete state to restart"
        exit 1
      fi
    fi
  fi

  # Auth preflight (grinder-auth-recovery R1.1, R1.5). Runs after pause /
  # validate / staleness / state checks but BEFORE lock acquisition so a
  # failed probe does not hold a lock that the trap then has to release.
  auth_preflight_probe

  # Acquire lock (REQ-12)
  if ! acquire_grinder_lock; then
    exit 1
  fi
  setup_traps

  # Set session globals (REQ-14)
  local project_name
  project_name=$(basename "$PROJECT_DIR")
  AUTOPILOT_SID="grinder-${project_name}-$(date +%s)"
  export AUTOPILOT_SID
  export DASHBOARD_DATA="${CLAUDE_DASHBOARD_DATA:-${PROJECTS_ROOT}/dotfiles/dashboard/data/sessions.jsonl}"
  export STREAM_FILE="$GRINDER_DIR/grinder-stream.ndjson"
  export ALLOWED_TOOLS="Read,Edit,Write,Bash,Grep,Glob"

  dashboard_event "SessionStart" "grinder" "Starting grinder for ${project_name}"

  log "Grinder started for project: ${project_name}"
  log "Plan: ${GRINDER_DIR}/grinder-plan.yaml"
  log "Stream: ${STREAM_FILE}"

  # Init state (REQ-7.1, REQ-15)
  init_state "run"

  # Run batch loop (REQ-7.3-7.6)
  run_batch_loop

  # Print summary (REQ-7.6)
  print_run_summary
}

# ── cmd_resume() — continue after crash/interruption (REQ-4,5,6,11,12) ──

cmd_resume() {
  mkdir -p "$GRINDER_DIR"

  # Remove PAUSE if present (REQ-6)
  if [[ -f "$GRINDER_DIR/PAUSE" ]]; then
    rm -f "$GRINDER_DIR/PAUSE"
    echo "pause cleared -- resuming"
  fi

  # Validate plan (REQ-4)
  local validation_msg
  if validation_msg=$(validate_plan 2>&1); then
    :
  else
    echo "$validation_msg"
    exit 1
  fi

  # Read plan for staleness check
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  local plan_sha threshold
  plan_sha=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
print(d.get('git_sha_at_start', ''))
")
  threshold=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
print(d.get('staleness_commit_threshold', 1))
")

  # Check staleness (REQ-5)
  local stale_msg
  if ! stale_msg=$(check_staleness "$plan_sha" "$threshold" 2>&1); then
    echo "$stale_msg"
    exit 1
  fi

  # Check for corrupt state (REQ-9)
  local state_file="$GRINDER_DIR/grinder-state.json"
  if [[ -f "$state_file" ]]; then
    local state_check
    if ! state_check=$(read_state 2>&1); then
      echo "$state_check"
      exit 1
    fi
    if [[ "$state_check" == *"corrupt"* ]]; then
      echo "$state_check"
      exit 1
    fi

    # Validate current_pass references valid pass (EC-9.2)
    if [[ -n "$state_check" ]]; then
      local current_pass
      current_pass=$(echo "$state_check" | jq -r '.current_pass')
      local pass_valid
      pass_valid=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
pass_ids = [p['id'] for p in d.get('passes', [])]
print('yes' if sys.argv[2] in pass_ids else 'no')
" "$plan_file" "$current_pass")
      if [[ "$pass_valid" == "no" ]]; then
        echo "grinder-state.json references unknown pass $current_pass -- delete state to restart"
        exit 1
      fi
    fi
  fi

  # Detect abandoned batches (REQ-11)
  local detect_rc=0
  detect_abandoned || detect_rc=$?
  if [[ $detect_rc -eq 2 ]]; then
    # In-progress batch found under 30 min — exit 0 (AS-6)
    exit 0
  elif [[ $detect_rc -ne 0 ]]; then
    exit 1
  fi

  # Auth preflight (grinder-auth-recovery R1.1, R1.5). Runs after pause /
  # validate / staleness / state checks but BEFORE lock acquisition so a
  # failed probe does not hold a lock that the trap then has to release.
  auth_preflight_probe

  # Acquire lock (REQ-12)
  if ! acquire_grinder_lock; then
    exit 1
  fi
  setup_traps

  # Set session globals (REQ-14)
  local project_name
  project_name=$(basename "$PROJECT_DIR")
  AUTOPILOT_SID="grinder-${project_name}-$(date +%s)"
  export AUTOPILOT_SID
  export DASHBOARD_DATA="${CLAUDE_DASHBOARD_DATA:-${PROJECTS_ROOT}/dotfiles/dashboard/data/sessions.jsonl}"
  export STREAM_FILE="$GRINDER_DIR/grinder-stream.ndjson"
  export ALLOWED_TOOLS="Read,Edit,Write,Bash,Grep,Glob"

  dashboard_event "SessionStart" "grinder" "Resuming grinder for ${project_name}"

  log "Grinder resuming for project: ${project_name}"
  log "Plan: ${GRINDER_DIR}/grinder-plan.yaml"
  log "Stream: ${STREAM_FILE}"

  # Init state (REQ-13.1 — reconstruct from events if needed)
  init_state "resume"

  # Check if anything to do (EC-11.2)
  local remaining
  remaining=$(python3 -c "
import yaml
with open('$plan_file') as f:
    d = yaml.safe_load(f)
count = 0
for p in d.get('passes', []):
    for b in p.get('batches', []):
        if b.get('status') == 'pending':
            count += 1
print(count)
")
  if [[ "$remaining" -eq 0 ]]; then
    echo "no batches to process"
    exit 0
  fi

  # Run batch loop
  run_batch_loop

  # Print summary
  print_run_summary
}

# ── cmd_ack_review() — clear needs_review flag on a batch (REQ-16) ──

cmd_ack_review() {
  local batch_id="$1"

  if [[ -z "$batch_id" ]]; then
    echo "ack-review: missing batch_id"
    echo "usage: grinder.sh ack-review <batch_id>"
    exit 1
  fi

  local plan_file="$GRINDER_DIR/grinder-plan.yaml"
  if [[ ! -f "$plan_file" ]]; then
    echo "ack-review: no active plan -- run grinder.sh discover first"
    exit 1
  fi

  # Check batch exists and read its state
  local batch_info
  batch_info=$(python3 -c "
import yaml, sys, json
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
for p in d.get('passes', []):
    for b in p.get('batches', []):
        if b['id'] == sys.argv[2]:
            print(json.dumps({'status': b.get('status'), 'needs_review': b.get('needs_review', False)}))
            sys.exit(0)
print('NOT_FOUND')
" "$plan_file" "$batch_id")

  if [[ "$batch_info" == "NOT_FOUND" ]]; then
    echo "ack-review: batch $batch_id not found in plan"
    exit 1
  fi

  local status needs_review
  status=$(echo "$batch_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
  needs_review=$(echo "$batch_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['needs_review'])")

  # Check if batch is already completed/failed
  case "$status" in
    completed|failed|deferred)
      echo "ack-review: batch $batch_id is already $status"
      exit 1
      ;;
  esac

  # Check if batch needs review
  if [[ "$needs_review" != "True" ]]; then
    echo "ack-review: batch $batch_id does not require review"
    exit 1
  fi

  # Clear the flag via grinder-plan-update.py
  if ! python3 "$LIB_DIR/grinder-plan-update.py" "$plan_file" "$batch_id" "$status" \
       --set-flag "needs_review=false"; then
    echo "ack-review: failed to update plan"
    exit 1
  fi

  echo "ack-review: batch $batch_id cleared for processing"
  exit 0
}

# ── main() — argument parsing, subcommand dispatch (REQ-1) ──

main() {
  local subcommand=""
  local ack_review_batch_id=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-dir)
        shift
        PROJECT_DIR="${1:-.}"
        ;;
      --grinder-dir)
        shift
        GRINDER_DIR="${1:-docs/grinder}"
        ;;
      discover|run|resume|pause|status|ack-review)
        subcommand="$1"
        ;;
      -*)
        echo "unknown option: $1"
        echo "usage: grinder.sh <discover|run|resume|pause|status|ack-review> [--project-dir PATH] [--grinder-dir PATH]"
        exit 1
        ;;
      *)
        if [[ -z "$subcommand" ]]; then
          echo "unknown subcommand: $1"
          echo "usage: grinder.sh <discover|run|resume|pause|status|ack-review> [--project-dir PATH] [--grinder-dir PATH]"
          exit 1
        fi
        # Capture batch_id for ack-review
        if [[ "$subcommand" == "ack-review" && -z "$ack_review_batch_id" ]]; then
          ack_review_batch_id="$1"
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$subcommand" ]]; then
    echo "usage: grinder.sh <discover|run|resume|pause|status|ack-review> [--project-dir PATH] [--grinder-dir PATH]"
    exit 1
  fi

  # Resolve project-dir
  if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "project-dir $PROJECT_DIR does not exist"
    exit 1
  fi
  PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)

  # Trust boundary check (EC-1.4)
  local resolved_root="${PROJECTS_ROOT%/}/"
  local resolved_project="${PROJECT_DIR%/}/"
  if [[ "$resolved_project" != "$resolved_root"* ]]; then
    echo "project-dir $PROJECT_DIR is outside trust boundary ($PROJECTS_ROOT)"
    exit 1
  fi

  # Resolve grinder-dir (relative to project-dir)
  if [[ "$GRINDER_DIR" != /* ]]; then
    GRINDER_DIR="$PROJECT_DIR/$GRINDER_DIR"
  fi

  # Trust boundary check for grinder-dir (EC-1.4)
  local resolved_gdir="${GRINDER_DIR%/}/"
  if [[ "$resolved_gdir" != "$resolved_root"* ]]; then
    echo "grinder-dir $GRINDER_DIR is outside trust boundary ($PROJECTS_ROOT)"
    exit 1
  fi
  export GRINDER_DIR

  # Dispatch
  case "$subcommand" in
    discover)    cmd_discover ;;
    run)         cmd_run ;;
    resume)      cmd_resume ;;
    pause)       cmd_pause ;;
    status)      cmd_status ;;
    ack-review)  cmd_ack_review "$ack_review_batch_id" ;;
  esac
}

# Run main only when executed directly. The sourcing guard lets tests
# source this file to unit-test individual functions (e.g. auth_preflight_probe)
# without triggering the dispatcher. Note: sourcing grinder.sh also pulls
# in claude-session-lib.sh (line 66) — that dependency is required for
# auth_preflight_probe (which calls _resolve_timeout_bin and
# _auth_failed_classify from the lib).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
