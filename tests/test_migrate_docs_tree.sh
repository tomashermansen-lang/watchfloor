#!/usr/bin/env bash
# test_migrate_docs_tree.sh — T5 (docs-tree-merge) test harness
#
# Drives scripts/migrate-docs-tree.sh against synthetic mktemp git
# fixtures (TC-01..TC-13). TC-14 (live commit subject + single-commit
# invariant) only runs when CWD is the real worktree, not a fixture.
#
# Usage: bash tests/test_migrate_docs_tree.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/migrate-docs-tree.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

passed=0
failed=0
skipped=0

# Each fixture is a self-contained tmp dir; cleanup-on-exit trap
# handles all of them.
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-migrate-docs-tree.XXXXXX")"
RENAMES_FILE="${TMPDIR:-/tmp}/docs-tree-merge-renames.txt"

cleanup() {
    rm -rf "$FIXTURE_ROOT"
    rm -f "$RENAMES_FILE"
}
trap cleanup EXIT

check() {
    local name="$1"
    shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

skip() {
    local name="$1"
    local reason="$2"
    echo -e "${YELLOW}~${NC} $name [skip: $reason]"
    skipped=$((skipped + 1))
}

# ---------------------------------------------------------------------------
# Fixture builder.
#
# Creates a fresh git repo with:
#   dashboard/docs/{DONE_Feature_alpha,PENDING_Feature_beta}/REQUIREMENTS.md
#   dashboard/docs/{BACKLOG,DEFERRED,PRODUCT_REVIEW,SANDBOX_REVIEW,
#                   architecture-review-chat,enterprise-copilot-agent-setup}.md
#   docs/{BACKLOG,DEFERRED,PRODUCT_REVIEW}.md
#
# All files end with `\n` unless explicitly stripped by a TC.
# Echoes the fixture path on stdout.
# ---------------------------------------------------------------------------
make_fixture() {
    local name="$1"
    local fix="$FIXTURE_ROOT/$name"
    mkdir -p "$fix"
    cd "$fix"

    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"

    mkdir -p dashboard/docs/DONE_Feature_alpha
    mkdir -p dashboard/docs/PENDING_Feature_beta
    mkdir -p docs

    printf 'reqs alpha\n' > dashboard/docs/DONE_Feature_alpha/REQUIREMENTS.md
    printf 'plan alpha\n' > dashboard/docs/DONE_Feature_alpha/PLAN.md
    printf 'reqs beta\n' > dashboard/docs/PENDING_Feature_beta/REQUIREMENTS.md

    printf '# Dashboard BACKLOG\n\nitem 1\n' > dashboard/docs/BACKLOG.md
    printf '# Dashboard DEFERRED\n\ndef 1\n' > dashboard/docs/DEFERRED.md
    printf '# Dashboard PRODUCT_REVIEW\n\npr 1\n' > dashboard/docs/PRODUCT_REVIEW.md
    printf '# Dashboard SANDBOX_REVIEW\n\nsb 1\n' > dashboard/docs/SANDBOX_REVIEW.md
    printf '# arch chat\n\nline\n' > dashboard/docs/architecture-review-chat.md
    printf '# enterprise copilot\n\nline\n' > dashboard/docs/enterprise-copilot-agent-setup.md

    printf '# Root BACKLOG\n\nroot item 1\n' > docs/BACKLOG.md
    printf '# Root DEFERRED\n\nroot def 1\n' > docs/DEFERRED.md
    printf '# Root PRODUCT_REVIEW\n\nroot pr 1\n' > docs/PRODUCT_REVIEW.md

    git add -A
    git commit -q -m baseline

    echo "$fix"
}

# Run script in fixture, returning exit code; captures stderr to a file.
run_script() {
    local fix="$1"
    local stderr_file="$2"
    cd "$fix"
    rm -f "$RENAMES_FILE"
    set +e
    bash "$SCRIPT" 2>"$stderr_file"
    local rc=$?
    set -e
    return "$rc"
}

# ---------------------------------------------------------------------------
# TC-01 — Happy-path lift.
# Maps R-01, R-06, R-07, R-09 → AC-01.
# ---------------------------------------------------------------------------
tc01() {
    local fix
    fix="$(make_fixture tc01)"
    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc01: script failed: $(cat "$err")"; return 1; }

    cd "$fix"
    [[ "$(find docs -maxdepth 1 \( -name 'DONE_Feature_*' -o -name 'PENDING_Feature_*' \) | wc -l | tr -d ' ')" -ge 2 ]] || return 1
    [[ ! -e dashboard/docs ]] || return 1
    git status --porcelain | grep -qE '^R' || return 1
    [[ -f docs/SANDBOX_REVIEW.md ]] || return 1
    [[ -f docs/architecture-review-chat.md ]] || return 1
    [[ -f docs/enterprise-copilot-agent-setup.md ]] || return 1
    git commit -q -m migrated || return 1
    [[ "$(git log --follow --oneline docs/DONE_Feature_alpha/REQUIREMENTS.md | wc -l | tr -d ' ')" -gt 0 ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-02 — BACKLOG.md append byte-equality.
# Maps R-03, R-08, R-10 → AC-02, AC-03.
# ---------------------------------------------------------------------------
tc02() {
    local fix
    fix="$(make_fixture tc02)"
    cd "$fix"
    local src_bytes dst_pre_bytes heading_bytes expected
    src_bytes=$(wc -c < dashboard/docs/BACKLOG.md | tr -d ' ')
    dst_pre_bytes=$(wc -c < docs/BACKLOG.md | tr -d ' ')
    heading_bytes=$(printf '\n## Dashboard Backlog (migrated 2026-04-29)\n\n' | wc -c | tr -d ' ')
    expected=$((dst_pre_bytes + heading_bytes + src_bytes))

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc02: script failed: $(cat "$err")"; return 1; }

    grep -q '^## Dashboard Backlog (migrated 2026-04-29)$' docs/BACKLOG.md || return 1
    local got
    got=$(wc -c < docs/BACKLOG.md | tr -d ' ')
    [[ "$got" == "$expected" ]] || { echo "tc02: bytes got=$got expected=$expected"; return 1; }
    [[ ! -e dashboard/docs/BACKLOG.md ]] || return 1
    git status --porcelain docs/BACKLOG.md | grep -qE '^M ' || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-03 — DEFERRED.md append byte-equality.
# Maps R-04, R-08 → AC-03.
# ---------------------------------------------------------------------------
tc03() {
    local fix
    fix="$(make_fixture tc03)"
    cd "$fix"
    local src dst heading expected
    src=$(wc -c < dashboard/docs/DEFERRED.md | tr -d ' ')
    dst=$(wc -c < docs/DEFERRED.md | tr -d ' ')
    heading=$(printf '\n## Dashboard Deferred (migrated 2026-04-29)\n\n' | wc -c | tr -d ' ')
    expected=$((dst + heading + src))

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc03: script failed: $(cat "$err")"; return 1; }

    grep -q '^## Dashboard Deferred (migrated 2026-04-29)$' docs/DEFERRED.md || return 1
    local got
    got=$(wc -c < docs/DEFERRED.md | tr -d ' ')
    [[ "$got" == "$expected" ]] || return 1
    [[ ! -e dashboard/docs/DEFERRED.md ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-04 — PRODUCT_REVIEW.md append byte-equality.
# Maps R-05, R-08 → AC-03.
# ---------------------------------------------------------------------------
tc04() {
    local fix
    fix="$(make_fixture tc04)"
    cd "$fix"
    local src dst heading expected
    src=$(wc -c < dashboard/docs/PRODUCT_REVIEW.md | tr -d ' ')
    dst=$(wc -c < docs/PRODUCT_REVIEW.md | tr -d ' ')
    heading=$(printf '\n## Dashboard Product Review (migrated 2026-04-29)\n\n' | wc -c | tr -d ' ')
    expected=$((dst + heading + src))

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc04: script failed: $(cat "$err")"; return 1; }

    grep -q '^## Dashboard Product Review (migrated 2026-04-29)$' docs/PRODUCT_REVIEW.md || return 1
    local got
    got=$(wc -c < docs/PRODUCT_REVIEW.md | tr -d ' ')
    [[ "$got" == "$expected" ]] || return 1
    [[ ! -e dashboard/docs/PRODUCT_REVIEW.md ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-05 — Collision rename (`dashboard-` prefix on the colliding basename).
# Maps R-02, R-12 → AC-04.
# ---------------------------------------------------------------------------
tc05() {
    local fix
    fix="$(make_fixture tc05)"
    cd "$fix"
    mkdir -p docs/DONE_Feature_alpha
    printf 'EXISTING\n' > docs/DONE_Feature_alpha/EXISTING.md
    git add docs/DONE_Feature_alpha
    git commit -q -m collide

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc05: script failed: $(cat "$err")"; return 1; }

    [[ -d docs/dashboard-DONE_Feature_alpha ]] || return 1
    [[ -d docs/DONE_Feature_alpha ]] || return 1
    [[ -f docs/DONE_Feature_alpha/EXISTING.md ]] || return 1
    [[ -f "$RENAMES_FILE" ]] || return 1
    grep -qF 'dashboard/docs/DONE_Feature_alpha/ → docs/dashboard-DONE_Feature_alpha/' "$RENAMES_FILE" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-06a — Abort: dashboard/docs/ missing.
# Maps R-13 → AC-06.
# ---------------------------------------------------------------------------
tc06a() {
    local fix
    fix="$(make_fixture tc06a)"
    cd "$fix"
    git rm -rfq dashboard/docs
    rm -rf dashboard
    git commit -q -m removed

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    if run_script "$fix" "$err"; then
        echo "tc06a: expected non-zero exit"
        return 1
    fi

    grep -q 'ABORT:' "$err" || return 1
    grep -q 'subtree-merge-restructure' "$err" || return 1
    [[ -z "$(git status --porcelain)" ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-06b — Abort: dashboard/docs/ not empty after lift loop (EC-05).
# Maps R-07 → AC-06.
# ---------------------------------------------------------------------------
tc06b() {
    local fix
    fix="$(make_fixture tc06b)"
    cd "$fix"
    mkdir -p dashboard/docs/.junk
    printf 'keep\n' > dashboard/docs/.junk/.keep
    git add -A
    git commit -q -m junk

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    if run_script "$fix" "$err"; then
        echo "tc06b: expected non-zero exit"
        return 1
    fi

    grep -q 'ABORT:' "$err" || return 1
    grep -qi 'dashboard/docs not empty' "$err" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-07 — Abort: dirty docs/ tree.
# Maps R-14 → AC-06.
# ---------------------------------------------------------------------------
tc07() {
    local fix
    fix="$(make_fixture tc07)"
    cd "$fix"
    printf 'dirty\n' > docs/SOMETHING.md   # untracked

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    if run_script "$fix" "$err"; then
        echo "tc07: expected non-zero exit"
        return 1
    fi

    grep -q 'ABORT:' "$err" || return 1
    grep -qi 'dirty' "$err" || grep -qi 'uncommitted' "$err" || return 1
    [[ -d dashboard/docs ]] || return 1
    [[ -f docs/SOMETHING.md ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-08 — Abort: marker pre-existing in target md.
# Maps R-15 → AC-06.
# Three sub-cases: BACKLOG / DEFERRED / PRODUCT_REVIEW.
# ---------------------------------------------------------------------------
tc08_one() {
    local sub="$1"     # BACKLOG | DEFERRED | PRODUCT_REVIEW
    local heading="$2" # the literal H2 heading line
    local fix
    fix="$(make_fixture "tc08_$sub")"
    cd "$fix"
    printf '\n%s\nstale\n' "$heading" >> "docs/${sub}.md"
    git add -u
    git commit -q -m partial

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    if run_script "$fix" "$err"; then
        echo "tc08_$sub: expected non-zero exit"
        return 1
    fi

    grep -q 'ABORT:' "$err" || return 1
    grep -qF "$heading" "$err" || return 1
    [[ -d dashboard/docs ]] || return 1
    return 0
}
tc08a() { tc08_one BACKLOG '## Dashboard Backlog (migrated 2026-04-29)'; }
tc08b() { tc08_one DEFERRED '## Dashboard Deferred (migrated 2026-04-29)'; }
tc08c() { tc08_one PRODUCT_REVIEW '## Dashboard Product Review (migrated 2026-04-29)'; }

# ---------------------------------------------------------------------------
# TC-09 — Byte-equality on non-appending md moves.
# Maps R-08 → AC-07.
# ---------------------------------------------------------------------------
tc09() {
    local fix
    fix="$(make_fixture tc09)"
    cd "$fix"
    local baseline
    baseline=$(git rev-parse HEAD)

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc09: script failed: $(cat "$err")"; return 1; }

    local f
    for f in SANDBOX_REVIEW.md architecture-review-chat.md enterprise-copilot-agent-setup.md; do
        local diff_out
        diff_out=$(git diff "$baseline:dashboard/docs/$f" -- "docs/$f" 2>&1 || true)
        [[ -z "$diff_out" ]] || { echo "tc09: $f diff non-empty: $diff_out"; return 1; }
    done
    return 0
}

# ---------------------------------------------------------------------------
# TC-10 — Byte-equality on lifted feature directory file.
# Maps R-08 → AC-07.
# ---------------------------------------------------------------------------
tc10() {
    local fix
    fix="$(make_fixture tc10)"
    cd "$fix"
    local baseline
    baseline=$(git rev-parse HEAD)

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc10: script failed: $(cat "$err")"; return 1; }

    local diff_out
    diff_out=$(git diff "$baseline:dashboard/docs/DONE_Feature_alpha/REQUIREMENTS.md" -- docs/DONE_Feature_alpha/REQUIREMENTS.md 2>&1 || true)
    [[ -z "$diff_out" ]] || { echo "tc10: diff non-empty: $diff_out"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# TC-11 — Append without trailing newline (EC-02).
# Maps R-08, EC-02 → AC-03.
# ---------------------------------------------------------------------------
tc11() {
    local fix
    fix="$(make_fixture tc11)"
    cd "$fix"

    # Strip the trailing \n from docs/BACKLOG.md.
    printf '%s' "$(cat docs/BACKLOG.md)" > docs/BACKLOG.md.tmp
    mv docs/BACKLOG.md.tmp docs/BACKLOG.md
    git add -u
    git commit -q -m strip-newline

    local src dst heading expected
    src=$(wc -c < dashboard/docs/BACKLOG.md | tr -d ' ')
    dst=$(wc -c < docs/BACKLOG.md | tr -d ' ')
    heading=$(printf '\n## Dashboard Backlog (migrated 2026-04-29)\n\n' | wc -c | tr -d ' ')
    # Script auto-prepends one extra \n because dst lacked trailing newline.
    expected=$((dst + 1 + heading + src))

    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc11: script failed: $(cat "$err")"; return 1; }

    grep -q '^## Dashboard Backlog (migrated 2026-04-29)$' docs/BACKLOG.md || return 1
    local got
    got=$(wc -c < docs/BACKLOG.md | tr -d ' ')
    [[ "$got" == "$expected" ]] || { echo "tc11: bytes got=$got expected=$expected"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# TC-12 — Subsumed by TC-08 (R-15 marker check). Documented and skipped.
# ---------------------------------------------------------------------------
tc12() {
    skip "TC-12 partial-run recovery" "subsumed by TC-08 + manual git reset --hard per PLAN.md R-B"
    return 0
}

# ---------------------------------------------------------------------------
# TC-13 — Renames block lists section-insertion entries.
# Maps R-12 (append branch) → AC-04 extended.
# ---------------------------------------------------------------------------
tc13() {
    local fix
    fix="$(make_fixture tc13)"
    local err
    err="$FIXTURE_ROOT/$(basename "$fix").stderr.log"
    run_script "$fix" "$err" || { echo "tc13: script failed: $(cat "$err")"; return 1; }

    [[ -f "$RENAMES_FILE" ]] || return 1
    grep -qF 'dashboard/docs/BACKLOG.md → docs/BACKLOG.md (appended as section)' "$RENAMES_FILE" || return 1
    grep -qF 'dashboard/docs/DEFERRED.md → docs/DEFERRED.md (appended as section)' "$RENAMES_FILE" || return 1
    grep -qF 'dashboard/docs/PRODUCT_REVIEW.md → docs/PRODUCT_REVIEW.md (appended as section)' "$RENAMES_FILE" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# TC-14 — Live commit subject + single-commit invariant.
# Skipped inside the unit harness; runs only when invoked from the live
# worktree post-/implement (signalled by RUN_LIVE_TC14=1).
# ---------------------------------------------------------------------------
tc14() {
    if [[ "${RUN_LIVE_TC14:-0}" != "1" ]]; then
        skip "TC-14 commit subject + single-commit invariant" "live-tree only (set RUN_LIVE_TC14=1)"
        return 0
    fi
    cd "$REPO_DIR"
    git log --oneline -1 --pretty='%s' HEAD | grep -qE '^(docs|chore)\(docs-tree-merge\): .+$' || return 1
    [[ "$(git rev-list --count HEAD ^HEAD~1)" == "1" ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Driver.
# ---------------------------------------------------------------------------
echo "Running test_migrate_docs_tree.sh..."
echo ""

check "TC-01 happy-path lift"               tc01
check "TC-02 BACKLOG append byte-equality"  tc02
check "TC-03 DEFERRED append byte-equality" tc03
check "TC-04 PRODUCT_REVIEW append byte-equality" tc04
check "TC-05 collision rename"              tc05
check "TC-06a abort: dashboard/docs missing" tc06a
check "TC-06b abort: dashboard/docs not empty" tc06b
check "TC-07 abort: dirty docs tree"        tc07
check "TC-08a abort: BACKLOG marker pre-existing" tc08a
check "TC-08b abort: DEFERRED marker pre-existing" tc08b
check "TC-08c abort: PRODUCT_REVIEW marker pre-existing" tc08c
check "TC-09 byte-equality non-appending md" tc09
check "TC-10 byte-equality lifted feature dir" tc10
check "TC-11 append without trailing newline (EC-02)" tc11
tc12
check "TC-13 renames block covers section-insertions" tc13
tc14

echo ""
echo "Results: ${passed} passed, ${failed} failed, ${skipped} skipped"

[[ $failed -eq 0 ]] || exit 1
exit 0
