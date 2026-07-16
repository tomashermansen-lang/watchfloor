#!/bin/bash
# test_explain_diff.sh — tests for explain-diff.sh + explain-settings-diff.py
#
# Covers:
#   - settings.json heuristic (no API call needed)
#   - cache hit / cache miss for non-settings files
#   - graceful degradation when OPENAI_API_KEY is unconfigured
#   - identical files produce no output
#
# LLM-roundtrip is integration-only (requires real key). Not tested here.
#
# Usage: bash tests/test_explain_diff.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-diff.sh"
HEURISTIC="$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-settings-diff.py"

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

TEST_BASE="${TMPDIR:-/tmp}/test-explain-diff-$$"
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir -p "$TEST_BASE"

# ---------------------------------------------------------------------------
# Heuristic tests (no API)
# ---------------------------------------------------------------------------

test_heuristic_added_deny() {
    local dir="$TEST_BASE/h1" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"permissions":{"deny":[]}}' > "$old"
    echo '{"permissions":{"deny":["Edit(/secret/**)"]}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"✓ HARDEN"* ]] && [[ "$out" == *"Edit(/secret/"* ]]
}
check "T01 heuristic: added deny rule classified ✓ HARDEN" test_heuristic_added_deny

test_heuristic_removed_deny() {
    local dir="$TEST_BASE/h2" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"permissions":{"deny":["Edit(/x)"]}}' > "$old"
    echo '{"permissions":{"deny":[]}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"⚠ DANGER"* ]] && [[ "$out" == *"FJERNET"* ]] && [[ "$out" == *"guardrail"* ]]
}
check "T02 heuristic: removed deny rule classified ⚠ DANGER" test_heuristic_removed_deny

test_heuristic_added_hook() {
    local dir="$TEST_BASE/h3" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"hooks":{"PreToolUse":[]}}' > "$old"
    echo '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"bash foo.sh"}]}]}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"✓ HARDEN"* ]] && [[ "$out" == *"PreToolUse"* ]] && [[ "$out" == *"foo.sh"* ]]
}
check "T03 heuristic: added PreToolUse hook classified ✓ HARDEN" test_heuristic_added_hook

test_heuristic_changed_default_mode() {
    local dir="$TEST_BASE/h4" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"permissions":{"defaultMode":"default"}}' > "$old"
    echo '{"permissions":{"defaultMode":"bypassPermissions"}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    # default → bypassPermissions = stricter → permissive = ⚠ DANGER
    [[ "$out" == *"⚠ DANGER"* ]] && [[ "$out" == *"defaultMode"* ]] && [[ "$out" == *"bypassPermissions"* ]]
}
check "T04 heuristic: defaultMode strict→permissive classified ⚠ DANGER" test_heuristic_changed_default_mode

test_heuristic_added_allow() {
    local dir="$TEST_BASE/h4b" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"permissions":{"allow":["Read"]}}' > "$old"
    echo '{"permissions":{"allow":["Read","Bash"]}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"⚠ DANGER"* ]] && [[ "$out" == *"allow"* ]] && [[ "$out" == *"Bash"* ]]
}
check "T04b heuristic: added allow rule classified ⚠ DANGER" test_heuristic_added_allow

test_heuristic_removed_allow() {
    local dir="$TEST_BASE/h4c" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"permissions":{"allow":["Read","Bash"]}}' > "$old"
    echo '{"permissions":{"allow":["Read"]}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"✓ HARDEN"* ]] && [[ "$out" == *"allow"* ]] && [[ "$out" == *"Bash"* ]]
}
check "T04c heuristic: removed allow rule classified ✓ HARDEN" test_heuristic_removed_allow

test_heuristic_added_denyread() {
    local dir="$TEST_BASE/h4d" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"sandbox":{"filesystem":{"denyRead":[]}}}' > "$old"
    echo '{"sandbox":{"filesystem":{"denyRead":["~/Library/Cookies"]}}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"✓ HARDEN"* ]] && [[ "$out" == *"denyRead"* ]] && [[ "$out" == *"Cookies"* ]]
}
check "T04d heuristic: added denyRead path classified ✓ HARDEN" test_heuristic_added_denyread

test_heuristic_removed_denyread() {
    local dir="$TEST_BASE/h4e" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"sandbox":{"filesystem":{"denyRead":["~/.ssh"]}}}' > "$old"
    echo '{"sandbox":{"filesystem":{"denyRead":[]}}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"⚠ DANGER"* ]] && [[ "$out" == *"denyRead"* ]] && [[ "$out" == *"eksponerer"* ]]
}
check "T04e heuristic: removed denyRead path classified ⚠ DANGER" test_heuristic_removed_denyread

test_heuristic_network_added() {
    local dir="$TEST_BASE/h4f" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"sandbox":{"network":{"allowedDomains":[]}}}' > "$old"
    echo '{"sandbox":{"network":{"allowedDomains":["evil.com"]}}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"⚠ DANGER"* ]] && [[ "$out" == *"network"* ]] && [[ "$out" == *"udvider egress"* ]]
}
check "T04f heuristic: added network domain classified ⚠ DANGER" test_heuristic_network_added

test_heuristic_env_value_redacted() {
    local dir="$TEST_BASE/h5" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"env":{"SECRET_TOKEN":"old-value-1234"}}' > "$old"
    echo '{"env":{"SECRET_TOKEN":"new-value-5678"}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    # Must NOT contain either value (privacy)
    [[ "$out" != *"old-value-1234"* ]] && [[ "$out" != *"new-value-5678"* ]] && [[ "$out" == *"SECRET_TOKEN"* ]]
}
check "T05 heuristic: env value never shown (only key name)" test_heuristic_env_value_redacted

test_heuristic_no_change() {
    local dir="$TEST_BASE/h6" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"permissions":{"deny":["a","b"]}}' > "$old"
    echo '{"permissions":{"deny":["a","b"]}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"no structural changes"* ]]
}
check "T06 heuristic: identical input → 'no structural changes'" test_heuristic_no_change

test_heuristic_sandbox_disable() {
    local dir="$TEST_BASE/h7" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"sandbox":{"enabled":true}}' > "$old"
    echo '{"sandbox":{"enabled":false}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"⚠ DANGER"* ]] && [[ "$out" == *"sandbox.enabled"* ]] && [[ "$out" == *"false"* ]]
}
check "T07 heuristic: sandbox.enabled true→false classified ⚠ DANGER" test_heuristic_sandbox_disable

test_heuristic_sandbox_enable() {
    local dir="$TEST_BASE/h7b" old new out
    mkdir -p "$dir"
    old="$dir/old.json"; new="$dir/new.json"
    echo '{"sandbox":{"enabled":false}}' > "$old"
    echo '{"sandbox":{"enabled":true}}' > "$new"
    out=$(python3 "$HEURISTIC" "$old" "$new")
    [[ "$out" == *"✓ HARDEN"* ]] && [[ "$out" == *"sandbox.enabled"* ]]
}
check "T07b heuristic: sandbox.enabled false→true classified ✓ HARDEN" test_heuristic_sandbox_enable

# ---------------------------------------------------------------------------
# explain-diff.sh shell-level tests
# ---------------------------------------------------------------------------

test_identical_files_no_output() {
    local dir="$TEST_BASE/s1" a b out
    mkdir -p "$dir"
    a="$dir/a.txt"; b="$dir/b.txt"
    echo "same content" > "$a"
    echo "same content" > "$b"
    # Source the lib in subshell so we don't pollute parent env
    out=$(EXPLAIN_CACHE_DIR="$dir/cache" bash -c "source '$LIB' && explain_path '$a' '$b' 'a.txt'" 2>&1)
    [[ -z "$out" ]]
}
check "T08 explain_path: identical files → no output" test_identical_files_no_output

test_settings_routed_to_heuristic() {
    local dir="$TEST_BASE/s2" a b out
    mkdir -p "$dir"
    a="$dir/settings.json"; b="$dir/home-settings.json"
    echo '{"permissions":{"deny":["Edit(/x)"]}}' > "$a"
    echo '{"permissions":{"deny":[]}}' > "$b"
    out=$(EXPLAIN_CACHE_DIR="$dir/cache" bash -c "source '$LIB' && explain_path '$a' '$b' 'claude/settings.json'" 2>&1)
    # Heuristic output starts with "Heuristik" (Danish).
    [[ "$out" == *"Heuristik"* ]] && [[ "$out" != *"LLM"* ]]
}
check "T09 explain_path: settings.json routed to heuristic, not LLM" test_settings_routed_to_heuristic

test_missing_key_graceful() {
    local dir="$TEST_BASE/s3" a b fake_repo out
    mkdir -p "$dir"
    fake_repo="$dir/repo"
    mkdir -p "$fake_repo/claude/tools/lib" "$fake_repo/secrets"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/openai-key.sh" "$fake_repo/claude/tools/lib/"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-diff.sh" "$fake_repo/claude/tools/lib/"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-settings-diff.py" "$fake_repo/claude/tools/lib/"
    a="$dir/a.md"; b="$dir/b.md"
    echo "hello" > "$a"
    echo "world" > "$b"
    # Use the fake repo's lib (no openai.env present)
    out=$(EXPLAIN_CACHE_DIR="$dir/cache" bash -c "source '$fake_repo/claude/tools/lib/explain-diff.sh' && explain_path '$a' '$b' 'a.md'" 2>&1)
    [[ "$out" == *"utilgængelig"* ]] || [[ "$out" == *"setup-besked"* ]]
}
check "T10 explain_path: missing OpenAI key → graceful degradation message" test_missing_key_graceful

# ---------------------------------------------------------------------------
# Trust-chain self-modification detection
# ---------------------------------------------------------------------------

test_trust_chain_prompt_md_blocked() {
    local dir="$TEST_BASE/tc1" old new out
    mkdir -p "$dir"
    old="$dir/old.md"; new="$dir/new.md"
    echo "old prompt content" > "$old"
    echo "modified prompt content — totally legit upgrade" > "$new"
    out=$(EXPLAIN_CACHE_DIR="$dir/cache" bash -c "source '$LIB' && explain_path '$new' '$old' 'claude/tools/lib/explain-prompt.md'" 2>&1)
    # No LLM was called: "LLM:" / "LLM (cached):" prefixes never appear.
    # CRITICAL banner appears instead. Word "LLM" can appear inside the banner
    # text ("LLM-explanation IS DISABLED") — that's expected.
    [[ "$out" == *"CRITICAL"* ]] \
        && [[ "$out" == *"trust-chain"* ]] \
        && [[ "$out" != *$'\nLLM:\n'* ]] \
        && [[ "$out" != *"LLM (cached)"* ]]
}
check "T12 trust-chain: explain-prompt.md modification → CRITICAL + raw diff (no LLM)" \
    test_trust_chain_prompt_md_blocked

test_trust_chain_explain_diff_sh_blocked() {
    local dir="$TEST_BASE/tc2" old new out
    mkdir -p "$dir"
    old="$dir/old.sh"; new="$dir/new.sh"
    echo "echo old" > "$old"
    echo "echo new" > "$new"
    out=$(EXPLAIN_CACHE_DIR="$dir/cache" bash -c "source '$LIB' && explain_path '$new' '$old' 'claude/tools/lib/explain-diff.sh'" 2>&1)
    [[ "$out" == *"CRITICAL"* ]] && [[ "$out" == *"trust-chain"* ]]
}
check "T13 trust-chain: explain-diff.sh modification → CRITICAL" \
    test_trust_chain_explain_diff_sh_blocked

test_trust_chain_heuristic_blocked() {
    local dir="$TEST_BASE/tc3" old new out
    mkdir -p "$dir"
    old="$dir/old.py"; new="$dir/new.py"
    echo "x=1" > "$old"
    echo "x=2" > "$new"
    out=$(EXPLAIN_CACHE_DIR="$dir/cache" bash -c "source '$LIB' && explain_path '$new' '$old' 'claude/tools/lib/explain-settings-diff.py'" 2>&1)
    [[ "$out" == *"CRITICAL"* ]] && [[ "$out" == *"trust-chain"* ]]
}
check "T14 trust-chain: explain-settings-diff.py modification → CRITICAL" \
    test_trust_chain_heuristic_blocked

test_hook_script_NOT_trust_chain() {
    # A hook script change is NOT in trust chain — LLM should still be invoked
    # (or fall back to "LLM unavailable" message in test environment).
    local dir="$TEST_BASE/tc4" old new fake_repo out
    mkdir -p "$dir"
    fake_repo="$dir/repo"
    mkdir -p "$fake_repo/claude/tools/lib" "$fake_repo/secrets"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/openai-key.sh" "$fake_repo/claude/tools/lib/"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-diff.sh" "$fake_repo/claude/tools/lib/"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-settings-diff.py" "$fake_repo/claude/tools/lib/"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-prompt.md" "$fake_repo/claude/tools/lib/"
    old="$dir/old.sh"; new="$dir/new.sh"
    echo "echo a" > "$old"; echo "echo b" > "$new"
    # Export REPO_DIR not needed since we use $fake_repo. Pass cache+lib by env.
    export EXPLAIN_CACHE_DIR="$dir/cache"
    out=$(bash -c "source '$fake_repo/claude/tools/lib/explain-diff.sh' && explain_path '$new' '$old' 'claude/hooks/edit-write-allowlist.sh'" 2>&1)
    unset EXPLAIN_CACHE_DIR
    # Should NOT be CRITICAL — hook scripts go through LLM path (or graceful degradation)
    [[ "$out" != *"CRITICAL"* ]] && [[ "$out" != *"trust-chain"* ]]
}
check "T15 hook script change is NOT trust-chain → LLM path used" \
    test_hook_script_NOT_trust_chain

# ---------------------------------------------------------------------------
# NEW / DELETED file analysis
# ---------------------------------------------------------------------------

test_explain_new_file_invokes_llm() {
    local dir="$TEST_BASE/nf1" repo_file out
    mkdir -p "$dir"
    repo_file="$dir/some-new-tool.sh"
    echo "echo legitimate code" > "$repo_file"
    # No openai key configured → graceful degradation, but we can verify the
    # function ROUTED to the LLM path (vs. the trust-chain path).
    out=$(bash -c "source '$LIB' && explain_new_file '$repo_file' 'claude/hooks/some-new-tool.sh'" 2>&1)
    # Must not be CRITICAL (it's not trust-chain), must mention LLM path
    # (either successful response or graceful unavailable message).
    [[ "$out" != *"CRITICAL"* ]] && ([[ "$out" == *"LLM"* ]] || [[ "$out" == *"utilgængelig"* ]])
}
check "T17 explain_new_file routes to LLM (not CRITICAL) for non-trust-chain" \
    test_explain_new_file_invokes_llm

test_explain_new_file_trust_chain_critical() {
    local dir="$TEST_BASE/nf2" repo_file out
    mkdir -p "$dir"
    repo_file="$dir/explain-prompt.md"
    echo "fake new prompt" > "$repo_file"
    out=$(bash -c "source '$LIB' && explain_new_file '$repo_file' 'claude/tools/lib/explain-prompt.md'" 2>&1)
    [[ "$out" == *"CRITICAL"* ]] && [[ "$out" == *"trust-chain"* ]]
}
check "T18 explain_new_file: trust-chain file → CRITICAL (no LLM)" \
    test_explain_new_file_trust_chain_critical

test_explain_deleted_file_invokes_llm() {
    local dir="$TEST_BASE/df1" home_file out
    mkdir -p "$dir"
    home_file="$dir/old-tool.sh"
    echo "echo deleted content" > "$home_file"
    out=$(bash -c "source '$LIB' && explain_deleted_file '$home_file' 'claude/hooks/old-tool.sh'" 2>&1)
    [[ "$out" != *"CRITICAL"* ]] && ([[ "$out" == *"LLM"* ]] || [[ "$out" == *"utilgængelig"* ]])
}
check "T19 explain_deleted_file routes to LLM for non-trust-chain" \
    test_explain_deleted_file_invokes_llm

test_explain_deleted_file_trust_chain_critical() {
    local dir="$TEST_BASE/df2" home_file out
    mkdir -p "$dir"
    home_file="$dir/explain-diff.sh"
    echo "old explain-diff" > "$home_file"
    out=$(bash -c "source '$LIB' && explain_deleted_file '$home_file' 'claude/tools/lib/explain-diff.sh'" 2>&1)
    [[ "$out" == *"CRITICAL"* ]] && [[ "$out" == *"trust-chain"* ]]
}
check "T20 explain_deleted_file: trust-chain file → CRITICAL (no LLM)" \
    test_explain_deleted_file_trust_chain_critical

test_explain_dir_routes_new_to_llm_path() {
    # A new file in a directory should now produce a "NEW: ..." line AND
    # then either an LLM-line or graceful-degradation marker. Previously
    # only the bare filename was printed.
    local dir="$TEST_BASE/dir1" repo home out
    mkdir -p "$dir"
    repo="$dir/repo"; home="$dir/home"
    mkdir -p "$repo/sub" "$home/sub"
    echo "echo same" > "$repo/sub/existing.sh"
    echo "echo same" > "$home/sub/existing.sh"
    echo "echo brand new content" > "$repo/sub/newhook.sh"
    out=$(bash -c "source '$LIB' && explain_dir '$repo' '$home' 'claude/sub'" 2>&1)
    # Strip ANSI to make pattern matching robust against bold/dim formatting.
    local clean
    clean=$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')
    # Header now uses bold "NEW" + spaces + path. Match the path component.
    [[ "$clean" == *"NEW"* ]] \
        && [[ "$clean" == *"sub/newhook.sh"* ]] \
        && ([[ "$clean" == *"LLM"* ]] || [[ "$clean" == *"utilgængelig"* ]])
}
check "T21 explain_dir: NEW file produces LLM analysis (not bare filename)" \
    test_explain_dir_routes_new_to_llm_path

test_explain_prompt_md_exists() {
    [[ -f "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-prompt.md" ]] \
        && [[ -s "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-prompt.md" ]] \
        && grep -q "DANGER" "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-prompt.md" \
        && grep -q "HARDEN" "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-prompt.md" \
        && grep -q "NEUTRAL" "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-prompt.md"
}
check "T16 explain-prompt.md exists and contains classification keywords" \
    test_explain_prompt_md_exists

test_no_caching() {
    # After commit removing the cache, no on-disk cache dir should be
    # created during invocation. Verify by running and checking ~/.cache.
    local dir="$TEST_BASE/s4" old new fake_repo
    mkdir -p "$dir"
    fake_repo="$dir/repo"
    mkdir -p "$fake_repo/claude/tools/lib"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/openai-key.sh" "$fake_repo/claude/tools/lib/"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-diff.sh" "$fake_repo/claude/tools/lib/"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-settings-diff.py" "$fake_repo/claude/tools/lib/"
    cp "$REPO_DIR/adapters/claude-code/claude/tools/lib/explain-prompt.md" "$fake_repo/claude/tools/lib/"
    old="$dir/old.md"; new="$dir/new.md"
    echo "v1" > "$old"; echo "v2" > "$new"
    bash -c "source '$fake_repo/claude/tools/lib/explain-diff.sh' && explain_path '$new' '$old' 'a.md'" >/dev/null 2>&1 || true
    # No EXPLAIN_CACHE_DIR variable should be referenced anywhere in the lib
    ! grep -q 'EXPLAIN_CACHE_DIR\|_explain_cache_get\|_explain_cache_put' "$fake_repo/claude/tools/lib/explain-diff.sh"
}
check "T11 cache code removed (no EXPLAIN_CACHE_DIR / _explain_cache_*)" test_no_caching

# ---------------------------------------------------------------------------

echo ""
echo "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
[[ $failed -eq 0 ]] && exit 0 || exit 1
