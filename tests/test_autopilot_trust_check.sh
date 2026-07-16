#!/bin/bash
# test_autopilot_trust_check.sh — tests for autopilot-trust-check.sh
#
# Validates Constraint A enforcement: autopilot refuses to run when git
# remotes point at untrusted owners, repository is a fork, or other
# high-risk signals are present. AUTOPILOT_FORCE_RUN=1 must bypass.
#
# Usage: bash tests/test_autopilot_trust_check.sh

set -uo pipefail

REPO_DIR_REAL="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR_REAL/adapters/claude-code/claude/tools/lib/autopilot-trust-check.sh"

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

TEST_BASE="${TMPDIR:-/tmp}/test-trust-check-$$"
trap 'rm -rf "$TEST_BASE"' EXIT
mkdir -p "$TEST_BASE"

# Build a fake repo with a single named git remote
make_fake_repo() {
    local d="$1" remote_url="$2"
    rm -rf "$d"
    mkdir -p "$d"
    (
      cd "$d"
      git init -q -b main
      git config user.email "test@example.com"
      git config user.name "Test"
      [[ -n "$remote_url" ]] && git remote add origin "$remote_url"
      echo "x" > a.txt
      git add a.txt
      git commit -q -m "init"
    )
}

# ---------------------------------------------------------------------------
# T01: Trusted owner via env override → passes
# ---------------------------------------------------------------------------
test_trusted_owner_passes() {
    local d="$TEST_BASE/t01"
    make_fake_repo "$d" "git@github.com:my-org/foo.git"
    AUTOPILOT_TRUSTED_OWNERS="my-org" bash "$LIB" "$d" t01-task >/dev/null 2>&1
}
check "T01 trusted owner via env passes" test_trusted_owner_passes

# ---------------------------------------------------------------------------
# T02: Untrusted owner → blocks (exit 1)
# ---------------------------------------------------------------------------
test_untrusted_owner_blocks() {
    local d="$TEST_BASE/t02" exit_code
    make_fake_repo "$d" "git@github.com:bad-actor/foo.git"
    set +e
    AUTOPILOT_TRUSTED_OWNERS="my-org" bash "$LIB" "$d" t02-task >/dev/null 2>&1
    exit_code=$?
    set -e
    [[ "$exit_code" == "1" ]]
}
check "T02 untrusted owner blocks (exit 1)" test_untrusted_owner_blocks

# ---------------------------------------------------------------------------
# T03: AUTOPILOT_FORCE_RUN=1 bypasses block
# ---------------------------------------------------------------------------
test_force_run_bypasses() {
    local d="$TEST_BASE/t03"
    make_fake_repo "$d" "git@github.com:bad-actor/foo.git"
    AUTOPILOT_TRUSTED_OWNERS="my-org" AUTOPILOT_FORCE_RUN=1 bash "$LIB" "$d" t03-task >/dev/null 2>&1
}
check "T03 AUTOPILOT_FORCE_RUN=1 bypasses untrusted-owner block" test_force_run_bypasses

# ---------------------------------------------------------------------------
# T04: Multiple owners in trust list — comma-separated
# ---------------------------------------------------------------------------
test_multi_owner_list() {
    local d="$TEST_BASE/t04"
    make_fake_repo "$d" "git@github.com:second-org/foo.git"
    AUTOPILOT_TRUSTED_OWNERS="first-org,second-org,third-org" bash "$LIB" "$d" t04-task >/dev/null 2>&1
}
check "T04 multi-owner trust list works (comma-separated)" test_multi_owner_list

# ---------------------------------------------------------------------------
# T05: Case-insensitive owner matching
# ---------------------------------------------------------------------------
test_case_insensitive() {
    local d="$TEST_BASE/t05"
    make_fake_repo "$d" "git@github.com:My-Org/foo.git"
    AUTOPILOT_TRUSTED_OWNERS="my-org" bash "$LIB" "$d" t05-task >/dev/null 2>&1
}
check "T05 case-insensitive owner matching" test_case_insensitive

# ---------------------------------------------------------------------------
# T06: HTTPS remote URL parsed correctly
# ---------------------------------------------------------------------------
test_https_url() {
    local d="$TEST_BASE/t06"
    make_fake_repo "$d" "https://github.com/my-org/foo.git"
    AUTOPILOT_TRUSTED_OWNERS="my-org" bash "$LIB" "$d" t06-task >/dev/null 2>&1
}
check "T06 HTTPS remote URL parsed correctly" test_https_url

# ---------------------------------------------------------------------------
# T07: Risk keyword in task name → warning (not blocker)
# ---------------------------------------------------------------------------
test_risk_keyword_warns() {
    local d="$TEST_BASE/t07" stderr exit_code
    make_fake_repo "$d" "git@github.com:my-org/foo.git"
    set +e
    stderr=$(AUTOPILOT_TRUSTED_OWNERS="my-org" bash "$LIB" "$d" review-pr-fork-stuff 2>&1 >/dev/null)
    exit_code=$?
    set -e
    # Should exit 0 (only warn) but stderr mentions risk-keyword
    [[ "$exit_code" == "0" ]] && [[ "$stderr" == *"risk-keyword"* || "$stderr" == *"warnings"* ]]
}
check "T07 risk keyword in task name → warning (not blocker)" test_risk_keyword_warns

# ---------------------------------------------------------------------------
# T08: No remote → passes (local-only repo is fine)
# ---------------------------------------------------------------------------
test_no_remote() {
    local d="$TEST_BASE/t08"
    make_fake_repo "$d" ""
    AUTOPILOT_TRUSTED_OWNERS="my-org" bash "$LIB" "$d" t08-task >/dev/null 2>&1
}
check "T08 repo with no remote → passes" test_no_remote

# ---------------------------------------------------------------------------
# T09: Multiple remotes — any untrusted blocks
# ---------------------------------------------------------------------------
test_multi_remote_one_untrusted() {
    local d="$TEST_BASE/t09" exit_code
    make_fake_repo "$d" "git@github.com:my-org/foo.git"
    git -C "$d" remote add upstream "git@github.com:bad-actor/foo.git"
    set +e
    AUTOPILOT_TRUSTED_OWNERS="my-org" bash "$LIB" "$d" t09-task >/dev/null 2>&1
    exit_code=$?
    set -e
    [[ "$exit_code" == "1" ]]
}
check "T09 multiple remotes — any untrusted blocks" test_multi_remote_one_untrusted

# ---------------------------------------------------------------------------
# T10: Owner-extraction handles GitHub noreply email format in fallback
# ---------------------------------------------------------------------------
test_email_fallback_strips_noreply() {
    local d="$TEST_BASE/t10"
    make_fake_repo "$d" "git@github.com:legit-user/foo.git"
    # Set git user.email to GitHub noreply format
    # IMPORTANT: only override globally for the test, not the user's actual config
    (
      cd "$d"
      # Use HOME override to isolate git config writes
      export HOME="$d/fakehome"
      mkdir -p "$HOME"
      git config --global user.email "12345+legit-user@users.noreply.github.com"
      # Without AUTOPILOT_TRUSTED_OWNERS, falls back to email parsing.
      # Should extract "legit-user" and trust the matching remote.
      unset AUTOPILOT_TRUSTED_OWNERS
      bash "$LIB" "$d" t10-task >/dev/null 2>&1
    )
}
check "T10 email-fallback strips GitHub noreply 'id+' prefix" test_email_fallback_strips_noreply

# ---------------------------------------------------------------------------
# T11: Self-test on real dotfiles repo passes (sanity check)
# ---------------------------------------------------------------------------
test_self_passes() {
    bash "$LIB" "$REPO_DIR_REAL" self-test >/dev/null 2>&1
}
check "T11 trust-check passes on the real dotfiles repo (sanity)" test_self_passes

# ---------------------------------------------------------------------------
# T12: Sub-directory of a trusted repo also passes
# ---------------------------------------------------------------------------
test_subdir_of_trusted() {
    local d="$TEST_BASE/t12"
    make_fake_repo "$d" "git@github.com:my-org/foo.git"
    mkdir -p "$d/sub"
    AUTOPILOT_TRUSTED_OWNERS="my-org" bash "$LIB" "$d/sub" t12-task >/dev/null 2>&1
}
check "T12 sub-directory of trusted repo passes" test_subdir_of_trusted

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
[[ $failed -eq 0 ]] && exit 0 || exit 1
