#!/usr/bin/env bash
# Test suite for the classify-bash-result PostToolUse hook + its
# settings.json wiring.
#
# Hermetic: synthesises PostToolUse payloads via echo + JSON; never
# spawns claude or autopilot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/adapters/claude-code/claude/hooks/classify-bash-result.sh"
SETTINGS="$REPO_ROOT/adapters/claude-code/claude/settings.json"

PASS=0
FAIL=0
FAILED_NAMES=()

check() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "  FAIL: $name" >&2
  fi
}

# ───── T1: hook file exists, is executable ─────
check "T1.1: hook script exists" test -f "$HOOK"
check "T1.2: hook is executable" test -x "$HOOK"

# ───── T2: hook handles sandbox_denied payload ─────
out=$(echo '{"tool_response":{"exit_code":1,"stderr":"pkill: Operation not permitted"}}' | bash "$HOOK")
check "T2.1: sandbox_denied surfaced as additionalContext" \
  grep -q 'stderr_class=sandbox_denied' <<<"$out"
check "T2.2: output is JSON with hookSpecificOutput" \
  grep -q 'hookSpecificOutput' <<<"$out"

# ───── T3: ok payload (exit 0) ─────
out=$(echo '{"tool_response":{"exit_code":0,"stderr":"","output":"hello"}}' | bash "$HOOK")
check "T3.1: exit 0 → stderr_class=ok" grep -q 'stderr_class=ok' <<<"$out"

# ───── T4: is_error shape (no exit_code field) ─────
out=$(echo '{"tool_response":{"is_error":true,"output":"ls: nope: No such file or directory"}}' | bash "$HOOK")
check "T4.1: is_error+output → not_found via output fallback" \
  grep -q 'stderr_class=not_found' <<<"$out"

# ───── T5: malformed payload → silent no-op (does not crash) ─────
ec=0
echo 'not json at all' | bash "$HOOK" >/dev/null 2>&1 || ec=$?
check "T5.1: malformed input → exit 0" test "$ec" -eq 0

# ───── T6: hook is wired in settings.json under PostToolUse Bash matcher ─────
check "T6.1: settings.json references classify-bash-result.sh" \
  grep -q 'classify-bash-result.sh' "$SETTINGS"

# Use python3 with stdlib json to confirm the structure: the hook
# command appears under hooks.PostToolUse[].hooks[] when the parent
# matcher is "Bash".
check "T6.2: hook is under PostToolUse Bash matcher" \
  python3 -c "
import json, sys
data = json.load(open('$SETTINGS'))
post = data.get('hooks', {}).get('PostToolUse', [])
found = False
for group in post:
    if group.get('matcher') != 'Bash':
        continue
    for h in group.get('hooks', []):
        if 'classify-bash-result.sh' in h.get('command', ''):
            found = True
sys.exit(0 if found else 1)
"

# ───── T7: classifier link — hook references the classifier path ─────
check "T7.1: hook references bash-stderr-classify.sh" \
  grep -q 'bash-stderr-classify.sh' "$HOOK"

# ───── T8: CLAUDE.md ships the rubric the classes are referenced by ─────
CLAUDE_MD="$REPO_ROOT/adapters/claude-code/claude/CLAUDE.md"
check "T8.1: CLAUDE.md has Bash error class rubric header" \
  grep -q '^## Bash error class rubric$' "$CLAUDE_MD"
check "T8.2: rubric documents sandbox_denied" \
  grep -q '`sandbox_denied`' "$CLAUDE_MD"
check "T8.3: rubric documents all seven classes" \
  bash -c "for c in ok sandbox_denied not_found permission_denied timeout network_blocked other; do
    grep -q \"\\\`\$c\\\`\" '$CLAUDE_MD' || exit 1
  done"

# ───── Final ─────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  for n in "${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"}"; do
    echo "  - $n" >&2
  done
  exit 1
fi
exit 0
