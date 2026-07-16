#!/bin/bash
# PreToolUse hook: TDD gate — blocks src/ writes when no test was modified first.
# Returns exit 2 to deny the tool call with feedback to Claude.
# Zero token cost — pure shell, no LLM invocation.
#
# Git queries are anchored to the file's repo root (via git -C) so the gate
# works regardless of the shell cwd — robust to worktrees and to Bash `cd`
# side-effects inside the session. Test-file detection covers both Python
# (tests/ at repo root) and TypeScript (any __tests__/ directory).

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.file // ""')

# Writes TO a test file are the test-first step — never gate them, even
# when the test file's own path contains the substring "src/" (e.g.
# src/__tests__/foo.test.ts under a Vite-style frontend, or a colocated
# *.test.ts / *_test.py next to its production sibling).
case "$FILE_PATH" in
    */__tests__/*) exit 0 ;;
    */tests/*) exit 0 ;;
    *.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.test.mjs|*.test.cjs) exit 0 ;;
    *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx) exit 0 ;;
    *_test.py|*_test.go) exit 0 ;;
    test_*.py) exit 0 ;;
esac

# Only gate implementation source files. Bash `*` in case patterns matches
# any sequence INCLUDING slashes, so each "*/path/*.py" rule covers files
# at any depth beneath that prefix (e.g. dashboard/server/middleware/csrf.py
# is caught by the dashboard/server rule).
#
# Bash files (.sh) are intentionally NOT gated — shellcheck is the bash
# quality gate (/implement Step 5.2 + /static-analysis Step 2.4 + the
# grinder's whole-repo pass). The TDD hook only enforces unit-test
# discipline, which is not the convention for bash orchestrators here.
#
# Surfaces gated (extended 2026-05-23 from /src/ alone):
#   - */src/*                                       TypeScript frontend
#   - */adapters/claude-code/claude/tools/*.py      Pipeline orchestrators (Python)
#   - */dashboard/server/*.py                       FastAPI backend (any depth)
#   - */dashboard/tools/*.py                        Dashboard CLI helpers
case "$FILE_PATH" in
    */src/*) ;;
    */adapters/claude-code/claude/tools/*.py) ;;
    */dashboard/server/*.py) ;;
    */dashboard/tools/*.py) ;;
    *) exit 0 ;;
esac

# Anchor git queries to the file's repo root (not the shell cwd).
FILE_DIR=$(dirname "$FILE_PATH")
REPO_ROOT=$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null)
[ -z "$REPO_ROOT" ] && exit 0

TEST_SPECS=(':(glob)**/tests/**' ':(glob)**/__tests__/**')
# pathspec scope:
#   **/tests/**       — root tests/ AND nested like dashboard/tests/,
#                       OIH/tests/, etc. (the repo has multiple test trees)
#   **/__tests__/**   — TypeScript convention (Vite/Jest colocated tests)
# Pre-2026-05-25 the spec was ':/tests/' which is git's "repo-top-only"
# anchor and missed every nested test tree. Caught when a test edit to
# dashboard/tests/test_autopilot_helpers.py failed to satisfy the gate.

# Allow if any test file has uncommitted changes (staged or unstaged).
if git -C "$REPO_ROOT" status --porcelain -- "${TEST_SPECS[@]}" 2>/dev/null | grep -q .; then
    exit 0
fi

# Allow if on a feature/hotfix branch and tests were committed in this branch.
BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null)
case "$BRANCH" in
    feature/*|hotfix/*)
        if git -C "$REPO_ROOT" diff --name-only main...HEAD -- "${TEST_SPECS[@]}" 2>/dev/null | grep -q .; then
            exit 0
        fi
        ;;
esac

echo "TDD: modify a test file (tests/ or __tests__/) before writing to src/. Test-first!" >&2
exit 2
