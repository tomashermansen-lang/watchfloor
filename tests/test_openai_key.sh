#!/bin/bash
# test_openai_key.sh — tests for claude/tools/lib/openai-key.sh
#
# Each test invokes the helper in a controlled REPO_DIR sandbox so the real
# secrets/openai.env is never touched.
#
# Usage: bash tests/test_openai_key.sh

set -uo pipefail

REPO_DIR_REAL="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR_REAL/adapters/claude-code/claude/tools/lib/openai-key.sh"

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

# Each test creates a fake repo layout with secrets/ inside it, copies LIB
# into the right relative location, and exercises the loader.
make_fake_repo() {
    local d="$1" key_value="${2:-}"
    rm -rf "$d"
    mkdir -p "$d/claude/tools/lib" "$d/secrets"
    cp "$LIB" "$d/claude/tools/lib/openai-key.sh"
    if [[ -n "$key_value" ]]; then
        printf 'OPENAI_API_KEY=%s\n' "$key_value" > "$d/secrets/openai.env"
    fi
}

TEST_BASE="${TMPDIR:-/tmp}/test-openai-key-$$"
trap 'rm -rf "$TEST_BASE"' EXIT

# ---------------------------------------------------------------------------
# T01: missing file → fail with setup hint
# ---------------------------------------------------------------------------
test_missing_file() {
    local d="$TEST_BASE/t01"
    make_fake_repo "$d"  # no secrets/openai.env
    local out exit_code
    set +e
    out=$(bash "$d/claude/tools/lib/openai-key.sh" 2>&1)
    exit_code=$?
    set -e
    [[ "$exit_code" == "1" ]] && [[ "$out" == *"not configured"* ]] && [[ "$out" == *"openai.env.example"* ]]
}
check "T01 missing secrets/openai.env → exit 1 with setup hint" test_missing_file

# ---------------------------------------------------------------------------
# T02: empty key → fail
# ---------------------------------------------------------------------------
test_empty_key() {
    local d="$TEST_BASE/t02"
    make_fake_repo "$d" ""  # empty value
    local exit_code
    set +e
    bash "$d/claude/tools/lib/openai-key.sh" >/dev/null 2>&1
    exit_code=$?
    set -e
    [[ "$exit_code" == "1" ]]
}
check "T02 empty OPENAI_API_KEY → exit 1" test_empty_key

# ---------------------------------------------------------------------------
# T03: placeholder value → fail
# ---------------------------------------------------------------------------
test_placeholder() {
    local d="$TEST_BASE/t03"
    make_fake_repo "$d" "sk-replace-me"
    local out exit_code
    set +e
    out=$(bash "$d/claude/tools/lib/openai-key.sh" 2>&1)
    exit_code=$?
    set -e
    [[ "$exit_code" == "1" ]] && [[ "$out" == *"placeholder"* ]]
}
check "T03 placeholder value → exit 1 with placeholder hint" test_placeholder

# ---------------------------------------------------------------------------
# T04: valid key → exit 0 and "loaded" message
# ---------------------------------------------------------------------------
test_valid_key() {
    local d="$TEST_BASE/t04"
    make_fake_repo "$d" "sk-test-validkey-1234"
    local out exit_code
    set +e
    out=$(bash "$d/claude/tools/lib/openai-key.sh" 2>&1)
    exit_code=$?
    set -e
    [[ "$exit_code" == "0" ]] && [[ "$out" == *"loaded"* ]]
}
check "T04 valid key → exit 0 with confirmation" test_valid_key

# ---------------------------------------------------------------------------
# T05: sourced + load_openai_key → exports OPENAI_API_KEY into parent shell
# ---------------------------------------------------------------------------
test_sourced() {
    local d="$TEST_BASE/t05"
    make_fake_repo "$d" "sk-sourced-test-9999"
    local key
    set +e
    key=$(bash -c "source '$d/claude/tools/lib/openai-key.sh' && load_openai_key && echo \"\$OPENAI_API_KEY\"")
    local exit_code=$?
    set -e
    [[ "$exit_code" == "0" ]] && [[ "$key" == "sk-sourced-test-9999" ]]
}
check "T05 sourced + load_openai_key exports OPENAI_API_KEY" test_sourced

# ---------------------------------------------------------------------------
# T06: secrets/openai.env is gitignored (real repo check)
# ---------------------------------------------------------------------------
test_gitignored() {
    cd "$REPO_DIR_REAL"
    git check-ignore secrets/openai.env >/dev/null 2>&1
}
check "T06 secrets/openai.env is gitignored" test_gitignored

# ---------------------------------------------------------------------------
# T07: secrets/openai.env.example is NOT gitignored (template tracked)
# ---------------------------------------------------------------------------
test_example_tracked() {
    cd "$REPO_DIR_REAL"
    ! git check-ignore secrets/openai.env.example >/dev/null 2>&1
}
check "T07 secrets/openai.env.example is tracked (not gitignored)" test_example_tracked

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
[[ $failed -eq 0 ]] && exit 0 || exit 1
