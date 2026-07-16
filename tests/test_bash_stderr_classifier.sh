#!/usr/bin/env bash
# Test suite for bash-stderr-classify.sh (fix for the 24-38% failed-tool-
# result antipattern surfaced by canary A/B/C).
#
# Contract: classify_stderr <exit_code> <stderr_text> echoes
#   [exit_code=N stderr_class=X]
# where X is one of:
#   ok | sandbox_denied | not_found | permission_denied | timeout |
#   network_blocked | other
#
# Hermetic: synthetic stderr fed via stdin; no real bash tool, no
# autopilot, no claude.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLASSIFIER="$REPO_ROOT/adapters/claude-code/claude/tools/lib/bash-stderr-classify.sh"

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

run_classify() {
  local exit_code="$1"
  local stderr_text="$2"
  bash "$CLASSIFIER" "$exit_code" <<<"$stderr_text"
}

# ───── T1: exit 0 → ok regardless of stderr text ─────
out=$(run_classify 0 "")
check "T1.1: exit 0 + empty stderr → ok" grep -qE 'stderr_class=ok' <<<"$out"

out=$(run_classify 0 "some informational message on stderr")
check "T1.2: exit 0 + non-empty stderr → ok (exit dominates)" \
  grep -qE 'stderr_class=ok' <<<"$out"

# ───── T2: sandbox_denied ─────
out=$(run_classify 1 "pkill: Cannot get process list (operation not permitted)")
check "T2.1: pkill sandbox shape → sandbox_denied" \
  grep -qE 'stderr_class=sandbox_denied' <<<"$out"

out=$(run_classify 1 "Operation not permitted")
check "T2.2: bare 'Operation not permitted' → sandbox_denied" \
  grep -qE 'stderr_class=sandbox_denied' <<<"$out"

out=$(run_classify 1 "sysmon request failed: cannot read /proc")
check "T2.3: sysmon request failed → sandbox_denied" \
  grep -qE 'stderr_class=sandbox_denied' <<<"$out"

# ───── T3: not_found ─────
out=$(run_classify 1 "ls: /some/missing/path: No such file or directory")
check "T3.1: No such file → not_found" \
  grep -qE 'stderr_class=not_found' <<<"$out"

out=$(run_classify 127 "bash: nonexistent-cmd: command not found")
check "T3.2: command not found → not_found" \
  grep -qE 'stderr_class=not_found' <<<"$out"

# ───── T4: permission_denied ─────
out=$(run_classify 1 "bash: /root/secret: Permission denied")
check "T4.1: Permission denied → permission_denied" \
  grep -qE 'stderr_class=permission_denied' <<<"$out"

out=$(run_classify 1 "open() failed: EACCES")
check "T4.2: EACCES → permission_denied" \
  grep -qE 'stderr_class=permission_denied' <<<"$out"

# ───── T5: timeout ─────
out=$(run_classify 124 "command timed out after 60s")
check "T5.1: timed out → timeout" \
  grep -qE 'stderr_class=timeout' <<<"$out"

out=$(run_classify 137 "Killed by signal 9")
check "T5.2: killed by signal → timeout" \
  grep -qE 'stderr_class=timeout' <<<"$out"

# ───── T6: network_blocked ─────
out=$(run_classify 6 "curl: (6) Could not resolve host: pypi.org")
check "T6.1: Could not resolve host → network_blocked" \
  grep -qE 'stderr_class=network_blocked' <<<"$out"

out=$(run_classify 1 "ERROR: tunnel error connecting to api.example.com")
check "T6.2: tunnel error → network_blocked" \
  grep -qE 'stderr_class=network_blocked' <<<"$out"

# ───── T7: other ─────
out=$(run_classify 1 "some unexpected error nobody anticipated")
check "T7.1: unmatched stderr → other" \
  grep -qE 'stderr_class=other' <<<"$out"

# ───── T8: header shape — always [exit_code=N stderr_class=X] ─────
out=$(run_classify 0 "")
check "T8.1: header carries exit_code" grep -qE '^\[exit_code=0 ' <<<"$out"
out=$(run_classify 137 "Killed")
check "T8.2: header carries non-zero exit_code" \
  grep -qE '^\[exit_code=137 stderr_class=timeout\]' <<<"$out"

# ───── T9: precedence — sandbox_denied beats not_found ─────
# A pkill that hits sandbox often also mentions "No such file" downstream.
# The sandbox marker is the actionable signal — must win.
out=$(run_classify 1 "pkill: Operation not permitted
ls: foo: No such file or directory")
check "T9.1: sandbox marker takes precedence over not_found" \
  grep -qE 'stderr_class=sandbox_denied' <<<"$out"

# ───── T10: exit code is required positional, classifier rejects missing ─────
if bash "$CLASSIFIER" </dev/null >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("T10.1: missing exit_code arg → non-zero exit")
  echo "  FAIL: T10.1: missing exit_code arg → non-zero exit" >&2
else
  PASS=$((PASS + 1))
fi

# ───── T11: header is a SINGLE line (must be cheap to splice into a wrapped result) ─────
out=$(run_classify 1 "Permission denied")
line_count=$(printf '%s' "$out" | wc -l | tr -d ' ')
# wc -l counts trailing newlines; single-line output has 0 newline terminators
# or 1 (with trailing \n). Accept either.
check "T11.1: header is exactly one line" test "$line_count" -le 1

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
