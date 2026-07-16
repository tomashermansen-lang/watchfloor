#!/usr/bin/env bash
set -euo pipefail

# ── commit-finalize.sh ──
# Deterministic post-commit finalization: rename docs, update plan,
# merge to main, push, cleanup worktree.
#
# Called by both /commit flow (manual) and autopilot.sh (autonomous).
# All operations are mechanical — no LLM judgement needed.
#
# Usage:
#   commit-finalize.sh --task <task-id> --worktree <path> --main <path> --branch <branch>
#
# Options:
#   --stream <file>  NDJSON stream file for dashboard events
#   --skip-merge     Skip merge/push (caller handles it)
#   --skip-cleanup   Skip worktree/branch deletion
#
# Prerequisites:
#   - jq (brew install jq)
#   - python3 (for YAML updates)
#   - bash 3.2+ (macOS compatible — no associative arrays)
#
# Output: JSON to stdout with status of each step. All diagnostics to stderr.
# Exit: Always 0. Errors reported via step statuses in JSON.

# ── Error trap: ensure valid JSON on crash ──
_bail() {
  jq -n --arg error "$1" '{"ok":false,"error":$error}' 2>/dev/null \
    || printf '{"ok":false,"error":"internal error"}\n'
  exit 0
}
trap '_bail "unexpected error at line $LINENO"' ERR

# ── Dependency checks ──
command -v jq >/dev/null 2>&1 || { _bail "jq not found — install with: brew install jq"; }
command -v git >/dev/null 2>&1 || { _bail "git not available"; }

# ── Source shared libraries ──
COMMIT_FINALIZE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/worktree-reaper.sh
source "$COMMIT_FINALIZE_DIR/lib/worktree-reaper.sh"
# shellcheck source=lib/pre-merge-rebase.sh
source "$COMMIT_FINALIZE_DIR/lib/pre-merge-rebase.sh"

# ── Parse arguments ──
TASK=""
WORKTREE=""
MAIN_DIR=""
BRANCH=""
SKIP_MERGE=false
SKIP_CLEANUP=false
STREAM_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --main) MAIN_DIR="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --stream) STREAM_FILE="$2"; shift 2 ;;
    --skip-merge) SKIP_MERGE=true; shift ;;
    --skip-cleanup) SKIP_CLEANUP=true; shift ;;
    *) shift ;;
  esac
done

[[ -n "$TASK" ]] || _bail "--task is required"
[[ -n "$WORKTREE" ]] || _bail "--worktree is required"
[[ -n "$MAIN_DIR" ]] || _bail "--main is required"
[[ -n "$BRANCH" ]] || _bail "--branch is required"

# ── Step tracking (bash 3.2 compatible — no associative arrays) ──
STEP_NAMES=""
STEP_STATUSES=""
HAS_FAILURE=false

step() {
  local name=$1 status=$2 msg=${3:-""}
  STEP_NAMES="${STEP_NAMES}${STEP_NAMES:+|}${name}"
  STEP_STATUSES="${STEP_STATUSES}${STEP_STATUSES:+|}${status}"
  if [[ "$status" == "fail" ]]; then
    HAS_FAILURE=true
  fi
  echo "  [$status] $name${msg:+: $msg}" >&2
  # Emit to NDJSON stream if available
  if [[ -n "$STREAM_FILE" && -f "$STREAM_FILE" ]]; then
    local escaped_msg
    escaped_msg=${msg//\"/\\\"}
    printf '{"type":"finalize_step","step":"%s","status":"%s","msg":"%s","ts":"%s"}\n' \
      "$name" "$status" "$escaped_msg" \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"
  fi
}

# ── Step 1: Rename docs on feature branch ──
cd "$WORKTREE" 2>/dev/null || _bail "worktree not found: $WORKTREE"

if [[ -d "docs/INPROGRESS_Feature_${TASK}" ]]; then
  mv "docs/INPROGRESS_Feature_${TASK}" "docs/DONE_Feature_${TASK}"
  git add "docs/DONE_Feature_${TASK}/" "docs/INPROGRESS_Feature_${TASK}/" 2>/dev/null || true
  step "docs_rename" "ok" "INPROGRESS → DONE"
elif [[ -d "docs/DONE_Feature_${TASK}" ]]; then
  step "docs_rename" "skip" "already renamed"
else
  step "docs_rename" "skip" "no docs folder found"
fi

# ── Step 2: Update execution plan YAML ──
# Pick the plan that actually contains the task id. The earlier
# `find … | head -1` flow assumed exactly one INPROGRESS_Plan_*/
# directory and silently picked the wrong plan when several plans
# coexisted (e.g. watchfloor + cost-efficiency). The result was a
# "not_found" skip → task.status stayed pending → the chain printed
# "No ready tasks" even after the autopilot run completed.
PLAN_YAML=""
for candidate in \
  $(find "$WORKTREE/docs" -name "execution-plan.yaml" -path "*/INPROGRESS_Plan_*" 2>/dev/null) \
  $(find "$MAIN_DIR/docs" -name "execution-plan.yaml" -path "*/INPROGRESS_Plan_*" 2>/dev/null); do
  if grep -q "^  - id: ${TASK}\$" "$candidate" 2>/dev/null; then
    PLAN_YAML="$candidate"
    break
  fi
done

if [[ -n "$PLAN_YAML" && -f "$PLAN_YAML" ]]; then
  UPDATED=$(python3 -c "
import re, sys
from datetime import datetime, timezone

path = '$PLAN_YAML'
task_id = '$TASK'

with open(path) as f:
    content = f.read()

ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
pattern = r'(- id: ' + re.escape(task_id) + r'\n(?:[ \t]+\w.*\n)*?)([ \t]+status: )\w+'
match = re.search(pattern, content)
if match:
    content = re.sub(
        r'(- id: ' + re.escape(task_id) + r'\n(?:[ \t]+\w.*\n)*?)([ \t]+status: )\w+',
        r'\g<1>\g<2>done',
        content
    )
    content = re.sub(
        r'(- id: ' + re.escape(task_id) + r'\n(?:[ \t]+\w.*\n)*?)([ \t]+last_updated: )\S+',
        r'\g<1>\g<2>' + ts,
        content
    )
    with open(path, 'w') as f:
        f.write(content)
    print('updated')
else:
    print('not_found')
" 2>/dev/null || echo "error")

  case "$UPDATED" in
    updated) step "plan_yaml" "ok" "task.status = done" ;;
    not_found) step "plan_yaml" "skip" "task '$TASK' not found in YAML" ;;
    *) step "plan_yaml" "fail" "python error" ;;
  esac
else
  step "plan_yaml" "skip" "no execution-plan.yaml found"
fi

# ── Step 3: Update EXECUTION_GUIDE.md ──
GUIDE=""
for candidate in "$WORKTREE/EXECUTION_GUIDE.md" "$MAIN_DIR/EXECUTION_GUIDE.md"; do
  if [[ -f "$candidate" ]]; then
    GUIDE="$candidate"
    break
  fi
done

if [[ -n "$GUIDE" ]]; then
  if grep -q "$TASK" "$GUIDE" 2>/dev/null; then
    if grep -q "${TASK}.*✓ DONE" "$GUIDE" 2>/dev/null; then
      step "exec_guide" "skip" "already marked done"
    else
      sed -i.bak "s/\(.*${TASK}.*\)/\1 ✓ DONE/" "$GUIDE" && rm -f "${GUIDE}.bak"
      step "exec_guide" "ok" "marked ✓ DONE"
    fi
  else
    step "exec_guide" "skip" "task not referenced"
  fi
else
  step "exec_guide" "skip" "no EXECUTION_GUIDE.md"
fi

# ── Step 4: Commit finalization on feature branch ──
cd "$WORKTREE"
git add docs/ EXECUTION_GUIDE.md 2>/dev/null || true
if git diff --cached --quiet 2>/dev/null; then
  step "finalize_commit" "skip" "nothing to commit"
else
  git commit -m "docs(plan): mark ${TASK} as done" --no-verify 2>/dev/null
  step "finalize_commit" "ok"
fi

# ── Step 5: Merge to main ──
if [[ "$SKIP_MERGE" == true ]]; then
  step "merge" "skip" "caller handles merge"
  step "push" "skip" "caller handles push"
else
  cd "$MAIN_DIR"
  git checkout main 2>/dev/null || true

  # Stash any dirty files on main before merge (pyproject.toml edits,
  # log files, etc. can block merge with "overwritten by merge" error).
  # Use -u to include untracked files — they can also collide with merge
  # (e.g. orphan autopilot-summary.json from a previous failed run).
  HAS_UNTRACKED=false
  if [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]; then
    HAS_UNTRACKED=true
  fi
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null || [[ "$HAS_UNTRACKED" == true ]]; then
    echo "Stashing dirty files on main before merge..." >&2
    git stash push -u -m "autopilot-finalize: pre-merge stash" 2>/dev/null || true
    STASHED=true
  else
    STASHED=false
  fi

  # Pull latest main (another autopilot may have merged first)
  git pull --ff-only origin main 2>/dev/null || true

  # Pre-merge rebase: replay the feature branch onto current main so a
  # sibling task's status/phase_results/deferred[] YAML update that
  # landed between worktree creation and now becomes a clean ancestor.
  # If the rebase fails (real conflict), the feature branch is restored
  # to its pre-rebase state and we proceed with the merge attempt — the
  # subsequent conflict surfaces with the original commit-finalize error
  # path, so behavior is no worse than before this fix.
  REBASE_RC=0
  pre_merge_rebase "$WORKTREE" "main" || REBASE_RC=$?
  if [[ $REBASE_RC -eq 0 ]]; then
    step "pre_merge_rebase" "ok"
  else
    step "pre_merge_rebase" "skip" "rebase-conflict; proceeding with merge attempt"
  fi

  MERGE_EXIT=0
  git merge --no-ff "$BRANCH" -m "feat(${TASK}): merge ${BRANCH}" >/dev/null 2>&1 || MERGE_EXIT=$?

  if [[ $MERGE_EXIT -eq 0 ]]; then
    step "merge" "ok"

    # Restore stashed files after successful merge.
    # If pop conflicts, abort the finalize — historically the warning was
    # silently ignored and conflict markers ended up committed via the
    # post-merge YAML update below (regex finalize is marker-blind).
    if [[ "$STASHED" == true ]]; then
      if ! git stash pop 2>/dev/null; then
        UNMERGED=$(git ls-files --unmerged 2>/dev/null | awk '{print $4}' | sort -u | head -5)
        echo "ERROR: stash pop conflict after merge — refusing to commit conflict markers" >&2
        echo "Unmerged files:" >&2
        echo "${UNMERGED:-<none reported>}" >&2
        echo "Stash kept; resolve manually: cd $MAIN_DIR && git status && git stash list" >&2
        step "stash_pop" "fail" "stash pop conflict on: ${UNMERGED:-unknown}"
        exit 1
      fi
    fi

    # Post-merge: update execution plan YAML on main (not on feature branch).
    # This prevents the parallel-merge YAML-overwrite bug: when two tasks
    # merge, the second's feature-branch YAML doesn't include the first's
    # status update. By updating AFTER merge, we always write to the latest
    # main state.
    # Same task-id-aware plan selection as Step 2 (line 110) — the
    # `find | head -1` form silently misses tasks that live in a
    # non-first INPROGRESS_Plan_*/ when multiple plans coexist.
    POST_MERGE_PLAN=""
    for candidate in $(find "$MAIN_DIR/docs" -name "execution-plan.yaml" -path "*/INPROGRESS_Plan_*" 2>/dev/null); do
      if grep -q "^  - id: ${TASK}\$" "$candidate" 2>/dev/null; then
        POST_MERGE_PLAN="$candidate"
        break
      fi
    done
    if [[ -n "$POST_MERGE_PLAN" && -f "$POST_MERGE_PLAN" ]]; then
      POST_MERGE_UPDATED=$(python3 -c "
import re, sys
from datetime import datetime, timezone

path = '$POST_MERGE_PLAN'
task_id = '$TASK'

with open(path) as f:
    content = f.read()

ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
pattern = r'(- id: ' + re.escape(task_id) + r'\n(?:[ \t]+\w.*\n)*?)([ \t]+status: )\w+'
match = re.search(pattern, content)
if match:
    content = re.sub(
        r'(- id: ' + re.escape(task_id) + r'\n(?:[ \t]+\w.*\n)*?)([ \t]+status: )\w+',
        r'\g<1>\g<2>done',
        content
    )
    content = re.sub(
        r'(- id: ' + re.escape(task_id) + r'\n(?:[ \t]+\w.*\n)*?)([ \t]+last_updated: )\S+',
        r'\g<1>\g<2>' + ts,
        content
    )
    with open(path, 'w') as f:
        f.write(content)
    print('updated')
else:
    print('not_found')
" 2>/dev/null || echo "error")
      if [[ "$POST_MERGE_UPDATED" == "updated" ]]; then
        # Defensive: refuse to commit conflict markers. The Python regex
        # finalize is marker-blind and would happily mark status: done in a
        # YAML still containing <<<<<<< from an upstream stash-pop conflict.
        if grep -qE '^(<<<<<<< |=======$|>>>>>>> )' "$POST_MERGE_PLAN"; then
          echo "ERROR: conflict markers detected in $POST_MERGE_PLAN — refusing to commit" >&2
          git checkout -- "$POST_MERGE_PLAN" 2>/dev/null || true
          step "post_merge_yaml" "fail" "conflict markers in plan YAML; reverted, not committed"
          exit 1
        fi
        git add "$POST_MERGE_PLAN" 2>/dev/null || true
        git commit -m "docs(plan): mark ${TASK} done (post-merge)" --no-verify 2>/dev/null || true
      fi
    fi

    # Push with retry — if another autopilot pushed between merge and push,
    # pull-rebase and try once more
    PUSH_EXIT=0
    git push origin main >/dev/null 2>&1 || PUSH_EXIT=$?
    if [[ $PUSH_EXIT -ne 0 ]]; then
      echo "Push failed, pulling and retrying..." >&2
      git pull --rebase origin main 2>/dev/null || true
      git push origin main >/dev/null 2>&1 || PUSH_EXIT=$?
    fi
    if [[ $PUSH_EXIT -eq 0 ]]; then
      step "push" "ok"
    else
      step "push" "fail" "push failed after retry (exit $PUSH_EXIT)"
    fi
  else
    # Abort the failed merge so main stays clean
    git merge --abort 2>/dev/null || true
    # Restore stashed files even on merge failure
    if [[ "$STASHED" == true ]]; then
      git stash pop 2>/dev/null || true
    fi
    step "merge" "fail" "merge conflict (exit $MERGE_EXIT) — aborted, main unchanged"
    step "push" "skip" "merge failed"
    # Do NOT clean up worktree/branch — the work is still needed for manual resolution
    SKIP_CLEANUP=true
  fi
fi

# ── Step 6: Cleanup worktree and branch ──
if [[ "$SKIP_CLEANUP" == true ]]; then
  step "cleanup" "skip" "caller handles cleanup"
else
  cd "$MAIN_DIR"
  reap_worktree_orphans "$WORKTREE"
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  rm -rf "$WORKTREE" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true

  if [[ -d "$WORKTREE" ]]; then
    step "cleanup" "fail" "worktree dir still exists"
  else
    step "cleanup" "ok"
  fi
fi

# ── Step 7: Post-merge verification ──
cd "$MAIN_DIR" 2>/dev/null || true

if [[ -d "docs/DONE_Feature_${TASK}" ]]; then
  step "docs_verify" "ok"
else
  step "docs_verify" "fail" "DONE_Feature_${TASK} not found on main"
fi

dirty=$(git status --porcelain 2>/dev/null | grep -v '^??' | head -5 || true)
if [[ -n "$dirty" ]]; then
  step "git_clean" "fail" "untracked/modified files remain"
else
  step "git_clean" "ok"
fi

# ── Output JSON ──
# Build steps array from pipe-delimited strings (bash 3.2 compatible)
IFS='|' read -ra NAMES <<< "$STEP_NAMES"
IFS='|' read -ra STATS <<< "$STEP_STATUSES"

steps_json="["
for i in "${!NAMES[@]}"; do
  [[ $i -gt 0 ]] && steps_json+=","
  steps_json+=$(printf '{"step":"%s","status":"%s"}' "${NAMES[$i]}" "${STATS[$i]}")
done
steps_json+="]"

overall_ok=true
if [[ "$HAS_FAILURE" == true ]]; then
  overall_ok=false
fi

jq -cn \
  --argjson ok "$overall_ok" \
  --arg task "$TASK" \
  --argjson steps "$steps_json" \
  '{ok:$ok, task:$task, steps:$steps}'

exit 0
