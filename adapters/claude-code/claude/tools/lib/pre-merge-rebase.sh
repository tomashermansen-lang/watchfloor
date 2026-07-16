#!/bin/bash
# pre-merge-rebase.sh — pre-merge rebase for parallel-task safety.
#
# Provides one function:
#   pre_merge_rebase <workdir> <target_branch>
#
# Rebases the current branch in <workdir> onto <target_branch>. On
# conflict the rebase is aborted (no half-rebased state, no conflict
# markers left in the worktree) and a non-zero exit is returned. On
# clean rebase (or already-up-to-date) returns 0.
#
# Purpose: when autopilot tasks run in parallel, sibling tasks land
# status/phase_results/deferred[] updates on main between this task's
# worktree creation and finalize. Without a pre-merge rebase the merge
# attempt in commit-finalize.sh hits YAML conflicts on adjacency-induced
# overlaps even when the actual semantic edits are disjoint. The rebase
# replays this task's commits on top of the latest main, letting the
# subsequent merge become a fast-forward.
#
# Source this file; do not execute directly.

pre_merge_rebase() {
    local workdir="${1:?pre_merge_rebase requires workdir}"
    local target="${2:?pre_merge_rebase requires target branch}"

    [[ -d "$workdir" ]] || return 2
    [[ -d "$workdir/.git" || -f "$workdir/.git" ]] || return 2

    # Subshell so the `cd` does not leak to the caller.
    (
        cd "$workdir" || exit 3
        # already at or descended from target → no-op
        if git merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
            return 0
        fi
        local rc=0
        git rebase "$target" >/dev/null 2>&1 || rc=$?
        if [[ $rc -ne 0 ]]; then
            git rebase --abort >/dev/null 2>&1 || true
        fi
        return $rc
    )
}
