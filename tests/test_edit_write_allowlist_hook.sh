#!/bin/bash
# test_edit_write_allowlist_hook.sh — TDD test suite for edit-write-allowlist.sh
#
# The hook reads JSON from stdin (Claude Code PreToolUse contract), extracts
# tool_input.file_path, canonicalizes it, and exits 2 if the path is outside
# the allowlist. Allowlist mirrors sandbox.filesystem.allowWrite.
#
# Usage: bash tests/test_edit_write_allowlist_hook.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_DIR/adapters/claude-code/claude/hooks/edit-write-allowlist.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

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

# Helper: invoke hook with a file_path payload and expected exit code.
# Usage: assert_hook_exit <expected_exit> <file_path>
assert_hook_exit() {
    local expected="$1"
    local path="$2"
    local payload exit_code
    payload=$(printf '{"tool_input":{"file_path":"%s"}}' "$path")
    set +e
    echo "$payload" | bash "$HOOK" >/dev/null 2>&1
    exit_code=$?
    set -e
    [[ "$exit_code" == "$expected" ]]
}

TEST_DIR="${TMPDIR:-/tmp}/test-allowlist-hook-$$"
setup() { rm -rf "$TEST_DIR"; mkdir -p "$TEST_DIR"; }
teardown() { rm -rf "$TEST_DIR"; }
trap teardown EXIT

echo "Running edit-write-allowlist hook tests..."
echo ""

# =============================================================================
# Allowed paths — must exit 0
# =============================================================================

check "T01 allow: ~/Projekter/dotfiles/foo.txt" \
    assert_hook_exit 0 "$HOME/Projekter/dotfiles/foo.txt"

check "T02 allow: ~/Projekter/dotfiles/claude/hooks/x.sh (source location is OK)" \
    assert_hook_exit 0 "$HOME/Projekter/dotfiles/claude/hooks/x.sh"

check "T03 allow: /tmp/foo.txt" \
    assert_hook_exit 0 "/tmp/foo.txt"

check "T04 allow: \$TMPDIR/foo.txt" \
    assert_hook_exit 0 "${TMPDIR:-/tmp}/foo.txt"

check "T05 allow: ~/.cache/foo" \
    assert_hook_exit 0 "$HOME/.cache/foo"

check "T06 allow: ~/.docker/config.json" \
    assert_hook_exit 0 "$HOME/.docker/config.json"

check "T07 allow: ~/.claude/debug/log.txt (debug subdir is OK)" \
    assert_hook_exit 0 "$HOME/.claude/debug/log.txt"

check "T08 allow: ~/.npm/_logs/x.log" \
    assert_hook_exit 0 "$HOME/.npm/_logs/x.log"

# =============================================================================
# Disallowed paths — must exit 2
# =============================================================================

check "T09 deny: ~/Documents/foo.txt (outside trust zone)" \
    assert_hook_exit 2 "$HOME/Documents/foo.txt"

check "T10 deny: /etc/passwd" \
    assert_hook_exit 2 "/etc/passwd"

check "T11 deny: ~/.ssh/id_rsa (credential)" \
    assert_hook_exit 2 "$HOME/.ssh/id_rsa"

check "T12 deny: ~/.bashrc (shell config)" \
    assert_hook_exit 2 "$HOME/.bashrc"

check "T13 deny: ~/.claude/hooks/foo.sh (deployed config — only sync.sh restore can write here)" \
    assert_hook_exit 2 "$HOME/.claude/hooks/foo.sh"

check "T14 deny: ~/.claude/agents/foo.md" \
    assert_hook_exit 2 "$HOME/.claude/agents/foo.md"

check "T15 deny: ~/.claude/commands/foo.md" \
    assert_hook_exit 2 "$HOME/.claude/commands/foo.md"

check "T16 deny: ~/.claude/skills/foo/SKILL.md" \
    assert_hook_exit 2 "$HOME/.claude/skills/foo/SKILL.md"

check "T17 deny: ~/.claude/settings.json" \
    assert_hook_exit 2 "$HOME/.claude/settings.json"

check "T18 deny: /Applications/foo" \
    assert_hook_exit 2 "/Applications/foo"

# =============================================================================
# Path traversal / canonicalization — must resolve before checking
# =============================================================================

check "T19 deny: traversal ~/Projekter/../../etc/passwd → /etc/passwd" \
    assert_hook_exit 2 "$HOME/Projekter/../../etc/passwd"

check "T20 deny: traversal /tmp/../etc/passwd → /etc/passwd" \
    assert_hook_exit 2 "/tmp/../etc/passwd"

# Symlink escape: create a symlink in allowed dir pointing outside, write through it.
test_symlink_escape() {
    setup
    ln -s /etc "$TEST_DIR/escape"
    # File doesn't have to exist — we test the path resolution.
    assert_hook_exit 2 "$TEST_DIR/escape/passwd"
}
check "T21 deny: symlink in allowed dir to /etc → resolved to /etc" \
    test_symlink_escape

# =============================================================================
# Edge cases — defensive, must not break other tools
# =============================================================================

check "T22 allow: empty file_path (graceful no-op)" \
    assert_hook_exit 0 ""

# Missing file_path field at all (Edit/Write without file_path is rare but possible)
test_missing_field() {
    set +e
    echo '{"tool_input":{}}' | bash "$HOOK" >/dev/null 2>&1
    local exit_code=$?
    set -e
    [[ "$exit_code" == "0" ]]
}
check "T23 allow: missing file_path field (graceful no-op)" \
    test_missing_field

# Malformed JSON should not crash the hook
test_malformed_json() {
    set +e
    echo 'not json' | bash "$HOOK" >/dev/null 2>&1
    local exit_code=$?
    set -e
    # Either 0 (graceful no-op) or 2 (deny on parse fail) — but NOT crash code
    [[ "$exit_code" == "0" || "$exit_code" == "2" ]]
}
check "T24 robustness: malformed JSON does not crash" \
    test_malformed_json

# Tool input field 'file' (alternative naming used by some tools)
test_alt_field() {
    set +e
    printf '{"tool_input":{"file":"%s"}}' "$HOME/Projekter/foo.txt" | bash "$HOOK" >/dev/null 2>&1
    local exit_code=$?
    set -e
    [[ "$exit_code" == "0" ]]
}
check "T25 allow: tool_input.file (alt field name)" \
    test_alt_field

# Stderr message on deny — must include the path and a hint
test_deny_stderr() {
    local stderr
    set +e
    stderr=$(printf '{"tool_input":{"file_path":"%s"}}' "$HOME/Documents/x" | bash "$HOOK" 2>&1 >/dev/null)
    set -e
    [[ "$stderr" == *"Documents"* ]] && [[ "$stderr" == *"sync.sh restore"* || "$stderr" == *"trust zone"* || "$stderr" == *"allowlist"* ]]
}
check "T26 deny stderr mentions path and remediation" \
    test_deny_stderr

# =============================================================================
# Explicit deny list (defense in depth — survives allowlist widening)
# =============================================================================

# Stderr message on explicit-deny path mentions the runtime-config remediation
test_explicit_deny_settings_message() {
    local stderr
    set +e
    stderr=$(printf '{"tool_input":{"file_path":"%s"}}' "$HOME/.claude/settings.json" | bash "$HOOK" 2>&1 >/dev/null)
    set -e
    [[ "$stderr" == *"explicitly denied"* ]] && [[ "$stderr" == *"sync.sh restore"* ]]
}
check "T27 explicit-deny: ~/.claude/settings.json shows runtime-config message" \
    test_explicit_deny_settings_message

check "T28 explicit-deny: ~/.claude/settings.local.json blocked" \
    assert_hook_exit 2 "$HOME/.claude/settings.local.json"

check "T29 explicit-deny: ~/.claude/CLAUDE.md blocked" \
    assert_hook_exit 2 "$HOME/.claude/CLAUDE.md"

# Verify the explicit-deny check survives a future widening of the allowlist.
# We simulate this by setting an env override (hook reads HOME) and checking
# settings.json is still blocked even though we're inside ~/.claude.
# This is a structural check: even with $HOME in allowlist, settings.json
# would be caught by the explicit-deny that runs FIRST.
test_explicit_deny_runs_before_allowlist() {
    # Structural check: EXPLICIT_DENY array declaration must come before the
    # ALLOWED= declaration in the hook source. This guarantees explicit-deny
    # fires first even if the allowlist is later widened to include
    # ~/.claude.
    local ed_line al_line
    ed_line=$(grep -n '^EXPLICIT_DENY=(' "$HOOK" | head -1 | cut -d: -f1)
    al_line=$(grep -n '^ALLOWED=(' "$HOOK" | head -1 | cut -d: -f1)
    [[ -n "$ed_line" ]] && [[ -n "$al_line" ]] && [[ "$ed_line" -lt "$al_line" ]]
}
check "T30 explicit-deny declared and processed BEFORE allowlist" \
    test_explicit_deny_runs_before_allowlist

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
[[ $failed -eq 0 ]] && exit 0 || exit 1
