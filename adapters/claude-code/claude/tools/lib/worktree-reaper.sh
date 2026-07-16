#!/usr/bin/env bash
# worktree-reaper.sh — kill processes whose cwd is inside a worktree before
# the worktree is destroyed.
#
# Source-only library. Exposes one public function:
#
#   reap_worktree_orphans <path>
#
# Behaviour:
#   - Resolves <path> to an absolute, symlink-resolved directory (pwd -P).
#   - Enumerates every PID whose cwd is at or below the resolved path
#     (lsof -a -d cwd +D on macOS; /proc/$pid/cwd fallback on Linux).
#   - Excludes $$ and $PPID so the manual `worktree.sh rm` flow cannot
#     self-terminate mid-script.
#   - Sends SIGTERM to each remaining PID, sleeps WORKTREE_REAPER_GRACE_SECONDS,
#     then SIGKILLs any survivor.
#   - Emits one stderr audit line per signal sent, prefixed
#     `reap_worktree_orphans:` so it can be greppped in autopilot streams.
#
# Exit codes:
#   0 — success (including silent no-op for empty arg, missing dir, no
#       processes found, or ESRCH races)
#   1 — refusal: missing tool (lsof and /proc both unavailable) or unsafe
#       path (empty / "/" / outside $PROJECTS_ROOT)
#
# Boundary guard: a path that resolves outside ${PROJECTS_ROOT:-$HOME/Projekter}
# is rejected. This prevents a bug that passes "" or "/" from enumerating
# every process on the host.
#
# $PROJECTS_ROOT is read INSIDE the function at call time — not snapshotted
# as a top-level readonly — so tests and future callers can override it
# without re-sourcing in a fresh subshell.

# Idempotent re-source guard: avoid `readonly` re-assignment errors when
# multiple scripts in the same shell session source the helper.
[[ -n "${WORKTREE_REAPER_LOADED:-}" ]] && return 0

readonly WORKTREE_REAPER_GRACE_SECONDS=2
readonly WORKTREE_REAPER_TERM_SIGNAL=TERM
readonly WORKTREE_REAPER_KILL_SIGNAL=KILL
readonly WORKTREE_REAPER_LOADED=1

reap_worktree_orphans() {
  local path="${1:-}"

  # R4 spirit / R7 — empty arg is "no work requested".
  [[ -z "$path" ]] && return 0

  # R7 — non-existent or non-directory path is silent no-op.
  [[ ! -d "$path" ]] && return 0

  # R2 — resolve via `pwd -P` so symlinks normalise to realpath.
  local resolved
  resolved=$(cd "$path" 2>/dev/null && pwd -P) || return 0
  [[ -z "$resolved" ]] && return 0

  # E5 — boundary guard. Read PROJECTS_ROOT fresh at call time.
  local boundary="${PROJECTS_ROOT:-$HOME/Projekter}"
  if [[ "$resolved" == "/" || "$resolved" != "$boundary"/* ]]; then
    echo "reap_worktree_orphans: refusing to scan path outside PROJECTS_ROOT: $resolved" >&2
    return 1
  fi

  # R3, R8 — discovery. Prefer lsof on macOS; fall back to /proc on Linux.
  # Newline-delimited strings (parallel arrays) instead of a real bash 3.2
  # associative array so callers under `set -u` don't trip empty-`[@]`.
  #
  # Two parallel lists keyed by record index:
  #   pids_raw[i]   — the worktree-cwd pid (lsof p-field)
  #   ppids_raw[i]  — that pid's ppid       (lsof R-field, macOS) / proc/stat
  # ppids_raw is used by the E1 sibling-spare check below.
  local pids_raw="" ppids_raw=""
  if command -v lsof >/dev/null 2>&1; then
    local lsof_out lsof_rc=0
    lsof_out=$(lsof -a -d cwd +D "$resolved" -F pR 2>/dev/null) || lsof_rc=$?
    # E6 — lsof exits 1 when the directory has no matching open files;
    # treat 0 and 1 as success, ≥2 as failure.
    if (( lsof_rc >= 2 )); then
      echo "reap_worktree_orphans: lsof failed with exit $lsof_rc on $resolved" >&2
      return 1
    fi
    # Parse lsof -F pR. Each process record starts with `p<pid>` followed
    # by `R<ppid>` and then per-fd records (`f`, `t`, `n`). When we see
    # the next `p` line we know the previous record is complete.
    local line cur_pid="" cur_ppid=""
    while IFS= read -r line; do
      case "$line" in
        p*)
          if [[ -n "$cur_pid" ]]; then
            pids_raw+="$cur_pid"$'\n'
            ppids_raw+="${cur_ppid:-0}"$'\n'
          fi
          cur_pid="${line:1}"
          cur_ppid=""
          ;;
        R*)
          cur_ppid="${line:1}"
          ;;
      esac
    done <<<"$lsof_out"
    if [[ -n "$cur_pid" ]]; then
      pids_raw+="$cur_pid"$'\n'
      ppids_raw+="${cur_ppid:-0}"$'\n'
    fi
  elif [[ -d /proc ]]; then
    # Linux fallback. Walk /proc/[0-9]*/cwd and keep pids whose cwd is
    # the resolved path or a descendant. ppid is field 4 of /proc/<pid>/stat
    # (after pid and comm; comm is wrapped in parens and may contain spaces,
    # so we anchor on the closing paren). Q3 — portability courtesy; not
    # exercised by the macOS test suite.
    local proc_pid proc_cwd proc_ppid stat_line
    for proc_pid in /proc/[0-9]*; do
      proc_cwd=$(readlink "$proc_pid/cwd" 2>/dev/null) || continue
      if [[ "$proc_cwd" == "$resolved" || "$proc_cwd" == "$resolved"/* ]]; then
        stat_line=$(cat "$proc_pid/stat" 2>/dev/null)
        # stat = "PID (comm) STATE PPID ..." — split on last `) ` so a
        # comm with spaces or parens doesn't break parsing.
        proc_ppid="${stat_line##*) }"
        proc_ppid="${proc_ppid%% *}"
        # That extracts STATE; the next field is PPID. Re-split.
        proc_ppid="${stat_line##*) }"
        # shellcheck disable=SC2206
        local _stat_fields=( $proc_ppid )
        proc_ppid="${_stat_fields[1]:-0}"
        pids_raw+="${proc_pid##*/}"$'\n'
        ppids_raw+="$proc_ppid"$'\n'
      fi
    done
  else
    echo "reap_worktree_orphans: lsof not found — cannot enumerate cwd holders" >&2
    return 1
  fi

  # E1 — never reap:
  #   (a) our own pid or our caller's pid (manual `worktree.sh rm` self-
  #       termination guard, original E1 contract; covered by T7), OR
  #   (b) a worktree-cwd process whose ppid equals our caller's pid —
  #       i.e. a sibling of the reaper inside the caller's process tree.
  #
  # (b) is the Backlog #62 fix. The reaper is called from commit-finalize.sh:359,
  # whose siblings include autopilot.sh:944's tee0 (which holds autopilot.sh's
  # stdout pipe) and spawn_result_watchdog's `(...) &` subshell. Killing
  # tee0 sends SIGPIPE up autopilot.sh's stdout fd → exit 141 immediately
  # after a clean merge. Sparing direct children of $PPID closes the cascade
  # without weakening the orphan-cleanup contract: true orphans have ppid=1
  # (kernel reparented after their parent died) and remain unfiltered.
  #
  # ppid comes from lsof's R-field (or /proc/<pid>/stat on Linux) — never
  # from `ps` — so the check works under sandboxes that block /bin/ps.
  local self_pid="$$" caller_pid="${PPID:-0}"
  local filtered_raw="" pid ppid i=0
  # Read pids and ppids in lockstep. mapfile would be cleanest but is
  # bash 4+; emulate with two readarrays via process substitution.
  local -a _pids _ppids
  while IFS= read -r line; do _pids+=( "$line" ); done <<<"$pids_raw"
  while IFS= read -r line; do _ppids+=( "$line" ); done <<<"$ppids_raw"
  for (( i=0; i<${#_pids[@]}; i++ )); do
    pid="${_pids[$i]}"
    ppid="${_ppids[$i]:-0}"
    [[ -z "$pid" ]] && continue
    if [[ "$pid" == "$self_pid" || "$pid" == "$caller_pid" ]]; then
      continue
    fi
    if [[ "$ppid" == "$caller_pid" ]]; then
      continue
    fi
    filtered_raw+="$pid"$'\n'
  done

  # R4 — empty list after exclusion is silent success.
  [[ -z "$filtered_raw" ]] && return 0

  # R5 — TERM phase. Capture cmdline first for the audit line so a fast
  # exit between signal and ps doesn't lose the context.
  local cmd
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    cmd=$(ps -o command= -p "$pid" 2>/dev/null | head -c 200)
    [[ -z "$cmd" ]] && cmd="unknown"
    # E3 — kill against an already-dead pid returns ESRCH; treat as success.
    if kill -"$WORKTREE_REAPER_TERM_SIGNAL" "$pid" 2>/dev/null; then
      echo "reap_worktree_orphans: SIGTERM pid=$pid cmd=$cmd" >&2
    fi
  done <<<"$filtered_raw"

  # Grace before SIGKILL.
  sleep "$WORKTREE_REAPER_GRACE_SECONDS"

  # R5 — KILL phase for survivors only.
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      cmd=$(ps -o command= -p "$pid" 2>/dev/null | head -c 200)
      [[ -z "$cmd" ]] && cmd="unknown"
      kill -"$WORKTREE_REAPER_KILL_SIGNAL" "$pid" 2>/dev/null || true
      echo "reap_worktree_orphans: SIGKILL pid=$pid cmd=$cmd" >&2
    fi
  done <<<"$filtered_raw"

  return 0
}
