#!/bin/bash
# test_sync_restore.sh — integration tests for sync.sh restore Y/N flow.
#
# Each test creates an isolated dotfiles-like layout in $TEST_BASE/repo and
# sets HOME=$TEST_BASE/home so the restore writes there. Verifies:
#   - Pre-flight aborts when working tree is dirty
#   - --no-diff skips prompt (full auto)
#   - --yes shows diff, skips prompt
#   - Default prompt: Y proceeds, anything else aborts
#   - Audit log written to docs/sync-log/ and auto-committed
#
# Usage: bash tests/test_sync_restore.sh

set -uo pipefail

REPO_DIR_REAL="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$REPO_DIR_REAL/sync.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"; shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"; passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"; failed=$((failed + 1))
    fi
}

TEST_BASE="${TMPDIR:-/tmp}/test-sync-restore-$$"
trap 'rm -rf "$TEST_BASE"' EXIT

# Build a minimal dotfiles-like fake repo + fake home, return paths.
# Echoes "<repo_dir> <home_dir>" on stdout.
make_fake() {
    local d="$1"
    rm -rf "$d"
    mkdir -p "$d/repo/claude/hooks" "$d/repo/claude/agents" "$d/repo/claude/commands" \
             "$d/repo/claude/skills" "$d/repo/claude/tools/lib" "$d/repo/claude/rules" \
             "$d/repo/claude/plans" "$d/repo/claude/schema" "$d/repo/claude/templates" \
             "$d/home/.claude/projects/test-proj/memory"

    # Source files
    cp "$SYNC" "$d/repo/sync.sh"
    echo '{"permissions":{"deny":["Edit(/x)"]}}' > "$d/repo/claude/settings.json"
    echo "# Test CLAUDE.md" > "$d/repo/claude/CLAUDE.md"
    echo "echo started" > "$d/repo/start-system.sh"
    cp "$REPO_DIR_REAL/adapters/claude-code/claude/tools/lib/explain-diff.sh" "$d/repo/claude/tools/lib/" 2>/dev/null
    cp "$REPO_DIR_REAL/adapters/claude-code/claude/tools/lib/explain-settings-diff.py" "$d/repo/claude/tools/lib/" 2>/dev/null
    cp "$REPO_DIR_REAL/adapters/claude-code/claude/tools/lib/openai-key.sh" "$d/repo/claude/tools/lib/" 2>/dev/null

    # Initialize git
    (
      cd "$d/repo"
      git init -q -b main
      git config user.email "test@example.com"
      git config user.name "Test"
      git add -A
      git commit -q -m "init"
    )

    # Pre-existing deployed file in home/.claude (so there's a diff to show)
    mkdir -p "$d/home/.claude"
    echo '{"permissions":{"deny":[]}}' > "$d/home/.claude/settings.json"
    echo "# Old CLAUDE.md" > "$d/home/.claude/CLAUDE.md"

    echo "$d/repo $d/home"
}

# ---------------------------------------------------------------------------
# T01: Pre-flight aborts when working tree is dirty
# ---------------------------------------------------------------------------
test_dirty_aborts() {
    local d="$TEST_BASE/t01" repo home out exit_code
    read -r repo home <<< "$(make_fake "$d")"
    # Make the tree dirty
    echo "uncommitted change" >> "$repo/claude/CLAUDE.md"

    set +e
    out=$(HOME="$home" bash "$repo/sync.sh" restore --no-diff 2>&1)
    exit_code=$?
    set -e
    [[ "$exit_code" != "0" ]] && [[ "$out" == *"uncommitted"* || "$out" == *"Aborting"* ]]
}
check "T01 dirty working tree aborts restore with clear message" test_dirty_aborts

# ---------------------------------------------------------------------------
# T02: --no-diff skips prompt and proceeds
# ---------------------------------------------------------------------------
test_no_diff_proceeds() {
    local d="$TEST_BASE/t02" repo home out exit_code
    read -r repo home <<< "$(make_fake "$d")"
    set +e
    out=$(HOME="$home" bash "$repo/sync.sh" restore --no-diff 2>&1)
    exit_code=$?
    set -e
    # Restore must succeed and deploy the new CLAUDE.md
    [[ "$exit_code" == "0" ]] && grep -q "Test CLAUDE" "$home/.claude/CLAUDE.md"
}
check "T02 --no-diff proceeds without prompt" test_no_diff_proceeds

# ---------------------------------------------------------------------------
# T03: Default mode prompts Y/N — N aborts
# ---------------------------------------------------------------------------
test_prompt_n_aborts() {
    local d="$TEST_BASE/t03" repo home exit_code
    read -r repo home <<< "$(make_fake "$d")"
    # Pipe "n" as input
    set +e
    echo "n" | HOME="$home" bash "$repo/sync.sh" restore >/dev/null 2>&1
    exit_code=$?
    set -e
    # Exit code should be 0 (graceful abort), and home file should NOT have been replaced
    [[ "$exit_code" == "0" ]] && grep -q "Old CLAUDE" "$home/.claude/CLAUDE.md"
}
check "T03 prompt: 'n' aborts and leaves home unchanged" test_prompt_n_aborts

# ---------------------------------------------------------------------------
# T04: Default mode prompts Y/N — Y proceeds
# ---------------------------------------------------------------------------
test_prompt_y_proceeds() {
    local d="$TEST_BASE/t04" repo home exit_code
    read -r repo home <<< "$(make_fake "$d")"
    set +e
    echo "y" | HOME="$home" bash "$repo/sync.sh" restore >/dev/null 2>&1
    exit_code=$?
    set -e
    [[ "$exit_code" == "0" ]] && grep -q "Test CLAUDE" "$home/.claude/CLAUDE.md"
}
check "T04 prompt: 'y' proceeds with restore" test_prompt_y_proceeds

# ---------------------------------------------------------------------------
# T05: Empty input aborts (defaults to N)
# ---------------------------------------------------------------------------
test_empty_input_aborts() {
    local d="$TEST_BASE/t05" repo home exit_code
    read -r repo home <<< "$(make_fake "$d")"
    set +e
    echo "" | HOME="$home" bash "$repo/sync.sh" restore >/dev/null 2>&1
    exit_code=$?
    set -e
    [[ "$exit_code" == "0" ]] && grep -q "Old CLAUDE" "$home/.claude/CLAUDE.md"
}
check "T05 prompt: empty input defaults to abort" test_empty_input_aborts

# ---------------------------------------------------------------------------
# T06: --yes shows diff but skips prompt
# ---------------------------------------------------------------------------
test_yes_skips_prompt() {
    local d="$TEST_BASE/t06" repo home out exit_code
    read -r repo home <<< "$(make_fake "$d")"
    set +e
    out=$(HOME="$home" bash "$repo/sync.sh" restore --yes 2>&1)
    exit_code=$?
    set -e
    # Output should include the diff banner AND the restore banner
    [[ "$exit_code" == "0" ]] \
        && [[ "$out" == *"Differences"* ]] \
        && [[ "$out" == *"Restoring"* ]] \
        && grep -q "Test CLAUDE" "$home/.claude/CLAUDE.md"
}
check "T06 --yes shows diff but skips Y/N prompt" test_yes_skips_prompt

# ---------------------------------------------------------------------------
# T07: Audit log written and committed after successful restore
# ---------------------------------------------------------------------------
test_audit_log_committed() {
    local d="$TEST_BASE/t07" repo home log_count log_files head_after
    read -r repo home <<< "$(make_fake "$d")"
    local head_before
    head_before=$(git -C "$repo" rev-parse HEAD)

    HOME="$home" bash "$repo/sync.sh" restore --no-diff >/dev/null 2>&1

    head_after=$(git -C "$repo" rev-parse HEAD)
    log_count=$(find "$repo/docs/sync-log" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    log_files=$(find "$repo/docs/sync-log" -name "*.md" 2>/dev/null)

    # Must have a new commit, exactly one log file, and the commit must be
    # the docs(sync-log) commit
    [[ "$log_count" == "1" ]] \
        && [[ "$head_before" != "$head_after" ]] \
        && git -C "$repo" log -1 --pretty=%s | grep -q "sync-log" \
        && grep -q "Approved by" "$log_files" \
        && grep -q "Repo HEAD" "$log_files"
}
check "T07 audit log written + committed after successful restore" test_audit_log_committed

# ---------------------------------------------------------------------------
# T08: Audit log includes diff content when not --no-diff
# ---------------------------------------------------------------------------
test_audit_log_includes_diff() {
    local d="$TEST_BASE/t08" repo home log_files
    read -r repo home <<< "$(make_fake "$d")"
    HOME="$home" bash "$repo/sync.sh" restore --yes >/dev/null 2>&1
    log_files=$(find "$repo/docs/sync-log" -name "*.md" 2>/dev/null)
    grep -q "Diff at deploy time" "$log_files" \
        && grep -q "CHANGED\|claude/CLAUDE.md\|claude/settings.json" "$log_files"
}
check "T08 audit log includes diff content when shown" test_audit_log_includes_diff

# ---------------------------------------------------------------------------
# T09: --no-diff log indicates 'no diff captured'
# ---------------------------------------------------------------------------
test_audit_log_no_diff_marker() {
    local d="$TEST_BASE/t09" repo home log_files
    read -r repo home <<< "$(make_fake "$d")"
    HOME="$home" bash "$repo/sync.sh" restore --no-diff >/dev/null 2>&1
    log_files=$(find "$repo/docs/sync-log" -name "*.md" 2>/dev/null)
    grep -q "No diff captured" "$log_files" || grep -q "no-diff was set" "$log_files"
}
check "T09 audit log marks 'no diff captured' when --no-diff used" test_audit_log_no_diff_marker

# ---------------------------------------------------------------------------
# T10: Default mode shows EXPLAINED diff (heuristic banner present)
# ---------------------------------------------------------------------------
test_default_is_explained() {
    local d="$TEST_BASE/t10" repo home out
    read -r repo home <<< "$(make_fake "$d")"
    out=$(echo "n" | HOME="$home" bash "$repo/sync.sh" restore 2>&1)
    # "with explanations" is the do_diff banner when EXPLAIN=1.
    [[ "$out" == *"with explanations"* ]]
}
check "T10 restore default shows EXPLAINED diff" test_default_is_explained

# ---------------------------------------------------------------------------
# T11: --no-explain falls back to raw diff (no "with explanations" banner)
# ---------------------------------------------------------------------------
test_no_explain_raw_diff() {
    local d="$TEST_BASE/t11" repo home out
    read -r repo home <<< "$(make_fake "$d")"
    out=$(echo "n" | HOME="$home" bash "$repo/sync.sh" restore --no-explain 2>&1)
    # Should show raw "Differences: repo vs home" without "with explanations".
    [[ "$out" == *"Differences: repo vs home"* ]] && [[ "$out" != *"with explanations"* ]]
}
check "T11 --no-explain shows raw diff (no explanation banner)" test_no_explain_raw_diff

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
[[ $failed -eq 0 ]] && exit 0 || exit 1
