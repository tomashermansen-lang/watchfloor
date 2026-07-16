#!/usr/bin/env bash
set -euo pipefail

# ── finalize-plan.sh ──
# Operator-facing equivalents of the chain's internal plan-finalization steps.
#
# Background (see CONTINUATION_chain-pipeline-friction.md section C):
# autopilot-chain.sh halts when a phase gate is blocked on `kind: human`
# items (manual smoke tests). The operator runs the smokes, but the chain's
# "Gate blocked" banner gives no recovery path. This helper exposes the two
# steps the operator needs:
#
#   approve-gate <plan-yaml> <phase-id>
#       Flip gate.passed:false → passed:true for the named phase and commit.
#       Idempotent: already-passed gate is a no-op (exit 0, no commit).
#
#   mark-done <plan-dir>
#       git mv docs/INPROGRESS_Plan_<x> → docs/DONE_Plan_<x> and commit.
#       Idempotent: already-DONE plan is a no-op.
#
# Both subcommands print a one-line confirmation on success and a
# self-contained error on failure. Designed to be quoted verbatim from the
# chain's recovery banner — no flags, no setup, no environment assumptions.

_print_usage() {
  cat <<'EOF' >&2
Usage:
  finalize-plan.sh approve-gate <plan-yaml> <phase-id>
  finalize-plan.sh mark-done <plan-dir>

Examples:
  finalize-plan.sh approve-gate docs/INPROGRESS_Plan_foo/execution-plan.yaml smoke
  finalize-plan.sh mark-done docs/INPROGRESS_Plan_foo
EOF
}

_die() {
  printf '✗ %s\n' "$1" >&2
  exit 1
}

# Sub-shell helper: commit only the named path with the given message,
# silently. Returns the resulting commit SHA on stdout (empty if nothing
# was staged). Skips commit if the working tree is unchanged for that path.
_commit_path() {
  local path=$1 msg=$2 repo_root
  repo_root=$(git -C "$(dirname "$path")" rev-parse --show-toplevel 2>/dev/null) \
    || _die "not inside a git repository: $path"
  ( cd "$repo_root" && \
    git add "${path#$repo_root/}" >/dev/null 2>&1 && \
    if ! git diff --cached --quiet -- "${path#$repo_root/}" 2>/dev/null; then
      git commit -m "$msg" >/dev/null 2>&1 || return 1
    fi )
}

cmd_approve_gate() {
  local yaml_file=${1:-} phase_id=${2:-}
  [[ -n "$yaml_file" && -n "$phase_id" ]] || { _print_usage; exit 1; }
  [[ -f "$yaml_file" ]] || _die "plan file not found: $yaml_file"

  # Match the same regex autopilot-chain.sh uses internally so format
  # preservation is identical (see autopilot-chain.sh evaluate_gate).
  python3 - "$yaml_file" "$phase_id" <<'PY' || _die "phase '$2' not found in $1, or gate already passed"
import re, sys
yaml_file, phase_id = sys.argv[1], sys.argv[2]
with open(yaml_file) as f:
    content = f.read()
# Find the phase block at all
if not re.search(r'(?m)^- id: ' + re.escape(phase_id) + r'\b', content):
    sys.exit(2)  # phase not found
# Try to flip passed: false → true
pattern = r'(- id: ' + re.escape(phase_id) + r'\n(?:[ \t].*\n|\n)*?[ \t]+passed: )false'
new_content, n = re.subn(pattern, r'\g<1>true', content, count=1)
if n == 1:
    with open(yaml_file, 'w') as f:
        f.write(new_content)
    print('flipped')
    sys.exit(0)
# Already true (idempotent path) — exit 0 with marker
already_true = re.search(
    r'- id: ' + re.escape(phase_id) + r'\n(?:[ \t].*\n|\n)*?[ \t]+passed: true',
    content,
)
if already_true:
    print('already-passed')
    sys.exit(0)
# Phase has no gate at all — treat as already done
print('no-gate')
sys.exit(0)
PY

  local result
  result=$(python3 - "$yaml_file" "$phase_id" <<'PY'
import re, sys
yaml_file, phase_id = sys.argv[1], sys.argv[2]
with open(yaml_file) as f:
    content = f.read()
m = re.search(
    r'- id: ' + re.escape(phase_id) + r'\n(?:[ \t].*\n|\n)*?[ \t]+passed: true',
    content,
)
print('ok' if m else 'fail')
PY
)
  [[ "$result" == "ok" ]] || _die "approve-gate did not produce 'passed: true' for $phase_id"

  # Commit only if the file actually changed in the working tree.
  local repo_root
  repo_root=$(git -C "$(dirname "$yaml_file")" rev-parse --show-toplevel 2>/dev/null) \
    || _die "not inside a git repository: $yaml_file"
  local rel_path
  rel_path=$(cd "$repo_root" && git ls-files --full-name -- "$yaml_file" 2>/dev/null \
    || realpath --relative-to="$repo_root" "$yaml_file" 2>/dev/null \
    || python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$yaml_file" "$repo_root")
  ( cd "$repo_root"
    if git diff --quiet -- "$rel_path" 2>/dev/null; then
      printf '✓ gate %s already passed (no-op)\n' "$phase_id"
    else
      git add "$rel_path" >/dev/null 2>&1
      git commit -m "chore(gate): $phase_id passed" >/dev/null 2>&1 \
        || _die "git commit failed for $rel_path"
      printf '✓ gate %s flipped to passed (committed)\n' "$phase_id"
    fi )
}

cmd_mark_done() {
  local plan_dir=${1:-}
  [[ -n "$plan_dir" ]] || { _print_usage; exit 1; }
  # Strip trailing slash for consistent matching.
  plan_dir=${plan_dir%/}

  local base
  base=$(basename "$plan_dir")

  # Idempotent path — already DONE.
  if [[ "$base" == DONE_Plan_* ]]; then
    [[ -d "$plan_dir" ]] || _die "DONE_Plan path does not exist: $plan_dir"
    printf '✓ %s already marked done (no-op)\n' "$base"
    return 0
  fi

  [[ "$base" == INPROGRESS_Plan_* ]] \
    || _die "expected INPROGRESS_Plan_* directory, got: $base"
  [[ -d "$plan_dir" ]] || _die "plan directory does not exist: $plan_dir"

  local parent_dir done_base done_dir
  parent_dir=$(dirname "$plan_dir")
  done_base="DONE_Plan_${base#INPROGRESS_Plan_}"
  done_dir="$parent_dir/$done_base"

  [[ ! -e "$done_dir" ]] || _die "destination already exists: $done_dir"

  local repo_root
  repo_root=$(git -C "$plan_dir" rev-parse --show-toplevel 2>/dev/null) \
    || _die "not inside a git repository: $plan_dir"

  ( cd "$repo_root"
    local rel_src rel_dst
    rel_src=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$plan_dir" "$repo_root")
    rel_dst=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$done_dir" "$repo_root")
    git mv "$rel_src" "$rel_dst" >/dev/null 2>&1 \
      || _die "git mv failed: $rel_src → $rel_dst"
    git commit -m "chore(plan): mark ${base#INPROGRESS_Plan_} done" >/dev/null 2>&1 \
      || _die "git commit failed"
    printf '✓ renamed %s → %s (committed)\n' "$base" "$done_base" )
}

# ── Dispatch ──
case "${1:-}" in
  approve-gate)  shift; cmd_approve_gate "$@" ;;
  mark-done)     shift; cmd_mark_done "$@" ;;
  -h|--help|help) _print_usage ;;
  '')            _print_usage; exit 1 ;;
  *)             printf '✗ unknown subcommand: %s\n' "$1" >&2; _print_usage; exit 1 ;;
esac
