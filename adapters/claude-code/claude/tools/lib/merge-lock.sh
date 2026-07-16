#!/usr/bin/env bash
# Shared merge-lock functions. Source this file; do not execute directly.
# Used by autopilot-chain.sh and autopilot.sh for merge serialization.

acquire_merge_lock() {
  local lock_file="$1"
  local max_wait="${MERGE_LOCK_MAX_WAIT:-300}"  # 5 minutes default
  local waited=0

  while ! shlock -f "$lock_file" -p $$; do
    # Check if holder PID is alive (stale lock detection)
    local holder_pid
    holder_pid=$(cat "$lock_file" 2>/dev/null)
    if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
      # TOCTOU: PID could be reused between kill -0 and rm. Retry loop mitigates.
      rm -f "$lock_file"  # Stale lock — remove it
      continue  # Re-attempt shlock immediately (no sleep)
    fi

    local jitter=$((2 + RANDOM % 3))
    sleep "$jitter"
    waited=$((waited + jitter))
    if [[ $waited -ge $max_wait ]]; then
      # Exit code 2 = "blocked / operator-resolvable" per the chain
      # contract. The caller (autopilot.sh) maps this to PIPELINE_STATUS
      # =blocked and the chain orchestrator routes the task to
      # blocked_tasks (auto-resume on next chain run when the holder
      # finishes), instead of failed_tasks (would require --retry-failed).
      echo "ERROR: merge lock timeout after ${max_wait}s — another finalize is taking unusually long" >&2
      return 2
    fi
  done
}

release_merge_lock() {
  rm -f "$1"
}
