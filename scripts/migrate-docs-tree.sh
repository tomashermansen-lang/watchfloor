#!/usr/bin/env bash
# migrate-docs-tree.sh — T5 (docs-tree-merge) one-shot migration.
#
# Lifts dashboard/docs/ contents into the monorepo-root docs/ tree:
#   - DONE_Feature_*/ and PENDING_Feature_*/ → docs/<basename>/
#     (collisions get a `dashboard-` basename prefix, recorded in
#     ${TMPDIR:-/tmp}/docs-tree-merge-renames.txt)
#   - SANDBOX_REVIEW.md, architecture-review-chat.md,
#     enterprise-copilot-agent-setup.md → docs/<filename>
#   - BACKLOG.md / DEFERRED.md / PRODUCT_REVIEW.md → appended under
#     `## Dashboard <Name> (migrated 2026-04-29)` H2 sections
#   - Source dashboard/docs/ deleted at the end (R-07)
#
# All staged in a single git index for /implement to seal in one
# commit (R-11). The script does NOT itself commit.
#
# Renames written to ${TMPDIR:-/tmp}/docs-tree-merge-renames.txt
# (R-12). /implement reads this file and inserts it into the commit
# message body.
#
# Recovery: if the script aborts mid-run, run `git reset --hard HEAD`
# inside the worktree to revert the staged-but-uncommitted changes.

set -euo pipefail

# Operates on the current working directory's dashboard/docs/ and docs/.
# The script does NOT cd into the script's repo — that lets the test
# harness drive it against synthetic mktemp fixtures while the live
# /implement run drives it against the real worktree.
RENAMES_FILE="${TMPDIR:-/tmp}/docs-tree-merge-renames.txt"

readonly MIGRATION_DATE="2026-04-29"
readonly BACKLOG_HEADING="## Dashboard Backlog (migrated ${MIGRATION_DATE})"
readonly DEFERRED_HEADING="## Dashboard Deferred (migrated ${MIGRATION_DATE})"
readonly PRODUCT_REVIEW_HEADING="## Dashboard Product Review (migrated ${MIGRATION_DATE})"

abort() {
    echo "ABORT: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# preflight_checks — R-13, R-14, R-15.
# ---------------------------------------------------------------------------
preflight_checks() {
    [[ -d dashboard/docs ]] \
        || abort "dashboard/docs/ does not exist — predecessor T2 (subtree-merge-restructure) likely incomplete"

    if [[ -n "$(git status --porcelain docs dashboard/docs 2>/dev/null || true)" ]]; then
        abort "uncommitted (dirty) changes in docs/ or dashboard/docs/ — commit or stash first"
    fi

    local heading file
    while IFS=$'\t' read -r heading file; do
        if [[ -f "$file" ]] && grep -qF "$heading" "$file"; then
            abort "partial-run marker '$heading' already present in $file — previous run did not complete cleanly"
        fi
    done <<EOF
${BACKLOG_HEADING}	docs/BACKLOG.md
${DEFERRED_HEADING}	docs/DEFERRED.md
${PRODUCT_REVIEW_HEADING}	docs/PRODUCT_REVIEW.md
EOF

    # EC-03 defensive symlink scan — empirically zero at branch HEAD.
    if find dashboard/docs -type l 2>/dev/null | grep -q .; then
        abort "symlink found inside dashboard/docs/ — manual review required"
    fi
}

# ---------------------------------------------------------------------------
# lift_feature_dirs — R-01, R-02, R-09.
# Moves DONE_Feature_*/ and PENDING_Feature_*/ via `git mv`.
# Collisions on basename trigger a `dashboard-` prefix.
# ---------------------------------------------------------------------------
lift_feature_dirs() {
    local src dst basename
    while IFS= read -r src; do
        [[ -n "$src" ]] || continue
        basename="$(basename "$src")"
        if [[ -e "docs/$basename" ]]; then
            dst="docs/dashboard-${basename}"
            printf '%s/ → %s/\n' "$src" "$dst" >> "$RENAMES_FILE"
        else
            dst="docs/$basename"
        fi
        git mv "$src" "$dst"
    done < <(find dashboard/docs -maxdepth 1 \
                  \( -name 'DONE_Feature_*' -o -name 'PENDING_Feature_*' \) \
                  | sort)
}

# ---------------------------------------------------------------------------
# lift_md_files — R-06, R-09.
# Moves the three non-colliding md files via `git mv`.
# ---------------------------------------------------------------------------
lift_md_files() {
    local f
    for f in SANDBOX_REVIEW.md architecture-review-chat.md enterprise-copilot-agent-setup.md; do
        if [[ -f "dashboard/docs/$f" ]]; then
            git mv "dashboard/docs/$f" "docs/$f"
        fi
    done
}

# ---------------------------------------------------------------------------
# append_section <src> <dst> <heading-line>
# Maps R-03 / R-04 / R-05 / R-08 / EC-02.
#
# Algorithm:
#   1. If <dst> does not end with `\n`, append a single `\n`
#      (defensive separator).
#   2. Append `\n<heading>\n\n` to <dst>.
#   3. Append <src> bytes verbatim to <dst>.
#   4. `git rm` the <src>; `git add` the <dst>.
#   5. Record the rename in $RENAMES_FILE as `(appended as section)`.
# ---------------------------------------------------------------------------
append_section() {
    local src="$1"
    local dst="$2"
    local heading="$3"

    [[ -f "$src" ]] || abort "append_section: source missing: $src"
    [[ -f "$dst" ]] || abort "append_section: destination missing: $dst"

    # Step 1 — auto-prepend `\n` if dst lacks trailing newline.
    local last_byte
    last_byte=$(tail -c 1 "$dst" | od -An -c | tr -d ' ')
    if [[ "$last_byte" != "\\n" ]]; then
        printf '\n' >> "$dst"
    fi

    # Steps 2 + 3 — heading then verbatim source bytes.
    printf '\n%s\n\n' "$heading" >> "$dst"
    cat "$src" >> "$dst"

    # Step 4 — record changes in the index.
    git rm -q "$src"
    git add "$dst"

    # Step 5 — renames-list line.
    printf '%s → %s (appended as section)\n' "$src" "$dst" >> "$RENAMES_FILE"
}

# ---------------------------------------------------------------------------
# delete_dashboard_docs — R-07 + EC-05.
# After all lifts, dashboard/docs/ MUST be empty; otherwise abort.
# ---------------------------------------------------------------------------
delete_dashboard_docs() {
    # `git rm` of the last file in `dashboard/docs/` (and in
    # `dashboard/` if the dashboard directory itself becomes empty)
    # removes empty parent directories as a courtesy on some
    # platforms. Tolerate either state — non-empty is the only
    # actual error.
    if [[ -d dashboard/docs ]]; then
        if [[ -n "$(find dashboard/docs -mindepth 1 2>/dev/null | head -1)" ]]; then
            echo "ABORT: dashboard/docs not empty after lift loop:" >&2
            find dashboard/docs -mindepth 1 >&2
            exit 1
        fi
        rmdir dashboard/docs
    fi
    if [[ -d dashboard ]]; then
        git add -u dashboard
    fi
}

# ---------------------------------------------------------------------------
# main — orchestrates the migration.
# ---------------------------------------------------------------------------
main() {
    # Reset the renames-list file at the start of every run so it
    # only contains entries from THIS invocation.
    : > "$RENAMES_FILE"

    preflight_checks

    lift_feature_dirs
    lift_md_files

    append_section dashboard/docs/BACKLOG.md         docs/BACKLOG.md         "$BACKLOG_HEADING"
    append_section dashboard/docs/DEFERRED.md        docs/DEFERRED.md        "$DEFERRED_HEADING"
    append_section dashboard/docs/PRODUCT_REVIEW.md  docs/PRODUCT_REVIEW.md  "$PRODUCT_REVIEW_HEADING"

    delete_dashboard_docs

    echo "Migration staged. Renames recorded in: $RENAMES_FILE"
}

main "$@"
